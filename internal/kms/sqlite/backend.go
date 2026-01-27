// Package sqlite provides a SQLite-backed implementation of the KMS Backend interface.
package sqlite

import (
	"context"
	"database/sql"
	"embed"
	"encoding/json"
	"fmt"
	"log/slog"
	"time"

	"github.com/rugwirobaker/inferno/internal/kms"

	_ "github.com/mattn/go-sqlite3"
	"github.com/rubenv/sql-migrate"
)

//go:embed migrations/*.sql
var migrationsFS embed.FS

// Backend implements kms.Backend using SQLite
type Backend struct {
	db     *sql.DB
	logger *slog.Logger
}

// New creates a new SQLite backend and runs migrations
func New(dbPath string, logger *slog.Logger) (*Backend, error) {
	db, err := sql.Open("sqlite3", dbPath)
	if err != nil {
		return nil, fmt.Errorf("failed to open database: %w", err)
	}

	// Enable WAL mode for better concurrency
	if _, err := db.Exec("PRAGMA journal_mode=WAL"); err != nil {
		db.Close()
		return nil, fmt.Errorf("failed to enable WAL mode: %w", err)
	}

	backend := &Backend{
		db:     db,
		logger: logger,
	}

	// Run migrations
	if err := backend.runMigrations(); err != nil {
		db.Close()
		return nil, fmt.Errorf("failed to run migrations: %w", err)
	}

	logger.Info("SQLite backend initialized", "db_path", dbPath)

	return backend, nil
}

// runMigrations applies all pending migrations
func (b *Backend) runMigrations() error {
	migrations := &migrate.EmbedFileSystemMigrationSource{
		FileSystem: migrationsFS,
		Root:       "migrations",
	}

	n, err := migrate.Exec(b.db, "sqlite3", migrations, migrate.Up)
	if err != nil {
		return err
	}

	if n > 0 {
		b.logger.Info("Applied migrations", "count", n)
	} else {
		b.logger.Debug("No new migrations to apply")
	}

	return nil
}

// Get retrieves a secret by path
func (b *Backend) Get(ctx context.Context, path string) (*kms.Secret, error) {
	b.logger.Debug("Backend get", "path", path)

	var dataJSON string
	var createdTimeStr string
	var version int
	var destroyed int
	var deletionTime string
	var customMetadataJSON string

	err := b.db.QueryRowContext(ctx, `
		SELECT data, created_time, version, destroyed, deletion_time, custom_metadata
		FROM secrets WHERE path = ?
	`, path).Scan(&dataJSON, &createdTimeStr, &version, &destroyed, &deletionTime, &customMetadataJSON)

	if err == sql.ErrNoRows {
		b.logger.Debug("Secret not found", "path", path)
		return nil, kms.ErrNotFound
	}
	if err != nil {
		b.logger.Error("Database error", "error", err, "path", path)
		return nil, err
	}

	// Check context cancellation
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}

	// Parse created time
	createdTime, err := time.Parse(time.RFC3339Nano, createdTimeStr)
	if err != nil {
		b.logger.Error("Failed to parse created_time", "error", err, "path", path)
		return nil, err
	}

	// Parse JSON data
	var data map[string]any
	if err := json.Unmarshal([]byte(dataJSON), &data); err != nil {
		b.logger.Error("Failed to unmarshal secret data", "error", err, "path", path)
		return nil, err
	}

	// Parse custom metadata
	var customMetadata map[string]any
	if customMetadataJSON != "" && customMetadataJSON != "{}" {
		if err := json.Unmarshal([]byte(customMetadataJSON), &customMetadata); err != nil {
			b.logger.Error("Failed to unmarshal custom metadata", "error", err, "path", path)
			return nil, err
		}
	}

	b.logger.Debug("Secret retrieved", "path", path, "version", version)

	return &kms.Secret{
		Data: data,
		Metadata: kms.SecretMetadata{
			CreatedTime:    createdTime,
			CustomMetadata: customMetadata,
			DeletionTime:   deletionTime,
			Destroyed:      destroyed == 1,
			Version:        version,
		},
	}, nil
}

// Put stores a secret at path
func (b *Backend) Put(ctx context.Context, path string, data map[string]any) (*kms.SecretMetadata, error) {
	b.logger.Debug("Backend put", "path", path)

	dataJSON, err := json.Marshal(data)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal data: %w", err)
	}

	now := time.Now().UTC()
	nowStr := now.Format(time.RFC3339Nano)

	// Upsert with context
	_, err = b.db.ExecContext(ctx, `
		INSERT INTO secrets (path, data, created_time, version)
		VALUES (?, ?, ?, 1)
		ON CONFLICT(path) DO UPDATE SET
			data = excluded.data,
			version = version + 1
	`, path, dataJSON, nowStr)

	if err != nil {
		b.logger.Error("Database error", "error", err, "path", path)
		return nil, err
	}

	// Check context cancellation
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}

	metadata := &kms.SecretMetadata{
		CreatedTime: now,
		Version:     1, // Simplified: always version 1 for demo
		Destroyed:   false,
	}

	b.logger.Info("Secret stored", "path", path, "version", metadata.Version)

	return metadata, nil
}

// Delete removes a secret at path
func (b *Backend) Delete(ctx context.Context, path string) error {
	b.logger.Debug("Backend delete", "path", path)

	result, err := b.db.ExecContext(ctx, "DELETE FROM secrets WHERE path = ?", path)
	if err != nil {
		b.logger.Error("Database error", "error", err, "path", path)
		return err
	}

	// Check context cancellation
	if ctx.Err() != nil {
		return ctx.Err()
	}

	rows, _ := result.RowsAffected()
	if rows == 0 {
		b.logger.Debug("Secret not found for deletion", "path", path)
		return kms.ErrNotFound
	}

	b.logger.Info("Secret deleted", "path", path)
	return nil
}

// List returns keys at path
func (b *Backend) List(ctx context.Context, path string) ([]string, error) {
	b.logger.Debug("Backend list", "path", path)

	// Ensure path ends with /
	if path != "" && path[len(path)-1] != '/' {
		path = path + "/"
	}

	// List paths that start with path prefix
	// Extract the next segment after the prefix
	rows, err := b.db.QueryContext(ctx, `
		SELECT DISTINCT
			CASE
				WHEN instr(substr(path, length(?) + 1), '/') > 0
				THEN substr(substr(path, length(?) + 1), 1, instr(substr(path, length(?) + 1), '/'))
				ELSE substr(path, length(?) + 1)
			END as key
		FROM secrets
		WHERE path LIKE ? || '%'
		AND path != ?
		ORDER BY key
	`, path, path, path, path, path, path)

	if err != nil {
		b.logger.Error("Database error", "error", err, "path", path)
		return nil, err
	}
	defer rows.Close()

	var keys []string
	for rows.Next() {
		// Check context cancellation
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}

		var key string
		if err := rows.Scan(&key); err != nil {
			b.logger.Error("Failed to scan row", "error", err)
			return nil, err
		}
		if key != "" {
			keys = append(keys, key)
		}
	}

	b.logger.Debug("Listed secrets", "path", path, "count", len(keys))
	return keys, nil
}

// GetMetadata retrieves metadata without secret data
func (b *Backend) GetMetadata(ctx context.Context, path string) (*kms.SecretMetadata, error) {
	b.logger.Debug("Backend get metadata", "path", path)

	var createdTimeStr string
	var version int
	var destroyed int
	var deletionTime string
	var customMetadataJSON string

	err := b.db.QueryRowContext(ctx, `
		SELECT created_time, version, destroyed, deletion_time, custom_metadata
		FROM secrets WHERE path = ?
	`, path).Scan(&createdTimeStr, &version, &destroyed, &deletionTime, &customMetadataJSON)

	if err == sql.ErrNoRows {
		b.logger.Debug("Secret not found", "path", path)
		return nil, kms.ErrNotFound
	}
	if err != nil {
		b.logger.Error("Database error", "error", err, "path", path)
		return nil, err
	}

	// Check context cancellation
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}

	// Parse created time
	createdTime, err := time.Parse(time.RFC3339Nano, createdTimeStr)
	if err != nil {
		b.logger.Error("Failed to parse created_time", "error", err, "path", path)
		return nil, err
	}

	// Parse custom metadata
	var customMetadata map[string]any
	if customMetadataJSON != "" && customMetadataJSON != "{}" {
		if err := json.Unmarshal([]byte(customMetadataJSON), &customMetadata); err != nil {
			b.logger.Error("Failed to unmarshal custom metadata", "error", err, "path", path)
			return nil, err
		}
	}

	b.logger.Debug("Metadata retrieved", "path", path)

	return &kms.SecretMetadata{
		CreatedTime:    createdTime,
		CustomMetadata: customMetadata,
		DeletionTime:   deletionTime,
		Destroyed:      destroyed == 1,
		Version:        version,
	}, nil
}

// Close cleans up backend resources
func (b *Backend) Close() error {
	b.logger.Info("Closing SQLite backend")
	return b.db.Close()
}
