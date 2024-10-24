package kiln

import (
	"context"
	"encoding/json"
	"fmt"
	"os"

	"github.com/rugwirobaker/inferno/internal/firecracker"
	"github.com/rugwirobaker/inferno/internal/flag"
	"github.com/rugwirobaker/inferno/internal/vsock"
)

// Resources defines the CPU and Memory limits for the VM.
type Resources struct {
	CPUCount int    `json:"cpu_count"`
	MemoryMB int    `json:"memory_mb"`
	CPUKind  string `json:"cpu_kind"`
}

// Config defines the full configuration for the Kiln jailer.
type Config struct {
	JailID string `json:"jail_id"`

	UID int `json:"uid"`
	GID int `json:"gid"`
	Log Log `json:"log"`

	FirecrackerSocketPath   string `json:"firecracker_socket_path"`
	FirecrackerConfigPath   string `json:"firecracker_config_path"`
	FirecrackerVsockUDSPath string `json:"firecracker_vsock_uds_path"`

	VsockStdoutPort int `json:"vsock_stdout_port"` // receive stdout/stderr send over by the init
	VsockExitPort   int `json:"vsock_exit_port"`   // receive exit code info from the init

	VMLogsSocketPath string `json:"vm_logs_socket_path"`
	ExitStatusPath   string `json:"exit_status_path"`

	Resources Resources `json:"resources"`
}

type Log struct {
	Format    string  `json:"format"`         // "text", "json"
	Timestamp bool    `json:"timestamp"`      // show timestamp
	Debug     bool    `json:"debug"`          // include debug logging
	Path      *string `json:"path,omitempty"` // log file path
}

func Default() *Config {
	return &Config{
		JailID: "kiln",
		UID:    firecracker.DefaultJailerGID,
		GID:    firecracker.DefaultJailerGID,
		Resources: Resources{
			CPUCount: 1,
			MemoryMB: 128,
			CPUKind:  "C3",
		},
		FirecrackerSocketPath:   "firecracker.sock",
		FirecrackerConfigPath:   "firecracker.json",
		FirecrackerVsockUDSPath: "firecracker.sock",

		VsockStdoutPort: vsock.VsockStdoutPort,
		VsockExitPort:   vsock.VsockExitPort,

		VMLogsSocketPath: "vm_logs.sock",
		ExitStatusPath:   "exit_status.json",

		Log: Log{
			Format:    "text",
			Timestamp: true,
			Debug:     false,
		},
	}
}

func configFromFile(path string) (*Config, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("failed to open kiln config: %w", err)
	}
	defer file.Close()

	var cfg = new(Config)
	if err := json.NewDecoder(file).Decode(cfg); err != nil {
		return nil, fmt.Errorf("failed to decode kiln config: %w", err)
	}
	return cfg, nil
}

func WriteConfig(path string, cfg *Config) error {
	file, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0644)
	if err != nil {
		return fmt.Errorf("failed to create kiln config: %w", err)
	}
	defer file.Close()

	encoder := json.NewEncoder(file)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(cfg); err != nil {
		return fmt.Errorf("failed to encode kiln config: %w", err)
	}
	return nil
}

func configWithFlags(ctx context.Context, cfg *Config) *Config {
	if flagID := flag.GetString(ctx, "id"); flagID != "" {
		cfg.JailID = flagID
	}
	if uid := flag.GetInt(ctx, "uid"); uid != 0 {
		cfg.UID = uid
	}
	if gid := flag.GetInt(ctx, "gid"); gid != 0 {
		cfg.GID = gid
	}
	if cpu := flag.GetInt(ctx, "cpu"); cpu != 0 {
		cfg.Resources.CPUCount = cpu
	}
	if mem := flag.GetInt(ctx, "mem"); mem != 0 {
		cfg.Resources.MemoryMB = mem
	}
	if firecrackerAPI := flag.GetString(ctx, "firecracker-api"); firecrackerAPI != "" {
		cfg.FirecrackerSocketPath = firecrackerAPI
	}
	if firecrackerCfg := flag.GetString(ctx, "firecracker-config"); firecrackerCfg != "" {
		cfg.FirecrackerConfigPath = firecrackerCfg
	}
	return cfg
}
