# =============================================================================
# QuarkLauncher Makefile
# =============================================================================

SHELL := /bin/bash

# Project configuration
PROJECT_NAME := QuarkLauncher
PROJECT_FILE := $(PROJECT_NAME).xcodeproj
TARGET_NAME := $(PROJECT_NAME)
SCHEME_NAME := $(PROJECT_NAME)

# Build configuration
BUILD_DIR := build
BUILD_PATH := $(abspath $(BUILD_DIR))
SRCROOT := .

# Xcode build settings
SDK := macosx
ARCH := x86_64

# Configuration types
DEBUG_CONFIG ?= Debug
RELEASE_CONFIG ?= Release

.PHONY: all debug release clean install-uninstall test help xcodebuild-install xcodebuild-uninstall

# Default target - build release version
all: release

# Build debug version
debug:
	@echo "Building $(PROJECT_NAME) in debug mode..."
	@mkdir -p $(BUILD_PATH)
	xcodebuild -project $(PROJECT_FILE) \
		-scheme $(SCHEME_NAME) \
		-configuration $(DEBUG_CONFIG) \
		-sdk $(SDK) \
		BUILD_DIR=$(BUILD_PATH) \
		clean build

# Build release version
release:
	@echo "Building $(PROJECT_NAME) in release mode..."
	@mkdir -p $(BUILD_PATH)
	xcodebuild -project $(PROJECT_FILE) \
		-scheme $(SCHEME_NAME) \
		-configuration $(RELEASE_CONFIG) \
		-sdk $(SDK) \
		BUILD_DIR=$(BUILD_PATH) \
		clean build

# Build and run debug version
run-debug: debug
	@echo "Running debug version..."
	@APP_PATH=$(BUILD_PATH)/$(DEBUG_CONFIG)/*.app
	@if [ -d "$$APP_PATH" ]; then \
		open "$$APP_PATH"; \
	else \
		echo "Error: App not found. Build failed?"; \
	fi

# Build and run release version
run-release: release
	@echo "Running release version..."
	@APP_PATH=$(BUILD_PATH)/$(RELEASE_CONFIG)/*.app
	@if [ -d "$$APP_PATH" ]; then \
		open "$$APP_PATH"; \
	else \
		echo "Error: App not found. Build failed?"; \
	fi

# Clean build artifacts
clean:
	@echo "Cleaning build artifacts..."
	@rm -rf $(BUILD_PATH)
	@echo "Build artifacts cleaned."

# Test the application
test:
	@echo "Running tests for $(PROJECT_NAME)..."
	@mkdir -p $(BUILD_PATH)
	xcodebuild -project $(PROJECT_FILE) \
		-scheme $(SCHEME_NAME) \
		-configuration $(DEBUG_CONFIG) \
		-sdk $(SDK) \
		-destination platform=macOS \
		BUILD_DIR=$(BUILD_PATH) \
		test

# Archive the application
archive:
	@echo "Archiving $(PROJECT_NAME)..."
	@mkdir -p $(BUILD_PATH)
	xcodebuild -project $(PROJECT_FILE) \
		-scheme $(SCHEME_NAME) \
		-configuration $(RELEASE_CONFIG) \
		-sdk $(SDK) \
		archivePath $(BUILD_PATH)/$(PROJECT_NAME).xcarchive \
		BUILD_DIR=$(BUILD_PATH) \
		archive

# Export IPA (for distribution)
export: archive
	@echo "Exporting archived app for distribution..."
	@mkdir -p $(BUILD_PATH)/Export
	xcodebuild -exportArchive \
		-archivePath $(BUILD_PATH)/$(PROJECT_NAME).xcarchive \
		-exportPath $(BUILD_PATH)/Export \
		-exportFormat APP

# Install the app to Applications folder
install:
	@echo "Installing $(PROJECT_NAME) to Applications folder..."
	@APP_PATH=$(BUILD_PATH)/$(RELEASE_CONFIG)/*.app
	@if [ -d "$$APP_PATH" ]; then \
		cp -R "$$APP_PATH" /Applications/; \
		echo "$(PROJECT_NAME) installed to Applications folder"; \
	else \
		echo "Error: App not found. Build the release version first?"; \
		exit 1; \
	fi

# Uninstall the app from Applications folder
uninstall:
	@echo "Uninstalling $(PROJECT_NAME) from Applications folder..."
	@sudo rm -rf "/Applications/$(PROJECT_NAME).app"
	@echo "$(PROJECT_NAME) uninstalled from Applications folder"

# Check if Xcode tools are installed
check-xcode:
	@command -v xcodebuild >/dev/null 2>&1 || { echo >&2 "xcodebuild is not installed. Please install Xcode Command Line Tools."; exit 1; }
	@echo "Xcode Command Line Tools are available."

# Open Xcode project
xcode:
	@echo "Opening $(PROJECT_NAME) in Xcode..."
	open $(PROJECT_FILE)

# Print project information
info:
	@echo "Project: $(PROJECT_NAME)"
	@echo "Project File: $(PROJECT_FILE)"
	@echo "Target: $(TARGET_NAME)"
	@echo "Scheme: $(SCHEME_NAME)"
	@echo "Build Directory: $(BUILD_PATH)"
	@echo "Debug Configuration: $(DEBUG_CONFIG)"
	@echo "Release Configuration: $(RELEASE_CONFIG)"

# Help target
help:
	@echo ""
	@echo "###############################################################################"
	@echo "#                            $(PROJECT_NAME) Makefile                           #"
	@echo "###############################################################################"
	@echo ""
	@echo "Usage:"
	@echo "  make                    # Build release version (default)"
	@echo "  make debug              # Build debug version"
	@echo "  make release            # Build release version"
	@echo "  make run-debug          # Build and run debug version"
	@echo "  make run-release        # Build and run release version"
	@echo "  make test               # Run tests"
	@echo "  make archive            # Create archive for distribution"
	@echo "  make export             # Export archived app"
	@echo "  make install            # Install app to Applications folder"
	@echo "  make uninstall          # Uninstall app from Applications folder"
	@echo "  make clean              # Clean build artifacts"
	@echo "  make info               # Show project information"
	@echo "  make xcode              # Open project in Xcode"
	@echo "  make help               # Show this help message"
	@echo ""
	@echo "Variables:"
	@echo "  DEBUG_CONFIG            # Debug configuration name (default: $(DEBUG_CONFIG))"
	@echo "  RELEASE_CONFIG          # Release configuration name (default: $(RELEASE_CONFIG))"
	@echo ""
	@echo "Build output directory: $(BUILD_PATH)"
	@echo ""

# Silent targets (use -@ to suppress command echo)
.SILENT: clean info

# Phony targets - these don't correspond to files
.PHONY: all debug release clean install uninstall test help xcode info run-debug run-release archive export