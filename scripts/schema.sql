CREATE TABLE IF NOT EXISTS vms (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT UNIQUE NOT NULL,
    tap_device TEXT UNIQUE NOT NULL,
    gateway_ip TEXT NOT NULL,
    guest_ip TEXT UNIQUE NOT NULL,
    mac_address TEXT UNIQUE NOT NULL,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

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

CREATE TABLE IF NOT EXISTS network_state (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    vm_id INTEGER NOT NULL,
    state TEXT NOT NULL CHECK (state IN ('created', 'exposed', 'deleted')),
    nft_rules_hash TEXT NOT NULL,
    config_files_hash TEXT NOT NULL,
    last_updated DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (vm_id) REFERENCES vms(id)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_l7_routes 
ON routes(hostname, host_port)
WHERE mode = 'l7' AND active = TRUE AND hostname IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_l4_routes 
ON routes(public_ip, host_port)
WHERE mode = 'l4' AND active = TRUE AND public_ip IS NOT NULL;

CREATE VIEW IF NOT EXISTS vm_details AS
SELECT 
    v.name,
    v.tap_device,
    v.guest_ip,
    v.gateway_ip,
    ns.state,
    ns.last_updated,
    COUNT(r.id) as active_routes
FROM vms v
LEFT JOIN network_state ns ON ns.vm_id = v.id
LEFT JOIN routes r ON r.vm_id = v.id AND r.active = TRUE
GROUP BY v.id;