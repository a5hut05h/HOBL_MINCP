# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

param(
    [string]$logFile = "",
    [string]$foundryVersion = "0.8.117.0"
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
if (-not $logFile) { $logFile = "$scriptDrive\hobl_data\foundrylocal_prep.log" }

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

# Determine processor architecture
$osInfo = Get-CimInstance Win32_OperatingSystem
$arch = $osInfo.OSArchitecture
$processorArch = $env:PROCESSOR_ARCHITECTURE

if ($arch -eq "64-bit" -and $processorArch -eq "AMD64") {
    $logSuffix = "x64"
} elseif ($arch -match "ARM" -or $processorArch -match "ARM") {
    $logSuffix = "ARM64"
} else {
    Write-Host " ERROR - Unsupported architecture: $arch (Processor: $processorArch)" -ForegroundColor Red
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
    if ($code -eq 0) {
        "Winget command succeeded" | log
        return
    } elseif ($code -eq -1978335189) {
        "Package already installed" | log
        return
    } elseif ($code -eq -1978335215) {
        "No upgrade available (already up to date)" | log
        return
    } else {
        " ERROR - Winget command failed with exit code: $code" | log
        Exit $code
    }
}

Set-Content -Path $logFile -encoding utf8 "-- Foundry Local prep started ($logSuffix version)"

"Detected architecture: $arch (Processor: $processorArch)" | log

# ============================================================================
# Step 1: Install AI Foundry Local via winget
# ============================================================================
"Step 1: Installing AI Foundry Local..." | log

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

"Installing Microsoft.FoundryLocal version $foundryVersion via winget..." | log
winget install Microsoft.FoundryLocal --source winget --version $foundryVersion --accept-source-agreements --accept-package-agreements 2>&1 | ForEach-Object { "  $_" | log }
checkWinget $LASTEXITCODE

# Refresh PATH to pick up newly installed foundry
$Env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

# ============================================================================
# Step 2: Verify installation
# ============================================================================
"Step 2: Verifying Foundry Local installation..." | log

$foundryCmd = Get-Command foundry -ErrorAction SilentlyContinue
if ($foundryCmd) {
    "Foundry command found at: $($foundryCmd.Source)" | log
    
    # Get version info
    "Getting Foundry version..." | log
    $versionOutput = & foundry --version 2>&1
    $versionOutput | ForEach-Object { "  $_" | log }
} else {
    " ERROR - Foundry command not found after installation" | log
    "Please ensure Microsoft.FoundryLocal is installed correctly" | log
    Exit 1
}

# ============================================================================
# Summary
# ============================================================================
"" | log
"========================================" | log
"Foundry Local prep completed successfully ($logSuffix version)" | log
"========================================" | log
"Log file: $logFile" | log

Exit 0
