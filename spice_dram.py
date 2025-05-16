import os
os.environ["PYSPICE_SIMULATOR_PATH"] = "/usr/local/bin/ngspice"
import matplotlib.pyplot as plt
from PySpice.Spice.Netlist import Circuit
from PySpice.Unit import *


# Create circuit
circuit = Circuit('1T1C DRAM Cell')

# Power supply
circuit.V('dd', 'bitline', circuit.gnd, 1.8 @ u_V)

# Word line pulse (controls gate)
circuit.PulseVoltageSource('word', 'wordline', circuit.gnd,
                           initial_value=0@u_V, pulsed_value=1.8@u_V,
                           delay_time=0@u_ns, rise_time=1@u_ns, fall_time=1@u_ns,
                           pulse_width=10@u_ns, period=20@u_ns)

# NMOS: drain=bitline, gate=wordline, source=gnd, body=gnd
circuit.MOSFET(1, 'bitline', 'wordline', circuit.gnd, circuit.gnd, model='NMOS')

# DRAM storage capacitor
circuit.C('cell', 'bitline', circuit.gnd, 0.05 @ u_pF)

# NMOS model
circuit.model('NMOS', 'NMOS', LEVEL=1, VTO=0.7, KP=120e-6)

# Transient simulation
simulator = circuit.simulator(temperature=25, nominal_temperature=25)
analysis = simulator.transient(step_time=0.1@u_ns, end_time=100@u_ns)

# Plot result
plt.figure(figsize=(8, 4))
plt.plot(analysis.time, analysis['bitline'], label='Bitline Voltage')
plt.xlabel('Time [s]')
plt.ylabel('Voltage [V]')
plt.title('1T1C DRAM Cell Transient Simulation')
plt.grid(True)
plt.legend()
plt.tight_layout()
plt.savefig('dram_simulation_plot.png')
plt.show()
