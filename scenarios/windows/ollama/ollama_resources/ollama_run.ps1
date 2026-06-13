# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

param(
    [string]$logFile = "",
    [string]$model = "gemma3",
    [string]$startTime = (Get-Date).ToString("o")
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

if (-not $logFile) { $logFile = "$scriptDrive\hobl_data\ollama_run.log" }

$timeTraceFile = "$scriptDrive\hobl_data\run_time.trace"
$totalTokenTraceFile = "$scriptDrive\hobl_data\total_tokens.trace"
$tpsTraceFile = "$scriptDrive\hobl_data\tokens_per_second.trace"


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

# 9F0F6E2E-8D06-4D2F-B8F5-6F1F2D5A1C01 is a custom provider we use to emit phase markers from the scenario script (optional, may not be present)
if (-not ('HoblRunPhaseProvider' -as [type])) {
    Add-Type -TypeDefinition @"
using System.Diagnostics.Tracing;

[EventSource(Name = "HOBL-Scenario-Phases", Guid = "9f0f6e2e-8d06-4d2f-b8f5-6f1f2d5a1c01")]
public sealed class HoblRunPhaseProvider : EventSource
{
    public static readonly HoblRunPhaseProvider Log = new HoblRunPhaseProvider();

    [Event(1, Level = EventLevel.Informational)]
    public void Phase(string marker, string scenario)
    {
        WriteEvent(1, marker, scenario);
    }
}
"@
}

function Write-RunPhaseMarker {
    param([string]$Marker)

    try {
        [HoblRunPhaseProvider]::Log.Phase($Marker, "ollama")
    } catch {
    }
}

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

Set-Content -Path $logFile -encoding utf8 "-- ollama run started ($logSuffix version)"

"Detected architecture: $arch (Processor: $processorArch)" | log
"Model: $model" | log
Write-RunPhaseMarker "phase.run_prep.start"

$Env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

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

Set-Location "$scriptDrive\hobl_bin\ollama"

# Disable Progress indicator
$env:NO_COLOR = "1"

# run ollama with model, prompt and capture output
# verbose logging adds model execution details
$verboseLog = Join-Path (Split-Path $logFile -Parent) "ollama_verbose_$($logSuffix.ToLower()).log"
"-- Run $model model with prompt" | log
"-- Script log: $logFile" | log
"-- Verbose output: $verboseLog" | log
Write-RunPhaseMarker "phase.run_prep.end"
Write-RunPhaseMarker "phase.run_build.start"
& $ollamaExe run $model "what is the meaning of life?" --verbose > $verboseLog 2>&1
check($lastexitcode)
Write-RunPhaseMarker "phase.run_build.end"
Write-RunPhaseMarker "phase.run_results.start"

"-- Parsing metrics from verbose log file" | log

# Example ollama --verbose output for reference:
#   total duration:       28.924842625s
#   load duration:        12.713512958s
#   prompt eval count:    16 token(s)
#   prompt eval duration: 99.495083ms
#   prompt eval rate:     160.81 tokens/s
#   eval count:           1024 token(s)
#   eval duration:        16.110097042s
#   eval rate:            63.56 tokens/s

# Read the verbose log file and extract metrics
$content = Get-Content $verboseLog -Raw

# Extract total duration (used as scenario_runtime)
# Format can be XmY.Zs or X.Ys
$totalDurationMatch = $content -match 'total duration:\s+([0-9]+)m([0-9.]+)s'
if ($totalDurationMatch) {
    $totalDurationSeconds = ([int]$matches[1] * 60) + [double]$matches[2]
} else {
    $totalDurationSecsMatch = $content -match 'total duration:\s+([0-9.]+)s'
    $totalDurationSeconds = if ($totalDurationSecsMatch) { [double]$matches[1] } else { 0 }
}
$scenarioRuntime = [math]::Round($totalDurationSeconds, 3)

# Extract metrics using regex
# Time To First Token (TTFT) comes from prompt eval duration
# it's the time spent generating the first token after prompt processing
$promptEvalDurationMatch = $content -match 'prompt eval duration:\s+([0-9.]+)([a-z]+)'
$promptEvalDuration = if ($promptEvalDurationMatch) { [double]$matches[1] } else { 0 }
$promptEvalDurationUnit = if ($promptEvalDurationMatch) { $matches[2] } else { "s" }

# Load duration is the time taken to load the model and not involved in TTFT
$loadDurationMatch = $content -match 'load duration:\s+([0-9.]+)([a-z]+)'
$loadDuration = if ($loadDurationMatch) { [double]$matches[1] } else { 0 }
$loadDurationUnit = if ($loadDurationMatch) { $matches[2] } else { "s" }

# Match "eval rate" but NOT "prompt eval rate"
# eval rate is tokens generated per second during evaluation
$evalRateMatch = $content -match '(?<!prompt )eval rate:\s+([0-9.]+)\s+tokens/s'
$evalRate = if ($evalRateMatch) { [double]$matches[1] } else { 0 }

# Match "eval count" but NOT "prompt eval count"
# eval count is the total number of tokens generated during evaluation
$evalCountMatch = $content -match '(?<!prompt )eval count:\s+([0-9]+)\s+token'
$evalCount = if ($evalCountMatch) { [int]$matches[1] } else { 0 }

# Match "eval duration" but NOT "prompt eval duration"
# eval duration is the total time taken to generate all tokens
$evalDurationMatch = $content -match '(?<!prompt )eval duration:\s+([0-9]+)m([0-9.]+)s'
$evalDurationMinutes = if ($evalDurationMatch) { [int]$matches[1] } else { 0 }
$evalDurationSeconds = if ($evalDurationMatch) { [double]$matches[2] } else { 0 }
$evalDurationTotalSeconds = ($evalDurationMinutes * 60) + $evalDurationSeconds

# If eval duration wasn't in minutes format, try seconds only
if (-not $evalDurationMatch) {
    $evalDurationSecondsMatch = $content -match '(?<!prompt )eval duration:\s+([0-9.]+)s'
    $evalDurationTotalSeconds = if ($evalDurationSecondsMatch) { [double]$matches[1] } else { 0 }
}

# Convert prompt eval duration to seconds if needed
$promptEvalDurationSeconds = switch ($promptEvalDurationUnit) {
    "ms" { $promptEvalDuration / 1000 }
    "s"  { $promptEvalDuration }
    "m"  { $promptEvalDuration * 60 }
    default { $promptEvalDuration }
}

# Convert load duration to seconds if needed (kept for reference if needed)
$loadDurationSeconds = switch ($loadDurationUnit) {
    "ms" { $loadDuration / 1000 }
    "s"  { $loadDuration }
    "m"  { $loadDuration * 60 }
    default { $loadDuration }
}

# Calculate metrics in required format
$time_to_first_token_s = $promptEvalDurationSeconds
$time_to_first_token_ms = $promptEvalDurationSeconds * 1000
$tokens_per_second = $evalRate
$total_tokens_generated = $evalCount
$total_generation_time_s = $evalDurationTotalSeconds
$device = $null

# ============================================================================
# Save results
# ============================================================================
$outputDir = Split-Path $logFile -Parent
$resultsFile = Join-Path $outputDir "ollama_results.csv"

"" | log
"========================================" | log
"Ollama Metrics Summary" | log
"========================================" | log
"Time to First Token: ${time_to_first_token_ms}ms (${time_to_first_token_s}s)" | log
"Tokens per Second:   $tokens_per_second" | log
"Total Tokens:        $total_tokens_generated" | log
"Generation Time:     ${total_generation_time_s}s" | log
"Model:               $model" | log
"Architecture:        $logSuffix" | log
"Scenario Runtime:    ${scenarioRuntime}s" | log
"========================================" | log

# Write metrics CSV file (key,value format - HOBL convention)
$metricsContent = @(
    "scenario_runtime,$scenarioRuntime"
    "time_to_first_token_ms,$time_to_first_token_ms"
    "time_to_first_token_s,$time_to_first_token_s"
    "tokens_per_second,$tokens_per_second"
    "total_tokens_generated,$total_tokens_generated"
    "total_generation_time_s,$total_generation_time_s"
    "ai_model,$model"
    "ai_device,$device"
    "architecture,$logSuffix"
)
$metricsContent | Set-Content $resultsFile -Encoding UTF8
"Metrics saved to: $resultsFile" | log

"" | log
"-- ollama run completed ($logSuffix version)" | log

$elapsedTime = ((Get-Date) - [DateTime]$startTime).TotalSeconds
# Append to .trace files for timeline correlation (key,value format)
if (-not (Test-Path $timeTraceFile)) {
    "Creating trace file with header: $timeTraceFile" | log
    Set-Content -Path $timeTraceFile -Value "Timestamp,scenario_runtime" -Encoding UTF8
}
if (-not (Test-Path $totalTokenTraceFile)) {
    "Creating trace file with header: $totalTokenTraceFile" | log
    Set-Content -Path $totalTokenTraceFile -Value "Timestamp,total_tokens" -Encoding UTF8
}
if (-not (Test-Path $tpsTraceFile)) {
    "Creating trace file with header: $tpsTraceFile" | log
    Set-Content -Path $tpsTraceFile -Value "Timestamp,tokens_per_second" -Encoding UTF8
}

$traceContent = @"
$elapsedTime,$scenarioRuntime
"@
"Appending scenario runtime to trace file: $timeTraceFile" | log  
Add-Content -Path $timeTraceFile -Value $traceContent -Encoding UTF8

$traceContent = @"
$elapsedTime,$total_tokens_generated
"@
"Appending total tokens to trace file: $totalTokenTraceFile" | log  
Add-Content -Path $totalTokenTraceFile -Value $traceContent -Encoding UTF8

$traceContent = @"
$elapsedTime,$tokens_per_second
"@
"Appending tokens per second to trace file: $tpsTraceFile" | log  
Add-Content -Path $tpsTraceFile -Value $traceContent -Encoding UTF8

Write-RunPhaseMarker "phase.run_results.end"

Exit 0