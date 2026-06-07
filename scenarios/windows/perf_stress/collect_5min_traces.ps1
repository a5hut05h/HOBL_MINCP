# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.
#
# collect_5min_traces.ps1 - Background rolling WPR capture for perf_stress.
#
# Runs alongside the core HOBL trace using a named WPR instance
# (-instancename perfStressHeavy) so it does not collide with the default
# unnamed WPR session. Debug use only - a second concurrent WPR session
# perturbs measurements and the output of this run should not be used as
# a reference number.
#
# Default behavior: rolling captures using general_cpi_collector.wprp, saved to
# C:\hobl_bin\perf_stress_heavy\<RunName>\WPR_<timestamp>.etl. A 15-20 min run
# at the default 5-min interval is expected to yield ~3 segments. Note that under
# heavy load (75% CPU + many tabs) `wpr -stop` for the Verbose CPI+kernel profile
# can take many minutes to flush, which reduces effective segment count; if that
# is observed, shorten the interval or switch to a lighter profile.
#
# Output is deliberately OUTSIDE C:\hobl_data so the heavy, often-locked rolling
# .etl files never enter HOBL's base scenario._copy_data_from_remote(C:\hobl_data)
# teardown tar (a segment still being written truncated that streamed tar and
# failed runs). perf_stress.tearDown() pulls this folder separately, best-effort,
# after the core result copy.

param(
    [int]$IntervalMinutes = 5,
    [int]$Iterations = 0,
    [string]$OutputDir = "C:\hobl_bin\perf_stress_heavy",
    [string]$RunName = "",

    # Default custom WPRP profile uploaded by code_PSECTRC.py
    [string]$WprpPath = "C:\hobl_bin\general_cpi_collector.wprp",

    # Optional fallback if WPRP not desired (e.g. -WprProfile GeneralProfile)
    [string]$WprProfile,

    # Named WPR instance - kept distinct from HOBL core's unnamed session
    [string]$InstanceName = "perfStressHeavy"
)

$ErrorActionPreference = "Continue"

# Capture admin state for the log. Do NOT re-launch with -Verb RunAs:
# 1) RunAs strips the original -RunName/-IntervalMinutes/-OutputDir args, so the
#    elevated copy writes to the wrong (default) location with no per-run subdir.
# 2) RunAs triggers a UAC dialog that never gets answered on an unattended DUT,
#    so the elevated copy hangs until teardown kills it, producing no output.
# If the DUT remote agent isn't admin, wpr -start will fail with a clear exit
# code that collect_log.txt now captures - much better than a silent hang.
$script:IsAdmin = ([Security.Principal.WindowsPrincipal]`
    [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(`
    [Security.Principal.WindowsBuiltInRole]::Administrator)

# Build per-run subdirectory under OutputDir
if ($RunName) {
    $OutputDir = Join-Path $OutputDir $RunName
}
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

# Persistent log file inside OutputDir so wpr -start/-stop failures are visible
# AFTER the folder is pulled back to the host (this background script's console
# output otherwise only goes to a hidden window and never reaches hobl.log).
# Writing it immediately also guarantees the folder is never empty, so the
# best-effort heavy pull always returns at least this diagnostic log.
$script:LogFile = Join-Path $OutputDir "collect_log.txt"
function Log([string]$msg) {
    $line = "[$(Get-Date -Format 'yyyyMMdd_HHmmss')] $msg"
    Write-Host $line
    if ($script:LogFile) {
        try { Add-Content -LiteralPath $script:LogFile -Value $line -ErrorAction SilentlyContinue } catch {}
    }
}

# Surface admin state immediately - wpr -start requires Administrator. If the
# DUT remote agent runs unelevated, wpr -start will fail in the loop and the
# log will show both this banner and the exit code, making the cause obvious.
if ($script:IsAdmin) {
    Log " INFO - Running as Administrator"
} else {
    Log " ERROR - NOT running as Administrator. wpr -start will fail. Configure the DUT remote agent to run elevated."
}

# Determine profile argument
if ($WprProfile) {
    Log " INFO - Using built-in WPR profile -> $WprProfile"
    $profileArg = $WprProfile
}
else {
    if (-not (Test-Path $WprpPath)) {
        Log " ERROR - Default WPRP file not found: $WprpPath"
        throw " ERROR - Default WPRP file not found: $WprpPath"
    }
    Log " INFO - Using custom WPRP profile -> $WprpPath"
    # No surrounding quotes: $WprpPath has no spaces and literal quotes are
    # passed through to wpr by PowerShell's native-arg handling, breaking it.
    $profileArg = $WprpPath
}

Log " INFO - WPR rolling capture started | Interval: $IntervalMinutes min | Instance: $InstanceName"
Log " INFO - Output: $OutputDir"
Log "---------------------------------------"

$iteration = 0

try {
    while ($true) {
        $iteration++
        if ($Iterations -gt 0 -and $iteration -gt $Iterations) {
            break
        }

        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $etlPath = Join-Path $OutputDir "WPR_${timestamp}.etl"

        Log " INFO - Recording started (iteration $iteration, segment=$timestamp)"

        # Cancel ONLY our named instance (do NOT touch HOBL core's unnamed session)
        wpr -cancel -instancename $InstanceName 2>$null | Out-Null

        $startOut = & wpr -start $profileArg -filemode -instancename $InstanceName 2>&1
        $startExit = $LASTEXITCODE
        if ($startExit -ne 0) {
            Log " ERROR - wpr -start failed exit=$startExit (instance=$InstanceName): $($startOut -join ' | ')"
            Start-Sleep -Seconds 30
            continue
        }
        Log " INFO - wpr -start ok (instance=$InstanceName)"

        Start-Sleep -Seconds ($IntervalMinutes * 60)

        # Log BEFORE calling wpr -stop so collect_log.txt records that we got here
        # even when stop_perfStress_background.ps1 force-kills this script mid-flush
        # (without this line, the absence of a "Trace saved" entry is ambiguous
        # between "never reached stop" and "stop was killed before completing").
        Log " INFO - Calling wpr -stop -> $etlPath (flush time depends on load and profile)."

        # -compress: shrink the heavy ETL (often 3-5x) so the DUT->host pull stays
        # manageable for remote / back-to-back runs (matches the core trace's -stop).
        $stopOut = & wpr -stop $etlPath -compress -instancename $InstanceName 2>&1
        $stopExit = $LASTEXITCODE
        if ($stopExit -eq 0) {
            Log " INFO - Trace saved -> $etlPath"
        } else {
            Log " ERROR - wpr -stop failed exit=$stopExit (instance=$InstanceName): $($stopOut -join ' | ')"
        }
        Log "---------------------------------------"
    }
}
catch {
    Log " ERROR - Tracing interrupted: $_"
}
finally {
    # Clean up only our named instance
    wpr -cancel -instancename $InstanceName 2>$null | Out-Null
    Log " INFO - Tracing session ended (instance=$InstanceName)"
}
