# agent-shell-usage.el

Display Claude Code and Codex subscription rate-limit usage in the mode-line
of [agent-shell](https://github.com/xenodium/agent-shell) buffers.

This package does **not** use `ANTHROPIC_API_KEY` or `OPENAI_API_KEY`. It reads
your existing local subscription credentials instead.

- **Claude**: shells out to [`ccusage`](https://github.com/wakamex/ccusage)
  (`ccusage json`), which reads the Claude Code OAuth subscription
  credentials.
- **Codex**: talks to a local `codex app-server` process over its JSON-RPC
  protocol (`account/rateLimits/read`), using your existing ChatGPT login.

## Requirements

- Emacs 29.1+
- [`agent-shell`](https://github.com/xenodium/agent-shell)
- `ccusage` in `PATH` for Claude usage:
  ```sh
  uv tool install ccusage
  ```
- `codex` in `PATH` with an existing ChatGPT login, for Codex usage.

## Installation

```elisp
(add-to-list 'load-path "/path/to/agent-shell-usage")
(require 'agent-shell-usage)
(agent-shell-usage-mode 1)
```

## Usage

Once `agent-shell-usage-mode` is enabled, a usage segment is automatically
added to the mode-line of every `agent-shell` buffer (existing and future),
refreshing both providers asynchronously on a timer.

The segment shows something like:

```
C S:42%↻2h15 W:18%↻3d | X 5h:30% 7d:12%
```

- `C` = Claude, `X` = Codex
- `S` / `W` = session / week window (Claude); `5h` / `7d` = the corresponding
  rate-limit windows Codex reports
- `↻` followed by a duration = time left until that window resets

Click the segment with `mouse-1` to refresh immediately, or `mouse-2` to open
a details buffer.

### Commands

- `M-x agent-shell-usage-refresh` — refresh both providers.
- `M-x agent-shell-usage-show-details` — show full cached details for both
  providers in a help window.

### Customization

```elisp
(setq agent-shell-usage-refresh-interval 120)   ; seconds between refreshes
(setq agent-shell-usage-display-as 'remaining)  ; or 'used
(setq agent-shell-usage-show-reset t)           ; show "↻<time-left>" after each percentage
(setq agent-shell-usage-mode-line-separator " | ")
(setq agent-shell-usage-claude-command "ccusage")
(setq agent-shell-usage-codex-command "codex")
```

## How it works

- Claude usage is fetched by running `ccusage json` as an async process and
  parsing its JSON output.
- Codex usage is fetched by launching `codex app-server`, performing the
  JSON-RPC `initialize`/`initialized` handshake, and calling
  `account/rateLimits/read`.

Both fetches run asynchronously on a timer (`agent-shell-usage-refresh-interval`,
default 120s) and never block Emacs.

## License

No license specified.
