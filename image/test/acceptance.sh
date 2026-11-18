#!/usr/bin/env bash
#
# Acceptance checks for the CIRRUS Terminal image, run with podman against a
# throwaway home. Covers what is expensive to find out in OnDemand:
#
#   1. an arbitrary uid gets a name, a group and the right login shell
#   2. ...even with no passwd entry at all (the Kubernetes case)
#   3. no password: the session refuses to start rather than open up
#   4. only the gate listens publicly; ttyd is on loopback
#   5. the gate: login page, wrong/right password, unprefixed redirect
#   6. through the gate: the page, /token, the client's URL construction, and
#      ONE request per connection even when two are pipelined
#   7. a real shell over the websocket, with a foreign Origin, on the path the
#      client derives -- and what that shell looks like: login shell, ~/.profile
#      read, prompt, $WORK/$SCRATCH/$NCAR_HOST, TZ, locale, module, ssh
#      aliases, the session's ssh-agent, bao-getkey
#   8. the same for a tcsh user, and ~/.hushlogin
#   9. the home directory afterwards
#  10. the idle watchdog: no cull while a tab is open, exit 0 after
#  11. tools, man pages, and the versions recorded in the image
#
# Usage: image/test/acceptance.sh [image-ref]
set -uo pipefail

IMAGE="${1:-localhost/cirrus-terminal:dev}"
HERE="$(cd "$(dirname "$0")" && pwd)"
DRIVER="${HERE}/ttyd_session.py"
WORK="$(mktemp -d)"
PORT="${CIRRUS_TEST_PORT:-19199}"
NAME="terminal-acceptance-$$"
PASSWORD="TestPass123"
PREFIX="/rnode/fakenode/30123"
BAO_SHA=9fee1714bd7b149dec56798304350642167cae3eb9236aecfbc44fd39dc7bf9e

pass=0; fail=0
ok()    { printf '  ok   %s\n' "$*"; pass=$((pass+1)); }
bad()   { printf '  FAIL %s\n' "$*"; fail=$((fail+1)); }
note()  { printf '  note %s\n' "$*"; }
head_() { printf '\n== %s ==\n' "$*"; }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }

cleanup() {
    podman rm -f --ignore "$NAME" "${NAME}-tcsh" "${NAME}-cull" "${NAME}-nopw" >/dev/null 2>&1
    podman unshare rm -rf "$WORK" 2>/dev/null || rm -rf "$WORK" 2>/dev/null
}
trap cleanup EXIT
trap 'cleanup; exit 130' TERM INT HUP

RUN_ENV=(-e USER=ncote -e NB_USER=ncote -e GROUP=ncar)
boot() {   # boot [podman args...] -- command...   (bootstrap mode, no session)
    local args=()
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do args+=("$1"); shift; done
    shift
    podman run --rm --user 54321:54321 -e HOME=/tmp/h "${RUN_ENV[@]}" \
        -e CIRRUS_TERMINAL_AUTH=none "${args[@]}" "$IMAGE" bootstrap "$@" 2>/dev/null
}
start_session() {   # start_session NAME PORT HOMEDIR [extra podman args...]
    local name="$1" port="$2" home="$3"; shift 3
    podman run -d --name "$name" --user 54321:54321 -p "${port}:8080" \
        -v "${home}:/glade/u/home/ncote:z" -v "$WORK/ood:/ood:z" \
        -e HOME=/glade/u/home/ncote "${RUN_ENV[@]}" \
        -e CIRRUS_TERMINAL_PASSWORD_FILE=/ood/csenv \
        -e CIRRUS_TERMINAL_BASE_URL_FILE=/ood/base_url \
        "$@" "$IMAGE" terminal >/dev/null || return 1
    for _ in $(seq 1 120); do
        curl -s -o /dev/null -m 1 "http://127.0.0.1:${port}/" && return 0
        sleep 0.5
    done
    return 1
}
sign_in() {   # sign_in PORT -> prints the cookie pair
    curl -s -D - -o /dev/null --data-urlencode "password=${PASSWORD}" \
        "http://127.0.0.1:$1/cirrus-signin" \
        | tr -d '\r' | sed -n 's/^[Ss]et-[Cc]ookie: \(cirrus_terminal_gate=[^;]*\).*/\1/p'
}
shell_session() {   # shell_session PORT COOKIE [driver args...] <<< commands
    local port="$1" cookie="$2"; shift 2
    python3 "$DRIVER" --port "$port" --cookie "$cookie" --until __DONE__ "$@"
}
kv() { grep -a "^$1=" | tail -1 | cut -d= -f2-; }

# ---------------------------------------------------------------------------
# A home that looks like a real GLADE home, including the start files the NCAR
# docs tell people to use. Every pre-existing file must come out byte-identical.
# ---------------------------------------------------------------------------
mkdir -p "$WORK/home/.ssh" "$WORK/home/bin" "$WORK/home/work" "$WORK/ood"
cat > "$WORK/home/.profile" <<'EOF'
export CIRRUS_TEST_PROFILE=read
export PBS_ACCOUNT=P00000000
EOF
printf 'setenv CIRRUS_TEST_TCSHRC read\n'  > "$WORK/home/.tcshrc"
printf '[user]\n\tname = Real Name\n'      > "$WORK/home/.gitconfig"
printf 'Host example\n  User ncote\n'      > "$WORK/home/.ssh/config"
printf 'x <- 1\n'                          > "$WORK/home/work/analysis.R"
chmod -R 777 "$WORK/home"; chmod 700 "$WORK/home/.ssh"; chmod 600 "$WORK/home/.ssh/config"
# Hashed BEFORE the chown: afterwards .ssh belongs to a uid in podman's user
# namespace and the host user can no longer read it, which would quietly leave
# ~/.ssh/config out of the byte-identical check.
( cd "$WORK/home" && find . -type f | sort | xargs md5sum ) > "$WORK/home-before.md5"
# Owned by the session uid, as a real home is: ssh refuses a ~/.ssh/config
# owned by anyone else ("Bad owner or permissions").
podman unshare chown -R 54321:54321 "$WORK/home" 2>/dev/null || true

printf '# seeded\npassword=%s\n' "$PASSWORD" > "$WORK/ood/csenv"
printf '%s/\n' "$PREFIX" > "$WORK/ood/base_url"
chmod -R 755 "$WORK/ood"

# ---------------------------------------------------------------------------
head_ "1. arbitrary uid, runtime-synthesised numeric passwd entry"
synth="$(podman run --rm --user 54321:54321 --entrypoint getent "$IMAGE" passwd 54321 2>/dev/null)"
case "$synth" in
    54321:*) ok "the runtime does synthesise a numeric entry: ${synth}" ;;
    *)       note "the runtime did not synthesise an entry (${synth:-none})" ;;
esac
out="$(boot -- id -un)"; check "id -un is ncote, not 54321 (got '${out}')" [ "$out" = ncote ]
out="$(boot -- id -gn)"; check "id -gn is ncar (got '${out}')" [ "$out" = ncar ]
out="$(boot -- sh -c 'getent passwd $(id -u) | cut -d: -f7')"
check "a bash user's passwd shell is /bin/bash (got '${out}')" [ "$out" = /bin/bash ]
out="$(boot -e CIRRUS_TERMINAL_LOGIN_SHELL=tcsh -- sh -c 'getent passwd $(id -u) | cut -d: -f7')"
check "a tcsh user's passwd shell is /bin/tcsh (got '${out}')" [ "$out" = /bin/tcsh ]
out="$(boot -e CIRRUS_TERMINAL_LOGIN_SHELL=fish -- sh -c 'getent passwd $(id -u) | cut -d: -f7')"
check "an unknown shell falls back to /bin/bash (got '${out}')" [ "$out" = /bin/bash ]

head_ "2. arbitrary uid with NO passwd entry at all"
boot -- cat /etc/passwd | grep -v '^[^:]*:[^:]*:54321:' > "$WORK/passwd-noentry"
chmod 644 "$WORK/passwd-noentry"
out="$(boot -v "$WORK/passwd-noentry:/etc/passwd:ro,z" -- id -un)"
check "id -un is ncote with no entry to start from (got '${out}')" [ "$out" = ncote ]

head_ "3. a session with no password refuses to start"
podman run --rm --name "${NAME}-nopw" --user 54321:54321 -e HOME=/tmp/h "${RUN_ENV[@]}" \
    -e CIRRUS_TERMINAL_PASSWORD_FILE=/nonexistent -e CIRRUS_TERMINAL_PASSWORD_WAIT=3 \
    "$IMAGE" terminal > "$WORK/nopw.log" 2>&1
rc=$?
if [ "$rc" -ne 0 ] && grep -q 'Refusing to start an unauthenticated terminal' "$WORK/nopw.log"; then
    ok "no password: refuses to start, exit ${rc}, and says why"
else
    bad "no password: exit ${rc}, no refusal in the log"; sed 's/^/       /' "$WORK/nopw.log"
fi

# ---------------------------------------------------------------------------
head_ "4. the session starts; only the gate listens publicly"
t0=$(date +%s)
if start_session "$NAME" "$PORT" "$WORK/home"; then
    ok "port answered $(( $(date +%s) - t0 ))s after start (startup probe budget is 305s)"
else
    bad "port never answered"; podman logs "$NAME" 2>&1 | sed 's/^/       /'; exit 1
fi
sleep 1
listen="$(podman exec "$NAME" ss -ltnH 2>/dev/null | awk '{print $4}' | sort)"
check "the gate listens on 0.0.0.0:8080" grep -qx '0.0.0.0:8080' <<<"$listen"
check "ttyd listens on 127.0.0.1:7681" grep -qx '127.0.0.1:7681' <<<"$listen"
others="$(grep -vx -e '0.0.0.0:8080' -e '127.0.0.1:7681' <<<"$listen" || true)"
check "nothing else listens on TCP${others:+ (found: ${others//$'\n'/ })}" [ -z "$others" ]

# ---------------------------------------------------------------------------
head_ "5. the password gate"
page="$(curl -s -D "$WORK/h-login" "http://127.0.0.1:${PORT}/")"
check "no cookie: login page, form posting to ${PREFIX}/cirrus-signin" \
    grep -q "action=\"${PREFIX}/cirrus-signin\"" <<<"$page"
check "the gate never sends WWW-Authenticate" bash -c "! grep -qi '^www-authenticate' '$WORK/h-login'"
code="$(curl -s -o /dev/null -w '%{http_code}' --data-urlencode 'password=wrong' \
        "http://127.0.0.1:${PORT}/cirrus-signin")"
check "wrong password refused (${code})" [ "$code" = 401 ]
curl -s -D "$WORK/h-signin" -o /dev/null --data-urlencode "password=${PASSWORD}" \
    "http://127.0.0.1:${PORT}/cirrus-signin"
loc="$(tr -d '\r' < "$WORK/h-signin" | sed -n 's/^[Ll]ocation: //p')"
check "correct password: 302 to '/', unprefixed (got '${loc}')" [ "$loc" = / ]
COOKIE="$(sign_in "$PORT")"
check "correct password: cookie issued, Path=/" grep -qi 'set-cookie: cirrus_terminal_gate=.*Path=/;' "$WORK/h-signin"
code="$(curl -s -o /dev/null -w '%{http_code}' -H 'Cookie: cirrus_terminal_gate=forged' \
        "http://127.0.0.1:${PORT}/token")"
check "a forged cookie gets the login page, not ttyd (${code}, and no token)" \
    bash -c "! curl -s -H 'Cookie: cirrus_terminal_gate=forged' http://127.0.0.1:${PORT}/token | grep -q token"

# ---------------------------------------------------------------------------
head_ "6. through the gate"
curl -s --compressed -H "Cookie: ${COOKIE}" "http://127.0.0.1:${PORT}/" > "$WORK/index.html"
check "the ttyd page loads through the gate" grep -qi '<title>' "$WORK/index.html"
tok="$(curl -s -H "Cookie: ${COOKIE}" "http://127.0.0.1:${PORT}/token")"
check "/token answers JSON through the gate (${tok})" grep -q '"token"' <<<"$tok"
# What makes ttyd work behind /rnode/ without help: the client builds the
# socket and token URLs from window.location.pathname. Asserted on the bundle
# actually served, so a ttyd bump that changes it fails here, not in OnDemand.
python3 - "$WORK/index.html" <<'PY' && ok "the client builds /ws and /token from window.location.pathname" \
                                       || bad "the client's URL construction changed; read the bundle"
import re, sys
s = open(sys.argv[1], encoding="utf-8", errors="replace").read()
assert re.search(r'window\.location\.pathname\.replace\(', s), "no pathname-derived base"
for ep in ('"/ws"', '"/token"'):
    i = s.find(ep)
    assert i > 0, "no %s literal" % ep
    assert "window.location.host" in s[max(0, i - 400):i], "%s not host+path relative" % ep
PY
# Two requests pipelined on one connection. Exactly one response may come
# back, and the connection must then close -- that is the gate's guarantee that
# every request is checked, whatever ttyd does with keep-alive.
python3 - "$PORT" "$COOKIE" > "$WORK/pipeline" <<'PY'
import socket, sys, time
port, cookie = int(sys.argv[1]), sys.argv[2]
req = ("GET /token HTTP/1.1\r\nHost: x\r\nCookie: %s\r\nConnection: keep-alive\r\n\r\n" % cookie).encode()
s = socket.create_connection(("127.0.0.1", port)); s.settimeout(10)
t0 = time.time(); s.sendall(req + req.replace(b"Cookie: " + cookie.encode() + b"\r\n", b""))
data = b""
try:
    while True:
        chunk = s.recv(65536)
        if not chunk: break
        data += chunk
except socket.timeout:
    print("TIMEOUT")
print("RESPONSES=%d" % data.count(b"HTTP/1.1 "))
print("SECS=%.1f" % (time.time() - t0))
PY
n="$(kv RESPONSES < "$WORK/pipeline")"; secs="$(kv SECS < "$WORK/pipeline")"
check "two pipelined requests: exactly one response (got ${n})" [ "$n" = 1 ]
check "...and the connection closed by itself in ${secs}s (ttyd honours Connection: close)" \
    bash -c "! grep -q TIMEOUT '$WORK/pipeline'"

# ---------------------------------------------------------------------------
head_ "7. a real login shell over the websocket"
# The path the client derives behind the proxy, then what the proxy forwards:
#   pathname  ${PREFIX}/  ->  socket  ${PREFIX}/ws  ->  pod receives  /ws
derived="${PREFIX}/"; derived="${derived%/}/ws"; forwarded="${derived#"$PREFIX"}"
check "the client-derived socket path arrives at the pod as /ws (${derived} -> ${forwarded})" \
    [ "$forwarded" = /ws ]
python3 "$DRIVER" --port "$PORT" --until x --timeout 5 </dev/null >/dev/null 2>"$WORK/ws-nocookie"
check "no cookie: refused, no upgrade ($(head -1 "$WORK/ws-nocookie"))" \
    bash -c "! grep -q ' 101 ' '$WORK/ws-nocookie' && [ -s '$WORK/ws-nocookie' ]"

shell_session "$PORT" "$COOKIE" > "$WORK/bash.out" <<'EOF'
printf 'WHO=%s\n' "$(id -un)"
printf 'LOGIN=%s\n' "$(shopt -q login_shell && echo yes || echo no)"
printf 'SHELLV=%s\n' "$SHELL"
printf 'PWDV=%s\n' "$PWD"
printf 'PROFILE=%s\n' "$CIRRUS_TEST_PROFILE"
printf 'PS1V=%s\n' "$PS1"
printf 'WORKV=%s\n' "$WORK"
printf 'SCRATCHV=%s\n' "$SCRATCH"
printf 'NCARHOST=%s\n' "$NCAR_HOST"
printf 'TZNAME=%s\n' "$(date +%Z)"
printf 'LOCALEERR=%s\n' "$(locale 2>&1 >/dev/null | head -1)"
printf 'CHARMAP=%s\n' "$(locale charmap)"
printf 'MODULE=%s\n' "$(type -t module)"
printf 'MODLIST=%s\n' "$(module list 2>&1 | tr '\n' ' ')"
printf 'SSHHOST=%s\n' "$(ssh -G derecho | awk '$1=="hostname"{print $2}')"
printf 'SSHUSER=%s\n' "$(ssh -G derecho | awk '$1=="user"{print $2}')"
printf 'AGENTSOCK=%s\n' "$SSH_AUTH_SOCK"
ssh-add -l >/dev/null 2>&1; printf 'AGENTRC=%s\n' "$?"
printf 'BAO=%s\n' "$(sha256sum /usr/local/bin/bao-getkey | cut -d' ' -f1)"
printf 'HOMEPATH=%s\n' "$(printf '%s' "$PATH" | tr ':' '\n' | grep -c "^$HOME/bin$")"
printf 'TABS=%s\n' "$(cat "$CIRRUS_TERMINAL_STATE_DIR/clients")"
echo __DO''NE__
EOF
rc=$?
if [ "$rc" -eq 0 ]; then
    ok "a shell ran commands over ws with a foreign Origin, via the gate"
else
    bad "the shell session did not complete (driver exit ${rc}); it said:"
    sed 's/^/       /' "$WORK/bash.out" | tail -30
fi
B="$WORK/bash.out"
check "the motd is shown at login" grep -q 'CIRRUS Terminal -- openSUSE Leap' "$B"
v="$(kv WHO < "$B")";       check "whoami is ncote (${v})" [ "$v" = ncote ]
v="$(kv LOGIN < "$B")";     check "it is a login shell (${v})" [ "$v" = yes ]
v="$(kv SHELLV < "$B")";    check "\$SHELL is /bin/bash (${v})" [ "$v" = /bin/bash ]
v="$(kv PWDV < "$B")";      check "it starts in \$HOME (${v})" [ "$v" = /glade/u/home/ncote ]
v="$(kv PROFILE < "$B")";   check "~/.profile was read, as on the login nodes (${v})" [ "$v" = read ]
v="$(kv PS1V < "$B")";      check "SUSE's prompt, with the host shown as cirrus (${v})" \
                                bash -c '[[ "$1" == *"\\u@cirrus:\\w"* ]]' _ "$v"
v="$(kv WORKV < "$B")";     check "\$WORK is /glade/work/ncote (${v})" [ "$v" = /glade/work/ncote ]
v="$(kv SCRATCHV < "$B")";  check "\$SCRATCH is the Derecho path (${v})" [ "$v" = /glade/derecho/scratch/ncote ]
v="$(kv NCARHOST < "$B")";  check "\$NCAR_HOST is cirrus (${v})" [ "$v" = cirrus ]
v="$(kv TZNAME < "$B")";    check "Mountain time (${v})" bash -c '[ "$1" = MST ] || [ "$1" = MDT ]' _ "$v"
v="$(kv LOCALEERR < "$B")"; check "no locale warnings${v:+ (${v})}" [ -z "$v" ]
v="$(kv CHARMAP < "$B")";   check "UTF-8 locale (${v})" [ "$v" = UTF-8 ]
v="$(kv MODULE < "$B")";    check "\`module\` is a shell function, as on the HPC systems (${v})" [ "$v" = function ]
v="$(kv MODLIST < "$B")";   check "\`module list\` runs (${v})" bash -c '[[ "$1" == *"o modules loaded"* ]]' _ "$v"
v="$(kv SSHHOST < "$B")";   check "\`ssh derecho\` resolves to derecho.hpc.ucar.edu (${v})" [ "$v" = derecho.hpc.ucar.edu ]
v="$(kv SSHUSER < "$B")";   check "ssh's default user is ncote (${v})" [ "$v" = ncote ]
v="$(kv AGENTSOCK < "$B")"; check "SSH_AUTH_SOCK is the session agent (${v})" [ "$v" = /tmp/cirrus-terminal/ssh-agent.sock ]
v="$(kv AGENTRC < "$B")";   check "the agent answers with no identities (ssh-add -l exit ${v})" [ "$v" = 1 ]
v="$(kv BAO < "$B")";       check "bao-getkey is the vendored upstream (sha256 matches)" [ "$v" = "$BAO_SHA" ]
v="$(kv HOMEPATH < "$B")";  check "~/bin is on PATH because it exists, as SUSE's /etc/profile does it" [ "$v" = 1 ]
v="$(kv TABS < "$B")";      check "the gate counts the open tab (${v})" [ "$v" = 1 ]
sleep 1
v="$(podman exec "$NAME" cat /tmp/cirrus-terminal/clients 2>/dev/null)"
check "...and uncounts it when the tab closes (${v})" [ "$v" = 0 ]

# ---------------------------------------------------------------------------
head_ "8. a tcsh user, and ~/.hushlogin"
TPORT=$((PORT + 1))
if start_session "${NAME}-tcsh" "$TPORT" "$WORK/home" -e CIRRUS_TERMINAL_LOGIN_SHELL=tcsh; then
    TCOOKIE="$(sign_in "$TPORT")"
    shell_session "$TPORT" "$TCOOKIE" > "$WORK/tcsh.out" <<'EOF'
echo SHELLVAR=$shell
echo LOGINSH=$?loginsh
echo TCSHRC=$CIRRUS_TEST_TCSHRC
echo WORKV=$WORK
echo PROMPTV="$prompt"
which module | grep -q aliased && echo MODULE=alias
echo AGENTSOCK=$SSH_AUTH_SOCK
echo __DO''NE__
EOF
    T="$WORK/tcsh.out"
    v="$(kv SHELLVAR < "$T")"; check "the shell is /bin/tcsh (${v})" [ "$v" = /bin/tcsh ]
    v="$(kv LOGINSH < "$T")";  check "it is a login shell (\$?loginsh=${v})" [ "$v" = 1 ]
    v="$(kv TCSHRC < "$T")";   check "~/.tcshrc was read (${v})" [ "$v" = read ]
    v="$(kv WORKV < "$T")";    check "\$WORK is set for tcsh too (${v})" [ "$v" = /glade/work/ncote ]
    v="$(kv PROMPTV < "$T")";  check "tcsh prompt shows cirrus (${v})" bash -c '[[ "$1" == *cirrus* ]]' _ "$v"
    v="$(kv MODULE < "$T")";   check "\`module\` exists in tcsh (${v:-missing})" [ "$v" = alias ]
    v="$(kv AGENTSOCK < "$T")"; check "tcsh sees the session agent (${v})" [ "$v" = /tmp/cirrus-terminal/ssh-agent.sock ]
    podman rm -f "${NAME}-tcsh" >/dev/null 2>&1
else
    bad "the tcsh session did not start"
fi

podman exec "$NAME" touch /glade/u/home/ncote/.hushlogin
shell_session "$PORT" "$COOKIE" > "$WORK/hush.out" <<'EOF'
echo __DO''NE__
EOF
check "~/.hushlogin suppresses the motd" bash -c "! grep -q 'CIRRUS Terminal --' '$WORK/hush.out'"
podman exec "$NAME" rm -f /glade/u/home/ncote/.hushlogin

# ---------------------------------------------------------------------------
head_ "9. the home directory afterwards"
( cd "$WORK/home" && podman unshare md5sum -c --quiet "$WORK/home-before.md5" ) >/dev/null 2>&1 \
    && ok "every pre-existing file is byte-identical (md5)" \
    || bad "a pre-existing file changed"
found="$(podman unshare find "$WORK/home" \( -type s -o -name 'session-password' -o -name 'ssh-agent*' \) 2>/dev/null)"
check "no sockets, agent or password files in \$HOME" [ -z "$found" ]
new="$(cd "$WORK/home" && podman unshare find . -newer "$WORK/home-before.md5" -type f 2>/dev/null | sort | tr '\n' ' ')"
note "files the shells wrote, as they would on a login node: ${new:-none}"

# ---------------------------------------------------------------------------
head_ "10. idle watchdog"
CPORT=$((PORT + 2))
mkdir -p "$WORK/home-cull"; chmod 777 "$WORK/home-cull"
start_session "${NAME}-cull" "$CPORT" "$WORK/home-cull" \
    -e CIRRUS_TERMINAL_IDLE_TIMEOUT=8 -e CIRRUS_TERMINAL_IDLE_CHECK=2 \
    || bad "the watchdog session did not start"
CCOOKIE="$(sign_in "$CPORT")"
echo 'echo __DO''NE__' | shell_session "$CPORT" "$CCOOKIE" --hold 16 >/dev/null
running="$(podman inspect -f '{{.State.Running}}' "${NAME}-cull" 2>/dev/null)"
check "a session with a tab open survives past its idle timeout" [ "$running" = true ]
for _ in $(seq 1 30); do
    [ "$(podman inspect -f '{{.State.Running}}' "${NAME}-cull" 2>/dev/null)" = false ] && break
    sleep 1
done
code="$(podman inspect -f '{{.State.ExitCode}}' "${NAME}-cull" 2>/dev/null)"
check "with no tab open it ends itself, exit 0 so OnFailure does not restart it (exit ${code})" \
    [ "$code" = 0 ]

# ---------------------------------------------------------------------------
head_ "11. tools and versions"
out="$(boot -- cirrus-terminal-shell -c '
    for b in ssh scp sftp ssh-agent ssh-add bao-getkey curl jq git tmux screen vim nano less \
             rsync gcc gfortran make python3 man tcsh zsh ksh; do
        command -v "$b" >/dev/null || echo "MISSING $b"
    done
    man -w ls >/dev/null 2>&1 || echo "MISSING man page for ls"
    man -w ssh >/dev/null 2>&1 || echo "MISSING man page for ssh"')"
check "the login-node tool set is present, with man pages${out:+ (${out//$'\n'/; })}" [ -z "$out" ]
out="$(boot -- terminal-versions --check)"
check "terminal-versions --check agrees with the record" bash -c "! grep -q '^DIFF' <<<\"\$1\"" _ "$out"
printf '%s\n' "$out" | sed 's/^/       /'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
