"""Offline collector checks; never accesses a daemon or production payout state."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'mina-payout-metrics.sh'

class MetricsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.engine = self.root / 'engine'
        self.state = self.engine / '.auto-payout'
        self.batches = self.state / 'batches'
        self.batches.mkdir(parents=True)
        self.output = self.root / 'payout.prom'
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        curl = self.bin / 'curl'
        curl.write_text('#!/bin/sh\ncat "$METRICS_RESPONSE"\n')
        curl.chmod(0o755)
        self.response = self.root / 'response.json'
        self.response.write_text(json.dumps({'data': {'syncStatus': 'SYNCED',
            'account': {'nonce': '542', 'inferredNonce': '550', 'balance': {'total': '1000000000'}},
            'pooledUserCommands': []}}))
        self.env = dict(os.environ, PATH=str(self.bin) + ':' + os.environ['PATH'],
                        METRICS_RESPONSE=str(self.response))
        self.env.pop('PAYOUT_PUBLIC_KEY', None)

    def batch(self, status='SUBMITTED_WAITING_CONFIRMATION', name='batch', active=True):
        data = {'epoch': '81', 'transaction_count': '250', 'status': status,
                'payout_wallet': 'TEST_WALLET', 'target_before_payout_nanomina': '11000000000',
                'execution': {'start_nonce': '500', 'expected_next_nonce': '750'}}
        directory = self.batches / name
        directory.mkdir(exist_ok=True)
        (directory / 'state.json').write_text(json.dumps(data))
        if active:
            (self.state / 'active_batch').write_text(name)
        return data, directory / 'state.json'

    def run_collector(self, expected=0):
        proc = subprocess.run([str(SCRIPT), str(self.engine), str(self.output)],
                              env=self.env, capture_output=True, text=True)
        self.assertEqual(proc.returncode, expected, proc.stderr)
        text = self.output.read_text()
        self.assertTrue(text.endswith('\n'))
        self.assertEqual(self.output.stat().st_mode & 0o777, 0o644)
        self.assertFalse(list(self.root.glob('.mina-payout-*')))
        return text

    def test_live_progress(self):
        self.batch()
        text = self.run_collector()
        for value in ['transactions_confirmed 42', 'progress_percent 16.8',
                      'next_transaction_position 43', 'wallet_nonce 542']:
            self.assertIn('mina_payout_' + value + '\n', text)
        self.assertNotIn('funding_remaining_mina', text)

    def test_funding(self):
        data, path = self.batch('WAITING_FOR_FUNDING')
        del data['execution']
        path.write_text(json.dumps(data))
        text = self.run_collector()
        self.assertIn('mina_payout_funding_remaining_mina 10.000000000', text)
        self.assertIn('mina_payout_progress_percent 0.0', text)

    def test_completed_fallback_and_clamp(self):
        data, path = self.batch('COMPLETED_OK', active=False)
        data['completed_at_utc'] = '2026-09-24T12:00:00Z'
        path.write_text(json.dumps(data))
        text = self.run_collector()
        self.assertIn('mina_payout_transactions_confirmed 250', text)
        self.assertIn('mina_payout_next_transaction_position 0', text)
        self.assertIn('mina_payout_last_completed_epoch 81', text)
        self.assertIn('mina_payout_active_batch 0', text)

    def test_failure_replaces_live_values(self):
        self.batch()
        self.run_collector()
        self.response.write_text('{"errors":[{"message":"Unavailable"}]}')
        text = self.run_collector(1)
        self.assertIn('mina_payout_metrics_collection_success 0', text)
        self.assertNotIn('mina_payout_wallet_nonce ', text)
        self.assertNotIn('mina_payout_progress_percent ', text)
        self.assertIn('mina_payout_epoch 81', text)

    def test_invalid_pointer(self):
        (self.state / 'active_batch').write_text('../outside')
        text = self.run_collector(1)
        self.assertIn('mina_payout_state_collection_success 0', text)
        self.assertNotIn('mina_payout_epoch ', text)

    def test_nonce_bounds(self):
        self.batch()
        for nonce, expected in [(400, 0), (900, 250)]:
            response = json.loads(self.response.read_text())
            response['data']['account']['nonce'] = str(nonce)
            self.response.write_text(json.dumps(response))
            text = self.run_collector()
            self.assertIn(f'mina_payout_transactions_confirmed {expected}\n', text)

    def test_active_takes_priority(self):
        old, path = self.batch('COMPLETED_OK', name='old', active=False)
        old['epoch'] = '80'
        old['completed_at_utc'] = '2026-09-23T12:00:00Z'
        path.write_text(json.dumps(old))
        self.batch()
        text = self.run_collector()
        self.assertIn('mina_payout_epoch 81\n', text)
        self.assertIn('mina_payout_last_completed_epoch 80\n', text)

    def test_unsynced(self):
        self.batch()
        response = json.loads(self.response.read_text())
        response['data']['syncStatus'] = 'BOOTSTRAP'
        self.response.write_text(json.dumps(response))
        text = self.run_collector(1)
        self.assertIn('mina_payout_daemon_synced 0', text)
        self.assertNotIn('mina_payout_progress_percent ', text)

    def test_idle(self):
        text = self.run_collector()
        self.assertIn('mina_payout_status{status="IDLE"} 1', text)
        self.assertIn('mina_payout_batch_available 0', text)
        self.assertNotIn('mina_payout_epoch ', text)

if __name__ == '__main__':
    unittest.main()
