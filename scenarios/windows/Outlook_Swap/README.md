# Outlook Swap

HOBL scenario for an interactive, unlocked **English Windows desktop**. Both
Outlook classic and the new Outlook app should already be installed and configured.
WinAppDriver must be available through the normal HOBL DUT tools.

Run from the HOBL repository root using your DUT profile:

```powershell
.\hobl.cmd -p <profile.ini> -s Outlook_Swap
```

Select the desired Outlook with these parameters (not an automatic toggle):

| `outlook-classic` | `Outlook` | Result |
|---|---|---|
| 0 | 1 | New Outlook only |
| 1 | 0 | Outlook classic only (default) |
| 0 | 0 | Outlook classic only |
| 1 | 1 | Outlook classic only |

Both parameters accept only `0` or `1`; equal values select classic Outlook.
Parameter names are case-sensitive: use `Outlook` with a capital `O`.
This replaces the previous `target=auto/classic/new` setting.
The selection works regardless of whether classic, new, both, or neither are
initially pinned. An already-correct pin is retained; the other Outlook is unpinned.

```powershell
.\hobl.cmd -p <profile.ini> -s Outlook_Swap Outlook_Swap:outlook-classic=1 Outlook_Swap:Outlook=0
.\hobl.cmd -p <profile.ini> -s Outlook_Swap Outlook_Swap:outlook-classic=0 Outlook_Swap:Outlook=1
```

Or set the parameters in your DUT profile:

```ini
[Outlook_Swap]
outlook-classic = 0
Outlook = 1
```

The scenario discovers application identities with `Get-StartApps`, checks actual
pin state through taskbar context menus, pins the destination through the Windows
Applications folder if necessary, and unpins the other version. It secures the
destination pin first so a failed pin operation does not remove the original pin.
The Applications folder is attached before type-to-select brings the destination
into view; the app item is then located through that window's automation session.
Its context menu is opened by directly right-clicking that item rather than
relying on desktop keyboard focus.
Once exactly the intended Outlook is pinned, it clicks that taskbar icon, waits for
the app's main window, maximizes it, verifies maximization, and keeps it open for
2 seconds before requesting a graceful close. The window identity and maximized
state are rechecked after the hold. The pin is checked again after the window closes.

Close existing Outlook windows before running. The scenario refuses to start
with open Outlook windows to avoid closing user work. It does not force-kill
processes, edit the taskbar registry, restart Explorer, install apps, or automate
sign-in. Background Outlook processes may remain after the window closes.
Windows pinning policies, unfamiliar taskbar identities, missing apps, first-run
dialogs, or blocked close requests cause a visible scenario failure rather than
a reported success. A failure after pinning leaves the last verified pin state;
there is no automatic rollback.

`Outlook_Swap:timeout=60` controls each UI/window wait in seconds (1–3600).
Taskbar scans retry with freshly acquired elements when the taskbar refreshes
or temporarily disappears. A completed scan with no Outlook buttons is valid;
an unreadable taskbar fails explicitly when the UI timeout expires.
Successful runs write `outlook_swap_results.csv` to the HOBL results directory
and log a metrics banner. `scenario_runtime` is wall-clock seconds covering
discovery, pin changes, launch, maximize, the 2-second hold, close, and final
pin verification.
