import matplotlib.pyplot as plt
import numpy as np
import sys 

csv_file = "dram_coupled_leak.csv"
plot_vdd_val = float(1.2)

try:
    data = np.loadtxt(csv_file) 
except Exception as e:
    print(f"Error loading {csv_file}: {e}")
    sys.exit(1)

if data.size == 0:
    print(f"Error: {csv_file} is empty.")
    sys.exit(1)

# CSV now has: time, v(node1), v(DBG_node2), v(DBG_wl2), v(DBG_bl2)
expected_min_cols = 3 
if data.ndim == 1: 
    if data.shape[0] >= expected_min_cols: 
        time_data = np.array([data[0]])
        v_node1_data = np.array([data[1]])
        v_node2_data = np.array([data[2]]) # This is now v(DBG_node2)
    else:
        print(f"Error: Single data line in {csv_file} has fewer than {expected_min_cols} values.")
        sys.exit(1)
elif data.ndim == 2:
    if data.shape[1] >= expected_min_cols:
        time_data = data[:, 0]
        v_node1_data = data[:, 1]
        v_node2_data = data[:, 2] # This is now v(DBG_node2)
    else:
        print(f"Error: Data in {csv_file} has fewer than {expected_min_cols} columns.")
        sys.exit(1)
else:
    print(f"Error: Unexpected data dimension in {csv_file}.")
    sys.exit(1)

plt.figure(figsize=(12, 7))
plt.plot(time_data, v_node1_data, label="Cell 1 Voltage (V(node1))")
plt.plot(time_data, v_node2_data, label="Cell 2 Voltage (V(DBG_node2)) - FORCED DC TEST", linestyle='--')

plt.title("DRAM Cells - Cell 2 Forced DC Debug")
plt.xlabel("Time (s)")
plt.ylabel("Voltage (V)")
plt.legend()
plt.grid(True)
plt.ylim(-0.1, plot_vdd_val * 1.25 if plot_vdd_val else 1.5) 
plt.tight_layout()
plt.savefig("dram_cell2_DC_debug.png")
print("Plot saved to dram_cell2_DC_debug.png")
