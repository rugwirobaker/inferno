package ssh

import "github.com/charmbracelet/ssh"

const (
	FingerprintContextKey = "fingerprint"
	UserIDContextKey      = "user_id"
)

type UserSession struct {
	ssh.Session
}

func (sesh *UserSession) UserID() string {
	return sesh.Context().Value(UserIDContextKey).(string)
}

func (sesh *UserSession) PublicKeyFingerprint() string {
	return sesh.Context().Value(FingerprintContextKey).(string)
}

func (sesh *UserSession) IsPTY() bool {
	_, _, isPty := sesh.Pty()
	return isPty
}

func (sesh *UserSession) IsCommand() bool {
	return len(sesh.Command()) > 0
}
