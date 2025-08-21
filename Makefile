# Sentry Zig SDK Makefile
.PHONY: help test test-quiet build clean format check install

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
	@echo "  make test                - Run all tests"
	@echo "  make build               - Build the library"
	@echo "  make clean               - Clean build artifacts"
	@echo "  make run-panic-handler   - Run the panic handler example"
	@echo "  make run-capture-message - Run the capture message example"

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
	@echo "Formatting source files..."
	@zig fmt src/
	@zig fmt examples/

check: ## Check code formatting and run linter
	@echo "Checking code formatting..."
	@if zig fmt --check src/ && zig fmt --check examples/; then \
		echo "All files are properly formatted"; \
	else \
		echo "Some files need formatting. Run 'make format' to fix."; \
		exit 1; \
	fi

install: ## Install the library (build and copy to zig-out)
	@zig build install $(ZIG_BUILD_OPTS)

# Example targets
.PHONY: examples run-panic-handler run-capture-message
examples: ## Build all examples (install only, don't run)
	@echo "Building all examples..."
	@zig build install $(ZIG_BUILD_OPTS)

run-panic-handler: ## Run the panic handler example
	@zig build panic_handler $(ZIG_BUILD_OPTS)

run-capture-message: ## Run the capture message example
	@zig build capture_message $(ZIG_BUILD_OPTS)

all: clean format check build test ## Run complete build pipeline
