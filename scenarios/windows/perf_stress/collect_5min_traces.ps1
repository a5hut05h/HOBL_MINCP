# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.


 param(
    [int]$IntervalMinutes = 5,
    [int]$Iterations = 0,
    [string]$OutputDir = "C:\WPR_Traces",
    [string]$RunName = "",

    # ✅ Default custom WPRP profile
    [string]$WprpPath = "C:\hobl_bin\general_cpi_collector.wprp",

    # Optional fallback if WPRP not desired
    [string]$WprProfile
)

# Elevation check
if (-not ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(`
    [Security.Principal.WindowsBuiltInRole]::Administrator)) {

    Start-Process powershell -Verb RunAs -ArgumentList `
        "-ExecutionPolicy Bypass -File `"$PSCommandPath`""

    exit
}

# Build per-run subdirectory under OutputDir
if ($RunName) {
    $OutputDir = Join-Path $OutputDir $RunName
}
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

# Determine profile logic
if ($WprProfile) {

    Write-Host "Using built-in WPR profile → $WprProfile"
    $profileArg = $WprProfile
}
else {

    if (-not (Test-Path $WprpPath)) {
        throw "Default WPRP file not found: $WprpPath"
    }

    Write-Host "Using custom WPRP profile → $WprpPath"
    $profileArg = "`"$WprpPath`""
}

Write-Host "WPR tracing started | Interval: $IntervalMinutes min"
Write-Host "Output: $OutputDir"
Write-Host "---------------------------------------"

$iteration = 0

try {
    while ($true) {

        $iteration++

        if ($Iterations -gt 0 -and $iteration -gt $Iterations) {
            break
        }

        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $etlPath = Join-Path $OutputDir "WPR_${timestamp}.etl"

        Write-Host "[$timestamp] Recording started"

        # Cancel stale sessions (critical safety)
        wpr -cancel 2>$null | Out-Null

        wpr -start $profileArg -filemode | Out-Null

        Start-Sleep -Seconds ($IntervalMinutes * 60)

        wpr -stop $etlPath | Out-Null

        Write-Host "[$timestamp] Trace saved → $etlPath"
        Write-Host "---------------------------------------"
    }
}
catch {
    Write-Warning "Tracing interrupted"
}
finally {
    wpr -cancel 2>$null | Out-Null
    Write-Host "Tracing session ended"
}
 