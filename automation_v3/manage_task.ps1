param(
    [Parameter(Mandatory)][ValidateSet('Start','Enable','Disable','Remove')][string]$Action,
    [Parameter(Mandatory)][string]$JobId,
    [string]$ConfigPath=''
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'lib\common.ps1')
try {
    $context=Get-HoblV3Config -ConfigPath $ConfigPath
    $null=Get-HoblV3Job -Context $context -JobId $JobId
    $taskName=Get-HoblV3TaskName $JobId
    switch($Action){
        'Start' { Start-ScheduledTask -TaskName $taskName }
        'Enable' { Enable-ScheduledTask -TaskName $taskName|Out-Null }
        'Disable' { Disable-ScheduledTask -TaskName $taskName|Out-Null }
        'Remove' {
            $task=Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
            if($task.State -eq 'Running'){throw "Task '$taskName' is running. It was not removed; active workers are never stopped automatically."}
            $paths=Get-HoblV3JobPaths -Context $context -JobId $JobId
            Assert-HoblV3RemovalLock -Path $paths.Lock -JobId $JobId
            $state=Read-HoblV3Json -Path $paths.CurrentState
            Assert-HoblV3RemovalState -Context $context -JobId $JobId -State $state
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        }
    }
    Write-Host "$Action completed for $taskName" -ForegroundColor Green
} catch { Write-Host " ERROR - $($_.Exception.Message)" -ForegroundColor Red; Exit 1 }
