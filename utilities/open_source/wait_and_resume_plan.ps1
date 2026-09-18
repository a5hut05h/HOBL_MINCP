# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

# Wait for server to respond with 302, then resume plan
param(
    [Parameter(Mandatory=$true)]
    [string]$PlanID,
    
    [string]$ServerUrl = "http://localhost",
    [int]$PollIntervalSeconds = 5,
    [int]$TimeoutMinutes = 30,
    
    [switch]$SetScenarioPending,
    [string]$ScenarioID
)

$pokeUrl = "$ServerUrl/plan/Poke"
$resumeUrl = "$ServerUrl/plan/ResumePlan?PlanIDs=$PlanID"

Write-Host "Waiting for server at $pokeUrl to respond with 302..."

$startTime = Get-Date
$timeout = New-TimeSpan -Minutes $TimeoutMinutes

$exitcode = 0

while ($true) {
    try {
        $response = Invoke-WebRequest -Uri $pokeUrl -MaximumRedirection 0 -UseBasicParsing -ErrorAction SilentlyContinue
        $statusCode = $response.StatusCode
    }
    catch {
        # Invoke-WebRequest throws on 3xx redirects, check the exception
        if ($_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }
        else {
            $statusCode = 0
        }
    }
    
    Write-Host "$(Get-Date -Format 'HH:mm:ss') - Status: $statusCode"
    
    if ($statusCode -eq 302) {
        Write-Host "Server responded with 302, resuming plan..."
        break
    }
    
    # Check timeout
    if ((Get-Date) - $startTime -gt $timeout) {
        Write-Host " ERROR - Timeout reached after $TimeoutMinutes minutes"
        exit 1
    }
    
    Start-Sleep -Seconds $PollIntervalSeconds
}


# Set scenario to pending if flag is set
if ($SetScenarioPending) {
    if (-not $ScenarioID) {
        Write-Host " ERROR - ScenarioID is required when using -SetScenarioPending"
        $exitcode = 1
    }
    Write-Host "Setting scenario $ScenarioID to pending..."
    $pendingUrl = "$ServerUrl/plan/Update"
    $body = @{
        PlanID     = $PlanID
        ScenarioID = $ScenarioID
    }

    # Send State request
    $body["State"] = "Pending"
    try {
        $response = Invoke-WebRequest -Uri $pendingUrl -Method Post -Body $body -UseBasicParsing -ErrorAction Stop
        Write-Host "Set scenario State=Pending response: $($response.StatusCode)"
    }
    catch {
        Write-Host " ERROR - Failed to set State to pending: $_"
    }

    # Send Status request
    $body.Remove("State")
    $body["Status"] = "PENDING"
    try {
        $response = Invoke-WebRequest -Uri $pendingUrl -Method Post -Body $body -UseBasicParsing -ErrorAction Stop
        Write-Host "Set scenario Status=PENDING response: $($response.StatusCode)"
    }
    catch {
        Write-Host " ERROR - Failed to set scenario Status to PENDING: $_"
    }
}

# Send resume command
try {
    $response = Invoke-WebRequest -Uri $resumeUrl -MaximumRedirection 0 -UseBasicParsing -ErrorAction SilentlyContinue
    Write-Host "Resume plan response: $($response.StatusCode)"
}
catch {
    if ($_.Exception.Response) {
        Write-Host "Resume plan response: $([int]$_.Exception.Response.StatusCode)"
    }
    else {
        Write-Host " ERROR - Failed to resume plan: $_"
        $exitcode = 1
    }
}

Start-Process "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe" -ArgumentList "--app=`"http://localhost:80/plan/Scenarios?PlanID=$PlanID`"", "-start-maximized"

Write-Host "Plan $PlanID resumed successfully"
exit $exitcode
