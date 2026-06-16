if ($ARGS[0] -eq $null) { return("Params .ini not supplied, please supply a params .ini parameter.") }

.\hobl.cmd -p $ARGS[0] -s charge_off global:run_type=Misc global:post_run_delay=60 global:charge_off_call="powershell -ExecutionPolicy Bypass -File C:\pdu_controller\apc_pdu_controller.ps1 off 3 -PduIp 10.150.18.38 -Community hobl"

.\hobl.cmd -p $ARGS[0] -s mincp_base global:tools="run_report display_brightness auto_recharge power_light" mincp_base:perf_run=1 mincp_base:mincp_workloads="copilot_query productivity file_explorer start_launch" mincp_base:web_workload="amazonsg amazongot amazonvacuum googleimagesapollo googleimageslondon googlersearchbelgium googlesearchsuperbowl instagram reddit theverge wikipedia youtubenas youtube" display_brightness:brightness=56 mincp_base:simple_office_launch=1 mincp_base:short_typing=1 auto_recharge:charge_threshold=30 auto_recharge:resume_threshold=95  audio_volume:volume=50 auto_recharge:charge_on_call="C:\pdu_controller\apc_pdu_controller.ps1 on 3 -PduIp 10.150.18.38 -Community hobl" auto_recharge:charge_off_call="C:\pdu_controller\apc_pdu_controller.ps1 off 3 -PduIp 10.150.18.38 -Community hobl" mincp_base:enable_mincp_productivity_trace=1 teams:access_key=3JVBW7x0qREHzTaYja1G6UmtqSN52cqvHuwPexktuhXMVBiil6r7Fw=="

.\hobl.cmd -p $ARGS[0] -s charge_on global:run_type=Misc global:charge_on_call="powershell -ExecutionPolicy Bypass -File C:\pdu_controller\apc_pdu_controller.ps1 on 3 -PduIp 10.150.18.38 -Community hobl"

