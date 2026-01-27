package kiln

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
)

// KeyRequestHandler proxies encryption key requests from guest to KMS
// The guest requests a key by device path (/dev/vdb), and we look up the
// corresponding volume_id from the config.Volumes mapping, then forward
// the request to the KMS service.
func KeyRequestHandler(cfg *Config) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		// Extract device parameter from query string
		device := r.URL.Query().Get("device")
		if device == "" {
			slog.Error("key request missing device parameter")
			http.Error(w, "missing device parameter", http.StatusBadRequest)
			return
		}

		// Look up volume_id from device mapping
		volumeID, ok := cfg.Volumes[device]
		if !ok {
			slog.Error("device not found in volume mapping",
				"device", device,
				"available_devices", cfg.Volumes)
			http.Error(w, fmt.Sprintf("device %s not found in volumes mapping", device), http.StatusNotFound)
			return
		}

		slog.Info("proxying key request",
			"device", device,
			"volume_id", volumeID)

		// Check if KMS socket is configured
		if cfg.KMSSocket == "" {
			slog.Error("KMS socket not configured")
			http.Error(w, "KMS socket not configured", http.StatusInternalServerError)
			return
		}

		// Build KMS request path
		kmsPath := fmt.Sprintf("/v1/secret/data/inferno/volumes/%s/encryption-key", volumeID)

		// Create HTTP client that connects to KMS via unix socket
		kmsClient := &http.Client{
			Transport: &http.Transport{
				DialContext: func(_ context.Context, _, _ string) (net.Conn, error) {
					return net.Dial("unix", cfg.KMSSocket)
				},
			},
		}

		// Forward GET request to KMS
		kmsReq, err := http.NewRequestWithContext(r.Context(), "GET", "http://unix"+kmsPath, nil)
		if err != nil {
			slog.Error("failed to create KMS request",
				"volume_id", volumeID,
				"error", err)
			http.Error(w, fmt.Sprintf("failed to create KMS request: %v", err), http.StatusInternalServerError)
			return
		}

		kmsResp, err := kmsClient.Do(kmsReq)
		if err != nil {
			slog.Error("KMS request failed",
				"volume_id", volumeID,
				"error", err)
			http.Error(w, fmt.Sprintf("KMS request failed: %v", err), http.StatusInternalServerError)
			return
		}
		defer kmsResp.Body.Close()

		slog.Info("key request proxied successfully",
			"device", device,
			"volume_id", volumeID,
			"status", kmsResp.StatusCode)

		// Forward KMS response to guest
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(kmsResp.StatusCode)
		if _, err := io.Copy(w, kmsResp.Body); err != nil {
			slog.Error("failed to copy KMS response to guest", "error", err)
		}
	}
}
