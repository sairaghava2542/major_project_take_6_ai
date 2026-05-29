# ============================================================================
# run_dc.tcl
#
# Design Compiler NXT low-power synthesis script for accel_top using the
# SAED32 EDK CCS .db libraries shown in your setup.
#
# Selected voltage plan:
#   PD_AON      : 1.05 V, RVT standard cells
#   PD_COMPUTE  : 0.78 V switched island, RVT standard cells
#   LP cells    : RVT pg + ulvl/dlvl cells for switch/isolation/level shifting
# ============================================================================

set_app_var sh_continue_on_error false

set DESIGN_NAME accel_top
set RTL_DIR     ./rtl
set UPF_IN      ./accel_top.upf
set OUT_DIR     ./syn
set RPT_DIR     ./reports/dc

file mkdir $OUT_DIR
file mkdir $RPT_DIR

# ----------------------------------------------------------------------------
# SAED32 library setup
# ----------------------------------------------------------------------------
set SAED32_ROOT /data/pdk/pdk32nm/SAED32_EDK
set RVT_DB      $SAED32_ROOT/lib/stdcell_rvt/db_ccs
set HVT_DB      $SAED32_ROOT/lib/stdcell_hvt/db_ccs
set LVT_DB      $SAED32_ROOT/lib/stdcell_lvt/db_ccs

proc pick_one_db {pattern} {
    set matches [lsort [glob -nocomplain $pattern]]
    if {[llength $matches] == 0} {
        error "No .db matched pattern: $pattern"
    }
    return [lindex $matches 0]
}

# Main functional libraries. RVT is the default choice; HVT is available for
# leakage recovery and LVT is linked so DC can use it if you explicitly allow it.
set LIB_RVT_AON_TT      [pick_one_db $RVT_DB/saed32rvt_tt1p05v25c.db]
set LIB_RVT_COMP_TT     [pick_one_db $RVT_DB/saed32rvt_tt0p78v25c.db]
set LIB_HVT_AON_TT      [pick_one_db $HVT_DB/saed32hvt_tt1p05v25c.db]
set LIB_HVT_COMP_TT     [pick_one_db $HVT_DB/saed32hvt_tt0p78v25c.db]
set LIB_LVT_AON_TT      [pick_one_db $LVT_DB/saed32lvt_tt1p05v25c.db]
set LIB_LVT_COMP_TT     [pick_one_db $LVT_DB/saed32lvt_tt0p78v25c.db]

# Low-power cells:
#   pg   : power-gating / always-on / isolation style cells
#   ulvl : up-level shifters, low-voltage input to high-voltage output
#   dlvl : down-level shifters, high-voltage input to low-voltage output
set LIB_RVT_PG_TT       [pick_one_db $RVT_DB/saed32rvt_pg_tt1p05v25c.db]
set LIB_RVT_ULVL_TT     [pick_one_db $RVT_DB/saed32rvt_ulvl_tt1p05v25c_*0p78v.db]
set LIB_RVT_DLVL_TT     [pick_one_db $RVT_DB/saed32rvt_dlvl_tt1p05v25c_*1p05v.db]

set_app_var search_path [list . $RTL_DIR $RVT_DB $HVT_DB $LVT_DB]

set target_library [list \
    $LIB_RVT_AON_TT \
    $LIB_RVT_COMP_TT \
    $LIB_RVT_PG_TT \
    $LIB_RVT_ULVL_TT \
    $LIB_RVT_DLVL_TT \
]

set link_library [concat "*" $target_library [list \
    $LIB_HVT_AON_TT \
    $LIB_HVT_COMP_TT \
    $LIB_LVT_AON_TT \
    $LIB_LVT_COMP_TT \
]]

set_app_var target_library $target_library
set_app_var link_library   $link_library

# Keep domain boundaries readable for UPF and ICC2.
set_app_var compile_ultra_ungroup_dw false
set_app_var hdlin_preserve_sequential true

# ----------------------------------------------------------------------------
# Analyze and elaborate RTL
# ----------------------------------------------------------------------------
analyze -format verilog [list \
    $RTL_DIR/systolic_pe.v \
    $RTL_DIR/systolic_array_8x8.v \
    $RTL_DIR/accel_regs.v \
    $RTL_DIR/accel_top.v \
]

elaborate $DESIGN_NAME
current_design $DESIGN_NAME
link
set_operating_conditions -max tt1p05v25c -max_library saed32rvt_tt1p05v25c
uniquify

set_ungroup [get_cells u_regs]    false
set_ungroup [get_cells u_compute] false

# ----------------------------------------------------------------------------
# Timing constraints
# ----------------------------------------------------------------------------
create_clock -name clk -period 5.30 [get_ports clk]
set_clock_uncertainty 0.250 [get_clocks clk]
set_input_delay  1.00 -clock [get_clocks clk] \
    [remove_from_collection [all_inputs] [get_ports clk]]
set_output_delay 1.00 -clock [get_clocks clk] [all_outputs]
set_max_fanout 10 [current_design]
set_max_transition 0.35 [current_design]
set_load 0.05 [all_outputs]

# ----------------------------------------------------------------------------
# Load and check UPF
# ----------------------------------------------------------------------------
load_upf $UPF_IN

# DC sometimes does not propagate add_port_state voltage values onto UPF supply
# nets. Make the rail voltages explicit for MV checking and MV-cell insertion.
set_voltage 1.05 -object_list {VDD_ALW}
set_voltage 0.78 -object_list {VDD_COMP VDD_COMP_SW}
set_voltage 0.00 -object_list {VSS}

check_mv_design -verbose > $RPT_DIR/check_mv_design.pre_compile.rpt

# ----------------------------------------------------------------------------
# Clock gating and low-power compile
# ----------------------------------------------------------------------------
set_clock_gating_style \
    -positive_edge_logic integrated \
    -negative_edge_logic integrated \
    -control_point before \
    -max_fanout 32

compile_ultra -gate_clock

# ----------------------------------------------------------------------------
# Reports and deliverables
# ----------------------------------------------------------------------------
check_design > $RPT_DIR/check_design.rpt
check_timing > $RPT_DIR/check_timing.rpt
check_mv_design -verbose > $RPT_DIR/check_mv_design.post_compile.rpt

report_qor > $RPT_DIR/qor.rpt
report_area -hierarchy > $RPT_DIR/area_hier.rpt
report_power -hierarchy > $RPT_DIR/power_hier.rpt
report_clock_gating > $RPT_DIR/clock_gating.rpt
report_timing -delay_type max -max_paths 25 > $RPT_DIR/timing_max.rpt
report_timing -delay_type min -max_paths 25 > $RPT_DIR/timing_min.rpt
report_power_domain > $RPT_DIR/power_domains.rpt
report_isolation > $RPT_DIR/isolation.rpt
report_level_shifter > $RPT_DIR/level_shifters.rpt

change_names -rules verilog -hierarchy

write -format verilog -hierarchy -output $OUT_DIR/${DESIGN_NAME}.lp.syn.v
write -format ddc     -hierarchy -output $OUT_DIR/${DESIGN_NAME}.ddc
write_sdc $OUT_DIR/${DESIGN_NAME}.syn.sdc
save_upf  $OUT_DIR/${DESIGN_NAME}.syn.upf

puts "DC complete:"
puts "  Netlist : $OUT_DIR/${DESIGN_NAME}.lp.syn.v"
puts "  UPF     : $OUT_DIR/${DESIGN_NAME}.syn.upf"
puts "  SDC     : $OUT_DIR/${DESIGN_NAME}.syn.sdc"
