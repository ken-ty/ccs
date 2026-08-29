#!/usr/bin/env bats
#
# hub の鼓動に相乗りした「古いまま気づかない」の検知。
#
# **新しいデーモンは作らない**（design.md §2.1）。`hub up` は launchd /
# systemd から 5 分ごとに冪等に走っているので、その鼓動に相乗りする。
# ここで見たいのは、相乗りが hub の仕事を邪魔しないことと、
# **自動切替が「決めたとおりにしか起きない」**こと。

bats_require_minimum_version 1.5.0

load '../test_helper'

setup() {
	ccs_setup_sandbox
	ccs_use_own_tmux_server
	ccs_use_fake_claude

	export CCS_CONFIG_FILE="${CCS_TEST_TMP}/config"
	export CCS_HUB_HOME="${CCS_TEST_TMP}/hub"
	export CCS_NEW_TIMEOUT=10
	export CCS_HUB_RC_TIMEOUT=5

	export CCS_INSTALL_ROOT="${CCS_TEST_TMP}/share"
	export CCS_BIN_DIR="${CCS_TEST_TMP}/instbin"
	export CCS_UPDATE_INTERVAL=0
	CCS_INSTALLER="${CCS_REPO_ROOT}/scripts/install.sh"
	export CCS_INSTALLER
}

teardown() {
	ccs_kill_own_tmux_server
	ccs_teardown_sandbox
}

ccs_make_upstream() {
	up="${CCS_TEST_TMP}/upstream.git"
	repo="${CCS_TEST_TMP}/repo"
	git init -q --bare "$up"
	# **既定のブランチ名を環境に決めさせない。** `git init` が作る HEAD は
	# `init.defaultBranch` 次第で、macOS の Apple Git は `main`、ubuntu の
	# 既定は `master`。放っておくと bare の HEAD が `master` を指したまま
	# `main` を push することになり、**clone しても作業ツリーが空**になる ──
	# 手元では緑で CI でだけ 12 件落ちた（2026-08-29、実測）。
	git -C "$up" symbolic-ref HEAD refs/heads/main
	git clone -q "$up" "$repo" 2>/dev/null
	mkdir -p "${repo}/bin"
	cp "$CCS_BIN" "${repo}/bin/ccs"
	git -C "$repo" config user.email 'test@example.com'
	git -C "$repo" config user.name 'test'
	git -C "$repo" add -A
	git -C "$repo" commit -q -m 'one'
	git -C "$repo" branch -M main
	git -C "$repo" push -q -u origin main
	"$CCS_INSTALLER" "$repo" >/dev/null
}

ccs_advance_upstream() {
	other="${CCS_TEST_TMP}/other"
	rm -rf "$other"
	git clone -q "$up" "$other" 2>/dev/null
	git -C "$other" config user.email 'test@example.com'
	git -C "$other" config user.name 'test'
	printf '\n# 新機能\n' >>"${other}/bin/ccs"
	git -C "$other" commit -qam 'feat: 新機能'
	git -C "$other" push -q origin main
}

# --- 入れていないとき ------------------------------------------------------

@test "hub up: install していなければ、更新の検知は何もしない" {
	# インストーラが居ない環境（clone しただけ）で hub が壊れては困る。
	run "$CCS_BIN" hub up
	[ "$status" -eq 0 ]
	ccs_tmux has-session -t '=cc/hub'
}

# --- 自動切替 --------------------------------------------------------------

@test "hub up: 上流が進んでいれば、鼓動のついでに切り替わる" {
	ccs_make_upstream
	before=$(cat "${CCS_INSTALL_ROOT}/current")
	ccs_advance_upstream

	run "$CCS_BIN" hub up
	[ "$status" -eq 0 ]

	after=$(cat "${CCS_INSTALL_ROOT}/current")
	[ "$before" != "$after" ] || return 1
	[[ "$(readlink "${CCS_BIN_DIR}/ccs")" == *"${after}" ]] || return 1
}

@test "hub up: 切り替えたことが hub.log に残る（無人で変わる以上、記録が要る）" {
	ccs_make_upstream
	before=$(cat "${CCS_INSTALL_ROOT}/current")
	ccs_advance_upstream
	"$CCS_BIN" hub up >/dev/null
	after=$(cat "${CCS_INSTALL_ROOT}/current")

	# hub 側には「切り替えた」ことと切り替え先。
	grep -q '"event":"updated"' "${CCS_HUB_HOME}/hub.log"
	grep -q "to=${after}" "${CCS_HUB_HOME}/hub.log"

	# **どの版から どの版へ・きっかけ**はインストーラ側の記録が持つ。
	# 実行しているのは切り替えられる当人（古い版）なので、
	# 記録は「切り替え後の版」で書かれていなければならない。
	line=$(grep '"trigger":"auto"' "${CCS_INSTALL_ROOT}/install.log")
	[[ "$line" == *"\"from\":\"${before}\""* ]] || return 1
	[[ "$line" == *"\"to\":\"${after}\""* ]] || return 1
}

@test "hub up: CCS_AUTO_UPDATE=off なら切り替えず、あることだけ言う" {
	ccs_make_upstream
	before=$(cat "${CCS_INSTALL_ROOT}/current")
	ccs_advance_upstream

	CCS_AUTO_UPDATE=off run "$CCS_BIN" hub up
	[ "$status" -eq 0 ]

	[ "$(cat "${CCS_INSTALL_ROOT}/current")" = "$before" ]
	grep -q '"event":"update-available"' "${CCS_HUB_HOME}/hub.log"
}

@test "hub up: 最新なら記録を増やさない（変化だけを残す）" {
	# healthy のたびに書くと、肝心の変化が埋もれる（hub_log の方針）。
	ccs_make_upstream
	"$CCS_BIN" hub up >/dev/null
	before=$(grep -c 'updated\|update-available' "${CCS_HUB_HOME}/hub.log" || true)
	"$CCS_BIN" hub up >/dev/null
	after=$(grep -c 'updated\|update-available' "${CCS_HUB_HOME}/hub.log" || true)
	[ "$before" = "$after" ]
}

@test "hub up: fetch できなくても hub は立つ（検知の失敗を hub の失敗にしない）" {
	ccs_make_upstream
	git -C "$repo" remote set-url origin "${CCS_TEST_TMP}/does-not-exist.git"

	run "$CCS_BIN" hub up
	[ "$status" -eq 0 ]
	ccs_tmux has-session -t '=cc/hub'
}

@test "hub up: 確認できないときは 5 分ごとに騒がない" {
	# オフラインで「分からない」と言われ続けても人にできることは無く、
	# 肝心の変化が埋もれる。見せるのは人が訊いたとき（ccs doctor）。
	ccs_make_upstream
	git -C "$repo" remote set-url origin "${CCS_TEST_TMP}/does-not-exist.git"
	"$CCS_BIN" hub up >/dev/null

	run grep -c 'update' "${CCS_HUB_HOME}/hub.log"
	[ "$output" = '0' ]
}

# --- doctor ----------------------------------------------------------------

@test "doctor: 走っている版と PATH の指す先を出す" {
	ccs_make_upstream
	run "${CCS_BIN_DIR}/ccs" doctor
	[ "$status" -eq 0 ]
	[[ "$output" == *"$(cat "${CCS_INSTALL_ROOT}/current")"* ]] || return 1
	[[ "$output" == *'最新'* ]] || return 1
}

@test "doctor: 古ければ古いと言い、巻き戻し方も出す" {
	ccs_make_upstream
	ccs_advance_upstream

	run "${CCS_BIN_DIR}/ccs" doctor
	[ "$status" -eq 10 ]
	[[ "$output" == *'古い'* ]] || return 1
	[[ "$output" == *'--switch'* ]] || return 1
}

@test "doctor: 確認できないときは「最新」と言わない" {
	ccs_make_upstream
	git -C "$repo" remote set-url origin "${CCS_TEST_TMP}/does-not-exist.git"

	run "${CCS_BIN_DIR}/ccs" doctor
	[ "$status" -eq 11 ]
	[[ "$output" == *'確認できていません'* ]] || return 1
	[[ "$output" != *'状態:       最新'* ]] || return 1
}

@test "doctor: リポジトリ直叩きなら「インストールされた実体ではない」と言う" {
	ccs_make_upstream
	run "$CCS_BIN" doctor
	[[ "$output" == *'インストールされた実体ではありません'* ]] || return 1
}
