# Automation V3 worker: executes and monitors exactly one configured job.
param(
    [Parameter(Mandatory)][string]$JobId,
    [string]$ConfigPath = '',
    [switch]$DryRun,
    [switch]$Resume
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\common.ps1')

$context = $null; $job = $null; $paths = $null; $logger = $null; $lock = $null; $state = $null
$runId = (Get-Date).ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8)
$runStart = Get-Date
$exitCode = 1

try {
    $context = Get-HoblV3Config -ConfigPath $ConfigPath
    Test-HoblV3Config -Context $context -ThrowOnError | Out-Null
    $job = Get-HoblV3Job -Context $context -JobId $JobId
    if (-not [bool]$job.enabled) { throw "Job '$JobId' is disabled." }

    $paths = Get-HoblV3JobPaths -Context $context -JobId $job.id
    Initialize-HoblV3JobPaths -Paths $paths
    $previousState = Read-HoblV3Json -Path $paths.CurrentState
    $logPath = Join-Path $paths.Logs ("{0}-{1}.log" -f (Get-Date).ToString('yyyyMMdd'),$runId)
    $logger = New-HoblV3Logger -LogPath $logPath
    & $logger "=== V3 worker start job=$($job.id) run=$runId profile=$($job.profile) dryRun=$([bool]$DryRun) ==="

    $cfg = $context.Config
    $baseUrl = if ($cfg.hoblwebBaseUrl) { [string]$cfg.hoblwebBaseUrl } else { 'http://localhost' }
    $submitTimeout = if ($cfg.submit.timeoutSec) { [int]$cfg.submit.timeoutSec } else { 30 }
    $submitMax = if ($cfg.submit.maxAttempts) { [int]$cfg.submit.maxAttempts } else { 5 }
    $submitBackoff = if ($cfg.submit.backoffSec) { @($cfg.submit.backoffSec | ForEach-Object { [int]$_ }) } else { @(5,15,60,180,600) }
    $monitorEnabled = if ($cfg.monitor -and $null -ne $cfg.monitor.enabled) { [bool]$cfg.monitor.enabled } else { $true }
    $monitorInterval = if ($cfg.monitor.intervalSec) { [int]$cfg.monitor.intervalSec } else { 45 }
    $monitorMaxHours = if ($cfg.monitor.maxHours) { [int]$cfg.monitor.maxHours } else { 8 }
    $reportEnabled = if ($cfg.report -and $null -ne $cfg.report.enabled) { [bool]$cfg.report.enabled } else { $true }
    $reportFrequency = if ($cfg.report.frequency) { [string]$cfg.report.frequency } else { 'Daily' }

    $v2Lib = Join-Path $context.RepoRoot 'automation_v2\lib'
    . (Join-Path $v2Lib 'submit.ps1')
    . (Join-Path $v2Lib 'monitor.ps1')
    . (Join-Path $v2Lib 'testplan.ps1')
    . (Join-Path $v2Lib 'report.ps1')
    $reportFrequency = Get-HoblReportFrequency $reportFrequency

    $testplanPath = [string]$job.testplan
    if (-not [System.IO.Path]::IsPathRooted($testplanPath)) { $testplanPath = Join-Path $context.RepoRoot $testplanPath }
    $parsed = ConvertFrom-HoblTestplan -Path $testplanPath
    $rows = @($parsed.Rows)
    $profileInfo = Assert-HoblV3ScenariosAvailable -HoblDut ([string]$job.profile) -Rows $rows
    $basePlanName = if ($job.planName) { [string]$job.planName } else { [string]$parsed.PlanName }
    $studyType = if ($job.studyType) { [string]$job.studyType } else { [string]$parsed.StudyType }
    & $logger "Parsed testplan=$testplanPath planName=$basePlanName studyType=$studyType rows=$($rows.Count) hoblRuntime=$($profileInfo.HoblPath)"

    if ($DryRun) {
        Set-HoblAutoResubmit -PlanRows $rows -Resubmits ([int]$job.runsPerDay - 1)
        & $logger "DryRun valid; no HOBLweb plan was submitted and authoritative job state was not changed."
        $exitCode=0
    } else {
        $lock = Enter-HoblV3Lock -Path $paths.Lock -JobId $job.id -RunId $runId
        $recoverableStatuses = @('Recovering','Submitting','SubmissionUnknown','Submitted','Monitoring','TimedOut')
        $recovering = ($previousState -and [string]$previousState.status -in $recoverableStatuses)
        $logicalRunDate = $runStart.Date
        if ($recovering -and $previousState.logicalRunDate) {
            $parsedDate = [datetime]::MinValue
            if ([datetime]::TryParse([string]$previousState.logicalRunDate,[ref]$parsedDate)) { $logicalRunDate = $parsedDate.Date }
        }
        $stateRunId=$runId; $stateStatus='Validating'; $stateCreatedAt=$runStart.ToString('o')
        $recoveryFromStatus=''; $statePlanName=''; $stateHeadPlanId=0; $stateLastPlanId=0
        $stateSubmissionBaseline=0; $stateCurrentScenario=''
        if($recovering){
            $stateRunId=[string]$previousState.runId
            $stateStatus='Recovering'
            $stateCreatedAt=[string]$previousState.createdAt
            $recoveryFromStatus=[string]$previousState.status
            if($previousState.recoveryFromStatus){$recoveryFromStatus=[string]$previousState.recoveryFromStatus}
            $statePlanName=[string]$previousState.planName
            $stateHeadPlanId=[int]$previousState.headPlanId
            $stateLastPlanId=[int]$previousState.lastPlanId
            if($previousState.submissionBaseline){$stateSubmissionBaseline=[int]$previousState.submissionBaseline}
            $stateCurrentScenario=[string]$previousState.currentScenario
        }
        $state = [pscustomobject][ordered]@{
            schemaVersion = 1
            jobId = [string]$job.id
            jobName = [string]$job.name
            runId = $stateRunId
            status = $stateStatus
            createdAt = $stateCreatedAt
            updatedAt = $runStart.ToString('o')
            pid = $PID
            recoveryFromStatus = $recoveryFromStatus
            logicalRunDate = $logicalRunDate.ToString('yyyy-MM-dd')
            profile = [string]$job.profile
            testplan = [string]$job.testplan
            planName = $statePlanName
            headPlanId = $stateHeadPlanId
            lastPlanId = $stateLastPlanId
            submissionBaseline = $stateSubmissionBaseline
            runsExpected = [int]$job.runsPerDay
            currentScenario = $stateCurrentScenario
            completed = $false
            dryRun = $false
            error = ''
            exitCode = $null
            logPath = $logPath
        }
        Write-HoblV3State -Paths $paths -State $state

        try {
            $probe = Invoke-WebRequest -Uri "$($baseUrl.TrimEnd('/'))/plan/Plans" -UseBasicParsing -TimeoutSec 10
            if ($probe.StatusCode -lt 200 -or $probe.StatusCode -ge 500) { throw "HTTP $($probe.StatusCode)" }
        } catch { throw ("HOBLweb is not reachable at {0}: {1}" -f $baseUrl,$_.Exception.Message) }

        try {
            $pokeInfo = Get-ScheduledTaskInfo -TaskName 'HOBLweb Poke' -ErrorAction Stop
            if ($pokeInfo.LastTaskResult -ne 0) { & $logger " WARN - HOBLweb Poke last result is $($pokeInfo.LastTaskResult), expected 0." }
        } catch { throw "Required scheduled task 'HOBLweb Poke' is unavailable." }

        $allPlans = @(Get-HoblPlans -BaseUrl $baseUrl -TimeoutSec $submitTimeout)
        $previous = $previousState
        $tracker = $null

        # Resume a saved nonterminal plan instead of submitting a duplicate.
        if (($Resume -or $recovering) -and $previous -and [int]$previous.headPlanId -gt 0) {
            $savedPlan = $allPlans | Where-Object { [int]$_.PlanID -eq [int]$previous.headPlanId } | Select-Object -First 1
            if ($savedPlan -and [string]$savedPlan.Profile -eq [string]$job.profile) {
                $state.headPlanId=[int]$previous.headPlanId; $state.planName=[string]$previous.planName
                $tracker = [pscustomobject]@{ Name=[string]$job.name; Profile=[string]$job.profile; PlanName=[string]$previous.planName; HeadPlanID=[int]$previous.headPlanId; RunsPerDay=[int]$job.runsPerDay; LastPlanID=0; LastState=''; LastRow=''; Done=$false; Completed=$false }
                & $logger "Resuming monitoring for saved PlanID=$($previous.headPlanId)."
            }
        }

        # Reconcile a create request whose response may have been lost. Never
        # blindly submit again when the previous process died during Create.
        if (-not $tracker -and $recovering -and $previous -and ([string]$previous.status -in @('Recovering','Submitting','SubmissionUnknown')) -and $previous.planName -and [int]$previous.headPlanId -eq 0) {
            $reconciled = $allPlans | Where-Object {
                [string]$_.Profile -eq [string]$job.profile -and [string]$_.PlanName -eq [string]$previous.planName -and [int]$_.PlanID -gt [int]$previous.submissionBaseline
            } | Sort-Object { [int]$_.PlanID } -Descending | Select-Object -First 1
            if ($reconciled) {
                $state.headPlanId=[int]$reconciled.PlanID; $state.lastPlanId=[int]$reconciled.PlanID; $state.planName=[string]$previous.planName
                $tracker=[pscustomobject]@{Name=[string]$job.name;Profile=[string]$job.profile;PlanName=[string]$previous.planName;HeadPlanID=[int]$reconciled.PlanID;RunsPerDay=[int]$job.runsPerDay;LastPlanID=0;LastState='';LastRow='';Done=$false;Completed=$false}
                & $logger "Reconciled interrupted submission to PlanID=$($reconciled.PlanID)."
            } else {
                $state.status='SubmissionUnknown';$state.error='A previous create request may have reached HOBLweb, but no correlated PlanID was found. Manual reconciliation is required before resubmission.';$state.exitCode=2
                Write-HoblV3State -Paths $paths -State $state
                & $logger " ERROR - $($state.error)"
                $exitCode=2
            }
        }

        if (-not $tracker -and $state.status -ne 'SubmissionUnknown') {
            $busy = @($allPlans | Where-Object { [string]$_.Profile -eq [string]$job.profile -and [string]$_.State -in @('Active','Pending') })
            if ($busy.Count -gt 0) {
                $ids = ($busy | ForEach-Object { $_.PlanID }) -join ','
                $state.headPlanId=[int](($busy|Sort-Object{[int]$_.PlanID}-Descending|Select-Object -First 1).PlanID)
                $state.lastPlanId=$state.headPlanId
                $state.status='BlockedByActivePlan'; $state.error="Profile already has active/pending plan(s): $ids"; $state.exitCode=0
                Write-HoblV3State -Paths $paths -State $state
                & $logger " WARN - $($state.error). No duplicate submitted."
                $exitCode=0
            } else {
                $planName = $basePlanName
                Set-HoblAutoResubmit -PlanRows $rows -Resubmits ([int]$job.runsPerDay - 1)
                $maxKnownId=0; foreach($p in $allPlans){ if([int]$p.PlanID -gt $maxKnownId){$maxKnownId=[int]$p.PlanID} }
                $state.status='Submitting';$state.planName=$planName;$state.submissionBaseline=$maxKnownId;Write-HoblV3State -Paths $paths -State $state
                $newPlan=$null
                for($attempt=1;$attempt -le $submitMax -and -not $newPlan;$attempt++){
                    $submitError=$null
                    try { $null=Submit-HoblPlan -BaseUrl $baseUrl -Profile $job.profile -PlanName $planName -PlanRows $rows -StudyType $studyType -TimeoutSec $submitTimeout }
                    catch { $submitError=$_ }
                    # Whether Create returned or threw, reconcile by the unique
                    # correlated name before considering another POST.
                    for($lookup=1;$lookup -le 5 -and -not $newPlan;$lookup++){
                        Start-Sleep -Seconds 1
                        try {
                            $after=@(Get-HoblPlans -BaseUrl $baseUrl -TimeoutSec $submitTimeout)
                            $newPlan=$after|Where-Object{[string]$_.Profile -eq [string]$job.profile -and [string]$_.PlanName -eq $planName -and [int]$_.PlanID -gt $maxKnownId}|Sort-Object{[int]$_.PlanID}-Descending|Select-Object -First 1
                        } catch { if($lookup -eq 5 -and -not $submitError){$submitError=$_} }
                    }
                    if($newPlan){break}
                    $httpStatus=if($submitError -and $submitError.Exception.Response){[int]$submitError.Exception.Response.StatusCode}else{0}
                    if($httpStatus -ge 400 -and $httpStatus -lt 500){throw $submitError}
                    if($attempt -ge $submitMax){
                        $state.status='SubmissionUnknown';$state.error="Create could not be reconciled after $attempt attempt(s). Plan name: $planName";$state.exitCode=2
                        Write-HoblV3State -Paths $paths -State $state
                        throw $state.error
                    }
                    $wait=$submitBackoff[[Math]::Min($attempt-1,$submitBackoff.Count-1)]
                    & $logger " WARN - Create attempt $attempt was not found after reconciliation; waiting ${wait}s before retry."
                    if($wait -gt 0){Start-Sleep -Seconds $wait}
                }
                if (-not $newPlan) { throw "Submission succeeded but the new PlanID could not be identified." }
                $state.status='Submitted'; $state.headPlanId=[int]$newPlan.PlanID; $state.lastPlanId=[int]$newPlan.PlanID
                Write-HoblV3State -Paths $paths -State $state
                & $logger "Submitted PlanID=$($newPlan.PlanID) state=$($newPlan.State)."
                if ($reportEnabled) {
                    Add-HoblReportEntry -ReportDir $paths.Report -Frequency $reportFrequency -Date $logicalRunDate -Entry @{type='plan';recordedAt=(Get-Date).ToString('o');profile=$job.profile;job=$job.name;jobId=$job.id;runId=$state.runId;planId=[int]$newPlan.PlanID;planName=$planName;studyType=$studyType;runsPerDay=[int]$job.runsPerDay}|Out-Null
                }
                $tracker=[pscustomobject]@{Name=[string]$job.name;Profile=[string]$job.profile;PlanName=$planName;HeadPlanID=[int]$newPlan.PlanID;RunsPerDay=[int]$job.runsPerDay;LastPlanID=0;LastState='';LastRow='';Done=$false;Completed=$false}
            }
        }

        if ($tracker) {
            if ($monitorEnabled) {
                $state.status='Monitoring'; Write-HoblV3State -Paths $paths -State $state
                $onResult=$null
                if($reportEnabled){
                    $onResult={param($entry)
                        $entry.jobId=[string]$job.id; $entry.runId=$state.runId
                        Add-HoblReportEntry -ReportDir $paths.Report -Frequency $reportFrequency -Date $logicalRunDate -Entry $entry|Out-Null
                        $state.currentScenario=[string]$entry.scenario; $state.lastPlanId=[int]$entry.planId
                        Write-HoblV3State -Paths $paths -State $state
                    }.GetNewClosure()
                }
                Invoke-HoblMonitor -Jobs @($tracker) -BaseUrl $baseUrl -IntervalSec $monitorInterval -MaxHours $monitorMaxHours -TimeoutSec $submitTimeout -Log $logger -OnResult $onResult
                if($reportEnabled){
                    Invoke-HoblReportBackfill -ReportDir $paths.Report -BaseUrl $baseUrl -Date $logicalRunDate -Frequency $reportFrequency -TimeoutSec $submitTimeout -Log $logger|Out-Null
                }
                $state.lastPlanId=[int]$tracker.LastPlanID
                if($tracker.Completed){$state.status='Completed';$state.completed=$true;$state.exitCode=0;$exitCode=0}
                elseif($tracker.Done){$state.status='Failed';$state.error="Plan chain stopped before completing all cycles.";$state.exitCode=2;$exitCode=2}
                else{$state.status='TimedOut';$state.error="Monitoring detached after $monitorMaxHours hour(s); the HOBLweb plan may still be running.";$state.exitCode=2;$exitCode=2}
                Write-HoblV3State -Paths $paths -State $state
                if($reportEnabled){Write-HoblReportHtml -ReportDir $paths.Report -Frequency $reportFrequency -Date $logicalRunDate|Out-Null}
            } else {
                $state.status='Submitted';$state.exitCode=0;Write-HoblV3State -Paths $paths -State $state;$exitCode=0
            }
        }
    }
} catch {
    if ($logger) { & $logger " ERROR - $($_.Exception.Message)" } else { Write-Host " ERROR - $($_.Exception.Message)" -ForegroundColor Red }
    if ($state -and $paths) {
        if ($state.status -ne 'SubmissionUnknown') {
            $state.status='Failed';$state.completed=$false;$state.error=$_.Exception.Message;$state.exitCode=1
        }
        try { Write-HoblV3State -Paths $paths -State $state } catch { }
    }
    if ($state -and $state.status -eq 'SubmissionUnknown') { $exitCode=2 } else { $exitCode=1 }
} finally {
    if ($lock) { Exit-HoblV3Lock -Lock $lock }
    if ($logger) { & $logger "=== V3 worker end job=$JobId run=$runId exit=$exitCode ===" }
    # Evaluate the immutable logical run date, including runs that cross midnight.
    if (-not $DryRun -and $context -and $state -and $state.logicalRunDate) {
        try {
            $coordinator = Join-Path $PSScriptRoot 'coordinator.ps1'
            & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $coordinator -ConfigPath $context.ConfigPath -Date ([string]$state.logicalRunDate)
        } catch {
            if ($logger) { & $logger " WARN - Could not invoke report coordinator: $($_.Exception.Message)" }
        }
    }
}
Exit $exitCode
