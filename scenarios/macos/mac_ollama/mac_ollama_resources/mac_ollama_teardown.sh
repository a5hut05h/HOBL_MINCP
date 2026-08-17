#!/bin/sh
# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

BIN_DIR="/Users/Shared/hobl_bin"
LOG_DIR="/Users/Shared/hobl_data"
LOG_FILE="$LOG_DIR/mac_ollama_teardown.log"
mkdir -p "$LOG_DIR"

log() {
    echo "$1"
    echo "$1" >> "$LOG_FILE"
}

echo "-- mac_ollama_teardown.sh started $(date)" > "$LOG_FILE"
log "-- ollama teardown started"

# Stop the Ollama server (built binary; legacy go-run pattern as fallback)
log "-- Stopping Ollama server"
pkill -f "$BIN_DIR/ollama/ollama serve" 2>/dev/null
pkill -f "go run . serve" 2>/dev/null
pkill -x ollama 2>/dev/null

# Give processes a moment to exit
sleep 2

# Verify server is stopped
if pgrep -f "$BIN_DIR/ollama/ollama serve" > /dev/null 2>&1 || pgrep -f "go run . serve" > /dev/null 2>&1; then
    log "-- Force killing remaining ollama processes"
    pkill -9 -f "$BIN_DIR/ollama/ollama serve" 2>/dev/null
    pkill -9 -f "go run . serve" 2>/dev/null
fi

log "-- ollama teardown completed"
