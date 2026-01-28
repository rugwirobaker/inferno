.PHONY: build build-all build-kernel install-kernel clean clean-all help

build:
	@echo Running Build
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags='-s -w' -o bin/init ./cmd/init
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags='-s -w' -o bin/kiln ./cmd/kiln
	CGO_ENABLED=1 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags='-s -w' -o bin/anubis ./cmd/anubis

# Build everything including custom kernel
build-all: build build-kernel

# Build custom kernel
build-kernel:
	@echo "Building custom Inferno kernel..."
	$(MAKE) -C kernel build

# Install kernel to /usr/share/inferno
install-kernel:
	@echo "Installing custom kernel..."
	$(MAKE) -C kernel install

install-anubis:
	@echo Installing Anubis service
	install -m 0755 -D bin/anubis /usr/share/inferno/anubis
	install -m 0644 -D etc/anubis/config.toml /etc/anubis/config.toml
	install -m 0644 -D etc/anubis/anubis.service /etc/systemd/system/anubis.service
	systemctl daemon-reload

clean:
	@echo Running Clean
	rm -f control.sock control.sock_10000 exit_status.json firecracker.sock

# Clean everything including kernel
clean-all: clean
	@echo "Cleaning kernel build artifacts..."
	$(MAKE) -C kernel clean

help:
	@echo "Inferno Build System"
	@echo ""
	@echo "Targets:"
	@echo "  make build         - Build init, kiln, and anubis binaries"
	@echo "  make build-kernel  - Build custom Inferno kernel"
	@echo "  make build-all     - Build everything (binaries + kernel)"
	@echo "  make install-kernel - Install custom kernel to /usr/share/inferno"
	@echo "  make clean         - Clean build artifacts"
	@echo "  make clean-all     - Clean everything including kernel"
	@echo "  make help          - Show this help message"
	@echo ""
	@echo "Kernel-specific targets:"
	@echo "  cd kernel && make help  - Show kernel build options"
