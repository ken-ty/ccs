# AGENTS.md — ccs

グローバルの AGENTS.md を前提に、このリポジトリ固有のことだけを書く。

## このリポジトリは何か

`ccs` は、ハブ 1 本から tmux 上に Claude Code セッションを立て・見つけ・畳むための薄い CLI。
**設計の正本は [docs/design.md](docs/design.md)。** 実装前に実測で確定させたものなので、
これに反する実装をしないこと。特に次の 2 点は繰り返し忘れられる:

- **一覧・セッション間通信・状態は自作しない。** `claude agents --json` と組み込みの
  `ListAgents` / `SendMessage` に委譲する。`tmux send-keys` でのプロンプト注入は採らない
- **`ccs` が持つのは 4 つだけ** — セッションの新規作成 / trust ダイアログの回避 /
  ghq・一時ディレクトリの解決 / 命名規約と後片付け

`hub`（常時 1 本のハブ）と設定層はこの 4 つの延長にある（design.md §8）。ここでも:

- **hub の死活監視に自前のデーモンを作らない。** `ccs hub up` を冪等にして、
  launchd / systemd から定期実行する。設定ファイルは出すだけで、設置は人がやる
- **既定値を作者の環境に固定しない。** 他人の環境ではぶつかる（`hub` はリポジトリ名
  としてありふれている）。新しい既定値を足すときは `CCS_CONFIG_KEYS` に載せて
  設定で変えられるようにし、`ccs config` に出す
- **設定ファイルを `source` しない。** 設定と実行の境界が無くなる

外部のボード ccb（**private リポジトリ**）がこのツールを叩く（design.md §9）。
**その都合でこのリポジトリの性格を変えない**:

- **`ccs` はタスクを知らない。** 紐付けは `ccs new --label` の**不透明な文字列**として
  運ぶだけで、中身を解釈しない。知らせると 4 責務が 5 つ目に膨らむ
- **ccb 無しで `ccs` が使えることを壊さない。** 追加はすべて任意のオプションで、
  終了コード・`--` の意味・既定の出力を変えない
- **ポーリングするのは `ccb` 側。** 盤面のために `ccs` にデーモンを足さない

## 公開リポジトリとしての書き方

**このリポジトリは public にする（判定済み）。** 書いたものは全世界から読める前提で書く。

- **新しく private リポジトリの名前・実パス・個人情報を書かない。** 例示には汎用名を使う
  （`example/repo`、`~/ghq/github.com/<owner>/<repo>`、`/Users/you/...`）
- **private リポジトリはリンクにしない。** 公開後は 404 になるだけなので、
  「private リポジトリ」と明記して名前だけ出すか、参照そのものを落とす
- **`scripts/termshot.py` で画面を撮り直すときは題材に注意する。** SVG には
  `ccs ls` の出力がそのまま入るので、public なリポジトリか汎用名で撮る
- 秘密（API キー、トークン、鍵）はそもそも置かない。テストの fixture も同じ

**既に履歴に入っているものは遡って消さない。** 公開判定の時点で、`x01` / `catan` /
`ccb` / `cost-management` / `agent-skills-store` / `collection_deck_ja` の名前が履歴に
埋まっていることを確認し、**その開示は受け入れた**（名前だけで、中身も取引先も秘密も
含まない）。履歴の書き換えはしない。**やるのは「これ以上増やさない」こと。**

## 承認レベル

**個人の private リポジトリ。先方も上流も無い。** グローバルの既定より緩める。

| 操作 | 扱い |
| --- | --- |
| ブランチ作成・コミット・push | 自由 |
| PR 作成 | 自由 |
| **PR のセルフマージ** | **自由**（`.claude/settings.json` で宣言済み） |
| ローカルの worktree / ブランチ / タグの削除 | 自由 |
| リポジトリ設定の変更（可視性・ブランチ保護・Actions・コラボレータ） | **人間の承認が要る** |
| force push、push 済み履歴の書き換え、リモートブランチの削除 | **人間の承認が要る** |
| 外部への送信（Issue/PR へのコメント以外） | **人間の承認が要る** |

**可視性は現在 private。** 公開に切り替えるかは未決なので、公開前提の記述
（GitHub Pages の URL 等）を勝手に足さない。

## 開発の作法

- ブランチは 1 トピック 1 本。`main` へ直接コミットしない
- **新しい clone では `make setup-hooks` を実行する。**
  `core.hooksPath` は `.git/config` のローカル設定で clone には付いてこない
  （**同じリポジトリの worktree には引き継がれる**ので、worktree ごとには不要）→ 「検証ゲート」
- コミットは Conventional Commits。理由 (why) は body に書く
- **判断が要ることはチャットで聞かず GitHub Issue に上げる**（`question` ラベル）。
  ループは非同期で走るので、チャットでの質問は人間が気づかない
- 1 サイクル = ROADMAP の S 項目 1 つ = 実装 → テスト → 自己レビュー → ドキュメント更新 → PR

## テストの方針

**「テストが書けない設計にしない」ことがこのリポジトリの主要な制約。**
tmux を起動し `claude` を立ち上げるツールなので、素朴に書くと
「テストのたびに本物の Claude が起動してトークンを食う」ことになる。それを避けるため、
**差し替え点を env で外に出す**。

| 変数 | 既定 | テストでの用途 |
| --- | --- | --- |
| `CCS_CLAUDE_BIN` | `claude` | fake claude スタブに差し替える |
| `CCS_TMUX_BIN` | `tmux` | 通常は差し替えない（本物の tmux で検証する） |
| `CCS_SESSIONS_DIR` | `~/.claude/sessions` | 一時ディレクトリに逃がす |
| `CCS_TRUST_FILE` | `~/.claude.json` | 一時ファイルに逃がす。**本物を書き換えるテストは書かない** |
| `CCS_SCRATCH_ROOT` | `~/.cc-scratch` | 一時ディレクトリに逃がす |
| `CCS_WORKTREE_ROOT` | `~/.cc-worktrees` | 一時ディレクトリに逃がす。**漏れると本物の worktree がブランチごと生える** |
| `CCS_GHQ_BIN` | `ghq` | 固定のリポジトリ一覧を返すスタブに差し替える |
| `CCS_GIT_BIN` | `git` | **差し替えない**（worktree の生成は git の挙動そのもの。課金もネットワークも無い） |
| `CCS_CONFIG_FILE` | `~/.config/ccs/config` | 一時ファイルに逃がす。**本物を読ませない** |
| `CCS_HUB_HOME` | `~/.cc-hub` | 一時ディレクトリに逃がす |

hub のテストでは、fake claude の `FAKE_CLAUDE_NO_BRIDGE` / `FAKE_CLAUDE_ECHO` で
「RC が付かない」「認証を求めて止まる」を作る。**tmux サーバの環境は起動時に
固定される**ので、つまみはその test の最初の `ccs` 実行より前に export する。

3 層に分ける:

1. **unit** — 引数パース、slug 決定、パス解決。外部プロセスを起動しない。速い
2. **integration** — **本物の tmux** + **fake claude**（`test/fixtures/fake-claude`）。
   レジストリ JSON を書いてアイドルするだけのスタブなので、**API を一切叩かない**。
   tmux 起動・レジストリ待ち・冪等性・後片付けはここで検証する。
   異常系は `FAKE_CLAUDE_*` のつまみで作る（登録遅延・登録しない・自ら終了など。
   一覧はスタブ本体の先頭コメント）。**新しい異常系が要るときは、テスト側で
   小細工せずスタブにつまみを足す** — 小細工は他のテストから見えない
3. **manual** — 本物の `claude` を使う確認。自動化しない。手順は
   [docs/hands-on.md](docs/hands-on.md) に置き、人間がなぞる

**`make test` は `LC_ALL=C` で走らせる**（Makefile が付ける）。macOS 標準の
bash 3.2 + bats の組み合わせだと、日本語を含むテスト名が化けて
「unknown test name」になり、**1 件も実行されないまま緑になりかける**。

**アサーションの `[[ ]]` には必ず `|| return 1` を付ける。** 同じ bash 3.2 に
もう 1 つ穴がある ── **テストの途中に置いた `[[ ]]` は、失敗しても errexit で
落ちない**。`false` も `[ ]` も関数の戻り値もすべて落ちるのに、`[[ ]]` だけが
素通りする（bash 4 で直っている）。付け忘れると、そのアサーションは
**手元では検証していないのと同じ**になり、Linux の CI でだけ落ちる。

```sh
[[ "$stderr" == *"worktree list"* ]] || return 1
```

`make lint` が素の `[[ ]]` を見つけたら落とす。**これは書式の好みではなく、
空振りするテストを禁じるための検査。**

**integration で本物の `claude` を起動しない。** これを破ると CI が課金され、
ローカルのテストがログイン状態に依存し、実行のたびに結果が変わる。

### 手元の環境に依存させない

CI（ubuntu / tmux の外 / C ロケール）と手元（macOS / **tmux の中** / ja_JP.UTF-8）は
違う。ここを踏むと「CI では通るのに手元でだけ落ちる」が起きて、
**検証ゲート（下記）が使い物にならなくなる**。実際に 2 つ踏んだ。

- **ロケール**: macOS 標準の bash 3.2 + bats だと、日本語を含むテスト名が化けて
  「unknown test name」になり **1 件も実行されない**。Makefile の
  `BATS_ENV ?= LC_ALL=C` が固定する
- **tmux**: ccs は tmux のためのツールなので、開発者は **tmux の中**で
  `make check` を回す。「tmux の外」を前提にするテストは ambient の `$TMUX` を
  継承しないよう、**テスト側で明示的に `unset TMUX TMUX_PANE` する**

## 検証ゲート — 手元とマージ前の 2 段

**CI は `main` への push と PR の両方で回る**（2026-08-23 に PR 側を戻した。
public にしたので標準ランナーが無料になり、ruleset で required check にできる)。
`ci.yml` の `check` は **`main` の ruleset で required** にしてあるので、
**赤い PR はマージできない。**

そのうえで、関門は手元にもある。**手元で落とすほうが速い**ので、CI は最後の
関門であって最初の関門ではない。

```sh
make setup-hooks    # git config core.hooksPath hooks
```

`core.hooksPath` は `.git/config` に入るリポジトリごとのローカル設定で、
**clone には付いてこない**（`.git/config` は複製されない）。clone したら 1 度実行する。

**同じリポジトリの worktree には引き継がれる。** `core.hooksPath` は共有の
`.git/config` にあり、worktree もそれを読むため（`extensions.worktreeConfig` を
有効にしていない限り）。worktree を足すたびに実行し直す必要は無い。

フックが回すのは CI と同じもの。

| いつ | 何を | 対応する CI |
| --- | --- | --- |
| 毎回 | `make check`（lint + unit + integration） | `ci.yml` |
| `docs/` `mkdocs.yml` `requirements-docs.txt` `scripts/termshot.py` `.github/workflows/docs.yml` が変わったとき | `make docs-build` | `docs.yml` |

**docs のパス一覧は `docs.yml` の `&docs_paths` と `hooks/pre-push` の 2 箇所にある。
片方を変えたら両方直すこと。**

逃げ道は `git push --no-verify`。使ってよいのは「CI で確かめたい」ときだけ
（**マージ前に PR で捕まる**ので、main を壊すことにはならない）。

### 手元で再現できないものが 1 つある

`ci.yml` の**「本物の claude を起動していないことを確かめる」だけは手元で意味を持たない。**
あれはランナーに `claude` が入っていないことを利用した保険で、`claude` が入っている
開発機では常に素通りする。**このステップだけは `main` への push でしか検証されない** —
テストが本物を起動する作りに変わってしまった場合、気づくのはマージ後になる。

shellcheck は手元も CI も 0.11.0 で揃えてあるが、bash と coreutils の差は残る。
**main で落ちたら revert せず fix-forward で直す。**

経緯は別リポジトリ（**private**）の issue にある。要点は ci.yml の冒頭コメントに写してある。

## 依存

- 必須: `tmux`、`jq`
- 開発: `bats-core`（テスト）、`shellcheck`（静的検査。**CI は v0.11.0 に固定**）
- ドキュメント: `uv`（`uvx` 経由で mkdocs を実行。グローバルに入れない）

CI で入るもの以外を勝手に増やさない。増やすなら ROADMAP に項目を立ててから。
