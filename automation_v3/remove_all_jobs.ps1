# Safely remove all V3 job configurations and scheduled tasks while preserving runtime history.
param([string]$ConfigPath='')
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'lib\common.ps1')

try {
    $context=Get-HoblV3Config -ConfigPath $ConfigPath
    $jobs=@($context.Config.jobs)
    if($jobs.Count -eq 0){
        $removedBackupCount=Remove-HoblV3ConfigBackups -ConfigPath $context.ConfigPath
        Write-Host "No DUT configurations exist. Removed $removedBackupCount legacy configuration backup(s)."
        Exit 0
    }

    $workerTasks=@()
    foreach($job in $jobs){
        $jobId=[string]$job.id
        $taskName=Get-HoblV3TaskName $jobId
        $task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if($task -and $task.State -eq 'Running'){throw "DUT '$($job.profile)' is running. Wait for it to finish before deleting all configurations."}
        if($task){$workerTasks+=$taskName}

        $paths=Get-HoblV3JobPaths -Context $context -JobId $jobId
        Assert-HoblV3RemovalLock -Path $paths.Lock -JobId $jobId
        $state=Read-HoblV3Json -Path $paths.CurrentState
        Assert-HoblV3RemovalState -Context $context -JobId $jobId -State $state
    }

    $relatedTasks=@()
    $coordinatorTaskName=if($context.Config.email.coordinatorTaskName){[string]$context.Config.email.coordinatorTaskName}else{'HOBL Automation V3 - Coordinator'}
    $emailTaskName=if($context.Config.email.taskName){[string]$context.Config.email.taskName}else{'HOBL Automation V3 - Report Email'}
    foreach($taskName in @($coordinatorTaskName,$emailTaskName)){
        $task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if($task -and $task.State -eq 'Running'){throw "Task '$taskName' is running. Wait for it to finish before deleting all configurations."}
        if($task){$relatedTasks+=$taskName}
    }

    foreach($taskName in @($workerTasks)+@($relatedTasks)){Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop}
    $context.Config.jobs=@()
    Test-HoblV3Config -Context $context -ThrowOnError|Out-Null
    Write-HoblV3JsonAtomic -Path $context.ConfigPath -Value $context.Config -Depth 12
    $removedBackupCount=Remove-HoblV3ConfigBackups -ConfigPath $context.ConfigPath
    Write-Host "Deleted all $($jobs.Count) DUT configuration(s). Runtime logs and reports were retained." -ForegroundColor Green
    Write-Host "Removed $removedBackupCount legacy configuration backup(s)."
} catch {
    Write-Host " ERROR - $($_.Exception.Message)" -ForegroundColor Red
    Exit 1
}
