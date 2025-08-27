// internal/vm/vm.go
package vm

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"sync"

	"golang.org/x/sys/unix"
)

type State string

const (
	StateInitializing State = "initializing"
	StateRunning      State = "running"
	StateStopped      State = "stopped"
	StateFailed       State = "failed"
)

type Config struct {
	Chroot      string
	LogPathSock string
}

type VM struct {
	// Unique identifier for the VM
	ID string
	// Reference to the VM configuration
	Config *Config
	// vsockClient
	// vsockClient *http.Client

	Mutex sync.Mutex

	PID int
}

func New(id string, cfg *Config) *VM {
	return &VM{
		ID:     id,
		Config: cfg,
	}
}

func (vm *VM) Start(ctx context.Context) error {
	vm.Mutex.Lock()
	defer vm.Mutex.Unlock()

	if err := unix.Mkfifo(vm.Config.LogPathSock, 0o666); err != nil && !os.IsExist(err) {
		return fmt.Errorf("could not create kiln fifo: %w", err)
	}

	kilnConfigPath := filepath.Join(vm.Config.Chroot, "kiln.json")

	// create cmd
	cmd := exec.Command("kiln", "--config", kilnConfigPath)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	// detach the process
	cmd.SysProcAttr = &unix.SysProcAttr{
		Setpgid: true,
		Pgid:    0,
	}

	vm.setPID(cmd.Process.Pid)

	// start the process
	if err := cmd.Start(); err != nil {
		return err
	}

	go func() {
		// wait for the process to finish
		if err := cmd.Wait(); err != nil {
			slog.Error("kiln process failed", "error", err)
		}
	}()

	return nil
}

func (vm *VM) setPID(pid int) {
	vm.Mutex.Lock()
	defer vm.Mutex.Unlock()
	vm.PID = pid
}
