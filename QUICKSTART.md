# Quick setup — du premier lancement au premier payout

**7 étapes, puis une seule action par epoch : alimenter le wallet au montant indiqué dans le mail.** Exemple fictif : 100 MINA de payouts, 0,010 MINA de frais, 1 MINA de réserve. Les adresses `B62***…` et les adresses mail ci-dessous sont à remplacer.

```text
Epoch terminée → mail « fund 100.010000000 MINA »
              → tu alimentes le wallet
              → envoi automatique → mail « COMPLETED OK »
```

## 1. Partir d'un moteur Mina Pool Payout opérationnel

Ce raccourci suppose un daemon synchronisé, Node/npm et un `mina-pool-payout` déjà configuré avec son `.env` et son historique `.paidblocks`. Pour une nouvelle installation, suivre d'abord les sections 5 à 10 du [README](README.md). Le moteur de référence est la version 1.7.4, commit `12ebcce`.

```bash
cd "$HOME/mina-scripts/payouts/mina-pool-payout"
npm run payout -- --help
ps -p 1 -o comm=
# Attendu : l'aide du moteur, puis systemd

sudo apt update
sudo apt install curl jq python3 util-linux gnupg pinentry-curses \
  msmtp msmtp-mta ca-certificates git
```

Sous WSL2, si la dernière commande de vérification n'affiche pas `systemd`, appliquer la section 6 du README. L'automatisation ne tourne que lorsque Linux/WSL et le daemon sont en marche.

```bash
curl -fsS http://127.0.0.1:3085/graphql \
  -H 'Content-Type: application/json' \
  --data '{"query":"{ syncStatus }"}' | jq -r '.data.syncStatus'
# Attendu : SYNCED
```

## 2. Installer le wrapper et renseigner ses paramètres

Pour une première installation, télécharger le wrapper et copier ses trois scripts à côté du moteur. Si le wrapper est déjà cloné, commencer à `cd`. Pour une mise à jour d'une automatisation existante, utiliser la section 39 du README.

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

Exemple de configuration : remplacer les deux adresses Mina, les mails et le fork ; conserver tes véritables commissions. Les taux ci-dessous sont uniquement illustratifs. Utiliser un wallet dédié, déjà créé sur la chaîne, dont tu détiens la clé privée ; dans cet exemple son solde initial est de 1 MINA.

```bash
BP_PUBLIC_KEY="B62***TON_BLOCK_PRODUCER"
PAYOUT_PUBLIC_KEY="B62***TON_WALLET_PAYOUT"
FORK="<TON_FORK_ACTUEL>"
POOL_COMMISSION="0.05"
O1_COMMISSION="0.08"
POOL_MEMO_PREFIX="MonPool_"
PAYOUT_RESERVE_MINA="1"
GRAPHQL_ENDPOINT="http://127.0.0.1:3085/graphql"
MAIL_TO="toi@example.com"
MAIL_FROM="ton.compte@gmail.com"
MAIL_SUBJECT_PREFIX="[Mina payout]"
SENDMAIL_BIN="/usr/sbin/sendmail"
```

Dans le `.env` du moteur, vérifier ces paramètres, en conservant les autres réglages de ton pool. Le wrapper fournit la clé privée uniquement au moment de l'exécution.

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

## 3. Préparer la clé du wallet de payout

Chiffrer la clé privée du **wallet de payout**, avec une phrase secrète GPG. Le nom `encrypted_key.gpg` est obligatoire. Si ce fichier existe déjà pour le bon wallet, passer directement au déverrouillage ; ne pas l'écraser.

```bash
cd "$HOME/mina-scripts/payouts/mina-pool-payout"
read -s -r -p 'Clé privée du wallet de payout : ' PRIVATE_KEY
echo
printf '%s' "$PRIVATE_KEY" | gpg --symmetric --cipher-algo AES256 \
  --output encrypted_key.gpg
unset PRIVATE_KEY
chmod 600 encrypted_key.gpg
```

Configurer le cache GPG en ajoutant ces lignes à `~/.gnupg/gpg-agent.conf` (ou en adaptant les valeurs existantes). Cela évite une demande de phrase secrète à chaque passage du timer.

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

Déverrouiller la clé, puis vérifier qu'elle est accessible sans dialogue. Après un redémarrage ou une expiration du cache, refaire ce déverrouillage : le wrapper attendra jusque-là.

```bash
gpgconf --kill gpg-agent
export GPG_TTY=$(tty)
gpg --decrypt encrypted_key.gpg >/dev/null
gpg --batch --pinentry-mode error --decrypt encrypted_key.gpg >/dev/null \
  && echo 'GPG OK'
# Attendu : GPG OK
```

## 4. Activer et tester les mails

Exemple Gmail : utiliser un mot de passe d'application Google pour le compte expéditeur (voir section 13 du README). Créer le fichier avec des permissions privées avant de saisir ce mot de passe.

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
from ton.compte@gmail.com
user ton.compte@gmail.com
password TON_MOT_DE_PASSE_APPLICATION_GOOGLE

account default : gmail
```

Envoyer un mail de test à l'adresse configurée dans `MAIL_TO`. Continuer après sa réception, en vérifiant aussi les indésirables.

```bash
printf 'Subject: Test Mina payouts\n\nLes notifications fonctionnent.\n' \
  | timeout 20s sendmail toi@example.com
```

```text
Objet : Test Mina payouts
Les notifications fonctionnent.
```

## 5. Démarrer la surveillance automatique

Installer le service et le timer. Le service fourni convient à Node/npm installé globalement ; la variante NVM est juste après. Le timer vérifie la situation toutes les 10 minutes.

```bash
mkdir -p "$HOME/.config/systemd/user"
cp "$HOME/mina-auto-payouts/mina-auto-payout.service" \
   "$HOME/mina-auto-payouts/mina-auto-payout.timer" \
   "$HOME/.config/systemd/user/"
command -v npm
```

Si le résultat contient `.nvm`, remplacer le contenu du service par la variante suivante. Sinon, conserver le fichier fourni.

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

Tester GPG dans le contexte systemd, puis lancer le service et activer le timer. **Dès ce lancement, un batch financé exactement peut être exécuté.** Éviter tout payout manuel concurrent avec ce wallet.

```bash
systemd-run --user --wait --pipe /bin/bash -lc \
  'gpg --batch --pinentry-mode error --decrypt "$HOME/mina-scripts/payouts/mina-pool-payout/encrypted_key.gpg" >/dev/null'
# Attendu : code de sortie 0 ; sinon revenir à l'étape 3.

sudo loginctl enable-linger "$USER"
systemctl --user daemon-reload
systemctl --user start mina-auto-payout.service
journalctl --user -u mina-auto-payout.service -n 30 --no-pager
# Corriger toute erreur avant de continuer.
systemctl --user enable --now mina-auto-payout.timer
systemctl --user list-timers mina-auto-payout.timer
# Attendu : une prochaine exécution planifiée.
```

Si l'epoch n'est pas encore entièrement payable, le wrapper attend ; aucun financement n'est demandé. Exemple de sortie, avec des hauteurs fictives :

```text
Epoch 80 is complete but not fully confirmed yet.
```

## 6. Recevoir le mail et alimenter le wallet

Une fois l'epoch payable, tu reçois un rapport. Voici un **extrait fictif**, avec les mêmes champs que le mail réel : 10 transactions totalisent 100 MINA, avec 0,010 MINA de frais ; le wallet contient déjà sa réserve de 1 MINA.

```text
Objet : [Mina payout] epoch 80 - WAITING_FOR_FUNDING - fund 100.010000000 MINA

Mina Pool Payout - PRE-FUNDING REPORT
Status:                 WAITING_FOR_FUNDING
Payout wallet:
B62***TON_WALLET_PAYOUT

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

Depuis ton wallet habituel, faire **un transfert du montant `TO FUND NOW`**, vers l'adresse du rapport. Le montant reçu doit être exact ; les frais du transfert de financement sont payés en plus depuis le wallet émetteur. Utiliser le dernier rapport et vérifier qu'aucun autre transfert n'a changé le solde depuis son calcul.

```text
Dans ton application de wallet → Envoyer
Destinataire : adresse complète du payout wallet indiquée dans le mail
Montant     : 100.010000000 MINA
Frais       : en plus, à la charge du wallet émetteur

Solde du payout wallet après réception :
1.000000000 + 100.010000000 = 101.010000000 MINA
```

Il n'y a ensuite aucune commande d'envoi à lancer : au prochain passage, le wrapper vérifie le solde, GPG et les autres conditions, puis soumet les transactions. Tu peux regarder les messages avec :

```bash
journalctl --user -u mina-auto-payout.service -n 30 --no-pager
```

```text
SUBMITTED_WAITING_CONFIRMATION: epoch80_...
```

## 7. Recevoir la confirmation et laisser tourner

Après soumission, un premier mail annonce l'attente de confirmation. Quand les contrôles de nonce, de transactions en attente et de solde final passent, un second annonce la réussite. Extraits fictifs :

```text
Objet : [Mina payout] epoch 80 - submitted, awaiting confirmation
Mina Pool Payout - SUBMITTED
Transactions:            10
The batch will NOT be executed again.
```

```text
Objet : [Mina payout] epoch 80 - COMPLETED OK
Mina Pool Payout - COMPLETED OK
Transactions:            10
Final wallet balance:    1.000000000 MINA
Expected reserve:        1.000000000 MINA
Pending transactions:    0
RESULT: COMPLETED_OK
```

Le wallet conserve sa réserve et le wrapper attend l'epoch suivante. Pour vérifier l'epoch terminée et la prochaine surveillance :

```bash
cd "$HOME/mina-scripts/payouts/mina-pool-payout"
cat .auto-payout/last_processed_epoch
# Dans cet exemple : 80
systemctl --user list-timers mina-auto-payout.timer
```

Si tu reçois `GPG key locked`, déverrouiller la clé et laisser le timer reprendre. Pour `RESEND REQUIRED`, un solde trop élevé ou une autre anomalie, arrêter le timer et suivre les sections 26 à 29 du README : ne pas supprimer `.paidblocks` ou relancer un batch déjà signé.

```bash
# GPG verrouillé :
gpg --decrypt "$HOME/mina-scripts/payouts/mina-pool-payout/encrypted_key.gpg" >/dev/null

# Autre anomalie : arrêter les prochains déclenchements et lire les logs.
# Cela n'interrompt pas un service déjà en cours d'exécution.
systemctl --user stop mina-auto-payout.timer
journalctl --user -u mina-auto-payout.service -n 100 --no-pager
```
