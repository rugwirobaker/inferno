package server

import (
	"bufio"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"strings"

	"github.com/cavaliergopher/cpio"
	"github.com/klauspost/compress/zstd"
	nanoid "github.com/matoous/go-nanoid/v2"
	"github.com/rugwirobaker/inferno/internal/config"
	"github.com/rugwirobaker/inferno/internal/firecracker"
	"github.com/rugwirobaker/inferno/internal/image"
	"github.com/rugwirobaker/inferno/internal/kiln"
	"github.com/rugwirobaker/inferno/internal/pointer"
	"github.com/rugwirobaker/inferno/internal/sys"
	"github.com/rugwirobaker/inferno/internal/vm"
	"github.com/rugwirobaker/inferno/internal/vsock"
)

const (
	initDeviceName = "initrd.img"
)

const HEX_ALPHABET = "1234567890abcdef"

type runRequest struct {
	Image    string `json:"image"`
	CPUKind  string `json:"cpu_kind"`
	CPUCount int    `json:"cpu_count"`
	MemoryMB int    `json:"memory_mb"`
}

func Run(cfg *config.Config, images *image.Manager) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var (
			logger = slog.With("system", "server")
			ctx    = r.Context()
		)
		var req runRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			logger.Error("Failed to decode request", "error", err)

			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}

		id, err := nanoid.Generate(HEX_ALPHABET, 8)
		if err != nil {
			logger.Error("Failed to generate VM ID", "error", err)

			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}

		var chroot = filepath.Join(cfg.StateBaseDir, "vms", id)

		if err := os.MkdirAll(chroot, 0o755); err != nil {
			logger.With(slog.String("vm-id", id)).Error("Failed to create chroot", "error", err)

			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}

		if err := os.Chown(chroot, firecracker.DefaultJailerUID, firecracker.DefaultJailerGID); err != nil {
			slog.With(slog.String("vm-id", id)).Error("Failed to chown chroot", "error", err)

			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}

		// Copy the kernel and init to the chroot
		if err := sys.CopyFile(cfg.KernelPath, filepath.Join(chroot, "vmlinux"), 0644); err != nil {
			logger.With(slog.String("vm-id", id)).Error("Failed to copy kernel", "error", err)
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}

		// copy the firecracker binary to the chroot
		if err := sys.CopyFile(cfg.FirecrackerBinPath, filepath.Join(chroot, "firecracker"), 0755); err != nil {
			logger.With(slog.String("vm-id", id)).Error("Failed to copy firecracker", "error", err)
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}

		// copy kiln binary to the chroot
		if err := sys.CopyFile(cfg.KilnBinPath, filepath.Join(chroot, "kiln"), 0755); err != nil {
			logger.With(slog.String("vm-id", id)).Error("Failed to copy kiln", "error", err)
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}

		// ensure the image is cached locally at /var
		if err := images.FetchImage(ctx, req.Image); err != nil {
			logger.With(slog.String("vm-id", id)).Error("Failed to fetch image", "error", err)
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}

		// extract the image from manifest
		img, err := images.CreateConfig(ctx, req.Image)
		if err != nil {
			logger.With(slog.String("vm-id", id)).Error("Failed to create image config", "error", err)
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}

		// package init files
		files := make(map[string][]byte)

		initBinaryPath := filepath.Join(chroot, "init") // Assuming init binary is copied to vmdir

		initContent, err := os.ReadFile(initBinaryPath)
		if err != nil {
			logger.With(slog.String("vm-id", id)).Error("Failed to read init binary", "error", err)
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		files["inferno/init"] = initContent

		// Convert run configuration to bytes (JSON)
		imageConfigJSON, err := img.Marshal()
		if err != nil {
			logger.With(slog.String("vm-id", id)).Error("Failed to marshal image config", "error", err)
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		files["inferno/run.json"] = imageConfigJSON

		_, err = createInitrd(chroot, files)
		if err != nil {
			logger.With(slog.String("vm-id", id)).Error("Failed to create initrd", "error", err)
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}

		// create the rootfs device
		if err := images.CreateRootFS(ctx, req.Image, filepath.Join(chroot, "rootfs.ext4")); err != nil {
			logger.With(slog.String("vm-id", id)).Error("Failed to create rootfs", "error", err)
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}

		// create the firecracker config
		fcConfig, err := firecrackerConfig(id, chroot, filepath.Join(chroot, initDeviceName))
		if err != nil {
			logger.With(slog.String("vm-id", id)).Error("Failed to create firecracker config", "error", err)
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}

		// write the firecracker config to a file
		fcConfigPath := filepath.Join(chroot, "firecracker.json")

		if err := firecracker.WriteConfig(fcConfigPath, fcConfig); err != nil {
			logger.With(slog.String("vm-id", id)).Error("Failed to write firecracker config", "error", err)
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}

		if err := os.Chown(fcConfigPath, firecracker.DefaultJailerUID, firecracker.DefaultJailerGID); err != nil {
			logger.With(slog.String("vm-id", id)).Error("Failed to chown firecracker config", "error", err)
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}

		// create kiln config
		kilnConfig, err := kilnConfig(id, filepath.Base(cfg.VMLogsSocketPath), kiln.Resources{
			CPUKind:  req.CPUKind,
			CPUCount: req.CPUCount,
			MemoryMB: req.MemoryMB,
		})
		if err != nil {
			logger.With(slog.String("vm-id", id)).Error("Failed to create kiln config", "error", err)
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}

		// write the kiln config to a file
		if err := kiln.WriteConfig(filepath.Join(chroot, "kiln.json"), kilnConfig); err != nil {
			logger.With(slog.String("vm-id", id)).Error("Failed to write kiln config", "error", err)
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}

		vm := vm.New(id, &vm.Config{
			Chroot:      chroot,
			LogPathSock: cfg.VMLogsSocketPath,
		})

		if err := vm.Start(ctx); err != nil {
			logger.With(slog.String("vm-id", id)).Error("Failed to start VM", "error", err)
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		if err := json.NewEncoder(w).Encode(map[string]string{"id": id}); err != nil {
			logger.With(slog.String("vm-id", id)).Error("Failed to encode response", "error", err)
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
	}
}

func createInitrd(chroot string, files map[string][]byte) (string, error) {
	var path = filepath.Join(chroot, initDeviceName)

	// create the initrd file with the right permissions
	initrd, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE|os.O_TRUNC, 0o644)
	if err != nil {
		return "", err
	}
	defer initrd.Close()

	writer := bufio.NewWriter(initrd)
	compressor, err := zstd.NewWriter(writer, zstd.WithEncoderLevel(zstd.SpeedFastest))

	if err != nil {
		return "", err
	}

	archiver := cpio.NewWriter(compressor)

	for name, content := range files {
		err := archiver.WriteHeader(&cpio.Header{
			Name: name,
			Mode: 0644,
			Size: int64(len(content)),
		})
		if err != nil {
			return "", err
		}
		_, err = archiver.Write(content)
		if err != nil {
			return "", err
		}
	}
	if err := archiver.Close(); err != nil {
		return "", err
	}
	if err := compressor.Close(); err != nil {
		return "", err
	}
	return path, nil
}

func firecrackerConfig(id, chroot, initrdPath string) (*firecracker.Config, error) {
	mac, err := generateMAC()
	if err != nil {
		return nil, err
	}

	// kernel boot args
	kargs := firecracker.DefaultBootArgs()
	// append init location
	kargs = append(kargs, "rdinit=/inferno/init")

	fcConfig := &firecracker.Config{
		BootSource: firecracker.BootSource{
			KernelImagePath: filepath.Join(chroot, "vmlinux"),
			InitrdPath:      pointer.String(initrdPath),
			BootArgs:        strings.Join(kargs, " "),
		},
		Drives: []firecracker.Drive{
			{
				DriveID:      "rootfs",
				PathOnHost:   filepath.Join(chroot, "rootfs.ext4"),
				IsRootDevice: false,
				IsReadOnly:   false,
			},
		},
		MachineConfig: firecracker.MachineConfig{
			VCPUCount:  2,
			MemSizeMib: 1024,
		},
		NetworkInterfaces: []firecracker.NetworkInterface{
			{
				IfaceName: "eth0",
				HostDev:   fmt.Sprintf("vm%s", id),
				Mac:       mac,
			},
		},
		VsockDevices: []firecracker.VsockDevice{
			{
				GuestCID: 3, // guest CID is always 3
				VsockID:  "control",
				UDSPath:  "control.sock",
			},
		},
	}
	return fcConfig, nil
}

func kilnConfig(id, logSocket string, resources kiln.Resources) (*kiln.Config, error) {
	return &kiln.Config{
		JailID:                  id,
		UID:                     firecracker.DefaultJailerUID,
		GID:                     firecracker.DefaultJailerGID,
		FirecrackerSocketPath:   "/firecracker.sock",
		FirecrackerConfigPath:   "firecracker.json",
		FirecrackerVsockUDSPath: "control.sock",

		VsockStdoutPort: vsock.VsockStdoutPort,
		VsockExitPort:   vsock.VsockExitPort,

		VMLogsSocketPath: logSocket,
		ExitStatusPath:   "exit-status.json",
		Resources:        resources,
	}, nil
}

func generateMAC() (string, error) {
	buf := make([]byte, 4)
	_, err := rand.Read(buf)
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("AB:CD:%02x:%02x:%02x:%02x", buf[0], buf[1], buf[2], buf[3]), nil
}
