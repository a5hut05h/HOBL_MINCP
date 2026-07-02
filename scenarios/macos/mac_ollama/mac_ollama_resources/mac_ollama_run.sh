#!/bin/sh
# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

# Set BIN_DIR to /Users/Shared/hobl_bin
BIN_DIR="/Users/Shared/hobl_bin"
LOG_DIR="/Users/Shared/hobl_data"
LOG_FILE="$LOG_DIR/mac_ollama_run.log"
MODEL="gemma3"

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
echo "-- ollama workload started" > "$LOG_FILE"

log "-- ollama workload started"

# Detect architecture
ARCH=$(uname -m)
log "Detected architecture: $ARCH"
log "Model: $MODEL"

# Load environment (homebrew and pyenv)
if [ -f ~/.zprofile ]; then
    source ~/.zprofile
fi
eval "$(/opt/homebrew/bin/brew shellenv)" 2>/dev/null || true

cd $BIN_DIR/ollama

OLLAMA_BIN="$BIN_DIR/ollama/ollama"
if [ ! -x "$OLLAMA_BIN" ]; then
    log " ERROR - $OLLAMA_BIN missing or not executable. Prep did not complete."
    log " ERROR - Re-prep required: delete the prep_status file for mac_ollama on the DUT and re-run."
    exit 1
fi

# Disable progress indicator
export NO_COLOR=1

# Run ollama with model, prompt and capture output
# verbose logging adds model execution details
VERBOSE_LOG="$LOG_DIR/mac_ollama_verbose.log"
log "-- Run $MODEL model with prompt"
log "-- Script log: $LOG_FILE"
log "-- Verbose output: $VERBOSE_LOG"
"$OLLAMA_BIN" run $MODEL "what is the meaning of life?" --verbose > $VERBOSE_LOG 2>&1
check $?

log "-- Parsing metrics from verbose log file"

# Example ollama --verbose output for reference:
#   total duration:       28.924842625s
#   load duration:        12.713512958s
#   prompt eval count:    16 token(s)
#   prompt eval duration: 99.495083ms
#   prompt eval rate:     160.81 tokens/s
#   eval count:           1024 token(s)
#   eval duration:        16.110097042s
#   eval rate:            63.56 tokens/s

# Read the verbose log file content
content=$(cat $VERBOSE_LOG)

# Extract total duration (used as scenario_runtime)
# Format can be Xm.Ys or X.Ys
total_duration_raw=$(echo "$content" | grep -o 'total duration:[[:space:]]*[0-9]*m[0-9.]*s' | sed 's/total duration:[[:space:]]*//')
if [ -z "$total_duration_raw" ]; then
    total_duration_raw=$(echo "$content" | grep -o 'total duration:[[:space:]]*[0-9.]*s' | awk '{print $3}')
    total_duration_seconds=$(echo "$total_duration_raw" | sed 's/s$//')
else
    td_minutes=$(echo "$total_duration_raw" | sed 's/m.*//')
    td_seconds=$(echo "$total_duration_raw" | sed 's/.*m//' | sed 's/s$//')
    total_duration_seconds=$(echo "$td_minutes * 60 + $td_seconds" | bc)
fi
SCENARIO_RUNTIME=${total_duration_seconds:-0}

# Extract prompt eval duration (TTFT)
prompt_eval_duration=$(echo "$content" | grep -o 'prompt eval duration:[[:space:]]*[0-9.]*[a-z]*' | awk '{print $4}')
prompt_eval_unit=$(echo "$prompt_eval_duration" | grep -o '[a-z]*$')
prompt_eval_value=$(echo "$prompt_eval_duration" | grep -o '^[0-9.]*')

# Extract eval rate (tokens per second)
eval_rate=$(echo "$content" | grep -v 'prompt eval rate' | grep -o 'eval rate:[[:space:]]*[0-9.]*[[:space:]]*tokens/s' | awk '{print $3}')

# Extract eval count (total tokens generated)
eval_count=$(echo "$content" | grep -v 'prompt eval count' | grep -o 'eval count:[[:space:]]*[0-9]*[[:space:]]*token' | awk '{print $3}')

# Extract eval duration (total generation time)
eval_duration=$(echo "$content" | grep -v 'prompt eval duration' | grep -o 'eval duration:[[:space:]]*[0-9]*m[0-9.]*s' | sed 's/eval duration:[[:space:]]*//')
if [ -z "$eval_duration" ]; then
    eval_duration=$(echo "$content" | grep -v 'prompt eval duration' | grep -o 'eval duration:[[:space:]]*[0-9.]*s' | awk '{print $3}')
    eval_duration_seconds=$(echo "$eval_duration" | sed 's/s$//')
else
    eval_minutes=$(echo "$eval_duration" | sed 's/m.*//')
    eval_seconds=$(echo "$eval_duration" | sed 's/.*m//' | sed 's/s$//')
    eval_duration_seconds=$(echo "$eval_minutes * 60 + $eval_seconds" | bc)
fi

# Convert prompt eval duration to seconds
case "$prompt_eval_unit" in
    ms)
        time_to_first_token_s=$(echo "scale=6; $prompt_eval_value / 1000" | bc)
        ;;
    s)
        time_to_first_token_s=$prompt_eval_value
        ;;
    m)
        time_to_first_token_s=$(echo "scale=6; $prompt_eval_value * 60" | bc)
        ;;
    *)
        time_to_first_token_s=$prompt_eval_value
        ;;
esac

# Calculate time to first token in milliseconds
time_to_first_token_ms=$(echo "scale=3; $time_to_first_token_s * 1000" | bc)

# Set other metrics
tokens_per_second=${eval_rate:-0}
total_tokens_generated=${eval_count:-0}
total_generation_time_s=${eval_duration_seconds:-0}
device=""

# ============================================================================
# Save results
# ============================================================================
log ""
log "========================================"
log "Ollama Metrics Summary"
log "========================================"
log "Time to First Token: ${time_to_first_token_ms}ms (${time_to_first_token_s}s)"
log "Tokens per Second:   $tokens_per_second"
log "Total Tokens:        $total_tokens_generated"
log "Generation Time:     ${total_generation_time_s}s"
log "Model:               $MODEL"
log "Scenario Runtime:    ${SCENARIO_RUNTIME}s"
log "Architecture:        $ARCH"
log "========================================"

# Create JSON output
JSON_OUTPUT_FILE="$LOG_DIR/mac_ollama_inference_info.json"
cat > $JSON_OUTPUT_FILE << EOF
{
  "scenario_runtime": $SCENARIO_RUNTIME,
  "time_to_first_token_ms": $time_to_first_token_ms,
  "time_to_first_token_s": $time_to_first_token_s,
  "tokens_per_second": $tokens_per_second,
  "total_tokens_generated": $total_tokens_generated,
  "total_generation_time_s": $total_generation_time_s,
  "ai_model": "$MODEL",
  "ai_device": "$device",
  "architecture": "$ARCH"
}
EOF
log "JSON metrics saved to $JSON_OUTPUT_FILE"

# Write metrics CSV file (key,value format - HOBL convention)
METRICS_FILE="$LOG_DIR/mac_ollama_results.csv"
cat > "$METRICS_FILE" << EOF
scenario_runtime,$SCENARIO_RUNTIME
time_to_first_token_ms,$time_to_first_token_ms
time_to_first_token_s,$time_to_first_token_s
tokens_per_second,$tokens_per_second
total_tokens_generated,$total_tokens_generated
total_generation_time_s,$total_generation_time_s
ai_model,$MODEL
ai_device,$device
architecture,$ARCH
EOF
log "Metrics saved to $METRICS_FILE"

log "-- ollama workload completed"
exit 0