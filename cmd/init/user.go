package main

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strconv"

	"github.com/rugwirobaker/inferno/internal/image"
	"golang.org/x/sys/unix"
)

type UserManager struct {
	config *image.UserConfig
}

func NewUserManager(config *image.UserConfig) *UserManager {
	return &UserManager{
		config: config.WithDefaults(),
	}
}

func (m *UserManager) Setup() error {
	// First ensure group exists
	group, err := m.ensureGroup()
	if err != nil {
		return fmt.Errorf("group setup failed: %w", err)
	}

	// Then ensure user exists
	usr, err := m.ensureUser(group)
	if err != nil {
		return fmt.Errorf("user setup failed: %w", err)
	}

	// Setup additional groups if specified
	if err := m.setupAdditionalGroups(usr); err != nil {
		return fmt.Errorf("additional groups setup failed: %w", err)
	}

	// Ensure home directory exists with correct permissions
	if err := m.setupHomeDir(usr); err != nil {
		return fmt.Errorf("home directory setup failed: %w", err)
	}

	// Switch to the user
	if err := m.switchUser(usr); err != nil {
		return fmt.Errorf("switching user failed: %w", err)
	}

	return nil
}

func (m *UserManager) ensureGroup() (*user.Group, error) {
	group, err := user.LookupGroup(m.config.Group)
	if err == nil {
		return group, nil
	}

	if !m.config.Create {
		return nil, fmt.Errorf("group %s doesn't exist and creation not enabled", m.config.Group)
	}

	gid := 0
	if m.config.GID != nil {
		gid = *m.config.GID
	}

	if err := createGroup(m.config.Group, gid); err != nil {
		return nil, err
	}

	return user.LookupGroup(m.config.Group)
}

func (m *UserManager) ensureUser(group *user.Group) (*user.User, error) {
	usr, err := user.Lookup(m.config.Name)
	if err == nil {
		return usr, nil
	}

	if !m.config.Create {
		return nil, fmt.Errorf("user %s doesn't exist and creation not enabled", m.config.Name)
	}

	uid := 0
	if m.config.UID != nil {
		uid = *m.config.UID
	}

	gid, _ := strconv.Atoi(group.Gid)
	if err := createUser(m.config.Name, uid, gid, m.config.Home, m.config.Shell); err != nil {
		return nil, err
	}

	return user.Lookup(m.config.Name)
}

func (m *UserManager) setupAdditionalGroups(usr *user.User) error {
	if len(m.config.Groups) == 0 {
		return nil
	}

	for _, groupName := range m.config.Groups {
		group, err := user.LookupGroup(groupName)
		if err != nil {
			if !m.config.Create {
				return fmt.Errorf("additional group %s doesn't exist: %w", groupName, err)
			}
			if err := createGroup(groupName, 0); err != nil {
				return fmt.Errorf("failed to create additional group %s: %w", groupName, err)
			}
			group, err = user.LookupGroup(groupName)
			if err != nil {
				return fmt.Errorf("failed to lookup newly created group %s: %w", groupName, err)
			}
		}

		if err := addUserToGroup(usr.Username, group.Name); err != nil {
			return fmt.Errorf("failed to add user to group %s: %w", group.Name, err)
		}
	}

	return nil
}

func (m *UserManager) setupHomeDir(usr *user.User) error {
	if err := os.MkdirAll(usr.HomeDir, 0750); err != nil {
		return fmt.Errorf("failed to create home directory: %w", err)
	}

	uid, _ := strconv.Atoi(usr.Uid)
	gid, _ := strconv.Atoi(usr.Gid)

	if err := os.Chown(usr.HomeDir, uid, gid); err != nil {
		return fmt.Errorf("failed to chown home directory: %w", err)
	}

	// Copy skeleton files if user is not root and directory is empty
	if usr.Username != "root" {
		if empty, err := isDirEmpty(usr.HomeDir); err != nil {
			return err
		} else if empty {
			if err := copySkelFiles(usr.HomeDir, uid, gid); err != nil {
				return fmt.Errorf("failed to copy skel files: %w", err)
			}
		}
	}

	return nil
}

func (m *UserManager) switchUser(usr *user.User) error {
	uid, _ := strconv.Atoi(usr.Uid)
	gid, _ := strconv.Atoi(usr.Gid)

	if err := unix.Setgroups([]int{gid}); err != nil {
		return fmt.Errorf("failed to set groups: %w", err)
	}

	if err := unix.Setgid(gid); err != nil {
		return fmt.Errorf("failed to set GID: %w", err)
	}

	if err := unix.Setuid(uid); err != nil {
		return fmt.Errorf("failed to set UID: %w", err)
	}

	if err := os.Setenv("HOME", usr.HomeDir); err != nil {
		return fmt.Errorf("failed to set HOME env: %w", err)
	}

	if err := os.Setenv("USER", usr.Username); err != nil {
		return fmt.Errorf("failed to set USER env: %w", err)
	}

	if err := os.Setenv("SHELL", m.config.Shell); err != nil {
		return fmt.Errorf("failed to set SHELL env: %w", err)
	}

	return nil
}

func isDirEmpty(path string) (bool, error) {
	f, err := os.Open(path)
	if err != nil {
		return false, err
	}
	defer f.Close()

	_, err = f.Readdirnames(1)
	if err == nil {
		return false, nil
	}
	return err == io.EOF, nil
}

func copySkelFiles(homedir string, uid, gid int) error {
	skelDir := "/etc/skel"
	if _, err := os.Stat(skelDir); os.IsNotExist(err) {
		return nil // Skip if skel directory doesn't exist
	}

	return filepath.Walk(skelDir, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}

		relPath, err := filepath.Rel(skelDir, path)
		if err != nil {
			return err
		}

		targetPath := filepath.Join(homedir, relPath)

		if info.IsDir() {
			return os.MkdirAll(targetPath, info.Mode())
		}

		return copyFile(path, targetPath, uid, gid, info.Mode())
	})
}

func copyFile(src, dst string, uid, gid int, mode os.FileMode) error {
	data, err := os.ReadFile(src)
	if err != nil {
		return err
	}

	if err := os.WriteFile(dst, data, mode); err != nil {
		return err
	}

	return os.Chown(dst, uid, gid)
}

// createGroup creates a new system group
func createGroup(name string, gid int) error {
	args := []string{"--system"}

	if gid != 0 {
		args = append(args, "-g", strconv.Itoa(gid))
	}
	args = append(args, name)

	cmd := exec.Command("groupadd", args...)
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("groupadd failed: %s: %w", string(out), err)
	}
	return nil
}

// createUser creates a new system user
func createUser(name string, uid, gid int, home, shell string) error {
	args := []string{
		"--system",
		"-g", strconv.Itoa(gid),
	}

	if uid != 0 {
		args = append(args, "-u", strconv.Itoa(uid))
	}

	if home != "" {
		args = append(args, "-d", home)
	}

	if shell != "" {
		args = append(args, "-s", shell)
	}

	args = append(args, name)

	cmd := exec.Command("useradd", args...)
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("useradd failed: %s: %w", string(out), err)
	}
	return nil
}

// addUserToGroup adds a user to an existing group
func addUserToGroup(username, groupname string) error {
	cmd := exec.Command("usermod", "-a", "-G", groupname, username)
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("usermod failed: %s: %w", string(out), err)
	}
	return nil
}

// Setuid sets the user ID for the current process
func Setuid(uid int) error {
	return unix.Setuid(uid)
}

// Setgid sets the group ID for the current process
func Setgid(gid int) error {
	return unix.Setgid(gid)
}
