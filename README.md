# T3 Code for Tern

A [Tern](https://docs.stencil.so/tern/) plugin that brings [T3 Code](https://github.com/pingdotgg/t3code)
threads into your terminal. It drives the local `t3` CLI (`t3 thread list|show|start|send`, `t3 app`), so
it needs T3 Code running on the machine that runs your panes.

## What it adds

| Where | What |
| --- | --- |
| Palette | **New T3 thread here**: asks for a message and starts a thread in the focused pane's project, opened beside it. |
| Palette | **Ask T3 about the last command**: starts a thread with your instruction, the last command, its exit status and the pane's recent output. |
| Palette | **Show T3 threads**: a block listing the project's threads (↑/↓, ↵ open, `a` open in the app, `r` refresh). |
| Palette | **Open project in T3 Code**: `t3 app <cwd>`. |
| Block | **T3 thread**: title, status, model, branch, PRs and the latest 30 messages (older ones folded); type and ↵ to send, ⌥↵ for a new line, Esc to clear. Polls every 3 s while the agent works, 15 s otherwise. |
| Links | `t3-thread://v1/<id>` opens a thread block; ⌘-click opens the thread in the desktop app (`t3code://threads/<env>/<id>`). |
| Status line | `T3 2 running · 1 waiting` for the focused pane's project; click to open the thread list. |

Directories that aren't a T3 Code project are skipped (add one with `t3 project add <dir>`).

## Install

```sh
tern plugin link ~/dev/tern-t3     # use it in place
tern plugin reload                 # after editing
```

## Develop

```sh
tern plugin types .                # writes tern.d.luau (gitignored)
luau-lsp analyze --platform=standard --definitions=@tern=tern.d.luau common.luau host.luau window.luau
```

`host.luau` holds the two blocks (it runs in Tern's session daemon), `window.luau` the commands, link route
and status segment, and `common.luau` the `t3` runner, statuses and links both halves share.

## Limits

- No live stream: Tern plugins can only run processes to completion, and `tern.fetch` has no WebSocket, so
  views poll the CLI.
- Questions an agent asks (status `waiting`) must be answered in the T3 Code app.
- Needs a desktop Tern: iOS has no processes, and the web tab runs no plugin code.
