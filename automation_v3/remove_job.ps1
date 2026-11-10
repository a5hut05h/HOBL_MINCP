# Safely remove one V3 job configuration and scheduled task while preserving runtime history.
param(
    [Parameter(Mandatory)][string]$JobId,
    [string]$ConfigPath=''
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'lib\common.ps1')
try {
    $context=Get-HoblV3Config -ConfigPath $ConfigPath
    $null=Get-HoblV3Job -Context $context -JobId $JobId
    $taskName=Get-HoblV3TaskName $JobId
    $task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if($task -and $task.State -eq 'Running'){throw "Task '$taskName' is running. Active workers are never stopped automatically."}
    $paths=Get-HoblV3JobPaths -Context $context -JobId $JobId
    Assert-HoblV3RemovalLock -Path $paths.Lock -JobId $JobId
    $state=Read-HoblV3Json -Path $paths.CurrentState
    Assert-HoblV3RemovalState -Context $context -JobId $JobId -State $state
    $remaining=@($context.Config.jobs|Where-Object{[string]$_.id -ine $JobId})
    $orphanTasks=@()
    if($remaining.Count -eq 0){
        $coordinatorTaskName=if($context.Config.email.coordinatorTaskName){[string]$context.Config.email.coordinatorTaskName}else{'HOBL Automation V3 - Coordinator'}
        $emailTaskName=if($context.Config.email.taskName){[string]$context.Config.email.taskName}else{'HOBL Automation V3 - Report Email'}
        foreach($orphanTaskName in @($coordinatorTaskName,$emailTaskName)){
            $orphanTask=Get-ScheduledTask -TaskName $orphanTaskName -ErrorAction SilentlyContinue
            if($orphanTask -and $orphanTask.State -eq 'Running'){throw "Task '$orphanTaskName' is running. Stop it before deleting the final configuration."}
            if($orphanTask){$orphanTasks+=$orphanTaskName}
        }
    }
    if($task){Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop}
    foreach($orphanTaskName in $orphanTasks){Unregister-ScheduledTask -TaskName $orphanTaskName -Confirm:$false -ErrorAction Stop}
    $context.Config.jobs=$remaining
    Test-HoblV3Config -Context $context -ThrowOnError|Out-Null
    Write-HoblV3JsonAtomic -Path $context.ConfigPath -Value $context.Config -Depth 12
    $removedBackupCount=Remove-HoblV3ConfigBackups -ConfigPath $context.ConfigPath
    Write-Host "Deleted job configuration '$JobId'. Runtime history was retained at $($paths.Root)." -ForegroundColor Green
    Write-Host "Removed $removedBackupCount legacy configuration backup(s)."
} catch {
    Write-Host " ERROR - $($_.Exception.Message)" -ForegroundColor Red
    Exit 1
}
