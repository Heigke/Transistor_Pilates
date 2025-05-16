* Two DRAM Cells with Leakage Coupling and Floating Node Stabilization - Enhanced Dynamics

.model NMOS NMOS (LEVEL=1 VTO=0.7 KP=120u)

* --- Cell A (initially charged towards 1.1V due to Vth) ---
* Pulse width (50ns) increased for fuller charge, Period (200us) > sim time for single pulse.
Vbit_a bl_a 0 PULSE(0 1.8 0n 1n 1n 50n 200u)
Vwl_a wl_a 0 PULSE(0 1.8 0n 1n 1n 50n 200u)
M1 bl_a wl_a node_a 0 NMOS
Ccell_a node_a 0 1p

* --- Cell B (initially 0V) ---
* Pulse width (50ns) increased for fuller discharge, Period (200us) > sim time for single pulse.
Vbit_b bl_b 0 PULSE(0 0 0n 1n 1n 50n 200u)
Vwl_b wl_b 0 PULSE(0 1.8 0n 1n 1n 50n 200u)
M2 bl_b wl_b node_b 0 NMOS
Ccell_b node_b 0 1p

* --- Coupling and Stabilization ---
* Rcouple reduced for faster charge sharing
Rcouple node_a node_b 2MEG
* Rfix reduced for visible leakage over 100us
Rfix_a node_a 0 200MEG
Rfix_b node_b 0 200MEG

.tran 2n 100u
.control
run
wrdata dram_out.csv v(node_a) v(node_b)
quit
.endc
.end
