if ($ARGS[0] -eq $null) { return("Params .ini not supplied, please supply a params .ini parameter.") }

# ---------------------------------------------------------------------------
# intern_teams2.ps1 - short 2-scenario testplan for scheduler smoke testing.
# All args are inlined (no PowerShell variables) so HOBLweb's text parser
# can read tools/parameters correctly in the "Load Plan" view.
# ---------------------------------------------------------------------------

# Pre: unplug charger (outlet 4)
.\hobl.cmd -p $ARGS[0] -s charge_off global:run_type=Misc global:post_run_delay=60 global:charge_off_call="powershell -ExecutionPolicy Bypass -File C:\pdu_controller\apc_pdu_controller.ps1 off 4 -PduIp 10.150.18.38 -Community hobl"

# Workload 1: Teams2 3x3 audio
.\hobl.cmd -p $ARGS[0] -s teams2_3x3_audio global:iterations=1 global:attempts=2 global:run_type=Power global:tools="auto_recharge display_brightness power_light powercfg" display:brightness=56 auto_recharge:charge_threshold=30 auto_recharge:resume_threshold=95 auto_recharge:charge_on_call="C:\pdu_controller\apc_pdu_controller.ps1 on 4 -PduIp 10.150.18.38 -Community hobl" auto_recharge:charge_off_call="C:\pdu_controller\apc_pdu_controller.ps1 off 4 -PduIp 10.150.18.38 -Community hobl"

# Workload 2: Teams2 3x3 video
.\hobl.cmd -p $ARGS[0] -s teams2_3x3_video global:iterations=1 global:attempts=2 global:run_type=Power global:tools="auto_recharge display_brightness power_light powercfg" display:brightness=56 auto_recharge:charge_threshold=30 auto_recharge:resume_threshold=95 auto_recharge:charge_on_call="C:\pdu_controller\apc_pdu_controller.ps1 on 4 -PduIp 10.150.18.38 -Community hobl" auto_recharge:charge_off_call="C:\pdu_controller\apc_pdu_controller.ps1 off 4 -PduIp 10.150.18.38 -Community hobl"

# Post: plug charger back in (outlet 4)
.\hobl.cmd -p $ARGS[0] -s charge_on global:run_type=Misc global:charge_on_call="powershell -ExecutionPolicy Bypass -File C:\pdu_controller\apc_pdu_controller.ps1 on 4 -PduIp 10.150.18.38 -Community hobl"
