#!/usr/bin/env bash
# Studio pod entrypoint (baked into the image).
# Env from the portal deploy: TS_AUTHKEY SB_KEY_B64 SB_USER SB_HOST
#                             PORTAL_URL POD_SECRET WORKERS
# RunPod injects: PUBLIC_KEY (for ssh)
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
/usr/sbin/sshd 2>/dev/null || true

report network "joining private network"
mkdir -p /var/lib/tailscale
pgrep tailscaled >/dev/null || nohup tailscaled --tun=userspace-networking \
  --statedir=/var/lib/tailscale > /var/log/tailscaled.log 2>&1 &
sleep 2
tailscale up --authkey "${TS_AUTHKEY:?TS_AUTHKEY missing}" --hostname gpu-pod --timeout 60s \
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
rclone lsd storagebox: >/dev/null 2>&1 || fail "storage unreachable"

report models "syncing models"
mkdir -p /SwarmUI/Models
rclone sync storagebox:models /SwarmUI/Models --transfers 8 --checkers 16 --fast-list \
  2>/tmp/rclone-sync.log || report models "sync warnings (continuing)"

report engine "configuring ${WORKERS:-1} worker(s)"
COMFY_MAIN=$(find /SwarmUI/dlbackend -name main.py -path '*ComfyUI*' | head -1)
COMFY_REL=${COMFY_MAIN#/SwarmUI/}
mkdir -p /SwarmUI/Data
T=$(printf '\t')
cat > /SwarmUI/Data/Settings.fds <<SET
IsInstalled: true
Network:
${T}Host: 0.0.0.0
Paths:
${T}SDModelFolder: checkpoints
${T}SDLoraFolder: loras
${T}SDVAEFolder: vae
${T}SDEmbeddingFolder: embeddings
SET
N=${WORKERS:-1}; case "$N" in 1|2|3|4) ;; *) N=1;; esac
: > /SwarmUI/Data/Backends.fds
for i in $(seq 0 $((N-1))); do
cat >> /SwarmUI/Data/Backends.fds <<BEND
${i}:
${T}type: comfyui_selfstart
${T}title: worker-${i}
${T}enabled: true
${T}settings:
${T}${T}StartScript: ${COMFY_REL}
${T}${T}GPU_ID: 0
BEND
done

report engine "starting the engine"
cd /SwarmUI
export PATH="/SwarmUI/.dotnet:$PATH"
nohup ./launch-linux.sh --host 0.0.0.0 --launch_mode none > /var/log/swarmui.log 2>&1 &

code=""
for i in $(seq 1 120); do
  code=$(curl -m 3 -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:7801/" || true)
  case "$code" in 200|302) break;; esac
  sleep 5
done
case "$code" in 200|302) ;; *) fail "engine did not come up (see /var/log/swarmui.log)";; esac

sleep 8

# reference images: library inputs/ <-> ComfyUI input/ (copy both ways, never delete)
COMFY_INPUT="$(dirname "$COMFY_MAIN")/input"
mkdir -p "$COMFY_INPUT"
rclone copy storagebox:inputs "$COMFY_INPUT" --transfers 8 2>/dev/null || true
( while true; do
    sleep 60
    rclone copy "$COMFY_INPUT" storagebox:inputs --exclude "*.tmp" --exclude "clipspace/**" 2>/dev/null || true
    rclone copy storagebox:inputs "$COMFY_INPUT" 2>/dev/null || true
  done ) &

# live metrics for the dashboard dials, every 10s
( while true; do
    G=$(nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
    IFS=, read -r GU VU VT GT <<< "${G:-,,,}"
    read -r RU RT <<< "$(free -m | awk '/Mem:/ {print $3, $2}')"
    read -r DU DT <<< "$(df -m / | awk 'NR==2 {print $3, $2}')"
    curl -m 5 -s -X POST "${PORTAL_URL:-}/api/pod/metrics" -H "X-Pod-Secret: ${POD_SECRET:-}" \
      --data-urlencode "gpu=${GU}" --data-urlencode "vram_used=${VU}" --data-urlencode "vram_total=${VT}" \
      --data-urlencode "temp=${GT}" --data-urlencode "ram_used=${RU}" --data-urlencode "ram_total=${RT}" \
      --data-urlencode "disk_used=${DU}" --data-urlencode "disk_total=${DT}" >/dev/null 2>&1 || true
    sleep 10
  done ) &

report ready "engine online at ${TSIP} with ${N} worker(s)"
echo "READY at ${TSIP}"
sleep infinity
