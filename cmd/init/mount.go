package main

import (
	"fmt"
	"log/slog"
	"os"
	"syscall"

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

	// Prepare /dev in new root
	if err := os.MkdirAll("/rootfs/dev", chmod0755); err != nil {
		return fmt.Errorf("failed to create /rootfs/dev: %w", err)
	}

	if err := syscall.Mount("/dev", "/rootfs/dev", "", syscall.MS_MOVE, ""); err != nil {
		return fmt.Errorf("failed to move /dev to new root: %w", err)
	}

	return nil
}

// MountFS mounts all required filesystems
func MountFS() error {
	// Mount pseudo filesystems first
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
