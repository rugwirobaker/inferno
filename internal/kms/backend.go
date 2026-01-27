// Package kms provides the core interfaces and types for the Key Management Service.
package kms

import (
	"context"
	"errors"
	"time"
)

var (
	// ErrNotFound is returned when a secret is not found
	ErrNotFound = errors.New("secret not found")

	// ErrExists is returned when attempting to create a secret that already exists
	ErrExists = errors.New("secret already exists")
)

// Secret represents a stored secret with its data and metadata
type Secret struct {
	Data     map[string]any // Actual secret data (e.g., encryption key)
	Metadata SecretMetadata // Metadata about the secret
}

// SecretMetadata matches Vault's KV v2 metadata structure
type SecretMetadata struct {
	CreatedTime    time.Time      `json:"created_time"`
	CustomMetadata map[string]any `json:"custom_metadata"`
	DeletionTime   string         `json:"deletion_time"`
	Destroyed      bool           `json:"destroyed"`
	Version        int            `json:"version"`
}

// Backend is the storage interface for secrets.
// All methods accept context.Context for cancellation, timeouts, and tracing.
type Backend interface {
	// Get retrieves a secret by path
	Get(ctx context.Context, path string) (*Secret, error)

	// Put stores a secret at path
	// If the secret already exists, it should be updated with a new version
	Put(ctx context.Context, path string, data map[string]any) (*SecretMetadata, error)

	// Delete removes a secret at path
	Delete(ctx context.Context, path string) error

	// List returns keys at path (directory-like listing)
	// Returns paths relative to the given path
	List(ctx context.Context, path string) ([]string, error)

	// GetMetadata retrieves metadata without secret data
	// Useful for checking if a secret exists or when it was created
	GetMetadata(ctx context.Context, path string) (*SecretMetadata, error)

	// Close cleans up backend resources
	Close() error
}
