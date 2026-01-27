# Cryptsetup Library Bundling Solution

**Date:** 2026-01-27
**Status:** ✅ Implemented

## Problem Statement

Cryptsetup is dynamically linked and requires ~10MB of shared libraries that aren't available in minimal container images:
- `libc.so.6` (glibc) - 2.2MB
- `libcrypto.so.3` (OpenSSL) - 4.3MB
- `libcryptsetup.so.12` - 474KB
- Plus 10 additional libraries (libdevmapper, libblkid, etc.)

When init tries to execute cryptsetup from the initramfs, it fails with "library not found" errors in Alpine and other minimal images.

## Solution: Clean Library Bundling

Rather than attempting to build a static cryptsetup (complex, requires static versions of many dependencies), we **bundle the required libraries into the initramfs** with a clean, reusable script.

### Architecture

```
initramfs/
├── inferno/
│   ├── init              # 8.8MB statically linked Go binary
│   ├── run.json          # VM configuration
│   └── sbin/
│       └── cryptsetup    # 170KB dynamically linked binary
├── lib/                  # Bundled libraries (~9.7MB)
│   ├── libcryptsetup.so.12 -> libcryptsetup.so.12.7.0
│   ├── libcryptsetup.so.12.7.0
│   ├── libcrypto.so.3
│   ├── libc.so.6
│   ├── libm.so.6
│   ├── libdevmapper.so.1.02.1
│   ├── libblkid.so.1 -> libblkid.so.1.1.0
│   ├── libblkid.so.1.1.0
│   └── ... (7 more libraries)
└── lib64/                # Dynamic linker
    └── ld-linux-x86-64.so.2
```

**Total initramfs impact:** ~18.7MB (init 8.8MB + cryptsetup 0.2MB + libraries 9.7MB)

### Implementation Components

#### 1. `scripts/bundle-libs.sh`
**Purpose:** Reusable library bundling utility

**Key Functions:**
- `bundle_binary_libs(binary, target_lib_dir)` - Automatically detects and copies all required libraries
- `verify_bundled_libs(binary, lib_dir)` - Validates bundled libraries work

**Features:**
- Preserves symlink structure (e.g., `libcrypto.so.3` → actual version)
- Handles dynamic linker (`ld-linux-x86-64.so.2`)
- Deduplicates libraries (multiple binaries can share the same lib dir)
- Provides size reporting

**Usage:**
```bash
bundle_binary_libs "/usr/share/inferno/cryptsetup" "$initramfs_dir/lib"
```

#### 2. `scripts/infernoctl.sh` (Modified)
**Changes:**
1. Sources `bundle-libs.sh` at startup
2. During VM creation (`cmd_create`), after copying cryptsetup to initramfs:
   ```bash
   if type -t bundle_binary_libs >/dev/null 2>&1; then
     debug "Bundling cryptsetup library dependencies..."
     local lib_dir="$initramfs_dir/lib"
     bundle_binary_libs "/usr/share/inferno/cryptsetup" "$lib_dir"
   fi
   ```

#### 3. `cmd/init/volumes.go` (Modified)
**Changes:**
1. Cryptsetup path resolution now checks initramfs first:
   ```go
   cryptsetupPath := "/inferno/sbin/cryptsetup"  // Initramfs location
   if _, err := os.Stat(cryptsetupPath); err != nil {
       // Fallback to container paths
       if _, err := os.Stat("/usr/sbin/cryptsetup"); err == nil {
           cryptsetupPath = "/usr/sbin/cryptsetup"
       } else if _, err := os.Stat("/sbin/cryptsetup"); err == nil {
           cryptsetupPath = "/sbin/cryptsetup"
       }
   }
   ```

2. Sets `LD_LIBRARY_PATH` for bundled libraries:
   ```go
   if strings.HasPrefix(cryptsetupPath, "/inferno/") {
       env := os.Environ()
       env = append(env, "LD_LIBRARY_PATH=/lib:/lib64:/usr/lib:/usr/lib64")
       cmd.Env = env
   }
   ```

#### 4. `scripts/install.sh` (Modified)
**Changes:**
Now prefers **glibc-based cryptsetup** instead of musl-based:

```bash
# Detect libc type
if ldd "$SYSTEM_CRYPT" 2>&1 | grep -q "not a dynamic executable"; then
    # Static binary - ideal but rare
    info "Using static system cryptsetup"
elif ldd "$SYSTEM_CRYPT" 2>&1 | grep -q "libc.so.6"; then
    # glibc-based - compatible with library bundling
    info "Using system cryptsetup (glibc-based, libraries will be bundled)"
else
    # musl or other - incompatible
    warn "System cryptsetup uses incompatible libc, attempting package install"
fi
```

### Why This Approach?

**✅ Advantages:**
1. **Simple:** No complex static compilation
2. **Automatic:** Libraries bundled transparently during VM creation
3. **Standard:** Uses system cryptsetup and standard glibc libraries
4. **Reusable:** `bundle-libs.sh` can bundle libraries for any binary
5. **Efficient:** Libraries shared across all initramfs binaries (future-proof)
6. **Maintainable:** System package manager updates cryptsetup, we just copy

**❌ Avoided Approaches:**
1. **Static cryptsetup:** Requires static builds of libcryptsetup, OpenSSL, argon2, etc. - very complex
2. **Alpine-based images only:** Restricts user choice unnecessarily
3. **Install in base image:** Adds 10MB+ to every container image layer

### Performance Impact

| Component | Size | Notes |
|-----------|------|-------|
| cryptsetup binary | 170KB | glibc dynamically linked |
| Bundled libraries | 9.7MB | 13 libraries + linker |
| **Total cryptsetup cost** | **9.9MB** | One-time per VM |
| init binary (existing) | 8.8MB | Statically linked |
| **Total initramfs** | **~19MB** | Reasonable for VM boot |

**Comparison:**
- Without encryption: initramfs ~9MB (just init + run.json)
- With encryption: initramfs ~19MB (+10MB for cryptsetup stack)
- Static cryptsetup (hypothetical): ~15MB (if achievable)

### Library Breakdown

```
Libraries bundled (9.7MB total):
├── libcrypto.so.3         4.3MB  (OpenSSL cryptographic library)
├── libc.so.6              2.2MB  (GNU C library)
├── libm.so.6              919KB  (Math library)
├── libpcre2-8.so.0        599KB  (Regex library)
├── libcryptsetup.so.12    474KB  (LUKS library)
├── libdevmapper.so.1      429KB  (Device mapper)
├── ld-linux-x86-64.so.2   236KB  (Dynamic linker)
├── libblkid.so.1          216KB  (Block device identification)
├── libselinux.so.1        163KB  (SELinux)
├── libudev.so.1           163KB  (Device management)
├── libjson-c.so.5          71KB  (JSON parsing)
├── libargon2.so.1          35KB  (Argon2 key derivation)
└── libuuid.so.1            31KB  (UUID generation)
```

**Note:** These are standard system libraries. Most are already in container images, but we bundle them in initramfs to guarantee availability before rootfs mount.

## Testing

### Unit Test: Library Bundling
```bash
# Test the bundling script standalone
/home/rugwiro/inferno/scripts/bundle-libs.sh \
  /usr/share/inferno/cryptsetup \
  /tmp/test-libs \
  verify

# Expected output:
# [INFO] Bundled 13 libraries for cryptsetup (9.7MiB)
# [DEBUG] Library verification passed
```

### Integration Test: VM Creation
```bash
# Create a VM with encrypted volume
sudo infernoctl create test-crypt --image alpine:latest

# Check initramfs contents
sudo cpio -itv < ~/.local/share/inferno/vms/kiln/*/root/initrd.cpio | grep -E 'sbin/cryptsetup|lib/'

# Expected:
# inferno/sbin/cryptsetup
# lib/libcrypto.so.3
# lib/libc.so.6
# ... (all libraries)
```

### End-to-End Test: Volume Unlock
```bash
# Create encrypted volume (requires KMS setup)
sudo infernoctl volume create test-vol --encrypted

# Create VM with encrypted volume
sudo infernoctl create test-vm --image alpine:latest --volume test-vol

# Start VM (init should successfully unlock volume)
sudo infernoctl start test-vm

# Verify cryptsetup was called
sudo infernoctl logs tail | grep -i crypt
# Expected: "volume unlocked successfully"
```

## Verification Commands

```bash
# 1. Check installed cryptsetup is glibc-based
file /usr/share/inferno/cryptsetup
# Expected: ELF 64-bit LSB pie executable, x86-64, version 1 (SYSV), dynamically linked, interpreter /lib64/ld-linux-x86-64.so.2

ldd /usr/share/inferno/cryptsetup | grep libc.so.6
# Expected: libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6

# 2. Test library bundling
rm -rf /tmp/test-libs
/home/rugwiro/inferno/scripts/bundle-libs.sh /usr/share/inferno/cryptsetup /tmp/test-libs verify
# Should succeed without errors

# 3. Check bundle-libs is sourced
grep -n "bundle-libs.sh" /usr/local/lib/inferno/scripts/infernoctl.sh
# Expected: Line sourcing the script

# 4. Verify init looks for initramfs cryptsetup first
grep "/inferno/sbin/cryptsetup" cmd/init/volumes.go
# Expected: cryptsetupPath := "/inferno/sbin/cryptsetup"
```

## Rollout Plan

1. ✅ **Build Phase:** Create `bundle-libs.sh` utility
2. ✅ **Integration Phase:** Modify `infernoctl.sh` to bundle libraries during VM creation
3. ✅ **Init Phase:** Update `volumes.go` to use bundled cryptsetup and libraries
4. ✅ **Install Phase:** Update `install.sh` to prefer glibc-based cryptsetup
5. ⏳ **Testing Phase:** Create encrypted volumes in minimal containers (alpine, distroless)
6. ⏳ **Documentation Phase:** Update CLAUDE.md with library bundling workflow

## Future Optimizations (Optional)

### 1. Lazy Library Loading
Don't bundle libraries for VMs without encrypted volumes:
```bash
if [[ "$volume_encrypted" == "true" ]]; then
  bundle_binary_libs "/usr/share/inferno/cryptsetup" "$lib_dir"
fi
```
**Savings:** 10MB per non-encrypted VM
**Trade-off:** More complex logic

### 2. Shared Library Cache
Bundle libraries once in a shared location, symlink into each initramfs:
```bash
SHARED_LIB_CACHE="$INFERNO_ROOT/cache/cryptsetup-libs"
if [[ ! -d "$SHARED_LIB_CACHE" ]]; then
  bundle_binary_libs "/usr/share/inferno/cryptsetup" "$SHARED_LIB_CACHE"
fi
ln -s "$SHARED_LIB_CACHE" "$initramfs_dir/lib"
```
**Savings:** Disk space for multiple VMs
**Trade-off:** Shared cache management, symlink resolution in cpio

### 3. Strip Debug Symbols
Reduce library sizes with `strip`:
```bash
strip --strip-debug "$target_lib_dir"/*.so*
```
**Savings:** ~1-2MB
**Trade-off:** Harder to debug library issues

### 4. Static Cryptsetup Build Script
For users who want minimal initramfs:
```bash
scripts/build-static-cryptsetup.sh
# Builds cryptsetup with musl-libc, static OpenSSL, etc.
# Result: ~2-3MB single binary
```
**Savings:** 7MB (vs current 10MB)
**Trade-off:** Complex build process, maintenance burden

## Lessons Learned

1. **libc compatibility matters:** musl vs glibc makes a huge difference for library bundling
2. **ldd parsing is fragile:** The `bundle-libs.sh` script is robust but needs careful parsing
3. **Symlinks are important:** Libraries like `libcrypto.so.3` are often symlinks to versioned files
4. **LD_LIBRARY_PATH is critical:** Must be set before exec() for dynamic loading to work
5. **Initramfs size is acceptable:** 19MB for full encryption support is reasonable for VM boot

## Related Files

- `scripts/bundle-libs.sh` - Library bundling utility
- `scripts/infernoctl.sh` - VM creation logic (lines 1727-1745)
- `cmd/init/volumes.go` - Volume unlocking logic (lines 119-139)
- `scripts/install.sh` - Cryptsetup installation (lines 350-403)
- `volumes/RFC-006.md` - Volume encryption design

## Status Summary

| Component | Status | Notes |
|-----------|--------|-------|
| bundle-libs.sh | ✅ Complete | Tested with system cryptsetup |
| infernoctl.sh integration | ✅ Complete | Sources and calls bundle function |
| volumes.go LD_LIBRARY_PATH | ✅ Complete | Sets path for bundled libs |
| install.sh glibc detection | ✅ Complete | Prefers glibc over musl |
| End-to-end testing | ⏳ Pending | Needs encrypted volume test |

**Next Steps:**
1. Create an encrypted volume end-to-end test
2. Test with minimal images (alpine:latest, gcr.io/distroless/static)
3. Measure actual initramfs boot time impact
4. Update CLAUDE.md with bundling workflow
