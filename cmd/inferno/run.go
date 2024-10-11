package main

import (
	"github.com/rugwirobaker/inferno/internal/command"
	"github.com/rugwirobaker/inferno/internal/flag"
	"github.com/spf13/cobra"
)

func NewRunCommand() *cobra.Command {
	const (
		long  = "Launches a microVM using the specified Docker image with optional CPU and memory configurations."
		short = "Launches a microVM"
	)

	cmd := command.New("run", short, long, nil)

	flag.Add(cmd,
		flag.String{
			Name:        "image",
			Shorthand:   "i",
			Description: "The Docker image to run",
		},
		flag.Int{
			Name:        "cpu",
			Shorthand:   "c",
			Description: "Number of CPUs to allocate to the microVM",
			Default:     1,
		},
		flag.Int{
			Name:        "mem",
			Shorthand:   "m",
			Description: "Memory (in MB) to allocate to the microVM",
			Default:     512,
		},
	)

	return cmd
}
