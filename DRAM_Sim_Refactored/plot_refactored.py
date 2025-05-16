import matplotlib.pyplot as plt
import numpy as np
import sys

VDD_PLOT = float(sys.argv[1])
TSTOP_PLOT = float(sys.argv[2])
CSV_FILE = "dram_sim_output.csv"

try:
    # Ngspice with 'set wr_vecnames' puts variable names in the first row
    # and 'set wr_singlescale' means first column is time.
    data_raw = np.genfromtxt(CSV_FILE, names=True, skip_header=0) # skip_header=0 if names=True handles it.
                                                                # If no vecnames, use skip_header=N based on log
except Exception as e:
    print(f"Python Plot: Error loading {CSV_FILE}: {e}")
    # Try loading without names if that failed
    try:
        print(f"Python Plot: Trying to load {CSV_FILE} without assuming header names...")
        data_raw_alt = np.loadtxt(CSV_FILE) # Assumes no header, or header is pure comment
        # Assuming order: time, v(c1_node), v(c2_node), v(c1_wl), v(c1_bl), v(c2_wl), v(c2_bl)
        time_data = data_raw_alt[:,0]
        v_c1_node = data_raw_alt[:,1]
        v_c2_node = data_raw_alt[:,2]
        v_c1_wl = data_raw_alt[:,3]
        v_c1_bl = data_raw_alt[:,4]
        v_c2_wl = data_raw_alt[:,5]
        v_c2_bl = data_raw_alt[:,6]
    except Exception as e_alt:
        print(f"Python Plot: Secondary loading attempt also failed: {e_alt}")
        sys.exit(1)
else: # Original try succeeded
    time_data = data_raw['time'] # Or 'sweep' or whatever ngspice names the scale
    v_c1_node = data_raw['vc1_node'] # ngspice often removes parentheses and uses underscore
    v_c2_node = data_raw['vc2_node']
    v_c1_wl = data_raw['vc1_wl']
    v_c1_bl = data_raw['vc1_bl']
    v_c2_wl = data_raw['vc2_wl']
    v_c2_bl = data_raw['vc2_bl']


fig, axs = plt.subplots(3, 1, figsize=(12, 10), sharex=True)

axs[0].plot(time_data, v_c1_node, label="V(c1_node) - Cell 1 Store")
axs[0].plot(time_data, v_c2_node, label="V(c2_node) - Cell 2 Store (Forced 1st pulse '1')", linestyle='--')
axs[0].set_ylabel("Voltage (V)")
axs[0].legend()
axs[0].grid(True)
axs[0].set_ylim(-0.1, VDD_PLOT * 1.25)
axs[0].set_title(f"DRAM Cell Storage Nodes (Seed: {sys.argv[3]})")

axs[1].plot(time_data, v_c1_wl, label="V(c1_wl) - Cell 1 WL")
axs[1].plot(time_data, v_c2_wl, label="V(c2_wl) - Cell 2 WL", linestyle='--')
axs[1].set_ylabel("Voltage (V)")
axs[1].legend()
axs[1].grid(True)

axs[2].plot(time_data, v_c1_bl, label="V(c1_bl) - Cell 1 BL")
axs[2].plot(time_data, v_c2_bl, label="V(c2_bl) - Cell 2 BL", linestyle='--')
axs[2].set_ylabel("Voltage (V)")
axs[2].set_xlabel("Time (s)")
axs[2].legend()
axs[2].grid(True)

plt.tight_layout()
plt.savefig("dram_simulation_refactored.png")
print(f"Python Plot: Plot saved to dram_simulation_refactored.png")
# plt.show()
