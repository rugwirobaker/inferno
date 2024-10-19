package kiln

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/rugwirobaker/inferno/internal/command"
	"github.com/rugwirobaker/inferno/internal/flag"
	"github.com/rugwirobaker/inferno/internal/pointer"
	"github.com/rugwirobaker/inferno/internal/vm"
	"github.com/rugwirobaker/inferno/internal/vsock"
	"github.com/spf13/cobra"
	"github.com/valyala/bytebufferpool"
)

// New sets up the kiln command structure
func New() *cobra.Command {
	const (
		longDesc  = "Supervises Firecracker VMs, and provides isolation and resource management(jailing)"
		shortDesc = "Supervise the Firecracker VMs"
	)

	cmd := command.New("kiln", shortDesc, longDesc, run)

	// Add flags using the correct Firecracker jailer options
	flag.Add(cmd,
		flag.String{
			Name:        "id",
			Description: "VM identifier (required)",
			Default:     "",
		},
		flag.String{
			Name:        "chroot",
			Description: "Chroot path for the jail (required)",
			Default:     "",
		},
		flag.Int{
			Name:        "uid",
			Description: "UID to run Firecracker as inside the jail",
			Default:     0,
		},
		flag.Int{
			Name:        "gid",
			Description: "GID to run Firecracker as inside the jail",
			Default:     0,
		},
		flag.Bool{
			Name:        "netns",
			Description: "Enable network namespace isolation",
			Default:     false,
		},
		flag.Int{
			Name:        "cpu",
			Description: "CPU limit in percentage (cgroups)",
			Default:     0,
		},
		flag.Int{
			Name:        "mem",
			Description: "Memory limit in MB (cgroups)",
			Default:     0,
		},
		flag.String{
			Name:        "chroot-base-dir",
			Description: " represents the base folder where chroot jails are built.",
		},
	)

	return cmd
}

var LogLevel struct {
	sync.Mutex
	slog.LevelVar
}

// run handles the main logic for the jailer command
func run(ctx context.Context) error {
	var chroot = "/" // we're in jail already

	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGTERM, syscall.SIGINT)

	config, err := configFromFile(filepath.Join(chroot, "kiln.json"))
	if err != nil {
		slog.Error("Failed to load kiln config", "error", err)
		return err
	}

	// Override config with flag values if provided
	config = configWithFlags(ctx, config)

	// Write the updated config back to kiln.json for debugging/tracing
	if err := WriteConfig(filepath.Join(chroot, "kiln.json"), config); err != nil {
		slog.Error("Failed to write updated kiln config", "error", err)
		return err
	}

	// Configure the logger
	if err := configureLogger(config); err != nil {
		slog.Error("Failed to configure logger", "error", err)
		return err
	}

	var vmID = config.JailID

	slog.Info("Running Firecracker", "vmID", vmID)

	// Prepare arguments for Firecracker execution
	args := []string{
		"--id", vmID,
		"--api-sock", filepath.Join(chroot, config.FirecrackerSocketPath),
		"--config-file", filepath.Join(chroot, config.FirecrackerConfigPath),
	}

	// Start Firecracker using exec.Command
	cmd := exec.Command("/firecracker", args...)
	cmd.Dir = chroot // Ensure we run Firecracker within the chroot directory

	// Set output to stdout/stderr for logging
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	// Run the Firecracker process
	if err := cmd.Start(); err != nil {
		slog.Error("Failed to run Firecracker", "error", err)
		return err
	}

	// some clean tasks to run at the end
	var finalizers []FinalizerFunc

	vsockExitPath := fmt.Sprintf("%s_%d", config.FirecrackerVsockUDSPath, config.VsockExitPort)
	exitListener, err := vsock.NewVsockUnixListener(vsockExitPath)
	if err != nil {
		slog.Error("Failed to start vsock listener", "error", err)
		return err
	}
	defer exitListener.Close()

	exitStatusChan := make(chan InitExitStatus)

	// Start the server that handles exit status requests
	go func() {
		slog.Info("Serving exit status on vsock")
		mux := http.NewServeMux()
		mux.HandleFunc("/exit", ExitStatusHandler(exitStatusChan))
		server := &http.Server{
			Handler:      mux,
			ReadTimeout:  5 * time.Second,
			WriteTimeout: 10 * time.Second,
			IdleTimeout:  120 * time.Second,
		}

		finalizers = append(finalizers, func() error {
			slog.Info("Stopping vsock server")
			ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
			defer cancel()
			return server.Shutdown(ctx)
		})

		if err := server.Serve(exitListener); err != nil && err != http.ErrServerClosed {
			slog.Error("Error serving exit status", "error", err)
		}
	}()

	vsockLogPath := fmt.Sprintf("%s_%d", config.FirecrackerVsockUDSPath, config.VsockStdoutPort)
	logListener, err := vsock.NewVsockUnixListener(vsockLogPath)
	if err != nil {
		slog.Error("Failed to start vsock listener", "error", err)
		return err
	}

	// Start the server that handles logs
	go func() {
		slog.Info("Serving logs on vsock")

		for {
			conn, err := logListener.Accept()
			slog.Debug("Accepted connection", "conn", conn)
			if err != nil {
				slog.Error("Failed to accept connection", "error", err)
				continue
			}

			// handle the connection(for this use the same pattern as net/http uses behind the scenes)
			go func() {
				defer conn.Close()

				ctx, cancel := context.WithCancel(ctx)
				defer cancel()

				factory := vm.SocketWriterFactory(ctx, *config.Log.Path)

				logger, err := vm.NewLogger(ctx, factory)
				if err != nil {
					slog.Error("Failed to create logger", "error", err)
					return
				}
				// add a finalizer to close the logger
				finalizers = append(finalizers, func() error {
					logger.Close()
					return nil
				})
				handleVMLogs(conn, logger)
			}()
		}
	}()

	// Wait for the Firecracker process to complete
	ps := cmd.Process
	waitErr := make(chan error)
	waitState := make(chan *os.ProcessState)
	go func() {
		state, err := ps.Wait()
		if err != nil {
			waitErr <- err
			return
		}
		waitState <- state
	}()

	kilnExitStatus := KilnExitStatus{}

	for {

		select {
		case sig := <-sigChan: // we received a signal
			slog.Info("Relaying signal to Firecracker", "signal", sig)
			if err := ps.Signal(sig); err != nil {
				slog.Error("Failed to stop Firecracker", "error", err)
			}
		case exitStatus := <-exitStatusChan: // the main process has exited
			slog.Info("Received exit status", "exitCode", exitStatus.ExitCode, "oomKilled", exitStatus.OOMKilled, "message", exitStatus.Message)

			kilnExitStatus.ExitCode = pointer.Int64(exitStatus.ExitCode)
			kilnExitStatus.OOMKilled = pointer.Bool(exitStatus.OOMKilled)
			kilnExitStatus.Error = pointer.String(exitStatus.Message)
			kilnExitStatus.Signal = pointer.Int64(int64(exitStatus.Signal))

		case err := <-waitErr: // firecracker process failed
			slog.Error("Firecracker execution failed", "error", err)
			kilnExitStatus.VMError = pointer.String(err.Error())
			return finalize(config, kilnExitStatus)

		case state := <-waitState: // firecracker process completed
			if !state.Success() {
				slog.Error("Firecracker execution failed", "exitCode", state.ExitCode())
				kilnExitStatus.VMExitCode = pointer.Int64(int64(state.ExitCode()))
				return finalize(config, kilnExitStatus, finalizers...)
			}
			slog.Info("Firecracker execution completed", "exitCode", state.ExitCode())
			kilnExitStatus.VMExitCode = pointer.Int64(int64(state.ExitCode()))

			return finalize(config, kilnExitStatus, finalizers...)
		}
	}
}

func handleVMLogs(src net.Conn, logger *vm.Logger) {
	defer src.Close()

	writeLine := func(line []byte) {
		lineStr := strings.TrimRight(string(line), " \t\r\n")
		if lineStr == "" {
			return
		}
		logger.Log(lineStr)
	}

	reader := bufio.NewReader(src)
	var buf *bytebufferpool.ByteBuffer
	for {
		line, isPrefix, err := reader.ReadLine()

		switch {
		case errors.Is(err, io.EOF):
			slog.Debug("done reading lines into chan")
			return
		case err != nil:
			slog.Warn("failed to read line", "error", err)
			time.Sleep(100 * time.Millisecond)
		case isPrefix:
			if buf == nil {
				buf = bytebufferpool.Get()
			}
			buf.B = append(buf.B, line...)
		case line == nil:
			// skip nil lines
		case buf == nil:
			// did not need to buffer, send as-is!
			writeLine(line)
		default:
			// insert the remaining bits of the line
			buf.B = append(buf.B, line...)
			// had to buffer, send the buffer's content
			writeLine(buf.B)
			bytebufferpool.Put(buf)
			buf.Reset()
		}
	}
}

func configureLogger(c *Config) error {
	opts := slog.HandlerOptions{Level: &LogLevel}

	if !c.Log.Timestamp {
		opts.ReplaceAttr = removeTime
	}

	var handler slog.Handler
	switch format := c.Log.Format; format {
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
