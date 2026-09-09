# IPCM HOBL Integration

IPCM is an optional host-side HOBL tool. It runs only for scenario rows that
include `ipcm_log` in their selected tools.

## Job configuration

For a scenario row that needs IPCM collection:

1. Select `ipcm_log` in the row's **Tools** field.
2. Set the IPCM values in the row's **Parameters** field:

   ```text
  ipcm_log:duration=30 ipcm_log:sample_period=500 ipcm_log:transfer_to_console=false
   ```

Supported duration values, in minutes:

```text
0 0.5 1 2 3 5 10 15 20 30
```

`0` disables IPCM automatic stop. HOBL stops IPCM when the first scenario
attempt ends. Positive durations begin when Log is selected.

Supported sample periods, in milliseconds:

```text
20 50 100 200 500 1000
```

`transfer_to_console` defaults to `false`. Set it to `true` to preserve IPCM
when an RDP session is manually disconnected. If the RDP connection remains
open, HOBL does nothing and the user can continue working. If the user closes
RDP without signing out, an IPCM-owned watchdog detects the disconnect and runs
`tscon` to move the existing Windows session to the physical console. The
watchdog remains active for the full HOBL process, including gaps between
iterations, so the same user can reconnect and disconnect RDP multiple times.
It requires the session to remain disconnected for 10 seconds before running
`tscon`, preventing transient reconnect states from forcing the user back to
the console.

If `ipcm_log` is not selected, the scenario runs without IPCM and existing HOBL
behavior is unchanged.

## Runtime behavior

- HOBL must be started as Administrator because IPCM requires host keyboard
  automation.
- For HOBL UI runs, the backend that executes HOBL must run in the active,
  unlocked user session; elevating only the UI shortcut does not move a
  service-hosted backend onto the interactive desktop.
- IPCM starts when HOBL initializes the selected tool, before scenario setup or
  DUT workload activity begins.
- If Preview opens the device dialog, automation selects the cached
  `Board SN 001_FBVDDQIN.json` configuration and confirms it.
- After selecting Preview, automation returns focus to the previous HOBL
  window and starts the workload without waiting for IPCM.
- A detached timer worker waits 30 seconds for Preview readings to stabilize,
  briefly activates IPCM, selects Log, and restores the window that was active
  before the Log action.
- Positive durations start when Log is selected. IPCM uses its own automatic
  duration to stop logging, so it does not take foreground focus when the
  duration expires.
- When `transfer_to_console=true`, leaving RDP connected does not interrupt the
  user. Manually disconnecting RDP triggers console transfer so HOBL and IPCM
  continue in the same Windows session. The process-wide watchdog handles every
  reconnect/disconnect cycle and protects the 30-second interval between
  Preview and Log, gaps between iterations, and later scenario iterations.
- Console transfer leaves the Windows desktop unlocked. Use it only on a
  physically secured lab machine. Signing out, locking Windows, sleeping, or
  shutting down still interrupts GUI automation.
- IPCM logs to an `IPCM` subfolder inside the scenario attempt's HOBL result
  directory.
- After automatic stop, the worker verifies both CSV files, waits 5 seconds,
  and closes IPCM without bringing it to the foreground.
- IPCM runs only for the first attempt in a HOBL result directory. If that
  attempt fails and HOBL retries, IPCM is not launched again for the retry.
- Failure or timeout during the first attempt cancels the timer worker and
  stops IPCM early. If failure occurs before Log starts, no CSV is expected.
- The direct Stop action is retained for failure cleanup and as a fallback if
  IPCM does not automatically finalize its files.
- The `IPCM` subfolder must contain both `ipcmview-log-*.csv` and
  `ipcmview-sum-*.csv` after finalization.
- `ipcm-diagnostic.json` at the attempt root records the plugin lifecycle. The
  `IPCM\ipcm-start-diagnostic.json` file records process, window, keyboard, and
  log-start stages for startup troubleshooting.
- `.ipcm-attempted.json` records that IPCM was already launched for this HOBL
  result directory. `.ipcm-session.json` records the owned IPCM and timer
  worker processes while collection is active.
- Failure and timeout cleanup stop only the IPCM process recorded for that
  result directory.

## Deployment path

The UI job's **HOBL Path** must point to the repository containing this tool.
For this installation, that path is:

```text
C:\HOBL_MINCP
```

If the UI points to another HOBL installation, such as
`C:\hobl_enterprise_minwin`, deploy `tools\ipcm_log.py` and the complete
`tools\ipcm` directory to that installation instead.
