# HOBL automation v2 — report email + pending-email marker contract.
#
# Dot-sourced by daily_run.ps1 (writes markers) and send_report_email.ps1
# (drains markers + sends). Keeps the Outlook COM send and the marker schema in
# ONE place so the two scripts can't drift.
#
# WHY A MARKER + HELPER (not an in-process send):
#   daily_run.ps1 runs as SYSTEM on the Host so it can fire headless / wake from
#   sleep. SYSTEM has no interactive desktop and no signed-in Outlook profile,
#   so it CANNOT drive Outlook COM. Instead, when a run finishes, daily_run
#   (SYSTEM) writes a small marker file describing the report it just built and
#   pokes the "HOBL Report Email" scheduled task. That task runs as the Host's
#   logged-in user (Outlook available) and drains the marker(s) — sending the
#   email within seconds. The marker persists across logoff, and the helper's
#   logon trigger drains any backlog the moment a user signs in, so the flow is
#   fully unattended with no lost emails.
#
# MARKER SCHEMA  (<reportDir>\pending_email\<runId>.json):
#   runId       run identifier (also the file stem)
#   createdAt   ISO timestamp the marker was written
#   reportDir   report root (so the helper resolves the same period files)
#   frequency   Daily | Weekly | Monthly (selects the period + subfolder)
#   date        ISO timestamp inside the target period (the run's start)
#   recipients  ;-separated recipient list
#   incomplete  bool — run detached at maxHours or a chain hard-stopped
#   note        human-readable reason shown in the email when incomplete
#
# Depends on lib\report.ps1 being dot-sourced by the caller (for
# Get-HoblReportPaths / Get-HoblReportSummary / Write-HoblReportHtml /
# ConvertTo-HoblEmailBodyHtml). Send-HoblReportEmail guards for that.

# ---------------------------------------------------------------------------
# Marker I/O
# ---------------------------------------------------------------------------

function Get-HoblPendingEmailDir {
    param([Parameter(Mandatory)] [string] $ReportDir)
    return (Join-Path $ReportDir 'pending_email')
}

# Write a pending-email marker. Called by daily_run.ps1 (SYSTEM) at run end.
# Returns the marker path.
function Write-HoblPendingEmail {
    param(
        [Parameter(Mandatory)] [string]   $ReportDir,
        [Parameter(Mandatory)] [string]   $Frequency,
        [Parameter(Mandatory)] [datetime] $Date,
        [Parameter(Mandatory)] [string]   $Recipients,
        [string] $RunId      = ((Get-Date).ToString('yyyyMMdd-HHmmss')),
        [bool]   $Incomplete = $false,
        [string] $Note       = ''
    )
    $dir = Get-HoblPendingEmailDir -ReportDir $ReportDir
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $marker = [ordered]@{
        runId      = $RunId
        createdAt  = (Get-Date).ToString('o')
        reportDir  = $ReportDir
        frequency  = $Frequency
        date       = $Date.ToString('o')
        recipients = $Recipients
        incomplete = [bool]$Incomplete
        note       = $Note
    }
    # File stem is the runId; sanitised so an odd runId can't escape the folder.
    $safeStem = ($RunId -replace '[^0-9A-Za-z._-]', '_')
    $path = Join-Path $dir "$safeStem.json"
    ($marker | ConvertTo-Json -Depth 5) | Set-Content -Path $path -Encoding utf8
    return $path
}

# Enumerate pending markers (oldest first, by file name which is time-ordered).
function Get-HoblPendingEmails {
    param([Parameter(Mandatory)] [string] $ReportDir)
    $dir = Get-HoblPendingEmailDir -ReportDir $ReportDir
    if (-not (Test-Path $dir)) { return ,@() }
    return ,@(Get-ChildItem -Path $dir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)
}

# ---------------------------------------------------------------------------
# Outlook COM send (interactive user only)
# ---------------------------------------------------------------------------
# Sends one already-built email. Returns $true on success, $false otherwise.
# Never throws — a send failure must not tear down the drain loop.
function Invoke-HoblOutlookSend {
    param(
        [Parameter(Mandatory)] [string] $Recipients,
        [Parameter(Mandatory)] [string] $Subject,
        [Parameter(Mandatory)] [string] $BodyHtml,
        [string] $AttachmentPath = '',
        [scriptblock] $Log
    )
    $outlook = $null
    try {
        $outlook = New-Object -ComObject Outlook.Application
    } catch {
        if ($Log) { & $Log " ERROR - Could not start Outlook COM. Is Outlook installed, signed in, and a user logged on? $($_.Exception.Message)" }
        return $false
    }
    try {
        $mail = $outlook.CreateItem(0)   # 0 = olMailItem
        $mail.To       = $Recipients
        $mail.Subject  = $Subject
        $mail.HTMLBody = $BodyHtml
        if ($AttachmentPath -and (Test-Path $AttachmentPath)) {
            $mail.Attachments.Add($AttachmentPath) | Out-Null
        }
        $mail.Send()
        return $true
    } catch {
        if ($Log) {
            & $Log " ERROR - Outlook failed to send: $($_.Exception.Message)"
            & $Log " ERROR -   If a security prompt appeared, the Outlook 'programmatic access' guard is active."
        }
        return $false
    } finally {
        if ($outlook) { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($outlook) | Out-Null }
    }
}

# ---------------------------------------------------------------------------
# Send one report (resolves + refreshes the period HTML, builds the email)
# ---------------------------------------------------------------------------
# $Marker is a parsed marker object (from ConvertFrom-Json). Returns $true if
# the email was sent (marker can be deleted), $false if it should be kept for
# retry. Ledger-only refresh (no HOBLweb dependency at send time — the monitor
# already recorded terminal rows live, and daily_run backfills before writing
# the marker).
function Send-HoblReportEmail {
    param(
        [Parameter(Mandatory)] $Marker,
        [scriptblock] $Log
    )
    foreach ($fn in @('Get-HoblReportPaths','Get-HoblReportSummary','Write-HoblReportHtml','ConvertTo-HoblEmailBodyHtml')) {
        if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) {
            if ($Log) { & $Log " ERROR - email: lib\report.ps1 not loaded ($fn missing); cannot send." }
            return $false
        }
    }

    $reportDir  = [string]$Marker.reportDir
    $frequency  = [string]$Marker.frequency
    $recipients = [string]$Marker.recipients
    if (-not $reportDir)  { if ($Log) { & $Log " ERROR - email: marker missing reportDir." };  return $false }
    if (-not $recipients) { if ($Log) { & $Log " ERROR - email: marker missing recipients." }; return $false }

    # Normalise recipient separators (comma or semicolon) to ';' for Outlook.
    $recipients = ($recipients -split '[;,]' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join ';'
    if (-not $recipients) { if ($Log) { & $Log " ERROR - email: recipient list empty after normalisation." }; return $false }

    # Resolve the target period date from the marker (fallback: now).
    $targetDate = ConvertTo-HoblDate ([string]$Marker.date)
    if (-not $targetDate) { $targetDate = Get-Date }

    # Refresh the HTML from the ledger so the emailed attachment is current.
    try {
        Write-HoblReportHtml -ReportDir $reportDir -Date $targetDate -Frequency $frequency -Log $Log | Out-Null
    } catch {
        if ($Log) { & $Log " WARN - email: could not refresh report HTML: $($_.Exception.Message)" }
    }

    $paths = Get-HoblReportPaths -ReportDir $reportDir -Date $targetDate -Frequency $frequency
    if (-not (Test-Path $paths.Html)) {
        if ($Log) { & $Log " ERROR - email: report HTML not found for $($paths.Period.Key): $($paths.Html)" }
        return $false
    }

    $summary = Get-HoblReportSummary -ReportDir $reportDir -Date $targetDate -Frequency $frequency
    $attName = [System.IO.Path]::GetFileName($paths.Html)
    $body    = ConvertTo-HoblEmailBodyHtml -Summary $summary -AttachmentName $attName

    $incomplete = [bool]$Marker.incomplete
    $note       = [string]$Marker.note
    if ($incomplete -and $note) {
        # Prepend an amber banner so the recipient knows the run didn't finish
        # cleanly and the numbers below may be partial.
        $noteHtml = '<div style="font-family:Segoe UI,Arial,sans-serif;background:#fff1e5;border:1px solid #f0c39a;color:#bc4c00;padding:10px 14px;border-radius:6px;margin-bottom:14px;font-size:13px;"><b>Note:</b> ' +
                    [System.Net.WebUtility]::HtmlEncode($note) + '</div>'
        $body = $noteHtml + $body
    }

    $rateTxt = if ($null -ne $summary.PassRate) { "$($summary.PassRate)%" } else { 'n/a' }
    $subject = "HOBL $($summary.Period.Title) Report $($summary.Period.Key) - $rateTxt pass, $($summary.Counts.Failed) failed, $($summary.Counts.Terminated) terminated"
    if ($incomplete) { $subject += ' [INCOMPLETE]' }

    if ($Log) {
        & $Log "email: period=$($summary.Period.Key) freq=$frequency recipients=$recipients attachment=$($paths.Html)"
    }

    return (Invoke-HoblOutlookSend -Recipients $recipients -Subject $subject -BodyHtml $body -AttachmentPath $paths.Html -Log $Log)
}

# ---------------------------------------------------------------------------
# Drain all pending markers (helper entry point)
# ---------------------------------------------------------------------------
# Single-pass over the markers present at start (a marker written mid-drain is
# picked up by the next trigger / logon). Deletes a marker ONLY when its email
# was sent; keeps it for retry on failure. A marker that can't be parsed is
# renamed .bad so it doesn't jam the queue forever. A file lock prevents a
# daily_run-triggered instance and a logon-triggered instance from double-sending.
# Returns a summary object { Sent; Kept; Bad }.
function Invoke-HoblEmailDrain {
    param(
        [Parameter(Mandatory)] [string] $ReportDir,
        [scriptblock] $Log
    )
    $dir = Get-HoblPendingEmailDir -ReportDir $ReportDir
    if (-not (Test-Path $dir)) {
        if ($Log) { & $Log "email drain: no pending_email folder; nothing to send." }
        return [pscustomobject]@{ Sent = 0; Kept = 0; Bad = 0 }
    }

    # ---- Concurrency lock ----
    $lockPath = Join-Path $dir '.drain.lock'
    $haveLock = $false
    try {
        if (Test-Path $lockPath) {
            $raw = (Get-Content -Path $lockPath -Raw -ErrorAction SilentlyContinue).Trim()
            $oldPid = ($raw -split '\|')[0]
            $alive = $false
            if ($oldPid -match '^\d+$') {
                try { Get-Process -Id ([int]$oldPid) -ErrorAction Stop | Out-Null; $alive = $true } catch { $alive = $false }
            }
            if ($alive) {
                if ($Log) { & $Log " WARN - email drain: another drain is running (PID $oldPid); skipping." }
                return [pscustomobject]@{ Sent = 0; Kept = 0; Bad = 0 }
            }
            Remove-Item -Path $lockPath -Force -ErrorAction SilentlyContinue
        }
        "$PID|$((Get-Date).ToUniversalTime().ToString('o'))" | Set-Content -Path $lockPath -Encoding utf8
        $haveLock = $true
    } catch {
        if ($Log) { & $Log " WARN - email drain: could not acquire lock: $($_.Exception.Message)" }
    }

    $sent = 0; $kept = 0; $bad = 0
    try {
        $markers = Get-HoblPendingEmails -ReportDir $ReportDir
        if ($markers.Count -eq 0) {
            if ($Log) { & $Log "email drain: no pending markers." }
        } else {
            if ($Log) { & $Log "email drain: $($markers.Count) pending marker(s)." }
            foreach ($m in $markers) {
                $obj = $null
                try {
                    $obj = Get-Content -Path $m.FullName -Raw -Encoding utf8 | ConvertFrom-Json
                } catch {
                    if ($Log) { & $Log " ERROR - email drain: marker $($m.Name) is corrupt; renaming .bad." }
                    try { Rename-Item -Path $m.FullName -NewName ($m.Name + '.bad') -Force } catch { }
                    $bad++
                    continue
                }
                $ok = Send-HoblReportEmail -Marker $obj -Log $Log
                if ($ok) {
                    Remove-Item -Path $m.FullName -Force -ErrorAction SilentlyContinue
                    if ($Log) { & $Log "email drain: sent + removed marker $($m.Name)." }
                    $sent++
                } else {
                    if ($Log) { & $Log " WARN - email drain: keeping marker $($m.Name) for retry." }
                    $kept++
                }
            }
        }
    } finally {
        if ($haveLock) { Remove-Item -Path $lockPath -Force -ErrorAction SilentlyContinue }
    }

    return [pscustomobject]@{ Sent = $sent; Kept = $kept; Bad = $bad }
}
