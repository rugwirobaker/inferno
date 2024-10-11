package kiln

import (
	"context"
	"encoding/json"
	"fmt"
	"os"

	"github.com/rugwirobaker/inferno/internal/flag"
)

// Resources defines the CPU and Memory limits for the VM.
type Resources struct {
	CPUCount int    `json:"cpu_count"`
	MemoryMB int    `json:"memory_mb"`
	CPUKind  string `json:"cpu_kind"`
}

// KilnConfig defines the full configuration for the Kiln jailer.
type Config struct {
	JailID        string `json:"jail_id"`
	ChrootPath    string `json:"chroot"`
	ChrootBaseDir string `json:"chroot_base_dir"`

	Log                     Log
	UID                     int       `json:"uid"`
	GID                     int       `json:"gid"`
	NetNS                   bool      `json:"netns"`
	FirecrackerSocketPath   string    `json:"firecracker_socket_path"`
	FirecrackerConfigPath   string    `json:"firecracker_config_path"`
	FirecrackerVsockUDSPath string    `json:"firecracker_vsock_uds_path"`
	Resources               Resources `json:"resources"`
}

type Log struct {
	Format    string  `yaml:"format"`    // "text", "json"
	Timestamp bool    `yaml:"timestamp"` // show timestamp
	Debug     bool    `yaml:"debug"`     // include debug logging
	Path      *string `yaml:"path"`      // log file path
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
	file, err := os.Create(path)
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
	if chroot := flag.GetString(ctx, "chroot"); chroot != "" {
		cfg.ChrootPath = chroot
	}
	if chrootBaseDir := flag.GetString(ctx, "chroot-base-dir"); chrootBaseDir != "" {
		cfg.ChrootBaseDir = chrootBaseDir
	}
	if uid := flag.GetInt(ctx, "uid"); uid != 0 {
		cfg.UID = uid
	}
	if gid := flag.GetInt(ctx, "gid"); gid != 0 {
		cfg.GID = gid
	}
	if netns := flag.GetBool(ctx, "netns"); netns {
		cfg.NetNS = netns
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
