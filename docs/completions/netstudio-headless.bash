# bash completion for netstudio-headless
# Install: sudo cp this file /usr/share/bash-completion/completions/netstudio-headless

_netstudio_headless() {
    local cur prev
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    case "$prev" in
        -c|--config|--output|--pid-file|--http-token-file)
            COMPREPLY=( $(compgen -f -- "$cur") )
            return 0
            ;;
        --format)
            COMPREPLY=( $(compgen -W "auto json text" -- "$cur") )
            return 0
            ;;
        --color)
            COMPREPLY=( $(compgen -W "auto always never" -- "$cur") )
            return 0
            ;;
        --log-level)
            COMPREPLY=( $(compgen -W "error warn info debug" -- "$cur") )
            return 0
            ;;
        --log-format)
            COMPREPLY=( $(compgen -W "text json" -- "$cur") )
            return 0
            ;;
        --listen)
            COMPREPLY=( $(compgen -W "127.0.0.1:9101 0.0.0.0:9101" -- "$cur") )
            return 0
            ;;
        --interval|--probe-interval|--probe-concurrency|--watch-config)
            COMPREPLY=()
            return 0
            ;;
    esac

    local options="
        -c --config --check --once --interval --probe-interval
        --probe-concurrency --watch-config --listen --output --pid-file
        --http-token-file
        -q --quiet --format --color --no-color --log-level --log-format
        -h --help -V --version
    "
    COMPREPLY=( $(compgen -W "$options" -- "$cur") )
}
complete -F _netstudio_headless netstudio-headless