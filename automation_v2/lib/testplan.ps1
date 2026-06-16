# HOBL automation v2 — testplan (.ps1) parser.
#
# Dot-sourced by daily_run.ps1. Reads a HOBL testplan file (a flat list of
# `.\hobl.cmd -p $ARGS[0] -s <scenario> [<key>=<value> ...]` invocations) and
# produces the planRows array that HOBLweb's /plan/Create endpoint expects.
#
# Why parse the testplan instead of pointing HOBLweb at a stored PlanID:
#   - The .ps1 testplan is already canonical for local lab developers.
#   - Eliminates the manual "build plan in UI, copy PlanID into config" step.
#   - One file per plan, in git, PR-reviewable, drift-free.
#
# Supported testplan shape (matches HOBLweb's own "Load Plan from .ps1" view):
#   - One scenario invocation per line.
#   - Each line begins (after optional indentation) with `.\hobl.cmd` or `hobl.cmd`.
#   - `-p $ARGS[0]` (or any other `-p <profile>`) is recognised but the profile
#     ITSELF is supplied per-job in schedule.config.json — the testplan's `-p`
#     value is ignored.
#   - `-s <scenario_name>` marks the scenario.
#   - All remaining `<key>=<value>` tokens are joined into a single
#     space-separated Parameters string (HOBLweb stores Parameters as one
#     string per row, NOT as a key/value object — verified against the
#     HOBLweb client code that POSTs to /plan/Create).
#   - Quoted values (`key="value with spaces"`) are preserved verbatim and
#     re-quoted on output if the value contains whitespace.
#   - Lines starting with `#` or blank lines are skipped.
#   - PowerShell variables / loops / conditionals are NOT supported — testplans
#     for HOBLweb must be flat invocation lists (this is the same constraint
#     HOBLweb's UI enforces; see comment at top of testplans/intern_teams2.ps1).
#
# Row schema (verified against HOBLweb client JS embedded in HOBLweb.dll):
#   POST /plan/Create body = { profile, planName, planRows, studyType }
#   each planRows[i] = { Scenario: <string>, Parameters: <string>, Meta: <obj> }
#   Meta on row 0 holds AutoResubmit / CheckPreps / StudyType / StudyVars /
#   PlanBasedStudyVars; Meta on later rows is empty.
#   Set-HoblAutoResubmit (lib/submit.ps1) sets row 0's Meta.AutoResubmit.

# Public entry point. Returns:
#   [pscustomobject]@{
#       PlanName  = <string>     # derived from file basename
#       StudyType = <string>     # inferred from row 0's global:run_type, or ''
#       Rows      = [object[]]   # planRows for /plan/Create
#   }
function ConvertFrom-HoblTestplan {
    param(
        [Parameter(Mandatory)] [string] $Path
    )
    if (-not (Test-Path $Path)) {
        throw "Testplan not found: $Path"
    }

    $rawLines = Get-Content -Path $Path -Encoding UTF8
    $rows     = @()
    $lineNo   = 0
    foreach ($line in $rawLines) {
        $lineNo++
        $trim = $line.Trim()
        if (-not $trim)         { continue }
        if ($trim.StartsWith('#')) { continue }

        # Only parse lines that invoke hobl.cmd. Anything else (early `if`
        # guards, comments masquerading as code, etc.) is ignored — same as
        # HOBLweb's text parser.
        if ($trim -notmatch '^[\.\\]*hobl\.cmd\b') { continue }

        $tokens = ConvertTo-HoblTestplanTokens -Text $trim
        if ($tokens.Count -lt 1) { continue }

        # Walk tokens: skip the hobl.cmd token itself, recognise -p / -s, then
        # treat everything else as key=value parameters.
        $scenario = $null
        $params   = [ordered]@{}
        $i = 1   # tokens[0] is `.\hobl.cmd` / `hobl.cmd`
        while ($i -lt $tokens.Count) {
            $t = $tokens[$i]
            switch -regex ($t) {
                '^-p$' {
                    # Skip the value too — profile comes from schedule.config.json.
                    $i += 2; continue
                }
                '^-s$' {
                    if ($i + 1 -ge $tokens.Count) {
                        throw "Testplan ${Path}:${lineNo}: -s flag has no value."
                    }
                    $scenario = $tokens[$i + 1]
                    $i += 2; continue
                }
                default {
                    if ($t -match '^([^=]+)=(.*)$') {
                        $params[$Matches[1]] = $Matches[2]
                    }
                    # else: silently ignore unrecognised bare tokens; keeps parser
                    # forgiving toward future hobl.cmd flags we don't know about.
                    $i++
                }
            }
        }

        if (-not $scenario) {
            throw "Testplan ${Path}:${lineNo}: hobl.cmd line has no -s <scenario>."
        }

        # HOBLweb's Parameters field is a single string, not a dict.
        # Re-emit each key=value pair, quoting values that contain whitespace
        # so they round-trip through HOBLweb's own parser (which splits on
        # whitespace outside double-quotes).
        $paramParts = @()
        foreach ($k in $params.Keys) {
            $v = [string]$params[$k]
            if ($v -match '\s') {
                $paramParts += ('{0}="{1}"' -f $k, $v)
            } else {
                $paramParts += ('{0}={1}' -f $k, $v)
            }
        }
        $paramString = $paramParts -join ' '

        # Pull row-level overrides out of the parameter dict so they don't
        # also get echoed inside the Parameters string. HOBLweb stores
        # Iterations as a STRING, not an int.
        $iterations = '1'
        if ($params.Contains('global:iterations')) {
            $iterations = [string]$params['global:iterations']
        }

        $rows += [pscustomobject]@{
            # Match the on-disk shape of a known-working plan (PlanID 2053
            # on this server). Field names + types verified against the
            # PlanContent JSON that HOBLweb returns from /plan/Plans listing.
            Seq        = 0
            # Enabled MUST be the literal string "1" — HOBLweb's UI does
            # `Enabled: s.Enabled === "1"`, so anything else (true / null /
            # "true") makes the runner skip the row and only the auto-injected
            # prep scenario runs.
            Enabled    = '1'
            Scenario   = $scenario
            Parameters = $paramString
            Iterations = $iterations
            Expand     = @()
            Expansions = $null
            Meta       = [pscustomobject]@{}
            # _ParamsDict is consumed by ConvertFrom-HoblTestplan for StudyType
            # inference, then stripped before the row is sent to HOBLweb.
            _ParamsDict = $params
        }
    }

    if ($rows.Count -eq 0) {
        throw "Testplan ${Path}: no hobl.cmd invocation lines found."
    }

    # PlanName from filename, e.g. intern_teams2.ps1 -> intern_teams2.
    $planName = [System.IO.Path]::GetFileNameWithoutExtension($Path)

    # StudyType: HOBLweb's plan body wants a top-level studyType string. The
    # testplan doesn't have a dedicated field, but every workload-row sets
    # `global:run_type=<Power|Performance|Misc|...>`. The first non-Misc
    # value wins (Misc is the convention for charge_off / charge_on bracket
    # rows; the actual study type comes from the workload rows). Caller can
    # override via schedule.config.json's job.studyType.
    $studyType = ''
    foreach ($r in $rows) {
        $rt = $r._ParamsDict['global:run_type']
        if ($rt -and $rt -ne 'Misc') {
            $studyType = [string]$rt
            break
        }
    }
    if (-not $studyType -and $rows.Count -gt 0) {
        $rt0 = $rows[0]._ParamsDict['global:run_type']
        if ($rt0) { $studyType = [string]$rt0 }
    }

    # Populate row[0].Meta with the fields HOBLweb's planController.Create
    # dereferences server-side. Missing any of StudyVars / PlanBasedStudyVars /
    # StudyType / CheckPreps / AutoResubmit / AutoResubmitRemaining / Scenarios
    # causes a NullReferenceException. Default values match a known-working
    # stored plan (PlanID 2053): empty containers, StudyType="" (the real
    # study type goes in the top-level body.studyType, NOT here).
    # Set-HoblAutoResubmit (lib/submit.ps1) overlays AutoResubmit /
    # AutoResubmitRemaining on top of this Meta after the parser returns.
    if ($rows.Count -gt 0) {
        $rows[0].Meta = [pscustomobject]@{
            StudyVars             = [pscustomobject]@{}
            PlanBasedStudyVars    = @()
            StudyType             = ''
            AutoResubmit          = 0
            CheckPreps            = $true
            AutoResubmitRemaining = 0
            Scenarios             = $null
        }
    }

    # Strip the helper field before returning — emit only the fields HOBLweb
    # stores on each row (verified against PlanID 2053's PlanContent).
    $cleanRows = $rows | ForEach-Object {
        [pscustomobject]@{
            Seq        = $_.Seq
            Enabled    = $_.Enabled
            Scenario   = $_.Scenario
            Parameters = $_.Parameters
            Iterations = $_.Iterations
            Expand     = $_.Expand
            Expansions = $_.Expansions
            Meta       = $_.Meta
        }
    }

    return [pscustomobject]@{
        PlanName  = $planName
        StudyType = $studyType
        Rows      = $cleanRows
    }
}

# Quote-aware tokenizer. Splits on whitespace EXCEPT inside double quotes;
# the surrounding quotes are stripped from the resulting token. Backslash
# inside quotes is taken literally (Windows paths) — we do not implement
# shell-style escape sequences.
function ConvertTo-HoblTestplanTokens {
    param([string]$Text)
    $tokens  = @()
    $buf     = New-Object System.Text.StringBuilder
    $inQuote = $false
    foreach ($ch in $Text.ToCharArray()) {
        if ($ch -eq '"') {
            $inQuote = -not $inQuote
            continue
        }
        if (-not $inQuote -and ($ch -eq ' ' -or $ch -eq "`t")) {
            if ($buf.Length -gt 0) {
                $tokens += $buf.ToString()
                [void]$buf.Clear()
            }
            continue
        }
        [void]$buf.Append($ch)
    }
    if ($buf.Length -gt 0) { $tokens += $buf.ToString() }
    return ,$tokens
}
