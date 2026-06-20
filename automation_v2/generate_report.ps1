# HOBL Daily Automation v2 — standalone weekly report builder.
#
# Rebuilds (or backfills) the weekly HTML report from the ledger that
# daily_run.ps1 / the monitor append to. Useful when you want to regenerate a
# report on demand, view a past week, or recover scenario rows the live
# monitor missed (e.g. it was disabled, or detached after monitor.maxHours).
#
#   # Rebuild THIS week's HTML from the ledger:
#   powershell -ExecutionPolicy Bypass -File generate_report.ps1
#
#   # Rebuild and ALSO pull anything the monitor missed from HOBLweb:
#   powershell -ExecutionPolicy Bypass -File generate_report.ps1 -Backfill
#
#   # A specific past week, then open it in the browser:
#   powershell -ExecutionPolicy Bypass -File generate_report.ps1 -Week 2026-W22 -Open
#
#   # Import results from daily logs (incl. logs copied from other hosts) into
#   # the matching weekly ledgers, then rebuild every affected week's HTML:
#   powershell -ExecutionPolicy Bypass -File generate_report.ps1 -ImportLogs
#
# Scope matches the automation: backfill only touches PlanIDs the ledger
# already knows are ours (plus their AutoResubmit-chain successors), so manual
# UI submissions on the same DUT are never pulled in.

param(
    [string]$ConfigPath = "",
    [string]$Date       = "",       # any date in the target week (yyyy-MM-dd); default = today
    [string]$Week       = "",       # OR an ISO week key, e.g. 2026-W23 (overrides -Date)
    [switch]$Backfill,              # merge missing scenario rows from HOBLweb
    [switch]$ImportLogs,            # reconstruct results from *_daily.log files and rebuild affected weeks
    [string]$LogDir     = "",       # where the *_daily.log files live (default: report dir / logDir)
    [switch]$Open                   # open the rendered HTML when done
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

$scriptDrive = Split-Path -Qualifier $PSScriptRoot
if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot "schedule.config.json" }

if (-not (Test-Path $ConfigPath)) {
    Write-Host " ERROR - Config not found: $ConfigPath" -ForegroundColor Red
    Exit 1
}
try {
    $cfg = Get-Content -Path $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    Write-Host " ERROR - Could not parse config: $($_.Exception.Message)" -ForegroundColor Red
    Exit 1
}

$baseUrl   = if ($cfg.hoblwebBaseUrl) { $cfg.hoblwebBaseUrl } else { "http://localhost" }
$logDir    = if ($cfg.logDir)         { $cfg.logDir }         else { "$scriptDrive\hobl_results\_automation_logs" }
$reportDir = $logDir
if ($cfg.report -and $cfg.report.dir) { $reportDir = [string]$cfg.report.dir }

$timeout = 30
if ($cfg.submit -and $cfg.submit.timeoutSec) { $timeout = [int]$cfg.submit.timeoutSec }

. (Join-Path $PSScriptRoot "lib\submit.ps1")
. (Join-Path $PSScriptRoot "lib\report.ps1")

$logger = { param($s) Write-Host $s }

# ---- Import-from-logs mode: parse *_daily.log into the weekly ledgers, then
# rebuild the HTML for every week the import touched, and exit. ----
if ($ImportLogs) {
    $srcLogDir = if ($LogDir) { $LogDir } else { $reportDir }
    if (-not (Test-Path $srcLogDir)) {
        Write-Host " ERROR - LogDir not found: $srcLogDir" -ForegroundColor Red
        Exit 1
    }
    Write-Host "Importing daily logs from: $srcLogDir"
    try {
        $res = Import-HoblReportFromLogs -ReportDir $reportDir -LogDir $srcLogDir -Log $logger
    } catch {
        Write-Host " ERROR - Log import failed: $($_.Exception.Message)" -ForegroundColor Red
        Exit 1
    }
    if ($res.Weeks.Count -eq 0) {
        Write-Host "No new results imported (logs empty or already imported)."
        Exit 0
    }
    $lastHtml = $null
    foreach ($w in $res.Weeks) {
        try {
            $lastHtml = Write-HoblReportHtml -ReportDir $reportDir -Date $w.Date -Log $logger
            Write-Host "  rebuilt $($w.Key): $lastHtml" -ForegroundColor Green
        } catch {
            Write-Host " ERROR - Render failed for week $($w.Key): $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    Write-Host "Imported $($res.Added) result row(s) across $($res.Weeks.Count) week(s)." -ForegroundColor Green
    if ($Open -and $lastHtml -and (Test-Path $lastHtml)) { Invoke-Item $lastHtml }
    Exit 0
}

# Resolve the target date: -Week wins, else -Date, else today.
function Resolve-WeekDate {
    param([string]$WeekKey)
    if ($WeekKey -notmatch '^(\d{4})-?W(\d{1,2})$') {
        throw "Invalid -Week '$WeekKey'. Use YYYY-Www, e.g. 2026-W23."
    }
    $y = [int]$Matches[1]; $w = [int]$Matches[2]
    $jan4 = [datetime]::new($y, 1, 4)         # Jan 4 is always in ISO week 1
    $dow  = [int]$jan4.DayOfWeek; if ($dow -eq 0) { $dow = 7 }
    $week1Monday = $jan4.AddDays(1 - $dow)
    return $week1Monday.AddDays(($w - 1) * 7)
}

$targetDate = Get-Date
if ($Week) {
    $targetDate = Resolve-WeekDate -WeekKey $Week
} elseif ($Date) {
    $parsed = [datetime]::MinValue
    if (-not [datetime]::TryParse($Date, [ref]$parsed)) {
        Write-Host " ERROR - Invalid -Date '$Date'. Use yyyy-MM-dd." -ForegroundColor Red
        Exit 1
    }
    $targetDate = $parsed
}

$iso = Get-HoblIsoWeek -Date $targetDate
Write-Host "Building report for week $($iso.Key) ($('{0:yyyy-MM-dd}' -f $iso.Monday) - $('{0:yyyy-MM-dd}' -f $iso.Sunday))"
Write-Host "  reportDir: $reportDir"
if ($Backfill) { Write-Host "  backfill:  ON (HOBLweb $baseUrl)" }

try {
    if ($Backfill) {
        $html = Write-HoblReportHtml -ReportDir $reportDir -Date $targetDate -BaseUrl $baseUrl -Backfill -TimeoutSec $timeout -Log $logger
    } else {
        $html = Write-HoblReportHtml -ReportDir $reportDir -Date $targetDate -Log $logger
    }
} catch {
    Write-Host " ERROR - Report render failed: $($_.Exception.Message)" -ForegroundColor Red
    Exit 1
}

Write-Host "Report written: $html" -ForegroundColor Green
if ($Open -and (Test-Path $html)) { Invoke-Item $html }
