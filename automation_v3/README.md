# HOBL Automation V3

Automation V3 runs each DUT/job independently. It is installed alongside V2 and does not modify or stop V2 tasks or active HOBLweb plans.

## Architecture

- One immutable job `id` per configured DUT/job.
- One Windows scheduled task, PowerShell worker, exclusive lock, state tree, log tree, and report ledger per job.
- Different profiles can run concurrently.
- A duplicate start for the same job is rejected by that job's lock and Task Scheduler `IgnoreNew` policy.
- Existing V2 testplan parsing, HOBLweb submission, retry, monitor, report, and Outlook libraries are reused.
- Submitted plans use the configured or testplan base name in HOBLweb (for example, `mincp_only`, `hobl`, or `etl_trace`). V3 correlates creation using the profile and the PlanID baseline captured immediately before submission.
- Workers never send individual emails. When an exact email date/time is configured, the coordinator waits until that time, merges the isolated ledgers, records incomplete DUT states, and queues one combined snapshot email.

## Files

| File | Purpose |
|---|---|
| `automation.config.json` | Shared defaults and per-job ID, profile, testplan, runs, and schedule. |
| `register_schedule.ps1` | V2-compatible guided setup for one or more independent DUTs, their common cadence, coordinator, and email helper. |
| `setup_job.ps1` | V2-style interactive setup: add a DUT, validate it, register only its task, and optionally start immediately. |
| `worker.ps1` | Submits and monitors exactly one job. Supports `-DryRun` and `-Resume`. |
| `validate_config.ps1` | Validates IDs, profiles, testplans, run counts, and schedules. |
| `register_tasks.ps1` | Registers one SYSTEM task per enabled job and the report coordinator. |
| `manage_task.ps1` | Starts, enables, disables, or safely removes one job task. |
| `remove_job.ps1` | Safely removes one job configuration and task while retaining runtime history. |
| `status.ps1` | Shows task, run, PlanID, scenario, schedule, and error status for every job. |
| `coordinator.ps1` | Builds one combined daily report when expected jobs are terminal. |
| `send_report_email.ps1` | Registers/drains the interactive-user Outlook email helper. |
| `lib/common.ps1` | Configuration, paths, atomic state, logging, and exclusive-lock helpers. |

The supplied `pantherlake07-mincp`, `purwa-dc-mincp`, and `heracles-mincp` entries are disabled examples. They are not registered, started, or expected in combined reporting unless explicitly enabled.

An optional WPF front end is available in `automation_v3/ui`. It configures these same V3 jobs and independent tasks, with HOBL, MinCP, and ETL trace scenario sets available for every approved DUT; use its `-Preview` mode to inspect the interface without making changes.

## Runtime layout

Runtime data defaults to `C:\hobl_results\automation_v3`:

```text
jobs\<job-id>\
  worker.lock
  logs\
  state\current.json
  state\runs\<run-id>.json
  report\daily\
coordinator\
  state\
  reports\daily\
  reports\pending_email\
```

## Safe rollout

1. Configure and register V3 with the same guided flow as V2 from Administrator PowerShell:
   `powershell -ExecutionPolicy Bypass -File .\automation_v3\register_schedule.ps1`

   Or use the V3 WPF interface:
   `powershell -ExecutionPolicy Bypass -File .\automation_v3\ui\register_schedule_wpf.ps1`

   This asks for cadence first, then whether to replace the enabled DUT set. Choosing `Y` asks for the number of DUTs and each profile, testplan, and run count. Each DUT receives its own independent task. Choosing `N` keeps the enabled DUT set and only updates their schedules. Use `-WhatIf` for a no-write preview.

   To add or update only one DUT instead, run:
   `powershell -ExecutionPolicy Bypass -File .\automation_v3\setup_job.ps1`

   It prompts for the HOBLweb profile/DUT name, testplan, runs, schedule, stable job ID, whether existing jobs stay enabled, and whether to start now. The DUT must match a `C:\profiles\<name>.ini` profile. Matching is case-insensitive and the canonical filename casing is saved, but spaces, hyphens, and other punctuation must match exactly. V3 reads that profile's `global:hobl_path` and confirms every testplan scenario exists in that runtime before saving or submitting. When old jobs are disabled, their future task triggers are disabled without stopping any running worker or HOBLweb plan. The configuration is backed up before every change and restored if task registration fails.

   To validate all answers without changing configuration or Task Scheduler, append `-WhatIf`. Use `-ConfigOnly` only when intentionally saving configuration without registering tasks.

   At the existing-job prompt, answer `Y` to keep previously added DUTs scheduled independently alongside the new DUT. Answer `N` to disable their future scheduled starts. Neither choice stops a worker or HOBLweb plan already running.

   A stable job ID is intentionally reusable. If the entered ID already exists, answer `Y` to update its DUT, testplan, run count, schedule, and scheduled task. For non-interactive use, pass `-UpdateExisting`.

2. Validate configuration:
   `powershell -ExecutionPolicy Bypass -File .\automation_v3\validate_config.ps1`
3. Parse one job without submission:
   `powershell -ExecutionPolicy Bypass -File .\automation_v3\worker.ps1 -JobId pantherlake07-mincp -DryRun`
4. Preview task registration without changing Task Scheduler:
   `powershell -ExecutionPolicy Bypass -File .\automation_v3\register_tasks.ps1 -JobId pantherlake07-mincp -WhatIf`
5. In Administrator PowerShell, register job and coordinator tasks:
   `powershell -ExecutionPolicy Bypass -File .\automation_v3\register_tasks.ps1 -All`
6. As the logged-in Outlook user, register the V3 email helper:
   `powershell -ExecutionPolicy Bypass -File .\automation_v3\send_report_email.ps1 -Register`
7. Start one selected job:
   `powershell -ExecutionPolicy Bypass -File .\automation_v3\manage_task.ps1 -Action Start -JobId pantherlake07-mincp`
8. Check all jobs:
   `powershell -ExecutionPolicy Bypass -File .\automation_v3\status.ps1`

Keep the V2 scheduled task enabled until V3 dry-run and controlled concurrency tests pass. Do not schedule V2 and V3 to submit the same profile at the same time; profile overlap protection will skip duplicates, but parallel operation should use separate validation profiles or times.

## State behavior

Clean terminal state is `Completed`. `Failed`, `Cancelled`, and cutoff-expired `NeverStarted` runs can produce an incomplete report. `TimedOut`, `BlockedByActivePlan`, and `SubmissionUnknown` are not considered terminal until HOBLweb reconciliation confirms there is no active or pending related plan.

If a saved state is `Submitted`, `Monitoring`, or `TimedOut` and its `PlanID` still exists, a later worker invocation can resume monitoring rather than submit another plan. Use `-Resume` to request this explicitly.

Dry-run parses and validates a job without changing its authoritative state. A create request is reconciled by its profile, base plan name, and pre-submit PlanID baseline before any retry, reducing the risk that an HTTP timeout creates duplicate DUT work. Do not manually submit the same plan name to the same profile while a V3 submission is in progress.

Disabling or removing a scheduled task does not cancel its HOBLweb plan. Removal is refused while its Windows task is running.

Removal also checks worker locks and saved run state. For a saved
`BlockedByActivePlan` state, removal rechecks HOBLweb and is permitted only when
the referenced plan is terminal and the profile has no unfinished plans.
Missing plans, unknown states, or HOBLweb errors block removal. No HOBLweb plan
is stopped, and runtime history is retained.

Lock status is determined by the operating system's file-sharing lock, not by
the presence of a file or a potentially reused PID. Status reports `Held`,
`Stale`, or `Free`. Removal ignores orphaned lock files but still checks the
scheduled task and saved run state; permission and other unexpected I/O errors
block removal. New worker/coordinator locks are deleted automatically when
their owning process closes or terminates. A new worker can atomically reuse
a stale file without deleting another worker's lock.
