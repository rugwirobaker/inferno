# Inferno Kernel Build Makefile
# Integrates kernel building with the main Inferno build system

KERNEL_VERSION ?= 5.10.223
BUILD_SCRIPT := ./build.sh
VMLINUX := vmlinux
INSTALL_DIR := /usr/share/inferno

.PHONY: all build install clean help menuconfig verify test

# Default target
all: build

# Build kernel
build:
	@echo "Building Inferno kernel $(KERNEL_VERSION)..."
	$(BUILD_SCRIPT) --no-install

# Build and install
install: build
	@echo "Installing kernel to $(INSTALL_DIR)..."
	sudo cp $(VMLINUX) $(INSTALL_DIR)/vmlinux
	sudo chmod 644 $(INSTALL_DIR)/vmlinux
	@echo "Kernel installed successfully"

# Clean build artifacts
clean:
	@echo "Cleaning kernel build artifacts..."
	$(BUILD_SCRIPT) --clean
	@echo "Clean complete"

# Interactive config
menuconfig:
	@echo "Running menuconfig (interactive kernel configuration)..."
	$(BUILD_SCRIPT) --menuconfig

# Verify kernel config
verify:
	@echo "Verifying kernel configuration..."
	@if [ -f linux-$(KERNEL_VERSION)/.config ]; then \
		echo "Checking critical config options..."; \
		grep -q "^CONFIG_BLK_DEV_DM=y" linux-$(KERNEL_VERSION)/.config && echo "  ✓ CONFIG_BLK_DEV_DM=y" || echo "  ✗ CONFIG_BLK_DEV_DM missing"; \
		grep -q "^CONFIG_DM_CRYPT=y" linux-$(KERNEL_VERSION)/.config && echo "  ✓ CONFIG_DM_CRYPT=y" || echo "  ✗ CONFIG_DM_CRYPT missing"; \
		grep -q "^CONFIG_VIRTIO=y" linux-$(KERNEL_VERSION)/.config && echo "  ✓ CONFIG_VIRTIO=y" || echo "  ✗ CONFIG_VIRTIO missing"; \
		grep -q "^CONFIG_BPF=y" linux-$(KERNEL_VERSION)/.config && echo "  ✓ CONFIG_BPF=y" || echo "  ✗ CONFIG_BPF missing"; \
	else \
		echo "Error: Kernel not configured. Run 'make build' first."; \
		exit 1; \
	fi

# Test kernel size
size:
	@if [ -f $(VMLINUX) ]; then \
		echo "Kernel size:"; \
		ls -lh $(VMLINUX) | awk '{print "  " $$5 "  " $$9}'; \
	else \
		echo "Error: Kernel not built. Run 'make build' first."; \
		exit 1; \
	fi

# Quick test with Inferno
test: install
	@echo "Testing kernel with Inferno VM..."
	@echo "Creating test VM..."
	-sudo infernoctl destroy kernel_test --yes 2>/dev/null
	sudo infernoctl create kernel_test --image alpine:latest
	@echo "Starting VM..."
	sudo infernoctl start kernel_test &
	@sleep 5
	@echo "Checking VM logs for errors..."
	infernoctl logs show | tail -20
	@echo "Stopping VM..."
	sudo infernoctl stop kernel_test
	sudo infernoctl destroy kernel_test --yes
	@echo "Test complete"

# Help
help:
	@echo "Inferno Kernel Build Targets"
	@echo ""
	@echo "  make build       - Build kernel (no install)"
	@echo "  make install     - Build and install kernel to /usr/share/inferno"
	@echo "  make clean       - Clean build artifacts"
	@echo "  make menuconfig  - Interactive kernel configuration"
	@echo "  make verify      - Verify kernel config has required options"
	@echo "  make size        - Show kernel size"
	@echo "  make test        - Build, install, and test with Inferno VM"
	@echo "  make help        - Show this help message"
	@echo ""
	@echo "Environment Variables:"
	@echo "  KERNEL_VERSION   - Kernel version to build (default: $(KERNEL_VERSION))"
	@echo "  JOBS             - Number of parallel build jobs (default: nproc)"
	@echo ""
	@echo "Examples:"
	@echo "  make build                        # Build with defaults"
	@echo "  KERNEL_VERSION=5.10.230 make      # Build specific version"
	@echo "  JOBS=8 make build                 # Build with 8 parallel jobs"
	@echo ""
