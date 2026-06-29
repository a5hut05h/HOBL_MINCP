# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.
#
# wlan_monitor.ps1
# Wrapper script for iperf3 runs that adds Wi-Fi layer telemetry alongside the
# normal iperf3 output. Invoked by the HoBL iperf3 scenario when wlan_logging=1.
#
# What it captures:
#   wlan_stats_before.csv  -- Get-NetAdapterStatistics snapshot at run start
#   wlan_stats_after.csv   -- Get-NetAdapterStatistics snapshot at run end
#   wlan_iface_before.csv  -- netsh wlan show interfaces at run start (channel, RSSI, rates)
#   wlan_iface_after.csv   -- netsh wlan show interfaces at run end
#   wlan_poll.txt          -- netsh wlan show interfaces polled every 5 s during the run
#   wlan_events.csv        -- WLAN AutoConfig event log entries during the test window
#
# Note: Get-NetAdapterStatistics is used instead of "netsh wlan show statistics" because
# the netsh wlan subcommand is inaccessible in restricted service-account contexts.
# OutboundPacketErrors and OutboundDiscardedPackets serve as proxy retry indicators.
#
# The script exits with iperf3's own exit code so the HoBL framework's
# expected_exit_code="0" check still works correctly.

param(
    [Parameter(Mandatory=$true)]
    [string]$IpeRf3Exe,

    [Parameter(Mandatory=$true)]
    [string]$IpeRf3Args,

    [Parameter(Mandatory=$true)]
    [string]$OutPath,

    [Parameter(Mandatory=$true)]
    [string]$DataPath
)

$startTime = Get-Date

# ---------------------------------------------------------------------------
# Helper: find the active Wi-Fi adapter name
# Prefers adapters whose PhysicalMediaType indicates 802.11; falls back to
# any Up adapter whose description contains "wi-fi" or "wireless".
# ---------------------------------------------------------------------------
function Get-WifiAdapterName {
    $adapter = Get-NetAdapter -ErrorAction SilentlyContinue |
        Where-Object { $_.Status -eq 'Up' -and $_.PhysicalMediaType -eq 'Native 802.11' } |
        Select-Object -First 1

    if (-not $adapter) {
        $adapter = Get-NetAdapter -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Status -eq 'Up' -and
                ($_.InterfaceDescription -imatch 'wi.?fi|wireless|802\.11|wlan')
            } |
            Select-Object -First 1
    }

    return $adapter.Name
}

# ---------------------------------------------------------------------------
# Helper: write a Get-NetAdapterStatistics snapshot to a file
# ---------------------------------------------------------------------------
function Write-AdapterStats {
    param([string]$AdapterName, [string]$FilePath, [string]$PrePendName = "")

    if (-not $AdapterName) {
        "No active Wi-Fi adapter found." | Out-File -FilePath $FilePath -Encoding utf8
        return
    }

    try {
        $stats = Get-NetAdapterStatistics -Name $AdapterName -ErrorAction Stop
        @"
$PrePendName AdapterName              , $($stats.Name)
$PrePendName Timestamp                , $(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
$PrePendName SentBytes                , $($stats.SentBytes)
$PrePendName ReceivedBytes            , $($stats.ReceivedBytes)
$PrePendName SentUnicastPackets       , $($stats.SentUnicastPackets)
$PrePendName ReceivedUnicastPackets   , $($stats.ReceivedUnicastPackets)
$PrePendName OutboundPacketErrors     , $($stats.OutboundPacketErrors)
$PrePendName ReceivedPacketErrors     , $($stats.ReceivedPacketErrors)
$PrePendName OutboundDiscardedPackets , $($stats.OutboundDiscardedPackets)
$PrePendName ReceivedDiscardedPackets , $($stats.ReceivedDiscardedPackets)
"@ | Out-File -FilePath $FilePath -Encoding utf8
    } catch {
        "Get-NetAdapterStatistics failed for '$AdapterName': $_" |
            Out-File -FilePath $FilePath -Encoding utf8
    }
}

# ---------------------------------------------------------------------------
# Helper: run "netsh wlan show interfaces" and write a CSV file.
# Drops the "There is N interface(s) on the system:" header and blank lines,
# splits each "Key : Value" row on the first colon, and trims whitespace.
# ---------------------------------------------------------------------------
function Write-WlanInterfaceCsv {
    param([string]$FilePath, [string]$PrePendName = "")

    $raw = netsh wlan show interfaces

    $rows = foreach ($line in $raw) {
        # Only keep indented "Key : Value" rows. The leading-whitespace
        # requirement excludes the "There is N interface(s) on the system:"
        # header, which starts at column 0.
        if ($line -match '^\s+(.+?)\s*:\s*(.*?)\s*$') {
            "$PrePendName $($matches[1].Trim()) , $($matches[2].Trim())"
        }
    }

    if ($rows) {
        $rows | Out-File -FilePath $FilePath -Encoding utf8
    } else {
        "$PrePendName Error , No Wi-Fi interface data returned by netsh" |
            Out-File -FilePath $FilePath -Encoding utf8
    }
}

# ---------------------------------------------------------------------------
# Pre-run snapshots
# ---------------------------------------------------------------------------
$wifiAdapter = Get-WifiAdapterName

Write-AdapterStats -AdapterName $wifiAdapter -FilePath "$DataPath\wlan_stats_before.csv" -PrePendName "Run Start"
Write-WlanInterfaceCsv -FilePath "$DataPath\wlan_iface_before.csv" -PrePendName "Run Start"

# ---------------------------------------------------------------------------
# Background polling job — samples wlan interfaces every 5 seconds
# Captures channel, frequency, RSSI, signal quality, and negotiated TX/RX rate.
# Channel hops appear as frequency changes between consecutive samples.
# ---------------------------------------------------------------------------
$pollJob = Start-Job -ScriptBlock {
    param($DataPath)
    while ($true) {
        $ts    = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"
        $iface = netsh wlan show interfaces
        "$ts`r`n$iface`r`n---`r`n" | Out-File -FilePath "$DataPath\wlan_poll.txt" -Append -Encoding utf8
        Start-Sleep -Seconds 5
    }
} -ArgumentList $DataPath

# ---------------------------------------------------------------------------
# Run iperf3
# ---------------------------------------------------------------------------
$cmdLine = "`"$IpeRf3Exe`" $IpeRf3Args > `"$OutPath`" 2>&1"
& cmd.exe /c $cmdLine
$iperf3ExitCode = $LASTEXITCODE

# ---------------------------------------------------------------------------
# Stop background poller
# ---------------------------------------------------------------------------
Stop-Job    -Job $pollJob
Receive-Job -Job $pollJob | Out-Null   # discard any stray output from the job
Remove-Job  -Job $pollJob

$endTime = Get-Date

# ---------------------------------------------------------------------------
# Post-run snapshots
# ---------------------------------------------------------------------------
Write-AdapterStats -AdapterName $wifiAdapter -FilePath "$DataPath\wlan_stats_after.csv" -PrePendName "Run Stop"
Write-WlanInterfaceCsv -FilePath "$DataPath\wlan_iface_after.csv" -PrePendName "Run Stop"

# ---------------------------------------------------------------------------
# WLAN AutoConfig event log — events that occurred during the iperf3 run
# Event IDs of interest:
#   8001  Connection successful
#   8002  Disconnected
#   8003  Association failed
#   11001 Roaming started
#   11004 Roaming completed
#   20019 Channel switch notification received
# ---------------------------------------------------------------------------
try {
    $events = Get-WinEvent -LogName "Microsoft-Windows-WLAN-AutoConfig/Operational" -ErrorAction Stop |
        Where-Object {
            $_.TimeCreated -ge $startTime -and
            $_.TimeCreated -le $endTime   -and
            $_.Id -in @(8001, 8002, 8003, 11001, 11004, 20019)
        } |
        Select-Object TimeCreated, Id, LevelDisplayName,
            @{Name='Message'; Expression={ $_.Message -replace "`r`n"," " }}

    if ($events) {
        $events | Export-Csv -Path "$DataPath\wlan_events.txt" -NoTypeInformation -Encoding utf8
    } else {
        "TimeCreated,Id,LevelDisplayName,Message" | Out-File "$DataPath\wlan_events.txt" -Encoding utf8
        "No WLAN AutoConfig events (8001/8002/8003/11001/11004/20019) recorded during test window." |
            Out-File "$DataPath\wlan_events.txt" -Append -Encoding utf8
    }
} catch {
    "Event log query failed: $_" | Out-File -FilePath "$DataPath\wlan_events.txt" -Encoding utf8
}

# ---------------------------------------------------------------------------
# Exit with iperf3's exit code so HoBL's expected_exit_code check still works
# ---------------------------------------------------------------------------
exit $iperf3ExitCode
