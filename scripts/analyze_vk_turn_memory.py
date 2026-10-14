#!/usr/bin/env python3
"""Summarize measured iOS extension footprint; reject failed or empty captures."""
import argparse
import csv
import json
import math
from pathlib import Path
import statistics


def analyze(path: Path, warmup: float = 120) -> dict:
    if not math.isfinite(warmup) or warmup < 0:
        raise ValueError('Invalid warmup')
    rows = []
    previous = -1.0
    with path.open(newline='') as source:
        for row in csv.DictReader(source):
            if len(rows) >= 86400:
                raise ValueError('Capture exceeds bounded sample limit')
            if row['metric'] != 'phys_footprint' or row['unit'] != 'bytes':
                raise ValueError('Expected Darwin phys_footprint in bytes')
            elapsed = float(row['elapsed_seconds'])
            footprint = int(row['footprint_bytes'])
            if not math.isfinite(elapsed) or elapsed < previous or footprint < 0:
                raise ValueError('Invalid time or footprint')
            if row['phase'] == 'failed':
                raise ValueError('Failed startup is not a memory measurement')
            previous = elapsed
            row.update(elapsed=elapsed, footprint=footprint)
            rows.append(row)
    steady = [r for r in rows if r['elapsed'] >= warmup and r['phase'] in ('baseline', 'combined', 'vless')]
    if not steady:
        raise ValueError('No running samples after warmup')
    phases = {r['phase'] for r in steady}
    if len(phases) != 1:
        raise ValueError('Mixed measurement modes')
    phase = phases.pop()
    requested = {int(r['requested_turn_connections']) for r in steady}
    if len(requested) != 1:
        raise ValueError('Requested session count changed')
    requested = requested.pop()
    active = [int(r['active_turn_connections']) for r in steady]
    if phase == 'combined' and (requested < 1 or min(active) != requested or max(active) != requested):
        raise ValueError('TURN did not hold the requested active session count throughout the window')
    if phase in ('baseline', 'vless') and (requested != 0 or min(active) != 0 or max(active) != 0):
        raise ValueError('Non-TURN mode contains active or requested TURN sessions')
    values = sorted(r['footprint'] / 1048576 for r in steady)
    return dict(mode=phase, metric='phys_footprint', unit='MiB', warmup_seconds=warmup,
                duration_seconds=rows[-1]['elapsed'], steady_samples=len(values),
                median=statistics.median(values), p95=values[math.ceil(len(values) * .95) - 1],
                steady_peak=max(values), startup_inclusive_peak=max(r['footprint'] for r in rows) / 1048576,
                requested_turn_connections=requested, active_turn_connections=[min(active), max(active)],
                turn_tx_bytes_delta=int(steady[-1]['turn_tx_bytes']) - int(steady[0]['turn_tx_bytes']),
                turn_rx_bytes_delta=int(steady[-1]['turn_rx_bytes']) - int(steady[0]['turn_rx_bytes']))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('csv', type=Path)
    parser.add_argument('--warmup-seconds', type=float, default=120)
    args = parser.parse_args()
    print(json.dumps(analyze(args.csv, args.warmup_seconds), indent=2))
