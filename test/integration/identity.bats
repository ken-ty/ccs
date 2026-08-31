#!/usr/bin/env bats
#
# 占有と冪等性の照合を cwd で行う（I1 / ADR-0002 決定 3）
#
# **tmux 名も claude の `name` も表示用のラベル**で、同一性の根拠にしない。
# 名前で当てていると、改名されたセッションが「居ない」ことになり、
#
#   - 稼働中の作業枠が横取りされる
#   - `ccs new <repo>` が同じ作業ツリーに 2 本目の claude を立てる
#   - `ccs gc` が使われている枠を「空き」として消しに行く
#
# の 3 つが同時に起きる。**改名は tmux セッション名の付け替えで再現する** ──
# レジストリの `tmux` 欄は起動時に 1 度書かれるだけで追随しない（実測
# 2026-08-30）ので、「名前だけがずれた稼働中のセッション」がそのまま作れる。

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

# 稼働中のまま tmux 名だけを変える。
_rename() {
	ccs_tmux rename-session -t "=${CCS_PREFIX:-cc/}$1" "${CCS_PREFIX:-cc/}$2"
}

@test "new --tmp: 改名された枠は本数に数える" {
	# **枠は使い回さない**（I2b）ので、横取りではなく「本数の数え上げ」に
	# 効く。名前が変わっても cwd は変わらないので、生きている 1 本と数える。
	export CCS_SCRATCH_SLOTS=1
	run --separate-stderr "$CCS_BIN" new --tmp
	[ "$status" -eq 0 ]
	local _slug
	_slug=$(printf '%s' "$output" | jq -r '.slug')

	_rename "$_slug" 'わかりやすい名前'

	run --separate-stderr "$CCS_BIN" new --tmp
	[ "$status" -eq 1 ]
}

@test "new <path>: 改名されていても 2 本目を立てない" {
	mkdir -p "${CCS_TEST_TMP}/work/mine"
	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/work/mine"
	[ "$status" -eq 0 ]
	local _id
	_id=$(printf '%s' "$output" | jq -r '.sessionId')

	_rename mine 'renamed'

	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/work/mine"
	[ "$status" -eq 0 ]
	# **立て直していない。** 同じ会話がそのまま返る。
	[ "$(printf '%s' "$output" | jq -r '.created')" = 'false' ]
	[ "$(printf '%s' "$output" | jq -r '.sessionId')" = "$_id" ]
	# **宛先は「いま届くほう」。** 打った綴りでも、レジストリに残っている
	# 起動時の名前でもない ── レジストリの tmux 欄は改名に追随しないので、
	# そこから返すと `ccs attach` できない slug を返すことになる。
	[ "$(printf '%s' "$output" | jq -r '.slug')" = 'renamed' ]
	[ "$(printf '%s' "$output" | jq -r '.tmux')" = 'cc/renamed' ]

	# **2 本目の claude が居ない。**
	[ "$(ccs_registry_count)" -eq 1 ]
}

@test "gc --yes: 改名された枠を空きとして消さない" {
	# **ここは実際に消える経路。** 空の枠は報告ではなく削除の対象なので、
	# 名前で当てていると**稼働中のセッションの足元のディレクトリを消す**。
	run --separate-stderr "$CCS_BIN" new --tmp
	[ "$status" -eq 0 ]
	local _slug _path
	_slug=$(printf '%s' "$output" | jq -r '.slug')
	_path=$(printf '%s' "$output" | jq -r '.path')
	[ -d "$_path" ]

	_rename "$_slug" 'renamed'

	run --separate-stderr "$CCS_BIN" gc --yes
	[ "$status" -eq 0 ]
	[ -d "$_path" ]
	[[ "$output" != *"$_path"* ]] || return 1

	# **セッション自体も畳まれていない。** 「止まったペイン」の判定も
	# 名前で当てているので、生きている相手を止まったと読むと畳みに行く。
	ccs_tmux has-session -t '=cc/renamed'
	[ "$(ccs_registry_count)" -eq 1 ]
}

@test "new --tmp: 本数に空きがあれば発行できる" {
	run --separate-stderr "$CCS_BIN" new --tmp
	[ "$status" -eq 0 ]
	[[ "$(printf '%s' "$output" | jq -r '.slug')" == tmp-* ]] || return 1
}

@test "new <path>: 管轄外のセッションが居ても断らない" {
	# **数えるのは管轄下だけ。** アプリや VS Code でその場所を開いている
	# だけで `ccs new` が断られると、使えない道具になる。
	local _dir="${CCS_TEST_TMP}/work/mine"
	ccs_start_outsider "$_dir" '00000000-0000-4000-8000-000000000001' >/dev/null

	run --separate-stderr "$CCS_BIN" new "$_dir"
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq -r '.created')" = 'true' ]
	ccs_stop_outsiders
}

@test "new <path>: 畳んだあとは新しく立てる" {
	# **残骸を「居る」と読まない**（registry_is_live）。
	mkdir -p "${CCS_TEST_TMP}/work/mine"
	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/work/mine"
	[ "$status" -eq 0 ]
	local _id
	_id=$(printf '%s' "$output" | jq -r '.sessionId')

	"$CCS_BIN" kill mine >/dev/null 2>&1
	ccs_wait_until 5 ccs_registry_count_is 0

	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/work/mine"
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq -r '.created')" = 'true' ]
	[ "$(printf '%s' "$output" | jq -r '.sessionId')" != "$_id" ]
}

# --- 表示も名前に依存させない（N2） ---------------------------------------
#
# **破壊はしないが、いちばん目に付く症状。** 動いているセッションが `stopped`
# と出ると、見た人は復帰の手を打とうとする（`ccs restore` を打つと、生きて
# いる会話をもう 1 本立てることになる）。

@test "ls: 改名されたセッションを stopped と出さない" {
	run --separate-stderr "$CCS_BIN" new --tmp
	[ "$status" -eq 0 ]
	local _id
	_id=$(printf '%s' "$output" | jq -r '.sessionId')

	_rename "$(printf '%s' "$output" | jq -r '.slug')" 'renamed'

	run --separate-stderr "$CCS_BIN" ls --json
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq -r '.[0].slug')" = 'renamed' ]
	[ "$(printf '%s' "$output" | jq -r '.[0].status')" != 'stopped' ]
	# **sessionId も cwd も、レジストリから引けている。**
	[ "$(printf '%s' "$output" | jq -r '.[0].sessionId')" = "$_id" ]
	[[ "$(printf '%s' "$output" | jq -r '.[0].path')" == "$(cd "$CCS_SCRATCH_ROOT" && pwd -P)/"* ]] || return 1
}

@test "ls -l: 改名されても pid が埋まる" {
	# **pid が `-` だと RSS の列も落ちる。** 盤面としての情報量が減る。
	run --separate-stderr "$CCS_BIN" new --tmp
	[ "$status" -eq 0 ]
	_rename "$(printf '%s' "$output" | jq -r '.slug')" 'renamed'

	run --separate-stderr "$CCS_BIN" ls -l --json
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq -r '.[0].pid')" != 'null' ]
}

@test "agents: 改名されたセッションを二重に出さない" {
	# **管轄下として 1 行だけ。** レジストリの tmux 欄は `cc/` のままなので
	# 管轄外の行には落ちない ── ここが崩れると同じ会話が 2 行に見える。
	run --separate-stderr "$CCS_BIN" new --tmp
	[ "$status" -eq 0 ]
	_rename "$(printf '%s' "$output" | jq -r '.slug')" 'renamed'

	run --separate-stderr "$CCS_BIN" agents --json
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq 'length')" -eq 1 ]
	[ "$(printf '%s' "$output" | jq -r '.[0].slug')" = 'renamed' ]
}

@test "ls: 本当に止まっていれば stopped のまま" {
	# **改名の救済が、死んだセッションまで生かして見せないこと。**
	export FAKE_CLAUDE_EXIT_AFTER=1
	"$CCS_BIN" new --tmp >/dev/null
	ccs_wait_until 10 ccs_registry_count_is 0

	run --separate-stderr "$CCS_BIN" ls --json
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq -r '.[0].status')" = 'stopped' ]
}
