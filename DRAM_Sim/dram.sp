* Two DRAM Cells with Leakage Coupling and Floating Node Stabilization

.model NMOS NMOS (LEVEL=1 VTO=0.7 KP=120u)

* --- Cell A (initially 1.8V) ---
Vbit_a bl_a 0 PULSE(0 1.8 0n 1n 1n 10n 1u)
Vwl_a wl_a 0 PULSE(0 1.8 0n 1n 1n 10n 1u)
M1 bl_a wl_a node_a 0 NMOS
Ccell_a node_a 0 1p

* --- Cell B (initially 0V) ---
Vbit_b bl_b 0 PULSE(0 0 0n 1n 1n 10n 1u)
Vwl_b wl_b 0 PULSE(0 1.8 0n 1n 1n 10n 1u)
M2 bl_b wl_b node_b 0 NMOS
Ccell_b node_b 0 1p

* --- Coupling and Stabilization ---
Rcouple node_a node_b 10MEG
Rfix_a node_a 0 100G
Rfix_b node_b 0 100G

.tran 2n 100u
.control
run
wrdata dram_out.csv v(node_a) v(node_b)
quit
.endc
.end
