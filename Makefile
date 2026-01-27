build:
	@echo Running Build
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags='-s -w' -o bin/init ./cmd/init
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags='-s -w' -o bin/kiln ./cmd/kiln
	CGO_ENABLED=1 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags='-s -w' -o bin/anubis ./cmd/anubis

install-anubis:
	@echo Installing Anubis service
	install -m 0755 -D bin/anubis /usr/share/inferno/anubis
	install -m 0644 -D etc/anubis/config.toml /etc/anubis/config.toml
	install -m 0644 -D etc/anubis/anubis.service /etc/systemd/system/anubis.service
	systemctl daemon-reload

clean:
	@echo Running Clean
	rm control.sock control.sock_10000 exit_status.json firecracker.sock
