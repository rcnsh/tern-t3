<div align="center">

# T3 Code for Tern

**Your [T3 Code](https://t3.codes) agent threads, inside the [Tern](https://stencil.so/tern) terminal.**

Start a thread from any pane, hand an agent your failing command, and read and reply to threads
in native Tern blocks, without leaving the terminal.

<img src="docs/thread.png" alt="A Tern window with a T3 thread list on the left and an open thread on the right, showing its status, model, branch, folded messages, a running agent and a message box" width="640">

</div>

## Features

- **Thread list.** Every thread in the project with its status, PR count and age, live while agents work.
- **Thread view.** Title, status, model, branch and PRs, the latest 30 messages (older ones folded to a line) and a message box to reply.
- **Start from the terminal.** Open a new thread in the focused pane's project, optionally in its own git worktree, or send it your terminal output with an instruction such as "Why did this fail? Fix it."
- **Links.** `t3-thread://` links open in Tern; ⌘-click opens them in the T3 Code app.
- **T3 Code as a Tern agent.** Pick T3 Code as Tern's default agent and ⇧⌘A opens a Tern chat backed by a T3 thread.
- **Status line.** `T3 2 running · 1 waiting` for the project you're in. Click it for the thread list.
- **Notifications.** A toast when an agent finishes, fails or starts waiting on you, in any project where one was running.
- **Works anywhere.** Outside a project folder, it asks which project you mean.

<p align="center">
  <img src="docs/picker.png" alt="Tern's picker listing T3 Code projects with their folders" width="480">
</p>

## Install

You need [Tern](https://stencil.so/tern) and the [T3 Code](https://t3.codes)
desktop app on the same machine. The app installs the `t3` CLI this plugin drives.

```sh
tern plugin install github.com/rcnsh/tern-t3
tern plugin list        # t3 0.1.0 T3 Code — 2 blocks, 0 lenses, window  ready
```

To hack on it, clone it and link the clone instead:

```sh
git clone https://github.com/rcnsh/tern-t3 ~/dev/tern-t3
tern plugin link ~/dev/tern-t3
```

## Usage

Open Tern's command palette and type `T3`:

| Command | What it does |
| --- | --- |
| **New T3 thread** | Asks for a message, starts a thread and opens it beside the pane. |
| **New T3 thread in a worktree** | Asks which branch, tag or commit to base it on (the current branch to start with), then for a message, and starts the thread in a new git worktree. |
| **Send terminal output to a new T3 thread** | Asks what you want done, then starts a thread with that, the last command, its exit status and the pane's last 120 lines. |
| **Show T3 threads** | Opens the project's thread list. |
| **Open project in T3 Code** | Opens the project in the desktop app. |

### T3 Code as a Tern agent

`acp/t3-acp.mjs` is an [ACP](https://agentclientprotocol.com) agent that runs T3 Code threads in Tern's own agent chat.
Add it to Tern's `settings.json` (needs Node 22 or newer):

```json
"agents": {
  "custom": [
    {
      "id": "t3",
      "name": "T3 Code",
      "command": "node",
      "args": ["/path/to/tern-t3/acp/t3-acp.mjs"]
    }
  ]
}
```

The path is your clone, or `tern plugin dir`'s `t3` folder for an installed plugin. If Tern can't find `node`, give its
full path. T3 Code then shows up in **Settings › Agents › Agent**, so ⇧⌘A opens it, and `tern acp t3` opens it from a shell.

Each chat is one T3 thread: the first message starts it and later ones send to it. Under the message box, the model chip
lists T3 Code's models by provider (T3's default ticked), and the project chip next to it lists T3 Code's projects,
starting on the one holding the chat's folder, else the most recently used. Both are set when the first message starts
the thread; after that, change them by opening a new chat (`/new`). Tern's session list shows the project's T3 threads,
and opening one loads its messages.

### Keys

| Thread list | |
| --- | --- |
| <kbd>↑</kbd> <kbd>↓</kbd> or <kbd>k</kbd> <kbd>j</kbd> | Move |
| <kbd>↵</kbd> | Open the thread in Tern |
| <kbd>a</kbd> | Open the thread in the T3 Code app |
| <kbd>r</kbd> | Refresh |

| Thread view | |
| --- | --- |
| Type, then <kbd>↵</kbd> | Send a message |
| <kbd>⌥</kbd> <kbd>↵</kbd> | New line |
| <kbd>Esc</kbd> | Clear the message |

## How it works

T3 Code has no plugin system, so this is a Tern plugin that drives T3 Code's `t3` CLI.

| File | Runs in | Holds |
| --- | --- | --- |
| [`host.luau`](host.luau) | Tern's session daemon | The thread list and thread blocks. They refresh every 3 s while an agent works, 15 s otherwise. |
| [`window.luau`](window.luau) | Each Tern window | Palette commands, the `t3-thread://` link route, the status line and notifications. |
| [`common.luau`](common.luau) | Both | Running `t3`, thread statuses, links and the project list. |
| [`acp/t3-acp.mjs`](acp/t3-acp.mjs) | Node, started by Tern's agent chat | The ACP agent: maps chat sessions to T3 threads with `t3 thread start\|send\|show\|list`. |
| [`acp/catalog.mjs`](acp/catalog.mjs) | Node | The agent's project and model lists, read from T3 Code's files. |

- Threads come from `t3 thread list|show|start|send`; the app opens with `t3 app` or a `t3code://threads/<environment>/<thread>` link.
- The CLI can't list projects, so the picker reads them read-only from T3 Code's state database
  (`~/.t3/userdata/statev2.sqlite`) with `/usr/bin/sqlite3`. A T3 Code update that changes that schema would break the picker.
- The agent chat's model list comes from T3 Code's `model-manifest.json` (current models per provider), the enabled
  providers, their custom models and your favourites in its `settings.json` (favourites fall back to
  `client-settings.json` while unset), all under `~/.t3/userdata`, read-only. Its project list comes from the same state database as the picker.
- The status line runs `t3` only for folders inside a project.
- Notifications track running threads in the plugin's `kv.json`, shared by every window, and check their projects every 15 s
  whichever pane has focus. A thread that starts and stops between checks is announced only when it was started from Tern.

## Limits

- **Polling, not streaming.** Tern plugins can only run a process to completion and can't open a WebSocket, so views refresh on a timer.
- **The agent chat shows whole messages.** `t3 thread show` reports finished messages only, so a reply appears a message
  at a time (polled every second), with no tool calls or thinking.
- **Opening a running thread.** Opening a thread from Tern's session list shows its finished messages; replies from a
  run still going show up after your next message.
- **Stopping.** Esc in the agent chat stops following the turn, but the `t3` CLI can't interrupt a run, so it carries on
  in T3 Code.
- **Agent questions.** When an agent asks you something (`waiting`), answer it in the T3 Code app. The agent chat says so
  and links to the thread.
- **Desktop only.** Tern's iOS client can't run processes, and its web tab runs no plugin code.

## Development

```sh
tern plugin types .     # writes tern.d.luau (gitignored)
luau-lsp analyze --platform=standard --definitions=@tern=tern.d.luau common.luau host.luau window.luau
tern plugin reload      # pick up edits
```

`luau-lsp` comes from its [GitHub releases](https://github.com/JohnnyMorganz/luau-lsp/releases).
To test in a separate window, start one with `tern --control /tmp/t3.sock ~/some/project` and drive it with
`tern ctl --control /tmp/t3.sock plugins run plugin.t3.threads`.

## License

[MIT](LICENSE)
