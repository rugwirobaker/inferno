build:
	@echo Running Build
	CGO_ENABLED=0 go build -o bin/inferno ./cmd/inferno
	CGO_ENABLED=0 go build -o bin/init ./cmd/init
	CGO_ENABLED=0 go build -o bin/kiln ./cmd/kiln