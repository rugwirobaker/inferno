package main

import (
	"context"
	"fmt"
	"log/slog"
	"net"
	"os"

	"github.com/rugwirobaker/inferno/internal/command"
	"github.com/rugwirobaker/inferno/internal/config"
	"github.com/rugwirobaker/inferno/internal/flag"
	"github.com/rugwirobaker/inferno/internal/image"
	"github.com/rugwirobaker/inferno/internal/server"
	"github.com/spf13/cobra"
)

const defaultConfigFile = "/etc/inferno/inferno.conf"

func NewServerCommand() *cobra.Command {
	const (
		longDesc  = "Inferno is a microVM runtime"
		shortDesc = "Starts the Inferno server"
	)
	cmd := command.New("server", shortDesc, longDesc, runDaemon)

	flag.Add(cmd,
		flag.String{
			Name:        "config",
			Description: "Path to the configuration file",
			Default:     defaultConfigFile,
		},
		flag.String{
			Name:        "socket-file",
			Description: "Path to the socket file",
		},
		flag.String{
			Name:        "vm-base-dir",
			Description: "Base directory for VM state",
		},
		flag.String{
			Name:        "image-base-dir",
			Description: "Base directory for image cache",
		},
		flag.String{
			Name:        "log-base-dir",
			Description: "Base directory for logs",
		},
	)

	return cmd
}

func runDaemon(ctx context.Context) error {
	configFile := flag.GetString(ctx, "config")

	// Load configuration from file
	cfg, err := config.FromFile(configFile)
	if err != nil {
		return fmt.Errorf("failed to load configuration: %w", err)
	}

	// Override configuration with command-line flags
	cfg.OverrideWithFlags(ctx)

	if err := configureLogger(cfg); err != nil {
		slog.Error("Failed to configure logger", "error", err)
		return err
	}

	// Ensure necessary directories exist
	if err := ensureDirectories(cfg); err != nil {
		return fmt.Errorf("failed to ensure directories: %w", err)
	}

	// Ensure necessary files exist
	if err := ensureFilesExist(cfg); err != nil {
		return fmt.Errorf("failed to ensure files: %w", err)
	}

	// Remove existing socket file if it exists
	if _, err := os.Stat(cfg.SocketFilePath); err == nil {
		os.Remove(cfg.SocketFilePath)
	}

	// Start the Unix socket listener
	listener, err := net.Listen("unix", cfg.SocketFilePath)
	if err != nil {
		return fmt.Errorf("failed to listen on socket: %w", err)
	}

	images, err := image.NewManager()
	if err != nil {
		return fmt.Errorf("failed to create image manager: %w", err)
	}

	// Pass the configuration to the server
	srv := server.New(listener, cfg, images)

	return srv.Run()
}

func ensureDirectories(cfg *config.Config) error {
	dirs := []string{
		cfg.StateBaseDir,
		cfg.ImageBaseDir,
		// Add other directories as needed
	}
	for _, dir := range dirs {
		if err := os.MkdirAll(dir, 0755); err != nil {
			return fmt.Errorf("failed to create directory %s: %w", dir, err)
		}
	}
	return nil
}

func ensureFilesExist(cfg *config.Config) error {
	files := []string{
		cfg.FirecrackerBinPath,
		cfg.KilnBinPath,
		cfg.InitPath,
		cfg.KernelPath,
	}
	for _, file := range files {
		if _, err := os.Stat(file); err != nil {
			if os.IsNotExist(err) {
				return fmt.Errorf("required file %s does not exist", file)
			}
			return fmt.Errorf("error checking file %s: %w", file, err)
		}
	}
	return nil
}

func configureLogger(c *config.Config) error {
	opts := slog.HandlerOptions{Level: &server.LogLevel}

	if !c.Log.Timestamp {
		opts.ReplaceAttr = removeTime
	}

	var handler slog.Handler
	switch format := c.Log.Format; format {
	case "text":
		handler = slog.NewTextHandler(os.Stderr, &opts)
	case "json":
		handler = slog.NewJSONHandler(os.Stderr, &opts)
	default:
		return fmt.Errorf("invalid log format: %q", format)
	}

	slog.SetDefault(slog.New(handler))
	return nil
}

// removeTime removes the "time" field from slog.
func removeTime(groups []string, a slog.Attr) slog.Attr {
	if a.Key == slog.TimeKey {
		return slog.Attr{}
	}
	return a
}
