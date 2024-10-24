package image

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
)

type Config struct {
	ID      string            `json:"id"`
	Process Process           `json:"process"`
	Env     map[string]string `json:"env"`
	Log     Log               `json:"log"`

	VsockStdoutPort int `json:"vsock_stdout_port"` // send stdout/stderr to the host
	VsockExitPort   int `json:"vsock_exit_port"`   // send exit code to the host
	VsockAPIPort    int `json:"vsock_api_port"`    // serves a utility API in the guest init

}

type Log struct {
	Format    string `yaml:"format"`    // "text", "json"
	Timestamp bool   `yaml:"timestamp"` // show timestamp
	Debug     bool   `yaml:"debug"`     // include debug logging
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
