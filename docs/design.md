# tmux ベースの Claude セッションマネージャ — 設計調査

対象: ハブ 1 本から、tmux 上に複数の Claude Code セッションを立て・回収し・畳む仕組み。
調査日: 2026-08-17 / claude 2.1.226 (CLI) / 2.1.229 (デスクトップ) / tmux 3.7b。

---

## 1. 結論

**作るものは薄い。** 想定していた「セッション管理」の大半は、Claude Code 2.1.x が既に持っている。
実測で確認できた既存機能は次のとおり。

| やりたいこと | 既にある | 自作が要るか |
| --- | --- | --- |
| 全セッションの一覧・状態 | `claude agents --json` | 不要 |
| ハブ → 子セッションへの指示 | `ListAgents` / `SendMessage` ツール | 不要 |
| tmux ペインとの対応づけ | Claude 自身が `tmux` フィールドに記録する | 不要 |
| セッション ID の固定 | `--session-id <uuid>` | 不要 |
| 表示名 | `-n <name>` | 不要 |
| Remote Control 登録 | `remoteControlAtStartup: true`（設定済み） | 不要 |
| skills が見えること | `~/.claude/skills` はユーザレベル。cwd に依らず 57 件見える | **不要** |
| **セッションの新規作成** | 無い（`SendMessage` は既存宛のみ） | **要る** |
| **workspace trust ダイアログの回避** | 無い | **要る** |
| **プロジェクト解決（ghq / 一時ディレクトリ）** | 無い | **要る** |
| **命名規約と後片付け** | 無い | **要る** |

したがって自作分は「**足りない 4 つだけを埋める薄いラッパー**」に収まる。既存の tmux
オーケストレータ（後述）を持ってくると、いま組み込みになった部分まで二重に抱えることになる。

---

## 2. 実測でわかったこと（証拠つき）

### 2.1 生きているセッションのレジストリが既にある

Claude Code は起動時に `~/.claude/sessions/<pid>.json` を書く。tmux 内で `claude` を起動して
実際に採取したもの:

```json
{"pid":82344,"sessionId":"b85e68f4-…","cwd":"/…/scratchpad/probe",
 "kind":"interactive","entrypoint":"claude-desktop",
 "tmux":"probe1:@0.%0",
 "messagingSocketPath":"/tmp/cc-socks/82344.sock",
 "name":"probe-tmux","status":"idle",
 "bridgeSessionId":"session_01HavSXkisL7kZBmaz6jkEFu"}
```

読み出しは `claude agents --json`（**TTY 不要**、スクリプトから叩ける）。デスクトップ・VS Code
拡張・tmux 内 CLI が**同じ配列に並ぶ**ことを確認した。

> **効いてくる点**: 状態監視のためのデーモンもポーリングも要らない。参考にした既存実装
> （devas.life 版）は tmux のユーザオプション `@claude_state` に hook で状態を書き込んでいたが、
> **その役割は今 Claude 本体が持っている**。

> **訂正（S7、2026-08-17）: `claude agents --json` は `tmux` フィールドを持たない。**
> 返るのは `cwd` / `kind` / `name` / `pid` / `sessionId` / `startedAt` だけで、`tmux` は
> `~/.claude/sessions/<pid>.json` の側にしか無い。したがって **あの出力から「`cc/` で
> 始まるセッション」を選び出すことはできない**。`ccs ls` は tmux 側を起点にし
> （`cc/` が付いているのは ccs が立てたものだけなので管轄として正しい）、
> 各セッションの中身はレジストリのファイルから引く。

### 2.2 ハブ → tmux セッションの往復が通る（実証済み）

`/tmp` 配下の空ディレクトリで tmux セッションを立て、このハブから `SendMessage` を投げ、返答を得た。

- `ListAgents` に `probe-tmux [68a618] · interactive · idle · tmux probe1:@0.%0` として出た
- `SendMessage` が届き、返答が `tmux capture-pane` で読めた
- 返答内容: cwd は `/tmp/…/probe`、`$TMUX` は設定済み、**`ls ~/.claude/skills | wc -l` = 57**

**つまり「一時ディレクトリで作業させても skills は全部見える」が実測で確定した。**
`~/.claude/skills` の 57 件は全て `~/.agents/skills/*` への symlink で、ユーザレベルなので
cwd に依存しない。ここに手当ては要らない。

### 2.3 `cross-session-hub` スキルは tmux セッションを見られない（要更新）

既存スキルが使う `mcp__ccd_session_mgmt__*` は **デスクトップアプリ専用**のストアを見ている。
セッション ID が `local_<uuid>` 形式で、実測では **VS Code のセッションも tmux のセッションも
一覧に出なかった**。

一方、組み込みの `ListAgents` / `SendMessage` は**全エントリポイントを横断する**。

| | `ccd_session_mgmt` | `ListAgents` / `SendMessage` |
| --- | --- | --- |
| デスクトップのセッション | ○ | ○ |
| VS Code のセッション | **×** | ○ |
| tmux 内の CLI セッション | **×** | ○ |
| 停止中セッションへの送信（自動起動） | ○ | ×（プロセスが生きている必要あり） |
| トランスクリプトの読み出し | ○ (`list_events`) | ×（`capture-pane` か jsonl 直読み） |

**両方要る。** 新方式では `ListAgents`/`SendMessage` が主、`ccd_session_mgmt` は
デスクトップ側セッションの履歴を読むときに残る。スキルはこの二層構造に書き直す必要がある。

### 2.4 `--session-id` は尊重される

`claude -p --session-id <uuid>` が、要求した UUID をそのまま `session_id` として返した。
→ **立てる前に ID を決められる。** トランスクリプトの場所
（`~/.claude/projects/<cwd-slug>/<uuid>.jsonl`）も起動前に確定するので、
起動直後のポーリングによる名寄せが不要になる。

### 2.5 tmux 連携は Claude 本体にも一部ある

`claude --worktree <name> --tmux` が組み込みで存在する（iTerm2 のネイティブペイン、
`--tmux=classic` で従来の tmux）。ただし **`--tmux` は `--worktree` 必須**なので、
「既存リポジトリのまま」「一時ディレクトリ」のケースは自前で立てることになる。

### 2.6 詰まりどころ: workspace trust ダイアログ

新しいディレクトリで対話モードの `claude` を起動すると、**最初に信頼確認で止まる**。
tmux 越しに `send-keys "1" Enter` で抜けるまで、セッションはレジストリにすら現れなかった
（`~/.claude/sessions/82344.json` が存在しない状態が続いた）。

- `-p`（print モード）はこのダイアログを飛ばす
- 対話モードでは、`~/.claude.json` の `projects["<abs path>"].hasTrustDialogAccepted` が真なら出ない

**一時ディレクトリを毎回新規に作る方式は、毎回ここで固まる。** 対策は §4.4。

### 2.7 その他

- 稼働中セッションの `name` は tmux のステータス行にも出る（`── probe-tmux ──`）
- 実測中、子セッションに `⚠ Your login expires in 1 day · run /login to renew` が出ていた。
  無人セッションを長期に走らせる構成では、**認証切れが最初に壊れる箇所**になる
- `/tmp/cc-socks/<pid>.sock` がセッション間 IPC の実体。プロセスが死ねば消える
  → **tmux ペインが生きていても claude プロセスが終了していれば通信不能**（§4.5）

---

## 3. 参考にした既存実装

| 実装 | 方式 | 採否 |
| --- | --- | --- |
| [devas.life の tmux セッションマネージャ](https://www.devas.life/i-made-a-claude-code-session-manager-for-tmux/) | tmux セッション名を cwd のハッシュで決定、状態は `@claude_state` に hook で書く、fzf + `capture-pane` でプレビュー。デーモン無し | **考え方を採る。** ただし状態管理は `claude agents --json` に置き換え（本体が持つようになったため） |
| [nielsgroen/claude-tmux](https://github.com/nielsgroen/claude-tmux) | tmux ポップアップの TUI。worktree / PR 連携 | 人間が操作する TUI が主眼。**ハブから AI が叩く用途には過剰** |
| [Tmux-Orchestrator 系](https://github.com/absmartly/Tmux-Orchestrator) | 「マネージャ役の Claude」が `send-keys` で子を叩き、自分でチェックインを予約する | **不採用。** `send-keys` によるプロンプト注入は `SendMessage` の下位互換で、脆い |

**共通する教訓**: デーモンを作らない。tmux のプリミティブと、その場で読める状態だけで構成する。

---

## 4. 設計案

### 4.1 全体像

```
┌─ ハブセッション（デスクトップ or tmux。Remote Control 常時 ON）─────────┐
│  ・スマホ / デスクトップからここだけを触る                              │
│  ・ListAgents で全体を見る、SendMessage で個別に指示する                │
│  ・立てる / 畳むときだけ ccs を叩く                                     │
└───────────────┬────────────────────────────────────────────────────────┘
                │ Bash: ccs new / ls / kill / gc
                ▼
        ┌───────────────┐   薄いラッパー（自作分はここだけ）
        │   ccs (CLI)   │   ・tmux new-session -d
        └───────┬───────┘   ・ghq / 一時ディレクトリの解決
                │           ・trust の事前承認
                │           ・命名規約と後片付け
                ▼
   tmux server（ターミナルを閉じても残る）
   ├─ cc/x01          → claude -n x01 --session-id … （~/ghq/…/x01）
   ├─ cc/catan        → claude -n catan …
   └─ cc/tmp-abc123   → claude -n tmp-abc123 …      （使い捨てディレクトリ）
                │
                └─ 各セッションが自力で:
                   ・~/.claude/sessions/<pid>.json に登録（tmux ペイン ID 込み）
                   ・/tmp/cc-socks/<pid>.sock を開く  → SendMessage が届く
                   ・CCR ブリッジに登録              → 単体でも Remote Control 可
                   ・~/.claude/skills の 57 件を見る  → cwd に依らない
```

**自作するのは `ccs` の 1 本だけ。** 一覧・通信・状態は全て組み込みに委譲する。

### 4.2 命名規約

一意な `<slug>` を 1 つ決め、3 箇所で同じものを使う。これが全ての名寄せの鍵になる。

| 場所 | 値 |
| --- | --- |
| tmux セッション名 | `cc/<slug>` |
| Claude の表示名 (`-n`) | `<slug>` |
| Claude の session id | 起動時に生成した UUID を `--session-id` で固定 |

`<slug>` の決め方:

- **リポジトリ**: `ghq list` の末尾要素（`x01`、`catan`）。同名衝突時は `<owner>-<repo>`
- **worktree**: `<repo>@<branch-slug>`（v1 対象外）
- **一時**: `tmp-<枠番号>`（`tmp-1` 〜 `tmp-8`）

> **`tmp-<6桁>` から `tmp-<枠番号>` に変えた。** §4.4 で使い捨て作業枠を固定枠にすると
> 決めた時点で、ランダムな 6 桁は枠番号と二重の識別子になる。枠が有限である以上、
> 番号で足りる。**実装は `tmp-<枠番号>`**（S3、2026-08-17）。

**衝突判定は「利用者がどう打ったか」に依らない。** `x01` と `ken-ty/x01` と
`github.com/ken-ty/x01` は同じ slug に落ちる。打ち方で別セッションが立つと、
下の冪等性が成立しない。

同じ `<slug>` の tmux セッションが既にあれば**新規に立てず、それを返す**（冪等）。
`cc/` 接頭辞により、手動で開いた tmux セッションを巻き込まない。

**slug からは tmux で危険な文字を落とす。** tmux 3.7 はセッション名に `:` を
受け付けてしまうが、`:` は `session:window` の区切りなので、後から `-t` で狙えなくなる
（実測）。`[A-Za-z0-9_@-]` 以外は `-` に潰す。

### 4.3 コマンド

```
ccs new <target> [-- <初期プロンプト>]   # target: リポジトリ名 | ghq パス
ccs new --tmp [-- <初期プロンプト>]       # 使い捨ての作業枠（"tmp" は短い綴り）
ccs ls                                    # claude agents --json を cc/ のものに絞って整形
ccs attach <slug>                         # 人間が乗り込む
ccs send <slug> <message>                 # 補助。通常はハブが SendMessage を使う
ccs kill <slug>                           # ペインごと畳む
ccs gc                                    # 死んだペイン・空の一時ディレクトリを掃除
```

> **追記（2026-08-18）: 枠は `--tmp` で指す。** 当初は `<target>` に `tmp` と書く形だけを
> 用意していたが、`<target>` の名前空間はリポジトリ名と共有している。`ghq get someone/tmp`
> をした瞬間、`ccs new tmp` がどちらを指すのかは打った人にしか分からない。オプションなら
> 名前空間の外なので、この曖昧さが起きない。
>
> **`tmp` も短い綴りとして残す**（既存のドキュメントとハブのエージェントを壊さないため）。
> ただし ghq に `tmp` というリポジトリがあるときだけは、同名リポジトリの衝突と同じく
> 候補を出して止める（§4.2）。

`ccs new` の中身（ここが設計の実体）:

1. `<target>` を解決 → 絶対パス（`ghq list --full-path` で照合。`--tmp` なら作業枠を確保）
2. `cc/<slug>` が既にあれば、その slug を返して終了（冪等）
3. **trust を事前承認**（§4.4）
4. UUID を生成
5. `tmux new-session -d -s "cc/<slug>" -c <path> "claude -n <slug> --session-id <uuid>; exec $SHELL"`
6. レジストリに `<uuid>` が現れるまで待つ（数秒。タイムアウトしたらペインの内容を出して失敗）
7. slug / uuid / tmux ターゲット / transcript パス を JSON で返す

**末尾の `exec $SHELL` が重要**: claude が終了してもペインが残るので、`ccs resume` で
同じ場所に `claude --resume <uuid>` を流し込める（§4.5）。

### 4.4 trust ダイアログの扱い（要判断）

対話モードは新規ディレクトリで止まる。取れる手は 3 つ:

| 案 | 中身 | 評価 |
| --- | --- | --- |
| **A. 事前書き込み** | `ccs new` が `~/.claude.json` の `projects["<path>"].hasTrustDialogAccepted = true` を立ててから起動 | 確実。ただし**安全確認をツールが自動で潰す**ことになる |
| **B. 一時ディレクトリを固定枠にする** | `~/.cc-scratch/{1..8}` を最初の 1 回だけ人が信頼し、以後は使い回す | ダイアログが一度も出ない。一時作業の分離は「使う前に中身を消す」で担保 |
| **C. send-keys で答える** | 起動後にペインを見て `1 Enter` を送る | 実測で動いたが、画面の見た目に依存する。**脆い** |

**推奨は B + A の限定運用。** ghq 配下のリポジトリは既に人が信頼済みのものが大半なので A は
ほぼ発火しない。一時作業は B の固定枠に閉じ込め、A を使うのは「ghq 配下の未信頼リポジトリを
明示的に指定したとき」だけに絞る。C は採らない。

> B なら「一時ディレクトリを毎回作る」より良い副作用がある。枠が 8 本しかないので、
> 使い捨てセッションが無限に増えない。

> **追記（2026-08-18）: 空の枠は ccs が自動で信頼する。** 上の「最初の 1 回だけ人が信頼する」を
> 実機で回したところ、枠 1 本ごとに承認が要ることが分かった（枠 2 を取った `ccs new tmp` が
> 信頼ダイアログで固まり、30 秒待って「登録されませんでした」で終わる）。**枠を何本も立てる
> 運用が実質できない。**
>
> 枠は `ccs` 自身が作ったディレクトリで、渡すのは空だと確かめたときだけ
> （`resolve_as_scratch`）。つまり信頼確認が守ろうとしている「知らないコード」がそこには
> 存在せず、確認は情報を増やさない。ghq 配下と同じ理由で A を適用する
> （[#6](https://github.com/ken-ty/ccs/issues/6) の回答）。
>
> **中身のある枠を実パスで指されたときは自動承認しない。** そこにあるのは誰かが置いたコード
> なので、確認する意味がある。判定は「枠の直下」かつ「いま空」の両方を毎回見る。

### 4.5 生死の扱い

- **生きている** = `claude agents --json` に載っている = ソケットがある = `SendMessage` が届く
- **ペインだけ生きている** = claude が終了した状態。`ccs ls` は `stopped` と表示し、
  `ccs resume <slug>` が同ペインに `claude --resume <uuid>` を送り込む
- **tmux サーバごと落ちた**（再起動など） = 全滅。`~/.claude/projects/**.jsonl` は残るので
  `ccs resume` で個別に復帰。**tmux 自体の永続化（resurrect 等）は入れない** —
  復帰の権限は claude 側の resume が持っている

### 4.6 ハブの役割とスキル

`ccs` はダムなツールにして、判断はスキル側に置く。

**`cross-session-hub` スキルを書き直す**（新設せず、既存を拡張）。理由は、いま書いてある
「新規セッションは開けない」という制約がこの設計で崩れるため、放置すると矛盾する。

追記・変更する内容:

- **二層になったことを書く** — `ListAgents`/`SendMessage`（全横断・要プロセス生存）と
  `ccd_session_mgmt`（デスクトップ限定・停止中も可・履歴が読める）の使い分け（§2.3 の表）
- **`ccs new` で立てられるようになったことを書く** — ただし立てるのはユーザーが頼んだときだけ。
  自発的に増やさない
- **読み取り専用の原則は維持する。** 副作用のある作業を他セッションに投げない現行ルールは、
  新しく立てたセッションにも同じく効かせる。**新規セッションに投げるのも「別セッションに
  投げる」ことに変わりはない** — 権限判断の主体がずれる問題（現行スキルの「安全策」節）は
  そのまま残る

### 4.7 置き場所

- `ccs` の実体 → **新規リポジトリ `ken-ty/ccs`**（`ghq create` で作る。`ghq` スキルの規約に従う）
- スキル本体（`cross-session-hub` の改訂）→ **`agent-skills-store`**
- **`agent-skills` には置かない。** ROADMAP の確定方針に「管轄範囲は skills 限定。
  dotfiles / harness には広げない」とあり、これはハーネス側のツール

---

## 5. 段取り案

| # | 内容 | サイズ |
| --- | --- | --- |
| 1 | `ccs new` / `ls` / `attach` / `kill`（ghq 解決 + 冪等性 + 命名規約） | M |
| 2 | 一時ディレクトリの固定枠（§4.4 案 B）と `ccs gc` | S |
| 3 | `cross-session-hub` スキルの改訂（二層の使い分け + `ccs` の呼び方） | S |
| 4 | `ccs resume`（停止中セッションの復帰） | S |
| 5 | worktree 対応（`ccs new <repo>@<branch>`）。`git-worktree` スキルの規約に合わせる | M |

1 → 3 まで通れば、ハブから「新しいセッションを立てて仕事を頼み、結果を回収する」が回る。

---

## 6. 決定事項（2026-08-17）

| 項目 | 決定 |
| --- | --- |
| `ccs` の置き場所 | **新規リポジトリ `ken-ty/ccs`**（`ghq create`） |
| 実装言語 | **POSIX sh / zsh**。依存は `tmux` と `jq` のみ |
| v1 の範囲 | **段取り 1〜3**。`resume`（4）と worktree（5）は v1 に含めない |
| trust の扱い | **§4.4 案 B + 限定的な A**。固定枠 `~/.cc-scratch/{1..8}` は人が一度だけ信頼し、`hasTrustDialogAccepted` の自動書き込みは「ghq 配下の未信頼リポジトリを明示指定したとき」に限る。案 C（`send-keys` で答える）は採らない |

### 決定から派生する実装上の縛り

- **`jq` を必須依存に加える。** `claude agents --json` を読むため。`tmux` ともども無ければ
  `ccs` は起動時に落として案内を出す
- **v1 に `resume` が無い** = claude が終了したペインは `ccs ls` に `stopped` と出るだけで、
  復帰は人が `ccs attach` して手で `claude --resume <uuid>` を打つ。
  uuid は `ccs ls` が表示する（表示していないと詰むので、これは v1 の要件）
- **v1 に worktree が無い** = 同一リポジトリに 2 本立てると同じ作業ツリーを共有する。
  `ccs new` は同一 slug では冪等に既存を返すので事故にはならないが、
  **並行作業をしたい場合は人が `git worktree` を切ってからそのパスを渡す**

### 残る判断（実装中に確認する）

- `~/.cc-scratch` の枠数 8 が妥当か。使ってみて増減する
- `ccs ls` の出力形式（人が読む表 / ハブが食う JSON）。**両方出す**（`--json` で切替）方針で進める

---

## 7. 実測に使ったコマンド（再現用）

```bash
claude agents --json | jq -r '.[] | "\(.pid) \(.name) \(.cwd)"'
for f in ~/.claude/sessions/*.json; do jq -r '"\(.name)\ttmux=\(.tmux // "-")\tstatus=\(.status // "-")"' "$f"; done
tmux new-session -d -s probe1 -c "$PWD" "claude -n probe-tmux --permission-mode plan; exec zsh"
tmux capture-pane -p -t probe1 | tail -20
claude -p --session-id "$(uuidgen | tr 'A-Z' 'a-z')" --output-format json "Reply with exactly: OK"
```
