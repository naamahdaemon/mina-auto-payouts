#!/usr/bin/env bash
# Read-only node_exporter collector. Requires Bash, Python 3, curl and flock.
# Usage: mina-payout-metrics.sh [ENGINE_DIR] [OUTPUT.prom] [GRAPHQL_URL]
# Optional PAYOUT_PUBLIC_KEY: query this wallet even before the first batch.
# Does not source auto-payout.conf or .env, or access private keys.
set -Eeuo pipefail
export LC_ALL=C
ENGINE_DIR="${1:-$HOME/mina-scripts/payouts/mina-pool-payout}"
OUTPUT="${2:-/var/lib/node_exporter/textfile_collector/mina_payout.prom}"
GRAPHQL_URL="${3:-http://127.0.0.1:3085/graphql}"
[[ "$OUTPUT" == *.prom ]] || { echo 'Output must end in .prom' >&2; exit 2; }
command -v python3 >/dev/null
# Serialize writers only; never acquire the payout executor's locks.
umask 022
exec 9>"${OUTPUT}.lock"
flock -n 9 || exit 0
python3 - "$ENGINE_DIR" "$OUTPUT" "$GRAPHQL_URL" <<'PY'
import datetime
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time

engine, output, endpoint = sys.argv[1:]
root = Path(engine) / '.auto-payout'
metrics = []
errors = []

def metric(name, value, help_text, labels=''):
    name = 'mina_payout_' + name
    metrics.extend([f'# HELP {name} {help_text}', f'# TYPE {name} gauge',
                    f'{name}{labels} {value}'])

def integer(value):
    if isinstance(value, bool) or not re.fullmatch(r'[0-9]+', str(value)):
        raise ValueError('Expected nonnegative integer')
    return int(value)

def timestamp(value):
    return int(datetime.datetime.strptime(value, '%Y-%m-%dT%H:%M:%SZ')
               .replace(tzinfo=datetime.timezone.utc).timestamp())

def read_state(path):
    data = json.loads(path.read_text())
    integer(data['epoch'])
    integer(data['transaction_count'])
    if not re.fullmatch(r'[A-Z_]+', data['status']):
        raise ValueError('Invalid status')
    if not isinstance(data.get('payout_wallet'), str) or not data['payout_wallet']:
        raise ValueError('Missing wallet')
    return data

batch = None
active = False
completed = []
try:
    if not Path(engine).is_dir():
        raise ValueError('Engine directory not found')
    if root.exists():
        # iterdir raises on permission errors instead of silently treating them as idle.
        list(root.iterdir())
        batches = root / 'batches'
        if batches.exists():
            for directory in batches.iterdir():
                path = directory / 'state.json'
                if not path.is_file():
                    continue
                state = read_state(path)
                if state['status'] == 'COMPLETED_OK':
                    completed.append((timestamp(state['completed_at_utc']), state))
        pointer = root / 'active_batch'
        if pointer.exists():
            batch_id = pointer.read_text().strip()
            if not re.fullmatch(r'[A-Za-z0-9_-]+', batch_id):
                raise ValueError('Invalid active batch pointer')
            batch = read_state(batches / batch_id / 'state.json')
            active = batch['status'] != 'COMPLETED_OK'
        elif completed:
            batch = max(completed, key=lambda item: item[0])[1]
    metric('active_batch', int(active), 'Whether a noncompleted batch is active.')
    metric('batch_available', int(batch is not None), 'Whether an active or completed batch is available.')
    last = root / 'last_processed_epoch'
    if last.exists():
        metric('last_processed_epoch', integer(last.read_text().strip()),
               'Last processed epoch, including epochs with no payout transactions.')
    if completed:
        finished, latest = max(completed, key=lambda item: item[0])
        metric('last_completed_epoch', integer(latest['epoch']), 'Epoch of the most recently completed batch.')
        metric('last_completed_timestamp_seconds', finished, 'UTC completion time of the last completed batch.')
    if batch:
        count = integer(batch['transaction_count'])
        metric('epoch', integer(batch['epoch']), 'Epoch of the selected batch.')
        metric('transactions_total', count, 'Transactions planned in this batch; a gauge, not a lifetime counter.')
        metric('status', 1, 'Current status of the selected batch.', '{status="' + batch['status'] + '"}')
    else:
        metric('status', 1, 'Current status of the selected batch.', '{status="IDLE"}')
    metric('state_collection_success', 1, 'Whether local payout state was read successfully.')
except (OSError, ValueError, KeyError, TypeError) as exc:
    metrics.clear()
    batch = None
    errors.append('Cannot read payout state: ' + str(exc))
    metric('state_collection_success', 0, 'Whether local payout state was read successfully.')

wallet = os.environ.get('PAYOUT_PUBLIC_KEY') or (batch or {}).get('payout_wallet')
wallet_data = None
if wallet:
    try:
        if batch and wallet != batch['payout_wallet']:
            raise ValueError('Configured wallet differs from selected batch wallet')
        query = {'query': 'query($pk: PublicKey!) { syncStatus account(publicKey:$pk) { balance { total } nonce inferredNonce } pooledUserCommands(publicKey:$pk) { id } }',
                 'variables': {'pk': wallet}}
        # curl provides a hard overall timeout, so a stalled daemon cannot hang cron.
        response = subprocess.run(['curl', '--silent', '--show-error', '--fail',
                                   '--connect-timeout', '3', '--max-time', '10',
                                   endpoint, '-H', 'Content-Type: application/json',
                                   '--data-binary', json.dumps(query)],
                                  capture_output=True, text=True, timeout=12, check=True)
        result = json.loads(response.stdout)
        if result.get('errors'):
            raise ValueError('GraphQL returned errors')
        data = result['data']
        synced = data['syncStatus'] == 'SYNCED'
        metric('daemon_synced', int(synced), 'Whether the Mina daemon is synchronized.')
        if not synced:
            raise ValueError('Mina daemon is not synchronized')
        account = data['account']
        nonce = integer(account['nonce'])
        inferred = integer(account['inferredNonce'])
        balance = integer(account['balance']['total'])
        if not isinstance(data['pooledUserCommands'], list):
            raise ValueError('Invalid pending transaction list')
        wallet_data = (nonce, balance)
        metric('wallet_nonce', nonce, 'Current on-chain nonce of the payout wallet.')
        metric('wallet_inferred_nonce', inferred, 'Payout wallet nonce including pending transactions.')
        metric('wallet_pending_transactions', len(data['pooledUserCommands']), 'Pending wallet transactions.')
        metric('wallet_balance_mina', f'{balance / 1e9:.9f}', 'Current payout wallet balance in MINA.')
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as exc:
        errors.append('Wallet query failed: ' + type(exc).__name__)
metric('wallet_collection_success', int(wallet_data is not None), 'Whether a live synchronized wallet query succeeded.')

try:
    if batch:
        count = integer(batch['transaction_count'])
        execution = batch.get('execution') or {}
        confirmed = None
        if batch['status'] == 'COMPLETED_OK':
            confirmed = count
        elif not execution:
            confirmed = 0
            if wallet_data:
                remaining = max(0, integer(batch['target_before_payout_nanomina']) - wallet_data[1])
                metric('funding_remaining_mina', f'{remaining / 1e9:.9f}', 'Funding still needed before signing; absent once signing starts.')
        elif wallet_data:
            start = integer(execution['start_nonce'])
            confirmed = min(count, max(0, wallet_data[0] - start))
        if confirmed is not None:
            metric('transactions_confirmed', confirmed, 'Estimated confirmations from consumed nonces; assumes a dedicated wallet.')
            metric('progress_percent', 100 * confirmed / count if count else 100,
                   'Estimated confirmation progress, not submission progress or final integrity status.')
            metric('next_transaction_position', confirmed + 1 if confirmed < count else 0,
                   'Next transaction awaiting confirmation, one-based; zero when all are confirmed.')
except (KeyError, ValueError, TypeError) as exc:
    errors.append('Invalid batch progress fields: ' + str(exc))

metric('metrics_collection_success', int(not errors), 'Whether this collection completed without errors.')
metric('metrics_collection_timestamp_seconds', int(time.time()), 'UTC time of this collection attempt; monitor for stale cron output.')
# Temporary file shares the destination directory and is not a .prom file.
# node_exporter sees either the complete old file or the complete new file.
fd, temporary = tempfile.mkstemp(prefix='.mina-payout-', dir=Path(output).parent)
try:
    with os.fdopen(fd, 'w') as stream:
        stream.write('\n'.join(metrics) + '\n')
        stream.flush()
        os.fchmod(stream.fileno(), 0o644)
    os.replace(temporary, output)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
for error in errors:
    print(error, file=sys.stderr)
sys.exit(1 if errors else 0)
PY
