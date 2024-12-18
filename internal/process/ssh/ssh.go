// internal/process/ssh.go
package ssh

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"log/slog"
	"os"

	"github.com/charmbracelet/ssh"
	"github.com/charmbracelet/wish"
	"github.com/rugwirobaker/inferno/internal/image"
	"github.com/rugwirobaker/inferno/internal/process"
)

const (
	sshHostKeyPath        = "/etc/inferno/ssh/host_key"
	sshAuthorizedKeysPath = "/etc/inferno/ssh/authorized_keys"
	sshPort               = 2222
)

type Server struct {
	*process.Base
	server *ssh.Server
	done   chan error
}

func NewServer(cfg *image.Config) (*Server, error) {
	authorizedKeys, err := GetAuthorizedKeys(sshAuthorizedKeysPath)
	if err != nil {
		return nil, err
	}
	sessionHandler := NewSessionHandler(cfg.User.Shell)

	sshServer, err := wish.NewServer(
		wish.WithAddress(fmt.Sprintf(":%d", sshPort)),
		wish.WithHostKeyPath(sshHostKeyPath),
		wish.WithPublicKeyAuth(func(_ ssh.Context, _ ssh.PublicKey) bool {
			return true
		}),
		wish.WithPasswordAuth(func(_ ssh.Context, _ string) bool {
			// accept pw auth so we can display a helpful message
			return true
		}),
		// note: middleware is evaluated in reverse order
		wish.WithMiddleware(
			sessionHandler.HandleFunc,
			WithAuthorizedKeys(authorizedKeys),
		),
	)
	if err != nil {
		return nil, err
	}

	return &Server{
		Base:   process.NewBaseProcess("ssh", false),
		server: sshServer,
		done:   make(chan error, 1),
	}, nil
}

func (s *Server) Start(ctx context.Context, output io.WriteCloser) error {
	// Start the SSH server in a goroutine
	go func() {
		s.Logger.Info("Starting SSH server", "port", sshPort)
		if err := s.server.ListenAndServe(); err != nil {
			s.Logger.Error("SSH server error", "error", err)
			s.done <- err
		}
	}()

	return nil
}

func (s *Server) Stop(ctx context.Context) error {
	slog.Info("Stopping SSH server")
	return s.server.Shutdown(ctx)
}

func (s *Server) Wait() error {
	return <-s.done
}

func (s *Server) ExitCode() int {
	select {
	case err := <-s.done:
		if err != nil {
			return 1
		}
	default:
	}
	return 0
}

func GetAuthorizedKeys(path string) ([]ssh.PublicKey, error) {
	authorizedKeys := make([]ssh.PublicKey, 0)

	if path == "" {
		return authorizedKeys, nil
	}

	authorizedKeysFile, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("unable to read authorized keys file: %w", err)
	}

	for i, keyBites := range bytes.Split(authorizedKeysFile, []byte("\n")) {
		if len(bytes.TrimSpace(keyBites)) == 0 {
			continue
		}

		out, _, _, _, err := ssh.ParseAuthorizedKey(keyBites)
		if err != nil {
			slog.Warn("unable to parse authorized key", slog.Int("line", i), slog.Any("error", err))
			continue
		}

		authorizedKeys = append(authorizedKeys, out)
	}

	return authorizedKeys, nil
}
