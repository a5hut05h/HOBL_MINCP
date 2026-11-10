if ($ARGS[0] -eq $null) {return("Params .ini not supplied, please supply a params .ini parameter.")}
#.\hobl.cmd -p $ARGS[0] -s process_idle_tasks global:run_type=Prep global:post_run_delay=0
.\hobl.cmd -p $ARGS[0] -s config_check
.\hobl.cmd -p $ARGS[0] -s charge_off global:run_type=Misc global:post_run_delay=300

#1
.\hobl.cmd -p $ARGS[0] -s teams2_1on1_audio global:iterations=1 global:attempts=2 global:run_type=Power global:module_name="teams2_1x1_aud_share" global:tools="+power_light auto_recharge" teams:bots_share_screen=1 teams:bots_send_audio=1 teams:send_audio=1

#GVC2
.\hobl.cmd -p $ARGS[0] -s teams2_1on1_audio global:iterations=1 global:attempts=2 global:run_type=Power global:module_name="teams2_1x1_aud_share" global:tools="+power_light auto_recharge" teams:bots_share_screen=1 teams:bots_send_audio=1 teams:send_audio=1 teams:send_video=0

#GVC3
.\hobl.cmd -p $ARGS[0] -s teams2_1on1_audio global:iterations=1 global:attempts=2 global:run_type=Power global:module_name="teams2_1x1_aud_share" global:tools="+power_light auto_recharge" teams:bots_send_audio=1 teams:send_audio=1 teams:send_video=0

.\hobl.cmd -p $ARGS[0] -s charge_on global:run_type=Misc
.\hobl.cmd -p $ARGS[0] -s study_report global:run_type=Misc
.\hobl.cmd -p $ARGS[0] -s version_report global:run_type=Prep global:post_run_delay=0
.\hobl.cmd -p $ARGS[0] -s notify global:run_type=Misc
