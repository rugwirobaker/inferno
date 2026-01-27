package main

import (
	"context"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/rugwirobaker/inferno/internal/kms"
	"github.com/rugwirobaker/inferno/internal/kms/sqlite"
)

// Server is the main KMS HTTP server
type Server struct {
	backend  kms.Backend
	listener net.Listener
	logger   *slog.Logger
	metrics  *Metrics
}

func main() {
	// Setup structured logging
	logLevel := slog.LevelInfo
	if os.Getenv("KMS_LOG_LEVEL") == "debug" {
		logLevel = slog.LevelDebug
	}

	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: logLevel,
	}))

	// Get configuration from environment
	dbPath := os.Getenv("KMS_DB_PATH")
	if dbPath == "" {
		// Default to user's local data directory
		dbPath = os.ExpandEnv("$HOME/.local/share/kms/kms.db")
	}

	socketPath := os.Getenv("KMS_SOCKET_PATH")
	if socketPath == "" {
		// Default to user's local runtime directory
		socketPath = os.ExpandEnv("$HOME/.local/share/kms/kms.sock")
	}

	logger.Info("Starting KMS service",
		"db_path", dbPath,
		"socket_path", socketPath,
	)

	// Ensure directories exist
	if err := os.MkdirAll(os.ExpandEnv("$HOME/.local/share/kms"), 0755); err != nil {
		logger.Error("Failed to create KMS data directory", "error", err)
		os.Exit(1)
	}

	// Initialize backend
	backend, err := sqlite.New(dbPath, logger)
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
	os.Remove(socketPath)
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		logger.Error("Failed to create socket", "error", err)
		os.Exit(1)
	}
	defer listener.Close()

	// Set permissions (group readable/writable)
	if err := os.Chmod(socketPath, 0660); err != nil {
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
		logger.Info("KMS service listening", "socket", socketPath)
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

	logger.Info("KMS service stopped")
}
