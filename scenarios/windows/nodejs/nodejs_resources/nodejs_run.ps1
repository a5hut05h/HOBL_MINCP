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

if (-not $logFile) { $logFile = "$scriptDrive\hobl_data\nodejs_run.log" }

# Simple standalone Node.js build script

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
        [HoblRunPhaseProvider]::Log.Phase($Marker, "nodejs")
    } catch {
    }
}

# Determine processor architecture and set appropriate Python version
$osInfo = Get-CimInstance Win32_OperatingSystem
$arch = $osInfo.OSArchitecture
$processorArch = $env:PROCESSOR_ARCHITECTURE

if ($arch -eq "64-bit" -and $processorArch -eq "AMD64") {
    $pythonVersion = "3.12.10"
    $arch_version = "x64"
    $vsProduct = "BuildTools"
    $vsArchParam = "x64"
    $vsHostArchParam = "x64"
} elseif ($arch -match "ARM" -or $processorArch -match "ARM") {
    $pythonVersion = "3.12.10-arm"
    $arch_version = "arm64"
    $vsProduct = "Community"
    $vsArchParam = "arm64"
    $vsHostArchParam = "arm64"
} else {
    Write-Host " ERROR - Unsupported architecture: $arch (Processor: $processorArch)" -ForegroundColor Red
    Exit 1
}
Write-RunPhaseMarker "phase.run_prep.start"

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

# Store original environment for restoration
$originalPath = $env:PATH
$originalPython = $env:PYTHON
$originalPythonHome = $env:PYTHONHOME

# --- Discover Visual Studio via vswhere and initialize developer environment ---
function getVSVersion {
    param([string]$product)

    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) {
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
                Path = $instance.installationPath
            }
        }
    } catch {
        return $null
    }

    return $null
}

"-- Initializing Visual Studio Developer Command environment" | log
$Env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

# Verify required commands are findable on PATH after refresh.
# Fail fast with a clear diagnostic instead of a chain of "term not recognized" errors.
# pyenv check is done before we prepend pyenv paths below; pyenv must be installed by prep.
foreach ($cmd in @('pyenv')) {
    $resolved = Get-Command $cmd -ErrorAction SilentlyContinue
    if (-not $resolved) {
        " ERROR - Required command '$cmd' not found on PATH after refresh." | log
        " ERROR - Prep may not have completed, or the RPC service has a stale PATH." | log
        " ERROR - PATH: $env:Path" | log
        Exit 1
    }
    "Found ${cmd}: $($resolved.Source)" | log
}

$vsInfo = getVSVersion -product $vsProduct
if (-not $vsInfo -or -not $vsInfo.Path) {
    " ERROR - Visual Studio $vsProduct installation not found via vswhere" | log
    Exit 1
}
"Found Visual Studio at: $($vsInfo.Path)" | log

$vsDevCmd = Join-Path $vsInfo.Path "Common7\Tools\VsDevCmd.bat"
if (-not (Test-Path $vsDevCmd)) {
    " ERROR - VsDevCmd.bat not found at: $vsDevCmd" | log
    Exit 1
}
"Using VsDevCmd.bat: $vsDevCmd" | log

$vsDevCmdArgs = "-arch=$vsArchParam -host_arch=$vsHostArchParam -no_logo"
"Sourcing VsDevCmd.bat with args: $vsDevCmdArgs" | log
cmd /c "`"$vsDevCmd`" $vsDevCmdArgs && set" | ForEach-Object {
    if ($_ -match '^([^=]+)=(.*)$') {
        [System.Environment]::SetEnvironmentVariable($matches[1], $matches[2], 'Process')
    }
}
"Visual Studio Developer Command environment initialized" | log

# Setup pyenv environment
$pyenvRoot = "$env:USERPROFILE\.pyenv"
$env:PATH = "$pyenvRoot\pyenv-win\bin;$pyenvRoot\pyenv-win\shims;$env:PATH"

# Navigate to nodejs build directory
cd "$scriptDrive\hobl_bin\nodejs\node-25.0.0"

# Set global Python version and get paths
pyenv global $pythonVersion

Write-Host "Current Python version:"
pyenv version

$pythonPath = & pyenv which python
$pythonDir = Split-Path $pythonPath -Parent

# Keep WindowsApps in PATH, but de-duplicate the explicit Python directory before prepending
$cleanPath = ($env:PATH -split ';' | Where-Object { $_ -and ($_ -ne $pythonDir) }) -join ';'
$env:PATH = "$pythonDir;$cleanPath"

# Set environment variables for vcbuild.bat
$env:PYTHON = $pythonPath
$env:PYTHONHOME = $pythonDir
"Finished settings environment variables" | log
"Cleaning exisiting nodejs build" | log

# Clean and build Node.js
.\vcbuild.bat clean $arch_version openssl-no-asm

# Remove build directories to ensure clean state
$dirs_to_remove = @("out", "Release", "Debug")
foreach ($dir in $dirs_to_remove) {
    if (Test-Path $dir) {
        Remove-Item -Recurse -Force $dir
        Write-Host "Removed directory: $dir"
    }
}

"Starting build of Node.js" | log
Write-RunPhaseMarker "phase.run_prep.end"
Write-RunPhaseMarker "phase.run_build.start"

$buildTimeLog = "$scriptDrive\hobl_data\nodejs_build_time.log"
$metricsFile = "$scriptDrive\hobl_data\nodejs_results.csv"
$traceFile = "$scriptDrive\hobl_data\nodejs_results.trace"

$buildTime = (Measure-Command {.\vcbuild.bat release $arch_version openssl-no-asm *> "$scriptDrive\hobl_data\nodejs_build.log"}).TotalSeconds
$buildTime = [math]::Round($buildTime, 2)
$scenarioRuntime = $buildTime
Write-RunPhaseMarker "phase.run_build.end"
Write-RunPhaseMarker "phase.run_results.start"

"Build completed in ${buildTime}s" | log

# Write build time to log file
Set-Content -Path $buildTimeLog -Value "build_time: ${buildTime}s"

# Write metrics CSV file (key,value format)
$metricsContent = @"
scenario_runtime,$scenarioRuntime
build_time,$buildTime
"@

Set-Content -Path $metricsFile -Value $metricsContent -NoNewline

# create .trace header if not exists
if (-not (Test-Path $traceFile)) {
    "Creating trace file with header: $traceFile" | log
    Set-Content -Path $traceFile -Value "Timestamp,node_build_time" -Encoding UTF8
}

$elapsedTime = ((Get-Date) - [DateTime]$startTime).TotalSeconds
# Append to .trace file for timeline correlation (key,value format)
$traceContent = @"
$elapsedTime,$buildTime
"@
"Appending build time to trace file: $traceFile" | log
Add-Content -Path $traceFile -Value $traceContent


"Completed build of Node.js, buildtime logged to $buildTimeLog" | log
"Metrics saved to: $metricsFile" | log

Write-Host ""
Write-Host "========================================"
Write-Host "Node.js Metrics Summary"
Write-Host "========================================"
Write-Host "Build Time:  ${buildTime}s"
Write-Host "scenario_runtime (total): ${scenarioRuntime}s"
Write-Host "========================================"

# Restore original environment to not affect other programs
$env:PATH = $originalPath
if ($originalPython) { $env:PYTHON = $originalPython } else { Remove-Item Env:PYTHON -ErrorAction SilentlyContinue }
if ($originalPythonHome) { $env:PYTHONHOME = $originalPythonHome } else { Remove-Item Env:PYTHONHOME -ErrorAction SilentlyContinue }

Write-Host "Environment restored - Python settings reverted to original state"
Write-RunPhaseMarker "phase.run_results.end"

Exit 0
