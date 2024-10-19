package main

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"syscall"
)

type KillSignal struct {
	Signal uint32 `json:"signal"`
}

type ErrorResponse struct {
	Error string `json:"error"`
}

func KillHandler(killChan chan syscall.Signal) http.Handler {
	fn := func(w http.ResponseWriter, r *http.Request) {
		var ks KillSignal
		if err := json.NewDecoder(r.Body).Decode(&ks); err != nil {
			slog.Error("Failed to decode kill signal", "error", err)

			// respond with json error
			w.Header().Set("Content-Type", "application/json")

			w.WriteHeader(http.StatusBadRequest)
			_ = json.NewEncoder(w).Encode(ErrorResponse{Error: "Failed to decode kill signal"})
			return
		}
		slog.Info("Received kill signal", "signal", ks.Signal)

		// validate the signal via syscall.Signal
		sig := syscall.Signal(ks.Signal)
		switch sig {
		case syscall.SIGTERM, syscall.SIGINT:
			break
		default:
			slog.Error("Invalid signal", "signal", ks.Signal)
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusBadRequest)
			_ = json.NewEncoder(w).Encode(ErrorResponse{Error: "Invalid signal"})
			return
		}
		killChan <- sig

		// respond with just OK but json
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)

		w.Write([]byte(`{"status": "ok"}`))
	}
	return http.HandlerFunc(fn)
}
