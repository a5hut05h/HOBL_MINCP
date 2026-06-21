# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

# Ollama cleanup/teardown script

param(
    [string]$logFile = ""
)

$scriptDrive = Split-Path -Qualifier $PSScriptRoot
if (-not $logFile) { $logFile = "$scriptDrive\hobl_data\ollama_teardown.log" }

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

# Determine processor architecture for log file naming
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

# Ollama source directory
$ollamaDir = "$scriptDrive\hobl_bin\ollama"

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

# Refresh PATH so ollama is findable
$Env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

"-- ollama teardown started (arch=$logSuffix)" | log

$ollamaExe = "$ollamaDir\ollama.exe"

# ============================================================================
# Step 1: Remove the gemma3 model via ollama.exe
# ============================================================================
"Step 1: Removing gemma3 model..." | log

try {
    if (Test-Path $ollamaExe) {
        "Current models:" | log
        $models = & $ollamaExe list 2>&1
        $models | ForEach-Object { "  $_" | log }

        "Removing gemma3 model via '$ollamaExe rm gemma3'..." | log
        $result = & $ollamaExe rm gemma3 2>&1
        $result | ForEach-Object { "  $_" | log }
        "gemma3 model removal attempted" | log
    } else {
        "$ollamaExe missing; skipping model removal (data dir will still be deleted below)" | log
    }
} catch {
    "Warning: Failed to remove gemma3 model: $_" | log
}

# ============================================================================
# Step 2: Kill ollama.exe background process
# ============================================================================
"Step 2: Killing ollama.exe process..." | log

try {
    $ollamaProcesses = Get-Process -Name "ollama" -ErrorAction SilentlyContinue
    if ($ollamaProcesses) {
        $ollamaProcesses | ForEach-Object {
            "Killing ollama.exe process (PID: $($_.Id))" | log
            Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        }
        "ollama.exe processes terminated" | log
    } else {
        "No ollama.exe processes found" | log
    }
    
    # Also check for ollama_llama_server or related processes
    $llamaProcesses = Get-Process -Name "*ollama*" -ErrorAction SilentlyContinue
    if ($llamaProcesses) {
        $llamaProcesses | ForEach-Object {
            "Killing $($_.Name) process (PID: $($_.Id))" | log
            Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        }
    }
} catch {
    "Warning: Failed to kill ollama processes: $_" | log
}

# Give processes time to terminate
Start-Sleep -Seconds 2

# ============================================================================
# Step 4: Full cleanup - remove Ollama data and (build-mode) dist artifacts
# ============================================================================
"Step 4: Performing full cleanup of Ollama data and build artifacts..." | log

# Remove Ollama models directory
$ollamaModelsPath = "$env:USERPROFILE\.ollama"
if (Test-Path $ollamaModelsPath) {
    try {
        $dirSize = (Get-ChildItem $ollamaModelsPath -Recurse -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum / 1GB
        "Removing Ollama data directory: $ollamaModelsPath (size: ~$([math]::Round($dirSize, 2)) GB)" | log
        Remove-Item -Recurse -Force $ollamaModelsPath -ErrorAction Stop
        "Ollama data directory removed successfully" | log
    } catch {
        " ERROR - Failed to remove Ollama data directory: $_" | log
    }
} else {
    "Ollama data directory not found at $ollamaModelsPath" | log
}

# Remove the build-mode dist directory if present (preserves the repo, cmake
# build, ollama.exe, and Go module cache so the next iteration can reuse them).
if (Test-Path $ollamaDir) {
    $distDir = Join-Path $ollamaDir "dist"
    if (Test-Path $distDir) {
        try {
            $dirSize = (Get-ChildItem $distDir -Recurse -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum / 1MB
            "Removing dist directory: $distDir (size: ~$([math]::Round($dirSize, 2)) MB)" | log
            Remove-Item -Recurse -Force $distDir -ErrorAction Stop
            "dist directory removed successfully" | log
        } catch {
            " ERROR - Failed to clean dist directory: $_" | log
        }
    } else {
        "No dist directory present (custom-zip prep or already cleaned)" | log
    }
} else {
    "Ollama directory not found at $ollamaDir" | log
}

# ============================================================================
# Summary
# ============================================================================
"" | log
"========================================" | log
"Ollama teardown completed" | log
"========================================" | log
"Log file: $logFile" | log
