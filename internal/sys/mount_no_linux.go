//go:build !linux

package linux

import "fmt"

func mount(source, target, fstype string, flags uintptr, data string) error {
	return fmt.Errorf("mount not supported on this platform")
}

func uptime() (float64, error) {
	return 0, fmt.Errorf("uptime not supported on this platform")
}
