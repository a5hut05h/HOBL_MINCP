# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

param(
    [string]$logFile = "",
    [string]$customResourcesPath = "",
    [switch]$useCustomOllama = $false
)

$scriptDrive = Split-Path -Qualifier $PSScriptRoot
if (-not (Test-Path "$scriptDrive\hobl_data")) {
    Write-Host " ERROR - Required directory not found: $scriptDrive\hobl_data" -ForegroundColor Red
    Exit 1
}
if (-not (Test-Path "$scriptDrive\hobl_bin")) {
    Write-Host " ERROR - Required directory not found: $scriptDrive\hobl_bin" -ForegroundColor Red
    Exit 1
}
if (-not $logFile) { $logFile = "$scriptDrive\hobl_data\ollama_prep.log" }

# Set execution policy for current process (required for Expand-Archive on fresh installs)
$executionPolicy = Get-ExecutionPolicy -Scope Process
if ($executionPolicy -eq "Restricted" -or $executionPolicy -eq "Undefined") {
    Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope Process -Force -ErrorAction Stop
}

# Require PowerShell > 7
$required = [version]"7.0"
if (-not $PSVersionTable.PSVersion) {
    Write-Host "Cannot determine PowerShell version; aborting." -ForegroundColor Red
    Exit 1
}
if ([version]$PSVersionTable.PSVersion -le $required) {
    Write-Host "This script requires PowerShell greater than $required. Current: $($PSVersionTable.PSVersion)" -ForegroundColor Yellow
    Write-Host "Please install PowerShell 7 or later from https://aka.ms/powershell" -ForegroundColor Yellow
    Exit 1
}

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Determine processor architecture and set appropriate variables
$osInfo = Get-CimInstance Win32_OperatingSystem
$arch = $osInfo.OSArchitecture
$processorArch = $env:PROCESSOR_ARCHITECTURE

if ($arch -eq "64-bit" -and $processorArch -eq "AMD64") {
    $isARM64 = $false
    $vsArchParam = "x64"
    $vsHostArchParam = "x64"
    $logSuffix = if ($useCustomOllama) { "x64_Custom" } else { "x64" }
    $vsInstallPath = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022"
    $vsProduct = "BuildTools"
} elseif ($arch -match "ARM" -or $processorArch -match "ARM") {
    $isARM64 = $true
    $vsArchParam = "arm64"
    $vsHostArchParam = "arm64"
    $logSuffix = if ($useCustomOllama) { "ARM64_Custom" } else { "ARM64" }
    $vsInstallPath = "${env:ProgramFiles}\Microsoft Visual Studio\2022"
    $vsProduct = "Community"
} else {
    Write-Host " ERROR - Unsupported architecture: $arch (Processor: $processorArch)" -ForegroundColor Red
    Add-Content -Path $logFile -encoding utf8 " ERROR - Unsupported architecture: $arch (Processor: $processorArch)"
    Exit 1
}

# Update log file name to include architecture
$logFile = $logFile -replace "\.log$", "_$($logSuffix.ToLower()).log"

function log {
    [CmdletBinding()] Param([Parameter(ValueFromPipeline)] $msg)
    process {
        if ($msg -Match " ERROR - ") {
            Write-Host $msg -ForegroundColor Red
        } else {
            Write-Host $msg
        }
        Add-Content -Path $logFile -encoding utf8 "$msg"
    }
}

function check {
    param($code)
    if ($code -ne 0) {
        " ERROR - Last command failed." | log
        Exit $code
    }
}

function checkCmd {
    param($code)
    if ($code -ne "True") {
        " ERROR - Last command failed." | log
        Exit 1
    }
}

function checkWinget {
    param($code)
    # Winget exit codes:
    # 0 = Success
    # -1978335189 (0x8A15002B) = Already installed
    # -1978335215 (0x8A150011) = No applicable upgrade found
    # Other non-zero = Actual error
    if ($code -eq 0) {
        "Winget command succeeded" | log
    } elseif ($code -eq -1978335189) {
        "Package already installed (this is OK)" | log
    } elseif ($code -eq -1978335215) {
        "No applicable upgrade found (this is OK)" | log
    } else {
        " ERROR - Winget command failed with exit code: $code" | log
        Exit $code
    }
}

function checkGitClone {
    param($code, $repoPath)
    # Git clone exit codes:
    # 0 = Success
    # 128 = Usually means directory already exists or other repository error
    if ($code -eq 0) {
        "Git clone succeeded" | log
    } elseif ($code -eq 128 -and (Test-Path $repoPath)) {
        "Repository already exists (this is OK)" | log
    } else {
        " ERROR - Git clone failed with exit code: $code" | log
        Exit $code
    }
}

function checkSetLocation {
    param($path)
    if (Test-Path $path) {
        Set-Location $path
        "Changed directory to: $path" | log
    } else {
        " ERROR - Directory does not exist: $path" | log
        Exit 1
    }
}

function getVSVersion {
    param([string]$product)
    
    # vswhere.exe location is always in Program Files (x86) even on ARM64
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) {
        # Fallback for ARM64 where installer might be in Program Files
        $vswhere = "${env:ProgramFiles}\Microsoft Visual Studio\Installer\vswhere.exe"
        if (-not (Test-Path $vswhere)) {
            return $null
        }
    }
    
    try {
        $productFilter = if ($product -eq "BuildTools") { "Microsoft.VisualStudio.Product.BuildTools" } else { "Microsoft.VisualStudio.Product.Community" }
        $instances = & $vswhere -products $productFilter -format json | ConvertFrom-Json
        
        if ($instances) {
            $instance = $instances | Select-Object -First 1
            return @{
                Version = $instance.installationVersion
                DisplayName = $instance.displayName
                Path = $instance.installationPath
            }
        }
    } catch {
        return $null
    }
    
    return $null
}

# Visual Studio Build tools installation using direct installer download
# This is more reliable than winget for VS installations
# Visual Studio installation using direct installer download
# Architecture-aware: Build Tools for x64, Community for ARM64
function installVisualStudio {
    # Get the directory where the script is located
    $scriptDir = Split-Path -Parent $PSCommandPath
    
    if ($isARM64) {
        "-- Installing Visual Studio Community 2022 (direct installer for ARM64)" | log
        $installerUrl = "https://aka.ms/vs/17/release/vs_community.exe"
        $installerPath = "$env:TEMP\vs_community.exe"
        $productName = "VS Community"
        $vsconfigPath = Join-Path $scriptDir ".vsconfig_arm64"
    } else {
        "-- Installing Visual Studio Build Tools 2022 (direct installer for x64)" | log
        $installerUrl = "https://aka.ms/vs/17/release/vs_buildtools.exe"
        $installerPath = "$env:TEMP\vs_buildtools.exe"
        $productName = "VS Build Tools"
        $vsconfigPath = Join-Path $scriptDir ".vsconfig_x64"
    }
    
    # Verify .vsconfig file exists
    if (-not (Test-Path $vsconfigPath)) {
        " ERROR - .vsconfig file not found at: $vsconfigPath" | log
        return $false
    }
    
    "Using .vsconfig file: $vsconfigPath" | log
    
    # Check if VS is already installed by getting version info
    $existingVS = getVSVersion -product $vsProduct
    if ($existingVS -and $existingVS.Path) {
        # VS Installer is in a shared location, not in the product folder
        $sharedInstaller = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\setup.exe"
        
        if (Test-Path $sharedInstaller) {
            "Found existing Visual Studio installer at: $sharedInstaller" | log
            "Using existing installer to apply .vsconfig (handles LTSC and version mismatches)" | log
            $installerPath = $sharedInstaller
        } else {
            "Existing VS installation found but no installer at expected location, downloading new installer..." | log
            
            try {
                Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath
                "$productName installer downloaded successfully" | log
            } catch {
                " ERROR - Failed to download $productName installer: $($_.Exception.Message)" | log
                return $false
            }
            
            if (-not (Test-Path $installerPath)) {
                " ERROR - $productName installer not found after download" | log
                return $false
            }
        }
    } else {
        "No existing Visual Studio installation found, downloading new installer..." | log
        
        try {
            Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath
            "$productName installer downloaded successfully" | log
        } catch {
            " ERROR - Failed to download $productName installer: $($_.Exception.Message)" | log
            return $false
        }
        
        if (-not (Test-Path $installerPath)) {
            " ERROR - $productName installer not found after download" | log
            return $false
        }
    }
    
    if ($existingVS) {
        # Build modify arguments using .vsconfig file and install path
        $installArgs = @(
            "modify"
            "--installPath", "`"$($existingVS.Path)`""
            "--quiet"
            "--config", "`"$vsconfigPath`""
        )
        "Visual Studio Modify args: $($installArgs -join ' ')" | log
    } else {
        # Build install arguments using .vsconfig file
        $installArgs = @(
            "install"
            "--quiet"
            "--wait"
            "--config", "`"$vsconfigPath`""
        )
        "Visual Studio Install args: $($installArgs -join ' ')" | log
    }
    
    "Starting $productName installation (this will wait for completion)..." | log
    $logDirectory = Split-Path -Path $logFile -Parent
    $vsStdOut = Join-Path $logDirectory "vs_install_ollama_stdout_$($logSuffix.ToLower()).log"
    $vsStdErr = Join-Path $logDirectory "vs_install_ollama_stderr_$($logSuffix.ToLower()).log"
    "VS installer stdout redirected to: $vsStdOut" | log
    "VS installer stderr redirected to: $vsStdErr" | log
    try {
        $process = Start-Process -FilePath $installerPath -ArgumentList $installArgs -Wait -PassThru -RedirectStandardOutput $vsStdOut -RedirectStandardError $vsStdErr
        $exitCode = $process.ExitCode
        
        "$productName installer completed with exit code: $exitCode" | log
        
        # VS installer exit codes:
        # 0 = Success
        # 3010 = Success but reboot required
        if ($exitCode -eq 0 -or $exitCode -eq 3010) {
            if ($exitCode -eq 3010) {
                "Installation successful but may require reboot for full functionality" | log
            }
            return $true
        } else {
            " ERROR - $productName installation failed with exit code: $exitCode" | log
            return $false
        }
    } catch {
        " ERROR - Failed to run $productName installer: $($_.Exception.Message)" | log
        return $false
    } finally {
        # Clean up downloaded installer (not existing installer)
        " Cleaning up installer file..." | log
        if ($installerPath -like "$env:TEMP\*" -and (Test-Path $installerPath)) {
            Remove-Item $installerPath -ErrorAction SilentlyContinue
        }
    }
}

function verifyVSInstallation {
    "Verifying Visual Studio $vsProduct installation..." | log
    
    # First, try to find VS using vswhere which handles non-default locations
    $vsInfo = getVSVersion -product $vsProduct
    
    if (-not $vsInfo -or -not $vsInfo.Path) {
        " ERROR - Visual Studio $vsProduct not found using vswhere" | log
        return $false
    }
    
    $actualVSPath = $vsInfo.Path
    "Found Visual Studio at: $actualVSPath" | log
    "Version: $($vsInfo.Version)" | log
    "Display Name: $($vsInfo.DisplayName)" | log
    
    # Use actual installation path for verification
    $vsPath = Join-Path $actualVSPath "Common7\Tools\VsDevCmd.bat"
    $msbuildPath = Join-Path $actualVSPath "MSBuild\Current\Bin\MSBuild.exe"
    $clPath = Join-Path $actualVSPath "VC\Tools\MSVC"
    
    $vsDevReady = Test-Path $vsPath
    $msbuildReady = Test-Path $msbuildPath  
    $vcToolsReady = Test-Path $clPath
    
    # Additional ARM64-specific verification
    $archSpecificReady = $true
    if ($isARM64) {
        $arm64ToolsReady = $false
        if (Test-Path $clPath) {
            $msvcVersions = Get-ChildItem $clPath -Directory
            foreach ($version in $msvcVersions) {
                $arm64CompilerPath = Join-Path $version.FullName "bin\Hostarm64\arm64\cl.exe"
                if (Test-Path $arm64CompilerPath) {
                    $arm64ToolsReady = $true
                    "Found ARM64 compiler at: $arm64CompilerPath" | log
                    break
                }
            }
        }
        $archSpecificReady = $arm64ToolsReady
        "VS Components Check - VsDevCmd: $vsDevReady, MSBuild: $msbuildReady, VCTools: $vcToolsReady, ARM64Tools: $arm64ToolsReady" | log
    } else {
        "VS Components Check - VsDevCmd: $vsDevReady, MSBuild: $msbuildReady, VCTools: $vcToolsReady" | log
    }
    
    if ($vsDevReady -and $msbuildReady -and $vcToolsReady -and $archSpecificReady) {
        "Visual Studio $vsProduct verification successful" | log
        return $true
    } else {
        " ERROR - Visual Studio $vsProduct verification failed - missing components" | log
        return $false
    }
}

function initializeVSEnvironment {
    "Initializing Visual Studio environment for build tools ($logSuffix)..." | log
    
    # Use vswhere to find actual VS installation path
    $vsInfo = getVSVersion -product $vsProduct
    
    if (-not $vsInfo -or -not $vsInfo.Path) {
        " ERROR - Visual Studio $vsProduct not found using vswhere" | log
        return $false
    }
    
    $actualVSPath = $vsInfo.Path
    "Using Visual Studio from: $actualVSPath" | log
    
    # Use actual installation path for VsDevCmd
    $vsDevCmd = Join-Path $actualVSPath "Common7\Tools\VsDevCmd.bat"
    
    if (-not (Test-Path $vsDevCmd)) {
        " ERROR - VsDevCmd.bat not found at expected location: $vsDevCmd" | log
        return $false
    }
    
    "Using VsDevCmd.bat from: $vsDevCmd" | log
    
    # Initialize VS environment with architecture-specific parameters
    $tempBat = "$env:TEMP\vsinit_$($logSuffix.ToLower()).bat"
    Set-Content -Path $tempBat -Value @"
@echo off
call "$vsDevCmd" -arch=$vsArchParam -host_arch=$vsHostArchParam > nul 2>&1
set
"@
    
    # Execute the batch file and capture environment variables
    $envVars = cmd /c "$tempBat" 2>nul
    Remove-Item $tempBat -ErrorAction SilentlyContinue
    
    # Parse and set environment variables
    $envVars | ForEach-Object {
        if ($_ -match "^([^=]+)=(.*)$") {
            $name = $matches[1]
            $value = $matches[2]
            
            # Set important VS-related environment variables
            if ($name -match "^(PATH|INCLUDE|LIB|LIBPATH|VS.*|VC.*|WindowsSDK.*|Platform.*|PROCESSOR_ARCHITECTURE)$") {
                Set-Item "env:$name" $value -ErrorAction SilentlyContinue
            }
        }
    }
    
    "Visual Studio environment initialized successfully for $logSuffix" | log
    return $true
}

Set-Content -Path $logFile -encoding utf8 "-- ollama prep started ($logSuffix version)"

"Detected architecture: $arch (Processor: $processorArch)" | log
if ($useCustomOllama) { "Mode: CUSTOM (use pre-built ollama.exe from zip; skip Go/VS/CMake/LLVM/git build chain)" | log }
if ($customResourcesPath) { "Custom resources path: $customResourcesPath" | log }

# ============================================================================
# Validate custom-resources inputs early so we fail fast with a clear message
# instead of part-way through download / install steps.
# ============================================================================
if ($useCustomOllama) {
    if (-not $customResourcesPath) {
        " ERROR - -useCustomOllama requires -customResourcesPath to be supplied." | log
        Exit 1
    }
    if (-not (Test-Path $customResourcesPath)) {
        " ERROR - customResourcesPath does not exist on the DUT: $customResourcesPath" | log
        Exit 1
    }
    "Contents of customResourcesPath ($customResourcesPath):" | log
    Get-ChildItem -Path $customResourcesPath -File | ForEach-Object {
        "  $($_.Name) ($([math]::Round($_.Length / 1MB, 1)) MB)" | log
    }
}

# ============================================================================
# Custom-Ollama path: extract pre-built ollama-windows-*.zip into $scriptDrive\hobl_bin\ollama.
# No Go, no Visual Studio, no CMake, no LLVM-MinGW, no git clone, no compile.
# ============================================================================
if ($useCustomOllama) {
    "-- Custom Ollama path: extracting pre-built binary" | log

    $expectedZipPattern = if ($isARM64) { "ollama-windows-arm64*.zip" } else { "ollama-windows-amd64*.zip" }
    $ollamaZip = Get-ChildItem -Path $customResourcesPath -Filter $expectedZipPattern | Select-Object -First 1
    if (-not $ollamaZip) {
        # Fall back to any ollama-windows-*.zip so a generically-named zip still works,
        # but log which one we picked.
        $ollamaZip = Get-ChildItem -Path $customResourcesPath -Filter "ollama-windows-*.zip" | Select-Object -First 1
        if ($ollamaZip) {
            " WARNING - No $expectedZipPattern found; falling back to $($ollamaZip.Name). Verify it matches the DUT architecture ($logSuffix)." | log
        }
    }
    if (-not $ollamaZip) {
        " ERROR - No ollama-windows-*.zip found in: $customResourcesPath" | log
        " ERROR - Expected file name pattern: $expectedZipPattern" | log
        Exit 1
    }
    "Found ollama zip: $($ollamaZip.Name) ($([math]::Round($ollamaZip.Length / 1MB, 1)) MB)" | log

    $ollamaInstallDir = "$scriptDrive\hobl_bin\ollama"
    if (Test-Path $ollamaInstallDir) {
        "Removing existing $ollamaInstallDir to ensure clean extraction..." | log
        try {
            Remove-Item -Recurse -Force $ollamaInstallDir -ErrorAction Stop
        } catch {
            " ERROR - Failed to clean $ollamaInstallDir : $($_.Exception.Message)" | log
            " ERROR - Close any process holding files in that directory (ollama.exe?) and retry." | log
            Exit 1
        }
    }
    New-Item -ItemType Directory -Path $ollamaInstallDir -Force | Out-Null

    "Extracting $($ollamaZip.FullName) -> $ollamaInstallDir ..." | log
    try {
        Expand-Archive -Path $ollamaZip.FullName -DestinationPath $ollamaInstallDir -Force -ErrorAction Stop
    } catch {
        " ERROR - Failed to extract ollama zip: $($_.Exception.Message)" | log
        Exit 1
    }

    # Zip layouts vary:
    #   - flat:    ollama.exe at root, libs in lib\ollama\
    #   - nested:  ollama-windows-amd64\ollama.exe (older releases, single top-level folder)
    #   - app/:    app\ollama.exe alongside its DLLs (current Windows release layout)
    # Promote a single top-level folder, but leave the app\ subfolder intact since
    # ollama.exe depends on the DLLs that ship next to it there.
    $ollamaExePath = Join-Path $ollamaInstallDir "ollama.exe"
    $ollamaExeAppPath = Join-Path $ollamaInstallDir "app\ollama.exe"
    if (-not (Test-Path $ollamaExePath) -and -not (Test-Path $ollamaExeAppPath)) {
        $nested = Get-ChildItem -Path $ollamaInstallDir -Directory | Where-Object {
            (Test-Path (Join-Path $_.FullName "ollama.exe")) -or
            (Test-Path (Join-Path $_.FullName "app\ollama.exe"))
        } | Select-Object -First 1
        if ($nested) {
            "Zip contained a top-level folder ($($nested.Name)); flattening..." | log
            Get-ChildItem -Path $nested.FullName -Force | ForEach-Object {
                Move-Item -Path $_.FullName -Destination $ollamaInstallDir -Force
            }
            Remove-Item -Recurse -Force $nested.FullName -ErrorAction SilentlyContinue
        }
    }

    if (Test-Path $ollamaExeAppPath) {
        $ollamaExePath = $ollamaExeAppPath
    }

    if (-not (Test-Path $ollamaExePath)) {
        " ERROR - ollama.exe not found at $ollamaInstallDir (checked root and app\) after extraction." | log
        "Extracted contents:" | log
        Get-ChildItem -Path $ollamaInstallDir -Recurse -Depth 2 | ForEach-Object {
            "  $($_.FullName)" | log
        }
        Exit 1
    }
    "ollama.exe present at: $ollamaExePath" | log

    # Verify the binary actually runs and report version into the log so future
    # failure triage knows exactly which build was used.
    "-- Verifying ollama.exe --version" | log
    $ollamaVersionOutput = & $ollamaExePath --version 2>&1
    if ($LASTEXITCODE -ne 0) {
        " ERROR - 'ollama.exe --version' exited $LASTEXITCODE" | log
        $ollamaVersionOutput | ForEach-Object { "  $_" | log }
        Exit 1
    }
    $ollamaVersionOutput | ForEach-Object { "ollama: $_" | log }

    "-- ollama prep completed ($logSuffix version - custom binary)" | log
    Exit 0
}

# ============================================================================
# Default path below: install Go + VS + CMake + LLVM-MinGW, clone, and build.
# ============================================================================
"Using Visual Studio $vsProduct for $logSuffix" | log

"-- Installing GoLang 1.25.1" | log
winget install --id GoLang.Go --version 1.25.1 --accept-source-agreements --accept-package-agreements
checkWinget($lastexitcode)

"-- Installing git" | log
winget install --id git.git --accept-source-agreements --accept-package-agreements
checkWinget($lastexitcode)
$Env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

# Check Visual Studio version before installation
"Checking Visual Studio version before installation..." | log
$vsBefore = getVSVersion -product $vsProduct
if ($vsBefore) {
    "Existing $vsProduct installation found:" | log
    "  Version: $($vsBefore.Version)" | log
    "  Display Name: $($vsBefore.DisplayName)" | log
    "  Path: $($vsBefore.Path)" | log
} else {
    "No existing $vsProduct installation found" | log
}

# Install Visual Studio using architecture-appropriate installer
if (-not (installVisualStudio)) {
    " ERROR - Visual Studio $vsProduct installation failed" | log
    Exit 1
}

# Check Visual Studio version after installation
"Checking Visual Studio version after installation..." | log
$vsAfter = getVSVersion -product $vsProduct
if ($vsAfter) {
    "Current $vsProduct installation:" | log
    "  Version: $($vsAfter.Version)" | log
    "  Display Name: $($vsAfter.DisplayName)" | log
    "  Path: $($vsAfter.Path)" | log
} else {
    " ERROR - $vsProduct not found after installation" | log
    Exit 1
}

# Verify installation completed properly
if (-not (verifyVSInstallation)) {
    " ERROR - Visual Studio $vsProduct verification failed" | log
    Exit 1
}

# Initialize VS environment for build tools
if (-not (initializeVSEnvironment)) {
    " ERROR - Failed to initialize Visual Studio environment" | log
    Exit 1
}

# Refresh environment variables after VS installation
"Refreshing environment variables after VS installation..." | log
$Env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

"-- Installing CMake 4.1.1" | log
winget install --id KitWare.CMake --version 4.1.1 --accept-source-agreements --accept-package-agreements
checkWinget($lastexitcode)

"Refreshing environment variables after cmake installation..." | log
$Env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

# Install LLVM MinGW UCRT with architecture-specific versions
if ($isARM64) {
    "-- Installing LLVM MinGW UCRT for ARM64 (version 20240619)" | log
    $llvmVersion = "20240619"
    $llvmArchSuffix = "ucrt-aarch64"
    $llvmUrl = "https://github.com/mstorsjo/llvm-mingw/releases/download/$llvmVersion/llvm-mingw-$llvmVersion-$llvmArchSuffix.zip"
} else {
    "-- Installing LLVM MinGW UCRT for x64 (version 20250613)" | log
    $llvmVersion = "20250613"
    $llvmArchSuffix = "ucrt-x86_64"
    $llvmUrl = "https://github.com/mstorsjo/llvm-mingw/releases/download/$llvmVersion/llvm-mingw-$llvmVersion-$llvmArchSuffix.zip"
}

$llvmZipPath = "$scriptDrive\temp\llvm-mingw-ucrt.zip"
$llvmFolderName = "llvm-mingw-$llvmVersion-$llvmArchSuffix"
$llvmInstallPath = "C:\Program Files\$llvmFolderName"
$llvmBinPath = "$llvmInstallPath\bin"

# Create temp directory if it doesn't exist
if (-not (Test-Path "$scriptDrive\temp")) {
    New-Item -ItemType Directory -Path "$scriptDrive\temp" -Force | Out-Null
    "Created temp directory: $scriptDrive\temp" | log
}

# Download LLVM MinGW UCRT
"Downloading LLVM MinGW UCRT from: $llvmUrl" | log
try {
    Invoke-WebRequest -Uri $llvmUrl -OutFile $llvmZipPath -UseBasicParsing
    "LLVM MinGW UCRT downloaded successfully" | log
} catch {
    " ERROR - Failed to download LLVM MinGW UCRT: $($_.Exception.Message)" | log
    Exit 1
}

# Extract LLVM archive
"Extracting LLVM MinGW UCRT to Program Files..." | log
try {
    Expand-Archive -Path $llvmZipPath -DestinationPath "C:\Program Files\" -Force
    "LLVM MinGW UCRT extracted successfully" | log
} catch {
    " ERROR - Failed to extract LLVM MinGW UCRT: $($_.Exception.Message)" | log
    Exit 1
}

# Add LLVM to PATH
"Adding LLVM MinGW to machine PATH..." | log
$currentPath = [Environment]::GetEnvironmentVariable("PATH", "Machine")
if ($currentPath -notlike "*$llvmBinPath*") {
    $updatedPath = $currentPath + ";" + $llvmBinPath
    [Environment]::SetEnvironmentVariable("PATH", $updatedPath, "Machine")
    "Added LLVM-MinGW to machine PATH: $llvmBinPath" | log
} else {
    "LLVM-MinGW already in machine PATH" | log
}

"Refreshing environment variables after adding LLVM MinGW installation..." | log
$Env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

# Clean up downloaded zip file
if (Test-Path $llvmZipPath) {
    Remove-Item $llvmZipPath -ErrorAction SilentlyContinue
    "Cleaned up downloaded LLVM zip file" | log
}

"-- Cloning git repo" | log
checkSetLocation "$scriptDrive\hobl_bin\"
git clone https://github.com/ollama/ollama.git
checkGitClone $lastexitcode "$scriptDrive\hobl_bin\ollama"

"-- Checkout" | log
checkSetLocation "$scriptDrive\hobl_bin\ollama"
git checkout v0.20.8-rc0
check($lastexitcode)

if (-not $isARM64) {
    "-- Configuring discrete-GPU runners (x64 only)" | log
    checkSetLocation "$scriptDrive\hobl_bin\ollama"
    cmake -B build
    check($lastexitcode)
} else {
    "-- Skipping cmake configure on ARM64 (no discrete-GPU runners; CPU/Vulkan inference is built into ollama.exe by go build + MinGW)" | log
}

"-- Download modules" | log
go mod tidy
check($lastexitcode)

if (-not $isARM64) {
    "-- Building discrete-GPU runners (x64 only)" | log
    cmake --build build
    check($lastexitcode)
} else {
    "-- Skipping cmake build on ARM64 (no discrete-GPU runners; CPU/Vulkan inference is built into ollama.exe by go build + MinGW)" | log
}

"-- Building ollama.exe" | log
checkSetLocation "$scriptDrive\hobl_bin\ollama"
go build -o ollama.exe .
check($lastexitcode)
if (-not (Test-Path "$scriptDrive\hobl_bin\ollama\ollama.exe")) {
    " ERROR - go build completed but $scriptDrive\hobl_bin\ollama\ollama.exe was not produced." | log
    Exit 1
}
"Built ollama.exe at: $scriptDrive\hobl_bin\ollama\ollama.exe" | log
& "$scriptDrive\hobl_bin\ollama\ollama.exe" --version 2>&1 | ForEach-Object { "ollama: $_" | log }

"-- ollama prep completed ($logSuffix version)" | log
Exit 0