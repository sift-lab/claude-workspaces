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
- **Resume on relaunch.** Sessions reopen with their conversations when you open a workspace again. After a `/clear` the app keeps the new conversation as soon as it has a message (see [Which conversation resumes](#which-conversation-resumes)).
- **Updates itself.** "Procurar atualizações…" in the app menu, and the same check in silence at launch and every 30 minutes, against the `main` branch of the repository the app was built from. A new commit is built in the background and the app asks before restarting into it (see [Updating](#updating)).
- **One item, one session.** Long-lived conversations reread their whole context on every call. Past a limit you set (300 thousand tokens by default) a session is marked "precisa de passagem" and is reminded to write a handoff; `recycle_self` then starts it over in a clean conversation that picks up from that handoff, behind locks that refuse whenever context could be lost (see [Recycling a session](#recycling-a-session)).

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

`build-app.sh` stamps the commit and the repository into `Info.plist`; from then on the installed app [updates itself](#updating) from that repository's `main`, so `--install` is only needed once. `WORKSPACES_BUILD_JOBS=2` limits the compile jobs.

Run the tests with `swift test`. To regenerate the icon after editing `Resources/AppIcon.svg`, run `swift scripts/make-icon.swift`.

You can open a workspace from the command line (handy for Raycast or Alfred):

```sh
open -a Workspaces --args --open "Work"
```

## How it works

- **No changes to your Claude Code setup.** Each session starts `claude` with `--settings` (hooks) and `--mcp-config` (the MCP server) pointing to files in `~/Library/Application Support/Workspaces/`. Your `~/.claude` settings are left untouched.
- **Hooks** run a tiny helper (`workspaces-hook`, Foundation only) that forwards the event to the app over a unix socket. It never blocks Claude.
- **MCP** is served by the app itself over HTTP on `127.0.0.1`, with a random token per launch, so no helper process runs per session.
- **Tokens** are read from Claude Code's transcripts in `~/.claude/projects` (two weeks, each file from where the last read stopped; agents count toward the session that started them). The account's limit comes from the status line: the settings file sets `statusLine` to the hook helper, which tells the app what Claude Code reported (`context_window`, `rate_limits`) and then prints your own status line, if you have one. Weighing tokens by API price turns them into one number; readings of the meter calibrate how much of it fills each window. The readings are kept per account in `limit-readings-<account>.json`, the account named by `WORKSPACES_CONTA` (`conta1` when unset), which every session also gets in its environment.
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
| `close_session` | Closes a finished session of the same workspace. Refused while it works or waits, or with changes not committed in its worktree; logged in `recycles.jsonl`. Off by default. |
| `recycle_self` | Starts the calling session over in a clean conversation once its turn ends, after it wrote its handoff. No arguments. |
| `recycle_session` | The same for another session of the workspace, for an orchestrating session. Only the session id. |

Each tool can be turned off in Settings. Claude Code asks for permission the first time a session uses each one.

`list_sessions` shows each session's context ("contexto 412k") and flags the ones past the limit.

### Recycling a session

The rule is one item, one session. When an item's PR is open and nothing is left for the session, it writes its handoff, commits and stops; it is closed, not recycled. When the context passes the limit with work still to do, the session writes a section whose title starts with "Passagem" and carries the date and time it was written (`## Passagem 07/10 14h30`) in the `FRENTE.md` at the root of its worktree (the item in progress with branch, commit and PR, what is left and the exact next step, orders still pending, queued jobs and background tasks, decisions, pitfalls), commits, and calls `recycle_self`. The app then:

1. **Checks the locks**, and refuses with the reason when any fails:
   - `FRENTE.md` exists at the root of the session's git worktree, and its latest Passagem (by the date in the title, not the file's date) is not empty and was written in the last 30 minutes;
   - `git status --porcelain` shows nothing modified and nothing untracked outside the ignore (the `FRENTE.md` itself is ignored);
   - the session is not in the middle of a turn (working or waiting for you), no recado waits to be typed, and the end of the conversation's `.jsonl` shows the turn ended with nothing queued (a message sent by Claude Code's own SendMessage shows there before any hook). `recycle_self` is always called from inside a turn, so it is scheduled and every lock is checked again when the turn ends (the Stop hook) and Claude Code has settled;
   - the current conversation's `.jsonl` is on disk;
   - Claude Code's input line is seen empty on screen, so `/clear` never goes out together with a draft or a message another session typed.
2. **Types `/clear` and looks once more** before Enter: the session still stopped, nothing queued, the input holding only `/clear`. If something arrived in between, the `/clear` is erased and the recycle waits for the end of the next turn (`deferred` in the log, and a notification).
3. **Logs before clearing**: one line in `recycles.jsonl` with the time, folder, old conversation id, old `.jsonl` path, a copy of the latest Passagem made at that moment, its date, and where the worktree stands (branch, HEAD, the branch's open PR from `gh`, the background tasks still running under Claude). The whole text the new conversation gets is also written to `passagens/` next to the log. If either cannot be written, nothing is cleared. Nothing is ever deleted: the old `.jsonl` stays where Claude Code wrote it.
4. **Sends `/clear`** and waits for the new conversation (a new session id from the `SessionStart` hook with source `clear`, or from the status line). The `SessionStart` hook answers with `hookSpecificOutput.additionalContext`: that text, or, when it is too long for a hook, its file and its beginning. After 30 s without a new conversation, a `/clear` still in the input is erased and the recycle is marked `delayed`; a `/clear` that runs later, up to 15 min, still gets the Passagem and the resume prompt.
5. **Sends a fixed message** with Enter, where only the paths change: "Leia a Passagem copiada no /clear em <file> e retome. A conversa anterior está em <path>: se faltar algo, procure nela com grep, sem ler inteira." Only that prompt counts as the resume (`resumed`): if another message started a turn first, the fixed message goes when that turn ends.
6. **Checks the resume** five minutes later: the new conversation's `.jsonl` exists, got the Passagem and the fixed message, and made a tool call. The verdict (`conferida` or `quebrada`, with the reason) is a `verified` line in the log; `quebrada` marks the session and notifies you.

Every phase is kept in `recycles-open.json` next to the log, so a restart of the app or of `workspacesd` finishes what it interrupted, or ends it as `failed` and tells you.

None of these tools accepts free text: extra arguments are refused, and the only things typed are `/clear` and the fixed message. A failure after the log is logged too (`failed`), shown in `list_sessions` and the sidebar, and sent to you as a notification.

While a session is past the limit, the `PostToolUse` and `UserPromptSubmit` hooks add a reminder to its context (`additionalContext`) once on crossing and again every 50 thousand tokens: "Contexto em 412k, acima do limite de 300k: no próximo ponto seguro, escreva a Passagem no FRENTE.md, com data e hora no título, e chame recycle_self." Past 500 thousand you get a macOS notification and the mark turns red. The app never switches the model to a smaller window and never forces a compaction: compaction summarizes on its own and loses detail.

The hook output follows Claude Code's documented format (`hookSpecificOutput` with `hookEventName` and `additionalContext`, see [Hooks](https://code.claude.com/docs/en/hooks)); the helper only ever prints a JSON object the app sent, never plain text.

### Which conversation resumes

Every hook feeds one rule (`ConversationTracker`): the conversation to reopen with `--resume` is the current one once it has a message (`UserPromptSubmit`, `PostToolUse`, `Stop` or a permission request). Right after a `/clear` the new conversation is still empty and `--resume` could not open it, so a relaunch in that moment starts clean. A `SessionEnd` only says which conversation ended, and a conversation that ended or was replaced never comes back from a late hook (Claude Code cuts the `SessionEnd` hooks of a `/clear` at 1.5 s, so one can arrive after the new conversation started); only a resume reopens it. Each change of the saved conversation is a line in `~/Library/Application Support/Workspaces/conversations.jsonl`.

### Updating

The app updates itself from the `main` branch of the repository it was built from (`WorkspacesRepository` in `Info.plist`), like any Mac app:

1. **Check.** "Procurar atualizações…" in the app menu, and the same check in silence 60 s after launch and every 30 minutes. If the repository has an `origin`, it is fetched first (only `origin/main` moves; nothing checked out is touched), and `origin/main` is used when it is ahead of the local `main`. There is an update when that commit contains the installed one and is a different one; a build ahead of `main` (from a branch not merged yet) is never replaced by an older one. A manual check with nothing new says "Você já está na versão mais recente".
2. **Build.** In a worktree of its own (`~/Library/Caches/Workspaces/update-wt`, never the one you develop in), with `scripts/build-app.sh`, `-j 2`, utility QoS and `nice 15`, and only with more than 30% of memory and 2 GB of disk free (it waits up to 25 minutes, then tries again at the next check). The build is refused if it is not the commit asked for or if it is not signed by the same team as the installed app, which would drop the macOS permissions. The log is `update/build.log` in the support folder.
3. **Ask.** A standard macOS dialog, "Há uma versão nova do Workspaces", with "Reiniciar agora" and "Depois", as a sheet on a workspace window (an automatic check does not take the focus; the Dock icon bounces). When sessions are working or waiting for you, it says how many and that they will be interrupted and come back with `--resume`. Nothing is applied without "Reiniciar agora"; after "Depois" the dialog comes back with a newer commit, at the next launch or with "Procurar atualizações…".
4. **Apply.** The app copies its `workspaces-hook` out of the bundle, writes the plan and the open windows, starts it detached (`apply-update`, in a session of its own) and quits, closing its sessions as on any quit. The helper waits for the app to exit, moves the installed app to `update/Workspaces-previous.app`, puts the new one in its place and opens it. The new app writes `update/heartbeat.json` (its pid and commit) once it finished launching; without it in 20 s, or if the process is gone 3 s later, the helper ends the new app, puts the previous one back, opens it, sends a notification and does not offer that commit again (`update/failed.json`). The steps are in `update/apply.log`.
5. **Come back.** Saved sessions resume with `--resume` as on every launch; windows that macOS's window restoration did not bring back are opened again.

The build runs whatever is on `main` (or on `origin/main`, when it is ahead) and signs it with your certificate: only point the app at a repository you trust.

### Configuration

Settings live in `~/Library/Application Support/Workspaces/workspaces.json` and can be edited in the app. Per project you can set where new sessions open, how many open with the workspace, and extra `claude` arguments (for example `--add-dir ../api`). Freeze and hibernate delays are in Settings, under "Economia"; the context above which a session needs its handoff (`handoffContextTokens`, 300 thousand by default) is under "Contexto".

To look at the screens without touching an installed app that hosts your sessions, run the built binary with its own support folder: `WORKSPACES_HOME=$(mktemp -d) WORKSPACES_TOKEN_SHOTS=<folder> build/Workspaces.app/Contents/MacOS/Workspaces` renders the token screens (sidebar marks included) from this Mac's transcripts and quits.

### Scripts

`workspaces-hook tool <name> ['{json}']` runs one MCP tool in the running app, for scripts that open, list, recycle or close sessions (as no session; run inside a session, it acts as that session, with its limits): `workspaces-hook tool list_sessions '{"all_workspaces":true}'`. It prints the tool's text and exits 0, 1 when the tool refused, 2 on bad usage and 3 when the app did not answer.

## On a Linux server (workspacesd)

`workspacesd` is the app without a screen, for a Linux machine where Claude Code sessions run unattended. Sessions run in tmux (`tmux attach -t ws-<id>` to look at one), and the same MCP tools, hooks, recycle locks and logs come from `WorkspacesCore`, so the rule is one on both machines.

```sh
./scripts/install-server.sh   # builds, installs to ~/.local/bin, runs it as a systemd user service
workspacesd open ~/src/acme --modelo sonnet --conta conta2 --prompt "Leia o FRENTE.md"
workspacesd status
workspacesd send 3f2a "Responda os comentários do PR"
workspacesd recycle 3f2a
workspacesd close 3f2a
```

It needs Swift 6 for Linux (with [swiftly](https://www.swift.org/install/linux/)), tmux, git and curl. Files live in `~/.workspaces` (`WORKSPACES_HOME` changes it): `workspaces.json` (projects, as in the app), `server.json`, `server-sessions.json`, `recycles.jsonl`, `conversations.jsonl`, `limit-readings-<account>.json` and `workspacesd.log`.

What differs from the app:

- **Accounts and models.** `open_session` takes `account` and `model`. Each account is a Claude Code config folder, `~/.claude-<account>` unless `server.json` says otherwise in `accounts`; the session starts with `CLAUDE_CONFIG_DIR` set to it and `WORKSPACES_CONTA` set to its name. `open_session` also takes a `path`, which becomes a project in the "Servidor" workspace when it is not one yet.
- **`send_message` presses Enter.** The message is pasted (bracketed paste) and sent; a session in the middle of a turn gets it queued. A hibernated one wakes with `--resume` and gets it once its prompt is up.
- **`notify` goes to the phone** through [ntfy](https://ntfy.sh): set `ntfyTopic` (and `ntfyServer`, `https://ntfy.sh` by default) in `server.json`. Keep the topic secret; anyone who knows it can read it. Without a topic the message goes to `workspacesd.log`.
- **Folder trust.** Claude Code asks once per folder whether to trust it. Inside `trustedRoots` (`server.json`, by default `~/src` and `~/obra`) the daemon answers yes; anywhere else the session waits and `list_sessions` says why.
- **Sleep.** Quiet sessions hibernate after `hibernateAfterMinutes` (`workspaces.json`); nothing is frozen.
- **Account limit.** When a turn ends on the account's limit (the `StopFailure` hook with `rate_limit`), the session continues by itself a minute after the reset (`retry_after`, or the reset of the full meter from the status line): "continue" goes in only when its input line is empty.
- **Restarts.** Stopping the daemon leaves the sessions running in tmux; the next start adopts them, and the ones that are gone come back with `--resume` when opened or messaged.
- **Tools.** Every tool is on by default (`disabledTools` in `workspaces.json` turns one off for the sessions; the command line can always use them).

`workspacesd tool <name> ['{json}']` runs any tool, like `workspaces-hook tool` on the Mac.

## Project layout

- `Sources/WorkspacesCore`: models, config, IPC, hook mapping, MCP protocol, sleep policy, HTTP parsing. No UI, fully unit tested.
- `Sources/Workspaces`: the SwiftUI app, terminal hosting, servers, usage monitor.
- `Sources/WorkspacesHook`: the hook helper.
- `Sources/WorkspacesDaemon`, `Sources/WorkspacesDaemonMain`: `workspacesd`, Linux only.
- `Tests/WorkspacesCoreTests`, `Tests/WorkspacesDaemonTests`: tests for the core (macOS and Linux) and the daemon (Linux).

## Resumo em português

App nativo para macOS que organiza as sessões do Claude Code por workspace: uma janela por workspace, projetos na barra lateral, várias sessões por projeto e uma barra de menu que mostra qual sessão está esperando você.

- Cada sessão é um terminal de verdade com o Claude Code, nomeado pela branch ou worktree.
- Os hooks do Claude Code informam o estado de cada sessão; as que precisam de você ficam em destaque e podem notificar.
- Cada sessão ganha um servidor MCP `workspaces` para ver as outras sessões, dizer o que está fazendo, abrir sessões, mandar recados e pedir atenção.
- Sessões paradas e fora da tela congelam (CPU zero) e depois hibernam (o processo encerra e a conversa volta com `claude --resume` ao abrir).
- Cada sessão mostra o contexto que carrega, se está subindo rápido ou perto do teto, quando compacta de novo e quanto gastou da janela de 5 h. A barra de menu e o anel da barra mostram a janela de 5 h e a semana com a projeção no ritmo atual, e um aviso chega quando a janela acaba antes de renovar.
- A tela de Consumo tem três abas: Agora (janela, semana e cada sessão), Semana (gasto por dia, por workspace e o que mais pesa) e Máquina (memória e CPU). Uma sessão abre inteira, com o contexto e o gasto do dia lado a lado.
- Um item, uma sessão: acima de um limite de contexto (300 mil por padrão, nos Ajustes) a sessão aparece como "precisa de passagem" e recebe um aviso a cada 50 mil. Ela escreve a seção Passagem, com data e hora no título, no FRENTE.md da raiz da worktree, faz commit e chama `recycle_self`; item com PR pronto e nada mais a fazer só para e é fechado. O app confere as travas (Passagem mais recente escrita nos últimos 30 min pela data do título, git status limpo, sessão parada sem nada na fila do Claude Code, caixa de entrada vazia; a sugestão esmaecida que o Claude Code mostra nela depois de um turno não conta como texto), digita `/clear`, confere de novo, registra tudo em `recycles.jsonl` antes de limpar e só então envia. A conversa nova recebe a Passagem com ramo, HEAD, PR e tarefas em segundo plano, depois uma mensagem fixa que manda ler a passagem e aponta o .jsonl da conversa anterior; cinco minutos depois o app confere a retomada e grava o veredito. As fases ficam em disco e um reinício conclui o que ficou no meio. Nada é apagado. `recycle_session` faz o mesmo a pedido de uma orquestradora; `close_session` recusa sessão trabalhando ou com mudança sem commit. Acima de 500 mil chega uma notificação e a marca fica vermelha; o app nunca troca o modelo nem força compactação.
- Depois de um /clear, o app guarda a conversa nova assim que ela tem uma mensagem; um hook atrasado da conversa anterior não a traz de volta. Cada troca fica em `conversations.jsonl`.
- Atualiza sozinho a partir da main do repositório de onde foi compilado: "Procurar atualizações…" no menu do app, e a mesma procura em silêncio ao abrir e a cada 30 min. Achou commit novo, compila em segundo plano num worktree próprio (-j 2, prioridade baixa, só com mais de 30% de memória livre) e mostra "Há uma versão nova do Workspaces" com "Reiniciar agora" e "Depois", dizendo quantas sessões estão trabalhando. Só aplica no clique. Um auxiliar destacado troca o app, guarda o anterior e, se a versão nova não abrir em 20 s, volta a anterior e avisa.
- Nada muda na sua configuração do Claude Code: tudo vai por `--settings` e `--mcp-config`.
- No Linux, o `workspacesd` faz o mesmo sem tela: as sessões rodam em tmux, com as mesmas ferramentas MCP, a mesma trava da reciclagem e os mesmos registros. `open_session` escolhe a conta (`CLAUDE_CONFIG_DIR`) e o modelo, `send_message` aperta Enter, `notify` vai para o celular pelo ntfy e a sessão que bate no limite da conta continua sozinha depois que ele reabre. Instala com `./scripts/install-server.sh` (serviço do systemd do usuário).
- As leituras do limite ficam num arquivo por conta, `limit-readings-<conta>.json`, com a conta de `WORKSPACES_CONTA` (`conta1` se não houver). `workspaces-hook tool <nome> '{json}'` roda uma ferramenta pelo app, para scripts.

Para instalar: `./scripts/build-app.sh --install` e abrir `~/Applications/Workspaces.app`. Depois disso o app se atualiza sozinho. Precisa de macOS 14 ou mais novo, Claude Code instalado e Xcode 16 ou mais novo.

## License

[MIT](LICENSE)
