# ハブの組み込みツール

`ccs` で立てたセッションに**指示を送るのは `ccs` ではない**。そこはエージェントの
組み込みツールが担当する（[設計調査 §1](design.md#1-結論) で「自作しない」と決めた部分）。

**これらはシェルのコマンドではない。** ターミナルに打っても何も起きない。
ハブ（Remote Control を張った 1 本）の**チャットに日本語で頼む**と、エージェントが呼ぶ。

| ツール | 何をする | 呼ばれ方 |
| --- | --- | --- |
| [`ListAgents`](#listagents) | 生きているセッションを一覧する | ハブのチャットで頼む |
| [`SendMessage`](#sendmessage) | セッションに指示を送り、返答を受け取る | ハブのチャットで頼む |

宛先に使う名前は `ccs` が返した `slug` そのもの。`ccs new` の JSON に出る `slug` が、
tmux セッション名（`cc/<slug>`）でもツール上の相手の名前でもある
（[命名規約](design.md#42-命名規約)）。

### `ccs ls --json` が返すもの

```json
{"slug":"x01","status":"idle","sessionId":"…","path":"/…/x01","tmux":"cc/x01",
 "labels":{},"startedAt":1788085167489,"transcript":"/…/….jsonl","worktree":null}
```

| キー | 何 |
| --- | --- |
| `status` | `idle` / `busy` / `waiting` / `stopped` |
| `startedAt` | 起動時刻（epoch ミリ秒）。止まっていれば `null` |
| `transcript` | 会話ログの場所。**止まっていても残る**（cwd と sessionId から決まるので） |
| `worktree` | linked worktree なら `{"repo":…,"branch":…}`、違えば `null` |
| `labels` | `--label` で付けた目印（下記） |

`ccs ls -l --json` は、これに盤面の列（`pid` / `rssMb` / `updatedAt` / `age` / `request`）が
足される。**既定の `--json` に入れたものは、どれも新しいプロセスを増やさない** ──
`startedAt` はレジストリから、`transcript` は組み立てるだけ、`worktree` は `.git` が
ファイルかという安い門番で大多数が落ちる。

### 紐付けの目印（`--label`）

`ccs new <target> --label k=v`（反復可）で、そのセッションに**不透明な文字列**を付けられる。
`ccs ls --json` の `labels` で返る。

```console
$ ccs new x01 --label task=T-12 --label board=main
$ ccs ls --json | jq -r '.[] | select(.labels.task == "T-12") | .slug'
x01
```

- **`ccs` は中身を解釈しない。** 知らせると 4 責務が 5 つ目に膨らむ（design.md §9）。
  検査するのは「key があること」だけで、値には空白も `=` も日本語も入る
- **渡した key だけを上書きし、他は消さない。** 「いま渡したものが全部」にすると、
  ラベルを知らない側が `ccs new` を打つたびに紐付けが消える
- 置き場所は tmux のユーザオプション。**セッションを畳めば一緒に消える**（状態を持たない）

### `ccs new` が失敗したとき

**stdout に 1 行の JSON が出る。** 終了コードだけでは「曖昧で選べない」のか
「trust で固まった」のかが区別できない。

```console
$ ccs new
{"error":{"code":"usage","message":"new: <target> を指定してください（…）","exit":2}}
```

| `code` | 何が起きたか | 打ち直しで直るか |
| --- | --- | --- |
| `usage` | 引数の誤り（未知のオプション、target 無し） | **直る** |
| `scratch-full` | 使い捨ての作業枠が全部埋まっている | 片付ければ直る（`ccs gc`） |
| `stale-pane` | ペインは残っているが claude が動いていない | `ccs restore <slug>` |
| `not-registered` | 立てたが登録されなかった（trust やログインで止まっている疑い） | `ccs attach <slug>` で確かめる |
| `fail` | それ以外 | `message` を読む |

**成功したときの形は変わらない**（`error` は足さない）。`message` は stderr に出る
人間向けの文と同じもの ── 2 つ書くと必ずずれるので、片方から作っている。

---

## ListAgents

いま生きているセッションを並べる。**引数は要らない。**

```
> ListAgents で今あるセッションを見せて
Peer sessions (7):
  catan [e679d3]  ·  interactive  ·  idle  ·  started 6s ago
  x01 [80bd9b]  ·  interactive  ·  idle  ·  started 17s ago
```

読み方:

| 出るもの | 中身 |
| --- | --- |
| 名前 | `ccs` の `slug`。`ccs new x01` で立てたものは `x01` |
| `[e679d3]` | そのセッションの短い識別子。`ccs ls` が出す `SESSION ID` とは別物 |
| `interactive` | 対話モードで動いている（`-p` の一発実行ではない） |
| `idle` / なし | 手が空いているか、何か走らせている最中か |

打ち方の例:

> ListAgents で今あるセッションを見せて

> いまどのセッションが動いてる？

!!! warning "名前は変わることがある"
    ここに出る名前は `ccs` が渡した `slug` で**始まる**が、**その後の会話や
    リネームで変わる**（実測: `tmp-1` → `朝会夕会`）。`SendMessage` の宛先は
    「いま `ListAgents` に出ている名前」であって、立てたときの slug とは限らない。

    tmux 側の名前（`cc/<slug>`）は変わらないので、対応づけを確かめるなら
    `ccs ls`。ハブ自身（`ccs hub`）は `--remote-control <slug>` を明示して
    立てるので、アプリ上でも名前が動かない（[hub](hub.md#名前とアプリでの見え方)）。

!!! warning "止まったセッションは出ない"
    `ListAgents` が見ているのは**生きている claude プロセス**。`/exit` などで claude が
    終了すると、tmux のペインが残っていても一覧から消える。
    ペインごと見たいときは `ccs ls`（[使い分け](#ccs-ls-との使い分け)）。

---

## SendMessage

セッションに指示を送り、返答を受け取る。宛先は `slug`。

打ち方の例:

> x01 のセッションに「このリポジトリの README の見出しだけ列挙して」と頼んで、結果を教えて

> tmp-1 に、いま何をしているか聞いて

返答は数十秒かかることがある。相手も 1 本の Claude Code なので、調べ物を頼めば調べるあいだ待つ。

!!! danger "頼むのは読み取りだけ"
    副作用のある作業（コミット、PR の作成、外部への送信）を他のセッションに投げない。
    **新しく立てたセッションに投げるのも「別セッションに投げる」ことに変わりはない。**
    権限の判断をした主体と、実際に手を動かす主体がずれる
    （`cross-session-hub` スキルの原則。[設計調査 §4.6](design.md#46-ハブの役割とスキル)）。

!!! warning "届く相手はプロセスが生きているものだけ"
    `ListAgents` に出ていない相手には届かない。`ccs ls` が `stopped` と言うなら、
    先に `ccs attach <slug>` して `claude --resume <uuid>` で起こす。

---

## `ccs ls` との使い分け

同じセッション群を、別のところから見ている。**どちらも要る。**

| | `ListAgents` | `ccs ls` |
| --- | --- | --- |
| 見ているもの | 生きている claude プロセス | `cc/` が付いた tmux セッション |
| 止まったセッション | 出ない | `stopped` として出る |
| `ccs` 以外のセッション | 出る（デスクトップ・VS Code も横断する） | 出ない |
| セッション ID | 短い識別子だけ | `claude --resume` に貼れる UUID |
| 呼び方 | ハブのチャットで頼む | シェルのコマンド |

**`ccs` が立てたものだけを、UUID 込みで見たいときは `ccs ls`。**
ハブから相手を選ぶときは `ListAgents`。

---

## そのほか

デスクトップアプリのセッション履歴を読む `mcp__ccd_session_mgmt__*` という別系統がある。
**tmux のセッションも VS Code のセッションも見えない**ので、`ccs` の用途では出番が無い。
実測した違いは [設計調査 §2.3](design.md#23-cross-session-hub-スキルは-tmux-セッションを見られない要更新) に表がある。
