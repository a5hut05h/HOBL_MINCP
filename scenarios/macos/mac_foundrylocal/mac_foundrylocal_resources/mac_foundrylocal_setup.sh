#!/bin/sh
# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

# AI Foundry Local setup script for macOS
# Starts the Foundry service and downloads the specified model

BIN_DIR="/Users/Shared/hobl_bin"
LOG_DIR="/Users/Shared/hobl_data"
LOG_FILE="$LOG_DIR/mac_foundrylocal_setup.log"
MODEL="${1:-Phi-3.5-mini-instruct-generic-cpu}"

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

# Clear log file
echo "-- Foundry Local setup started" > "$LOG_FILE"

log "-- Foundry Local setup started"

# Detect architecture
ARCH=$(uname -m)
log "Detected architecture: $ARCH"
log "Model to download: $MODEL"

# Load environment (homebrew)
if [ -f ~/.zprofile ]; then
    source ~/.zprofile
fi
eval "$(/opt/homebrew/bin/brew shellenv)" 2>/dev/null || true

# Add foundry to PATH (installed via install-foundry.command)
export PATH="$HOME/bin:$PATH"

# ============================================================================
# Step 1: Start Foundry service
# ============================================================================
log "Step 1: Starting Foundry service..."

# Spawn the foundry service fully detached: redirect its stdio away from the
# inherited RPC pipes and disown it so the parent shell's exit isn't blocked
# on the daemon and the RPC layer (SimpleRemote) gets EOF on stdout/stderr
# immediately when this script returns. A bare `foundry service start &`
# leaves the daemon owning the script's stdout fd; SimpleRemote then waits
# for EOF and times out at 30 minutes even though setup completed.
FOUNDRY_SERVICE_LOG="$LOG_DIR/mac_foundrylocal_foundry_service.log"
log "Running: foundry service start (background, logs -> $FOUNDRY_SERVICE_LOG)"
nohup foundry service start </dev/null >>"$FOUNDRY_SERVICE_LOG" 2>&1 &
disown 2>/dev/null || true

# Wait for service to be ready
log "Waiting for Foundry service to be ready..."
MAX_ATTEMPTS=90
ATTEMPT=0
SERVICE_READY=false

while [ $ATTEMPT -lt $MAX_ATTEMPTS ] && [ "$SERVICE_READY" = "false" ]; do
    ATTEMPT=$((ATTEMPT + 1))
    sleep 1
    
    STATUS_OUTPUT=$(foundry service status 2>&1)
    
    if echo "$STATUS_OUTPUT" | grep -qi "running\|successfully\|valid"; then
        SERVICE_READY=true
        log "Foundry service ready after $ATTEMPT seconds"
        echo "$STATUS_OUTPUT" | while read line; do log "  $line"; done
    else
        log "Waiting for service... ($ATTEMPT/$MAX_ATTEMPTS)"
    fi
done

if [ "$SERVICE_READY" = "false" ]; then
    log " ERROR - Foundry service did not start within $MAX_ATTEMPTS seconds"
    log "Last status output: $STATUS_OUTPUT"
    exit 1
fi

# ============================================================================
# Step 2: Download model to cache
# ============================================================================
log "Step 2: Downloading model to local cache..."

log "Running: foundry model download $MODEL"
START_TIME=$(date +%s)

DOWNLOAD_OUTPUT=$(foundry model download "$MODEL" 2>&1)
DOWNLOAD_EXIT=$?
echo "$DOWNLOAD_OUTPUT" | while read line; do log "  $line"; done
check $DOWNLOAD_EXIT

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
log "Model download completed in $DURATION seconds"

# ============================================================================
# Step 3: Verify model is cached
# ============================================================================
log "Step 3: Verifying model is cached..."

log "Listing cached models:"
CACHE_OUTPUT=$(foundry cache list 2>&1)
echo "$CACHE_OUTPUT" | while read line; do log "  $line"; done

if echo "$CACHE_OUTPUT" | grep -qi "$MODEL"; then
    log "Model '$MODEL' verified in cache"
else
    log " ERROR - Model '$MODEL' not found in cache"
    exit 1
fi

# ============================================================================
# Summary
# ============================================================================
log ""
log "========================================"
log "Foundry Local setup completed successfully"
log "Model: $MODEL"
log "Download time: $DURATION seconds"
log "========================================"
log "Log file: $LOG_FILE"

exit 0
