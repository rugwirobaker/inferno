package main

import (
	"encoding/base64"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"syscall"

	"github.com/rugwirobaker/inferno/internal/image"
	"golang.org/x/sys/unix"
)

const (
	chmod0755  = 0755
	chmod1777  = 01777
	cgroupMode = "mode=755"
)

// MountFlags represents available mount flags
type MountFlags struct {
	ReadOnly  bool
	NoExec    bool
	NoSuid    bool
	NoDev     bool
	RelaTime  bool
	Recursive bool
}

func (f MountFlags) ToSyscall() uintptr {
	var flags uintptr
	if f.ReadOnly {
		flags |= syscall.MS_RDONLY
	}
	if f.NoExec {
		flags |= syscall.MS_NOEXEC
	}
	if f.NoSuid {
		flags |= syscall.MS_NOSUID
	}
	if f.NoDev {
		flags |= syscall.MS_NODEV
	}
	if f.RelaTime {
		flags |= syscall.MS_RELATIME
	}
	if f.Recursive {
		flags |= syscall.MS_REC
	}
	return flags
}

// Mount mounts a filesystem
func Mount(source, target, fstype string, flags MountFlags, data string) error {
	if err := os.MkdirAll(target, chmod0755); err != nil {
		return fmt.Errorf("failed to create mount point %s: %w", target, err)
	}

	if err := syscall.Mount(source, target, fstype, flags.ToSyscall(), data); err != nil {
		return fmt.Errorf("failed to mount %s to %s: %w", source, target, err)
	}

	slog.Debug("Mounted filesystem",
		"source", source,
		"target", target,
		"type", fstype,
	)
	return nil
}

// MountInitialDevFS mounts the initial devtmpfs
func MountInitialDevFS() error {
	if err := Mount("devtmpfs", "/dev", "devtmpfs", MountFlags{NoSuid: true}, "mode=0755"); err != nil {
		return fmt.Errorf("failed to mount initial devtmpfs: %w", err)
	}
	return nil
}

// MountRootFS mounts the root filesystem
func MountRootFS(device, fstype string, options []string) error {
	flags := MountFlags{RelaTime: true}
	for _, opt := range options {
		switch opt {
		case "ro":
			flags.ReadOnly = true
		case "noexec":
			flags.NoExec = true
		case "nosuid":
			flags.NoSuid = true
		case "nodev":
			flags.NoDev = true
		}
	}

	if err := os.MkdirAll("/rootfs", chmod0755); err != nil {
		return fmt.Errorf("failed to create /rootfs: %w", err)
	}

	if err := Mount(device, "/rootfs", fstype, flags, ""); err != nil {
		return fmt.Errorf("failed to mount root filesystem: %w", err)
	}

	// Prepare /dev in new root (but don't move it yet - that happens after volume unlock)
	if err := os.MkdirAll("/rootfs/dev", chmod0755); err != nil {
		return fmt.Errorf("failed to create /rootfs/dev: %w", err)
	}

	return nil
}

// MoveDevToNewRoot moves /dev to the new root after volumes are unlocked
// This must be called AFTER unlockEncryptedVolumes so that /dev/vdb and /dev/mapper/* are accessible
func MoveDevToNewRoot() error {
	if err := syscall.Mount("/dev", "/rootfs/dev", "", syscall.MS_MOVE, ""); err != nil {
		return fmt.Errorf("failed to move /dev to new root: %w", err)
	}
	return nil
}

// MountEarlyPseudoFS mounts /proc and /sys early for device-mapper
// This must be called BEFORE unlockEncryptedVolumes so cryptsetup can initialize device-mapper
func MountEarlyPseudoFS() error {
	return mountPseudoFS()
}

// MountFS mounts all required filesystems
func MountFS() error {
	// Pseudo filesystems (/proc, /sys) are already mounted by MountEarlyPseudoFS
	// We call mountPseudoFS again here to handle the case where we're in the new root
	// The mounts will be re-created in the new mount namespace
	if err := mountPseudoFS(); err != nil {
		return err
	}

	// Mount device filesystems
	if err := mountDevFS(); err != nil {
		return err
	}

	// Mount cgroups
	if err := mountCgroups(); err != nil {
		return err
	}

	// Creare symlinks in /dev
	if err := createProcSymlinks(); err != nil {
		return err
	}

	return nil
}

func CreateUserFiles(files []image.File) error {
	for _, f := range files {
		// Make sure the parent directories exist before creating the file
		if err := os.MkdirAll(filepath.Dir(f.Path), 0755); err != nil {
			return fmt.Errorf("creating parent directories for %s: %w", f.Path, err)
		}

		decoded, err := base64.StdEncoding.DecodeString(f.Content)
		if err != nil {
			return fmt.Errorf("decoding base64 content for %s: %w", f.Path, err)
		}

		// Create or overwrite the file with the specified mode
		if err := writeFile(f.Path, f.Mode, decoded); err != nil {
			return fmt.Errorf("writing file %s: %w", f.Path, err)
		}
	}
	return nil
}

// mountPseudoFS mounts proc and sysfs
func mountPseudoFS() error {
	mounts := []struct {
		source, target, fstype string
		flags                  MountFlags
	}{
		{
			source: "proc",
			target: "/proc",
			fstype: "proc",
			flags:  MountFlags{ReadOnly: true},
		},
		{
			source: "sysfs",
			target: "/sys",
			fstype: "sysfs",
			flags:  MountFlags{NoSuid: true, NoExec: true, NoDev: true},
		},
	}

	for _, m := range mounts {
		if err := Mount(m.source, m.target, m.fstype, m.flags, ""); err != nil {
			return err
		}
	}
	return nil
}

// mountDevFS mounts device-related filesystems
func mountDevFS() error {
	mounts := []struct {
		source, target, fstype, options string
		flags                           MountFlags
	}{
		{
			source:  "devpts",
			target:  "/dev/pts",
			fstype:  "devpts",
			options: "mode=0620,gid=5,ptmxmode=666",
			flags:   MountFlags{NoExec: true, NoSuid: true, RelaTime: true},
		},
		{
			source: "mqueue",
			target: "/dev/mqueue",
			fstype: "mqueue",
		},
		{
			source: "tmpfs",
			target: "/dev/shm",
			fstype: "tmpfs",
			flags:  MountFlags{NoSuid: true, NoDev: true},
		},
		{
			source:  "hugetlbfs",
			target:  "/dev/hugepages",
			fstype:  "hugetlbfs",
			options: "pagesize=2M",
			flags:   MountFlags{RelaTime: true},
		},
	}

	for _, m := range mounts {
		if err := Mount(m.source, m.target, m.fstype, m.flags, m.options); err != nil {
			return err
		}
	}
	return nil
}

// mountCgroups mounts the cgroup filesystem
func mountCgroups() error {
	if err := Mount("tmpfs", "/sys/fs/cgroup", "tmpfs",
		MountFlags{NoSuid: true, NoExec: true, NoDev: true},
		cgroupMode); err != nil {
		return fmt.Errorf("failed to mount cgroup: %w", err)
	}
	return nil
}

// createProcSymlinks creates standard /dev symlinks
func createProcSymlinks() error {
	links := []struct {
		oldname string
		newname string
	}{
		{"/proc/self/fd", "/dev/fd"},
		{"/proc/self/fd/0", "/dev/stdin"},
		{"/proc/self/fd/1", "/dev/stdout"},
		{"/proc/self/fd/2", "/dev/stderr"},
	}

	for _, link := range links {
		// Remove existing symlink if it exists
		_ = os.Remove(link.newname)
		if err := unix.Symlinkat(link.oldname, 0, link.newname); err != nil {
			return fmt.Errorf("failed to create symlink %s -> %s: %w",
				link.newname, link.oldname, err)
		}
	}
	return nil
}

func writeFile(path string, perm os.FileMode, content []byte) error {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, perm)
	if err != nil {
		return err
	}
	defer f.Close()

	if len(content) > 0 {
		if _, err := f.Write(content); err != nil {
			return fmt.Errorf("writing content to %s: %w", path, err)
		}
	}
	return nil
}
