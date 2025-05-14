# Transistor_Pilates

## Project Description

The **Transistor_Pilates** project provides a conceptual, system-level analogy suite designed to explore behaviors inspired by the **Neuro-Synaptic Random Access Memory (NS-RAM)** cell. NS-RAM is a novel approach demonstrating that a single standard CMOS transistor, when biased in a specific, unconventional manner, can exhibit both neural and synaptic behaviors [1, 2]. By operating a MOSFET on the verge of punch-through and controlling the bulk connection, researchers have shown it can mimic leaky-integrate-and-fire neuron characteristics and adjustable synaptic plasticity (short-term and long-term) [2-5].

This project's script, "Advanced NS-RAM System-Level Analogy Stress Suite", **does not replicate transistor physics** [6]. Instead, it uses standard system stress tools (`stress-ng`, `sysbench`, etc.) to induce observable system behaviors (such as throttling, performance changes, and errors) [6]. These system behaviors are then interpreted conceptually as analogies for the NS-RAM transistor dynamics like Leaky-Integrate-and-Fire (LIF), Plasticity (Short-Term and Long-Term), and Tunability [6-9].

The script attempts to map high system load pulses to 'neural firing' or 'synaptic potentiation', idle periods to 'recovery' or 'forgetting', and monitors system state (CPU frequency, temperature, benchmark performance) as indicators of these analogized 'neuro-synaptic' effects [7, 10-17]. It also includes checks for critical system errors or data corruption as potential analogies for device threshold exceedance, instability, or irreversible state changes [18-26].

## Setup and Usage

**!!! EXTREME WARNING: This script is DANGEROUS and EXPERIMENTAL. It is intended for TEST MACHINES ONLY and CANNOT replicate transistor physics. It applies significant system stress and may cause instability, data loss, or hardware damage. Use with extreme caution.** [6, 27]

1.  **Make the script executable:**
    ```bash
    chmod +x plast_claude_vis.sh
    ```

2.  **Copy source files:**
    (These files are used for compiling custom stress tools mentioned in the script, though compilation checks for their presence [28, 29].)
    ```bash
    cp spec_havoccopy.S spec_havoc.S
    cp hammercopy.c hammer.c
    ```

3.  **Run the main script:**
    (This script checks for and attempts to install dependencies [30, 31], sets system parameters, runs stress tests based on configured modes, and logs results [7-9, 27, 32].) **Requires root privileges.**
    ```bash
    sudo ./plast_claude_vis.sh
    ```
    The script will output progress and results to the console and a log file [10].

4.  **When done, run the visualization:**
    (Requires a separate visualization script, `vis.py`, which is not provided in the sources but is mentioned in the original README content.)
    ```bash
    python vis.py
    ```

## Warnings

*   This script is marked as **EXTREME DANGER** and for **CONCEPTUAL ANALOGY ONLY** on test machines [6].
*   It **CANNOT replicate transistor physics** [6].
*   It applies **significant stress** to the CPU and other system components [10, 13, 33].
*   Running this script **may cause system instability, crashes, data corruption, or permanent hardware damage** [6, 25, 27].
*   The script requires and modifies system settings like the CPU governor, turbo/boost states, and ASLR [28, 34]. It also attempts to manage RAPL power limits [35-37].
*   Critical errors (like Machine Check Exceptions or system panics) and data corruption checks are included as failure indicators within the analogy, but these signify actual potential system failures [18-22, 25].

**Use at your own risk.**

## Reference Article

The concepts informing this project are drawn from the research demonstrating neuro-synaptic behaviors in standard silicon transistors:

**Pazos, S., Zhu, K., Villena, M. A., Alharbi, O., Zheng, W., Shen, Y., Yuan, Y., Ping, Y., & Lanza, M. (2025). Synaptic and neural behaviours in a standard silicon transistor. *Nature*, *639*(8053), 575–581.** [1, 38]
**DOI:** https://doi.org/10.1038/s41586-025-08742-4 [38]

This paper details how standard CMOS MOSFETs, specifically when operated in a floating-bulk configuration near punch-through conditions, can mimic essential functions of biological neurons (like leaky-integrate-and-fire) and synapses (like short-term and long-term plasticity), forming a versatile NS-RAM cell using just two transistors [1, 2, 39, 40].
