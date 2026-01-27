package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/rugwirobaker/inferno/internal/kms"

	"github.com/oklog/ulid/v2"
)

// handleSecretData handles requests to /v1/secret/data/*
func (s *Server) handleSecretData(w http.ResponseWriter, r *http.Request) {
	// Extract path: /v1/secret/data/inferno/volumes/vol_xxx/encryption-key
	// → path = inferno/volumes/vol_xxx/encryption-key
	path := strings.TrimPrefix(r.URL.Path, "/v1/secret/data/")
	ctx := r.Context()

	switch r.Method {
	case http.MethodGet:
		s.handleGet(w, r, ctx, path)
	case http.MethodPost, http.MethodPut:
		s.handlePut(w, r, ctx, path)
	case http.MethodDelete:
		s.handleDelete(w, r, ctx, path)
	default:
		s.respondError(w, http.StatusMethodNotAllowed, "Method not allowed")
	}
}

// handleGet retrieves a secret
func (s *Server) handleGet(w http.ResponseWriter, r *http.Request, ctx context.Context, path string) {
	requestID := generateRequestID()

	s.logger.Info("Get secret request",
		"path", path,
		"request_id", requestID,
	)

	secret, err := s.backend.Get(ctx, path)
	if err == kms.ErrNotFound {
		s.logger.Debug("Secret not found", "path", path, "request_id", requestID)
		s.respondError(w, http.StatusNotFound, "Secret not found")
		return
	}
	if err != nil {
		s.logger.Error("Backend error", "error", err, "path", path, "request_id", requestID)
		s.respondError(w, http.StatusInternalServerError, "Internal error")
		return
	}

	resp := VaultResponse{
		RequestID:     requestID,
		LeaseID:       "",
		Renewable:     false,
		LeaseDuration: 0,
		Data: SecretDataResponse{
			Data:     secret.Data,
			Metadata: secret.Metadata,
		},
		WrapInfo: nil,
		Warnings: nil,
		Auth:     nil,
	}

	s.logger.Info("Secret retrieved",
		"path", path,
		"request_id", requestID,
		"version", secret.Metadata.Version,
	)

	s.respondJSON(w, http.StatusOK, resp)
}

// handlePut stores a secret
func (s *Server) handlePut(w http.ResponseWriter, r *http.Request, ctx context.Context, path string) {
	requestID := generateRequestID()

	s.logger.Info("Put secret request", "path", path, "request_id", requestID)

	var req PutSecretRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		s.logger.Warn("Invalid JSON", "error", err, "request_id", requestID)
		s.respondError(w, http.StatusBadRequest, "Invalid JSON")
		return
	}

	if req.Data == nil {
		s.logger.Warn("Missing data field", "request_id", requestID)
		s.respondError(w, http.StatusBadRequest, "Missing 'data' field")
		return
	}

	metadata, err := s.backend.Put(ctx, path, req.Data)
	if err != nil {
		s.logger.Error("Backend error", "error", err, "path", path, "request_id", requestID)
		s.respondError(w, http.StatusInternalServerError, "Failed to store secret")
		return
	}

	resp := VaultResponse{
		RequestID: requestID,
		Data:      metadata,
	}

	s.logger.Info("Secret stored",
		"path", path,
		"request_id", requestID,
		"version", metadata.Version,
	)

	s.respondJSON(w, http.StatusOK, resp)
}

// handleDelete removes a secret
func (s *Server) handleDelete(w http.ResponseWriter, r *http.Request, ctx context.Context, path string) {
	requestID := generateRequestID()

	s.logger.Info("Delete secret request", "path", path, "request_id", requestID)

	err := s.backend.Delete(ctx, path)
	if err == kms.ErrNotFound {
		s.logger.Debug("Secret not found for deletion", "path", path, "request_id", requestID)
		s.respondError(w, http.StatusNotFound, "Secret not found")
		return
	}
	if err != nil {
		s.logger.Error("Backend error", "error", err, "path", path, "request_id", requestID)
		s.respondError(w, http.StatusInternalServerError, "Failed to delete secret")
		return
	}

	s.logger.Info("Secret deleted", "path", path, "request_id", requestID)
	w.WriteHeader(http.StatusNoContent)
}

// handleSecretMetadata handles requests to /v1/secret/metadata/*
func (s *Server) handleSecretMetadata(w http.ResponseWriter, r *http.Request) {
	path := strings.TrimPrefix(r.URL.Path, "/v1/secret/metadata/")
	ctx := r.Context()
	requestID := generateRequestID()

	switch r.Method {
	case http.MethodGet:
		s.handleGetMetadata(w, ctx, path, requestID)
	case "LIST":
		s.handleList(w, ctx, path, requestID)
	default:
		s.respondError(w, http.StatusMethodNotAllowed, "Method not allowed")
	}
}

// handleGetMetadata retrieves metadata without secret data
func (s *Server) handleGetMetadata(w http.ResponseWriter, ctx context.Context, path string, requestID string) {
	s.logger.Info("Get metadata request", "path", path, "request_id", requestID)

	metadata, err := s.backend.GetMetadata(ctx, path)
	if err == kms.ErrNotFound {
		s.logger.Debug("Secret not found", "path", path, "request_id", requestID)
		s.respondError(w, http.StatusNotFound, "Secret not found")
		return
	}
	if err != nil {
		s.logger.Error("Backend error", "error", err, "path", path, "request_id", requestID)
		s.respondError(w, http.StatusInternalServerError, "Internal error")
		return
	}

	data := MetadataResponse{
		CreatedTime:    metadata.CreatedTime.Format(time.RFC3339Nano),
		CurrentVersion: metadata.Version,
		CustomMetadata: metadata.CustomMetadata,
		DeletionTime:   metadata.DeletionTime,
		Destroyed:      metadata.Destroyed,
		Versions: map[string]VersionInfo{
			fmt.Sprintf("%d", metadata.Version): {
				CreatedTime:  metadata.CreatedTime.Format(time.RFC3339Nano),
				DeletionTime: metadata.DeletionTime,
				Destroyed:    metadata.Destroyed,
			},
		},
	}

	resp := VaultResponse{
		RequestID: requestID,
		Data:      data,
	}

	s.logger.Info("Metadata retrieved", "path", path, "request_id", requestID)
	s.respondJSON(w, http.StatusOK, resp)
}

// handleList lists keys at a path
func (s *Server) handleList(w http.ResponseWriter, ctx context.Context, path string, requestID string) {
	s.logger.Info("List request", "path", path, "request_id", requestID)

	keys, err := s.backend.List(ctx, path)
	if err != nil {
		s.logger.Error("Backend error", "error", err, "path", path, "request_id", requestID)
		s.respondError(w, http.StatusInternalServerError, "Internal error")
		return
	}

	data := ListResponse{
		Keys: keys,
	}

	resp := VaultResponse{
		RequestID: requestID,
		Data:      data,
	}

	s.logger.Info("List complete", "path", path, "count", len(keys), "request_id", requestID)
	s.respondJSON(w, http.StatusOK, resp)
}

// handleHealth returns service health status
func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	resp := HealthResponse{
		Initialized:                true,
		Sealed:                     false,
		Standby:                    false,
		PerformanceStandby:         false,
		ReplicationPerformanceMode: "disabled",
		ReplicationDRMode:          "disabled",
		ServerTimeUTC:              time.Now().Unix(),
		Version:                    "kms-0.1.0",
		ClusterName:                "inferno",
		ClusterID:                  "",
	}

	s.respondJSON(w, http.StatusOK, resp)
}

// handleSealStatus returns seal status
func (s *Server) handleSealStatus(w http.ResponseWriter, r *http.Request) {
	resp := SealStatusResponse{
		Type:         "sqlite",
		Initialized:  true,
		Sealed:       false,
		T:            0,
		N:            0,
		Progress:     0,
		Nonce:        "",
		Version:      "kms-0.1.0",
		Migration:    false,
		RecoverySeal: false,
		StorageType:  "sqlite",
	}

	s.respondJSON(w, http.StatusOK, resp)
}

// Helper functions

// generateRequestID creates a unique request ID using ULID
func generateRequestID() string {
	return ulid.Make().String()
}

// respondJSON sends a JSON response
func (s *Server) respondJSON(w http.ResponseWriter, status int, data any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(data); err != nil {
		s.logger.Error("Failed to encode JSON response", "error", err)
	}
}

// respondError sends a Vault-format error response
func (s *Server) respondError(w http.ResponseWriter, status int, message string) {
	resp := ErrorResponse{
		Errors: []string{message},
	}
	s.respondJSON(w, status, resp)
}
