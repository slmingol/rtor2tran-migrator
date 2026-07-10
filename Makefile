# ══════════════════════════════════════════════════════════════════════════════
#  rtor2tran-migrator
# ══════════════════════════════════════════════════════════════════════════════

# ── Colors ────────────────────────────────────────────────────────────────────
RESET   := \033[0m
BOLD    := \033[1m
DIM     := \033[2m
RED     := \033[31m
GREEN   := \033[32m
YELLOW  := \033[33m
BLUE    := \033[34m
MAGENTA := \033[35m
CYAN    := \033[36m
WHITE   := \033[37m

# ── Build config ──────────────────────────────────────────────────────────────
BINARY  := rtor2tran-migrator
DIST    := dist
VERSION := $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
LDFLAGS := -s -w -X main.version=$(VERSION)

UNAME_S := $(shell uname -s)
UNAME_M := $(shell uname -m)

ifeq ($(UNAME_S),Darwin)
  BIN := $(DIST)/$(BINARY)
else ifeq ($(UNAME_M),aarch64)
  BIN := $(DIST)/$(BINARY)-linux-arm64
else
  BIN := $(DIST)/$(BINARY)-linux-amd64
endif

# ── Remote config (override on the command line or export from your shell) ────
PI_HOST     ?= root@pi-vpn
PI_BIN      ?= ~/rtor2tran-migrator

# ── Docker config ─────────────────────────────────────────────────────────────
REGISTRY  ?= ghcr.io
REPO      ?= $(shell git remote get-url origin 2>/dev/null | sed 's|.*github\.com[:/]||;s|\.git$$||' | tr '[:upper:]' '[:lower:]')
IMAGE     := $(REGISTRY)/$(REPO)
# Convert ~/... paths to absolute for Docker volume mounts
_to_abs    = $(subst ~,$(HOME),$(1))

# ── Migration config ──────────────────────────────────────────────────────────
SESSION_DIR  ?= ~/rtorrent/sessions
OUTPUT_DIR   ?= /var/lib/transmission-daemon/.config/transmission-daemon
DOWNLOAD_DIR ?= /mnt4/torrent-complete
HASH         ?=
FORCE        ?=
INCOMPLETE   ?=
MOVE_FILES   ?=
COPY_FILES   ?=

# ── Computed flags (empty unless the variable is set) ─────────────────────────
_DOWNLOAD := $(if $(DOWNLOAD_DIR),--download-dir $(DOWNLOAD_DIR),)
_HASH     := $(if $(HASH),--only $(HASH),)
_FORCE    := $(if $(FORCE),--force,)
_INC      := $(if $(INCOMPLETE),--incomplete,)
_MOVE     := $(if $(MOVE_FILES),--move-files,)
_COPY     := $(if $(COPY_FILES),--copy-files,)

# ── Helpers ───────────────────────────────────────────────────────────────────
define log
	@printf "$(BOLD)$(CYAN) ▶$(RESET) $(1)\n"
endef

define ok
	@printf "$(BOLD)$(GREEN) ✔$(RESET) $(1)\n"
endef

define warn
	@printf "$(BOLD)$(YELLOW) !$(RESET) $(1)\n"
endef

define section
	@printf "\n$(BOLD)$(BLUE)$(1)$(RESET)\n"
	@printf "$(DIM)────────────────────────────────────────$(RESET)\n"
endef

define _run
	$(BIN) \
	  --session-dir $(SESSION_DIR) \
	  --output-dir $(OUTPUT_DIR) \
	  $(_DOWNLOAD) $(_HASH) $(_FORCE) $(_INC) $(_MOVE) $(_COPY) $(1)
endef

# ══════════════════════════════════════════════════════════════════════════════
#  Default
# ══════════════════════════════════════════════════════════════════════════════
.DEFAULT_GOAL := help

.PHONY: help
help:
	@printf "\n$(BOLD)$(WHITE)rtor2tran-migrator$(RESET) — rtorrent → transmission migration tool\n\n"
	@printf "$(BOLD)Config$(RESET) $(DIM)(override with VAR=value)$(RESET)\n"
	@printf "  $(YELLOW)PI_HOST$(RESET)      = $(PI_HOST)\n"
	@printf "  $(YELLOW)PI_BIN$(RESET)       = $(PI_BIN)\n"
	@printf "  $(YELLOW)SESSION_DIR$(RESET)  = $(SESSION_DIR)\n"
	@printf "  $(YELLOW)OUTPUT_DIR$(RESET)   = $(OUTPUT_DIR)\n"
	@printf "  $(YELLOW)DOWNLOAD_DIR$(RESET) = $(if $(DOWNLOAD_DIR),$(DOWNLOAD_DIR),$(DIM)(same as session)$(RESET))\n"
	@printf "  $(YELLOW)MOVE_FILES$(RESET)   = $(if $(MOVE_FILES),yes,$(DIM)no$(RESET))\n"
	@printf "  $(YELLOW)COPY_FILES$(RESET)   = $(if $(COPY_FILES),yes,$(DIM)no$(RESET))\n"
	@printf "\n"
	@printf "$(BOLD)Build$(RESET)\n"
	@printf "  $(CYAN)build$(RESET)          Build for the current platform\n"
	@printf "  $(CYAN)linux-arm64$(RESET)    Build for Raspberry Pi 4 / ARM64\n"
	@printf "  $(CYAN)linux-amd64$(RESET)    Build for x86-64 Linux\n"
	@printf "  $(CYAN)all$(RESET)            Build all platforms\n"
	@printf "\n"
	@printf "$(BOLD)Deploy$(RESET)\n"
	@printf "  $(CYAN)deploy$(RESET)         Build ARM64 and scp to PI_HOST\n"
	@printf "\n"
	@printf "$(BOLD)Docker$(RESET) $(DIM)(IMAGE=$(IMAGE))$(RESET)\n"
	@printf "  $(CYAN)docker-build$(RESET)   Build image for current platform\n"
	@printf "  $(CYAN)docker-push$(RESET)    Build multi-arch image and push to GHCR\n"
	@printf "  $(CYAN)docker-run$(RESET)     Run migration via Docker\n"
	@printf "\n"
	@printf "$(BOLD)Migrate$(RESET) $(DIM)(runs locally against SESSION_DIR / OUTPUT_DIR)$(RESET)\n"
	@printf "  $(CYAN)list-hashes$(RESET)    List up to 20 session hashes to pick one for testing\n"
	@printf "  $(CYAN)dry-run$(RESET)        Dry-run the full migration\n"
	@printf "  $(CYAN)migrate$(RESET)        Run the full migration\n"
	@printf "  $(CYAN)test-one$(RESET)       Dry-run a single torrent  $(DIM)requires HASH=$(RESET)\n"
	@printf "  $(CYAN)migrate-one$(RESET)    Migrate a single torrent  $(DIM)requires HASH=$(RESET)\n"
	@printf "\n"
	@printf "$(BOLD)Dev$(RESET)\n"
	@printf "  $(CYAN)tidy$(RESET)           go mod tidy\n"
	@printf "  $(CYAN)vet$(RESET)            go vet\n"
	@printf "  $(CYAN)clean$(RESET)          Remove dist/\n"
	@printf "\n"
	@printf "$(BOLD)Examples$(RESET)\n"
	@printf "  $(DIM)# Build and deploy to the Pi$(RESET)\n"
	@printf "  make deploy\n\n"
	@printf "  $(DIM)# Pick a hash to test with$(RESET)\n"
	@printf "  make list-hashes\n\n"
	@printf "  $(DIM)# Test a single torrent before committing$(RESET)\n"
	@printf "  make test-one HASH=0C9E809C2CA0D0A19E3C60CEF04B7ACA5505AE1F\n\n"
	@printf "  $(DIM)# Migrate that one torrent for real$(RESET)\n"
	@printf "  make migrate-one HASH=0C9E809C2CA0D0A19E3C60CEF04B7ACA5505AE1F\n\n"
	@printf "  $(DIM)# Dry-run everything$(RESET)\n"
	@printf "  make dry-run\n\n"
	@printf "  $(DIM)# Full migration$(RESET)\n"
	@printf "  make migrate\n\n"
	@printf "  $(DIM)# Re-run and overwrite any existing resume files$(RESET)\n"
	@printf "  make migrate FORCE=1\n\n"
	@printf "  $(DIM)# Include incomplete torrents$(RESET)\n"
	@printf "  make migrate INCOMPLETE=1\n\n"
	@printf "  $(DIM)# Override the download path (cross-machine migration)$(RESET)\n"
	@printf "  make migrate DOWNLOAD_DIR=/mnt/media/torrents\n\n"
	@printf "  $(DIM)# Move media files to transmission's download dir$(RESET)\n"
	@printf "  make migrate MOVE_FILES=1\n\n"
	@printf "  $(DIM)# Same but copy instead of move (keeps originals)$(RESET)\n"
	@printf "  make migrate COPY_FILES=1\n\n"
	@printf "  $(DIM)# Dry-run a single torrent including file move$(RESET)\n"
	@printf "  make test-one HASH=0C9E809C2CA0D0A19E3C60CEF04B7ACA5505AE1F MOVE_FILES=1\n\n"
	@printf "  $(DIM)# Target a different Pi$(RESET)\n"
	@printf "  make deploy PI_HOST=root@other-box\n\n"
	@printf "  $(DIM)# Build and run via Docker$(RESET)\n"
	@printf "  make docker-build && make docker-run\n\n"
	@printf "  $(DIM)# Push multi-arch image to GHCR$(RESET)\n"
	@printf "  make docker-push\n\n"

# ══════════════════════════════════════════════════════════════════════════════
#  Build
# ══════════════════════════════════════════════════════════════════════════════
.PHONY: build
build: _dist
	$(call section,Building for current platform)
	$(call log,Compiling $(BINARY)...)
	@go build -ldflags "$(LDFLAGS)" -o $(DIST)/$(BINARY) .
	$(call ok,$(DIST)/$(BINARY))

.PHONY: linux-arm64
linux-arm64: _dist
	$(call section,Building for Linux ARM64 (Raspberry Pi 4))
	$(call log,Compiling $(BINARY)-linux-arm64...)
	@GOOS=linux GOARCH=arm64 go build -ldflags "$(LDFLAGS)" -o $(DIST)/$(BINARY)-linux-arm64 .
	$(call ok,$(DIST)/$(BINARY)-linux-arm64)

.PHONY: linux-amd64
linux-amd64: _dist
	$(call section,Building for Linux x86-64)
	$(call log,Compiling $(BINARY)-linux-amd64...)
	@GOOS=linux GOARCH=amd64 go build -ldflags "$(LDFLAGS)" -o $(DIST)/$(BINARY)-linux-amd64 .
	$(call ok,$(DIST)/$(BINARY)-linux-amd64)

.PHONY: all
all: build linux-arm64 linux-amd64
	$(call section,All builds complete)
	@ls -lh $(DIST)/
	@printf "\n"

# ══════════════════════════════════════════════════════════════════════════════
#  Deploy
# ══════════════════════════════════════════════════════════════════════════════
.PHONY: deploy
deploy: linux-arm64
	$(call section,Deploying to $(PI_HOST))
	$(call log,Copying $(DIST)/$(BINARY)-linux-arm64 → $(PI_HOST):$(PI_BIN)...)
	@scp $(DIST)/$(BINARY)-linux-arm64 $(PI_HOST):$(PI_BIN)
	$(call ok,Deployed to $(PI_HOST):$(PI_BIN))

# ══════════════════════════════════════════════════════════════════════════════
#  Docker
# ══════════════════════════════════════════════════════════════════════════════
.PHONY: docker-build
docker-build:
	$(call section,Building Docker image (current platform))
	$(call log,$(IMAGE):$(VERSION))
	@docker build --build-arg VERSION=$(VERSION) \
	  -t $(IMAGE):$(VERSION) -t $(IMAGE):latest .
	$(call ok,$(IMAGE):$(VERSION))

.PHONY: docker-push
docker-push:
	$(call section,Building and pushing multi-arch Docker image)
	$(call log,$(IMAGE):$(VERSION)  [linux/amd64 linux/arm64])
	@docker buildx build --platform linux/amd64,linux/arm64 \
	  --build-arg VERSION=$(VERSION) \
	  -t $(IMAGE):$(VERSION) -t $(IMAGE):latest \
	  --push .
	$(call ok,Pushed $(IMAGE):$(VERSION))

.PHONY: docker-run
docker-run:
	$(call section,Running migration via Docker)
	$(call log,$(IMAGE):latest)
	@docker run --rm \
	  -v "$(call _to_abs,$(SESSION_DIR))":"$(call _to_abs,$(SESSION_DIR))":ro \
	  -v "$(OUTPUT_DIR)":"$(OUTPUT_DIR)" \
	  $(if $(DOWNLOAD_DIR),-v "$(DOWNLOAD_DIR)":"$(DOWNLOAD_DIR)",) \
	  $(IMAGE):latest \
	  --session-dir "$(call _to_abs,$(SESSION_DIR))" \
	  --output-dir "$(OUTPUT_DIR)" \
	  $(_DOWNLOAD) $(_HASH) $(_FORCE) $(_INC) $(_MOVE) $(_COPY)

# ══════════════════════════════════════════════════════════════════════════════
#  Migrate
# ══════════════════════════════════════════════════════════════════════════════
.PHONY: list-hashes
list-hashes:
	$(call section,Available session hashes)
	@ls $(SESSION_DIR)/*.torrent.rtorrent 2>/dev/null \
	  | xargs -I{} basename {} .torrent.rtorrent \
	  | head -20

# ══════════════════════════════════════════════════════════════════════════════
#  Migrate
# ══════════════════════════════════════════════════════════════════════════════
.PHONY: dry-run
dry-run: _require-bin
	$(call section,Dry-run migration)
	$(call log,SESSION_DIR=$(SESSION_DIR))
	$(call log,OUTPUT_DIR=$(OUTPUT_DIR))
	@printf "\n"
	@$(call _run,--dry-run)

.PHONY: migrate
migrate: _require-bin
	$(call section,Running migration)
	$(call log,SESSION_DIR=$(SESSION_DIR))
	$(call log,OUTPUT_DIR=$(OUTPUT_DIR))
	$(call warn,Transmission must be stopped before running)
	@printf "\n"
	@$(call _run,)

.PHONY: test-one
test-one: _require-bin
	$(call section,Dry-run single torrent)
ifndef HASH
	@printf "$(RED)error:$(RESET) HASH is required\n"
	@printf "  usage: make test-one HASH=<infohash>\n"
	@exit 1
endif
	$(call log,HASH=$(HASH))
	@printf "\n"
	@$(call _run,--dry-run)

.PHONY: migrate-one
migrate-one: _require-bin
	$(call section,Migrating single torrent)
ifndef HASH
	@printf "$(RED)error:$(RESET) HASH is required\n"
	@printf "  usage: make migrate-one HASH=<infohash>\n"
	@exit 1
endif
	$(call log,HASH=$(HASH))
	@printf "\n"
	@$(call _run,)

# ══════════════════════════════════════════════════════════════════════════════
#  Dev
# ══════════════════════════════════════════════════════════════════════════════
.PHONY: tidy
tidy:
	$(call section,Tidying modules)
	$(call log,Running go mod tidy...)
	@go mod tidy
	$(call ok,go.mod and go.sum updated)

.PHONY: vet
vet:
	$(call section,Vetting)
	$(call log,Running go vet...)
	@go vet ./...
	$(call ok,No issues found)

.PHONY: clean
clean:
	$(call section,Cleaning)
	$(call log,Removing $(DIST)/...)
	@rm -rf $(DIST)
	$(call ok,Clean)

# ══════════════════════════════════════════════════════════════════════════════
#  Internal
# ══════════════════════════════════════════════════════════════════════════════
.PHONY: _dist
_dist:
	@mkdir -p $(DIST)

.PHONY: _require-bin
_require-bin:
	@test -f $(BIN) || { \
	  printf "$(RED)error:$(RESET) $(BIN) not found\n"; \
	  printf "  run $(CYAN)make build$(RESET) first (requires Go), or copy the binary into $(DIST)/\n"; \
	  exit 1; \
	}
