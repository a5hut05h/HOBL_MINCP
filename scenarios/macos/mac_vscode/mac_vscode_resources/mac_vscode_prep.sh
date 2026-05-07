#!/bin/sh
# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

BIN_DIR="/Users/Shared/hobl_bin"
export SUDO_ASKPASS=$BIN_DIR/get_password.sh
LOG_DIR="/Users/Shared/hobl_data"
LOG_FILE="$LOG_DIR/mac_vscode_prep.log"
mkdir -p "$LOG_DIR"

log() {
    echo "$1"
    echo "$1" >> "$LOG_FILE"
}

# Helper function for error checking
check_status() {
    if [ $? -ne 0 ]; then
        log " ERROR - $1 failed"
        exit 1
    fi
    log "✓ $1 successful"
}

# Helper function to verify command exists
check_command() {
    if command -v "$1" >/dev/null 2>&1; then
        log "✓ $1 is available"
        return 0
    else
        log " ERROR - $1 is not available"
        return 1
    fi
}

echo "-- mac_vscode_prep.sh started $(date)" > "$LOG_FILE"
log "-- vscode prep started"

# Detect processor architecture
ARCH=$(uname -m)
log "-- Detected architecture: $ARCH"

if [ "$ARCH" != "arm64" ]; then
    log " ERROR - This script is for Apple Silicon (ARM64) only. Detected: $ARCH"
    exit 1
fi

if [ ! -d "$BIN_DIR" ]; then
    log " ERROR - $BIN_DIR does not exist"
    exit 1
fi

cd $BIN_DIR || { log " ERROR - Failed to change to $BIN_DIR"; exit 1; }

# 1. Ensure Xcode command-line tools are installed
log "-- Checking Xcode command-line tools"
if ! xcode-select -p >/dev/null 2>&1; then
    log "-- Installing Xcode command-line tools..."
    xcode-select --install
    log " ERROR - Please complete the Xcode installation dialog and re-run this script"
    exit 1
else
    log "✓ Xcode command-line tools already installed"
fi

# 2. Install Homebrew (if not already installed)
log "-- Checking Homebrew installation"
if [ -x /opt/homebrew/bin/brew ]; then
    log "✓ Brew already installed at /opt/homebrew/bin/brew"
else
    log "-- Installing Homebrew..."
    export NONINTERACTIVE=1
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    check_status "Brew installation"
fi

if [ ! -x /opt/homebrew/bin/brew ]; then
    log " ERROR - Homebrew not found at /opt/homebrew/bin/brew"
    exit 1
fi
eval "$(/opt/homebrew/bin/brew shellenv)"

# 3. Install Node.js 22
log "-- Checking Node.js installation"
if command -v node >/dev/null 2>&1 && node --version | grep -q "^v22"; then
    log "✓ Node.js 22 already installed: $(node --version)"
else
    log "-- Installing Node.js 22..."
    brew install node@22
    check_status "Node.js 22 installation"
    brew link node@22 --force --overwrite
    check_status "Node.js 22 linking"
fi
check_command "node" || exit 1
log "-- Node.js version: $(node --version)"

# 4. Install readline and xz (needed for pyenv Python builds)
log "-- Installing readline and xz"
brew install readline xz
check_status "readline and xz installation"

# 5. Install pyenv and Python
log "-- Checking pyenv installation"
if ! command -v pyenv >/dev/null 2>&1; then
    log "-- Installing pyenv and pyenv-virtualenv..."
    brew install pyenv pyenv-virtualenv
    check_status "pyenv installation"
fi

log "-- Modifying profile"
if ! grep -q 'eval "$(/opt/homebrew/bin/brew shellenv)"' ~/.zprofile 2>/dev/null; then
    echo '# brew variables and PATH' >> ~/.zprofile
    echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
fi

if ! grep -q "pyenv init" ~/.zprofile 2>/dev/null; then
    echo '# for pyenv and pyenv-virtualenv' >> ~/.zprofile
    echo 'eval "$(pyenv init -)"' >> ~/.zprofile
    echo 'eval "$(pyenv virtualenv-init -)"' >> ~/.zprofile
fi

source ~/.zprofile
check_command "pyenv" || exit 1

log "-- Installing Python 3.10.11"
pyenv install 3.10.11 -f
check_status "Python 3.10.11 installation"

log "-- Setting Python version"
pyenv global 3.10.11
check_status "Setting Python global version"

PYTHON_VERSION=$(python --version 2>&1 | awk '{print $2}')
if [ "$PYTHON_VERSION" != "3.10.11" ]; then
    log " ERROR - Python version is $PYTHON_VERSION, expected 3.10.11"
    pyenv versions
    exit 1
fi
log "✓ Python version confirmed: $PYTHON_VERSION"

# 6. Clone VS Code repository
VSCODE_DIR="$BIN_DIR/vscode"
log "-- Checking VS Code repository"
if [ -d "$VSCODE_DIR" ]; then
    log "✓ VS Code repository already exists at: $VSCODE_DIR"
else
    log "-- Cloning VS Code repository..."
    cd $BIN_DIR || { log " ERROR - Failed to change to $BIN_DIR"; exit 1; }
    git clone https://github.com/microsoft/vscode.git
    check_status "VS Code clone"
fi

cd "$VSCODE_DIR" || { log " ERROR - Failed to change to $VSCODE_DIR"; exit 1; }
log "✓ Current directory: $(pwd)"

# Checkout specific version
log "-- Checking out VS Code version 1.106.2"
git checkout 1.106.2
check_status "VS Code checkout v1.106.2"

# 7. Install npm dependencies
log "-- Installing npm dependencies (this may take 10-20 minutes)..."
# First attempt - this will fail on @vscode/spdlog due to Apple Clang consteval issue on Darwin 25.4+
npm install --loglevel=error 2>/dev/null

# Patch bundled fmt in @vscode/spdlog to work around Apple Clang consteval issue
SPDLOG_FMT_DIR="node_modules/@vscode/spdlog/deps/spdlog/include/spdlog/fmt/bundled"
if [ -d "$SPDLOG_FMT_DIR" ]; then
    log "-- Patching spdlog fmt headers (consteval -> constexpr)"
    sed -i '' 's/consteval/constexpr/g' "$SPDLOG_FMT_DIR/format.h"
    sed -i '' 's/consteval/constexpr/g' "$SPDLOG_FMT_DIR/core.h"
    check_status "spdlog fmt patch"

    # Rebuild just spdlog with the patched source (npm uses its bundled node-gyp)
    log "-- Rebuilding @vscode/spdlog..."
    npm rebuild @vscode/spdlog
    check_status "spdlog rebuild"
else
    log "-- No spdlog fmt patch needed"
fi

# Re-run npm install to complete any remaining steps (postinstall, etc.)
log "-- Completing npm install..."
npm install --loglevel=error
check_status "npm install"

log ""
log "✓ All checks passed"
log "-- vscode prep completed successfully"
exit 0
