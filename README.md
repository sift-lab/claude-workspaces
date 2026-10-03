<p align="center"><img src="Resources/AppIcon.svg" width="128" alt="Workspaces icon"></p>

# Claude Workspaces

A native macOS app that organizes your [Claude Code](https://docs.claude.com/en/docs/claude-code) sessions by workspace. One window per workspace, projects in a sidebar, several sessions per project, and a menu bar that tells you which session is waiting for you.

It also keeps idle sessions cheap: sessions you are not looking at are frozen after a few minutes and hibernated later, and come back when you open them.

> Unofficial. Not affiliated with or endorsed by Anthropic.

[Resumo em português](#resumo-em-português)

<p align="center"><img src="docs/screenshots/window.png" alt="A workspace window: projects and sessions in the sidebar, a session asking for permission in the terminal"></p>

## Screenshots

| Grid | Usage |
|---|---|
| <img src="docs/screenshots/grid.png" alt="Grid of every session in the workspace"> | <img src="docs/screenshots/usage.png" alt="Memory and CPU of each session"> |
| **Settings** | **Menu bar** |
| <img src="docs/screenshots/settings.png" alt="Settings with freeze and hibernate delays"> | <img src="docs/screenshots/menubar.png" alt="Menu bar with the sessions waiting for you"> |

The screenshots come from a demo workspace with made-up projects (`./scripts/screenshots.sh`), and the app takes them of its own windows. The UI is in Portuguese.

## Features

- **Workspaces and projects.** Group projects (folders) into workspaces such as "Work" or "Personal". Each workspace opens in its own window, with `⌃1` to `⌃9` to switch.
- **Many sessions per project.** Each session is a real Claude Code terminal (SwiftTerm), named after its git branch or worktree. New sessions can open in the project folder or in a fresh `claude --worktree`.
- **Knows what each session is doing.** Claude Code hooks report "working", "waiting for you", "done" and "idle". Sessions that need you are highlighted, counted in the menu bar and the Dock, and can send a notification.
- **Grid view.** See every session of a workspace at once, with the last lines of each terminal.
- **MCP integration.** Every session gets a `workspaces` MCP server, so Claude can list sibling sessions, report what it is doing, open a new session, hand a message to another session, or ask for your attention.
- **Sleep for idle sessions.** A session that is off screen, not waiting for you and not running a command is frozen (`SIGSTOP`, zero CPU, instant wake) and later hibernated (the process ends and the conversation resumes with `claude --resume` when you open it).
- **Tokens and the limit.** Next to each session's state, how much context it carries (and whether it is climbing fast or close to the ceiling); a popover shows the context through the day, each compaction, when the next one comes at the current pace, and the session's part of the 5 h window. The toolbar ring shows the 5 h window; the menu bar shows both windows of the account's limit with where they land at the current pace, and a notification comes when the 5 h window would run out before it resets.
- **Usage screen.** "Agora": the 5 h window and the week with their projections, and every session's context, last-hour trend and share of the window. "Semana": spend per day and workspace, what weighs the most (rereading context, agents, models) and the heaviest sessions. A session opens in full: context and spend every 5 minutes, side by side, and the stretches between compactions. "Máquina": memory and CPU of every session (Claude plus its MCP servers), totals, and how much hibernation freed.
- **Resume on relaunch.** Sessions reopen with their conversations when you open a workspace again.

## Requirements

- macOS 14 or later (built and tested on macOS 26).
- [Claude Code](https://docs.claude.com/en/docs/claude-code) installed and available as `claude` in your login shell.
- Xcode 16 or later (Swift 6 toolchain) to build.

## Build and install

```sh
git clone https://github.com/gabriel-kohler/claude-workspaces.git
cd claude-workspaces
./scripts/build-app.sh --install   # builds build/Workspaces.app and copies it to ~/Applications
open ~/Applications/Workspaces.app
```

Run the tests with `swift test`. To regenerate the icon after editing `Resources/AppIcon.svg`, run `swift scripts/make-icon.swift`.

You can open a workspace from the command line (handy for Raycast or Alfred):

```sh
open -a Workspaces --args --open "Work"
```

## How it works

- **No changes to your Claude Code setup.** Each session starts `claude` with `--settings` (hooks) and `--mcp-config` (the MCP server) pointing to files in `~/Library/Application Support/Workspaces/`. Your `~/.claude` settings are left untouched.
- **Hooks** run a tiny helper (`workspaces-hook`, Foundation only) that forwards the event to the app over a unix socket. It never blocks Claude.
- **MCP** is served by the app itself over HTTP on `127.0.0.1`, with a random token per launch, so no helper process runs per session.
- **Tokens** are read from Claude Code's transcripts in `~/.claude/projects` (two weeks, each file from where the last read stopped; agents count toward the session that started them). The account's limit comes from the status line: the settings file sets `statusLine` to the hook helper, which tells the app what Claude Code reported (`context_window`, `rate_limits`) and then prints your own status line, if you have one. Weighing tokens by API price turns them into one number; readings of the meter calibrate how much of it fills each window.
- **Launch.** The app reads your login shell environment once and then starts `claude` directly, so each session skips the cost of a login shell. Commands that need shell syntax fall back to the login shell.
- **Crash safety.** On `SIGTERM` the app closes its sessions; on launch it ends orphaned sessions left by a crashed run (only processes that carry its own settings file).

### MCP tools

| Tool | What it does |
|---|---|
| `list_sessions` | Lists sessions by workspace and project, with state, memory and id. |
| `set_status` | Sets the short phrase shown next to the session ("running the tests"). |
| `open_session` | Opens a new session in a project, optionally in a new worktree and with a first prompt. |
| `send_message` | Types a message into another session's prompt without sending it. Wakes it if asleep. |
| `notify` | Sends a macOS notification asking for your attention. |
| `close_session` | Closes a finished session of the same workspace. Off by default. |

Each tool can be turned off in Settings. Claude Code asks for permission the first time a session uses each one.

### Configuration

Settings live in `~/Library/Application Support/Workspaces/workspaces.json` and can be edited in the app. Per project you can set where new sessions open, how many open with the workspace, and extra `claude` arguments (for example `--add-dir ../api`). Freeze and hibernate delays are in Settings, under "Economia".

## Project layout

- `Sources/WorkspacesCore`: models, config, IPC, hook mapping, MCP protocol, sleep policy, HTTP parsing. No UI, fully unit tested.
- `Sources/Workspaces`: the SwiftUI app, terminal hosting, servers, usage monitor.
- `Sources/WorkspacesHook`: the hook helper.
- `Tests/WorkspacesCoreTests`: tests for the core.

## Resumo em português

App nativo para macOS que organiza as sessões do Claude Code por workspace: uma janela por workspace, projetos na barra lateral, várias sessões por projeto e uma barra de menu que mostra qual sessão está esperando você.

- Cada sessão é um terminal de verdade com o Claude Code, nomeado pela branch ou worktree.
- Os hooks do Claude Code informam o estado de cada sessão; as que precisam de você ficam em destaque e podem notificar.
- Cada sessão ganha um servidor MCP `workspaces` para ver as outras sessões, dizer o que está fazendo, abrir sessões, mandar recados e pedir atenção.
- Sessões paradas e fora da tela congelam (CPU zero) e depois hibernam (o processo encerra e a conversa volta com `claude --resume` ao abrir).
- Cada sessão mostra o contexto que carrega, se está subindo rápido ou perto do teto, quando compacta de novo e quanto gastou da janela de 5 h. A barra de menu e o anel da barra mostram a janela de 5 h e a semana com a projeção no ritmo atual, e um aviso chega quando a janela acaba antes de renovar.
- A tela de Consumo tem três abas: Agora (janela, semana e cada sessão), Semana (gasto por dia, por workspace e o que mais pesa) e Máquina (memória e CPU). Uma sessão abre inteira, com o contexto e o gasto do dia lado a lado.
- Nada muda na sua configuração do Claude Code: tudo vai por `--settings` e `--mcp-config`.

Para instalar: `./scripts/build-app.sh --install` e abrir `~/Applications/Workspaces.app`. Precisa de macOS 14 ou mais novo, Claude Code instalado e Xcode 16 ou mais novo.

## License

[MIT](LICENSE)
