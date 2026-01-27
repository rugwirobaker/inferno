package main

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"sync"
	"time"

	"syscall"

	"github.com/rugwirobaker/inferno/internal/image"
	"github.com/rugwirobaker/inferno/internal/process"
	"github.com/rugwirobaker/inferno/internal/process/primary"
	"github.com/rugwirobaker/inferno/internal/process/ssh"
	"github.com/rugwirobaker/inferno/internal/vsock"
	"golang.org/x/sys/unix"
)

const Path = "PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin"

var LogLevel struct {
	sync.Mutex
	slog.LevelVar
}

// main starts an init process that can prepare an environment and start a shell
// after the Kernel has started.
func main() {
	ctx := context.Background()

	// Load and validate configuration
	config, err := image.FromFile("/inferno/run.json")
	if err != nil {
		panic(fmt.Sprintf("could not read run.json, error: %s", err))
	}

	if err := configureLogger(config); err != nil {
		panic(fmt.Sprintf("could not configure logger, error: %s", err))
	}

	slog.Info("inferno init started")
	slog.With("config", config).Debug("loaded config")

	// Initial system setup
	if err := MountInitialDevFS(); err != nil {
		slog.Error("Failed to mount initial devfs", "error", err)
		os.Exit(1)
	}

	// Mount root filesystem
	if err := MountRootFS(config.Mounts.Root.Device, config.Mounts.Root.FSType, config.Mounts.Root.Options); err != nil {
		slog.Error("Failed to mount root filesystem", "error", err)
		os.Exit(1)
	}

	// Mount /run as tmpfs for runtime data (needed by cryptsetup for lock files)
	// This must happen early, before volume unlock
	if err := os.MkdirAll("/run", 0755); err != nil {
		slog.Error("Failed to create /run", "error", err)
		os.Exit(1)
	}
	if err := syscall.Mount("tmpfs", "/run", "tmpfs", 0, "mode=0755"); err != nil {
		slog.Error("Failed to mount /run", "error", err)
		os.Exit(1)
	}
	if err := os.MkdirAll("/run/cryptsetup", 0755); err != nil {
		slog.Error("Failed to create /run/cryptsetup", "error", err)
		os.Exit(1)
	}

	// Unlock encrypted volumes BEFORE moving /dev
	// This must happen while /dev is still in initramfs where devices are accessible
	if err := unlockEncryptedVolumes(ctx, config); err != nil {
		slog.Error("FATAL: encrypted volume unlock failed", "error", err)
		// Fail fast - exit init with non-zero status
		// VM will terminate, operator must fix key/volume issues
		os.Exit(1)
	}

	// Move /dev to new root AFTER volume unlock
	// This preserves both /dev/vdb and /dev/mapper/*_crypt devices
	if err := MoveDevToNewRoot(); err != nil {
		slog.Error("Failed to move /dev to new root", "error", err)
		os.Exit(1)
	}

	// Switch to new root
	if err := switchRoot(); err != nil {
		slog.Error("Failed to switch root", "error", err)
		os.Exit(1)
	}

	// Mount essential filesystems
	if err := MountFS(); err != nil {
		slog.Error("Failed to mount filesystems", "error", err)
		os.Exit(1)
	}

	// Mount additional volumes
	for _, vol := range config.Mounts.Volumes {
		flags := MountFlags{}
		for _, opt := range vol.Options {
			switch opt {
			case "ro":
				flags.ReadOnly = true
			case "noexec":
				flags.NoExec = true
			case "nosuid":
				flags.NoSuid = true
			case "nodev":
				flags.NoDev = true
			case "relatime":
				flags.RelaTime = true
			}
		}

		// Use mapper device for encrypted volumes
		device := vol.Device
		if vol.Encrypted {
			mapperName := strings.TrimPrefix(vol.Device, "/dev/")
			mapperName = strings.ReplaceAll(mapperName, "/", "_") + "_crypt"
			device = "/dev/mapper/" + mapperName
			slog.Debug("using mapper device for encrypted volume",
				"original", vol.Device,
				"mapper", device,
			)
		}

		if err := Mount(device, vol.MountPoint, vol.FSType, flags, ""); err != nil {
			slog.Error("Failed to mount volume",
				"device", device,
				"mountPoint", vol.MountPoint,
				"error", err,
			)
			os.Exit(1)
		}
	}

	// Create necessary directories
	if err := os.MkdirAll("/run/lock", 0755); err != nil {
		slog.Error("Failed to create /run/lock", "error", err)
		os.Exit(1)
	}

	if err := unix.Setrlimit(0, &unix.Rlimit{Cur: 10240, Max: 10240}); err != nil {
		slog.Error("Failed to set rlimit", "error", err)
		os.Exit(1)
	}

	if err := os.Setenv("PATH", Path); err != nil {
		slog.Error("Failed to set PATH env", "error", err)
	}

	if err := setHostname(config.ID); err != nil {
		slog.Error("Failed to set hostname", "error", err)
	}

	// mkdir /etc with 0755
	if err := os.MkdirAll("/etc", 0755); err != nil {
		slog.Error("Failed to create /etc", "error", err)
		os.Exit(1)
	}

	// write hostname to /etc/hostname
	if err := os.WriteFile("/etc/hostname", []byte(config.ID), 0644); err != nil {
		slog.Error("Failed to write hostname to /etc/hostname", "error", err)
		os.Exit(1)
	}

	// write resolv.conf
	if err := writeResolvConf(config.EtcResolv); err != nil {
		slog.Error("Failed to write resolv.conf", "error", err)
		os.Exit(1)
	}

	// populate /etc/hosts
	if err := writeEtcHost(config.EtcHost); err != nil {
		slog.Error("Failed to write /etc/hosts", "error", err)
		os.Exit(1)
	}

	slog.Debug("Mounting user defined files")
	if err := CreateUserFiles(config.Files); err != nil {
		slog.Error("Failed to create user files", "error", err)
		os.Exit(1)
	}

	if err := setupNetworking(*config); err != nil {
		slog.Error("Failed to setup networking", "error", err)
		os.Exit(1)
	}

	// Setup the user environment
	users := NewUserManager(config.User)
	if err := users.Initialize(); err != nil {
		slog.Error("Failed to setup user", "error", err)
		os.Exit(1)
	}

	// Create VSOCK client to send exit status
	exitClient, err := vsock.NewHostClient(ctx, uint32(config.VsockExitPort))
	if err != nil {
		slog.Error("Failed to create exit code vsock client", "error", err)
		os.Exit(1)
	}

	// Open VSOCK connection for logging
	stdoutConn, err := vsock.NewVsockConn(uint32(config.VsockStdoutPort))
	if err != nil {
		slog.Error("Failed to create vsock log connection", "error", err)
		os.Exit(1)
	}
	defer stdoutConn.Close()

	// Reconfigure logger to write to vsock instead of stderr
	// This ensures init's slog messages appear in the combined log
	if err := configureLoggerWithOutput(config, stdoutConn); err != nil {
		panic(fmt.Sprintf("could not reconfigure logger to vsock: %s", err))
	}

	apiListener, err := vsock.NewVsockListener(uint32(config.VsockAPIPort))
	if err != nil {
		slog.Error("Failed to create vsock listener", "error", err)
		os.Exit(1)
	}

	// / Create the kill signal channel and pass it to the HTTP handler
	killChan := make(chan syscall.Signal, 1)

	handleSystemSignals(killChan)

	api := NewAPI(uint32(config.VsockStdoutPort), killChan)
	server := &http.Server{
		Handler:      api.Handler(),
		ReadTimeout:  5 * time.Second,
		WriteTimeout: 10 * time.Second,
		IdleTimeout:  120 * time.Second,
	}

	// Start HTTP server in a goroutine and wait for shutdown signal
	go func() {
		slog.Debug("Serving Init API on vsock", "port", config.VsockAPIPort)

		if err := server.Serve(apiListener); err != nil && err != http.ErrServerClosed {
			slog.Error("HTTP server failed", "error", err)
			os.Exit(1)
		}

	}()
	// Create and set up supervisor
	supervisor := process.NewSupervisor(exitClient)

	// Create and add primary process
	primary := primary.New(config.Process, config.Env, config.ID)
	supervisor.Add(primary, stdoutConn)
	supervisor.SetPrimary(primary)

	// Create and add SSH server
	sshServer, err := ssh.NewServer(config)
	if err != nil {
		slog.Error("Failed to create SSH server", "error", err)
		os.Exit(1)
	}
	supervisor.Add(sshServer, stdoutConn)

	// Run supervisor
	slog.Debug("Starting supervisor.Run()")
	if err := supervisor.Run(ctx, killChan); err != nil {
		slog.Error("Supervisor error", "error", err)
		os.Exit(1)
	}
	slog.Info("Supervisor.Run() completed successfully")

	// Shutdown API server
	slog.Info("Shutting down API server")
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	if err := server.Shutdown(shutdownCtx); err != nil {
		slog.Error("Error shutting down API server", "error", err)
	}
	slog.Info("API server shutdown complete")

	slog.Info("init exiting")
}

func setHostname(hostname string) error {
	err := syscall.Sethostname([]byte(hostname))
	if err != nil {
		return fmt.Errorf("failed to set hostname: %w", err)
	}
	return nil
}

// ExitStatus represents the structure to log exit status
type ExitStatus struct {
	ExitCode  int    `json:"exit_code"`
	OOMKilled bool   `json:"oom_killed"`
	Message   string `json:"message"`
	Signal    *int   `json:"signal,omitempty"`
}

// signal handling function to gracefully handle OS/system kill signals
func handleSystemSignals(killChan chan syscall.Signal) {
	sigChan := make(chan os.Signal, 1)

	signal.Notify(sigChan, syscall.SIGTERM, syscall.SIGINT)

	go func() {
		for sig := range sigChan {
			slog.Debug("Received system signal", "signal", sig)

			killChan <- syscall.Signal(sig.(syscall.Signal))
		}
	}()
}

func configureLogger(c *image.Config) error {
	return configureLoggerWithOutput(c, os.Stderr)
}

func configureLoggerWithOutput(c *image.Config, output io.Writer) error {
	if c.Log.Debug {
		LogLevel.Set(slog.LevelDebug)
	}

	opts := slog.HandlerOptions{
		Level: &LogLevel,
		ReplaceAttr: func(groups []string, a slog.Attr) slog.Attr {
			// Standardize field names to match our LogEntry format
			if a.Key == slog.TimeKey {
				if !c.Log.Timestamp {
					return slog.Attr{} // Remove timestamp if disabled
				}
				a.Key = "timestamp"
			}
			if a.Key == slog.MessageKey {
				a.Key = "message"
			}
			return a
		},
	}

	// Always use JSON handler with source="init" and vm_id attributes
	handler := slog.NewJSONHandler(output, &opts).WithAttrs([]slog.Attr{
		slog.String("source", "init"),
		slog.String("vm_id", c.ID),
	})

	slog.SetDefault(slog.New(handler))
	return nil
}

func switchRoot() error {
	if err := os.Chdir("/rootfs"); err != nil {
		return fmt.Errorf("failed to change directory to /rootfs: %w", err)
	}
	if err := syscall.Mount(".", "/", "", syscall.MS_MOVE, ""); err != nil {
		return fmt.Errorf("failed to mount new root: %w", err)
	}
	if err := syscall.Chroot("."); err != nil {
		return fmt.Errorf("failed to chroot: %w", err)
	}
	if err := os.Chdir("/"); err != nil {
		return fmt.Errorf("failed to change directory to new root: %w", err)
	}
	return nil
}
