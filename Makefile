.DEFAULT_GOAL := help

BINARY ?= desk-agent
OUT_DIR ?= $(HOME)/build/desk-agent
PUBLISH_DIR ?= /mnt/neptun/Scratch/desk-agent
PKG := ./cmd/desk-agent

VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
COMMIT ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo none)
DATE ?= $(shell date -u +%Y-%m-%dT%H:%M:%SZ)

GOFLAGS ?= -trimpath
LDFLAGS := -s -w -X main.version=$(VERSION) -X main.commit=$(COMMIT) -X main.date=$(DATE)

.PHONY: help fmt vet test tidy run build build-linux build-windows build-all publish clean

help:
	@printf '%s\n' \
		'Targets:' \
		'  make build          Build native binary to $(OUT_DIR)' \
		'  make build-linux    Build linux-amd64 binary to $(OUT_DIR)' \
		'  make build-windows  Build windows-amd64 binary to $(OUT_DIR)' \
		'  make build-all      Build linux-amd64 and windows-amd64' \
		'  make publish        Build all and copy binaries to $(PUBLISH_DIR)' \
		'  make test           Run unit tests' \
		'  make vet            Run go vet' \
		'  make fmt            Run go fmt' \
		'  make tidy           Run go mod tidy' \
		'  make run ARGS=...   Run from source' \
		'  make clean          Remove $(OUT_DIR)' \
		'' \
		'Variables:' \
		'  OUT_DIR=/path       Override output directory' \
		'  PUBLISH_DIR=/path   Override publish/copy directory' \
		'  VERSION=vX.Y.Z      Override embedded version'

fmt:
	go fmt ./...

vet:
	go vet ./...

test:
	go test ./... -count=1

tidy:
	go mod tidy

run:
	go run $(PKG) $(ARGS)

build:
	mkdir -p "$(OUT_DIR)"
	CGO_ENABLED=0 go build $(GOFLAGS) -ldflags "$(LDFLAGS)" -o "$(OUT_DIR)/$(BINARY)" $(PKG)

build-linux:
	mkdir -p "$(OUT_DIR)"
	GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build $(GOFLAGS) -ldflags "$(LDFLAGS)" -o "$(OUT_DIR)/$(BINARY)-linux-amd64" $(PKG)

build-windows:
	mkdir -p "$(OUT_DIR)"
	GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go build $(GOFLAGS) -ldflags "$(LDFLAGS)" -o "$(OUT_DIR)/$(BINARY)-windows-amd64.exe" $(PKG)

build-all: build-linux build-windows

publish: build-all
	mkdir -p "$(PUBLISH_DIR)"
	cp -f "$(OUT_DIR)/$(BINARY)-linux-amd64" "$(OUT_DIR)/$(BINARY)-windows-amd64.exe" "$(PUBLISH_DIR)/"

clean:
	rm -rf "$(OUT_DIR)"
