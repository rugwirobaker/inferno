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

func New(config image.Process, env map[string]string, vmID string) *Primary {
	return &Primary{
		Base:   process.NewBaseProcess("primary", true, vmID),
		config: config,
		env:    env,
	}
}

func (p *Primary) Start(ctx context.Context, output io.WriteCloser) error {
	var env []string
	for k, v := range p.env {
		env = append(env, fmt.Sprintf("%s=%s", k, v))
	}

	if err := p.SetupCommand(ctx, p.config.Cmd, p.config.Args, env); err != nil {
		return err
	}

	return p.StartWithOutput(output)
}
