# Quick setup — from first launch to first payout

**7 steps, then one action per epoch: fund the wallet with the amount shown in the email.** Illustrative example: 100 MINA in payouts, 0.010 MINA in fees, and a 1 MINA reserve. Replace the `B62***…` addresses and email addresses below with your own.

```text
Epoch completed → email: "fund 100.010000000 MINA"
                → you fund the wallet
                → automatic submission → email: "COMPLETED OK"
```

## 1. Start with a working Mina Pool Payout engine

This quick guide assumes a synced daemon, Node/npm, and an existing `mina-pool-payout` installation with its `.env` configuration and `.paidblocks` history. For a fresh installation, complete sections 5–10 of the [README](README.md) first. The reference engine is version 1.7.4, commit `12ebcce`.

```bash
cd "$HOME/mina-scripts/payouts/mina-pool-payout"
npm run payout -- --help
ps -p 1 -o comm=
# Expected: engine help, then systemd

sudo apt update
sudo apt install curl jq python3 util-linux gnupg pinentry-curses \
  msmtp msmtp-mta ca-certificates git
```

On WSL2, if `ps -p 1 -o comm=` does not print `systemd`, follow section 6 of the README. Automation runs only while Linux/WSL and the daemon are running.

```bash
curl -fsS http://127.0.0.1:3085/graphql \
  -H 'Content-Type: application/json' \
  --data '{"query":"{ syncStatus }"}' | jq -r '.data.syncStatus'
# Expected: SYNCED
```

## 2. Install and configure the wrapper

For a first installation, download the wrapper and copy its three scripts into the engine directory. If you have already cloned the wrapper, start at `cd`. To upgrade an existing automation setup, follow section 39 of the README.

```bash
git clone https://github.com/naamahdaemon/mina-auto-payouts.git "$HOME/mina-auto-payouts"
cd "$HOME/mina-auto-payouts"
cp auto-payout.sh prepare-payout.sh execute-payout.sh \
  "$HOME/mina-scripts/payouts/mina-pool-payout/"
cd "$HOME/mina-scripts/payouts/mina-pool-payout"
cp -n "$HOME/mina-auto-payouts/auto-payout.conf.example" auto-payout.conf
chmod 700 auto-payout.sh prepare-payout.sh execute-payout.sh
chmod 600 auto-payout.conf
nano auto-payout.conf
```

Example configuration: replace both Mina addresses, the email addresses, and the fork; use your actual commission rates. The rates below are illustrative only. Use a dedicated wallet that already exists on-chain and whose private key you control; in this example, its starting balance is 1 MINA.

```bash
BP_PUBLIC_KEY="B62***YOUR_BLOCK_PRODUCER"
PAYOUT_PUBLIC_KEY="B62***YOUR_PAYOUT_WALLET"
FORK="<YOUR_CURRENT_FORK>"
POOL_COMMISSION="0.05"
O1_COMMISSION="0.08"
POOL_MEMO_PREFIX="MyPool_"
PAYOUT_RESERVE_MINA="1"
GRAPHQL_ENDPOINT="http://127.0.0.1:3085/graphql"
MAIL_TO="you@example.com"
MAIL_FROM="your.account@gmail.com"
MAIL_SUBJECT_PREFIX="[Mina payout]"
SENDMAIL_BIN="/usr/sbin/sendmail"
```

Check these settings in the engine's `.env`, keeping your other pool settings. The wrapper supplies the private key only when executing the payout.

```bash
nano .env
```

```dotenv
SEND_PRIVATE_KEY=
SEND_TRANSACTION_FEE=0.001
MIN_CONFIRMATIONS=50
DO_NOT_SAVE_TRANSACTION_DETAILS=FALSE
SEND_PAYMENT_GRAPHQL_ENDPOINT=http://127.0.0.1:3085/graphql
```

## 3. Prepare the payout wallet key

Encrypt the **payout wallet** private key using a GPG passphrase. The filename must be `encrypted_key.gpg`. If this file already exists for the correct wallet, skip encryption and proceed to unlocking; do not overwrite it.

```bash
cd "$HOME/mina-scripts/payouts/mina-pool-payout"
read -s -r -p 'Payout wallet private key: ' PRIVATE_KEY
echo
printf '%s' "$PRIVATE_KEY" | gpg --symmetric --cipher-algo AES256 \
  --output encrypted_key.gpg
unset PRIVATE_KEY
chmod 600 encrypted_key.gpg
```

Configure the GPG cache by adding these lines to `~/.gnupg/gpg-agent.conf` (or adjusting existing values). This keeps the passphrase available across timer runs.

```bash
mkdir -p "$HOME/.gnupg"
chmod 700 "$HOME/.gnupg"
nano "$HOME/.gnupg/gpg-agent.conf"
```

```text
default-cache-ttl 86400
max-cache-ttl 2592000
pinentry-program /usr/bin/pinentry-curses
```

Unlock the key, then check that it can be accessed without an interactive prompt. After a reboot or cache expiration, unlock it again: the wrapper will wait until you do.

```bash
gpgconf --kill gpg-agent
export GPG_TTY=$(tty)
gpg --decrypt encrypted_key.gpg >/dev/null
gpg --batch --pinentry-mode error --decrypt encrypted_key.gpg >/dev/null \
  && echo 'GPG OK'
# Expected: GPG OK
```

## 4. Set up and test email notifications

Gmail example: use a Google App Password for the sending account (see section 13 of the README). Create the file with private permissions before entering that password.

```bash
(umask 077; touch "$HOME/.msmtprc")
chmod 600 "$HOME/.msmtprc"
nano "$HOME/.msmtprc"
```

```ini
defaults
auth on
tls on
tls_starttls on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
timeout 30

account gmail
host smtp.gmail.com
port 587
from your.account@gmail.com
user your.account@gmail.com
password YOUR_GOOGLE_APP_PASSWORD

account default : gmail
```

Send a test email to the address configured in `MAIL_TO`. Continue once it arrives; check your spam folder too.

```bash
printf 'Subject: Mina payouts test\n\nNotifications are working.\n' \
  | timeout 20s sendmail you@example.com
```

```text
Subject: Mina payouts test
Notifications are working.
```

## 5. Start automatic monitoring

Install the service and timer. The supplied service works with globally installed Node/npm; the NVM variant is shown below. The timer checks payout state every 10 minutes.

```bash
mkdir -p "$HOME/.config/systemd/user"
cp "$HOME/mina-auto-payouts/mina-auto-payout.service" \
   "$HOME/mina-auto-payouts/mina-auto-payout.timer" \
   "$HOME/.config/systemd/user/"
command -v npm
```

If the output contains `.nvm`, replace the service contents with the following variant. Otherwise, keep the supplied file.

```bash
nano "$HOME/.config/systemd/user/mina-auto-payout.service"
```

```ini
[Unit]
Description=Mina automatic payout orchestrator

[Service]
Type=oneshot
WorkingDirectory=%h/mina-scripts/payouts/mina-pool-payout
Environment=GNUPGHOME=%h/.gnupg
ExecStart=/bin/bash -lc 'source "$HOME/.nvm/nvm.sh" && nvm use default >/dev/null && exec "$HOME/mina-scripts/payouts/mina-pool-payout/auto-payout.sh"'
StandardOutput=journal
StandardError=journal
```

Test GPG in the systemd context, then start the service and enable the timer. **Once started, the automation may execute an exactly funded batch.** Do not run manual payouts concurrently from this wallet.

```bash
systemd-run --user --wait --pipe /bin/bash -lc \
  'gpg --batch --pinentry-mode error --decrypt "$HOME/mina-scripts/payouts/mina-pool-payout/encrypted_key.gpg" >/dev/null'
# Expected: exit code 0; otherwise return to step 3.

sudo loginctl enable-linger "$USER"
systemctl --user daemon-reload
systemctl --user start mina-auto-payout.service
journalctl --user -u mina-auto-payout.service -n 30 --no-pager
# Resolve any errors before continuing.
systemctl --user enable --now mina-auto-payout.timer
systemctl --user list-timers mina-auto-payout.timer
# Expected: a scheduled next run.
```

If the epoch is not fully payable yet, the wrapper waits and does not request funding. Example output for an illustrative epoch:

```text
Epoch 80 is complete but not fully confirmed yet.
```

## 6. Receive the email and fund the wallet

Once the epoch is payable, you receive a report. This **illustrative excerpt** uses the same fields as the actual email: 10 transactions total 100 MINA, with 0.010 MINA in fees; the wallet already holds its 1 MINA reserve.

```text
Subject: [Mina payout] epoch 80 - WAITING_FOR_FUNDING - fund 100.010000000 MINA

Mina Pool Payout - PRE-FUNDING REPORT
Status:                 WAITING_FOR_FUNDING
Payout wallet:
B62***YOUR_PAYOUT_WALLET

Transactions:           10
Payout amounts:         100.000000000 MINA
Transaction fees:       0.010000000 MINA
Batch cost:             100.010000000 MINA
Permanent reserve:      1.000000000 MINA
------------------------------------------------------------
TARGET BEFORE PAYOUT:   101.010000000 MINA
CURRENT BALANCE:        1.000000000 MINA
TO FUND NOW:            100.010000000 MINA
------------------------------------------------------------
EXPECTED AFTER PAYOUT:  1.000000000 MINA
```

From your usual wallet, **transfer the `TO FUND NOW` amount** to the address in the report. The amount received must be exact; pay the funding transfer fee separately from the sending wallet. Use the latest report and check that no other transfer has changed the balance since it was calculated.

```text
In your wallet app → Send
Recipient : full payout wallet address shown in the email
Amount    : 100.010000000 MINA
Fee       : paid separately by the sending wallet

Payout wallet balance after receipt:
1.000000000 + 100.010000000 = 101.010000000 MINA
```

No submission command is needed: on the next run, the wrapper checks the balance, GPG, and the other conditions, then submits the transactions. View its messages with:

```bash
journalctl --user -u mina-auto-payout.service -n 30 --no-pager
```

```text
SUBMITTED_WAITING_CONFIRMATION: epoch80_...
```

## 7. Receive confirmation and leave it running

After submission, an email announces that confirmation is pending. Once the nonce, pending transaction, and final balance checks pass, another email announces success. Illustrative excerpts:

```text
Subject: [Mina payout] epoch 80 - submitted, awaiting confirmation
Mina Pool Payout - SUBMITTED
Transactions:            10
The batch will NOT be executed again.
```

```text
Subject: [Mina payout] epoch 80 - COMPLETED OK
Mina Pool Payout - COMPLETED OK
Transactions:            10
Final wallet balance:    1.000000000 MINA
Expected reserve:        1.000000000 MINA
Pending transactions:    0
RESULT: COMPLETED_OK
```

The wallet keeps its reserve and the wrapper waits for the next epoch. Check the completed epoch and the next scheduled run with:

```bash
cd "$HOME/mina-scripts/payouts/mina-pool-payout"
cat .auto-payout/last_processed_epoch
# In this example: 80
systemctl --user list-timers mina-auto-payout.timer
```

If you receive `GPG key locked`, unlock the key and let the timer resume. For `RESEND REQUIRED`, an excessive balance, or another anomaly, stop the timer and follow sections 26–29 of the README: do not delete `.paidblocks` or rerun a batch that has already been signed.

```bash
# GPG locked:
gpg --decrypt "$HOME/mina-scripts/payouts/mina-pool-payout/encrypted_key.gpg" >/dev/null

# Other anomaly: stop future timer runs and inspect the logs.
# This does not interrupt a service that is already running.
systemctl --user stop mina-auto-payout.timer
journalctl --user -u mina-auto-payout.service -n 100 --no-pager
```
