# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

param(
    [string]$logFile = "",
    [string]$mlperfClientPath = ""
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
if (-not $logFile) { $logFile = "$scriptDrive\hobl_data\mlperf_prep.log" }

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
    $logSuffix = "x64"
    $mlperfZipName = "mlperf-client-x64.zip"
    $mlperfUrl = "https://github.com/mlcommons/mlperf_client/releases/download/v1.5/mlperf-client-1.5.0-8665cb1-windows-x64.zip"
} elseif ($arch -match "ARM" -or $processorArch -match "ARM") {
    $isARM64 = $true
    $logSuffix = "ARM64"
    $mlperfZipName = "mlperf-client-arm64.zip"
    $mlperfUrl = "https://github.com/mlcommons/mlperf_client/releases/download/v1.5/mlperf-client-1.5.0-8665cb1-windows-arm64.zip"
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
        " ERROR - Last command failed with exit code: $code" | log
        Exit $code
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

Set-Content -Path $logFile -encoding utf8 "-- MLPerf prep started ($logSuffix version)"

"Detected architecture: $arch (Processor: $processorArch)" | log

# -------------------------------------------------------------------
# Install Windows App SDK, required for MLPerf client
# -------------------------------------------------------------------
# --- Remove the msstore source before any winget install so a broken pinned
# certificate on that source cannot fail the command (winget 0x8a15005e /
# -1978335138) behind an SSL-inspecting proxy. All needed packages are on 'winget'. ---
try {
    if ((winget source list 2>$null) -match "msstore") {
        "Removing msstore winget source to avoid pinned-certificate failures (0x8a15005e)" | log
        winget source remove msstore 2>&1 | log
    }
} catch {
    "Could not remove msstore source (continuing): $($_.Exception.Message)" | log
}

"-- Installing Windows App SDK" | log
winget install --id Microsoft.WindowsAppRuntime.1.8 --source winget --accept-source-agreements --accept-package-agreements
checkWinget($lastexitcode)

# Create mlperf directory if it doesn't exist
$mlperfDir = "$scriptDrive\hobl_bin\mlperf"
if (-not (Test-Path $mlperfDir)) {
    "Creating directory: $mlperfDir" | log
    New-Item -Path $mlperfDir -ItemType Directory -Force | Out-Null
} else {
    "Directory already exists: $mlperfDir" | log
}

# Determine the zip file location
if ([string]::IsNullOrEmpty($mlperfClientPath)) {
    # No zip path provided, use default location
    $mlperfClientPath = Join-Path $mlperfDir $mlperfZipName
    
    if (-not (Test-Path $mlperfClientPath)) {
        "No zip file provided and default not found. Downloading MLPerf v1.5 from GitHub..." | log
        "Download URL: $mlperfUrl" | log
        try {
            Invoke-WebRequest -Uri $mlperfUrl -OutFile $mlperfClientPath
            "Download completed successfully" | log
        } catch {
            " ERROR - Failed to download MLPerf: $($_.Exception.Message)" | log
            Exit 1
        }
    } else {
        "Using existing zip file at: $mlperfClientPath" | log
    }
} else {
    # Zip path provided as parameter
    if (-not (Test-Path $mlperfClientPath)) {
        " ERROR - Specified zip file does not exist: $mlperfClientPath" | log
        Exit 1
    }
    "Using provided zip file: $mlperfClientPath" | log
}

# Unzip MLPerf
"Unzipping MLPerf archive..." | log
"Source: $mlperfClientPath" | log
"Destination: $mlperfDir" | log

# Clean up existing mlperf-windows.exe and related files to avoid conflicts
$mlperfExe = Join-Path $mlperfDir "mlperf-windows.exe"
if (Test-Path $mlperfExe) {
    "Removing existing MLPerf files before extraction..." | log
    Remove-Item $mlperfExe -Force -ErrorAction SilentlyContinue
}

try {
    # Use -Force to overwrite existing files
    Expand-Archive -Path $mlperfClientPath -DestinationPath $mlperfDir -Force -ErrorAction Stop
    "MLPerf archive extracted successfully" | log
} catch {
    " ERROR - Failed to extract MLPerf archive: $($_.Exception.Message)" | log
    "Exception details: $($_.Exception)" | log
    Exit 1
}

# Verify extraction
$mlperfExe = Join-Path $mlperfDir "mlperf-windows.exe"
if (Test-Path $mlperfExe) {
    "SUCCESS: MLPerf executable found at: $mlperfExe" | log
} else {
    " ERROR - MLPerf executable not found after extraction" | log
    Exit 1
}

# List contents of mlperf directory for verification
"Contents of $mlperfDir :" | log
Get-ChildItem $mlperfDir -Recurse | Select-Object FullName | ForEach-Object {
    "  $($_.FullName)" | log
}

# Install WinML QNN EP on Snapdragon X Elite devices
if ($isARM64) {
    $processorName = (Get-CimInstance Win32_Processor).Name
    "Processor: $processorName" | log

    if ($processorName -match "X1E80100") {
        "Snapdragon X Elite (X1E80100) detected, checking for WinML QNN EP..." | log

        $qnnEp = Get-AppxPackage | Where-Object { $_.Name -like "*WinML.Qualcomm.QNN.EP*" }
        if ($qnnEp) {
            "WinML QNN EP already installed: $($qnnEp.Name) v$($qnnEp.Version)" | log
        } else {
            $qnnEpMsix = Join-Path (Split-Path $mlperfClientPath -Parent) "qnnep_arm.msix"
            if (-not (Test-Path $qnnEpMsix)) {
                " ERROR - WinML QNN EP not installed and msix not found: $qnnEpMsix" | log
                Exit 1
            }
            "Installing WinML QNN EP from: $qnnEpMsix" | log
            try {
                Add-AppxPackage -Path $qnnEpMsix -ErrorAction Stop
                "WinML QNN EP installed successfully" | log
            } catch {
                " ERROR - Failed to install WinML QNN EP: $($_.Exception.Message)" | log
                Exit 1
            }

            # Verify installation
            $qnnEp = Get-AppxPackage | Where-Object { $_.Name -like "*WinML.Qualcomm.QNN.EP*" }
            if ($qnnEp) {
                "Verified: $($qnnEp.Name) v$($qnnEp.Version)" | log
            } else {
                " ERROR - WinML QNN EP not found after installation" | log
                Exit 1
            }
        }
    } else {
        "Non-X1E80100 ARM64 processor, skipping WinML QNN EP check" | log
    }
}

"-- MLPerf prep completed successfully ($logSuffix version)" | log
Exit 0
