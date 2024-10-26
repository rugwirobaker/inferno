package main

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"sync"
	"time"

	"syscall"

	"github.com/rugwirobaker/inferno/internal/image"
	"github.com/rugwirobaker/inferno/internal/pointer"
	"github.com/rugwirobaker/inferno/internal/vsock"
)

const paths = "PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin"

var LogLevel struct {
	sync.Mutex
	slog.LevelVar
}

// main starts an init process that can prepare an environment and start a shell
// after the Kernel has started.
func main() {
	ctx := context.Background()

	config, err := image.FromFile("/inferno/run.json")
	if err != nil {
		panic(fmt.Sprintf("could not read run.json, error: %s", err))
	}

	if err := configureLogger(config); err != nil {
		panic(fmt.Sprintf("could not configure logger, error: %s", err))
	}

	slog.Info("inferno init started")

	slog.With("config", config).Debug("loaded config")

	if err := syscall.Mount("devtmpfs", "/dev", "devtmpfs", syscall.MS_NOSUID, "mode=0755"); err != nil {
		slog.Error("Failed to mount devtmpfs to /dev", "error", err)
		os.Exit(1)
	}
	// mount root device at /rootfs
	if err := os.MkdirAll("/rootfs", 0755); err != nil {
		slog.Error("Failed to create /rootfs", "error", err)
		os.Exit(1)
	}
	if err := syscall.Mount("/dev/vda", "/rootfs", "ext4", syscall.MS_RELATIME, ""); err != nil {
		slog.Error("Failed to mount /dev/vda to /rootfs", "error", err)
		os.Exit(1)
	}

	if err := os.MkdirAll("/rootfs/dev", 0755); err != nil {
		slog.Error("Failed to create /rootfs/dev", "error", err)
		os.Exit(1)
	}
	if err := syscall.Mount("/dev", "/rootfs/dev", "", syscall.MS_MOVE, ""); err != nil {
		slog.Error("Failed to mount /dev to /rootfs/dev", "error", err)
		os.Exit(1)
	}

	// change root to /rootfs
	if err := os.Chdir("/rootfs"); err != nil {
		slog.Error("Failed to change directory to /rootfs", "error", err)
		os.Exit(1)
	}
	if err := syscall.Mount(".", "/", "", syscall.MS_MOVE, ""); err != nil {
		slog.Error("Failed to mount new root over /", "error", err)
		os.Exit(1)
	}
	if err := syscall.Chroot("."); err != nil {
		slog.Error("Failed to chroot to the new root", "error", err)
		os.Exit(1)
	}
	if err := os.Chdir("/"); err != nil {
		slog.Error("Failed to change directory to new /", "error", err)
		os.Exit(1)
	}

	// finally mount other filesystems
	if err := mountFS(); err != nil {
		slog.Error("Failed to mount filesystems", "error", err)
	}

	if err := setHostname(config.ID); err != nil {
		slog.Error("Failed to set hostname", "error", err)
	}

	client, err := vsock.NewHostClient(ctx, uint32(config.VsockExitPort))
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

	// Start the main process in the VM
	cmd := exec.Command(config.Process.Cmd, config.Process.Args...)
	cmd.Env = append(cmd.Env, paths)

	// Add environment variables
	for k, v := range config.Env {
		cmd.Env = append(cmd.Env, fmt.Sprintf("%s=%s", k, v))
	}

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		slog.Error("Failed to capture stderr", "error", err)
		os.Exit(1)
	}

	stderr, err := cmd.StderrPipe()
	if err != nil {
		slog.Error("Failed to capture stderr", "error", err)
		os.Exit(1)
	}

	var wg sync.WaitGroup // Create a WaitGroup
	wg.Add(1)
	go func() {
		slog.Debug("streaming stdout")

		defer wg.Done()
		streamLogs(stdout, stdoutConn)
	}()

	wg.Add(1)
	go func() {
		slog.Debug("streaming stderr")

		defer wg.Done()
		streamLogs(stderr, stdoutConn)
	}()

	err = cmd.Start()
	if err != nil {
		panic(fmt.Sprintf("could not start main process: %s", err))
	}

	// Handle OS/system signals
	handleSystemSignals(killChan)

	// Monitor child process for exit or errors in a separate goroutine
	childExited := make(chan error)
	go func() {
		err := cmd.Wait()
		childExited <- err
	}()

	// Initialize exit status
	var exit ExitStatus

	slog.Debug("Waiting for kill signal or child process exit")

	select {
	case signal := <-killChan:
		slog.Debug("Received kill signal", "signal", signal, "pid", cmd.Process.Pid)
		_ = syscall.Kill(cmd.Process.Pid, syscall.Signal(signal))

		// Wait for child to exit after receiving the signal
		if err := cmd.Wait(); err != nil {
			exit = ExitStatus{
				ExitCode:  -1,
				OOMKilled: false,
				Signal:    pointer.Int(int(signal)),
				Message:   fmt.Sprintf("Process terminated with signal %d", signal),
			}
		}

	case err := <-childExited:
		switch {
		case err != nil:
			exit = ExitStatus{
				ExitCode:  -1,
				OOMKilled: false,
				Message:   fmt.Sprintf("Main process exited with error: %v", err),
			}
		default:
			exit = ExitStatus{
				ExitCode:  0,
				OOMKilled: false,
				Message:   "Main process exited normally",
			}

		}
	}

	// OOM killer detection
	oom, err := checkOOMKill(cmd.Process.Pid)
	if err != nil {
		slog.Error("Failed to check OOM kill", "error", err)
	}

	if oom {
		exit.OOMKilled = true
		exit.Message = "Main process was killed by the OOM killer"
	}

	if err := sendExitStatus(ctx, client, exit); err != nil {
		slog.Debug("Failed to send exit status", "error", err)
	}

	// Gracefully shut down the HTTP server
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	if err := server.Shutdown(ctx); err != nil {
		slog.Error("HTTP server Shutdown failed", "error", err)
		os.Exit(1)
	}

	wg.Wait()

	slog.Info("init exiting")
}

func streamLogs(src io.ReadCloser, dst io.WriteCloser) {
	defer src.Close()
	defer dst.Close()

	scanner := bufio.NewScanner(src)
	for scanner.Scan() {
		_, err := fmt.Fprintln(dst, scanner.Text())
		if err != nil {
			slog.Error("Failed to write log line to vsock", "error", err)
			return
		}
	}
	if err := scanner.Err(); err != nil {
		slog.Error("Error reading logs", "error", err)
	}
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

// Function to check if the process was killed by the OOM killer
func checkOOMKill(pid int) (bool, error) {
	file, err := os.Open("/dev/kmsg")
	if err != nil {
		return false, fmt.Errorf("failed to open /dev/kmsg: %w", err)
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	matcher := fmt.Sprintf("Killed process %d", pid)

	for scanner.Scan() {
		if text := scanner.Text(); text != "" && time.Now().Before(time.Now().Add(1*time.Second)) {
			if contains := text; contains == matcher {
				return true, nil
			}
		}
	}
	return false, nil
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
