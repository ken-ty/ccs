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

@test "new --tmp: 改名された枠を横取りしない" {
	run --separate-stderr "$CCS_BIN" new --tmp
	[ "$status" -eq 0 ]
	local _first=$output
	[ "$(printf '%s' "$_first" | jq -r '.slug')" = 'tmp-1' ]

	_rename tmp-1 'わかりやすい名前'

	run --separate-stderr "$CCS_BIN" new --tmp
	[ "$status" -eq 0 ]
	# **枠 1 は使われている。** 名前が変わっても cwd は変わらない。
	[ "$(printf '%s' "$output" | jq -r '.slug')" = 'tmp-2' ]
	[ "$(printf '%s' "$output" | jq -r '.sessionId')" \
		!= "$(printf '%s' "$_first" | jq -r '.sessionId')" ]
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
	# 宛先は相手が名乗るほう（打った綴りではない）。
	[ "$(printf '%s' "$output" | jq -r '.slug')" = 'mine' ]

	# **2 本目の claude が居ない。**
	[ "$(ccs_registry_count)" -eq 1 ]
}

@test "gc --yes: 改名された枠を空きとして消さない" {
	# **ここは実際に消える経路。** 空の枠は報告ではなく削除の対象なので、
	# 名前で当てていると**稼働中のセッションの足元のディレクトリを消す**。
	"$CCS_BIN" new --tmp >/dev/null
	[ -d "${CCS_SCRATCH_ROOT}/1" ]

	_rename tmp-1 'renamed'

	run --separate-stderr "$CCS_BIN" gc --yes
	[ "$status" -eq 0 ]
	[ -d "${CCS_SCRATCH_ROOT}/1" ]
	[[ "$output" != *"${CCS_SCRATCH_ROOT}/1"* ]] || return 1

	# **セッション自体も畳まれていない。** 「止まったペイン」の判定も
	# 名前で当てているので、生きている相手を止まったと読むと畳みに行く。
	ccs_tmux has-session -t '=cc/renamed'
	[ "$(ccs_registry_count)" -eq 1 ]
}

@test "new --tmp: 枠が空いていれば今までどおり 1 番から使う" {
	run --separate-stderr "$CCS_BIN" new --tmp
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq -r '.slug')" = 'tmp-1' ]
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
