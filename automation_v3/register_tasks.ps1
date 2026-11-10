# Register or update independent Automation V3 scheduled tasks.
param([string]$ConfigPath='', [string[]]$JobId=@(), [switch]$All, [switch]$CoordinatorOnly, [switch]$WhatIf)
[Console]::OutputEncoding=[Text.Encoding]::UTF8
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'lib\common.ps1')

function New-V3Trigger($Schedule) {
    switch([string]$Schedule.frequency) {
        'Once' {
            $runAt=[datetime]::ParseExact("$($Schedule.date) $($Schedule.time)",'yyyy-MM-dd HH:mm',[Globalization.CultureInfo]::InvariantCulture)
            if($runAt -le (Get-Date)){throw "One-time schedule must be in the future: $runAt"}
            New-ScheduledTaskTrigger -Once -At $runAt
        }
        'Daily' { New-ScheduledTaskTrigger -Daily -At ([string]$Schedule.time) }
        'Weekly' { New-ScheduledTaskTrigger -Weekly -DaysOfWeek ([string]$Schedule.dayOfWeek) -At ([string]$Schedule.time) }
        default { throw 'Monthly triggers are created through schtasks.exe.' }
    }
}
function New-V3Settings {
    New-ScheduledTaskSettingsSet -WakeToRun -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 0)
}
function Assert-Admin {
    $admin=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if(-not $admin){throw 'Run this script from an elevated Administrator PowerShell.'}
}

try {
    $context=Get-HoblV3Config -ConfigPath $ConfigPath
    Test-HoblV3Config -Context $context -ThrowOnError|Out-Null
    if(-not $WhatIf){Assert-Admin}
    if(-not $All -and -not $CoordinatorOnly -and $JobId.Count -eq 0){throw 'Specify -JobId <id>, -All, or -CoordinatorOnly.'}
    if($JobId.Count -gt 0){
        $known=@($context.Config.jobs|ForEach-Object{[string]$_.id})
        $unknown=@($JobId|Where-Object{$known -inotcontains $_})
        if($unknown.Count -gt 0){throw "Unknown job id(s): $($unknown -join ', ')"}
    }
    $selected=if($CoordinatorOnly){@()}elseif($All){@($context.Config.jobs|Where-Object{$_.enabled})}else{@($context.Config.jobs|Where-Object{($JobId -icontains [string]$_.id) -and $_.enabled})}
    if(-not $CoordinatorOnly -and $selected.Count -eq 0){throw 'No matching enabled jobs were selected.'}
    $worker=Join-Path $PSScriptRoot 'worker.ps1'
    $settings=New-V3Settings
    foreach($job in $selected){
        $taskName=Get-HoblV3TaskName $job.id
        $args="-ExecutionPolicy Bypass -NoProfile -File `"$worker`" -JobId `"$($job.id)`" -ConfigPath `"$($context.ConfigPath)`""
        Write-Host "Register $taskName ($($job.schedule.frequency) $($job.schedule.time))"
        if($WhatIf){continue}
        $existing=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if($existing -and $existing.State -eq 'Running'){throw "Task '$taskName' is running and was not changed."}
        if([string]$job.schedule.frequency -eq 'Monthly'){
            $tr="powershell.exe $args"
            if($tr.Length -gt 250){throw "Monthly action for '$taskName' is too long for schtasks.exe ($($tr.Length) characters). Shorten the repository/config path."}
            & schtasks.exe /create /tn $taskName /tr $tr /sc MONTHLY /mo 1 /d ([int]$job.schedule.dayOfMonth) /st ([string]$job.schedule.time) /ru SYSTEM /rl HIGHEST /f|Out-Null
            if($LASTEXITCODE -ne 0){throw "schtasks failed to register '$taskName' (exit $LASTEXITCODE)."}
            Set-ScheduledTask -TaskName $taskName -Settings $settings|Out-Null
        }else{
            $action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $args
            $trigger=New-V3Trigger $job.schedule
            Register-ScheduledTask -TaskName $taskName -Description "HOBL Automation V3 independent worker for job $($job.id)." -Action $action -Trigger $trigger -Settings $settings -User SYSTEM -RunLevel Highest -Force|Out-Null
        }
    }

    # Coordinator runs as SYSTEM and is also started by each worker on completion.
    $coordName=if($context.Config.email.coordinatorTaskName){[string]$context.Config.email.coordinatorTaskName}else{'HOBL Automation V3 - Coordinator'}
    $coord=Join-Path $PSScriptRoot 'coordinator.ps1'
    $checkTime=if($context.Config.email.sendTime){[string]$context.Config.email.sendTime}elseif($context.Config.email.checkTime){[string]$context.Config.email.checkTime}else{'23:30'}
    $sendDate=if($context.Config.email.sendDate){[string]$context.Config.email.sendDate}else{''}
    $existingCoordinator=Get-ScheduledTask -TaskName $coordName -ErrorAction SilentlyContinue
    if($sendDate){Write-Host "Register $coordName (one-time combined report $sendDate $checkTime)"}else{Write-Host "Register $coordName (daily check $checkTime)"}
    if(-not $WhatIf){
        if($existingCoordinator -and $existingCoordinator.State -eq 'Running'){throw "Coordinator task '$coordName' is running and cannot be updated now."}
        $coordArgs="-ExecutionPolicy Bypass -NoProfile -File `"$coord`" -ConfigPath `"$($context.ConfigPath)`""
        if($sendDate){
            $sendAt=[datetime]::ParseExact("$sendDate $checkTime",'yyyy-MM-dd HH:mm',[Globalization.CultureInfo]::InvariantCulture)
            if($sendAt -le (Get-Date)){throw "Coordinator send date/time must be in the future: $sendAt"}
            $coordArgs += " -Date `"$sendDate`""
            $coordTrigger=New-ScheduledTaskTrigger -Once -At $sendAt
        }else{$coordTrigger=New-ScheduledTaskTrigger -Daily -At $checkTime}
        Register-ScheduledTask -TaskName $coordName -Description 'Builds one V3 combined report at the configured delivery date and time.' -Action (New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $coordArgs) -Trigger $coordTrigger -Settings $settings -User SYSTEM -RunLevel Highest -Force|Out-Null
    }
    Write-Host 'V3 task registration complete.' -ForegroundColor Green
} catch { Write-Host " ERROR - $($_.Exception.Message)" -ForegroundColor Red; Exit 1 }
