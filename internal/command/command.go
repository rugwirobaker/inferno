package command

import (
	"context"

	"github.com/spf13/cobra"
)

type Runner func(context.Context) error

func New(usage, short, long string, fn Runner) *cobra.Command {
	return &cobra.Command{
		Use:   usage,
		Short: short,
		Long:  long,
		RunE:  newRunE(fn),
	}
}

func newRunE(fn Runner) func(*cobra.Command, []string) error {
	if fn == nil {
		return nil
	}
	return func(cmd *cobra.Command, args []string) error {
		return fn(cmd.Context())
	}
}
