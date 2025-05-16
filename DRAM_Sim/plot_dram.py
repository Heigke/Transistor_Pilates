import matplotlib.pyplot as plt
import numpy as np

data = np.loadtxt("dram_out.csv")
time = data[:, 0]
v_a = data[:, 1]
v_b = data[:, 2]

plt.figure(figsize=(10, 5))
plt.plot(time, v_a, label="Cell A (node_a, starts at 1)")
plt.plot(time, v_b, label="Cell B (node_b, starts at 0)")
plt.xlabel("Time (s)")
plt.ylabel("Voltage (V)")
plt.title("Coupled DRAM Cells — Leakage and Crosstalk")
plt.legend()
plt.grid(True)
plt.tight_layout()
plt.savefig("dram_plot.png")
plt.show()
