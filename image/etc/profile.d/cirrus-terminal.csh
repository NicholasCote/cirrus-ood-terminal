# CIRRUS Terminal: the csh/tcsh twin of cirrus-terminal.sh -- read it for the
# reasons. Sourced by /etc/csh.login for every tcsh login shell, before the
# user's own ~/.tcshrc and ~/.login. Every value is only filled in when missing.

if ( $?USER ) then
    if ( ! $?WORK )    setenv WORK    /glade/work/${USER}
    if ( ! $?SCRATCH ) setenv SCRATCH /glade/derecho/scratch/${USER}
endif

if ( ! $?NCAR_HOST ) setenv NCAR_HOST cirrus

if ( $?CIRRUS_TERMINAL_STATE_DIR ) then
    if ( -d "${CIRRUS_TERMINAL_STATE_DIR}" ) then
        if ( ! $?XDG_RUNTIME_DIR ) setenv XDG_RUNTIME_DIR "${CIRRUS_TERMINAL_STATE_DIR}/run"
        if ( ! $?TMPDIR )          setenv TMPDIR          "${CIRRUS_TERMINAL_STATE_DIR}/tmp"
        if ( ! $?TMUX_TMPDIR )     setenv TMUX_TMPDIR     "${CIRRUS_TERMINAL_STATE_DIR}/run"
    endif
endif

if ( ! $?SSH_AUTH_SOCK ) then
    if ( -S /tmp/cirrus-terminal/ssh-agent.sock ) setenv SSH_AUTH_SOCK /tmp/cirrus-terminal/ssh-agent.sock
endif
