package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/signal"
	"runtime"
	"syscall"

	"github.com/AlecAivazis/survey/v2/terminal"
	"github.com/rugwirobaker/inferno/internal/iostreams"
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
