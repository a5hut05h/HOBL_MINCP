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
    # Fail fast. The heavy CPI profile (general_cpi_collector.wprp) uses SampledProfile
    # + PMU HardwareCounters, which require SeSystemProfilePrivilege (Administrator).
    # Without elevation every `wpr -start` returns 0xc5585011 ("Failed to enable the
    # policy to profile system performance") and the loop would otherwise spin uselessly
    # for the whole run, producing ZERO ETLs (observed on DUT collect_log 20260623_0140xx,
    # 16 failed iterations). Aborting now makes the misconfiguration loud and immediate
    # instead of burying it under dozens of identical retries.
    Log " ERROR - NOT running as Administrator. The heavy CPI profile requires elevation."
    Log " ERROR - Configure the DUT remote agent (simple_remote) to run ELEVATED, then re-run."
    Log " ERROR - Aborting rolling capture - zero segments would be produced until this is fixed."
    exit 1
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
$script:SavedCount = 0

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
            # 0xc5585011 (= -984068079) = "Failed to enable the policy to profile system
            # performance": the SampledProfile/PMU source could not be claimed. This is
            # NOT transient - it means missing elevation, or another WPR/xperf session
            # already owns the system profiler/PMU. Retrying every 30s just burns the
            # whole run with zero output, so abort loudly instead of spinning.
            if ($startExit -eq -984068079) {
                Log " ERROR - System profiler/PMU could not be enabled (0xc5585011) - not a transient error."
                Log " ERROR - Causes: DUT agent not elevated, or another WPR/xperf session owns the CPU profiler/PMU."
                Log " ERROR - Aborting rolling capture after $script:SavedCount saved segment(s)."
                exit 1
            }
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

        # CRITICAL: run `wpr -stop` (the trace merge) at HIGH priority.
        #
        # The merge is CPU-bound, not I/O-bound (a ~1 GB ETL writes to disk in
        # seconds). The percentile_stress.py workers run at NORMAL priority and
        # busy-spin to pin the CPU at stress_cpu_target (75-85%). A NORMAL-priority
        # `wpr -stop` therefore gets starved and a single flush ran 15+ min, consuming
        # the whole run so only ONE segment ever completed (see perf_stress_321/323:
        # stop called at 02:16:06, run still flushing when teardown cancelled it at
        # 02:31:37). Starting wpr.exe and bumping it to High lets the merge preempt the
        # stress workers and finish in ~1-2 min, restoring the rolling cadence. Full
        # diagnostic fidelity is preserved (identical profile/providers); -compress is
        # still omitted so the flush stays as light as possible under load.
        #
        # Launch via [System.Diagnostics.Process]::Start(ProcessStartInfo) rather
        # than Start-Process. Start-Process -PassThru -NoNewWindow combined with
        # -RedirectStandardOutput/-RedirectStandardError returns a Process object
        # whose ExitCode is NOT reliably populated after WaitForExit() on PS 5.1:
        # observed in run perf_stress_351 where every successful flush logged
        # "exit=" (empty) and was misreported as an ERROR even though stdout
        # clearly said "The trace was successfully saved." Direct .NET Process.Start
        # always populates ExitCode and lets us read both streams synchronously
        # without temp files.
        $stopExit = $null
        $stopOutText = ""
        $stopErrText = ""
        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = "wpr.exe"
            $psi.Arguments = '-stop "' + $etlPath + '" -instancename ' + $InstanceName
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.CreateNoWindow = $true
            $stopProc = [System.Diagnostics.Process]::Start($psi)
            try { $stopProc.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::High } catch {
                Log " INFO - Could not raise wpr -stop priority (continuing at default): $_"
            }
            # ReadToEnd before WaitForExit on the stdout stream avoids deadlock when
            # wpr fills its pipe buffer (multi-MB progress output). stderr is small
            # enough that order does not matter.
            $stopOutText = $stopProc.StandardOutput.ReadToEnd()
            $stopErrText = $stopProc.StandardError.ReadToEnd()
            $stopProc.WaitForExit()
            $stopExit = $stopProc.ExitCode
        } catch {
            Log " ERROR - Failed to launch wpr -stop: $_"
            $stopExit = -1
        }
        $stopMsg = (($stopOutText + "`n" + $stopErrText).Trim())
        # Treat as success when ExitCode is 0, OR when wpr's stdout confirms the
        # save (defence-in-depth: if a future shell quirk swallows ExitCode again,
        # the segment count stays honest as long as wpr printed its success line).
        $stopSucceeded = ($stopExit -eq 0) -or ($stopMsg -match 'trace was successfully saved')
        if ($stopSucceeded) {
            $script:SavedCount++
            Log " INFO - Trace saved (segment #$script:SavedCount) -> $etlPath"
        } else {
            Log " ERROR - wpr -stop failed exit=$stopExit (instance=$InstanceName): $stopMsg"
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
    Log " INFO - Rolling capture summary: $script:SavedCount ETL segment(s) saved to $OutputDir"
    Log " INFO - Tracing session ended (instance=$InstanceName)"
}
