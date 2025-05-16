* Simple 1T1C DRAM Cell
M1 bitline wordline 0 0 NMOS W=1u L=0.1u
Ccell bitline 0 0.05p
Vdd bitline 0 DC 1.8
Vword wordline 0 PULSE(0 1.8 0n 1n 1n 10n 20n)
.model NMOS NMOS (LEVEL=1 VTO=0.7 KP=120u)
.tran 0.1n 100n
.control
run
plot v(bitline)
.endc
.end
