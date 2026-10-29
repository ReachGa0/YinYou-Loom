set project_dir [file dirname [file normalize [info script]]]
file mkdir [file join $project_dir impl]
file copy -force [file join $project_dir src process_config.json] [file join $project_dir impl lissajous_demo_process_config.json]
open_project [file join $project_dir lissajous_demo.gprj]
set_option -top_module lissajous_demo_top
run all
exit
