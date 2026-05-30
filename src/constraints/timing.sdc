//Copyright (C)2014-2025 GOWIN Semiconductor Corporation.
//All rights reserved.
//File Title: Timing Constraints file
//Tool Version: V1.9.12 (64-bit) 
//Created Time: 2025-12-11 19:02:44

# DDR3/PLL timing constraints
# Assumes DDR IP + PLL configuration matches ref/src (clk_x1=100MHz, memory_clk=400MHz).
# - clk      : top input clock (27MHz)
# - clk_x1   : DDR3 IP clk_out
# - memory_clk: rPLL output to DDR3 IP

# create_clock -name clk_x1 -period 10 -waveform {0 5} [get_nets {clk_x1}]
create_clock -name clk_x4 -period 2.5 -waveform {0 1.25} [get_nets {memory_clk}]
create_clock -name clk -period 37.037 -waveform {0 18.518} [get_ports {clk}]

# set_clock_groups -asynchronous -group [get_clocks {clk_x1}] -group [get_clocks {clk_x4}] -group [get_clocks {clk}]
set_clock_groups -asynchronous -group [get_clocks {clk_x4}] -group [get_clocks {clk}]

# Optional: emit timing summaries for all clock domains.
report_timing -hold -from_clock [get_clocks {clk*}] -to_clock [get_clocks {clk*}] -max_paths 25 -max_common_paths 1
report_timing -setup -from_clock [get_clocks {clk*}] -to_clock [get_clocks {clk*}] -max_paths 25 -max_common_paths 1
