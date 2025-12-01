#!/usr/bin/env python3
"""
Train from multiple rst folders (hardcoded list) into a single model.

Flow per rst:
  - Generate CSVs under out/<rst_name>/csv using update_data helpers
Then:
  - Concatenate all merged.csv with workload_name prefixed by dataset name
  - Build features (full set internally), optionally append AOL
  - Restrict to SELECTED_FEATURES (hardcoded), train GradientBoosting + LOO
  - Save metrics, predictions, model under out/multi

Edit the RST_LIST and SELECTED_FEATURES below.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Dict, List

import joblib
import numpy as np
import pandas as pd
from sklearn.base import clone
from sklearn.ensemble import GradientBoostingRegressor
from sklearn.metrics import mean_absolute_error, mean_squared_error, r2_score
from sklearn.model_selection import LeaveOneOut

try:
    import spa.proc.update_data as u
    from spa.proc.model_utils import load_dataset, compute_aol_feature
except ImportError:
    import sys

    sys.path.append(str(Path(__file__).resolve().parents[2]))
    import spa.proc.update_data as u
    from spa.proc.model_utils import load_dataset, compute_aol_feature


# 1) Hardcoded list of rst roots to include
RST_LIST: List[str] = [
    "spa/proc/rst/rst_cpu2017_13counter_190ns",
    "spa/proc/rst/rst_gapbs_13counter_190ns",
]

# 2) Hardcoded selected features whitelist (must match printed names)
SELECTED_FEATURES: List[str] = ['ipc', 'time_local', 'log_cycles', 'log_time',
                                'CYCLE_ACTIVITY.STALLS_MEM_ANY_per_cycle',
                                'CYCLE_ACTIVITY.STALLS_MEM_ANY_per_instr',
                                'EXE_ACTIVITY.BOUND_ON_STORES_per_cycle',
                                'EXE_ACTIVITY.BOUND_ON_STORES_per_instr',
                                'CYCLE_ACTIVITY.STALLS_L1D_MISS_per_cycle',
                                'CYCLE_ACTIVITY.STALLS_L1D_MISS_per_instr',
                                'CYCLE_ACTIVITY.STALLS_L2_MISS_per_cycle',
                                'CYCLE_ACTIVITY.STALLS_L2_MISS_per_instr',
                                'CYCLE_ACTIVITY.STALLS_L3_MISS_per_cycle',
                                'CYCLE_ACTIVITY.STALLS_L3_MISS_per_instr',
                                'EXE_ACTIVITY.1_PORTS_UTIL_per_cycle',
                                'EXE_ACTIVITY.1_PORTS_UTIL_per_instr',
                                'EXE_ACTIVITY.2_PORTS_UTIL_per_cycle',
                                'EXE_ACTIVITY.2_PORTS_UTIL_per_instr',
                                'PARTIAL_RAT_STALLS.SCOREBOARD_per_cycle',
                                'PARTIAL_RAT_STALLS.SCOREBOARD_per_instr',
                                'MEM_LOAD_RETIRED.L3_MISS_per_cycle',
                                'MEM_LOAD_RETIRED.L3_MISS_per_instr',
                                'CPU_CLK_UNHALTED.THREAD_per_cycle',
                                'CPU_CLK_UNHALTED.THREAD_per_instr',
                                'OFFCORE_REQUESTS_OUTSTANDING.CYCLES_WITH_DEMAND_DATA_RD_per_cycle',
                                'OFFCORE_REQUESTS_OUTSTANDING.CYCLES_WITH_DEMAND_DATA_RD_per_instr',
                                'OFFCORE_REQUESTS_OUTSTANDING.DEMAND_DATA_RD_per_cycle',
                                'OFFCORE_REQUESTS_OUTSTANDING.DEMAND_DATA_RD_per_instr',
                                'OFFCORE_REQUESTS.DEMAND_DATA_RD_per_cycle',
                                'OFFCORE_REQUESTS.DEMAND_DATA_RD_per_instr', '_cycle_base_per_cycle',
                                '_cycle_base_per_instr', 'store_share', 'core_share',
                                'CYCLE_ACTIVITY.STALLS_L1D_MISS_share',
                                'CYCLE_ACTIVITY.STALLS_L2_MISS_share',
                                'CYCLE_ACTIVITY.STALLS_L3_MISS_share',
                                "AOL",  # uncomment if you pass --add-aol
]

"""
['ipc', 'time_local', 'log_cycles', 'log_time',
       'CYCLE_ACTIVITY.STALLS_MEM_ANY_per_cycle',
       'CYCLE_ACTIVITY.STALLS_MEM_ANY_per_instr',
       'EXE_ACTIVITY.BOUND_ON_STORES_per_cycle',
       'EXE_ACTIVITY.BOUND_ON_STORES_per_instr',
       'CYCLE_ACTIVITY.STALLS_L1D_MISS_per_cycle',
       'CYCLE_ACTIVITY.STALLS_L1D_MISS_per_instr',
       'CYCLE_ACTIVITY.STALLS_L2_MISS_per_cycle',
       'CYCLE_ACTIVITY.STALLS_L2_MISS_per_instr',
       'CYCLE_ACTIVITY.STALLS_L3_MISS_per_cycle',
       'CYCLE_ACTIVITY.STALLS_L3_MISS_per_instr',
       'EXE_ACTIVITY.1_PORTS_UTIL_per_cycle',
       'EXE_ACTIVITY.1_PORTS_UTIL_per_instr',
       'EXE_ACTIVITY.2_PORTS_UTIL_per_cycle',
       'EXE_ACTIVITY.2_PORTS_UTIL_per_instr',
       'PARTIAL_RAT_STALLS.SCOREBOARD_per_cycle',
       'PARTIAL_RAT_STALLS.SCOREBOARD_per_instr',
       'MEM_LOAD_RETIRED.L3_MISS_per_cycle',
       'MEM_LOAD_RETIRED.L3_MISS_per_instr',
       'CPU_CLK_UNHALTED.THREAD_per_cycle',
       'CPU_CLK_UNHALTED.THREAD_per_instr',
       'OFFCORE_REQUESTS_OUTSTANDING.CYCLES_WITH_DEMAND_DATA_RD_per_cycle',
       'OFFCORE_REQUESTS_OUTSTANDING.CYCLES_WITH_DEMAND_DATA_RD_per_instr',
       'OFFCORE_REQUESTS_OUTSTANDING.DEMAND_DATA_RD_per_cycle',
       'OFFCORE_REQUESTS_OUTSTANDING.DEMAND_DATA_RD_per_instr',
       'OFFCORE_REQUESTS.DEMAND_DATA_RD_per_cycle',
       'OFFCORE_REQUESTS.DEMAND_DATA_RD_per_instr', '_cycle_base_per_cycle',
       '_cycle_base_per_instr', 'store_share', 'core_share',
       'CYCLE_ACTIVITY.STALLS_L1D_MISS_share',
       'CYCLE_ACTIVITY.STALLS_L2_MISS_share',
       'CYCLE_ACTIVITY.STALLS_L3_MISS_share',
       "AOL",  # uncomment if you pass --add-aol
       ]
"""


def evaluate_model(model, X: pd.DataFrame, y: pd.Series):
    loo = LeaveOneOut()
    preds = np.zeros(len(X))
    for tr, te in loo.split(X):
        m = clone(model)
        m.fit(X.iloc[tr], y.iloc[tr])
        preds[te[0]] = m.predict(X.iloc[te])[0]
    mae = mean_absolute_error(y, preds)
    rmse = float(np.sqrt(mean_squared_error(y, preds)))
    mape = float(np.mean(np.abs((y - preds) / np.clip(np.abs(y), 1e-9, None))))
    r2 = r2_score(y, preds)
    return {"mae": mae, "rmse": rmse, "mape": mape, "r2": r2}, preds


def _parse_feature_list_arg(text: str) -> List[str]:
    parts = [p.strip() for p in text.split(",")]
    return [p for p in parts if p]


def _load_features_file(path: Path) -> List[str]:
    # Try JSON array first; fallback to newline-separated text
    try:
        data = json.loads(path.read_text())
        if isinstance(data, list) and all(isinstance(x, str) for x in data):
            return [x.strip() for x in data if x.strip()]
    except Exception:
        pass
    # Fallback newline-separated
    return [line.strip() for line in path.read_text().splitlines() if line.strip()]


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Train slowdown model from multiple rst roots (hardcoded list)")
    p.add_argument("--add-aol", action="store_true", help="Append AOL (A1/A3) as extra feature if available")
    p.add_argument("--out-dir", type=Path, default=Path("spa/proc/out/multi"))
    p.add_argument(
        "--features",
        type=str,
        default=None,
        help=(
            "Comma-separated feature names to use. Overrides internal SELECTED_FEATURES when provided. "
            "Example: --features CYCLE_ACTIVITY.STALLS_L3_MISS_per_cycle,EXE_ACTIVITY.2_PORTS_UTIL_per_instr,AOL"
        ),
    )
    p.add_argument(
        "--features-file",
        type=Path,
        default=None,
        help=(
            "Path to a file containing feature names. Either a JSON array or newline-separated list. "
            "Overrides internal SELECTED_FEATURES (and --features string if both given)."
        ),
    )
    return p.parse_args()


def main() -> None:
    args = parse_args()
    out_root = args.out_dir.resolve()
    out_root.mkdir(parents=True, exist_ok=True)

    combined_dir = out_root / "combined"
    combined_dir.mkdir(parents=True, exist_ok=True)

    merged_parts = []
    # Generate CSV per rst and collect merged.csv
    for rst in RST_LIST:
        rst_p = Path(rst).resolve()
        ds_name = rst_p.name
        ds_dir = out_root / ds_name / "csv"
        ds_dir.mkdir(parents=True, exist_ok=True)

        # Build CSVs into ds_dir
        u.directory = str(rst_p)
        u.new_separate_csv(str(ds_dir))
        u.merge_csv(str(ds_dir))

        df = pd.read_csv(ds_dir / "merged.csv")
        # Prefix workload_name to avoid index collisions across datasets
        df["workload_name"] = df["workload_name"].apply(lambda w: f"{ds_name}:{w}")
        merged_parts.append(df)

    # Concatenate all merged
    merged_all = pd.concat(merged_parts, ignore_index=True)
    (combined_dir / "merged.csv").write_text(merged_all.to_csv(index=False))

    # Build features from the combined merged
    X, y = load_dataset(combined_dir, feature_mode="all")

    print(f"Available features ({len(X.columns)}):")
    print(X.columns)

    if args.add_aol:
        aol_df = compute_aol_feature(combined_dir)
        if aol_df is None:
            print("[WARN] AOL not added: required columns missing in merged.csv")
        else:
            X = pd.concat([X, aol_df.reindex(X.index).fillna(0.0)], axis=1)

    # Determine feature whitelist: CLI overrides internal list
    cli_features: List[str] | None = None
    if getattr(args, "features_file", None):
        try:
            cli_features = _load_features_file(args.features_file)
            print(f"[INFO] Loaded {len(cli_features)} features from {args.features_file}")
        except Exception as e:
            print(f"[WARN] Failed to load --features-file {args.features_file}: {e}")
            cli_features = None
    elif getattr(args, "features", None):
        cli_features = _parse_feature_list_arg(args.features)

    selected = cli_features if cli_features else SELECTED_FEATURES

    # Apply selected feature whitelist
    if selected:
        missing = [f for f in selected if f not in X.columns]
        if missing:
            print("[INFO] Some selected features are not present and will be ignored:")
            for m in missing:
                print(f"  - {m}")
        kept = [f for f in selected if f in X.columns]
        if not kept:
            raise SystemExit(
                "No selected features matched available columns. Provide --features/--features-file or edit SELECTED_FEATURES."
            )
        X = X[kept]
        print(f"Using {len(kept)} selected features:")
        for k in kept:
            print(f"  {k}")

    model = GradientBoostingRegressor(
        loss="squared_error",
        learning_rate=0.05,
        n_estimators=400,
        max_depth=3,
        min_samples_leaf=2,
        random_state=42,
        subsample=0.9,
    )
    metrics, preds = evaluate_model(model, X, y)
    final_model = clone(model).fit(X, y)

    importances = None
    if hasattr(final_model, "feature_importances_"):
        importances = {feat: float(w) for feat, w in zip(X.columns, final_model.feature_importances_)}
        print("Feature importances:")
        for feat, w in sorted(importances.items(), key=lambda kv: kv[1], reverse=True):
            print(f"  {feat}: {w:.6f}")

    # Save artifacts
    pd.DataFrame(
        {
            "workload_name": X.index,
            "actual_slowdown": y.values,
            "predicted_slowdown": preds,
            "abs_error": np.abs(y.values - preds),
            "pct_error": np.abs(y.values - preds) / np.clip(np.abs(y.values), 1e-9, None),
        }
    ).to_csv(out_root / "predictions.csv", index=False)

    with (out_root / "metrics.json").open("w") as fh:
        json.dump(
            {
                "rst_list": [str(Path(r).resolve()) for r in RST_LIST],
                "combined_csv_dir": str(combined_dir),
                "add_aol": args.add_aol,
                "metrics": metrics,
                "model_params": final_model.get_params(),
                "features": list(X.columns),
                "feature_importances": importances,
            },
            fh,
            indent=2,
        )

    bundle = {"model": final_model, "feature_columns": list(X.columns)}
    joblib.dump(bundle, out_root / "model.joblib")

    print("Saved:")
    print(f"  metrics: {out_root / 'metrics.json'}")
    print(f"  predictions: {out_root / 'predictions.csv'}")
    print(f"  model: {out_root / 'model.joblib'}")


if __name__ == "__main__":
    main()
