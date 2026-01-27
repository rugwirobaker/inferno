-- +migrate Up
-- Initial KMS secrets storage schema

CREATE TABLE IF NOT EXISTS secrets (
    path TEXT PRIMARY KEY,              -- Full path to the secret (e.g., inferno/volumes/vol_xxx/encryption-key)
    data TEXT NOT NULL,                 -- JSON-encoded secret data
    created_time TEXT NOT NULL,         -- ISO 8601 timestamp
    version INTEGER NOT NULL DEFAULT 1, -- Secret version (simplified - always 1 for now)
    destroyed INTEGER NOT NULL DEFAULT 0, -- Boolean: 1 if destroyed, 0 otherwise
    deletion_time TEXT DEFAULT '',      -- ISO 8601 timestamp when deleted (empty if not deleted)
    custom_metadata TEXT DEFAULT '{}'   -- JSON-encoded custom metadata
);

-- Index for faster lookups
CREATE INDEX IF NOT EXISTS idx_secrets_path ON secrets(path);

-- Index for querying by creation time
CREATE INDEX IF NOT EXISTS idx_secrets_created ON secrets(created_time);

-- Index for listing operations (paths with common prefixes)
CREATE INDEX IF NOT EXISTS idx_secrets_prefix ON secrets(path);

-- +migrate Down
DROP INDEX IF EXISTS idx_secrets_prefix;
DROP INDEX IF EXISTS idx_secrets_created;
DROP INDEX IF EXISTS idx_secrets_path;
DROP TABLE IF EXISTS secrets;
