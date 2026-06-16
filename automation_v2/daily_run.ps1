# HOBL Daily Automation v2 — entry point fired by Windows Task Scheduler.
#
# Reads automation_v2\schedule.config.json, then for each enabled job:
#   1. Parses the testplan .ps1 file (a flat list of `hobl.cmd -s ...` lines)
#      into the planRows array HOBLweb's /plan/Create endpoint expects.
#   2. Sets AutoResubmit on Seq 0 to (runsPerDay - 1) so HOBLweb auto-cycles.
#   3. POSTs it as a brand-new plan via /plan/Create (the same call HOBLweb's
#      UI makes when you click Submit).
#
# Unlike v1 there is NO template plan in HOBLweb's database — the testplan
# .ps1 file in git is the canonical source. This means:
#   - No manual "build plan in UI, paste PlanID into config" step.
#   - One file per plan, PR-reviewable, drift-free.
#   - The same .ps1 a developer runs locally is the one HOBLweb runs daily.
#
# HOBLweb still owns the queue, the worker process, the resubmission cycle
# and the per-scenario logs — this script is just a "robot finger" that
# presses Submit at the scheduled time, and skips if a previous day's plan
# is still running (overlap = "skip").
#
# Run manually:    powershell -ExecutionPolicy Bypass -File <this file>
# Dry run (build): powershell -ExecutionPolicy Bypass -File <this file> -DryRun
# Registered:      by register_schedule.ps1
#
# Exit codes:
#   0  all jobs submitted (or correctly skipped)
#   1  some jobs failed; others may have succeeded
#   2  all enabled jobs failed
#   3  pre-flight failed (HOBLweb down, Poke task missing, config invalid, ...)

param(
    [string]$configPath = "",
    [string]$logFile    = "",
    [switch]$DryRun                # parse + build rows + log them, but do NOT POST
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

$scriptDrive = Split-Path -Qualifier $PSScriptRoot
if (-not $configPath) { $configPath = Join-Path $PSScriptRoot "schedule.config.json" }

# --- Load config -------------------------------------------------------------
if (-not (Test-Path $configPath)) {
    Write-Host " ERROR - Config not found: $configPath" -ForegroundColor Red
    Exit 3
}
try {
    $cfg = Get-Content -Path $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    Write-Host " ERROR - Could not parse config: $($_.Exception.Message)" -ForegroundColor Red
    Exit 3
}

$baseUrl    = if ($cfg.hoblwebBaseUrl)   { $cfg.hoblwebBaseUrl }              else { "http://localhost" }
$logDir     = if ($cfg.logDir)           { $cfg.logDir }                      else { "$scriptDrive\hobl_results\_automation_logs" }
$retainDays = if ($cfg.logRetentionDays) { [int]$cfg.logRetentionDays }       else { 30 }
$overlap    = if ($cfg.overlap)          { ([string]$cfg.overlap).ToLower() } else { "skip" }

$submitTimeout = 30
$submitMax     = 5
$submitBackoff = @(5, 15, 60, 180, 600)
if ($cfg.submit) {
    if ($cfg.submit.timeoutSec)  { $submitTimeout = [int]$cfg.submit.timeoutSec }
    if ($cfg.submit.maxAttempts) { $submitMax     = [int]$cfg.submit.maxAttempts }
    if ($cfg.submit.backoffSec)  { $submitBackoff = @($cfg.submit.backoffSec | ForEach-Object { [int]$_ }) }
}

# Monitor config: after submission, poll HOBLweb until the AutoResubmit chain
# finishes (or maxHours elapses). Disable by setting monitor.enabled = false.
$monitorEnabled  = $true
$monitorInterval = 45
$monitorMaxHours = 8
if ($cfg.monitor) {
    if ($null -ne $cfg.monitor.enabled)     { $monitorEnabled  = [bool]$cfg.monitor.enabled }
    if ($cfg.monitor.intervalSec)           { $monitorInterval = [int]$cfg.monitor.intervalSec }
    if ($cfg.monitor.maxHours)              { $monitorMaxHours = [int]$cfg.monitor.maxHours }
}

# Report config: a weekly HTML report (scenario pass/fail/terminated) is built
# from a per-week ledger the monitor appends to. Disable with report.enabled =
# false. report.dir defaults to logDir so it sits next to the daily logs.
$reportEnabled = $true
$reportDir     = $logDir
if ($cfg.report) {
    if ($null -ne $cfg.report.enabled) { $reportEnabled = [bool]$cfg.report.enabled }
    if ($cfg.report.dir)               { $reportDir     = [string]$cfg.report.dir }
}

if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

# Per-day log file (append). Same file across runs same day so a 3x/day schedule
# produces ONE log for that calendar day, easy to grep.
if (-not $logFile) {
    $logFile = Join-Path $logDir ("{0}_daily.log" -f (Get-Date).ToString("yyyyMMdd"))
}

# --- log() ----- emit to host + per-day log; mirrors HOBL's " ERROR - " convention.
function log {
    [CmdletBinding()] Param([Parameter(ValueFromPipeline)] $msg)
    process {
        $line = "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) $msg"
        if ("$msg" -match " ERROR - ") {
            Write-Host $line -ForegroundColor Red
        } elseif ("$msg" -match " WARN - ") {
            Write-Host $line -ForegroundColor Yellow
        } else {
            Write-Host $line
        }
        try { Add-Content -Path $logFile -Encoding utf8 -Value $line } catch { }
    }
}

# --- Single-instance lock ---------------------------------------------------
# Prevents two scheduler invocations stomping on each other if Windows fires
# the task twice (catch-up after sleep + the regular trigger). Lock file holds
# "PID|StartUTC"; if the recorded PID is dead we reclaim it.
$lockPath = Join-Path $logDir "daily_run.lock"
function Lock-DailyRun {
    if (Test-Path $lockPath) {
        $raw = (Get-Content -Path $lockPath -Raw -ErrorAction SilentlyContinue).Trim()
        $oldPid = ($raw -split '\|')[0]
        $alive = $false
        if ($oldPid -match '^\d+$') {
            try { Get-Process -Id ([int]$oldPid) -ErrorAction Stop | Out-Null; $alive = $true } catch { $alive = $false }
        }
        if ($alive) {
            " ERROR - Another daily_run is already running (PID $oldPid). Lock: $lockPath" | log
            return $false
        }
        " WARN - Stale lock from PID $oldPid; reclaiming." | log
        Remove-Item -Path $lockPath -Force -ErrorAction SilentlyContinue
    }
    "$PID|$((Get-Date).ToUniversalTime().ToString('o'))" | Set-Content -Path $lockPath -Encoding utf8
    return $true
}
function Unlock-DailyRun { Remove-Item -Path $lockPath -Force -ErrorAction SilentlyContinue }

# --- Pre-flight -------------------------------------------------------------
function Test-HoblWebUp {
    try {
        $r = Invoke-WebRequest -Uri "$($baseUrl.TrimEnd('/'))/plan/Plans" -UseBasicParsing -TimeoutSec 10
        return ($r.StatusCode -ge 200 -and $r.StatusCode -lt 500)
    } catch { return $false }
}
function Test-PokeTask {
    # The Poke task is registered as SYSTEM with a tight ACL; non-elevated
    # callers can't *read* it but schtasks reports the existence/missing
    # distinction via stderr text. We parse that:
    #   "Access is denied"     -> task exists, ACL-hidden       -> return $true
    #   "cannot find" / "not"  -> task is genuinely missing     -> return $false
    # When run by Task Scheduler as SYSTEM (the production path) Get-ScheduledTask
    # returns the object cleanly, so we try that first.
    try {
        $t = Get-ScheduledTask -TaskName "HOBLweb Poke" -ErrorAction Stop
        return ($null -ne $t)
    } catch { }

    $err = & cmd /c 'schtasks /query /tn "HOBLweb Poke" 2>&1'
    $code = $LASTEXITCODE
    if ($code -eq 0) { return $true }

    $errText = "$err"
    if ($errText -match 'Access is denied') {
        " WARN - Poke task ACL-hidden from this user; assuming present. Run elevated to verify." | log
        return $true
    }
    if ($errText -match 'cannot find|does not exist|不存在|找不到') { return $false }

    " WARN - schtasks query unclear (exit=$code, msg=$errText); assuming present." | log
    return $true
}

# --- Helper libs -------------------------------------------------------------
. (Join-Path $PSScriptRoot "lib\submit.ps1")
. (Join-Path $PSScriptRoot "lib\monitor.ps1")
. (Join-Path $PSScriptRoot "lib\testplan.ps1")
. (Join-Path $PSScriptRoot "lib\report.ps1")

# --- Log retention -----------------------------------------------------------
function Invoke-LogRetention {
    if ($retainDays -le 0) { return }
    $cutoff = (Get-Date).AddDays(-1 * $retainDays)
    Get-ChildItem -Path $logDir -Filter "*_daily.log" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        ForEach-Object {
            "Retention: removing $($_.Name)" | log
            Remove-Item -Path $_.FullName -Force -ErrorAction SilentlyContinue
        }
}

# ============================================================================
# Main
# ============================================================================
# Run ID disambiguates multiple invocations sharing the same daily log file
# (e.g. an N-per-day schedule, or a manual run on top of the scheduled one).
$runId    = (Get-Date).ToString('yyyyMMdd-HHmmss')
$runStart = Get-Date
"=== run start id=$runId; config=$configPath; log=$logFile ===" | log
"hoblwebBaseUrl=$baseUrl; overlap=$overlap; logRetentionDays=$retainDays" | log

if (-not (Lock-DailyRun)) { Exit 3 }
try {
    # ---- Pre-flight ----
    if (-not (Test-HoblWebUp)) {
        " ERROR - Pre-flight: HOBLweb not reachable at $baseUrl" | log
        Exit 3
    }
    "Pre-flight: HOBLweb reachable." | log

    if (-not (Test-PokeTask)) {
        " ERROR - Pre-flight: 'HOBLweb Poke' scheduled task not found. Queue will not advance." | log
        " ERROR -   Install: schtasks /create /ru system /sc minute /mo 1 /tn ""HOBLweb Poke"" /tr ""cmd.exe /C curl http://%COMPUTERNAME%/plan/Poke"" /f" | log
        Exit 3
    }
    "Pre-flight: HOBLweb Poke task present." | log

    try {
        $writeProbe = Join-Path $logDir "_writetest.tmp"
        "test" | Out-File -FilePath $writeProbe -Encoding utf8 -Force
        Remove-Item $writeProbe -Force
    } catch {
        " ERROR - Pre-flight: logDir not writable: $logDir" | log
        Exit 3
    }

    # ---- Validate config ----
    $jobs = @($cfg.jobs)
    if ($jobs.Count -eq 0) {
        " ERROR - Config has zero jobs." | log
        Exit 3
    }
    foreach ($j in $jobs) {
        if (-not $j.name)       { " ERROR - A job is missing 'name'."                     | log; Exit 3 }
        if (-not $j.profile)    { " ERROR - Job '$($j.name)' missing 'profile'."          | log; Exit 3 }
        if (-not $j.testplan)   { " ERROR - Job '$($j.name)' missing 'testplan' path."    | log; Exit 3 }
        if (-not $j.runsPerDay) { " ERROR - Job '$($j.name)' missing 'runsPerDay'."       | log; Exit 3 }
        if ([int]$j.runsPerDay -lt 1) { " ERROR - Job '$($j.name)' runsPerDay must be >= 1." | log; Exit 3 }
    }
    # Duplicate detection by (profile, testplan): two jobs targeting the same
    # combination would race on HOBLweb's queue.
    $dupes = $jobs | Group-Object { "$($_.profile)|$($_.testplan)" } | Where-Object Count -gt 1
    if ($dupes) {
        " ERROR - Duplicate (profile, testplan) in config: $($dupes.Name -join '; ')" | log
        Exit 3
    }

    $enabledJobs = @($jobs | Where-Object { $_.enabled })
    if ($enabledJobs.Count -eq 0) {
        " WARN - No enabled jobs. Nothing to submit." | log
        Invoke-LogRetention
        Exit 0
    }
    "Enabled jobs ($($enabledJobs.Count)): $($enabledJobs.name -join ', ')" | log
    if ($DryRun) { " WARN - DryRun mode: testplans will be parsed and rows logged, but NOT submitted." | log }

    # ---- Snapshot all plans once (used by overlap check + post-submit verify) ----
    # In DryRun we don't need this, but fetching is cheap and exercises the
    # HOBLweb connection, so we do it unconditionally.
    $allPlans = $null
    try {
        $allPlans = Get-HoblPlans -BaseUrl $baseUrl -TimeoutSec $submitTimeout
    } catch {
        " ERROR - Pre-flight: /plan/PlanData failed: $($_.Exception.Message)" | log
        Exit 3
    }
    "Snapshot: $(@($allPlans).Count) plans known to HOBLweb." | log

    # ---- Per-job loop ----
    $ok = 0; $skip = 0; $fail = 0
    $monitorJobs = @()   # populated on successful submit; consumed by the monitor loop below
    foreach ($job in $enabledJobs) {
        ">>> Job '$($job.name)' profile=$($job.profile) testplan=$($job.testplan) runsPerDay=$($job.runsPerDay)" | log

        # Resolve testplan path: relative paths are taken relative to the repo
        # root (the parent of automation_v2\), so a job can write
        # "testplans/intern_teams2.ps1" and we find it.
        $testplanPath = $job.testplan
        if (-not [System.IO.Path]::IsPathRooted($testplanPath)) {
            $repoRoot = Split-Path -Parent $PSScriptRoot
            $testplanPath = Join-Path $repoRoot $testplanPath
        }
        if (-not (Test-Path $testplanPath)) {
            " ERROR - Testplan not found: $testplanPath. Skipping job." | log
            $fail++; continue
        }
        "    testplan: $testplanPath" | log

        # Parse testplan -> rows.
        try {
            $parsed = ConvertFrom-HoblTestplan -Path $testplanPath
        } catch {
            " ERROR - Failed to parse testplan: $($_.Exception.Message)" | log
            $fail++; continue
        }
        $rowsArr   = @($parsed.Rows)
        $planName  = if ($job.planName)  { [string]$job.planName }  else { $parsed.PlanName }
        $studyType = if ($job.studyType) { [string]$job.studyType } else { $parsed.StudyType }

        # Overlap check: if any plan with same profile is still Active, skip.
        # We consult the snapshot we already took, same as v1.
        if ($overlap -eq 'skip') {
            $busy = @($allPlans | Where-Object { $_.Profile -eq $job.profile -and $_.State -eq 'Active' })
            if ($busy.Count -gt 0) {
                $busyIds = ($busy | ForEach-Object { $_.PlanID }) -join ','
                " WARN - Profile $($job.profile) has $($busy.Count) active plan(s) [$busyIds]. overlap=skip -> skipping." | log
                $skip++; continue
            }
        }

        # Apply AutoResubmit on the first row (HOBLweb's UI does the same).
        $resubmits = [int]$job.runsPerDay - 1
        Set-HoblAutoResubmit -PlanRows $rowsArr -Resubmits $resubmits
        "    parsed: planName=$planName studyType=$studyType rows=$($rowsArr.Count); set Seq[0].Meta.AutoResubmit=$resubmits" | log
        "    scenarios: $(($rowsArr | ForEach-Object { $_.Scenario }) -join ', ')" | log

        if ($DryRun) {
            $bodyPreview = @{ profile = $job.profile; planName = $planName; studyType = $studyType; planRows = $rowsArr } |
                ConvertTo-Json -Depth 12
            "    [DryRun] would POST /plan/Create with body:" | log
            foreach ($bl in ($bodyPreview -split "`n")) { "      $bl" | log }
            $ok++
            "<<< Job '$($job.name)' built (DryRun)." | log
            continue
        }

        $submitStart = Get-Date
        try {
            $resp = Invoke-WithRetry -MaxAttempts $submitMax -BackoffSec $submitBackoff -LogLine { param($s) $s | log } -Action {
                Submit-HoblPlan -BaseUrl    $baseUrl `
                                -Profile    $job.profile `
                                -PlanName   $planName `
                                -PlanRows   $rowsArr `
                                -StudyType  $studyType `
                                -TimeoutSec $submitTimeout
            }
        } catch {
            " ERROR - Submit failed for job '$($job.name)': $($_.Exception.Message)" | log
            $fail++; continue
        }
        $submitElapsed = [math]::Round(((Get-Date) - $submitStart).TotalSeconds, 2)
        "    submit OK; elapsed=${submitElapsed}s; redirect=$($resp.redirectToUrl)" | log

        # Verify: re-list and find the NEW plan with same profile/name and a
        # PlanID greater than every plan we knew about pre-submit.
        Start-Sleep -Seconds 1
        try {
            $maxKnownId = 0
            foreach ($p in $allPlans) {
                if ([int]$p.PlanID -gt $maxKnownId) { $maxKnownId = [int]$p.PlanID }
            }
            $afterPlans = Get-HoblPlans -BaseUrl $baseUrl -TimeoutSec $submitTimeout
            $newPlan = $afterPlans |
                Where-Object { $_.Profile -eq $job.profile -and $_.PlanName -eq $planName -and [int]$_.PlanID -gt $maxKnownId } |
                Sort-Object { [int]$_.PlanID } -Descending |
                Select-Object -First 1
            if ($newPlan) {
                # PlanData's AutoResubmit field is a boolean flag (does this plan auto-resubmit?),
                # not the remaining count. The remaining count lives in PlanContent's Meta.
                "    verified: new PlanID=$($newPlan.PlanID) state=$($newPlan.State) AutoResubmit=$($newPlan.AutoResubmit)" | log
                if ($resubmits -gt 0 -and -not $newPlan.AutoResubmit) {
                    " WARN - New plan's AutoResubmit flag is false but we requested $resubmits resubmit(s)." | log
                }
                # Record a report ledger marker so the weekly report (and any
                # later -Backfill) knows this PlanID is one the automation owns.
                if ($reportEnabled) {
                    try {
                        Add-HoblReportEntry -ReportDir $reportDir -Entry @{
                            type       = 'plan'
                            recordedAt = (Get-Date).ToString('o')
                            profile    = $job.profile
                            job        = $job.name
                            planId     = [int]$newPlan.PlanID
                            planName   = $planName
                            studyType  = $studyType
                            runsPerDay = [int]$job.runsPerDay
                        } | Out-Null
                    } catch {
                        " WARN - report: could not record plan marker: $($_.Exception.Message)" | log
                    }
                }
                $monitorJobs += [pscustomobject]@{
                    Name        = $job.name
                    Profile     = $job.profile
                    PlanName    = $planName
                    HeadPlanID  = [int]$newPlan.PlanID
                    RunsPerDay  = [int]$job.runsPerDay
                    LastPlanID  = 0
                    LastState   = ''
                    LastRow     = ''
                    Done        = $false
                }
            } else {
                " WARN - Could not locate the freshly-submitted plan in HOBLweb's plan list." | log
            }
        } catch {
            " WARN - Post-submit verification call failed: $($_.Exception.Message)" | log
        }

        $ok++
        "<<< Job '$($job.name)' submitted." | log
    }

    # ---- Monitor loop ----
    # After submission, hand the trackers to lib\monitor.ps1, which polls
    # HOBLweb until every chain finishes (or maxHours elapses). Skipped on
    # DryRun (nothing was actually submitted).
    if ($monitorEnabled -and -not $DryRun -and $monitorJobs.Count -gt 0) {
        # OnResult: append each finished scenario to the weekly report ledger
        # and re-render the HTML. Rendering is cheap (reads a small jsonl) so we
        # do it per result to keep the report live.
        $onResult = $null
        if ($reportEnabled) {
            $onResult = {
                param($entry)
                try {
                    Add-HoblReportEntry -ReportDir $reportDir -Entry $entry | Out-Null
                    Write-HoblReportHtml -ReportDir $reportDir | Out-Null
                } catch {
                    " WARN - report: $($_.Exception.Message)" | log
                }
            }.GetNewClosure()
        }
        Invoke-HoblMonitor -Jobs        $monitorJobs `
                           -BaseUrl     $baseUrl `
                           -IntervalSec $monitorInterval `
                           -MaxHours    $monitorMaxHours `
                           -TimeoutSec  $submitTimeout `
                           -Log         { param($s) $s | log } `
                           -OnResult    $onResult
    }

    # ---- Final report render ----
    # Ensure the week's HTML reflects the latest ledger even if the monitor was
    # disabled or detached early. Safe no-op when reporting is off / DryRun.
    if ($reportEnabled -and -not $DryRun) {
        try {
            $htmlPath = Write-HoblReportHtml -ReportDir $reportDir
            if ($htmlPath) { "Report updated: $htmlPath" | log }
        } catch {
            " WARN - report: final render failed: $($_.Exception.Message)" | log
        }
    }

    Invoke-LogRetention

    $totalElapsed = [math]::Round(((Get-Date) - $runStart).TotalSeconds, 2)
    "=== run end id=$runId; ok=$ok skip=$skip fail=$fail; elapsed=${totalElapsed}s ===" | log

    if     ($fail -eq 0)                   { Exit 0 }
    elseif ($ok -gt 0 -or $skip -gt 0)     { Exit 1 }
    else                                   { Exit 2 }
}
finally {
    Unlock-DailyRun
}
