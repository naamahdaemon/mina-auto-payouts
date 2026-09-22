#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="$BASE/auto-payout.conf"
STATE="$BASE/.auto-payout"
source "$CONF"

for c in curl jq python3 npm flock gpg; do
  command -v "$c" >/dev/null || { echo "Missing command: $c" >&2; exit 1; }
done

mkdir -p "$STATE"/{batches,locks,notified}
exec 9>"$STATE/locks/execute.lock"
flock -n 9 || { echo "execute-payout already running"; exit 0; }
cd "$BASE"

send_report() {
  local id=$1 status=$2 subject=$3 body=$4
  [[ -n "${MAIL_TO:-}" ]] || return 0
  local mark="$STATE/notified/${id}.${status}"
  [[ -e "$mark" ]] && return 0

  local sendmail_bin="${SENDMAIL_BIN:-$(command -v sendmail || true)}"
  [[ -n "$sendmail_bin" && -x "$sendmail_bin" ]] || {
    echo "No sendmail transport configured; report saved locally." >&2
    return 0
  }

  local boundary="=_mina_payout_$(date +%s)_$$"
  local html_body
  html_body="$(
    python3 - "$body" <<'PY'
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
    echo "Subject: $subject"
    echo "MIME-Version: 1.0"
    echo "Content-Type: multipart/alternative; boundary=\"$boundary\""
    echo
    echo "--$boundary"
    echo "Content-Type: text/plain; charset=UTF-8"
    echo "Content-Transfer-Encoding: 8bit"
    echo
    cat "$body"
    echo
    echo "--$boundary"
    echo "Content-Type: text/html; charset=UTF-8"
    echo "Content-Transfer-Encoding: 8bit"
    echo
    printf '%s\n' "$html_body"
    echo "--$boundary--"
  } | "$sendmail_bin" -t

  touch "$mark"
}

update_state() {
  local filter=$1
  shift
  local tmp="$DIR/state.json.tmp"
  jq "$@" "$filter" "$DIR/state.json" > "$tmp"
  mv "$tmp" "$DIR/state.json"
}

wallet_state() {
  local gql d
  gql=$(jq -n --arg pk "$PAYOUT_PUBLIC_KEY" '{
    query:"query($pk: PublicKey!) { syncStatus bestChain(maxLength:1) { protocolState { consensusState { epochCount blockHeight } } } account(publicKey:$pk) { balance { total } nonce inferredNonce } pooledUserCommands(publicKey:$pk) { id } }",
    variables:{pk:$pk}
  }')
  d=$(curl -fsS "$GRAPHQL_ENDPOINT" -H 'Content-Type: application/json' --data-binary "$gql")
  jq -e '.errors == null' <<<"$d" >/dev/null || {
    jq '.errors' <<<"$d" >&2
    return 1
  }
  printf '%s' "$d"
}

ID="${1:-}"
if [[ -z "$ID" ]]; then
  [[ -s "$STATE/active_batch" ]] || { echo "No active payout batch."; exit 0; }
  ID=$(<"$STATE/active_batch")
fi

DIR="$STATE/batches/$ID"
STATE_FILE="$DIR/state.json"
[[ -s "$STATE_FILE" ]] || { echo "Missing state file for batch $ID" >&2; exit 1; }

STATUS=$(jq -r '.status' "$STATE_FILE")
EPOCH=$(jq -r '.epoch' "$STATE_FILE")
FORK_STATE=$(jq -r '.fork' "$STATE_FILE")
MIN=$(jq -r '.min_height' "$STATE_FILE")
MAX=$(jq -r '.max_height' "$STATE_FILE")
HASH=$(jq -r '.payout_hash' "$STATE_FILE")
COUNT=$(jq -r '.transaction_count | tonumber' "$STATE_FILE")
COST_NM=$(jq -r '.batch_cost_nanomina // empty' "$STATE_FILE")
RESERVE_NM=$(jq -r '.reserve_nanomina // empty' "$STATE_FILE")
TARGET_NM=$(jq -r '.target_before_payout_nanomina // empty' "$STATE_FILE")
STATE_BP=$(jq -r '.block_producer' "$STATE_FILE")
STATE_WALLET=$(jq -r '.payout_wallet' "$STATE_FILE")

[[ "$STATE_BP" == "$BP_PUBLIC_KEY" ]] || { echo "Block producer mismatch" >&2; exit 1; }
[[ "$STATE_WALLET" == "$PAYOUT_PUBLIC_KEY" ]] || { echo "Payout wallet mismatch" >&2; exit 1; }
[[ "$FORK_STATE" == "$FORK" ]] || { echo "Fork mismatch" >&2; exit 1; }
[[ "$HASH" =~ ^[0-9a-f]{40}$ ]] || { echo "Invalid payout hash" >&2; exit 1; }
[[ "$MIN" =~ ^[0-9]+$ && "$MAX" =~ ^[0-9]+$ ]] || { echo "Invalid frozen block range" >&2; exit 1; }
[[ "$COUNT" =~ ^[0-9]+$ && "$COUNT" -gt 0 ]] || { echo "Invalid transaction count" >&2; exit 1; }
[[ "$COST_NM" =~ ^[0-9]+$ && "$RESERVE_NM" =~ ^[0-9]+$ && "$TARGET_NM" =~ ^[0-9]+$ ]] || {
  echo "This batch was created by an older prepare-payout version. Recreate the dry-run batch before automatic execution." >&2
  exit 1
}

# A signed attempt is never repeated automatically. Error recovery is resend-only.
case "$STATUS" in
  COMPLETED_OK)
    echo "Batch already completed: $ID"
    exit 0
    ;;
  MANUAL_INTERVENTION_REQUIRED|HASH_MISMATCH|SIGNED_ATTEMPT_UNKNOWN)
    echo "Batch blocked for manual intervention: $ID ($STATUS)"
    exit 0
    ;;
esac

D=$(wallet_state)
SYNC=$(jq -r '.data.syncStatus' <<<"$D")
HEIGHT=$(jq -r '.data.bestChain[0].protocolState.consensusState.blockHeight' <<<"$D")
BALANCE_NM=$(jq -r '.data.account.balance.total // empty' <<<"$D")
NONCE=$(jq -r '.data.account.nonce // empty' <<<"$D")
INFERRED=$(jq -r '.data.account.inferredNonce // empty' <<<"$D")
PENDING=$(jq -r '.data.pooledUserCommands | length' <<<"$D")

[[ "$SYNC" == "SYNCED" ]] || { echo "Daemon not synced: $SYNC" >&2; exit 1; }
[[ "$BALANCE_NM" =~ ^[0-9]+$ && "$NONCE" =~ ^[0-9]+$ && "$INFERRED" =~ ^[0-9]+$ ]] || {
  echo "Invalid wallet state returned by GraphQL" >&2
  exit 1
}

fmt_nm() {
  python3 - "$1" <<'PY'
from decimal import Decimal
import sys
print(f"{Decimal(sys.argv[1])/Decimal(1_000_000_000):.9f}")
PY
}

BALANCE=$(fmt_nm "$BALANCE_NM")
TARGET=$(fmt_nm "$TARGET_NM")
RESERVE=$(fmt_nm "$RESERVE_NM")

# Confirmation phase after a signed attempt: NEVER execute payout again.
if [[ "$STATUS" == "SUBMITTED_WAITING_CONFIRMATION" ]]; then
  START_NONCE=$(jq -r '.execution.start_nonce | tonumber' "$STATE_FILE")
  EXPECTED_NEXT=$(jq -r '.execution.expected_next_nonce | tonumber' "$STATE_FILE")
  LAST_NONCE=$((EXPECTED_NEXT-1))

  if (( NONCE >= EXPECTED_NEXT )) && (( PENDING == 0 )); then
    if (( BALANCE_NM == RESERVE_NM )); then
      update_state '.status="COMPLETED_OK"
        | .completed_at_utc=$now
        | .final.wallet_balance_nanomina=$balance_nm
        | .final.wallet_balance_mina=$balance
        | .final.nonce=$nonce
        | .final.inferred_nonce=$inferred
        | .final.pending_transactions=$pending
        | .final.block_height=$height' \
        --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg balance_nm "$BALANCE_NM" --arg balance "$BALANCE" \
        --arg nonce "$NONCE" --arg inferred "$INFERRED" --arg pending "$PENDING" --arg height "$HEIGHT"

      REPORT="$DIR/completed-report.txt"
      cat > "$REPORT" <<EOF
Mina Pool Payout - COMPLETED OK

Batch:                   $ID
Epoch / fork:            $EPOCH / $FORK_STATE
Frozen block range:      $MIN -> $MAX
Payout hash:             $HASH
Transactions:            $COUNT

Final wallet balance:    $BALANCE MINA
Expected reserve:        $RESERVE MINA
Final nonce:             $NONCE
Expected next nonce:     $EXPECTED_NEXT
Pending transactions:    $PENDING
Daemon height:           $HEIGHT

RESULT: COMPLETED_OK

All expected outgoing nonces have been consumed and the payout wallet
returned exactly to the permanent reserve.
EOF
      send_report "$ID" "COMPLETED_OK" "${MAIL_SUBJECT_PREFIX:-[Mina payout]} epoch $EPOCH - COMPLETED OK" "$REPORT"
      printf '%s\n' "$EPOCH" > "$STATE/last_processed_epoch"
      rm -f "$STATE/active_batch"
      echo "COMPLETED_OK: $ID"
      exit 0
    else
      update_state '.status="MANUAL_INTERVENTION_REQUIRED"
        | .error.type="FINAL_BALANCE_MISMATCH"
        | .error.detected_at_utc=$now
        | .error.final_balance_nanomina=$balance_nm
        | .error.final_balance_mina=$balance
        | .error.expected_reserve_nanomina=$reserve_nm
        | .error.expected_reserve_mina=$reserve' \
        --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg balance_nm "$BALANCE_NM" --arg balance "$BALANCE" \
        --arg reserve_nm "$RESERVE_NM" --arg reserve "$RESERVE"

      REPORT="$DIR/manual-intervention-report.txt"
      cat > "$REPORT" <<EOF
Mina Pool Payout - MANUAL INTERVENTION REQUIRED

Batch:                   $ID
Epoch / fork:            $EPOCH / $FORK_STATE
Frozen block range:      $MIN -> $MAX
Payout hash:             $HASH

All expected nonces appear consumed, but the final wallet balance is wrong.

Expected final balance:  $RESERVE MINA
Observed final balance:  $BALANCE MINA
Final nonce:             $NONCE
Pending transactions:    $PENDING

IMPORTANT:
.paidblocks MUST remain untouched.
DO NOT run the payout again automatically.
Investigate the transactions manually.
EOF
      send_report "$ID" "MANUAL_INTERVENTION_REQUIRED" "${MAIL_SUBJECT_PREFIX:-[Mina payout]} epoch $EPOCH - ERROR final balance" "$REPORT"
      echo "MANUAL_INTERVENTION_REQUIRED: final balance mismatch"
      exit 2
    fi
  fi

  # If the chain has stopped before the expected nonce and nothing remains in the pool,
  # recovery must be performed via resend, never by running payout again.
  if (( PENDING == 0 )) && (( NONCE < EXPECTED_NEXT )); then
    NEXT_MISSING="$NONCE"
    update_state '.status="MANUAL_INTERVENTION_REQUIRED"
      | .error.type="NONCE_GAP_AFTER_SUBMISSION"
      | .error.detected_at_utc=$now
      | .error.next_missing_nonce=$next
      | .error.last_expected_nonce=$last' \
      --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg next "$NEXT_MISSING" --arg last "$LAST_NONCE"

    REPORT="$DIR/manual-intervention-report.txt"
    cat > "$REPORT" <<EOF
Mina Pool Payout - MANUAL INTERVENTION REQUIRED

Batch:                   $ID
Epoch / fork:            $EPOCH / $FORK_STATE
Frozen block range:      $MIN -> $MAX
Payout hash:             $HASH

Current account nonce:   $NONCE
Expected next nonce:     $EXPECTED_NEXT
Pending transactions:    $PENDING

The payout was already signed/engaged and .paidblocks must remain intact.
DO NOT execute the payout again.

First nonce not confirmed: $NEXT_MISSING
Last payout nonce:          $LAST_NONCE

Manual recovery command:
  npm run resend -- -f=$NEXT_MISSING -t=$LAST_NONCE
EOF
    send_report "$ID" "MANUAL_INTERVENTION_REQUIRED" "${MAIL_SUBJECT_PREFIX:-[Mina payout]} epoch $EPOCH - RESEND REQUIRED" "$REPORT"
    echo "MANUAL_INTERVENTION_REQUIRED: resend $NEXT_MISSING..$LAST_NONCE"
    exit 2
  fi

  echo "Waiting for confirmation: nonce $NONCE/$EXPECTED_NEXT, pending=$PENDING, balance=$BALANCE MINA"
  exit 0
fi

# Before the signed attempt there must be no pending transaction from this wallet.
if (( PENDING != 0 )) || [[ "$NONCE" != "$INFERRED" ]]; then
  update_state '.status="BLOCKED_PENDING_TRANSACTION"
    | .last_check_at_utc=$now
    | .wallet_balance_nanomina=$balance_nm
    | .wallet_balance_mina=$balance
    | .nonce=$nonce | .inferred_nonce=$inferred | .pending_transactions=$pending' \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg balance_nm "$BALANCE_NM" --arg balance "$BALANCE" \
    --arg nonce "$NONCE" --arg inferred "$INFERRED" --arg pending "$PENDING"
  echo "Blocked: payout wallet has pending transactions (nonce=$NONCE inferred=$INFERRED pending=$PENDING)"
  exit 0
fi

if (( BALANCE_NM < TARGET_NM )); then
  TOPUP_NM=$((TARGET_NM-BALANCE_NM))
  TOPUP=$(fmt_nm "$TOPUP_NM")
  update_state '.status="WAITING_FOR_FUNDING"
    | .last_check_at_utc=$now
    | .wallet_balance_nanomina=$balance_nm
    | .wallet_balance_mina=$balance
    | .topup_required_nanomina=$topup_nm
    | .topup_required_mina=$topup' \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg balance_nm "$BALANCE_NM" --arg balance "$BALANCE" \
    --arg topup_nm "$TOPUP_NM" --arg topup "$TOPUP"

  send_report \
    "$ID" \
    "WAITING_FOR_FUNDING" \
    "${MAIL_SUBJECT_PREFIX:-[Mina payout]} epoch $EPOCH - WAITING_FOR_FUNDING - fund $TOPUP MINA" \
    "$DIR/report.txt"

  echo "Waiting for funding: $TOPUP MINA still required."
  exit 0
fi

if (( BALANCE_NM > TARGET_NM )); then
  EXCESS_NM=$((BALANCE_NM-TARGET_NM))
  EXCESS=$(fmt_nm "$EXCESS_NM")
  update_state '.status="BLOCKED_BALANCE_ABOVE_TARGET"
    | .last_check_at_utc=$now
    | .wallet_balance_nanomina=$balance_nm
    | .wallet_balance_mina=$balance
    | .error.type="BALANCE_ABOVE_TARGET"
    | .error.excess_nanomina=$excess_nm
    | .error.excess_mina=$excess' \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg balance_nm "$BALANCE_NM" --arg balance "$BALANCE" \
    --arg excess_nm "$EXCESS_NM" --arg excess "$EXCESS"

  REPORT="$DIR/balance-above-target-report.txt"
  cat > "$REPORT" <<EOF
Mina Pool Payout - EXECUTION BLOCKED

Batch:                  $ID
Payout hash:            $HASH

Expected wallet target: $TARGET MINA
Observed balance:       $BALANCE MINA
Excess:                 $EXCESS MINA

Execution is intentionally blocked because the wallet was not funded to
the exact expected target. No private key was decrypted and no payout was sent.
EOF
  send_report "$ID" "BLOCKED_BALANCE_ABOVE_TARGET" "${MAIL_SUBJECT_PREFIX:-[Mina payout]} epoch $EPOCH - BLOCKED balance above target" "$REPORT"
  echo "Blocked: wallet balance is $EXCESS MINA above exact target."
  exit 0
fi

# Exact target reached. From this point onward a signed attempt must never be automatically repeated.
START_NONCE="$INFERRED"
EXPECTED_NEXT=$((START_NONCE+COUNT))
LAST_NONCE=$((EXPECTED_NEXT-1))

# Refuse to start if nonce artefacts already exist. They may belong to unresolved manual recovery.
for ((n=START_NONCE; n<=LAST_NONCE; n++)); do
  if [[ -e "$BASE/src/data/$n.gql" || -e "$BASE/src/data/$n.json" ]]; then
    update_state '.status="MANUAL_INTERVENTION_REQUIRED"
      | .error.type="PREEXISTING_NONCE_ARTIFACT"
      | .error.detected_at_utc=$now
      | .error.nonce=$nonce' \
      --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg nonce "$n"
    echo "Refusing signed payout: existing src/data/$n.gql or .json"
    exit 2
  fi
done

TMP="$STATE/.execute-$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p "$TMP"
trap 'unset SEND_PRIVATE_KEY PRIVATE_KEY 2>/dev/null || true; rm -rf "$TMP"' EXIT

# Only now touch the encrypted private key. pinentry-mode=error guarantees no interactive prompt.
set +e
PRIVATE_KEY=$(gpg --batch --pinentry-mode error --decrypt "$BASE/encrypted_key.gpg" 2>"$TMP/gpg.err")
GPG_RC=$?
set -e
if (( GPG_RC != 0 )) || [[ -z "$PRIVATE_KEY" ]]; then
  update_state '.status="BLOCKED_GPG_LOCKED"
    | .last_check_at_utc=$now
    | .error.type="GPG_KEY_NOT_AVAILABLE"' \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  REPORT="$DIR/gpg-locked-report.txt"
  cat > "$REPORT" <<EOF
Mina Pool Payout - EXECUTION BLOCKED

Batch: $ID

The payout wallet is funded exactly to target, but the encrypted Mina
private key could not be decrypted non-interactively.

No signed payout was attempted.
Unlock encrypted_key.gpg manually to refresh the gpg-agent cache.
EOF
  send_report "$ID" "BLOCKED_GPG_LOCKED" "${MAIL_SUBJECT_PREFIX:-[Mina payout]} epoch $EPOCH - GPG key locked" "$REPORT"
  echo "Blocked: GPG key is not available in agent cache."
  exit 0
fi

export POOL_PUBLIC_KEY="$BP_PUBLIC_KEY"
export SEND_PUBLIC_KEY="$PAYOUT_PUBLIC_KEY"
export COMMISSION_RATE="$POOL_COMMISSION"
export O1_COMMISSION_RATE="$O1_COMMISSION"
export POOL_MEMO="${POOL_MEMO_PREFIX}${EPOCH}_payout"
export SEND_PRIVATE_KEY="$PRIVATE_KEY"
unset PRIVATE_KEY

# Mark SIGNED_ATTEMPT_STARTED BEFORE calling npm. A crash from here on can never trigger an automatic retry.
update_state '.status="SIGNED_ATTEMPT_STARTED"
  | .execution.started_at_utc=$now
  | .execution.start_nonce=$start
  | .execution.expected_next_nonce=$next
  | .execution.last_nonce=$last
  | .execution.balance_before_nanomina=$balance_nm
  | .execution.balance_before_mina=$balance
  | .execution.command=$command' \
  --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg start "$START_NONCE" --arg next "$EXPECTED_NEXT" --arg last "$LAST_NONCE" \
  --arg balance_nm "$BALANCE_NM" --arg balance "$BALANCE" \
  --arg command "npm run payout -- -m=$MIN -x=$MAX -f=$FORK_STATE -h=$HASH"

set +e
npm run payout -- -m="$MIN" -x="$MAX" -f="$FORK_STATE" -h="$HASH" 2>&1 | tee "$DIR/execution.log"
RC=${PIPESTATUS[0]}
set -e
unset SEND_PRIVATE_KEY

FAILED_NONCE=$(sed -nE 's/.*STOPPED SENDING AT NONCE ([0-9]+).*/\1/p' "$DIR/execution.log" | tail -1)
HASH_MISMATCH=0
grep -q "HASHES DON'T MATCH" "$DIR/execution.log" && HASH_MISMATCH=1

if (( HASH_MISMATCH == 1 )); then
  update_state '.status="HASH_MISMATCH"
    | .error.type="HASH_MISMATCH"
    | .error.detected_at_utc=$now
    | .execution.exit_code=$rc' \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson rc "$RC"

  REPORT="$DIR/hash-mismatch-report.txt"
  {
    echo "Mina Pool Payout - HASH MISMATCH"
    echo
    echo "Batch: $ID"
    echo "Expected payout hash: $HASH"
    echo
    echo "No automatic retry will be performed."
    echo "Inspect execution.log manually."
    echo
    cat "$DIR/execution.log"
  } > "$REPORT"
  send_report "$ID" "HASH_MISMATCH" "${MAIL_SUBJECT_PREFIX:-[Mina payout]} epoch $EPOCH - HASH MISMATCH" "$REPORT"
  echo "HASH_MISMATCH: automatic execution permanently blocked for this batch."
  exit 2
fi

if [[ -n "$FAILED_NONCE" ]]; then
  update_state '.status="MANUAL_INTERVENTION_REQUIRED"
    | .error.type="TRANSMISSION_ERROR"
    | .error.detected_at_utc=$now
    | .error.failed_nonce=$failed
    | .error.last_expected_nonce=$last
    | .execution.exit_code=$rc' \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg failed "$FAILED_NONCE" --arg last "$LAST_NONCE" --argjson rc "$RC"

  REPORT="$DIR/manual-intervention-report.txt"
  cat > "$REPORT" <<EOF
Mina Pool Payout - MANUAL INTERVENTION REQUIRED

Batch:                   $ID
Epoch / fork:            $EPOCH / $FORK_STATE
Frozen block range:      $MIN -> $MAX
Payout hash:             $HASH

Transmission stopped at nonce: $FAILED_NONCE
Last payout nonce:              $LAST_NONCE

IMPORTANT:
The signed payout has already been engaged.
.paidblocks MUST remain untouched.
DO NOT run payout again.

Use the generated .gql files and resend manually:

  npm run resend -- -f=$FAILED_NONCE -t=$LAST_NONCE

Full execution log:
================================================================
EOF
  cat "$DIR/execution.log" >> "$REPORT"
  send_report "$ID" "MANUAL_INTERVENTION_REQUIRED" "${MAIL_SUBJECT_PREFIX:-[Mina payout]} epoch $EPOCH - SEND ERROR / RESEND REQUIRED" "$REPORT"
  echo "MANUAL_INTERVENTION_REQUIRED: resend $FAILED_NONCE..$LAST_NONCE"
  exit 2
fi

if (( RC != 0 )); then
  update_state '.status="SIGNED_ATTEMPT_UNKNOWN"
    | .error.type="NONZERO_EXIT_AFTER_SIGNED_ATTEMPT"
    | .error.detected_at_utc=$now
    | .execution.exit_code=$rc' \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson rc "$RC"

  REPORT="$DIR/signed-attempt-unknown-report.txt"
  {
    echo "Mina Pool Payout - SIGNED ATTEMPT STATUS UNKNOWN"
    echo
    echo "Batch: $ID"
    echo "Exit code: $RC"
    echo
    echo ".paidblocks MUST remain untouched."
    echo "DO NOT run payout again."
    echo "Inspect execution.log and nonce .gql/.json files manually."
    echo
    cat "$DIR/execution.log"
  } > "$REPORT"
  send_report "$ID" "SIGNED_ATTEMPT_UNKNOWN" "${MAIL_SUBJECT_PREFIX:-[Mina payout]} epoch $EPOCH - SIGNED ATTEMPT UNKNOWN" "$REPORT"
  echo "SIGNED_ATTEMPT_UNKNOWN: no automatic retry."
  exit 2
fi

# Verify that the signer generated every expected .gql and every broadcast returned a .json.
MISSING=""
for ((n=START_NONCE; n<=LAST_NONCE; n++)); do
  [[ -s "$BASE/src/data/$n.gql" ]] || MISSING+=" $n.gql"
  [[ -s "$BASE/src/data/$n.json" ]] || MISSING+=" $n.json"
done

if [[ -n "$MISSING" ]]; then
  update_state '.status="MANUAL_INTERVENTION_REQUIRED"
    | .error.type="MISSING_SEND_ARTIFACTS"
    | .error.detected_at_utc=$now
    | .error.missing=$missing' \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg missing "$MISSING"

  REPORT="$DIR/manual-intervention-report.txt"
  cat > "$REPORT" <<EOF
Mina Pool Payout - MANUAL INTERVENTION REQUIRED

Batch: $ID

The signed payout command returned without its standard transmission-error
marker, but one or more expected nonce artefacts are missing:

$MISSING

.paidblocks MUST remain untouched.
DO NOT run payout again.
Inspect execution.log and use resend for the missing nonce range as needed.
EOF
  send_report "$ID" "MANUAL_INTERVENTION_REQUIRED" "${MAIL_SUBJECT_PREFIX:-[Mina payout]} epoch $EPOCH - missing send artefacts" "$REPORT"
  echo "MANUAL_INTERVENTION_REQUIRED: missing send artefacts."
  exit 2
fi

update_state '.status="SUBMITTED_WAITING_CONFIRMATION"
  | .submitted_at_utc=$now
  | .execution.exit_code=0' \
  --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

REPORT="$DIR/submitted-report.txt"
cat > "$REPORT" <<EOF
Mina Pool Payout - SUBMITTED

Batch:                   $ID
Epoch / fork:            $EPOCH / $FORK_STATE
Frozen block range:      $MIN -> $MAX
Payout hash:             $HASH
Transactions:            $COUNT
Nonce range:             $START_NONCE -> $LAST_NONCE

All expected .gql and GraphQL response .json files were generated.
The batch will NOT be executed again.

The automation will now only monitor chain confirmation and the final
wallet reserve of exactly $RESERVE MINA.
EOF
send_report "$ID" "SUBMITTED_WAITING_CONFIRMATION" "${MAIL_SUBJECT_PREFIX:-[Mina payout]} epoch $EPOCH - submitted, awaiting confirmation" "$REPORT"

echo "SUBMITTED_WAITING_CONFIRMATION: $ID"

