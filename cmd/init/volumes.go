package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/rugwirobaker/inferno/internal/image"
	"github.com/rugwirobaker/inferno/internal/vsock"
)

// KMSKeyResponse represents the response from Anubis KMS
type KMSKeyResponse struct {
	Data struct {
		Data map[string]interface{} `json:"data"`
	} `json:"data"`
}

// unlockEncryptedVolumes unlocks all encrypted volumes by requesting keys from kiln via vsock
func unlockEncryptedVolumes(ctx context.Context, cfg *image.Config) error {
	for _, vol := range cfg.Mounts.Volumes {
		if !vol.Encrypted {
			continue
		}

		slog.Info("unlocking encrypted volume", "device", vol.Device)

		// Request key from kiln via vsock
		key, err := requestVolumeKey(ctx, cfg.VsockKeyPort, vol.Device)
		if err != nil {
			slog.Error("key request failed", "device", vol.Device, "error", err)
			return fmt.Errorf("failed to request key for %s: %w", vol.Device, err)
		}

		// Unlock LUKS volume
		mapperName := strings.TrimPrefix(vol.Device, "/dev/")
		mapperName = strings.ReplaceAll(mapperName, "/", "_") + "_crypt"
		if err := luksOpen(vol.Device, mapperName, key); err != nil {
			slog.Error("LUKS unlock failed", "device", vol.Device, "error", err)
			return fmt.Errorf("failed to unlock LUKS volume %s: %w", vol.Device, err)
		}

		// Note: key is cleared within luksOpen after use

		slog.Info("volume unlocked successfully", "device", vol.Device, "mapper", mapperName)
	}

	return nil
}

// requestVolumeKey requests the encryption key for a device from kiln via vsock
func requestVolumeKey(ctx context.Context, port int, device string) (string, error) {
	conn, err := vsock.NewVsockConn(uint32(port))
	if err != nil {
		return "", fmt.Errorf("vsock connection failed: %w", err)
	}
	defer conn.Close()

	client := &http.Client{
		Transport: &http.Transport{
			DialContext: func(_ context.Context, _, _ string) (net.Conn, error) {
				return conn, nil
			},
		},
		Timeout: 10 * time.Second,
	}

	url := fmt.Sprintf("http://host/v1/volume/key?device=%s", device)
	slog.Debug("requesting volume key", "url", url, "device", device)

	resp, err := client.Get(url)
	if err != nil {
		return "", fmt.Errorf("HTTP request failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		body, _ := io.ReadAll(resp.Body)
		return "", fmt.Errorf("KMS returned %d: %s", resp.StatusCode, body)
	}

	var kmsResp KMSKeyResponse
	if err := json.NewDecoder(resp.Body).Decode(&kmsResp); err != nil {
		return "", fmt.Errorf("JSON decode failed: %w", err)
	}

	key, ok := kmsResp.Data.Data["key"].(string)
	if !ok {
		return "", fmt.Errorf("key field missing or invalid in response")
	}

	return key, nil
}

// luksOpen opens a LUKS-encrypted device using cryptsetup
func luksOpen(device, mapperName, keyBase64 string) error {
	// Decode the base64 key
	keyBytes, err := base64.StdEncoding.DecodeString(keyBase64)
	if err != nil {
		return fmt.Errorf("failed to decode key: %w", err)
	}

	// Ensure key is zeroed after use
	defer func() {
		for i := range keyBytes {
			keyBytes[i] = 0
		}
	}()

	// Create the cryptsetup command (use absolute path to ensure we find it)
	// Try multiple common paths (initramfs first, then container paths)
	cryptsetupPath := "/inferno/sbin/cryptsetup"
	if _, err := os.Stat(cryptsetupPath); err != nil {
		if _, err := os.Stat("/usr/sbin/cryptsetup"); err == nil {
			cryptsetupPath = "/usr/sbin/cryptsetup"
		} else if _, err := os.Stat("/sbin/cryptsetup"); err == nil {
			cryptsetupPath = "/sbin/cryptsetup"
		}
	}

	cmd := exec.Command(cryptsetupPath, "open", "--key-file=-", device, mapperName)
	cmd.Stdin = strings.NewReader(string(keyBytes))

	// Set LD_LIBRARY_PATH for bundled libraries in initramfs
	// If cryptsetup is from initramfs, it needs our bundled libs
	if strings.HasPrefix(cryptsetupPath, "/inferno/") {
		env := os.Environ()
		env = append(env, "LD_LIBRARY_PATH=/lib:/lib64:/usr/lib:/usr/lib64")
		cmd.Env = env
	}

	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("cryptsetup failed: %w (output: %s)", err, output)
	}

	slog.Debug("cryptsetup completed successfully", "device", device, "mapper", mapperName)
	return nil
}
