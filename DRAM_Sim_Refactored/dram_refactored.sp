* DRAM Simulation - Refactored for Clarity
* Global Parameters defined in controlling script

.PARAM sim_vdd = 1.2
.PARAM sim_vwl_h = 2.0
.PARAM sim_c_cell = 30f
.PARAM sim_r_cap_leak = 3T
.PARAM sim_tran_tstep = 50n
.PARAM sim_c_couple = 25f
.PARAM sim_r_couple_leak = 100MEG

.model MyNMOS_Model NMOS (LEVEL=1 VTO=0.7 KP=120u W=0.1u L=0.1u) ; MOSFET Model

* --- Cell 1 ---
Vwl1 c1_wl 0 PWL(0 0 3.448140e-06 2.0 3.948140e-06 2.0 3.949140e-06 0 3.949240e-06 2.0 4.449240e-06 2.0 4.450240e-06 0 7.578434e-06 2.0 8.078434e-06 2.0 8.079434e-06 0 1.181405e-05 2.0 1.231405e-05 2.0 1.231505e-05 0 1.433395e-05 2.0 1.483395e-05 2.0 1.483495e-05 0 1.846755e-05 2.0 1.896755e-05 2.0 1.896855e-05 0 2.000000e-05 0)
Vbl1 c1_bl 0 PWL(0 0 3.448140e-06 0 3.948140e-06 0 3.949140e-06 0 3.949240e-06 0 4.449240e-06 0 4.450240e-06 0 7.578434e-06 1.2 8.078434e-06 1.2 8.079434e-06 0 1.181405e-05 0 1.231405e-05 0 1.231505e-05 0 1.433395e-05 1.2 1.483395e-05 1.2 1.483495e-05 0 1.846755e-05 1.2 1.896755e-05 1.2 1.896855e-05 0 2.000000e-05 0)
Cc1  c1_node 0 {sim_c_cell}      ; Cell 1 Storage Capacitor
Rcl1 c1_node 0 {sim_r_cap_leak}  ; Cell 1 Leakage Resistor
M1   c1_bl c1_wl c1_node 0 MyNMOS_Model

* --- Cell 2 ---
Vwl2 c2_wl 0 PWL(0 0 3.598140e-06 2.0 4.098140e-06 2.0 4.099140e-06 0 4.099240e-06 2.0 4.599240e-06 2.0 4.600240e-06 0 7.728434e-06 2.0 8.228434e-06 2.0 8.229434e-06 0 1.196405e-05 2.0 1.246405e-05 2.0 1.246505e-05 0 1.448395e-05 2.0 1.498395e-05 2.0 1.498495e-05 0 1.861755e-05 2.0 1.911755e-05 2.0 1.911855e-05 0 2.000000e-05 0)
Vbl2 c2_bl 0 PWL(0 0 3.598140e-06 1.2 4.098140e-06 1.2 4.099140e-06 0 4.099240e-06 0 4.599240e-06 0 4.600240e-06 0 7.728434e-06 0 8.228434e-06 0 8.229434e-06 0 1.196405e-05 0 1.246405e-05 0 1.246505e-05 0 1.448395e-05 0 1.498395e-05 0 1.498495e-05 0 1.861755e-05 0 1.911755e-05 0 1.911855e-05 0 2.000000e-05 0)
Cc2  c2_node 0 {sim_c_cell}      ; Cell 2 Storage Capacitor
Rcl2 c2_node 0 {sim_r_cap_leak}  ; Cell 2 Leakage Resistor
M2   c2_bl c2_wl c2_node 0 MyNMOS_Model ; Cell 2 Access Transistor

* --- Coupling ---
Ccouple_cells c1_node c2_node {sim_c_couple}
Rcouple_cells c1_node c2_node {sim_r_couple_leak}

* --- Analysis ---
.tran {sim_tran_tstep} 20e-6 UIC ; UIC uses t=0 values and 0 for IC of L/C

.control
set wr_vecnames              ; Ensure variable names are in first line of wrdata output
set wr_singlescale           ; Use time as the single scale
run
wrdata dram_sim_output.csv v(c1_node) v(c2_node) v(c1_wl) v(c1_bl) v(c2_wl) v(c2_bl)
listing e                    ; Expanded listing of the circuit
* plot v(c1_node) v(c2_node) xlimit 0 20e-6 ylimit -0.1 [ $PY_VDD * 1.2 ] ; Example plot (escape $ for literal)
quit
.endc

.end
