package vsock

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"os"

	"github.com/mdlayher/vsock"
)

const (
	// VsockStdoutPort is port is used by the guest to send stdout/stderr to the host
	VsockStdoutPort int = iota + 10000
	// VsockExitPort is port used by the guest to send exit code(status) of the main process to the host
	VsockExitPort
	// VsockMetricsPort is port used by the host to request metrics from the guest
	VsockMetricsPort
	// VsockSignalPort is port used by the host to send a kill signal to the guest
	VsockSignalPort
)

func NewClient(ctx context.Context, port uint32) (*http.Client, error) {
	// Dial to the host server over vsock
	conn, err := vsock.Dial(2, port, nil) // Connect to host CID (2) and the specified port
	if err != nil {
		return nil, fmt.Errorf("failed to connect to host via vsock: %v", err)
	}

	// Create an HTTP client that uses the VSOCK connection
	client := &http.Client{
		Transport: &http.Transport{
			DialContext: func(_ context.Context, _, _ string) (net.Conn, error) {
				return conn, nil
			},
		},
	}
	return client, nil
}

// NewVsockListener creates a new vsock listener on the specified port.
// Its used by the guest to communicate with the host via /dev/vsock
func NewVsockListener(port uint32) (net.Listener, error) {
	// Listen on the specified port
	ls, err := vsock.Listen(port, nil)
	if err != nil {
		return nil, fmt.Errorf("failed to listen on vsock port %d: %v", port, err)
	}
	return ls, nil
}

// NewVsockUnixListener creates a new unix listener on the specified path.
// Firecracker takes of proxying the vsock connection to the unix socket
func NewVsockUnixListener(path string) (net.Listener, error) {
	// Remove any old socket file before creating a new one
	if err := os.RemoveAll(path); err != nil {
		return nil, fmt.Errorf("failed to remove old vsock path: %w", err)
	}

	listener, err := net.Listen("unix", path)
	if err != nil {
		return nil, fmt.Errorf("failed to start vsock listener: %w", err)
	}
	return listener, nil
}
