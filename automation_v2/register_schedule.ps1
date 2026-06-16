# Register the "HOBL Daily Automation" scheduled task.
#
# Run this ONCE, in an elevated (Administrator) PowerShell.
# After that, Windows Task Scheduler fires daily_run.ps1 every day at the
# configured time, regardless of who is logged on, and wakes the machine
# if asleep.
#
# To re-register (e.g. after changing the trigger time), just run again —
# the -Force flag overwrites the existing task.

param(
    [string]$TaskName     = "HOBL Daily Automation",
    [string]$Time         = "00:00",
    [string]$DailyRunPath = ""
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

# Default the script path relative to this file's location so the task points
# at the same automation\ folder this script lives in.
if (-not $DailyRunPath) {
    $DailyRunPath = Join-Path $PSScriptRoot "daily_run.ps1"
}

if (-not (Test-Path $DailyRunPath)) {
    Write-Host " ERROR - daily_run.ps1 not found at: $DailyRunPath" -ForegroundColor Red
    Exit 1
}

# Require admin — Register-ScheduledTask for SYSTEM/HIGHEST needs it.
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host " ERROR - Must be run from an elevated (Administrator) PowerShell." -ForegroundColor Red
    Exit 1
}

# ---------------------------------------------------------------------------
# Optional interactive reconfiguration of schedule.config.json.
# Prompt once: do you want to rebuild the jobs[] list and pick a new trigger
# time? Y = walk through DUT count + time + per-DUT profile/testplan and
# REPLACE jobs[] (after backing the file up to .bak). N = leave the file as
# is and just register the task with the existing -Time param.
# ---------------------------------------------------------------------------
$configPath = Join-Path $PSScriptRoot "schedule.config.json"
$repoRoot   = Split-Path -Parent $PSScriptRoot
$profilesDir = "C:\profiles"

function Read-NonEmpty {
    param([string]$Prompt)
    while ($true) {
        $v = Read-Host $Prompt
        if ($v -and $v.Trim()) { return $v.Trim() }
        Write-Host " ERROR - value cannot be empty." -ForegroundColor Red
    }
}

function Read-PositiveInt {
    param([string]$Prompt, [int]$Default = 0)
    while ($true) {
        $v = Read-Host $Prompt
        if (-not $v -and $Default -gt 0) { return $Default }
        if ($v -match '^[1-9]\d*$') { return [int]$v }
        Write-Host " ERROR - enter a positive integer." -ForegroundColor Red
    }
}

function Read-TimeHHMM {
    param([string]$Prompt = "Trigger time (HH:MM, 24h)")
    while ($true) {
        $v = Read-Host $Prompt
        if ($v -match '^([01]\d|2[0-3]):[0-5]\d$') { return $v }
        Write-Host " ERROR - format must be HH:MM (00:00 - 23:59)." -ForegroundColor Red
    }
}

function Read-Profile {
    while ($true) {
        $p = Read-NonEmpty "  Profile name (file in $profilesDir without .ini)"
        $f = Join-Path $profilesDir "$p.ini"
        if (Test-Path $f) { return $p }
        Write-Host " ERROR - profile '$p' not found at $f" -ForegroundColor Red
    }
}

function Read-Testplan {
    # Lazy-load the parser so we can dry-parse for validation.
    if (-not (Get-Command ConvertFrom-HoblTestplan -ErrorAction SilentlyContinue)) {
        . (Join-Path $PSScriptRoot "lib\testplan.ps1")
    }
    $testplansDir = Join-Path $repoRoot "testplans"
    while ($true) {
        $t = Read-NonEmpty "  Testplan name (file in testplans/ without .ps1, e.g. intern_teams2)"
        # If user typed a path or full filename, honour it; otherwise resolve
        # bare name under testplans/<name>.ps1.
        if ($t -match '[\\/]' -or $t -like '*.ps1') {
            $abs = if ([System.IO.Path]::IsPathRooted($t)) { $t } else { Join-Path $repoRoot $t }
        } else {
            $abs = Join-Path $testplansDir "$t.ps1"
        }
        if (-not (Test-Path $abs)) {
            Write-Host " ERROR - testplan not found at $abs" -ForegroundColor Red
            continue
        }
        try {
            $null = ConvertFrom-HoblTestplan -Path $abs
        } catch {
            Write-Host " ERROR - testplan failed to parse: $($_.Exception.Message)" -ForegroundColor Red
            continue
        }
        # Store relative path if it lives under the repo root, else absolute.
        $rel = $abs
        if ($abs.StartsWith($repoRoot, [StringComparison]::OrdinalIgnoreCase)) {
            $rel = $abs.Substring($repoRoot.Length).TrimStart('\','/').Replace('\','/')
        }
        return $rel
    }
}

Write-Host ""
$change = Read-Host "Want to change configuration (Y/N)?"
if ($change -match '^[Yy]') {
    if (-not (Test-Path $configPath)) {
        Write-Host " ERROR - schedule.config.json not found at $configPath" -ForegroundColor Red
        Exit 1
    }

    $config = Get-Content -Path $configPath -Raw -Encoding UTF8 | ConvertFrom-Json

    $count = Read-PositiveInt "Number of DUTs"
    $Time  = Read-TimeHHMM
    Write-Host "  trigger time: $Time"

    $newJobs = @()
    for ($i = 1; $i -le $count; $i++) {
        Write-Host ""
        Write-Host "DUT $i of $count" -ForegroundColor Cyan
        $profileName = Read-Profile
        $testplan    = Read-Testplan
        $runsPerDay  = Read-PositiveInt "  Runs per day (default 1)" 1

        $tpBase  = [System.IO.Path]::GetFileNameWithoutExtension($testplan)
        $jobName = "${profileName}_${tpBase}"

        $newJobs += [pscustomobject]@{
            name       = $jobName
            enabled    = $true
            profile    = $profileName
            testplan   = $testplan
            runsPerDay = $runsPerDay
        }
        Write-Host "  added job: $jobName (profile=$profileName, testplan=$testplan, runsPerDay=$runsPerDay)" -ForegroundColor Green
    }

    # Back up then replace jobs[] in the config (preserve all other top-level
    # keys: hoblwebBaseUrl, logDir, submit, monitor, etc.).
    Copy-Item -Path $configPath -Destination "$configPath.bak" -Force
    Write-Host ""
    Write-Host "Backed up existing config to: $configPath.bak"

    $config.jobs = $newJobs
    $config | ConvertTo-Json -Depth 12 | Set-Content -Path $configPath -Encoding UTF8

    Write-Host "Wrote $count job(s) to $configPath"
} else {
    Write-Host "Leaving schedule.config.json unchanged. Trigger time = $Time"
}
Write-Host ""

Write-Host "Registering scheduled task '$TaskName'..."
Write-Host "  Trigger: daily at $Time"
Write-Host "  Action:  powershell.exe -File $DailyRunPath"

$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-ExecutionPolicy Bypass -NoProfile -File `"$DailyRunPath`""

$trigger = New-ScheduledTaskTrigger -Daily -At $Time

# WakeToRun: wake the host from sleep at trigger time.
# StartWhenAvailable: if the host was off at trigger time, run as soon as it comes back.
# AllowStartIfOnBatteries + DontStopIfGoingOnBatteries: DUT hosts may be on battery.
# ExecutionTimeLimit 0 = no time limit (cycles can be long).
$settings = New-ScheduledTaskSettingsSet `
    -WakeToRun `
    -StartWhenAvailable `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Hours 0)

Register-ScheduledTask `
    -TaskName    $TaskName `
    -Description "HOBL automation: re-submits HOBLweb plan templates listed in automation\schedule.config.json once per day with AutoResubmit set so HOBLweb auto-cycles them runsPerDay times." `
    -Action      $action `
    -Trigger     $trigger `
    -Settings    $settings `
    -User        "SYSTEM" `
    -RunLevel    Highest `
    -Force | Out-Null

Write-Host ""
Write-Host "Registered. Useful follow-ups:"
Write-Host "  schtasks /query /tn `"$TaskName`" /v /fo list   # see details + next run time"
Write-Host "  schtasks /run   /tn `"$TaskName`"               # force-fire now (best smoke test)"
Write-Host "  schtasks /change /tn `"$TaskName`" /disable     # pause"
Write-Host "  schtasks /delete /tn `"$TaskName`" /f           # remove"

# ---------------------------------------------------------------------------
# Optional: also register the weekly report-email task in the same run, so the
# operator doesn't have to invoke send_report_email.ps1 -Register separately.
#
# The two stay as SEPARATE scheduled tasks on purpose: the daily run is SYSTEM,
# but the email task must run as the LOGGED-IN user (Outlook COM needs an
# interactive session). We just drive both registrations from one prompt here.
# Defaults (recipient / day / time) come from the config's "email" block.
# ---------------------------------------------------------------------------
$emailScript = Join-Path $PSScriptRoot "send_report_email.ps1"
if (Test-Path $emailScript) {
    # Pull defaults from schedule.config.json's email block, if present.
    $emailTo   = ""
    $emailDay  = "Friday"
    $emailTime = "17:00"
    $emailDefaultEnabled = $true
    if (Test-Path $configPath) {
        try {
            $cfgForEmail = Get-Content -Path $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($cfgForEmail.email) {
                if ($cfgForEmail.email.to)       { $emailTo   = [string]$cfgForEmail.email.to }
                if ($cfgForEmail.email.sendDay)  { $emailDay  = [string]$cfgForEmail.email.sendDay }
                if ($cfgForEmail.email.sendTime) { $emailTime = [string]$cfgForEmail.email.sendTime }
                if ($null -ne $cfgForEmail.email.enabled) { $emailDefaultEnabled = [bool]$cfgForEmail.email.enabled }
            }
        } catch { }
    }

    Write-Host ""
    $defHint = if ($emailDefaultEnabled) { "Y" } else { "N" }
    $wantEmail = Read-Host "Also register the weekly report email task? (Y/N) [$defHint]"
    if (-not $wantEmail) { $wantEmail = $defHint }
    if ($wantEmail -match '^[Yy]') {
        # Recipient: use config default if present, else prompt (required).
        if (-not $emailTo) {
            $emailTo = Read-Host "  Recipient email (;-separated for multiple)"
        } else {
            $override = Read-Host "  Recipient [$emailTo] (Enter to keep)"
            if ($override) { $emailTo = $override }
        }
        if (-not $emailTo) {
            Write-Host " WARN - No recipient given; skipping email task registration." -ForegroundColor Yellow
        } else {
            # Day of week.
            $dayIn = Read-Host "  Send day [$emailDay] (Enter to keep)"
            if ($dayIn) { $emailDay = $dayIn }
            # Time HH:MM.
            $timeIn = Read-Host "  Send time HH:MM [$emailTime] (Enter to keep)"
            if ($timeIn) { $emailTime = $timeIn }

            Write-Host "Registering weekly email task (day=$emailDay time=$emailTime to=$emailTo)..."
            # Delegate to send_report_email.ps1 -Register so there's ONE source
            # of truth for how the email task is built. It registers as the
            # current interactive user (required for Outlook COM).
            & powershell.exe -ExecutionPolicy Bypass -NoProfile -File $emailScript `
                -Register -Day $emailDay -Time $emailTime -To $emailTo
            if ($LASTEXITCODE -ne 0) {
                Write-Host " WARN - Email task registration returned exit code $LASTEXITCODE." -ForegroundColor Yellow
            }
        }
    } else {
        Write-Host "Skipped weekly email task. Register later with:"
        Write-Host "  send_report_email.ps1 -Register -Day $emailDay -Time $emailTime"
    }
}
