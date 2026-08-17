# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

# Initialize logging IMMEDIATELY (before anything else) so we catch all failures
$scriptDrive = Split-Path -Qualifier $PSScriptRoot
$logFile = "$scriptDrive\hobl_data\ollama_setup.log"
$logDir = Split-Path $logFile -Parent

# Create log directory and write first marker
if (-not (Test-Path $logDir)) { 
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null 
}
Add-Content -Path $logFile -encoding utf8 "=== ollama_setup.ps1 execution started at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') ==="
Add-Content -Path $logFile -encoding utf8 "Script location: $PSCommandPath"
Add-Content -Path $logFile -encoding utf8 "PowerShell version: $($PSVersionTable.PSVersion)"

# Require PowerShell > 7
$required = [version]"7.0"
if (-not $PSVersionTable.PSVersion) {
    Add-Content -Path $logFile -encoding utf8 " ERROR - Cannot determine PowerShell version; aborting."
    Write-Host "Cannot determine PowerShell version; aborting." -ForegroundColor Red
    Exit 1
}
if ([version]$PSVersionTable.PSVersion -le $required) {
    Add-Content -Path $logFile -encoding utf8 " ERROR - PowerShell version $($PSVersionTable.PSVersion) is less than required $required"
    Write-Host "This script requires PowerShell greater than $required. Current: $($PSVersionTable.PSVersion)" -ForegroundColor Yellow
    Write-Host "Please install PowerShell 7 or later from https://aka.ms/powershell" -ForegroundColor Yellow
    Exit 1
}
Add-Content -Path $logFile -encoding utf8 "PowerShell version check passed."


# [Console]::OutputEncoding = [System.Text.Encoding]::UTF8

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

$Env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
"-- ollama setup starting execution phase" | log

checkSetLocation "$scriptDrive\hobl_bin\ollama"

# Source-built ollama lives at ollama\ollama.exe; custom-zip releases ship it at ollama\app\ollama.exe.
$ollamaExe = "$scriptDrive\hobl_bin\ollama\ollama.exe"
if (-not (Test-Path $ollamaExe)) {
    $ollamaExeApp = "$scriptDrive\hobl_bin\ollama\app\ollama.exe"
    if (Test-Path $ollamaExeApp) {
        $ollamaExe = $ollamaExeApp
    } else {
        " ERROR - ollama.exe missing at both $ollamaExe and $ollamaExeApp. Prep did not complete." | log
        " ERROR - Re-prep required: delete $scriptDrive\hobl_bin\prep_status\ollama<version> on the DUT and re-run." | log
        Exit 1
    }
}
"Using ollama binary: $ollamaExe" | log

# Clean up any existing Ollama processes before starting
"-- Stopping any existing Ollama processes..." | log

$ollamaProcesses = Get-Process -Name "ollama" -ErrorAction SilentlyContinue
if ($ollamaProcesses) {
    "-- Found existing ollama.exe processes, terminating..." | log
    Stop-Process -Name "ollama" -Force -ErrorAction SilentlyContinue
} else {
    "-- No ollama.exe processes running..." | log
}

$llamaProcesses = Get-Process -Name "*ollama*" -ErrorAction SilentlyContinue
if ($llamaProcesses) {
    $llamaProcesses | ForEach-Object {
        "-- Terminating $($_.Name) (PID: $($_.Id))..." | log
    }
    $llamaProcesses | ForEach-Object {
        Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
    }
} else {
    "-- No ollama_llama_server processes running..." | log
}

Start-Sleep -Seconds 2

"-- Verifying ollama.exe --version" | log
$ollamaVersionOutput = & $ollamaExe --version 2>&1
if ($LASTEXITCODE -ne 0) {
    " ERROR - 'ollama.exe --version' exited $LASTEXITCODE" | log
    $ollamaVersionOutput | ForEach-Object { "  $_" | log }
    Exit 1
}
$ollamaVersionOutput | ForEach-Object { "ollama: $_" | log }

"-- Launching ollama server in background ($ollamaExe serve)" | log
Start-Process -FilePath $ollamaExe `
    -ArgumentList "serve" `
    -WindowStyle Hidden

"-- Waiting for server to be ready..." | log
$maxAttempts = 30
$attempt = 0
$serverReady = $false

while ($attempt -lt $maxAttempts -and -not $serverReady) {
    $attempt++
    Start-Sleep -Seconds 1
    
    try {
        $response = Invoke-WebRequest -Uri "http://localhost:11434/api/tags" -Method GET -TimeoutSec 10 -ErrorAction Stop
        if ($response.StatusCode -eq 200) {
            $serverReady = $true
            "-- Server ready after $attempt seconds" | log
        }
    } catch {
        "-- Waiting for server... ($attempt/$maxAttempts)" | log
    }
}

if (-not $serverReady) {
    " ERROR - Server did not start within $maxAttempts seconds" | log
    " ERROR - See hobl.log for the server's own output." | log
    Exit 1
}

"-- Pulling gemma3" | log
$pullStdOut = Join-Path $logDir "ollama_pull_stdout.log"
$pullStdErr = Join-Path $logDir "ollama_pull_stderr.log"
$pullTimeoutSec = 5400
$pullHeartbeatSec = 30
"-- Pull stdout redirected to: $pullStdOut" | log
"-- Pull stderr redirected to: $pullStdErr" | log
"-- Starting model pull with timeout: $pullTimeoutSec seconds" | log

$pullProc = Start-Process -FilePath $ollamaExe `
    -ArgumentList "pull", "gemma3" `
    -WindowStyle Hidden `
    -RedirectStandardOutput $pullStdOut `
    -RedirectStandardError $pullStdErr `
    -PassThru

$elapsedSec = 0
while (-not $pullProc.HasExited -and $elapsedSec -lt $pullTimeoutSec) {
    Start-Sleep -Seconds 1
    $elapsedSec++

    if (($elapsedSec % $pullHeartbeatSec) -eq 0) {
        "-- Pull in progress... elapsed=${elapsedSec}s pid=$($pullProc.Id)" | log
    }
}

if (-not $pullProc.HasExited) {
    " ERROR - Model pull timed out after $pullTimeoutSec seconds" | log
    " ERROR - Terminating pull process (pid=$($pullProc.Id))" | log
    Stop-Process -Id $pullProc.Id -Force -ErrorAction SilentlyContinue
    Exit 1
}

if ($pullProc.ExitCode -ne 0) {
    " ERROR - Model pull failed with exit code $($pullProc.ExitCode)" | log
    " ERROR - See $pullStdOut and $pullStdErr for full details." | log

    if (Test-Path $pullStdErr) {
        Get-Content -Path $pullStdErr -Tail 20 -ErrorAction SilentlyContinue | ForEach-Object { "pull-stderr: $_" | log }
    }

    Exit $pullProc.ExitCode
}

"-- Model pull completed successfully in ${elapsedSec}s" | log

Exit 0