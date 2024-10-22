package command

import (
	"context"

	"github.com/rugwirobaker/inferno/internal/flag"
	"github.com/rugwirobaker/inferno/internal/iostreams"
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
		ctx := cmd.Context()
		ctx = NewContext(ctx, cmd)
		ctx = flag.NewContext(ctx, cmd.Flags())

		io := iostreams.System()
		ctx = iostreams.NewContext(ctx, io)

		return fn(ctx)
	}
}

type contextKey struct{}

func NewContext(ctx context.Context, cmd *cobra.Command) context.Context {
	return context.WithValue(ctx, contextKey{}, cmd)
}

func FromContext(ctx context.Context) *cobra.Command {
	return ctx.Value(contextKey{}).(*cobra.Command)
}
