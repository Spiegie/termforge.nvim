-- Commands for termforge.launch (<leader>ll). Placeholders, see
-- :h termforge-commands:
--   {file}, {file_basename}, {file_dirname}  file buffer visited last
--   {cwd}                                    terminal's live working dir
--   {root}                                   project root of {cwd} (git
--                                            worktree root, or {cwd})
--   {git_branch}                             branch checked out in {cwd}
--   {selection}                              last visual selection in that
--                                            file buffer
--   {cursor}                                 removed; the edit prompt opens
--                                            with the cursor at that spot
return {
  { name = "build", cmd = "echo hello" },
  { name = "flake-build", cmd = "nix build .#" },
  { name = "flake-test", cmd = "nix run .#test" },
  { name = "format", cmd = "nix develop -c stylua {file}" },
  { name = "refs", cmd = "rg -n {file_basename}" },
  { name = "search", cmd = "rg -n {selection}" },
  { name = "format-dir", cmd = "nix develop -c stylua {file_dirname}" },
  { name = "ls", cmd = "ls -la {cwd}" },
  { name = "attr", cmd = "nix build {cursor}.#" },
  { name = "rg-root", cmd = "rg -n --hidden {selection} {root}" },
  { name = "push", cmd = "git push origin {git_branch}" },
}
