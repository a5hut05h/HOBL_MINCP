#!/bin/sh
# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

# Set BIN_DIR to /Users/Shared/hobl_bin
BIN_DIR="/Users/Shared/hobl_bin"
export SUDO_ASKPASS=$BIN_DIR/get_password.sh
LOG_DIR="/Users/Shared/hobl_data"
LOG_FILE="$LOG_DIR/mac_pytorch_inf_prep.log"
mkdir -p "$LOG_DIR"

log() {
    echo "$1"
    echo "$1" >> "$LOG_FILE"
}

check_status() {
    if [ $? -ne 0 ]; then
        log " ERROR - $1 failed"
        exit 1
    fi
    log "✓ $1 successful"
}

check_command() {
    if command -v "$1" >/dev/null 2>&1; then
        log "✓ $1 is available"
        return 0
    else
        log " ERROR - $1 is not available"
        return 1
    fi
}

# Always copy resources to pick up script/config changes
log "-- Copying resources to $BIN_DIR/mac_pytorch_inf_resources"
SRC_RES_DIR="$(cd "$(dirname "$0")" && pwd)"
DST_RES_DIR="$BIN_DIR/mac_pytorch_inf_resources"
mkdir -p "$DST_RES_DIR"
check_status "resource directory creation"
if [ "$SRC_RES_DIR" = "$DST_RES_DIR" ]; then
    log "✓ Resource copy skipped (already running from $DST_RES_DIR)"
else
    cp -r "$SRC_RES_DIR"/* "$DST_RES_DIR/"
    check_status "resource copy"
fi

echo "-- mac_pytorch_inf_prep.sh started $(date)" > "$LOG_FILE"
log "-- pytorch_inf prep started"

# Check if BIN_DIR exists
if [ ! -d "$BIN_DIR" ]; then
    log " ERROR - $BIN_DIR does not exist"
    exit 1
fi

# --- Install Homebrew ---
log "-- Installing Brew"
if [ -x /opt/homebrew/bin/brew ]; then
    log "✓ Brew already installed at /opt/homebrew/bin/brew"
else
    export NONINTERACTIVE=1
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    check_status "Brew installation"
fi

if [ ! -x /opt/homebrew/bin/brew ]; then
    log " ERROR - Homebrew not found at /opt/homebrew/bin/brew"
    exit 1
fi
eval "$(/opt/homebrew/bin/brew shellenv)"

log "-- Installing readline and xz"
brew install readline xz
check_status "readline and xz installation"

# --- Install pyenv ---
log "-- Installing pyenv"
brew install pyenv pyenv-virtualenv
check_status "pyenv installation"

log "-- Modifying profile"

# Add brew shellenv if not already there
if ! grep -q 'eval "$(/opt/homebrew/bin/brew shellenv)"' ~/.zprofile 2>/dev/null; then
    echo '# brew variables and PATH' >> ~/.zprofile
    echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
    log "✓ Added brew to profile"
else
    log "✓ brew already in profile"
fi

# Add pyenv init if not already there
if ! grep -q "pyenv init" ~/.zprofile 2>/dev/null; then
    echo '# for pyenv and pyenv-virtualenv' >> ~/.zprofile
    echo 'eval "$(pyenv init -)"' >> ~/.zprofile
    echo 'eval "$(pyenv virtualenv-init -)"' >> ~/.zprofile
    log "✓ Added pyenv to profile"
else
    log "✓ pyenv already in profile"
fi

# Source profile to load environment
source ~/.zprofile

check_command "pyenv" || exit 1

# --- Install Python ---
log "-- Installing Python 3.12.10"
pyenv install 3.12.10 -f
check_status "Python 3.12.10 installation"

log "-- Setting Python version"
pyenv global 3.12.10
check_status "Setting Python global version"

# Verify Python version
PYTHON_VERSION=$(python --version 2>&1 | awk '{print $2}')
if [ "$PYTHON_VERSION" != "3.12.10" ]; then
    log " ERROR - Python version is $PYTHON_VERSION, expected 3.12.10"
    pyenv versions
    exit 1
fi
log "✓ Python version confirmed: $PYTHON_VERSION"
log "Python path: $(which python)"
log "Pip path: $(python -m pip --version)"

# --- CD to resources ---
log "-- CD to resources"
cd $BIN_DIR/mac_pytorch_inf_resources
if [ $? -ne 0 ]; then
    log " ERROR - Failed to change directory to $BIN_DIR/mac_pytorch_inf_resources"
    exit 1
fi

if [ ! -f "requirements_osx.txt" ]; then
    log " ERROR - requirements_osx.txt file not found"
    exit 1
fi

# --- Install Python packages ---
log "-- Installing Python packages from requirements_osx.txt"
python -m pip install -r requirements_osx.txt
check_status "Python package installation"

# --- Download model ---
log "-- Setup LLM Phi-4-mini inferencing"
python inference.py --setup
check_status "Model setup"

log "-- pytorch_inf prep completed"
exit 0