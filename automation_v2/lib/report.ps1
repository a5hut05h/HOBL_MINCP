# HOBL automation v2 — per-run HTML report (scenario pass/fail/terminated).
#
# Dot-sourced by daily_run.ps1 (live updates) and generate_report.ps1
# (on-demand rebuild / backfill). The report PERIOD follows the automation's
# schedule frequency (schedule.frequency in schedule.config.json), and each
# period's files live in a frequency subfolder under <reportDir>:
#
#   Daily    <reportDir>\daily\daily_report_<YYYY-MM-DD>.jsonl / .html
#   Weekly   <reportDir>\weekly\weekly_report_<YYYY>-W<WW>.jsonl / .html
#   Monthly  <reportDir>\monthly\monthly_report_<YYYY-MM>.jsonl / .html
#
# Because the schedule fires exactly once per period (one run per day / week /
# month), a period's ledger maps 1:1 to the run that produced it — so the
# report the run emails at the end contains only that run's scenarios.
#
# Design:
#   - The ledger is the source of truth. Each finished scenario the monitor
#     observes is appended as ONE json line (Add-HoblReportEntry). The HTML is
#     always RE-RENDERED from the ledger (Write-HoblReportHtml) — never edited
#     in place — so a crash mid-write can't corrupt the report.
#   - Scope is "plans the automation submitted": daily_run also writes a
#     type=plan marker per submitted PlanID, so a later -Backfill knows which
#     plans are ours without scraping unrelated manual submissions.
#   - Entries are binned into the period the RUN belongs to. daily_run passes
#     the run's start (-Date) so all cycles of an AutoResubmit chain land in one
#     file even when the chain crosses a day/week/month boundary; backfill and
#     log-import bin by the scenario's own StartTime when no -Date is forced.
#
# Status buckets (prep rows are EXCLUDED from the headline counts):
#   Passed     = PASS / PASSED
#   Failed     = FAIL / FAILED / ERROR / ERRORED
#   Terminated = TERMINATED / CANCELLED / ABORTED / STOPPED
#   Other      = anything else still terminal (e.g. SKIPPED)

# ---------------------------------------------------------------------------
# Date helpers (ISO week, parsing) — implemented by hand so this works under
# Windows PowerShell 5.1 too (System.Globalization.ISOWeek is .NET Core only,
# and the scheduled task runs powershell.exe = 5.1).
# ---------------------------------------------------------------------------
function ConvertTo-HoblDate {
    param([string]$Value)
    if (-not $Value) { return $null }
    $dt = [datetime]::MinValue
    $ok = [datetime]::TryParse(
        $Value,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::RoundtripKind,
        [ref]$dt)
    if ($ok) { return $dt }
    return $null
}

function Get-HoblIsoWeek {
    param([datetime]$Date = (Get-Date))
    $d = $Date.Date
    $isoDow = [int]$d.DayOfWeek          # Sunday=0..Saturday=6
    if ($isoDow -eq 0) { $isoDow = 7 }   # ISO: Monday=1..Sunday=7
    $thursday = $d.AddDays(4 - $isoDow)  # the Thursday decides the ISO year
    $isoYear  = $thursday.Year
    $jan1     = [datetime]::new($isoYear, 1, 1)
    $week     = [int]([math]::Floor((($thursday - $jan1).Days) / 7) + 1)
    $monday   = $d.AddDays(1 - $isoDow)
    $sunday   = $monday.AddDays(6)
    [pscustomobject]@{
        Year   = $isoYear
        Week   = $week
        Key    = ('{0:0000}-W{1:00}' -f $isoYear, $week)
        Monday = $monday
        Sunday = $sunday
    }
}

# Normalise a caller-supplied frequency to one of Daily/Weekly/Monthly.
# Anything unrecognised (or empty) falls back to Weekly so a mis-typed config
# still produces a report rather than throwing mid-run.
function Get-HoblReportFrequency {
    param([string]$Frequency)
    switch (("$Frequency").Trim().ToLower()) {
        'daily'   { return 'Daily' }
        'weekly'  { return 'Weekly' }
        'monthly' { return 'Monthly' }
        default   { return 'Weekly' }
    }
}

# Resolve the reporting PERIOD that a given date falls into for a frequency.
# Returns everything the rest of the module needs to name, bin, and title a
# report: the period Key, its inclusive Start/End dates, the frequency
# subfolder, the file stem, and pre-formatted Range/Title strings.
function Get-HoblReportPeriod {
    param(
        [datetime] $Date = (Get-Date),
        [string]   $Frequency = 'Weekly'
    )
    $freq = Get-HoblReportFrequency $Frequency
    switch ($freq) {
        'Daily' {
            $start = $Date.Date
            $end   = $start
            $key   = $start.ToString('yyyy-MM-dd')
            $sub   = 'daily'
            $stem  = "daily_report_$key"
            $range = '{0:ddd dd MMM yyyy}' -f $start
        }
        'Monthly' {
            $start = [datetime]::new($Date.Year, $Date.Month, 1)
            $end   = $start.AddMonths(1).AddDays(-1)
            $key   = $start.ToString('yyyy-MM')
            $sub   = 'monthly'
            $stem  = "monthly_report_$key"
            $range = '{0:dd MMM} - {1:dd MMM yyyy}' -f $start, $end
        }
        default {   # Weekly
            $iso   = Get-HoblIsoWeek -Date $Date
            $start = $iso.Monday
            $end   = $iso.Sunday
            $key   = $iso.Key
            $sub   = 'weekly'
            $stem  = "weekly_report_$key"
            $range = '{0:ddd dd MMM} - {1:ddd dd MMM yyyy}' -f $start, $end
        }
    }
    [pscustomobject]@{
        Frequency = $freq
        Key       = $key
        Start     = $start
        End       = $end
        SubFolder = $sub
        Stem      = $stem
        Range     = $range
        Title     = $freq
    }
}

# Resolve the ledger + HTML paths (and their containing frequency subfolder)
# for the period a date belongs to. The subfolder keeps daily/weekly/monthly
# reports from colliding and makes the layout self-describing on disk.
function Get-HoblReportPaths {
    param(
        [Parameter(Mandatory)] [string] $ReportDir,
        [datetime] $Date = (Get-Date),
        [string]   $Frequency = 'Weekly'
    )
    $period = Get-HoblReportPeriod -Date $Date -Frequency $Frequency
    $dir    = Join-Path $ReportDir $period.SubFolder
    [pscustomobject]@{
        Period = $period
        Dir    = $dir
        Ledger = Join-Path $dir "$($period.Stem).jsonl"
        Html   = Join-Path $dir "$($period.Stem).html"
    }
}

# ---------------------------------------------------------------------------
# Ledger I/O
# ---------------------------------------------------------------------------

# Append one entry (a hashtable or object) to the appropriate period ledger.
# Pass -Date to force the target period (used by daily_run so every scenario of
# a run bins to the run's period, and by backfill); otherwise the period is
# derived from the entry's startTime, then recordedAt, then now. -Frequency
# selects daily/weekly/monthly binning (default weekly).
function Add-HoblReportEntry {
    param(
        [Parameter(Mandatory)] [string] $ReportDir,
        [Parameter(Mandatory)] $Entry,
        [datetime] $Date,
        [string]   $Frequency = 'Weekly'
    )
    # Normalise to a hashtable so we can guarantee recordedAt.
    if ($Entry -is [hashtable]) {
        $h = @{}; foreach ($k in $Entry.Keys) { $h[$k] = $Entry[$k] }
    } else {
        $h = @{}; foreach ($p in $Entry.PSObject.Properties) { $h[$p.Name] = $p.Value }
    }
    if (-not $h.ContainsKey('recordedAt') -or -not $h['recordedAt']) {
        $h['recordedAt'] = (Get-Date).ToString('o')
    }

    if ($PSBoundParameters.ContainsKey('Date')) {
        $bin = $Date
    } else {
        $eff = $null
        if ($h['startTime'])  { $eff = ConvertTo-HoblDate ([string]$h['startTime']) }
        if (-not $eff)        { $eff = ConvertTo-HoblDate ([string]$h['recordedAt']) }
        if (-not $eff)        { $eff = Get-Date }
        $bin = $eff
    }

    if (-not (Test-Path $ReportDir)) {
        New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null
    }
    $paths = Get-HoblReportPaths -ReportDir $ReportDir -Date $bin -Frequency $Frequency
    if (-not (Test-Path $paths.Dir)) {
        New-Item -ItemType Directory -Path $paths.Dir -Force | Out-Null
    }
    ($h | ConvertTo-Json -Depth 6 -Compress) | Add-Content -Path $paths.Ledger -Encoding utf8
    return $paths.Ledger
}

function Read-HoblReportLedger {
    param([Parameter(Mandatory)] [string] $Path)
    $out = @()
    if (-not (Test-Path $Path)) { return ,$out }
    foreach ($line in (Get-Content -Path $Path -Encoding utf8)) {
        $t = $line.Trim()
        if (-not $t) { continue }
        try { $out += ($t | ConvertFrom-Json) } catch { }
    }
    return ,$out
}

# ---------------------------------------------------------------------------
# Status classification
# ---------------------------------------------------------------------------
function Get-HoblStatusBucket {
    param([string]$Status)
    switch -regex (("$Status").ToUpper()) {
        '^(PASS|PASSED)$'                      { return 'Passed' }
        '^(FAIL|FAILED|ERROR|ERRORED)$'        { return 'Failed' }
        '^(TERMINATED|CANCELLED|CANCELED|ABORTED|STOPPED)$' { return 'Terminated' }
        default                                { return 'Other' }
    }
}

$script:HoblRowTerminal = @(
    'PASS','PASSED','FAIL','FAILED','ERROR','ERRORED',
    'TERMINATED','CANCELLED','CANCELED','ABORTED','STOPPED','SKIPPED'
)

# ---------------------------------------------------------------------------
# Backfill from HOBLweb (optional) — fills scenario rows the live monitor
# missed (e.g. it was disabled, or detached after maxHours). Scoped to plans
# the automation owns: PlanIDs already in the ledger, plus the AutoResubmit
# chain successors of each type=plan marker. Requires lib\submit.ps1 to be
# dot-sourced (Get-HoblPlans / Get-HoblScenariosData).
# ---------------------------------------------------------------------------
function Invoke-HoblReportBackfill {
    param(
        [Parameter(Mandatory)] [string]   $ReportDir,
        [Parameter(Mandatory)] [string]   $BaseUrl,
        [datetime] $Date = (Get-Date),
        [string]   $Frequency = 'Weekly',
        [int] $TimeoutSec = 30,
        [scriptblock] $Log
    )
    if (-not (Get-Command Get-HoblScenariosData -ErrorAction SilentlyContinue)) {
        if ($Log) { & $Log " WARN - report backfill: submit.ps1 not loaded; skipping." }
        return
    }
    $paths  = Get-HoblReportPaths -ReportDir $ReportDir -Date $Date -Frequency $Frequency
    $period = $paths.Period
    $weekStart = $period.Start
    $weekEnd   = $period.End.AddDays(1)   # exclusive

    $existing = Read-HoblReportLedger -Path $paths.Ledger
    $recorded = @{}                       # "<planId>|<scenarioId>" already in ledger
    $planMarkers = @()
    $planIds = @{}
    foreach ($e in $existing) {
        if ("$($e.type)" -eq 'plan') {
            $planMarkers += $e
            if ($e.planId) { $planIds["$([int]$e.planId)"] = $true }
        } else {
            if ($null -ne $e.planId -and $null -ne $e.scenarioId) {
                $recorded["$([int]$e.planId)|$([int]$e.scenarioId)"] = $true
            }
            if ($e.planId) { $planIds["$([int]$e.planId)"] = $true }
        }
    }

    # Expand AutoResubmit chains from plan markers so cycle 2..N PlanIDs are
    # covered even if the monitor never saw them.
    try {
        $allPlans = Get-HoblPlans -BaseUrl $BaseUrl -TimeoutSec $TimeoutSec
        foreach ($m in $planMarkers) {
            $head = [int]$m.planId
            foreach ($p in $allPlans) {
                if ("$($p.Profile)" -ne "$($m.profile)")   { continue }
                if ("$($p.PlanName)" -ne "$($m.planName)")  { continue }
                if ([int]$p.PlanID -lt $head)               { continue }
                $st = ConvertTo-HoblDate ([string]$p.StartTime)
                if ($st -and ($st -lt $weekStart -or $st -ge $weekEnd)) { continue }
                $planIds["$([int]$p.PlanID)"] = $true
            }
        }
    } catch {
        if ($Log) { & $Log " WARN - report backfill: /plan/PlanData failed: $($_.Exception.Message)" }
    }

    $added = 0
    foreach ($pidKey in @($planIds.Keys)) {
        $planId = [int]$pidKey
        try {
            $rows = @(Get-HoblScenariosData -BaseUrl $BaseUrl -PlanID $planId -TimeoutSec $TimeoutSec)
        } catch {
            if ($Log) { & $Log " WARN - report backfill: ScenariosData PlanID=$planId failed: $($_.Exception.Message)" }
            continue
        }
        foreach ($r in $rows) {
            $stat = "$($r.Status)".ToUpper()
            if ($script:HoblRowTerminal -notcontains $stat) { continue }
            $key = "$planId|$([int]$r.ScenarioID)"
            if ($recorded.ContainsKey($key)) { continue }
            $name = "$($r.Scenario)"
            $entry = @{
                type       = 'scenario'
                recordedAt = (Get-Date).ToString('o')
                profile    = "$($r.Profile)"
                job        = ''
                planId     = $planId
                scenarioId = [int]$r.ScenarioID
                cycle      = 0
                cycleTotal = 0
                scenario   = $name
                status     = $stat
                startTime  = if ($r.StartTime) { "$($r.StartTime)" } else { $null }
                isPrep     = ($name -eq 'prep')
                source     = 'backfill'
            }
            Add-HoblReportEntry -ReportDir $ReportDir -Entry $entry -Date $Date -Frequency $Frequency | Out-Null
            $recorded[$key] = $true
            $added++
        }
    }
    if ($Log -and $added -gt 0) { & $Log "    report backfill: added $added scenario row(s) from HOBLweb." }
    return $added
}

# ---------------------------------------------------------------------------
# Import from daily logs (offline backfill)
# ---------------------------------------------------------------------------
# Reconstruct scenario results from daily_run.ps1's per-day log files
# (<logDir>\YYYYMMDD_daily.log) and append them to the matching weekly ledger.
# Useful for seeding the report from runs that pre-date the report feature, or
# for aggregating logs copied from OTHER hosts (where the PlanIDs are not in the
# local HOBLweb DB, so HOBLweb backfill can't help).
#
# It parses three line shapes the monitor already emits:
#   ">>> Job 'X' profile=Y testplan=Z runsPerDay=N"           -> job -> profile
#   "[X] PlanID=N cycle=C/T ..."                               -> PlanID -> cycle
#   "[X] PlanID=N row=R started"                               -> scenario start time
#   "[X] PlanID=N row=R <PREV> -> <STATUS>"  (terminal status) -> one result row
#
# Each result is binned into its ISO week by the scenario's start time (or the
# transition time when it never started). Idempotent: a synthetic, deterministic
# scenarioId derived from "PlanID|scenario" lets re-imports skip rows already in
# the ledger. Synthetic IDs are negative so they never collide with real
# HOBLweb scenarioIds.
function Get-HoblSyntheticScenarioId {
    param([Parameter(Mandatory)] [string] $Text)
    # FNV-1a over the string, kept in 32-bit range with modulo (NOT -band: the
    # literal 0xFFFFFFFF is -1 under Windows PowerShell 5.1 but 4294967295 under
    # PS 7, so -band masking silently differs by host — modulo is identical on
    # both). Mapped to a negative int so it never collides with real HOBLweb
    # scenarioIds.
    $hash = [long]2166136261
    $mod  = [long]4294967296          # 2^32
    foreach ($ch in $Text.ToCharArray()) {
        $hash = $hash -bxor [long][int][char]$ch
        $hash = ($hash * 16777619) % $mod
    }
    return (-1 * [int]($hash % 2000000000))
}

function Import-HoblReportFromLogs {
    param(
        [Parameter(Mandatory)] [string] $ReportDir,
        [string] $LogDir = $ReportDir,
        [string] $Frequency = 'Weekly',
        [scriptblock] $Log
    )
    $logFiles = @(Get-ChildItem -Path $LogDir -Filter '*_daily.log' -File -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($logFiles.Count -eq 0) {
        if ($Log) { & $Log " WARN - report import: no *_daily.log files found in $LogDir" }
        return [pscustomobject]@{ Added = 0; Weeks = @() }
    }

    $rowTerminal = 'PASS|PASSED|FAIL|FAILED|ERROR|ERRORED|TERMINATED|CANCELLED|CANCELED|ABORTED|STOPPED|SKIPPED'

    # ---- Pass 1: build lookup maps across every log ----
    $jobProfile = @{}        # jobName        -> profile
    $planCycle  = @{}        # planId(string) -> @{ cycle; total }
    $scenStart  = @{}        # "planId|row"   -> 'yyyy-MM-dd HH:mm:ss'
    foreach ($lf in $logFiles) {
        foreach ($line in (Get-Content -Path $lf.FullName -Encoding utf8)) {
            if ($line -match ">>> Job '([^']+)' profile=(\S+) testplan=(\S+) runsPerDay=(\d+)") {
                $jobProfile[$Matches[1]] = $Matches[2]
                continue
            }
            if ($line -match '\[([^\]]+)\] PlanID=(\d+) cycle=(\d+)/(\d+)') {
                $planCycle[$Matches[2]] = @{ cycle = [int]$Matches[3]; total = [int]$Matches[4] }
                continue
            }
            if ($line -match '\[([^\]]+)\] PlanID=(\d+) row=(\S+) started') {
                $scenStart["$($Matches[2])|$($Matches[3])"] = ($line.Substring(0, 19))
                continue
            }
        }
    }

    # ---- Pass 2: emit a scenario entry per terminal transition ----
    # Idempotency / cross-source de-dup is keyed by "planId|scenario-name"
    # (lowercased), NOT by scenarioId. A scenario name is unique within a plan,
    # so this lets a log-imported row be skipped when the SAME scenario is
    # already in the ledger from the live monitor (real scenarioId) or a prior
    # import (synthetic scenarioId). Without this, importing logs for a week the
    # monitor already covered would double-count every row.
    $seenByWeek = @{}
    function Get-PeriodSeen {
        param($PeriodKey, $LedgerPath)
        if (-not $seenByWeek.ContainsKey($PeriodKey)) {
            $set = @{}
            foreach ($e in (Read-HoblReportLedger -Path $LedgerPath)) {
                if ("$($e.type)" -eq 'plan') { continue }
                if ($null -ne $e.planId -and $e.scenario) {
                    $set["$([int]$e.planId)|$("$($e.scenario)".ToLower())"] = $true
                }
            }
            $seenByWeek[$PeriodKey] = $set
        }
        return $seenByWeek[$PeriodKey]
    }

    $added        = 0
    $weeksTouched = @{}
    foreach ($lf in $logFiles) {
        foreach ($line in (Get-Content -Path $lf.FullName -Encoding utf8)) {
            if ($line -notmatch "^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}).*\[([^\]]+)\] PlanID=(\d+) row=(\S+) (RUNNING|PENDING) -> ($rowTerminal)\b") {
                continue
            }
            $tsStr   = $Matches[1]
            $jobName = $Matches[2]
            $planId  = [int]$Matches[3]
            $row     = $Matches[4]
            $status  = $Matches[6].ToUpper()

            $startStr = $null
            if ($scenStart.ContainsKey("$planId|$row")) { $startStr = $scenStart["$planId|$row"] }
            $effStr = if ($startStr) { $startStr } else { $tsStr }
            try {
                $eff = [datetime]::ParseExact($effStr, 'yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
            } catch { continue }

            $iso = Get-HoblReportPeriod -Date $eff -Frequency $Frequency
            $paths = Get-HoblReportPaths -ReportDir $ReportDir -Date $eff -Frequency $Frequency
            $seen  = Get-PeriodSeen -PeriodKey $iso.Key -LedgerPath $paths.Ledger

            $dedupKey = "$planId|$($row.ToLower())"
            if ($seen.ContainsKey($dedupKey)) { continue }   # already recorded (monitor or prior import)

            $scenarioId = Get-HoblSyntheticScenarioId -Text "$planId|$row"
            $rowProfile = if ($jobProfile.ContainsKey($jobName)) { $jobProfile[$jobName] } else { '' }
            $cyc     = if ($planCycle.ContainsKey("$planId")) { $planCycle["$planId"] } else { @{ cycle = 0; total = 0 } }
            $startIso = $null
            if ($startStr) {
                try { $startIso = ([datetime]::ParseExact($startStr, 'yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)).ToString('o') } catch { $startIso = $null }
            }

            $entry = @{
                type       = 'scenario'
                recordedAt = $eff.ToString('o')
                profile    = $rowProfile
                job        = $jobName
                planId     = $planId
                scenarioId = $scenarioId
                cycle      = [int]$cyc.cycle
                cycleTotal = [int]$cyc.total
                scenario   = $row
                status     = $status
                startTime  = $startIso
                isPrep     = ($row -eq 'prep')
                source     = 'logimport'
            }
            Add-HoblReportEntry -ReportDir $ReportDir -Entry $entry -Date $eff -Frequency $Frequency | Out-Null
            $seen[$dedupKey] = $true
            $weeksTouched[$iso.Key] = $eff
            $added++
        }
    }

    $weeks = @($weeksTouched.GetEnumerator() | ForEach-Object { [pscustomobject]@{ Key = $_.Key; Date = $_.Value } } | Sort-Object Key)
    if ($Log) { & $Log "    report import: added $added scenario row(s) from $($logFiles.Count) log file(s) across $($weeks.Count) period(s)." }
    return [pscustomobject]@{ Added = $added; Weeks = $weeks }
}

# ---------------------------------------------------------------------------
# Render
# ---------------------------------------------------------------------------
function ConvertTo-HoblHtmlText {
    param([string]$Text)
    return [System.Net.WebUtility]::HtmlEncode("$Text")
}

# Read the period's ledger, optionally backfill from HOBLweb, then (re)write the
# period HTML report. Returns the HTML path.
function Write-HoblReportHtml {
    param(
        [Parameter(Mandatory)] [string] $ReportDir,
        [datetime] $Date = (Get-Date),
        [string]   $Frequency = 'Weekly',
        [string]   $BaseUrl = '',
        [switch]   $Backfill,
        [int]      $TimeoutSec = 30,
        [scriptblock] $Log
    )
    if (-not (Test-Path $ReportDir)) {
        New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null
    }
    if ($Backfill -and $BaseUrl) {
        Invoke-HoblReportBackfill -ReportDir $ReportDir -BaseUrl $BaseUrl -Date $Date -Frequency $Frequency -TimeoutSec $TimeoutSec -Log $Log | Out-Null
    }

    $paths = Get-HoblReportPaths -ReportDir $ReportDir -Date $Date -Frequency $Frequency
    $iso   = $paths.Period
    if (-not (Test-Path $paths.Dir)) {
        New-Item -ItemType Directory -Path $paths.Dir -Force | Out-Null
    }
    $entries = Read-HoblReportLedger -Path $paths.Ledger

    # Dedup scenario rows by planId|scenarioId, keeping the latest recordedAt.
    $byKey = @{}
    foreach ($e in $entries) {
        if ("$($e.type)" -eq 'plan') { continue }
        if ($null -eq $e.planId -or $null -eq $e.scenarioId) { continue }
        $key = "$([int]$e.planId)|$([int]$e.scenarioId)"
        $prev = $byKey[$key]
        if (-not $prev) {
            $byKey[$key] = $e
        } else {
            $a = ConvertTo-HoblDate ([string]$e.recordedAt)
            $b = ConvertTo-HoblDate ([string]$prev.recordedAt)
            if ($a -and $b -and $a -ge $b) { $byKey[$key] = $e }
        }
    }
    $rows = @($byKey.Values)

    # Counts exclude prep rows.
    $counts = [ordered]@{ Passed = 0; Failed = 0; Terminated = 0; Other = 0 }
    # Per-DUT and per-scenario aggregation (also prep-excluded) for the
    # summary tables.
    $byDut  = @{}
    $byScen = @{}
    foreach ($r in $rows) {
        if ($r.isPrep) { continue }
        $bucket = Get-HoblStatusBucket -Status ([string]$r.status)
        $counts[$bucket]++

        $dut = [string]$r.profile
        if (-not $byDut.ContainsKey($dut)) { $byDut[$dut] = [ordered]@{ Passed=0; Failed=0; Terminated=0; Other=0 } }
        $byDut[$dut][$bucket]++

        $scn = [string]$r.scenario
        if (-not $byScen.ContainsKey($scn)) { $byScen[$scn] = [ordered]@{ Passed=0; Failed=0; Terminated=0; Other=0 } }
        $byScen[$scn][$bucket]++
    }
    $totalWork = $counts.Passed + $counts.Failed + $counts.Terminated + $counts.Other

    # Pass rate excludes "Other" (e.g. skipped) from the denominator — a
    # skipped row is neither a pass nor a failure, so counting it would be
    # misleading. Denominator = Passed + Failed + Terminated.
    $rateDenom    = $counts.Passed + $counts.Failed + $counts.Terminated
    $passRate     = if ($rateDenom -gt 0) { [int][math]::Round($counts.Passed / $rateDenom * 100) } else { $null }
    $passRateText = if ($null -ne $passRate) { "$passRate%" } else { '&mdash;' }
    $rateClass    = if ($null -eq $passRate) { 'na' } elseif ($passRate -ge 90) { 'good' } elseif ($passRate -ge 70) { 'warn' } else { 'bad' }

    # Sort: newest plan first, then run order within the plan.
    $sorted = $rows | Sort-Object `
        @{ Expression = { [int]$_.planId }; Descending = $true }, `
        @{ Expression = { [int]$_.scenarioId }; Descending = $false }

    # Rows needing attention: failed or terminated (prep excluded).
    $problems = @($sorted | Where-Object {
        -not $_.isPrep -and ((Get-HoblStatusBucket -Status ([string]$_.status)) -in @('Failed','Terminated'))
    })

    # Local helper: percent bar class. The bar renders pass% in green with the
    # remaining (fail/term) portion in red, so the only distinction needed is
    # whether there is data at all ('na' = no runs -> rendered as a grey track).
    $barClassOf = {
        param($rate)
        if ($null -eq $rate) { 'na' } else { 'val' }
    }

    $rangeText = $iso.Range
    $genText   = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<!DOCTYPE html>')
    [void]$sb.AppendLine('<html lang="en"><head><meta charset="utf-8">')
    [void]$sb.AppendLine('<meta name="viewport" content="width=device-width, initial-scale=1">')
    [void]$sb.AppendLine("<title>HOBL $($iso.Title) Report $($iso.Key)</title>")
    [void]$sb.AppendLine(@'
<style>
  :root { --pass:#1a7f37; --fail:#cf222e; --term:#bc4c00; --other:#57606a; --ink:#1f2328; --line:#d0d7de; --good:#1a7f37; --warn:#bc4c00; --bad:#cf222e; }
  * { box-sizing: border-box; }
  body { font-family: -apple-system, Segoe UI, Roboto, Helvetica, Arial, sans-serif; color: var(--ink); margin: 0; padding: 28px; background: #f6f8fa; }
  h1 { font-size: 22px; margin: 0 0 2px; }
  h2 { font-size: 15px; margin: 26px 0 10px; }
  .sub { color: var(--other); font-size: 13px; margin-bottom: 20px; }
  .cards { display: flex; flex-wrap: wrap; gap: 14px; margin-bottom: 8px; }
  .card { flex: 1 1 130px; background: #fff; border: 1px solid var(--line); border-radius: 10px; padding: 16px 18px; border-left-width: 6px; }
  .card .n { font-size: 30px; font-weight: 700; line-height: 1; }
  .card .l { font-size: 12px; text-transform: uppercase; letter-spacing: .04em; color: var(--other); margin-top: 6px; }
  .card.rate.good { border-left-color: var(--good); } .card.rate.good .n { color: var(--good); }
  .card.rate.warn { border-left-color: var(--warn); } .card.rate.warn .n { color: var(--warn); }
  .card.rate.bad  { border-left-color: var(--bad);  } .card.rate.bad  .n { color: var(--bad);  }
  .card.rate.na   { border-left-color: var(--other);} .card.rate.na   .n { color: var(--other);}
  .card.pass { border-left-color: var(--pass); } .card.pass .n { color: var(--pass); }
  .card.fail { border-left-color: var(--fail); } .card.fail .n { color: var(--fail); }
  .card.term { border-left-color: var(--term); } .card.term .n { color: var(--term); }
  .card.total{ border-left-color: var(--other); } .card.total .n { color: var(--ink); }
  table { width: 100%; border-collapse: collapse; background: #fff; border: 1px solid var(--line); border-radius: 10px; overflow: hidden; }
  th, td { text-align: left; padding: 9px 12px; font-size: 13px; border-bottom: 1px solid var(--line); }
  th { background: #f6f8fa; font-size: 11px; text-transform: uppercase; letter-spacing: .04em; color: var(--other); user-select: none; }
  table.sortable th { cursor: pointer; }
  table.sortable th:hover { color: var(--ink); }
  tr:last-child td { border-bottom: 0; }
  tr.prep td { color: #8c959f; font-style: italic; }
  .pill { display: inline-block; padding: 2px 9px; border-radius: 999px; font-size: 11px; font-weight: 600; }
  .pill.Passed { background: #dafbe1; color: var(--pass); }
  .pill.Failed { background: #ffebe9; color: var(--fail); }
  .pill.Terminated { background: #fff1e5; color: var(--term); }
  .pill.Other { background: #eaeef2; color: var(--other); }
  .mono { font-variant-numeric: tabular-nums; }
  .grid2 { display: grid; grid-template-columns: 1fr 1fr; gap: 18px; }
  @media (max-width: 820px) { .grid2 { grid-template-columns: 1fr; } }
  .bar { background: var(--fail); border-radius: 999px; height: 8px; width: 84px; display: inline-block; overflow: hidden; vertical-align: middle; margin-right: 8px; }
  .bar > span { display: block; height: 100%; background: var(--pass); }
  .bar.na { background: var(--other); } .bar.na > span { background: var(--other); }
  .rate-cell { white-space: nowrap; }
  .controls { display: flex; flex-wrap: wrap; gap: 10px; align-items: center; margin-bottom: 10px; }
  .controls label { font-size: 12px; color: var(--other); }
  .controls select, .controls input[type=text] { font: inherit; font-size: 13px; padding: 5px 8px; border: 1px solid var(--line); border-radius: 7px; background: #fff; }
  .controls .count { margin-left: auto; font-size: 12px; color: var(--other); }
  .ok-banner { background:#dafbe1; border:1px solid #a7e3b6; color:var(--pass); border-radius:10px; padding:12px 16px; font-size:13px; }
  .foot { color: var(--other); font-size: 12px; margin-top: 22px; }
  .empty { background:#fff; border:1px dashed var(--line); border-radius:10px; padding:40px; text-align:center; color:var(--other); }
</style>
'@)
    [void]$sb.AppendLine('</head><body>')
    [void]$sb.AppendLine("<h1>HOBL $($iso.Title) Automation Report</h1>")
    [void]$sb.AppendLine("<div class=""sub"">$($iso.Title) $($iso.Key) &nbsp;&middot;&nbsp; $rangeText &nbsp;&middot;&nbsp; generated $genText</div>")

    # Summary cards (pass rate first).
    [void]$sb.AppendLine('<div class="cards">')
    [void]$sb.AppendLine("<div class=""card rate $rateClass""><div class=""n"">$passRateText</div><div class=""l"">Pass rate</div></div>")
    [void]$sb.AppendLine("<div class=""card pass""><div class=""n"">$($counts.Passed)</div><div class=""l"">Passed</div></div>")
    [void]$sb.AppendLine("<div class=""card fail""><div class=""n"">$($counts.Failed)</div><div class=""l"">Failed</div></div>")
    [void]$sb.AppendLine("<div class=""card term""><div class=""n"">$($counts.Terminated)</div><div class=""l"">Terminated</div></div>")
    [void]$sb.AppendLine("<div class=""card total""><div class=""n"">$totalWork</div><div class=""l"">Total scenarios</div></div>")
    [void]$sb.AppendLine('</div>')

    $rateNote = "Pass rate = Passed / (Passed + Failed + Terminated)."
    if ($counts.Other -gt 0) { $rateNote += " $($counts.Other) other terminal status (e.g. skipped) shown in Total but excluded from the rate." }
    [void]$sb.AppendLine("<div class=""sub"">$rateNote</div>")

    if ($sorted.Count -eq 0) {
        [void]$sb.AppendLine('<div class="empty">No scenario results recorded for this period yet.</div>')
    } else {
        # ---- Needs attention ----
        [void]$sb.AppendLine('<h2>Needs attention</h2>')
        if ($problems.Count -eq 0) {
            [void]$sb.AppendLine('<div class="ok-banner">No failures or terminations recorded this period.</div>')
        } else {
            [void]$sb.AppendLine('<table><thead><tr>')
            foreach ($h in @('Scenario','DUT / Profile','PlanID','Cycle','Started','Status')) { [void]$sb.AppendLine("<th>$h</th>") }
            [void]$sb.AppendLine('</tr></thead><tbody>')
            foreach ($r in $problems) {
                $bucket = Get-HoblStatusBucket -Status ([string]$r.status)
                $scen   = ConvertTo-HoblHtmlText ([string]$r.scenario)
                $prof   = ConvertTo-HoblHtmlText ([string]$r.profile)
                $planId = ConvertTo-HoblHtmlText ([string]$r.planId)
                $cycle  = if ([int]$r.cycleTotal -gt 0) { "$([int]$r.cycle)/$([int]$r.cycleTotal)" } else { '' }
                $st     = ConvertTo-HoblDate ([string]$r.startTime)
                $started = if ($st) { $st.ToString('MM-dd HH:mm:ss') } else { '' }
                $statusText = ConvertTo-HoblHtmlText ([string]$r.status)
                [void]$sb.AppendLine('<tr>')
                [void]$sb.AppendLine("<td>$scen</td><td>$prof</td><td class=""mono"">$planId</td><td class=""mono"">$cycle</td><td class=""mono"">$started</td><td><span class=""pill $bucket"">$statusText</span></td>")
                [void]$sb.AppendLine('</tr>')
            }
            [void]$sb.AppendLine('</tbody></table>')
        }

        # ---- By DUT / By scenario summaries ----
        [void]$sb.AppendLine('<div class="grid2">')

        # By DUT
        [void]$sb.AppendLine('<div><h2>By DUT</h2><table><thead><tr><th>DUT / Profile</th><th>Pass</th><th>Fail</th><th>Term</th><th>Pass rate</th></tr></thead><tbody>')
        $dutSorted = $byDut.GetEnumerator() | Sort-Object @{ Expression = { $_.Value.Failed + $_.Value.Terminated }; Descending = $true }, @{ Expression = { $_.Key } }
        foreach ($d in $dutSorted) {
            $den  = $d.Value.Passed + $d.Value.Failed + $d.Value.Terminated
            $rate = if ($den -gt 0) { [int][math]::Round($d.Value.Passed / $den * 100) } else { $null }
            $rtxt = if ($null -ne $rate) { "$rate%" } else { '&mdash;' }
            $bcls = & $barClassOf $rate
            $w    = if ($null -ne $rate) { $rate } else { 0 }
            $name = ConvertTo-HoblHtmlText ([string]$d.Key)
            [void]$sb.AppendLine("<tr><td>$name</td><td class=""mono"">$($d.Value.Passed)</td><td class=""mono"">$($d.Value.Failed)</td><td class=""mono"">$($d.Value.Terminated)</td><td class=""rate-cell""><span class=""bar $bcls""><span style=""width:$w%""></span></span>$rtxt</td></tr>")
        }
        [void]$sb.AppendLine('</tbody></table></div>')

        # By scenario (prep already excluded)
        [void]$sb.AppendLine('<div><h2>By scenario</h2><table><thead><tr><th>Scenario</th><th>Pass</th><th>Fail</th><th>Term</th><th>Pass rate</th></tr></thead><tbody>')
        $scenSorted = $byScen.GetEnumerator() | Sort-Object @{ Expression = { $_.Value.Failed + $_.Value.Terminated }; Descending = $true }, @{ Expression = { $_.Key } }
        foreach ($s in $scenSorted) {
            $den  = $s.Value.Passed + $s.Value.Failed + $s.Value.Terminated
            $rate = if ($den -gt 0) { [int][math]::Round($s.Value.Passed / $den * 100) } else { $null }
            $rtxt = if ($null -ne $rate) { "$rate%" } else { '&mdash;' }
            $bcls = & $barClassOf $rate
            $w    = if ($null -ne $rate) { $rate } else { 0 }
            $name = ConvertTo-HoblHtmlText ([string]$s.Key)
            [void]$sb.AppendLine("<tr><td>$name</td><td class=""mono"">$($s.Value.Passed)</td><td class=""mono"">$($s.Value.Failed)</td><td class=""mono"">$($s.Value.Terminated)</td><td class=""rate-cell""><span class=""bar $bcls""><span style=""width:$w%""></span></span>$rtxt</td></tr>")
        }
        [void]$sb.AppendLine('</tbody></table></div>')
        [void]$sb.AppendLine('</div>')

        # ---- All scenarios (filterable + sortable) ----
        [void]$sb.AppendLine('<h2>All scenarios</h2>')

        # Distinct DUT options for the filter.
        $dutOptions = @($byDut.Keys | Sort-Object)
        [void]$sb.AppendLine('<div class="controls">')
        [void]$sb.AppendLine('<label>Status <select id="f-status"><option value="all">All</option><option value="Passed">Passed</option><option value="Failed">Failed</option><option value="Terminated">Terminated</option><option value="Other">Other</option></select></label>')
        $dutSel = New-Object System.Text.StringBuilder
        [void]$dutSel.Append('<label>DUT <select id="f-dut"><option value="all">All</option>')
        foreach ($d in $dutOptions) { $dv = ConvertTo-HoblHtmlText ([string]$d); [void]$dutSel.Append("<option value=""$dv"">$dv</option>") }
        [void]$dutSel.Append('</select></label>')
        [void]$sb.AppendLine($dutSel.ToString())
        [void]$sb.AppendLine('<label>Scenario <input type="text" id="f-scen" placeholder="filter by name"></label>')
        [void]$sb.AppendLine('<label><input type="checkbox" id="f-prep"> Hide prep</label>')
        [void]$sb.AppendLine('<span class="count" id="f-count"></span>')
        [void]$sb.AppendLine('</div>')

        [void]$sb.AppendLine('<table id="main" class="sortable"><thead><tr>')
        [void]$sb.AppendLine('<th data-type="text">Scenario</th><th data-type="text">DUT / Profile</th><th data-type="num">PlanID</th><th data-type="num">Cycle</th><th data-type="num">Started</th><th data-type="text">Status</th>')
        [void]$sb.AppendLine('</tr></thead><tbody>')
        foreach ($r in $sorted) {
            $isPrep = [bool]$r.isPrep
            $bucket = Get-HoblStatusBucket -Status ([string]$r.status)
            $scen   = ConvertTo-HoblHtmlText ([string]$r.scenario)
            $prof   = ConvertTo-HoblHtmlText ([string]$r.profile)
            $planId = ConvertTo-HoblHtmlText ([string]$r.planId)
            $cycleN = [int]$r.cycle
            $cycle  = if ([int]$r.cycleTotal -gt 0) { "$cycleN/$([int]$r.cycleTotal)" } else { '' }
            $st     = ConvertTo-HoblDate ([string]$r.startTime)
            $started   = if ($st) { $st.ToString('MM-dd HH:mm:ss') } else { '' }
            $startSort = if ($st) { $st.ToString('yyyyMMddHHmmss') } else { '0' }
            $statusText = ConvertTo-HoblHtmlText ([string]$r.status)
            $rowClass   = if ($isPrep) { 'prep' } else { '' }
            $prepAttr   = if ($isPrep) { '1' } else { '0' }
            [void]$sb.AppendLine("<tr class=""$rowClass"" data-status=""$bucket"" data-dut=""$prof"" data-scenario=""$scen"" data-prep=""$prepAttr"">")
            [void]$sb.AppendLine("<td>$scen</td>")
            [void]$sb.AppendLine("<td>$prof</td>")
            [void]$sb.AppendLine("<td class=""mono"">$planId</td>")
            [void]$sb.AppendLine("<td class=""mono"" data-sort=""$cycleN"">$cycle</td>")
            [void]$sb.AppendLine("<td class=""mono"" data-sort=""$startSort"">$started</td>")
            [void]$sb.AppendLine("<td><span class=""pill $bucket"">$statusText</span></td>")
            [void]$sb.AppendLine('</tr>')
        }
        [void]$sb.AppendLine('</tbody></table>')
    }

    [void]$sb.AppendLine('<div class="foot">Prep rows are greyed and excluded from all counts. Click a column header to sort. Times are local to the host that generated this report.</div>')
    [void]$sb.AppendLine(@'
<script>
(function(){
  var tbl = document.getElementById('main');
  if (!tbl) return;
  var tb = tbl.tBodies[0];
  var statusSel = document.getElementById('f-status');
  var dutSel = document.getElementById('f-dut');
  var scenInp = document.getElementById('f-scen');
  var prepChk = document.getElementById('f-prep');
  var countEl = document.getElementById('f-count');

  function applyFilter(){
    var s = statusSel.value, d = dutSel.value, q = (scenInp.value || '').toLowerCase(), hidePrep = prepChk.checked;
    var rows = tb.rows, shown = 0;
    for (var i = 0; i < rows.length; i++){
      var r = rows[i], ok = true;
      if (s !== 'all' && r.getAttribute('data-status') !== s) ok = false;
      if (ok && d !== 'all' && r.getAttribute('data-dut') !== d) ok = false;
      if (ok && q && r.getAttribute('data-scenario').toLowerCase().indexOf(q) === -1) ok = false;
      if (ok && hidePrep && r.getAttribute('data-prep') === '1') ok = false;
      r.style.display = ok ? '' : 'none';
      if (ok) shown++;
    }
    if (countEl) countEl.textContent = shown + ' of ' + rows.length + ' shown';
  }

  function sortBy(col, type){
    var rows = Array.prototype.slice.call(tb.rows);
    var asc = (tbl.getAttribute('data-sortcol') == col) ? (tbl.getAttribute('data-sortdir') !== 'asc') : true;
    rows.sort(function(a, b){
      var x = a.cells[col].getAttribute('data-sort'); if (x === null) x = a.cells[col].textContent.trim();
      var y = b.cells[col].getAttribute('data-sort'); if (y === null) y = b.cells[col].textContent.trim();
      if (type === 'num'){ x = parseFloat(x) || 0; y = parseFloat(y) || 0; return asc ? x - y : y - x; }
      return asc ? x.localeCompare(y) : y.localeCompare(x);
    });
    for (var i = 0; i < rows.length; i++) tb.appendChild(rows[i]);
    tbl.setAttribute('data-sortcol', col);
    tbl.setAttribute('data-sortdir', asc ? 'asc' : 'desc');
  }

  var ths = tbl.tHead.rows[0].cells;
  for (var i = 0; i < ths.length; i++){
    (function(idx){
      var type = ths[idx].getAttribute('data-type') || 'text';
      ths[idx].addEventListener('click', function(){ sortBy(idx, type); });
    })(i);
  }
  statusSel.addEventListener('change', applyFilter);
  dutSel.addEventListener('change', applyFilter);
  scenInp.addEventListener('input', applyFilter);
  prepChk.addEventListener('change', applyFilter);
  applyFilter();
})();
</script>
'@)
    [void]$sb.AppendLine('</body></html>')

    Set-Content -Path $paths.Html -Value ($sb.ToString()) -Encoding utf8
    return $paths.Html
}

# ---------------------------------------------------------------------------
# Weekly summary (for email) — same numbers the HTML shows, as an object.
# ---------------------------------------------------------------------------
# Reads a week's ledger and returns counts, pass rate, the failed/terminated
# rows, and per-DUT breakdown. Used by send_report_email.ps1 to build the
# email-safe body. Mirrors Write-HoblReportHtml's aggregation (dedup by
# planId|scenarioId, prep excluded from counts).
function Get-HoblReportSummary {
    param(
        [Parameter(Mandatory)] [string] $ReportDir,
        [datetime] $Date = (Get-Date),
        [string]   $Frequency = 'Weekly'
    )
    $paths   = Get-HoblReportPaths -ReportDir $ReportDir -Date $Date -Frequency $Frequency
    $iso     = $paths.Period
    $entries = Read-HoblReportLedger -Path $paths.Ledger

    $byKey = @{}
    foreach ($e in $entries) {
        if ("$($e.type)" -eq 'plan') { continue }
        if ($null -eq $e.planId -or $null -eq $e.scenarioId) { continue }
        $key  = "$([int]$e.planId)|$([int]$e.scenarioId)"
        $prev = $byKey[$key]
        if (-not $prev) {
            $byKey[$key] = $e
        } else {
            $a = ConvertTo-HoblDate ([string]$e.recordedAt)
            $b = ConvertTo-HoblDate ([string]$prev.recordedAt)
            if ($a -and $b -and $a -ge $b) { $byKey[$key] = $e }
        }
    }
    $rows = @($byKey.Values)

    $counts = [ordered]@{ Passed = 0; Failed = 0; Terminated = 0; Other = 0 }
    $byDut  = @{}
    $problems = @()
    foreach ($r in $rows) {
        if ($r.isPrep) { continue }
        $bucket = Get-HoblStatusBucket -Status ([string]$r.status)
        $counts[$bucket]++
        $dut = [string]$r.profile
        if (-not $byDut.ContainsKey($dut)) { $byDut[$dut] = [ordered]@{ Passed=0; Failed=0; Terminated=0; Other=0 } }
        $byDut[$dut][$bucket]++
        if ($bucket -in @('Failed','Terminated')) { $problems += $r }
    }
    $total = $counts.Passed + $counts.Failed + $counts.Terminated + $counts.Other
    $denom = $counts.Passed + $counts.Failed + $counts.Terminated
    $rate  = if ($denom -gt 0) { [int][math]::Round($counts.Passed / $denom * 100) } else { $null }

    $problems = @($problems | Sort-Object `
        @{ Expression = { [int]$_.planId }; Descending = $true }, `
        @{ Expression = { [int]$_.scenarioId }; Descending = $false })

    [pscustomobject]@{
        Period     = $iso
        Counts     = $counts
        Total      = $total
        PassRate   = $rate
        ByDut      = $byDut
        Problems   = $problems
        HasData    = ($total -gt 0)
    }
}

# Build an email-safe HTML body (inline styles only, NO JavaScript — email
# clients strip JS). The full interactive report rides along as an attachment.
function ConvertTo-HoblEmailBodyHtml {
    param(
        [Parameter(Mandatory)] $Summary,
        [string] $AttachmentName = ''
    )
    $iso   = $Summary.Period
    $c     = $Summary.Counts
    $rate  = if ($null -ne $Summary.PassRate) { "$($Summary.PassRate)%" } else { '&mdash;' }
    $rateColor = if ($null -eq $Summary.PassRate) { '#57606a' } elseif ($Summary.PassRate -ge 90) { '#1a7f37' } elseif ($Summary.PassRate -ge 70) { '#bc4c00' } else { '#cf222e' }
    $range = $iso.Range

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<div style="font-family:Segoe UI,Arial,sans-serif;color:#1f2328;font-size:14px;">')
    [void]$sb.AppendLine("<h2 style=""margin:0 0 2px;"">HOBL $($iso.Title) Automation Report</h2>")
    [void]$sb.AppendLine("<div style=""color:#57606a;font-size:13px;margin-bottom:16px;"">$($iso.Title) $($iso.Key) &middot; $range</div>")

    if (-not $Summary.HasData) {
        [void]$sb.AppendLine('<p>No scenario results were recorded for this period.</p>')
    } else {
        # Headline numbers as a simple table (email-safe).
        [void]$sb.AppendLine('<table cellpadding="8" cellspacing="0" style="border-collapse:collapse;margin-bottom:16px;">')
        [void]$sb.AppendLine('<tr>')
        [void]$sb.AppendLine("<td style=""border:1px solid #d0d7de;text-align:center;""><div style=""font-size:26px;font-weight:700;color:$rateColor;"">$rate</div><div style=""font-size:11px;color:#57606a;text-transform:uppercase;"">Pass rate</div></td>")
        [void]$sb.AppendLine("<td style=""border:1px solid #d0d7de;text-align:center;""><div style=""font-size:26px;font-weight:700;color:#1a7f37;"">$($c.Passed)</div><div style=""font-size:11px;color:#57606a;text-transform:uppercase;"">Passed</div></td>")
        [void]$sb.AppendLine("<td style=""border:1px solid #d0d7de;text-align:center;""><div style=""font-size:26px;font-weight:700;color:#cf222e;"">$($c.Failed)</div><div style=""font-size:11px;color:#57606a;text-transform:uppercase;"">Failed</div></td>")
        [void]$sb.AppendLine("<td style=""border:1px solid #d0d7de;text-align:center;""><div style=""font-size:26px;font-weight:700;color:#bc4c00;"">$($c.Terminated)</div><div style=""font-size:11px;color:#57606a;text-transform:uppercase;"">Terminated</div></td>")
        [void]$sb.AppendLine("<td style=""border:1px solid #d0d7de;text-align:center;""><div style=""font-size:26px;font-weight:700;"">$($Summary.Total)</div><div style=""font-size:11px;color:#57606a;text-transform:uppercase;"">Total</div></td>")
        [void]$sb.AppendLine('</tr></table>')

        # Needs attention.
        if ($Summary.Problems.Count -eq 0) {
            [void]$sb.AppendLine('<p style="background:#dafbe1;border:1px solid #a7e3b6;color:#1a7f37;padding:10px 14px;border-radius:6px;">No failures or terminations this period.</p>')
        } else {
            [void]$sb.AppendLine("<h3 style=""margin:16px 0 6px;"">Needs attention ($($Summary.Problems.Count))</h3>")
            [void]$sb.AppendLine('<table cellpadding="6" cellspacing="0" style="border-collapse:collapse;width:100%;font-size:13px;">')
            [void]$sb.AppendLine('<tr style="background:#f6f8fa;"><th align="left" style="border:1px solid #d0d7de;">Scenario</th><th align="left" style="border:1px solid #d0d7de;">DUT</th><th align="left" style="border:1px solid #d0d7de;">PlanID</th><th align="left" style="border:1px solid #d0d7de;">Started</th><th align="left" style="border:1px solid #d0d7de;">Status</th></tr>')
            foreach ($p in $Summary.Problems) {
                $scen = ConvertTo-HoblHtmlText ([string]$p.scenario)
                $prof = ConvertTo-HoblHtmlText ([string]$p.profile)
                $planId = ConvertTo-HoblHtmlText ([string]$p.planId)
                $stat = ConvertTo-HoblHtmlText ([string]$p.status)
                $stDt = ConvertTo-HoblDate ([string]$p.startTime)
                $started = if ($stDt) { $stDt.ToString('ddd dd MMM HH:mm') } else { '&mdash;' }
                $sc   = if ((Get-HoblStatusBucket -Status ([string]$p.status)) -eq 'Failed') { '#cf222e' } else { '#bc4c00' }
                [void]$sb.AppendLine("<tr><td style=""border:1px solid #d0d7de;"">$scen</td><td style=""border:1px solid #d0d7de;"">$prof</td><td style=""border:1px solid #d0d7de;"">$planId</td><td style=""border:1px solid #d0d7de;white-space:nowrap;"">$started</td><td style=""border:1px solid #d0d7de;color:$sc;font-weight:600;"">$stat</td></tr>")
            }
            [void]$sb.AppendLine('</table>')
        }

        # By DUT.
        [void]$sb.AppendLine('<h3 style="margin:16px 0 6px;">By DUT</h3>')
        [void]$sb.AppendLine('<table cellpadding="6" cellspacing="0" style="border-collapse:collapse;font-size:13px;">')
        [void]$sb.AppendLine('<tr style="background:#f6f8fa;"><th align="left" style="border:1px solid #d0d7de;">DUT / Profile</th><th align="left" style="border:1px solid #d0d7de;">Pass</th><th align="left" style="border:1px solid #d0d7de;">Fail</th><th align="left" style="border:1px solid #d0d7de;">Term</th><th align="left" style="border:1px solid #d0d7de;">Rate</th></tr>')
        $dutSorted = $Summary.ByDut.GetEnumerator() | Sort-Object @{ Expression = { $_.Value.Failed + $_.Value.Terminated }; Descending = $true }, @{ Expression = { $_.Key } }
        foreach ($d in $dutSorted) {
            $den  = $d.Value.Passed + $d.Value.Failed + $d.Value.Terminated
            $dr   = if ($den -gt 0) { "$([int][math]::Round($d.Value.Passed / $den * 100))%" } else { '&mdash;' }
            $name = ConvertTo-HoblHtmlText ([string]$d.Key)
            [void]$sb.AppendLine("<tr><td style=""border:1px solid #d0d7de;"">$name</td><td style=""border:1px solid #d0d7de;"">$($d.Value.Passed)</td><td style=""border:1px solid #d0d7de;"">$($d.Value.Failed)</td><td style=""border:1px solid #d0d7de;"">$($d.Value.Terminated)</td><td style=""border:1px solid #d0d7de;"">$dr</td></tr>")
        }
        [void]$sb.AppendLine('</table>')
    }

    if ($AttachmentName) {
        [void]$sb.AppendLine("<p style=""margin-top:18px;color:#57606a;font-size:13px;"">The full interactive report (sortable, filterable) is attached as <b>$([System.Net.WebUtility]::HtmlEncode($AttachmentName))</b> &mdash; open it in a browser.</p>")
    }
    [void]$sb.AppendLine('<div style="color:#8c959f;font-size:12px;margin-top:10px;">Prep rows are excluded from counts. Times are local to the reporting host.</div>')
    [void]$sb.AppendLine('</div>')
    return $sb.ToString()
}
