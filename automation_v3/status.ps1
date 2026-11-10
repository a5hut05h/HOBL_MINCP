param([string]$ConfigPath='')
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'lib\common.ps1')
try {
    $context=Get-HoblV3Config -ConfigPath $ConfigPath
    $rows=foreach($job in @($context.Config.jobs)){
        $paths=Get-HoblV3JobPaths -Context $context -JobId $job.id
        $state=Read-HoblV3Json -Path $paths.CurrentState
        $taskName=Get-HoblV3TaskName $job.id
        $task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        $info=if($task){Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue}else{$null}
        [pscustomobject]@{
            JobId=$job.id; Profile=$job.profile; Enabled=[bool]$job.enabled
            Task=if($task){[string]$task.State}else{'NotRegistered'}
            NextRun=if($info){$info.NextRunTime}else{$null}; LastTaskResult=if($info){$info.LastTaskResult}else{$null}
            RunStatus=if($state){$state.status}else{'NeverRun'}; HeadPlanID=if($state){$state.headPlanId}else{$null}; PlanID=if($state){$state.lastPlanId}else{$null}
            Scenario=if($state){$state.currentScenario}else{''}; Updated=if($state){$state.updatedAt}else{$null}
            Lock=Get-HoblV3LockStatus -Path $paths.Lock
            Error=if($state){$state.error}else{''}
        }
    }
    $rows|Format-Table JobId,Profile,Enabled,Task,Lock,RunStatus,HeadPlanID,PlanID,Scenario,NextRun,LastTaskResult -AutoSize
    $problems=@($rows|Where-Object{$_.Error});if($problems.Count){Write-Host "`nErrors:" -ForegroundColor Yellow;$problems|Select-Object JobId,Error|Format-Table -Wrap -AutoSize}

    $coordRoot=Join-Path $context.RuntimeRoot 'coordinator'
    $coordTaskName=if($context.Config.email.coordinatorTaskName){[string]$context.Config.email.coordinatorTaskName}else{'HOBL Automation V3 - Coordinator'}
    $emailTaskName=if($context.Config.email.taskName){[string]$context.Config.email.taskName}else{'HOBL Automation V3 - Report Email'}
    Write-Host "`nServices:"
    $services=foreach($name in @($coordTaskName,$emailTaskName)){
        $task=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
        $info=if($task){Get-ScheduledTaskInfo -TaskName $name -ErrorAction SilentlyContinue}else{$null}
        [pscustomobject]@{Task=$name;State=if($task){[string]$task.State}else{'NotRegistered'};LastResult=if($info){$info.LastTaskResult}else{$null};NextRun=if($info){$info.NextRunTime}else{$null}}
    }
    $services|Format-Table -AutoSize
    $pendingDir=Join-Path (Join-Path $coordRoot 'reports') 'pending_email'
    $pending=@(Get-ChildItem -LiteralPath $pendingDir -Filter '*.json' -File -ErrorAction SilentlyContinue)
    $bad=@(Get-ChildItem -LiteralPath $pendingDir -Filter '*.bad' -File -ErrorAction SilentlyContinue)
    Write-Host "Email outbox: pending=$($pending.Count) bad=$($bad.Count) path=$pendingDir"
} catch { Write-Host " ERROR - $($_.Exception.Message)" -ForegroundColor Red; Exit 1 }
