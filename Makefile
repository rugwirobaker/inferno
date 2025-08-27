build:
	@echo Running Build
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags='-s -w' -o bin/init ./cmd/init
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags='-s -w' -o bin/kiln ./cmd/kiln

clean:
	@echo Running Clean
	rm control.sock control.sock_10000 exit_status.json firecracker.sock