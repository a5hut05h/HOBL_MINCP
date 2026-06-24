if ($ARGS[0] -eq $null) {return("Params .ini not supplied, please supply a params .ini parameter.")}
.\hobl.cmd -p $ARGS[0] -s winbuilds_install global:run_type=Prep global:post_run_delay=0
.\hobl.cmd -p $ARGS[0] -s teams_install global:attempts=2 global:run_type=Prep global:post_run_delay=0
.\hobl.cmd -p $ARGS[0] -s msa_prep global:attempts=2 global:run_type=Prep global:post_run_delay=0
.\hobl.cmd -p $ARGS[0] -s system_prep global:run_type=Prep global:post_run_delay=0 daily_prep:run_idle_tasks=0
.\hobl.cmd -p $ARGS[0] -s store_prep global:attempts=3 global:run_type=Prep global:post_run_delay=0
.\hobl.cmd -p $ARGS[0] -s edge_install global:attempts=2 global:run_type=Prep global:post_run_delay=0
.\hobl.cmd -p $ARGS[0] -s web_prep global:attempts=2 global:run_type=Prep global:post_run_delay=0
.\hobl.cmd -p $ARGS[0] -s button_install global:attempts=2 global:run_type=Prep global:post_run_delay=0
.\hobl.cmd -p $ARGS[0] -s office_install global:attempts=2 global:run_type=Prep global:post_run_delay=0
.\hobl.cmd -p $ARGS[0] -s reboot global:run_type=Prep global:post_run_delay=0
.\hobl.cmd -p $ARGS[0] -s adaptive_color_disable global:attempts=2 global:run_type=Prep global:post_run_delay=0
.\hobl.cmd -p $ARGS[0] -s surface_app_prep global:attempts=2 global:run_type=Prep global:post_run_delay=0
.\hobl.cmd -p $ARGS[0] -s onedrive_prep global:attempts=2 global:run_type=Prep global:post_run_delay=0
.\hobl.cmd -p $ARGS[0] -s reboot global:run_type=Prep global:post_run_delay=0
.\hobl.cmd -p $ARGS[0] -s productivity_prep global:attempts=2 global:run_type=Prep global:post_run_delay=0
.\hobl.cmd -p $ARGS[0] -s cs_floor_prep global:attempts=2 global:run_type=Prep global:post_run_delay=0
.\hobl.cmd -p $ARGS[0] -s net_prep global:attempts=2 global:run_type=Prep global:post_run_delay=0
.\hobl.cmd -p $ARGS[0] -s config_check global:attempts=2 global:post_run_delay=0
.\hobl.cmd -p $ARGS[0] -s version_report global:attempts=2 global:run_type=Prep global:post_run_delay=0
.\hobl.cmd -p $ARGS[0] -s notify global:run_type=Misc
.\hobl.cmd -p $ARGS[0] -s run_hoblWG_if_preps_passed global:run_type=Misc
