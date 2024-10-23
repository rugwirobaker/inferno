package sys

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"syscall"
)

func mount(source, target, fstype string, flags uintptr, data string) error {
	if err := syscall.Mount(source, target, fstype, flags, data); err != nil {
		return err
	}
	return nil
}

func uptime() (float64, error) {
	// Read the content of /proc/uptime
	data, err := os.ReadFile("/proc/uptime")
	if err != nil {
		return 0, fmt.Errorf("failed to read /proc/uptime: %w", err)
	}

	// Extract the first number from the content (the uptime in seconds)
	fields := strings.Fields(string(data))
	if len(fields) < 1 {
		return 0, fmt.Errorf("unexpected content in /proc/uptime")
	}

	// Convert the first field to a float64
	uptimeSeconds, err := strconv.ParseFloat(fields[0], 64)
	if err != nil {
		return 0, fmt.Errorf("failed to parse uptime: %w", err)
	}

	return uptimeSeconds, nil
}
