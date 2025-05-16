* Two-Coupled DRAM Cells
* CELL 1 NORMAL, CELL 2 FORCED DC DEBUG

.PARAM VDD_PARAM = 1.2         
.PARAM VWL_H_PARAM = 2.0       
.PARAM C_CELL = 30f
.PARAM R_CAP_LEAK = 3T
.PARAM TRAN_TSTEP_PARAM = 50n     

.PARAM C_COUPLE_VAL = 25f
.PARAM R_COUPLE_LEAK_VAL = 100MEG

.model MyNMOS NMOS (LEVEL=1 VTO=0.7 KP=120u W=0.1u L=0.1u)

* ===== CELL 1 (Normal Operation) =====
Vwl1 wl1 0 PWL(0 0 3.292302e-06 2.0 3.792302e-06 2.0 3.793302e-06 0 3.793402e-06 2.0 4.293402e-06 2.0 4.294402e-06 0 7.204268e-06 2.0 7.704268e-06 2.0 7.705268e-06 0 1.121599e-05 2.0 1.171599e-05 2.0 1.171699e-05 0 1.360269e-05 2.0 1.410269e-05 2.0 1.410369e-05 0 1.751779e-05 2.0 1.801779e-05 2.0 1.801879e-05 0 2.000000e-05 0)
Vbl1 bl1 0 PWL(0 0 3.292302e-06 0 3.792302e-06 0 3.793302e-06 0 3.793402e-06 0 4.293402e-06 0 4.294402e-06 0 7.204268e-06 1.2 7.704268e-06 1.2 7.705268e-06 0 1.121599e-05 0 1.171599e-05 0 1.171699e-05 0 1.360269e-05 1.2 1.410269e-05 1.2 1.410369e-05 0 1.751779e-05 1.2 1.801779e-05 1.2 1.801879e-05 0 2.000000e-05 0)
Cc1 node1 0 {C_CELL}
Rcl1 node1 0 {R_CAP_LEAK}
M1 bl1 wl1 node1 0 MyNMOS

* ===== CELL 2 (FORCED DC DEBUG - Bypassing all PWL from cell_patterns.txt for Cell 2) =====
Vwl2_dc DBG_wl2 0 2.0   ; Force Wordline 2 HIGH
Vbl2_dc DBG_bl2 0 1.2     ; Force Bitline 2 HIGH (to write '1')
Cc2_dbg DBG_node2 0 {C_CELL}
Rcl2_dbg DBG_node2 0 {R_CAP_LEAK}
M2_dbg DBG_bl2 DBG_wl2 DBG_node2 0 MyNMOS ; Access Transistor for Cell 2

* ===== COUPLING (Connect Cell 1 to the DEBUG Cell 2 node) =====
Ccouple node1 DBG_node2 {C_COUPLE_VAL}
Rcouple_path node1 DBG_node2 {R_COUPLE_LEAK_VAL}

.tran {TRAN_TSTEP_PARAM} 2e-05 UIC

.control
run
wrdata dram_coupled_leak.csv v(node1) v(DBG_node2) v(DBG_wl2) v(DBG_bl2)
listing e
quit
.endc
.end
