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
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (vm_id) REFERENCES vms(id)
);

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
