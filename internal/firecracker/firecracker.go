package firecracker

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

const (
	DefaultJailerUID = 123
	DefaultJailerGID = 100
)

// Config represents the full Firecracker configuration.
type Config struct {
	BootSource        BootSource          `json:"boot-source"`
	Drives            []Drive             `json:"drives"`
	MachineConfig     MachineConfig       `json:"machine-config"`
	NetworkInterfaces []NetworkInterface  `json:"network-interfaces,omitempty"` // Optional
	VsockDevices      []VsockDevice       `json:"vsock,omitempty"`              // Optional
	Logger            *Logger             `json:"logger,omitempty"`             // Optional
	Metrics           *FirecrackerMetrics `json:"metrics,omitempty"`            // Optional
	Entropy           *string             `json:"entropy,omitempty"`            // Optional
}

// NewConfig creates a default Firecracker configuration for a VM.
func NewConfig(vmDir string, vcpuCount, memSizeMib int) *Config {
	return &Config{
		BootSource: BootSource{
			KernelImagePath: "vmlinux",
			BootArgs:        "console=ttyS0 reboot=k panic=1 pci=off",
		},
		Drives: []Drive{
			{
				DriveID:      "rootfs",
				IsRootDevice: true,
				PathOnHost:   filepath.Join(vmDir, "rootfs.ext4"),
				CacheType:    "Unsafe",
				IsReadOnly:   false,
				IOEngine:     "Sync",
			},
		},
		MachineConfig: MachineConfig{
			VCPUCount:       vcpuCount,
			MemSizeMib:      memSizeMib,
			SMT:             false,
			TrackDirtyPages: false,
			HugePages:       false,
		},
	}
}

// BootSource represents the boot source configuration.
type BootSource struct {
	KernelImagePath string  `json:"kernel_image_path"`
	BootArgs        string  `json:"boot_args"`
	InitrdPath      *string `json:"initrd_path,omitempty"` // Optional field
}

// Drive represents a drive configuration.
type Drive struct {
	DriveID      string  `json:"drive_id"`
	IsRootDevice bool    `json:"is_root_device"`
	PathOnHost   string  `json:"path_on_host"`
	CacheType    string  `json:"cache_type"`
	IsReadOnly   bool    `json:"is_read_only"`
	IOEngine     string  `json:"io_engine"`
	RateLimiter  *string `json:"rate_limiter,omitempty"` // Optional field
	Socket       *string `json:"socket,omitempty"`       // Optional field
	PartUUID     *string `json:"partuuid,omitempty"`     // Optional field
}

// MachineConfig represents the VM machine configuration.
type MachineConfig struct {
	VCPUCount       int  `json:"vcpu_count"`
	MemSizeMib      int  `json:"mem_size_mib"`
	SMT             bool `json:"smt"`
	TrackDirtyPages bool `json:"track_dirty_pages"`
	HugePages       bool `json:"huge_pages"`
}

// NetworkInterface represents a network interface configuration.
type NetworkInterface struct {
	IfaceName string `json:"if_name"`
	HostDev   string `json:"host_dev"`
	Mac       string `json:"mac,omitempty"`
}

// VsockDevice represents a Virtio vsock device configuration.
type VsockDevice struct {
	VsockID  string `json:"vsock_id"`
	GuestCID uint32 `json:"guest_cid"`
	UDSPath  string `json:"uds_path"`
}

// Logger represents the logger configuration.
type Logger struct {
	LogPath  string `json:"log_path"`
	LogLevel string `json:"level"`
}

// FirecrackerMetrics represents the metrics configuration.
type FirecrackerMetrics struct {
	MetricsPath string `json:"metrics_path"`
}

// WriteConfig writes the Firecracker configuration to a file.
func WriteConfig(path string, config *Config) error {
	file, err := os.Create(path)
	if err != nil {
		return fmt.Errorf("failed to create firecracker config file: %w", err)
	}
	defer file.Close()

	encoder := json.NewEncoder(file)
	encoder.SetIndent("", "  ") // Pretty-print the JSON
	if err := encoder.Encode(config); err != nil {
		return fmt.Errorf("failed to encode firecracker config: %w", err)
	}
	return nil
}

// ReadConfig reads the Firecracker configuration from a file.
func ReadConfig(path string) (*Config, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("failed to open firecracker config file: %w", err)
	}
	defer file.Close()

	var cfg Config
	if err := json.NewDecoder(file).Decode(&cfg); err != nil {
		return nil, fmt.Errorf("failed to decode firecracker config: %w", err)
	}

	return &cfg, nil
}

func DefaultBootArgs() []string {
	return []string{"console=ttyS0", "reboot=k", "panic=1", "pci=off"}
}

// func DefaultBootArgs() []string {
// 	return []string{
// 		"console=ttyS0",
// 		// "8250.nr_uarts=0",
// 		"nomodules",
// 		"reboot=k",
// 		"panic=1",
// 		"pci=off",
// 		"cgroup_enable=memory",
// 		"swapaccount=1",
// 		"random.trust_cpu=on",
// 		"i8042.noaux",
// 		"i8042.nomux",
// 		"i8042.nopnp",
// 		"i8042.dumbkbd",
// 		"acpi=off",
// 		"lapic=notscdeadline", // needed for suspend/resume until Firecracker v1.8
// 		"quiet",
// 		// "LOG_FILTER=init=debug,fly_init=debug,hyper=debug,warp=debug",
// 	}
// }
