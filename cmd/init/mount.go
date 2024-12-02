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

// Mount all required filesystems
func mountFS() error {
	if err := mountDev(); err != nil {
		return err
	}
	if err := mountCgroups(); err != nil {
		return err
	}
	if err := mountCommon(); err != nil {
		return err
	}
	return nil
}

// Mount dev filesystems
func mountDev() error {
	mounts := []struct {
		source, target, fstype, options string
		flags                           uintptr
	}{
		{"devpts", "/dev/pts", "devpts", "mode=0620,gid=5,ptmxmode=666", syscall.MS_NOEXEC | syscall.MS_NOSUID | syscall.MS_NOATIME},
		{"mqueue", "/dev/mqueue", "mqueue", "", 0},
		{"tmpfs", "/dev/shm", "tmpfs", "", syscall.MS_NOSUID | syscall.MS_NODEV},
		{"hugetlbfs", "/dev/hugepages", "hugetlbfs", "pagesize=2M", syscall.MS_RELATIME},
	}
	for _, m := range mounts {
		if err := os.MkdirAll(m.target, chmod0755); err != nil {
			return fmt.Errorf("error creating dir %s: %v", m.target, err)
		}
		if err := syscall.Mount(m.source, m.target, m.fstype, m.flags, m.options); err != nil {
			return fmt.Errorf("error mounting %s to %s: %v", m.source, m.target, err)
		}
		slog.Debug("Mounted %s to %s", m.source, m.target)
	}
	return nil
}

// Mount cgroup filesystems
func mountCgroups() error {
	if err := os.MkdirAll("/sys/fs/cgroup", chmod0755); err != nil {
		return fmt.Errorf("error creating /sys/fs/cgroup: %v", err)
	}
	if err := syscall.Mount("tmpfs", "/sys/fs/cgroup", "tmpfs", syscall.MS_NOSUID|syscall.MS_NOEXEC|syscall.MS_NODEV, cgroupMode); err != nil {
		return fmt.Errorf("error mounting cgroup: %v", err)
	}
	slog.Debug("Mounted cgroup")
	return nil
}

// Mount common filesystems
func mountCommon() error {
	commonMounts := []struct {
		source, target, fstype string
		flags                  uintptr
		options                string
	}{
		{"proc", "/proc", "proc", syscall.MS_RDONLY, ""},
		{"sysfs", "/sys", "sysfs", syscall.MS_NOSUID | syscall.MS_NOEXEC | syscall.MS_NODEV, ""},
	}

	for _, m := range commonMounts {
		if err := os.MkdirAll(m.target, chmod0755); err != nil {
			return fmt.Errorf("error creating directory %s: %w", m.target, err)
		}
		if err := syscall.Mount(m.source, m.target, m.fstype, m.flags, m.options); err != nil {
			return fmt.Errorf("error mounting %s (%s) to %s: %w", m.source, m.fstype, m.target, err)
		}
		slog.Debug("Mounted filesystem", "source", m.source, "target", m.target)
	}

	return nil
}

func createProcSymlinks() error {
	if err := unix.Symlinkat("/proc/self/fd", 0, "/dev/fd"); err != nil {
		return fmt.Errorf("error creating /dev/fd symlink: %v", err)
	}

	if err := unix.Symlinkat("/proc/self/fd/0", 0, "/dev/stdin"); err != nil {
		return fmt.Errorf("error creating /dev/stdin symlink: %v", err)
	}

	if err := unix.Symlinkat("/proc/self/fd/1", 0, "/dev/stdout"); err != nil {
		return fmt.Errorf("error creating /dev/stdout symlink: %v", err)
	}

	if err := unix.Symlinkat("/proc/self/fd/2", 0, "/dev/stderr"); err != nil {
		return fmt.Errorf("error creating /dev/stderr symlink: %v", err)
	}
	return nil
}
