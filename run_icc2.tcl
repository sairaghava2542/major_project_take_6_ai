# ============================================================================
# run_icc2.tcl
#
# IC Compiler II low-power place-and-route script for accel_top using the
# SAED32 EDK NDM libraries shown in your setup.
#
# Inputs from DC:
#   ./syn/accel_top.lp.syn.v
#   ./syn/accel_top.syn.upf
#   ./syn/accel_top.syn.sdc
# ============================================================================

set_app_options -name shell.common.continue_on_error -value false

set DESIGN_NAME accel_top
set WORK_DIR    ./icc2_work
set OUT_DIR     ./icc2_out
set RPT_DIR     ./reports/icc2

set DESIGN_LIB  $WORK_DIR/${DESIGN_NAME}.dlib
set NETLIST     ./syn/${DESIGN_NAME}.lp.syn.v
set UPF_FILE    ./syn/${DESIGN_NAME}.syn.upf
set SDC_FILE    ./syn/${DESIGN_NAME}.syn.sdc

file mkdir $WORK_DIR
file mkdir $OUT_DIR
file mkdir $RPT_DIR

# ----------------------------------------------------------------------------
# SAED32 NDM and technology setup
# ----------------------------------------------------------------------------
set SAED32_ROOT /data/pdk/pdk32nm/SAED32_EDK
set NDM_ROOT    $SAED32_ROOT/lib

# From your screenshot, these are directories:
#   saed32_lp9m_tech.ndm, saed32_hvt.ndm, saed32_lvt.ndm, saed32_rvt.ndm
set TECH_NDM    $NDM_ROOT/saed32_lp9m_tech.ndm
set REF_LIBS    [list \
    $NDM_ROOT/saed32_rvt.ndm \
    $NDM_ROOT/saed32_hvt.ndm \
    $NDM_ROOT/saed32_lvt.ndm \
]

# Common SAED32 ICC2 collateral names vary by installation. These defaults are
# the usual EDK locations; adjust only if your tree uses different names.
set TECH2ITF_MAP $SAED32_ROOT/tech/milkyway/saed32nm_tf_itf_tluplus.map
set TLUPLUS_MAX  $SAED32_ROOT/tech/star_rcxt/saed32nm_1p9m_Cmax.tluplus
set TLUPLUS_MIN  $SAED32_ROOT/tech/star_rcxt/saed32nm_1p9m_Cmin.tluplus
set GDS_MAP_FILE $SAED32_ROOT/tech/milkyway/saed32nm_1p9m_gdsout_mw.map

if {[file exists $DESIGN_LIB]} {
    file delete -force $DESIGN_LIB
}

create_lib $DESIGN_LIB \
    -technology $TECH_NDM \
    -ref_libs $REF_LIBS

open_lib $DESIGN_LIB

# ----------------------------------------------------------------------------
# Read synthesized low-power design
# ----------------------------------------------------------------------------
read_verilog $NETLIST
read_upf $UPF_FILE
current_design $DESIGN_NAME
link_block
read_sdc $SDC_FILE

set_tlu_plus_files \
    -max_tluplus $TLUPLUS_MAX \
    -min_tluplus $TLUPLUS_MIN \
    -tech2itf_map $TECH2ITF_MAP

# ----------------------------------------------------------------------------
# MCMM setup matching the selected SAED32 voltage plan
# ----------------------------------------------------------------------------
remove_modes -all
remove_corners -all
remove_scenarios -all

create_mode FUNC
create_corner C_SS_0P75_125C
create_corner C_TT_1P05_025C
create_corner C_FF_1P16_M40C

create_scenario -name FUNC_SS_SETUP -mode FUNC -corner C_SS_0P75_125C
create_scenario -name FUNC_FF_HOLD  -mode FUNC -corner C_FF_1P16_M40C
create_scenario -name FUNC_TT_PWR   -mode FUNC -corner C_TT_1P05_025C

set_scenario_status * -setup true -hold true -leakage_power true -dynamic_power true

# ----------------------------------------------------------------------------
# Floorplan and PD_COMPUTE voltage island
# ----------------------------------------------------------------------------
initialize_floorplan \
    -core_utilization 0.60 \
    -core_offset {10 10 10 10} \
    -side_ratio {1 1}

# Adjust this box after your first trial placement if the array needs more
# space. It intentionally keeps the compute island physically distinct.
create_physical_block PD_COMPUTE_PBLOCK \
    -type hard \
    -boundary {{80 80} {520 520}}

create_power_domain_area PD_COMPUTE \
    -boundary {{80 80} {520 520}}

set_attribute [get_cells u_compute] physical_block PD_COMPUTE_PBLOCK

# ----------------------------------------------------------------------------
# Power planning
# ----------------------------------------------------------------------------
create_pg_ring_pattern AON_RING_PATTERN \
    -horizontal_layer M8 \
    -vertical_layer M9 \
    -horizontal_width 2.0 \
    -vertical_width 2.0 \
    -horizontal_spacing 1.0 \
    -vertical_spacing 1.0

create_pg_ring_pattern COMP_RING_PATTERN \
    -horizontal_layer M8 \
    -vertical_layer M9 \
    -horizontal_width 1.6 \
    -vertical_width 1.6 \
    -horizontal_spacing 0.8 \
    -vertical_spacing 0.8

set_pg_strategy AON_RING \
    -core \
    -pattern {{name: AON_RING_PATTERN} {nets: {VDD_ALW VSS}} {offset: {3 3}}}

set_pg_strategy COMP_RING \
    -power_domains PD_COMPUTE \
    -pattern {{name: COMP_RING_PATTERN} {nets: {VDD_COMP_SW VSS}} {offset: {2 2}}}

compile_pg -strategies {AON_RING COMP_RING}

# ----------------------------------------------------------------------------
# Power-switch insertion
# ----------------------------------------------------------------------------
# The exact sleep-switch cell name depends on the SAED32 pg NDM content. This
# pattern lets ICC2 pick a matching pg switch cell if the library class is set.
set power_switch_cells [get_lib_cells -quiet */*HEAD*]
if {[sizeof_collection $power_switch_cells] == 0} {
    set power_switch_cells [get_lib_cells -quiet */*SW*]
}

if {[sizeof_collection $power_switch_cells] > 0} {
    set_power_switch_lib_cells \
        -power_switches compute_sw \
        -lib_cells $power_switch_cells
}

insert_power_switches \
    -power_switches compute_sw \
    -domain PD_COMPUTE \
    -strategy column \
    -switch_effort high

connect_pg_net -automatic
check_pg_connectivity > $RPT_DIR/check_pg_connectivity.rpt
check_mv_design -verbose > $RPT_DIR/check_mv_design.floorplan.rpt

# ----------------------------------------------------------------------------
# Placement, CTS, routing
# ----------------------------------------------------------------------------
place_opt
check_mv_design -verbose > $RPT_DIR/check_mv_design.post_place.rpt

clock_opt -from build_clock -to route_clock
clock_opt -from final_opto

route_global
route_track
route_detail
route_opt

# ----------------------------------------------------------------------------
# Final reports and outputs
# ----------------------------------------------------------------------------
check_routes > $RPT_DIR/check_routes.rpt
check_lvs    > $RPT_DIR/check_lvs.rpt

report_qor > $RPT_DIR/qor_final.rpt
report_timing -max_paths 50 > $RPT_DIR/timing_final.rpt
report_power -hierarchy > $RPT_DIR/power_final.rpt
report_power_domain > $RPT_DIR/power_domains_final.rpt
report_isolation > $RPT_DIR/isolation_final.rpt
report_level_shifter > $RPT_DIR/level_shifters_final.rpt

write_verilog $OUT_DIR/${DESIGN_NAME}.icc2.v
write_def -output $OUT_DIR/${DESIGN_NAME}.def
save_upf $OUT_DIR/${DESIGN_NAME}.icc2.upf
write_sdc -output $OUT_DIR/${DESIGN_NAME}.icc2.sdc

write_gds \
    -design $DESIGN_NAME \
    -layer_map $GDS_MAP_FILE \
    -output $OUT_DIR/${DESIGN_NAME}.gds

save_block

puts "ICC2 complete:"
puts "  GDS : $OUT_DIR/${DESIGN_NAME}.gds"
puts "  DEF : $OUT_DIR/${DESIGN_NAME}.def"
