package image

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net"
	"os"
)

type Config struct {
	ID      string            `json:"id"`
	Process Process           `json:"process"`
	Env     map[string]string `json:"env"`
	IPs     []IPConfig        `json:"ips"`
	Log     Log               `json:"log"`
	Mounts  Mounts            `json:"mounts"`
	User    *UserConfig       `json:"user,omitempty"`
	Files   []File            `json:"files,omitempty"`

	EtcResolv EtcResolv `json:"etc_resolv"`
	EtcHost   []EtcHost `json:"etc_hosts,omitempty"`

	VsockStdoutPort int `json:"vsock_stdout_port"` // send stdout/stderr to the host
	VsockExitPort   int `json:"vsock_exit_port"`   // send exit code to the host
	VsockAPIPort    int `json:"vsock_api_port"`    // serves a utility API in the guest init

}

func (c *Config) Marshal() ([]byte, error) {
	w := new(bytes.Buffer)

	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")

	if err := enc.Encode(c); err != nil {
		return nil, fmt.Errorf("failed to marshal run config: %w", err)
	}
	return w.Bytes(), nil
}

type IPConfig struct {
	IP      net.IP `json:"ip"`
	Gateway net.IP `json:"gateway"`
	Mask    int    `json:"mask"`
}

type EtcResolv struct {
	Nameservers []string `json:"nameservers"`
}

type EtcHost struct {
	Host string
	IP   string
	Desc string
}

type Log struct {
	Format    string `json:"format"`    // "text", "json"
	Timestamp bool   `json:"timestamp"` // show timestamp
	Debug     bool   `json:"debug"`     // include debug logging
}

type Process struct {
	Cmd  string
	Args []string
}

type Mounts struct {
	Root    Volume   `json:"root"`    // The root filesystem
	Volumes []Volume `json:"volumes"` // Additional volumes
}

type Volume struct {
	Device     string   `json:"device"`      // e.g. /dev/vda
	MountPoint string   `json:"mount_point"` // e.g. / for root, /data for others
	FSType     string   `json:"fs_type"`     // e.g. ext4
	Options    []string `json:"options,omitempty"`
}

type File struct {
	Path    string      `json:"path"`
	Mode    os.FileMode `json:"mode"`
	Content string      `json:"content"`
}

func (m *Mounts) Validate() error {
	if m.Root.Device == "" {
		return fmt.Errorf("root device cannot be empty")
	}
	if m.Root.MountPoint != "/" {
		return fmt.Errorf("root mount point must be /")
	}
	if m.Root.FSType == "" {
		return fmt.Errorf("root filesystem type cannot be empty")
	}
	return nil
}

type UserConfig struct {
	Name   string   `json:"name"`
	Group  string   `json:"group"`
	Create bool     `json:"create"`
	UID    *int     `json:"uid,omitempty"`
	GID    *int     `json:"gid,omitempty"`
	Home   string   `json:"home,omitempty"`
	Shell  string   `json:"shell,omitempty"`
	Groups []string `json:"groups,omitempty"`
}

func (u *UserConfig) WithDefaults() *UserConfig {
	if u.Name == "" {
		u.Name = "root"
	}
	if u.Group == "" {
		u.Group = u.Name
	}
	if u.Home == "" {
		if u.Name == "root" {
			u.Home = "/root"
		} else {
			u.Home = "/home/" + u.Name
		}
	}
	if u.Shell == "" {
		u.Shell = "/bin/sh"
	}
	return u
}

type SSHConfig struct {
	HostKeyPath string `json:"host_key_path"`
}

func FromFile(path string) (*Config, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("failed to open run config: %w", err)
	}
	defer file.Close()

	var cfg = new(Config)
	if err := json.NewDecoder(file).Decode(cfg); err != nil {
		return nil, fmt.Errorf("failed to decode run config: %w", err)
	}
	return cfg, nil
}
