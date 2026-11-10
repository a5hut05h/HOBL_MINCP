# Shared configuration, path, state, logging, and lock helpers for Automation V3.

function Get-HoblV3SafeId {
    param([Parameter(Mandatory)][string]$Value)
    $safe = ($Value.Trim().ToLowerInvariant() -replace '[^a-z0-9._-]', '-') -replace '-+', '-'
    $safe = $safe.Trim('-','.')
    if (-not $safe) { throw "Value '$Value' cannot be converted to a safe identifier." }
    return $safe
}

function Get-HoblV3ProfileInfo {
    param([Parameter(Mandatory)][string]$HoblDut)
    $profilesDir = 'C:\profiles'
    if (-not (Test-Path -LiteralPath $profilesDir -PathType Container)) { throw "HOBL profiles directory not found: $profilesDir" }
    $requested = [System.IO.Path]::GetFileNameWithoutExtension($HoblDut.Trim())
    $profileFiles = @(Get-ChildItem -LiteralPath $profilesDir -File -Filter '*.ini' | Where-Object { $_.BaseName -ieq $requested })
    if ($profileFiles.Count -ne 1) { throw "Profile '$HoblDut' was not found. Enter the exact profile filename from $profilesDir (case does not matter; spaces and punctuation do)." }

    $section = ''
    $hoblPath = ''
    foreach ($line in @(Get-Content -LiteralPath $profileFiles[0].FullName -Encoding UTF8)) {
        if ($line -match '^\s*\[([^]]+)\]\s*$') { $section = $Matches[1]; continue }
        if ($section -ieq 'global' -and $line -match '^\s*hobl_path\s*=\s*(.+?)\s*$') { $hoblPath = $Matches[1].Trim(); break }
    }
    if (-not $hoblPath) { throw "Profile '$($profileFiles[0].BaseName)' does not define global:hobl_path in $($profileFiles[0].FullName)." }
    if (-not (Test-Path -LiteralPath $hoblPath -PathType Container)) { throw "Profile '$($profileFiles[0].BaseName)' points to missing HOBL runtime: $hoblPath" }
    [pscustomobject]@{ Name = $profileFiles[0].BaseName; Path = $profileFiles[0].FullName; HoblPath = [System.IO.Path]::GetFullPath($hoblPath) }
}

function Assert-HoblV3ScenariosAvailable {
    param([Parameter(Mandatory)][string]$HoblDut, [Parameter(Mandatory)][object[]]$Rows)
    $info = Get-HoblV3ProfileInfo -HoblDut $HoblDut
    $missing = @()
    foreach ($scenario in @($Rows | ForEach-Object { [string]$_.Scenario } | Sort-Object -Unique)) {
        $found = $false
        foreach ($platform in @('common','windows','macos')) {
            $base = Join-Path (Join-Path $info.HoblPath 'scenarios') $platform
            if ((Test-Path -LiteralPath (Join-Path $base ($scenario + '.py')) -PathType Leaf) -or
                (Test-Path -LiteralPath (Join-Path (Join-Path $base $scenario) ($scenario + '.py')) -PathType Leaf)) { $found = $true; break }
        }
        if (-not $found) { $missing += $scenario }
    }
    if ($missing.Count -gt 0) { throw "Profile '$($info.Name)' uses HOBL runtime '$($info.HoblPath)', which is missing testplan scenario(s): $($missing -join ', '). Synchronize that runtime before scheduling or starting this job." }
    return $info
}

function Get-HoblV3Config {
    param([string]$ConfigPath = '')
    if (-not $ConfigPath) { $ConfigPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'automation.config.json' }
    $ConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw "Config not found: $ConfigPath" }
    try { $cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { throw "Could not parse config '$ConfigPath': $($_.Exception.Message)" }

    $v3Root = Split-Path -Parent $ConfigPath
    $repoRoot = Split-Path -Parent $v3Root
    $runtimeRoot = if ($cfg.runtimeRoot) { [string]$cfg.runtimeRoot } else { 'C:\hobl_results\automation_v3' }
    if (-not [System.IO.Path]::IsPathRooted($runtimeRoot)) { $runtimeRoot = Join-Path $v3Root $runtimeRoot }
    $runtimeRoot = [System.IO.Path]::GetFullPath($runtimeRoot)

    [pscustomobject]@{
        ConfigPath = $ConfigPath
        V3Root = $v3Root
        RepoRoot = $repoRoot
        RuntimeRoot = $runtimeRoot
        Config = $cfg
    }
}

function Test-HoblV3Config {
    param([Parameter(Mandatory)]$Context, [switch]$ThrowOnError)
    $errors = @()
    $cfg = $Context.Config
    if ([int]$cfg.schemaVersion -ne 1) { $errors += "schemaVersion must be 1." }
    if (-not $cfg.hoblwebBaseUrl -or [string]$cfg.hoblwebBaseUrl -notmatch '^https?://') { $errors += 'hoblwebBaseUrl must be an HTTP or HTTPS URL.' }
    if ($cfg.report -and $cfg.report.frequency -and [string]$cfg.report.frequency -ne 'Daily') { $errors += 'Automation V3 currently requires report.frequency = Daily.' }
    if ($cfg.submit -and $cfg.submit.timeoutSec -and [int]$cfg.submit.timeoutSec -lt 1) { $errors += 'submit.timeoutSec must be >= 1.' }
    if ($cfg.submit -and $cfg.submit.maxAttempts -and [int]$cfg.submit.maxAttempts -lt 1) { $errors += 'submit.maxAttempts must be >= 1.' }
    if ($cfg.monitor -and $cfg.monitor.intervalSec -and [int]$cfg.monitor.intervalSec -lt 1) { $errors += 'monitor.intervalSec must be >= 1.' }
    if ($cfg.monitor -and $cfg.monitor.maxHours -and [int]$cfg.monitor.maxHours -lt 1) { $errors += 'monitor.maxHours must be >= 1.' }
    if ($cfg.email -and $cfg.email.enabled -and -not $cfg.email.to) { $errors += 'email.to is required when email is enabled.' }
    if ($cfg.email -and $cfg.email.checkTime -and [string]$cfg.email.checkTime -notmatch '^([01]\d|2[0-3]):[0-5]\d$') { $errors += 'email.checkTime must be HH:MM.' }
    if ($cfg.email -and $cfg.email.sendDate -and [string]$cfg.email.sendDate -notmatch '^\d{4}-\d{2}-\d{2}$') { $errors += 'email.sendDate must be yyyy-MM-dd.' }
    if ($cfg.email -and $cfg.email.sendDate -and [string]$cfg.email.sendTime -notmatch '^([01]\d|2[0-3]):[0-5]\d$') { $errors += 'email.sendTime must be HH:MM when email.sendDate is set.' }
    $jobs = @($cfg.jobs)
    $ids = @{}
    $profiles = @{}
    foreach ($job in $jobs) {
        if (-not $job.id) { $errors += "A job is missing 'id'."; continue }
        $id = Get-HoblV3SafeId ([string]$job.id)
        if ($id -ne [string]$job.id) { $errors += "Job id '$($job.id)' is not path/task safe; use '$id'." }
        if ($ids.ContainsKey($id)) { $errors += "Duplicate job id '$id'." } else { $ids[$id] = $true }
        if (-not $job.name) { $errors += "Job '$id' is missing 'name'." }
        if (-not $job.profile) { $errors += "Job '$id' is missing 'profile'." }
        elseif ($job.enabled) {
            $profileKey = ([string]$job.profile).ToLowerInvariant()
            if ($profiles.ContainsKey($profileKey)) { $errors += "Enabled jobs '$($profiles[$profileKey])' and '$id' share profile '$($job.profile)'. V3 MVP permits one job per profile." }
            else { $profiles[$profileKey] = $id }
        }
        if (-not $job.testplan) { $errors += "Job '$id' is missing 'testplan'." }
        else {
            $tp = [string]$job.testplan
            if (-not [System.IO.Path]::IsPathRooted($tp)) { $tp = Join-Path $Context.RepoRoot $tp }
            if (-not (Test-Path -LiteralPath $tp -PathType Leaf)) { $errors += "Job '$id' testplan not found: $tp" }
        }
        if (-not $job.runsPerDay -or [int]$job.runsPerDay -lt 1) { $errors += "Job '$id' runsPerDay must be >= 1." }
        $schedule = $job.schedule
        if (-not $schedule) { $errors += "Job '$id' is missing 'schedule'."; continue }
        if ([string]$schedule.frequency -notin @('Once','Daily','Weekly','Monthly')) { $errors += "Job '$id' schedule.frequency must be Once, Daily, Weekly, or Monthly." }
        if ([string]$schedule.time -notmatch '^([01]\d|2[0-3]):[0-5]\d$') { $errors += "Job '$id' schedule.time must be HH:MM." }
        if ([string]$schedule.frequency -eq 'Once' -and [string]$schedule.date -notmatch '^\d{4}-\d{2}-\d{2}$') { $errors += "Job '$id' schedule.date must be yyyy-MM-dd for a Once schedule." }
        if ([string]$schedule.frequency -eq 'Weekly' -and [string]$schedule.dayOfWeek -notin @('Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday')) { $errors += "Job '$id' has an invalid dayOfWeek." }
        if ([string]$schedule.frequency -eq 'Monthly' -and ([int]$schedule.dayOfMonth -lt 1 -or [int]$schedule.dayOfMonth -gt 28)) { $errors += "Job '$id' dayOfMonth must be 1-28." }
    }
    if ($cfg.submit -and $null -ne $cfg.submit.backoffSec) {
        $backoff = @($cfg.submit.backoffSec)
        if ($backoff.Count -eq 0) { $errors += 'submit.backoffSec cannot be empty.' }
        elseif (@($backoff | Where-Object { [int]$_ -lt 0 }).Count -gt 0) { $errors += 'submit.backoffSec values must be >= 0.' }
    }
    if ($ThrowOnError -and $errors.Count -gt 0) { throw ($errors -join [Environment]::NewLine) }
    return $errors
}

function Get-HoblV3Job {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$JobId)
    $matches = @($Context.Config.jobs | Where-Object { [string]$_.id -ieq $JobId })
    if ($matches.Count -ne 1) { throw "Expected exactly one job with id '$JobId'; found $($matches.Count)." }
    return $matches[0]
}

function Get-HoblV3JobPaths {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$JobId)
    $id = Get-HoblV3SafeId $JobId
    $root = Join-Path (Join-Path $Context.RuntimeRoot 'jobs') $id
    [pscustomobject]@{
        Root = $root
        Lock = Join-Path $root 'worker.lock'
        Logs = Join-Path $root 'logs'
        State = Join-Path $root 'state'
        CurrentState = Join-Path (Join-Path $root 'state') 'current.json'
        Runs = Join-Path (Join-Path $root 'state') 'runs'
        Report = Join-Path $root 'report'
    }
}

function Initialize-HoblV3JobPaths {
    param([Parameter(Mandatory)]$Paths)
    foreach ($dir in @($Paths.Root,$Paths.Logs,$Paths.State,$Paths.Runs,$Paths.Report)) {
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    }
}

function Write-HoblV3JsonAtomic {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value, [int]$Depth = 10)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $temp = Join-Path $dir (([System.IO.Path]::GetFileName($Path)) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    $json = $Value | ConvertTo-Json -Depth $Depth
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($temp, $json, $encoding)
    Move-Item -LiteralPath $temp -Destination $Path -Force
}

function Read-HoblV3Json {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Remove-HoblV3ConfigBackups {
    param([Parameter(Mandatory)][string]$ConfigPath)
    $configDirectory = Split-Path -Parent $ConfigPath
    $configFileName = [System.IO.Path]::GetFileName($ConfigPath)
    $backups = @(Get-ChildItem -LiteralPath $configDirectory -File -ErrorAction Stop | Where-Object {
        $_.Name.StartsWith("$configFileName.", [System.StringComparison]::OrdinalIgnoreCase) -and
        $_.Name.EndsWith('.bak', [System.StringComparison]::OrdinalIgnoreCase)
    })
    foreach ($backup in $backups) {
        Remove-Item -LiteralPath $backup.FullName -Force -ErrorAction Stop
    }
    return $backups.Count
}

function Write-HoblV3State {
    param([Parameter(Mandatory)]$Paths, [Parameter(Mandatory)]$State)
    $State.updatedAt = (Get-Date).ToString('o')
    Write-HoblV3JsonAtomic -Path $Paths.CurrentState -Value $State -Depth 12
    if ($State.runId) { Write-HoblV3JsonAtomic -Path (Join-Path $Paths.Runs "$($State.runId).json") -Value $State -Depth 12 }
}

function New-HoblV3Logger {
    param([Parameter(Mandatory)][string]$LogPath)
    $parent = Split-Path -Parent $LogPath
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    return {
        param($Message)
        $line = "{0} {1}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), [string]$Message
        if ($line -match ' ERROR - ') { Write-Host $line -ForegroundColor Red }
        elseif ($line -match ' WARN - ') { Write-Host $line -ForegroundColor Yellow }
        else { Write-Host $line }
        try { Add-Content -LiteralPath $LogPath -Encoding UTF8 -Value $line } catch { }
    }.GetNewClosure()
}

function Get-HoblV3LockStatus {
    param([Parameter(Mandatory)][string]$Path)
    $stream = $null
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::Read)
        return 'Stale'
    } catch [System.IO.FileNotFoundException] {
        return 'Free'
    } catch [System.IO.DirectoryNotFoundException] {
        return 'Free'
    } catch [System.IO.IOException] {
        $code = $_.Exception.HResult -band 0xffff
        if ($code -in @(32,33)) { return 'Held' }
        throw
    } finally {
        if ($stream) { $stream.Dispose() }
    }
}

function Assert-HoblV3RemovalLock {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$JobId)
    $status = Get-HoblV3LockStatus -Path $Path
    if ($status -eq 'Held') { throw "Job '$JobId' has an active worker lock. Wait for it to finish before removal." }
    if ($status -eq 'Stale') { Write-Host "Ignoring stale worker lock for '$JobId': $Path. Saved run state must still permit removal." }
}

function Enter-HoblV3Lock {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$JobId, [Parameter(Mandatory)][string]$RunId)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $stream = $null
    try {
            # Reuse orphaned files atomically; a live holder denies write/delete access.
            $stream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::Read, 4096, [System.IO.FileOptions]::DeleteOnClose)
            $stream.SetLength(0)
            $processStart = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
            $token = [guid]::NewGuid().ToString('N')
            $payload = "$PID|$processStart|$JobId|$RunId|$token"
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
            $stream.Write($bytes,0,$bytes.Length); $stream.Flush()
            return [pscustomobject]@{ Path=$Path; Stream=$stream; RunId=$RunId; Token=$token }
    } catch {
        if ($stream) { $stream.Dispose() }
        if ($_.Exception -is [System.IO.IOException] -and ($_.Exception.HResult -band 0xffff) -in @(32,33)) {
            throw "Job '$JobId' is already running or its lock is in use: $Path"
        }
        throw
    }
}

function Exit-HoblV3Lock {
    param($Lock)
    if ($null -eq $Lock) { return }
    $Lock.Stream.Dispose()
}

function Assert-HoblV3RemovalState {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$JobId, $State)
    if (-not $State -or [string]$State.status -in @('Completed','Failed','Cancelled','NeverStarted')) { return }
    if ([string]$State.status -ne 'BlockedByActivePlan') {
        throw "Job '$JobId' has state '$($State.status)'. Resolve or complete that run before removing its configuration or task."
    }

    $job = Get-HoblV3Job -Context $Context -JobId $JobId
    $planId = [int]$State.headPlanId
    if ($planId -le 0) { throw "Job '$JobId' has no blocking PlanID. Cannot verify that removal is safe." }
    if (-not (Get-Command Get-HoblPlans -ErrorAction SilentlyContinue)) {
        . (Join-Path $Context.RepoRoot 'automation_v2\lib\submit.ps1')
    }
    $timeout = if ($Context.Config.submit.timeoutSec) { [int]$Context.Config.submit.timeoutSec } else { 30 }
    $plans = @(Get-HoblPlans -BaseUrl $Context.Config.hoblwebBaseUrl -TimeoutSec $timeout)
    $blocking = @($plans | Where-Object { [int]$_.PlanID -eq $planId -and [string]$_.Profile -ieq [string]$job.profile })
    $terminal = @('Complete','Completed','Errored','Error','Failed','Terminated','Cancelled','Canceled','Stopped','Aborted')
    if ($blocking.Count -ne 1 -or [string]$blocking[0].State -notin $terminal) {
        throw "Job '$JobId': blocking plan $planId is not confirmed finished in HOBLweb. Removal was refused."
    }
    $active = @($plans | Where-Object {
        [string]$_.Profile -ieq [string]$job.profile -and [string]$_.State -notin $terminal
    })
    if ($active.Count -gt 0) {
        throw "Job '$JobId' still has active/pending or unrecognized HOBLweb plan state(s). Wait for them to finish before removal."
    }
}

function Get-HoblV3TaskName {
    param([Parameter(Mandatory)][string]$JobId)
    return "HOBL Automation V3 - $(Get-HoblV3SafeId $JobId)"
}
