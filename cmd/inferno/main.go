package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"runtime"
	"syscall"

	"github.com/AlecAivazis/survey/v2/terminal"
	"github.com/rugwirobaker/inferno/internal/config"
	"github.com/rugwirobaker/inferno/internal/iostreams"
	"github.com/rugwirobaker/inferno/internal/server"
)

func main() {
	signals := []os.Signal{os.Interrupt}
	if runtime.GOOS != "windows" {
		signals = append(signals, syscall.SIGTERM)
	}

	ctx, cancel := signal.NotifyContext(context.Background(), signals...)
	defer cancel()

	// handle the case where the user interrupts the command with ctrl+c
	go func() {
		<-ctx.Done()
		fmt.Fprintln(os.Stderr, "Received interrupt signal, exiting...")
		os.Exit(1)
	}()

	exit := Run(ctx, iostreams.System(), os.Args[1:]...)

	os.Exit(exit)
}

func Run(ctx context.Context, io *iostreams.IOStreams, args ...string) int {
	ctx = iostreams.NewContext(ctx, io)

	cmd := NewRootCmd()
	cmd.SetOut(io.Out)
	cmd.SetErr(io.ErrOut)

	cmd.SetArgs(args)
	cmd.SilenceErrors = true

	cmd, err := cmd.ExecuteContextC(ctx)
	switch {
	case err == nil:
		return 0
	case errors.Is(err, context.Canceled), errors.Is(err, terminal.InterruptErr):
		return 127
	case errors.Is(err, context.DeadlineExceeded):
		printError(io, err)
		return 126
	default:
		printError(io, err)

		_, _, e := cmd.Find(args)
		if e != nil {
			fmt.Printf("Run '%v --help' for usage.\n", cmd.CommandPath())
			fmt.Println()
		}
		return 1
	}
}

func printError(io *iostreams.IOStreams, err error) {
	fmt.Fprintf(io.ErrOut, "Error: %v\n", err)
	fmt.Fprintln(io.ErrOut)
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
