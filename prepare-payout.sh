#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="$BASE/auto-payout.conf"
STATE="$BASE/.auto-payout"
source "$CONF"

for c in curl jq python3 npm flock; do
  command -v "$c" >/dev/null || { echo "Missing command: $c" >&2; exit 1; }
done
mkdir -p "$STATE"/{batches,locks,notified}
exec 9>"$STATE/locks/prepare.lock"
flock -n 9 || { echo "prepare-payout already running"; exit 0; }
cd "$BASE"

if [[ -s "$STATE/active_batch" ]]; then
  ACTIVE_ID=$(<"$STATE/active_batch")
  ACTIVE_STATE="$STATE/batches/$ACTIVE_ID/state.json"
  if [[ -s "$ACTIVE_STATE" ]]; then
    ACTIVE_STATUS=$(jq -r '.status // "UNKNOWN"' "$ACTIVE_STATE")
    if [[ "$ACTIVE_STATUS" != "COMPLETED_OK" ]]; then
      echo "Active batch already exists: $ACTIVE_ID ($ACTIVE_STATUS)"
      echo "Refusing to create a new payout batch."
      exit 0
    fi
  fi
  rm -f "$STATE/active_batch"
fi

# Read current epoch, daemon sync state and payout-wallet state from the local Mina daemon.
GQL=$(jq -n --arg pk "$PAYOUT_PUBLIC_KEY" '{
  query:"query($pk: PublicKey!) { syncStatus bestChain(maxLength:1) { protocolState { consensusState { epochCount blockHeight } } } account(publicKey:$pk) { balance { total } nonce inferredNonce } pooledUserCommands(publicKey:$pk) { id } }",
  variables:{pk:$pk}
}')
D=$(curl -fsS "$GRAPHQL_ENDPOINT" -H 'Content-Type: application/json' --data-binary "$GQL")
jq -e '.errors == null' <<<"$D" >/dev/null || { jq '.errors' <<<"$D" >&2; exit 1; }

SYNC=$(jq -r '.data.syncStatus' <<<"$D")
CURRENT_EPOCH=$(jq -r '.data.bestChain[0].protocolState.consensusState.epochCount' <<<"$D")
HEIGHT=$(jq -r '.data.bestChain[0].protocolState.consensusState.blockHeight' <<<"$D")
BALANCE_NM=$(jq -r '.data.account.balance.total // empty' <<<"$D")
NONCE=$(jq -r '.data.account.nonce // empty' <<<"$D")
INFERRED_NONCE=$(jq -r '.data.account.inferredNonce // empty' <<<"$D")
PENDING=$(jq -r '.data.pooledUserCommands | length' <<<"$D")
[[ "$SYNC" == "SYNCED" ]] || { echo "Daemon not synced: $SYNC" >&2; exit 1; }
[[ -n "$BALANCE_NM" ]] || { echo "Payout wallet not found" >&2; exit 1; }
[[ "$BALANCE_NM" =~ ^[0-9]+$ ]] || { echo "Invalid payout wallet balance: $BALANCE_NM" >&2; exit 1; }

if [[ -n "${1:-}" ]]; then
  EPOCH="$1"
  AUTO_EPOCH=0
else
  (( CURRENT_EPOCH > 0 )) || {
    echo "Current epoch is $CURRENT_EPOCH; there is no previous completed epoch yet."
    exit 0
  }
  EPOCH=$((CURRENT_EPOCH - 1))
  AUTO_EPOCH=1
fi
[[ "$EPOCH" =~ ^[0-9]+$ ]] || { echo "Invalid epoch: $EPOCH" >&2; exit 1; }

# Avoid recalculating an epoch that has already been fully processed by the
# automation. This includes epochs with zero remaining payout transactions.
if (( AUTO_EPOCH == 1 )) && [[ -s "$STATE/last_processed_epoch" ]]; then
  LAST_PROCESSED_EPOCH=$(<"$STATE/last_processed_epoch")
  if [[ "$LAST_PROCESSED_EPOCH" =~ ^[0-9]+$ ]] && (( EPOCH <= LAST_PROCESSED_EPOCH )); then
    echo "Epoch $EPOCH already processed; nothing to do."
    exit 0
  fi
fi

# These exports override stale interactive values from .env. No private key is available in this phase.
export POOL_PUBLIC_KEY="$BP_PUBLIC_KEY"
export SEND_PUBLIC_KEY="$PAYOUT_PUBLIC_KEY"
export COMMISSION_RATE="$POOL_COMMISSION"
export O1_COMMISSION_RATE="$O1_COMMISSION"
export POOL_MEMO="${POOL_MEMO_PREFIX}${EPOCH}_payout"
export SEND_PRIVATE_KEY=""

TMP="$STATE/.run-$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT
run_payout() {
  local log=$1; shift
  set +e
  npm run payout -- "$@" 2>&1 | tee "$log"
  local rc=${PIPESTATUS[0]}
  set -e
  return "$rc"
}

# Single dry-run, matching the normal interactive workflow.
# mina-pool-payout determines the currently payable range for the epoch.
# We record that exact range and hash; the later execution will reuse them
# with -m/-x and -h, which protects against any changed calculation.
run_payout "$TMP/simulation.raw.log" -e="$EPOCH" -f="$FORK" || exit $?

HASH=$(awk -F': ' '/PAYOUT HASH:/ {print $2}' "$TMP/simulation.raw.log" | tail -1 | tr -d '\r')
RANGE=$(grep -E 'This script will payout from block [0-9]+ to maximum height [0-9]+' "$TMP/simulation.raw.log" | tail -1)
MIN=$(sed -nE 's/.*block ([0-9]+) to maximum height ([0-9]+).*/\1/p' <<<"$RANGE")
MAX=$(sed -nE 's/.*block ([0-9]+) to maximum height ([0-9]+).*/\2/p' <<<"$RANGE")
EPOCH_RANGE=$(grep -E 'Epoch Minimum Height: [0-9]+ - Epoch Maximum Height: [0-9]+' "$TMP/simulation.raw.log" | tail -1)
EPOCH_MIN=$(sed -nE 's/.*Epoch Minimum Height: ([0-9]+) - Epoch Maximum Height: ([0-9]+).*/\1/p' <<<"$EPOCH_RANGE")
EPOCH_MAX=$(sed -nE 's/.*Epoch Minimum Height: ([0-9]+) - Epoch Maximum Height: ([0-9]+).*/\2/p' <<<"$EPOCH_RANGE")

[[ "$HASH" =~ ^[0-9a-f]{40}$ && "$MIN" =~ ^[0-9]+$ && "$MAX" =~ ^[0-9]+$ ]] || {
  echo "Could not extract payout hash/range" >&2
  exit 1
}

# Always validate that the payout range stays entirely inside the requested epoch.
[[ "$EPOCH_MIN" =~ ^[0-9]+$ && "$EPOCH_MAX" =~ ^[0-9]+$ ]] || {
  echo "Could not extract complete epoch range" >&2
  exit 1
}

# Hard safety boundary: never allow a block outside the requested epoch,
# including when an explicit/manual epoch argument is used.
if (( MIN < EPOCH_MIN || MAX > EPOCH_MAX )); then
  echo "ERROR: payout range $MIN -> $MAX is outside epoch $EPOCH range $EPOCH_MIN -> $EPOCH_MAX" >&2
  echo "No batch created." >&2
  exit 1
fi

# Automatic mode is strictly once per completed epoch.
# Manual mode (prepare-payout.sh <epoch>) may intentionally prepare a partial
# epoch for testing, but it still cannot cross the epoch boundaries above.
if (( AUTO_EPOCH == 1 )); then
  # Do not freeze or fund a partial epoch. Wait until mina-pool-payout says
  # the epoch's final height is payable after MIN_CONFIRMATIONS.
  if (( MAX < EPOCH_MAX )); then
    echo "Epoch $EPOCH is complete but not fully confirmed yet."
    echo "Payable range:          $MIN -> $MAX"
    echo "Epoch full range:       $EPOCH_MIN -> $EPOCH_MAX"
    echo "Waiting for the remaining confirmations; no batch created."
    exit 0
  fi
fi

TX_REL=$(sed -n 's/^writing transactions to //p' "$TMP/simulation.raw.log" | tail -1 | tr -d '\r')
DETAIL_REL=$(sed -n 's/^writing details to //p' "$TMP/simulation.raw.log" | tail -1 | tr -d '\r')
TX="$TX_REL"; [[ "$TX" = /* ]] || TX="$BASE/${TX#./}"
DETAIL="$DETAIL_REL"; [[ -z "$DETAIL" || "$DETAIL" = /* ]] || DETAIL="$BASE/${DETAIL#./}"
jq -e 'type=="array"' "$TX" >/dev/null

read -r COUNT AMOUNT_NM FEES_NM COST_NM AMOUNT FEES COST < <(python3 - "$TX" <<'PY'
import json,sys
from decimal import Decimal
r=json.load(open(sys.argv[1]))
a=sum(int(x['amount']) for x in r); f=sum(int(x['fee']) for x in r); c=a+f
fmt=lambda n:f"{Decimal(n)/Decimal(1_000_000_000):.9f}"
print(len(r),a,f,c,fmt(a),fmt(f),fmt(c))
PY
)
if [[ "$COUNT" == 0 ]]; then
  if (( AUTO_EPOCH == 1 )); then
    printf '%s\n' "$EPOCH" > "$STATE/last_processed_epoch"
  fi
  echo "No payout transaction for epoch $EPOCH"
  exit 0
fi

read -r BALANCE TARGET TOPUP RESERVE RESERVE_NM TARGET_NM TOPUP_NM < <(python3 - "$BALANCE_NM" "$COST_NM" "$PAYOUT_RESERVE_MINA" <<'PY'
import sys
from decimal import Decimal, ROUND_HALF_UP
N=Decimal(1_000_000_000)
balance_nm=int(sys.argv[1])
cost_nm=int(sys.argv[2])
reserve=Decimal(sys.argv[3])
reserve_nm=int((reserve*N).to_integral_value(rounding=ROUND_HALF_UP))
target_nm=reserve_nm+cost_nm
topup_nm=max(0,target_nm-balance_nm)
fmt=lambda n:f"{Decimal(n)/N:.9f}"
print(fmt(balance_nm),fmt(target_nm),fmt(topup_nm),fmt(reserve_nm),reserve_nm,target_nm,topup_nm)
PY
)

STATUS=WAITING_FOR_FUNDING
if [[ "$PENDING" != 0 || "$NONCE" != "$INFERRED_NONCE" ]]; then
  STATUS=BLOCKED_PENDING_TRANSACTION
elif (( BALANCE_NM == TARGET_NM )); then
  STATUS=FUNDED_READY_FOR_EXECUTION
elif (( BALANCE_NM > TARGET_NM )); then
  STATUS=BLOCKED_BALANCE_ABOVE_TARGET
fi

ID="epoch${EPOCH}_${MIN}_${MAX}_${HASH}"
DIR="$STATE/batches/$ID"
mkdir -p "$DIR"
cp "$TMP/simulation.raw.log" "$DIR/"
cp "$TX" "$DIR/payout_transactions.json"
[[ -n "$DETAIL" && -s "$DETAIL" ]] && cp "$DETAIL" "$DIR/payout_details.json"
python3 - "$TMP/simulation.raw.log" "$DIR/simulation.log" <<'PY'
import re,sys
s=open(sys.argv[1],errors='replace').read()
s=re.sub(r'\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])','',s)
open(sys.argv[2],'w').write(s)
PY

jq -n \
  --arg status "$STATUS" --arg epoch "$EPOCH" --arg fork "$FORK" \
  --arg min "$MIN" --arg max "$MAX" --arg epoch_min "${EPOCH_MIN:-}" --arg epoch_max "${EPOCH_MAX:-}" --arg hash "$HASH" \
  --arg bp "$BP_PUBLIC_KEY" --arg wallet "$PAYOUT_PUBLIC_KEY" \
  --arg count "$COUNT" --arg amount "$AMOUNT" --arg fees "$FEES" --arg cost "$COST" \
  --arg reserve "$RESERVE" --arg reserve_nm "$RESERVE_NM" --arg balance "$BALANCE" --arg balance_nm "$BALANCE_NM" \
  --arg target "$TARGET" --arg target_nm "$TARGET_NM" --arg topup "$TOPUP" --arg topup_nm "$TOPUP_NM" \
  --arg cost_nm "$COST_NM" --arg nonce "$NONCE" --arg inferred "$INFERRED_NONCE" --arg pending "$PENDING" \
  --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{status:$status,created_at_utc:$created,epoch:$epoch,fork:$fork,min_height:$min,max_height:$max,
    epoch_min_height:$epoch_min,epoch_max_height:$epoch_max,payout_hash:$hash,
    block_producer:$bp,payout_wallet:$wallet,transaction_count:$count,payout_amount_mina:$amount,
    transaction_fees_mina:$fees,batch_cost_mina:$cost,batch_cost_nanomina:$cost_nm,
    reserve_mina:$reserve,reserve_nanomina:$reserve_nm,
    wallet_balance_mina:$balance,wallet_balance_nanomina:$balance_nm,
    target_before_payout_mina:$target,target_before_payout_nanomina:$target_nm,
    topup_required_mina:$topup,topup_required_nanomina:$topup_nm,
    nonce:$nonce,inferred_nonce:$inferred,pending_transactions:$pending}' > "$DIR/state.json"

printf '%s\n' "$ID" > "$STATE/active_batch"

REPORT="$DIR/report.txt"
cat >"$REPORT" <<EOF_REPORT
Mina Pool Payout - PRE-FUNDING REPORT

Status:                 $STATUS
Epoch / fork:           $EPOCH / $FORK
Frozen block range:     $MIN -> $MAX
Epoch full range:        ${EPOCH_MIN:-unknown} -> ${EPOCH_MAX:-unknown}
Daemon height:          $HEIGHT
Payout hash:            $HASH

Payout wallet:
$PAYOUT_PUBLIC_KEY

Transactions:           $COUNT
Payout amounts:         $AMOUNT MINA
Transaction fees:       $FEES MINA
Batch cost:             $COST MINA
Permanent reserve:      $RESERVE MINA
------------------------------------------------------------
TARGET BEFORE PAYOUT:   $TARGET MINA
CURRENT BALANCE:        $BALANCE MINA
TO FUND NOW:            $TOPUP MINA
------------------------------------------------------------
EXPECTED AFTER PAYOUT:  $RESERVE MINA

Wallet nonce:           $NONCE
Inferred nonce:         $INFERRED_NONCE
Pending transactions:   $PENDING

The batch is frozen. The final execution must use:
  -m=$MIN -x=$MAX -f=$FORK -h=$HASH

If you fund exactly TO FUND NOW and every payout is applied,
the payout wallet must finish at exactly $RESERVE MINA.

================ FULL MINA-POOL-PAYOUT SIMULATION ================

EOF_REPORT
cat "$DIR/simulation.log" >> "$REPORT"

SUBJECT="${MAIL_SUBJECT_PREFIX:-[Mina payout]} epoch $EPOCH - $STATUS - fund $TOPUP MINA"
MARK="$STATE/notified/${ID}.${STATUS}"
if [[ ! -e "$MARK" && -n "${MAIL_TO:-}" ]]; then
  SENDMAIL="${SENDMAIL_BIN:-$(command -v sendmail || true)}"
  if [[ -n "$SENDMAIL" && -x "$SENDMAIL" ]]; then
    BOUNDARY="=_mina_payout_$(date +%s)_$$"
HTML_BODY="$(
  python3 - "$REPORT" <<'PY'
import html
import pathlib
import sys

content = pathlib.Path(sys.argv[1]).read_text(errors="replace")
print(
    '<!doctype html><html><body>'
    '<pre style="font-family: Consolas, Menlo, Monaco, '
    '\'Courier New\', monospace; font-size: 13px; line-height: 1.25; '
    'white-space: pre; margin: 0;">'
    + html.escape(content)
    + '</pre></body></html>'
)
PY
)"
    {
      echo "To: $MAIL_TO"
      [[ -n "${MAIL_FROM:-}" ]] && echo "From: $MAIL_FROM"
      echo "Subject: $SUBJECT"
      echo "MIME-Version: 1.0"
      echo "Content-Type: multipart/alternative; boundary=\"$BOUNDARY\""
      echo
      echo "--$BOUNDARY"
      echo "Content-Type: text/plain; charset=UTF-8"
      echo "Content-Transfer-Encoding: 8bit"
      echo
      cat "$REPORT"
      echo
      echo "--$BOUNDARY"
      echo "Content-Type: text/html; charset=UTF-8"
      echo "Content-Transfer-Encoding: 8bit"
      echo
      printf '%s\n' "$HTML_BODY"
      echo "--$BOUNDARY--"
    } | "$SENDMAIL" -t
    touch "$MARK"
    echo "Email sent to $MAIL_TO"
  else
    echo "No sendmail transport configured; report saved locally."
  fi
fi

echo
echo "Batch:    $ID"
echo "Status:   $STATUS"
echo "Cost:     $COST MINA"
echo "Balance:  $BALANCE MINA"
echo "To fund:  $TOPUP MINA"
echo "Target:   $TARGET MINA"
echo "After:    $RESERVE MINA"
echo "Report:   $REPORT"

