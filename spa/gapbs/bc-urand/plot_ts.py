import pandas as pd
import numpy as np
import matplotlib.pyplot as plt
import joblib
from scipy.interpolate import interp1d
from sklearn.metrics import r2_score
from scipy.optimize import curve_fit

# Config
LOCAL_CSV = 'results_ts/local.csv'
REMOTE_CSV = 'results_ts/remote.csv'
OUTPUT_PLOT = 'prediction_plot.png'
MODEL_PATH = 'model.joblib'
L_LOC = 94.8  # ns
L_REM = 192.0 # ns
DELTA_L = L_REM - L_LOC
N_BINS = 1000 # Number of instruction bins for resampling

# Load Data
def load_perf_csv(filepath):
    data = []
    with open(filepath, 'r') as f:
        for line in f:
            if line.startswith('#') or not line.strip():
                continue
            parts = line.split(',')
            if len(parts) < 4:
                continue
            try:
                ts = float(parts[0])
                val = float(parts[1])
                event = parts[3].strip()
                data.append({'timestamp': ts, 'value': val, 'event': event})
            except ValueError:
                continue
    
    df = pd.DataFrame(data)
    df_pivot = df.pivot_table(index='timestamp', columns='event', values='value', aggfunc='first')
    df_pivot = df_pivot.sort_index()
    return df_pivot

print("Loading data...")
local_df = load_perf_csv(LOCAL_CSV)
remote_df = load_perf_csv(REMOTE_CSV)

# --- Data Rescaling Fix ---
# Check for massive instruction count discrepancy (e.g. perf -I missing threads in Local run)
# We sum up the 'instructions' column to verify totals.
# Note: perf -I outputs deltas, so simple sum is correct.
total_local_instr = local_df['instructions'].sum()
total_remote_instr = remote_df['instructions'].sum()

print(f"Total Local Instr: {total_local_instr:.0f}")
print(f"Total Remote Instr: {total_remote_instr:.0f}")

if total_local_instr > 0 and total_remote_instr > 0:
    ratio = total_remote_instr / total_local_instr
    if ratio > 2.0:
        print(f"WARNING: Huge instruction discrepancy detected (Ratio: {ratio:.2f}).")
        print(f"Assuming Local run under-counted (e.g. perf missing threads). Scaling Local data...")
        
        # Scale all numeric columns except timestamp
        # metrics are all columns except 'timestamp' (which is index in df_pivot? No, load_perf_csv sets index to timestamp)
        # In load_perf_csv, df_pivot index is timestamp.
        
        for col in local_df.columns:
             local_df[col] = local_df[col] * ratio
             
        print("Local data scaled.")

# Filter out incomplete rows (start/end noise)
local_df = local_df.dropna()
remote_df = remote_df.dropna()

# Helper to calculate cumulative metrics
def process_cumulative(df):
    # We need cumulative sums for all counters to interpolate correctly
    # perf stat -I reports deltas.
    # FillNA with 0 for safety
    df = df.fillna(0)
    cum_df = df.cumsum()
    
    # Time is the index. We need cumulative time (seconds)
    # The index is already timestamp (cumulative time since start)
    cum_df['timestamp'] = df.index
    
    # Explicitly store cumulative instructions for alignment
    cum_df['cumulative_instructions'] = cum_df['instructions']
    return cum_df

local_cum = process_cumulative(local_df)
remote_cum = process_cumulative(remote_df)

print(f"Local samples: {len(local_df)}, Remote samples: {len(remote_df)}")

# --- Instruction-based Binning (Resampling) ---
print(f"Resampling data into {N_BINS} instruction bins...")

# Determine common instruction range
min_instr = 0
max_instr = min(local_cum['cumulative_instructions'].iloc[-1], remote_cum['cumulative_instructions'].iloc[-1])

# Create equidistant instruction checkpoints
# We start from a small offset to avoid 0
checkpoints = np.linspace(min_instr, max_instr, N_BINS + 1)

# Function to resample a dataframe based on cumulative instructions
def resample_dataset(cum_df, target_instr_points):
    # Source x: cumulative instructions
    src_x = np.concatenate(([0], cum_df['cumulative_instructions'].values))
    
    # Source y: all columns. We need to interpolate each column.
    # We'll create a dict of interpolation functions
    interp_funcs = {}
    for col in cum_df.columns:
        src_y = np.concatenate(([0], cum_df[col].values))
        # interp1d is fast. 
        interp_funcs[col] = interp1d(src_x, src_y, kind='linear', fill_value='extrapolate')
        
    # Generate new data
    new_data = {}
    for col, func in interp_funcs.items():
        new_data[col] = func(target_instr_points)
        
    resampled_df = pd.DataFrame(new_data)
    
    # Now we have cumulative values at checkpoints.
    # We need INTERVAL values (Delta) for the bins.
    # Diff between row i and row i-1
    interval_df = resampled_df.diff().iloc[1:].copy()
    
    # Reset index to be clean 0..N-1
    interval_df = interval_df.reset_index(drop=True)
    
    # Recalculate 'interval_seconds' from the timestamp diff
    # timestamp col in cum_df was actually cumulative time
    interval_df['interval_seconds'] = interval_df['timestamp']
    
    return interval_df

local_binned = resample_dataset(local_cum, checkpoints)
remote_binned = resample_dataset(remote_cum, checkpoints)

# --- Calculate Metrics on Bins ---

# 1. Actual Slowdown
# Since bins represent EQUAL amount of work (Instructions),
# Slowdown = (Time_Remote - Time_Local) / Time_Local
# Note: Time_Local should NOT be zero unless empty bin.
# With bins, T_local is averaged over a large chunk, so it's stable.

# Avoid div by zero
mask = local_binned['interval_seconds'] > 1e-9
local_binned = local_binned[mask]
remote_binned = remote_binned[mask]

remote_binned['Actual_Slowdown'] = (remote_binned['interval_seconds'] - local_binned['interval_seconds']) / local_binned['interval_seconds']
# Also bring over Local Time for Heuristic
remote_binned['Local_Interval_Time'] = local_binned['interval_seconds']

# --- Features & Models ---
# Now remote_binned has interval metrics (deltas) for each bin.
# We can calculate rates (per cycle, per instr) directly.

df_analysis = remote_binned.copy()

# Features
df_analysis['P'] = df_analysis['CYCLE_ACTIVITY.STALLS_L3_MISS'] / df_analysis['cycles']
# Protect against div by zero in AOL
df_analysis['AOL'] = df_analysis['OFFCORE_REQUESTS_OUTSTANDING.CYCLES_WITH_DEMAND_DATA_RD'] / \
                     df_analysis['OFFCORE_REQUESTS.DEMAND_DATA_RD'].replace(0, np.nan)

# --- Fix Timestamp for X-Axis ---
# Cumulative sum of intervals gives the absolute time axis
df_analysis['timestamp'] = df_analysis['interval_seconds'].cumsum()

# --- AOL Model Fitting ---
fit_data = df_analysis.dropna(subset=['P', 'AOL', 'Actual_Slowdown'])
# Filter reasonable range for fitting
fit_data = fit_data[(fit_data['AOL'] > 0) & (fit_data['Actual_Slowdown'] > -0.5)]
fit_data['K_target'] = fit_data['Actual_Slowdown'] / fit_data['P']

def func_k(aol, a, b):
    return 1.0 / (a + b / aol)

# User provided fixed AOL parameters
a_fit = 0.317760
b_fit = 7.329282
print(f"Using User-Provided AOL Fit: a={a_fit:.4f}, b={b_fit:.4f}")

# try:
#     popt, pcov = curve_fit(func_k, fit_data['AOL'], fit_data['K_target'], p0=[1.0, 10.0], bounds=(0, [np.inf, np.inf]))
#     a_fit, b_fit = popt
#     print(f"AOL Fit: a={a_fit:.4f}, b={b_fit:.4f}")
# except Exception as e:
#     print(f"Fitting failed: {e}, utilizing default")
#     a_fit, b_fit = 1.0, 10.0 # Default fallback

df_analysis['K_pred'] = func_k(df_analysis['AOL'], a_fit, b_fit)
df_analysis['AOL_Pred'] = df_analysis['P'] * df_analysis['K_pred']

# --- ML Model (Pre-trained) ---
# Features match model expectation
X_ml = pd.DataFrame({
    'CYCLE_ACTIVITY.STALLS_L3_MISS_per_cycle': df_analysis['CYCLE_ACTIVITY.STALLS_L3_MISS'] / df_analysis['cycles'],
    'EXE_ACTIVITY.2_PORTS_UTIL_per_instr': df_analysis['EXE_ACTIVITY.2_PORTS_UTIL'] / df_analysis['instructions'],
    'OFFCORE_REQUESTS.DEMAND_DATA_RD_per_cycle': df_analysis['OFFCORE_REQUESTS.DEMAND_DATA_RD'] / df_analysis['cycles']
})
# Handle NaNs
X_ml = X_ml.fillna(0)

print(f"Loading model from {MODEL_PATH}...")
try:
    loaded_data = joblib.load(MODEL_PATH)
    if isinstance(loaded_data, dict):
        ml_model = loaded_data['model']
    else:
        ml_model = loaded_data

    df_analysis['ML_Pred'] = ml_model.predict(X_ml)
    r2_val = r2_score(df_analysis['Actual_Slowdown'], df_analysis['ML_Pred'])
    print(f"Loaded Model R2 (on Binned Data): {r2_val:.4f}")
except Exception as e:
    print(f"Error loading/predicting with model: {e}")
    import traceback
    traceback.print_exc()
    df_analysis['ML_Pred'] = np.nan

# --- Heuristic Model ---
# Calculate Global Alpha Min
local_total_stalls = local_cum['CYCLE_ACTIVITY.STALLS_L3_MISS'].iloc[-1]
local_total_cycles = local_cum['cycles'].iloc[-1]
local_total_misses = local_cum['OFFCORE_REQUESTS.DEMAND_DATA_RD'].iloc[-1]
local_total_time_ns = local_cum['timestamp'].iloc[-1] * 1e9

alpha_naive = local_total_stalls / local_total_cycles
freq = local_total_cycles / (local_total_time_ns / 1e9)
stall_time_ns_calc = (local_total_stalls / freq) * 1e9
mlp_avg = (local_total_misses * L_LOC) / stall_time_ns_calc
if mlp_avg < 1: mlp_avg = 1.0
alpha_min_global = alpha_naive / mlp_avg
if alpha_min_global > 1: alpha_min_global = 1.0

print(f"Heuristic Params: alpha_naive={alpha_naive:.4f}, MLP_avg={mlp_avg:.4f}, alpha_min={alpha_min_global:.4f}")

# Apply per bin
heuristic_preds = []
for i, row in df_analysis.iterrows():
    # T0 (Local Time for this bin)
    t_loc = row['Local_Interval_Time']
    n_misses = row['OFFCORE_REQUESTS.DEMAND_DATA_RD']
    
    if t_loc <= 1e-5:
        heuristic_preds.append(0)
        continue
        
    term = (n_misses * alpha_min_global * DELTA_L) / (t_loc * 1e9)
    heuristic_preds.append(term)

df_analysis['Heuristic_Pred'] = heuristic_preds


# --- Plotting ---
plt.figure(figsize=(12, 6))

# X-axis: Cumulative Time (Remote). 
# Note: 'timestamp' column currently holds interval deltas due to diff(), so we cumsum it to get absolute time.
x_vals = df_analysis['interval_seconds'].cumsum().values
# Prepend 0 to x to close the gap at the start
x_plot = np.concatenate(([0], x_vals))

def extend_start(series):
    vals = series.values
    if len(vals) > 0:
        return np.concatenate(([vals[0]], vals))
    return vals

plt.plot(x_plot, extend_start(df_analysis['Actual_Slowdown']), label='Actual Slowdown', color='black', linewidth=2)
plt.plot(x_plot, extend_start(df_analysis['P']), label='Base Predictor (P)', color='pink', linestyle='--', alpha=0.7)
plt.plot(x_plot, extend_start(df_analysis['AOL_Pred']), label=f'AOL Predictor', color='blue')
# plt.plot(x, df_analysis['ML_Pred'], label='User ML Model', color='green') # Temporarily removed due to poor performance
plt.plot(x_plot, extend_start(df_analysis['Heuristic_Pred']), label='Heuristic LowerBound', color='orange', linestyle='-.')

plt.xlim(left=0) # Ensure X-axis starts at 0
plt.title(f'Slowdown Prediction: GAPBS bc-urand (Binned Resampling N={N_BINS})')
plt.xlabel('Time (s)')
plt.ylabel('Slowdown (Relative)')
plt.legend()
plt.grid(True, alpha=0.3)
plt.ylim(bottom=0) # Set Y-axis to start from 0
plt.tight_layout()
plt.savefig(OUTPUT_PLOT)
print(f"Plot saved to {OUTPUT_PLOT}")

df_analysis.to_csv('results_ts/remote_processed.csv')
