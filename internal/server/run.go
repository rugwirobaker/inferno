package server

import (
	"bufio"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"log"
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
	"github.com/rugwirobaker/inferno/internal/linux"
	"github.com/rugwirobaker/inferno/internal/pointer"
	"github.com/rugwirobaker/inferno/internal/vm"
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
		var ctx = r.Context()

		var req runRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}

		id, err := nanoid.Generate(HEX_ALPHABET, 8)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}

		var chroot = filepath.Join(cfg.StateBaseDir, "vms", id)

		if err := os.MkdirAll(chroot, 0o755); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}

		if err := os.Chown(chroot, firecracker.DefaultJailerUID, firecracker.DefaultJailerGID); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}

		// Copy the kernel and init to the chroot
		if err := linux.CopyFile(cfg.KernelPath, filepath.Join(chroot, "vmlinux"), 0644); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}

		// copy the firecracker binary to the chroot
		if err := linux.CopyFile(cfg.FirecrackerBinPath, filepath.Join(chroot, "firecracker"), 0755); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}

		// copy kiln binary to the chroot
		if err := linux.CopyFile(cfg.KilnBinPath, filepath.Join(chroot, "kiln"), 0755); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}

		// ensure the image is cached locally at /var
		if err := images.FetchImage(ctx, req.Image); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}

		// extract the image from manifest
		img, err := images.CreateConfig(ctx, req.Image)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}

		// package init files
		files := make(map[string][]byte)

		initBinaryPath := filepath.Join(chroot, "init") // Assuming init binary is copied to vmdir

		initContent, err := os.ReadFile(initBinaryPath)
		if err != nil {
			log.Fatalf("Failed to read init binary: %v", err)
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		files["inferno/init"] = initContent

		// Convert run configuration to bytes (JSON)
		imageConfigJSON, err := img.Marshal()
		if err != nil {
			log.Fatalf("Failed to marshal run config: %v", err)
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		files["inferno/run.json"] = imageConfigJSON

		_, err = createInitrd(chroot, files)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}

		// create the rootfs device
		if err := images.CreateRootFS(ctx, req.Image, filepath.Join(chroot, "rootfs.ext4")); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}

		// create the firecracker config
		fcConfig, err := firecrackerConfig(id, chroot, filepath.Join(chroot, initDeviceName))
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}

		// write the firecracker config to a file
		fcConfigPath := filepath.Join(chroot, "firecracker.json")

		if err := firecracker.WriteConfig(fcConfigPath, fcConfig); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}

		if err := os.Chown(fcConfigPath, firecracker.DefaultJailerUID, firecracker.DefaultJailerGID); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}

		// create kiln config
		kilnConfig, err := kilnConfig(id, chroot, kiln.Resources{
			CPUKind:  req.CPUKind,
			CPUCount: req.CPUCount,
			MemoryMB: req.MemoryMB,
		})
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}

		// write the kiln config to a file
		if err := kiln.WriteConfig(filepath.Join(chroot, "kiln.json"), kilnConfig); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}

		vm := vm.New(id, &vm.Config{
			Image:       img,
			Kiln:        kilnConfig,
			Firecracker: fcConfig,
		})

		if err := vm.Start(ctx); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		if err := json.NewEncoder(w).Encode(map[string]string{"id": id}); err != nil {
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
				GuestCID: 3,
				VsockID:  "control",
				UDSPath:  "control.sock",
			},
		},
	}
	return fcConfig, nil
}

func kilnConfig(id, chroot string, resources kiln.Resources) (*kiln.Config, error) {
	return &kiln.Config{
		JailID:                id,
		ChrootPath:            chroot,
		UID:                   firecracker.DefaultJailerUID,
		GID:                   firecracker.DefaultJailerGID,
		NetNS:                 true,
		FirecrackerSocketPath: "/firecracker.sock",
		FirecrackerConfigPath: "firecracker.json",
		Resources:             resources,
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
