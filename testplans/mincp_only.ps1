if ($ARGS[0] -eq $null) { return("Params .ini not supplied, please supply a params .ini parameter.") }

.\hobl.cmd -p $ARGS[0] -s charge_off global:run_type=Misc global:post_run_delay=60

# mincp_base workload: copilot_query productivity file_explorer start_launch
.\hobl.cmd -p $ARGS[0] -s mincp_base global:run_type=Power global:tools="run_report display auto_recharge power_light powercfg" mincp_base:perf_run=1 mincp_base:mincp_workloads="copilot_query productivity file_explorer start_launch" mincp_base:web_workload="amazonsg amazongot amazonvacuum googleimagesapollo googleimageslondon googlersearchbelgium googlesearchsuperbowl instagram reddit theverge wikipedia youtubenas youtube" mincp_base:simple_office_launch=1 mincp_base:short_typing=1 audio_volume:volume=50 mincp_base:enable_mincp_productivity_trace=1 teams:access_key=3JVBW7x0qREHzTaYja1G6UmtqSN52cqvHuwPexktuhXMVBiil6r7Fw==

# Post: plug charger back in (PDU outlet/port comes from the device profile)
.\hobl.cmd -p $ARGS[0] -s charge_on global:run_type=Misc