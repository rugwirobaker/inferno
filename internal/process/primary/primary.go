// internal/process/primary.go
package primary

import (
	"context"
	"fmt"
	"io"

	"github.com/rugwirobaker/inferno/internal/image"
	"github.com/rugwirobaker/inferno/internal/process"
)

type Primary struct {
	*process.Base
	config image.Process
	env    map[string]string
}

func New(config image.Process, env map[string]string) *Primary {
	return &Primary{
		Base:   process.NewBaseProcess("primary", true),
		config: config,
		env:    env,
	}
}

func (p *Primary) Start(ctx context.Context, output io.WriteCloser) error {
	// Convert env map to slice
	var envSlice []string
	for k, v := range p.env {
		envSlice = append(envSlice, fmt.Sprintf("%s=%s", k, v))
	}

	if err := p.SetupCommand(ctx, p.config.Cmd, p.config.Args, envSlice); err != nil {
		return err
	}

	return p.StartWithOutput(output)
}
