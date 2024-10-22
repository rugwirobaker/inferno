package linux

import (
	"fmt"
	"os"
	"syscall"
)

func mount(source, target, filesystemtype string, flags uintptr) error {
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
