# Drain V3 combined-report email markers through Outlook COM.
param([string]$ConfigPath='', [switch]$Register, [string]$TaskName='')
[Console]::OutputEncoding=[Text.Encoding]::UTF8
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'lib\common.ps1')
$drainLock=$null
try {
    $context=Get-HoblV3Config -ConfigPath $ConfigPath
    if(-not $TaskName){$TaskName=if($context.Config.email.taskName){[string]$context.Config.email.taskName}else{'HOBL Automation V3 - Report Email'}}
    if($Register){
        $self=Join-Path $PSScriptRoot 'send_report_email.ps1'
        $args="-ExecutionPolicy Bypass -NoProfile -File `"$self`" -ConfigPath `"$($context.ConfigPath)`""
        $user=[Security.Principal.WindowsIdentity]::GetCurrent().Name
        $principal=New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
        $trigger=New-ScheduledTaskTrigger -AtLogOn -User $user
        $settings=New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 1)
        Register-ScheduledTask -TaskName $TaskName -Description 'Sends Automation V3 combined reports through the interactive user Outlook profile.' -Action (New-ScheduledTaskAction -Execute powershell.exe -Argument $args) -Trigger $trigger -Principal $principal -Settings $settings -Force|Out-Null
        Write-Host "Registered '$TaskName' for interactive user $user." -ForegroundColor Green;Exit 0
    }
    $reportRoot=Join-Path (Join-Path $context.RuntimeRoot 'coordinator') 'reports'
    $v2Lib=Join-Path $context.RepoRoot 'automation_v2\lib'
    . (Join-Path $v2Lib 'report.ps1');. (Join-Path $v2Lib 'email.ps1')
    $logger={param($s)if("$s"-match ' ERROR - '){Write-Host $s -ForegroundColor Red}elseif("$s"-match ' WARN - '){Write-Host $s -ForegroundColor Yellow}else{Write-Host $s}}
    $drainLock=Enter-HoblV3Lock -Path (Join-Path (Join-Path $context.RuntimeRoot 'coordinator') 'email-drain.lock') -JobId 'email-drain' -RunId ([guid]::NewGuid().ToString('N'))
    $result=Invoke-HoblEmailDrain -ReportDir $reportRoot -Log $logger
    Write-Host "V3 email drain complete: sent=$($result.Sent) kept=$($result.Kept) bad=$($result.Bad)"
    if($result.Kept -gt 0 -or $result.Bad -gt 0){Exit 1}
} catch {Write-Host " ERROR - $($_.Exception.Message)" -ForegroundColor Red;Exit 1}
finally {if($drainLock){Exit-HoblV3Lock $drainLock}}
