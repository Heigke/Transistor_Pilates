import matplotlib.pyplot as plt
import numpy as np

# Load data, skipping the header row if Ngspice adds one (often does for wrdata)
# and handling potential issues with the simple text format.
try:
    data = np.loadtxt("dram_out.csv", skiprows=0) # Try without skipping first
    if data.ndim == 0 or data.size == 0: # Check if data is empty or scalar
        print("Warning: Data array is empty or scalar. Trying with skiprows=1.")
        data = np.loadtxt("dram_out.csv", skiprows=1)
except Exception as e:
    print(f"Error loading data, trying with skiprows=1 due to: {e}")
    data = np.loadtxt("dram_out.csv", skiprows=1) # Default to skipping one row if issues

# Check if data was successfully loaded and has expected shape
if data.ndim == 1 and data.shape[0] % 3 == 0 and data.shape[0] > 0 : # might be a flat array if only one timepoint
    num_vars = 2 # v(node_a), v(node_b)
    num_points = data.shape[0] // (num_vars + 1) # +1 for time
    print(f"Data seems to be a flat array, attempting to reshape. Num points: {num_points}")
    data = data.reshape((num_points, num_vars + 1))
elif data.ndim == 1 and data.shape[0] !=3 : # If it's a 1D array but not fitting 3 columns.
    print(f"Error: Loaded data is 1D with unexpected shape: {data.shape}")
    print("Please check dram_out.csv")
    exit(1)
elif data.ndim == 2 and data.shape[1] !=3 :
    print(f"Error: Loaded data has {data.shape[1]} columns, expected 3 (time, v_a, v_b).")
    print("Please check dram_out.csv")
    exit(1)


time = data[:, 0]
v_a = data[:, 1]
v_b = data[:, 2]

plt.figure(figsize=(12, 6)) # Slightly wider for better visibility
plt.plot(time, v_a, label="Cell A (node_a, Vinitial ≈ 1.1V)")
plt.plot(time, v_b, label="Cell B (node_b, Vinitial = 0V)")
plt.xlabel("Time (s)")
plt.ylabel("Voltage (V)")
plt.title("Coupled DRAM Cells — Charge Sharing and Leakage Dynamics")
plt.legend()
plt.grid(True)
plt.ylim(-0.1, 1.2) # Adjust y-axis for better view of 0V to ~1.1V range
plt.tight_layout()
plt.savefig("dram_plot.png")
#echo "Plot saved to dram_plot.png. Displaying plot..."
plt.show()
