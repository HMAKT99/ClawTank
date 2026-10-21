# ClawTank build entry points. See README.md → "Building".
SHELL := /bin/bash
ARCH  ?= $(shell uname -m)
CONFIG ?= Release
DERIVED := app/build
APP := $(DERIVED)/Build/Products/$(CONFIG)/ClawTank.app
VERSION := $(shell sed -n 's/^version = "\(.*\)"/\1/p' core/Cargo.toml | head -1)

.PHONY: build core app project test test-core test-app lint audit package clean spike-vd dev-signing bench

build: app ## Build Rust core + macOS app

core: ## Build the Rust static library and regenerate the C header
	cd core && cargo build --release

project: ## Generate the Xcode project from app/project.yml
	cd app && xcodegen generate --quiet

app: core project
	xcodebuild -project app/ClawTank.xcodeproj -scheme ClawTank -configuration $(CONFIG) \
		-derivedDataPath $(DERIVED) -destination "platform=macOS,arch=$(ARCH)" ARCHS=$(ARCH) -quiet build
	@if [ -f "$$HOME/Library/Keychains/clawtank-dev.keychain-db" ]; then scripts/dev-signing.sh sign "$(APP)"; \
	else echo "note: ad-hoc signed (run 'make dev-signing' to keep permissions across rebuilds)"; fi
	@echo "Built $(APP)"

dev-signing: ## One-time: create the local "ClawTank Dev" signing identity (ADR-015)
	scripts/dev-signing.sh setup

test: test-core test-app ## Run all unit tests

test-core:
	cd core && cargo test

test-app: core project
	xcodebuild -project app/ClawTank.xcodeproj -scheme ClawTank -configuration Debug \
		-derivedDataPath $(DERIVED) -destination "platform=macOS,arch=$(ARCH)" ARCHS=$(ARCH) -quiet test

lint: ## clippy, rustfmt, swiftlint
	cd core && cargo clippy --all-targets -- -D warnings
	cd core && cargo fmt --check
	swiftlint lint --strict --quiet

audit: ## RustSec advisory check
	cd core && cargo audit

package: build ## Unsigned (ad-hoc) DMG in dist/
	scripts/package-dmg.sh "$(APP)" "dist/ClawTank-$(VERSION).dmg"

spike-vd: ## Phase 0 virtual-display spike (needs Screen Recording permission)
	mkdir -p build && swiftc -O -import-objc-header spikes/virtual-display/CGVirtualDisplay.h \
		-framework CoreGraphics -framework ScreenCaptureKit spikes/virtual-display/main.swift -o build/vd-spike
	./build/vd-spike build/virtual-display.png

clean:
	cd core && cargo clean
	rm -rf $(DERIVED) app/ClawTank.xcodeproj dist build
