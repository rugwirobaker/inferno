package ssh

import (
	"log/slog"

	"github.com/charmbracelet/ssh"
	"github.com/charmbracelet/wish"
)

// WithAuthorizedKeys will block any SSH connections that aren't using a public key in the authorized key list.
// If authorizedKeys is empty, this middleware will be a no-op.
func WithAuthorizedKeys(authorizedKeys []ssh.PublicKey) func(next ssh.Handler) ssh.Handler {
	if len(authorizedKeys) == 0 {
		return func(next ssh.Handler) ssh.Handler {
			return next
		}
	}

	slog.Debug("using SSH allowlist", slog.Int("allowed_keys", len(authorizedKeys)))

	return func(next ssh.Handler) ssh.Handler {
		return func(sesh ssh.Session) {
			for _, key := range authorizedKeys {
				if ssh.KeysEqual(key, sesh.PublicKey()) {
					next(sesh)
					return
				}
			}

			wish.Println(sesh, "❌ Public key not authorized.")
			_ = sesh.Exit(1)
		}
	}
}
