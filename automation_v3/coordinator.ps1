# Build and queue exactly one combined daily report after all expected jobs are terminal.
param([string]$ConfigPath='', [datetime]$Date=(Get-Date))
[Console]::OutputEncoding=[Text.Encoding]::UTF8
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'lib\common.ps1')
$lock=$null

function Test-V3JobDue($Job,[datetime]$Day) {
    if(-not [bool]$Job.enabled){return $false}
    switch([string]$Job.schedule.frequency){
        'Once'{return ([string]$Job.schedule.date -eq $Day.ToString('yyyy-MM-dd'))}
        'Weekly'{return ([string]$Job.schedule.dayOfWeek -eq $Day.DayOfWeek.ToString())}
        'Monthly'{return ([int]$Job.schedule.dayOfMonth -eq $Day.Day)}
        default{return $true}
    }
}

function Get-V3RunForDate($Paths,[datetime]$Day) {
    $candidates=@()
    $current=Read-HoblV3Json -Path $Paths.CurrentState
    if($current){$candidates += $current}
    if(Test-Path $Paths.Runs){
        foreach($file in @(Get-ChildItem -LiteralPath $Paths.Runs -Filter '*.json' -File -ErrorAction SilentlyContinue)){
            $item=Read-HoblV3Json -Path $file.FullName
            if($item){$candidates += $item}
        }
    }
    return $candidates|Where-Object{[string]$_.logicalRunDate -eq $Day.ToString('yyyy-MM-dd')}|Sort-Object{[datetime]$_.updatedAt}-Descending|Select-Object -First 1
}

function Write-V3EmailMarkerAtomic($ReportDir,$TargetDate,$Recipients,$Incomplete,$Note) {
    $pending=Join-Path $ReportDir 'pending_email'
    if(-not(Test-Path $pending)){New-Item -ItemType Directory -Path $pending -Force|Out-Null}
    $id='v3-Daily-'+$TargetDate.ToString('yyyy-MM-dd')
    $path=Join-Path $pending "$id.json"
    $marker=[ordered]@{runId=$id;createdAt=(Get-Date).ToString('o');reportDir=$ReportDir;frequency='Daily';date=$TargetDate.ToString('o');recipients=$Recipients;incomplete=[bool]$Incomplete;note=$Note}
    Write-HoblV3JsonAtomic -Path $path -Value $marker -Depth 5
    return $path
}

try {
    $Date=$Date.Date
    $context=Get-HoblV3Config -ConfigPath $ConfigPath
    Test-HoblV3Config -Context $context -ThrowOnError|Out-Null
    if($context.Config.email -and [bool]$context.Config.email.enabled -and $context.Config.email.sendDate){
        $targetDate=[datetime]::ParseExact([string]$context.Config.email.sendDate,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture).Date
        $targetTime=if($context.Config.email.sendTime){[string]$context.Config.email.sendTime}else{[string]$context.Config.email.checkTime}
        $timeParts=$targetTime.Split(':');$sendAt=$targetDate.AddHours([int]$timeParts[0]).AddMinutes([int]$timeParts[1])
        if($Date -ne $targetDate){Exit 0}
        if((Get-Date) -lt $sendAt){Exit 0}
    }
    $coordRoot=Join-Path $context.RuntimeRoot 'coordinator'
    foreach($d in @($coordRoot,(Join-Path $coordRoot 'state'),(Join-Path $coordRoot 'reports'),(Join-Path $coordRoot 'logs'))){if(-not(Test-Path $d)){New-Item -ItemType Directory -Path $d -Force|Out-Null}}
    $log=New-HoblV3Logger -LogPath (Join-Path (Join-Path $coordRoot 'logs') ("{0}.log" -f $Date.ToString('yyyyMMdd')))
    $lock=Enter-HoblV3Lock -Path (Join-Path $coordRoot 'coordinator.lock') -JobId 'coordinator' -RunId $Date.ToString('yyyy-MM-dd')
    $periodKey='Daily-'+$Date.ToString('yyyy-MM-dd')
    $coordStatePath=Join-Path (Join-Path $coordRoot 'state') "$periodKey.json"
    $coordState=Read-HoblV3Json -Path $coordStatePath
    if($coordState -and $coordState.emailQueued){&$log "Coordinator: $periodKey already queued; no duplicate created.";Exit 0}

    $expected=@($context.Config.jobs|Where-Object{Test-V3JobDue $_ $Date})
    if($expected.Count -eq 0){&$log "Coordinator: no enabled jobs were due on $($Date.ToString('yyyy-MM-dd')); no report or email created.";Exit 0}

    $v2Lib=Join-Path $context.RepoRoot 'automation_v2\lib'
    . (Join-Path $v2Lib 'submit.ps1')
    . (Join-Path $v2Lib 'report.ps1')
    . (Join-Path $v2Lib 'email.ps1')
    $baseUrl=if($context.Config.hoblwebBaseUrl){[string]$context.Config.hoblwebBaseUrl}else{'http://localhost'}
    $timeout=if($context.Config.submit.timeoutSec){[int]$context.Config.submit.timeoutSec}else{30}
    $plans=@()
    try{$plans=@(Get-HoblPlans -BaseUrl $baseUrl -TimeoutSec $timeout)}catch{&$log " WARN - Coordinator cannot verify HOBLweb plans: $($_.Exception.Message)";Exit 0}

    $checkTime=if($context.Config.email.sendTime){[string]$context.Config.email.sendTime}elseif($context.Config.email.checkTime){[string]$context.Config.email.checkTime}else{'23:30'}
    $parts=$checkTime.Split(':');$cutoff=$Date.AddHours([int]$parts[0]).AddMinutes([int]$parts[1])
    $pastCutoff=((Get-Date) -ge $cutoff -or (Get-Date).Date -gt $Date)
    $pending=@();$jobStates=@{}
    foreach($job in $expected){
        $jp=Get-HoblV3JobPaths -Context $context -JobId $job.id
        $s=Get-V3RunForDate -Paths $jp -Day $Date
        if(-not $s){
            if($pastCutoff){$jobStates[[string]$job.id]=[pscustomobject]@{status='NeverStarted';error='No worker run was recorded before the reporting cutoff.'}}
            else{$pending += [string]$job.id}
            continue
        }
        $status=[string]$s.status
        if($status -in @('Completed','Failed','Cancelled')){$jobStates[[string]$job.id]=$s;continue}
        if($pastCutoff){$jobStates[[string]$job.id]=$s;continue}
        if($status -in @('TimedOut','BlockedByActivePlan','SubmissionUnknown')){
            $related=@()
            if([int]$s.headPlanId -gt 0){$related=@($plans|Where-Object{[int]$_.PlanID -ge [int]$s.headPlanId -and [string]$_.Profile -eq [string]$job.profile -and (-not $s.planName -or [string]$_.PlanName -eq [string]$s.planName)})}
            else{$related=@($plans|Where-Object{[string]$_.Profile -eq [string]$job.profile -and [string]$_.State -in @('Active','Pending')})}
            $active=@($related|Where-Object{[string]$_.State -in @('Active','Pending')})
            if($active.Count -gt 0){$pending += [string]$job.id}
            elseif($pastCutoff -or $related.Count -gt 0){$jobStates[[string]$job.id]=$s}
            else{$pending += [string]$job.id}
            continue
        }
        $pending += [string]$job.id
    }
    if($pending.Count -gt 0){&$log "Coordinator waiting: $($pending.Count) expected job(s) are not terminal: $($pending -join ', ').";Exit 0}

    $reportRoot=Join-Path $coordRoot 'reports'
    $combinedPaths=Get-HoblReportPaths -ReportDir $reportRoot -Date $Date -Frequency Daily
    if(-not(Test-Path $combinedPaths.Dir)){New-Item -ItemType Directory -Path $combinedPaths.Dir -Force|Out-Null}
    $entries=@{}
    foreach($job in $expected){
        $jp=Get-HoblV3JobPaths -Context $context -JobId $job.id
        $source=Get-HoblReportPaths -ReportDir $jp.Report -Date $Date -Frequency Daily
        $ledgerEntries=Read-HoblReportLedger -Path $source.Ledger
        foreach($entry in $ledgerEntries){
            $key=if([string]$entry.type -eq 'scenario'){"scenario|$($entry.planId)|$($entry.scenarioId)"}else{"plan|$($entry.planId)"}
            $entries[$key]=$entry
        }
    }
    $temp=$combinedPaths.Ledger+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    $encoding=New-Object Text.UTF8Encoding($false)
    $writer=New-Object IO.StreamWriter($temp,$false,$encoding)
    try{foreach($entry in $entries.Values){$writer.WriteLine(($entry|ConvertTo-Json -Depth 8 -Compress))}}finally{$writer.Dispose()}
    Move-Item -LiteralPath $temp -Destination $combinedPaths.Ledger -Force
    $html=Write-HoblReportHtml -ReportDir $reportRoot -Date $Date -Frequency Daily
    & $log "Combined report generated from $($expected.Count) job(s), entries=$($entries.Count): $html"

    $incompleteJobs=@($expected|Where-Object{[string]$jobStates[[string]$_.id].status -ne 'Completed'})
    $incomplete=($incompleteJobs.Count -gt 0)
    $note=if($incomplete){"$($incompleteJobs.Count) expected job(s) did not complete cleanly: $(($incompleteJobs.id)-join ', ')."}else{''}
    $queued=$false
    if($context.Config.email -and [bool]$context.Config.email.enabled){
        $to=[string]$context.Config.email.to
        if(-not $to){throw 'email.enabled is true but email.to is empty.'}
        $marker=Write-V3EmailMarkerAtomic -ReportDir $reportRoot -TargetDate $Date -Recipients $to -Incomplete $incomplete -Note $note
        $queued=$true;&$log "Queued combined email marker: $marker"
    }
    $newState=[pscustomobject]@{schemaVersion=1;periodKey=$periodKey;date=$Date.ToString('o');expectedJobs=@($expected.id);jobStatus=$jobStates;generatedAt=(Get-Date).ToString('o');reportPath=$html;emailQueued=$queued;incomplete=$incomplete;note=$note}
    Write-HoblV3JsonAtomic -Path $coordStatePath -Value $newState -Depth 12
    if($queued){
        $emailTask=if($context.Config.email.taskName){[string]$context.Config.email.taskName}else{'HOBL Automation V3 - Report Email'}
        try{Start-ScheduledTask -TaskName $emailTask -ErrorAction Stop;&$log "Started email task '$emailTask'."}
        catch{&$log " WARN - Could not start email task '$emailTask': $($_.Exception.Message). Marker retained."}
    }
} catch {Write-Host " ERROR - $($_.Exception.Message)" -ForegroundColor Red;Exit 1}
finally {if($lock){Exit-HoblV3Lock $lock}}
