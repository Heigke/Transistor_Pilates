import matplotlib.pyplot as plt
import matplotlib.dates as mdates
from datetime import datetime
from collections import defaultdict

flip_offsets = []
flip_timestamps = defaultdict(int)

print("[*] Processing FLIP entries from CSV...")

with open("dram_aggressive_log.csv", "r") as f:
    for line in f:
        if not line.startswith("FLIP"):
            continue
        try:
            parts = line.strip().split(",")
            _, timestamp, offset_hex, *_ = parts
            ts_float = float(timestamp)
            offset = int(offset_hex, 16)
            flip_offsets.append(offset)
            time_bin = int(ts_float)  # group by seconds
            flip_timestamps[time_bin] += 1
        except Exception as e:
            print("Skipping malformed line:", e)

print(f"[+] Total flips parsed: {len(flip_offsets)}")

# --- Flip Location Histogram ---
plt.figure(figsize=(10, 5))
plt.hist(flip_offsets, bins=500, edgecolor='black')
plt.xlabel("Memory Offset (bytes)")
plt.ylabel("Flip Count")
plt.title("Spatial Distribution of Bit Flips")
plt.tight_layout()
plt.savefig("flip_location_histogram.png")
print("[+] Saved: flip_location_histogram.png")

# --- Temporal Flip Rate ---
plt.figure(figsize=(10, 5))
sorted_ts = sorted(flip_timestamps.items())
times = [datetime.fromtimestamp(t) for t, _ in sorted_ts]
counts = [c for _, c in sorted_ts]

plt.plot(times, counts, linestyle='-', marker='.')
plt.xlabel("Time")
plt.ylabel("Flips per Second")
plt.title("Bit Flip Rate Over Time")
plt.gca().xaxis.set_major_formatter(mdates.DateFormatter('%H:%M:%S'))
plt.gcf().autofmt_xdate()
plt.tight_layout()
plt.savefig("flip_rate_over_time.png")
print("[+] Saved: flip_rate_over_time.png")

print("[✓] Plotting complete.")
