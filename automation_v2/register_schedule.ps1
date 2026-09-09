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
    [string]$DailyRunPath = "",

    # Schedule cadence. Leave $Frequency empty to be prompted interactively.
    # Defaults when chosen interactively: Weekly -> Monday, Monthly -> day 1.
    [ValidateSet("", "Daily", "Weekly", "Monthly")]
    [string]$Frequency    = "",
    [string]$DayOfWeek    = "",      # used when Frequency = Weekly  (e.g. Monday)
    [int]   $DayOfMonth   = 0        # used when Frequency = Monthly (1-28)
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

# Default the script path relative to this file's location so the task points
# at the same automation_v2\ folder this script lives in.
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
    param([string]$Prompt = "Trigger time (HH:MM, 24h)", [string]$Default = "")
    while ($true) {
        $label = if ($Default) { "$Prompt [$Default]" } else { $Prompt }
        $v = Read-Host $label
        if (-not $v -and $Default) { return $Default }
        if ($v -match '^([01]\d|2[0-3]):[0-5]\d$') { return $v }
        Write-Host " ERROR - format must be HH:MM (00:00 - 23:59)." -ForegroundColor Red
    }
}

function Read-Frequency {
    param([string]$Default = "Daily")
    while ($true) {
        Write-Host ""
        Write-Host "How often should the automation run?"
        Write-Host "  [1] Daily"
        Write-Host "  [2] Weekly   (default day: Monday)"
        Write-Host "  [3] Monthly  (default day of month: 1)"
        $v = Read-Host "Choose 1/2/3 (or Daily/Weekly/Monthly) [$Default]"
        if (-not $v) { return $Default }
        switch ($v.Trim().ToLower()) {
            "1"       { return "Daily" }
            "daily"   { return "Daily" }
            "2"       { return "Weekly" }
            "weekly"  { return "Weekly" }
            "3"       { return "Monthly" }
            "monthly" { return "Monthly" }
            default   { Write-Host " ERROR - choose 1, 2, 3, Daily, Weekly or Monthly." -ForegroundColor Red }
        }
    }
}

function Read-DayOfWeek {
    param([string]$Default = "Monday")
    $valid = @("Sunday","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday")
    while ($true) {
        $v = Read-Host "  Day of week [$Default]"
        if (-not $v) { return $Default }
        $match = $valid | Where-Object { $_ -ieq $v.Trim() } | Select-Object -First 1
        if ($match) { return $match }
        Write-Host " ERROR - enter a weekday name (e.g. Monday)." -ForegroundColor Red
    }
}

function Read-DayOfMonth {
    param([int]$Default = 1)
    while ($true) {
        $v = Read-Host "  Day of month 1-28 [$Default]"
        if (-not $v) { return $Default }
        # Capped at 28 so the day exists in every month (no skipped months).
        if ($v -match '^([1-9]|1\d|2[0-8])$') { return [int]$v }
        Write-Host " ERROR - enter a day 1-28 (kept <=28 so it runs every month)." -ForegroundColor Red
    }
}

# Build the Task Scheduler trigger for daily/weekly cadences. New-ScheduledTaskTrigger
# natively supports -Daily / -Weekly. Monthly is NOT handled here: PowerShell has
# no -Monthly switch and the MSFT_TaskMonthlyTrigger CIM class is unreliable across
# Windows builds ("The parameter is incorrect"), so the monthly case is registered
# separately via schtasks.exe (see the registration section below).
function New-HoblTrigger {
    param(
        [Parameter(Mandatory)][string]$Frequency,
        [Parameter(Mandatory)][string]$Time,
        [string]$DayOfWeek  = "Monday"
    )
    switch ($Frequency) {
        "Daily"  { return New-ScheduledTaskTrigger -Daily  -At $Time }
        "Weekly" { return New-ScheduledTaskTrigger -Weekly -DaysOfWeek $DayOfWeek -At $Time }
        default  { throw "New-HoblTrigger does not handle frequency '$Frequency'." }
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
        $t = Read-NonEmpty "  Testplan name (file in testplans/ without .ps1, e.g. power_workloads)"
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

# ---------------------------------------------------------------------------
# Schedule cadence selection (daily / weekly / monthly).
# Prompt for any value not supplied on the command line, seeding defaults from
# the existing schedule.config.json "schedule" block when present. The chosen
# cadence is persisted back into the config so re-registering reuses it.
# ---------------------------------------------------------------------------
$cfgSchedule = $null
if (Test-Path $configPath) {
    try {
        $cfgTmp = Get-Content -Path $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($cfgTmp.schedule) { $cfgSchedule = $cfgTmp.schedule }
    } catch { }
}

$defFrequency  = if ($cfgSchedule -and $cfgSchedule.frequency)  { [string]$cfgSchedule.frequency } else { "Daily" }
$defDayOfWeek  = if ($cfgSchedule -and $cfgSchedule.dayOfWeek)  { [string]$cfgSchedule.dayOfWeek } else { "Monday" }
$defDayOfMonth = if ($cfgSchedule -and $cfgSchedule.dayOfMonth) { [int]$cfgSchedule.dayOfMonth }   else { 1 }
$defTime       = if ($cfgSchedule -and $cfgSchedule.time)       { [string]$cfgSchedule.time }      else { $Time }

if (-not $Frequency) { $Frequency = Read-Frequency $defFrequency }

# Was -Time supplied explicitly on the command line? If so, honor it for every
# cadence and skip the interactive time prompt. We can't infer this from the
# value alone because the param default "00:00" is itself a valid trigger time.
$timeExplicit = $PSBoundParameters.ContainsKey('Time')

switch ($Frequency) {
    "Daily" {
        if (-not $timeExplicit) { $Time = Read-TimeHHMM "Trigger time (HH:MM, 24h)" $defTime }
    }
    "Weekly" {
        if (-not $DayOfWeek) { $DayOfWeek = Read-DayOfWeek $defDayOfWeek }
        if (-not $timeExplicit) { $Time = Read-TimeHHMM "Trigger time (HH:MM, 24h)" $defTime }
    }
    "Monthly" {
        if (-not $DayOfMonth -or $DayOfMonth -lt 1) { $DayOfMonth = Read-DayOfMonth $defDayOfMonth }
        if (-not $timeExplicit) { $Time = Read-TimeHHMM "Trigger time (HH:MM, 24h)" $defTime }
    }
}
if (-not $DayOfWeek)  { $DayOfWeek  = $defDayOfWeek }
if (-not $DayOfMonth -or $DayOfMonth -lt 1) { $DayOfMonth = $defDayOfMonth }

# Human-readable description of the chosen cadence (used in console + task desc).
switch ($Frequency) {
    "Daily"   { $scheduleDesc = "daily at $Time" }
    "Weekly"  { $scheduleDesc = "weekly on $DayOfWeek at $Time" }
    "Monthly" { $scheduleDesc = "monthly on day $DayOfMonth at $Time" }
}
Write-Host ""
Write-Host "Schedule: $scheduleDesc" -ForegroundColor Cyan

# Persist the cadence into schedule.config.json (independent of the job-list
# edit below, so it is saved even when you choose not to rebuild jobs[]).
if (Test-Path $configPath) {
    try {
        $cfgS = Get-Content -Path $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $scheduleObj = [pscustomobject]@{
            frequency  = $Frequency
            time       = $Time
            dayOfWeek  = $DayOfWeek
            dayOfMonth = $DayOfMonth
        }
        $cfgS | Add-Member -NotePropertyName schedule -NotePropertyValue $scheduleObj -Force
        $cfgS | ConvertTo-Json -Depth 12 | Set-Content -Path $configPath -Encoding UTF8
        Write-Host "Saved schedule cadence to $configPath"
    } catch {
        Write-Host " WARN - Could not persist schedule to config: $($_.Exception.Message)" -ForegroundColor Yellow
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
    Write-Host "Leaving schedule.config.json jobs unchanged. Schedule = $scheduleDesc"
}
Write-Host ""

Write-Host "Registering scheduled task '$TaskName'..."
Write-Host "  Trigger: $scheduleDesc"
Write-Host "  Action:  powershell.exe -File $DailyRunPath"

$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-ExecutionPolicy Bypass -NoProfile -File `"$DailyRunPath`""

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

$taskDescription = "HOBL automation: re-submits HOBLweb plan templates listed in automation_v2\schedule.config.json on the configured cadence ($scheduleDesc) with AutoResubmit set so HOBLweb auto-cycles them runsPerDay times."

if ($Frequency -eq "Monthly") {
    # PowerShell's New-ScheduledTaskTrigger has no -Monthly switch, and neither
    # building an MSFT_TaskMonthlyTrigger via CIM nor lifting one from an existing
    # task survives Register-ScheduledTask on this OS ("The parameter is incorrect").
    # So create the whole monthly task with schtasks.exe (which takes a literal
    # day-of-month via /d and quotes the action correctly), then apply the same
    # rich settings the daily/weekly path uses.
    $trCmd = "powershell.exe -ExecutionPolicy Bypass -NoProfile -File `"$DailyRunPath`""
    schtasks.exe /create /tn $TaskName /tr $trCmd /sc MONTHLY /mo 1 /d $DayOfMonth `
        /st $Time /ru "SYSTEM" /rl HIGHEST /f | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host " ERROR - schtasks failed to create the monthly task (exit $LASTEXITCODE)." -ForegroundColor Red
        Exit 1
    }
    # Apply WakeToRun / StartWhenAvailable / battery flags / etc. via the -TaskName
    # parameter set: it updates ONLY the settings, so it doesn't re-serialize the
    # monthly trigger (which is what makes -InputObject fail with "parameter is
    # incorrect"). The task Description is cosmetic and can't be set on a monthly
    # task through the cmdlets for the same reason, so it's left blank for Monthly.
    try {
        Set-ScheduledTask -TaskName $TaskName -Settings $settings | Out-Null
    } catch {
        Write-Host " WARN - monthly task created, but applying extended settings failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }
} else {
    $trigger = New-HoblTrigger -Frequency $Frequency -Time $Time -DayOfWeek $DayOfWeek

    Register-ScheduledTask `
        -TaskName    $TaskName `
        -Description $taskDescription `
        -Action      $action `
        -Trigger     $trigger `
        -Settings    $settings `
        -User        "SYSTEM" `
        -RunLevel    Highest `
        -Force | Out-Null
}

Write-Host ""
Write-Host "Registered. Useful follow-ups:"
Write-Host "  schtasks /query /tn `"$TaskName`" /v /fo list   # see details + next run time"
Write-Host "  schtasks /run   /tn `"$TaskName`"               # force-fire now (best smoke test)"
Write-Host "  schtasks /change /tn `"$TaskName`" /disable     # pause"
Write-Host "  schtasks /delete /tn `"$TaskName`" /f           # remove"

# ---------------------------------------------------------------------------
# Optional: also register the run-end report-email helper task in the same run,
# so the operator doesn't have to invoke send_report_email.ps1 -Register
# separately.
#
# The two stay as SEPARATE scheduled tasks on purpose: the daily run is SYSTEM
# (headless, wakes from sleep), but the email helper must run as the LOGGED-IN
# user (Outlook COM needs an interactive session). daily_run.ps1 starts the
# helper at run end; the helper also has a logon trigger to drain any backlog.
# The recipient default comes from the config's "email" block.
# ---------------------------------------------------------------------------
$emailScript = Join-Path $PSScriptRoot "send_report_email.ps1"
if (Test-Path $emailScript) {
    # Pull defaults from schedule.config.json's email block, if present.
    $emailTo   = ""
    $emailDefaultEnabled = $true
    if (Test-Path $configPath) {
        try {
            $cfgForEmail = Get-Content -Path $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($cfgForEmail.email) {
                if ($cfgForEmail.email.to) { $emailTo = [string]$cfgForEmail.email.to }
                if ($null -ne $cfgForEmail.email.enabled) { $emailDefaultEnabled = [bool]$cfgForEmail.email.enabled }
            }
        } catch { }
    }

    Write-Host ""
    $defHint = if ($emailDefaultEnabled) { "Y" } else { "N" }
    $wantEmail = Read-Host "Also register the run-end report email task? (Y/N) [$defHint]"
    if (-not $wantEmail) { $wantEmail = $defHint }
    if ($wantEmail -match '^[Yy]') {
        # Recipient (required): daily_run.ps1 stamps it onto each run's email
        # marker, and the helper sends there. Stored in config email.to.
        if (-not $emailTo) {
            $emailTo = Read-Host "  Recipient email (;-separated for multiple)"
        } else {
            $override = Read-Host "  Recipient [$emailTo] (Enter to keep)"
            if ($override) { $emailTo = $override }
        }
        if (-not $emailTo) {
            Write-Host " WARN - No recipient given; skipping email task registration." -ForegroundColor Yellow
        } else {
            # Persist recipient + enabled into config so daily_run picks it up.
            if (Test-Path $configPath) {
                try {
                    $cfgE = Get-Content -Path $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
                    $emailObj = [pscustomobject]@{ enabled = $true; to = $emailTo }
                    $cfgE | Add-Member -NotePropertyName email -NotePropertyValue $emailObj -Force
                    $cfgE | ConvertTo-Json -Depth 12 | Set-Content -Path $configPath -Encoding UTF8
                    Write-Host "  Saved email recipient to $configPath"
                } catch {
                    Write-Host " WARN - Could not persist email settings to config: $($_.Exception.Message)" -ForegroundColor Yellow
                }
            }

            Write-Host "Registering run-end email helper task (to=$emailTo)..."
            # Delegate to send_report_email.ps1 -Register so there's ONE source
            # of truth for how the helper task is built. It registers as the
            # current interactive user (required for Outlook COM), on-demand +
            # at-logon (no fixed time — daily_run.ps1 starts it at run end).
            & powershell.exe -ExecutionPolicy Bypass -NoProfile -File $emailScript -Register
            if ($LASTEXITCODE -ne 0) {
                Write-Host " WARN - Email task registration returned exit code $LASTEXITCODE." -ForegroundColor Yellow
            }
        }
    } else {
        Write-Host "Skipped run-end email task. Register later with:"
        Write-Host "  send_report_email.ps1 -Register"
    }
}
