package main

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
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

		if err := Mount(vol.Device, vol.MountPoint, vol.FSType, flags, ""); err != nil {
			slog.Error("Failed to mount volume",
				"device", vol.Device,
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
	primary := primary.New(config.Process, config.Env)
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
	if err := supervisor.Run(ctx, killChan); err != nil {
		slog.Error("Supervisor error", "error", err)
		os.Exit(1)
	}

	// Shutdown API server
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	if err := server.Shutdown(shutdownCtx); err != nil {
		slog.Error("Error shutting down API server", "error", err)
	}

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
	if c.Log.Debug {
		LogLevel.Set(slog.LevelDebug)
	}

	opts := slog.HandlerOptions{Level: &LogLevel}

	if !c.Log.Timestamp {
		opts.ReplaceAttr = removeTime
	}

	var handler slog.Handler
	switch format := c.Log.Format; format {
	case "kernel":
		handler = NewKernelStyleHandler(os.Stderr, "init", opts)
	case "text":
		handler = slog.NewTextHandler(os.Stderr, &opts)
	case "json":
		handler = slog.NewJSONHandler(os.Stderr, &opts)
	default:
		return fmt.Errorf("invalid log format: %q", format)
	}

	slog.SetDefault(slog.New(handler))
	return nil
}

// removeTime removes the "time" field from slog.
func removeTime(groups []string, a slog.Attr) slog.Attr {
	if a.Key == slog.TimeKey {
		return slog.Attr{}
	}
	return a
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
