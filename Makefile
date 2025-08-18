# Sentry Zig SDK Makefile
.PHONY: help test test-quiet build clean format check install examples run-examples run-basic

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
	@echo "  make test        - Run all tests"
	@echo "  make build       - Build the library"
	@echo "  make examples    - Build all examples"
	@echo "  make run-examples - Build and run all examples"
	@echo "  make clean       - Clean build artifacts"

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
	@if [ -d "examples/" ]; then zig fmt examples/; fi

check: ## Check code formatting and run linter
	@echo "Checking code formatting..."
	@if zig fmt --check src/ && ([ ! -d "examples/" ] || zig fmt --check examples/); then \
		echo "All files are properly formatted"; \
	else \
		echo "Some files need formatting. Run 'make format' to fix."; \
		exit 1; \
	fi

install: ## Install the library (build and copy to zig-out)
	@zig build install $(ZIG_BUILD_OPTS)

examples: ## Build all examples
	@echo "Building examples..."
	@zig build examples $(ZIG_BUILD_OPTS)

run-basic: ## Build and run the basic example
	@echo "Running basic example..."
	@zig build run-basic $(ZIG_BUILD_OPTS)

run-examples: examples run-basic ## Build and run all examples
	@echo "All examples completed successfully!"

all: clean format check build test ## Run complete build pipeline