package main

import (
	"context"
	"fmt"
	"os"

	"github.com/rugwirobaker/inferno/internal/command"
	"github.com/rugwirobaker/inferno/internal/config"
	"github.com/rugwirobaker/inferno/internal/flag"
	"github.com/spf13/cobra"
)

func NewInitCommand() *cobra.Command {
	const (
		long  = "Creates a default inferno server configuration file at the specified path"
		short = "Creates configuration file"
	)

	cmd := command.New("run", short, long, runInit)

	flag.Add(cmd,
		flag.String{
			Name:        "path",
			Shorthand:   "p",
			Description: "The path to write the configuration file",
			Default:     "inferno.yaml",
		},
	)
	return cmd
}

func runInit(ctx context.Context) (err error) {
	var path = flag.GetString(ctx, "path")

	cfg := config.Default()

	file, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return fmt.Errorf("could not create configuration file: %w", err)
	}
	defer file.Close()

	if err := cfg.Write(file); err != nil {
		return fmt.Errorf("could not write configuration file: %w", err)
	}
	return
}
