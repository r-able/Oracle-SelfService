#!/usr/bin/env python3
"""
forecast_tablespace.py — the "Predict" stage of the closed-loop demo.

Maintains a small per-tablespace history file (one JSON line per day) and
fits a simple linear trend to project when pct_used will cross a breach
threshold. Deliberately not using Prophet/statsmodels — a demo doesn't need
them, and a plain least-squares fit over a handful of points is easier to
explain on camera than a black-box forecasting library anyway.

Usage:
  forecast_tablespace.py --tablespace USERS --pct-used 72.3 \
      --history-file /etc/ansible/OEM/history/USERS.jsonl \
      --breach-threshold 95 --warn-days 4

Prints one JSON object to stdout, e.g.:
  {"tablespace": "USERS", "current_pct_used": 72.3, "slope_per_day": 4.1,
   "days_to_breach": 5.5, "should_alert": false, "data_points": 3}

Ansible consumes this via `from_json` on the task's stdout.
"""

import argparse
import json
import sys
from datetime import date, datetime
from pathlib import Path


def load_history(path: Path):
    if not path.exists():
        return []
    points = []
    with path.open() as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            points.append(json.loads(line))
    return points


def save_history(path: Path, points):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w") as f:
        for p in sorted(points, key=lambda x: x["date"]):
            f.write(json.dumps(p) + "\n")


def upsert_today(points, today_str: str, pct_used: float):
    """Idempotent: re-running on the same day overwrites, doesn't duplicate."""
    points = [p for p in points if p["date"] != today_str]
    points.append({"date": today_str, "pct_used": pct_used})
    return points


def linear_fit(points):
    """Least-squares slope/intercept of pct_used vs. day-index (day 0 =
    earliest reading). Returns (slope_per_day, intercept). Needs >=2
    distinct dates; with exactly 2 points this is just the two-point slope,
    which is fine and expected for a fresh demo history."""
    dates = sorted({p["date"] for p in points})
    base = datetime.strptime(dates[0], "%Y-%m-%d").date()
    xs, ys = [], []
    for p in points:
        d = datetime.strptime(p["date"], "%Y-%m-%d").date()
        xs.append((d - base).days)
        ys.append(p["pct_used"])

    n = len(xs)
    mean_x = sum(xs) / n
    mean_y = sum(ys) / n
    num = sum((x - mean_x) * (y - mean_y) for x, y in zip(xs, ys))
    den = sum((x - mean_x) ** 2 for x in xs)
    if den == 0:
        return 0.0, mean_y
    slope = num / den
    intercept = mean_y - slope * mean_x
    return slope, intercept


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tablespace", required=True)
    ap.add_argument("--pct-used", required=True, type=float)
    ap.add_argument("--history-file", required=True)
    ap.add_argument("--breach-threshold", type=float, default=95.0)
    ap.add_argument("--warn-days", type=float, default=4.0)
    ap.add_argument("--today", default=None, help="override for testing, YYYY-MM-DD")
    args = ap.parse_args()

    history_path = Path(args.history_file)
    today_str = args.today or date.today().isoformat()

    points = load_history(history_path)
    points = upsert_today(points, today_str, args.pct_used)
    save_history(history_path, points)

    distinct_dates = {p["date"] for p in points}
    result = {
        "tablespace": args.tablespace,
        "current_pct_used": args.pct_used,
        "data_points": len(distinct_dates),
    }

    if len(distinct_dates) < 2:
        result.update(slope_per_day=None, days_to_breach=None, should_alert=False,
                       note="not enough history yet to project a trend")
        print(json.dumps(result))
        return

    slope, intercept = linear_fit(points)
    result["slope_per_day"] = round(slope, 3)

    if slope <= 0:
        result.update(days_to_breach=None, should_alert=False,
                       note="flat or shrinking usage, no forecast needed")
        print(json.dumps(result))
        return

    days_to_breach = (args.breach_threshold - args.pct_used) / slope
    result["days_to_breach"] = round(days_to_breach, 1)
    result["should_alert"] = 0 <= days_to_breach <= args.warn_days
    print(json.dumps(result))


if __name__ == "__main__":
    main()
