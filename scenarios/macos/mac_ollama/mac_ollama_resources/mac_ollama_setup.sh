#!/bin/sh
# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

# Set BIN_DIR to /Users/Shared/hobl_bin
BIN_DIR="/Users/Shared/hobl_bin"
LOG_DIR="/Users/Shared/hobl_data"
LOG_FILE="$LOG_DIR/mac_ollama_setup.log"

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
echo "-- ollama setup started" > "$LOG_FILE"

log "-- ollama setup started"

# Load environment (homebrew and pyenv)
if [ -f ~/.zprofile ]; then
    source ~/.zprofile
fi
eval "$(/opt/homebrew/bin/brew shellenv)" 2>/dev/null || true

cd $BIN_DIR/ollama
if [ $? -ne 0 ]; then
    log " ERROR - Directory does not exist: $BIN_DIR/ollama"
    exit 1
fi

OLLAMA_BIN="$BIN_DIR/ollama/ollama"
if [ ! -x "$OLLAMA_BIN" ]; then
    log " ERROR - $OLLAMA_BIN missing or not executable. Prep did not complete."
    log " ERROR - Re-prep required: delete the prep_status file for mac_ollama on the DUT and re-run."
    exit 1
fi
log "-- Using ollama binary: $OLLAMA_BIN"
"$OLLAMA_BIN" --version 2>&1 | while IFS= read -r line; do log "ollama: $line"; done

log "-- Launching server in background"
SERVER_LOG="$LOG_DIR/mac_ollama_server.log"
: > "$SERVER_LOG"
nohup "$OLLAMA_BIN" serve > "$SERVER_LOG" 2>&1 &
SERVER_PID=$!
log "-- Server PID: $SERVER_PID  (stdout/stderr -> $SERVER_LOG)"

log "-- Waiting for server to be ready..."
max_attempts=30
attempt=0
server_ready=false

while [ $attempt -lt $max_attempts ] && [ "$server_ready" = "false" ]; do
    attempt=$((attempt + 1))
    sleep 1

    # Fail fast if the server process died (crash on startup: port in use,
    # permission issues, GPU init failure, etc.).
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        log " ERROR - ollama serve process (pid $SERVER_PID) exited after $attempt seconds"
        exit 1
    fi

    # Try to connect to ollama's default endpoint
    if curl -s -o /dev/null -w "%{http_code}" "http://localhost:11434/api/tags" | grep -q "200"; then
        server_ready=true
        log "-- Server ready after $attempt seconds"
    else
        log "-- Waiting for server... ($attempt/$max_attempts)"
    fi
done

if [ "$server_ready" = "false" ]; then
    log " ERROR - Server did not start within $max_attempts seconds"
    exit 1
fi

log "-- Pulling gemma3"
PULL_LOG="$LOG_DIR/mac_ollama_pull.log"
"$OLLAMA_BIN" pull gemma3 > "$PULL_LOG" 2>&1
check $?

exit 0