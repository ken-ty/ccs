# 手を動かして確かめる

**実機で 1 周する手順。** 上から順に打てば、`ccs` が本当に動くかを自分の目で確認できる。

各手順には「期待される出力」と「違ったときに見るところ」を付けた。
**期待される出力は、すべてこのマシンで実際に上から順に走らせて得たもの**
（UUID と時刻だけは毎回変わる）。信頼確認の 30 秒待ちも、`/exit` のあとに
ペインがシェルへ戻ることも、実機で確認した上で書いている。

所要時間はおよそ 15 分。**途中でやめても、最後の「元に戻す」だけやれば跡は残らない。**

---

## 0. 前提を確かめる

```bash
tmux -V && jq --version && claude --version && which ccs
```

**期待される出力**（版は前後してよい）:

```
tmux 3.7b
jq-1.8.1
2.1.226 (Claude Code)
/Users/apple/.local/bin/ccs
```

??? question "`ccs` が見つからない"
    symlink を張る。

    ```bash
    ln -sf ~/ghq/github.com/ken-ty/ccs/bin/ccs ~/.local/bin/ccs
    ```

??? question "`tmux` か `jq` が無い"
    ```bash
    brew install tmux jq
    ```
    `ccs` は依存が無いと**終了コード 4** で落ち、導入方法を出す。それも試してよい:
    `CCS_JQ_BIN=nope ccs ls`

---

## 1. 触る前の状態を控える

**あとで「元に戻ったか」を確かめるため。** 何も変わっていないことを最後に確認する。

```bash
tmux ls; ls ~/.cc-scratch 2>&1 | head -3; jq -r '.projects | length' ~/.claude.json
```

**期待される出力**（まだ tmux を使っていなければ）:

```
no server running on /private/tmp/tmux-501/default
ls: /Users/apple/.cc-scratch: No such file or directory
55
```

!!! note "数字は控えておく"
    最後の数字（`.projects` の件数）を覚えておく。**手順 9 以外では増えないはず。**

---

## 2. 何も起きないことを確かめる

`resolve` は**副作用が無い**。まずここで、打ち間違いが安全に分かることを見る。

```bash
ccs resolve x01
```

**期待される出力**:

```
x01	/Users/apple/ghq/github.com/ken-ty/x01
```

続けて、曖昧なときに**勝手に選ばない**ことを見る。

```bash
ccs resolve IceCubesApp
```

**期待される出力**（終了コードは 1）:

```
ccs: IceCubesApp に当てはまるリポジトリが複数あります:

  Dimillian/IceCubesApp
  ken-ty/IceCubesApp

<owner>/<repo> の形で指定し直してください。
```

**ここまでで tmux セッションは 1 つも立っていない。** 確かめる:

```bash
tmux ls
```

→ `no server running ...` のまま。

---

## 3. 立てる

```bash
ccs new x01
```

**期待される出力**（1 行の JSON。`sessionId` は毎回変わる）:

```json
{"slug":"x01","sessionId":"0ecd87dd-…","path":"/Users/apple/ghq/github.com/ken-ty/x01","tmux":"cc/x01","transcript":"/Users/apple/.claude/projects/-Users-apple-ghq-github-com-ken-ty-x01/0ecd87dd-….jsonl","created":true,"running":true}
```

見るところ:

- `created` が `true`
- `running` が `true`
- 数秒で返る（30 秒待たされたら手順 3 の下の「うまくいかないとき」へ）

??? failure "30 秒待って「登録されませんでした」と言われた"
    `ccs` はペインの中身を見せてくれる。だいたいは次のどれか:

    - **信頼確認で止まっている** → `ccs attach x01` して「1. Yes, I trust this folder」
    - **ログインが切れている** → `ccs attach x01` して `/login`
    - それ以外 → ペインの内容をそのまま読む

    **`ccs` はこのときセッションを消さない。** 何に詰まったかを見られるようにするため。
    諦めるときは `ccs kill x01`。

---

## 4. ハブから見えることを確かめる（ここが核心）

**`ccs` を作った理由はこの 1 点。** 立てたセッションに、このハブから指示を送れること。

このチャットで、こう聞く:

> ListAgents で今あるセッションを見せて

**期待される結果**: 一覧に `x01` が `interactive · idle` として現れる。

```
Peer sessions (7):
  x01 [80bd9b]  ·  interactive  ·  idle  ·  started 17s ago
  …
```

続けて、実際に仕事を頼んでみる:

> x01 のセッションに「このリポジトリの README の見出しだけ列挙して」と頼んで、結果を教えて

**期待される結果**: 数十秒で、x01 側が調べた内容が返ってくる。

!!! success "ここが通れば、狙っていたものは動いている"
    ターミナルを 1 度も開かずに、新しいセッションを立てて仕事を頼み、結果を回収できた。

---

## 5. 乗り込んで、抜ける

```bash
ccs attach x01
```

**期待される動き**: Claude Code の画面に切り替わる。左下に `x01` と出ている。

**抜けるとき**: `Ctrl-b` を押してから `d`（detach）。**`Ctrl-c` や `exit` ではない。**

!!! warning "detach と kill は違う"
    `Ctrl-b d` で抜けてもセッションは生き続ける。**それが tmux を使っている理由。**
    畳みたいときだけ `ccs kill` を使う。

抜けたあと、生きていることを確かめる:

```bash
ccs ls
```

**期待される出力**:

```
SLUG  STATUS    SESSION ID                            PATH
x01   idle      0ecd87dd-cdb0-4835-add0-23e4c14b9b5f  ~/ghq/github.com/ken-ty/x01
```

---

## 6. 二度立てても増えないことを確かめる

```bash
ccs new x01
```

**期待される出力**: 手順 3 と**同じ `sessionId`** で、`created` が `false`。

```json
{"slug":"x01","sessionId":"0ecd87dd-…",…,"created":false,"running":true}
```

打ち方を変えても同じになることも見る:

```bash
ccs new ken-ty/x01
```

→ これも `created:false`、同じ `sessionId`。

**tmux セッションが 1 本のままであること**:

```bash
tmux ls
```

→ `cc/x01: 1 windows …` の 1 行だけ。

---

## 7. 止まったセッションの見え方

claude だけを終了させて、ペインが残っている状態を作る。

```bash
ccs attach x01
```

→ Claude Code の中で `/exit`（または `Ctrl-d`）。**ペインはシェルに戻る。**
→ `Ctrl-b d` で抜ける。

```bash
ccs ls
```

**期待される出力**:

```
SLUG  STATUS    SESSION ID                            PATH
x01   stopped   0ecd87dd-cdb0-4835-add0-23e4c14b9b5f  ~/ghq/github.com/ken-ty/x01
```

見るところ: **`stopped` になっても `SESSION ID` が出ている。**
v1 に `resume` は無いので、この UUID が同じ会話に戻る唯一の手掛かり。

この状態で `ccs new x01` を打つと、**成功扱いにせず**復帰コマンドを出す:

```
ccs: cc/x01 のペインは残っていますが、claude は動いていません。

  乗り込んで、同じ会話を再開する:
    ccs attach x01
    claude --resume 0ecd87dd-cdb0-4835-add0-23e4c14b9b5f
  畳んで立て直す:     ccs kill x01 && ccs new x01
```

---

## 8. 掃除する

まず**見せるだけ**:

```bash
ccs gc
```

**期待される出力**:

```
止まっているセッション（畳む対象）:
  x01                  claude --resume 0ecd87dd-cdb0-4835-add0-23e4c14b9b5f

実行するには: ccs gc --yes
```

見るところ: **何も消えていない。** `tmux ls` で確かめてよい。

内容を確認してから実行:

```bash
ccs gc --yes
```

**期待される出力**:

```
止まっているセッション（畳む対象）:
  x01                  claude --resume 0ecd87dd-…

畳みました: cc/x01
```

```bash
ccs ls
```

**期待される出力**:

```
立っているセッションはありません。

  立てる: ccs new <target>
```

---

## 9. 使い捨ての作業枠（信頼確認を体験する）

!!! info "ここだけ `~/.claude.json` に 1 行増える"
    信頼確認に答えると、Claude Code 自身がそれを記録する。**`ccs` が書くのではない。**
    手順 1 で控えた `.projects` の件数が 1 増えるのはここ。

```bash
ccs new tmp
```

**期待される出力**（`ccs` は先に警告してから立てる）:

```
ccs: /Users/apple/.cc-scratch/1 はまだ信頼されていません。
起動時に信頼確認が出ます。一度答えれば以後は出ません:
  ccs attach tmp-1   # 「1. Yes, I trust this folder」を選ぶ
```

その後 30 秒待って失敗する。これは**想定どおり**の動き。

```bash
ccs attach tmp-1
```

→ 信頼確認が出ているので **「1. Yes, I trust this folder」** を選ぶ。
→ Claude Code が起動したら `Ctrl-b d` で抜ける。

```bash
ccs ls
```

**期待される出力**: `tmp-1` が `idle` で出る。

**2 回目以降は確認が出ない**ことを確かめる:

```bash
ccs kill tmp-1
ccs new tmp
```

→ 今度は警告なしで、数秒で `created:true` が返る。

!!! question "この往復が面倒だと思ったら"
    そのとおりで、枠 8 本ぶん初回だけこれをやることになる。
    自動承認してよいかは [#6](https://github.com/ken-ty/ccs/issues/6) で判断待ち。
    意見をそこに書いてほしい。

---

## 10. 元に戻す

```bash
ccs kill tmp-1
ccs gc --yes
```

**期待される出力**: 空になった枠のディレクトリも `gc` が消す。

```
消しました: ~/.cc-scratch/1
```

親のディレクトリだけ残るので、それも消す:

```bash
rmdir ~/.cc-scratch
tmux ls; ls ~/.cc-scratch
```

**期待される出力**:

```
no server running on /private/tmp/tmux-501/default
ls: /Users/apple/.cc-scratch: No such file or directory
```

`ccs` 自体を外すなら:

```bash
rm ~/.local/bin/ccs
```

??? note "`~/.claude.json` について"
    手順 9 で増えた `hasTrustDialogAccepted` の 1 行は残る。これは Claude Code の
    通常の記録で、`~/.cc-scratch/1` を次に使うときに確認が出なくなるだけ。
    害は無いので消さなくてよい。

---

## 通ったかどうかの一覧

- [ ] 0. 依存が揃っている
- [ ] 2. `resolve` が副作用なしで答え、曖昧なときは勝手に選ばない
- [ ] 3. `ccs new` が数秒で JSON を返す
- [ ] **4. ハブの `ListAgents` に現れ、`SendMessage` で仕事を頼めた** ← ここが本命
- [ ] 5. `Ctrl-b d` で抜けてもセッションが生きている
- [ ] 6. 二度立てても増えない（`created:false`、同じ `sessionId`）
- [ ] 7. `stopped` でも `SESSION ID` が出る
- [ ] 8. `gc` が既定では何も消さない
- [ ] 9. 信頼確認に一度答えれば、以後出ない
- [ ] 10. 元に戻せた

**4 が通れば、この道具が解こうとしていた問題は解けている。**
他が引っかかっても、それは使い勝手の話。

---

## うまくいかないときの見どころ

| 症状 | 見るところ |
| --- | --- |
| `ccs new` が 30 秒待って失敗する | ペインの中身が出るのでそれを読む。信頼確認かログイン切れが大半 |
| `ListAgents` に出てこない | `ccs ls` で `idle` か確かめる。`stopped` なら claude が落ちている |
| `attach` から抜けられない | `Ctrl-b` → `d`。`Ctrl-c` ではない |
| `ccs new tmp` が「枠が全部埋まっています」 | `ccs gc` で状況を見る。中身のある枠は `ccs` が消さないので自分で確認する |
| `ccs kill` が「作業中です」で止まる | 意図した動き。`ccs attach` で様子を見てから `--force` |
| 終了コードの意味 | 0 成功 / 1 失敗 / 2 使い方の誤り / 4 依存が無い |

それでも分からなければ、**このチャットにそのまま貼ってほしい。**
`ccs` が出すメッセージは、次の手が分かるように書いてある。
書いていなかったとしたら、それはこちらの直すべき点。
