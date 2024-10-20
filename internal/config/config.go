package config

import (
	"context"
	"fmt"
	"io"
	"os"

	"gopkg.in/yaml.v3"

	"github.com/rugwirobaker/inferno/internal/flag"
)

type Config struct {
	StateBaseDir         string `yaml:"state_base_dir"`       // /var/lib/inferno
	ImageBaseDir         string `yaml:"image_base_dir"`       // /var/lib/inferno/images
	KernelPath           string `yaml:"kernel_path"`          // /var/lib/inferno/kernel
	FirecrackerBinPath   string `yaml:"firecracker_bin_path"` // /usr/local/bin/firecracker
	KilnBinPath          string `yaml:"kiln_bin_path"`        // /usr/local/bin/kiln
	InitPath             string `yaml:"init_path"`            // /var/lib/inferno/initrd.img
	VMLogsSocketPath     string `yaml:"vm_logs_socket_path"`  // /var/run/inferno_vm_logs.sock
	ServerSocketFilePath string `yaml:"server_socket_path"`   // /var/run/inferno.sock
	Log                  Log    `yaml:"log"`
}

type Log struct {
	Format    string  `yaml:"format"`         // "text", "json"
	Timestamp bool    `yaml:"timestamp"`      // show timestamp
	Debug     bool    `yaml:"debug"`          // include debug logging
	Path      *string `yaml:"path,omitempty"` // /var/log/inferno.log
}

func Default() *Config {
	return &Config{
		StateBaseDir:         "/var/lib/inferno",
		ImageBaseDir:         "/var/lib/inferno/images",
		KernelPath:           "/var/lib/inferno/kernel",
		FirecrackerBinPath:   "/usr/local/bin/firecracker",
		KilnBinPath:          "/usr/local/bin/kiln",
		InitPath:             "/var/lib/inferno/initrd.img",
		ServerSocketFilePath: "/var/run/inferno.sock",
		VMLogsSocketPath:     "/var/run/inferno_vm_logs.sock",
		Log: Log{
			Format:    "text",
			Timestamp: true,
			Debug:     false,
		},
	}
}

func (cfg *Config) Write(w io.Writer) error {
	encoder := yaml.NewEncoder(w)

	encoder.SetIndent(2)
	if err := encoder.Encode(cfg); err != nil {
		return fmt.Errorf("failed to encode config: %w", err)
	}
	return nil
}

func FromFile(path string) (*Config, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("failed to open config file: %w", err)
	}
	defer file.Close()

	var cfg = new(Config)

	decoder := yaml.NewDecoder(file)
	decoder.KnownFields(true)
	if err := decoder.Decode(cfg); err != nil {
		return nil, fmt.Errorf("failed to decode config file: %w", err)
	}
	return cfg, nil
}

func (cfg *Config) OverrideWithFlags(ctx context.Context) {
	if socketFile := flag.GetString(ctx, "socket-file"); socketFile != "" {
		cfg.ServerSocketFilePath = socketFile
	}
	if vmBaseDir := flag.GetString(ctx, "vm-base-dir"); vmBaseDir != "" {
		cfg.StateBaseDir = vmBaseDir
	}
	if imageBaseDir := flag.GetString(ctx, "image-base-dir"); imageBaseDir != "" {
		cfg.ImageBaseDir = imageBaseDir
	}
	if logFormat := flag.GetString(ctx, "log-format"); logFormat != "" {
		cfg.Log.Format = logFormat
	}
	if logTimestamp := flag.GetBool(ctx, "log-timestamp"); logTimestamp {
		cfg.Log.Timestamp = logTimestamp
	}
	if logBaseDir := flag.GetString(ctx, "log-path"); logBaseDir != "" {
		cfg.Log.Path = &logBaseDir
	}
}
