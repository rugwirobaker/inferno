//go:build !linux

package linux

import (
	"errors"
)

func mount(source, target, filesystemtype string, flags uintptr) error {
	return errors.New("mount operation only supported on linux")
}
