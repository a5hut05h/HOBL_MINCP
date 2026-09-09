# HOBL automation v2 — report email helper (Outlook COM, on-demand + logon).
#
# Sends the per-run HTML report to the configured recipients using the Host's
# already-signed-in Outlook desktop account. No SMTP, no stored password —
# Outlook sends as the logged-in user, so internal distribution lists accept it.
# The email body is an email-safe static summary (pass rate, failures, per-DUT);
# the full interactive .html report is ATTACHED (email clients strip the
# JavaScript that powers the in-report sort/filter, so the live controls only
# work when the attachment is opened in a browser).
#
# HOW IT FITS THE PIPELINE:
#   daily_run.ps1 runs as SYSTEM and can't drive Outlook COM. When a run
#   finishes it writes a marker under <reportDir>\pending_email\ and pokes the
#   "HOBL Report Email" scheduled task, which runs THIS script (as the logged-in
#   user) in -Drain mode. -Drain sends every pending marker's report and deletes
#   each marker on success. The task also has a logon trigger, so any markers
#   left while logged off are drained automatically at next sign-in.
#
# MODES (same script):
#   1. Drain (default; what the helper task runs):
#        powershell -ExecutionPolicy Bypass -File send_report_email.ps1
#        powershell -ExecutionPolicy Bypass -File send_report_email.ps1 -Drain
#   2. Register the on-demand + logon helper task (runs as the interactive user):
#        powershell -ExecutionPolicy Bypass -File send_report_email.ps1 -Register
#   3. Manual send of a specific period's report NOW (re-send / ad-hoc):
#        ... -Send -Frequency Daily   -Date 2026-07-06
#        ... -Send -Frequency Weekly  -Week 2026-W27
#        ... -Send -Frequency Monthly -Date 2026-07-15 -To "a@x.com;b@y.com"
#
# IMPORTANT: the helper task runs as the LOGGED-IN Host user (Outlook COM needs
# an interactive session), NOT as SYSTEM. On a Host that stays signed in this
# sends within seconds of a run finishing.
#
# Recipients: -To wins (manual send), else the marker's recipients (drain), else
# config email.to. Configure the default in schedule.config.json:
#   "email": { "enabled": true, "to": "wssi-fun-idc@microsoft.com" }

param(
    [string]$ConfigPath = "",
    [switch]$Drain,                 # send all pending markers (default when no mode given)
    [switch]$Send,                  # manual: build + send a specific period's report now
    [switch]$Register,              # register the on-demand + logon helper task
    [string]$To         = "",       # ;-separated recipients; overrides config email.to (manual -Send)
    [string]$Frequency  = "",       # Daily|Weekly|Monthly (manual -Send); default from config schedule
    [string]$Week       = "",       # ISO week key e.g. 2026-W27 (manual weekly -Send)
    [string]$Date       = "",       # any date in the target period (manual -Send); -Week wins
    [switch]$LastPeriod,            # manual -Send: target the PREVIOUS period instead of the current one
    [string]$TaskName   = "HOBL Report Email"
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

$scriptDrive = Split-Path -Qualifier $PSScriptRoot
if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot "schedule.config.json" }

# ---------------------------------------------------------------------------
# -Register: create the on-demand + logon helper task (runs as the interactive
# user). No time trigger — daily_run.ps1 starts it when a run finishes, and the
# logon trigger drains any markers left while the Host was logged off.
# ---------------------------------------------------------------------------
if ($Register) {
    $self = Join-Path $PSScriptRoot "send_report_email.ps1"
    $argLine = "-ExecutionPolicy Bypass -NoProfile -File `"$self`" -Drain"
    $action  = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $argLine

    # Run as the current INTERACTIVE user (Outlook COM needs a logged-in
    # session). Limited run level is sufficient — no admin needed to send mail.
    $userId    = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited
    # Logon trigger so a backlog of markers is drained automatically at sign-in.
    $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $userId
    $settings  = New-ScheduledTaskSettingsSet `
        -StartWhenAvailable `
        -DontStopIfGoingOnBatteries `
        -AllowStartIfOnBatteries `
        -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Hours 1)

    Register-ScheduledTask -TaskName $TaskName `
        -Description "HOBL automation: sends the per-run HTML report (Outlook COM). Started on-demand by daily_run.ps1 at run end; also drains pending reports at logon. Runs as the interactive user." `
        -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null

    Write-Host "Registered '$TaskName': on-demand + at-logon, sends pending run reports (runs as $userId)." -ForegroundColor Green
    Write-Host "  Test now:  schtasks /run /tn `"$TaskName`""
    Write-Host "  Remove:    schtasks /delete /tn `"$TaskName`" /f"
    Exit 0
}

# ---------------------------------------------------------------------------
# Load config (for reportDir + default recipients + default frequency).
# ---------------------------------------------------------------------------
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

$logDir    = if ($cfg.logDir) { $cfg.logDir } else { "$scriptDrive\hobl_results\_automation_logs" }
$reportDir = $logDir
if ($cfg.report -and $cfg.report.dir) { $reportDir = [string]$cfg.report.dir }

. (Join-Path $PSScriptRoot "lib\report.ps1")
. (Join-Path $PSScriptRoot "lib\email.ps1")

$logger = { param($s)
    if ("$s" -match ' ERROR - ')    { Write-Host $s -ForegroundColor Red }
    elseif ("$s" -match ' WARN - ') { Write-Host $s -ForegroundColor Yellow }
    else                            { Write-Host $s }
}

# ---------------------------------------------------------------------------
# -Send (manual): build + send one period's report immediately (no marker).
# ---------------------------------------------------------------------------
if ($Send) {
    # Recipients: -To wins, else config email.to.
    $recipients = $To
    if (-not $recipients -and $cfg.email -and $cfg.email.to) { $recipients = [string]$cfg.email.to }
    if (-not $recipients) {
        Write-Host " ERROR - No recipient. Pass -To or set email.to in schedule.config.json." -ForegroundColor Red
        Exit 1
    }

    # Frequency: -Frequency wins, else config schedule.frequency, else Weekly.
    $freq = $Frequency
    if (-not $freq -and $cfg.schedule -and $cfg.schedule.frequency) { $freq = [string]$cfg.schedule.frequency }
    $freq = Get-HoblReportFrequency $freq

    # Resolve the target period date: -Week wins, else -Date, else today; then
    # -LastPeriod shifts back one whole period.
    function Resolve-WeekDate {
        param([string]$WeekKey)
        if ($WeekKey -notmatch '^(\d{4})-?W(\d{1,2})$') { throw "Invalid -Week '$WeekKey'. Use YYYY-Www." }
        $y = [int]$Matches[1]; $w = [int]$Matches[2]
        $jan4 = [datetime]::new($y, 1, 4)
        $dow  = [int]$jan4.DayOfWeek; if ($dow -eq 0) { $dow = 7 }
        return $jan4.AddDays(1 - $dow).AddDays(($w - 1) * 7)
    }
    $targetDate = Get-Date
    if ($Week) { $targetDate = Resolve-WeekDate -WeekKey $Week }
    elseif ($Date) {
        $parsed = [datetime]::MinValue
        if (-not [datetime]::TryParse($Date, [ref]$parsed)) { Write-Host " ERROR - Invalid -Date '$Date'." -ForegroundColor Red; Exit 1 }
        $targetDate = $parsed
    }
    if ($LastPeriod) {
        switch ($freq) {
            'Daily'   { $targetDate = $targetDate.AddDays(-1) }
            'Monthly' { $targetDate = $targetDate.AddMonths(-1) }
            default   { $targetDate = $targetDate.AddDays(-7) }
        }
    }

    # Reuse the shared send path via a synthetic marker so manual and automated
    # sends build the email identically.
    $marker = [pscustomobject]@{
        runId      = 'manual'
        createdAt  = (Get-Date).ToString('o')
        reportDir  = $reportDir
        frequency  = $freq
        date       = $targetDate.ToString('o')
        recipients = $recipients
        incomplete = $false
        note       = ''
    }
    $ok = Send-HoblReportEmail -Marker $marker -Log $logger
    if ($ok) { Write-Host "Email sent." -ForegroundColor Green; Exit 0 }
    Write-Host " ERROR - Email was not sent (see messages above)." -ForegroundColor Red
    Exit 1
}

# ---------------------------------------------------------------------------
# Default / -Drain: send every pending marker, delete each on success.
# ---------------------------------------------------------------------------
$res = Invoke-HoblEmailDrain -ReportDir $reportDir -Log $logger
Write-Host "Drain complete: sent=$($res.Sent) kept=$($res.Kept) bad=$($res.Bad)"
if ($res.Kept -gt 0) { Exit 1 }
Exit 0
