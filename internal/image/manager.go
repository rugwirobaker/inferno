package image

import (
	"context"
	"fmt"
	"io"
	"os"

	"github.com/docker/docker/api/types/container"
	"github.com/docker/docker/api/types/image"
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

func (m *Manager) CreateRootFS(ctx context.Context, imageName, path string) (err error) {
	if err := m.FetchImage(ctx, imageName); err != nil {
		return err
	}

	// Create a container from the image
	containerConfig := &container.Config{
		Image: imageName,
		Cmd:   []string{"/bin/sh"}, // Minimal command
	}
	resp, err := m.docker.ContainerCreate(ctx, containerConfig, nil, nil, nil, "")
	if err != nil {
		return fmt.Errorf("failed to create container from image '%s': %w", imageName, err)
	}
	containerID := resp.ID
	defer func() {
		// Clean up: remove the container
		_ = m.docker.ContainerRemove(ctx, containerID, container.RemoveOptions{Force: true})
	}()

	// Export the container's filesystem
	reader, err := m.docker.ContainerExport(ctx, containerID)
	if err != nil {
		return fmt.Errorf("failed to export container '%s': %w", containerID, err)
	}
	defer reader.Close()

	// Create the destination file
	destFile, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return fmt.Errorf("failed to create rootfs file '%s': %w", path, err)
	}
	defer destFile.Close()

	// Write the exported tar to the destination
	_, err = io.Copy(destFile, reader)
	if err != nil {
		return fmt.Errorf("failed to write rootfs to '%s': %w", path, err)
	}

	fmt.Printf("Root filesystem exported to '%s'.\n", path)

	return nil
}

func (m *Manager) FetchImage(ctx context.Context, imageName string) (err error) {
	_, _, err = m.docker.ImageInspectWithRaw(ctx, imageName)
	if err == nil {
		fmt.Printf("Image '%s' is already present locally.\n", imageName)
		return
	}
	if !client.IsErrNotFound(err) {
		return fmt.Errorf("failed to inspect image '%s': %w", imageName, err)
	}
	fmt.Printf("Pulling image '%s'...\n", imageName)
	reader, err := m.docker.ImagePull(ctx, imageName, image.PullOptions{})
	if err != nil {
		return fmt.Errorf("failed to pull image '%s': %w", imageName, err)
	}
	defer reader.Close()

	// Consume the output to ensure pull completes
	_, err = io.Copy(os.Stdout, reader)
	if err != nil {
		return fmt.Errorf("error during image pull: %w", err)
	}

	fmt.Printf("Successfully pulled image '%s'.\n", imageName)
	return
}
