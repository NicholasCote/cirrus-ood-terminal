#!/usr/bin/env bash
#
# CIRRUS Terminal entrypoint.  Usage: entrypoint.sh {terminal|bootstrap}
#
# What this does, in order:
#   1. session-local state under /tmp, never in the shared home
#   2. give the runtime uid a real name and its real login shell (nss_wrapper)
#   3. resolve the session password and the proxy prefix
#   4. start the session's one ssh-agent, ttyd on loopback, and the gate
#   5. supervise: cull an idle session, cap a long one, report the right status
#
# Nothing here chowns anything, and nothing writes into the image. Logging goes
# to stderr, which is the pod log.

set -euo pipefail

PROG="cirrus-terminal"
log()  { printf '%s: %s\n' "$PROG" "$*" >&2; }
warn() { printf '%s: WARNING: %s\n' "$PROG" "$*" >&2; }

usage() {
    cat >&2 <<USAGE
usage: entrypoint.sh terminal
       entrypoint.sh bootstrap [command...]

  terminal    Start ttyd behind the password gate (the OOD app path).

  bootstrap   Run the common bootstrap only -- runtime uid, state directory,
              password, proxy prefix -- then exec command... if one was given,
              or print a summary and exit. image/test/acceptance.sh drives it,
              and it is the way to reproduce a session's environment by hand.
USAGE
}

MODE="${1:-terminal}"
case "$MODE" in
    terminal|bootstrap) shift || true ;;
    -h|--help) usage; exit 2 ;;
    *) printf '%s: ERROR: unknown mode: %s\n' "$PROG" "$MODE" >&2; usage; exit 2 ;;
esac

# ===========================================================================
# 1. Session-local state
#
# Sockets, the resolved password and runtime directories live on the pod's own
# /tmp. Never on GLADE: it is shared with Casper and Derecho, and a socket or a
# password file there would be visible from every login node.
#
# That is ALL this app keeps out of the home. Unlike the desktop and RStudio
# apps, it deliberately does not redirect XDG_CONFIG_HOME, XDG_DATA_HOME or
# PYTHONUSERBASE: the point of this app is to be another login to the same
# account, and a shell that writes ~/.bash_history, ~/.viminfo or ~/.lesshst is
# doing exactly what it does on a Casper login node. The userland is the same
# OS family (see image/Dockerfile), so a ~/.local built here is not the
# cross-glibc hazard it is from an Ubuntu container.
# ===========================================================================

STATE_DIR="${CIRRUS_TERMINAL_STATE_DIR:-/tmp/cirrus-terminal}"
export CIRRUS_TERMINAL_STATE_DIR="$STATE_DIR"

# A pod always has $HOME set from the spec, but a bare `podman run --user N:N`
# may not, and then every ~-relative path expands to "/".
if [ -n "${HOME:-}" ] && [ ! -d "$HOME" ]; then
    mkdir -p -- "$HOME" 2>/dev/null || true
fi
if [ -z "${HOME:-}" ] || [ ! -d "${HOME:-}" ]; then
    warn "\$HOME is unset or unusable (${HOME:-<unset>}); using ${STATE_DIR}/home"
    HOME="${STATE_DIR}/home"
    export HOME
fi

mkdir -p "${STATE_DIR}" "${STATE_DIR}/tmp" "${STATE_DIR}/run" 2>/dev/null || true
# XDG_RUNTIME_DIR must be 0700 or anything that checks complains on every start.
chmod 0700 "${STATE_DIR}" "${STATE_DIR}/run" 2>/dev/null || true
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-${STATE_DIR}/run}"
export TMPDIR="${TMPDIR:-${STATE_DIR}/tmp}"
# tmux and screen put their sockets here; on the pod's /tmp, not on GLADE.
export TMUX_TMPDIR="${TMUX_TMPDIR:-${STATE_DIR}/run}"

# ===========================================================================
# 2. Runtime uid and login shell
#
# OOD sets runAsUser/runAsGroup to the user's real NFS uid/gid, which has no
# entry in this image's /etc/passwd. Without one, the prompt shows a number,
# `whoami` fails, git refuses to commit and ssh does not know who to log in as.
# ===========================================================================

# The shell the user has on Casper and Derecho, by basename; resolved to a path
# in this image. The passwd entry must carry the same one: tmux, screen, vim's
# :shell and anything else that starts "the user's shell" read it from there,
# not from $SHELL.
case "${CIRRUS_TERMINAL_LOGIN_SHELL:-bash}" in
    *tcsh|*csh) LOGIN_SHELL_PATH=/bin/tcsh ;;
    *zsh)       LOGIN_SHELL_PATH=/bin/zsh ;;
    *ksh)       LOGIN_SHELL_PATH=/bin/ksh ;;
    *)          LOGIN_SHELL_PATH=/bin/bash ;;
esac
[ -x "$LOGIN_SHELL_PATH" ] || LOGIN_SHELL_PATH=/bin/bash
export CIRRUS_TERMINAL_LOGIN_SHELL="${LOGIN_SHELL_PATH##*/}"
export SHELL="$LOGIN_SHELL_PATH"

setup_nss_wrapper() {
    local uid gid lib want_name want_group cur_name cur_group cur_shell
    local passwd_file group_file need_passwd=0 need_group=0
    uid="$(id -u)"
    gid="$(id -g)"

    # OOD sets USER, NB_USER and GROUP in the pod spec, and it is the authority:
    # the container has no way to know any of them.
    want_name="${USER:-${NB_USER:-}}"
    case "${want_name}" in ''|*[!a-zA-Z0-9._-]*) want_name="" ;; esac
    [ -n "$want_name" ] || want_name="terminal-${uid}"
    want_group="${GROUP:-}"
    case "${want_group}" in *[!a-zA-Z0-9._-]*) want_group="" ;; esac

    # `|| true` is load-bearing: with no entry getent exits 2, and under
    # set -e + pipefail that kills this script before it logs a single line.
    cur_name="$(getent passwd "$uid" 2>/dev/null | cut -d: -f1 || true)"
    cur_shell="$(getent passwd "$uid" 2>/dev/null | cut -d: -f7 || true)"
    cur_group="$(getent group "$gid" 2>/dev/null | cut -d: -f1 || true)"

    # "Does an entry exist" is the wrong test: container runtimes synthesise
    # one whose NAME IS THE UID (podman: 54321:*:54321:54321:container
    # user:/:/bin/sh). Treat an all-digits name as no name at all.
    if [ -z "$cur_name" ] || [ "$cur_name" = "$uid" ]; then
        need_passwd=1
    else
        case "$cur_name" in
            *[!0-9]*) [ "$cur_shell" = "$LOGIN_SHELL_PATH" ] || need_passwd=1 ;;
            *) need_passwd=1 ;;
        esac
    fi
    if [ -n "$want_group" ] && [ "$cur_group" != "$want_group" ]; then
        need_group=1
    fi

    if [ "$need_passwd" -eq 0 ] && [ "$need_group" -eq 0 ]; then
        return 0
    fi

    lib="$(cat /opt/cirrus-terminal/nss_wrapper_lib 2>/dev/null || true)"
    if [ -z "$lib" ] || [ ! -r "$lib" ]; then
        warn "libnss_wrapper.so was not found; uid ${uid} will resolve as"
        warn "'${cur_name:-<unresolved>}'. The prompt will show a number and git will"
        warn "refuse to commit. This is an image bug, not a site problem."
        return 0
    fi

    passwd_file="${STATE_DIR}/passwd"
    group_file="${STATE_DIR}/group"

    # Existing entries for this uid are filtered out rather than appended
    # after: nss_wrapper returns the FIRST match. `|| true`: grep exits 1 when
    # it filters everything out, which under pipefail would end the script.
    grep -v "^[^:]*:[^:]*:${uid}:" /etc/passwd > "$passwd_file" 2>/dev/null || true
    printf '%s:x:%s:%s:%s:%s:%s\n' \
        "$want_name" "$uid" "$gid" "$want_name" "$HOME" "$LOGIN_SHELL_PATH" >> "$passwd_file"

    if [ -n "$want_group" ]; then
        grep -v "^[^:]*:[^:]*:${gid}:" /etc/group > "$group_file" 2>/dev/null || true
        printf '%s:x:%s:\n' "$want_group" "$gid" >> "$group_file"
    else
        cp /etc/group "$group_file" 2>/dev/null || : > "$group_file"
        getent group "$gid" >/dev/null 2>&1 || printf '%s:x:%s:\n' "$want_name" "$gid" >> "$group_file"
    fi

    export NSS_WRAPPER_PASSWD="$passwd_file"
    export NSS_WRAPPER_GROUP="$group_file"
    export LD_PRELOAD="${lib}${LD_PRELOAD:+:${LD_PRELOAD}}"
    export USER="$want_name"
    export LOGNAME="$want_name"
    log "uid ${uid} resolves as '${want_name}'${want_group:+, gid ${gid} as '${want_group}'}, shell ${LOGIN_SHELL_PATH} (via nss_wrapper)"
}
setup_nss_wrapper
export LOGNAME="${LOGNAME:-${USER:-}}"

# ===========================================================================
# 3. Session password
#
# Generated by the init-secret container into <pod>-secret, copied into the
# session ConfigMap by add-passwd-to-cfg, and projected here as a file. The
# dashboard reads the same Secret to build the Open Terminal button, so the user
# never types it.
# ===========================================================================

PASSWORD_FILE_OUT="${STATE_DIR}/session-password"
resolve_password() {
    local src="${CIRRUS_TERMINAL_PASSWORD_FILE:-}" i pw=""

    if [ "${CIRRUS_TERMINAL_AUTH:-password}" = "none" ]; then
        return 0
    fi
    if [ -z "$src" ]; then
        warn "CIRRUS_TERMINAL_AUTH=password but CIRRUS_TERMINAL_PASSWORD_FILE is unset."
        return 1
    fi

    # The wait is what makes this race-free. Volumes are projected before init
    # containers run, so the file is already here -- empty -- by the time
    # add-passwd-to-cfg edits the ConfigMap, and kubelet re-projects it a second
    # or two later. The startup probe in submit.yml.erb (5 minutes) covers it.
    # Configurable only so the acceptance test can drive the give-up path fast.
    local wait_secs="${CIRRUS_TERMINAL_PASSWORD_WAIT:-120}"
    case "$wait_secs" in ''|*[!0-9]*) wait_secs=120 ;; esac

    for i in $(seq 1 "$wait_secs"); do
        # `|| true` twice over: no file yet (exit 2) and no password line yet
        # (exit 1) are both the normal state of this loop.
        pw="$(grep -m1 '^password=' "$src" 2>/dev/null | cut -d= -f2- || true)"
        [ -n "$pw" ] && break
        [ "$i" -eq 1 ] && log "waiting for the session password at ${src}"
        sleep 1
    done

    if [ -z "$pw" ]; then
        warn "no password appeared at ${src} after ${wait_secs}s."
        warn "The add-passwd-to-cfg init container did not write one. Check:"
        warn "    kubectl logs \$POD -c add-passwd-to-cfg"
        return 1
    fi

    ( umask 077; printf '%s' "$pw" > "$PASSWORD_FILE_OUT" )
    export CIRRUS_TERMINAL_PASSWORD_FILE_RESOLVED="$PASSWORD_FILE_OUT"
    log "session password loaded (${#pw} characters)"
    return 0
}
PASSWORD_OK=1
resolve_password || PASSWORD_OK=0

# ===========================================================================
# 4. Proxy prefix
#
# OnDemand's /rnode/ proxy strips /rnode/<node>/<port> on the way in and adds it
# back to Location headers and cookie Paths on the way out, so neither ttyd nor
# the gate needs to know it -- with one exception: the gate's fallback login
# form, whose action is in a response body, which the proxy does not rewrite.
# The node and NodePort do not exist until the pod is scheduled, so an init
# container computes the prefix into the ConfigMap and this reads it.
# ===========================================================================

BASE_URL="${CIRRUS_TERMINAL_BASE_URL:-}"
if [ -z "$BASE_URL" ] && [ -n "${CIRRUS_TERMINAL_BASE_URL_FILE:-}" ]; then
    for i in $(seq 1 30); do
        # Last path-looking line; `|| true` because an empty file -- what a
        # failed init container leaves -- makes grep exit 1.
        BASE_URL="$(grep -oE '^[[:space:]]*/[^[:space:]]*' "$CIRRUS_TERMINAL_BASE_URL_FILE" 2>/dev/null | tr -d '[:space:]' | tail -1 || true)"
        [ -n "$BASE_URL" ] && break
        sleep 1
    done
    if [ -n "$BASE_URL" ]; then
        log "proxy prefix read from ${CIRRUS_TERMINAL_BASE_URL_FILE}: ${BASE_URL}"
    else
        warn "no proxy prefix appeared at ${CIRRUS_TERMINAL_BASE_URL_FILE}; check"
        warn "    kubectl logs \$POD -c add-baseurl-to-cfg"
        warn "The fallback login form will post to /, which behind OnDemand is a 404."
        warn "The Open Terminal button still works; it posts the full path itself."
    fi
fi
[ -n "$BASE_URL" ] || BASE_URL="/"
case "$BASE_URL" in */) ;; *) BASE_URL="${BASE_URL}/" ;; esac

PORT="${CIRRUS_TERMINAL_PORT:-8080}"
UPSTREAM_PORT="${CIRRUS_TERMINAL_UPSTREAM_PORT:-7681}"

# ===========================================================================
# 5. bootstrap mode -- everything above, then stop or hand over
# ===========================================================================
if [ "$MODE" = "bootstrap" ]; then
    if [ "$#" -gt 0 ]; then
        exec "$@"
    fi
    log "bootstrap complete"
    log "  user             : $(id -un 2>/dev/null || echo '<no passwd entry>') (uid $(id -u), gid $(id -g))"
    log "  HOME             : ${HOME}"
    log "  login shell      : ${LOGIN_SHELL_PATH}"
    log "  XDG_RUNTIME_DIR  : ${XDG_RUNTIME_DIR}"
    log "  TMPDIR           : ${TMPDIR}"
    log "  proxy prefix     : ${BASE_URL} (gate login form only)"
    log "  port             : ${PORT} (gate), ${UPSTREAM_PORT} (ttyd, loopback)"
    exit 0
fi

# ===========================================================================
# 6. The terminal
# ===========================================================================

USE_GATE=0
if [ "${CIRRUS_TERMINAL_AUTH:-password}" = "password" ]; then
    if [ "$PASSWORD_OK" -eq 1 ]; then
        USE_GATE=1
    else
        # Refuse rather than fall back to no auth: a pod that looks healthy
        # while handing a shell in someone's home to anyone who can reach the
        # port is worse than one that does not start.
        warn "CIRRUS_TERMINAL_AUTH=password but no session password is available."
        warn "Refusing to start an unauthenticated terminal. The reason is above;"
        warn "set CIRRUS_TERMINAL_AUTH=none deliberately if that is really wanted."
        exit 1
    fi
fi

if [ "$USE_GATE" -eq 1 ]; then
    TTYD_IFACE=lo
    TTYD_PORT="$UPSTREAM_PORT"
    export CIRRUS_TERMINAL_ROOT_PATH="$BASE_URL"
    export CIRRUS_TERMINAL_UPSTREAM_PORT="$UPSTREAM_PORT"
else
    TTYD_IFACE=""
    TTYD_PORT="$PORT"
    warn "CIRRUS_TERMINAL_AUTH=none: anyone who can reach port ${PORT} gets a shell"
    warn "in your home directory. Only appropriate behind something else that"
    warn "authenticates."
fi

# --- one ssh-agent per session ----------------------------------------------
#
# For bao-getkey, which loads a short-lived OpenBao SSH certificate into it so
# ssh to Casper/Derecho skips the two-factor prompt, and for git over ssh.
# Exported before ttyd starts, so every tab's shell inherits the same socket and
# one bao-getkey covers them all. On the pod's /tmp, never the NFS home: it ends
# with the pod and is never shared between sessions. A missing agent is a
# warning, not a failure: a terminal is still useful without it.
SSH_AGENT_SOCK="${STATE_DIR}/ssh-agent.sock"
SSH_AGENT_PID=""
rm -f -- "$SSH_AGENT_SOCK"
if agent_env="$(ssh-agent -s -a "$SSH_AGENT_SOCK" 2>&1)"; then
    SSH_AGENT_PID="$(printf '%s\n' "$agent_env" | sed -n 's/^SSH_AGENT_PID=\([0-9]*\);.*/\1/p')"
    export SSH_AUTH_SOCK="$SSH_AGENT_SOCK" SSH_AGENT_PID
    log "ssh-agent started at ${SSH_AUTH_SOCK} (pid ${SSH_AGENT_PID:-?})"
else
    unset SSH_AUTH_SOCK SSH_AGENT_PID
    warn "ssh-agent failed to start; bao-getkey will not work in this session."
    warn "${agent_env}"
fi

# --- ttyd -------------------------------------------------------------------
#
#   -W            writable. ttyd 1.7 is READ-ONLY by default: without this the
#                 page paints, the prompt appears, and no key does anything.
#   -i lo         loopback only; the gate is the only way in.
#   -t ...        client options. The leave alert stays ON (the default):
#                 closing the tab ends that shell, the same as closing an ssh
#                 connection, and the browser asking first is a kindness.
#
# Each websocket gets its own process, and ttyd sends it SIGHUP when the tab
# goes -- the same thing sshd does on a dropped connection.
ttyd_args=(
    -W
    -p "$TTYD_PORT"
    -t "fontSize=${CIRRUS_TERMINAL_FONT_SIZE:-14}"
)
[ -z "$TTYD_IFACE" ] || ttyd_args+=(-i "$TTYD_IFACE")

cd "$HOME" 2>/dev/null || cd /
log "starting ttyd on ${TTYD_IFACE:-0.0.0.0}:${TTYD_PORT}, login shell ${LOGIN_SHELL_PATH}"
ttyd "${ttyd_args[@]}" /usr/local/bin/cirrus-terminal-shell &
TTYD_PID=$!

# --- the gate ---------------------------------------------------------------
GATE_PID=""
if [ "$USE_GATE" -eq 1 ]; then
    /usr/local/bin/cirrus-terminal-gate &
    GATE_PID=$!
    log "password gate on :${PORT}, ttyd on 127.0.0.1:${UPSTREAM_PORT}"
fi

# ===========================================================================
# 7. Supervision: idle culling and a hard ceiling
#
# Nothing outside the pod reclaims an abandoned session. The signal is whether
# any terminal tab is open, which the gate tracks -- ttyd has no API for it --
# in ${STATE_DIR}/clients: the number of open websockets, whose mtime is when
# that number last changed. Background jobs a user left running do not count;
# use tmux on Derecho or Casper for anything that has to outlive the session.
# ===========================================================================

check_int() {
    local name="$1" value="$2" fallback="$3"
    case "$value" in
        ''|*[!0-9]*)
            warn "${name}=${value} is not a whole number of seconds; using ${fallback}."
            printf '%s' "$fallback" ;;
        *)  printf '%s' "$value" ;;
    esac
}
IDLE_TIMEOUT="$(check_int CIRRUS_TERMINAL_IDLE_TIMEOUT "${CIRRUS_TERMINAL_IDLE_TIMEOUT:-3600}" 3600)"
IDLE_CHECK="$(check_int CIRRUS_TERMINAL_IDLE_CHECK "${CIRRUS_TERMINAL_IDLE_CHECK:-300}" 300)"
MAX_LIFETIME="$(check_int CIRRUS_TERMINAL_MAX_LIFETIME "${CIRRUS_TERMINAL_MAX_LIFETIME:-43200}" 43200)"
[ "$IDLE_CHECK" -gt 0 ] || IDLE_CHECK=300
# Without the gate nothing counts clients, so there is nothing to cull on.
[ "$USE_GATE" -eq 1 ] || IDLE_TIMEOUT=0
CULLED="${STATE_DIR}/culled"
CLIENTS="${STATE_DIR}/clients"
rm -f "$CULLED"
STARTED="$(date +%s)"

# 0 only when the gate says so. A missing or unreadable file means "connected":
# the failure mode of a broken count must be a session that is not culled,
# never one culled while somebody is typing in it.
open_tabs() {
    local n
    n="$(cat "$CLIENTS" 2>/dev/null || true)"
    case "$n" in ''|*[!0-9]*) echo 1 ;; *) echo "$n" ;; esac
}

WATCHDOG_PID=""
if [ "$IDLE_TIMEOUT" -gt 0 ] || [ "$MAX_LIFETIME" -gt 0 ]; then
    (
        LAST_SEEN="$STARTED"
        while sleep "$IDLE_CHECK"; do
            kill -0 "$TTYD_PID" 2>/dev/null || exit 0
            NOW="$(date +%s)"

            if [ "$MAX_LIFETIME" -gt 0 ] && [ $(( NOW - STARTED )) -ge "$MAX_LIFETIME" ]; then
                warn "this session has run for $(( NOW - STARTED ))s, the maximum. Ending it."
                warn "Relaunch from OnDemand; your files are where you left them."
                : > "$CULLED"
                kill -TERM "$TTYD_PID" 2>/dev/null || true
                exit 0
            fi

            if [ "$IDLE_TIMEOUT" -gt 0 ]; then
                if [ "$(open_tabs)" -gt 0 ]; then
                    LAST_SEEN="$NOW"
                else
                    # The last tab may have closed just now, after a long
                    # session: idle time counts from that, not from the last
                    # check that happened to see it open.
                    changed="$(stat -c %Y "$CLIENTS" 2>/dev/null || echo "$NOW")"
                    [ "$changed" -le "$LAST_SEEN" ] || LAST_SEEN="$changed"
                    if [ $(( NOW - LAST_SEEN )) -ge "$IDLE_TIMEOUT" ]; then
                        warn "no terminal has been open for $(( NOW - LAST_SEEN ))s (limit"
                        warn "${IDLE_TIMEOUT}s). Ending this session so it stops holding its"
                        warn "CPU and memory. Relaunch from OnDemand when you need it."
                        : > "$CULLED"
                        kill -TERM "$TTYD_PID" 2>/dev/null || true
                        exit 0
                    fi
                fi
            fi
        done
    ) &
    WATCHDOG_PID=$!
fi

# Pod deletion sends SIGTERM to this shell, PID 1. Forward it so ending the
# session from the dashboard shuts things down instead of waiting for SIGKILL.
shutdown_all() {
    local pid
    for pid in "$TTYD_PID" ${GATE_PID:+"$GATE_PID"} \
               ${WATCHDOG_PID:+"$WATCHDOG_PID"} ${SSH_AGENT_PID:+"$SSH_AGENT_PID"}; do
        kill -TERM "$pid" 2>/dev/null || true
    done
}
trap 'shutdown_all; exit 0' TERM INT

# Either of ttyd or the gate ending ends the session: without ttyd there is no
# shell, and without the gate a port that answers nothing.
RC=0
wait -n "$TTYD_PID" ${GATE_PID:+"$GATE_PID"} || RC=$?

WENT="unknown"
kill -0 "$TTYD_PID" 2>/dev/null || WENT="ttyd"
[ -z "${GATE_PID:-}" ] || kill -0 "$GATE_PID" 2>/dev/null || WENT="gate"

shutdown_all

# Exit 0 after a cull. restart_policy is OnFailure, so a nonzero exit would
# bring the session straight back and it would never release anything. A
# genuine crash still exits nonzero and still gets its restart.
if [ -f "$CULLED" ]; then
    log "session ended by the watchdog (exit 0 so the pod completes rather than restarting)"
    exit 0
fi
log "session ending: ${WENT} exited with status ${RC}"
# Neither process ends on its own in normal operation, so even a 0 here is an
# unplanned exit, and it should get the restart a crash gets.
[ "$RC" -ne 0 ] || RC=1
exit "$RC"
