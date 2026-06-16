# HOBL automation v2 — HOBLweb submit helpers.
#
# Dot-sourced by daily_run.ps1. Encapsulates everything we know about HOBLweb's
# plan API so the orchestrator stays small.
#
# HOBLweb API surface used here (reverse-engineered from its UI):
#   POST /plan/PlanData         body: draw/start/length DataTables fields
#                               returns: array of all plans (PlanID, State, Profile, AutoResubmit, ...)
#   POST /plan/Create           Content-Type: application/json
#                               body: { profile, planName, planRows, studyType }
#                               creates a NEW plan (new PlanID) from the supplied content
#   GET  /plan/ScenariosData?PlanID=<n>
#                               returns: per-row live Status (used by monitor)
#   GET  /plan/Poke             advances HOBLweb's internal queue (heartbeat)
#
#   POST /plan/PlanContentByID  body: PlanID=<n>&FailedOnly=false
#                               returns: scenario rows for an existing plan.
#                               v2 does NOT use this in the daily flow (rows are
#                               built from the testplan .ps1 file in git).
#                               Retained because tools\dump_plan.ps1 uses it
#                               to capture a real plan body for schema
#                               verification.

function Get-HoblPlans {
    param(
        [Parameter(Mandatory)] [string] $BaseUrl,
        [int] $TimeoutSec = 30
    )
    $url = "$($BaseUrl.TrimEnd('/'))/plan/PlanData"
    $r = Invoke-WebRequest -Uri $url -Method Post -UseBasicParsing -TimeoutSec $TimeoutSec `
            -Body @{ draw = 1; start = 0; length = 500 }
    return ($r.Content | ConvertFrom-Json)
}

function Get-HoblPlanContent {
    param(
        [Parameter(Mandatory)] [string] $BaseUrl,
        [Parameter(Mandatory)] [int]    $PlanID,
        [int] $TimeoutSec = 30
    )
    $url = "$($BaseUrl.TrimEnd('/'))/plan/PlanContentByID"
    $r = Invoke-WebRequest -Uri $url -Method Post -UseBasicParsing -TimeoutSec $TimeoutSec `
            -Body @{ PlanID = $PlanID; FailedOnly = 'false' }
    return ($r.Content | ConvertFrom-Json)
}

# Per-row runtime status for a plan. Unlike PlanContentByID (which only returns
# the static template), this endpoint exposes Status (PASS/RUNNING/PENDING/FAIL)
# and StartTime per scenario. Used by the monitor to report live progress.
function Get-HoblScenariosData {
    param(
        [Parameter(Mandatory)] [string] $BaseUrl,
        [Parameter(Mandatory)] [int]    $PlanID,
        [int] $TimeoutSec = 30
    )
    $url = "$($BaseUrl.TrimEnd('/'))/plan/ScenariosData?PlanID=$PlanID"
    $r   = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec $TimeoutSec
    return ($r.Content | ConvertFrom-Json)
}

# Returns $true if any plan for $Profile is currently in an "active" state
# (still running or queued). Used to honour overlap=skip.
function Test-HoblProfileBusy {
    param(
        [Parameter(Mandatory)] [string] $BaseUrl,
        [Parameter(Mandatory)] [string] $Profile,
        [int] $TimeoutSec = 30
    )
    $plans = Get-HoblPlans -BaseUrl $BaseUrl -TimeoutSec $TimeoutSec
    $busy  = @($plans | Where-Object {
        $_.Profile -eq $Profile -and $_.State -eq 'Active'
    })
    return ,$busy   # comma keeps it as an array even when 0/1 element
}

# Mutates $PlanRows in place: sets per-scenario AutoResubmit on the FIRST row
# (HOBLweb stores the count on Seq 0's Meta object — same shape its UI saves).
function Set-HoblAutoResubmit {
    param(
        [Parameter(Mandatory)] [object[]] $PlanRows,
        [Parameter(Mandatory)] [int]      $Resubmits   # = runsPerDay - 1
    )
    if ($PlanRows.Count -lt 1) { throw "Plan has no rows." }

    $head = $PlanRows[0]
    if (-not $head.Meta) {
        $head | Add-Member -NotePropertyName Meta -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    $head.Meta | Add-Member -NotePropertyName AutoResubmit          -NotePropertyValue $Resubmits -Force
    $head.Meta | Add-Member -NotePropertyName AutoResubmitRemaining -NotePropertyValue $Resubmits -Force
    if (-not $head.Meta.PSObject.Properties['CheckPreps']) {
        $head.Meta | Add-Member -NotePropertyName CheckPreps -NotePropertyValue $true -Force
    }
}

# POST /plan/Create with the JSON body shape HOBLweb's UI uses.
# Returns the new PlanID parsed from the response's redirectToUrl, or $null on hard failure.
function Submit-HoblPlan {
    param(
        [Parameter(Mandatory)] [string]   $BaseUrl,
        [Parameter(Mandatory)] [string]   $Profile,
        [Parameter(Mandatory)] [string]   $PlanName,
        [Parameter(Mandatory)] [object[]] $PlanRows,
        [string] $StudyType  = '',
        [int]    $TimeoutSec = 30
    )
    $url  = "$($BaseUrl.TrimEnd('/'))/plan/Create"
    $body = @{
        profile   = $Profile
        planName  = $PlanName
        planRows  = $PlanRows
        studyType = $StudyType
    } | ConvertTo-Json -Depth 12 -Compress

    $r = Invoke-WebRequest -Uri $url -Method Post -UseBasicParsing -TimeoutSec $TimeoutSec `
            -ContentType 'application/json; charset=utf-8' -Body $body

    # HOBLweb responds with { "redirectToUrl": "/plan/Plans" } or similar; the
    # new PlanID is not always in the body. Caller can re-list plans to discover it.
    try { return ($r.Content | ConvertFrom-Json) } catch { return $null }
}

# Wrapper: retries on transient HTTP errors (5xx / timeout / connection) using a
# caller-supplied backoff schedule. 4xx is treated as permanent and not retried.
function Invoke-WithRetry {
    param(
        [Parameter(Mandatory)] [scriptblock] $Action,
        [Parameter(Mandatory)] [int]         $MaxAttempts,
        [Parameter(Mandatory)] [int[]]       $BackoffSec,
        [Parameter(Mandatory)] [scriptblock] $LogLine    # called with a string
    )
    for ($i = 1; $i -le $MaxAttempts; $i++) {
        try {
            return & $Action
        } catch {
            $resp   = $_.Exception.Response
            $status = if ($resp) { [int]$resp.StatusCode } else { 0 }
            $msg    = $_.Exception.Message
            $perm   = ($status -ge 400 -and $status -lt 500)

            & $LogLine " ERROR - attempt $i/$MaxAttempts failed (status=$status): $msg"

            if ($perm) { throw }   # don't retry permanent client errors

            if ($i -lt $MaxAttempts) {
                $waitIdx = [Math]::Min($i - 1, $BackoffSec.Count - 1)
                $wait    = $BackoffSec[$waitIdx]
                & $LogLine "    waiting ${wait}s before retry"
                Start-Sleep -Seconds $wait
            }
        }
    }
    throw "Exhausted $MaxAttempts attempts."
}
