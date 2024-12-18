package process

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"syscall"
	"time"

	"github.com/rugwirobaker/inferno/internal/pointer"
)

type ProcessEntry struct {
	process Process
	output  io.WriteCloser
}

type Supervisor struct {
	processes []ProcessEntry
	primary   Process // Reference to primary process for exit status
	client    http.Client
}

func NewSupervisor(client *http.Client) *Supervisor {
	return &Supervisor{
		client: *client,
	}
}

func (s *Supervisor) Add(p Process, output io.WriteCloser) {
	s.processes = append(s.processes, ProcessEntry{
		process: p,
		output:  output,
	})
}

func (s *Supervisor) SetPrimary(p Process) {
	s.primary = p
}

func (s *Supervisor) Start(ctx context.Context) error {
	for _, entry := range s.processes {
		if err := entry.process.Start(ctx, entry.output); err != nil {
			return fmt.Errorf("failed to start process: %w", err)
		}
	}
	return nil
}

func (s *Supervisor) Run(ctx context.Context, killChan chan syscall.Signal) error {
	if s.primary == nil {
		return fmt.Errorf("no primary process registered")
	}

	// Start all processes
	if err := s.Start(ctx); err != nil {
		return err
	}

	// Monitor primary process exit
	primaryExit := make(chan error, 1)
	go func() {
		primaryExit <- s.primary.Wait()
	}()

	var exit ExitStatus

	// Wait for either a kill signal or primary process exit
	select {
	case signal := <-killChan:
		slog.Debug("Received kill signal", "signal", signal)
		exit = s.handleSignal(ctx, signal)

	case err := <-primaryExit:
		exit = s.handleExit(err)
	}

	// Send exit status before shutting down other processes
	if err := s.sendExitStatus(ctx, exit); err != nil {
		slog.Error("Failed to send exit status", "error", err)
	}

	// Shutdown other processes sequentially
	s.shutdownProcesses(ctx)

	return nil
}

func (s *Supervisor) handleSignal(ctx context.Context, signal syscall.Signal) ExitStatus {
	// Signal the primary process and wait for it to exit
	if err := s.primary.Stop(ctx); err != nil {
		slog.Error("Failed to stop primary process", "error", err)
	}

	if err := s.primary.Wait(); err != nil {
		return ExitStatus{
			ExitCode:  -1,
			OOMKilled: false,
			Signal:    pointer.Int(int(signal)),
			Message:   fmt.Sprintf("Process terminated with signal %d", signal),
		}
	}

	return ExitStatus{
		ExitCode: s.primary.ExitCode(),
		Signal:   pointer.Int(int(signal)),
		Message:  fmt.Sprintf("Process stopped by signal %d", signal),
	}
}

func (s *Supervisor) handleExit(err error) ExitStatus {
	var exit ExitStatus

	if err != nil {
		exit = ExitStatus{
			ExitCode:  -1,
			OOMKilled: false,
			Message:   fmt.Sprintf("Primary process exited with error: %v", err),
		}
	} else {
		exit = ExitStatus{
			ExitCode:  0,
			OOMKilled: false,
			Message:   "Primary process exited normally",
		}
	}

	pid := s.primary.PID()
	if pid > 0 {
		if oom, err := checkOOMKill(pid); err != nil {
			slog.Error("Failed to check OOM kill", "error", err)
		} else if oom {
			exit.OOMKilled = true
			exit.Message = "Primary process was killed by the OOM killer"
		}
	}
	return exit
}

func (s *Supervisor) shutdownProcesses(ctx context.Context) {
	for i := len(s.processes) - 1; i >= 0; i-- {
		entry := s.processes[i]
		if entry.process == s.primary {
			continue // Skip primary, it's already stopped
		}

		slog.Debug("Shutting down process", "index", i)
		shutdownCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
		if err := entry.process.Stop(shutdownCtx); err != nil {
			slog.Error("Failed to stop process", "index", i, "error", err)
		}
		cancel()
	}
}

func (s *Supervisor) sendExitStatus(ctx context.Context, status ExitStatus) error {
	body, err := json.Marshal(status)
	if err != nil {
		return fmt.Errorf("failed to encode exit status: %v", err)
	}

	// Create HTTP POST request
	req, err := http.NewRequestWithContext(ctx, "POST", "/exit", bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("failed to create HTTP request: %v", err)
	}
	req.Header.Set("Content-Type", "application/json")

	// Send the request
	resp, err := s.client.Do(req)
	if err != nil {
		return fmt.Errorf("failed to send exit status: %v", err)
	}
	defer resp.Body.Close()

	// Check response
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("failed to send exit status, server responded with: %s", resp.Status)
	}
	return nil
}

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
