// internal/process/process.go
package process

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"log/slog"
	"os/exec"
	"sync"
	"syscall"
)

// Process defines the interface for managed processes in the VM
type Process interface {
	Start(context.Context, io.WriteCloser) error
	Stop(context.Context) error
	Wait() error
	ExitCode() int
	PID() int
}

// ExitStatus represents detailed information about how a process ended
type ExitStatus struct {
	ExitCode  int    `json:"exit_code"`
	OOMKilled bool   `json:"oom_killed"`
	Message   string `json:"message"`
	Signal    *int   `json:"signal,omitempty"`
}

// Base provides common functionality for process management
type Base struct {
	Name      string
	Logger    *slog.Logger
	IsPrimary bool

	cmd  *exec.Cmd
	done chan error
	wg   sync.WaitGroup
}

func NewBaseProcess(name string, isPrimary bool) *Base {
	return &Base{
		Name:      name,
		IsPrimary: isPrimary,
		done:      make(chan error, 1),
	}
}

func (p *Base) SetupCommand(ctx context.Context, cmd string, args []string, env []string) error {
	p.cmd = exec.CommandContext(ctx, cmd, args...)
	p.cmd.Env = env
	return nil
}

func (p *Base) StartWithOutput(output io.WriteCloser) error {
	stdout, err := p.cmd.StdoutPipe()
	if err != nil {
		return fmt.Errorf("failed to create stdout pipe: %w", err)
	}

	stderr, err := p.cmd.StderrPipe()
	if err != nil {
		return fmt.Errorf("failed to create stderr pipe: %w", err)
	}

	if err := p.cmd.Start(); err != nil {
		return fmt.Errorf("failed to start process: %w", err)
	}

	// Start streaming logs
	p.wg.Add(2)
	go func() {
		p.streamLogs(stdout, output)
		p.wg.Done()
	}()
	go func() {
		p.streamLogs(stderr, output)
		p.wg.Done()
	}()

	// Monitor process
	go func() {
		err := p.cmd.Wait()
		p.wg.Wait() // Wait for log streaming to finish
		p.done <- err
	}()

	p.Logger.Info("Started process",
		"name", p.Name,
		"pid", p.cmd.Process.Pid,
		"primary", p.IsPrimary,
	)

	return nil
}

func (p *Base) streamLogs(src io.ReadCloser, dst io.WriteCloser) {
	defer src.Close()

	scanner := bufio.NewScanner(src)
	for scanner.Scan() {
		_, err := fmt.Fprintln(dst, scanner.Text())
		if err != nil {
			p.Logger.Error("Failed to write log line", "error", err)
			return
		}
	}

	if err := scanner.Err(); err != nil {
		p.Logger.Error("Error reading logs", "error", err)
	}
}

func (p *Base) Stop(ctx context.Context) error {
	if p.cmd == nil || p.cmd.Process == nil {
		return nil
	}

	// First try SIGTERM
	if err := p.cmd.Process.Signal(syscall.SIGTERM); err != nil {
		p.Logger.Warn("Failed to send SIGTERM to process", "error", err)
		return p.cmd.Process.Kill()
	}

	// Wait for process to exit or context to cancel
	select {
	case <-ctx.Done():
		p.Logger.Warn("Process didn't stop in time, forcing kill")
		return p.cmd.Process.Kill()
	case <-p.done:
		return nil
	}
}

func (p *Base) Wait() error {
	return <-p.done
}

func (p *Base) ExitCode() int {
	if p.cmd == nil || p.cmd.ProcessState == nil {
		return 0
	}
	return p.cmd.ProcessState.ExitCode()
}

func (p *Base) PID() int {
	if p.cmd == nil || p.cmd.Process == nil {
		return 0
	}
	return p.cmd.Process.Pid
}
