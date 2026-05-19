#!/bin/sh
# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

# MLPerf Client Run Script for macOS

# Set BIN_DIR to /Users/Shared/hobl_bin
BIN_DIR="/Users/Shared/hobl_bin"
MLPERF_DIR="$BIN_DIR/mac_mlperf"
OUTPUT_DIR="/Users/Shared/hobl_data"
LOG_FILE="$OUTPUT_DIR/mac_mlperf_run.log"

# Get config file from argument, default to phi3.5/macOS_MLX_GPU.json
CONFIG_FILE="${1:-./phi3.5/macOS_MLX_GPU.json}"

# Create output directory if it doesn't exist
if [ ! -d "$OUTPUT_DIR" ]; then
    mkdir -p "$OUTPUT_DIR"
fi

log() {
    echo "$1"
    echo "$1" >> "$LOG_FILE"
}

echo "-- mac_mlperf_run.sh started $(date)" > "$LOG_FILE"
log "-- MLPerf run started"

# Load environment
if [ -f ~/.zprofile ]; then
    source ~/.zprofile
fi

# Change to mlperf directory
if [ ! -d "$MLPERF_DIR" ]; then
    log " ERROR - MLPerf directory not found: $MLPERF_DIR"
    log "Please run mac_mlperf_prep.sh first"
    exit 1
fi

log "-- Changing directory to: $MLPERF_DIR"
cd "$MLPERF_DIR"

# Verify mlperf executable exists
MLPERF_EXE="./mlperf-mac"
if [ ! -f "$MLPERF_EXE" ]; then
    log " ERROR - MLPerf executable not found: $MLPERF_EXE"
    exit 1
fi

# Verify config file exists
if [ ! -f "$CONFIG_FILE" ]; then
    log " ERROR - Config file not found: $CONFIG_FILE"
    exit 1
fi

log "-- Using config file: $CONFIG_FILE"

# Create output directory if it doesn't exist
if [ ! -d "$OUTPUT_DIR" ]; then
    log "-- Creating output directory: $OUTPUT_DIR"
    mkdir -p "$OUTPUT_DIR"
fi

# Delete existing results.json to prevent appended/corrupted results
RESULTS_FILE="$OUTPUT_DIR/results.json"
if [ -f "$RESULTS_FILE" ]; then
    log "-- Deleting existing results file: $RESULTS_FILE"
    rm -f "$RESULTS_FILE"
fi

# Run MLPerf benchmark
log "-- Running MLPerf benchmark..."
log "   Command: $MLPERF_EXE --config $CONFIG_FILE --temp-dir . --output-dir $OUTPUT_DIR --download_behaviour skip_all --pause false"

# Redirect output to a per-phase log so it is preserved in the results share.
# Without redirection, stdout goes only to the RPC buffer and is lost on timeout.
MLPERF_LOG="$OUTPUT_DIR/mac_mlperf_run_output.log"
log "-- MLPerf output: $MLPERF_LOG"
"$MLPERF_EXE" --config "$CONFIG_FILE" --temp-dir . --output-dir "$OUTPUT_DIR" --download_behaviour skip_all --pause false > "$MLPERF_LOG" 2>&1

EXIT_CODE=$?
if [ $EXIT_CODE -ne 0 ]; then
    log " ERROR - MLPerf benchmark failed with exit code: $EXIT_CODE. See $MLPERF_LOG for details."
    exit $EXIT_CODE
fi

log "-- MLPerf benchmark completed successfully"

# Parse results.json file
if [ ! -f "$RESULTS_FILE" ]; then
    log "WARNING: Results file not found: $RESULTS_FILE"
    log "-- MLPerf run completed"
    exit 0
fi

log "-- Parsing results from: $RESULTS_FILE"

# Extract and display key metrics using Python (available on macOS)
python3 << 'EOF'
import json
import sys
import math

try:
    with open('/Users/Shared/hobl_data/results.json', 'r') as f:
        data = json.load(f)
    
    # Check if benchmark succeeded
    if not data.get('Benchmark Success', False):
        err_msg = data.get('Error Message', 'Unknown error').replace('\n', ' ').strip()
        print(f" ERROR - MLPerf benchmark failed: {err_msg}")
        sys.exit(1)
    
    overall_results = data.get('overall_results')
    
    # Parse Benchmark Duration (HH:MM:SS.mmm) to seconds
    benchmark_duration = data.get('Benchmark Duration', '00:00:00.000')
    parts = benchmark_duration.split(':')
    scenario_runtime = round(int(parts[0]) * 3600 + int(parts[1]) * 60 + float(parts[2]), 3)
    
    # If overall_results is null/None, compute geomeans from category_results
    # The 5 categories are: Code Analysis, Content Generation, Creative Writing,
    # Summarization Light, Summarization Moderate
    if not overall_results:
        print("overall_results is null, computing geomeans from category_results")
        category_results = data.get('category_results', {})
        if category_results:
            categories = list(category_results.values())
            count = len(categories)
            
            ttft_values = [c['Avg Time to First Token'] for c in categories]
            tps_values = [c['Avg 2nd+ Token Generation Rate'] for c in categories]
            token_counts = [c['Avg Generated Tokens'] for c in categories]
            
            # Geometric mean = (product of values)^(1/n)
            geomean_ttft = math.prod(ttft_values) ** (1.0 / count)
            geomean_tps = math.prod(tps_values) ** (1.0 / count)
            avg_tokens = round(sum(token_counts) / count)
            
            overall_results = {
                'Geomean Time to First Token': geomean_ttft,
                'Geomean 2nd+ Token Generation Rate': geomean_tps,
                'Avg Generated Tokens': avg_tokens
            }
        else:
            print(" ERROR - Neither overall_results nor category_results found in results.json", file=sys.stderr)
            sys.exit(1)
    
    # Create output object
    # Note: The Geomean fields are geometric means across the 5 prompt categories (Code Analysis,
    # Content Generation, Creative Writing, Summarization Light, Summarization Moderate),
    # which makes them a fair single-number summary since the categories have very different
    # input/output lengths.
    output = {
        'time_to_first_token_ms': round(overall_results.get('Geomean Time to First Token', 0) * 1000, 2),
        'time_to_first_token_s': round(overall_results.get('Geomean Time to First Token', 0), 4),
        'tokens_per_second': round(overall_results.get('Geomean 2nd+ Token Generation Rate', 0), 2),
        'total_tokens_generated': overall_results.get('Avg Generated Tokens', 0),
        'total_generation_time_s': None,
        'scenario_runtime': scenario_runtime,
        'ai_model': data.get('Model Name', ''),
        'ai_device': data.get('Device Type', '')
    }
    
    # Print metrics summary
    print("")
    print("========================================")
    print("MLPerf Metrics Summary")
    print("========================================")
    print(f"Time to First Token: {output['time_to_first_token_ms']}ms ({output['time_to_first_token_s']}s)")
    print(f"Tokens per Second:   {output['tokens_per_second']}")
    print(f"Total Tokens:        {output['total_tokens_generated']}")
    print(f"Model:               {output['ai_model']}")
    print(f"Device:              {output['ai_device']}")
    print(f"Scenario Runtime:    {output['scenario_runtime']}s")
    print("========================================")
    
    # Output as JSON
    print("\n=== Results (JSON Format) ===")
    print(json.dumps(output, indent=2))
    
    # Output as CSV
    print("\n=== Results (CSV Format) ===")
    for key, value in output.items():
        print(f"{key},{value}")
    
    # Save both formats to files
    with open('/Users/Shared/hobl_data/mlperf_formatted_results.json', 'w') as f:
        json.dump(output, f, indent=2)
    
    with open('/Users/Shared/hobl_data/mac_mlperf_results.csv', 'w') as f:
        for key, value in output.items():
            f.write(f"{key},{value}\n")
    
    print("\nResults saved to:")
    print("  /Users/Shared/hobl_data/mlperf_formatted_results.json")
    print("  /Users/Shared/hobl_data/mac_mlperf_results.csv")

except Exception as e:
    print(f" ERROR - Failed to parse results: {e}", file=sys.stderr)
    sys.exit(1)
EOF

if [ $? -ne 0 ]; then
    log " ERROR - Failed to parse results"
    exit 1
fi

log "-- MLPerf run completed successfully"
exit 0
