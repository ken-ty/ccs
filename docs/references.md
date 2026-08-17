# 参照資料

[docs/design.md](design.md) の設計調査（2026-08-17）で当たったもの。

## 既存実装

**読んだもの**（本文まで確認済み）

- [I made a Claude Code session manager for tmux — devas.life](https://www.devas.life/i-made-a-claude-code-session-manager-for-tmux/)
  — tmux セッション名を cwd のハッシュで決め、状態は tmux のユーザオプション `@claude_state` に
  hook で書き込み、fzf + `capture-pane` でプレビューする。**デーモンを作らない**という方針を
  ここから採った。ただし状態管理そのものは `claude agents --json` に置き換えている
  （Claude 本体が同じ情報を持つようになったため）

**検索結果のスニペットまでしか見ていないもの**（採否の判断には足りている）

- [nielsgroen/claude-tmux](https://github.com/nielsgroen/claude-tmux)
  — tmux ポップアップの TUI。worktree / PR 連携あり。人間が操作する TUI が主眼で、
  ハブから AI が叩く用途には過剰
- [absmartly/Tmux-Orchestrator](https://github.com/absmartly/Tmux-Orchestrator)
  — 「マネージャ役の Claude」が `send-keys` で子セッションを叩き、自分でチェックインを予約する。
  `send-keys` によるプロンプト注入は `SendMessage` の下位互換で脆いため不採用
- [Jedward23/Tmux-Orchestrator](https://github.com/Jedward23/Tmux-Orchestrator) — 上記の別系統
- [primeline-ai/claude-tmux-orchestration](https://github.com/primeline-ai/claude-tmux-orchestration)
  / [解説記事](https://primeline.cc/blog/tmux-orchestration)
  — heartbeat 監視とファイルベースの協調。作者自身が「Claude Code が機能の大半を吸収した」と
  書いている
- [Tmux Session Orchestrator（mcpmarket）](https://mcpmarket.com/tools/skills/tmux-session-orchestrator)
- [awesome-claude-code #1279](https://github.com/hesreallyhim/awesome-claude-code/issues/1279)
  — tmux-orchestrator 系の収録議論

## ローカルで実測したもの（URL ではない）

設計の根拠の大半はこちら。再現コマンドは [design.md §7](design.md#7-実測に使ったコマンド再現用)。

| 対象 | 何が分かったか |
| --- | --- |
| `~/.claude/sessions/<pid>.json` | 生きているセッションのレジストリ。`tmux` ペイン ID・`status`・`messagingSocketPath`・`bridgeSessionId` を持つ |
| `claude agents --json` | 上を TTY 無しで読める。デスクトップ / VS Code 拡張 / tmux 内 CLI が同じ配列に並ぶ |
| `ListAgents` / `SendMessage`（組み込みツール） | 全エントリポイントを横断する。ハブ → tmux セッションの往復を実証 |
| `mcp__ccd_session_mgmt__list_sessions` | **デスクトップ専用**。VS Code も tmux も一覧に出ない |
| `claude -p --session-id <uuid>` | 要求した UUID がそのまま採用される |
| `/tmp/cc-socks/<pid>.sock` | セッション間 IPC の実体。プロセスが死ねば消える |
| `~/.claude.json` の `projects[<path>].hasTrustDialogAccepted` | workspace trust ダイアログの状態 |
| `~/.claude/skills` | 57 件すべて `~/.agents/skills/*` への symlink。ユーザレベルなので cwd に依らない |

検証環境: claude 2.1.226 (CLI) / 2.1.229 (デスクトップ)、tmux 3.7b、macOS (darwin 25.3.0)。
