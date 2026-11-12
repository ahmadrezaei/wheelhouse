# Wheelhouse shell integration (fish), sourced through `fish --init-command 'source <this>'` for ONE session.
# fish reads the user's config.fish before this runs; the app points XDG_CONFIG_HOME at an empty folder while development safety is active (DeckTerminalSession.configuration).

# The nonce is read first, kept in a global, unexported variable, and the file is removed.
if status is-interactive; and not set -q __wh_nonce; and set -q WH_SESSION_DIR; and test -r "$WH_SESSION_DIR/nonce"
    set -l __wh_read (string trim < "$WH_SESSION_DIR/nonce")
    command rm -f -- "$WH_SESSION_DIR/nonce" 2>/dev/null
    if string match -qr '^[0-9a-f]{32}$' -- $__wh_read
        set -g __wh_nonce $__wh_read
    end
end

# The session kubeconfig wins over whatever the user's files set.
if set -q WH_KUBECONFIG; and test "$KUBECONFIG" != "$WH_KUBECONFIG"
    if set -q KUBECONFIG; and test -t 2
        printf '\e[2mwheelhouse: KUBECONFIG from your shell startup files is overridden in this guarded session\e[0m\n' >&2
    end
    set -gx KUBECONFIG $WH_KUBECONFIG
end

set -q __wh_nonce; or exit 0

function __wh_emit
    printf '\e]%s;wh=%s\a' $argv[1] $__wh_nonce >/dev/tty 2>/dev/null
end

function __wh_escape
    string replace -a '\\' '\\\\' -- $argv[1] | string replace -a ';' '\\x3b' | string replace -a \n '\\x0a' | string replace -a \r '\\x0d' | string replace -a \e '\\x1b' | string replace -a \a '\\x07' | string replace -a \cX '\\x18' | string replace -a \cZ '\\x1a'
end

function __wh_report_state
    if set -q KUBECONFIG
        __wh_emit "633;P;KubeConfig="(__wh_escape "$KUBECONFIG")
    else
        __wh_emit "633;P;KubeConfigUnset=1"
    end
end

set -g __wh_running 0

function __wh_preexec --on-event fish_preexec
    set -l line (__wh_escape "$argv[1]")
    # An alias or function is not what runs: no line is reported.
    set -l first (string split -m1 ' ' -- $argv[1])[1]
    if functions -q -- $first
        set line ""
    end
    __wh_emit "633;E;$line"
    __wh_report_state
    __wh_emit "133;C"
    set -g __wh_running 1
end

function __wh_postexec --on-event fish_postexec
    __wh_emit "133;D;$status"
    set -g __wh_running 0
end

function __wh_prompt_mark --on-event fish_prompt
    __wh_report_state
    __wh_emit "633;P;Cwd="(__wh_escape "$PWD")
    __wh_emit "133;A"
end
