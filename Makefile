SHELL := /bin/bash

APP_DIR := build/PiCanvas.app
BIN := $(APP_DIR)/Contents/MacOS/PiCanvas
SWIFTTERM_LIB := build/swiftterm/libSwiftTerm.a

.PHONY: all app run open kill clean rebuild deps test

all: app

## Fetch vendored sources (SwiftTerm fallback + Ghostty's core) if missing.
deps:
	@./scripts/fetch-deps.sh

## Build Ghostty's core (libghostty) — the primary terminal backend.
## Needs the Zig toolchain (brew install zig).
ghostty:
	@./scripts/build-libghostty.sh

## Build the SwiftTerm fallback library and Swift module.
swiftterm:
	@./scripts/build-swiftterm.sh

## Build the app bundle.
app:
	@./scripts/build-app.sh

## Build, then run in the foreground with logs on stdout.
run: app
	@echo "==> running $(BIN)"
	@$(BIN)

## Build and launch as a normal app.
open: app
	@open $(APP_DIR)

## Stop any running instance.
kill:
	@-pkill -x PiCanvas 2>/dev/null && echo "stopped PiCanvas" || echo "PiCanvas was not running"

clean:
	@rm -rf build
	@echo "==> cleaned (Vendor/ is kept; remove it by hand to re-fetch)"

## Full rebuild from scratch, including SwiftTerm.
rebuild: clean app
