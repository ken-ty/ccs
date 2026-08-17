# ROADMAP

`/loop` が毎サイクル 1 項目を拾うためのバックログ。**着手可能** から S サイズを 1 つ選び、
実装 → テスト → 自己レビュー → ドキュメント更新 → PR の 1 サイクルを回す。

- 判断が要ることはチャットで聞かず **Issue に上げる**（`question` ラベル）。
- 完了した項目はこの表から消し、[完了ログ](#完了ログ) に 1 行で残す。
- **設計の正本は [docs/design.md](docs/design.md)。** 迷ったらチャットではなくそちらを読む。

## 確定している設計方針

毎サイクル読み直す前提。これに反する実装をしないこと。

| 方針 | 決定 | 出所 |
| --- | --- | --- |
| 自作する範囲 | **4 つだけ** — 新規作成 / trust 回避 / パス解決 / 命名規約と後片付け | design.md §1 |
| 一覧・状態 | `claude agents --json` に委譲。**自前のデーモンやポーリングを作らない** | design.md §2.1 |
| セッション間通信 | 組み込みの `ListAgents` / `SendMessage`。**`tmux send-keys` でのプロンプト注入は採らない** | design.md §3 |
| 命名 | tmux は `cc/<slug>`、Claude の `-n` は `<slug>`、id は `--session-id` で固定 | design.md §4.2 |
| 冪等性 | 同一 slug の tmux セッションがあれば**新規に立てず既存を返す** | design.md §4.3 |
| trust | 固定枠 `~/.cc-scratch/{1..8}` + ghq 配下の未信頼リポジトリのみ自動承認。**`send-keys` で答える案は採らない** | design.md §4.4 |
| v1 の範囲 | `new` / `ls` / `attach` / `kill` / `gc` まで。**`resume` と worktree は入れない** | design.md §6 |
| テスト | integration では **本物の `claude` を起動しない**（fake claude スタブを使う） | AGENTS.md |
| 言語 | POSIX sh。依存は `tmux` と `jq` のみ | design.md §6 |

## 着手可能

| # | 内容 | サイズ | 依存 |
| --- | --- | --- | --- |
| S1 | `bin/ccs` の骨格 — サブコマンド分岐 / `--help` / 依存チェック（tmux・jq）/ AGENTS.md の env 差し替え点を定義。`test/` に bats の骨格と CI（shellcheck + bats）を通す | S | — |
| S2 | `test/fixtures/fake-claude` — レジストリ JSON を書いてアイドルするスタブ。**これが無いと以降の integration が全部書けない** | S | S1 |
| S3 | `resolve_target` — リポジトリ名 / ghq パス / `tmp` → 絶対パス + slug。ghq はスタブ。同名衝突時は `<owner>-<repo>` | S | S1 |
| S4 | `ccs new` — tmux 起動 → レジストリに uuid が現れるまで待つ → JSON を返す。ペインは `exec $SHELL` で残す。fake claude で integration | S | S2, S3 |
| S5 | `ccs new` の冪等性 — 同一 slug が既にあれば立てずに既存を返す | S | S4 |
| S6 | trust の事前承認 — 固定枠の用意と、ghq 配下未信頼リポジトリのみ `hasTrustDialogAccepted` を立てる。`CCS_TRUST_FILE` で差し替え、**本物の `~/.claude.json` を触るテストは書かない** | S | S4 |
| S7 | `ccs ls` — `claude agents --json` を `cc/` で絞って整形。人が読む表と `--json` の両方。**uuid を必ず出す**（v1 に resume が無いため、手で `claude --resume` する導線がこれしかない） | S | S4 |
| S8 | `ccs attach` / `ccs kill` | S | S7 |
| S9 | `ccs gc` — 死んだペイン・空の固定枠の掃除 | S | S8 |
| S10 | ドキュメント基盤 — MkDocs Material（`uvx` 経由、依存はピン留め）+ `scripts/termshot.py`（キャプチャ済みの端末出力 → SVG、Python 標準ライブラリのみ）+ CI でビルド。**Pages へは出さない**（private のため。catan と同じく Artifacts） | S | S1 |
| S11 | `docs/tutorial.md` — 基本的な使い方。**スクリーンショット（実際の実行を termshot で SVG 化したもの）を多めに** | S | S9, S10 |
| S12 | `docs/hands-on.md` — 人間が本物の claude で触るときのステップバイステップ確認手順。各手順に「期待される出力」を書く | S | S9 |
| S13 | `cross-session-hub` スキルの改訂（`agent-skills-store` 側）— 二層の使い分けと `ccs new` の呼び方。**このリポジトリの外なので、別途 PR を立てる** | S | S12 |

**S1 → S2 → S3 の順は動かせない。** S2 が無いと integration が書けず、テストの無いまま
S4 以降を積むことになる。

## 完了ログ

| 日付 | 内容 |
| --- | --- |
| 2026-08-17 | 設計調査を実施し、自作範囲を 4 つに確定（`545e370`） |
