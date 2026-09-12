# agent-shell-stats.el

Display Claude Code, Codex, and Antigravity subscription rate-limit usage in
the mode-line of [agent-shell](https://github.com/xenodium/agent-shell)
buffers.

This package does **not** use `ANTHROPIC_API_KEY` or `OPENAI_API_KEY`. It reads
your existing local subscription credentials instead.

- **Claude**: reuses Claude Code's own OAuth credentials — the on-disk
  `~/.claude/.credentials.json` file if present, otherwise (macOS only) the
  "Claude Code-credentials" Keychain item — and calls Anthropic's
  `/api/oauth/usage` endpoint directly via `curl`.
- **Codex**: talks to a local `codex app-server` process over its JSON-RPC
  protocol (`account/rateLimits/read`), using your existing ChatGPT login.
- **Antigravity**: runs `agy -p "/quota" --output-format json` non-
  interactively, using your existing Antigravity login. agy reports two
  weekly quota groups: one for Gemini models, and one shared by
  Claude and GPT-OSS models.

## Requirements

- Emacs 29.1+
- [`agent-shell`](https://github.com/xenodium/agent-shell)
- `curl` in `PATH` and an existing Claude Code login, for Claude usage.
  On macOS, the first Keychain read/write may prompt for access — choose
  "Always Allow" so subsequent automatic refreshes don't prompt again.
- `codex` in `PATH` with an existing ChatGPT login, for Codex usage.
- `agy` in `PATH` with an existing Antigravity login, for Antigravity usage.

## Installation

```elisp
(add-to-list 'load-path "/path/to/agent-shell-stats")
(require 'agent-shell-stats)
(agent-shell-stats-mode 1)
```

## Usage

Once `agent-shell-stats-mode` is enabled, a usage segment is automatically
added to the mode-line of every `agent-shell` buffer (existing and future),
refreshing all three providers asynchronously on a timer.

The segment shows something like:

```
C S:42%↻2h15 W:18%↻3d | X 5h:30% 7d:12% | A G:92%↻4d14h P:100%↻6d
```

- `C` = Claude, `X` = Codex, `A` = Antigravity
- `S` / `W` = session / week window (Claude); `5h` / `7d` = the corresponding
  rate-limit windows Codex reports; `G` / `P` = Gemini / Claude+GPT-OSS
  weekly quota groups (Antigravity)
- `↻` followed by a duration = time left until that window resets

Click the segment with `S-mouse-1` (shift-click) to refresh immediately, or
`mouse-1` to open a details buffer.

### Commands

- `M-x agent-shell-stats-refresh` — refresh all three providers.
- `M-x agent-shell-stats-show-details` — show full cached details for all
  three providers in a help window.

### Customization

```elisp
(setq agent-shell-stats-refresh-interval 120)   ; seconds between refreshes
(setq agent-shell-stats-display-as 'remaining)  ; or 'used
(setq agent-shell-stats-show-reset t)           ; show "↻<time-left>" after each percentage
(setq agent-shell-stats-mode-line-separator " | ")
(setq agent-shell-stats-claude-keychain-service "Claude Code-credentials")
(setq agent-shell-stats-codex-command "codex")
(setq agent-shell-stats-agy-command "agy")
```

## How it works

- Claude usage is fetched by reading Claude Code's own OAuth credentials
  (refreshing and persisting the token when it's expired, just like Claude
  Code itself does) and calling Anthropic's `/api/oauth/usage` endpoint
  with `curl` as an async process.
- Codex usage is fetched by launching `codex app-server`, performing the
  JSON-RPC `initialize`/`initialized` handshake, and calling
  `account/rateLimits/read`.
- Antigravity usage is fetched by running
  `agy -p "/quota" --output-format json` as an async process and parsing its
  JSON response.

All three fetches run asynchronously on a timer
(`agent-shell-stats-refresh-interval`, default 120s) and never block Emacs.

## License

MIT License

Copyright (c) 2026 sugitach

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to
deal in the Software without restriction, including without limitation the
rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
sell copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
DEALINGS IN THE SOFTWARE.
