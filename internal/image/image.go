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

	EtcResolv EtcResolv `json:"etc_resolv"`
	EtcHost   []EtcHost `json:"etc_hosts,omitempty"`

	VsockStdoutPort int `json:"vsock_stdout_port"` // send stdout/stderr to the host
	VsockExitPort   int `json:"vsock_exit_port"`   // send exit code to the host
	VsockAPIPort    int `json:"vsock_api_port"`    // serves a utility API in the guest init

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

func (c *Config) Marshal() ([]byte, error) {
	w := new(bytes.Buffer)

	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")

	if err := enc.Encode(c); err != nil {
		return nil, fmt.Errorf("failed to marshal run config: %w", err)
	}
	return w.Bytes(), nil
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
