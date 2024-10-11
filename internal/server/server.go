package server

import (
	"log/slog"
	"net"
	"net/http"
	"sync"

	"github.com/rugwirobaker/inferno/internal/config"
	"github.com/rugwirobaker/inferno/internal/image"
)

var LogLevel struct {
	sync.Mutex
	slog.LevelVar
}

type Server struct {
	handler http.Handler
	ls      net.Listener
	cfg     *config.Config
}

func New(listener net.Listener, cfg *config.Config, images *image.Manager) *Server {
	mux := http.NewServeMux()

	mux.HandleFunc("/run", Run(cfg, images))
	mux.HandleFunc("/stop", Stop(cfg))

	return &Server{
		handler: mux,
		ls:      listener,
		cfg:     cfg,
	}
}

func (s *Server) Run() error {
	return http.Serve(s.ls, s.handler)
}
