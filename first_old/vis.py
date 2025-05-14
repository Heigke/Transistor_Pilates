#!/usr/bin/env python3
"""
NS-RAM System Stress Test Visualization
Plots data collected from the stress testing script
"""

import os
import sys
import pandas as pd
import numpy as np
import matplotlib.pyplot as plt
import matplotlib.dates as mdates
from matplotlib.gridspec import GridSpec
from datetime import datetime
import argparse

def load_data(data_dir):
    """Load data from CSV files in the specified directory"""
    data = {}
    
    # Load system summary data
    summary_file = os.path.join(data_dir, 'system_summary.csv')
    if os.path.exists(summary_file):
        data['summary'] = pd.read_csv(summary_file)
    
    # Load neuron mode data
    neuron_file = os.path.join(data_dir, 'neuron_data.csv')
    if os.path.exists(neuron_file):
        data['neuron'] = pd.read_csv(neuron_file)
        # Convert timestamp to datetime
        data['neuron']['datetime'] = pd.to_datetime(data['neuron']['timestamp'], unit='s')
    
    # Load synaptic short-term data
    synaptic_short_file = os.path.join(data_dir, 'synaptic_short_data.csv')
    if os.path.exists(synaptic_short_file):
        data['synaptic_short'] = pd.read_csv(synaptic_short_file)
        # Convert timestamp to datetime
        data['synaptic_short']['datetime'] = pd.to_datetime(data['synaptic_short']['timestamp'], unit='s')
    
    # Load synaptic long-term data
    synaptic_long_file = os.path.join(data_dir, 'synaptic_long_data.csv')
    if os.path.exists(synaptic_long_file):
        data['synaptic_long'] = pd.read_csv(synaptic_long_file)
        # Convert timestamp to datetime
        data['synaptic_long']['datetime'] = pd.to_datetime(data['synaptic_long']['timestamp'], unit='s')
    
    # Load test configuration
    config_file = os.path.join(data_dir, 'test_config.txt')
    if os.path.exists(config_file):
        data['config'] = {}
        with open(config_file, 'r') as f:
            for line in f:
                if '=' in line:
                    key, value = line.strip().split('=', 1)
                    # Remove quotes if present
                    value = value.strip('"\'')
                    try:
                        # Convert to numeric if possible
                        data['config'][key] = float(value)
                    except ValueError:
                        data['config'][key] = value
    
    return data

def plot_summary(data, output_dir):
    """Plot overall system metrics summary"""
    if 'summary' not in data:
        print("No summary data available")
        return
    
    df = data['summary']
    
    # Create figure
    plt.figure(figsize=(10, 6))
    
    # Extract baseline and final values
    metrics = df['metric'].tolist()
    baseline = df['baseline'].astype(float).tolist()
    final = df['final'].astype(float).tolist()
    percent_change = df['percent_change'].astype(float).tolist()
    
    # Create bar chart
    x = np.arange(len(metrics))
    width = 0.35
    
    fig, ax = plt.subplots(figsize=(12, 6))
    baseline_bars = ax.bar(x - width/2, baseline, width, label='Baseline')
    final_bars = ax.bar(x + width/2, final, width, label='Final')
    
    # Add labels
    ax.set_ylabel('Value')
    ax.set_title('System Metrics: Baseline vs Final')
    ax.set_xticks(x)
    ax.set_xticklabels(metrics)
    ax.legend()
    
    # Add percentage change labels
    for i, v in enumerate(percent_change):
        ax.annotate(f"{v:.1f}%", 
                   xy=(i + width/2, final[i]),
                   xytext=(0, 3),  # 3 points vertical offset
                   textcoords="offset points",
                   ha='center', va='bottom')
    
    plt.tight_layout()
    plt.savefig(os.path.join(output_dir, 'summary_comparison.png'))
    plt.close()

def plot_neuron_mode(data, output_dir):
    """Plot neuron mode test results"""
    if 'neuron' not in data:
        print("No neuron mode data available")
        return
    
    df = data['neuron']
    if len(df) == 0:
        print("Neuron mode data is empty")
        return
    
    # Create figure with 3 subplots: temperature, frequency, and recovery time
    fig = plt.figure(figsize=(14, 12))
    gs = GridSpec(3, 1, figure=fig)
    
    # Temperature plot
    ax1 = fig.add_subplot(gs[0, 0])
    
    # Filter data for pulse and recovery phases
    pulse_data = df[df['phase'] == 'pulse']
    recovery_data = df[df['phase'] == 'recovery']
    
    # Plot temperature data
    for cycle in df['cycle'].unique():
        cycle_data = df[df['cycle'] == cycle]
        pulse_cycle = cycle_data[cycle_data['phase'] == 'pulse']
        recovery_cycle = cycle_data[cycle_data['phase'] == 'recovery']
        
        if not pulse_cycle.empty:
            ax1.plot(pulse_cycle.index, pulse_cycle['temp'].astype(float), 'ro', label=f'Cycle {cycle} Pulse' if cycle == 1 else "")
        
        if not recovery_cycle.empty:
            ax1.plot(recovery_cycle.index, recovery_cycle['temp'].astype(float), 'bo', label=f'Cycle {cycle} Recovery' if cycle == 1 else "")
        
        # Connect points for the same cycle
        if not pulse_cycle.empty and not recovery_cycle.empty:
            x_points = list(pulse_cycle.index) + list(recovery_cycle.index)
            y_points = list(pulse_cycle['temp'].astype(float)) + list(recovery_cycle['temp'].astype(float))
            ax1.plot(x_points, y_points, 'k-', alpha=0.3)
    
    ax1.set_title('Temperature During Neuron Mode Cycles')
    ax1.set_ylabel('Temperature (°C)')
    ax1.set_xlabel('Measurement Index')
    if cycle == 1:  # Only add legend for first cycle to avoid clutter
        ax1.legend()
    
    # Frequency plot
    ax2 = fig.add_subplot(gs[1, 0])
    
    # Plot frequency data
    for cycle in df['cycle'].unique():
        cycle_data = df[df['cycle'] == cycle]
        pulse_cycle = cycle_data[cycle_data['phase'] == 'pulse']
        recovery_cycle = cycle_data[cycle_data['phase'] == 'recovery']
        
        if not pulse_cycle.empty:
            ax2.plot(pulse_cycle.index, pulse_cycle['freq'].astype(float)/1000, 'ro', label=f'Cycle {cycle} Pulse' if cycle == 1 else "")
        
        if not recovery_cycle.empty:
            ax2.plot(recovery_cycle.index, recovery_cycle['freq'].astype(float)/1000, 'bo', label=f'Cycle {cycle} Recovery' if cycle == 1 else "")
        
        # Connect points for the same cycle
        if not pulse_cycle.empty and not recovery_cycle.empty:
            x_points = list(pulse_cycle.index) + list(recovery_cycle.index)
            y_points = list(pulse_cycle['freq'].astype(float)/1000) + list(recovery_cycle['freq'].astype(float)/1000)
            ax2.plot(x_points, y_points, 'k-', alpha=0.3)
    
    ax2.set_title('CPU Frequency During Neuron Mode Cycles')
    ax2.set_ylabel('Frequency (GHz)')
    ax2.set_xlabel('Measurement Index')
    if cycle == 1:  # Only add legend for first cycle to avoid clutter
        ax2.legend()
    
    # Recovery time plot (only for recovery phase)
    ax3 = fig.add_subplot(gs[2, 0])
    
    recovery_times = []
    cycle_nums = []
    
    for cycle in df['cycle'].unique():
        cycle_recovery = df[(df['cycle'] == cycle) & (df['phase'] == 'recovery')]
        if not cycle_recovery.empty:
            try:
                recovery_time = float(cycle_recovery['recovery_time'].iloc[0])
                recovery_times.append(recovery_time)
                cycle_nums.append(cycle)
            except (ValueError, TypeError):
                # Skip if recovery time is not a valid float
                pass
    
    if recovery_times:
        ax3.bar(cycle_nums, recovery_times)
        ax3.set_title('Recovery Time by Cycle (tau_r analogy)')
        ax3.set_ylabel('Recovery Time (s)')
        ax3.set_xlabel('Cycle')
        ax3.set_xticks(cycle_nums)
        
        # Add a trend line
        if len(recovery_times) > 1:
            z = np.polyfit(cycle_nums, recovery_times, 1)
            p = np.poly1d(z)
            ax3.plot(cycle_nums, p(cycle_nums), "r--", alpha=0.8, label=f"Trend: {z[0]:.4f}x + {z[1]:.4f}")
            ax3.legend()
    
    plt.tight_layout()
    plt.savefig(os.path.join(output_dir, 'neuron_mode_analysis.png'))
    plt.close()

def plot_synaptic_short_term(data, output_dir):
    """Plot synaptic short-term plasticity test results"""
    if 'synaptic_short' not in data:
        print("No synaptic short-term data available")
        return
    
    df = data['synaptic_short']
    if len(df) == 0:
        print("Synaptic short-term data is empty")
        return
    
    # Create a new figure
    plt.figure(figsize=(14, 10))
    
    # Plot the benchmark scores for each cycle with separate colors for different phases
    for cycle in df['cycle'].unique():
        cycle_data = df[df['cycle'] == cycle]
        
        # Plot each phase with different styles
        # Potentiation phase (should show decline in performance)
        pot_data = cycle_data[cycle_data['phase'] == 'potentiation']
        if not pot_data.empty:
            plt.plot(pot_data['datetime'], pot_data['bench_score'].astype(float), 
                     'ro-', label=f'Cycle {cycle} Potentiation' if cycle == 1 else None)
        
        # Depression phase (should show recovery in performance)
        dep_data = cycle_data[cycle_data['phase'] == 'depression']
        if not dep_data.empty:
            plt.plot(dep_data['datetime'], dep_data['bench_score'].astype(float), 
                     'go-', label=f'Cycle {cycle} Depression' if cycle == 1 else None)
        
        # Forgetting phase (should show gradual return to baseline)
        forget_data = cycle_data[cycle_data['phase'] == 'forget']
        if not forget_data.empty:
            plt.plot(forget_data['datetime'], forget_data['bench_score'].astype(float), 
                     'bo-', label=f'Cycle {cycle} Forgetting' if cycle == 1 else None)
        
        # Start and end points
        start_data = cycle_data[cycle_data['phase'] == 'start']
        end_data = cycle_data[cycle_data['phase'] == 'end']
        
        if not start_data.empty:
            plt.plot(start_data['datetime'], start_data['bench_score'].astype(float), 
                     'kD', markersize=8, label=f'Cycle {cycle} Start' if cycle == 1 else None)
        
        if not end_data.empty:
            plt.plot(end_data['datetime'], end_data['bench_score'].astype(float), 
                     'kX', markersize=8, label=f'Cycle {cycle} End' if cycle == 1 else None)
    
    # Get baseline benchmark score from config if available
    baseline = None
    if 'config' in data and 'BASELINE_BENCH' in data['config']:
        baseline = data['config']['BASELINE_BENCH']
    
    # Add baseline line if available
    if baseline is not None:
        plt.axhline(y=baseline, color='k', linestyle='--', label='Baseline Performance')
    
    plt.title('Synaptic Short-Term Plasticity Test: Performance Over Time')
    plt.xlabel('Time')
    plt.ylabel('Benchmark Score (events/sec)')
    plt.legend(loc='best')
    plt.grid(True, alpha=0.3)
    
    # Format x-axis as time
    plt.gca().xaxis.set_major_formatter(mdates.DateFormatter('%H:%M:%S'))
    plt.gcf().autofmt_xdate()
    
    plt.tight_layout()
    plt.savefig(os.path.join(output_dir, 'synaptic_short_term_analysis.png'))
    plt.close()
    
    # Create a second plot showing percent of baseline
    plt.figure(figsize=(14, 8))
    
    for cycle in df['cycle'].unique():
        cycle_data = df[df['cycle'] == cycle]
        
        # Only include rows with valid percent values
        valid_percent = cycle_data[cycle_data['percent_of_baseline'] != 'N/A']
        if not valid_percent.empty:
            try:
                # Convert percent to float if it's not already
                valid_percent['percent_float'] = valid_percent['percent_of_baseline'].astype(float)
                
                plt.plot(valid_percent['datetime'], valid_percent['percent_float'], 
                         'o-', label=f'Cycle {cycle}')
            except (ValueError, TypeError):
                print(f"Warning: Could not convert percent values for cycle {cycle}")
    
    plt.axhline(y=100, color='k', linestyle='--', label='Baseline (100%)')
    plt.title('Synaptic Short-Term Plasticity Test: Performance as Percentage of Baseline')
    plt.xlabel('Time')
    plt.ylabel('Performance (% of Baseline)')
    plt.legend(loc='best')
    plt.grid(True, alpha=0.3)
    
    # Format x-axis as time
    plt.gca().xaxis.set_major_formatter(mdates.DateFormatter('%H:%M:%S'))
    plt.gcf().autofmt_xdate()
    
    plt.tight_layout()
    plt.savefig(os.path.join(output_dir, 'synaptic_short_term_percent.png'))
    plt.close()

def plot_synaptic_long_term(data, output_dir):
    """Plot synaptic long-term plasticity test results"""
    if 'synaptic_long' not in data:
        print("No synaptic long-term data available")
        return
    
    df = data['synaptic_long']
    if len(df) == 0:
        print("Synaptic long-term data is empty")
        return
    
    # Create figure with subplots
    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(14, 12))
    
    # Temperature plot
    cycle_numbers = []
    pot_temps = []
    dep_temps = []
    
    for cycle in sorted(df['cycle'].unique()):
        cycle_data = df[df['cycle'] == cycle]
        
        # Get temperature data for potentiation and depression phases
        pot_data = cycle_data[cycle_data['phase'] == 'potentiation']
        dep_data = cycle_data[cycle_data['phase'] == 'depression']
        
        if not pot_data.empty and 'temp' in pot_data.columns:
            try:
                pot_temp = float(pot_data['temp'].iloc[0])
                pot_temps.append(pot_temp)
                cycle_numbers.append(cycle)
            except (ValueError, TypeError):
                pass
        
        if not dep_data.empty and 'temp' in dep_data.columns:
            try:
                dep_temp = float(dep_data['temp'].iloc[0])
                dep_temps.append(dep_temp)
            except (ValueError, TypeError):
                pass
    
    # Plot temperature data
    if cycle_numbers and pot_temps:
        ax1.plot(cycle_numbers, pot_temps, 'ro-', label='After Potentiation')
    if cycle_numbers and dep_temps:
        ax1.plot(cycle_numbers, dep_temps, 'bo-', label='After Depression')
    
    ax1.set_title('Temperature During Long-Term Potentiation/Depression Cycles')
    ax1.set_xlabel('Cycle')
    ax1.set_ylabel('Temperature (°C)')
    ax1.legend()
    ax1.grid(True, alpha=0.3)
    
    # Error/Corruption events plot
    error_cycles = []
    corruption_cycles = []
    
    for i, row in df.iterrows():
        try:
            if float(row['error_detected']) > 0:
                error_cycles.append(float(row['cycle']))
            if float(row['corruption_detected']) > 0:
                corruption_cycles.append(float(row['cycle']))
        except (ValueError, TypeError):
            pass
    
    # Plot retention phase data separately
    retention_data = df[df['phase'].str.contains('retention')]
    if not retention_data.empty:
        # Extract numeric timestamp for plotting on consistent scale
        retention_data['elapsed'] = retention_data['timestamp'] - retention_data['timestamp'].min()
        
        # Plot bench scores during retention if available
        valid_bench = retention_data[retention_data['bench_score'] != 'N/A']
        if not valid_bench.empty:
            try:
                ax2.plot(valid_bench['elapsed'], valid_bench['bench_score'].astype(float), 
                         'go-', label='Performance During Retention')
            except (ValueError, TypeError):
                print("Warning: Could not convert bench scores during retention")
    
    # Plot error events
    if error_cycles:
        for cycle in error_cycles:
            ax2.axvline(x=cycle, color='r', linestyle='--', alpha=0.7)
        ax2.plot([], [], 'r--', label='Error Detected')  # For legend
    
    if corruption_cycles:
        for cycle in corruption_cycles:
            ax2.axvline(x=cycle, color='m', linestyle='--', alpha=0.7)
        ax2.plot([], [], 'm--', label='Corruption Detected')  # For legend
    
    ax2.set_title('System Events During Long-Term Test and Retention Phase')
    ax2.set_xlabel('Cycle / Elapsed Time (s) during Retention')
    ax2.set_ylabel('Benchmark Score / Event')
    ax2.legend()
    ax2.grid(True, alpha=0.3)
    
    plt.tight_layout()
    plt.savefig(os.path.join(output_dir, 'synaptic_long_term_analysis.png'))
    plt.close()

def main():
    parser = argparse.ArgumentParser(description='NS-RAM System Stress Test Visualization')
    parser.add_argument('data_dir', help='Directory containing test data files')
    parser.add_argument('--output', '-o', default=None, help='Output directory for plots (default: same as data_dir)')
    
    args = parser.parse_args()
    
    data_dir = args.data_dir
    output_dir = args.output if args.output else data_dir
    
    if not os.path.exists(data_dir):
        print(f"Error: Data directory {data_dir} does not exist")
        sys.exit(1)
    
    if not os.path.exists(output_dir):
        os.makedirs(output_dir)
    
    print(f"Loading data from {data_dir}...")
    data = load_data(data_dir)
    
    if not data:
        print("No data found in the specified directory")
        sys.exit(1)
    
    print("Generating plots...")
    
    # Create summary plot
    if 'summary' in data:
        print("- Plotting system summary")
        plot_summary(data, output_dir)
    
    # Create neuron mode plots
    if 'neuron' in data:
        print("- Plotting neuron mode analysis")
        plot_neuron_mode(data, output_dir)
    
    # Create synaptic short-term plots
    if 'synaptic_short' in data:
        print("- Plotting synaptic short-term analysis")
        plot_synaptic_short_term(data, output_dir)
    
    # Create synaptic long-term plots
    if 'synaptic_long' in data:
        print("- Plotting synaptic long-term analysis")
        plot_synaptic_long_term(data, output_dir)
    
    print(f"Plots saved to {output_dir}")

if __name__ == "__main__":
    main()
