package flag

import (
	"context"
	"log/slog"

	"github.com/spf13/cobra"
)

func Adapt(
	fn func(ctx context.Context, cmd *cobra.Command, args []string, partial string) ([]string, error),
) func(*cobra.Command, []string, string) ([]string, cobra.ShellCompDirective) {
	return func(cmd *cobra.Command, args []string, partial string) (ideas []string, code cobra.ShellCompDirective) {

		var err error
		defer func() {
			if code == cobra.ShellCompDirectiveError {
				slog.Debug("completion error", "error", err)
			}
		}()
		ctx := cmd.Context()

		res, err := fn(ctx, cmd, args, partial)
		if err != nil {
			return nil, cobra.ShellCompDirectiveError
		} else {
			return res, cobra.ShellCompDirectiveNoFileComp
		}
	}
}
