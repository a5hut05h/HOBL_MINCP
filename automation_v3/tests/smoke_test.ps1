# Non-destructive Automation V3 smoke tests. No HOBLweb plan or email is created.
$ErrorActionPreference='Stop'
$v3Root=Split-Path -Parent $PSScriptRoot
$repoRoot=Split-Path -Parent $v3Root
. (Join-Path $v3Root 'lib\common.ps1')
$tempRoot=Join-Path $env:TEMP ('hobl-v3-smoke-'+[guid]::NewGuid().ToString('N'))
$tempConfig=Join-Path $v3Root ('.smoke-'+[guid]::NewGuid().ToString('N')+'.json')
try {
    $source=Get-Content -LiteralPath (Join-Path $v3Root 'automation.config.json') -Raw -Encoding UTF8|ConvertFrom-Json
    $source.runtimeRoot=$tempRoot
    $source.email.enabled=$false
    $jobs=@($source.jobs|Select-Object -First 1)
    if($jobs.Count -eq 0) {
        New-Item -ItemType Directory -Path $tempRoot -Force|Out-Null
        $tempTestplan=Join-Path $tempRoot 'smoke-testplan.ps1'
        Set-Content -LiteralPath $tempTestplan -Encoding UTF8 -Value '# Smoke-test placeholder'
        $jobs=@([pscustomobject]@{
            id='smoke-job'
            name='Smoke Job'
            profile='smoke-profile'
            testplan=$tempTestplan
            runsPerDay=1
            enabled=$true
            schedule=[pscustomobject]@{frequency='Daily';time='00:00'}
        })
    } else {
        $jobs[0].enabled=$true
    }
    $source.jobs=$jobs
    Write-HoblV3JsonAtomic -Path $tempConfig -Value $source -Depth 12
    $context=Get-HoblV3Config -ConfigPath $tempConfig
    Test-HoblV3Config -Context $context -ThrowOnError|Out-Null

    # Exclusive lock must reject a second holder and cleanly release.
    $paths=Get-HoblV3JobPaths -Context $context -JobId $source.jobs[0].id
    Initialize-HoblV3JobPaths -Paths $paths
    $first=Enter-HoblV3Lock -Path $paths.Lock -JobId $source.jobs[0].id -RunId 'smoke-1'
    $rejected=$false
    try{$null=Enter-HoblV3Lock -Path $paths.Lock -JobId $source.jobs[0].id -RunId 'smoke-2'}catch{$rejected=$true}
    if(-not $rejected){throw 'Second lock holder was not rejected.'}
    Exit-HoblV3Lock $first
    if(Test-Path $paths.Lock){throw 'Worker lock was not removed by its owner.'}

    # Seed one terminal run and isolated ledger, then build a combined report.
    $today=(Get-Date).Date
    $state=[pscustomobject]@{schemaVersion=1;jobId=[string]$source.jobs[0].id;jobName=[string]$source.jobs[0].name;runId='smoke-run';status='Completed';createdAt=$today.ToString('o');updatedAt=(Get-Date).ToString('o');logicalRunDate=$today.ToString('yyyy-MM-dd');pid=0;profile=[string]$source.jobs[0].profile;testplan=[string]$source.jobs[0].testplan;planName='smoke-plan';headPlanId=999999;lastPlanId=999999;runsExpected=1;currentScenario='smoke';completed=$true;dryRun=$false;error='';exitCode=0;logPath=''}
    Write-HoblV3State -Paths $paths -State $state
    $v2Lib=Join-Path $repoRoot 'automation_v2\lib'
    . (Join-Path $v2Lib 'report.ps1')
    Add-HoblReportEntry -ReportDir $paths.Report -Date $today -Frequency Daily -Entry @{type='plan';recordedAt=(Get-Date).ToString('o');profile=$state.profile;job=$state.jobName;jobId=$state.jobId;runId=$state.runId;planId=999999;planName='smoke-plan';studyType='Power';runsPerDay=1}|Out-Null
    Add-HoblReportEntry -ReportDir $paths.Report -Date $today -Frequency Daily -Entry @{type='scenario';recordedAt=(Get-Date).ToString('o');profile=$state.profile;job=$state.jobName;jobId=$state.jobId;runId=$state.runId;planId=999999;scenarioId=1;cycle=1;cycleTotal=1;scenario='smoke';status='PASS';startTime=$today.ToString('o');isPrep=$false;source='smoke'}|Out-Null
    & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $v3Root 'coordinator.ps1') -ConfigPath $tempConfig -Date $today.ToString('yyyy-MM-dd')
    if($LASTEXITCODE -ne 0){throw "Coordinator exited $LASTEXITCODE."}
    $combined=Join-Path $tempRoot ('coordinator\reports\daily\daily_report_'+$today.ToString('yyyy-MM-dd')+'.html')
    if(-not(Test-Path $combined)){throw "Combined report was not created: $combined"}
    $combinedLedger=[System.IO.Path]::ChangeExtension($combined,'.jsonl')
    $combinedEntries=@(Get-Content -LiteralPath $combinedLedger|Where-Object{$_.Trim()})
    if($combinedEntries.Count -ne 2){throw "Expected 2 combined ledger entries, found $($combinedEntries.Count)."}
    $pending=Join-Path $tempRoot 'coordinator\reports\pending_email'
    if((Test-Path $pending) -and @(Get-ChildItem $pending -File).Count -gt 0){throw 'Smoke test unexpectedly queued email.'}
    Write-Host 'Automation V3 smoke tests passed.' -ForegroundColor Green
} finally {
    Remove-Item -LiteralPath $tempConfig -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
