#!/usr/bin/env python3
"""
Parallel, more precise feature ablation and forward selection.

Improvements over feature_ablation.py:
- Parallel evaluation for single-feature, drop-one, and forward-selection steps
- Configurable CV: Leave-One-Out or Repeated K-Fold
- Optional permutation importance (aggregated across CV folds)

Outputs:
- JSON summary (baseline + top-k lists + forward path + optional permutation importance)
- CSV table merging single-feature and drop-one results
"""
from __future__ import annotations

import argparse
import json
import math
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple

import numpy as np
import pandas as pd
from joblib import Parallel, delayed
from sklearn.base import clone
from sklearn.ensemble import GradientBoostingRegressor
from sklearn.metrics import mean_absolute_error, mean_squared_error, r2_score
from sklearn.model_selection import LeaveOneOut, RepeatedKFold

try:
    from spa.proc.model_utils import load_dataset
except ImportError:  # allow running as plain script
    import sys
    from pathlib import Path

    sys.path.append(str(Path(__file__).resolve().parents[2]))
    from spa.proc.model_utils import load_dataset


@dataclass
class Metrics:
    mae: float
    rmse: float
    mape: float
    r2: float

    def to_dict(self) -> Dict[str, float]:
        return {"mae": self.mae, "rmse": self.rmse, "mape": self.mape, "r2": self.r2}


def build_cv(cv_kind: str, n_splits: int, n_repeats: int, random_state: int, n_samples: int):
    if cv_kind == "loo":
        return LeaveOneOut()
    if cv_kind == "rkf":
        # Guard: if data very small, cap splits
        splits = max(2, min(n_splits, n_samples))
        return RepeatedKFold(n_splits=splits, n_repeats=n_repeats, random_state=random_state)
    raise ValueError(f"Unsupported cv '{cv_kind}'. Use 'loo' or 'rkf'.")


def evaluate_oof(model, X: pd.DataFrame, y: pd.Series, cv, n_jobs: int) -> Tuple[Metrics, np.ndarray]:
    # Run folds in parallel; aggregate OOF preds
    indices = np.arange(len(X))

    def _run_fold(train_idx, test_idx):
        m = clone(model)
        m.fit(X.iloc[train_idx], y.iloc[train_idx])
        pred = m.predict(X.iloc[test_idx])
        return test_idx, pred

    results = Parallel(n_jobs=n_jobs, backend="loky")(
        delayed(_run_fold)(train_idx, test_idx) for train_idx, test_idx in cv.split(X, y)
    )
    # Some CV splitters (RepeatedKFold) predict each sample multiple times; average them
    preds = np.zeros(len(X), dtype=float)
    counts = np.zeros(len(X), dtype=int)
    for test_idx, pred in results:
        preds[test_idx] += pred
        counts[test_idx] += 1
    # Avoid div-by-zero when some samples unseen (shouldn't happen for LOO or RKF)
    counts[counts == 0] = 1
    preds = preds / counts

    mae = mean_absolute_error(y, preds)
    rmse = float(np.sqrt(mean_squared_error(y, preds)))
    mape = float(np.mean(np.abs((y - preds) / np.clip(np.abs(y), 1e-9, None))))
    r2 = r2_score(y, preds)
    return Metrics(mae, rmse, mape, r2), preds


def permutation_importance_cv(model, X: pd.DataFrame, y: pd.Series, cv, n_repeats: int, n_jobs: int) -> Dict[str, float]:
    # Simple, CV-averaged permutation importance using MAE degradation
    rng = np.random.RandomState(42)
    base_metrics, base_oof = evaluate_oof(model, X, y, cv, n_jobs)
    base_mae = base_metrics.mae

    def _perm_feat(col: str) -> Tuple[str, float]:
        deltas: List[float] = []
        for _ in range(n_repeats):
            Xp = X.copy()
            # permute column values consistently across rows
            Xp[col] = rng.permutation(Xp[col].values)
            m, _ = evaluate_oof(model, Xp, y, cv, n_jobs)
            deltas.append(m.mae - base_mae)
        return col, float(np.mean(deltas))

    results = Parallel(n_jobs=n_jobs, backend="loky")(
        delayed(_perm_feat)(c) for c in X.columns
    )
    return {k: v for k, v in results}


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Parallel, precise feature ablation + forward selection")
    p.add_argument("--dataset", type=Path, required=True, help="Folder containing merged.csv")
    p.add_argument("--feature-mode", choices=["minimal", "all"], default="all")
    p.add_argument("--cv", choices=["loo", "rkf"], default="loo")
    p.add_argument("--rkf-splits", type=int, default=5)
    p.add_argument("--rkf-repeats", type=int, default=10)
    p.add_argument("--n-jobs", type=int, default=-1, help="Parallel workers (-1 for all cores)")
    p.add_argument("--perm-importance", action="store_true", help="Compute permutation importance (slow)")
    p.add_argument("--perm-repeats", type=int, default=10)
    p.add_argument("--out-json", type=Path, default=Path("spa/proc/ablation_pro.json"))
    p.add_argument("--out-csv", type=Path, default=Path("spa/proc/ablation_pro.csv"))
    return p.parse_args()


def main() -> None:
    args = parse_args()
    X, y = load_dataset(args.dataset, feature_mode=args.feature_mode)

    model = GradientBoostingRegressor(
        loss="squared_error",
        learning_rate=0.05,
        n_estimators=600,           # slightly larger for stability
        max_depth=3,
        min_samples_leaf=2,
        random_state=42,
        subsample=0.9,
    )

    cv = build_cv(args.cv, args.rkf_splits, args.rkf_repeats, 42, len(X))

    # Baseline
    baseline, base_oof = evaluate_oof(model, X, y, cv, args.n_jobs)

    # Single-feature (parallel over features)
    def _eval_single(col: str):
        m, _ = evaluate_oof(model, X[[col]], y, cv, args.n_jobs)
        return {"feature": col, **m.to_dict()}

    single_rows = Parallel(n_jobs=args.n_jobs, backend="loky")(
        delayed(_eval_single)(c) for c in X.columns
    )

    # Drop-one (parallel over features)
    def _eval_drop(col: str):
        remain = [c for c in X.columns if c != col]
        m, _ = evaluate_oof(model, X[remain], y, cv, args.n_jobs)
        return {
            "dropped_feature": col,
            **m.to_dict(),
            "delta_mae": m.mae - baseline.mae,
            "delta_rmse": m.rmse - baseline.rmse,
            "delta_r2": m.r2 - baseline.r2,
        }

    drop_rows = Parallel(n_jobs=args.n_jobs, backend="loky")(
        delayed(_eval_drop)(c) for c in X.columns
    )

    # Greedy forward selection (parallel per step over remaining candidates)
    remaining = list(X.columns)
    selected: List[str] = []
    forward_path: List[Dict] = []
    current_best_mae = math.inf
    while remaining:
        candidates = remaining.copy()

        def _eval_with(feat: str):
            cols = selected + [feat]
            m, _ = evaluate_oof(model, X[cols], y, cv, args.n_jobs)
            return feat, m

        results = Parallel(n_jobs=args.n_jobs, backend="loky")(
            delayed(_eval_with)(f) for f in candidates
        )
        # pick best by MAE
        best_feat, best_metrics = min(results, key=lambda t: t[1].mae)
        selected.append(best_feat)
        remaining.remove(best_feat)
        forward_path.append({"k": len(selected), "added": best_feat, "features": list(selected), **best_metrics.to_dict()})

        # Early stop if improvement is negligible
        if current_best_mae - best_metrics.mae < 1e-4:
            break
        current_best_mae = best_metrics.mae

    # Optional permutation importance (slow)
    perm_importances = None
    if args.perm_importance:
        perm_importances = permutation_importance_cv(model, X, y, cv, args.perm_repeats, args.n_jobs)

    # Persist outputs
    args.out_json.parent.mkdir(parents=True, exist_ok=True)
    with args.out_json.open("w") as f:
        json.dump(
            {
                "dataset": str(args.dataset),
                "feature_mode": args.feature_mode,
                "cv": args.cv,
                "rkf_splits": args.rkf_splits,
                "rkf_repeats": args.rkf_repeats,
                "n_jobs": args.n_jobs,
                "baseline": baseline.to_dict(),
                "best_single": sorted(single_rows, key=lambda d: d["mae"])[:15],
                "drop_importance": sorted(drop_rows, key=lambda d: d["delta_mae"], reverse=True)[:30],
                "forward_path": forward_path,
                "permutation_importance": perm_importances,
            },
            f,
            indent=2,
        )

    table = pd.concat(
        [pd.DataFrame(single_rows).assign(kind="single"), pd.DataFrame(drop_rows).assign(kind="drop_one")],
        ignore_index=True,
    )
    table.to_csv(args.out_csv, index=False)

    # Console summary
    print("Baseline:")
    for k, v in baseline.to_dict().items():
        print(f"  {k}: {v:.4f}")
    print("\nBest single (top-5 by MAE):")
    for row in sorted(single_rows, key=lambda d: d["mae"])[:5]:
        print(f"  {row['feature']}: mae={row['mae']:.4f}, r2={row['r2']:.3f}")
    print("\nDrop-one importance (top-5 by ΔMAE):")
    for row in sorted(drop_rows, key=lambda d: d["delta_mae"], reverse=True)[:5]:
        print(f"  drop {row['dropped_feature']}: Δmae={row['delta_mae']:.4f}, Δr2={row['delta_r2']:.3f}")
    print("\nForward selection (first 6 steps):")
    for step in forward_path[:6]:
        print(f"  k={step['k']}, +{step['added']}, mae={step['mae']:.4f}, r2={step['r2']:.3f}")


if __name__ == "__main__":
    main()

