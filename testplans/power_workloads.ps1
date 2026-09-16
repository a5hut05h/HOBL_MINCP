if ($ARGS[0] -eq $null) { return("Params .ini not supplied, please supply a params .ini parameter.") }

# ---------------------------------------------------------------------------
# power_workloads.ps1 - power-workload testplan (device-agnostic).
# PDU outlet/port, charge calls, and auto_recharge thresholds all come from
# the device profile, so the same plan runs across all devices.
# All args are inlined (no PowerShell variables) so HOBLweb's text parser
# can read tools/parameters correctly in the "Load Plan" view.
# ---------------------------------------------------------------------------

# Pre: unplug charger (PDU outlet/port comes from the device profile)
.\hobl.cmd -p $ARGS[0] -s charge_off global:run_type=Misc global:post_run_delay=30

# Workload 1: ABL standby
.\hobl.cmd -p $ARGS[0] -s abl_standby global:iterations=1 global:attempts=2 global:run_type=Power global:tools="display auto_recharge power_light powercfg"

# Workload 2: Web
.\hobl.cmd -p $ARGS[0] -s web global:iterations=1 global:attempts=2 global:run_type=Power global:tools="display power_light auto_recharge powercfg"

# Workload 3: Teams2 3x3 audio
.\hobl.cmd -p $ARGS[0] -s teams2_3x3_audio global:iterations=1 global:attempts=2 global:run_type=Power global:tools="display power_light auto_recharge powercfg"

# Workload 4: Teams2 3x3 video
.\hobl.cmd -p $ARGS[0] -s teams2_3x3_video global:iterations=1 global:attempts=2 global:run_type=Power global:tools="display power_light auto_recharge powercfg"

# Workload 5: YouTube
.\hobl.cmd -p $ARGS[0] -s youtube global:iterations=1 global:attempts=2 global:run_type=Power global:tools="auto_recharge display power_light powercfg"

# Workload 6: Enterprise collab
.\hobl.cmd -p $ARGS[0] -s enterprise_collab global:iterations=1 global:attempts=2 global:run_type=Power global:tools="display auto_recharge power_light powercfg"

#mincp_base workload: copilot_query productivity file_explorer start_launch
.\hobl.cmd -p $ARGS[0] -s mincp_base global:run_type=Power global:iterations=1 global:tools="run_report display auto_recharge power_light powercfg" mincp_base:perf_run=1 mincp_base:mincp_workloads="copilot_query productivity file_explorer start_launch" mincp_base:web_workload="amazonsg amazongot amazonvacuum googleimagesapollo googleimageslondon googlersearchbelgium googlesearchsuperbowl instagram reddit theverge wikipedia youtubenas youtube" mincp_base:simple_office_launch=1 mincp_base:short_typing=1 audio_volume:volume=50 mincp_base:enable_mincp_productivity_trace=1 teams:access_key=3JVBW7x0qREHzTaYja1G6UmtqSN52cqvHuwPexktuhXMVBiil6r7Fw==

# Post: plug charger back in (PDU outlet/port comes from the device profile)
.\hobl.cmd -p $ARGS[0] -s charge_on global:run_type=Misc
