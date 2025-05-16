* DRAM Weight Write Simulation - Epoch 45
* Goal: Write target voltages (representing NN weights) to cell capacitors.

.PARAM sim_vdd = 1.0
.PARAM sim_vwl_h = 1.8
.PARAM sim_c_cell = 50f
.PARAM sim_r_cap_leak = 100T
.PARAM sim_c_couple = 1f
.PARAM sim_r_couple_leak = 1000T
.PARAM sim_tran_tstep = 10n ; Fine enough for the write pulse

.model MyNMOS_Model NMOS (LEVEL=1 VTO=0.4 KP=100u W=0.2u L=0.1u) ; Slightly adjusted VTO

* --- Cell 1 (Weight W1) ---
Vwl1 c1_wl 0 PWL(0 0 1.000000e-07 0 1.010000e-07 1.800000e+00 4.100000e-06 1.800000e+00 4.101000e-06 0 5.000000e-06 0)
Vbl1 c1_bl 0 PWL(0 0 1.000000e-07 0 1.010000e-07 1.000000e-01 4.100000e-06 1.000000e-01 4.101000e-06 0 5.000000e-06 0)
Cc1  c1_node 0 {sim_c_cell}      ; Cell 1 Storage Capacitor (W1)
Rcl1 c1_node 0 {sim_r_cap_leak}  ; Cell 1 Leakage Resistor
M1   c1_bl c1_wl c1_node 0 MyNMOS_Model ; Access transistor for W1

* --- Cell 2 (Weight W2) ---
Vwl2 c2_wl 0 PWL(0 0 1.000000e-07 0 1.010000e-07 1.800000e+00 4.100000e-06 1.800000e+00 4.101000e-06 0 5.000000e-06 0)
Vbl2 c2_bl 0 PWL(0 0 1.000000e-07 0 1.010000e-07 1.000000e-01 4.100000e-06 1.000000e-01 4.101000e-06 0 5.000000e-06 0)
Cc2  c2_node 0 {sim_c_cell}      ; Cell 2 Storage Capacitor (W2)
Rcl2 c2_node 0 {sim_r_cap_leak}  ; Cell 2 Leakage Resistor
M2   c2_bl c2_wl c2_node 0 MyNMOS_Model ; Access transistor for W2

* --- Coupling (minimal for now) ---
Ccouple_cells c1_node c2_node {sim_c_couple}
Rcouple_cells c1_node c2_node {sim_r_couple_leak}

* --- Analysis ---
.tran {sim_tran_tstep} 5e-6 UIC

.control
set wr_vecnames              ; Ensure variable names are in first line
set wr_singlescale           ; Use time as the single scale
run
wrdata dram_sim_output.csv v(c1_node) v(c2_node) v(c1_wl) v(c1_bl) v(c2_wl) v(c2_bl)
* plot v(c1_node) v(c2_node) xlimit 0 5e-6 ylimit -0.1 [ $sim_vdd * 1.1 ]
listing e
quit
.endc

.end
