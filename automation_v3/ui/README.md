# HOBL Automation V3 Scheduler UI

This folder provides a WPF interface for the independent-DUT Automation V3 implementation. It uses the production V3 configuration and scripts in the parent [automation_v3](..) folder; it does not modify or register V2 tasks.

## Launch

Double-click **HOBL-Scheduler.exe** in this folder and approve the Windows UAC
administrator prompt. The scheduler window opens without a PowerShell console.
The launcher requires elevation; it does not bypass UAC. If Windows asks for
administrator credentials, use an authorized administrator account.

Keep the EXE in this folder with `register_schedule_wpf.ps1` and the rest of the
repository. It launches the existing scripts rather than embedding a stale
copy, so script updates take effect without rebuilding the launcher. A desktop
shortcut to the EXE is supported; moving just the EXE is not.

Build or rebuild the EXE locally (no package downloads required):

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\automation_v3\ui\build_launcher.ps1
```

The generated EXE is unsigned and ignored by Git. Windows may show an unknown
publisher warning. The launcher reports startup failures in an error dialog.
Optional command-line switches are `--validate-only`, `--startup-check`, and
`--preview`; these still request administrator permission.

Alternatively, launch the script directly:

Open Windows PowerShell 5.1 as Administrator from the repository root:

```powershell
.\automation_v3\ui\register_schedule_wpf.ps1
```

Validate dependencies and configuration without opening the window or changing anything:

```powershell
.\automation_v3\ui\register_schedule_wpf.ps1 -ValidateOnly
```

Open a safe preview with save and task-management actions disabled:

```powershell
.\automation_v3\ui\register_schedule_wpf.ps1 -Preview
```

The UI reads and writes `automation_v3/automation.config.json`. A timestamped backup is created before each save.

## Workflow

1. Choose a common Once, Daily, Weekly, or Monthly schedule. Once requires a future run date and time and creates a non-recurring worker trigger.
2. In the required DUT list, check each available DUT to add. No scenario set is selected by default; explicitly choose exactly one of **HOBL scenarios**, **MinCP scenarios**, **MinCP New Outlook**, or **ETL trace scenarios**, then set its run count. **MinCP New Outlook** uses [Mincp_NewOutlook.ps1](../../testplans/Mincp_NewOutlook.ps1).
3. Existing configured DUTs are shaded and read-only so they cannot be scheduled twice. Adding another DUT preserves every existing DUT configuration and task.
4. When combined report email is enabled, enter the recipients and an exact future local send date and time.
5. Select **Save and register independent tasks**. Only newly checked DUTs receive new worker tasks; existing workers are not reconfigured.

Each enabled DUT receives its own `HOBL Automation V3 - <job-id>` SYSTEM task. V3 also ensures the shared coordinator task exists. The Outlook email helper is registered for the interactive user when email is enabled.

Before saving, new jobs are validated against their profile’s `global:hobl_path`, and every scenario in the selected testplan must exist in that runtime. V3 permits only one job per profile.

At the configured email date and time, the coordinator creates one combined snapshot. It records every expected DUT as completed, failed, running, or not started and then queues the report for Outlook delivery. Worker completion cannot send the report before that date and time.

For a Once schedule, the email date must match the DUT run date and its send time must be later than the DUT start time.

## Task management

Select a DUT row to view and manage its independent task:

- **Run selected** starts only that DUT.
- **Pause / Resume** disables or enables future starts without stopping active work.
- **Delete selected** safely removes the selected job and task, retains its runtime history, and makes that DUT available to add again.
- **Delete all** safely removes all inactive job configurations and tasks while retaining runtime history.
- **Open selected logs** opens that job's isolated log directory.

Changing or disabling jobs never stops an already-running worker or HOBLweb plan.

## Approved profiles

The profile list is restricted by `allowed_profiles.json`. A listed profile appears only when its matching `.ini` file exists under `C:\profiles`. Update the allowlist when onboarding another approved DUT.
