package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
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
)

const paths = "PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin"

var LogLevel struct {
	sync.Mutex
	slog.LevelVar
}

// main starts an init process that can prepare an environment and start a shell
// after the Kernel has started.
func main() {
	fmt.Printf("inferno init started\n")

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

	if err := setHostname(config.ID); err != nil {
		panic(err)
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
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	err = cmd.Start()
	if err != nil {
		panic(fmt.Sprintf("could not start %s, error: %s", config.Process.Cmd, err))
	}

	// Setup HTTP server with timeouts and graceful shutdown
	server := &http.Server{
		Addr:         ":8080",
		Handler:      KillHandler(killChan),
		ReadTimeout:  5 * time.Second,
		WriteTimeout: 10 * time.Second,
		IdleTimeout:  120 * time.Second,
	}

	// Start HTTP server in a goroutine and wait for shutdown signal
	go func() {
		log.Println("Starting HTTP server on :8080")
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("HTTP server failed: %v", err)
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
	var exitStatus ExitStatus

	// Wait for kill signals or child process exit in a loop
	select {
	case signal := <-killChan:
		log.Printf("Received kill signal: %d, sending to child process (PID: %d)", signal, cmd.Process.Pid)
		syscall.Kill(cmd.Process.Pid, syscall.Signal(signal))
		err := cmd.Wait() // Wait for child to exit after receiving the signal
		if err != nil {
			exitStatus = ExitStatus{
				ExitCode:  -1,
				OOMKilled: false,
				Message:   fmt.Sprintf("Process terminated with signal %d", signal),
			}
		}

	case err := <-childExited:
		switch {
		case err != nil:
			exitStatus = ExitStatus{
				ExitCode:  -1,
				OOMKilled: false,
				Message:   fmt.Sprintf("Main process exited with error: %v", err),
			}
		default:
			exitStatus = ExitStatus{
				ExitCode:  0,
				OOMKilled: false,
				Message:   "Main process exited normally",
			}

		}
	}

	// OOM killer detection
	if checkOOMKill(cmd.Process.Pid) {
		exitStatus.OOMKilled = true
		exitStatus.Message = "Process was killed by OOM killer"
	}

	// Gracefully shut down the HTTP server
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := server.Shutdown(ctx); err != nil {
		log.Fatalf("HTTP server Shutdown failed: %v", err)
	}
	log.Println("HTTP server gracefully stopped")

	// Write exit status to file(TODO: send via vsock)
	writeExitStatus(exitStatus)
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
}

// signal handling function to gracefully handle OS/system kill signals
func handleSystemSignals(killChan chan syscall.Signal) {
	sigChan := make(chan os.Signal, 1)

	signal.Notify(sigChan, syscall.SIGTERM, syscall.SIGKILL)

	go func() {
		for sig := range sigChan {
			log.Printf("Received system signal: %v\n", sig)
			killChan <- syscall.Signal(sig.(syscall.Signal))
		}
	}()
}

// Function to write the exit status
func writeExitStatus(exitStatus ExitStatus) {
	file, err := os.Create("/inferno/exit_status.json") // You can modify the path as needed
	if err != nil {
		log.Printf("Error creating exit status file: %v", err)
		return
	}
	defer file.Close()

	encoder := json.NewEncoder(file)
	if err := encoder.Encode(exitStatus); err != nil {
		log.Printf("Error writing exit status: %v", err)
	}
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
