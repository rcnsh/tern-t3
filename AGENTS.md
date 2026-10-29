# tern-t3

A Tern plugin that drives T3 Code's `t3` CLI. The README's "How it works" covers the files and what each half does, and
"Development" covers the typecheck. Read both first.

## Checks

The typecheck in the README is the only automated check; it must come back with no errors. Run `tern plugin types .`
again after a Tern update so `tern.d.luau` matches the running Tern.

Prove behaviour in a real Tern window as well: the typecheck can't tell whether a toast shows or a link routes.

## Testing in a control window

Start a separate window with a control socket and drive it with `tern ctl` (`tern help dev` lists every command):

```sh
tern --control /tmp/t3.sock <project-dir> &
tern ctl --control /tmp/t3.sock ready
tern ctl --control /tmp/t3.sock palette T3 worktree   # open the palette with a query
tern ctl --control /tmp/t3.sock key enter
tern ctl --control /tmp/t3.sock type '"a message with spaces"'
tern ctl --control /tmp/t3.sock tree '#statusline'    # elements and their text, as JSON
tern ctl --control /tmp/t3.sock shot NAME             # PNG of the window
tern ctl --control /tmp/t3.sock quit
```

- `type` takes one argument: wrap text with spaces in double quotes inside single quotes, as above.
- `tern --control … --open-url 't3-thread://…'` delivers a link at launch, which tests the link route.
- Toasts disappear after a few seconds. Poll `tree` (grep its JSON for the toast text) and `shot` as soon as it appears.
- `shot` writes under `target/shots/` (gitignored) in the directory the window was launched from.
- The window restores your saved Tern session, so tabs it opens stay there afterwards. Close them (`tab <n>`, then
  `tab close`) before `quit`.
- Plugin logs (`tern.log.warn(...)`) go to Tern's log file (`~/Library/Logs/Tern/tern.log` on macOS) with
  `plugin="t3"`.
- To pick up edits in a window, run **Reload plugins** from its palette. `tern plugin reload` reaches only a running
  `tern serve` daemon.

`tern plugin link` points every Tern window at one checkout, so switching branches there changes the code Tern loads on
its next reload. Work on a second change in a separate `git worktree`, and link it only while you test it.

## Tern behaviour to design around

- **The window half reloads on its own** (for example, when Tern reloads its settings), and no `window_start` follows.
  Module state is lost, so start timers at module load, and keep anything that has to persist in `tern.kv`, which every
  window and both halves share.
- **`cx` is short-lived.** Each `:next(fn)` callback gets a fresh `cx`; use that one. A process callback's `cx` can be
  nil: check before calling `cx:toast`.
- **Icons:** use icon names the plugin already uses (`sparkle`, `list`, `open`, `folder`, …). Tern doesn't list valid
  names, and a guessed one may not render.

## `t3` CLI behaviour

- `t3 thread list --project <id>` with an unknown id falls back to the current directory's project instead of failing.
- Thread ids can contain `:` (`mcp:<uuid>`). Links come as `t3-thread://v2/<environment>/<id>`, or
  `t3-thread://v1/<id>` from older builds.
- `t3 <command> --help` is the reference for flags.
- To keep a test thread running across the 15 s status tick, ask its agent for several short foreground commands
  (`sleep 8` six times). A single long `sleep` is often backgrounded, and the turn ends at once.

## Git

Conventional Commits (`feat:`, `fix:`, `docs:`). PRs are squash-merged.
