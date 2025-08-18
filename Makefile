# Sentry Zig SDK Makefile
.PHONY: help test build clean format check install dev

# Default target
.DEFAULT_GOAL := help

# Zig build options
ZIG_BUILD_OPTS := 
ZIG_TEST_OPTS := --summary all

help: ## Show this help message
	@echo "Sentry Zig SDK"
	@echo "=============="
	@echo ""
	@echo "Available targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-12s %s\n", $$1, $$2}'
	@echo ""
	@echo "Examples:"
	@echo "  make test     - Run all tests"
	@echo "  make build    - Build the library"
	@echo "  make clean    - Clean build artifacts"

test: ## Run all tests with detailed output
	@echo "Running tests..."
	@zig build test $(ZIG_TEST_OPTS)

test-quiet: ## Run tests with minimal output
	@zig build test

build: ## Build the static library
	@zig build $(ZIG_BUILD_OPTS)

clean: ## Clean build artifacts and cache
	@rm -rf zig-out/ .zig-cache/

format: ## Format all Zig source files
	@find src/ -name "*.zig" -exec zig fmt {} \;
	@if [ -d "examples/" ]; then find examples/ -name "*.zig" -exec zig fmt {} \; ; fi

check: ## Check code formatting and run linter
	@FAILED=0; \
	for file in $$(find src/ -name "*.zig"); do \
		if ! zig fmt --check "$$file" >/dev/null 2>&1; then \
			echo "File needs formatting: $$file"; \
			FAILED=1; \
		fi; \
	done; \
	if [ -d "examples/" ]; then \
		for file in $$(find examples/ -name "*.zig"); do \
			if ! zig fmt --check "$$file" >/dev/null 2>&1; then \
				echo "File needs formatting: $$file"; \
				FAILED=1; \
			fi; \
		done; \
	fi; \
	if [ $$FAILED -eq 0 ]; then \
		echo "All files are properly formatted"; \
	else \
		echo "Some files need formatting. Run 'make format' to fix."; \
		exit 1; \
	fi

install: ## Install the library (build and copy to zig-out)
	@zig build install $(ZIG_BUILD_OPTS)

release: ## Build optimized release version
	@zig build -Doptimize=ReleaseFast

debug: ## Build debug version with extra information
	@zig build -Doptimize=Debug

all: clean format check build test ## Run complete build pipeline
