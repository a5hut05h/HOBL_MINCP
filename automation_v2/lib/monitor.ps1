# HOBL automation — post-submit live progress monitor.
#
# Dot-sourced by daily_run.ps1. After the orchestrator submits one or more
# AutoResubmit chains, it hands the resulting tracker objects to
# Invoke-HoblMonitor, which polls HOBLweb on a fixed cadence and emits one log
# line per chain per tick:
#
#     [<job-name>] PlanID=<n> cycle=<i>/<N> state=<plan-state> phase=<phase>
#                  scenario=<row-name> status=<row-state>
#
# Phase is inferred from the per-scenario Status returned by /plan/ScenariosData
# (PlanContentByID only returns the static template, so it can't tell us live
# state). HOBLweb auto-injects a scenario named "prep" at the head of each
# plan, which is how we distinguish prep from a regular scenario:
#   plan Active + scenario "prep" RUNNING       -> "prep"
#   plan Active + any other scenario RUNNING    -> "scenario"
#   plan Active + every row PENDING             -> "prep"   (just started)
#   plan Active + nothing PENDING, nothing RUNN -> "teardown"
#   plan Pending                                -> "queued"
#   plan terminal                               -> "done"
#
# Exits when every chain has reached its target cycle count and a terminal
# state, when a chain hits a hard-stop state (Errored / Terminated / ...),
# or when MaxHours elapses (logs WARN, detaches; HOBLweb keeps running).

# Tracker shape produced by daily_run.ps1 and consumed here:
#   [pscustomobject]@{
#       Name        = <string>      # job display name
#       Profile     = <string>      # HOBLweb profile
#       PlanName    = <string>      # template plan name
#       HeadPlanID  = <int>         # PlanID of the first submitted plan in the chain
#       RunsPerDay  = <int>         # target cycle count (== chain length when complete)
#       LastPlanID  = <int>         # bookkeeping: last logged PlanID (dedup)
#       LastState   = <string>      # bookkeeping: last logged plan state (dedup)
#       LastRow     = <string>      # bookkeeping: "<phase>|<row>|<status>" (dedup)
#       Done        = <bool>        # set true when the chain is finished
#   }
#
# The monitor lazily attaches one more field per tracker:
#   LastRowStatus = @{ "<planId>|<scenarioId>" = "<STATUS>" }
# This is the per-row state from the previous tick, used to emit transition
# lines (start / pass / fail / terminated / skipped) independently of the
# active-row heartbeat. Keyed by ScenarioID + PlanID so cycles don't collide.

function Invoke-HoblMonitor {
    param(
        [Parameter(Mandatory)] [object[]] $Jobs,
        [Parameter(Mandatory)] [string]   $BaseUrl,
        [int] $IntervalSec   = 45,
        [int] $MaxHours      = 8,
        [int] $TimeoutSec    = 30,
        # Caller-supplied logger so we share daily_run.ps1's per-day log file
        # and " ERROR - " / " WARN - " coloring without re-implementing them.
        [Parameter(Mandatory)] [scriptblock] $Log,
        # Optional callback invoked once per scenario the moment it reaches a
        # terminal status (PASS / FAIL / TERMINATED / SKIPPED / ...). Receives a
        # single hashtable; daily_run.ps1 uses it to append to the weekly report
        # ledger. De-duplicated per (PlanID, ScenarioID) so it fires once even
        # though the row is polled every tick.
        [scriptblock] $OnResult = $null
    )

    if (-not $Jobs -or $Jobs.Count -eq 0) { return }

    & $Log "--- monitor: tracking $($Jobs.Count) chain(s); intervalSec=$IntervalSec; maxHours=$MaxHours ---"

    $monitorStart    = Get-Date
    $monitorDeadline = $monitorStart.AddHours($MaxHours)
    $tick            = 0

    # Terminal plan states for an individual plan within the chain.
    # "Terminating" / "Cancelling" / "Stopping" are transient stop states; we
    # treat them as terminal so the monitor detaches immediately rather than
    # waiting for HOBLweb to settle the row.
    $terminalStates = @(
        'Complete','Completed',
        'Errored','Error','Failed',
        'Terminated','Terminating',
        'Cancelled','Canceled','Cancelling','Canceling',
        'Stopped','Stopping',
        'Aborted','Aborting'
    )

    # Per-ROW terminal statuses (from /plan/ScenariosData), used to fire the
    # OnResult report callback once a scenario finishes. Distinct from the
    # plan-level $terminalStates above.
    $rowTerminalStatuses = @(
        'PASS','PASSED','FAIL','FAILED','ERROR','ERRORED',
        'TERMINATED','CANCELLED','CANCELED','ABORTED','STOPPED','SKIPPED'
    )

    while ($true) {
        $tick++
        $remaining = @($Jobs | Where-Object { -not $_.Done })
        if ($remaining.Count -eq 0) { & $Log "--- monitor: all chains finished. ---"; break }
        if ((Get-Date) -gt $monitorDeadline) {
            & $Log " WARN - monitor: maxHours=$MaxHours reached; $($remaining.Count) chain(s) still running. Detaching."
            break
        }

        $plansNow = $null
        try {
            $plansNow = Get-HoblPlans -BaseUrl $BaseUrl -TimeoutSec $TimeoutSec
        } catch {
            & $Log " WARN - monitor: /plan/PlanData failed: $($_.Exception.Message). Will retry next tick."
            Start-Sleep -Seconds $IntervalSec
            continue
        }

        foreach ($mj in $remaining) {
            # Find every plan in this chain: same Profile + PlanName, PlanID >= HeadPlanID.
            $chain = @($plansNow |
                Where-Object { $_.Profile -eq $mj.Profile -and $_.PlanName -eq $mj.PlanName -and [int]$_.PlanID -ge $mj.HeadPlanID } |
                Sort-Object { [int]$_.PlanID })
            if ($chain.Count -eq 0) {
                & $Log " WARN - monitor: chain for '$($mj.Name)' (head=$($mj.HeadPlanID)) not found."
                continue
            }
            $current    = $chain[-1]
            $currentId  = [int]$current.PlanID
            $cycleIndex = $chain.Count
            $cycleTotal = $mj.RunsPerDay
            $planState  = "$($current.State)"

            # Per-row runtime status comes from /plan/ScenariosData, NOT from
            # PlanContent (which only holds the static template). ScenariosData
            # rows expose Status (PASS/RUNNING/PENDING/FAIL/TERMINATED/...) and
            # Scenario. It also includes the auto-injected "prep" row, which is
            # how we distinguish phase=prep from phase=scenario.
            $activeRow  = ''
            $activeStat = ''
            $allStats   = @()
            $rows       = @()
            try {
                $rows = @(Get-HoblScenariosData -BaseUrl $BaseUrl -PlanID $currentId -TimeoutSec $TimeoutSec)
            } catch {
                # row fetch is best-effort; don't fail the whole monitor on it
                & $Log " WARN - monitor: ScenariosData for PlanID=$currentId failed: $($_.Exception.Message)"
            }

            # Per-row transition detection. We log every change in a row's
            # status, keyed by "<planId>|<scenarioId>" so we don't conflate
            # rows across cycles or duplicate scenario names within a plan.
            # This is independent of the active-row heartbeat below, so manual
            # terminations / failures / skipped rows never get silently
            # absorbed by a later RUNNING row in the same poll.
            if (-not $mj.PSObject.Properties['LastRowStatus'] -or $null -eq $mj.LastRowStatus) {
                $mj | Add-Member -Force -NotePropertyName 'LastRowStatus' -NotePropertyValue (@{})
            }
            # Track which (planId|scenarioId) we've already reported to the
            # report ledger so OnResult fires exactly once per scenario even
            # though we poll the row every tick (and even if the row is already
            # terminal the first time we see it).
            if (-not $mj.PSObject.Properties['Reported'] -or $null -eq $mj.Reported) {
                $mj | Add-Member -Force -NotePropertyName 'Reported' -NotePropertyValue (@{})
            }
            foreach ($r in $rows) {
                $stat = "$($r.Status)".ToUpper()
                $name = "$($r.Scenario)"
                if ($stat) { $allStats += $stat }
                if (-not $activeRow -and $stat -eq 'RUNNING') {
                    $activeRow  = $name
                    $activeStat = $stat
                }

                $rid  = "$currentId|$($r.ScenarioID)"
                $prev = $mj.LastRowStatus[$rid]
                if ($null -ne $prev -and $prev -ne $stat) {
                    # Emit an explicit transition line. PENDING->RUNNING marks
                    # a start; RUNNING->anything-else (or PENDING->terminal,
                    # which happens when HOBLweb skips a row) marks an end.
                    if ($prev -eq 'RUNNING' -or ($stat -ne 'PENDING' -and $stat -ne 'RUNNING')) {
                        $tag = if ($stat -eq 'PASS') { '    ' } else { ' WARN - ' }
                        & $Log ("{0}[{1}] PlanID={2} row={3} {4} -> {5}" -f $tag, $mj.Name, $currentId, $name, $prev, $stat)
                    } elseif ($prev -eq 'PENDING' -and $stat -eq 'RUNNING') {
                        & $Log ("    [{0}] PlanID={1} row={2} started" -f $mj.Name, $currentId, $name)
                    }
                }
                $mj.LastRowStatus[$rid] = $stat

                # Report ledger: record each scenario once it reaches a terminal
                # status, independent of the transition log above (covers rows
                # already terminal on first sight, e.g. monitor attached late).
                if ($OnResult -and ($rowTerminalStatuses -contains $stat) -and -not $mj.Reported.ContainsKey($rid)) {
                    $mj.Reported[$rid] = $true
                    try {
                        & $OnResult @{
                            type       = 'scenario'
                            recordedAt = (Get-Date).ToString('o')
                            profile    = "$($mj.Profile)"
                            job        = "$($mj.Name)"
                            planId     = $currentId
                            scenarioId = [int]$r.ScenarioID
                            cycle      = $cycleIndex
                            cycleTotal = $cycleTotal
                            scenario   = $name
                            status     = $stat
                            startTime  = if ($r.StartTime) { "$($r.StartTime)" } else { $null }
                            isPrep     = ($name -eq 'prep')
                            source     = 'monitor'
                        }
                    } catch {
                        & $Log " WARN - monitor: OnResult callback failed for PlanID=$currentId row=${name}: $($_.Exception.Message)"
                    }
                }
            }

            # Fallback for the active-row line: nothing running -> show the
            # last non-pending row so the heartbeat isn't blank between
            # scenarios (e.g. brief gap as one row finishes before the next
            # picks up).
            if (-not $activeRow -and $rows.Count -gt 0) {
                $lastDone = $rows | Where-Object { "$($_.Status)".ToUpper() -notin @('PENDING','') } | Select-Object -Last 1
                if ($lastDone) {
                    $activeRow  = "$($lastDone.Scenario)"
                    $activeStat = "$($lastDone.Status)".ToUpper()
                }
            }

            # Phase inference using real Status values.
            if ($planState -eq 'Pending') {
                $phase = 'queued'
            } elseif ($terminalStates -contains $planState) {
                $phase = 'done'
            } elseif ($activeStat -eq 'RUNNING' -and $activeRow -eq 'prep') {
                $phase = 'prep'
            } elseif ($activeStat -eq 'RUNNING') {
                $phase = 'scenario'
            } elseif ($allStats.Count -gt 0 -and ($allStats | Where-Object { $_ -ne 'PENDING' }).Count -eq 0) {
                $phase = 'prep'      # plan Active but nothing started yet
            } elseif ($allStats.Count -gt 0 -and ($allStats | Where-Object { $_ -eq 'PENDING' }).Count -eq 0) {
                $phase = 'teardown'  # everything past pending, plan not yet terminal
            } else {
                $phase = 'scenario'  # mid-flight between rows
            }

            $line = "    [$($mj.Name)] PlanID=$currentId cycle=$cycleIndex/$cycleTotal state=$planState phase=$phase"
            if ($activeRow)  { $line += " scenario=$activeRow" }
            if ($activeStat) { $line += " status=$activeStat" }

            # Suppress duplicate consecutive lines per chain to keep the log
            # readable; force a heartbeat every 2 ticks (~90s at the default
            # interval) so it's obvious we're still attached when nothing
            # changes (e.g. a long prep phase).
            $sig     = "$currentId|$planState|$phase|$activeRow|$activeStat"
            $prevSig = "$($mj.LastPlanID)|$($mj.LastState)|$($mj.LastRow)"
            if ($sig -ne $prevSig -or ($tick % 2 -eq 1)) {
                & $Log $line
            }
            $mj.LastPlanID = $currentId
            $mj.LastState  = $planState
            $mj.LastRow    = "$phase|$activeRow|$activeStat"

            $isTerminal = $terminalStates -contains $planState
            $hardStop   = $planState -match '^(Errored|Error|Failed|Terminated|Terminating|Cancelled|Canceled|Cancelling|Canceling|Stopping|Stopped|Aborted|Aborting)$'
            if ($hardStop) {
                & $Log " WARN - monitor: chain '$($mj.Name)' stopped early at PlanID=$currentId state=$planState (cycle $cycleIndex/$cycleTotal)."
                $mj.Done = $true
            } elseif ($isTerminal -and $cycleIndex -ge $cycleTotal) {
                & $Log "    [$($mj.Name)] chain complete: $cycleIndex/$cycleTotal cycles, last PlanID=$currentId state=$planState"
                $mj.Done = $true
            }
        }

        if (@($Jobs | Where-Object { -not $_.Done }).Count -eq 0) {
            & $Log "--- monitor: all chains finished. ---"
            break
        }
        Start-Sleep -Seconds $IntervalSec
    }
}
