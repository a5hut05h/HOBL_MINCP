# HOBL Daily Automation v2

A thin scheduler that re-submits HOBL plans on a daily cadence, fully unattended.
The actual workload execution, queueing, retries and dashboards stay in HOBLweb —
this layer only **presses Submit at the right time**.

**v2 vs v1.** v1 required you to build a *template* plan once in HOBLweb's UI
and paste its PlanID into `schedule.config.json`. v2 reads the plan straight
from a HOBL testplan `.ps1` file in git — the same file lab developers run
locally with `hobl.cmd`. No HOBLweb UI step at all. The testplan is the single
source of truth; HOBLweb just runs what we POST to `/plan/Create`.

## How it works

You write (or already have) a HOBL testplan `.ps1` under `testplans/` — a flat
list of `.\hobl.cmd -p $ARGS[0] -s <scenario> <key>=<value> ...` lines.
[testplans/power_workloads.ps1](../testplans/power_workloads.ps1) is the worked
example.

Add a job to `schedule.config.json` pointing at that file plus a `profile` and
a `runsPerDay`. Then each day at the registered trigger time,
[`daily_run.ps1`](daily_run.ps1):

1. Parses the testplan into the `planRows` array HOBLweb's `/plan/Create`
   accepts (one row per `hobl.cmd` line; all `key=value` tokens are joined
   into a single space-separated `Parameters` string; `-p` is ignored —
   profile comes from the job).
2. Sets `Meta.AutoResubmit = runsPerDay - 1` on the first row.
3. POSTs that body to `/plan/Create` — the same call HOBLweb's UI makes when
   you click Submit.

HOBLweb then runs the new plan and at the end of each cycle re-queues itself
until `AutoResubmit` reaches zero — so `runsPerDay = 3` produces 3 full cycles.

There is **no template plan in HOBLweb's database**. Each daily fire creates a
fresh PlanID from the `.ps1` file. Edit the file, commit, the next run picks
it up — no UI revisits, no PlanID copy-paste.

## Required: HOBLweb Poke task

HOBLweb's queue only advances when something pokes its `/plan/Poke` endpoint.
Install once, as administrator:

```cmd
schtasks /create /ru system /sc minute /mo 1 /tn "HOBLweb Poke" ^
  /tr "cmd.exe /C curl http://%COMPUTERNAME%/plan/Poke" /f
```

`daily_run.ps1` checks for this task during pre-flight. If `Get-ScheduledTask`
or `schtasks /query` reports it as genuinely missing, the run aborts with exit
code `3`. If the task exists but its ACL hides it from the current user (common
when running non-elevated against a SYSTEM-owned task), pre-flight logs a
`WARN` and proceeds.

## Files

| File | Role |
|---|---|
| [schedule.config.json](schedule.config.json)   | The job list. Add a DUT + testplan + cadence here. |
| [daily_run.ps1](daily_run.ps1)                 | The script Task Scheduler runs every day. Reads the config, parses each testplan, submits to HOBLweb. |
| [lib/testplan.ps1](lib/testplan.ps1)           | Turns a HOBL `.ps1` testplan into the JSON shape `/plan/Create` expects. |
| [lib/submit.ps1](lib/submit.ps1)               | Talks to HOBLweb (list plans, submit, retry on 5xx). |
| [lib/monitor.ps1](lib/monitor.ps1)             | After submit, polls HOBLweb and logs live progress until the chain finishes. |
| [lib/report.ps1](lib/report.ps1)               | Builds the weekly HTML report (scenario pass/fail/terminated) from a per-week ledger the monitor appends to. |
| [generate_report.ps1](generate_report.ps1)     | Rebuild or backfill a week's HTML report on demand (`-Week`, `-Backfill`, `-Open`, `-ImportLogs`). |
| [send_report_email.ps1](send_report_email.ps1) | Email the weekly report via Outlook (configurable recipient). Manual, or `-Register` for a weekly task. |
| [register_schedule.ps1](register_schedule.ps1)| Run once. Registers `daily_run.ps1` as a Windows scheduled task under SYSTEM. |
| [tools/dump_plan.ps1](tools/dump_plan.ps1)     | Diagnostic. Dumps a real HOBLweb plan's JSON so you can compare shapes if `/plan/Create` ever starts rejecting rows. |

## Quick start

```cmd
:: 1. Use an existing testplan or write one under testplans\<name>.ps1.
::    Format: one `.\hobl.cmd -p $ARGS[0] -s <scenario> <k>=<v> ...` line per row.
::    See testplans\power_workloads.ps1 for a worked example.

:: 2. Edit schedule.config.json: set 'profile', 'testplan', 'runsPerDay'.

:: 3. Smoke-test without submitting (parses + builds + logs the JSON body):
powershell -ExecutionPolicy Bypass -File c:\hobl\automation_v2\daily_run.ps1 -DryRun

:: 4. Smoke-test with a real submit:
powershell -ExecutionPolicy Bypass -File c:\hobl\automation_v2\daily_run.ps1

:: 5. Register the daily trigger (ADMIN PowerShell):
powershell -ExecutionPolicy Bypass -File c:\hobl\automation_v2\register_schedule.ps1

::    To register at a different time of day (default 00:00), pass -Time HH:MM:
powershell -ExecutionPolicy Bypass -File c:\hobl\automation_v2\register_schedule.ps1 -Time "02:30"

:: 6. Force-fire the registered task immediately (best end-to-end test):
schtasks /run /tn "HOBL Daily Automation"

:: 7. Inspect / disable / remove
schtasks /query  /tn "HOBL Daily Automation" /v /fo list
schtasks /change /tn "HOBL Daily Automation" /disable
schtasks /delete /tn "HOBL Daily Automation" /f
```

## Adding a DUT

Append a block to `jobs[]` in `schedule.config.json`:

```json
{
    "name":       "Lunarlake02_power_workloads",
    "enabled":    true,
    "profile":    "Lunarlake02",
    "testplan":   "testplans/power_workloads.ps1",
    "runsPerDay": 3
}
```

Two DUTs running the same plan share the **same testplan file** — no copy &
paste of plan content. If the plan changes, both DUTs pick up the change on
their next run.

## Changing the schedule (daily / weekly / monthly)

Re-run `register_schedule.ps1`. It now **prompts** for the cadence:

```
How often should the automation run?
  [1] Daily
  [2] Weekly   (default day: Monday)
  [3] Monthly  (default day of month: 1)
```

- **Daily** — fires every day at the chosen time (default `00:00`).
- **Weekly** — fires on the chosen weekday (default **Monday**) at the chosen time.
- **Monthly** — fires on the chosen day of month, `1-28` (default **1**) at the
  chosen time. Capped at 28 so the day exists in every month.

The chosen cadence is saved into the `schedule` block of
`schedule.config.json`, so the next registration reuses it as the default.

You can also pass it non-interactively to skip the prompts:

```powershell
.\register_schedule.ps1 -Frequency Daily   -Time "02:30"
.\register_schedule.ps1 -Frequency Weekly  -DayOfWeek Monday -Time "00:00"
.\register_schedule.ps1 -Frequency Monthly -DayOfMonth 1     -Time "00:00"
```

## Testplan `.ps1` constraints

The testplan parser handles the same shape HOBLweb's own "Load Plan from .ps1"
view requires: a flat list of invocations, no PowerShell variables / loops /
conditionals. From [testplans/power_workloads.ps1](../testplans/power_workloads.ps1):

```powershell
.\hobl.cmd -p $ARGS[0] -s charge_off global:run_type=Misc global:post_run_delay=30
.\hobl.cmd -p $ARGS[0] -s abl_standby global:iterations=1 global:attempts=2 global:run_type=Power global:tools="display auto_recharge power_light powercfg"
.\hobl.cmd -p $ARGS[0] -s web global:iterations=1 global:attempts=2 global:run_type=Power global:tools="display power_light auto_recharge powercfg"
.\hobl.cmd -p $ARGS[0] -s charge_on global:run_type=Misc
```

Parser rules:

- Lines starting with `#` and blank lines are ignored.
- Only lines beginning with `.\hobl.cmd` or `hobl.cmd` are parsed.
- `-p <profile>` is **ignored** — the profile comes from the job in
  `schedule.config.json`, not from the testplan.
- `-s <scenario>` marks the scenario name (required per row).
- All remaining `<key>=<value>` tokens are joined into a single
  space-separated `Parameters` string (this is what HOBLweb stores per row).
  Quoted values (`global:tools="a b c"`) are preserved verbatim and
  re-quoted on output if the value contains whitespace.
- `global:iterations=<N>` is also lifted out into the row's separate
  `Iterations` field (HOBLweb stores it both there and inside `Parameters`).
- The `studyType` for the HOBLweb plan body is inferred from the first
  workload row's `global:run_type` (the convention is that bracket rows use
  `Misc` and workload rows use `Power` / `Performance` / etc.). Override
  per-job with an explicit `"studyType"` field if needed.
- `planName` defaults to the testplan filename without extension. Override
  per-job with an explicit `"planName"` field if needed.

If a testplan does anything fancier than this list of invocations (loops,
variables, conditionals), the parser will skip non-matching lines and may
produce wrong output. Keep testplans literal. The comment at the top of
`testplans/power_workloads.ps1` —
*"All args are inlined (no PowerShell variables) so HOBLweb's text parser can
read tools/parameters correctly"* — applies to v2 too.

## Plan-row schema

The row shape emitted by [lib/testplan.ps1](lib/testplan.ps1) is **verified**
against a known-working stored plan on this server. Each row is:

| Field | Type | Notes |
|---|---|---|
| `Seq`        | int    | Always `0`. Reserved by HOBLweb for plan-internal sequencing. |
| `Enabled`    | string | Literal `"1"`. **Must be a string, not a bool** — HOBLweb's runner does `Enabled === "1"`; rows submitted as `true` are stored with `Enabled: null` and silently skipped, leaving only the auto-injected prep row visible. |
| `Scenario`   | string | Scenario name from `-s`. |
| `Parameters` | string | Single space-separated `key=value` string; values containing whitespace are double-quoted. |
| `Iterations` | string | Lifted from `global:iterations` if present, else `"1"`. |
| `Expand`     | array  | Empty `[]` (study-vars row IDs — not used by testplan flow). |
| `Expansions` | null   | HOBLweb populates this server-side. |
| `Meta`       | object | Empty `{}` on rows 1..N. On row 0, see below. |

Row `[0].Meta` carries the plan-wide settings:

| Field | Default | Notes |
|---|---|---|
| `StudyVars`             | `{}`     | Per-row study-var overrides; empty for testplan flow. |
| `PlanBasedStudyVars`    | `[]`     | List of plan-based study-var IDs; empty for testplan flow. |
| `StudyType`             | `""`     | Empty string — the *real* study type goes in the top-level `body.studyType`, not here. |
| `AutoResubmit`          | `N - 1`  | Set by `Set-HoblAutoResubmit` from `runsPerDay`. |
| `AutoResubmitRemaining` | `N - 1`  | Same value; HOBLweb decrements it per cycle. |
| `CheckPreps`            | `true`   | Always run prep on the new plan (cheap when caches hit). |
| `Scenarios`             | `null`   | HOBLweb populates this server-side. |

If any of these fields are missing, HOBLweb's `planController.Create`
NullReferenceExceptions and the POST returns `500`. The defaults above are
taken from a known-working stored plan and are kept in sync with HOBLweb in
[lib/testplan.ps1](lib/testplan.ps1).

### Diagnostic helper

If HOBLweb is updated and rejects rows after a server-side schema change,
capture a real plan and diff its row shape against what `-DryRun` prints:

```cmd
powershell -ExecutionPolicy Bypass -File tools\dump_plan.ps1 -PlanID 31
```

This writes `tools\plan_31.dump.json` with the exact JSON HOBLweb returned.
Update [lib/testplan.ps1](lib/testplan.ps1)'s row builder if the shape
changes.

## Config reference (`schedule.config.json`)

| Field | Default | Meaning |
|---|---|---|
| `hoblwebBaseUrl`    | `http://localhost` | HOBLweb root URL. |
| `logDir`            | `<scriptDrive>\hobl_results\_automation_logs` | Log + lock-file directory. Empty string = use the default (the drive `daily_run.ps1` lives on, per HOBL's `$scriptDrive` convention). |
| `logRetentionDays`  | `30` | Daily logs older than this are deleted at end of run. `0` = never delete. |
| `overlap`           | `"skip"` | If a previous day's plan for the same profile is still `Active`, skip submission. (Only `skip` is implemented today.) |
| `submit.timeoutSec` | `30` | Per-HTTP-call timeout. |
| `submit.maxAttempts`| `5`  | Max attempts per HOBLweb call before giving up. 4xx errors are NOT retried. |
| `submit.backoffSec` | `[5, 15, 60, 180, 600]` | Wait between retries (seconds), indexed by attempt-1. |
| `monitor.enabled`   | `true` | After submit, stay attached and poll HOBLweb until the chain finishes. Set `false` for fire-and-forget. Skipped automatically under `-DryRun`. |
| `monitor.intervalSec` | `45` | Poll cadence in seconds. |
| `monitor.maxHours`  | `8` | Hard cap on monitor lifetime; logs a `WARN` and detaches if exceeded. |
| `report.enabled`    | `true` | Build the weekly HTML report as scenarios finish. Set `false` to disable. |
| `report.dir`        | `logDir` | Where the weekly `.jsonl` ledger + `.html` report are written. Defaults to `logDir`. |
| `email.enabled`     | `true` | Allow the weekly report email. Set `false` to disable. |
| `email.to`          | required for email | Recipient list (`;`-separated). Overridden by `send_report_email.ps1 -To`. |
| `email.sendDay`     | `Friday` | Day of week the registered weekly email task fires. |
| `email.sendTime`    | `17:00` | Time (HH:MM, 24h) the registered weekly email task fires. |
| `jobs[].name`       | required | Free-text label used in logs. |
| `jobs[].profile`    | required | HOBLweb profile name (the DUT). |
| `jobs[].testplan`   | required | Path to a HOBL testplan `.ps1` file. Relative paths resolve to the repo root (the parent of `automation_v2\`). |
| `jobs[].runsPerDay` | required | `1` = single run; `N` sets `AutoResubmit = N-1`. |
| `jobs[].enabled`    | required | Set `false` to pause without removing. |
| `jobs[].planName`   | optional | Override the auto-derived plan name (default: testplan filename without extension). |
| `jobs[].studyType`  | optional | Override the auto-derived `studyType` (default: first non-`Misc` `global:run_type` value found in the testplan). |

## Logs

`daily_run.ps1` writes one log per **calendar day** at
`<logDir>\YYYYMMDD_daily.log` (UTF-8, append). A 3x/day schedule produces a
single grep-able file per day.

Each invocation is stamped with a `runId=YYYYMMDD-HHmmss` so multiple runs in
the same daily file can be told apart. Per-job lines record the testplan path,
the parsed scenario list, and the submit elapsed time, e.g.

```
2026-06-03 23:39:35 === run start id=20260603-233935; config=...; log=... ===
2026-06-03 23:39:38 >>> Job 'Pantherlake08_power_workloads' profile=Pantherlake08 testplan=testplans/power_workloads.ps1 runsPerDay=3
2026-06-03 23:39:38     testplan: C:\hobl\testplans\power_workloads.ps1
2026-06-03 23:39:38     parsed: planName=power_workloads studyType=Power rows=9; set Seq[0].Meta.AutoResubmit=2
2026-06-03 23:39:38     scenarios: charge_off, abl_standby, web, teams2_3x3_audio, teams2_3x3_video, youtube, enterprise_collab, mincp_base, charge_on
2026-06-03 23:39:39     submit OK; elapsed=0.42s; redirect=/plan/Plans
2026-06-03 23:39:40     verified: new PlanID=2051 state=Pending AutoResubmit=True
```

Per-scenario workload logs are written by HOBL itself into the usual
`<scriptDrive>\hobl_results\` folders — this layer doesn't duplicate them.

### Live progress monitor

When `monitor.enabled = true` (default) and you're not in `-DryRun`,
`daily_run.ps1` does **not** exit after submitting. It polls HOBLweb every
`monitor.intervalSec` seconds (default 45s) and writes one heartbeat line per
active chain showing the current PlanID, cycle index, plan state, **phase**
(`prep` / `scenario` / `teardown` / `queued` / `done`), and the row that's
currently executing:

```
2026-06-03 23:39:40     verified: new PlanID=2051 state=Pending AutoResubmit=True
--- monitor: tracking 1 chain(s); intervalSec=45; maxHours=8 ---
2026-06-03 23:40:25     [Pantherlake08_power_workloads] PlanID=2051 cycle=1/3 state=Active phase=prep scenario=prep status=RUNNING
2026-06-03 23:48:53     [Pantherlake08_power_workloads] PlanID=2051 row=prep RUNNING -> PASS
2026-06-03 23:48:54     [Pantherlake08_power_workloads] PlanID=2051 row=charge_off started
2026-06-03 23:48:54     [Pantherlake08_power_workloads] PlanID=2051 cycle=1/3 state=Active phase=scenario scenario=charge_off status=RUNNING
2026-06-03 23:52:53     [Pantherlake08_power_workloads] PlanID=2051 row=charge_off RUNNING -> PASS
2026-06-03 23:52:54     [Pantherlake08_power_workloads] PlanID=2051 row=teams2_3x3_audio started
...
2026-06-04 02:48:00     [Pantherlake08_power_workloads] PlanID=2053 cycle=3/3 state=Complete phase=done
2026-06-04 02:48:00     [Pantherlake08_power_workloads] chain complete: 3/3 cycles, last PlanID=2053 state=Complete
--- monitor: all chains finished. ---
```

Phase is **inferred** from live per-row Status returned by HOBLweb's
`/plan/ScenariosData` endpoint. HOBLweb auto-injects a scenario row literally
named `prep` at the head of every plan, which is how the monitor distinguishes
prep from a regular scenario:

| Plan state | Row signal | Phase |
|---|---|---|
| `Pending` | — | `queued` |
| terminal (`Complete`, `Errored`, `Terminated`, …) | — | `done` |
| `Active` | row named `prep` is `RUNNING` | `prep` |
| `Active` | any other row is `RUNNING` | `scenario` |
| `Active` | every row still `PENDING` (just started) | `prep` |
| `Active` | nothing `PENDING` and nothing `RUNNING` | `teardown` |
| `Active` | mid-flight between rows | `scenario` |

In addition to the per-tick heartbeat line shown above, the monitor emits a
**per-row transition line** any time a row's Status changes:

- `PENDING -> RUNNING` → `[name] PlanID=N row=X started`
- `RUNNING -> PASS` → `[name] PlanID=N row=X RUNNING -> PASS`
- `RUNNING -> FAIL` / `TERMINATED` / `SKIPPED` / etc. → same shape, but logged
  with a ` WARN - ` prefix (yellow in the host) so non-PASS outcomes stand out.

These transition lines are independent of the heartbeat, so a row that fails
or is skipped never gets silently absorbed by a later `RUNNING` row in the
same poll.

The monitor exits when every chain reaches its target cycle count and a
terminal plan state (`Complete`, `Errored`, `Terminated`, …), when a chain
hits a hard-stop state early (`Errored`, `Failed`, `Terminated`, `Cancelled`,
`Stopping`, `Aborted`, …) — in which case the chain is logged as
` WARN - monitor: chain '...' stopped early ...` and marked done before
reaching `runsPerDay` — or when `monitor.maxHours` elapses (logs a `WARN` and
detaches; HOBLweb keeps running regardless). Duplicate consecutive heartbeat
lines are suppressed; a heartbeat is forced every 2 ticks (~90s at the
default interval) so the log shows it's still attached even when nothing has
changed (e.g. a long prep phase).

Set `monitor.enabled = false` to revert to fire-and-forget behavior (useful
for fast manual smoke tests).

## Weekly HTML report

As plans run, the monitor records every finished scenario into a **per-week
ledger**, and a matching **HTML report** is re-rendered from it. Both live in
`logDir` (next to the daily logs), one pair per ISO week (Mon–Sun):

```
<logDir>\weekly_report_2026-W24.jsonl   append-only data (source of truth)
<logDir>\weekly_report_2026-W24.html    the rendered report
```

The HTML shows a headline summary — **Pass rate %, Passed / Failed /
Terminated / Total** — then a **Needs attention** block listing only the
failed/terminated rows, **By DUT** and **By scenario** pass-rate tables, and
finally an **All scenarios** table you can **sort** (click any column) and
**filter** (by status, DUT, scenario name, or hide prep). The auto-injected
`prep` row is greyed and excluded from all counts. Status is bucketed:

| Bucket | HOBLweb row statuses |
|---|---|
| Passed     | `PASS`, `PASSED` |
| Failed     | `FAIL`, `FAILED`, `ERROR`, `ERRORED` |
| Terminated | `TERMINATED`, `CANCELLED`, `ABORTED`, `STOPPED` |
| Other      | anything else still terminal (e.g. `SKIPPED`) — counted in Total only |

Pass rate excludes `Other` from its denominator (`Passed / (Passed + Failed +
Terminated)`) — a skipped row is neither a pass nor a failure. Sorting and
filtering are plain client-side JavaScript with no external dependencies, so
the `.html` stays a single portable file.

### How it updates

- **Live, during a run.** When `monitor.enabled = true`, each scenario is
  appended to the ledger the moment it reaches a terminal status, and the HTML
  is regenerated. The current week's report is always up to date while
  `daily_run.ps1` is attached.
- **The HTML is never edited in place** — it's a fresh render of the ledger
  every time, so a crash mid-write can't corrupt it.
- **Scope is the automation's own plans.** `daily_run.ps1` writes a `plan`
  marker per submitted PlanID, so the report (and any backfill) only counts
  plans this automation submitted — not manual UI submissions on the same DUT.
- **Binned by start time.** A scenario that starts Sun 23:50 lands in that
  week even if it finishes after midnight.

### Rebuilding / backfilling on demand

If `monitor.enabled = false`, or the monitor detached early (`monitor.maxHours`),
some scenario rows won't have been captured live. Rebuild any week from the
ledger — and optionally pull the gaps from HOBLweb — with
[generate_report.ps1](generate_report.ps1):

```cmd
:: Rebuild THIS week's HTML from the ledger:
powershell -ExecutionPolicy Bypass -File generate_report.ps1

:: Rebuild and also pull anything the monitor missed from HOBLweb:
powershell -ExecutionPolicy Bypass -File generate_report.ps1 -Backfill

:: A specific past week, then open it in the browser:
powershell -ExecutionPolicy Bypass -File generate_report.ps1 -Week 2026-W22 -Open
```

Backfill is scoped: it only fetches PlanIDs already known to be the
automation's (from the ledger's `plan` markers and their AutoResubmit-chain
successors), so it never pulls in unrelated manual plans.

### Importing from daily logs

When HOBLweb no longer has the plans (its DB was reset, or the runs happened on
a **different host** whose `*_daily.log` files you've copied in), HOBLweb
backfill can't help — but the daily logs still contain every scenario result.
`-ImportLogs` reconstructs results from those logs and writes them into the
matching weekly ledgers, then rebuilds every affected week's HTML:

```cmd
:: Import all *_daily.log in the report dir, rebuild affected weeks:
powershell -ExecutionPolicy Bypass -File generate_report.ps1 -ImportLogs

:: Import logs from a different folder (e.g. copied from another host):
powershell -ExecutionPolicy Bypass -File generate_report.ps1 -ImportLogs -LogDir D:\incoming_logs
```

Each result is binned into its ISO week by the scenario's start time, so a run
spanning two weeks lands in the right reports. The import is **idempotent and
safe to mix with live data**: it de-duplicates by `PlanID + scenario name`, so
a scenario already recorded by the live monitor is never double-counted — the
import only fills genuine gaps (plans or rows the monitor never saw). Imported
rows are tagged `source=logimport` in the ledger.

Disable reporting entirely with `report.enabled = false`.

## Weekly report email

[send_report_email.ps1](send_report_email.ps1) emails the weekly report using
the DUT's **already-signed-in Outlook desktop account** — no SMTP, no stored
password. Because Outlook sends as the logged-in user, internal distribution
lists accept the mail. The email **body** is an email-safe static summary (pass
rate, the failures list, per-DUT breakdown); the full interactive `.html`
report is **attached** (email clients strip the JavaScript that powers the
in-report sort/filter, so those controls only work when the attachment is
opened in a browser).

Recipient and schedule come from the `email` block in
[schedule.config.json](schedule.config.json):

```json
"email": {
    "enabled":  true,
    "to":       "wssi-fun-idc@microsoft.com",
    "sendDay":  "Friday",
    "sendTime": "17:00"
}
```

Send on demand, or register the weekly task:

```cmd
:: Send THIS week's report now (refreshes the HTML first):
powershell -ExecutionPolicy Bypass -File send_report_email.ps1 -Refresh

:: Override the recipient ad-hoc (;-separated):
powershell -ExecutionPolicy Bypass -File send_report_email.ps1 -To "a@x.com;b@y.com"

:: Email a specific past week:
powershell -ExecutionPolicy Bypass -File send_report_email.ps1 -Week 2026-W22

:: Register the recurring weekly email (runs as the logged-in user):
powershell -ExecutionPolicy Bypass -File send_report_email.ps1 -Register -Day Friday -Time 17:00
```

You usually don't need to register it separately: **`register_schedule.ps1`
offers to set up the weekly email task in the same run** (after registering the
daily task it asks *"Also register the weekly report email task?"*, defaulting
to the config's `email` block). The two remain **separate** scheduled tasks
because the daily run is SYSTEM while the email task must run as the logged-in
user — but you only do one registration pass.

Important: the weekly email task runs **as the logged-in user**, not SYSTEM —
Outlook COM needs an interactive session. This suits lab DUTs that auto-login
and stay awake. (This is different from the SYSTEM-run `daily_run` task.)

One environment caveat: Outlook's "programmatic access" guard *can* prompt
before an unattended `.Send()`. On a managed DUT with healthy, current Defender
it stays silent (verified on this host). If it ever blocks sending, the
supported fix is Group Policy → *Configure programmatic access* → **Never warn**.

Disable the email entirely with `email.enabled = false` (or just don't register
the task).

## Exit codes

`daily_run.ps1`:

| Code | Meaning |
|---|---|
| `0` | All enabled jobs submitted (or correctly skipped). Includes `-DryRun` success. |
| `1` | Some jobs succeeded or were skipped, but at least one failed. |
| `2` | Every enabled job failed. |
| `3` | Pre-flight failed: HOBLweb unreachable, Poke task missing, config invalid, log dir not writable, or another `daily_run` already holds the lock. |

## Edge-case handling

- **Single-instance lock** — `<logDir>\daily_run.lock` records `PID|StartUTC`.
  If the recorded PID is dead, the lock is reclaimed; if alive, the new run
  exits with code `3`.
- **HOBLweb down** — pre-flight detects this and exits `3` without touching
  state.
- **Poke task missing** — when `Get-ScheduledTask` / `schtasks` reports the
  task is genuinely absent, pre-flight exits `3`. ACL-hidden ⇒ WARN+proceed.
- **Testplan missing or unparseable** — job logs `ERROR` and is counted as
  failed; other jobs continue.
- **Profile already busy** — when `overlap = skip`, the job logs `WARN` and is
  counted as skipped (not failed).
- **Transient HTTP errors** — `submit.maxAttempts` retries with the configured
  backoff. 4xx errors are treated as permanent and not retried.
- **Verification mismatch** — after submit, the script re-lists plans, locates
  the freshly-submitted plan (highest PlanID for the profile+name), and warns
  if `runsPerDay > 1` was requested but HOBLweb's `AutoResubmit` flag on the
  new plan is false.
- **Missed trigger (host asleep)** — Task Scheduler fires it as soon as the host
  comes back (`StartWhenAvailable`); `WakeToRun` also wakes the host at the
  scheduled time when possible. `MultipleInstances=IgnoreNew` prevents pile-up
  if the catch-up trigger and a regular trigger collide.

## Roadmap

Future stages (not implemented yet):

- **Result extraction** from `<scriptDrive>\hobl_results\` once HOBLweb finishes a cycle.
- Upload of those results to a cloud server.
- Parser support for HOBL's `--params <file.ini>` style (currently only inline
  `key=value` tokens are recognised).
