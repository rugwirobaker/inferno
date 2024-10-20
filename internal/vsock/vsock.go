package vsock

import (
	"bufio"
	"context"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"time"

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

// NewGuestClient creates a new http client that connects that the host uses to connect to the guest
// it will mainly be used to call the unit control API
func NewGuestClient(chroot string, port int) *http.Client {
	vsockPath := filepath.Join(chroot, "control.sock")

	return &http.Client{
		Timeout: 5 * time.Second,
		Transport: &maxBytesTransport{
			Transport: &http.Transport{
				DisableKeepAlives: true,
				DialContext: func(_ context.Context, _, _ string) (net.Conn, error) {
					conn, err := net.DialTimeout("unix", vsockPath, 1*time.Second)
					if err != nil {
						return nil, fmt.Errorf("could not dial %s: %w", vsockPath, err)
					}

					n, err := conn.Write([]byte(fmt.Sprintf("CONNECT %d\n", port)))
					if err != nil {
						return nil, fmt.Errorf("could not write vsock CONNECT %d line: %w", port, err)
					}
					slog.Debug("wrote", "bytes", n)

					r := bufio.NewReader(conn)

					// read one line (OK 123456789)
					slog.Debug("reading OK line from vsock")
					l, _, err := r.ReadLine()
					if err != nil {
						return nil, fmt.Errorf("could not read OK line from vsock: %w", err)
					}

					slog.Debug("connection established", "read", string(l))

					return conn, nil
				},
			},
		},
	}
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

type maxBytesTransport struct {
	Transport   http.RoundTripper
	MaxBodySize int64
}

func (t *maxBytesTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	resp, err := t.Transport.RoundTrip(req)
	if err != nil {
		return nil, err
	}

	// Limit the response body to the specified maximum size
	resp.Body = http.MaxBytesReader(nil, resp.Body, t.MaxBodySize)

	return resp, nil
}
