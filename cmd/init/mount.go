package main

import (
	"fmt"
	"log"
	"os"
	"syscall"
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
		log.Printf("Mounted %s to %s", m.source, m.target)
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
	log.Println("Mounted cgroup")
	return nil
}

// Mount common filesystems
func mountCommon() error {
	commonMounts := []struct {
		source, target, fstype string
		flags                  uintptr
	}{
		{"proc", "/proc", "proc", 0},
		{"sysfs", "/sys", "sysfs", 0},
	}
	for _, m := range commonMounts {
		if err := os.MkdirAll(m.target, chmod0755); err != nil {
			return fmt.Errorf("error creating dir %s: %v", m.target, err)
		}
		if err := syscall.Mount(m.source, m.target, m.fstype, m.flags, ""); err != nil {
			return fmt.Errorf("error mounting %s to %s: %v", m.source, m.target, err)
		}
		log.Printf("Mounted %s to %s", m.source, m.target)
	}
	return nil
}
