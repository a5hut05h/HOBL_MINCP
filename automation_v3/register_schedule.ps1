# V2-style interactive registration for independent Automation V3 DUT jobs.
param(
    [string]$ConfigPath='',
    [switch]$WhatIf
)
[Console]::OutputEncoding=[Text.Encoding]::UTF8
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'lib\common.ps1')

function Read-YesNo([string]$Prompt,[bool]$Default=$true) {
    $suffix=if($Default){'[Y]'}else{'[N]'}
    while($true){$value=Read-Host "$Prompt (Y/N) $suffix";if(-not $value){return $Default};if($value -match '^[Yy]'){return $true};if($value -match '^[Nn]'){return $false};Write-Host ' ERROR - Enter Y or N.' -ForegroundColor Red}
}
function Read-Required([string]$Prompt) {
    while($true){$value=Read-Host $Prompt;if($value -and $value.Trim()){return $value.Trim()};Write-Host ' ERROR - Value cannot be empty.' -ForegroundColor Red}
}
function Read-Positive([string]$Prompt,[int]$Default=1) {
    while($true){$value=Read-Host "$Prompt [$Default]";if(-not $value){return $Default};if($value -match '^[1-9]\d*$'){return [int]$value};Write-Host ' ERROR - Enter a positive integer.' -ForegroundColor Red}
}
function Read-HHMM([string]$Default) {
    while($true){$value=Read-Host "Trigger time (HH:MM, 24h) [$Default]";if(-not $value){$value=$Default};if($value -match '^([01]\d|2[0-3]):[0-5]\d$'){return $value};Write-Host ' ERROR - Use HH:MM in 24-hour format.' -ForegroundColor Red}
}
function Read-Frequency([string]$Default) {
    while($true){Write-Host '';Write-Host 'How often should the automation run?';Write-Host '  [1] Daily';Write-Host '  [2] Weekly   (default day: Monday)';Write-Host '  [3] Monthly  (default day of month: 1)';$value=Read-Host "Choose 1/2/3 (or Daily/Weekly/Monthly) [$Default]";if(-not $value){return $Default};switch($value.Trim().ToLowerInvariant()){'1'{return 'Daily'}'daily'{return 'Daily'}'2'{return 'Weekly'}'weekly'{return 'Weekly'}'3'{return 'Monthly'}'monthly'{return 'Monthly'}default{Write-Host ' ERROR - Choose 1, 2, or 3.' -ForegroundColor Red}}}
}
function Read-Weekday([string]$Default) {
    $days=@('Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday')
    while($true){$value=Read-Host "Day of week [$Default]";if(-not $value){return $Default};$day=$days|Where-Object{$_ -ieq $value.Trim()}|Select-Object -First 1;if($day){return $day};Write-Host ' ERROR - Enter a weekday name.' -ForegroundColor Red}
}
function Read-MonthDay([int]$Default) {
    while($true){$value=Read-Host "Day of month (1-28) [$Default]";if(-not $value){return $Default};if($value -match '^([1-9]|1\d|2[0-8])$'){return [int]$value};Write-Host ' ERROR - Enter a number from 1 through 28.' -ForegroundColor Red}
}
function Read-Email([string]$Default) {
    while($true){$value=Read-Host "  Recipient [$Default] (Enter or Y to keep)";if(-not $value -or $value -match '^[Yy]$'){return $Default};if($value -match '^[^\s@]+@[^\s@]+\.[^\s@]+$'){return $value.Trim()};Write-Host ' ERROR - Enter a valid email address, or press Enter to keep the current recipient.' -ForegroundColor Red}
}
function Get-TestplanBase([string]$Value) {
    $name=[IO.Path]::GetFileName($Value)
    if(-not $name){$name=$Value}
    return [IO.Path]::GetFileNameWithoutExtension($name)
}

$originalConfig=$null
$configChanged=$false
try {
    $context=Get-HoblV3Config -ConfigPath $ConfigPath
    Test-HoblV3Config -Context $context -ThrowOnError|Out-Null
    $cfg=$context.Config
    $originalConfig=Read-HoblV3Json -Path $context.ConfigPath
    if(-not $WhatIf){
        $admin=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if(-not $admin){throw 'Run this script from an elevated Administrator PowerShell.'}
    }

    $enabledJobs=@($cfg.jobs|Where-Object{$_.enabled})
    $scheduleDefault=if($enabledJobs.Count -gt 0){$enabledJobs[0].schedule}else{[pscustomobject]@{frequency='Daily';time='10:35';dayOfWeek='Monday';dayOfMonth=1}}
    $frequency=Read-Frequency ([string]$scheduleDefault.frequency)
    $time=Read-HHMM ([string]$scheduleDefault.time)
    $dayOfWeek=if($frequency -eq 'Weekly'){Read-Weekday ([string]$scheduleDefault.dayOfWeek)}else{'Monday'}
    $dayOfMonth=if($frequency -eq 'Monthly'){Read-MonthDay ([int]$scheduleDefault.dayOfMonth)}else{1}
    Write-Host '';Write-Host "Schedule: $($frequency.ToLowerInvariant()) at $time" -ForegroundColor Cyan

    $changeConfig=Read-YesNo 'Want to change DUT configuration?' $true
    $oldEnabledIds=@($enabledJobs|ForEach-Object{[string]$_.id})
    $selectedIds=@()
    if($changeConfig){
        $dutCount=Read-Positive 'Number of DUTs' 1
        for($i=1;$i -le $dutCount;$i++){
            Write-Host '';Write-Host "DUT $i of $dutCount" -ForegroundColor Cyan
            $enteredDut=Read-Required '  Profile name (file in C:\profiles without .ini)'
            $profileInfo=Get-HoblV3ProfileInfo -HoblDut $enteredDut
            if($profileInfo.Name -cne $enteredDut){Write-Host "  resolved profile as $($profileInfo.Name)"}
            $testplan=Read-Required '  Testplan name (file in testplans/ without .ps1, e.g. power_workloads)'
            $runs=Read-Positive '  Runs per day' 1
            $testplanBase=Get-TestplanBase $testplan
            $jobId=Get-HoblV3SafeId ("$($profileInfo.Name)-$testplanBase")
            if($selectedIds -icontains $jobId){throw "DUT configuration produced duplicate job ID '$jobId'."}
            $childArgs=@('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'setup_job.ps1'),'-ConfigPath',$context.ConfigPath,'-HoblDut',$profileInfo.Name,'-Testplan',$testplan,'-RunsPerDay',[string]$runs,'-Frequency',$frequency,'-Time',$time,'-DayOfWeek',$dayOfWeek,'-DayOfMonth',[string]$dayOfMonth,'-JobId',$jobId,'-Name',("$($profileInfo.Name)_$testplanBase"),'-UpdateExisting')
            if($i -eq 1){$childArgs+='-DisableOtherJobs'}else{$childArgs+='-KeepOtherJobs'}
            if($WhatIf){$childArgs+='-WhatIf'}else{$childArgs+='-ConfigOnly'}
            & powershell.exe @childArgs
            if($LASTEXITCODE -ne 0){throw "DUT $i configuration failed with exit code $LASTEXITCODE."}
            $selectedIds+=$jobId
            $configChanged=(-not $WhatIf)
            Write-Host "  configured independent job: $jobId" -ForegroundColor Green
        }
    }else{
        if($enabledJobs.Count -eq 0){throw 'No enabled DUT jobs exist. Choose Y and configure at least one DUT.'}
        $selectedIds=@($oldEnabledIds)
        foreach($job in $cfg.jobs|Where-Object{$_.enabled}){$job.schedule=[pscustomobject][ordered]@{frequency=$frequency;time=$time;dayOfWeek=$dayOfWeek;dayOfMonth=$dayOfMonth}}
        Test-HoblV3Config -Context $context -ThrowOnError|Out-Null
        if($WhatIf){Write-Host "WhatIf: would update schedule for: $($selectedIds -join ', ')."}
        else{Write-HoblV3JsonAtomic -Path $context.ConfigPath -Value $cfg -Depth 12;$configChanged=$true;Write-Host 'Leaving DUT jobs unchanged; updated their schedule.'}
    }

    if($WhatIf){
        if($changeConfig){
            Write-Host 'WhatIf: would register independent tasks:'
        }else{
            Write-Host "WhatIf: would register these independent tasks with schedule $frequency $time`:"
        }
        $selectedIds|ForEach-Object{Write-Host "  $(Get-HoblV3TaskName $_)"}
        Write-Host 'WhatIf: would also ensure the shared coordinator task exists.'
        Write-Host 'WhatIf complete; configuration and Task Scheduler were not changed.' -ForegroundColor Green
        Exit 0
    }

    foreach($id in $selectedIds){$task=Get-ScheduledTask -TaskName (Get-HoblV3TaskName $id) -ErrorAction SilentlyContinue;if($task -and $task.State -eq 'Running'){throw "Task '$($task.TaskName)' is running and cannot be re-registered now."}}
    & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'register_tasks.ps1') -ConfigPath $context.ConfigPath -All
    if($LASTEXITCODE -ne 0){throw "Task registration failed with exit code $LASTEXITCODE."}

    $noLongerEnabled=@($oldEnabledIds|Where-Object{$selectedIds -inotcontains $_})
    foreach($id in $noLongerEnabled){$taskName=Get-HoblV3TaskName $id;$task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue;if($task){Disable-ScheduledTask -TaskName $taskName|Out-Null;Write-Host "Disabled future starts for $taskName; a running instance was not stopped."}}

    Write-Host '';Write-Host 'Registered independent V3 DUT task(s):' -ForegroundColor Green
    $selectedIds|ForEach-Object{Write-Host "  $(Get-HoblV3TaskName $_)"}

    if(Read-YesNo 'Also register the combined report email task?' $true){
        $latest=Get-HoblV3Config -ConfigPath $context.ConfigPath
        $recipient=Read-Email ([string]$latest.Config.email.to)
        $latest.Config.email.to=$recipient
        $latest.Config.email.enabled=$true
        Write-HoblV3JsonAtomic -Path $latest.ConfigPath -Value $latest.Config -Depth 12
        & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'send_report_email.ps1') -ConfigPath $latest.ConfigPath -Register
        if($LASTEXITCODE -ne 0){throw "Email task registration failed with exit code $LASTEXITCODE."}
    }

    Write-Host '';Write-Host 'V3 schedule registration complete.' -ForegroundColor Green
} catch {
    $failure=$_.Exception.Message
    if($configChanged -and $originalConfig){
        try{Write-HoblV3JsonAtomic -Path $context.ConfigPath -Value $originalConfig -Depth 12;Write-Host 'Configuration restored after registration failed.' -ForegroundColor Yellow}catch{Write-Host " WARN - Configuration rollback failed: $($_.Exception.Message)" -ForegroundColor Yellow}
    }
    Write-Host " ERROR - $failure" -ForegroundColor Red
    Exit 1
}
