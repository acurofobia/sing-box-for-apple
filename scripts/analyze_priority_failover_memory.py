#!/usr/bin/env python3
"""Analyze bounded packet-tunnel footprint CSVs; never substitute synthetic values."""
import argparse
import csv
import json
import math
import pathlib
import statistics

MAX_SAMPLES = 86400


def _validate(samples: list[float]) -> None:
    if not samples or any(not math.isfinite(x) or x < 0 for x in samples):
        raise ValueError('Samples must be nonempty, finite and nonnegative')


def median(samples: list[float]) -> float:
    _validate(samples)
    return statistics.median(samples)


def percentile(samples: list[float], quantile: float) -> float:
    _validate(samples)
    if not math.isfinite(quantile) or not 0 < quantile <= 1:
        raise ValueError('Quantile must be in (0, 1]')
    return sorted(samples)[math.ceil(len(samples) * quantile) - 1]


def analyze(path: pathlib.Path, warmup_seconds: float = 120,
            baseline_bytes: float | None = None) -> dict:
    _validate([warmup_seconds])
    if baseline_bytes is not None:
        _validate([baseline_bytes])
    phases = {}
    metric = None
    previous_time = -1
    total = 0
    with path.open(newline='') as source:
        reader = csv.DictReader(source)
        for row in reader:
            total += 1
            if total > MAX_SAMPLES:
                raise ValueError('CSV exceeds bounded sample limit')
            if row['unit'] != 'bytes' or row['metric'] != 'phys_footprint':
                raise ValueError('Expected Darwin phys_footprint in bytes')
            current_metric = (row['unit'], row['metric'])
            if metric is not None and metric != current_metric:
                raise ValueError('Mixed metrics or units')
            metric = current_metric
            elapsed = float(row['elapsed_seconds'])
            footprint = float(row['footprint_bytes'])
            _validate([elapsed, footprint])
            if elapsed < previous_time:
                raise ValueError('Sample time must be monotonic')
            previous_time = elapsed
            phase = row['phase']
            if not phase or len(phase) > 64 or not all(c.isalnum() or c == '_' for c in phase):
                raise ValueError('Invalid phase name')
            item = phases.setdefault(phase, {'samples': [], 'peak_bytes': 0})
            item['peak_bytes'] = max(item['peak_bytes'], footprint)
            if elapsed >= warmup_seconds:
                item['samples'].append(footprint)
    if total == 0:
        raise ValueError('Empty CSV')
    for item in phases.values():
        samples = item.pop('samples')
        item.update(sample_count=len(samples), median_bytes=median(samples),
                    p95_bytes=percentile(samples, .95))
        if baseline_bytes is not None:
            item['delta_bytes'] = item['median_bytes'] - baseline_bytes
    return {'metric': 'phys_footprint', 'unit': 'bytes',
            'warmup_seconds': warmup_seconds, 'phases': phases}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('csv', type=pathlib.Path)
    parser.add_argument('--warmup-seconds', type=float, default=120)
    parser.add_argument('--baseline-bytes', type=float)
    args = parser.parse_args()
    print(json.dumps(analyze(args.csv, args.warmup_seconds, args.baseline_bytes), indent=2))


if __name__ == '__main__':
    main()
