#!/usr/bin/env bash
# Train pod entrypoint (baked into the train image). Mirrors boot.sh.
# Env from the portal deploy: TS_AUTHKEY SB_KEY_B64 SB_USER SB_HOST
#                             PORTAL_URL POD_SECRET HF_TOKEN TENANT_SLUG
# AI_TOOLKIT_AUTH defaults to the pod secret. RunPod injects: PUBLIC_KEY (ssh).
set -uo pipefail
TSIP=""
report() { curl -m 8 -s -X POST "${PORTAL_URL:-}/api/pod/status" \
  -H "X-Pod-Secret: ${POD_SECRET:-}" \
  --data-urlencode "stage=$1" --data-urlencode "detail=${2:-}" \
  --data-urlencode "ts_ip=${TSIP}" >/dev/null 2>&1 || true; }
fail() { report error "$1"; echo "FATAL: $1"; sleep infinity; }

report tools "machine booted"

# ssh for debugging (RunPod convention: PUBLIC_KEY env)
mkdir -p /root/.ssh /run/sshd
[ -n "${PUBLIC_KEY:-}" ] && echo "${PUBLIC_KEY}" >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys 2>/dev/null || true
ssh-keygen -A 2>/dev/null || true
/usr/sbin/sshd 2>/dev/null || true

report network "joining private network"
mkdir -p /var/lib/tailscale
pgrep tailscaled >/dev/null || nohup tailscaled --tun=userspace-networking \
  --statedir=/var/lib/tailscale > /var/log/tailscaled.log 2>&1 &
sleep 2
tailscale up --authkey "${TS_AUTHKEY:?TS_AUTHKEY missing}" --hostname "train-pod${TENANT_SLUG:+-$TENANT_SLUG}" --timeout 60s \
  || fail "tailscale join failed"
TSIP=$(tailscale ip -4 2>/dev/null | head -1)
[ -n "$TSIP" ] || fail "no tailscale ip"
report network "joined as ${TSIP}"

report storage "connecting library"
echo "${SB_KEY_B64:?SB_KEY_B64 missing}" | base64 -d > /root/.ssh/storagebox
chmod 600 /root/.ssh/storagebox
mkdir -p /root/.config/rclone
cat > /root/.config/rclone/rclone.conf <<CONF
[storagebox]
type = sftp
host = ${SB_HOST:?}
user = ${SB_USER:?}
port = 23
key_file = /root/.ssh/storagebox
shell_type = none
CONF
# a dead sftp stream must error out, never hang the boot or the sync loops
export RCLONE_TIMEOUT=60s RCLONE_CONTIMEOUT=30s RCLONE_LOW_LEVEL_RETRIES=5
rclone lsd storagebox: >/dev/null 2>&1 || fail "storage unreachable"

# everything big lives on the volume (/workspace): datasets, finished training
# runs, the HF download cache. ai-toolkit's paths are fixed -> symlink them over.
mkdir -p /workspace/datasets /workspace/training /workspace/hf /workspace/aitk/config
rm -rf /app/ai-toolkit/datasets /app/ai-toolkit/output
ln -s /workspace/datasets /app/ai-toolkit/datasets
ln -s /workspace/training /app/ai-toolkit/output
# job configs + the UI's job db survive Stop->Resume on the volume
if [ -d /app/ai-toolkit/config ] && [ ! -L /app/ai-toolkit/config ]; then
  cp -a /app/ai-toolkit/config/. /workspace/aitk/config/ 2>/dev/null || true
  rm -rf /app/ai-toolkit/config
fi
ln -sfn /workspace/aitk/config /app/ai-toolkit/config
if [ -f /app/ai-toolkit/aitk_db.db ] && [ ! -L /app/ai-toolkit/aitk_db.db ]; then
  [ -f /workspace/aitk/aitk_db.db ] || mv /app/ai-toolkit/aitk_db.db /workspace/aitk/aitk_db.db
  rm -f /app/ai-toolkit/aitk_db.db
fi
ln -sfn /workspace/aitk/aitk_db.db /app/ai-toolkit/aitk_db.db

# datasets down from the library (the "models" stage so the portal timeline works)
report models "syncing datasets"
rclone copy storagebox:datasets /workspace/datasets --transfers 8 --checkers 16 \
  --stats 10s --stats-one-line --stats-log-level NOTICE --log-level NOTICE --log-file /tmp/rclone-sync.log &
SYNC_PID=$!
( while kill -0 "$SYNC_PID" 2>/dev/null; do
    sleep 10
    L=$(grep -E '%,.*ETA' /tmp/rclone-sync.log 2>/dev/null | tail -1 | sed 's/^.*NOTICE:[[:space:]]*//' | tr -s ' ')
    [ -z "$L" ] && L=$(grep 'NOTICE:' /tmp/rclone-sync.log 2>/dev/null | tail -1 | sed 's/^.*NOTICE:[[:space:]]*//' | tr -s ' ')
    [ -n "$L" ] && report models "${L}"
  done ) &
PROG_PID=$!
wait "$SYNC_PID" || report models "sync warnings (continuing)"
kill "$PROG_PID" 2>/dev/null || true

report engine "starting the trainer"
export HF_HOME=/workspace/hf
export NODE_ENV=production
# no AI_TOOLKIT_AUTH: unset disables the UI's own login ("approve all requests" in its
# middleware) — the portal's Caddy forward_auth gate is the auth layer, and 8675 is
# only reachable over the tailnet. Set AI_TOOLKIT_AUTH in the deploy env to re-enable.
[ -n "${HF_TOKEN:-}" ] && export HF_TOKEN
cd /app/ai-toolkit/ui
nohup npm run start > /var/log/aitoolkit.log 2>&1 &

code=""
for i in $(seq 1 120); do
  code=$(curl -m 3 -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:8675/" || true)
  case "$code" in 200|302|401) break;; esac
  [ $((i % 6)) -eq 0 ] && report engine "waited $((i * 5))s for first response"
  sleep 5
done
case "$code" in 200|302|401) ;; *) fail "trainer did not come up (see /var/log/aitoolkit.log)";; esac

# rescue loop: UI-made datasets go home, library-added datasets come down (copy
# both ways, never delete), and every finished checkpoint/sample lands in a
# per-session training/ folder. NO auto-promote to loras/ - promotion is a
# deliberate act in the portal library.
SESSION_TAG=$(date +%Y%m%d-%H%M%S)
( while true; do
    sleep 60
    rclone copy /workspace/datasets storagebox:datasets --exclude "*.tmp" 2>/dev/null || true
    rclone copy storagebox:datasets /workspace/datasets 2>/dev/null || true
    rclone copy /workspace/training "storagebox:training/pod-${SESSION_TAG}" --exclude "*.tmp" 2>/dev/null || true
  done ) &

# live metrics for the dashboard dials, every 4s (identical to boot.sh)
( while true; do
    G=$(nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
    IFS=, read -r GU VU VT GT <<< "${G:-,,,}"
    read -r RU RT <<< "$(free -m | awk '/Mem:/ {print $3, $2}')"
    read -r DU DT <<< "$(df -m /workspace 2>/dev/null | awk 'NR==2 {print $3, $2}')"
    [ -z "$DT" ] && read -r DU DT <<< "$(df -m / | awk 'NR==2 {print $3, $2}')"
    curl -m 5 -s -X POST "${PORTAL_URL:-}/api/pod/metrics" -H "X-Pod-Secret: ${POD_SECRET:-}" \
      --data-urlencode "gpu=${GU}" --data-urlencode "vram_used=${VU}" --data-urlencode "vram_total=${VT}" \
      --data-urlencode "temp=${GT}" --data-urlencode "ram_used=${RU}" --data-urlencode "ram_total=${RT}" \
      --data-urlencode "disk_used=${DU}" --data-urlencode "disk_total=${DT}" >/dev/null 2>&1 || true
    sleep 4
  done ) &

report ready "trainer online at ${TSIP}"
echo "READY at ${TSIP}"
sleep infinity
