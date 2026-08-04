#!/bin/sh
# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

# Set BIN_DIR to /Users/Shared/hobl_bin
BIN_DIR="/Users/Shared/hobl_bin"
LOG_DIR="/Users/Shared/hobl_data"
LOG_FILE="$LOG_DIR/mac_ollama_prep.log"
export SUDO_ASKPASS=$BIN_DIR/get_password.sh

# Create log directory if it doesn't exist
if [ ! -d "$LOG_DIR" ]; then
    mkdir -p "$LOG_DIR"
fi

log() {
    echo "$1"
    echo "$1" >> "$LOG_FILE"
}

check() {
    if [ $1 -ne 0 ]; then
        log " ERROR - Last command failed with exit code: $1"
        exit $1
    fi
}

# Initialize log file
echo "-- ollama prep started" > "$LOG_FILE"

log "-- ollama prep started"

log "-- Installing XCode tools"
# xcode-select --install returns non-zero when CLT is already present; ignore rc.
xcode-select --install

if [ ! -d "$BIN_DIR" ]; then
    log " ERROR - Directory $BIN_DIR does not exist"
    exit 1
fi

log "-- Changing to $BIN_DIR"
cd $BIN_DIR

log "-- Cloning repo"
if [ -d "$BIN_DIR/ollama/.git" ]; then
    log "-- ollama repo already present at $BIN_DIR/ollama; reusing existing clone"
else
    if [ -e "$BIN_DIR/ollama" ]; then
        log " ERROR - $BIN_DIR/ollama exists but is not a git repo; remove it manually and re-prep"
        exit 1
    fi
    git clone https://github.com/ollama/ollama.git
    check $?
fi
cd $BIN_DIR/ollama
log "-- Checkout version 0.20.8-rc0"
git fetch --tags --quiet
git checkout v0.20.8-rc0
check $?

log "-- Install Brew"
export NONINTERACTIVE=1
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
eval "$(/opt/homebrew/bin/brew shellenv)"

log "-- Install go"
brew install go@1.25
check $?

# go@1.25 is keg-only and not symlinked into /opt/homebrew, add to PATH
export PATH="/opt/homebrew/opt/go@1.25/bin:$PATH"

# Persist to ~/.zprofile if not already present
if ! grep -q 'go@1.25/bin' ~/.zprofile 2>/dev/null; then
    echo '' >> ~/.zprofile
    echo '# Added by ollama prep - go@1.25 is keg-only' >> ~/.zprofile
    echo 'export PATH="/opt/homebrew/opt/go@1.25/bin:$PATH"' >> ~/.zprofile
    log "-- Added go@1.25 to ~/.zprofile"
else
    log "-- go@1.25 already in ~/.zprofile"
fi

log "-- Download modules"
cd $BIN_DIR/ollama
go mod tidy
check $?

log "-- Building ollama binary"
cd $BIN_DIR/ollama
go build -o ollama .
check $?
if [ ! -x "$BIN_DIR/ollama/ollama" ]; then
    log " ERROR - go build completed but $BIN_DIR/ollama/ollama was not produced"
    exit 1
fi
log "-- Built ollama at: $BIN_DIR/ollama/ollama"
./ollama --version 2>&1 | while IFS= read -r line; do log "ollama: $line"; done

log "-- ollama prep completed"
exit 0