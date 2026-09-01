if ($ARGS[0] -eq $null) {return("Params .ini not supplied, please supply a params .ini parameter.")}

.\hobl.cmd -p $ARGS[0] -s process_idle_tasks global:run_type=Prep global:post_run_delay=600
# .\hobl.cmd -p $ARGS[0] -s config_check
.\hobl.cmd -p $ARGS[0] -s charge_off global:run_type=Misc global:post_run_delay=300

.\hobl.cmd -p $ARGS[0] -s idle_desktop global:run_type=Power global:tools="+power_light" pre_run_delay=60
.\hobl.cmd -p $ARGS[0] -s cs_floor global:run_type=Power global:tools="+powercfg power_light"
.\hobl.cmd -p $ARGS[0] -s lvp global:run_type=Power global:tools="+power_light"

.\hobl.cmd -p $ARGS[0] -s charge_on global:run_type=Misc
.\hobl.cmd -p $ARGS[0] -s study_report global:run_type=Misc
