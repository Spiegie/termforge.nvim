# termforge.nvim shell integration — notify Neovim when a command finishes.
#
# Source this from your .zshrc. It is a no-op unless the shell runs inside
# a Neovim :terminal ($NVIM is set there). After every command the shell
# writes "<exit> <duration> <command>" to /tmp/termforge-cmd-<pid>; Neovim
# picks the file up and turns it into a notification.
if [[ -n "$NVIM" ]]; then
  zmodload zsh/datetime

  typeset -g _TERMFORGE_START=''
  typeset -g _TERMFORGE_CMD=''

  _termforge_preexec() {
    _TERMFORGE_START=$EPOCHSECONDS
    _TERMFORGE_CMD=${1//$'\n'/ }
  }

  _termforge_precmd() {
    local exit_code=$?
    if [[ -n "$_TERMFORGE_START" ]]; then
      printf '%s %s %s\n' "$exit_code" "$(( EPOCHSECONDS - _TERMFORGE_START ))" "$_TERMFORGE_CMD" >| "/tmp/termforge-cmd-$$"
      _TERMFORGE_START=''
      _TERMFORGE_CMD=''
    fi
  }

  autoload -Uz add-zsh-hook
  add-zsh-hook preexec _termforge_preexec
  add-zsh-hook precmd _termforge_precmd
fi
