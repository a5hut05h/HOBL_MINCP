# Isolated removal-state tests; no tasks, configurations, or HOBLweb plans are changed.
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\common.ps1')
$context = [pscustomobject]@{
    Config = [pscustomobject]@{
        hoblwebBaseUrl = 'http://localhost'
        submit = [pscustomobject]@{ timeoutSec = 30 }
        jobs = @([pscustomobject]@{ id = 'test-job'; profile = 'test-dut' })
    }
}
$state = [pscustomobject]@{ status = 'BlockedByActivePlan'; headPlanId = 52475 }
$script:plans = @()
$script:failRequest = $false
function Get-HoblPlans {
    param($BaseUrl, $TimeoutSec)
    if ($script:failRequest) { throw 'HOBLweb unavailable' }
    return $script:plans
}
function Assert-RemovalOutcome {
    param([bool]$Allowed, [string]$Name)
    $rejected = $false
    try { Assert-HoblV3RemovalState -Context $context -JobId 'test-job' -State $state }
    catch { $rejected = $true }
    if ($rejected -eq $Allowed) { throw "Unexpected removal outcome: $Name" }
}
foreach ($status in @('Complete','Completed','Failed','Terminated','Cancelled','Stopped','Aborted')) {
    $script:plans = @([pscustomobject]@{ PlanID = 52475; Profile = 'test-dut'; State = $status })
    Assert-RemovalOutcome -Allowed $true -Name "Finished blocker: $status"
}
foreach ($status in @('Active','Pending','Terminating','Unknown','')) {
    $script:plans = @([pscustomobject]@{ PlanID = 52475; Profile = 'test-dut'; State = $status })
    Assert-RemovalOutcome -Allowed $false -Name "Unfinished blocker: $status"
}
$script:plans = @()
Assert-RemovalOutcome -Allowed $false -Name 'Missing blocker'
$script:plans = @([pscustomobject]@{ PlanID = 52475; Profile = 'other-dut'; State = 'Complete' })
Assert-RemovalOutcome -Allowed $false -Name 'Wrong profile'
$script:plans = @(
    [pscustomobject]@{ PlanID = 52475; Profile = 'test-dut'; State = 'Complete' },
    [pscustomobject]@{ PlanID = 52476; Profile = 'test-dut'; State = 'Active' }
)
Assert-RemovalOutcome -Allowed $false -Name 'Another active plan'
$script:failRequest = $true
Assert-RemovalOutcome -Allowed $false -Name 'Dashboard unavailable'
$script:failRequest = $false
$state.headPlanId = 0
Assert-RemovalOutcome -Allowed $false -Name 'Missing plan ID'
$state.status = 'Running'
Assert-RemovalOutcome -Allowed $false -Name 'Running worker state'
foreach ($status in @('Completed','Failed','Cancelled','NeverStarted')) {
    $state.status = $status
    Assert-RemovalOutcome -Allowed $true -Name "Existing terminal state: $status"
}
Write-Host 'Removal-state tests passed.'
