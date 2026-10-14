import csv
import importlib.util
import math
import pathlib
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).parents[1] / 'analyze_priority_failover_memory.py'
spec = importlib.util.spec_from_file_location('memory_analysis', SCRIPT)
analysis = importlib.util.module_from_spec(spec)
spec.loader.exec_module(analysis)

class MemoryAnalysisTests(unittest.TestCase):
    def test_known_fixture(self):
        samples = [10, 20, 30, 40, 50]
        self.assertEqual(analysis.median(samples), 30)
        self.assertEqual(analysis.percentile(samples, .95), 50)
        self.assertEqual(analysis.median([10, 20]), 15)

    def test_invalid_samples(self):
        for samples in ([], [-1], [math.nan], [math.inf]):
            with self.assertRaises(ValueError):
                analysis.median(samples)
            with self.assertRaises(ValueError):
                analysis.percentile(samples, .95)
        for quantile in (0, -1, 1.1, math.nan):
            with self.assertRaises(ValueError):
                analysis.percentile([1], quantile)

    def test_warmup_peak_and_delta(self):
        rows = [dict(elapsed_seconds=str(t), phase='primary', metric='phys_footprint', unit='bytes', footprint_bytes=str(v)) for t, v in [(0, 100), (120, 10), (121, 20), (122, 30)]]
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / 'samples.csv'
            with path.open('w', newline='') as output:
                writer = csv.DictWriter(output, fieldnames=rows[0].keys())
                writer.writeheader()
                writer.writerows(rows)
            result = analysis.analyze(path, warmup_seconds=120, baseline_bytes=15)
            self.assertEqual(result['phases']['primary']['median_bytes'], 20)
            self.assertEqual(result['phases']['primary']['p95_bytes'], 30)
            self.assertEqual(result['phases']['primary']['peak_bytes'], 100)
            self.assertEqual(result['phases']['primary']['delta_bytes'], 5)
            rows[1]['unit'] = 'MiB'
            with path.open('w', newline='') as output:
                writer = csv.DictWriter(output, fieldnames=rows[0].keys())
                writer.writeheader()
                writer.writerows(rows)
            with self.assertRaises(ValueError):
                analysis.analyze(path)

if __name__ == '__main__':
    unittest.main()
