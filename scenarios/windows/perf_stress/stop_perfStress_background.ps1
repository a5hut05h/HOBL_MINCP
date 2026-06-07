# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

$ErrorActionPreference = "SilentlyContinue"
Write-Host " INFO - stop_perfStress_background starting"

# Retry helper so cleanup remains robust when processes are still spinning up/down.
function Stop-PerfStressProcesses {
    $patterns = "percentile_stress\.py|install_python\.ps1"
    $attempt = 0
    while ($attempt -lt 5) {
        $found = $false
        $killedThisAttempt = 0

        Get-CimInstance Win32_Process |
            Where-Object { $_.CommandLine -and ($_.CommandLine -match $patterns) } |
            ForEach-Object {
                $found = $true
                $killedThisAttempt++
                Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
            }

        # Extra guards for python launch variants.
        Get-CimInstance Win32_Process |
            Where-Object { $_.Name -match "(?i)^(python|py|pythonw)\.exe$" -and $_.CommandLine -and ($_.CommandLine -match "percentile_stress\.py") } |
            ForEach-Object {
                $found = $true
                $killedThisAttempt++
                Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
            }

        Write-Host (" INFO - Stop attempt {0}: killed candidates={1}" -f ($attempt + 1), $killedThisAttempt)

        if (-not $found) {
            break
        }

        Start-Sleep -Milliseconds 500
        $attempt++
    }
}

function Stop-HeavyWprCapture {
    # Stops the optional background rolling WPR capture started by collect_5min_traces.ps1
    # (perf_stress:bg_heavy_capture=1). This is CRITICAL for teardown reliability: the base
    # scenario._copy_data_from_remote() tars all of C:\hobl_data during teardown. If the named
    # heavy WPR session is still live, its in-progress, growing .etl truncates that tar
    # (tarfile.ReadError: unexpected end of data) and the entire DUT->host download aborts.
    param(
        [string]$InstanceName = "perfStressHeavy",
        # Grace period (seconds) to let an in-progress `wpr -stop` finish before we
        # force-kill the collect script. Under heavy load `wpr -stop` for the Verbose
        # CPI+kernel profile can take 10-15 min, so this grace period will NOT save a
        # long flush - but when the stop happens to be close to done (light load, end
        # of iteration), it lets the script return cleanly and log "Trace saved",
        # turning a forced-kill into a clean exit.
        [int]$StopGraceSeconds = 60
    )

    # 1. Give an in-progress `wpr -stop` a brief grace period to finalize. We look
    #    for any wpr.exe child of the collect script. If none is running, no wait.
    #    Polling is cheap (every 2s) and bounded by $StopGraceSeconds.
    $wprInFlight = @(Get-CimInstance Win32_Process -Filter "Name='wpr.exe'" -ErrorAction SilentlyContinue)
    if ($wprInFlight.Count -gt 0) {
        Write-Host (" INFO - Detected {0} in-flight wpr.exe; waiting up to {1}s for graceful finish" -f $wprInFlight.Count, $StopGraceSeconds)
        $waited = 0
        while ($waited -lt $StopGraceSeconds) {
            Start-Sleep -Seconds 2
            $waited += 2
            $still = @(Get-CimInstance Win32_Process -Filter "Name='wpr.exe'" -ErrorAction SilentlyContinue)
            if ($still.Count -eq 0) {
                Write-Host (" INFO - wpr.exe exited after {0}s grace; iteration finished cleanly" -f $waited)
                break
            }
        }
        $finalCount = @(Get-CimInstance Win32_Process -Filter "Name='wpr.exe'" -ErrorAction SilentlyContinue).Count
        if ($finalCount -gt 0) {
            Write-Host (" INFO - wpr.exe still running after {0}s grace; proceeding with force-cancel (heavy ETL may be partial)" -f $StopGraceSeconds)
        }
    }

    # 2. Kill the rolling-capture driver script so it cannot start a new WPR segment.
    #    (Force-killing the process skips its own finally{} cleanup, so we must cancel
    #     the WPR session explicitly in step 3.)
    $killed = 0
    Get-CimInstance Win32_Process |
        Where-Object { $_.CommandLine -and ($_.CommandLine -match "collect_5min_traces\.ps1") } |
        ForEach-Object {
            $killed++
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
    Write-Host (" INFO - Killed collect_5min_traces.ps1 processes={0}" -f $killed)

    # 3. Release the named heavy WPR session. Use -cancel (fast, frees the file lock
    #    immediately) rather than -stop (which flushes a heavy kernel trace and can hang
    #    for minutes under stress). Completed rolling segments are already finalized on
    #    disk and will still be copied back; only an in-progress segment is discarded.
    wpr -cancel -instancename $InstanceName 2>$null | Out-Null
    Write-Host (" INFO - Cancelled heavy WPR session (instance={0})" -f $InstanceName)
}

function Close-ExplorerWindows {
    # Filter to actual File Explorer folder windows (have a MainWindowTitle).
    # The desktop shell explorer process has MainWindowHandle != 0 but no title, so excluding it
    # avoids the misleading "before=1 / after=1" count caused by the always-present shell process.
    $explorerCount = (Get-Process explorer | Where-Object { $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle -ne '' } | Measure-Object).Count
    Write-Host (" INFO - Explorer folder windows before close={0}" -f $explorerCount)

    Get-Process explorer |
        Where-Object { $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle -ne '' } |
        ForEach-Object { $_.CloseMainWindow() | Out-Null }

    Start-Sleep -Milliseconds 700

    # Fallback close for any remaining explorer folder windows.
    try {
        $shell = New-Object -ComObject Shell.Application
        foreach ($w in $shell.Windows()) {
            if ($w -and $w.FullName -and ($w.FullName -like "*explorer.exe")) {
                $w.Quit()
            }
        }
    }
    catch {
        Write-Host " ERROR - stop_perfStress_background fallback close failed."
    }

    $remainingExplorer = (Get-Process explorer | Where-Object { $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle -ne '' } | Measure-Object).Count
    Write-Host (" INFO - Explorer folder windows after close={0}" -f $remainingExplorer)
}

# Stop background processes launched by perf_stress setup.
Stop-PerfStressProcesses

# Stop the optional background heavy WPR rolling capture (bg_heavy_capture=1) so its
# in-progress .etl under C:\hobl_data cannot truncate the teardown result-tar download.
Stop-HeavyWprCapture

$remainingStress = (Get-CimInstance Win32_Process |
    Where-Object {
        ($_.CommandLine -and ($_.CommandLine -match "percentile_stress\.py|install_python\.ps1")) -or
        ($_.Name -match "(?i)^(python|py|pythonw)\.exe$" -and $_.CommandLine -and ($_.CommandLine -match "percentile_stress\.py"))
    } |
    Measure-Object).Count

Write-Host (" INFO - Remaining stress candidates after stop={0}" -f $remainingStress)

# Close open File Explorer windows so reruns start clean.
Close-ExplorerWindows

Write-Host " INFO - stop_perfStress_background completed"

exit 0


