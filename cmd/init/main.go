package main

import (
	"fmt"
	"log"
	"log/slog"
	"os"
	"os/exec"
	"sync"

	"syscall"

	"github.com/rugwirobaker/inferno/internal/image"
	"github.com/rugwirobaker/inferno/internal/linux"
)

const paths = "PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin"

var LogLevel struct {
	sync.Mutex
	slog.LevelVar
}

// main starts an init process that can prepare an environment and start a shell
// after the Kernel has started.
func main() {
	fmt.Printf("inferno init started\n")

	if err := linux.Mount("none", "/proc", "proc", 0); err != nil {
		log.Fatalf("error mounting /proc: %v", err)
	}
	if err := linux.Mount("none", "/dev/pts", "devpts", 0); err != nil {
		log.Fatalf("error mounting /dev/pts: %v", err)
	}
	if err := linux.Mount("none", "/dev/mqueue", "mqueue", 0); err != nil {
		log.Fatalf("error mounting /dev/mqueue: %v", err)
	}
	if err := linux.Mount("none", "/dev/shm", "tmpfs", 0); err != nil {
		log.Fatalf("error mounting /dev/shm: %v", err)
	}
	if err := linux.Mount("none", "/sys", "sysfs", 0); err != nil {
		log.Fatalf("error mounting /sys: %v", err)
	}
	if err := linux.Mount("none", "/sys/fs/cgroup", "cgroup", 0); err != nil {
		log.Fatalf("error mounting /sys/fs/cgroup: %v", err)
	}

	config, err := image.FromFile("/inferno/run.json")
	if err != nil {
		panic(fmt.Sprintf("could not read run.json, error: %s", err))
	}

	setHostname(config.ID)

	cmd := exec.Command(config.Process.Cmd, config.Process.Args...)

	cmd.Env = append(cmd.Env, paths)

	for k, v := range config.Env {
		cmd.Env = append(cmd.Env, fmt.Sprintf("%s=%s", k, v))
	}
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	err = cmd.Start()
	if err != nil {
		panic(fmt.Sprintf("could not start /bin/sh, error: %s", err))
	}

	err = cmd.Wait()
	if err != nil {
		panic(fmt.Sprintf("could not wait for /bin/sh, error: %s", err))
	}
}

func setHostname(hostname string) {
	err := syscall.Sethostname([]byte(hostname))
	if err != nil {
		panic(fmt.Sprintf("cannot set hostname to %s, error: %s", hostname, err))
	}
}
