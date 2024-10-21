package server

import (
	"bytes"
	"encoding/json"
	"log/slog"
	"net/http"
	"path/filepath"

	"github.com/rugwirobaker/inferno/internal/config"
	"github.com/rugwirobaker/inferno/internal/vsock"
)

type StopRequest struct {
	ID     string `json:"id"`
	Signal int32  `json:"signal"`
}

func Stop(cfg *config.Config) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var ctx = r.Context()

		var req StopRequest

		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			slog.Error("failed to decode request", "error", err)
			http.Error(w, "failed to decode request", http.StatusBadRequest)
			return
		}

		var chroot = filepath.Join(cfg.StateBaseDir, "vms", req.ID)

		client := vsock.NewGuestClient(chroot, vsock.VsockSignalPort)

		signal := signalVm{
			Signal: req.Signal,
		}

		buf := new(bytes.Buffer)

		_ = json.NewEncoder(buf).Encode(signal)

		stopReq, err := http.NewRequestWithContext(ctx, http.MethodPost, "http://firecracker/signal", buf)
		if err != nil {
			slog.Error("failed to create request", "error", err)
			http.Error(w, "failed to create request", http.StatusInternalServerError)
			return
		}
		stopReq.Header.Set("Content-Type", "application/json")

		resp, err := client.Do(stopReq)
		if err != nil {
			slog.Error("failed to send signal", "error", err)
			http.Error(w, "failed to send signal", http.StatusInternalServerError)
			return
		}

		if resp.StatusCode != http.StatusOK {
			slog.Error("failed to send signal", "status", resp.Status)
			http.Error(w, "failed to send signal", http.StatusInternalServerError)
			return
		}
		w.WriteHeader(http.StatusOK)
	}
}

type signalVm struct {
	Signal int32 `json:"signal"`
}
