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
	"github.com/rugwirobaker/inferno/internal/iostreams"
	"github.com/rugwirobaker/inferno/internal/pointer"
	"github.com/rugwirobaker/inferno/internal/render"
	"github.com/rugwirobaker/inferno/internal/vm"
	"github.com/rugwirobaker/inferno/internal/vsock"
	"github.com/spf13/cobra"
	"github.com/valyala/bytebufferpool"
	"gopkg.in/natefinch/lumberjack.v2"
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

		flag.String{
			Name:        "init",
			Description: "Hijacks the command flow to generate a kiln.json file for testing",
		},

		flag.String{Name: "start-time-us", Description: "Firecracker start time (jailer passthrough)"},
		flag.String{Name: "start-time-cpu-us", Description: "Firecracker parent CPU start time (jailer passthrough)"},
		flag.String{Name: "parent-cpu-time-us", Description: "Firecracker parent CPU time us (jailer passthrough)"},
		flag.String{Name: "seccomp-level", Description: "Firecracker seccomp level (jailer passthrough)"},
		flag.String{Name: "api-sock", Description: "Firecracker API socket path (jailer passthrough)"},
	)

	return cmd
}

var LogLevel struct {
	sync.Mutex
	slog.LevelVar
}

// run handles the main logic for the jailer command
func run(ctx context.Context) error {
	if configPath := flag.GetString(ctx, "init"); configPath != "" {
		return initConfig(ctx, configPath)
	}
	// var chroot = "/" // we're in jail already

	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGTERM, syscall.SIGINT)

	config, err := configFromFile("./kiln.json")
	if err != nil {
		slog.Error("Failed to load kiln config", "error", err)
		return err
	}

	// Override config with flag values if provided
	config = configWithFlags(ctx, config)

	// Write the updated config back to kiln.json for debugging/tracing
	if err := WriteConfig("kiln.json", config); err != nil {
		slog.Error("Failed to write updated kiln config", "error", err)
		return err
	}

	// Configure the logger
	if err := configureLogger(config); err != nil {
		slog.Error("Failed to configure logger", "error", err)
		return err
	}

	// Write PID file for process management
	pid := os.Getpid()
	pidFile := "kiln.pid"
	if err := os.WriteFile(pidFile, []byte(fmt.Sprintf("%d\n", pid)), 0644); err != nil {
		slog.Warn("Failed to write PID file", "error", err)
		// Don't fail - this is not critical
	}

	var vmID = config.JailID

	slog.Info("Running Firecracker", "vmID", vmID)

	// Prepare arguments for Firecracker execution
	args := []string{
		"--id", vmID,
		"--api-sock", config.FirecrackerSocketPath,
		"--config-file", config.FirecrackerConfigPath,
		// "--level", "Debug",
	}

	if v := flag.GetString(ctx, "start-time-us"); v != "" {
		args = append(args, "--start-time-us", v)
	}
	if v := flag.GetString(ctx, "start-time-cpu-us"); v != "" {
		args = append(args, "--start-time-cpu-us", v)
	}
	if v := flag.GetString(ctx, "parent-cpu-time-us"); v != "" {
		args = append(args, "--parent-cpu-time-us", v)
	}
	if v := flag.GetString(ctx, "seccomp-level"); v != "" {
		args = append(args, "--seccomp-level", v)
	}

	slog.Debug("Firecracker arguments", "args", args)

	// Start Firecracker using exec.Command
	cmd := exec.Command("/firecracker", args...)
	// cmd.Dir = chroot // Ensure we run Firecracker within the chroot directory

	// Set output to stdout/stderr for logging
	stdoutReader, stdoutWriter := io.Pipe()
	stderrReader, stderrWriter := io.Pipe()

	cmd.Stdout = stdoutWriter
	cmd.Stderr = stderrWriter

	// Stream Firecracker stdout/stderr as JSON logs to inferno.log
	go streamFirecrackerLogs(stdoutReader, "stdout")
	go streamFirecrackerLogs(stderrReader, "stderr")

	// some clean tasks to run at the end
	var finalizers []FinalizerFunc

	// Clean up PID file on exit
	finalizers = append(finalizers, func() error {
		os.Remove(pidFile)
		return nil
	})

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

		ctx, cancel := context.WithCancel(ctx)
		defer cancel()

		// Create log file writer with rotation using lumberjack
		// Use MachineID for filename if available, otherwise fall back to JailID
		logFilename := config.MachineID
		if logFilename == "" {
			logFilename = config.JailID
		}
		vmLogFile := &lumberjack.Logger{
			Filename:   filepath.Join(config.LogDir, "vm", logFilename+".log"),
			MaxSize:    config.LogRotation.MaxSizeMB,
			MaxBackups: config.LogRotation.MaxFiles,
			MaxAge:     config.LogRotation.MaxAgeDays,
			Compress:   config.LogRotation.Compress,
		}

		// Create WriterFactory that returns the lumberjack logger
		factory := func(ctx context.Context) (io.WriteCloser, error) {
			return vmLogFile, nil
		}

		logSink, err := vm.NewLogSink(ctx, factory)
		if err != nil {
			slog.Error("Failed to create log sink", "error", err)
			return
		}
		// add a finalizer to close the log sink
		finalizers = append(finalizers, func() error {
			logSink.Close()
			return nil
		})

		for {
			conn, err := logListener.Accept()
			if err != nil {
				slog.Error("Failed to accept connection", "error", err)
				continue
			}
			slog.Debug("Accepted connection", "conn", conn)

			go func() {
				handleVMLogs(conn, logSink)
			}()
		}
	}()

	// Start the server that handles encryption key requests (port 10003)
	// Only start if volumes are configured (indicating encrypted volumes may be present)
	if len(config.Volumes) > 0 {
		vsockKeyPath := fmt.Sprintf("%s_%d", config.FirecrackerVsockUDSPath, vsock.VsockKeyPort)
		keyListener, err := vsock.NewVsockUnixListener(vsockKeyPath)
		if err != nil {
			slog.Error("Failed to start key vsock listener", "error", err)
			return err
		}
		defer keyListener.Close()

		go func() {
			slog.Info("Serving encryption keys on vsock", "port", vsock.VsockKeyPort)

			mux := http.NewServeMux()
			mux.HandleFunc("/v1/volume/key", KeyRequestHandler(config))
			server := &http.Server{
				Handler:      mux,
				ReadTimeout:  5 * time.Second,
				WriteTimeout: 10 * time.Second,
				IdleTimeout:  120 * time.Second,
			}

			finalizers = append(finalizers, func() error {
				slog.Info("Stopping key vsock server")
				ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
				defer cancel()
				return server.Shutdown(ctx)
			})

			if err := server.Serve(keyListener); err != nil && err != http.ErrServerClosed {
				slog.Error("Error serving encryption keys", "error", err)
			}
		}()
	}

	// Run the Firecracker process
	if err := cmd.Start(); err != nil {
		slog.Error("Failed to run Firecracker", "error", err)
		return err
	}

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
				slog.Error("Firecracker execution failed", "pid", state.Pid(), "exitCode", state.ExitCode())
				kilnExitStatus.VMExitCode = pointer.Int64(int64(state.ExitCode()))
				return finalize(config, kilnExitStatus, finalizers...)
			}
			slog.Info("Firecracker execution completed", "exitCode", state.ExitCode())
			kilnExitStatus.VMExitCode = pointer.Int64(int64(state.ExitCode()))

			return finalize(config, kilnExitStatus, finalizers...)
		}
	}
}

func handleVMLogs(src net.Conn, logSink *vm.LogSink) {
	defer src.Close()

	writeLine := func(line []byte) {
		lineStr := strings.TrimRight(string(line), " \t\r\n")
		if lineStr == "" {
			return
		}
		logSink.Log(lineStr)
	}

	reader := bufio.NewReader(src)
	var buf *bytebufferpool.ByteBuffer
	for {
		line, isPrefix, err := reader.ReadLine()                                    // Or use ReadString('\n') for simplicity
		slog.Debug("Attempting to read a line", "line", line, "isPrefix", isPrefix) // Log the raw line for verification

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

// streamFirecrackerLogs reads from a Firecracker stdout/stderr pipe and logs each line
// using slog with source="firecracker". Since slog is configured to write to inferno.log,
// this effectively sends Firecracker logs to the infrastructure log file.
func streamFirecrackerLogs(reader io.Reader, stream string) {
	scanner := bufio.NewScanner(reader)
	for scanner.Scan() {
		line := scanner.Text()
		if line == "" {
			continue
		}
		// Log with source="firecracker" and stream type
		// The slog handler is already configured with source="kiln" and vm_id,
		// but we want to override source for Firecracker logs
		slog.Info(line, "source", "firecracker", "stream", stream)
	}
	if err := scanner.Err(); err != nil {
		slog.Error("Error reading Firecracker output", "error", err, "stream", stream)
	}
}

func configureLogger(c *Config) error {
	if c.Log.Debug {
		LogLevel.Set(slog.LevelDebug)
	} else {
		LogLevel.Set(slog.LevelInfo)
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

	// Create infrastructure log file writer with rotation
	infraLogFile := &lumberjack.Logger{
		Filename:   filepath.Join(c.LogDir, "inferno.log"),
		MaxSize:    c.LogRotation.MaxSizeMB,
		MaxBackups: c.LogRotation.MaxFiles,
		MaxAge:     c.LogRotation.MaxAgeDays,
		Compress:   c.LogRotation.Compress,
	}

	// Always use JSON handler for infrastructure logs, with source and vm_id attributes
	handler := slog.NewJSONHandler(infraLogFile, &opts).WithAttrs([]slog.Attr{
		slog.String("source", "kiln"),
		slog.String("vm_id", c.JailID),
	})

	slog.SetDefault(slog.New(handler))
	return nil
}

func initConfig(ctx context.Context, configPath string) (err error) {
	var io = iostreams.FromContext(ctx)
	config := Default()

	if err = WriteConfig(configPath, config); err != nil {
		return
	}

	_ = render.JSON(io.Out, config)

	return
}
