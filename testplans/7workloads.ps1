if ($ARGS[0] -eq $null) { return("Params .ini not supplied, please supply a params .ini parameter.") }

# ---------------------------------------------------------------------------
# intern_study.ps1 - 5-scenario intern testplan.
# All args are inlined (no PowerShell variables) so HOBLweb's text parser
# can read tools/parameters correctly in the "Load Plan" view.
# ---------------------------------------------------------------------------

# Pre: unplug charger (outlet 3)
.\hobl.cmd -p $ARGS[0] -s charge_off global:run_type=Misc global:post_run_delay=60 global:charge_off_call="powershell -ExecutionPolicy Bypass -File C:\pdu_controller\apc_pdu_controller.ps1 off 3 -PduIp 10.150.18.38 -Community hobl"

# Workload 1: ABL standby
.\hobl.cmd -p $ARGS[0] -s abl_standby global:iterations=1 global:attempts=2 global:run_type=Power global:tools="display_brightness auto_recharge power_light" display:brightness=56 auto_recharge:charge_threshold=30 auto_recharge:resume_threshold=95 auto_recharge:charge_on_call="C:\pdu_controller\apc_pdu_controller.ps1 on 3 -PduIp 10.150.18.38 -Community hobl" auto_recharge:charge_off_call="C:\pdu_controller\apc_pdu_controller.ps1 off 3 -PduIp 10.150.18.38 -Community hobl"

# Workload 2: Web
.\hobl.cmd -p $ARGS[0] -s web global:iterations=1 global:attempts=2 global:run_type=Power global:tools="display_brightness power_light auto_recharge" display:brightness=56 auto_recharge:charge_threshold=30 auto_recharge:resume_threshold=95 auto_recharge:charge_on_call="C:\pdu_controller\apc_pdu_controller.ps1 on 3 -PduIp 10.150.18.38 -Community hobl" auto_recharge:charge_off_call="C:\pdu_controller\apc_pdu_controller.ps1 off 3 -PduIp 10.150.18.38 -Community hobl"

# Workload 3: Teams2 3x3 audio
.\hobl.cmd -p $ARGS[0] -s teams2_3x3_audio global:iterations=1 global:attempts=2 global:run_type=Power global:tools="display_brightness power_light auto_recharge" display:brightness=56 auto_recharge:charge_threshold=30 auto_recharge:resume_threshold=95 auto_recharge:charge_on_call="C:\pdu_controller\apc_pdu_controller.ps1 on 3 -PduIp 10.150.18.38 -Community hobl" auto_recharge:charge_off_call="C:\pdu_controller\apc_pdu_controller.ps1 off 3 -PduIp 10.150.18.38 -Community hobl"

# Workload 4: Teams2 3x3 video
.\hobl.cmd -p $ARGS[0] -s teams2_3x3_video global:iterations=1 global:attempts=2 global:run_type=Power global:tools="display_brightness power_light auto_recharge" display:brightness=56 auto_recharge:charge_threshold=30 auto_recharge:resume_threshold=95 auto_recharge:charge_on_call="C:\pdu_controller\apc_pdu_controller.ps1 on 3 -PduIp 10.150.18.38 -Community hobl" auto_recharge:charge_off_call="C:\pdu_controller\apc_pdu_controller.ps1 off 3 -PduIp 10.150.18.38 -Community hobl"

# Workload 5: YouTube
.\hobl.cmd -p $ARGS[0] -s youtube global:iterations=1 global:attempts=2 global:run_type=Power global:tools="auto_recharge display_brightness power_light" display:brightness=56 auto_recharge:charge_threshold=30 auto_recharge:resume_threshold=95 auto_recharge:charge_on_call="C:\pdu_controller\apc_pdu_controller.ps1 on 3 -PduIp 10.150.18.38 -Community hobl" auto_recharge:charge_off_call="C:\pdu_controller\apc_pdu_controller.ps1 off 3 -PduIp 10.150.18.38 -Community hobl"

# Workload 6: Enterprise collab
.\hobl.cmd -p $ARGS[0] -s enterprise_collab global:iterations=1 global:attempts=2 global:run_type=Power global:tools="display_brightness auto_recharge power_light" display:brightness=56 auto_recharge:charge_threshold=30 auto_recharge:resume_threshold=95 auto_recharge:charge_on_call="C:\pdu_controller\apc_pdu_controller.ps1 on 3 -PduIp 10.150.18.38 -Community hobl" auto_recharge:charge_off_call="C:\pdu_controller\apc_pdu_controller.ps1 off 3 -PduIp 10.150.18.38 -Community hobl"

#mincp_base workload: copilot_query productivity file_explorer start_launch
.\hobl.cmd -p $ARGS[0] -s mincp_base global:run_type=Power global:tools="run_report display_brightness auto_recharge power_light" mincp_base:perf_run=1 mincp_base:mincp_workloads="copilot_query productivity file_explorer start_launch" mincp_base:web_workload="amazonsg amazongot amazonvacuum googleimagesapollo googleimageslondon googlersearchbelgium googlesearchsuperbowl instagram reddit theverge wikipedia youtubenas youtube" display_brightness:brightness=56 mincp_base:simple_office_launch=1 mincp_base:short_typing=1 auto_recharge:charge_threshold=30 auto_recharge:resume_threshold=95  audio_volume:volume=50 auto_recharge:charge_on_call="C:\pdu_controller\apc_pdu_controller.ps1 on 3 -PduIp 10.150.18.38 -Community hobl" auto_recharge:charge_off_call="C:\pdu_controller\apc_pdu_controller.ps1 off 3 -PduIp 10.150.18.38 -Community hobl" mincp_base:enable_mincp_productivity_trace=1 teams:access_key=3JVBW7x0qREHzTaYja1G6UmtqSN52cqvHuwPexktuhXMVBiil6r7Fw==

# Post: plug charger back in (outlet 3)
.\hobl.cmd -p $ARGS[0] -s charge_on global:run_type=Misc global:charge_on_call="powershell -ExecutionPolicy Bypass -File C:\pdu_controller\apc_pdu_controller.ps1 on 3 -PduIp 10.150.18.38 -Community hobl"
