package ssh

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"syscall"
	"unsafe"

	"github.com/charmbracelet/ssh"
	"github.com/creack/pty"
)

type SessionHandler struct {
	shell string
}

func NewSessionHandler(shell string) *SessionHandler {
	return &SessionHandler{shell}
}

func (h *SessionHandler) HandleFunc(_ ssh.Handler) ssh.Handler {

	return func(sesh ssh.Session) {
		userSesh := &UserSession{sesh}

		if userSesh.IsPTY() {
			h.Interactive(userSesh)
		} else if userSesh.IsCommand() {
			h.Command(userSesh)
		}
	}

}

// Interactive is a handler for interactive sessions
func (h *SessionHandler) Interactive(sesh *UserSession) {
	ptyReq, winCh, isPty := sesh.Pty()
	if !isPty {
		fmt.Fprintf(sesh, "no PTY requested\n")
		sesh.Exit(1)
		return
	}

	cmd := exec.Command(h.shell)
	cmd.Env = append(os.Environ(),
		fmt.Sprintf("TERM=%s", ptyReq.Term),
		fmt.Sprintf("HOME=%s", os.Getenv("HOME")),
		fmt.Sprintf("USER=%s", sesh.User()),
	)

	ptmx, err := pty.Start(cmd)
	if err != nil {
		fmt.Fprintf(sesh, "failed to start PTY: %v\n", err)
		sesh.Exit(1)
		return
	}
	defer ptmx.Close()

	// Handle window size changes
	go func() {
		for win := range winCh {
			setWinsize(ptmx, uint32(win.Width), uint32(win.Height))
		}
	}()

	// Copy stdin/stdout
	go func() {
		io.Copy(ptmx, sesh) // stdin
	}()
	io.Copy(sesh, ptmx) // stdout

	cmd.Wait()
}

// Command
func (h *SessionHandler) Command(sesh *UserSession) {
	cmd := exec.Command(h.shell, "-c", sesh.Command()[0])
	cmd.Env = append(os.Environ(),
		fmt.Sprintf("HOME=%s", os.Getenv("HOME")),
		fmt.Sprintf("USER=%s", sesh.User()),
	)

	// Set up I/O
	cmd.Stdout = sesh
	cmd.Stderr = sesh
	cmd.Stdin = sesh

	err := cmd.Run()
	if err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			sesh.Exit(exitErr.ExitCode())
		} else {
			fmt.Fprintf(sesh, "command failed: %v\n", err)
			sesh.Exit(1)
		}
		return
	}
	sesh.Exit(0)
}

// setWinsize sets the window size for a PTY
func setWinsize(f *os.File, w, h uint32) {
	syscall.Syscall(syscall.SYS_IOCTL, f.Fd(), syscall.TIOCSWINSZ,
		uintptr(unsafe.Pointer(&struct{ h, w, x, y uint16 }{
			h: uint16(h),
			w: uint16(w),
		})))
}
