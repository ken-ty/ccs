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
_new_tmp() {
	run --separate-stderr "$CCS_BIN" new --tmp
	[ "$status" -eq 0 ]
	printf '%s' "$output" | jq -r '.sessionId'
}

# 会話ログの置き場所（ccs と同じ規則で前向きに組み立てる）。
_transcript_dir() {
	printf '%s/%s' "$CCS_PROJECTS_DIR" \
		"$(printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g')"
}

# 作業枠の絶対パス（/tmp → /private/tmp の正規化を通す）。
_slot_path() {
	printf '%s/%s' "$(cd "$CCS_SCRATCH_ROOT" && pwd -P)" "$1"
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
	[[ "$output" != *"tmp-1"* ]] || return 1
}

# --- 消えた作業枠を戻す ----------------------------------------------------

@test "restore: tmux ごと消えた作業枠を、同じ会話で立て直す" {
	local id
	id=$(_new_tmp)
	_wipe_session tmp-1

	run "$CCS_BIN" restore --yes
	[ "$status" -eq 0 ]
	[[ "$output" == *"戻しました"* ]] || return 1

	ccs_tmux has-session -t '=cc/tmp-1'

	# **同じ sessionId で戻っていること。** ここが本体。
	run --separate-stderr "$CCS_BIN" ls --json
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq -r '.[0].sessionId')" = "$id" ]
	[ "$(printf '%s' "$output" | jq -r '.[0].slug')" = 'tmp-1' ]
}

@test "restore: 既定では立てない（dry-run）" {
	# 戻すと claude が動き出す。確認なしで N 本動き出す設計は割に合わない
	# （ccs gc と同じ作法）。
	_new_tmp >/dev/null
	_wipe_session tmp-1

	run "$CCS_BIN" restore
	[ "$status" -eq 0 ]
	[[ "$output" == *"tmp-1"* ]] || return 1
	[[ "$output" == *"ccs restore --yes"* ]] || return 1

	run ccs_tmux has-session -t '=cc/tmp-1'
	[ "$status" -ne 0 ]
}

@test "restore: 枠のディレクトリが gc で消えていても戻せる" {
	# 枠は ccs が作る空のディレクトリなので、消えていても失うものが無い。
	# 会話ログのほうは残っているので、そこに戻す。
	local id
	id=$(_new_tmp)
	_wipe_session tmp-1
	rmdir "$(_slot_path 1)"

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
	_wipe_session tmp-1

	local log="${CCS_TEST_TMP}/claude-args.txt"
	FAKE_CLAUDE_LOG="$log" run "$CCS_BIN" restore --yes
	[ "$status" -eq 0 ]

	# tmux サーバは既に起動しているので、FAKE_CLAUDE_LOG はペイン側には
	# 届かない。ccs が組み立てたコマンド文字列を tmux から直接見る。
	run ccs_tmux list-panes -t '=cc/tmp-1' -F '#{pane_start_command}'
	[[ "$output" == *"--resume"* ]] || return 1
	[[ "$output" != *" -n "* ]] || return 1
}

# --- 止まったペイン --------------------------------------------------------

@test "restore: ペインが残っているだけのセッションも立て直す" {
	local id
	id=$(_new_tmp)
	ccs_kill_claude_of tmp-1

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
	_wipe_session tmp-1
	"$CCS_BIN" restore --yes >/dev/null
	ccs_kill_claude_of tmp-1

	run --separate-stderr "$CCS_BIN" ls --json
	[ "$(printf '%s' "$output" | jq -r '.[0].status')" = 'stopped' ]
	[ "$(printf '%s' "$output" | jq -r '.[0].sessionId')" = "$id" ]
}

# --- 名指し ----------------------------------------------------------------

@test "restore: slug を名指しできる" {
	local id
	id=$(_new_tmp)
	_wipe_session tmp-1

	run "$CCS_BIN" restore tmp-1 --yes
	[ "$status" -eq 0 ]
	[[ "$output" == *"$id"* ]] || return 1
}

@test "restore: --list はその場所の会話を並べる" {
	local id
	id=$(_new_tmp)
	_wipe_session tmp-1

	# 同じ枠に古い会話を 1 つ置く。
	printf '{"type":"user","cwd":"%s","sessionId":"old"}\n' "$(_slot_path 1)" \
		>"$(_transcript_dir "$(_slot_path 1)")/00000000-0000-4000-8000-000000000000.jsonl"

	run "$CCS_BIN" restore tmp-1 --list
	[ "$status" -eq 0 ]
	[[ "$output" == *"$id"* ]] || return 1
	[[ "$output" == *"00000000-0000-4000-8000-000000000000"* ]] || return 1
}

@test "restore: --session-id で古い会話を選べる" {
	_new_tmp >/dev/null
	_wipe_session tmp-1

	local old='00000000-0000-4000-8000-000000000000'
	printf '{"type":"user","cwd":"%s","sessionId":"%s"}\n' "$(_slot_path 1)" "$old" \
		>"$(_transcript_dir "$(_slot_path 1)")/${old}.jsonl"

	run "$CCS_BIN" restore tmp-1 --session-id "$old" --yes
	[ "$status" -eq 0 ]

	run --separate-stderr "$CCS_BIN" ls --json
	[ "$(printf '%s' "$output" | jq -r '.[0].sessionId')" = "$old" ]
}

@test "restore: 生きている slug を名指ししても触らない" {
	local id
	id=$(_new_tmp)

	run "$CCS_BIN" restore tmp-1 --yes
	[ "$status" -eq 0 ]
	[[ "$output" == *"生きている"* ]] || return 1

	run --separate-stderr "$CCS_BIN" ls --json
	[ "$(printf '%s' "$output" | jq -r '.[0].sessionId')" = "$id" ]
}

# --- 戻せないものを黙って戻さない ------------------------------------------

@test "restore: 会話ログが無ければ理由を出して戻さない" {
	_new_tmp >/dev/null
	_wipe_session tmp-1
	rm -f "$(_transcript_dir "$(_slot_path 1)")"/*.jsonl

	run "$CCS_BIN" restore
	[ "$status" -eq 0 ]
	[[ "$output" != *"ccs restore --yes"* ]] || return 1
}

@test "restore: 会話ログの cwd が食い違えば飛ばす" {
	# エンコード規則の答え合わせ。規則が変わったとき、黙って別の会話を
	# 戻すのではなく、その 1 本を飛ばす。
	_new_tmp >/dev/null
	_wipe_session tmp-1

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
	_wipe_session tmp-1
	touch -t 202001010000 "$(_transcript_dir "$(_slot_path 1)")"/*.jsonl

	run "$CCS_BIN" restore
	[ "$status" -eq 0 ]
	[[ "$output" == *"ありません"* ]] || return 1
}

@test "restore: --all なら古い会話も拾う" {
	_new_tmp >/dev/null
	_wipe_session tmp-1
	touch -t 202001010000 "$(_transcript_dir "$(_slot_path 1)")"/*.jsonl

	run "$CCS_BIN" restore --all
	[ "$status" -eq 0 ]
	[[ "$output" == *"tmp-1"* ]] || return 1
}

@test "restore: 名指しなら古くても戻す" {
	_new_tmp >/dev/null
	_wipe_session tmp-1
	touch -t 202001010000 "$(_transcript_dir "$(_slot_path 1)")"/*.jsonl

	run "$CCS_BIN" restore tmp-1
	[ "$status" -eq 0 ]
	[[ "$output" == *"tmp-1"* ]] || return 1
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

	_wipe_session 'x01@topic'

	run "$CCS_BIN" restore --yes
	[ "$status" -eq 0 ]
	[[ "$output" == *'x01@topic'* ]] || return 1

	run --separate-stderr "$CCS_BIN" ls --json
	[ "$(printf '%s' "$output" | jq -r '.[0].slug')" = 'x01@topic' ]
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
	_wipe_session tmp-1

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
		_wipe_session "tmp-${i}"
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
	[[ "$output" == *"tmp-1"* ]] || return 1
	[[ "$output" == *"tmp-2"* ]] || return 1
	[[ "$output" != *"tmp-3"* ]] || return 1

	# 素の restore は 3 本とも出す（絞っているのは --last だけ）。
	run "$CCS_BIN" restore
	[ "$status" -eq 0 ]
	[[ "$output" == *"tmp-3"* ]] || return 1
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
	[[ "$output" == *"tmp-1"* ]] || return 1
	[[ "$output" != *"tmp-2"* ]] || return 1
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
	[[ "$output" != *"tmp-2"* ]] || return 1

	CCS_RESTORE_LAST_WINDOW=1200 run "$CCS_BIN" restore --last
	[ "$status" -eq 0 ]
	[[ "$output" == *"tmp-2"* ]] || return 1
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
	[[ "$output" != *"tmp-1"* ]] || return 1

	run "$CCS_BIN" restore --last
	[ "$status" -eq 0 ]
	[[ "$output" == *"tmp-1"* ]] || return 1
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

	ccs_tmux has-session -t '=cc/tmp-1'
	run ccs_tmux has-session -t '=cc/tmp-2'
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

	run ccs_tmux has-session -t '=cc/tmp-1'
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
	[[ "$output" == *"tmp-1"* ]] || return 1
	[[ "$output" != *"tmp-2"* ]] || return 1

	run "$CCS_BIN" restore --since 6h
	[ "$status" -eq 0 ]
	[[ "$output" == *"tmp-2"* ]] || return 1
	[[ "$output" != *"tmp-3"* ]] || return 1
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
