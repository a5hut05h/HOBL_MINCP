# HOBL Daily Automation v2 — weekly report emailer (Outlook COM).
#
# Sends the weekly HTML report to a configurable recipient list using the
# DUT's already-signed-in Outlook desktop account. No SMTP, no stored password
# — Outlook sends as the logged-in user, so internal distribution lists accept
# it. The email body is an email-safe static summary (pass rate, failures,
# per-DUT); the full interactive .html report is ATTACHED (email clients strip
# the JavaScript that powers the in-report sort/filter, so the live controls
# only work when the attachment is opened in a browser).
#
# Two ways to use it — same script:
#   1. Manual / on-demand (sends the CURRENT week):
#        powershell -ExecutionPolicy Bypass -File send_report_email.ps1
#        powershell -ExecutionPolicy Bypass -File send_report_email.ps1 -Week 2026-W22
#        powershell -ExecutionPolicy Bypass -File send_report_email.ps1 -To "a@x.com;b@y.com"
#   2. Automatic weekly: register a scheduled task that runs this script.
#        powershell -ExecutionPolicy Bypass -File send_report_email.ps1 -Register -Day Monday -Time 09:00
#      The registered task bakes in -LastWeek, so each Monday it emails the
#      PREVIOUS week's report (by then every scenario for that week has run).
#      Manual runs (without -LastWeek) still send the current week.
#
# IMPORTANT: the weekly task runs as the LOGGED-IN user (Outlook COM needs an
# interactive session), NOT as SYSTEM. This suits lab DUTs that auto-login and
# stay awake. If no one is logged in at trigger time, the task waits until a
# session is available.
#
# Recipient comes from (in priority order): -To param, then config email.to,
# else it errors. Configure the default in schedule.config.json:
#   "email": { "enabled": true, "to": "wssi-fun-idc@microsoft.com",
#              "sendDay": "Friday", "sendTime": "17:00" }

param(
    [string]$ConfigPath = "",
    [string]$To         = "",       # ;-separated recipients; overrides config email.to
    [string]$Week       = "",       # ISO week key (e.g. 2026-W23); default = current week
    [string]$Date       = "",       # any date in the target week (yyyy-MM-dd); -Week wins
    [switch]$LastWeek,              # target the PREVIOUS week instead of the current one (baked into the registered task)
    [switch]$Refresh,               # re-render the week's HTML from the ledger before sending
    [switch]$Register,              # register the weekly scheduled task instead of sending
    [string]$Day        = "Monday", # (with -Register) day of week to send
    [string]$Time       = "09:00",  # (with -Register) HH:MM 24h
    [string]$TaskName   = "HOBL Weekly Report Email"
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

$scriptDrive = Split-Path -Qualifier $PSScriptRoot
if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot "schedule.config.json" }

# ---------------------------------------------------------------------------
# -Register: create the weekly scheduled task (runs as the interactive user).
# ---------------------------------------------------------------------------
if ($Register) {
    if ($Time -notmatch '^([01]\d|2[0-3]):[0-5]\d$') {
        Write-Host " ERROR - -Time must be HH:MM (00:00 - 23:59)." -ForegroundColor Red
        Exit 1
    }
    $validDays = 'Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday'
    if ($validDays -notcontains $Day) {
        Write-Host " ERROR - -Day must be one of: $($validDays -join ', ')." -ForegroundColor Red
        Exit 1
    }
    $self = Join-Path $PSScriptRoot "send_report_email.ps1"
    # Bake -To into the task action when provided, so the weekly run targets
    # exactly the recipient given at registration. When omitted, the task falls
    # back to config email.to at send time.
    # -LastWeek is baked in so the registered task always emails the previous
    # (fully completed) week; manual runs without it send the current week.
    $argLine = "-ExecutionPolicy Bypass -NoProfile -File `"$self`" -Refresh -LastWeek"
    if ($To) { $argLine += " -To `"$To`"" }
    $action  = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $argLine
    $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $Day -At $Time
    # Run as the current INTERACTIVE user (Outlook COM needs a logged-in
    # session). Limited run level is sufficient — no admin needed to send mail.
    $principal = New-ScheduledTaskPrincipal -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) `
        -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet `
        -StartWhenAvailable `
        -DontStopIfGoingOnBatteries `
        -AllowStartIfOnBatteries `
        -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Hours 1)

    Register-ScheduledTask -TaskName $TaskName `
        -Description "HOBL automation: emails the PREVIOUS week's HTML report (Outlook COM) every $Day at $Time." `
        -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null

    Write-Host "Registered '$TaskName': every $Day at $Time, emails the previous week's report (runs as $($principal.UserId))." -ForegroundColor Green
    Write-Host "  Test now:  schtasks /run /tn `"$TaskName`""
    Write-Host "  Remove:    schtasks /delete /tn `"$TaskName`" /f"
    Exit 0
}

# ---------------------------------------------------------------------------
# Normal path: build + send the email.
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

# Resolve recipients: -To wins, else config email.to.
$recipients = $To
if (-not $recipients -and $cfg.email -and $cfg.email.to) { $recipients = [string]$cfg.email.to }
if (-not $recipients) {
    Write-Host " ERROR - No recipient. Pass -To or set email.to in schedule.config.json." -ForegroundColor Red
    Exit 1
}
# Normalise separators (comma or semicolon) to ';' for Outlook.
$recipients = ($recipients -split '[;,]' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join ';'

. (Join-Path $PSScriptRoot "lib\report.ps1")

# Resolve target week date.
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
elseif ($LastWeek) { $targetDate = (Get-Date).AddDays(-7) }

# Optionally refresh the HTML from the ledger first (the scheduled task uses
# this so the emailed report is current).
if ($Refresh) {
    try { Write-HoblReportHtml -ReportDir $reportDir -Date $targetDate | Out-Null }
    catch { Write-Host " WARN - could not refresh report HTML: $($_.Exception.Message)" -ForegroundColor Yellow }
}

$paths = Get-HoblReportPaths -ReportDir $reportDir -Date $targetDate
if (-not (Test-Path $paths.Html)) {
    Write-Host " ERROR - Report HTML not found for week $($paths.Iso.Key): $($paths.Html)" -ForegroundColor Red
    Write-Host "         Run with -Refresh, or generate_report.ps1 first." -ForegroundColor Red
    Exit 1
}

$summary = Get-HoblReportSummary -ReportDir $reportDir -Date $targetDate
$attName = [System.IO.Path]::GetFileName($paths.Html)
$body    = ConvertTo-HoblEmailBodyHtml -Summary $summary -AttachmentName $attName
$rateTxt = if ($null -ne $summary.PassRate) { "$($summary.PassRate)%" } else { 'n/a' }
$subject = "HOBL Weekly Report $($summary.Iso.Key) - $rateTxt pass, $($summary.Counts.Failed) failed, $($summary.Counts.Terminated) terminated"

Write-Host "Week:       $($summary.Iso.Key)"
Write-Host "Recipients: $recipients"
Write-Host "Attachment: $($paths.Html)"

# ---- Send via Outlook COM ----
$outlook = $null
try {
    $outlook = New-Object -ComObject Outlook.Application
} catch {
    Write-Host " ERROR - Could not start Outlook COM. Is Outlook installed and signed in, and is a user logged on? $($_.Exception.Message)" -ForegroundColor Red
    Exit 1
}
try {
    $mail = $outlook.CreateItem(0)   # 0 = olMailItem
    $mail.To       = $recipients
    $mail.Subject  = $subject
    $mail.HTMLBody = $body
    $mail.Attachments.Add($paths.Html) | Out-Null
    $mail.Send()
    Write-Host "Email sent." -ForegroundColor Green
} catch {
    Write-Host " ERROR - Outlook failed to send: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "         If a security prompt appeared, the Outlook 'programmatic access' guard is active." -ForegroundColor Red
    Exit 1
} finally {
    if ($outlook) { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($outlook) | Out-Null }
}
Exit 0
