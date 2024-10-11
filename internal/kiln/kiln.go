package kiln

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"sync"

	"github.com/rugwirobaker/inferno/internal/command"
	"github.com/rugwirobaker/inferno/internal/flag"
	"github.com/spf13/cobra"
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
	if err := cmd.Run(); err != nil {
		slog.Error("Failed to run Firecracker", "error", err)
		return err
	}

	slog.Info("Firecracker execution complete", "vmID", vmID)
	return nil
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
