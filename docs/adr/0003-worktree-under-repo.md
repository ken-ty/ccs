# ADR-0003: worktree はリポジトリ配下の `.worktrees/` に置き、素性は git から引く

- **状態**: Accepted
- **日付**: 2026-08-26
- **関連**: `docs/design.md` §4.2 / §4.4 / §9.6、`docs/configuration.md`、`docs/restore.md`、
  [ADR-0002](0002-session-identity.md) 決定 5、`bin/ccs` の `worktree_root_abs` /
  `worktree_path_for` / `resolve_as_worktree` / `ensure_worktree` / `path_is_ccs_worktree` /
  `slug_for_path` / `restore_candidates`
- **覆すもの**: `docs/design.md` §9.6 の「置き場所」の行（C1、2026-08-20）。
  **その根拠が今回の配置には当てはまらないことが実測で分かった**（→ 文脈）。
  ADR-0002 決定 5 は**結論を維持し、根拠 3 だけ差し替える**（→ 決定 3）
- **実装**: 別 PR（W1〜W3）。本 ADR では `bin/ccs` を触らない

## 文脈

`ccs new <repo>@<branch>` が切る worktree は、いま **ghq root の外**の別ツリーに置いている。

```
~/.cc-worktrees/<repo-slug>/<branch-slug>
```

`bin/ccs:177-184` と `docs/design.md` §9.6 が、その理由をこう書いている。

> **ghq root の外に置く。** `ghq list` は `<repo>.worktrees/<name>` のような配置を独立した
> リポジトリとして列挙してしまう（実測）。ghq 配下に置くと `resolve_as_repo` の末尾一致が
> worktree にも当たり、`ccs new <branch-slug>` が worktree を掴む。

### 実測: その根拠は「リポジトリ配下」には当てはまらない（2026-08-26）

当時観測されたのは **`<repo>` の兄弟**に置いた配置だった。**`<repo>` の配下**に置いた場合を
測っていない。測った。

```sh
SB=$(mktemp -d); mkdir -p "$SB/github.com/acme"
git init -q "$SB/github.com/acme/demo"
cd "$SB/github.com/acme/demo"
echo hi >a.txt && git add a.txt
git -c user.email=a@b.c -c user.name=t commit -q -m init
git worktree add -q .worktrees/feat-x -b feat-x     # repo 配下（隠し）
git worktree add -q wt/feat-y       -b feat-y       # repo 配下（非隠し）
git worktree add -q ../demo.worktrees/feat-z -b feat-z   # 兄弟
GHQ_ROOT="$SB" ghq list -p
```

結果（ghq 実物 / git 2.50.0 / macOS）:

| 配置 | `ghq list` に出るか |
| --- | --- |
| `…/acme/demo` | 出る（本体。当然） |
| `…/acme/demo.worktrees/feat-z` | **出る** ← 当時観測したのはこれ |
| `…/acme/demo/.worktrees/feat-x` | **出ない** |
| `…/acme/demo/wt/feat-y` | **出ない** |

**`ghq` は `.git` を見つけた時点で、そのディレクトリより下へ降りない**（挙動からの推定。
観測事実は上の表）。したがって「ghq root の外に置く」の根拠は**兄弟配置にだけ効く**もので、
リポジトリ配下には最初から無関係だった。§9.6 は成立しない前提の上に立っている。

### 別ツリーに置いていることの代償

**(a) プロジェクトが 2 か所に散る。** `~/ghq/github.com/ken-ty/ccs` と
`~/.cc-worktrees/ccs/*` は同じリポジトリの作業ツリーだが、`ls`・エディタのワークスペース・
`ghq list` から `cd` する動線のどれからも繋がって見えない。

**(b) 素性をパス規約でしか語れない。** `path_is_ccs_worktree`（`bin/ccs:904-914`）は
「`CCS_WORKTREE_ROOT` 配下か」＋「解決時に立てた変数 `CCS_RESOLVED_WORKTREE_REPO`」で
判定している。**実パスで指されると後者が空なので判定できない** ── ADR-0002 の表 #9 が
既に指摘していた穴で、パス規約に依存している限り塞がらない。

**(c) slug が打ち方で割れる（実測、2026-08-26）。**

```
$ ccs resolve ~/.cc-worktrees/ccs/mobile-terminal
mobile-terminal        /Users/apple/.cc-worktrees/ccs/mobile-terminal
$ ccs resolve ccs@mobile-terminal
ccs@mobile-terminal    /Users/apple/.cc-worktrees/ccs/mobile-terminal
```

同じディレクトリに 2 つの slug が付く。`cc/mobile-terminal` と `cc/ccs@mobile-terminal` が
同時に立ち、**1 つの作業ツリーを 2 本の claude が触る**。冪等性（design.md §4.3）の穴で、
原因は `slug_for_path` が「そのパスが linked worktree かどうか」を知らないこと。

**(d) `feat-foo` と `feat/foo` が同じディレクトリに落ちる。** `branch_slug` は `/` を `-` に
潰す（`bin/ccs:516-518`）。§9.6 はその理由を「潰さないと `feat` と `feat/login` が同居できない」と
書いているが、**その 2 つは git 自身が共存を禁じる**（後述）。潰したことで生まれる衝突のほうが
実在する。

### 実測: リポジトリ配下に置いたとき、何が二重に拾われるか

```sh
cd "$SB/github.com/acme/demo"
git status --short          # → ?? .worktrees/  ?? wt/
git add -A --dry-run        # → warning: adding embedded git repository: .worktrees/feat-x
rg --files                  # → a.txt, wt/feat-y/a.txt   （.worktrees/ は出ない）
printf '/.worktrees/\n' >> .git/info/exclude
git status --short          # → ?? wt/          （.worktrees/ は消える）
rg --files                  # → a.txt, wt/feat-y/a.txt
git -C .worktrees/feat-x status --short   # → 何も出ない（exclude が効いている）
```

| 事実 | 結果 |
| --- | --- |
| `git status` | 追跡外として `?? .worktrees/` が 1 行出る（中までは列挙しない） |
| `git add -A` | **embedded git repository として gitlink で index に入る**。エージェントが打つ形なので事故として現実的 |
| ripgrep | **`.worktrees/` は素で無視する**（ドット始まり＝ hidden）。`wt/` は拾う |
| `.git/info/exclude` に `/.worktrees/` | `git status` が clean になり、`git add -A` の事故も止まる |
| その exclude の適用範囲 | **`--git-common-dir` は全 worktree 共有**なので、1 回書けば linked worktree 側にも効く（実測。入れ子も同時に塞がる） |

### 実測: git は `feat` と `feat/foo` の共存を禁じる

```sh
git branch feat && git branch feat/foo
# fatal: cannot lock ref 'refs/heads/feat/foo': 'refs/heads/feat' exists
git branch -d feat && git branch feat/foo && git branch feat-foo   # ← こちらは両立する
```

`refs/heads/` はファイルシステム上の階層なので、`feat` と `feat/foo` は原理的に同居しない。
一方 `feat-foo` と `feat/foo` は同居でき、いまの `branch_slug` は**両者を同じディレクトリに
落とす**。

## 決定

### 1. 置き場所は `<repo>/.worktrees/<branch-slug>`

`<repo>` は本体（main worktree）の working tree の絶対パス。ghq 配下かどうかは問わない。

```
~/ghq/github.com/ken-ty/ccs/.worktrees/topic
/anywhere/else/repo/.worktrees/topic
```

**ドット始まりであることは飾りではない。** gitignore を読まない道具
（`go build ./...`・pytest の `norecursedirs`・各種 analyzer・`rg` の hidden 既定）が
軒並みドット始まりを既定で飛ばす。`.gitignore` 系の防御と独立した二重の防御になる。

### 2. `.git/info/exclude` に `/.worktrees/` を冪等に書く

`ensure_worktree` が worktree を作る前に、本体の `--git-common-dir` 配下の `info/exclude` へ
1 行足す。既にあれば足さない。ファイルが無ければ作る。末尾に改行が無いファイルを壊さないこと。

**`.gitignore` ではなく `.git/info/exclude` を使う。** 前者は追跡対象なので、先方のリポジトリや
fork に対してこちらの都合で差分を作ることになる（グローバル AGENTS.md「自分が所有しない
コードベース」）。後者は追跡外・clone ローカル・全 worktree 共有で、この制約を満たす。

リポジトリが既に `.worktrees` を追跡している場合（`git ls-files --error-unmatch .worktrees`
が当たる）は、**exclude を書かずに落とす**。そこは利用者のファイルであって ccs の場所ではない。

### 3. 素性は git から引く。パス規約を同一性の根拠にしない

「そのパスは linked worktree か」「本体はどこか」「ブランチは何か」を、次で判定する。

```sh
git -C "$p" rev-parse --absolute-git-dir                    # linked なら .git/worktrees/<n>
git -C "$p" rev-parse --path-format=absolute --git-common-dir  # 常に本体の .git
# 両者が違えば linked worktree。本体の working tree は common-dir の親
git -C "$p" rev-parse --abbrev-ref HEAD                     # ブランチ
git -C "$repo" worktree list --porcelain                    # 一覧（prunable 付き）
```

これで次が同時に片付く。

- `path_is_ccs_worktree` が解決時の変数に依存しなくなる（文脈 (b)、ADR-0002 表 #9）
- `slug_for_path` が実パス指定でも `<repo-slug>@<branch>` を返せる（文脈 (c)）
- `restore_candidates` の 2 段 glob が `git worktree list --porcelain` になる。
  **ディレクトリ名からブランチ名を逆算する必要が消える**

**ADR-0002 決定 5「worktree と ghq 配下には印を置かない」の結論は維持する。** ただし
その根拠 3 番目 ──

> パスも `<CCS_WORKTREE_ROOT>/<repo-slug>/<branch-slug>` で素性を語る（design.md §9.6）

── は本 ADR で無効になる。**根拠 1（git の作業ツリーを汚さない）と根拠 2（git 自身が素性を
持っている）は残り、むしろ強くなる** ── パス規約を読む代わりに `git rev-parse` を直接引くので、
規約と実体がずれる余地が無くなる。したがって `.ccs.json` は引き続き置かない。

### 4. worktree を repo 部に指されたら、本体へ読み替える

`ccs new .@foo` を worktree の中から打つ、`ccs new /abs/…/.worktrees/x@foo` と綴る、の 2 経路。
いまは「それは既に worktree です」と落としている。**落とさず、本体に読み替えて続ける。**

```
ccs: 本体のリポジトリに読み替えました: /Users/apple/ghq/github.com/ken-ty/ccs
```

- **入れ子を「拒否する」のではなく「起こり得なくする」。** 読み替えれば
  `.worktrees/a/.worktrees/b` は原理的に生まれない
- **slug が自動で正しくなる。** slug の `<repo-slug>` は本体から決まる。拒否する設計は、
  正しい slug を得るために呼び出し側が本体のパスを知っていることを要求する
- **決定 3 と同じ処理になる。** `slug_for_path` の穴（文脈 (c)）の直し方も「linked worktree を
  本体とブランチに読み替える」であって、片方で読み替え片方で拒否するのは一貫しない

bare repo の worktree だけは `--git-common-dir` の親に working tree が無いので、落として理由を出す。

なお **`ccs new <repo>@<branch>` の主経路（`ghq list` 経由）はこの判定に触れない** ──
ghq は worktree を列挙しないので、repo 部は必ず本体に解決される（文脈の表）。

### 5. ブランチの slug は flatten のまま。ただし衝突を検出する

`feat/foo` → `feat-foo`。**slug とディレクトリ名を一致させ続けるため**であって、
「`feat` と `feat/login` が同居できないから」ではない（その理由は成立しない。文脈）。

`ensure_worktree` は、あるべきパスに既にディレクトリがあるとき、**その `HEAD` が要求された
ブランチと一致するかを見る。** 違えば落とす。

```
ccs: そこには別のブランチの worktree があります: <path>
     そこにあるのは feat/foo、指定されたのは feat-foo です。
```

これで文脈 (d) の穴が塞がる。`git worktree list --porcelain` を使う限り、ディレクトリ名は
表示上の都合でしかないので、flatten の副作用はここだけに閉じる。

### 6. `CCS_WORKTREE_ROOT` は削除する。移行しない

- 設定キー、既定値、`ccs config` の行、`docs/configuration.md` の行を消す
- **旧レイアウトの読み取り互換も作らない。** `restore_candidates` の候補 3
  （`<root>/<repo>/<branch>` の走査）は削除する
- **テストの差し替え点としても不要になる。** 新レイアウトでは worktree の場所が repo のパスから
  導出され、テストは既にサンドボックス内に本物の git repo を作っている
  （`test/integration/worktree.bats`）ので、worktree は自動的にサンドボックスの中に落ちる。
  `test/test_helper.bash` の `export CCS_WORKTREE_ROOT` と `AGENTS.md` の差し替え点の行も落とす

**利用者は 1 人で、破壊的変更が許容されている。** 版はまだ `0.0.x` の帯で、タグもリリースも
発行していない。移行の段取りを作るコストのほうが、それが守る利益より大きい。

手元に残る 2 本（`~/.cc-worktrees/ccs/{mobile-terminal,worktree-under-repo}`）は**動かさない。**
移動すると cwd が変わり、`transcript_dir_for` が出す会話ログの置き場所が変わって
`ccs restore` から引けなくなる。使い切ってから手で消す（→ 影響・運用）。

### 7. 撤去は `ccs gc` が担う。`--force` / `-D` は使わない

`ccs kill` は **worktree を消さない**（§9.6 の決定を維持）。畳んだあとに片付け先を 1 行案内する。

`ccs gc` は既定 dry-run のまま、worktree を 4 分類で報告する。

| 状態 | 扱い |
| --- | --- |
| 生きたセッション無し + clean + ブランチが merged | **消す候補。** `--yes` で `git worktree remove` → `git branch -d` |
| 生きたセッション無し + clean + 未 merge または未 push | **報告だけ** |
| dirty（追跡外ファイルを含む） | **報告だけ** |
| `prunable`（ディレクトリだけ消えている） | `git worktree prune` の候補 |

**`git worktree remove` と `git branch -d` を素で使うことが安全性の本体。** 実測:

- `git worktree remove` は dirty な worktree を拒む。**clean なら未 merge コミットがあっても
  消す** ── ただしブランチ ref は残るのでコミットは失われない
- `git branch -d` は未 merge を拒む。**コミットを守るのはこの層**

この 2 つを force 無しで直列に通す限り、「未 push かつ未マージ」は自動では消えない。
`--force` / `-D` に切り替えるところが人に聞く境界になる（グローバル AGENTS.md）。

上流が無いブランチ（`git log @{u}..` が `fatal` になる）は**「未 push」として報告側に倒す。**

### 8. 「作業開始時に既定で worktree を切る」は採らない

`ccs new <repo>` が本体を直接開くのをやめ、常に worktree を切る案は採らない（→ 捨てた案）。
**同じ作業ツリーに 2 本の claude を立てない**という目的は、ADR-0002 決定 3（冪等性を cwd 照合へ
移す。バックログ I1）が担う。

## 根拠

### なぜ「リポジトリ配下」なのか（4 案の比較）

| 観点 | A 現状 `~/.cc-worktrees` | **B `<repo>/.worktrees/`** | C `<repo>/worktrees/` + `.gitignore` | D 兄弟 `<repo>.worktrees/` |
| --- | --- | --- | --- | --- |
| `ghq list` に混ざる | 混ざらない | **混ざらない**（実測） | 混ざらない | **混ざる**（実測） |
| `git status` | 無関係 | clean（exclude） | clean | 無関係 |
| `git add -A` の gitlink 事故 | 無し | 防げる | 防げる | 無し |
| ripgrep / grep 系 | 無関係 | **素で無視**（hidden）＋ exclude | `.gitignore` 依存 | 無関係 |
| gitignore を読まない道具 | 無関係 | **既定で無視**（ドット始まり） | **拾う** | 無関係 |
| 先方のリポジトリを汚すか | 汚さない | **汚さない**（exclude は追跡外） | **汚す**（`.gitignore` は追跡対象） | 汚さない |
| プロジェクトが 1 か所に | ✗ | **✓** | ✓ | △ |
| 素性を git から引けるか | 引けるが規約に依存 | **引ける** | 引ける | 引ける |

C の致命傷は最下段のひとつ上 ── fork や先方のリポジトリに `.gitignore` の 1 行を足すのは、
こちらの都合で追跡ファイルを書き換える行為で、グローバル AGENTS.md に正面から反する。

### なぜ exclude を書くのか（ドット始まりだけでは足りない）

ripgrep は `.worktrees/` を素で飛ばすが、**`git status` と `git add -A` は飛ばさない**（実測）。
`git add -A` はエージェントが日常的に打つ形で、通ると gitlink がコミットに載る。
ドット始まりは「読む道具」への防御、exclude は「書く道具」への防御で、役割が違う。

### なぜパス規約ではなく git に訊くのか

パス規約は**書く側の約束**であって、**読む側の事実**ではない。`path_is_ccs_worktree` が
実パス指定で判定できないのも、`slug_for_path` が打ち方で割れるのも、規約を知っている経路と
知らない経路が同じディレクトリを別物として扱うことから来ている（文脈 (b)(c)）。
`git rev-parse` は経路に依らず同じ答えを返す。

これは ADR-0002 決定 1「名前は同一性の根拠にしない」の、パスへの拡張にあたる。
**パスもまた名前である。**

## 捨てた案

**`.gitignore` に書く。** 追跡対象なので、所有していないリポジトリに差分を作る。
`.git/info/exclude` は同じ効果を追跡外で得られるうえ、全 worktree で共有される。

**非隠しのディレクトリ名（`worktrees/`・`wt/`）。** gitignore を読まない道具に素通りする
（実測: `rg --files` が `wt/feat-y/a.txt` を拾い、`.worktrees/feat-x/a.txt` は拾わない）。
見た目の分かりやすさより、防御が二重になることを取る。

**兄弟配置 `<repo>.worktrees/<name>`。** `ghq list` が独立したリポジトリとして列挙する（実測）。
C1 で退けた形そのもので、退けた判断は正しかった。

**ブランチの階層をディレクトリに掘る（`.worktrees/feat/foo`）。** git が `feat` と `feat/foo` の
共存を禁じるので衝突はしないが、ディレクトリ名と slug がずれ、列挙が再帰 glob になる。
決定 3 で列挙を `git worktree list` に移すと、掘って得るものが無くなる。

**`git worktree lock` で稼働中の worktree を守る。** 解除忘れが新しい詰まりを作る。
ADR-0002 決定 2 の「更新が要るものは必ず腐る」に反する。稼働中かどうかは、その都度
レジストリの `cwd` から引けばよい（ADR-0002 決定 3）。

**`CCS_WORKTREE_ROOT` をフォールバックとして残す。** リポジトリに書けない状況
（read-only mount など）で別の場所へ逃がす案。黙って別の場所に作るより、落として理由を
出すほうがよい。設定キーが 1 つ残ると、「効いているのはどちらか」を人が確かめる手間も残る。

**`ccs new <repo>` でも既定で worktree を切る。** 検討したが採らない。

- **冪等性（design.md §4.3）が壊れる。** hub は「その名前のセッションが欲しい」と言っているので
  あって「必ず新しく作れ」ではない。毎回切ると `ccs new x01` が二重に立つ
- **ccs がブランチ名を発明することになる。** リポジトリのブランチ名前空間を汚し、
  後片付けの対象が worktree だけでなくブランチにも増える
- **本体を開きたい正当な用途がある。** main のレビュー、リリース、履歴を見るだけのセッション
- `--tmp` や git でないパスでは成立せず、target の種類で挙動が割れる
- **目的の大半は I1 が達成する。** 冪等性を cwd 照合に移せば 2 本目は既存を返す ＝
  同じ作業ツリーに 2 本の claude は立たない。残る差分は「ccs 以外（人のエディタ、素の
  `claude`）が本体を触る」ケースだけで、それは ccs の責務外

## 影響

### コード（別 PR。本 ADR では触らない）

| # | 内容 | サイズ |
| --- | --- | --- |
| W1 | **素性判定を git に移す。** linked 判定・本体の特定・ブランチ取得のヘルパを追加し、`resolve_as_worktree` の入れ子チェック（`bin/ccs:582-589`）と `path_is_ccs_worktree`（`:904-914`）をパス前方一致から git へ。`slug_for_path`（`:422-455`）の穴（文脈 (c)）も塞ぐ。**置き場所は変えない** | S |
| W2 | **置き場所を `<repo>/.worktrees/<branch-slug>` へ。** `worktree_root_abs` / `worktree_path_for`（`:536-546`）を作り替え、`ensure_worktree`（`:616-656`）に exclude 書き込みと衝突検出を足す。決定 4 の読み替え。`CCS_WORKTREE_ROOT` を削除し、`restore_candidates` の候補 3（`:1889-1901`）を `git worktree list` へ | M |
| W3 | **`ccs gc` の worktree 4 分類**と `git worktree prune`。`ccs kill` の案内 1 行 | S |

`git` は引き続き必須依存に入れない（`@` を使ったときだけ要る）。決定 3 の判定は git が
無ければ「linked ではない」に倒す。

**版**: `CCS_VERSION` を `0.0.1` に付け替える（別の `chore:` コミット。タグもリリースも
発行していないので外部影響は無い）。W2 が `0.0.2`。

### ドキュメント

- `docs/design.md` §9.6 の「置き場所」の行を書き換え、本 ADR を参照する。
  ブランチ slug の行の理由も直す（「同居できない」は成立しない）
- `docs/configuration.md:69` の `CCS_WORKTREE_ROOT` の行を削除
- `docs/restore.md:37` の候補 3 の行と `:74` の note を書き換え
- `AGENTS.md:93` の差し替え点の行を削除
- `bin/ccs:177-184` のコメントを書き換え、ADR 番号を添える（ADR README の規律）
- `docs/adr/README.md` の一覧と `mkdocs.yml` の nav に本 ADR を足す
- ADR-0002 決定 5 に「根拠 3 は ADR-0003 で差し替え。結論は維持」を追記

### 運用

手元の 2 本は**動かさない**（決定 6）。W2 のマージ後、使い切ってから手で片付ける。

| worktree | ブランチ | 状態 |
| --- | --- | --- |
| `~/.cc-worktrees/ccs/mobile-terminal` | `close-19` | clean、**origin/main より ahead 1 で未 push**。セッション稼働中。`site/`（mkdocs 成果物、追跡外）3.7M |
| `~/.cc-worktrees/ccs/worktree-under-repo` | `worktree-under-repo` | clean、コミット 0 本、上流なし。セッション稼働中（本 ADR を書いているセッション） |

```sh
ccs kill ccs@<slug>
git -C ~/ghq/github.com/ken-ty/ccs worktree remove ~/.cc-worktrees/ccs/<slug>
git -C ~/ghq/github.com/ken-ty/ccs branch -d <branch>
rmdir ~/.cc-worktrees/ccs ~/.cc-worktrees
```

`branch -d` は未 merge を拒むので、マージ前に打つと止まる。**それが正しい挙動**（決定 7）。

trust は両方 `~/.claude.json` に登録済みなので、`path_is_ccs_worktree` を消しても
信頼確認は出ない（実測）。

`restore` の候補 3 が消えるので、この 2 本は「消えた worktree」としては列挙されなくなる。
ただし **tmux セッションが生きている限り候補 1（止まったペイン）が拾う**ので、実害は無い。

## 未決

- ~~**`ccs kill --prune-worktree`**（畳むと同時に撤去するオプトイン）を用意するか。~~
  → **用意しない**（W3、2026-08-26）。**畳む時点は、判断に要る情報がまだ揃っていない。**
  消してよいかは「merge 済みか」「push 済みか」で決まるが、その 2 つが真になるのは PR が
  マージされたあとで、セッションを畳むのはそれより前。畳むと同時に撤去しようとしても
  `git branch -d` が拒むので、オプションは**ほぼ必ず空振りする**。手元の `close-19` が
  まさにその形だった ── セッションは畳んだが、ブランチは未 merge・未 push のまま残っている。
  `ccs gc` は冪等で安いので、マージしたあとに打てばよい。`ccs kill` は片付け先を 1 行
  案内するだけにした（決定 7）
- **`.worktrees` を既に追跡しているリポジトリ**に当たったとき、落とす以外の逃げ道が要るか。
  いまは実例が無いので落とすだけにする
