# build_bitstream.tcl -- batch synthesis + implementation + bitstream + reports.
# Usage: vivado -mode batch -source scripts/build_bitstream.tcl \
#          [-tclargs CLKS_PER_BIT SUFFIX]
#   default:            CLKS_PER_BIT=109 (921,600 baud), no suffix
#   2 Mbaud demo build: -tclargs 50 _2M
# Reports land in docs/reports/ (suffixed); bitstream copies in docs/bitstreams/.

set script_dir [file dirname [file normalize [info script]]]
set proj_root  [file normalize [file join $script_dir ..]]

set clks 109
set suffix ""
if {$argc >= 1} { set clks   [lindex $argv 0] }
if {$argc >= 2} { set suffix [lindex $argv 1] }
puts "BUILD-CFG: CLKS_PER_BIT=$clks suffix='$suffix'"

source [file join $script_dir add_sources.tcl]
set_property generic "CLKS_PER_BIT=$clks" [get_filesets sources_1]

set rpt_dir [file join $proj_root docs reports]
file mkdir $rpt_dir
file mkdir [file join $proj_root docs bitstreams]

reset_run synth_1
launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
  puts "BUILD-FAIL: synthesis did not complete"
  exit 1
}

launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
  puts "BUILD-FAIL: implementation did not complete"
  exit 1
}

open_run impl_1
report_utilization       -file [file join $rpt_dir utilization$suffix.rpt]
report_utilization -hierarchical -file [file join $rpt_dir utilization_hier$suffix.rpt]
report_timing_summary    -file [file join $rpt_dir timing_summary$suffix.rpt]
report_power             -file [file join $rpt_dir power$suffix.rpt]

set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set bit [file join [get_property DIRECTORY [get_runs impl_1]] kv_top.bit]
file copy -force $bit [file join $proj_root docs bitstreams kv_top$suffix.bit]
puts "BUILD-OK: WNS = $wns ns"
puts "bitstream: docs/bitstreams/kv_top$suffix.bit"
