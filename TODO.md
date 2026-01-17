# Inferno TODO

## High Priority

### 1. Passwordless sudo Configuration
Add sudoers rule for infernoctl to avoid password prompts during development.

**Steps:**
```bash
sudo visudo -f /etc/sudoers.d/infernoctl
```

Add:
```
# Allow user to run infernoctl commands without password
<username> ALL=(root) NOPASSWD: /usr/local/bin/infernoctl
<username> ALL=(root) NOPASSWD: /usr/local/lib/inferno/scripts/infernoctl.sh
```

**Benefits:**
- Smoother development workflow
- Still maintains security (limited to specific binary)
- Audit trail preserved via sudo logs

### 2. KVM Module Autoload
Ensure KVM kernel modules load automatically on boot.

**Steps:**
```bash
# Add to /etc/modules
echo "kvm_intel" | sudo tee -a /etc/modules  # For Intel CPUs
# OR
echo "kvm_amd" | sudo tee -a /etc/modules    # For AMD CPUs
```

**Why:** Currently requires manual `modprobe kvm_intel` after reboot, causing Firecracker to fail with Error 19 (ENODEV).

### 3. Update Documentation
Document the bugs fixed in this session (2026-01-17).

**Files to update:**
- `CLAUDE.md` - Add "Known Issues and Fixes" section
- `README.md` - Update troubleshooting section

**Bugs fixed:**
1. Duplicate `--id` flag in kiln.go causing startup panic
2. VM destroy not cleaning up database records
3. VM logs socket path mismatch (absolute vs relative path)
4. Missing /dev/kvm in jail (documentation issue)
5. Missing kiln PID file causing startup warnings

### 4. Integration Testing
Create automated test script to catch regressions.

**Test coverage needed:**
- VM lifecycle (create → start → stop → destroy)
- Database cleanup verification
- Network connectivity (ping, curl)
- SSH access
- Log aggregation
- PID file creation

**Suggested file:** `scripts/test-integration.sh`

**Example structure:**
```bash
#!/bin/bash
# Test VM lifecycle
test_create_vm() { ... }
test_start_vm() { ... }
test_network_connectivity() { ... }
test_ssh_access() { ... }
test_stop_vm() { ... }
test_destroy_cleanup() { ... }

# Run all tests
run_all_tests
```

## Medium Priority

### 5. Logging Improvements
- Implement log rotation for `vm_combined.log`
- Add per-VM log files (optional, for debugging)
- Consider structured logging format (JSON) for better parsing

### 6. Error Handling
- Improve error messages when KVM is not available
- Better feedback when Docker/Podman is missing
- Validate network configuration before VM creation

### 7. Performance Optimization
- Cache extracted Docker images to avoid re-pulling
- Parallelize multiple VM creation
- Optimize initrd.cpio generation

## Low Priority

### 8. Feature Enhancements
- VM snapshots support
- Live migration between hosts
- Resource limits enforcement (cgroups)
- Multi-tenancy / namespaces
- Health checks and auto-restart
- Private container registry authentication

### 9. Developer Experience
- Add bash completion for infernoctl
- Improve `infernoctl logs` with filtering options
- Add `infernoctl ps` command to list running VMs
- Add `infernoctl exec` for running commands in VMs

### 10. CI/CD
- Set up GitHub Actions for automated testing
- Add linting (shellcheck for bash, golangci-lint for Go)
- Automated builds for releases

---

## Recently Completed (2026-01-17)

✅ Fixed duplicate `--id` flag in kiln.go
✅ Fixed VM destroy database cleanup
✅ Fixed vm_logs.sock path mismatch
✅ Added kiln PID file writing
✅ Improved PID file waiting logic in bash
✅ Documented KVM module requirement
✅ Tested full VM lifecycle with nginx
✅ Verified SSH and HTTP connectivity
