# Interactively add one DUT/job to Automation V3, then register and optionally start it.
param(
    [string]$ConfigPath='',
    [string]$HoblDut='',
    [string]$Testplan='',
    [int]$RunsPerDay=0,
    [ValidateSet('','Daily','Weekly','Monthly')][string]$Frequency='',
    [string]$Time='',
    [string]$DayOfWeek='',
    [int]$DayOfMonth=0,
    [string]$JobId='',
    [string]$Name='',
    [switch]$UpdateExisting,
    [switch]$DisableOtherJobs,
    [switch]$KeepOtherJobs,
    [switch]$StartNow,
    [switch]$ConfigOnly,
    [switch]$WhatIf
)
[Console]::OutputEncoding=[Text.Encoding]::UTF8
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'lib\common.ps1')
$originalConfig=$null
$configWritten=$false
$registrationComplete=$false
$newTaskCreated=$false

function Read-Required([string]$Prompt,[string]$Default='') {
    while($true){$label=if($Default){"$Prompt [$Default]"}else{$Prompt};$value=Read-Host $label;if(-not $value){$value=$Default};if($value -and $value.Trim()){return $value.Trim()};Write-Host ' ERROR - Value cannot be empty.' -ForegroundColor Red}
}
function Read-Positive([string]$Prompt,[int]$Default=1) {
    while($true){$value=Read-Host "$Prompt [$Default]";if(-not $value){return $Default};if($value -match '^[1-9]\d*$'){return [int]$value};Write-Host ' ERROR - Enter a positive integer.' -ForegroundColor Red}
}
function Read-HHMM([string]$Default='10:35') {
    while($true){$value=Read-Host "Start time HH:MM [$Default]";if(-not $value){$value=$Default};if($value -match '^([01]\d|2[0-3]):[0-5]\d$'){return $value};Write-Host ' ERROR - Use HH:MM in 24-hour format.' -ForegroundColor Red}
}
function Read-Cadence([string]$Default='Daily') {
    while($true){Write-Host 'Schedule: [1] Daily  [2] Weekly  [3] Monthly';$value=Read-Host "Choose [$Default]";if(-not $value){return $Default};switch($value.Trim().ToLower()){'1'{return 'Daily'}'daily'{return 'Daily'}'2'{return 'Weekly'}'weekly'{return 'Weekly'}'3'{return 'Monthly'}'monthly'{return 'Monthly'}default{Write-Host ' ERROR - Choose 1-3 or enter a schedule name.' -ForegroundColor Red}}}
}
function Read-Weekday([string]$Default='Monday') {
    $days=@('Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday')
    while($true){$value=Read-Host "Day of week [$Default]";if(-not $value){return $Default};$match=$days|Where-Object{$_ -ieq $value.Trim()}|Select-Object -First 1;if($match){return $match};Write-Host ' ERROR - Enter a weekday name.' -ForegroundColor Red}
}
function Read-MonthDay([int]$Default=1) {
    while($true){$value=Read-Host "Day of month 1-28 [$Default]";if(-not $value){return $Default};if($value -match '^([1-9]|1\d|2[0-8])$'){return [int]$value};Write-Host ' ERROR - Enter 1-28.' -ForegroundColor Red}
}
function Resolve-HoblDut([string]$Value) {
    return (Get-HoblV3ProfileInfo -HoblDut $Value).Name
}

try {
    $context=Get-HoblV3Config -ConfigPath $ConfigPath
    $originalConfig=Read-HoblV3Json -Path $context.ConfigPath
    $cfg=$context.Config
    Write-Host 'HOBL Automation V3 - Add DUT' -ForegroundColor Cyan
    if(-not $HoblDut){$HoblDut=Read-Required 'HOBLweb profile/DUT name'}
    $enteredDut=$HoblDut
    $HoblDut=Resolve-HoblDut $HoblDut
    if($HoblDut -cne $enteredDut){Write-Host "Resolved profile '$enteredDut' as '$HoblDut'." -ForegroundColor Green}
    if(-not $Testplan){$Testplan=Read-Required 'Testplan name or path' 'mincp_only'}
    if($Testplan -notmatch '[\\/]' -and $Testplan -notlike '*.ps1'){$Testplan="testplans/$Testplan.ps1"}
    elseif($Testplan -notmatch '[\\/]' -and $Testplan -like '*.ps1'){$Testplan="testplans/$Testplan"}
    $absoluteTestplan=if([IO.Path]::IsPathRooted($Testplan)){$Testplan}else{Join-Path $context.RepoRoot $Testplan}
    if(-not(Test-Path -LiteralPath $absoluteTestplan -PathType Leaf)){throw "Testplan not found: $absoluteTestplan"}
    . (Join-Path $context.RepoRoot 'automation_v2\lib\testplan.ps1')
    $parsed=ConvertFrom-HoblTestplan -Path $absoluteTestplan
    if(@($parsed.Rows).Count -eq 0){throw "No scenarios were parsed from $absoluteTestplan"}
    $profileInfo=Assert-HoblV3ScenariosAvailable -HoblDut $HoblDut -Rows @($parsed.Rows)
    Write-Host "Validated $(@($parsed.Rows).Count) testplan scenario(s) in $($profileInfo.HoblPath)." -ForegroundColor Green
    if($RunsPerDay -lt 1){$RunsPerDay=Read-Positive 'Runs per execution' 1}
    if(-not $Frequency){$Frequency=Read-Cadence 'Daily'}
    if(-not $Time){$Time=Read-HHMM '10:35'}
    if($Frequency -eq 'Weekly' -and -not $DayOfWeek){$DayOfWeek=Read-Weekday 'Monday'}
    if($Frequency -eq 'Monthly' -and $DayOfMonth -lt 1){$DayOfMonth=Read-MonthDay 1}
    if(-not $DayOfWeek){$DayOfWeek='Monday'}
    if($DayOfMonth -lt 1){$DayOfMonth=1}
    if(-not $Time){$Time='00:00'}

    $testplanBase=[IO.Path]::GetFileNameWithoutExtension($absoluteTestplan)
    $suggestedId=Get-HoblV3SafeId ("$HoblDut-$testplanBase")
    if(-not $JobId){$JobId=Read-Required 'Stable job ID' $suggestedId}
    $JobId=Get-HoblV3SafeId $JobId
    if(-not $Name){$Name="${HoblDut}_${testplanBase}"}
    $existingById=@($cfg.jobs|Where-Object{[string]$_.id -ieq $JobId})
    if($existingById.Count -gt 1){throw "Job ID '$JobId' occurs more than once in configuration."}
    $isUpdate=($existingById.Count -eq 1)
    if($isUpdate -and -not $UpdateExisting){
        $answer=Read-Host "Job ID '$JobId' already exists. Update and re-register this job? (Y/N) [Y]"
        if($answer -match '^[Nn]'){throw "Existing job '$JobId' was not changed."}
    }
    $previouslyEnabledIds=@($cfg.jobs|Where-Object{$_.enabled -and [string]$_.id -ine $JobId}|ForEach-Object{[string]$_.id})
    if($isUpdate){$cfg.jobs=@($cfg.jobs|Where-Object{[string]$_.id -ine $JobId})}

    if($DisableOtherJobs -and $KeepOtherJobs){throw 'Use either -DisableOtherJobs or -KeepOtherJobs, not both.'}
    if(-not $PSBoundParameters.ContainsKey('DisableOtherJobs') -and -not $KeepOtherJobs -and $previouslyEnabledIds.Count -gt 0){
        Write-Host "Currently enabled DUT job(s): $($previouslyEnabledIds -join ', ')"
        $choice=Read-Host 'Keep these existing DUT jobs scheduled alongside the new DUT? Y=keep running, N=disable future runs [Y]'
        if($choice -match '^[Nn]'){$DisableOtherJobs=$true}
    }
    if($DisableOtherJobs){foreach($old in @($cfg.jobs)){$old.enabled=$false}}
    $existingProfile=@($cfg.jobs|Where-Object{$_.enabled -and [string]$_.profile -ieq $HoblDut})
    if($existingProfile.Count -gt 0){throw "Enabled job '$($existingProfile[0].id)' already uses profile '$HoblDut'. Choose another profile or disable that job."}

    $storedTestplan=$absoluteTestplan
    if($absoluteTestplan.StartsWith($context.RepoRoot,[StringComparison]::OrdinalIgnoreCase)){$storedTestplan=$absoluteTestplan.Substring($context.RepoRoot.Length).TrimStart('\','/').Replace('\','/')}
    $job=[pscustomobject][ordered]@{
        id=$JobId;name=$Name;enabled=$true;profile=$HoblDut;testplan=$storedTestplan;runsPerDay=$RunsPerDay
        schedule=[pscustomobject][ordered]@{frequency=$Frequency;time=$Time;dayOfWeek=$DayOfWeek;dayOfMonth=$DayOfMonth}
    }
    $cfg.jobs=@($cfg.jobs)+$job
    Test-HoblV3Config -Context $context -ThrowOnError|Out-Null
    if($WhatIf){
        $verb=if($isUpdate){'update and re-register'}else{'add and register'}
        Write-Host "WhatIf: would $verb '$JobId' (profile=$HoblDut, testplan=$storedTestplan, runs=$RunsPerDay, schedule=$Frequency $Time)." -ForegroundColor Cyan
        if($DisableOtherJobs -and $previouslyEnabledIds.Count -gt 0){Write-Host "WhatIf: would disable configured jobs and task triggers: $($previouslyEnabledIds -join ', ')."}
        Write-Host 'WhatIf: configuration and Task Scheduler were not changed.'
        Exit 0
    }
    Write-HoblV3JsonAtomic -Path $context.ConfigPath -Value $cfg -Depth 12
    $configWritten=$true
    $updated=Get-HoblV3Config -ConfigPath $context.ConfigPath
    Test-HoblV3Config -Context $updated -ThrowOnError|Out-Null
    $savedVerb=if($isUpdate){'Updated'}else{'Added'}
    Write-Host "$savedVerb job '$JobId' (profile=$HoblDut, testplan=$storedTestplan, runs=$RunsPerDay)." -ForegroundColor Green

    if($ConfigOnly){Write-Host 'ConfigOnly selected; scheduled task was not registered.';Exit 0}
    $admin=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if(-not $admin){Write-Host " WARN - Job was saved, but task registration requires Administrator PowerShell." -ForegroundColor Yellow;Exit 0}
    $newTaskName=Get-HoblV3TaskName $JobId
    $taskExistedBefore=[bool](Get-ScheduledTask -TaskName $newTaskName -ErrorAction SilentlyContinue)
    if($taskExistedBefore -and -not $isUpdate){throw "Task '$newTaskName' already exists without a matching configured job. Resolve or remove that orphan task first."}
    & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'register_tasks.ps1') -ConfigPath $context.ConfigPath -JobId $JobId
    $registrationExitCode=$LASTEXITCODE
    $newTaskCreated=(-not $taskExistedBefore) -and [bool](Get-ScheduledTask -TaskName $newTaskName -ErrorAction SilentlyContinue)
    if($registrationExitCode -ne 0){throw "Task registration failed with exit code $registrationExitCode."}
    $registrationComplete=$true
    if($DisableOtherJobs){
        foreach($oldId in $previouslyEnabledIds){
            $oldTaskName=Get-HoblV3TaskName $oldId
            $oldTask=Get-ScheduledTask -TaskName $oldTaskName -ErrorAction SilentlyContinue
            if($oldTask){
                try{Disable-ScheduledTask -TaskName $oldTaskName|Out-Null;Write-Host "Disabled future starts for $oldTaskName. A running instance, if any, was not stopped."}
                catch{Write-Host " WARN - Could not disable task '$oldTaskName': $($_.Exception.Message)" -ForegroundColor Yellow}
            }
        }
    }
    if(-not $PSBoundParameters.ContainsKey('StartNow')){$answer=Read-Host 'Start this DUT now? (Y/N) [N]';if($answer -match '^[Yy]'){$StartNow=$true}}
    if($StartNow){& powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'manage_task.ps1') -ConfigPath $context.ConfigPath -Action Start -JobId $JobId;if($LASTEXITCODE -ne 0){throw "Starting task failed with exit code $LASTEXITCODE."}}
} catch {
    $failure=$_.Exception.Message
    if($configWritten -and -not $registrationComplete -and $originalConfig){
        try{Write-HoblV3JsonAtomic -Path $context.ConfigPath -Value $originalConfig -Depth 12;Write-Host 'Configuration restored after task registration failed.' -ForegroundColor Yellow}
        catch{Write-Host " WARN - Configuration rollback failed: $($_.Exception.Message)" -ForegroundColor Yellow}
    }
    if($newTaskCreated -and -not $registrationComplete){
        try{$task=Get-ScheduledTask -TaskName $newTaskName -ErrorAction SilentlyContinue;if($task -and $task.State -ne 'Running'){Unregister-ScheduledTask -TaskName $newTaskName -Confirm:$false}}
        catch{Write-Host " WARN - Partial task cleanup failed: $($_.Exception.Message)" -ForegroundColor Yellow}
    }
    Write-Host " ERROR - $failure" -ForegroundColor Red
    Exit 1
}
