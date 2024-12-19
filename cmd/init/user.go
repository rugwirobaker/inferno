package main

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/rugwirobaker/inferno/internal/image"
)

// UserManager handles user and group setup in the VM environment
type UserManager struct {
	config *image.UserConfig
}

// NewUserManager creates a new UserManager with the given config
func NewUserManager(config *image.UserConfig) *UserManager {
	return &UserManager{
		config: config.WithDefaults(),
	}
}

// Initialize sets up the user environment including groups, home directory, and permissions
func (m *UserManager) Initialize() error {
	if err := m.createSystemFiles(); err != nil {
		return fmt.Errorf("creating system files: %w", err)
	}

	// Create group first, then user
	gid, err := m.createOrGetGroup()
	if err != nil {
		return fmt.Errorf("managing group: %w", err)
	}

	if err := m.createOrGetUser(gid); err != nil {
		return fmt.Errorf("managing user: %w", err)
	}

	if err := m.createSecondaryGroups(); err != nil {
		return fmt.Errorf("managing secondary groups: %w", err)
	}

	if err := m.createHomeDirectory(); err != nil {
		return fmt.Errorf("managing home directory: %w", err)
	}

	// if err := m.assumeUserIdentity(); err != nil {
	// 	return fmt.Errorf("assuming user identity: %w", err)
	// }

	return nil
}

func (m *UserManager) createSystemFiles() error {
	files := []struct {
		path string
		perm os.FileMode
	}{
		{"/etc/passwd", 0644},
		{"/etc/group", 0644},
	}

	for _, f := range files {
		if err := ensureFile(f.path, f.perm); err != nil {
			return fmt.Errorf("creating %s: %w", f.path, err)
		}
	}
	return nil
}

func (m *UserManager) createOrGetGroup() (int, error) {
	// Use configured GID or default
	desiredGID := 1000
	if m.config.GID != nil {
		desiredGID = *m.config.GID
	}

	// Check if group exists
	existingGID, err := lookupGroupID(m.config.Group)
	if err == nil {
		return existingGID, nil
	}

	// Create new group with desired GID
	entry := fmt.Sprintf("%s:x:%d:\n", m.config.Group, desiredGID)
	if err := appendToFile("/etc/group", entry); err != nil {
		return 0, err
	}

	return desiredGID, nil
}

func (m *UserManager) createOrGetUser(gid int) error {
	// Use configured UID or default
	desiredUID := 1000
	if m.config.UID != nil {
		desiredUID = *m.config.UID
	}

	// Check if user exists
	if _, err := lookupUserID(m.config.Name); err == nil {
		return nil
	}

	entry := fmt.Sprintf("%s:x:%d:%d:%s:%s:%s\n",
		m.config.Name, desiredUID, gid,
		m.config.Name,
		m.config.Home,
		m.config.Shell)

	return appendToFile("/etc/passwd", entry)
}

func (m *UserManager) createHomeDirectory() error {
	// Create parent directories with standard permissions
	parent := filepath.Dir(m.config.Home)
	if parent != "/" {
		if err := os.MkdirAll(parent, 0755); err != nil {
			return fmt.Errorf("creating parent directories: %w", err)
		}
	}

	// Create home directory with restricted permissions
	if err := os.MkdirAll(m.config.Home, 0750); err != nil {
		return fmt.Errorf("creating home directory: %w", err)
	}

	uid := 1000
	if m.config.UID != nil {
		uid = *m.config.UID
	}

	gid := 1000
	if m.config.GID != nil {
		gid = *m.config.GID
	}

	if err := os.Chown(m.config.Home, uid, gid); err != nil {
		return fmt.Errorf("setting home directory ownership: %w", err)
	}

	return nil
}

func (m *UserManager) createSecondaryGroups() error {
	if len(m.config.Groups) == 0 {
		return nil
	}

	for _, groupName := range m.config.Groups {
		if err := m.addUserToSecondaryGroup(groupName); err != nil {
			return fmt.Errorf("managing secondary group %s: %w", groupName, err)
		}
	}

	return nil
}

func (m *UserManager) addUserToSecondaryGroup(groupName string) error {
	_, err := lookupGroupID(groupName)
	if err != nil {
		// Create new group if it doesn't exist
		gid := findNextAvailableGID()
		entry := fmt.Sprintf("%s:x:%d:%s\n", groupName, gid, m.config.Name)
		return appendToFile("/etc/group", entry)
	}

	return addUserToGroup(m.config.Name, groupName)
}

// func (m *UserManager) assumeUserIdentity() error {
// 	uid := 1000
// 	if m.config.UID != nil {
// 		uid = *m.config.UID
// 	}

// 	gid := 1000
// 	if m.config.GID != nil {
// 		gid = *m.config.GID
// 	}

// 	// Set supplementary groups first
// 	if err := unix.Setgroups([]int{gid}); err != nil {
// 		return fmt.Errorf("setting groups: %w", err)
// 	}

// 	if err := unix.Setgid(gid); err != nil {
// 		return fmt.Errorf("setting GID: %w", err)
// 	}

// 	if err := unix.Setuid(uid); err != nil {
// 		return fmt.Errorf("setting UID: %w", err)
// 	}

// 	// Set environment variables
// 	envVars := map[string]string{
// 		"HOME":  m.config.Home,
// 		"USER":  m.config.Name,
// 		"SHELL": m.config.Shell,
// 	}

// 	for key, value := range envVars {
// 		if err := os.Setenv(key, value); err != nil {
// 			return fmt.Errorf("setting %s environment variable: %w", key, err)
// 		}
// 	}

// 	return nil
// }

// Helper functions

func ensureFile(path string, perm os.FileMode) error {
	if _, err := os.Stat(path); os.IsNotExist(err) {
		f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY, perm)
		if err != nil {
			return err
		}
		return f.Close()
	}
	return nil
}

func lookupUserID(username string) (int, error) {
	f, err := os.Open("/etc/passwd")
	if err != nil {
		return 0, err
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		fields := strings.Split(scanner.Text(), ":")
		if len(fields) >= 3 && fields[0] == username {
			return strconv.Atoi(fields[2])
		}
	}
	return 0, fmt.Errorf("user not found: %s", username)
}

func lookupGroupID(groupname string) (int, error) {
	f, err := os.Open("/etc/group")
	if err != nil {
		return 0, err
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		fields := strings.Split(scanner.Text(), ":")
		if len(fields) >= 3 && fields[0] == groupname {
			return strconv.Atoi(fields[2])
		}
	}
	return 0, fmt.Errorf("group not found: %s", groupname)
}

func appendToFile(path, content string) error {
	f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0644)
	if err != nil {
		return fmt.Errorf("opening file %s: %w", path, err)
	}
	defer f.Close()

	if _, err := f.WriteString(content); err != nil {
		return fmt.Errorf("writing to file %s: %w", path, err)
	}

	return nil
}

func addUserToGroup(username, groupname string) error {
	content, err := os.ReadFile("/etc/group")
	if err != nil {
		return fmt.Errorf("reading group file: %w", err)
	}

	lines := strings.Split(string(content), "\n")
	modified := false

	for i, line := range lines {
		fields := strings.Split(line, ":")
		if len(fields) >= 4 && fields[0] == groupname {
			members := strings.Split(fields[3], ",")
			for _, member := range members {
				if member == username {
					return nil // User already in group
				}
			}
			if fields[3] == "" {
				fields[3] = username
			} else {
				fields[3] += "," + username
			}
			lines[i] = strings.Join(fields, ":")
			modified = true
			break
		}
	}

	if !modified {
		return fmt.Errorf("group not found: %s", groupname)
	}

	return os.WriteFile("/etc/group", []byte(strings.Join(lines, "\n")), 0644)
}

func findNextAvailableGID() int {
	maxGID := 1000
	f, err := os.Open("/etc/group")
	if err != nil {
		return maxGID
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		fields := strings.Split(scanner.Text(), ":")
		if len(fields) >= 3 {
			if gid, err := strconv.Atoi(fields[2]); err == nil && gid >= maxGID {
				maxGID = gid + 1
			}
		}
	}
	return maxGID
}
