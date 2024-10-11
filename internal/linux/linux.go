package linux

import (
	"fmt"
	"io"
	"os"
	"syscall"
)

func Mount(source, target, filesystemtype string, flags uintptr) error {
	if _, err := os.Stat(target); os.IsNotExist(err) {
		err := os.MkdirAll(target, 0755)
		if err != nil {
			return fmt.Errorf("error creating target folder: %s %s", target, err)
		}
	}

	err := syscall.Mount(source, target, filesystemtype, flags, "")
	if err != nil {
		return fmt.Errorf("error mounting %s to %s, error: %s", source, target, err)
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
