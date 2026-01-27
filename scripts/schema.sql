-- Description: This script creates the schema for the database
CREATE TABLE IF NOT EXISTS vms (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT UNIQUE NOT NULL,
    tap_device TEXT UNIQUE NOT NULL,
    gateway_ip TEXT NOT NULL,
    guest_ip TEXT UNIQUE NOT NULL,
    mac_address TEXT UNIQUE NOT NULL,
    state TEXT NOT NULL DEFAULT 'created' CHECK (state IN ('created', 'running', 'stopped')),
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- Add routes table
CREATE TABLE IF NOT EXISTS routes (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    vm_id INTEGER NOT NULL,
    mode TEXT NOT NULL CHECK (mode IN ('l4', 'l7')),
    host_port INTEGER NOT NULL,
    guest_port INTEGER NOT NULL,
    hostname TEXT,
    public_ip TEXT,
    active BOOLEAN DEFAULT TRUE,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (vm_id) REFERENCES vms(id)
);

-- Add network state table
CREATE TABLE IF NOT EXISTS network_state (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    vm_id INTEGER NOT NULL,
    state TEXT NOT NULL CHECK (state IN ('created', 'exposed', 'deleted')),
    nft_rules_hash TEXT NOT NULL,
    config_files_hash TEXT NOT NULL,
    last_updated DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (vm_id) REFERENCES vms(id)
);

-- Add index for l7 routes
CREATE UNIQUE INDEX IF NOT EXISTS idx_l7_routes
ON routes(hostname, host_port)
WHERE mode = 'l7' AND active = TRUE AND hostname IS NOT NULL;

-- Add index for l4 routes
CREATE UNIQUE INDEX IF NOT EXISTS idx_l4_routes
ON routes(public_ip, host_port)
WHERE mode = 'l4' AND active = TRUE AND public_ip IS NOT NULL;

-- Add volumes table
CREATE TABLE IF NOT EXISTS volumes (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    volume_id TEXT UNIQUE NOT NULL,        -- e.g. vol_3q80vd3xyxkrgzy6
    name TEXT NOT NULL,                    -- user-provided name (e.g. data)
    device_path TEXT UNIQUE NOT NULL,      -- e.g. /dev/inferno_vg/vol_3q80vd3xyxkrgzy6
    size_gb INTEGER NOT NULL,
    vm_id INTEGER,                         -- nullable for unattached volumes
    encrypted BOOLEAN NOT NULL DEFAULT TRUE,  -- encryption enabled by default
    state TEXT NOT NULL DEFAULT 'available' CHECK(state IN ('available', 'attaching', 'attached', 'detaching', 'error')),
    active_source_checkpoint_id INTEGER,   -- which checkpoint is the volume currently based on
    destination TEXT NOT NULL DEFAULT '/data',  -- mount point in guest
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (vm_id) REFERENCES vms(id) ON DELETE SET NULL,
    FOREIGN KEY (active_source_checkpoint_id) REFERENCES volume_checkpoints(id)
);

-- Volume checkpoints (snapshots)
CREATE TABLE IF NOT EXISTS volume_checkpoints (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    volume_id INTEGER NOT NULL,
    lv_name TEXT UNIQUE NOT NULL,          -- vol_xxx_cp_001, vol_xxx_cp_002, etc.
    sequence_num INTEGER NOT NULL,         -- monotonic counter per volume
    source_checkpoint_id INTEGER,          -- parent checkpoint for lineage tracking
    type TEXT NOT NULL DEFAULT 'user' CHECK(type IN ('user', 'pre_restore', 'scheduled')),
    comment TEXT,                          -- user-provided description
    size_mb INTEGER,                       -- exclusive size if tracked
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (volume_id) REFERENCES volumes(id) ON DELETE CASCADE,
    FOREIGN KEY (source_checkpoint_id) REFERENCES volume_checkpoints(id),
    UNIQUE(volume_id, sequence_num)
);

-- Index for checkpoint queries
CREATE INDEX IF NOT EXISTS idx_volume_checkpoints_volume ON volume_checkpoints(volume_id, sequence_num DESC);
CREATE INDEX IF NOT EXISTS idx_volume_checkpoints_source ON volume_checkpoints(source_checkpoint_id);

-- Add to vm_details view
CREATE VIEW IF NOT EXISTS vm_details AS
SELECT
    v.name,
    v.tap_device,
    v.guest_ip,
    v.gateway_ip,
    ns.state,
    ns.last_updated,
    COUNT(r.id) as active_routes,
    COUNT(vol.id) as volumes
FROM vms v
LEFT JOIN network_state ns ON ns.vm_id = v.id
LEFT JOIN routes r ON r.vm_id = v.id AND r.active = TRUE
LEFT JOIN volumes vol ON vol.vm_id = v.id
GROUP BY v.id;

-- Add images table
CREATE TABLE IF NOT EXISTS images (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    image_id TEXT UNIQUE NOT NULL,
    name TEXT NOT NULL,
    source_image TEXT NOT NULL,
    rootfs_path TEXT UNIQUE NOT NULL,
    manifest_path TEXT UNIQUE NOT NULL,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- Add vm_versions table
CREATE TABLE IF NOT EXISTS vms_versions (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    vm_id        INTEGER NOT NULL,
    version      TEXT    NOT NULL,
    created_at   DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at   DATETIME DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(vm_id, version),
    FOREIGN KEY (vm_id) REFERENCES vms(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_vms_versions_vm_version ON vms_versions(vm_id, version DESC);

-- Add image_id to vms table
ALTER TABLE vms ADD COLUMN image_id INTEGER REFERENCES images(id);

-- Update vm_details view
DROP VIEW IF EXISTS vm_details;
CREATE VIEW vm_details AS
SELECT
    v.name,
    v.tap_device,
    v.guest_ip,
    v.gateway_ip,
    i.name as image_name,
    i.image_id,
    ns.state,
    ns.last_updated,
    COUNT(r.id) as active_routes,
    COUNT(vol.id) as volumes
FROM vms v
LEFT JOIN network_state ns ON ns.vm_id = v.id
LEFT JOIN routes r ON r.vm_id = v.id AND r.active = TRUE
LEFT JOIN volumes vol ON vol.vm_id = v.id
LEFT JOIN images i ON i.id = v.image_id
GROUP BY v.id;

-- ============================================================================
-- LVM Thin Snapshots Support
-- ============================================================================

-- Base images (LVM thin volumes for rootfs)
CREATE TABLE IF NOT EXISTS base_images (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    docker_ref TEXT NOT NULL,              -- "nginx:latest"
    docker_digest TEXT UNIQUE NOT NULL,    -- "sha256:abc123..."
    lv_name TEXT UNIQUE NOT NULL,          -- "base_abc123"
    lv_path TEXT NOT NULL,                 -- "/dev/mapper/inferno_rootfs_vg-base_abc123"
    size_mb INTEGER NOT NULL,
    manifest_json TEXT,                    -- Full docker inspect JSON
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    last_used_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- Index for fast lookup by digest
CREATE INDEX IF NOT EXISTS idx_base_images_digest ON base_images(docker_digest);

-- Ephemeral snapshots (track active VM snapshots)
CREATE TABLE IF NOT EXISTS ephemeral_snapshots (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    vm_id INTEGER NOT NULL UNIQUE,         -- One snapshot per VM at a time
    base_image_id INTEGER NOT NULL,
    lv_name TEXT UNIQUE NOT NULL,          -- "snap_vmname_version"
    lv_path TEXT NOT NULL,                 -- "/dev/mapper/inferno_rootfs_vg-snap_vmname_version"
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (vm_id) REFERENCES vms(id) ON DELETE CASCADE,
    FOREIGN KEY (base_image_id) REFERENCES base_images(id)
);

-- Index for cleanup operations
CREATE INDEX IF NOT EXISTS idx_ephemeral_snapshots_vm ON ephemeral_snapshots(vm_id);

-- View: VMs with their rootfs info
DROP VIEW IF EXISTS vm_rootfs_details;
CREATE VIEW vm_rootfs_details AS
SELECT
    v.name AS vm_name,
    v.state AS vm_state,
    bi.docker_ref AS base_image,
    bi.docker_digest AS image_digest,
    bi.size_mb AS base_size_mb,
    bi.lv_name AS base_lv,
    es.lv_name AS snapshot_lv,
    es.lv_path AS snapshot_path,
    es.created_at AS snapshot_created_at
FROM vms v
LEFT JOIN ephemeral_snapshots es ON es.vm_id = v.id
LEFT JOIN base_images bi ON es.base_image_id = bi.id;
