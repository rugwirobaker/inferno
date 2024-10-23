package sys

import (
	"io"
	"os"
)

func Mount(source, target, fstype string, flags uintptr, data string) error {
	return mount(source, target, fstype, flags, data)
}

func Uptime() (float64, error) {
	return uptime()
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
