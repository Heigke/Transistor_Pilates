#!/usr/bin/env python3
import os
import csv
import re
from datetime import datetime

BASELINE_BENCH_SCORE = 3319.26  # From system_summary.csv

def extract_float_from_string(val):
    """Extract last float value from a string like '[12:24:42] 3327.41 events/sec'"""
    try:
        matches = re.findall(r"\d+\.\d+", str(val))
        return float(matches[-1]) if matches else None
    except Exception:
        return None

def clean_synaptic_csv(file_path, output_path, is_short=False):
    print(f"Cleaning {file_path} -> {output_path}")
    cleaned_rows = []

    with open(file_path, 'r') as f:
        reader = csv.reader(f)
        header = next(reader)

        while True:
            try:
                line1 = next(reader)
                line2 = next(reader)
            except StopIteration:
                break  # EOF

            if is_short:
                if len(line1) < 5:
                    continue
                try:
                    timestamp = int(float(line1[0]))
                    cycle = int(float(line1[1]))
                    phase = line1[2]
                    pulse = line1[3]
                except (ValueError, IndexError):
                    continue

                bench_score = extract_float_from_string(" ".join(line2))
                percent = (bench_score / BASELINE_BENCH_SCORE * 100) if bench_score else None
                dt = datetime.utcfromtimestamp(timestamp).strftime('%Y-%m-%d %H:%M:%S')

                cleaned_rows.append([
                    timestamp, cycle, phase, pulse,
                    bench_score, percent, dt
                ])
            else:
                if len(line1) < 4:
                    continue
                try:
                    timestamp = int(float(line1[0]))
                    cycle = int(float(line1[1]))
                    phase = line1[2]
                    temp = float(line1[3])
                except (ValueError, IndexError):
                    continue

                bench_score = extract_float_from_string(" ".join(line2))
                percent = (bench_score / BASELINE_BENCH_SCORE * 100) if bench_score else None
                dt = datetime.utcfromtimestamp(timestamp).strftime('%Y-%m-%d %H:%M:%S')

                cleaned_rows.append([
                    timestamp, cycle, phase, temp,
                    bench_score, percent, 0, 0, dt
                ])

    with open(output_path, 'w', newline='') as out_csv:
        writer = csv.writer(out_csv)
        if is_short:
            writer.writerow([
                'timestamp', 'cycle', 'phase', 'pulse',
                'bench_score', 'percent_of_baseline', 'datetime'
            ])
        else:
            writer.writerow([
                'timestamp', 'cycle', 'phase', 'temp',
                'bench_score', 'percent_of_baseline',
                'error_detected', 'corruption_detected', 'datetime'
            ])
        writer.writerows(cleaned_rows)

    print(f"Saved cleaned CSV to: {output_path}")

def main():
    base_dir = '/home/blue/stress_data_20250513_121204'
    input_short = os.path.join(base_dir, 'synaptic_short_data.csv')
    input_long = os.path.join(base_dir, 'synaptic_long_data.csv')

    output_short = os.path.join(base_dir, 'synaptic_short_data_clean.csv')
    output_long = os.path.join(base_dir, 'synaptic_long_data_clean.csv')

    if os.path.exists(input_short):
        clean_synaptic_csv(input_short, output_short, is_short=True)
    else:
        print(f"File not found: {input_short}")

    if os.path.exists(input_long):
        clean_synaptic_csv(input_long, output_long, is_short=False)
    else:
        print(f"File not found: {input_long}")

if __name__ == '__main__':
    main()
