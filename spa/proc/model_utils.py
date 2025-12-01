#!/usr/bin/env python3
"""Utilities for loading perf datasets and building feature matrices."""
from __future__ import annotations

from pathlib import Path
from typing import Tuple, Optional

import numpy as np
import pandas as pd


def load_dataset(csv_dir: Path, feature_mode: str = "all") -> Tuple[pd.DataFrame, pd.Series]:
    """
    Load LOCAL/NUMA counter CSVs from `csv_dir` (expects merged.csv as produced by update_data.py)
    and return (features, slowdown) ready for modeling.
    """
    merged = csv_dir / "merged.csv"
    if not merged.exists():
        raise FileNotFoundError(f"{merged} does not exist. Run update_data.py for {csv_dir}")

    df = pd.read_csv(merged)
    local = df[df["mem_type"] == "LOCAL"].set_index("workload_name")
    numa = df[df["mem_type"] == "NUMA"].set_index("workload_name")

    joined = local.add_suffix("_local").join(numa.add_suffix("_numa"), how="inner").sort_index()
    # Prefer CPU clock as the cycle baseline when available, fall back to generic cycles
    if "CPU_CLK_UNHALTED.THREAD_local" in joined and "CPU_CLK_UNHALTED.THREAD_numa" in joined:
        base_local = joined["CPU_CLK_UNHALTED.THREAD_local"]
        base_numa = joined["CPU_CLK_UNHALTED.THREAD_numa"]
        slowdown = (base_numa - base_local) / base_local
        joined = joined.assign(_cycle_base_local=base_local)
    else:
        slowdown = (joined["cycles_numa"] - joined["cycles_local"]) / joined["cycles_local"]
        joined = joined.assign(_cycle_base_local=joined["cycles_local"]) 
    features = _build_features(joined, feature_mode)
    return features, slowdown


def compute_aol_feature(csv_dir: Path) -> Optional[pd.DataFrame]:
    """
    Compute AOL = A1 / A3 from LOCAL (fast-tier) counters if available and return
    a single-column DataFrame indexed by workload_name with column 'AOL'.

    A1: OFFCORE_REQUESTS_OUTSTANDING.CYCLES_WITH_DEMAND_DATA_RD
    A3: OFFCORE_REQUESTS.DEMAND_DATA_RD
    """
    merged = csv_dir / "merged.csv"
    if not merged.exists():
        raise FileNotFoundError(f"{merged} does not exist. Run update_data.py for {csv_dir}")

    df = pd.read_csv(merged)
    local = df[df["mem_type"] == "LOCAL"].set_index("workload_name")
    numa = df[df["mem_type"] == "NUMA"].set_index("workload_name")
    joined = local.add_suffix("_local").join(numa.add_suffix("_numa"), how="inner").sort_index()

    a1_col = "OFFCORE_REQUESTS_OUTSTANDING.CYCLES_WITH_DEMAND_DATA_RD_local"
    a3_col = "OFFCORE_REQUESTS.DEMAND_DATA_RD_local"
    if a1_col not in joined.columns or a3_col not in joined.columns:
        return None
    eps = 1e-12
    aol = joined[a1_col] / (joined[a3_col] + eps)
    return pd.DataFrame({"AOL": aol}).astype(float)


def _build_features(joined: pd.DataFrame, feature_mode: str) -> pd.DataFrame:
    feature_mode = feature_mode.lower()
    if feature_mode not in {"minimal", "all"}:
        raise ValueError(f"Unsupported feature_mode '{feature_mode}'. Use 'minimal' or 'all'.")
    return _build_features_all(joined) if feature_mode == "all" else _build_features_minimal(joined)


def _build_features_minimal(joined: pd.DataFrame) -> pd.DataFrame:
    eps = 1e-12
    feats = pd.DataFrame(index=joined.index)

    stall_like = [
        "CYCLE_ACTIVITY.STALLS_MEM_ANY",
        "EXE_ACTIVITY.BOUND_ON_STORES",
        "EXE_ACTIVITY.1_PORTS_UTIL",
        "EXE_ACTIVITY.2_PORTS_UTIL",
        "PARTIAL_RAT_STALLS.SCOREBOARD",
    ]

    for counter in stall_like:
        cname = f"{counter}_local"
        if cname not in joined:
            continue
        feats[f"{counter}_per_cycle"] = joined[cname] / (joined["_cycle_base_local"] + eps)
        feats[f"{counter}_per_instr"] = joined[cname] / (joined["instructions_local"] + eps)

    if "CYCLE_ACTIVITY.STALLS_MEM_ANY_local" in joined:
        mem_any = joined["CYCLE_ACTIVITY.STALLS_MEM_ANY_local"] + eps
        if "EXE_ACTIVITY.BOUND_ON_STORES_local" in joined:
            feats["store_share"] = joined["EXE_ACTIVITY.BOUND_ON_STORES_local"] / mem_any

        core_delta = sum(
            joined.get(col, 0.0)
            for col in [
                "EXE_ACTIVITY.1_PORTS_UTIL_local",
                "EXE_ACTIVITY.2_PORTS_UTIL_local",
                "PARTIAL_RAT_STALLS.SCOREBOARD_local",
            ]
        )
        feats["core_share"] = core_delta / (mem_any + eps)

    return feats.replace([np.inf, -np.inf], np.nan).fillna(0.0)


def _build_features_all(joined: pd.DataFrame) -> pd.DataFrame:
    eps = 1e-12
    feats = pd.DataFrame(index=joined.index)

    feats["ipc"] = joined["instructions_local"] / (joined["_cycle_base_local"] + eps)
    feats["time_local"] = joined["time_local"]
    feats["log_cycles"] = np.log1p(joined["_cycle_base_local"])
    feats["log_time"] = np.log1p(joined["time_local"])

    cycle_base = joined["_cycle_base_local"] + eps
    instr_base = joined["instructions_local"] + eps

    value_cols = []
    for col in joined.columns:
        if not col.endswith("_local"):
            continue
        if col in {"instructions_local", "cycles_local", "time_local"}:
            continue
        if not pd.api.types.is_numeric_dtype(joined[col]):
            continue
        value_cols.append(col)

    for cname in value_cols:
        counter = cname[: -len("_local")]
        feats[f"{counter}_per_cycle"] = joined[cname] / cycle_base
        feats[f"{counter}_per_instr"] = joined[cname] / instr_base

    if "CYCLE_ACTIVITY.STALLS_MEM_ANY_local" in joined:
        mem_any = joined["CYCLE_ACTIVITY.STALLS_MEM_ANY_local"] + eps
        if "EXE_ACTIVITY.BOUND_ON_STORES_local" in joined:
            feats["store_share"] = joined["EXE_ACTIVITY.BOUND_ON_STORES_local"] / mem_any

        core_delta = sum(
            joined.get(col, 0.0)
            for col in [
                "EXE_ACTIVITY.1_PORTS_UTIL_local",
                "EXE_ACTIVITY.2_PORTS_UTIL_local",
                "PARTIAL_RAT_STALLS.SCOREBOARD_local",
            ]
        )
        feats["core_share"] = core_delta / (mem_any + eps)

        for lvl in [
            "CYCLE_ACTIVITY.STALLS_L1D_MISS",
            "CYCLE_ACTIVITY.STALLS_L2_MISS",
            "CYCLE_ACTIVITY.STALLS_L3_MISS",
        ]:
            col = f"{lvl}_local"
            if col in joined:
                feats[f"{lvl}_share"] = joined[col] / mem_any

    return feats.replace([np.inf, -np.inf], np.nan).fillna(0.0)
