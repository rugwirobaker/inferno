package server

import (
	"net/http"

	"github.com/rugwirobaker/inferno/internal/config"
)

func Stop(cfg *config.Config) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("OK"))
	}
}
