# CIRRUS Terminal: the parts of the Casper/Derecho login environment that are
# not just "the same OS". Read by every login shell of the sh family (bash, ksh,
# zsh via /etc/zprofile) through /etc/profile, before the user's own ~/.profile,
# so anything a user sets there still wins.
#
# Every value is only filled in when missing.

if [ -n "${USER:-}" ]; then
    # The NCAR names for the GLADE spaces, as documented for PBS jobs and login
    # sessions on both systems. $SCRATCH is set even though Derecho scratch is
    # not mounted in this app: a script that does `cd $SCRATCH` should fail
    # with "No such file or directory" naming the real path, not quietly land
    # in $HOME because the variable was empty.
    : "${WORK:=/glade/work/${USER}}"
    : "${SCRATCH:=/glade/derecho/scratch/${USER}}"
    export WORK SCRATCH
fi

# The host class, as NCAR's modules set it ("derecho", "casper"). Scripts
# branch on this, and the honest answer here is neither.
: "${NCAR_HOST:=cirrus}"
export NCAR_HOST

# Runtime state on the pod's /tmp, for a shell that did not inherit it.
if [ -n "${CIRRUS_TERMINAL_STATE_DIR:-}" ] && [ -d "${CIRRUS_TERMINAL_STATE_DIR}" ]; then
    : "${XDG_RUNTIME_DIR:=${CIRRUS_TERMINAL_STATE_DIR}/run}"
    : "${TMPDIR:=${CIRRUS_TERMINAL_STATE_DIR}/tmp}"
    : "${TMUX_TMPDIR:=${CIRRUS_TERMINAL_STATE_DIR}/run}"
    export XDG_RUNTIME_DIR TMPDIR TMUX_TMPDIR
fi

# The session's ssh-agent, for bao-getkey and ssh to Casper/Derecho. Every tab
# inherits SSH_AUTH_SOCK from the entrypoint; this is a fallback for a shell
# that lost it. Only when unset, so a user's own agent is left alone.
if [ -z "${SSH_AUTH_SOCK:-}" ] && [ -S "${CIRRUS_TERMINAL_STATE_DIR:-/tmp/cirrus-terminal}/ssh-agent.sock" ]; then
    SSH_AUTH_SOCK="${CIRRUS_TERMINAL_STATE_DIR:-/tmp/cirrus-terminal}/ssh-agent.sock"
    export SSH_AUTH_SOCK
fi
