# agent-shell-stats.el

[agent-shell](https://github.com/xenodium/agent-shell) のバッファの mode-line
に、Claude Code と Codex のサブスクリプション利用状況（レートリミット）を
表示する Emacs パッケージです。

このパッケージは `ANTHROPIC_API_KEY` や `OPENAI_API_KEY` を一切使用しません。
代わりに、既にローカルに存在するサブスクリプションの認証情報を利用します。

- **Claude**: [`ccusage`](https://github.com/wakamex/ccusage) を外部コマンド
  として実行し（`ccusage json`）、Claude Code の OAuth サブスクリプション
  認証情報を読み取ります。
- **Codex**: ローカルの `codex app-server` プロセスと JSON-RPC
  （`account/rateLimits/read`）で通信し、既存の ChatGPT ログインを利用します。

## 必要環境

- Emacs 29.1 以上
- [`agent-shell`](https://github.com/xenodium/agent-shell)
- Claude の利用状況取得には `ccusage` が `PATH` 上にあること:
  ```sh
  uv tool install ccusage
  ```
- Codex の利用状況取得には `codex` が `PATH` 上にあり、ChatGPT に
  ログイン済みであること。

## インストール

```elisp
(add-to-list 'load-path "/path/to/agent-shell-stats")
(require 'agent-shell-stats)
(agent-shell-stats-mode 1)
```

## 使い方

`agent-shell-stats-mode` を有効化すると、既存および今後開かれる全ての
`agent-shell` バッファの mode-line に利用状況セグメントが自動的に追加され、
タイマーにより両プロバイダの情報が非同期に更新されます。

セグメントの表示例:

```
C S:42%↻2h15 W:18%↻3d | X 5h:30% 7d:12%
```

- `C` = Claude、`X` = Codex
- `S` / `W` = セッション / 週間ウィンドウ（Claude）、`5h` / `7d` = Codex が
  報告するレートリミットウィンドウ
- `↻` の後の時間 = そのウィンドウがリセットされるまでの残り時間

セグメントを `mouse-1` でクリックすると即座に再取得、`mouse-2` で詳細バッファ
を開けます。

### コマンド

- `M-x agent-shell-stats-refresh` — 両プロバイダの利用状況を再取得する。
- `M-x agent-shell-stats-show-details` — 両プロバイダのキャッシュ済み詳細を
  ヘルプウィンドウに表示する。

### カスタマイズ

```elisp
(setq agent-shell-stats-refresh-interval 120)   ; 更新間隔（秒）
(setq agent-shell-stats-display-as 'remaining)  ; 'remaining または 'used
(setq agent-shell-stats-show-reset t)           ; パーセンテージの後に「↻残り時間」を表示するか
(setq agent-shell-stats-mode-line-separator " | ")
(setq agent-shell-stats-claude-command "ccusage")
(setq agent-shell-stats-codex-command "codex")
```

## 仕組み

- Claude の利用状況は、`ccusage json` を非同期プロセスとして実行し、その
  JSON 出力をパースして取得します。
- Codex の利用状況は、`codex app-server` を起動し、JSON-RPC の
  `initialize`/`initialized` ハンドシェイクを行った後、
  `account/rateLimits/read` を呼び出して取得します。

いずれの取得処理もタイマー（`agent-shell-stats-refresh-interval`、デフォルト
120秒）により非同期で実行され、Emacs をブロックしません。

## ライセンス

MIT License で公開しています。

Copyright (c) 2026 sugitach

本ソフトウェアおよび関連ドキュメントファイル（以下「本ソフトウェア」）の
コピーを取得するすべての人に対し、本ソフトウェアを無制限に扱うことを、
無償で許可します。これには、本ソフトウェアの複製、使用、改変、結合、掲載、
頒布、サブライセンス、および/または販売する権利、および本ソフトウェアを
提供する相手に同じことを許可する権利も無制限に含まれます。

上記の著作権表示および本許諾表示を、本ソフトウェアのすべての複製または
重要な部分に記載するものとします。

本ソフトウェアは「現状のまま」で、明示黙示を問わず、商品性、特定目的への
適合性、および権利非侵害についての保証を含め、いかなる保証もなく提供され
ます。著作者または著作権者は、契約行為、不法行為、またはそれ以外であるか
を問わず、本ソフトウェアに起因または関連し、本ソフトウェアの使用またはそ
の他の扱いによって生じる一切の請求、損害、その他の義務について何らの責任
も負わないものとします。

（法的な正文は英語版 [README.md](README.md) の MIT License 条文を参照して
ください。）
