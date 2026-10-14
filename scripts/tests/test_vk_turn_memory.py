import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('analyzer', Path(__file__).parents[1] / 'analyze_vk_turn_memory.py')
analyzer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(analyzer)


class MemoryTests(unittest.TestCase):
    def capture(self, rows):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        path = Path(directory.name) / 'capture.csv'
        path.write_text('elapsed_seconds,phase,metric,unit,footprint_bytes,requested_turn_connections,active_turn_connections,turn_tx_bytes,turn_rx_bytes\n' + rows)
        return path

    def test_excludes_warmup_but_keeps_startup_peak(self):
        path = self.capture('0,combined-startup,phys_footprint,bytes,104857600,1,0,0,0\n120,combined,phys_footprint,bytes,20971520,1,1,10,20\n121,combined,phys_footprint,bytes,23068672,1,1,30,50\n')
        result = analyzer.analyze(path)
        self.assertEqual(result['median'], 21)
        self.assertEqual(result['startup_inclusive_peak'], 100)
        self.assertEqual(result['turn_rx_bytes_delta'], 30)

    def test_vless_capture_has_no_turn_sessions(self):
        path = self.capture('0,vless-startup,phys_footprint,bytes,31457280,0,0,0,0\n120,vless,phys_footprint,bytes,25165824,0,0,0,0\n')
        result = analyzer.analyze(path)
        self.assertEqual(result['mode'], 'vless')
        self.assertEqual(result['median'], 24)
        self.assertEqual(result['active_turn_connections'], [0, 0])

    def test_vless_capture_rejects_active_turn(self):
        path = self.capture('120,vless,phys_footprint,bytes,25165824,0,1,0,0\n')
        with self.assertRaises(ValueError):
            analyzer.analyze(path)

    def test_rejects_incomplete_turn_pool(self):
        path = self.capture('120,combined,phys_footprint,bytes,100,30,1,10,20\n')
        with self.assertRaises(ValueError):
            analyzer.analyze(path)

    def test_rejects_failed_and_short_captures(self):
        for row in ('0,failed,phys_footprint,bytes,100,0,0,0,0\n', '0,baseline,phys_footprint,bytes,100,0,0,0,0\n'):
            with self.assertRaises(ValueError):
                analyzer.analyze(self.capture(row))

    def test_accepts_long_capture_with_minute_samples(self):
        rows = ''.join(f'{780 + 60 * i},combined,phys_footprint,bytes,20971520,30,30,10,20\n'
                       for i in range(1001))
        result = analyzer.analyze(self.capture(rows))
        self.assertEqual(result['steady_samples'], 1001)
        self.assertEqual(result['duration_seconds'], 60780)
        self.assertEqual(result['median'], 20)
