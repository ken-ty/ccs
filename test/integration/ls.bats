#!/usr/bin/env bats
#
# ccs ls
#
# **sessionId を必ず出す。** v1 に resume が無いので、止まったセッションを
# 手で `claude --resume <uuid>` するのが唯一の復帰路であり、その uuid を
# 知る手段がこの一覧しかない。ここで落とすと詰む。

bats_require_minimum_version 1.5.0

load '../test_helper'

setup() {
	ccs_setup_sandbox
	ccs_use_fake_claude
	ccs_use_own_tmux_server
	ccs_stub_ghq ''
	export CCS_NEW_TIMEOUT=15
}

teardown() {
	ccs_kill_own_tmux_server
	ccs_teardown_sandbox
}

_new() {
	mkdir -p "${CCS_TEST_TMP}/work/$1"
	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/work/$1"
	[ "$status" -eq 0 ]
	echo "$output"
}

# --- 空のとき --------------------------------------------------------------

@test "ls: 何も無ければ、その旨と次の手を出す" {
	run "$CCS_BIN" ls
	[ "$status" -eq 0 ]
	[[ "$output" == *"ありません"* ]] || return 1
	[[ "$output" == *"ccs new"* ]] || return 1
}

@test "ls --json: 何も無ければ空配列" {
	run "$CCS_BIN" ls --json
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | jq -r 'length')" = '0' ]
}

# --- 立っているものを出す --------------------------------------------------

@test "ls: 立てたセッションが並ぶ" {
	_new myrepo >/dev/null

	run "$CCS_BIN" ls
	[ "$status" -eq 0 ]
	[[ "$output" == *"myrepo"* ]] || return 1
	[[ "$output" == *"SLUG"* ]] || return 1
}

@test "ls --json: slug / status / sessionId / path / tmux を持つ" {
	_out=$(_new myrepo)
	_id=$(echo "$_out" | jq -r '.sessionId')

	run "$CCS_BIN" ls --json
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | jq -r 'length')" = '1' ]
	[ "$(echo "$output" | jq -r '.[0].slug')" = 'myrepo' ]
	[ "$(echo "$output" | jq -r '.[0].sessionId')" = "$_id" ]
	[ "$(echo "$output" | jq -r '.[0].tmux')" = 'cc/myrepo' ]
	[ "$(echo "$output" | jq -r '.[0].path')" = "$(echo "$_out" | jq -r '.path')" ]
}

@test "ls: sessionId をそのまま出す（省略しない）" {
	# 手で claude --resume に貼れる必要がある。
	_out=$(_new myrepo)
	_id=$(echo "$_out" | jq -r '.sessionId')

	run "$CCS_BIN" ls
	[[ "$output" == *"$_id"* ]] || return 1
}

@test "ls: 複数あれば slug 順に並ぶ" {
	_new zebra >/dev/null
	_new alpha >/dev/null
	_new middle >/dev/null

	run "$CCS_BIN" ls --json
	[ "$(echo "$output" | jq -r '.[0].slug')" = 'alpha' ]
	[ "$(echo "$output" | jq -r '.[1].slug')" = 'middle' ]
	[ "$(echo "$output" | jq -r '.[2].slug')" = 'zebra' ]
}

@test "ls: status はレジストリの値を映す" {
	export FAKE_CLAUDE_STATUS=working
	_new myrepo >/dev/null

	run "$CCS_BIN" ls --json
	[ "$(echo "$output" | jq -r '.[0].status')" = 'working' ]
}

# --- 止まっているもの ------------------------------------------------------

@test "ls: claude が終了していれば stopped と出す" {
	export FAKE_CLAUDE_EXIT_AFTER=1
	_new myrepo >/dev/null
	ccs_wait_registry_count 0 10

	run "$CCS_BIN" ls --json
	[ "$(echo "$output" | jq -r '.[0].status')" = 'stopped' ]
}

@test "ls: stopped でも sessionId を出す" {
	# **これが無いと復帰できない。** v1 に resume が無いので、
	# 手で claude --resume するための uuid はここにしか無い。
	export FAKE_CLAUDE_EXIT_AFTER=1
	_out=$(_new myrepo)
	_id=$(echo "$_out" | jq -r '.sessionId')
	ccs_wait_registry_count 0 10

	run "$CCS_BIN" ls --json
	[ "$(echo "$output" | jq -r '.[0].sessionId')" = "$_id" ]
}

@test "ls: stopped でも path を出す" {
	export FAKE_CLAUDE_EXIT_AFTER=1
	_out=$(_new myrepo)
	_expected=$(echo "$_out" | jq -r '.path')
	ccs_wait_registry_count 0 10

	run "$CCS_BIN" ls --json
	[ "$(echo "$output" | jq -r '.[0].path')" = "$_expected" ]
}

@test "ls: 生きているものと止まっているものが混在しても正しい" {
	_alive=$(_new alive)
	_alive_id=$(echo "$_alive" | jq -r '.sessionId')

	_dead=$(_new dead)
	_dead_id=$(echo "$_dead" | jq -r '.sessionId')

	# FAKE_CLAUDE_EXIT_AFTER は使えない ── tmux サーバの環境は
	# サーバ起動時（= 1 本目の new）に固定されるので、あとから export しても
	# 2 本目には届かない。プロセスを直接落として同じ状態を作る。
	ccs_kill_claude_of dead

	run "$CCS_BIN" ls --json
	[ "$(echo "$output" | jq -r 'length')" = '2' ]
	[ "$(echo "$output" | jq -r '.[] | select(.slug=="alive") | .status')" != 'stopped' ]
	[ "$(echo "$output" | jq -r '.[] | select(.slug=="alive") | .sessionId')" = "$_alive_id" ]
	[ "$(echo "$output" | jq -r '.[] | select(.slug=="dead") | .status')" = 'stopped' ]
	[ "$(echo "$output" | jq -r '.[] | select(.slug=="dead") | .sessionId')" = "$_dead_id" ]
}

# --- 管轄の境界 ------------------------------------------------------------

@test "ls: cc/ が付かない tmux セッションは無視する" {
	# 手で開いた作業用セッションを巻き込まない。
	ccs_tmux new-session -d -s 'my-own-work' -c "$CCS_TEST_TMP" 'sleep 60'
	_new myrepo >/dev/null

	run "$CCS_BIN" ls --json
	[ "$(echo "$output" | jq -r 'length')" = '1' ]
	[ "$(echo "$output" | jq -r '.[0].slug')" = 'myrepo' ]
}

@test "ls: 別セッションの sessionId を取り違えない" {
	# レジストリの照合は cc/<slug>: まで含めた前方一致。
	_a=$(_new x01)
	_b=$(_new x011)

	run "$CCS_BIN" ls --json
	_got_a=$(echo "$output" | jq -r '.[] | select(.slug=="x01") | .sessionId')
	_got_b=$(echo "$output" | jq -r '.[] | select(.slug=="x011") | .sessionId')
	[ "$_got_a" = "$(echo "$_a" | jq -r '.sessionId')" ]
	[ "$_got_b" = "$(echo "$_b" | jq -r '.sessionId')" ]
	[ "$_got_a" != "$_got_b" ]
}

@test "ls: 死んだプロセスのレジストリを掴まない" {
	# claude は終了時に自分のファイルを消すが、シグナル死では残る。
	# 残骸を掴むと、**死んでいるセッションを idle と表示し、立て直した
	# あとも古い sessionId を出し続ける**（2026-08-23 に CI が捕まえた）。
	_a=$(_new x01)
	_live=$(echo "$_a" | jq -r '.sessionId')

	# 同じ tmux セッションを指す残骸を、死んだ pid で置く。
	# ファイル名を先頭に来るものにして、live より先に当たるようにする。
	cat >"${CCS_SESSIONS_DIR}/00000.json" <<JSON
{"pid":999999,"sessionId":"00000000-0000-4000-8000-000000000000","cwd":"/somewhere","tmux":"cc/x01:@0.%0","name":"stale","status":"idle"}
JSON

	run --separate-stderr "$CCS_BIN" ls --json
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | jq -r '.[] | select(.slug=="x01") | .sessionId')" = "$_live" ]
}

# --- 出力の作法 -------------------------------------------------------------

@test "ls --json: 妥当な JSON" {
	_new a >/dev/null
	_new b >/dev/null

	run "$CCS_BIN" ls --json
	echo "$output" | jq -e . >/dev/null
	[ "$(echo "$output" | jq -r 'length')" = '2' ]
}

@test "ls --json: パスに引用符が混じっても壊れない" {
	mkdir -p "${CCS_TEST_TMP}/work/say\"hi"
	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/work/say\"hi"
	[ "$status" -eq 0 ]

	run "$CCS_BIN" ls --json
	echo "$output" | jq -e . >/dev/null
}

@test "ls: 表は長い slug でも崩れない" {
	mkdir -p "${CCS_TEST_TMP}/work/a-very-long-repository-name-here"
	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/work/a-very-long-repository-name-here"
	[ "$status" -eq 0 ]
	_new b >/dev/null

	run "$CCS_BIN" ls
	[ "$status" -eq 0 ]
	# ヘッダと各行の SESSION ID 列が同じ桁から始まる
	_header_col=$(printf '%s\n' "$output" | sed -n '1p' | awk '{ print index($0, "SESSION ID") }')
	[ "$_header_col" -gt 0 ]
}

@test "ls: 知らないオプションは 2" {
	run "$CCS_BIN" ls --nope
	[ "$status" -eq 2 ]
}

# --- 盤面（ccs ls -l）------------------------------------------------------
#
# **既定の `ccs ls` を壊さないこと**が第一の要件（既存の使い方が壊れる）。
# 盤面の列はすべて `-l` の下にだけ足す。

# その slug の会話ログのパス。無ければ置き場所ごと作る。
_transcript_of() {
	_tr_json=$("$CCS_BIN" ls --json)
	_tr_path=$(echo "$_tr_json" | jq -r --arg s "$1" '.[] | select(.slug==$s) | .path')
	_tr_id=$(echo "$_tr_json" | jq -r --arg s "$1" '.[] | select(.slug==$s) | .sessionId')
	_tr_dir="${CCS_PROJECTS_DIR}/$(printf '%s' "$_tr_path" | sed 's/[^A-Za-z0-9]/-/g')"
	mkdir -p "$_tr_dir"
	printf '%s/%s.jsonl\n' "$_tr_dir" "$_tr_id"
}

# 人が打った依頼を 1 行足す（content が文字列の形）。
_say() {
	jq -cn --arg t "$2" '{type:"user",message:{role:"user",content:$t}}' >>"$1"
}

# 人が打った依頼を 1 行足す（content が text ブロックの配列の形）。
_say_blocks() {
	jq -cn --arg t "$2" \
		'{type:"user",message:{role:"user",content:[{type:"text",text:$t}]}}' >>"$1"
}

# ツール結果を 1 行足す。これは「依頼」ではない。
_tool_result() {
	jq -cn --arg t "$2" \
		'{type:"user",message:{role:"user",content:[{tool_use_id:"toolu_x",type:"tool_result",content:$t}]}}' >>"$1"
}

@test "ls: 既定の出力に盤面の列を足さない" {
	_new myrepo >/dev/null

	run "$CCS_BIN" ls
	[ "$status" -eq 0 ]
	[[ "$output" == *"SESSION ID"* ]] || return 1
	[[ "$output" == *"PATH"* ]] || return 1
	[[ "$output" != *"REQUEST"* ]] || return 1
	[[ "$output" != *"RSS"* ]] || return 1
}

@test "ls --json: 既定のキーを増やさない" {
	# ここが増えると「既定は軽い」という約束が崩れる。
	# **`labels` は C2 で足した**（tmux のユーザオプションを 1 回で引くので、
	# 行ごとにプロセスが増えることはない ── 約束は破っていない）。
	_new myrepo >/dev/null

	run "$CCS_BIN" ls --json
	[ "$status" -eq 0 ]
	_keys=$(echo "$output" | jq -r '.[0] | keys_unsorted | join(",")')
	[ "$_keys" = 'slug,status,sessionId,path,tmux,labels' ]
}

@test "ls -l: 直近の依頼・RSS・最終更新の列を出す" {
	_new myrepo >/dev/null
	_f=$(_transcript_of myrepo)
	_say "$_f" 'ROADMAP の I1 を片付けて'

	run "$CCS_BIN" ls -l
	[ "$status" -eq 0 ]
	[[ "$output" == *"RSS"* ]] || return 1
	[[ "$output" == *"AGE"* ]] || return 1
	[[ "$output" == *"REQUEST"* ]] || return 1
	[[ "$output" == *"ROADMAP の I1 を片付けて"* ]] || return 1
}

@test "ls --long: -l と同じ" {
	_new myrepo >/dev/null
	_f=$(_transcript_of myrepo)
	_say "$_f" 'これをやって'

	run "$CCS_BIN" ls --long
	[ "$status" -eq 0 ]
	[[ "$output" == *"これをやって"* ]] || return 1
}

@test "ls -l: 最後の依頼を出す（途中のものではない）" {
	_new myrepo >/dev/null
	_f=$(_transcript_of myrepo)
	_say "$_f" 'ふるいほうのいらい'
	_say "$_f" 'あたらしいほうのいらい'

	run "$CCS_BIN" ls -l
	[[ "$output" == *"あたらしいほうのいらい"* ]] || return 1
	[[ "$output" != *"ふるいほうのいらい"* ]] || return 1
}

@test "ls -l: ツール結果を依頼として拾わない" {
	# 会話ログの user 行の大半はツール結果。ここを拾うと列が意味を失う。
	_new myrepo >/dev/null
	_f=$(_transcript_of myrepo)
	_say "$_f" 'ほんとうのいらい'
	_tool_result "$_f" 'ツールの出力です'
	_tool_result "$_f" 'ツールの出力です'

	run "$CCS_BIN" ls -l
	[[ "$output" == *"ほんとうのいらい"* ]] || return 1
	[[ "$output" != *"ツールの出力です"* ]] || return 1
}

@test "ls -l: text ブロックの配列も依頼として拾う" {
	_new myrepo >/dev/null
	_f=$(_transcript_of myrepo)
	_say_blocks "$_f" 'てんぷつきのいらい'

	run "$CCS_BIN" ls -l
	[[ "$output" == *"てんぷつきのいらい"* ]] || return 1
}

@test "ls -l: 定型文を飛ばして 1 つ前の依頼を拾う" {
	# 中断の印・スラッシュコマンドの展開・継続プロンプトは人が打った依頼では
	# ない。そのまま出すと「何をしているか」が読めなくなる。
	_new myrepo >/dev/null
	_f=$(_transcript_of myrepo)
	_say "$_f" 'ほんとうのいらい'
	_say "$_f" '[Request interrupted by user]'
	_say "$_f" '<command-name>/clear</command-name>'
	_say "$_f" 'Caveat: The messages below were generated by the user while running local commands.'
	_say "$_f" 'This session is being continued from a previous conversation that ran out of context.'
	_say "$_f" 'Continue from where you left off.'

	run "$CCS_BIN" ls -l
	[[ "$output" == *"ほんとうのいらい"* ]] || return 1
	[[ "$output" != *"Request interrupted"* ]] || return 1
	[[ "$output" != *"Continue from where"* ]] || return 1
}

@test "ls -l: 末尾から遠くても空欄にならない" {
	# **暫定のハブ用スクリプトはここで空欄を出していた**（末尾 300KB 固定で、
	# 13 本中 4 本が届かなかった）。当たるまで遡ることを担保する。
	_new myrepo >/dev/null
	_f=$(_transcript_of myrepo)
	_say "$_f" 'とおくのいらい'

	_pad=$(head -c 40000 /dev/zero | tr '\0' 'x')
	_i=0
	while [ "$_i" -lt 20 ]; do
		_tool_result "$_f" "$_pad"
		_i=$((_i + 1))
	done
	# 256KB の 1 段目には届かないところまで押し出せていること。
	[ "$(wc -c <"$_f")" -gt 400000 ] || return 1

	run "$CCS_BIN" ls -l
	[[ "$output" == *"とおくのいらい"* ]] || return 1
}

@test "ls -l: 会話ログが無ければ依頼と最終更新は - になる" {
	# 立てた直後は会話ログがまだ無い（本物は最初のやり取りで作る）。
	_new myrepo >/dev/null

	run "$CCS_BIN" ls -l
	[ "$status" -eq 0 ]
	_line=$(printf '%s\n' "$output" | sed -n '2p')
	[[ "$_line" == myrepo* ]] || return 1
	[[ "$_line" == *" - "* ]] || return 1
}

@test "ls -l: RSS を MB で出す" {
	_new myrepo >/dev/null

	run "$CCS_BIN" ls -l --json
	[ "$status" -eq 0 ]
	_rss=$(echo "$output" | jq -r '.[0].rssMb')
	[[ "$_rss" =~ ^[0-9]+$ ]] || return 1
}

@test "ls -l: 止まっていれば RSS は null" {
	export FAKE_CLAUDE_EXIT_AFTER=1
	_new myrepo >/dev/null
	ccs_wait_registry_count 0 10

	run "$CCS_BIN" ls -l --json
	[ "$(echo "$output" | jq -r '.[0].status')" = 'stopped' ]
	[ "$(echo "$output" | jq -r '.[0].pid')" = 'null' ]
	[ "$(echo "$output" | jq -r '.[0].rssMb')" = 'null' ]
}

@test "ls -l --json: 既定のキーを残したまま盤面のキーを足す" {
	_new myrepo >/dev/null
	_f=$(_transcript_of myrepo)
	_say "$_f" 'いらい'

	run "$CCS_BIN" ls -l --json
	[ "$status" -eq 0 ]
	echo "$output" | jq -e . >/dev/null
	_keys=$(echo "$output" | jq -r '.[0] | keys_unsorted | join(",")')
	[ "$_keys" = 'slug,status,sessionId,path,tmux,labels,pid,rssMb,updatedAt,age,request' ]
	[ "$(echo "$output" | jq -r '.[0].request')" = 'いらい' ]
	[ "$(echo "$output" | jq -r '.[0].updatedAt')" -gt 0 ]
}

@test "ls -l: 半角は 70 桁で切る" {
	_new myrepo >/dev/null
	_f=$(_transcript_of myrepo)
	_say "$_f" "$(head -c 100 /dev/zero | tr '\0' 'a')"

	run "$CCS_BIN" ls -l --json
	# 69 文字 + … で 70。切ったことが分かるように … を付ける。
	[ "$(echo "$output" | jq -r '.[0].request | length')" = '70' ]
	[[ "$(echo "$output" | jq -r '.[0].request')" == *"…" ]] || return 1
}

@test "ls -l: 全角は 2 桁として数える" {
	# **文字数で切ると横に 2 倍伸びて 1 画面に収まらない。** 盤面の列なので
	# 数えるのは桁数。
	_new myrepo >/dev/null
	_f=$(_transcript_of myrepo)
	_long=''
	_i=0
	while [ "$_i" -lt 100 ]; do
		_long="${_long}あ"
		_i=$((_i + 1))
	done
	_say "$_f" "$_long"

	run "$CCS_BIN" ls -l --json
	# 34 文字（68 桁）+ … で 35 文字。
	[ "$(echo "$output" | jq -r '.[0].request | length')" = '35' ]
}

@test "ls -l: 改行やタブを 1 行に畳む" {
	# 表が崩れるだけでなく、JSON 側でも列が割れる。
	_new myrepo >/dev/null
	_f=$(_transcript_of myrepo)
	_say "$_f" "$(printf 'まえ\n\tうしろ')"

	run "$CCS_BIN" ls -l --json
	[ "$(echo "$output" | jq -r '.[0].request')" = 'まえ うしろ' ]
}

@test "ls -l: 何も立っていなくても既定と同じ案内を出す" {
	run "$CCS_BIN" ls -l
	[ "$status" -eq 0 ]
	[[ "$output" == *"ありません"* ]] || return 1
}

@test "ls -l --json: 何も立っていなければ空配列" {
	run "$CCS_BIN" ls -l --json
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | jq -r 'length')" = '0' ]
}
