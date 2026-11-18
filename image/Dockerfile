# CIRRUS Terminal image
#
# One Open OnDemand Batch Connect app: a shell in the browser, served by ttyd,
# running as a pod on the CIRRUS Kubernetes cluster with the user's GLADE home
# mounted -- set up to feel like a login to Casper or Derecho.
#
# ---------------------------------------------------------------------------
# Why openSUSE Leap 15, and not the Ubuntu the sibling apps use
#
# Casper runs openSUSE 15 and Derecho runs SUSE Linux Enterprise 15. Leap 15.6
# is built from the same sources as SLES 15 SP6, so this image's userland is
# the HPC one rather than an approximation of it:
#
#   bash 4.4, tcsh 6.20, gcc 7 as the system compiler, python3 3.6, glibc 2.38,
#   SUSE's own /etc/profile, /etc/bash.bashrc and /etc/csh.cshrc -- so the
#   default prompt is the familiar  user@host:~>  and ~/bin and ~/.local/bin
#   are on PATH because SUSE's /etc/profile puts them there, exactly as on the
#   login nodes.
#
# It is also why this app, unlike the Ubuntu Desktop and RStudio ones, does not
# fence the user's dotfiles off into an app directory. Those apps keep
# ~/.local, pip --user and compiled R packages away from Casper and Derecho
# because a binary built against Ubuntu's glibc 2.39 is not one the HPC systems
# can run. Here it is the same OS family, and the point of the app is to be
# another login to the same account. Match BASE_IMAGE's minor version to
# `cat /etc/os-release` on a Casper login node when either side moves.
#
# Why ttyd: it is one static binary that serves the page, the websocket and a
# pty per tab, over ONE port carrying HTTP and WebSocket, which is all the
# OnDemand node proxy gives an app. Its client builds the websocket URL from
# window.location.pathname, so it works behind /rnode/<node>/<port>/ without
# the query-parameter injection the Ubuntu Desktop gate needs for KasmVNC. See
# image/bin/cirrus-terminal-gate for both.
# ---------------------------------------------------------------------------
ARG BASE_IMAGE=registry.opensuse.org/opensuse/leap:15.6
FROM ${BASE_IMAGE}

ARG BASE_IMAGE

# Pinned, with the checksum from ttyd's own SHA256SUMS for this release
# (checked against a fresh download on 2026-11-18). Bump deliberately and re-run
# image/test/acceptance.sh: it asserts the client's URL construction and the
# server's Connection: close handling, either of which a release could change.
ARG TTYD_VERSION=1.7.7
ARG TTYD_SHA256=8a217c968aba172e0dbf3f34447218dc015bc4d5e59bf51db2f2cd12b7be4f55

ENV CIRRUS_TERMINAL_HOME=/opt/cirrus-terminal

# ---------------------------------------------------------------------------
# Packages: what a Casper or Derecho login node has without loading a module.
#
# man, man-pages and coreutils-doc, because a login node answers `man ls` and
# this should too. SUSE ships the coreutils man pages in coreutils-doc, not in
# coreutils -- without it `man ls` says "No manual entry" while `man ssh`
# works, which looks like a broken man rather than a missing package. (The Leap
# image does NOT exclude docs; rpm.install.excludedocs is commented out in its
# zypp.conf, so everything else installed here brings its man pages.)
#
# Shells          bash (the default for new accounts), tcsh (the other one
#                 NCAR documents), zsh and ksh, so whatever SAM says a user's
#                 shell is, it exists here. cirrus-terminal-shell falls back to
#                 bash, and says so, for anything else.
# lua-lmod        the `module` command, as on both systems. The NCAR module
#                 tree is NOT here -- it lives under /glade/u/apps, which this
#                 app does not mount, and Derecho's is built for Cray anyway --
#                 so `module load netcdf` fails with Lmod's own, recognisable
#                 "unknown module" message rather than "command not found".
# nss_wrapper     the arbitrary-uid case: the pod runs as the user's NFS uid,
#                 which has no passwd entry, and the prompt, whoami, git and ssh
#                 all ask for one.
# openssh-clients ssh, scp, sftp, ssh-agent, ssh-add: to Derecho and Casper,
#                 for git over ssh, and for bao-getkey (below).
# curl jq which   what bao-getkey needs, which is checked by name in its own
#                 first lines (`which curl`).
# python3         the gate, standard library only. Also the system python3 a
#                 user would find on the login nodes, at the same version.
# glibc-locale-base, timezone
#                 en_US.UTF-8 and America/Denver, which is what the HPC
#                 systems use.
# gcc gcc-c++ gcc-fortran make
#                 the SUSE system compiler -- gcc 7, as on the login nodes
#                 before `module load gcc`. Quick builds and pip packages with
#                 C extensions work; anything serious belongs on Derecho.
# ---------------------------------------------------------------------------
RUN set -eux; \
    zypper -n --gpg-auto-import-keys refresh; \
    zypper -n update --no-recommends; \
    zypper -n install --no-recommends \
        bash tcsh zsh ksh \
        lua-lmod \
        nss_wrapper \
        openssh-clients \
        curl jq which ca-certificates-mozilla \
        python3 \
        glibc-locale-base timezone \
        git git-lfs \
        vim emacs-nox nano less \
        man man-pages coreutils-doc \
        tmux screen \
        rsync wget \
        tar gzip bzip2 xz zstd unzip zip \
        file tree htop time bc \
        procps psmisc ncurses-utils util-linux \
        findutils diffutils patch gawk grep sed \
        hostname iproute2 iputils bind-utils \
        gcc gcc-c++ gcc-fortran make; \
    zypper -n clean -a; \
    rm -rf /var/log/zypp* /var/cache/zypp

# ---------------------------------------------------------------------------
# ttyd: a static binary, verified against the release's own checksum.
# `ttyd --version` doubles as proof that the binary runs on this userland.
# ---------------------------------------------------------------------------
RUN set -eux; \
    curl -fsSL -o /usr/local/bin/ttyd \
        "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.x86_64"; \
    echo "${TTYD_SHA256}  /usr/local/bin/ttyd" | sha256sum -c -; \
    chmod 0755 /usr/local/bin/ttyd; \
    ttyd --version

# --- bao-getkey -------------------------------------------------------------
# HSG's OpenBao client (NCAR/hsg-openbao-scripts, MIT). One password+Duo login
# mints a short-lived signed SSH certificate and loads it into ssh-agent, so
# ssh to Casper/Derecho stops prompting for ncar-two-factor.
#
# Vendored because the upstream repo is internal to the NCAR org and an
# unauthenticated build cannot fetch it. Verbatim copy of bin/bao-getkey at
# commit ef6b7a7503c911977865df50df3b4d4fc223c25b, sha256
# 9fee1714bd7b149dec56798304350642167cae3eb9236aecfbc44fd39dc7bf9e -- the same
# file the Ubuntu Desktop, RStudio and VS Code apps ship. Checked here, in CI
# and in image/test/acceptance.sh. The entrypoint starts the ssh-agent it loads
# into.
COPY bao-getkey /usr/local/bin/bao-getkey
RUN set -eux; \
    echo "9fee1714bd7b149dec56798304350642167cae3eb9236aecfbc44fd39dc7bf9e  /usr/local/bin/bao-getkey" \
        | sha256sum -c -; \
    chmod 0755 /usr/local/bin/bao-getkey

# ---------------------------------------------------------------------------
# Our scripts and the system shell configuration. Plain COPY + chmod rather
# than COPY --chmod, which older buildah lacks.
#
#   /etc/profile.d/cirrus-terminal.{sh,csh}  $WORK, $SCRATCH, $NCAR_HOST, and
#                                            fallbacks for the session's state
#   /etc/bash.bashrc.local, /etc/csh.cshrc.local
#                                            SUSE's own hooks for site prompt
#                                            settings; see the files
#   /etc/motd                                printed by cirrus-terminal-shell
#                                            unless ~/.hushlogin exists
#   /etc/ssh/ssh_config.d/                   `ssh derecho`, `ssh casper`
# ---------------------------------------------------------------------------
COPY bin/entrypoint.sh            /usr/local/bin/entrypoint.sh
COPY bin/cirrus-terminal-gate     /usr/local/bin/cirrus-terminal-gate
COPY bin/cirrus-terminal-shell    /usr/local/bin/cirrus-terminal-shell
COPY bin/terminal-versions        /usr/local/bin/terminal-versions
COPY etc/profile.d/cirrus-terminal.sh  /etc/profile.d/cirrus-terminal.sh
COPY etc/profile.d/cirrus-terminal.csh /etc/profile.d/cirrus-terminal.csh
COPY etc/bash.bashrc.local        /etc/bash.bashrc.local
COPY etc/csh.cshrc.local          /etc/csh.cshrc.local
COPY etc/motd                     /etc/motd
COPY etc/ssh/ssh_config.d/50-cirrus-hpc.conf /etc/ssh/ssh_config.d/50-cirrus-hpc.conf
RUN set -eux; \
    chmod 0755 /usr/local/bin/entrypoint.sh /usr/local/bin/cirrus-terminal-gate \
               /usr/local/bin/cirrus-terminal-shell /usr/local/bin/terminal-versions; \
    chmod 0644 /etc/profile.d/cirrus-terminal.sh /etc/profile.d/cirrus-terminal.csh \
               /etc/bash.bashrc.local /etc/csh.cshrc.local /etc/motd \
               /etc/ssh/ssh_config.d/50-cirrus-hpc.conf; \
    python3 -m py_compile /usr/local/bin/cirrus-terminal-gate; \
    rm -rf /usr/local/bin/__pycache__

# ---------------------------------------------------------------------------
# Resolved versions, recorded once at build time so a bug report can name them,
# and the nss_wrapper library path, resolved here rather than in every session.
# ---------------------------------------------------------------------------
RUN set -eux; \
    mkdir -p "${CIRRUS_TERMINAL_HOME}"; \
    rpmv() { rpm -q --qf '%{VERSION}-%{RELEASE}' "$1"; }; \
    { \
      echo "# CIRRUS Terminal image -- resolved versions"; \
      echo "# name<TAB>expected version"; \
      printf 'base-image\t%s\n' "${BASE_IMAGE}"; \
      printf 'leap\t%s\n'       "$(. /etc/os-release; echo "${VERSION_ID}")"; \
      printf 'glibc\t%s\n'      "$(ldd --version | head -1 | awk '{print $NF}')"; \
      printf 'ttyd\t%s\n'       "$(ttyd --version | awk '{print $3}')"; \
      for p in bash tcsh zsh ksh lua-lmod openssh-clients git gcc python3; do \
        printf '%s\t%s\n' "$p" "$(rpmv "$p")"; \
      done; \
      printf 'bao-getkey\t%s\n' "$(sha256sum /usr/local/bin/bao-getkey | awk '{print $1}')"; \
    } > "${CIRRUS_TERMINAL_HOME}/versions.txt"; \
    lib="$(rpm -ql nss_wrapper | grep -E '/libnss_wrapper\.so(\.[0-9]+)*$' | sort | tail -1)"; \
    test -n "$lib" && test -r "$lib"; \
    echo "$lib" > "${CIRRUS_TERMINAL_HOME}/nss_wrapper_lib"; \
    chmod -R a+rX "${CIRRUS_TERMINAL_HOME}"

# ---------------------------------------------------------------------------
# Runtime defaults. In the OOD path submit.yml.erb sets the session ones; these
# exist so the image runs standalone for local testing.
# ---------------------------------------------------------------------------
ENV LANG=en_US.UTF-8 \
    TZ=America/Denver \
    CIRRUS_TERMINAL_PORT=8080 \
    CIRRUS_TERMINAL_STATE_DIR=/tmp/cirrus-terminal \
    CIRRUS_TERMINAL_AUTH=password \
    CIRRUS_TERMINAL_PROMPT_HOST=cirrus

EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["terminal"]
