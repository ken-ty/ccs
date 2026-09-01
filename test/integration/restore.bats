#!/usr/bin/env bats
#
# ccs restore
#
# **戻すのは会話であって、ディレクトリではない。** 立て直したセッションが
# 元と同じ sessionId になっていることを毎回確かめる ── ここがずれると、
# 「戻った」ように見えて別の（あるいは新しい）会話が立っているだけになる。
#
# 実機の出発点は PC の再起動で、そのとき消えるのは tmux セッションごと。
# 「ペインは残っているが claude が死んでいる」場合と両方を押さえる。

bats_require_minimum_version 1.5.0

load '../test_helper'

setup() {
	ccs_setup_sandbox
	ccs_use_fake_claude
	ccs_use_own_tmux_server
	ccs_stub_ghq ''
	export CCS_NEW_TIMEOUT=15
	# 会話ログが無ければ戻すものが無い。**tmux サーバの環境は起動時に
	# 固定される**ので、最初の ccs 実行より前に export する。
	export FAKE_CLAUDE_TRANSCRIPT=1
}

teardown() {
	ccs_kill_own_tmux_server
	ccs_teardown_sandbox
}

# 作業枠に 1 本立てて、その sessionId を返す。
# 作業枠に 1 本立てて、その sessionId を返す。
#
# **slug は返り値では運べない**（この関数はコマンド置換ごしに呼ぶので、
# 変数への代入はサブシェルに閉じる）。発行順にファイルへ積んで `_ts` で引く
# ── 枠の id が一意になった（I2b）ので、`$(_ts 1)` と決め打てなくなった。
_new_tmp() {
	run --separate-stderr "$CCS_BIN" new --tmp
	[ "$status" -eq 0 ]
	printf '%s' "$output" | jq -r '.slug' >>"${CCS_TEST_TMP}/tmp-slugs"
	printf '%s' "$output" | jq -r '.sessionId'
}

# 発行した順に <n> 本目の slug（1 始まり）。
_ts() {
	sed -n "${1:-1}p" "${CCS_TEST_TMP}/tmp-slugs"
}

# 会話ログの置き場所（ccs と同じ規則で前向きに組み立てる）。
_transcript_dir() {
	printf '%s/%s' "$CCS_PROJECTS_DIR" \
		"$(printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g')"
}

# 作業枠の絶対パス（/tmp → /private/tmp の正規化を通す）。
_slot_path() {
	printf '%s/%s' "$(cd "$CCS_SCRATCH_ROOT" && pwd -P)" \
		"$(_ts "${1:-1}" | sed 's/^tmp-//')"
}

# 再起動を模す。tmux セッションごと消す。
#
# **レジストリから消えるまで待つ。** tmux セッションが消えても、ペインの
# プロセスが片付いてレジストリのファイルを消すまでには間がある。待たないと
# 「残骸 + 立て直したもの」の 2 件が並んだ状態で次の検証に入り、どちらを
# 掴むかがマシン任せになる。
_wipe_session() {
	ccs_tmux kill-session -t "=cc/$1"
	ccs_wait_until 5 bash -c "! '${CCS_REAL_TMUX:-tmux}' -S '$CCS_TMUX_SOCKET' has-session -t '=cc/$1' 2>/dev/null"
	ccs_wait_until 5 bash -c "! grep -lq '\"tmux\":\"cc/$1:' '$CCS_SESSIONS_DIR'/*.json 2>/dev/null"
}

# --- 何も無いとき ----------------------------------------------------------

@test "restore: 戻すものが無ければその旨を出す" {
	run "$CCS_BIN" restore
	[ "$status" -eq 0 ]
	[[ "$output" == *"ありません"* ]] || return 1
}

@test "restore: 生きているセッションは候補に出ない" {
	_new_tmp >/dev/null

	run "$CCS_BIN" restore
	[ "$status" -eq 0 ]
	[[ "$output" != *"$(_ts 1)"* ]] || return 1
}

# --- 消えた作業枠を戻す ----------------------------------------------------

@test "restore: tmux ごと消えた作業枠を、同じ会話で立て直す" {
	local id
	id=$(_new_tmp)
	_wipe_session $(_ts 1)

	run "$CCS_BIN" restore --yes
	[ "$status" -eq 0 ]
	[[ "$output" == *"戻しました"* ]] || return 1

	ccs_tmux has-session -t "=cc/$(_ts 1)"

	# **同じ sessionId で戻っていること。** ここが本体。
	run --separate-stderr "$CCS_BIN" ls --json
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq -r '.[0].sessionId')" = "$id" ]
	[ "$(printf '%s' "$output" | jq -r '.[0].slug')" = "$(_ts 1)" ]
}

@test "restore: 既定では立てない（dry-run）" {
	# 戻すと claude が動き出す。確認なしで N 本動き出す設計は割に合わない
	# （ccs gc と同じ作法）。
	_new_tmp >/dev/null
	_wipe_session $(_ts 1)

	run "$CCS_BIN" restore
	[ "$status" -eq 0 ]
	[[ "$output" == *"$(_ts 1)"* ]] || return 1
	[[ "$output" == *"ccs restore --yes"* ]] || return 1

	run ccs_tmux has-session -t "=cc/$(_ts 1)"
	[ "$status" -ne 0 ]
}

@test "restore: 枠のディレクトリが gc で消えていても戻せる" {
	# 枠は ccs が作る空のディレクトリなので、消えていても失うものが無い。
	# 会話ログのほうは残っているので、そこに戻す。
	local id
	id=$(_new_tmp)
	_wipe_session "$(_ts 1)"
	# **印ごと消す**（I2b）。`ccs gc` は印を先に消してから rmdir するので、
	# 「gc で消えた」を再現するならこちらも中身ごと。
	rm -rf "$(_slot_path 1)"

	run "$CCS_BIN" restore --yes
	[ "$status" -eq 0 ]
	[ -d "$(_slot_path 1)" ]

	run --separate-stderr "$CCS_BIN" ls --json
	[ "$(printf '%s' "$output" | jq -r '.[0].sessionId')" = "$id" ]
}

@test "restore: 会話の名前を上書きしない（-n を渡さない）" {
	# 戻す会話には既に名前が付いていて、アプリの一覧に出ているのはその名前。
	# ここで slug を被せると、探している名前のほうが消える。
	_new_tmp >/dev/null
	_wipe_session $(_ts 1)

	local log="${CCS_TEST_TMP}/claude-args.txt"
	FAKE_CLAUDE_LOG="$log" run "$CCS_BIN" restore --yes
	[ "$status" -eq 0 ]

	# tmux サーバは既に起動しているので、FAKE_CLAUDE_LOG はペイン側には
	# 届かない。ccs が組み立てたコマンド文字列を tmux から直接見る。
	run ccs_tmux list-panes -t "=cc/$(_ts 1)" -F '#{pane_start_command}'
	[[ "$output" == *"--resume"* ]] || return 1
	[[ "$output" != *" -n "* ]] || return 1
}

# --- 止まったペイン --------------------------------------------------------

@test "restore: ペインが残っているだけのセッションも立て直す" {
	local id
	id=$(_new_tmp)
	ccs_kill_claude_of $(_ts 1)

	run --separate-stderr "$CCS_BIN" ls --json
	[ "$(printf '%s' "$output" | jq -r '.[0].status')" = 'stopped' ]

	run "$CCS_BIN" restore --yes
	[ "$status" -eq 0 ]

	run --separate-stderr "$CCS_BIN" ls --json
	[ "$(printf '%s' "$output" | jq -r '.[0].status')" != 'stopped' ]
	[ "$(printf '%s' "$output" | jq -r '.[0].sessionId')" = "$id" ]
}

@test "restore: 戻したセッションが止まっても uuid を引ける" {
	# --resume で立てたペインは --session-id を持たない。両方を読めないと、
	# 二度目の復帰路が消える（ccs ls の stopped 行が - になる）。
	local id
	id=$(_new_tmp)
	_wipe_session $(_ts 1)
	"$CCS_BIN" restore --yes >/dev/null
	ccs_kill_claude_of $(_ts 1)

	run --separate-stderr "$CCS_BIN" ls --json
	[ "$(printf '%s' "$output" | jq -r '.[0].status')" = 'stopped' ]
	[ "$(printf '%s' "$output" | jq -r '.[0].sessionId')" = "$id" ]
}

# --- 名指し ----------------------------------------------------------------

@test "restore: slug を名指しできる" {
	local id
	id=$(_new_tmp)
	_wipe_session $(_ts 1)

	run "$CCS_BIN" restore $(_ts 1) --yes
	[ "$status" -eq 0 ]
	[[ "$output" == *"$id"* ]] || return 1
}

@test "restore: --list はその場所の会話を並べる" {
	local id
	id=$(_new_tmp)
	_wipe_session $(_ts 1)

	# 同じ枠に古い会話を 1 つ置く。
	printf '{"type":"user","cwd":"%s","sessionId":"old"}\n' "$(_slot_path 1)" \
		>"$(_transcript_dir "$(_slot_path 1)")/00000000-0000-4000-8000-000000000000.jsonl"

	run "$CCS_BIN" restore $(_ts 1) --list
	[ "$status" -eq 0 ]
	[[ "$output" == *"$id"* ]] || return 1
	[[ "$output" == *"00000000-0000-4000-8000-000000000000"* ]] || return 1
}

@test "restore: --session-id で古い会話を選べる" {
	_new_tmp >/dev/null
	_wipe_session $(_ts 1)

	local old='00000000-0000-4000-8000-000000000000'
	printf '{"type":"user","cwd":"%s","sessionId":"%s"}\n' "$(_slot_path 1)" "$old" \
		>"$(_transcript_dir "$(_slot_path 1)")/${old}.jsonl"

	run "$CCS_BIN" restore $(_ts 1) --session-id "$old" --yes
	[ "$status" -eq 0 ]

	run --separate-stderr "$CCS_BIN" ls --json
	[ "$(printf '%s' "$output" | jq -r '.[0].sessionId')" = "$old" ]
}

@test "restore: 生きている slug を名指ししても触らない" {
	local id
	id=$(_new_tmp)

	run "$CCS_BIN" restore $(_ts 1) --yes
	[ "$status" -eq 0 ]
	[[ "$output" == *"生きている"* ]] || return 1

	run --separate-stderr "$CCS_BIN" ls --json
	[ "$(printf '%s' "$output" | jq -r '.[0].sessionId')" = "$id" ]
}

# --- 戻せないものを黙って戻さない ------------------------------------------

@test "restore: 会話ログが無ければ理由を出して戻さない" {
	_new_tmp >/dev/null
	_wipe_session $(_ts 1)
	rm -f "$(_transcript_dir "$(_slot_path 1)")"/*.jsonl

	run "$CCS_BIN" restore
	[ "$status" -eq 0 ]
	[[ "$output" != *"ccs restore --yes"* ]] || return 1
}

@test "restore: 会話ログの cwd が食い違えば飛ばす" {
	# エンコード規則の答え合わせ。規則が変わったとき、黙って別の会話を
	# 戻すのではなく、その 1 本を飛ばす。
	_new_tmp >/dev/null
	_wipe_session $(_ts 1)

	local f
	f=$(ls "$(_transcript_dir "$(_slot_path 1)")"/*.jsonl | head -1)
	printf '{"type":"user","cwd":"/somewhere/else","sessionId":"x"}\n' >"$f"

	run "$CCS_BIN" restore
	[ "$status" -eq 0 ]
	[[ "$output" == *"cwd が違います"* ]] || return 1
	[[ "$output" != *"ccs restore --yes"* ]] || return 1
}

# --- 古さ ------------------------------------------------------------------

@test "restore: 古い会話は既定では拾わない" {
	_new_tmp >/dev/null
	_wipe_session $(_ts 1)
	touch -t 202001010000 "$(_transcript_dir "$(_slot_path 1)")"/*.jsonl

	run "$CCS_BIN" restore
	[ "$status" -eq 0 ]
	[[ "$output" == *"ありません"* ]] || return 1
}

@test "restore: --all なら古い会話も拾う" {
	_new_tmp >/dev/null
	_wipe_session $(_ts 1)
	touch -t 202001010000 "$(_transcript_dir "$(_slot_path 1)")"/*.jsonl

	run "$CCS_BIN" restore --all
	[ "$status" -eq 0 ]
	[[ "$output" == *"$(_ts 1)"* ]] || return 1
}

@test "restore: 名指しなら古くても戻す" {
	_new_tmp >/dev/null
	_wipe_session $(_ts 1)
	touch -t 202001010000 "$(_transcript_dir "$(_slot_path 1)")"/*.jsonl

	run "$CCS_BIN" restore $(_ts 1)
	[ "$status" -eq 0 ]
	[[ "$output" == *"$(_ts 1)"* ]] || return 1
}

# --- hub ------------------------------------------------------------------

@test "restore: hub は候補に入れない" {
	# hub は ccs hub up（自動起動）が立て直す担当。
	export CCS_HUB_HOME="${CCS_TEST_TMP}/hub"
	"$CCS_BIN" hub up --quiet
	ccs_kill_claude_of hub

	run "$CCS_BIN" restore
	[ "$status" -eq 0 ]
	[[ "$output" != *"hub"* ]] || return 1
}

# --- worktree --------------------------------------------------------------

@test "restore: 消えた worktree セッションも候補に入る" {
	# worktree は ccs が置き場所を決めているので、枠と同じく列挙してよい
	# （ghq 配下のリポジトリと違い、そこに立てたのは ccs だけ）。
	local repo="${CCS_TEST_TMP}/ghq/github.com/o/x01"
	ccs_make_git_repo "$repo"
	ccs_stub_ghq "$repo"

	local id
	run --separate-stderr "$CCS_BIN" new 'x01@topic'
	[ "$status" -eq 0 ]
	id=$(printf '%s' "$output" | jq -r '.sessionId')

	_wipe_session 'x01--topic'

	run "$CCS_BIN" restore --yes
	[ "$status" -eq 0 ]
	[[ "$output" == *'x01--topic'* ]] || return 1

	run --separate-stderr "$CCS_BIN" ls --json
	[ "$(printf '%s' "$output" | jq -r '.[0].slug')" = 'x01--topic' ]
	[ "$(printf '%s' "$output" | jq -r '.[0].sessionId')" = "$id" ]
}

@test "restore: ghq 配下でも、ccs が立てた印があれば列挙する" {
	# 印は「会話ログの 1 行目が custom-title」。ccs new は -n <slug> を渡すので
	# 本物はそこに名前を書く（実測）。
	local repo="${CCS_TEST_TMP}/ghq/github.com/o/x01"
	ccs_make_git_repo "$repo"
	ccs_stub_ghq "$repo"

	local id
	run --separate-stderr "$CCS_BIN" new x01
	[ "$status" -eq 0 ]
	id=$(printf '%s' "$output" | jq -r '.sessionId')

	_wipe_session x01

	run "$CCS_BIN" restore
	[ "$status" -eq 0 ]
	[[ "$output" == *"x01"* ]] || return 1

	run "$CCS_BIN" restore --yes
	[ "$status" -eq 0 ]

	run --separate-stderr "$CCS_BIN" ls --json
	[ "$(printf '%s' "$output" | jq -r '.[0].sessionId')" = "$id" ]
}

@test "restore: 印の無い会話ログは列挙しない（アプリから開いたもの）" {
	# デスクトップアプリや VS Code のセッションは名前が会話の内容から自動で
	# 決まるので、custom-title が先頭に来ない。**一括で戻すと ccs が管理して
	# いない会話まで tmux に生える**ので、ここは拾わない。
	local repo="${CCS_TEST_TMP}/ghq/github.com/o/x01"
	ccs_make_git_repo "$repo"
	ccs_stub_ghq "$repo"

	local abs dir
	abs=$(cd "$repo" && pwd -P)
	dir="$(_transcript_dir "$abs")"
	mkdir -p "$dir"
	printf '{"type":"user","cwd":"%s","sessionId":"x"}\n' "$abs" \
		>"${dir}/11111111-1111-4111-8111-111111111111.jsonl"

	run "$CCS_BIN" restore
	[ "$status" -eq 0 ]
	[[ "$output" != *"x01"* ]] || return 1

	# **名指しなら戻す。** 人が名前を打っているなら、それが意図。
	run "$CCS_BIN" restore x01
	[ "$status" -eq 0 ]
	[[ "$output" == *"x01"* ]] || return 1
}

# --- hub up からの案内 ------------------------------------------------------

@test "hub up: 立て直したときだけ、他に止まっているものがあると言う" {
	# 再起動の直後がまさにこれ。**言うだけで、立て直しはしない** ──
	# 自動起動から 5 分おきに走るので、ここで戻すと人が畳んだものが生き返る。
	export CCS_HUB_HOME="${CCS_TEST_TMP}/hub"
	_new_tmp >/dev/null
	_wipe_session $(_ts 1)

	run "$CCS_BIN" hub up
	[ "$status" -eq 0 ]
	[[ "$output" == *"ccs restore"* ]] || return 1
	# **--last を先に案内する。** ここへ来るのは再起動の直後で、候補には
	# 「一緒に落ちた組」と「それ以前からの残骸」が混ざる。hub が slug を
	# 目視で選ばずに済む導線がここに無いと、結局手打ちに戻る。
	[[ "$output" == *"ccs restore --last --yes"* ]] || return 1

	# 2 回目は hub が健全なので何も言わない（毎回吠えない）。
	run "$CCS_BIN" hub up
	[ "$status" -eq 0 ]
	[[ "$output" != *"ccs restore"* ]] || return 1
}

# --- 前回の停止まで生きていた組だけを戻す（--last / --since） --------------
#
# **会話ログの mtime は「最後に活動した時刻」ではなく「最後に生きていた時刻」。**
# OS のシャットダウンは生きている claude に SIGTERM を送り、claude はそこで
# 会話ログを書き切る（実測 2026-08-27。bin/ccs の `restore_epoch_of` の上の
# コメント）。だから **手で畳んだセッションだけが塊から外れる。**
#
# ここで見るのは切り出しだけなので、mtime は touch で作る ── 実際に
# シャットダウンを起こすテストは書けない。

# epoch を `touch -t` の綴りに直す。
#
# **`date -r` の意味が BSD と GNU で違う**（BSD は秒、GNU はファイル）ので、
# 当たったほうを使う。GNU では `date -r <数字>` がファイルとして stat に
# 失敗するので、素直に落ちて次へ回る。
_stamp() {
	date -r "$1" '+%Y%m%d%H%M.%S' 2>/dev/null || date -d "@$1" '+%Y%m%d%H%M.%S'
}

# 作業枠の会話ログの mtime を epoch で作る。
_touch_slot() {
	touch -t "$(_stamp "$2")" "$(_transcript_dir "$(_slot_path "$1")")"/*.jsonl
}

# 枠を n 本立てて、全部 tmux ごと消す（＝再起動を模す）。
_wipe_slots() {
	local i
	for ((i = 1; i <= $1; i++)); do
		_new_tmp >/dev/null
	done
	for ((i = 1; i <= $1; i++)); do
		_wipe_session "$(_ts "$i")"
	done
}

@test "restore --last: 一緒に落ちた組だけを拾い、その前に畳んだものは拾わない" {
	_wipe_slots 3

	local stop=$(($(date +%s) - 3600))
	# **停止は一瞬ではない。** シャットダウンは順に SIGTERM を送るので、
	# 一緒に落ちた組でも数十秒ばらける（実測で 13 本 45 秒）。
	_touch_slot 1 "$stop"
	_touch_slot 2 "$((stop - 20))"
	# 1 時間前に手で畳んだ 1 本。書き込みはそこで止まっている。
	_touch_slot 3 "$((stop - 3600))"

	export CCS_RESTORE_BOOT_EPOCH=$((stop + 60))

	run "$CCS_BIN" restore --last
	[ "$status" -eq 0 ]
	[[ "$output" == *"$(_ts 1)"* ]] || return 1
	[[ "$output" == *"$(_ts 2)"* ]] || return 1
	[[ "$output" != *"$(_ts 3)"* ]] || return 1

	# 素の restore は 3 本とも出す（絞っているのは --last だけ）。
	run "$CCS_BIN" restore
	[ "$status" -eq 0 ]
	[[ "$output" == *"$(_ts 3)"* ]] || return 1
}

@test "restore --last: 起動より後に書かれたものは「前回」ではない" {
	# 一度戻したあとに死んだセッションを、前回の組に混ぜない。
	_wipe_slots 2

	local stop=$(($(date +%s) - 3600))
	_touch_slot 1 "$stop"
	export CCS_RESTORE_BOOT_EPOCH=$((stop + 60))
	# 起動より後（＝今回の分）。
	_touch_slot 2 "$((stop + 600))"

	run "$CCS_BIN" restore --last
	[ "$status" -eq 0 ]
	[[ "$output" == *"$(_ts 1)"* ]] || return 1
	[[ "$output" != *"$(_ts 2)"* ]] || return 1
}

@test "restore --last: 塊が無ければその旨を出す" {
	_wipe_slots 1

	local stop=$(($(date +%s) - 3600))
	# 候補が全部「起動より後」なら、前回の組は 1 本も無い。
	_touch_slot 1 "$stop"
	export CCS_RESTORE_BOOT_EPOCH=$((stop - 60))

	run "$CCS_BIN" restore --last
	[ "$status" -eq 0 ]
	[[ "$output" == *"ありません"* ]] || return 1
}

@test "restore --last: 窓の幅は CCS_RESTORE_LAST_WINDOW で変えられる" {
	_wipe_slots 2

	local stop=$(($(date +%s) - 3600))
	_touch_slot 1 "$stop"
	_touch_slot 2 "$((stop - 600))" # 10 分前
	export CCS_RESTORE_BOOT_EPOCH=$((stop + 60))

	# 既定は 5 分なので届かない。
	run "$CCS_BIN" restore --last
	[ "$status" -eq 0 ]
	[[ "$output" != *"$(_ts 2)"* ]] || return 1

	CCS_RESTORE_LAST_WINDOW=1200 run "$CCS_BIN" restore --last
	[ "$status" -eq 0 ]
	[[ "$output" == *"$(_ts 2)"* ]] || return 1
}

@test "restore --last: 7 日の線を越えていても拾う" {
	# **マシンが長く落ちていたら、戻したい組ごと古さの線に落ちる。**
	# 絞るのは窓のほうなので、--last は列挙の線を外す。
	_wipe_slots 1

	local stop=$(($(date +%s) - 30 * 86400))
	_touch_slot 1 "$stop"
	export CCS_RESTORE_BOOT_EPOCH=$((stop + 60))

	run "$CCS_BIN" restore
	[ "$status" -eq 0 ]
	[[ "$output" != *"$(_ts 1)"* ]] || return 1

	run "$CCS_BIN" restore --last
	[ "$status" -eq 0 ]
	[[ "$output" == *"$(_ts 1)"* ]] || return 1
}

@test "restore --last --yes: 組だけを立て直す" {
	_wipe_slots 2

	local stop=$(($(date +%s) - 3600))
	_touch_slot 1 "$stop"
	_touch_slot 2 "$((stop - 3600))"
	export CCS_RESTORE_BOOT_EPOCH=$((stop + 60))

	run "$CCS_BIN" restore --last --yes
	[ "$status" -eq 0 ]
	[[ "$output" == *"戻しました"* ]] || return 1

	ccs_tmux has-session -t "=cc/$(_ts 1)"
	run ccs_tmux has-session -t "=cc/$(_ts 2)"
	[ "$status" -ne 0 ]
}

@test "restore --last: 既定は dry-run で、繰り返せる形の案内を出す" {
	# **ここで `ccs restore --yes` と案内してはいけない。** 絞ったつもりの
	# 人が残骸まで立ち上げることになる。
	_wipe_slots 2

	local stop=$(($(date +%s) - 3600))
	_touch_slot 1 "$stop"
	_touch_slot 2 "$((stop - 3600))"
	export CCS_RESTORE_BOOT_EPOCH=$((stop + 60))

	run "$CCS_BIN" restore --last
	[ "$status" -eq 0 ]
	[[ "$output" == *"ccs restore --last --yes"* ]] || return 1

	run ccs_tmux has-session -t "=cc/$(_ts 1)"
	[ "$status" -ne 0 ]
}

@test "restore --since: 指定した期間だけ遡る" {
	# 一斉書き込みが起きない止まり方（電源断）だと --last の塊ができない。
	# そのときに人が幅を打てる口。
	_wipe_slots 3

	local now
	now=$(date +%s)
	_touch_slot 1 "$((now - 3600))"      # 1 時間前
	_touch_slot 2 "$((now - 3 * 3600))"  # 3 時間前
	_touch_slot 3 "$((now - 30 * 3600))" # 30 時間前

	run "$CCS_BIN" restore --since 2h
	[ "$status" -eq 0 ]
	[[ "$output" == *"$(_ts 1)"* ]] || return 1
	[[ "$output" != *"$(_ts 2)"* ]] || return 1

	run "$CCS_BIN" restore --since 6h
	[ "$status" -eq 0 ]
	[[ "$output" == *"$(_ts 2)"* ]] || return 1
	[[ "$output" != *"$(_ts 3)"* ]] || return 1
	[[ "$output" == *"ccs restore --since 6h --yes"* ]] || return 1
}

@test "restore --last: 起動時刻は設定なしでも OS から取れる" {
	# **ここだけは本物の OS を見る。** macOS の `kern.boottime` と Linux の
	# `/proc/stat` は綴りが違うので、片方しか通らないと「CI では緑なのに
	# 手元で候補が全滅する」が起きる（実測で一度踏んだ ── `.*sec` が貪欲に
	# `usec` へ当たり、起動時刻の代わりにマイクロ秒が返っていた）。
	unset CCS_RESTORE_BOOT_EPOCH
	_wipe_slots 1

	run "$CCS_BIN" restore --last
	[ "$status" -eq 0 ]
	[[ "$output" != *"起動時刻が取れない"* ]] || return 1
}

# --- 機械可読な出力（R2） --------------------------------------------------
#
# **ハブのエージェントが結果を読めるようにする。** 人間向けの 3 つの見出し
# （立て直せる / 生きているので触りません / 戻せません）を読み分けさせない。
# `applied` で分岐すれば足りる 1 つのオブジェクトにする。

@test "restore --json: 予告は applied:false と 3 つの配列" {
	local _uuid
	_uuid=$(_new_tmp)
	_wipe_session $(_ts 1)

	run --separate-stderr "$CCS_BIN" restore --json
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq -r '.applied')" = 'false' ]
	[ "$(printf '%s' "$output" | jq -r '.ready[0].slug')" = "$(_ts 1)" ]
	[ "$(printf '%s' "$output" | jq -r '.ready[0].sessionId')" = "$_uuid" ]
	[ "$(printf '%s' "$output" | jq -r '.ready[0].tmux')" = "cc/$(_ts 1)" ]
	# **予告なので立てていない。**
	run ccs_tmux has-session -t "=cc/$(_ts 1)"
	[ "$status" -ne 0 ]
}

@test "restore --json --yes: applied:true と restored" {
	local _uuid
	_uuid=$(_new_tmp)
	_wipe_session $(_ts 1)

	run --separate-stderr "$CCS_BIN" restore --json --yes
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq -r '.applied')" = 'true' ]
	[ "$(printf '%s' "$output" | jq -r '.restored[0].slug')" = "$(_ts 1)" ]
	# **同じ会話で戻っている。**
	[ "$(printf '%s' "$output" | jq -r '.restored[0].sessionId')" = "$_uuid" ]
	[ "$(printf '%s' "$output" | jq '.failed | length')" -eq 0 ]
	ccs_tmux has-session -t "=cc/$(_ts 1)"
}

@test "restore --json: 戻すものが無くてもキーの形は変わらない" {
	# **空のときだけ別の形にしない。** 読む側が 2 通りの分岐を持つことになる。
	run --separate-stderr "$CCS_BIN" restore --json
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq -r '.applied')" = 'false' ]
	[ "$(printf '%s' "$output" | jq '.ready | length')" -eq 0 ]
	[ "$(printf '%s' "$output" | jq -c 'keys')" = '["alive","applied","ready","skipped"]' ]
}

@test "restore --json --yes: 戻すものが無くても 1 つ返す" {
	# **黙って終わらない。** 失敗したのか対象が無かったのかを区別できなくなる。
	run --separate-stderr "$CCS_BIN" restore --json --yes
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq -r '.applied')" = 'true' ]
	[ "$(printf '%s' "$output" | jq '.restored | length')" -eq 0 ]
}

@test "restore --json: 生きているものは alive に入る" {
	_new_tmp >/dev/null

	run --separate-stderr "$CCS_BIN" restore $(_ts 1) --json
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq -r '.alive[0].slug')" = "$(_ts 1)" ]
	[ "$(printf '%s' "$output" | jq '.ready | length')" -eq 0 ]
}

@test "restore --json: stdout は JSON だけ（人間向けの文を混ぜない）" {
	# **混ぜるとハブ側でパースできなくなる**（design.md の出力の約束）。
	local _uuid
	_uuid=$(_new_tmp)
	_wipe_session $(_ts 1)

	run --separate-stderr "$CCS_BIN" restore --json
	[ "$status" -eq 0 ]
	printf '%s' "$output" | jq -e . >/dev/null
	[[ "$output" != *"立て直せるセッション"* ]] || return 1
	[[ "$output" != *"実行するには"* ]] || return 1
}

@test "restore --list --json: 会話ログを並べる" {
	local _uuid
	_uuid=$(_new_tmp)
	_wipe_session $(_ts 1)

	run --separate-stderr "$CCS_BIN" restore $(_ts 1) --list --json
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq -r '.[0].slug')" = "$(_ts 1)" ]
	[ "$(printf '%s' "$output" | jq -r '.[0].conversations[0].sessionId')" = "$_uuid" ]
}

@test "restore: 改名された稼働中のセッションを立て直しに行かない" {
	# **I1 と同じ穴が restore にもあった。** 名前で「止まっている」と決めると、
	# --yes が生きているペインを畳んで立て直す（会話は残るが、走っていた作業は
	# 巻き添えになる）。
	local _uuid
	_uuid=$(_new_tmp)
	ccs_tmux rename-session -t "=cc/$(_ts 1)" 'cc/renamed'

	run --separate-stderr "$CCS_BIN" restore --json
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq '.ready | length')" -eq 0 ]

	# **畳まれていない。**
	ccs_tmux has-session -t '=cc/renamed'
	[ "$(ccs_registry_count)" -eq 1 ]
}

# --- 生死は場所で見る（2026-08-31） ----------------------------------------
#
# **名前で引くと、名前の付け方が変わった瞬間に「居ない」ことになる。**
# N1 で worktree の slug を `@` から `--` に変えたとき、**生きている worktree
# セッションが `ccs restore` の候補に並んだ**（実測）── レジストリの `tmux` 欄も
# tmux セッション名も古い綴りのままなので、名前を起点にした照合が 2 つとも
# 外れる。`--yes` を打てば同じ会話に 2 本目が立つところだった。

@test "restore: その場所で claude が生きていれば立て直しに行かない" {
	# **名前は一切合わせない。** レジストリの tmux 欄も、tmux セッション名も、
	# ccs が組み立てる slug と食い違う状態を作る ── これが N1 で起きたこと。
	local _dir="${CCS_SCRATCH_ROOT}/aaaa1111"
	local _u='11111111-2222-4333-8444-777777777777'
	mkdir -p "$_dir"
	# **印が要る**（I3b）── 印の無いディレクトリは、そもそも ccs の枠として
	# 数えない。ここで見たいのは「ccs の枠だが生きている」ほう。
	printf '{"schema":1,"workspaceId":"aaaa1111","kind":"scratch"}\n' \
		>"${_dir}/.ccs.json"
	local _abs
	_abs=$(cd "$_dir" && pwd -P)

	# 会話ログ（候補になる条件）。
	mkdir -p "$(_transcript_dir "$_abs")"
	printf '{"type":"user"}\n' >"$(_transcript_dir "$_abs")/${_u}.jsonl"

	# その場所で生きている claude（名前は無関係なものにしておく）。
	printf '{"pid":%d,"sessionId":"%s","cwd":"%s","tmux":"cc/まったく別の名前"}\n' \
		"$$" "$_u" "$_abs" >"${CCS_SESSIONS_DIR}/20001.json"

	run --separate-stderr "$CCS_BIN" restore --json
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq '[.ready[] | select(.path == "'"$_abs"'")] | length')" -eq 0 ]
	[ "$(printf '%s' "$output" | jq '[.alive[] | select(.path == "'"$_abs"'")] | length')" -eq 1 ]
}

@test "restore: 管轄外の claude が居る場所も立て直しに行かない" {
	# **そこで誰かが作業しているなら、ccs が立てたものかどうかに関係なく
	# 上から立て直してよい場所ではない**（gc_live_cwds と同じ判断）。
	local _dir="${CCS_SCRATCH_ROOT}/bbbb2222"
	local _u='11111111-2222-4333-8444-888888888888'
	mkdir -p "$_dir"
	local _abs
	_abs=$(cd "$_dir" && pwd -P)
	mkdir -p "$(_transcript_dir "$_abs")"
	printf '{"type":"user"}\n' >"$(_transcript_dir "$_abs")/${_u}.jsonl"

	# tmux 欄が無い = 管轄外（アプリや VS Code から開いたもの）。
	printf '{"pid":%d,"sessionId":"%s","cwd":"%s"}\n' \
		"$$" "$_u" "$_abs" >"${CCS_SESSIONS_DIR}/20002.json"

	run --separate-stderr "$CCS_BIN" restore --json
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq '[.ready[] | select(.path == "'"$_abs"'")] | length')" -eq 0 ]
}

# --- 痕跡の照合を厳しくする（I3b） -----------------------------------------
#
# **ghq 配下には印を置けない**（ADR-0002 決定 5 ── `.ccs.json` は `git status`
# に出て、コミットされ得て、clean 判定を壊す）。だから**印ベースには置き換え
# られず**、名前が付いていたことの痕跡を読むしかない。
#
# **「`custom-title` を含む」では足りない。** それだと `ccs` 以外が `-n` を
# 付けて起動したセッションも通る。`customTitle` の値が **`ccs` がそのパスに
# 対して計算する slug と一致するか**まで見る。

_seed_titled() { # <repo> <customTitle> <uuid>
	local _abs _dir
	_abs=$(cd "$1" && pwd -P)
	_dir="$(_transcript_dir "$_abs")"
	mkdir -p "$_dir"
	printf '{"type":"custom-title","customTitle":"%s","sessionId":"%s"}\n' "$2" "$3" \
		>"${_dir}/${3}.jsonl"
	printf '{"type":"user","cwd":"%s","sessionId":"%s"}\n' "$_abs" "$3" \
		>>"${_dir}/${3}.jsonl"
}

@test "restore: customTitle が slug と一致すれば列挙する" {
	local repo="${CCS_TEST_TMP}/ghq/github.com/o/x01"
	ccs_make_git_repo "$repo"
	ccs_stub_ghq "$repo"
	_seed_titled "$repo" 'x01' '11111111-1111-4111-8111-111111111111'

	run --separate-stderr "$CCS_BIN" restore --json
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq '[.ready[] | select(.slug == "x01")] | length')" -eq 1 ]
}

@test "restore: customTitle が slug と違えば列挙しない" {
	# **ここが厳しくしたところ。** 以前は「custom-title を含む」だけを見て
	# いたので、`ccs` 以外が付けた名前でも通っていた。
	local repo="${CCS_TEST_TMP}/ghq/github.com/o/x01"
	ccs_make_git_repo "$repo"
	ccs_stub_ghq "$repo"
	_seed_titled "$repo" '手で付けた名前' '11111111-1111-4111-8111-222222222222'

	run --separate-stderr "$CCS_BIN" restore --json
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq '.ready | length')" -eq 0 ]
}

@test "restore: 作業枠は、ディレクトリが在れば印まで見る" {
	# **scratch root の直下にあるだけでは ccs のものとは言えない。**
	# 人が手で作ったディレクトリで会話していれば、そこも候補に出てしまう。
	local _dir="${CCS_SCRATCH_ROOT}/handmade"
	local _u='11111111-1111-4111-8111-333333333333'
	mkdir -p "$_dir"
	local _abs
	_abs=$(cd "$_dir" && pwd -P)
	mkdir -p "$(_transcript_dir "$_abs")"
	printf '{"type":"user","cwd":"%s"}\n' "$_abs" \
		>"$(_transcript_dir "$_abs")/${_u}.jsonl"

	run --separate-stderr "$CCS_BIN" restore --json
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq '[.ready[] | select(.path == "'"$_abs"'")] | length')" -eq 0 ]
}

@test "restore: 作業枠が消えていれば印は問わない" {
	# **印はディレクトリと一緒に消える。** そこを疑うと ccs gc のあとに
	# 戻せなくなる（I2b でわざわざ拾えるようにしたところ）。
	local _u
	_u=$(_new_tmp)
	_wipe_session "$(_ts 1)"
	rm -rf "$(_slot_path 1)"

	run --separate-stderr "$CCS_BIN" restore --json
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq '[.ready[] | select(.sessionId == "'"$_u"'")] | length')" -eq 1 ]
}

# --- 候補を選んで戻す（R5） ------------------------------------------------
#
# **終了判定は context ベース ── 人が見ないと決まらない。** `--last` は
# 「一緒に落ちた組」を時刻の塊でしか切れないので、「会話は終わっていないが
# 1 日放置している」を取りこぼし、直前に畳んだものを巻き込む。判定を自動化
# するのをやめて、人に選ばせる。
#
# **bats はパイプ越しに走るので `[ -t 0 ]` が偽**になる。`attach` の番号選択と
# 同じく pty を用意して、本物の端末から選んだときの挙動を見る。

_pick_restore() {
	run "${CCS_REPO_ROOT}/test/fixtures/pty-run.py" "$1" -- \
		env -u TMUX "$CCS_BIN" restore --pick
}

@test "restore --pick: 選んだものだけ戻す" {
	# **並び順は発行順ではない**（候補は会話ログの置き場所から拾うので）。
	# どれが 1 番になるかに依存させず、「1 本だけ戻り、それが報告されたもの」
	# であることを見る。
	_wipe_slots 2

	_pick_restore 1
	[ "$status" -eq 0 ]
	[ "$(ccs_registry_count)" -eq 1 ]

	local _restored
	_restored=$(printf '%s\n' "$output" | sed -n 's/.*戻しました: cc\/\([^（]*\).*/\1/p' | tr -d ' ')
	[ -n "$_restored" ]
	ccs_tmux has-session -t "=cc/${_restored}"
}

@test "restore --pick: 番号を並べて複数戻す" {
	_wipe_slots 2

	_pick_restore '1 2'
	[ "$status" -eq 0 ]
	ccs_tmux has-session -t "=cc/$(_ts 1)"
	ccs_tmux has-session -t "=cc/$(_ts 2)"
}

@test "restore --pick: 範囲でも指定できる" {
	_wipe_slots 2

	_pick_restore '1-2'
	[ "$status" -eq 0 ]
	ccs_tmux has-session -t "=cc/$(_ts 1)"
	ccs_tmux has-session -t "=cc/$(_ts 2)"
}

@test "restore --pick: all なら全部戻す" {
	_wipe_slots 2

	_pick_restore all
	[ "$status" -eq 0 ]
	ccs_tmux has-session -t "=cc/$(_ts 1)"
	ccs_tmux has-session -t "=cc/$(_ts 2)"
}

@test "restore --pick: 重ねて打っても 2 度立てない" {
	# **同じ会話を 2 本の claude が握らない**（restore の冪等性）。
	_wipe_slots 2

	_pick_restore '1-2 1 2'
	[ "$status" -eq 0 ]
	[ "$(ccs_registry_count)" -eq 2 ]
}

@test "restore --pick: 何も選ばなければ何も戻さず 0 で終わる" {
	# **中止は失敗ではない**（attach の番号選択と同じ）。
	_wipe_slots 1

	_pick_restore ''
	[ "$status" -eq 0 ]
	[[ "$output" == *"中止しました"* ]] || return 1
	run ccs_tmux has-session -t "=cc/$(_ts 1)"
	[ "$status" -ne 0 ]
}

@test "restore --pick: 番号でないものを選んだら 2" {
	_wipe_slots 1

	_pick_restore nope
	[ "$status" -eq 2 ]
	[[ "$output" == *"番号で指定してください"* ]] || return 1
}

@test "restore --pick: 範囲の外を選んだら 2" {
	_wipe_slots 1

	_pick_restore 5
	[ "$status" -eq 2 ]
}

@test "restore --pick: 判断材料を並べる" {
	# **slug と最終更新だけでは選べない。** 会話のタイトルと直近の依頼まで出す。
	local uuid
	uuid=$(_new_tmp)
	jq -cn --arg t 'ROADMAP の I1 を片付けて' \
		'{type:"user",message:{role:"user",content:$t}}' \
		>>"$(_transcript_dir "$(_slot_path 1)")/${uuid}.jsonl"
	_wipe_session "$(_ts 1)"

	_pick_restore ''
	[[ "$output" == *"$(_ts 1)"* ]] || return 1
	[[ "$output" == *"ROADMAP の I1 を片付けて"* ]] || return 1
}

@test "restore --pick: 非対話では固まらず断る" {
	# **launchd やパイプ越しから呼ばれても止まらない。**
	_wipe_slots 1

	run --separate-stderr "$CCS_BIN" restore --pick
	[ "$status" -eq 2 ]
	[[ "$stderr" == *"対話端末でだけ"* ]] || return 1
}

@test "restore --pick: --yes / --json とは併用できない" {
	run --separate-stderr "$CCS_BIN" restore --pick --yes
	[ "$status" -eq 2 ]
	[[ "$stderr" == *"一緒に使えません"* ]] || return 1

	run --separate-stderr "$CCS_BIN" restore --pick --json
	[ "$status" -eq 2 ]
}

# --- 「これは死んだ」を覚える（R6） ----------------------------------------
#
# **一度「終わった」と判断した会話が、7 日間ずっと候補に並び続ける**のを止める。
# 判断は人からしか出てこない情報で、会話ログにもレジストリにも印にも無いので、
# `ccs` が持つしかない（#97 で A を選択）。

@test "restore --pick: 選ばなかったものは次から候補に出ない" {
	_wipe_slots 2

	_pick_restore 1
	[ "$status" -eq 0 ]

	# 選ばれなかった 1 本が記録される。
	[ "$(wc -l <"$CCS_DISMISSED_FILE" | tr -d ' ')" -eq 1 ]

	run --separate-stderr "$CCS_BIN" restore --json
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq '.ready | length')" -eq 0 ]
}

@test "restore --pick: 全部選べば何も記録しない" {
	_wipe_slots 2

	_pick_restore all
	[ "$status" -eq 0 ]
	[ ! -s "$CCS_DISMISSED_FILE" ] || [ "$(wc -l <"$CCS_DISMISSED_FILE" | tr -d ' ')" -eq 0 ]
}

@test "restore --pick: none なら全部が死んだ扱いになる" {
	_wipe_slots 2

	_pick_restore none
	[ "$status" -eq 0 ]
	[[ "$output" == *"次からは候補に出ません"* ]] || return 1
	[ "$(wc -l <"$CCS_DISMISSED_FILE" | tr -d ' ')" -eq 2 ]

	run --separate-stderr "$CCS_BIN" restore --json
	[ "$(printf '%s' "$output" | jq '.ready | length')" -eq 0 ]
}

@test "restore <slug>: 名指しなら記録があっても戻せる" {
	# **名指しは「これを戻す」という答えそのもの。** 記録より強い。
	_wipe_slots 1
	_pick_restore none
	[ "$(wc -l <"$CCS_DISMISSED_FILE" | tr -d ' ')" -eq 1 ]

	run --separate-stderr "$CCS_BIN" restore "$(_ts 1)" --yes
	[ "$status" -eq 0 ]
	ccs_tmux has-session -t "=cc/$(_ts 1)"
}

@test "restore: 戻したら記録は消える" {
	# **生き返ったものを「死んだ」と覚えたままにすると、次に死んだとき
	# 候補に出ない。**
	_wipe_slots 1
	_pick_restore none
	[ "$(wc -l <"$CCS_DISMISSED_FILE" | tr -d ' ')" -eq 1 ]

	"$CCS_BIN" restore "$(_ts 1)" --yes >/dev/null
	[ ! -s "$CCS_DISMISSED_FILE" ] || [ "$(wc -l <"$CCS_DISMISSED_FILE" | tr -d ' ')" -eq 0 ]
}

@test "restore: 会話ログが消えた記録は掃除される" {
	# **放っておくと増え続ける。** 書き込みのたびに落とす。
	mkdir -p "$(dirname "$CCS_DISMISSED_FILE")"
	printf '%s\t%s\n' '11111111-1111-4111-8111-999999999999' '/nowhere' \
		>"$CCS_DISMISSED_FILE"

	_wipe_slots 1
	_pick_restore none
	[ "$status" -eq 0 ]

	# 消えた会話の行は残らない。いま判断したぶんだけになる。
	[ "$(wc -l <"$CCS_DISMISSED_FILE" | tr -d ' ')" -eq 1 ]
	[[ "$(cat "$CCS_DISMISSED_FILE")" != *"999999999999"* ]] || return 1
}

@test "restore --pick: Enter は中止で、何も記録しない" {
	# **反射で Enter を打った人の判断を、記録として固定しない。**
	# 「全部いらない」は `none` と明示させる。
	_wipe_slots 2

	_pick_restore ''
	[ "$status" -eq 0 ]
	[ ! -f "$CCS_DISMISSED_FILE" ] || [ ! -s "$CCS_DISMISSED_FILE" ]

	run --separate-stderr "$CCS_BIN" restore --json
	[ "$(printf '%s' "$output" | jq '.ready | length')" -eq 2 ]
}
