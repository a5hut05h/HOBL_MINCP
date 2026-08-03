if ($ARGS[0] -eq $null) {return("Params .ini not supplied, please supply a params .ini parameter.")}

.\hobl.cmd -p $ARGS[0] -s charge_on global:run_type="Misc"
.\hobl.cmd -p $ARGS[0] -s wait_for_dut global:run_type="Misc"
.\hobl.cmd -p $ARGS[0] -s process_idle_tasks global:collection_enabled="0" daily_prep:timeout=7200 daily_prep:loops=1 global:run_type="Misc"
.\hobl.cmd -p $ARGS[0] -s reboot global:run_type="Misc"
.\hobl.cmd -p $ARGS[0] -s config_check global:run_type="Misc"
.\hobl.cmd -p $ARGS[0] -s recharge global:run_type="Misc"
.\hobl.cmd -p $ARGS[0] -s teams2_3x3_video teams:duration="43200" teams:meeting_time="800" teams:maintain_bots=1 teams:number_of_bots=9 global:rundown_mode=1 global:stop_soc=0 global:crit_batt_level=3 display_brightness:brightness=150nits screenshot:pause=3600 global:tools="+power_light auto_charge screenshot" global:run_type="Power"
.\hobl.cmd -p $ARGS[0] -s charge_on global:run_type="Misc"
.\hobl.cmd -p $ARGS[0] -s study_report global:run_type="Misc"
