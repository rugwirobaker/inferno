package main

import (
	"github.com/rugwirobaker/inferno/internal/command"
	"github.com/spf13/cobra"
)

func NewStopCommand() *cobra.Command {
	const (
		long  = "stops a microVM"
		short = "stops a microVM"
	)

	cmd := command.New("stop", short, long, nil)

	return cmd
}
