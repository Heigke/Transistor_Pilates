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

def safe_float(series):
    return pd.to_numeric(series, errors='coerce')

def load_data(data_dir):
    data = {}

    def load_csv(filename):
        path = os.path.join(data_dir, filename)
        return pd.read_csv(path) if os.path.exists(path) else None

    # System summary
    data['summary'] = load_csv('system_summary.csv')

    # Neuron mode
    df_neuron = load_csv('neuron_data.csv')
    if df_neuron is not None:
        df_neuron['datetime'] = pd.to_datetime(df_neuron['timestamp'], unit='s')
        data['neuron'] = df_neuron

    # Synaptic short-term
    df_short = load_csv('synaptic_short_data.csv')
    if df_short is not None:
        df_short['datetime'] = pd.to_datetime(df_short['timestamp'], unit='s')
        data['synaptic_short'] = df_short

    # Synaptic long-term
    df_long = load_csv('synaptic_long_data.csv')
    if df_long is not None:
        df_long['datetime'] = pd.to_datetime(df_long['timestamp'], unit='s')
        data['synaptic_long'] = df_long

    # Config
    config_path = os.path.join(data_dir, 'test_config.txt')
    if os.path.exists(config_path):
        data['config'] = {}
        with open(config_path) as f:
            for line in f:
                if '=' in line:
                    k, v = line.strip().split('=', 1)
                    v = v.strip('"\'')
                    try:
                        data['config'][k] = float(v)
                    except ValueError:
                        data['config'][k] = v
    return data

def plot_summary(data, output_dir):
    if 'summary' not in data:
        print("No summary data.")
        return

    df = data['summary'].copy()
    df['baseline'] = safe_float(df['baseline'])
    df['final'] = safe_float(df['final'])
    df['percent_change'] = safe_float(df['percent_change'])

    x = np.arange(len(df))
    width = 0.35

    # Baseline vs Final (log)
    fig, ax1 = plt.subplots(figsize=(12, 6))
    ax1.bar(x - width/2, df['baseline'], width, label='Baseline')
    ax1.bar(x + width/2, df['final'], width, label='Final')
    ax1.set_yscale('log')
    ax1.set_ylabel('Log Scale')
    ax1.set_title('Baseline vs Final (Log Scale)')
    ax1.set_xticks(x)
    ax1.set_xticklabels(df['metric'], rotation=45, ha='right')
    ax1.legend()
    for i, v in enumerate(df['percent_change']):
        if not np.isnan(v):
            ax1.annotate(f"{v:.1f}%", (i + width/2, df['final'].iloc[i]), xytext=(0, 5),
                         textcoords="offset points", ha='center')
    plt.tight_layout()
    plt.savefig(os.path.join(output_dir, 'summary_comparison_log.png'))
    plt.close()

    # Percent change
    fig2, ax2 = plt.subplots(figsize=(10, 6))
    bars = ax2.bar(x, df['percent_change'], width=0.5)
    ax2.axhline(0, color='gray', linestyle='--')
    ax2.set_title('Percent Change from Baseline')
    ax2.set_ylabel('% Change')
    ax2.set_xticks(x)
    ax2.set_xticklabels(df['metric'], rotation=45, ha='right')
    for i, bar in enumerate(bars):
        if not np.isnan(bar.get_height()):
            ax2.annotate(f"{bar.get_height():.1f}%", (bar.get_x() + bar.get_width() / 2, bar.get_height()),
                         xytext=(0, 3), textcoords="offset points", ha='center')
    plt.tight_layout()
    plt.savefig(os.path.join(output_dir, 'summary_percent_change.png'))
    plt.close()

def plot_neuron_mode(data, output_dir):
    if 'neuron' not in data:
        return

    df = data['neuron'].copy()
    df['temp'] = safe_float(df['temp'])
    df['freq'] = safe_float(df['freq']) / 1000  # to GHz
    df['recovery_time'] = safe_float(df['recovery_time'])

    fig = plt.figure(figsize=(14, 12))
    gs = GridSpec(3, 1, figure=fig)
    ax1 = fig.add_subplot(gs[0])
    ax2 = fig.add_subplot(gs[1])
    ax3 = fig.add_subplot(gs[2])

    for cycle in df['cycle'].unique():
        cdf = df[df['cycle'] == cycle]
        pulse = cdf[cdf['phase'] == 'pulse']
        recovery = cdf[cdf['phase'] == 'recovery']

        ax1.plot(pulse.index, pulse['temp'], 'ro', label='Pulse' if cycle == 1 else "")
        ax1.plot(recovery.index, recovery['temp'], 'bo', label='Recovery' if cycle == 1 else "")
        ax1.plot(list(pulse.index) + list(recovery.index),
                 list(pulse['temp']) + list(recovery['temp']), 'k-', alpha=0.3)

        ax2.plot(pulse.index, pulse['freq'], 'ro', label='Pulse' if cycle == 1 else "")
        ax2.plot(recovery.index, recovery['freq'], 'bo', label='Recovery' if cycle == 1 else "")
        ax2.plot(list(pulse.index) + list(recovery.index),
                 list(pulse['freq']) + list(recovery['freq']), 'k-', alpha=0.3)

    ax1.set_title('Temperature over Neuron Cycles'); ax1.set_ylabel('°C'); ax1.set_xlabel('Index')
    ax2.set_title('CPU Frequency (GHz)'); ax2.set_ylabel('GHz'); ax2.set_xlabel('Index')
    ax1.legend(); ax2.legend()

    recovery_data = df[df['phase'] == 'recovery']
    recovery_data = recovery_data.dropna(subset=['recovery_time'])
    if not recovery_data.empty:
        ax3.bar(recovery_data['cycle'], recovery_data['recovery_time'])
        z = np.polyfit(recovery_data['cycle'], recovery_data['recovery_time'], 1)
        p = np.poly1d(z)
        ax3.plot(recovery_data['cycle'], p(recovery_data['cycle']), 'r--', label='Trend')
        ax3.legend()
    ax3.set_title('Recovery Time per Cycle'); ax3.set_ylabel('s'); ax3.set_xlabel('Cycle')

    plt.tight_layout()
    plt.savefig(os.path.join(output_dir, 'neuron_mode_analysis.png'))
    plt.close()

def main():
    parser = argparse.ArgumentParser(description='NS-RAM Visualization Tool')
    parser.add_argument('data_dir', help='Path to NS-RAM test data directory')
    parser.add_argument('-o', '--output', help='Output dir for plots', default=None)
    args = parser.parse_args()

    data_dir = args.data_dir
    output_dir = args.output or data_dir
    if not os.path.exists(data_dir):
        print(f"Directory not found: {data_dir}"); sys.exit(1)
    if not os.path.exists(output_dir):
        os.makedirs(output_dir)

    print("Loading data...")
    data = load_data(data_dir)
    if not data:
        print("No data loaded."); sys.exit(1)

    print("Plotting summary...")
    plot_summary(data, output_dir)
    print("Plotting neuron mode...")
    plot_neuron_mode(data, output_dir)
    print("Done.")

if __name__ == '__main__':
    main()
