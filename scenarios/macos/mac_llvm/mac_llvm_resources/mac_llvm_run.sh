#!/bin/sh
# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

# LLVM clean build script for macOS
# Cleans and rebuilds LLVM, measures build time with /usr/bin/time

BIN_DIR="/Users/Shared/hobl_bin"
BUILD_DIR="$BIN_DIR/build_llvm"
LLVM_SRC_DIR="$BIN_DIR/llvm-project"
DATA_DIR="/Users/Shared/hobl_data"
METRICS_FILE="$DATA_DIR/mac_llvm_results.csv"
LOG_FILE="$DATA_DIR/mac_llvm_run.log"

# Create data directory if it doesn't exist
if [ ! -d "$DATA_DIR" ]; then
    mkdir -p "$DATA_DIR"
fi

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

# Helper function to parse time output and calculate cputime
# Args: $1 = time log file, $2 = phase name prefix (e.g., "build")
# Sets: <prefix>_real, <prefix>_user, <prefix>_sys, <prefix>_cputime
#
# Time metrics explained:
#   Real - Wall clock time from start to finish of the call. This is all elapsed time
#          including time slices used by other processes and time the process spends
#          blocked (for example if it is waiting for I/O to complete).
#
#   User - The amount of CPU time spent in user-mode code (outside the kernel) within
#          the process. This is only actual CPU time used in executing the process.
#          Other processes and time the process spends blocked do not count towards
#          this figure.
#
#   Sys  - The amount of CPU time spent in the kernel within the process. This means
#          executing CPU time spent in system calls within the kernel, as opposed to
#          library code, which is still running in user-space. Like 'user', this is
#          only CPU time used by the process.
#
#   User+Sys (cputime) - How much actual CPU time your process used. Note that this is
#          across all CPUs, so if the process has multiple threads on a multi-processor
#          system, it could potentially exceed the wall clock time reported by 'Real'.
#          These figures include the 'User' and 'Sys' time of all child processes when
#          they could have been collected (e.g., by wait(2) or waitpid(2)).
#
parse_time_output() {
    local time_file="$1"
    local prefix="$2"

    if [ ! -f "$time_file" ]; then
        log " ERROR - Time log file not found: $time_file"
        return 1
    fi

    # Parse the -p format output (real, user, sys on separate lines)
    local real_val=$(grep "^real" "$time_file" | awk '{print $2}')
    local user_val=$(grep "^user" "$time_file" | awk '{print $2}')
    local sys_val=$(grep "^sys" "$time_file" | awk '{print $2}')

    # Calculate cputime = user + sys
    local cputime=$(echo "$user_val + $sys_val" | bc)

    # Export values using eval for dynamic variable names
    eval "${prefix}_real=$real_val"
    eval "${prefix}_user=$user_val"
    eval "${prefix}_sys=$sys_val"
    eval "${prefix}_cputime=$cputime"

    log "✓ Parsed $prefix phase: real=${real_val}s, user=${user_val}s, sys=${sys_val}s, cputime=${cputime}s"
}

echo "-- mac_llvm_run.sh started $(date)" > "$LOG_FILE"
log "-- mac_llvm run started"

# Source profile
if [ -f ~/.zprofile ]; then
    source ~/.zprofile
    check_status "Loading profile"
else
    echo " ERROR - ~/.zprofile not found"
    exit 1
fi

# Verify required commands are available
log "-- Verifying required commands"
check_command "cmake" || exit 1
check_command "ninja" || exit 1
check_command "sysctl" || exit 1

# Verify build directory exists
log "-- Verifying build directory"
if [ ! -d "$BUILD_DIR" ]; then
    log " ERROR - LLVM build directory not found: $BUILD_DIR"
    log "Please run mac_llvm_prep.sh first"
    exit 1
fi
log "✓ LLVM build directory exists"

cd "$BUILD_DIR" || {
    log " ERROR - Failed to change to $BUILD_DIR"
    exit 1
}
log "✓ Current directory: $(pwd)"

# Verify CMake build was configured
if [ ! -f "CMakeCache.txt" ]; then
    log " ERROR - CMakeCache.txt not found"
    log "Please run mac_llvm_prep.sh first"
    exit 1
fi
log "✓ CMake build directory verified"

# Clean previous build outputs
log "-- Cleaning previous build outputs"
ninja -t clean 2>/dev/null || log "   No previous build to clean"

CORES=$(sysctl -n hw.ncpu)
log "-- Building LLVM with $CORES cores"

# Redirect ninja output to a per-phase log so it is preserved in the results
# share. Without redirection, stdout goes only to the RPC buffer and is lost
# on timeout (LLVM is the longest scenario, so this risk is real).
BUILD_LOG="$DATA_DIR/mac_llvm_build.log"
log "-- Build output: $BUILD_LOG"

# Build LLVM with timing
/usr/bin/time -p -o "$DATA_DIR/mac_llvm_build_time.log" ninja -j$CORES > "$BUILD_LOG" 2>&1
BUILD_STATUS=$?

if [ $BUILD_STATUS -ne 0 ]; then
    log " ERROR - LLVM build failed with exit code $BUILD_STATUS. See $BUILD_LOG for details."
    exit 1
fi
log "✓ LLVM build completed successfully"

# Parse build phase timing
parse_time_output "$DATA_DIR/mac_llvm_build_time.log" "build"

# Confirm build by checking for clang binary
log "-- Confirming build"
if [ ! -f "$BUILD_DIR/bin/clang" ]; then
    log " ERROR - clang binary not found after build"
    exit 1
fi
log "✓ clang binary found"

$BUILD_DIR/bin/clang --version
check_status "Running clang --version"

# ============================================================================
# Save metrics
# ============================================================================
# Use real (wall clock) time for scenario_runtime as it represents actual elapsed time
scenario_runtime=$build_real

log ""
log "========================================"
log "LLVM Build Metrics Summary"
log "========================================"
log "Build Phase: real=${build_real}s, user=${build_user}s, sys=${build_sys}s, cputime=${build_cputime}s"
log "scenario_runtime (total real time): ${scenario_runtime}s"
log "========================================"

# Write metrics CSV file (key,value format)
cat > "$METRICS_FILE" << EOF
scenario_runtime,$scenario_runtime
build_real,$build_real
build_user,$build_user
build_sys,$build_sys
build_cputime,$build_cputime
EOF

log "✓ Metrics saved to: $METRICS_FILE"

log "-- mac_llvm run completed"
exit 0
