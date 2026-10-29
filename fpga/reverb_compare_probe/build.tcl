set project_dir [file dirname [file normalize [info script]]]
file mkdir [file join $project_dir impl]
file copy -force [file join $project_dir src process_config.json] [file join $project_dir impl reverb_compare_probe_process_config.json]
open_project [file join $project_dir reverb_compare_probe.gprj]
set_option -top_module reverb_compare_probe_top
run all
exit
