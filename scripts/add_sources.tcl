# add_sources.tcl -- idempotent source registration for kv_cache.xpr
#
# Usage (from any cwd):
#   vivado -mode batch -source scripts/add_sources.tcl
# or from an open Vivado Tcl console with the project already open:
#   source scripts/add_sources.tcl
#
# Adds rtl/*.v to sources_1, constraints/basys3.xdc to constrs_1 and
# sim/tb_*.v to sim_1, sets the synthesis and simulation tops, and refreshes
# compile order. Already-registered files are skipped, so re-running is safe.

set script_dir [file dirname [file normalize [info script]]]
set proj_root  [file normalize [file join $script_dir ..]]

# Open the project only if no project is currently open.
if {[catch {current_project}]} {
  open_project [file join $proj_root kv_cache.xpr]
}

proc add_one {fileset path} {
  # add_files errors if the file is already in the project: catch and skip.
  if {[catch {add_files -norecurse -fileset [get_filesets $fileset] $path} msg]} {
    puts "add_sources.tcl: skip [file tail $path] ($fileset): $msg"
  } else {
    puts "add_sources.tcl: added [file tail $path] -> $fileset"
  }
}

foreach f [lsort [glob -nocomplain [file join $proj_root rtl *.v]]] {
  add_one sources_1 $f
}

set xdc [file join $proj_root constraints basys3.xdc]
if {[file exists $xdc]} {
  add_one constrs_1 $xdc
} else {
  puts "add_sources.tcl: WARNING: $xdc not found"
}

foreach f [lsort [glob -nocomplain [file join $proj_root sim tb_*.v]]] {
  add_one sim_1 $f
}

# Tops (catch: tolerate a partially-populated checkout so the script stays
# idempotent while other sources are still being written).
if {[catch {set_property top kv_top [get_filesets sources_1]} msg]} {
  puts "add_sources.tcl: WARNING: could not set sources_1 top: $msg"
}
if {[catch {set_property top tb_kv_top_full [get_filesets sim_1]} msg]} {
  puts "add_sources.tcl: WARNING: could not set sim_1 top: $msg"
}

if {[catch {update_compile_order -fileset sources_1} msg]} {
  puts "add_sources.tcl: WARNING: update_compile_order sources_1: $msg"
}
if {[catch {update_compile_order -fileset sim_1} msg]} {
  puts "add_sources.tcl: WARNING: update_compile_order sim_1: $msg"
}

puts "add_sources.tcl: done"
