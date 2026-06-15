#!/bin/sh
# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

# Set BIN_DIR to /Users/Shared/hobl_bin
BIN_DIR="/Users/Shared/hobl_bin"
export SUDO_ASKPASS=$BIN_DIR/get_password.sh
LOG_DIR="/Users/Shared/hobl_data"
LOG_FILE="$LOG_DIR/mac_opencv_build_prep.log"
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

echo "-- mac_opencv_build_prep.sh started $(date)" > "$LOG_FILE"
log "-- opencv prep started"

# Check if BIN_DIR exists
if [ ! -d "$BIN_DIR" ]; then
    log " ERROR - $BIN_DIR does not exist"
    exit 1
fi
log "✓ BIN_DIR exists: $BIN_DIR"

# Installing XCode tools
log "-- Installing XCode tools"
if xcode-select -p >/dev/null 2>&1; then
    log "✓ XCode tools already installed"
else
    xcode-select --install 2>/dev/null || true
    
    # Wait for installation to complete (up to 10 minutes)
    log "Waiting for XCode tools installation to complete..."
    MAX_WAIT=600
    ELAPSED=0
    while [ $ELAPSED -lt $MAX_WAIT ]; do
        if xcode-select -p >/dev/null 2>&1; then
            log "✓ XCode tools installation completed"
            break
        fi
        sleep 10
        ELAPSED=$((ELAPSED + 10))
        log "  Still waiting... ($ELAPSED seconds elapsed)"
    done
    
    if ! xcode-select -p >/dev/null 2>&1; then
        log " ERROR - XCode tools installation did not complete within $MAX_WAIT seconds"
        exit 1
    fi
fi

cd $BIN_DIR || {
    log " ERROR - Failed to change to $BIN_DIR"
    exit 1
}

# Clone repo (or verify it exists)
log "-- Cloning repo"
if [ -d "$BIN_DIR/opencv" ]; then
    log "✓ OpenCV repo already exists"
    cd $BIN_DIR/opencv
else
    git clone https://github.com/opencv/opencv.git
    check_status "Git clone"
    cd $BIN_DIR/opencv
fi

log "-- Checkout version 4.10.0"
git checkout tags/4.10.0
check_status "Git checkout 4.10.0"

# Install Brew (or verify it exists at default location)
log "-- Installing Brew"
if [ -x /opt/homebrew/bin/brew ]; then
    log "✓ Brew already installed at /opt/homebrew/bin/brew"
else
    export NONINTERACTIVE=1
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    check_status "Brew installation"
fi

# Verify brew is installed at expected location
if [ ! -x /opt/homebrew/bin/brew ]; then
    log " ERROR - Homebrew not found at /opt/homebrew/bin/brew"
    exit 1
fi
log "✓ Homebrew verified at /opt/homebrew/bin/brew"
eval "$(/opt/homebrew/bin/brew shellenv)"

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

# Verify pyenv is available
check_command "pyenv" || exit 1

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

log "-- Installing CMake and FFmpeg 6"
brew install cmake ffmpeg@6
check_status "CMake and FFmpeg 6 installation"
check_command "cmake" || exit 1

# OpenCV 4.10.0 is compatible with the FFmpeg 6 API surface. Windows uses the
# FFmpeg revision pinned by OpenCV's 4.10 packaging; on macOS Homebrew's rolling
# `ffmpeg` formula can advance to 7.x, which breaks OpenCV 4.10 videoio compile
# with removed APIs like `avcodec_close`. Prefer the keg-only ffmpeg@6 formula
# explicitly so mac stays aligned with the Windows workload.
FFMPEG6_PREFIX="$(/opt/homebrew/bin/brew --prefix ffmpeg@6 2>/dev/null)"
if [ -z "$FFMPEG6_PREFIX" ] || [ ! -d "$FFMPEG6_PREFIX" ]; then
    log " ERROR - ffmpeg@6 prefix could not be resolved"
    exit 1
fi
export PKG_CONFIG_PATH="$FFMPEG6_PREFIX/lib/pkgconfig:$PKG_CONFIG_PATH"
log "✓ Using ffmpeg@6 from: $FFMPEG6_PREFIX"
FFMPEG_VERSION=$(PKG_CONFIG_PATH="$PKG_CONFIG_PATH" pkg-config --modversion libavcodec 2>/dev/null)
if [ -z "$FFMPEG_VERSION" ]; then
    log " ERROR - pkg-config could not resolve libavcodec from ffmpeg@6"
    exit 1
fi
log "✓ libavcodec version resolved via pkg-config: $FFMPEG_VERSION"

log "-- Creating build directory"
# Force a clean CMake configuration. A stale CMakeCache.txt from a previous prep
# (e.g. one generated before ffmpeg@6 pinning) caches the resolved FFmpeg paths,
# so re-running cmake silently keeps the old ffmpeg (8.x) and breaks the
# OpenCV 4.10 videoio compile with removed APIs like avcodec_close and
# av_stream_get_side_data. Removing the build dir guarantees ffmpeg@6 is picked
# up fresh via PKG_CONFIG_PATH below.
rm -rf $BIN_DIR/build_opencv
mkdir -p $BIN_DIR/build_opencv
cd $BIN_DIR/build_opencv || {
    log " ERROR - Failed to change to build_opencv directory"
    exit 1
}

log "-- Configuring cmake"
cmake \
-DCMAKE_BUILD_TYPE=Release \
-DBUILD_EXAMPLES=ON \
-DWITH_PYTHON=OFF \
-DBUILD_opencv_python2=OFF \
-DBUILD_opencv_python3=OFF \
-DBUILD_opencv_python_bindings_generator=OFF \
-DBUILD_opencv_python_tests=OFF \
-DOPENCV_SKIP_PYTHON_LOADER=ON \
-DOPENCV_PYTHON_SKIP_DETECTION=ON \
-DBUILD_PERF_TESTS=OFF \
-DBUILD_TESTS=OFF \
-DPYTHON_EXECUTABLE= \
-DPYTHON3_EXECUTABLE= \
-DPYTHON2_EXECUTABLE= \
../opencv
check_status "CMake configuration"

log ""
log "✓ All checks passed"
log "-- opencv prep completed successfully"
exit 0