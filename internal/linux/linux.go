package linux

import (
	"io"
	"log"
	"os"
	"syscall"

	"golang.org/x/sys/unix"
)

func Mount(source, target, filesystemtype string, flags uintptr) error {
	return mount(source, target, filesystemtype, flags)
}

// PivotRoot changes the root filesystem of the calling process to the directory
// specified by newRoot and mounts the old root at putOld.
func PivotRoot(newRoot, putOld string) error {
	if err := os.MkdirAll(putOld, 0700); err != nil {
		return err
	}

	if err := unix.PivotRoot(newRoot, putOld); err != nil {
		return err
	}

	// Change the working directory to the new root
	if err := syscall.Chdir("/"); err != nil {
		log.Fatalf("error changing directory to new root: %v", err)
	}

	return nil
}

func CopyFile(src, dst string, perm os.FileMode) error {
	sourceFile, err := os.Open(src)
	if err != nil {
		return err
	}
	defer sourceFile.Close()

	destFile, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer destFile.Close()

	if _, err := io.Copy(destFile, sourceFile); err != nil {
		return err
	}
	return os.Chmod(dst, perm)
}
