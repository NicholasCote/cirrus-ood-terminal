# Terminal on CIRRUS (Open OnDemand)

An Open OnDemand Batch Connect app that opens a **shell in the browser**, as a
pod on the CIRRUS Kubernetes cluster, with the same GLADE mounts as the other
CIRRUS apps — set up so that it feels like logging in to Casper or Derecho. The
terminal is served by [ttyd].

The repository root **is** the OOD app root. `image/` holds the container we
build and OOD ignores it.

```
manifest.yml  form.yml  submit.yml.erb  view.html.erb  info.md.erb
template/.keep                    # required; the built-in "basic" template is used
icon.png                          # 400x400, square
image/Dockerfile                  # the image; built and pushed by CI
image/bin/entrypoint.sh           # identity, state, password, ssh-agent, ttyd, gate, watchdog
image/bin/cirrus-terminal-gate    # the password gate in front of ttyd
image/bin/cirrus-terminal-shell   # what every tab runs: the user's own login shell
image/bin/terminal-versions       # what is actually in this image
image/bao-getkey                  # vendored OpenBao SSH-certificate client
image/etc/profile.d/              # $WORK, $SCRATCH, $NCAR_HOST (sh and csh)
image/etc/bash.bashrc.local       # SUSE's site hook: the prompt
image/etc/csh.cshrc.local         # the same for tcsh
image/etc/motd                    # what is and is not here, shown at login
image/etc/ssh/ssh_config.d/       # `ssh derecho`, `ssh casper`
image/test/acceptance.sh          # the 63 checks below, runnable with podman
image/test/ttyd_session.py        # drives a real shell over the websocket
.github/workflows/build.yml
```

[ttyd]: https://github.com/tsl0922/ttyd

## SSH to Casper and Derecho without the two-factor prompt

Run `bao-getkey` once. It asks for your password and a Duo approval, then
loads a short-lived SSH certificate into this session's ssh-agent:

```bash
bao-getkey
ssh derecho          # no ncar-two-factor prompt
ssh casper qstat -u $USER
```

Every tab in the session shares the same agent, so you only do this once per
session. When ssh starts prompting again, the certificate has expired: run
`bao-getkey` again. The key lives only in the session's memory and is never
written to `~/.ssh`.

`ssh derecho` and `ssh casper` work as short names because
`/etc/ssh/ssh_config.d/50-cirrus-hpc.conf` maps them to `*.hpc.ucar.edu` — on
the login nodes DNS does that, but a pod's DNS search path is the cluster's.
Your own `~/.ssh/config` is read first and wins. The first connection to a
host asks you to confirm its host key; answer `yes`.

**Troubleshooting** is the same as for the sibling apps:

- **"error in libcrypto"** from `bao-getkey`: your account does not have the
  OpenBao `ssh-client-signer` policy yet. Not an app bug; ask for the policy.
- **A new tab still prompts**: your `~/.bashrc` or `~/.profile` starts its own
  `ssh-agent`, replacing the session's. Start one only when none is set:
  `if [ -z "$SSH_AUTH_SOCK" ]; then eval "$(ssh-agent -s)" >/dev/null; fi`
- **`ssh-add -l` cannot connect to the agent**: something in your start files
  unset `SSH_AUTH_SOCK`. It should be `/tmp/cirrus-terminal/ssh-agent.sock`.

`bao-getkey` is vendored at `image/bao-getkey` because its upstream repo
(`NCAR/hsg-openbao-scripts`) is internal to the NCAR org. It is a verbatim copy
of `bin/bao-getkey` at commit `ef6b7a7503c911977865df50df3b4d4fc223c25b`,
sha256 `9fee1714bd7b149dec56798304350642167cae3eb9236aecfbc44fd39dc7bf9e` —
byte-identical to the copies in the Ubuntu Desktop, RStudio and VS Code apps.
The Dockerfile, CI and `image/test/acceptance.sh` all check the hash; to update
it, copy the file again and change the hash in all three.

## How close to a Casper or Derecho login it is

The reference is the NCAR HPC documentation: the
[Derecho](https://ncar-hpc-docs.readthedocs.io/en/latest/compute-systems/derecho/)
and Casper pages (shells, modules), *Personalizing start files* (which files a
login reads), and the PBS job-script page (`$WORK`, `$SCRATCH`, `$NCAR_HOST`).

| On Casper / Derecho | Here | How |
| --- | --- | --- |
| openSUSE 15 (Casper), SLES 15 (Derecho) | openSUSE Leap 15.6 — built from SLES 15 SP6 sources | `FROM registry.opensuse.org/opensuse/leap:15.6` |
| bash by default, tcsh if chosen in SAM | the shell from your directory entry; bash, tcsh, zsh, ksh installed | `submit.yml.erb` reads it; `cirrus-terminal-shell` execs it |
| a login shell reads `~/.profile` (bash/ksh) or `~/.tcshrc` + `~/.login` (tcsh) | the same — every tab is a login shell | `argv[0]` starts with `-`, as sshd does it |
| starts in `/glade/u/home/$USER` | the same path; your real GLADE home is mounted there | |
| prompt `user@derecho4:~>` | `user@cirrus:~>` | SUSE's own default prompt, `\h` replaced in `/etc/bash.bashrc.local` |
| `~/bin`, `~/.local/bin` on PATH when they exist | the same | SUSE's own `/etc/profile`, unmodified |
| `module` (Lmod) | `module` (Lmod 8.7), but **no NCAR module tree** | see below |
| `$WORK`, `$SCRATCH` | both set, to the same paths | `/etc/profile.d/cirrus-terminal.{sh,csh}` |
| `$NCAR_HOST` = `derecho` / `casper` | `cirrus` | the honest answer for scripts that branch on it |
| bash 4.4, tcsh 6.20, gcc 7, python3 3.6 | the same versions | same OS release |
| Mountain time, en_US.UTF-8 | the same | `TZ=America/Denver`, `LANG=en_US.UTF-8` |
| `man ls` works | works | `man`, `man-pages`, `coreutils-doc` |
| `/etc/motd` at login, `~/.hushlogin` silences it | the same | `cirrus-terminal-shell` |
| closing ssh hangs up the shell | closing the tab hangs it up (SIGHUP) | ttyd's default |
| git, vim, emacs, nano, tmux, screen, rsync, wget, curl, jq, htop, tree, zip… | the same set | `image/Dockerfile` |

**What is deliberately not the same, and why.** These are printed in the
motd so nobody has to discover them:

- **No PBS.** `qsub`/`qstat` need the cluster's PBS server; run them on the
  HPC systems over `ssh` (see above).
- **No NCAR module tree.** It lives in `/glade/u/apps`, which none of the
  CIRRUS apps mount, and Derecho's stack is built for Cray anyway. `module` is
  real Lmod, so `module list` and `module purge` in your start files work, and
  `module load netcdf` fails with Lmod's own recognisable
  `The following module(s) are unknown` rather than `command not found`. The
  NCAR docs advise against `module load` in start files for exactly this kind
  of reason.
- **No `/glade/derecho/scratch`.** `$SCRATCH` is still set, so `cd $SCRATCH`
  fails naming the real path instead of quietly landing in `$HOME`.
- **The hostname in the prompt is `cirrus`**, not the pod's generated name.
  `hostname` still prints the real one. Set `PS1` yourself to change it, or set
  `CIRRUS_TERMINAL_PROMPT_HOST` in `submit.yml.erb` for everyone.

### Why openSUSE, when every sibling app is Ubuntu

Two reasons, and the second matters more.

1. Everything in the table above comes from SUSE itself — `/etc/profile`,
   `/etc/bash.bashrc`, `/etc/csh.cshrc`, the prompt, the PATH rules, the
   package versions — instead of being re-implemented on Ubuntu and drifting.
2. **The shared home stops being a hazard.** The Ubuntu Desktop and RStudio
   apps redirect `XDG_*`, `PYTHONUSERBASE` and the R library into an app
   directory, because something compiled against Ubuntu's glibc 2.39 lands in
   `~/.local` and then breaks on Casper. Here the userland is the HPC one, so a
   terminal can be what a login node is: **another login to the same account,
   writing the same dotfiles**. That is why this app redirects nothing in the
   home. Only sockets, the session password and runtime directories go to the
   pod's own `/tmp/cirrus-terminal`, and the acceptance test checks that no
   socket, agent or password file ever lands in `$HOME`.

Keep `BASE_IMAGE`'s minor version in step with `cat /etc/os-release` on a
Casper login node; the docs say "openSUSE 15", not which 15.x.

## Design

### ttyd behind a password gate

ttyd is one static binary that serves the page, the websocket and a pty per
tab over **one port carrying HTTP and WebSocket**, which is all the OnDemand
node proxy gives an app. It is pinned (1.7.7) and verified against the
release's own `SHA256SUMS` at build time.

ttyd can authenticate on its own, but only with HTTP Basic, which has the same
two problems the Ubuntu Desktop app found with KasmVNC: the dashboard's
Connect button is a form POST and cannot send a Basic header, and browsers
cache Basic credentials per origin, which every session on `ondemand.ucar.edu`
shares. So, like that app, `cirrus-terminal-gate` holds port 8080, turns one
POST from the **Open Terminal** button into a cookie, and relays to ttyd, which
has no credential of its own and listens on `127.0.0.1:7681` only. The session
password comes from the same `init-secret` → `add-passwd-to-cfg` → ConfigMap
path as every other CIRRUS app, and the user never types it.

### One request per connection, enforced by the gate

This is where it differs from the desktop gate. KasmVNC closes every
connection after one response, so checking the first request head *was*
checking every request. ttyd (libwebsockets) honours keep-alive, so a gate that
checked the first request and then relayed blindly would let later requests on
the same connection ride on the first one's cookie — and the other end of that
connection is OnDemand's Apache, which may reuse backend connections.

So for anything that is not a websocket upgrade, the gate forwards only
`GET`/`HEAD`, rewrites `Connection` to `close`, relays the one response, and
never forwards another byte from that client connection. The acceptance test
pipelines two requests on one connection, the second without a cookie, and
requires exactly one response. A websocket upgrade is checked like any
request, since browsers send cookies on the handshake, and is then a blind
relay.

### `/rnode/` and the websocket path

`/rnode/HOST/PORT/` strips its prefix inbound and rewrites `Location` and
cookie `Path` outbound, so the gate's redirect is plain `/` and its cookie
`Path=/`. The proxy turns both into `/rnode/<node>/<port>`, which scopes the
cookie to this one session.

The websocket URL was the thing that broke the Ubuntu Desktop app on its first
live launch, because KasmVNC's client builds it root-absolutely. **ttyd's does
not:**

```js
const path = window.location.pathname.replace(/[/]+$/, '');
const wsUrl = [protocol, '//', window.location.host, path, '/ws', window.location.search].join('');
```

so behind the proxy the client opens `wss://<ondemand>/rnode/<node>/<port>/ws`
and the pod receives `/ws`. Nothing needs injecting. The acceptance test
asserts it against the bundle ttyd actually serves, so a ttyd bump that changed
it would fail there and not in OnDemand. The one place the prefix is still
needed is the fallback login form's `action`, which is in a response body;
`add-baseurl-to-cfg` computes it as in the sibling apps.

### Identity

The pod runs as the user's NFS uid, which has no `/etc/passwd` entry, and the
runtime may synthesise a useless one whose name is the uid. The entrypoint
writes a passwd/group pair under `/tmp` and preloads `libnss_wrapper`, exactly
as the Ubuntu and RStudio apps do — with the addition that the entry's shell is
the user's real login shell (`/bin/tcsh` for a tcsh user), because tmux,
screen and vim's `:shell` read it from there rather than from `$SHELL`.

### Idle culling and session length

ttyd has no API that reports connected clients, so the gate counts open
websockets in `/tmp/cirrus-terminal/clients`. The watchdog in the entrypoint
ends the session **1 hour** after the last tab closes, checking every 5
minutes, and after **12 hours** regardless (also the pod's `wall_time`). An
open tab keeps the session alive even when nobody is typing in it, the same as
the desktop app. Background jobs left running do not: put long work on Derecho
or Casper, or in `tmux` there.

A culled session exits **0** so the pod completes; `restart_policy: OnFailure`
would otherwise bring it straight back. An unreadable count is treated as
"connected", so a broken count can only fail to cull, never cull a session
someone is using. An unplanned exit of ttyd or the gate exits nonzero and gets
the restart.

## Verifying it

```
podman build -t localhost/cirrus-terminal:dev -f image/Dockerfile image
image/test/acceptance.sh
```

Last run on 2026-11-18: 63 checks, all passing. In summary:

```
== 1. arbitrary uid, runtime-synthesised numeric passwd entry ==     6 ok
== 2. arbitrary uid with NO passwd entry at all ==                   1 ok
== 3. a session with no password refuses to start ==                 1 ok
== 4. the session starts; only the gate listens publicly ==          4 ok
== 5. the password gate ==                                           6 ok
== 6. through the gate ==                                            5 ok
  ok   the client builds /ws and /token from window.location.pathname
  ok   two pipelined requests: exactly one response (got 1)
  ok   ...and the connection closed by itself in 0.0s (ttyd honours Connection: close)
== 7. a real login shell over the websocket ==                      26 ok
  ok   ~/.profile was read, as on the login nodes (read)
  ok   SUSE's prompt, with the host shown as cirrus (\u@cirrus:\w> )
  ok   `module list` runs (No modules loaded )
  ok   `ssh derecho` resolves to derecho.hpc.ucar.edu (derecho.hpc.ucar.edu)
  ok   the agent answers with no identities (ssh-add -l exit 1)
  ok   bao-getkey is the vendored upstream (sha256 matches)
== 8. a tcsh user, and ~/.hushlogin ==                               8 ok
== 9. the home directory afterwards ==                               2 ok
  note files the shells wrote, as they would on a login node: ./.bash_history ./.history
== 10. idle watchdog ==                                              2 ok
== 11. tools and versions ==                                         2 ok
```

Section 7 is a real websocket client (`image/test/ttyd_session.py`) speaking
ttyd's protocol through the gate, with a foreign `Origin`, on the path the
client derives behind `/rnode/`. Every shell assertion is made from inside that
shell, not from `podman exec`.

What it does not cover is a browser, or OnDemand's actual Apache. The first
launch in OnDemand is still the first time those are in the path.

### Versions

```
$ podman run --rm --entrypoint terminal-versions localhost/cirrus-terminal:dev
leap             15.6
glibc            2.38
ttyd             1.7.7-40e79c7
bash             4.4-150400.27.6.1
tcsh             6.20.00-150000.4.18.2
lua-lmod         8.7.34-150600.3.2.1
openssh-clients  9.6p1-150600.6.34.1
git              2.51.0-150600.3.15.1
gcc              7-3.9.1
python3          3.6.15-150300.10.118.1
```

`terminal-versions --check` re-resolves each one and diffs against the
record; both CI and the acceptance test run it. The image is about 1.07 GB.

## Assumptions a live launch is the first real test of

1. **`Etc.getpwnam(user.name).shell` on the OnDemand host returns the same
   shell Casper and Derecho use** — that is, the OOD host reads the same
   directory. If it does not, everyone gets bash, which is still the HPC
   default.
2. **The pod's service account can `get` pods and services and `patch`
   configmaps**, as the sibling apps already depend on.
3. **OnDemand's Apache keeps the websocket open between keystrokes.** ttyd
   pings every 5 seconds, which is well inside any sane proxy timeout.

## CI

`.github/workflows/build.yml` is the sibling apps' workflow: it triggers on
pushes to `main` touching `image/**` or the workflow, and on manual dispatch.
It tags `%Y-%m-%d.%H.%M` and pushes to `hub.k8s.ucar.edu/ncote/cirrus-terminal`
with `HARBOR_LOGIN` / `HARBOR_SECRET`.

Before pushing, a smoke test runs the image as an arbitrary uid: the tools are
present (including `ssh`, `ssh-agent`, `ssh-add`, `which`, `jq`, `curl` and
`bao-getkey`), `bao-getkey`'s hash matches, `module` exists in a login shell,
the recorded versions check out, and a real session serves its login page,
lets a signed-in client reach ttyd, runs a command over the websocket, and has
an ssh-agent answering with no identities. A failure fails the build and
nothing is pushed.

**After a successful push from `main`, CI pins the new tag in `submit.yml.erb`
itself** with a `[skip ci]` commit, so pull before editing locally. Until that
first build has run, `terminal_img` is a placeholder (`:unbuilt`) and a launch
fails with ImagePullBackOff.

## Possible next steps

- **Mount `/glade/u/apps`** read-only and point Lmod at Casper's module tree.
  Casper's stack is built for openSUSE 15, which this image is, so much of it
  should simply run. Not done here, because this app is meant to mount exactly
  what the other CIRRUS apps mount.
- **Mount Derecho scratch**, if the storage side allows it, and drop it from
  the motd's "not here" line.
