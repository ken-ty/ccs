#!/usr/bin/env bats
#
# workspace trust の事前承認。
#
# **ここは利用者の ~/.claude.json を書き換えうる唯一の場所。** そのファイルは
# Claude Code の状態がまとめて入った 100KB 級のもので、壊すと本体が動かなく
# なる。テストは必ず CCS_TRUST_FILE をサンドボックスに向けたまま走らせる
# （test_helper が担保。unit/cli.bats にその番人がいる）。

bats_require_minimum_version 1.5.0

load '../test_helper'

setup() {
	ccs_setup_sandbox
	ccs_use_fake_claude
	ccs_use_own_tmux_server
	export CCS_GHQ_ROOT_DIR="${CCS_TEST_TMP}/ghq"
	mkdir -p "$CCS_GHQ_ROOT_DIR"
	ccs_stub_ghq '' "$CCS_GHQ_ROOT_DIR"
	export CCS_NEW_TIMEOUT=15
}

teardown() {
	ccs_kill_own_tmux_server
	ccs_teardown_sandbox
}

_repo() {
	_p="${CCS_GHQ_ROOT_DIR}/github.com/ken-ty/$1"
	mkdir -p "$_p"
	printf '%s' "$_p"
}

_trusted() {
	# ファイルが無い = 誰も信頼していない。jq のエラーにせず false を返す。
	[ -f "$CCS_TRUST_FILE" ] || {
		echo false
		return 0
	}
	jq -r --arg p "$1" '.projects[$p].hasTrustDialogAccepted // false' "$CCS_TRUST_FILE"
}

# --- ghq 配下は自動で信頼する ----------------------------------------------

@test "ghq 配下なら hasTrustDialogAccepted を立てる" {
	_p=$(_repo myrepo)

	run --separate-stderr "$CCS_BIN" new "$_p"
	[ "$status" -eq 0 ]

	_abs=$(echo "$output" | jq -r '.path')
	[ "$(_trusted "$_abs")" = 'true' ]
}

@test "ghq 配下: 立てたことを stderr で伝える" {
	# 黙って安全確認を潰さない。何をしたかは必ず言う。
	_p=$(_repo myrepo)

	run --separate-stderr "$CCS_BIN" new "$_p"
	[ "$status" -eq 0 ]
	[[ "$stderr" == *"信頼済みにしました"* ]] || return 1
	echo "$output" | jq -e . >/dev/null
}

@test "ghq 配下: すでに信頼済みなら何も言わない" {
	_p=$(_repo myrepo)
	_abs=$(cd "$_p" && pwd -P)
	printf '{"projects":{"%s":{"hasTrustDialogAccepted":true}}}' "$_abs" >"$CCS_TRUST_FILE"

	run --separate-stderr "$CCS_BIN" new "$_p"
	[ "$status" -eq 0 ]
	[[ "$stderr" != *"信頼済みにしました"* ]] || return 1
	# 既に true のままであること（触っていないことの確認）
	[ "$(_trusted "$_abs")" = 'true' ]
}

@test "ghq 配下: 他の項目を壊さない" {
	# 100KB 級のファイルを読み書きするので、書き戻しで他が消えないこと。
	_p=$(_repo myrepo)
	cat >"$CCS_TRUST_FILE" <<'JSON'
{
  "someTopLevel": "keep me",
  "numberField": 42,
  "projects": {
    "/other/repo": {"hasTrustDialogAccepted": true, "allowedTools": ["Bash"]}
  }
}
JSON

	run --separate-stderr "$CCS_BIN" new "$_p"
	[ "$status" -eq 0 ]

	# 対象自身が信頼済みになったことをまず見る。これが無いと、
	# trust_accept が一度も走らなくても通ってしまう（実際に空振りした）。
	[ "$(_trusted "$(echo "$output" | jq -r '.path')")" = 'true' ]
	[ "$(jq -r '.someTopLevel' "$CCS_TRUST_FILE")" = 'keep me' ]
	[ "$(jq -r '.numberField' "$CCS_TRUST_FILE")" = '42' ]
	[ "$(_trusted '/other/repo')" = 'true' ]
	[ "$(jq -r '.projects["/other/repo"].allowedTools[0]' "$CCS_TRUST_FILE")" = 'Bash' ]
}

@test "ghq 配下: 既存プロジェクトの他のキーを消さない" {
	_p=$(_repo myrepo)
	_abs=$(cd "$_p" && pwd -P)
	jq -n --arg p "$_abs" \
		'{projects: {($p): {lastCost: 1.23, hasTrustDialogAccepted: false}}}' \
		>"$CCS_TRUST_FILE"

	run "$CCS_BIN" new "$_p"
	[ "$status" -eq 0 ]

	[ "$(_trusted "$_abs")" = 'true' ]
	[ "$(jq -r --arg p "$_abs" '.projects[$p].lastCost' "$CCS_TRUST_FILE")" = '1.23' ]
}

@test "ghq 配下: ファイルが無ければ作る" {
	_p=$(_repo myrepo)
	rm -f "$CCS_TRUST_FILE"

	run "$CCS_BIN" new "$_p"
	[ "$status" -eq 0 ]

	[ -f "$CCS_TRUST_FILE" ]
	jq -e . "$CCS_TRUST_FILE" >/dev/null
}

@test "ghq 配下: 結果は常に妥当な JSON" {
	_p=$(_repo myrepo)
	run "$CCS_BIN" new "$_p"
	[ "$status" -eq 0 ]
	jq -e . "$CCS_TRUST_FILE" >/dev/null
}

@test "ghq 配下: 一時ファイルを残さない" {
	_p=$(_repo myrepo)
	run "$CCS_BIN" new "$_p"
	[ "$status" -eq 0 ]

	_leftover=$(find "$(dirname "$CCS_TRUST_FILE")" -name '*.ccs.*' 2>/dev/null | head -1)
	[ -z "$_leftover" ]
}

# --- 壊れた入力には触らない ------------------------------------------------

@test "壊れた JSON なら書き換えず、そのまま残す" {
	# 直せると思って上書きするのが一番まずい。読めないなら触らない。
	_p=$(_repo myrepo)
	printf '{this is not json' >"$CCS_TRUST_FILE"
	_before=$(cat "$CCS_TRUST_FILE")

	run "$CCS_BIN" new "$_p"
	[ "$status" -eq 1 ]
	[[ "$output" == *"妥当な JSON ではない"* ]] || return 1
	[ "$(cat "$CCS_TRUST_FILE")" = "$_before" ]
}

# --- ghq の外は自動承認しない ----------------------------------------------

@test "ghq の外なら自動で信頼しない" {
	# 安全確認をツールが黙って潰さない（design.md §4.4）。
	mkdir -p "${CCS_TEST_TMP}/elsewhere/proj"
	printf '{"projects":{}}' >"$CCS_TRUST_FILE"

	run "$CCS_BIN" new "${CCS_TEST_TMP}/elsewhere/proj"
	[ "$status" -eq 0 ]

	_abs=$(cd "${CCS_TEST_TMP}/elsewhere/proj" && pwd -P)
	[ "$(_trusted "$_abs")" = 'false' ]
}

@test "ghq の外: 確認が出ることを先に伝える" {
	# 黙って立てると 30 秒待たされて「登録されませんでした」とだけ言われる。
	mkdir -p "${CCS_TEST_TMP}/elsewhere/proj"

	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/elsewhere/proj"
	[ "$status" -eq 0 ]
	[[ "$stderr" == *"信頼されていません"* ]] || return 1
	[[ "$stderr" == *"ccs attach proj"* ]] || return 1
}

# --- 空の作業枠は自動で信頼する（#6、2026-08-18 の決定） --------------------

@test "空の作業枠は自動で信頼する" {
	# 枠は ccs 自身が作った空のディレクトリ。確認が守ろうとしている
	# 「知らないコード」がそもそも無い。手作業にすると枠ごとに承認が要り、
	# tmp を何本も立てる運用が実質できなくなる。
	run --separate-stderr "$CCS_BIN" new --tmp
	[ "$status" -eq 0 ]

	_abs=$(echo "$output" | jq -r '.path')
	[ "$(_trusted "$_abs")" = 'true' ]
}

@test "作業枠: 信頼済みにしたことを stderr で伝える" {
	run --separate-stderr "$CCS_BIN" new --tmp
	[ "$status" -eq 0 ]
	[[ "$stderr" == *"作業枠なので信頼済みにしました"* ]] || return 1
}

@test "作業枠: 2 本目以降も自動で信頼する" {
	# ここが壊れると tmp の 2 回目が信頼ダイアログで止まり、30 秒待って
	# 「登録されませんでした」になる（実機で踏んだ）。
	run --separate-stderr "$CCS_BIN" new --tmp
	[ "$status" -eq 0 ]
	_first=$(echo "$output" | jq -r '.path')

	run --separate-stderr "$CCS_BIN" new --tmp
	[ "$status" -eq 0 ]
	_second=$(echo "$output" | jq -r '.path')

	[ "$_first" != "$_second" ]
	[ "$(_trusted "$_second")" = 'true' ]
}

@test "中身のある作業枠を実パスで指したら自動では信頼しない" {
	# そこにあるのは誰かが置いたコード。確認する意味がある。
	mkdir -p "${CCS_SCRATCH_ROOT}/1"
	printf 'x' >"${CCS_SCRATCH_ROOT}/1/leftover.txt"

	run --separate-stderr "$CCS_BIN" new "${CCS_SCRATCH_ROOT}/1"
	[ "$status" -eq 0 ]

	_abs=$(cd "${CCS_SCRATCH_ROOT}/1" && pwd -P)
	[ "$(_trusted "$_abs")" = 'false' ]
	[[ "$stderr" == *"信頼されていません"* ]] || return 1
}

@test "ghq の外でも、伝えたうえで立てる" {
	# 確認が出るのは起動後なので、ここで止める理由はない。
	mkdir -p "${CCS_TEST_TMP}/elsewhere/proj"

	run "$CCS_BIN" new "${CCS_TEST_TMP}/elsewhere/proj"
	[ "$status" -eq 0 ]
	ccs_tmux has-session -t '=cc/proj'
}

# --- 出力の作法 -------------------------------------------------------------

@test "trust の案内は stdout を汚さない" {
	# ハブがそのままパースする。
	mkdir -p "${CCS_TEST_TMP}/elsewhere/proj"

	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/elsewhere/proj"
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | wc -l | tr -d ' ')" = '1' ]
	echo "$output" | jq -e . >/dev/null
}

# --- 印を「空」と数えない（I2a・I2b） --------------------------------------
#
# **ADR-0001 が守ろうとしたのは「知らないコードがそこに無い」こと**で、
# 「空であること」はその代理指標だった。`ccs` が書いた印は知らないコードでは
# ないので、代理指標のほうを少しだけ緩める ── そうしないと、**発行した枠に
# 印を刻んだ瞬間に「空でない」に化けて、自動承認が止まる**。
#
# **緩めるのは正しい印だけ。** 名前だけ合わせた他人のファイルは数える。

_mark() { # <dir> [workspaceId] [kind] [schema]
	local _d=$1
	mkdir -p "$_d"
	printf '{"schema":%s,"workspaceId":"%s","kind":"%s"}\n' \
		"${4:-1}" "${2:-$(basename "$_d")}" "${3:-scratch}" >"${_d}/.ccs.json"
}

@test "trust: 発行した枠は印つきでも自動で信頼する" {
	# **I2b で実際にこの経路を通るようになった。** 発行 → 印 → trust の順。
	run --separate-stderr "$CCS_BIN" new --tmp
	[ "$status" -eq 0 ]
	[[ "$stderr" == *"信頼済みにしました"* ]] || return 1
	[ -f "$(printf '%s' "$output" | jq -r '.path')/.ccs.json" ]
}

@test "gc: 印だけの枠は空として扱う" {
	_mark "${CCS_SCRATCH_ROOT}/aaaa1111"

	run --separate-stderr "$CCS_BIN" gc
	[ "$status" -eq 0 ]
	[[ "$output" == *"空のまま残った作業枠"* ]] || return 1
}

@test "gc: 印のほかに何かあれば空ではない" {
	_mark "${CCS_SCRATCH_ROOT}/aaaa1111"
	printf 'work\n' >"${CCS_SCRATCH_ROOT}/aaaa1111/note.txt"

	run --separate-stderr "$CCS_BIN" gc
	[ "$status" -eq 0 ]
	[[ "$output" == *"中身のある作業枠"* || "$output" == *"作業枠"* ]] || return 1
	[[ "$output" != *"空のまま残った作業枠"* ]] || return 1
}

@test "gc: kind が違う印は数える（緩めない）" {
	_mark "${CCS_SCRATCH_ROOT}/aaaa1111" 'aaaa1111' 'something-else'

	run --separate-stderr "$CCS_BIN" gc
	[ "$status" -eq 0 ]
	[[ "$output" != *"空のまま残った作業枠"* ]] || return 1
}

@test "gc: workspaceId がディレクトリ名と違う印は数える" {
	# **素性は「そこに書いてあること」ではなく「そこと結びついていること」。**
	_mark "${CCS_SCRATCH_ROOT}/aaaa1111" 'someone-else'

	run --separate-stderr "$CCS_BIN" gc
	[ "$status" -eq 0 ]
	[[ "$output" != *"空のまま残った作業枠"* ]] || return 1
}

@test "gc: 名前だけ .ccs.json の他人のファイルは数える" {
	mkdir -p "${CCS_SCRATCH_ROOT}/aaaa1111"
	printf 'not json at all\n' >"${CCS_SCRATCH_ROOT}/aaaa1111/.ccs.json"

	run --separate-stderr "$CCS_BIN" gc
	[ "$status" -eq 0 ]
	[[ "$output" != *"空のまま残った作業枠"* ]] || return 1
}

@test "gc --yes: 印だけの枠は、印ごと消える" {
	# **`rmdir` は中身があると失敗する。** 印を数えない側だけ直して消すほうを
	# 直さないと、「空だと言ったのに消せない」で止まる。
	_mark "${CCS_SCRATCH_ROOT}/aaaa1111"

	run --separate-stderr "$CCS_BIN" gc --yes
	[ "$status" -eq 0 ]
	[ ! -d "${CCS_SCRATCH_ROOT}/aaaa1111" ]
	[[ "$stderr" != *"消せませんでした"* ]] || return 1
}

@test "gc --yes: 印のほかに中身があれば消さない" {
	_mark "${CCS_SCRATCH_ROOT}/aaaa1111"
	printf 'work\n' >"${CCS_SCRATCH_ROOT}/aaaa1111/note.txt"

	run --separate-stderr "$CCS_BIN" gc --yes
	[ "$status" -eq 0 ]
	[ -f "${CCS_SCRATCH_ROOT}/aaaa1111/note.txt" ]
	[ -f "${CCS_SCRATCH_ROOT}/aaaa1111/.ccs.json" ]
}
