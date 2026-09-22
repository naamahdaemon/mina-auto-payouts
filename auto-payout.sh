#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="$BASE/.auto-payout"
mkdir -p "$STATE/locks"

exec 9>"$STATE/locks/auto.lock"
flock -n 9 || { echo "auto-payout already running"; exit 0; }

cd "$BASE"

if [[ -s "$STATE/active_batch" ]]; then
  ID=$(<"$STATE/active_batch")
  STATE_FILE="$STATE/batches/$ID/state.json"

  if [[ ! -s "$STATE_FILE" ]]; then
    echo "Active batch pointer is invalid: $ID" >&2
    exit 1
  fi

  STATUS=$(jq -r '.status // "UNKNOWN"' "$STATE_FILE")

  case "$STATUS" in
    COMPLETED_OK)
      rm -f "$STATE/active_batch"
      "$BASE/prepare-payout.sh"
      ;;
    MANUAL_INTERVENTION_REQUIRED|HASH_MISMATCH|SIGNED_ATTEMPT_UNKNOWN)
      echo "Automation blocked by active batch $ID ($STATUS). Manual intervention required."
      exit 0
      ;;
    SIGNED_ATTEMPT_STARTED)
      # A crash occurred after the irreversible boundary. Never retry payout.
      TMP="$STATE_FILE.tmp"
      jq '.status="SIGNED_ATTEMPT_UNKNOWN"
          | .error.type="INTERRUPTED_AFTER_SIGNED_ATTEMPT_STARTED"
          | .error.detected_at_utc=(now|todateiso8601)' "$STATE_FILE" > "$TMP"
      mv "$TMP" "$STATE_FILE"
      echo "Batch $ID was interrupted after signed attempt started. Automatic retry disabled." >&2
      exit 2
      ;;
    *)
      "$BASE/execute-payout.sh" "$ID"
      ;;
  esac
else
  "$BASE/prepare-payout.sh"
fi

