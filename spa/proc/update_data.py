import sys
import csv
import numpy as np
import os
import math
import pandas as pd
from collections import OrderedDict
from pathlib import Path
import argparse

directory = 'rst'
mem_types = ["LOCAL", "NUMA"]
type_to_file = {"LOCAL": "L100-100.data", "NUMA": "L0-1.data"}

events = [
  "time",
  "instructions",
  "cycles",
  "CYCLE_ACTIVITY.STALLS_MEM_ANY",
  "EXE_ACTIVITY.BOUND_ON_STORES",
  "CYCLE_ACTIVITY.STALLS_L3_MISS",
  "CYCLE_ACTIVITY.STALLS_L2_MISS",
  "CYCLE_ACTIVITY.STALLS_L1D_MISS",
  "EXE_ACTIVITY.1_PORTS_UTIL",
  "EXE_ACTIVITY.2_PORTS_UTIL",
  "PARTIAL_RAT_STALLS.SCOREBOARD",
  "OFFCORE_REQUESTS_OUTSTANDING.CYCLES_WITH_DEMAND_DATA_RD",
  "OFFCORE_REQUESTS_OUTSTANDING.DEMAND_DATA_RD",
  "OFFCORE_REQUESTS.DEMAND_DATA_RD",
  "CPU_CLK_UNHALTED.THREAD",
  "MEM_LOAD_RETIRED.L3_MISS",
]

def read_file(file, workload_id, workload_name, mem_type, skip_not_counted=False):
  res = OrderedDict()
  res["workload_id"] = workload_id
  res["workload_name"] = workload_name
  res["mem_type"] = mem_type
  # Note: We no longer skip the whole workload on '<not counted>' lines.
  # Such events will simply remain missing and will be filled with 0 later.
  with open(file) as csv_file:
    csv_header = csv.reader(csv_file, delimiter=' ')
    line_count = 0
    had_not_counted = False
    for row in csv_header:
      line_count += 1
      processed_row = [item for item in row if item]
      if '<not' in processed_row and 'counted>' in processed_row:
        had_not_counted = True
        # keep reading other lines; this particular event won't be parsed
        continue
      for e in events:
        if e in processed_row:
          value = float(processed_row[0].replace(',', ''))
          res[e] = value
  if had_not_counted:
    res["__had_not_counted__"] = True
  return res

def read_data(directory, mem_type, skip_not_counted=False):
  files = []
  for filename in os.listdir(directory):
    files.append(filename)
  files.sort()
  data = []
  for i, filename in enumerate(files):
    f = os.path.join(directory, filename)
    f1 = os.path.join(f, type_to_file[mem_type])
    assert os.path.isfile(f1)
    res = read_file(f1, filename+'..'+mem_type, filename, mem_type, skip_not_counted=skip_not_counted)
    data.append(res)
  return data

def tocsv(mem_type, csv_path, skip_not_counted=False):
  data = read_data(directory, mem_type, skip_not_counted=skip_not_counted)
  if not data:
    print(f"[WARN] No entries for mem_type={mem_type} in {directory}. Writing empty CSV.")
    df = pd.DataFrame(columns=["workload_id", "workload_name", "mem_type", *events])
  else:
    df = pd.DataFrame(data)
  # Fill any missing expected event columns with 0 to keep not-counted workloads
  for col in events:
    if col not in df.columns:
      df[col] = 0.0
  # Ensure identifier columns exist
  for id_col in ("workload_id", "workload_name", "mem_type"):
    if id_col not in df.columns:
      df[id_col] = ""
  # Set index and write
  df.set_index("workload_id", inplace=True)
  filename = os.path.join(csv_path, 'm'+str(mem_type)+'.csv')
  df.to_csv(filename)

def new_separate_csv(csv_path, skip_not_counted=False):
  for lat in mem_types:
    tocsv(lat, csv_path, skip_not_counted=skip_not_counted)

def merge_csv(csv_path):
  merged_df = pd.DataFrame()
  for t in mem_types:
    filename = os.path.join(csv_path, 'm'+str(t)+'.csv')
    if not os.path.exists(filename):
      print(f"[WARN] Missing {filename}; skipping.")
      continue
    df = pd.read_csv(filename)
    merged_df = pd.concat([merged_df, df], ignore_index=True)
  out_file = os.path.join(csv_path, 'merged.csv')
  if merged_df.empty:
    print(f"[WARN] No data to merge for {csv_path}. Writing empty merged.csv")
    pd.DataFrame(columns=["workload_id", "workload_name", "mem_type", *events]).set_index("workload_id", drop=False).to_csv(out_file, index=False)
    return
  merged_df.set_index("workload_id", inplace=True)
  merged_df.to_csv(out_file)

def main():
  parser = argparse.ArgumentParser(description='Merge perf rst into CSVs')
  parser.add_argument('--directory', default=directory, help='rst root directory containing per-workload folders')
  parser.add_argument('--csv-out', default='csv', help='output CSV folder (default: csv under script dir)')
  parser.add_argument('--skip-not-counted', action='store_true',
                      help='skip workloads whose perf output contains "<not counted>"')
  args = parser.parse_args(args=None if sys.argv[0].endswith('update_data.py') else [])

  script_dir = Path(__file__).resolve().parent
  # Resolve rst root relative to script dir if not absolute
  rst_root = Path(args.directory)
  if not rst_root.is_absolute():
    rst_root = rst_root if rst_root.exists() else (script_dir / rst_root)
  rst_root = rst_root.resolve()
  # Resolve csv output under script dir unless absolute
  csv_dir = Path(args.csv_out)
  if not csv_dir.is_absolute():
    csv_dir = csv_dir if csv_dir.exists() else (script_dir / csv_dir)
  csv_dir = csv_dir.resolve()

  globals()['directory'] = str(rst_root)

  csv_dir.mkdir(parents=True, exist_ok=True)
  new_separate_csv(str(csv_dir), skip_not_counted=args.skip_not_counted)
  merge_csv(str(csv_dir))
  print(f"Wrote CSVs to {csv_dir} from rst root {rst_root}")

if __name__ == "__main__":
  mem_types = ["LOCAL", "NUMA"]
  main()
