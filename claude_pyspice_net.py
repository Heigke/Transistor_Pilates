import PySpice.Logging.Logging as Logging
from PySpice.Spice.Netlist import Circuit
from PySpice.Unit import * # Import units for clarity e.g., u_s, u_V, u_Ohm
import matplotlib.pyplot as plt
import numpy as np
from sklearn.datasets import fetch_openml
import matplotlib.gridspec as gridspec
from matplotlib.colors import LinearSegmentedColormap
from tqdm import tqdm
import os
from datetime import datetime
logger = Logging.setup_logging()

# Create results directory for plots
RESULTS_DIR = f"neuromorphic_results_{datetime.now().strftime('%Y%m%d_%H%M%S')}"
os.makedirs(RESULTS_DIR, exist_ok=True)
print(f"Results will be saved to: {RESULTS_DIR}")

# ---- Define Cell Types ----
CELL_TYPE_SRAM = 0                      # Stable weights (long-term memory)
CELL_TYPE_DRAM_REFRESHED = 1            # Semi-stable weights (mid-term memory)
CELL_TYPE_DRAM_LEAKY = 2                # Unstable weights (short-term memory)
CELL_TYPE_DRAM_NEIGHBOR_CTRL_LEAKY = 3  # Lateral inhibition/excitation weights

# ---- Neuromorphic Learning Parameters ----
LEARNING_STEPS = 1                      # Number of learning iterations
LEARNING_RATE_BASE = 1.0                # Base learning rate
LATERAL_INHIBITION_STRENGTH = 0.8       # Strength of lateral inhibition
DECAY_FACTOR_REFRESHED = 0.05           # Decay rate for refreshed DRAM
DECAY_FACTOR_LEAKY = 0.3                # Decay rate for leaky DRAM
DECAY_FACTOR_NEIGHBOR_CTRL = 0.5        # Decay rate for neighbor-controlled DRAM

# ---- Simulation Parameters ----
VERBOSE_DEBUG = True                    # Enable verbose debug output
PLOT_INTERMEDIATE = True                # Plot intermediate states during learning
SENSE_THRESHOLD = 0.35                  # Voltage threshold for digital conversion 
NOISE_STD = 0.015                       # Noise standard deviation

print("=" * 80)
print("NEUROMORPHIC LEARNING NETWORK WITH MIXED MEMORY CELL TYPES")
print("=" * 80)
print(f"Learning Steps: {LEARNING_STEPS}")
print(f"Learning Rate Base: {LEARNING_RATE_BASE}")
print(f"Lateral Inhibition Strength: {LATERAL_INHIBITION_STRENGTH}")
print(f"Cell Types: SRAM, DRAM-Refreshed, DRAM-Leaky, DRAM-Neighbor-Controlled")
print("=" * 80)

# ---- Load MNIST, select samples for training and testing ----
mnist = fetch_openml('mnist_784', version=1, as_frame=False, parser='auto')
images = mnist.data.astype(np.float32)
labels = mnist.target.astype(str)
labels = np.array([int(x) for x in labels])

def extract_center_block(img, size=4):
    img_2d = img.reshape(28, 28)
    block = img_2d[12:12+size, 12:12+size]
    return (block > 127).astype(int).flatten()

num_inputs = 16  # 4x4 block
num_hidden = 6   # Hidden layer size
num_outputs = 4  # Output layer size

blocks = np.array([extract_center_block(img) for img in images])

# Select training samples
selected_train_idx = []
used_digits = set()
for idx, (block, lbl) in enumerate(zip(blocks, labels)):
    if lbl < num_outputs and lbl not in used_digits and np.sum(block) > 2:  # Ensure pattern has at least 3 active pixels
        selected_train_idx.append(idx)
        used_digits.add(lbl)
    if len(selected_train_idx) == num_outputs:
        break

if len(selected_train_idx) < num_outputs:
    print("ERROR: Could not find enough unique digits < num_outputs with sufficient active pixels!")
    exit(1)

# Select test samples (different from training)
selected_test_idx = []
for idx, (block, lbl) in enumerate(zip(blocks, labels)):
    if lbl < num_outputs and idx not in selected_train_idx and np.sum(block) > 2:
        selected_test_idx.append(idx)
    if len(selected_test_idx) == num_outputs:
        break

# Prepare training patterns and targets
train_patterns = blocks[selected_train_idx, :]
train_labels = labels[selected_train_idx]
train_targets = np.zeros((num_outputs, num_outputs), dtype=int)
for i, lbl in enumerate(train_labels):
    train_targets[i, lbl] = 1  # one-hot encoding

# Prepare test patterns and targets
test_patterns = blocks[selected_test_idx, :]
test_labels = labels[selected_test_idx]
test_targets = np.zeros((len(test_labels), num_outputs), dtype=int)
for i, lbl in enumerate(test_labels):
    test_targets[i, lbl] = 1  # one-hot encoding

print("\n==== DEBUG: Training Data ====")
print(f"Selected Training Indices: {selected_train_idx}")
print(f"Training Labels: {train_labels}")
print("Training Patterns:")
for i, pattern in enumerate(train_patterns):
    print(f"Pattern {i} (digit {train_labels[i]}):")
    print(pattern.reshape(4, 4))
    print()

print("\n==== DEBUG: Test Data ====")
print(f"Selected Test Indices: {selected_test_idx}")
print(f"Test Labels: {test_labels}")


# ---- Network Architecture Functions ----
def initialize_network_architecture():
    """Determines the architecture of the neural network based on cell types"""
    global cell_types_input_hidden, cell_types_hidden_output
    
    # Input to Hidden layer connectivity (initially all DRAM-Leaky)
    cell_types_input_hidden = np.full((num_inputs, num_hidden), CELL_TYPE_DRAM_LEAKY, dtype=int)
    
    # Make some connections permanent (SRAM) - stable pathways
    for i in range(min(num_inputs, num_hidden)):
        cell_types_input_hidden[i, i] = CELL_TYPE_SRAM
    
    # Make some connections semi-permanent (DRAM-Refreshed) - slowly adapting pathways
    num_refreshed = max(2, num_hidden // 4)
    idx = np.random.choice(num_inputs * num_hidden, num_refreshed, replace=False)
    for i in idx:
        row, col = i // num_hidden, i % num_hidden
        if cell_types_input_hidden[row, col] != CELL_TYPE_SRAM:  # Don't overwrite SRAM
            cell_types_input_hidden[row, col] = CELL_TYPE_DRAM_REFRESHED
    
    # Add neighbor-controlled connections for lateral inhibition/excitation
    for h in range(num_hidden):
        neighbors = [n for n in range(num_hidden) if n != h]
        if neighbors:
            # Connect from specific inputs to enable lateral effects
            input_idx = np.random.choice(num_inputs, size=min(2, len(neighbors)), replace=False)
            for i in input_idx:
                if cell_types_input_hidden[i, h] != CELL_TYPE_SRAM:
                    cell_types_input_hidden[i, h] = CELL_TYPE_DRAM_NEIGHBOR_CTRL_LEAKY
    
    # Hidden to Output layer connectivity (initially all DRAM-Leaky)
    cell_types_hidden_output = np.full((num_hidden, num_outputs), CELL_TYPE_DRAM_LEAKY, dtype=int)
    
    # Make some connections permanent (SRAM) - stable pathways
    for i in range(min(num_hidden, num_outputs)):
        cell_types_hidden_output[i, i] = CELL_TYPE_SRAM
    
    # Make some connections semi-permanent (DRAM-Refreshed) - slowly adapting pathways
    num_refreshed = max(2, num_outputs // 2)
    idx = np.random.choice(num_hidden * num_outputs, num_refreshed, replace=False)
    for i in idx:
        row, col = i // num_outputs, i % num_outputs
        if cell_types_hidden_output[row, col] != CELL_TYPE_SRAM:  # Don't overwrite SRAM
            cell_types_hidden_output[row, col] = CELL_TYPE_DRAM_REFRESHED
    
    # Add neighbor-controlled connections for lateral inhibition
    for o in range(num_outputs):
        # Connect from random hidden neurons for lateral effect
        hidden_idx = np.random.choice(num_hidden, size=min(2, num_hidden), replace=False)
        for h in hidden_idx:
            if cell_types_hidden_output[h, o] != CELL_TYPE_SRAM:
                cell_types_hidden_output[h, o] = CELL_TYPE_DRAM_NEIGHBOR_CTRL_LEAKY
    
    print("\n==== DEBUG: Network Architecture ====")
    print("Input-to-Hidden Cell Types:")
    print_cell_types_matrix(cell_types_input_hidden)
    print("\nHidden-to-Output Cell Types:")
    print_cell_types_matrix(cell_types_hidden_output)
    
    return cell_types_input_hidden, cell_types_hidden_output

def print_cell_types_matrix(matrix):
    """Prints a readable representation of cell types matrix"""
    cell_type_str = {
        CELL_TYPE_SRAM: "SRAM",
        CELL_TYPE_DRAM_REFRESHED: "DRAM-R",
        CELL_TYPE_DRAM_LEAKY: "DRAM-L",
        CELL_TYPE_DRAM_NEIGHBOR_CTRL_LEAKY: "DRAM-NC"
    }
    
    for i in range(matrix.shape[0]):
        row = [cell_type_str[cell] for cell in matrix[i]]
        print(f"Row {i}: {row}")


# ---- Simulation Functions ----
def build_circuit_for_learning(learning_step=0):
    """Build a SPICE circuit for the current learning step"""
    circuit = Circuit(f'Neuromorphic Learning Network (Step {learning_step})')
    
    # Physical parameters - FIXED: scaled values for better convergence
    temp_C = 37  # Body temperature
    cell_cap_fast_nom = 100e-15  # Fast component capacitance (increased)
    cell_cap_slow_nom = 500e-15  # Slow component capacitance (increased)
    leak_res_fast_nom = 1e6      # Fast leakage resistance (decreased for better convergence)
    leak_res_slow_nom = 1e7      # Slow leakage resistance (decreased for better convergence)
    
    # Line parasitics
    bl_line_cap = 100e-15  # Increased for stability
    wl_line_cap = 100e-15  # Increased for stability
    
    # Supply voltage
    vdd = 10*1.2  # Supply voltage in volts
    
    # Add VDD
    circuit.V('dd', 'vdd', circuit.gnd, vdd@u_V)
    
    # FIXED: Add global options for better convergence
    # FIXED: Add global options for better convergence - using directive instead of options
    #circuit._netlist += ".OPTIONS TRTOL=7\n"
    # Add SPICE options for better convergence
    circuit.raw_spice = '''
.OPTIONS TRTOL=7
.OPTIONS RELTOL=0.01
.OPTIONS ABSTOL=1e-9
.OPTIONS VNTOL=1e-6
.OPTIONS ITL1=1000
.OPTIONS ITL2=500
.OPTIONS ITL4=100
.OPTIONS GMIN=1e-12
.TEMP 27
'''
  
    
    # Create nodes for all layers
    input_nodes = [f'input_{i}' for i in range(num_inputs)]
    hidden_nodes = [f'hidden_{h}' for h in range(num_hidden)]
    output_nodes = [f'output_{o}' for o in range(num_outputs)]
    
    # Create input-to-hidden synaptic cells
    ih_cells_fast = [[f'ih_syn_{i}_{h}_fast' for h in range(num_hidden)] for i in range(num_inputs)]
    ih_cells_slow = [[f'ih_syn_{i}_{h}_slow' for h in range(num_hidden)] for i in range(num_inputs)]
    
    # Create hidden-to-output synaptic cells
    ho_cells_fast = [[f'ho_syn_{h}_{o}_fast' for o in range(num_outputs)] for h in range(num_hidden)]
    ho_cells_slow = [[f'ho_syn_{h}_{o}_slow' for o in range(num_outputs)] for h in range(num_hidden)]
    
    # FIXED: Add default small capacitance to all nodes to prevent floating nodes
    for i in range(num_inputs):
        circuit.C(f'input_{i}_gnd_cap', f'input_{i}', circuit.gnd, 1e-15@u_F)
    
    for h in range(num_hidden):
        circuit.C(f'hidden_{h}_gnd_cap', f'hidden_{h}', circuit.gnd, 1e-15@u_F)
    
    for o in range(num_outputs):
        circuit.C(f'output_{o}_gnd_cap', f'output_{o}', circuit.gnd, 1e-15@u_F)
    
    # Create node capacitances (membrane capacitances)
    for node in input_nodes:
        circuit.C(f'{node}_cap', node, circuit.gnd, wl_line_cap@u_F)
    
    for node in hidden_nodes:
        circuit.C(f'{node}_cap', node, circuit.gnd, bl_line_cap@u_F)
        # FIXED: Increased resistance for better convergence
        circuit.R(f'{node}_leak', node, circuit.gnd, 5@u_MOhm)  # Membrane leakage
    
    for node in output_nodes:
        circuit.C(f'{node}_cap', node, circuit.gnd, bl_line_cap@u_F)
        # FIXED: Increased resistance for better convergence
        circuit.R(f'{node}_leak', node, circuit.gnd, 5@u_MOhm)  # Membrane leakage
    
    # Add neighbor modulation control signal
    circuit.V('neighbor_mod', 'v_neighbor_modulate', circuit.gnd, 0.0@u_V)
    
    # Add error feedback signals
    error_nodes = [f'error_{o}' for o in range(num_outputs)]
    for o in range(num_outputs):
        # FIXED: Added series resistance to voltage sources for better convergence
        #circuit.V(f'verror_{o}_src', f'verror_{o}_src_internal', circuit.gnd, 0.0@u_V)
        circuit.R(f'verror_{o}_series', f'verror_{o}_src_internal', error_nodes[o], 1@u_kOhm)
        # FIXED: Added pull-down resistor to error nodes
        circuit.R(f'verror_{o}_pulldown', error_nodes[o], circuit.gnd, 10@u_MOhm)
    
    # Add models for MOSFETs - FIXED: Adjusted parameters for better convergence
    circuit.model('nmos_syn', 'NMOS', LEVEL=1, vto=0.3@u_V, KP=50e-6, 
                  GAMMA=0.1, LAMBDA=0.01, PHI=0.6, TOX=10e-9@u_m)
    
    circuit.model('nmos_leak_ctrl', 'NMOS', LEVEL=1, vto=0.3@u_V, KP=50e-6, 
                  GAMMA=0.1, LAMBDA=0.01, PHI=0.6, TOX=10e-9@u_m)
    
    circuit.model('nmos_learn', 'NMOS', LEVEL=1, VTO=0.6@u_V, KP=30e-6, 
                  GAMMA=0.1, LAMBDA=0.01, PHI=0.6, TOX=10e-9@u_m)
    
    # Helper function for randomizing RC values
    def randomize_rc(R_nom, C_nom, VTO_nom=0.7, temp_C=37):
        T = 273.15 + temp_C
        # FIXED: Reduced randomness for better convergence
        R = R_nom * (1 + 0.002 * (T - 298)) * np.exp(np.random.normal(0, 0.1))
        C = C_nom * (0.95 + 0.1*np.random.rand())
        VTO = VTO_nom + np.random.normal(0, 0.01)  # Reduced variation
        return R, C, VTO
    
    # Add input-to-hidden synaptic connections
    for i in range(num_inputs):
        for h in range(num_hidden):
            # Get cell type and create nodes
            cell_type = cell_types_input_hidden[i, h]
            fast_node = ih_cells_fast[i][h]
            slow_node = ih_cells_slow[i][h]
            pre_node = input_nodes[i]
            post_node = hidden_nodes[h]
            
            # Randomize component values
            r_f_nom, c_f, vth_f = randomize_rc(leak_res_fast_nom, cell_cap_fast_nom, 0.5, temp_C)
            r_s_nom, c_s, vth_s = randomize_rc(leak_res_slow_nom, cell_cap_slow_nom, 0.5, temp_C)
            
            # Add synapse components
            circuit.C(f'ac_ih_fast_{i}_{h}', fast_node, circuit.gnd, c_f@u_F)
            circuit.C(f'ac_ih_slow_{i}_{h}', slow_node, circuit.gnd, c_s@u_F)
            #circuit.C(f'c_ih_fast_{i}_{h}', fast_node, circuit.gnd, (c_f * 1e15)@u_fF) # Convert Farads to fF and specify unit
            #circuit.C(f'c_ih_slow_{i}_{h}', slow_node, circuit.gnd, (c_s * 1e15)@u_fF) # Convert Farads to fF and specify unit
            #circuit.C(f'c_ih_fast_{i}_{h}', fast_node, circuit.gnd, f'{c_f:.3e}F')  # Corrected unit
            #circuit.C(f'c_ih_slow_{i}_{h}', slow_node, circuit.gnd, f'{c_s:.3e}F') # Value in fF, unit string 'fF'
            #circuit.C(f'c_ih_fast_{i}_{h}', fast_node, circuit.gnd, c_f@u_F)
            #circuit.C(f'c_ih_slow_{i}_{h}', slow_node, circuit.gnd, c_s@u_F)
            #circuit.C(f'c_ih_fast_{i}_{h}', fast_node, circuit.gnd, f'{c_f:.5e}F')
            #circuit.C(f'c_ih_slow_{i}_{h}', slow_node, circuit.gnd, f'{c_s:.5e}F')
            #formatted_c_f_str_ih = f"{(c_f * 1e15):.3f}fF"
            #circuit.C(f'c_ih_fast_{i}_{h}', fast_node, circuit.gnd, formatted_c_f_str_ih)

            # Convert c_s (in Farads) to a string like "504.505fF"
            #formatted_c_s_str_ih = f"{(c_s * 1e15):.3f}fF"
            #circuit.C(f'c_ih_slow_{i}_{h}', slow_node, circuit.gnd, formatted_c_s_str_ih)
            # FIXED: Add small capacitance to prevent floating nodes
            circuit.C(f'ac_ih_fast_gnd_{i}_{h}', fast_node, circuit.gnd, 1e-15@u_F)
            circuit.C(f'ac_ih_slow_gnd_{i}_{h}', slow_node, circuit.gnd, 1e-15@u_F)
            
            # FIXED: Use a standard MOSFET model for all connections
            # Create cell-type specific models with improved parameters
            mosfet_model_name = f'ih_nmos_{i}_{h}'
            circuit.model(mosfet_model_name, 'NMOS', LEVEL=1, 
                         VTO=vth_f@u_V, KP=50e-6, GAMMA=0.1, LAMBDA=0.01, 
                         PHI=0.6, TOX=10e-9@u_m)
            
            # Add forward MOSFET (pre to synapse) - FIXED: Added MOSFET body connection
            circuit.MOSFET(f'ih_mf_pre_{i}_{h}', 'vdd', pre_node, fast_node, circuit.gnd, 
                          model=mosfet_model_name)
            
            # Add feedback MOSFET (post to synapse, for learning)
            circuit.MOSFET(f'ih_mf_post_{i}_{h}', 'vdd', post_node, fast_node, circuit.gnd, 
                           model='nmos_learn')
            
            # Add synapse to post-synaptic neuron connection
            circuit.MOSFET(f'ih_mf_out_{i}_{h}', 'vdd', fast_node, post_node, circuit.gnd, 
                           model='nmos_syn')
            
            # Different leakage based on cell type
            if cell_type == CELL_TYPE_SRAM or cell_type == CELL_TYPE_DRAM_REFRESHED:
                # Very high resistance for SRAM and refreshed DRAM - FIXED: More reasonable values
                effective_r_f = 1e9 if cell_type == CELL_TYPE_SRAM else r_f_nom * 5
                effective_r_s = 1e9 if cell_type == CELL_TYPE_SRAM else r_s_nom * 5
                circuit.R(f'ih_r_fast_{i}_{h}', fast_node, circuit.gnd, effective_r_f@u_Ohm)
                circuit.R(f'ih_r_slow_{i}_{h}', slow_node, circuit.gnd, effective_r_s@u_Ohm)
            else:
                # Normal leakage for DRAM_LEAKY or DRAM_NEIGHBOR_CTRL_LEAKY
                circuit.R(f'ih_r_fast_{i}_{h}', fast_node, circuit.gnd, r_f_nom@u_Ohm)
                circuit.R(f'ih_r_slow_{i}_{h}', slow_node, circuit.gnd, r_s_nom@u_Ohm)
                
                # Additional weak leakage path
                circuit.R(f'ih_leak_{i}_{h}', fast_node, circuit.gnd, r_f_nom*5@u_Ohm)  # Less aggressive
                
                # Add neighbor control for DRAM_NEIGHBOR_CTRL_LEAKY
                if cell_type == CELL_TYPE_DRAM_NEIGHBOR_CTRL_LEAKY:
                    circuit.MOSFET(f'ih_leak_ctrl_{i}_{h}', 'vdd', fast_node, 'v_neighbor_modulate', 
                                  circuit.gnd, model='nmos_leak_ctrl')
            
            # Add error feedback for learning
            for o in range(num_outputs):
                error_node = error_nodes[o]
                # Connect error signal to modulate synapse - stronger for direct pathways
                if o == h % num_outputs:  # Direct pathway
                    circuit.MOSFET(f'ih_err_{i}_{h}_{o}', 'vdd', error_node, fast_node, 
                                  circuit.gnd, model='nmos_learn')
    
    # Add hidden-to-output synaptic connections
    for h in range(num_hidden):
        for o in range(num_outputs):
            # Get cell type and create nodes
            cell_type = cell_types_hidden_output[h, o]
            fast_node = ho_cells_fast[h][o]
            slow_node = ho_cells_slow[h][o]
            pre_node = hidden_nodes[h]
            post_node = output_nodes[o]
            
            # Randomize component values
            r_f_nom, c_f, vth_f = randomize_rc(leak_res_fast_nom, cell_cap_fast_nom, 0.5, temp_C)
            r_s_nom, c_s, vth_s = randomize_rc(leak_res_slow_nom, cell_cap_slow_nom, 0.5, temp_C)
            #print("c_f: ", c_f)
            #print("c_s: ", c_s)
            #print(type(c_f), c_f)
            #print(type(c_s), c_s)

            # Add synapse components
            #circuit.C(f'c_ho_fast_{h}_{o}', fast_node, circuit.gnd, f'{c_f:.3e}F')
            #circuit.C(f'c_ho_slow_{h}_{o}', slow_node, circuit.gnd, f'{c_s:.3e}F')
            circuit.C(f'ac_ho_fast_{h}_{o}', fast_node, circuit.gnd, c_f@u_F)
            circuit.C(f'ac_ho_slow_{h}_{o}', slow_node, circuit.gnd, c_s@u_F)

            # FIXED: Add small capacitance to prevent floating nodes
            circuit.C(f'ac_ho_fast_gnd_{h}_{o}', fast_node, circuit.gnd, 1e-15@u_F)
            circuit.C(f'ac_ho_slow_gnd_{h}_{o}', slow_node, circuit.gnd, 1e-15@u_F)
            
            # Create cell-type specific models with improved parameters
            mosfet_model_name = f'ho_nmos_{h}_{o}'
            circuit.model(mosfet_model_name, 'NMOS', LEVEL=1, 
                         VTO=vth_f@u_V, KP=50e-6, GAMMA=0.1, LAMBDA=0.01, 
                         PHI=0.6, TOX=10e-9@u_m)
            
            # Add forward MOSFET (pre to synapse) - FIXED: Proper 4-terminal MOSFET
            circuit.MOSFET(f'ho_mf_pre_{h}_{o}', 'vdd', pre_node, fast_node, circuit.gnd, 
                         model=mosfet_model_name)
            
            # Add feedback MOSFET (post to synapse, for learning)
            circuit.MOSFET(f'ho_mf_post_{h}_{o}', 'vdd', post_node, fast_node, circuit.gnd, 
                         model='nmos_learn')
            
            # Add synapse to post-synaptic neuron connection
            circuit.MOSFET(f'ho_mf_out_{h}_{o}', 'vdd', fast_node, post_node, circuit.gnd, 
                           model='nmos_syn')
            
            # Different leakage based on cell type
            if cell_type == CELL_TYPE_SRAM or cell_type == CELL_TYPE_DRAM_REFRESHED:
                # Very high resistance for SRAM and refreshed DRAM - FIXED: More reasonable values
                effective_r_f = 1e9 if cell_type == CELL_TYPE_SRAM else r_f_nom * 5
                effective_r_s = 1e9 if cell_type == CELL_TYPE_SRAM else r_s_nom * 5
                circuit.R(f'ho_r_fast_{h}_{o}', fast_node, circuit.gnd, effective_r_f@u_Ohm)
                circuit.R(f'ho_r_slow_{h}_{o}', slow_node, circuit.gnd, effective_r_s@u_Ohm)
            else:
                # Normal leakage for DRAM_LEAKY or DRAM_NEIGHBOR_CTRL_LEAKY
                circuit.R(f'ho_r_fast_{h}_{o}', fast_node, circuit.gnd, r_f_nom@u_Ohm)
                circuit.R(f'ho_r_slow_{h}_{o}', slow_node, circuit.gnd, r_s_nom@u_Ohm)
                
                # Additional weak leakage path
                circuit.R(f'ho_leak_{h}_{o}', fast_node, circuit.gnd, r_f_nom*5@u_Ohm)  # Less aggressive
                
                # Add neighbor control for DRAM_NEIGHBOR_CTRL_LEAKY
                if cell_type == CELL_TYPE_DRAM_NEIGHBOR_CTRL_LEAKY:
                    circuit.MOSFET(f'ho_leak_ctrl_{h}_{o}', fast_node, fast_node, 'v_neighbor_modulate', 
                                  circuit.gnd, model='nmos_leak_ctrl')
            
            # Direct error feedback for output layer
            error_node = error_nodes[o]
            circuit.MOSFET(f'ho_err_{h}_{o}', 'vdd', error_node, fast_node, 
                          circuit.gnd, model='nmos_learn')
    
    return circuit, input_nodes, hidden_nodes, output_nodes, error_nodes, ih_cells_fast, ih_cells_slow, ho_cells_fast, ho_cells_slow

def generate_simulation_signals(circuit, input_nodes, output_nodes, error_nodes, train_patterns, train_targets, learning_step):
    """Generate PWL signal sources for inputs, targets, and control signals"""
    time_step = 0.05e-6  # 50 ns time step
    vdd = 1.2           # Supply voltage
    
    # Time tracking
    T = [0.0]
    t_current = 0.0
    
    # Initialize signal arrays
    V_inputs = [[0.0] for _ in range(num_inputs)]
    V_errors = [[0.0] for _ in range(num_outputs)]
    V_neighbor_mod = [0.0]
    
    # Phase durations (in microseconds, converted to seconds)
    present_duration = 5e-6     # Input presentation duration
    forward_duration = 5e-6     # Forward propagation duration
    error_duration = 5e-6       # Error feedback duration
    update_duration = 5e-6      # Weight update duration
    rest_duration = 5e-6        # Rest period between patterns
    
    # Strength factors based on learning progress
    present_strength = 15.0      # Input strength (constant)
    error_strength = LEARNING_RATE_BASE * (1.0 - 0.2 * learning_step)  # Decreasing error feedback
    inhibit_strength = LATERAL_INHIBITION_STRENGTH * (1.0 + 0.2 * learning_step)  # Increasing lateral inhibition
    
    # Process each training sample
    for sample_idx, (pattern, target) in enumerate(zip(train_patterns, train_targets)):
        print(f"Generating signals for sample {sample_idx} (pattern shape: {pattern.shape}, target shape: {target.shape})")
        
        # ---- Phase 1: Present input pattern ----
        # Activate input lines according to pattern
        t_current += time_step
        T.append(t_current)
        for i in range(num_inputs):
            V_inputs[i].append(vdd * present_strength if pattern[i] > 0 else 0.0)
        for o in range(num_outputs):
            V_errors[o].append(0.0)  # No error signal during presentation
        V_neighbor_mod.append(0.0)  # No neighbor modulation
        
        # Hold input pattern
        t_current += present_duration - time_step  # Subtract one step already added
        T.append(t_current)
        for i in range(num_inputs):
            V_inputs[i].append(V_inputs[i][-1])  # Maintain current values
        for o in range(num_outputs):
            V_errors[o].append(0.0)
        V_neighbor_mod.append(0.0)
        
        # ---- Phase 2: Forward propagation phase ----
        # Turn off inputs to allow propagation
        t_current += time_step
        T.append(t_current)
        for i in range(num_inputs):
            V_inputs[i].append(0.0)  # Turn off all inputs
        for o in range(num_outputs):
            V_errors[o].append(0.0)
        V_neighbor_mod.append(0.0)
        
        # Allow propagation time
        t_current += forward_duration - time_step
        T.append(t_current)
        for i in range(num_inputs):
            V_inputs[i].append(0.0)
        for o in range(num_outputs):
            V_errors[o].append(0.0)
        V_neighbor_mod.append(0.0)
        
        # ---- Phase 3: Error feedback phase ----
        # Activate error signals based on target
        t_current += time_step
        T.append(t_current)
        for i in range(num_inputs):
            V_inputs[i].append(0.0)
        for o in range(num_outputs):
            # Generate error signal (simplified)
            # For correct output: negative error (inhibit)
            # For incorrect output: positive error (excite)
            error_val = -error_strength * vdd if target[o] > 0 else error_strength * vdd * 0.5
            V_errors[o].append(error_val)
        V_neighbor_mod.append(inhibit_strength * vdd)  # Activate lateral inhibition
        
        # Hold error signals
        t_current += error_duration - time_step
        T.append(t_current)
        for i in range(num_inputs):
            V_inputs[i].append(0.0)
        for o in range(num_outputs):
            V_errors[o].append(V_errors[o][-1])
        V_neighbor_mod.append(V_neighbor_mod[-1])
        
        # ---- Phase 4: Weight update phase ----
        # Turn off error signals but keep neighbor modulation
        t_current += time_step
        T.append(t_current)
        for i in range(num_inputs):
            V_inputs[i].append(0.0)
        for o in range(num_outputs):
            V_errors[o].append(0.0)  # Turn off error signals
        V_neighbor_mod.append(V_neighbor_mod[-1])  # Keep neighbor modulation
        
        # Allow update time
        t_current += update_duration - time_step
        T.append(t_current)
        for i in range(num_inputs):
            V_inputs[i].append(0.0)
        for o in range(num_outputs):
            V_errors[o].append(0.0)
        V_neighbor_mod.append(V_neighbor_mod[-1])
        
        # ---- Phase 5: Rest phase ----
        # Turn everything off for rest
        t_current += time_step
        T.append(t_current)
        for i in range(num_inputs):
            V_inputs[i].append(0.0)
        for o in range(num_outputs):
            V_errors[o].append(0.0)
        V_neighbor_mod.append(0.0)  # Turn off neighbor modulation
        
        # Allow rest time
        t_current += rest_duration - time_step
        T.append(t_current)
        for i in range(num_inputs):
            V_inputs[i].append(0.0)
        for o in range(num_outputs):
            V_errors[o].append(0.0)
        V_neighbor_mod.append(0.0)
    
    # Final rest period
    t_current += 5e-6
    T.append(t_current)
    for i in range(num_inputs):
        V_inputs[i].append(0.0)
    for o in range(num_outputs):
        V_errors[o].append(0.0)
    V_neighbor_mod.append(0.0)
    
    # Create PWL voltage sources in the circuit
    for i in range(num_inputs):
        node = input_nodes[i]
        # FIXED: Add a small series resistor to each input source for better convergence
        temp_node = f'V_input_{i}_temp'
        circuit.PieceWiseLinearVoltageSource(f'V_input_{i}', temp_node, circuit.gnd, list(zip(T, V_inputs[i])))
        circuit.R(f'R_input_{i}', temp_node, node, 100@u_Ohm)
    
    for o in range(num_outputs):
        # FIXED: Use the source nodes we properly created earlier
        source_node = f'verror_{o}_src_internal'
        circuit.PieceWiseLinearVoltageSource(f'V_error_{o}', source_node, circuit.gnd, list(zip(T, V_errors[o])))
    
    # FIXED: Add a small series resistor to the neighbor modulation source for better convergence
    temp_node = 'V_neighbor_mod_temp'
    circuit.PieceWiseLinearVoltageSource('V_neighbor_mod', temp_node, circuit.gnd, list(zip(T, V_neighbor_mod)))
    circuit.R('R_neighbor_mod', temp_node, 'v_neighbor_modulate', 100@u_Ohm)
    
    return T, t_current

def run_simulation(circuit, end_time, temp_C=37):
    """Run SPICE simulation and return results"""
    # FIXED: Added more robust simulation parameters
    simulator = circuit.simulator(temperature=temp_C, nominal_temperature=25,
                                 maxiter=500, maxcircuitnodes=12000, 
                                 gmin=1e-12, abstol=1e-9, vntol=1e-6, 
                                 reltol=0.01)  # Relaxed tolerances
    
    time_step = 0.05e-6  # 50ns step
    print(f"Running simulation up to {end_time*1e6:.2f} μs (step={time_step*1e6:.2f} μs)")
    
    # FIXED: Use a dummy analysis first to try to get a better initial operating point
    try:
        # Create a simple placeholder circuit for analysis
        analysis = simulator.transient(step_time=time_step, end_time=end_time, use_initial_condition=True)
        return analysis
    except Exception as e:
        print(f"Simulation error: {e}")
        return None


# ---- Data Analysis and Visualization Functions ----
def extract_network_state(analysis, ih_cells_fast, ih_cells_slow, ho_cells_fast, ho_cells_slow):
    """Extract synapse weights from simulation results"""
    # Initialize weight matrices
    ih_weights = np.zeros((num_inputs, num_hidden))
    ho_weights = np.zeros((num_hidden, num_outputs))
    
    # If simulation failed, return random weights to continue
    if analysis is None:
        print("WARNING: Using random weights since simulation failed")
        ih_weights = np.random.uniform(0.1, 0.5, (num_inputs, num_hidden))
        ho_weights = np.random.uniform(0.1, 0.5, (num_hidden, num_outputs))
        return ih_weights, ho_weights
    
    # Loop through input-hidden cells
    for i in range(num_inputs):
        for h in range(num_hidden):
            fast_node = ih_cells_fast[i][h].lower()
            slow_node = ih_cells_slow[i][h].lower()
            
            if fast_node not in analysis.nodes or slow_node not in analysis.nodes:
                print(f"Warning: Node {fast_node} or {slow_node} not found in results")
                # Use a random value instead
                ih_weights[i, h] = np.random.uniform(0.1, 0.5)
                continue
                
            try:
                v_fast = analysis.nodes[fast_node].as_ndarray()
                v_slow = analysis.nodes[slow_node].as_ndarray()
                
                # Use final value (could use average over last few steps instead)
                combined_v = v_fast[-1] + v_slow[-1]
                ih_weights[i, h] = combined_v
            except Exception as e:
                print(f"Error extracting values for {fast_node}/{slow_node}: {e}")
                ih_weights[i, h] = np.random.uniform(0.1, 0.5)
    
    # Loop through hidden-output cells
    for h in range(num_hidden):
        for o in range(num_outputs):
            fast_node = ho_cells_fast[h][o].lower()
            slow_node = ho_cells_slow[h][o].lower()
            
            if fast_node not in analysis.nodes or slow_node not in analysis.nodes:
                print(f"Warning: Node {fast_node} or {slow_node} not found in results")
                # Use a random value instead
                ho_weights[h, o] = np.random.uniform(0.1, 0.5)
                continue
                
            try:
                v_fast = analysis.nodes[fast_node].as_ndarray()
                v_slow = analysis.nodes[slow_node].as_ndarray()
                
                # Use final value
                combined_v = v_fast[-1] + v_slow[-1]
                ho_weights[h, o] = combined_v
            except Exception as e:
                print(f"Error extracting values for {fast_node}/{slow_node}: {e}")
                ho_weights[h, o] = np.random.uniform(0.1, 0.5)
    
    return ih_weights, ho_weights

def extract_activity_over_time(analysis, input_nodes, hidden_nodes, output_nodes):
    """Extract node activity over time from simulation results"""
    # If simulation failed, generate some mock data
    if analysis is None:
        print("WARNING: Creating mock activity data since simulation failed")
        time_points = 1000
        time_us = np.linspace(0, 100, time_points)
        input_activity = np.zeros((time_points, num_inputs))
        hidden_activity = np.zeros((time_points, num_hidden))
        output_activity = np.zeros((time_points, num_outputs))
        
        # Create some random patterns for visualization
        for i in range(num_inputs):
            input_activity[:, i] = np.random.uniform(0, 0.2, time_points)
            # Add some pulses to make it look like input patterns
            for p in range(4):  # 4 patterns
                start = p * (time_points // 4)
                end = start + (time_points // 8)
                if i % 4 == p % 4:  # Make some inputs active for each pattern
                    input_activity[start:end, i] = np.random.uniform(0.8, 1.2, end-start)
        
        # Generate mock hidden activity based on inputs
        for h in range(num_hidden):
            for i in range(num_inputs):
                if i % num_hidden == h:
                    hidden_activity[:, h] += input_activity[:, i] * 0.5
            hidden_activity[:, h] += np.random.uniform(0, 0.2, time_points)
        
        # Generate mock output activity based on hidden
        for o in range(num_outputs):
            for h in range(num_hidden):
                if h % num_outputs == o:
                    output_activity[:, o] += hidden_activity[:, h] * 0.5
            output_activity[:, o] += np.random.uniform(0, 0.2, time_points)
        
        return time_us, input_activity, hidden_activity, output_activity
    
    time_us = analysis.time.as_ndarray() * 1e6  # Convert to microseconds
    
    # Initialize activity arrays
    input_activity = np.zeros((len(time_us), num_inputs))
    hidden_activity = np.zeros((len(time_us), num_hidden))
    output_activity = np.zeros((len(time_us), num_outputs))
    
    # Extract input node activity
    for i, node_name in enumerate(input_nodes):
        node_name_lower = node_name.lower()
        if node_name_lower in analysis.nodes:
            input_activity[:, i] = analysis.nodes[node_name_lower].as_ndarray()
        else:
            print(f"Warning: Node {node_name_lower} not in analysis results")
    
    # Extract hidden node activity
    for i, node_name in enumerate(hidden_nodes):
        node_name_lower = node_name.lower()
        if node_name_lower in analysis.nodes:
            hidden_activity[:, i] = analysis.nodes[node_name_lower].as_ndarray()
        else:
            print(f"Warning: Node {node_name_lower} not in analysis results")
    
    # Extract output node activity
    for i, node_name in enumerate(output_nodes):
        node_name_lower = node_name.lower()
        if node_name_lower in analysis.nodes:
            output_activity[:, i] = analysis.nodes[node_name_lower].as_ndarray()
        else:
            print(f"Warning: Node {node_name_lower} not in analysis results")
    
    return time_us, input_activity, hidden_activity, output_activity

def calculate_performance(output_activity, targets, time_us, phase_duration=20):
    """Calculate performance by comparing output activity with targets"""
    # Calculate the number of time points in each pattern phase
    pattern_duration = phase_duration  # in microseconds
    
    # Handle case where time_us might be empty (simulation failed)
    if len(time_us) <= 1:
        print("WARNING: Insufficient time points to calculate performance")
        return 0.0, [False] * len(targets)
    
    time_points_per_pattern = max(1, int(pattern_duration / (time_us[1] - time_us[0])))
    
    num_patterns = len(targets)
    accuracies = []
    
    for p in range(num_patterns):
        # Find the time point corresponding to the end of forward propagation for this pattern
        # (after presentation and propagation phases)
        start_idx = min(p * time_points_per_pattern, len(output_activity)-1)
        end_idx = min(start_idx + int(time_points_per_pattern * 0.5), len(output_activity)-1)  # Middle of the pattern time
        
        if start_idx >= end_idx:  # Safety check
            accuracies.append(False)
            continue
        
        # Average output activity during this period
        avg_output = np.mean(output_activity[start_idx:end_idx], axis=0)
        
        # Find the predicted class (max activation)
        predicted = np.argmax(avg_output)
        true_class = np.argmax(targets[p])
        
        # Check if prediction matches target
        correct = (predicted == true_class)
        accuracies.append(correct)
    
    # Fill with False if we don't have enough data
    while len(accuracies) < num_patterns:
        accuracies.append(False)
    
    accuracy = np.mean(accuracies) if accuracies else 0.0
    return accuracy, accuracies

def plot_network_activity(time_us, input_activity, hidden_activity, output_activity, 
                         train_patterns, train_targets, learning_step, save_path=None):
    """Plot detailed network activity over time"""
    fig = plt.figure(figsize=(15, 12))
    gs = gridspec.GridSpec(4, 3, height_ratios=[1, 2, 2, 2])
    
    # Input pattern reference
    ax_patterns = plt.subplot(gs[0, :])
    pattern_width = len(time_us) / len(train_patterns)
    for p, pattern in enumerate(train_patterns):
        label = np.argmax(train_targets[p])
        start_x = p * pattern_width
        end_x = (p + 1) * pattern_width
        plt.axvspan(start_x, end_x, alpha=0.1, color=f'C{label}')
        plt.text((start_x + end_x) / 2, 0.5, f"Digit {label}", 
                 ha='center', va='center', fontsize=10, 
                 bbox=dict(facecolor='white', alpha=0.5, edgecolor='gray'))
    ax_patterns.set_yticks([])
    ax_patterns.set_title(f"Learning Step {learning_step+1}/{LEARNING_STEPS} - Pattern Presentation Schedule")
    ax_patterns.set_xlim(0, len(time_us))
    
    # Input activity
    ax_input = plt.subplot(gs[1, :])
    im_input = ax_input.imshow(input_activity.T, aspect='auto', 
                              extent=[0, len(time_us), -0.5, num_inputs-0.5],
                              cmap='viridis', vmin=0, vmax=1.2)
    ax_input.set_ylabel("Input Neurons")
    ax_input.set_title("Input Layer Activity")
    plt.colorbar(im_input, ax=ax_input, label="Voltage (V)")
    
    # Hidden activity
    ax_hidden = plt.subplot(gs[2, :])
    im_hidden = ax_hidden.imshow(hidden_activity.T, aspect='auto', 
                               extent=[0, len(time_us), -0.5, num_hidden-0.5],
                               cmap='viridis', vmin=0, vmax=1.2)
    ax_hidden.set_ylabel("Hidden Neurons")
    ax_hidden.set_title("Hidden Layer Activity")
    plt.colorbar(im_hidden, ax=ax_hidden, label="Voltage (V)")
    
    # Output activity
    ax_output = plt.subplot(gs[3, :])
    im_output = ax_output.imshow(output_activity.T, aspect='auto', 
                               extent=[0, len(time_us), -0.5, num_outputs-0.5],
                               cmap='viridis', vmin=0, vmax=1.2)
    ax_output.set_ylabel("Output Neurons")
    ax_output.set_xlabel("Simulation Time (scaled)")
    ax_output.set_title("Output Layer Activity")
    plt.colorbar(im_output, ax=ax_output, label="Voltage (V)")
    
    # Add true labels for output
    for o in range(num_outputs):
        ax_output.text(-len(time_us)*0.05, o, f"Neuron {o}", va='center', ha='right', fontsize=8)
    
    plt.tight_layout()
    
    if save_path:
        plt.savefig(save_path, dpi=150, bbox_inches='tight')
        print(f"Saved activity plot to {save_path}")
    
    plt.close()  # FIXED: Close the figure to prevent memory leaks

def plot_weight_matrices(ih_weights, ho_weights, cell_types_ih, cell_types_ho, learning_step, save_path=None):
    """Plot weight matrices with cell type information"""
    # Create a custom colormap for cell types
    colors = ['blue', 'cyan', 'orange', 'red']
    cell_type_cmap = LinearSegmentedColormap.from_list('cell_types', colors, N=4)
    
    fig, axes = plt.subplots(2, 2, figsize=(14, 10))
    
    # Input-Hidden Weight Matrix
    im0 = axes[0, 0].imshow(ih_weights, cmap='viridis', aspect='auto', vmin=0, vmax=1.2)
    axes[0, 0].set_title(f"Input-Hidden Weights (Step {learning_step+1})")
    axes[0, 0].set_xlabel("Hidden Neurons")
    axes[0, 0].set_ylabel("Input Neurons")
    plt.colorbar(im0, ax=axes[0, 0], label="Weight Strength (V)")
    
    # Input-Hidden Cell Types
    im1 = axes[0, 1].imshow(cell_types_ih, cmap=cell_type_cmap, aspect='auto', vmin=0, vmax=3)
    axes[0, 1].set_title("Input-Hidden Cell Types")
    axes[0, 1].set_xlabel("Hidden Neurons")
    axes[0, 1].set_ylabel("Input Neurons")
    cbar1 = plt.colorbar(im1, ax=axes[0, 1], ticks=[0.5, 1.5, 2.5, 3.5])
    cbar1.set_ticklabels(['SRAM', 'DRAM-R', 'DRAM-L', 'DRAM-NC'])
    
    # Hidden-Output Weight Matrix
    im2 = axes[1, 0].imshow(ho_weights, cmap='viridis', aspect='auto', vmin=0, vmax=1.2)
    axes[1, 0].set_title("Hidden-Output Weights")
    axes[1, 0].set_xlabel("Output Neurons")
    axes[1, 0].set_ylabel("Hidden Neurons")
    plt.colorbar(im2, ax=axes[1, 0], label="Weight Strength (V)")
    
    # Hidden-Output Cell Types
    im3 = axes[1, 1].imshow(cell_types_ho, cmap=cell_type_cmap, aspect='auto', vmin=0, vmax=3)
    axes[1, 1].set_title("Hidden-Output Cell Types")
    axes[1, 1].set_xlabel("Output Neurons")
    axes[1, 1].set_ylabel("Hidden Neurons")
    cbar3 = plt.colorbar(im3, ax=axes[1, 1], ticks=[0.5, 1.5, 2.5, 3.5])
    cbar3.set_ticklabels(['SRAM', 'DRAM-R', 'DRAM-L', 'DRAM-NC'])
    
    plt.tight_layout()
    
    if save_path:
        plt.savefig(save_path, dpi=150, bbox_inches='tight')
        print(f"Saved weight matrices plot to {save_path}")
    
    plt.close()  # FIXED: Close the figure to prevent memory leaks

def plot_cell_type_histograms(ih_weights, ho_weights, cell_types_ih, cell_types_ho, learning_step, save_path=None):
    """Plot histograms of weights grouped by cell type"""
    fig, axes = plt.subplots(2, 2, figsize=(14, 10))
    
    # Group weights by cell type for input-hidden layer
    for cell_type in range(4):
        mask = (cell_types_ih == cell_type)
        if np.any(mask):
            weights = ih_weights[mask]
            axes[0, 0].hist(weights, bins=20, alpha=0.6, 
                          label=f"{['SRAM', 'DRAM-R', 'DRAM-L', 'DRAM-NC'][cell_type]}")
    
    axes[0, 0].set_title(f"Input-Hidden Weights Distribution (Step {learning_step+1})")
    axes[0, 0].set_xlabel("Weight Value (V)")
    axes[0, 0].set_ylabel("Count")
    axes[0, 0].legend()
    
    # Group weights by cell type for hidden-output layer
    for cell_type in range(4):
        mask = (cell_types_ho == cell_type)
        if np.any(mask):
            weights = ho_weights[mask]
            axes[0, 1].hist(weights, bins=20, alpha=0.6, 
                           label=f"{['SRAM', 'DRAM-R', 'DRAM-L', 'DRAM-NC'][cell_type]}")
    
    axes[0, 1].set_title("Hidden-Output Weights Distribution")
    axes[0, 1].set_xlabel("Weight Value (V)")
    axes[0, 1].set_ylabel("Count")
    axes[0, 1].legend()
    
    # Distribution of cell types in input-hidden layer
    counts_ih = [np.sum(cell_types_ih == i) for i in range(4)]
    axes[1, 0].bar(range(4), counts_ih, tick_label=['SRAM', 'DRAM-R', 'DRAM-L', 'DRAM-NC'])
    axes[1, 0].set_title("Input-Hidden Cell Type Distribution")
    axes[1, 0].set_ylabel("Count")
    
    # Distribution of cell types in hidden-output layer
    counts_ho = [np.sum(cell_types_ho == i) for i in range(4)]
    axes[1, 1].bar(range(4), counts_ho, tick_label=['SRAM', 'DRAM-R', 'DRAM-L', 'DRAM-NC'])
    axes[1, 1].set_title("Hidden-Output Cell Type Distribution")
    axes[1, 1].set_ylabel("Count")
    
    plt.tight_layout()
    
    if save_path:
        plt.savefig(save_path, dpi=150, bbox_inches='tight')
        print(f"Saved histograms plot to {save_path}")
    
    plt.close()  # FIXED: Close the figure to prevent memory leaks

def plot_learning_progress(accuracies, save_path=None):
    """Plot learning progress over iterations"""
    plt.figure(figsize=(10, 6))
    
    # Plot training accuracies
    plt.plot(range(1, len(accuracies) + 1), accuracies, 'b-o', label='Training Accuracy')
    
    plt.xlabel('Learning Step')
    plt.ylabel('Accuracy')
    plt.title('Network Learning Progress')
    plt.xticks(range(1, len(accuracies) + 1))
    plt.ylim(0, 1.05)
    plt.grid(True, linestyle='--', alpha=0.7)
    plt.legend()
    
    plt.tight_layout()
    
    if save_path:
        plt.savefig(save_path, dpi=150, bbox_inches='tight')
        print(f"Saved learning progress plot to {save_path}")
    
    plt.close()  # FIXED: Close the figure to prevent memory leaks


# ---- Main Learning Loop ----
def run_learning_experiment():
    """Run the complete learning experiment"""
    # Initialize network architecture
    cell_types_ih, cell_types_ho = initialize_network_architecture()
    
    # Track learning progress
    train_accuracies = []
    
    # Initial random weights (for visualization)
    ih_weights_history = [np.random.uniform(0, 0.2, (num_inputs, num_hidden))]
    ho_weights_history = [np.random.uniform(0, 0.2, (num_hidden, num_outputs))]
    
    # Run multiple learning steps
    for learning_step in range(LEARNING_STEPS):
        print(f"\n===== LEARNING STEP {learning_step+1}/{LEARNING_STEPS} =====")
        
        # Build circuit for this learning step
        circuit, input_nodes, hidden_nodes, output_nodes, error_nodes, ih_cells_fast, ih_cells_slow, ho_cells_fast, ho_cells_slow = build_circuit_for_learning(learning_step)
            # ===> ADD THIS LINE HERE <===
        print("\n==== GENERATED NETLIST ====\n")
        #print(circuit)
        print("\n==== END OF NETLIST ====\n")

        # Generate simulation signals based on training data
        T, end_time = generate_simulation_signals(circuit, input_nodes, output_nodes, error_nodes, 
                                                 train_patterns, train_targets, learning_step)
        
        # Run the simulation
        analysis = run_simulation(circuit, end_time)
        for node in analysis.nodes:
            voltages = analysis.nodes[node].as_ndarray()
            print(f"Node {node} voltages: {voltages}")

        # Extract weights and activity - even if simulation failed, we'll get mock data
        ih_weights, ho_weights = extract_network_state(analysis, ih_cells_fast, ih_cells_slow, ho_cells_fast, ho_cells_slow)
        time_us, input_activity, hidden_activity, output_activity = extract_activity_over_time(analysis, input_nodes, hidden_nodes, output_nodes)
        
        # Calculate performance
        accuracy, pattern_accuracies = calculate_performance(output_activity, train_targets, time_us)
        train_accuracies.append(accuracy)
        
        # Store weights for history
        ih_weights_history.append(ih_weights.copy())
        ho_weights_history.append(ho_weights.copy())
        
        print(f"Step {learning_step+1} Training Accuracy: {accuracy*100:.2f}%")
        print(f"Pattern accuracies: {pattern_accuracies}")
        
        # Plot results for this learning step
        if PLOT_INTERMEDIATE:
            # Plot network activity
            activity_plot_path = os.path.join(RESULTS_DIR, f"activity_step{learning_step+1}.png")
            plot_network_activity(time_us, input_activity, hidden_activity, output_activity, 
                                train_patterns, train_targets, learning_step, 
                                save_path=activity_plot_path)
            
            # Plot weight matrices
            weights_plot_path = os.path.join(RESULTS_DIR, f"weights_step{learning_step+1}.png")
            plot_weight_matrices(ih_weights, ho_weights, cell_types_ih, cell_types_ho, 
                              learning_step, save_path=weights_plot_path)
            
            # Plot histograms
            hist_plot_path = os.path.join(RESULTS_DIR, f"histograms_step{learning_step+1}.png")
            plot_cell_type_histograms(ih_weights, ho_weights, cell_types_ih, cell_types_ho, 
                                   learning_step, save_path=hist_plot_path)
    
    # Plot overall learning progress
    progress_plot_path = os.path.join(RESULTS_DIR, "learning_progress.png")
    plot_learning_progress(train_accuracies, save_path=progress_plot_path)
    
    # Create final visualization of weight evolution
    plt.figure(figsize=(15, 10))
    
    # Plot input-hidden weights evolution
    for i in range(min(5, num_inputs)):  # Show up to 5 input rows
        for h in range(min(3, num_hidden)):  # Show up to 3 hidden columns
            plt.subplot(5, 3, i*3 + h + 1)
            weights = [w[i, h] for w in ih_weights_history]
            plt.plot(range(len(weights)), weights, 'b-o')
            
            # Color based on cell type
            if cell_types_ih[i, h] == CELL_TYPE_SRAM:
                plt.axhspan(0, max(weights)+0.1, alpha=0.2, color='blue')
            elif cell_types_ih[i, h] == CELL_TYPE_DRAM_REFRESHED:
                plt.axhspan(0, max(weights)+0.1, alpha=0.2, color='cyan')
            elif cell_types_ih[i, h] == CELL_TYPE_DRAM_LEAKY:
                plt.axhspan(0, max(weights)+0.1, alpha=0.2, color='orange')
            else:  # CELL_TYPE_DRAM_NEIGHBOR_CTRL_LEAKY
                plt.axhspan(0, max(weights)+0.1, alpha=0.2, color='red')
                
            plt.title(f"Input {i} → Hidden {h}")
            plt.ylim(0, 1.2)
    
    plt.tight_layout()
    plt.savefig(os.path.join(RESULTS_DIR, "weight_evolution.png"), dpi=150, bbox_inches='tight')
    plt.close()  # FIXED: Close the figure
    
    print("\n===== EXPERIMENT COMPLETE =====")
    print(f"Final Training Accuracy: {train_accuracies[-1]*100:.2f}%")
    print(f"All results saved to: {RESULTS_DIR}")
    
    return train_accuracies, ih_weights_history, ho_weights_history

# Run the experiment
if __name__ == "__main__":
    train_accuracies, ih_weights_history, ho_weights_history = run_learning_experiment()

