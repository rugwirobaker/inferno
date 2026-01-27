package main

import "github.com/rugwirobaker/inferno/internal/kms"

// Vault-compatible request/response types

// PutSecretRequest is the request body for storing a secret
type PutSecretRequest struct {
	Data map[string]any `json:"data"`
}

// VaultResponse is the standard Vault API response wrapper
type VaultResponse struct {
	RequestID     string `json:"request_id"`
	LeaseID       string `json:"lease_id"`
	Renewable     bool   `json:"renewable"`
	LeaseDuration int    `json:"lease_duration"`
	Data          any    `json:"data"`
	WrapInfo      any    `json:"wrap_info"`
	Warnings      any    `json:"warnings"`
	Auth          any    `json:"auth"`
}

// SecretDataResponse is the data field for secret retrieval
type SecretDataResponse struct {
	Data     map[string]any     `json:"data"`
	Metadata kms.SecretMetadata `json:"metadata"`
}

// MetadataResponse is the response for metadata endpoints
type MetadataResponse struct {
	CreatedTime    string         `json:"created_time"`
	CurrentVersion int            `json:"current_version"`
	CustomMetadata map[string]any `json:"custom_metadata"`
	DeletionTime   string         `json:"deletion_time"`
	Destroyed      bool           `json:"destroyed"`
	Versions       map[string]VersionInfo `json:"versions"`
}

// VersionInfo contains version-specific metadata
type VersionInfo struct {
	CreatedTime  string `json:"created_time"`
	DeletionTime string `json:"deletion_time"`
	Destroyed    bool   `json:"destroyed"`
}

// ListResponse is the response for LIST operations
type ListResponse struct {
	Keys []string `json:"keys"`
}

// HealthResponse is the response for /v1/sys/health
type HealthResponse struct {
	Initialized                bool   `json:"initialized"`
	Sealed                     bool   `json:"sealed"`
	Standby                    bool   `json:"standby"`
	PerformanceStandby         bool   `json:"performance_standby"`
	ReplicationPerformanceMode string `json:"replication_performance_mode"`
	ReplicationDRMode          string `json:"replication_dr_mode"`
	ServerTimeUTC              int64  `json:"server_time_utc"`
	Version                    string `json:"version"`
	ClusterName                string `json:"cluster_name"`
	ClusterID                  string `json:"cluster_id"`
}

// SealStatusResponse is the response for /v1/sys/seal-status
type SealStatusResponse struct {
	Type         string `json:"type"`
	Initialized  bool   `json:"initialized"`
	Sealed       bool   `json:"sealed"`
	T            int    `json:"t"`
	N            int    `json:"n"`
	Progress     int    `json:"progress"`
	Nonce        string `json:"nonce"`
	Version      string `json:"version"`
	Migration    bool   `json:"migration"`
	RecoverySeal bool   `json:"recovery_seal"`
	StorageType  string `json:"storage_type"`
}

// ErrorResponse is the response for errors
type ErrorResponse struct {
	Errors []string `json:"errors"`
}
