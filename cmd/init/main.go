package main

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"log"
	"log/slog"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"sync"
	"time"

	"syscall"

	"github.com/rugwirobaker/inferno/internal/image"
	"github.com/rugwirobaker/inferno/internal/linux"
	"github.com/rugwirobaker/inferno/internal/pointer"
	"github.com/rugwirobaker/inferno/internal/vsock"
)

const (
	paths = "PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin"
	port  = 10000
)

var LogLevel struct {
	sync.Mutex
	slog.LevelVar
}

// main starts an init process that can prepare an environment and start a shell
// after the Kernel has started.
func main() {
	fmt.Printf("inferno init started\n")

	ctx := context.Background()

	if err := linux.Mount("none", "/proc", "proc", 0); err != nil {
		log.Fatalf("error mounting /proc: %v", err)
	}
	if err := linux.Mount("none", "/dev/pts", "devpts", 0); err != nil {
		log.Fatalf("error mounting /dev/pts: %v", err)
	}
	if err := linux.Mount("none", "/dev/mqueue", "mqueue", 0); err != nil {
		log.Fatalf("error mounting /dev/mqueue: %v", err)
	}
	if err := linux.Mount("none", "/dev/shm", "tmpfs", 0); err != nil {
		log.Fatalf("error mounting /dev/shm: %v", err)
	}
	if err := linux.Mount("none", "/sys", "sysfs", 0); err != nil {
		log.Fatalf("error mounting /sys: %v", err)
	}
	if err := linux.Mount("none", "/sys/fs/cgroup", "cgroup", 0); err != nil {
		log.Fatalf("error mounting /sys/fs/cgroup: %v", err)
	}

	config, err := image.FromFile("/inferno/run.json")
	if err != nil {
		panic(fmt.Sprintf("could not read run.json, error: %s", err))
	}

	if err := configureLogger(config); err != nil {
		panic(fmt.Sprintf("could not configure logger, error: %s", err))
	}

	if err := setHostname(config.ID); err != nil {
		panic(err)
	}

	client, err := vsock.NewHostClient(ctx, uint32(config.VsockExitPort))
	if err != nil {
		slog.Error("Failed to create vsock client", "error", err)
		os.Exit(1)
	}

	// Open VSOCK connection for logging
	stdoutConn, err := vsock.NewVsockConn(uint32(config.VsockStdoutPort))
	if err != nil {
		slog.Error("Failed to create vsock log connection", "error", err)
		os.Exit(1)
	}
	defer stdoutConn.Close()

	listener, err := vsock.NewVsockListener(uint32(config.VsockSignalPort))
	if err != nil {
		slog.Error("Failed to create vsock listener", "error", err)
		os.Exit(1)
	}

	// / Create the kill signal channel and pass it to the HTTP handler
	killChan := make(chan syscall.Signal, 1)

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

	wg.Add(1) // Increment for stdout
	go streamLogs(stdout, stdoutConn, &wg)

	wg.Add(1) // Increment for stderr
	go streamLogs(stderr, stdoutConn, &wg)

	// Wait for all log streams to complete before exiting main
	wg.Wait()
	err = cmd.Start()
	if err != nil {
		panic(fmt.Sprintf("could not start %s, error: %s", config.Process.Cmd, err))
	}

	api := NewAPI(killChan)
	server := &http.Server{
		Handler:      api.Handler(),
		ReadTimeout:  5 * time.Second,
		WriteTimeout: 10 * time.Second,
		IdleTimeout:  120 * time.Second,
	}

	// Start HTTP server in a goroutine and wait for shutdown signal
	go func() {
		slog.Debug("Serving Init API on vsock", "port", port)

		if err := server.Serve(listener); err != nil && err != http.ErrServerClosed {
			slog.Error("HTTP server failed", "error", err)
			os.Exit(1)
		}
	}()

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

	// Wait for kill signals or child process exit in a loop
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
	if checkOOMKill(cmd.Process.Pid) {
		exit.OOMKilled = true
		exit.Message = "Process was killed by OOM killer"
	}

	if err := sendExitStatus(ctx, client, exit); err != nil {
		slog.Debug("Failed to send exit status", "error", err)
	}

	// Gracefully shut down the HTTP server
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := server.Shutdown(ctx); err != nil {
		slog.Error("HTTP server Shutdown failed", "error", err)
		os.Exit(1)
	}

	wg.Wait()

	slog.Info("HTTP server gracefully stopped")
}

func streamLogs(src io.ReadCloser, dst io.WriteCloser, wg *sync.WaitGroup) {
	defer wg.Done()
	defer src.Close()
	defer dst.Close()

	// Directly copy from pipe (stdout/stderr) to the VSOCK connection
	_, err := io.Copy(dst, src)
	if err != nil && err != io.EOF {
		slog.Error("Failed to copy logs to vsock", "error", err)
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
			log.Printf("Received system signal: %v\n", sig)
			killChan <- syscall.Signal(sig.(syscall.Signal))
		}
	}()
}

// Function to check if the process was killed by the OOM killer
func checkOOMKill(pid int) bool {
	file, err := os.Open("/dev/kmsg")
	if err != nil {
		log.Printf("error opening /dev/kmsg: %s", err)
		return false
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	matcher := fmt.Sprintf("Killed process %d", pid)

	for scanner.Scan() {
		if text := scanner.Text(); text != "" && time.Now().Before(time.Now().Add(1*time.Second)) {
			if contains := text; contains == matcher {
				return true
			}
		}
	}

	return false
}

func configureLogger(c *image.Config) error {
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
