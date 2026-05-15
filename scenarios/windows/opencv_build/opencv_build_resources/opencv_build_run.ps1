# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

param(
    [string]$logFile = "",
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

if (-not $logFile) { $logFile = "$scriptDrive\hobl_data\opencv_build_run.log" }

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
        [HoblRunPhaseProvider]::Log.Phase($Marker, "opencv_build")
    } catch {
    }
}

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
        $code = 1
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

Set-Content -Path $logFile -encoding utf8 "-- opencv_build_run started ($logSuffix version)"
Write-RunPhaseMarker "phase.run_prep.start"

$Env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

# Verify required commands are findable on PATH after refresh.
# Fail fast with a clear diagnostic instead of a chain of "term not recognized" errors.
foreach ($cmd in @('cmake')) {
    $resolved = Get-Command $cmd -ErrorAction SilentlyContinue
    if (-not $resolved) {
        " ERROR - Required command '$cmd' not found on PATH after refresh." | log
        " ERROR - Prep may not have completed, or the RPC service has a stale PATH." | log
        " ERROR - PATH: $env:Path" | log
        Exit 1
    }
    "Found ${cmd}: $($resolved.Source)" | log
}

$time = Get-Date -Format "HH:mm:ss"
"$time - Clean build files" | log

if (-not (Test-Path "$scriptDrive\opencv\build_msvc")) {
    " ERROR - build_msvc directory does not exist. Prep script must be run first." | log
    Exit 1
}

Set-Location "$scriptDrive\opencv\build_msvc"
cmake --build . --target clean --config Release
check($lastexitcode)

$time = Get-Date -Format "HH:mm:ss"
"$time - Build OpenCV Project" | log
Write-RunPhaseMarker "phase.run_prep.end"
Write-RunPhaseMarker "phase.run_build.start"

$buildDuration = Measure-Command {
    cmake --build . --config Release
}
check($lastexitcode)

$buildTime = [math]::Round($buildDuration.TotalSeconds, 2)
$scenarioRuntime = $buildTime
Write-RunPhaseMarker "phase.run_build.end"
Write-RunPhaseMarker "phase.run_results.start"

$time = Get-Date -Format "HH:mm:ss"
"$time - OpenCV build completed in ${buildTime}s" | log

$time = Get-Date -Format "HH:mm:ss"
"$time - Build OpenCV Install Project" | log
cmake --build . --target INSTALL --config Release
check($lastexitcode)

$time = Get-Date -Format "HH:mm:ss"
"$time - OpenCV completed building" | log


$time = Get-Date -Format "HH:mm:ss"
"$time - Confirm build by running opencv_version.exe" | log
./install/x64/vc17/bin/opencv_version.exe
check($lastexitcode)

# Print metrics summary
"" | log
"========================================" | log
"OpenCV Build Metrics Summary" | log
"========================================" | log
"Build Time:       ${buildTime}s" | log
"Architecture:     $logSuffix" | log
"Scenario Runtime: ${scenarioRuntime}s" | log
"========================================" | log

# Write metrics CSV file (key,value format - HOBL convention)
$outputDir = Split-Path $logFile -Parent
$resultsFile = Join-Path $outputDir "opencv_build_results.csv"
$traceFile = Join-Path $outputDir "opencv_build_results.trace"

$metricsContent = @(
    "scenario_runtime,$scenarioRuntime"
    "build_time,$buildTime"
    "architecture,$logSuffix"
)
$metricsContent | Set-Content $resultsFile -Encoding UTF8
"Metrics saved to: $resultsFile" | log

 # create .trace header if not exists
if (-not (Test-Path $traceFile)) {
    "Creating trace file with header: $traceFile" | log
    Set-Content -Path $traceFile -Value "Timestamp,opencv_build_time" -Encoding UTF8
}

$elapsedTime = ((Get-Date) - [DateTime]$startTime).TotalSeconds
$traceContent = @"
$elapsedTime,$buildTime
"@

"Appending build time to trace file: $traceFile" | log  
Add-Content -Path $traceFile -Value $traceContent -Encoding UTF8


"-- opencv_build_run completed ($logSuffix version)" | log
Write-RunPhaseMarker "phase.run_results.end"

Exit 0
