# termforge.nvim shell integration — notify Neovim when a command finishes.
#
# Source this from your config.fish. It is a no-op unless the shell runs
# inside a Neovim :terminal ($NVIM is set there). After every command the
# shell writes "<exit> <duration> <command>" to /tmp/termforge-cmd-<pid>;
# Neovim picks the file up and turns it into a notification.
if test -n "$NVIM"
    function _termforge_preexec --on-event fish_preexec
        set -g _termforge_start (date +%s)
        set -g _termforge_cmd (string replace -a \n ' ' -- $argv[1])
    end

    function _termforge_postexec --on-event fish_postexec
        set -l exit_code $status
        if set -q _termforge_start
            printf '%s %s %s\n' $exit_code (math (date +%s) - $_termforge_start) "$_termforge_cmd" > /tmp/termforge-cmd-$fish_pid
            set -e _termforge_start
            set -e _termforge_cmd
        end
    end
end
