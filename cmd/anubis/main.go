package main

import (
	"context"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"syscall"
	"time"

	"github.com/BurntSushi/toml"
	"github.com/rugwirobaker/inferno/internal/kms"
	"github.com/rugwirobaker/inferno/internal/kms/sqlite"
)

// Config represents the Anubis configuration
type Config struct {
	DB struct {
		Path string `toml:"path"`
	} `toml:"db"`

	Socket struct {
		Path string `toml:"path"`
		Mode string `toml:"mode"`
	} `toml:"socket"`

	Log struct {
		Level string `toml:"level"`
	} `toml:"log"`
}

// loadConfig loads configuration with the following priority:
// 1. Environment variables (highest)
// 2. TOML config file
// 3. Built-in defaults (lowest)
func loadConfig() Config {
	cfg := Config{}

	// Set built-in defaults
	cfg.DB.Path = "/var/lib/anubis/anubis.db"
	cfg.Socket.Path = "/var/lib/anubis/anubis.sock"
	cfg.Socket.Mode = "0660"
	cfg.Log.Level = "info"

	// Load from TOML file (if exists)
	if _, err := toml.DecodeFile("/etc/anubis/config.toml", &cfg); err != nil {
		// Config file doesn't exist or can't be read - that's okay, use defaults
	}

	// Override with environment variables
	if dbPath := os.Getenv("ANUBIS_DB_PATH"); dbPath != "" {
		cfg.DB.Path = dbPath
	}
	if socketPath := os.Getenv("ANUBIS_SOCKET_PATH"); socketPath != "" {
		cfg.Socket.Path = socketPath
	}
	if logLevel := os.Getenv("ANUBIS_LOG_LEVEL"); logLevel != "" {
		cfg.Log.Level = logLevel
	}

	return cfg
}

// Server is the main Anubis HTTP server
type Server struct {
	backend  kms.Backend
	listener net.Listener
	logger   *slog.Logger
	metrics  *Metrics
}

func main() {
	// Load configuration
	cfg := loadConfig()

	// Setup structured logging
	logLevel := slog.LevelInfo
	switch cfg.Log.Level {
	case "debug":
		logLevel = slog.LevelDebug
	case "warn":
		logLevel = slog.LevelWarn
	case "error":
		logLevel = slog.LevelError
	}

	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: logLevel,
	}))

	logger.Info("Starting Anubis (KMS) service",
		"db_path", cfg.DB.Path,
		"socket_path", cfg.Socket.Path,
	)

	// Ensure database directory exists
	dbDir := filepath.Dir(cfg.DB.Path)
	if err := os.MkdirAll(dbDir, 0750); err != nil {
		logger.Error("Failed to create database directory", "error", err, "dir", dbDir)
		os.Exit(1)
	}

	// Initialize backend
	backend, err := sqlite.New(cfg.DB.Path, logger)
	if err != nil {
		logger.Error("Failed to initialize backend", "error", err)
		os.Exit(1)
	}
	defer backend.Close()

	// Create server
	srv := &Server{
		backend: backend,
		logger:  logger,
		metrics: NewMetrics(),
	}

	// Setup unix socket
	os.Remove(cfg.Socket.Path)
	listener, err := net.Listen("unix", cfg.Socket.Path)
	if err != nil {
		logger.Error("Failed to create socket", "error", err)
		os.Exit(1)
	}
	defer listener.Close()

	// Set permissions from config
	mode, err := strconv.ParseUint(cfg.Socket.Mode, 8, 32)
	if err != nil {
		logger.Error("Invalid socket mode in config", "mode", cfg.Socket.Mode, "error", err)
		os.Exit(1)
	}
	if err := os.Chmod(cfg.Socket.Path, os.FileMode(mode)); err != nil {
		logger.Error("Failed to set socket permissions", "error", err)
		os.Exit(1)
	}

	srv.listener = listener

	// Setup HTTP router
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/secret/data/", srv.handleSecretData)
	mux.HandleFunc("/v1/secret/metadata/", srv.handleSecretMetadata)
	mux.HandleFunc("/v1/sys/health", srv.handleHealth)
	mux.HandleFunc("/v1/sys/seal-status", srv.handleSealStatus)
	mux.Handle("/v1/sys/metrics", srv.metrics.Handler())

	// Add middleware
	handler := srv.loggingMiddleware(srv.metricsMiddleware(mux))

	// Start server
	httpServer := &http.Server{
		Handler:      handler,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 10 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	// Start server in background
	go func() {
		logger.Info("Anubis service listening", "socket", cfg.Socket.Path)
		if err := httpServer.Serve(listener); err != http.ErrServerClosed {
			logger.Error("Server error", "error", err)
			os.Exit(1)
		}
	}()

	// Wait for interrupt signal
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, os.Interrupt, syscall.SIGTERM)
	<-sigChan

	logger.Info("Shutting down...")

	// Graceful shutdown with timeout
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if err := httpServer.Shutdown(ctx); err != nil {
		logger.Error("Shutdown error", "error", err)
	}

	logger.Info("Anubis service stopped")
}
