package main

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"syscall"
)

type API struct {
	signalChan chan syscall.Signal
}

func NewAPI(signalChan chan syscall.Signal) *API {
	return &API{signalChan: signalChan}
}

func (a *API) Handler() http.Handler {
	v1 := http.NewServeMux()
	v1.HandleFunc("/status", statusHandler)
	v1.Handle("/signal", signalHandler(a.signalChan))
	v1.Handle("/v1/", http.StripPrefix("/v1", v1))
	return v1
}

type KillSignal struct {
	Signal uint32 `json:"signal"`
}

type ErrorResponse struct {
	Error string `json:"error"`
}

func statusHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	w.Write([]byte(`{"status": "ok"}`))
}

func signalHandler(killChan chan syscall.Signal) http.Handler {
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
