# termforge.nvim shell integration — notify Neovim when a command finishes.
#
# Source this from your .bashrc, after bash-preexec if you use it. It is a
# no-op unless the shell runs inside a Neovim :terminal ($NVIM is set
# there). After every command the shell writes "<exit> <duration>
# <command>" to /tmp/termforge-cmd-<pid>; Neovim picks the file up and
# turns it into a notification.
if [[ -n "${NVIM:-}" ]]; then
  _termforge_preexec() {
    _TERMFORGE_START=${EPOCHSECONDS:-$SECONDS}
    _TERMFORGE_CMD=${1//$'\n'/ }
  }

  _termforge_precmd() {
    local exit_code=$?
    if [[ -n "${_TERMFORGE_START:-}" ]]; then
      local now=${EPOCHSECONDS:-$SECONDS}
      printf '%s %s %s\n' "$exit_code" "$(( now - _TERMFORGE_START ))" "${_TERMFORGE_CMD:-}" >| "/tmp/termforge-cmd-$$"
      _TERMFORGE_START=''
      _TERMFORGE_CMD=''
    fi
  }

  if [[ $(trap -p DEBUG) == *bp_preexec* ]]; then
    # bash-preexec is loaded: hook into its precmd/preexec mechanism.
    preexec() { _termforge_preexec "$1"; }
    precmd() { _termforge_precmd; }
  else
    # Without functrace the DEBUG trap only fires for top-level commands,
    # which is exactly what we need; guard our own prompt hook anyway.
    # The PROMPT_COMMAND assignment must happen before the trap is
    # installed, otherwise it triggers the trap itself while sourcing.
    _termforge_debug() {
      case $BASH_COMMAND in
      _termforge*) return ;;
      esac
      _termforge_preexec "$BASH_COMMAND"
    }
    PROMPT_COMMAND="_termforge_precmd${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
    trap _termforge_debug DEBUG
  fi
fi
