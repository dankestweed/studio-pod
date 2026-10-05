#!/usr/bin/env bash
# Studio pod entrypoint (baked into the image). Plain ComfyUI at /comfy, port 8188.
# Env from the portal deploy: TS_AUTHKEY SB_KEY_B64 SB_USER SB_HOST
#                             PORTAL_URL POD_SECRET (WORKERS is ignored: one engine)
# Optional: COMFY_EXTRA_ARGS (default --cache-none, keeps RAM under the pod's cgroup cap)
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
tailscale up --authkey "${TS_AUTHKEY:?TS_AUTHKEY missing}" --hostname "gpu-pod${TENANT_SLUG:+-$TENANT_SLUG}" --timeout 60s \
  || fail "tailscale join failed"
TSIP=$(tailscale ip -4 2>/dev/null | head -1)
[ -n "$TSIP" ] || fail "no tailscale ip"
report network "joined as ${TSIP}"

# GPU gate: catch nvidia1-only device mappings and CUDA init failures BEFORE the
# model sync burns time. The detail wording is load-bearing: "GPU"/"CUDA" in an
# error stage triggers the portal's community-host auto-blacklist.
report tools "checking GPU"
# any NVIDIA device node counts: on multi-GPU hosts the allocated GPU keeps its HOST
# index (/dev/nvidia3 for slot 3), so requiring nvidia0 rejected 7 of 8 healthy rentals
if ! ls /dev/nvidia[0-9]* >/dev/null 2>&1; then
  fail "GPU never initialized (no NVIDIA device node)"
fi
VPY=/comfy/venv/bin/python
[ -x "$VPY" ] || VPY=python3
GPU_OK=""
for i in $(seq 1 24); do
  if "$VPY" -c "import torch; torch.cuda.init(); assert torch.cuda.device_count() > 0" 2>/dev/null; then
    GPU_OK=1; break
  fi
  [ $((i % 6)) -eq 0 ] && report tools "waiting on CUDA init ($((i * 5))s)"
  sleep 5
done
[ -n "$GPU_OK" ] || fail "GPU never initialized (CUDA init failed after 120s)"
report tools "GPU ok: $(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)"

# uplink probe: 10s Cloudflare pull so dead-network hosts self-identify on the
# timeline before the sync starts crawling at 9 B/s
BPS=$(curl -m 12 -s -o /dev/null -w '%{speed_download}' "https://speed.cloudflare.com/__down?bytes=104857600" 2>/dev/null || echo 0)
MBPS=$(awk -v b="${BPS%%.*}" 'BEGIN{printf "%.1f", b/1048576}')
report tools "uplink ${MBPS} MiB/s"

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

# session manifest: the portal says whether this Start is a selected-workflows session
# (sync only whats needed) or a full-library one. Any failure -> full (old behavior).
MODE=full
curl -m 10 -s "${PORTAL_URL:-}/api/pod/manifest" -H "X-Pod-Secret: ${POD_SECRET:-}" -o /tmp/manifest.json || true
if python3 - <<'PY' 2>/dev/null
import json, sys
d = json.load(open("/tmp/manifest.json"))
ok = d.get("mode") == "selected" and d.get("models")
open("/tmp/models.list", "w").write("".join(m + "\n" for m in d.get("models") or []))
open("/tmp/wf.list", "w").write("".join(w + "\n" for w in d.get("workflows") or []))
sys.exit(0 if ok else 1)
PY
then MODE=selected; fi

# models live on the volume (/workspace): fits the growing library and survives Stop->Resume
mkdir -p /workspace/Models
if [ "$MODE" = selected ]; then
  report models "syncing $(wc -l < /tmp/models.list | tr -d ' ') selected model(s)"
  rclone copy storagebox:models /workspace/Models --files-from /tmp/models.list --transfers 8 --checkers 16 \
    --stats 10s --stats-one-line --stats-log-level NOTICE --log-level NOTICE --log-file /tmp/rclone-sync.log &
else
  report models "syncing models"
  rclone sync storagebox:models /workspace/Models --transfers 8 --checkers 16 --fast-list \
    --stats 10s --stats-one-line --stats-log-level NOTICE --log-level NOTICE --log-file /tmp/rclone-sync.log &
fi
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

report engine "configuring the engine"
COMFY=/comfy
# models: ComfyUI's own models/ dir IS the volume library. Every ComfyUI category
# (checkpoints, loras, diffusion_models, text_encoders, vae, ...) and every pack that
# hard-codes ComfyUI's models dir (facetools landmarks/ultralytics, SEEDVR2...) lands on
# /workspace/Models - no path config, no bridges. The repo's stock folders (incl. configs/)
# are seeded add-only after the library sync so a full-mode sync can't strand them.
cp -rn /comfy/models.dist/. /workspace/Models/ 2>/dev/null || true
if [ ! -L "$COMFY/models" ]; then rm -rf "$COMFY/models"; ln -s /workspace/Models "$COMFY/models"; fi
# custom nodes: library custom_nodes/ -> ComfyUI (add-only) + their pip requirements, before the engine loads
CN_DIR="$COMFY/custom_nodes"
if rclone lsd storagebox:custom_nodes >/dev/null 2>&1; then
  report engine "installing custom nodes"
  rclone copy storagebox:custom_nodes "$CN_DIR" 2>/dev/null || true
  for RQ in "$CN_DIR"/*/requirements.txt; do
    [ -f "$RQ" ] && "$COMFY/venv/bin/pip" install -q -r "$RQ" 2>/dev/null || true
  done
fi
COMFY_ARGS="--listen 0.0.0.0 --port 8188 --enable-cors-header --preview-method latent2rgb --disable-auto-launch ${COMFY_EXTRA_ARGS---cache-none}"

report engine "starting the engine"
# supervisor: ComfyUI restarts itself if it dies (OOM kill etc.); each exit is logged
( cd "$COMFY" && while true; do
    echo "=== engine start $(date +%T) args: ${COMFY_ARGS}"
    "$COMFY/venv/bin/python" -s main.py ${COMFY_ARGS}
    echo "=== engine exited code=$? at $(date +%T); restarting in 5s"
    sleep 5
  done ) >> /var/log/comfyui.log 2>&1 &

code=""
for i in $(seq 1 120); do
  code=$(curl -m 3 -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:8188/" || true)
  case "$code" in 200|302) break;; esac
  [ $((i % 6)) -eq 0 ] && report engine "waited $((i * 5))s for first response"
  sleep 5
done
case "$code" in 200|302) ;; *) fail "engine did not come up (see /var/log/comfyui.log)";; esac

# reference images: library inputs/ <-> ComfyUI input/ (copy both ways, never delete)
COMFY_INPUT="$COMFY/input"
mkdir -p "$COMFY_INPUT"
rclone copy storagebox:inputs "$COMFY_INPUT" --transfers 8 2>/dev/null || true
# rescue generated outputs: saves land on the pod, not the VPS -> push
# them home every minute into a per-session folder (comfy renumbers from 00001 each
# session, so a shared folder would overwrite across sessions)
SESSION_TAG=$(date +%Y%m%d-%H%M%S)
COMFY_OUT="$COMFY/output"
mkdir -p "$COMFY_OUT"

# workflows: library workflows/ <-> ComfyUI's native workflow browser (two-way, never delete)
COMFY_WF="$COMFY/user/default/workflows"
mkdir -p "$COMFY_WF"
WF_SEL=""; [ "$MODE" = selected ] && [ -s /tmp/wf.list ] && WF_SEL="--files-from /tmp/wf.list"
# selected sessions get ONLY their chosen workflows (unvalidated ones must not open on the pod)
rclone copy storagebox:workflows "$COMFY_WF" $WF_SEL 2>/dev/null || true
( while true; do
    sleep 60
    rclone copy "$COMFY_INPUT" storagebox:inputs --exclude "*.tmp" --exclude "clipspace/**" 2>/dev/null || true
    rclone copy storagebox:inputs "$COMFY_INPUT" 2>/dev/null || true
    rclone copy "$COMFY_WF" storagebox:workflows --exclude "*.tmp" 2>/dev/null || true
    rclone copy storagebox:workflows "$COMFY_WF" $WF_SEL 2>/dev/null || true
    rclone copy "$COMFY_OUT" "storagebox:outputs/pod-${SESSION_TAG}" --exclude "*.tmp" 2>/dev/null || true
  done ) &

# live metrics for the dashboard dials, every 4s
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

# generation timings for the dashboard strip: poll each worker's queue/history, post every 10s
cat > /tmp/genpoll.py <<'PY'
import json, os, time, urllib.request, urllib.parse
PORTAL = os.environ.get("PORTAL_URL", ""); SECRET = os.environ.get("POD_SECRET", "")
def get(u):
    try:
        with urllib.request.urlopen(u, timeout=4) as r: return json.load(r)
    except Exception: return None
while True:
    runs, running, pending = [], 0, 0
    for p in (8188,):
        q = get(f"http://127.0.0.1:{p}/queue")
        if q is None: continue
        running += len(q.get("queue_running") or []); pending += len(q.get("queue_pending") or [])
        h = get(f"http://127.0.0.1:{p}/history?max_items=8") or {}
        for rec in h.values():
            st = rec.get("status") or {}
            ts = {}
            for m in st.get("messages") or []:
                if isinstance(m, list) and len(m) > 1 and isinstance(m[1], dict) and m[1].get("timestamp"):
                    ts[m[0]] = m[1]["timestamp"]
            a, b = ts.get("execution_start"), ts.get("execution_success") or ts.get("execution_error")
            if a and b:
                runs.append({"t": b/1000.0, "seconds": round((b-a)/1000.0, 1),
                             "worker": 0, "ok": st.get("status_str") == "success"})
    runs.sort(key=lambda r: -r["t"])
    data = urllib.parse.urlencode({"payload": json.dumps({"runs": runs[:6], "running": running, "pending": pending})}).encode()
    try:
        urllib.request.urlopen(urllib.request.Request(PORTAL + "/api/pod/gens", data=data,
                                                      headers={"X-Pod-Secret": SECRET}), timeout=5)
    except Exception: pass
    time.sleep(10)
PY
nohup python3 /tmp/genpoll.py >/dev/null 2>&1 &

# node registry: once a worker answers, push the full class list home (arms pre-flight node checks)
cat > /tmp/nodespush.py <<'PY'
import json, os, time, urllib.request, urllib.parse
for _ in range(60):
    try:
        with urllib.request.urlopen("http://127.0.0.1:8188/object_info", timeout=8) as r:
            classes = sorted(json.load(r).keys())
        data = urllib.parse.urlencode({"payload": json.dumps(classes)}).encode()
        req = urllib.request.Request(os.environ.get("PORTAL_URL", "") + "/api/pod/nodes", data=data,
                                     headers={"X-Pod-Secret": os.environ.get("POD_SECRET", "")})
        urllib.request.urlopen(req, timeout=10)
        break
    except Exception:
        time.sleep(5)
PY
nohup python3 /tmp/nodespush.py >/dev/null 2>&1 &

# import-failure truth: the engine's own startup verdict on every custom node pack.
# Grep the log at +60s and +180s and post home (empty list clears a previous session's fails).
cat > /tmp/importfails.py <<'PY'
import json, os, re, time, urllib.request, urllib.parse
def collect():
    fails, seen = [], set()
    try:
        log = open("/var/log/comfyui.log", errors="ignore").read()
    except Exception:
        return fails
    for m in re.finditer(r"Cannot import (\S*custom_nodes/([^/\s:]+))[^:]*: ?(.*)", log):
        name, reason = m.group(2), m.group(3).strip()[:200]
        if name not in seen:
            seen.add(name); fails.append({"pack": name, "reason": reason})
    for m in re.finditer(r"IMPORT FAILED[:\s]+([\w .-]{2,60})", log):
        name = m.group(1).strip()
        if name and name not in seen:
            seen.add(name); fails.append({"pack": name, "reason": ""})
    return fails
for wait in (60, 120):
    time.sleep(wait)
    data = urllib.parse.urlencode({"payload": json.dumps(collect())}).encode()
    try:
        urllib.request.urlopen(urllib.request.Request(os.environ.get("PORTAL_URL", "") + "/api/pod/importfails",
            data=data, headers={"X-Pod-Secret": os.environ.get("POD_SECRET", "")}), timeout=8)
    except Exception:
        pass
PY
nohup python3 /tmp/importfails.py >/dev/null 2>&1 &

report ready "engine online at ${TSIP}"
echo "READY at ${TSIP}"
sleep infinity