// forked from https://github.com/cli/cli/tree/trunk/pkg/iostreams

package iostreams

import (
	"io"
	"os"
)

type IOStreams struct {
	In     io.ReadCloser
	Out    io.Writer
	ErrOut io.Writer
}

func NewStream(stdin io.ReadCloser, stdout, stderr io.Writer) *IOStreams {
	return &IOStreams{
		In:     stdin,
		Out:    stdout,
		ErrOut: stderr,
	}
}
func System() *IOStreams {
	return NewStream(os.Stdin, os.Stdout, os.Stderr)
}
