package image

import (
	"context"
	"fmt"

	"github.com/docker/docker/client"
)

type Manager struct {
	docker *client.Client
}

func NewManager() (*Manager, error) {
	docker, err := client.NewClientWithOpts(client.FromEnv)
	if err != nil {
		return nil, fmt.Errorf("failed to create docker client: %w", err)
	}

	return &Manager{
		docker: docker,
	}, nil
}

func (m *Manager) CreateConfig(ctx context.Context, imageName string) (*Config, error) {
	imgInspect, _, err := m.docker.ImageInspectWithRaw(ctx, imageName)
	if err != nil {
		return nil, fmt.Errorf("failed to inspect image: %w", err)
	}

	var cmd string
	var args []string

	if len(imgInspect.Config.Cmd) > 0 {
		cmd = imgInspect.Config.Cmd[0]
		if len(imgInspect.Config.Cmd) > 1 {
			args = imgInspect.Config.Cmd[1:]
		}
	} else {
		return nil, fmt.Errorf("image has no CMD defined")
	}

	return &Config{
		ID: imgInspect.ID,
		Process: Process{
			Cmd:  cmd,
			Args: args,
		},
	}, nil
}

func (m *Manager) ExtractRootFS(ctx context.Context, imageName, path string) error {
	return nil
}
