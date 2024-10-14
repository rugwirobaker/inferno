package main

import (
	"github.com/rugwirobaker/inferno/internal/command"
	"github.com/spf13/cobra"
)

func NewRootCmd() *cobra.Command {
	const (
		long  = "Inferno is like docker but the daemon but firecracker microVMs"
		short = " inferno is a microVM runtime"
	)

	cmd := command.New("inferno", short, long, nil)

	cmd.PersistentPreRun = func(cmd *cobra.Command, args []string) {
		cmd.SilenceUsage = true
		cmd.SilenceErrors = true
	}

	cmd.AddCommand(
		NewRunCommand(),
		NewStopCommand(),
		NewServerCommand(),
		NewInitCommand(),
	)
	return cmd
}
