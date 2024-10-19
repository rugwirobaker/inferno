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
	Vsock   Vsock             `json:"vsock"`
	Log     Log               `json:"log"`
}

type Log struct {
	Format    string `yaml:"format"`    // "text", "json"
	Timestamp bool   `yaml:"timestamp"` // show timestamp
	Debug     bool   `yaml:"debug"`     // include debug logging
}

type Vsock struct {
	CID  uint32
	Path string
	Port uint32
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
