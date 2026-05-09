# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

param(
    [string]$logFile = "",
    [string]$startTime = (Get-Date).ToString("o"),
    [switch]$noGpu = $false
)

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
        [HoblRunPhaseProvider]::Log.Phase($Marker, "pytorch_inf")
    } catch {
    }
}

$scriptDrive = Split-Path -Qualifier $PSScriptRoot

if (-not (Test-Path "$scriptDrive\hobl_data")) {
    Write-Host " ERROR - Required directory not found: $scriptDrive\hobl_data" -ForegroundColor Red
    Exit 1
}
if (-not (Test-Path "$scriptDrive\hobl_bin")) {
    Write-Host " ERROR - Required directory not found: $scriptDrive\hobl_bin" -ForegroundColor Red
    Exit 1
}

if (-not $logFile) { $logFile = "$scriptDrive\hobl_data\pytorch_inf_run.log" }

$timeTraceFile = "$scriptDrive\hobl_data\run_time.trace"
$totalTokenTraceFile = "$scriptDrive\hobl_data\total_tokens.trace"
$tpsTraceFile = "$scriptDrive\hobl_data\tokens_per_second.trace"


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

Set-Content -Path $logFile -encoding utf8 "-- pytorch_inf run started"
"-- pytorch_inf run started" | log
Write-RunPhaseMarker "phase.run_prep.start"

# Determine processor architecture for pyenv Python version
$osInfo = Get-CimInstance Win32_OperatingSystem
$arch = $osInfo.OSArchitecture
$processorArch = $env:PROCESSOR_ARCHITECTURE

if ($arch -eq "64-bit" -and $processorArch -eq "AMD64") {
    # Detect whether the custom wheel path was used during prep by checking the active pyenv version
    $activeVersion = (pyenv version 2>$null) -replace '\s.*', ''
    if ($activeVersion -match "^3\.13") {
        $pythonVersion = $activeVersion
    } else {
        $pythonVersion = "3.12.10"
    }
} elseif ($arch -match "ARM" -or $processorArch -match "ARM") {
    # Detect whether the custom wheel path was used during prep by checking the active pyenv version
    $activeVersion = (pyenv version 2>$null) -replace '\s.*', ''
    if ($activeVersion -match "^3\.13") {
        $pythonVersion = $activeVersion
    } else {
        $pythonVersion = "3.12.10-arm"
    }
} else {
    " ERROR - Unsupported architecture: $arch (Processor: $processorArch)" | log
    Exit 1
}

# --- Ensure CUDA paths are in session PATH if available ---
if ($env:CUDA_PATH -and (Test-Path $env:CUDA_PATH)) {
    $cudaBin = Join-Path $env:CUDA_PATH "bin"
    $cuptiLib = Join-Path $env:CUDA_PATH "extras\CUPTI\lib64"
    if ($env:PATH -notlike "*$cudaBin*") {
        $env:PATH = "$cudaBin;$env:PATH"
        "Added CUDA bin to session PATH: $cudaBin" | log
    }
    if ((Test-Path $cuptiLib) -and $env:PATH -notlike "*$cuptiLib*") {
        $env:PATH = "$cuptiLib;$env:PATH"
        "Added CUPTI to session PATH: $cuptiLib" | log
    }
}

# --- Optimize PATH: pyenv shims before WindowsApps ---
$pyenvPaths = @(
    "$env:USERPROFILE\.pyenv\pyenv-win\shims",
    "$env:USERPROFILE\.pyenv\pyenv-win\bin"
)

function Set-OptimizedPathOrder {
    function Normalize-PathEntry {
        param([string]$Entry)
        if (-not $Entry) { return $null }
        $value = $Entry.Trim().Trim('"')
        if (-not $value) { return $null }
        if ($value.Length -gt 3 -and $value.EndsWith("\")) {
            $value = $value.TrimEnd("\\")
        }
        return $value
    }

    function Get-PathEntries {
        param([string]$PathValue)
        $entries = New-Object System.Collections.Generic.List[string]
        if (-not $PathValue) { return $entries }
        foreach ($segment in ($PathValue -split ';')) {
            $normalized = Normalize-PathEntry -Entry $segment
            if ($normalized) { $entries.Add($normalized) }
        }
        return $entries
    }

    function Add-UniquePathEntry {
        param(
            [System.Collections.Generic.List[string]]$List,
            [hashtable]$Seen,
            [string]$Entry
        )
        $normalized = Normalize-PathEntry -Entry $Entry
        if (-not $normalized) { return }
        $key = $normalized.ToLowerInvariant()
        if (-not $Seen.ContainsKey($key)) {
            $List.Add($normalized)
            $Seen[$key] = $true
        }
    }

    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")

    $currentUserPath = [System.Environment]::GetEnvironmentVariable('PATH', 'User')

    $windowsAppsCanonical = Normalize-PathEntry -Entry "$env:LOCALAPPDATA\Microsoft\WindowsApps"
    $windowsAppsCanonicalKey = $windowsAppsCanonical.ToLowerInvariant()
    $windowsAppsEnvKey = "%localappdata%\microsoft\windowsapps"

    $pyenvPathKeys = @{}
    foreach ($pyenvPath in $pyenvPaths) {
        $normalizedPyenv = Normalize-PathEntry -Entry $pyenvPath
        if ($normalizedPyenv) { $pyenvPathKeys[$normalizedPyenv.ToLowerInvariant()] = $true }
    }

    $userEntries = Get-PathEntries -PathValue $currentUserPath
    $cleanUserEntries = New-Object System.Collections.Generic.List[string]
    $cleanUserSeen = @{}
    $hadWindowsAppsInUserPath = $false

    foreach ($entry in $userEntries) {
        $entryKey = $entry.ToLowerInvariant()
        if ($entryKey -eq $windowsAppsCanonicalKey -or $entryKey -eq $windowsAppsEnvKey) {
            $hadWindowsAppsInUserPath = $true
            continue
        }
        if ($pyenvPathKeys.ContainsKey($entryKey)) { continue }
        Add-UniquePathEntry -List $cleanUserEntries -Seen $cleanUserSeen -Entry $entry
    }

    $newUserEntries = New-Object System.Collections.Generic.List[string]
    $newUserSeen = @{}
    foreach ($pyenvPath in $pyenvPaths) {
        Add-UniquePathEntry -List $newUserEntries -Seen $newUserSeen -Entry $pyenvPath
    }
    foreach ($entry in $cleanUserEntries) {
        Add-UniquePathEntry -List $newUserEntries -Seen $newUserSeen -Entry $entry
    }
    if ($hadWindowsAppsInUserPath -or (Test-Path $windowsAppsCanonical)) {
        Add-UniquePathEntry -List $newUserEntries -Seen $newUserSeen -Entry $windowsAppsCanonical
    }

    $newUserPath = ($newUserEntries -join ';')

    try {
        [System.Environment]::SetEnvironmentVariable('PATH', $newUserPath, 'User')
        if ($isAdmin) {
            $machinePath = [System.Environment]::GetEnvironmentVariable('PATH', 'Machine')
            $machineEntries = Get-PathEntries -PathValue $machinePath
            $cleanMachineEntries = New-Object System.Collections.Generic.List[string]
            $cleanMachineSeen = @{}
            foreach ($entry in $machineEntries) {
                if ($pyenvPathKeys.ContainsKey($entry.ToLowerInvariant())) { continue }
                Add-UniquePathEntry -List $cleanMachineEntries -Seen $cleanMachineSeen -Entry $entry
            }
            $newMachineEntries = New-Object System.Collections.Generic.List[string]
            $newMachineSeen = @{}
            foreach ($pyenvPath in $pyenvPaths) {
                Add-UniquePathEntry -List $newMachineEntries -Seen $newMachineSeen -Entry $pyenvPath
            }
            foreach ($entry in $cleanMachineEntries) {
                Add-UniquePathEntry -List $newMachineEntries -Seen $newMachineSeen -Entry $entry
            }
            $newMachinePath = ($newMachineEntries -join ';')
            [System.Environment]::SetEnvironmentVariable('PATH', $newMachinePath, 'Machine')
        }
        $machinePath = [System.Environment]::GetEnvironmentVariable('PATH', 'Machine')
        $env:PATH = $machinePath + ";" + $newUserPath
    } catch {
        " ERROR - Failed to update PATH: $($_.Exception.Message)" | log
        Exit 1
    }
}

Set-OptimizedPathOrder

"Setting Python global version to $pythonVersion..." | log
pyenv global $pythonVersion
if ($LASTEXITCODE -ne 0) {
    " ERROR - Failed to set Python version $pythonVersion. Make sure it's installed via pyenv." | log
    "Run the pytorch_inf prep script first to install the correct Python version." | log
    Exit 1
}

"Location of python:" | log
pyenv which python

"-- CD to resources" | log
Set-Location "$scriptDrive\hobl_bin\pytorch_inf_resources"
checkCmd($?)

"-- Extract log directory from logFile path" | log
$logDir = Split-Path -Parent $logFile
"Log directory: $logDir" | log

# inference.py writes pytorch_inference_info.csv to --log-dir with these metrics:
#   time_to_first_token_ms, time_to_first_token_s, tokens_per_second,
#   total_tokens_generated, total_generation_time_s, ai_model, ai_device
$inferenceCSV = Join-Path $logDir "pytorch_inference_info.csv"
Write-RunPhaseMarker "phase.run_prep.end"
Write-RunPhaseMarker "phase.run_build.start"

"-- Run LLM Phi-4-mini inferencing" | log
if ($noGpu) {
    "Running in CPU-only mode (--no-gpu)" | log
    python inference.py --prompt "What is the meaning of life?" --log-dir "$logDir" --no-gpu > "$logDir\pytorch_inf_output.txt" 2>&1
} else {
    python inference.py --prompt "What is the meaning of life?" --log-dir "$logDir" > "$logDir\pytorch_inf_output.txt" 2>&1
}
check($lastexitcode)
Write-RunPhaseMarker "phase.run_build.end"
Write-RunPhaseMarker "phase.run_results.start"

"-- Parsing inference metrics" | log

# Read metrics from the CSV that inference.py produced (key,value format)
if (Test-Path $inferenceCSV) {
    $csvContent = Get-Content $inferenceCSV
    $metricsHash = @{}
    foreach ($line in $csvContent) {
        $parts = $line -split ',', 2
        if ($parts.Count -eq 2) {
            $metricsHash[$parts[0]] = $parts[1]
        }
    }
    $total_generation_time_s = $metricsHash['total_generation_time_s']
    $time_to_first_token_ms = $metricsHash['time_to_first_token_ms']
    $time_to_first_token_s = $metricsHash['time_to_first_token_s']
    $tokens_per_second = $metricsHash['tokens_per_second']
    $total_tokens_generated = $metricsHash['total_tokens_generated']
    $ai_model = $metricsHash['ai_model']
    $ai_device = $metricsHash['ai_device']
} else {
    " ERROR - Inference metrics file not found: $inferenceCSV" | log
    Exit 1
}

# Use total_generation_time_s as scenario_runtime
$scenarioRuntime = if ($total_generation_time_s) { $total_generation_time_s } else { 0 }

# ============================================================================
# Save results
# ============================================================================
$resultsFile = Join-Path $logDir "pytorch_inf_results.csv"

"" | log
"========================================" | log
"PyTorch Inference Metrics Summary" | log
"========================================" | log
"Time to First Token: ${time_to_first_token_ms}ms (${time_to_first_token_s}s)" | log
"Tokens per Second:   $tokens_per_second" | log
"Total Tokens:        $total_tokens_generated" | log
"Generation Time:     ${total_generation_time_s}s" | log
"Model:               $ai_model" | log
"Device:              $ai_device" | log
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
    "ai_model,$ai_model"
    "ai_device,$ai_device"
)
$metricsContent | Set-Content $resultsFile -Encoding UTF8
"Metrics saved to: $resultsFile" | log

"-- pytorch_inf run completed" | log

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