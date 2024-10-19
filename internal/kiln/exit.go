package kiln

import (
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
)

// KilnExitStatus stores the exit status of the kiln process
// At the end of the kiln process, we write to exit_status.json
type KilnExitStatus struct {
	// from the VM
	VMExitCode *int64  `json:"vm_exit_code"`
	VMError    *string `json:"vm_error,omitempty"`
	VMSignal   *int64  `json:"vm_signal,omitempty"`

	// from the guest main process
	ExitCode  *int64  `json:"exit_code,omitempty"`
	Signal    *int64  `json:"signal,omitempty"`
	Error     *string `json:"error,omitempty"`
	OOMKilled *bool   `json:"oom_killed,omitempty"`
}

type FinalizerFunc func() error

// finalize cleans up the kiln process and writes the exit status to exit_status.json
func finalize(config *Config, exitStatus KilnExitStatus, finalizers ...FinalizerFunc) (err error) {
	for _, f := range finalizers {
		if err := f(); err != nil {
			slog.Error("Failed to run finalizer", "error", err)
		}
	}
	if err := writeExitStatus(config.ExitStatusPath, exitStatus); err != nil {
		slog.Error("Failed to write exit status", "error", err)
		return err
	}

	return nil
}

func writeExitStatus(path string, exitStatus KilnExitStatus) (err error) {
	file, err := os.CreateTemp(".", "exit_status.json")
	if err != nil {
		return fmt.Errorf("failed to create exit status file: %w", err)
	}
	defer file.Close()
	if err := json.NewEncoder(file).Encode(exitStatus); err != nil {
		return fmt.Errorf("could not encode exit status file, %w", err)
	}
	if err := file.Chmod(0644); err != nil {
		return fmt.Errorf("could chmod exit status file, %w", err)
	}

	dir, err := os.Getwd()
	if err != nil {
		return fmt.Errorf("could not get current working directory, %w", err)
	}

	path = filepath.Join(dir, path)
	if err := os.Rename(file.Name(), path); err != nil {
		return fmt.Errorf("could not rename exit status file, %w", err)
	}

	slog.Info("Exit status written to file", "filePath", path)

	return
}
