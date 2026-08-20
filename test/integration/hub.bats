#!/usr/bin/env bats
#
# hub を本物の tmux + fake claude で動かす。
#
# **ここで見たいのは「落ちても戻る」こと。** hub が死ぬと ccs を叩く経路
# そのものが消えるので、up が冪等で、状態を正しく判定し、暴走しないことが
# hub の存在意義そのものになる（docs/hub.md）。

load '../test_helper'

setup() {
	ccs_setup_sandbox
	ccs_use_own_tmux_server
	ccs_use_fake_claude

	export CCS_CONFIG_FILE="${CCS_TEST_TMP}/config"
	export CCS_HUB_HOME="${CCS_TEST_TMP}/hub"
	export CCS_NEW_TIMEOUT=10
	export CCS_HUB_RC_TIMEOUT=5
}

teardown() {
	ccs_kill_own_tmux_server
	ccs_teardown_sandbox
}

hub_json() {
	printf '%s' "$1" | grep '^{' | tail -1
}

hub_field() {
	hub_json "$1" | jq -r ".$2"
}

# --- 立てる ---------------------------------------------------------------

@test "hub up: tmux に cc/hub を立てて JSON を返す" {
	run "$CCS_BIN" hub up
	[ "$status" -eq 0 ]
	[ "$(hub_field "$output" state)" = 'healthy' ]
	[ "$(hub_field "$output" created)" = 'true' ]
	[ "$(hub_field "$output" tmux)" = 'cc/hub' ]
	ccs_tmux has-session -t '=cc/hub'
}

@test "hub up: Remote Control の名前を明示して渡す" {
	# **渡さないと、アプリ側の名前が会話の内容から自動で決まって動く。**
	# hub だけは名前が動くと見失う。
	export FAKE_CLAUDE_LOG="${CCS_TEST_TMP}/args.log"
	run "$CCS_BIN" hub up
	[ "$status" -eq 0 ]
	grep -q -- '--remote-control hub' "$FAKE_CLAUDE_LOG"
	[ -n "$(hub_field "$output" bridge)" ]
}

@test "hub up: 名前を変えれば tmux も RC もその名前になる" {
	export FAKE_CLAUDE_LOG="${CCS_TEST_TMP}/args.log"
	export CCS_HUB_SLUG=orchestrator
	run "$CCS_BIN" hub up
	[ "$status" -eq 0 ]
	ccs_tmux has-session -t '=cc/orchestrator'
	grep -q -- '--remote-control orchestrator' "$FAKE_CLAUDE_LOG"
}

@test "hub up: 接頭辞も設定で変えられる" {
	export CCS_PREFIX='mine/'
	run "$CCS_BIN" hub up
	[ "$status" -eq 0 ]
	ccs_tmux has-session -t '=mine/hub'
}

@test "hub up: 2 回目は立て直さず、既存を返す" {
	run "$CCS_BIN" hub up
	[ "$status" -eq 0 ]
	_first=$(hub_field "$output" sessionId)

	run "$CCS_BIN" hub up
	[ "$status" -eq 0 ]
	[ "$(hub_field "$output" created)" = 'false' ]
	[ "$(hub_field "$output" sessionId)" = "$_first" ]
}

@test "hub up --quiet: 健全なら何も言わない（自動起動が毎回吠えないため）" {
	"$CCS_BIN" hub up >/dev/null
	run "$CCS_BIN" hub up --quiet
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "hub up: 作業ディレクトリに CLAUDE.md と権限設定を置く" {
	run "$CCS_BIN" hub up
	[ "$status" -eq 0 ]
	[ -f "${CCS_HUB_HOME}/CLAUDE.md" ]
	[ -f "${CCS_HUB_HOME}/.claude/settings.json" ]
	jq -e . "${CCS_HUB_HOME}/.claude/settings.json" >/dev/null
	grep -q 'ccs hub restart' "${CCS_HUB_HOME}/CLAUDE.md"
}

@test "hub up: 既にある CLAUDE.md は上書きしない" {
	mkdir -p "$CCS_HUB_HOME"
	printf '私が書いた\n' >"${CCS_HUB_HOME}/CLAUDE.md"
	run "$CCS_BIN" hub up
	[ "$status" -eq 0 ]
	[ "$(cat "${CCS_HUB_HOME}/CLAUDE.md")" = '私が書いた' ]
}

@test "hub up: 作業ディレクトリを信頼済みにする" {
	# ghq 配下でも空の作業枠でもないので、明示的に扱わないと
	# 起動が信頼確認で固まる。
	run "$CCS_BIN" hub up
	[ "$status" -eq 0 ]
	# **JSON が返した path で引く。** ccs は symlink を辿った形に揃えるので
	# （macOS の /var → /private/var）、書いた側と読む側で形を合わせる。
	_path=$(hub_field "$output" path)
	[ "$(jq -r --arg p "$_path" '.projects[$p].hasTrustDialogAccepted' "$CCS_TRUST_FILE")" = 'true' ]
}

# --- Remote Control -------------------------------------------------------

@test "hub up: RC が付かなければ no-rc（10）で報告する" {
	# **実機で起きる。** 対話セッションとしては正常なのに bridgeSessionId が
	# null のまま残ると、スマホのアプリには出ない = 実質死んでいる。
	export FAKE_CLAUDE_NO_BRIDGE=1
	run "$CCS_BIN" hub up
	[ "$status" -eq 10 ]
	[[ "$output" == *"Remote Control"* ]]
	# **セッションは消さない。** ローカルからは使えるし、消すと調べられない。
	ccs_tmux has-session -t '=cc/hub'
}

@test "hub status: RC が無ければ no-rc（10）" {
	export FAKE_CLAUDE_NO_BRIDGE=1
	"$CCS_BIN" hub up || true
	run "$CCS_BIN" hub status
	[ "$status" -eq 10 ]
	[[ "$output" == *"no-rc"* ]]
}

@test "CCS_REMOTE_CONTROL=off: RC を渡さず、RC 無しでも healthy" {
	# RC を使わない・使えない環境でも hub が回るようにするための逃げ道。
	export CCS_REMOTE_CONTROL=off
	export FAKE_CLAUDE_LOG="${CCS_TEST_TMP}/args.log"
	run "$CCS_BIN" hub up
	[ "$status" -eq 0 ]
	[ "$(hub_field "$output" state)" = 'healthy' ]
	! grep -q -- '--remote-control' "$FAKE_CLAUDE_LOG"
}

# --- 落ちたときに戻る -----------------------------------------------------

@test "hub status: claude が死んでいれば stopped（11）" {
	"$CCS_BIN" hub up >/dev/null
	ccs_kill_claude_of hub
	run "$CCS_BIN" hub status
	[ "$status" -eq 11 ]
	[[ "$output" == *"stopped"* ]]
}

@test "hub status: レジストリの残骸に騙されない" {
	# claude は終了時に自分のファイルを消すが、SIGKILL では残る。
	# **残骸を信じると hub は永久に healthy に見えたまま戻らない。**
	"$CCS_BIN" hub up >/dev/null
	_f=$(grep -l '"tmux":"cc/hub:' "$CCS_SESSIONS_DIR"/*.json)
	_pid=$(jq -r '.pid' "$_f")
	kill -9 "$_pid"
	ccs_wait_until 5 bash -c "! kill -0 $_pid 2>/dev/null"

	[ -f "$_f" ] # 残骸が残っていることを確かめた上で
	run "$CCS_BIN" hub status
	[ "$status" -eq 11 ]
	[[ "$output" == *"stopped"* ]]
}

@test "hub up: 残骸が残っていても立て直せる" {
	run "$CCS_BIN" hub up
	_first=$(hub_field "$output" sessionId)
	_f=$(grep -l '"tmux":"cc/hub:' "$CCS_SESSIONS_DIR"/*.json)
	_pid=$(jq -r '.pid' "$_f")
	kill -9 "$_pid"
	ccs_wait_until 5 bash -c "! kill -0 $_pid 2>/dev/null"

	run "$CCS_BIN" hub up
	[ "$status" -eq 0 ]
	[ "$(hub_field "$output" sessionId)" != "$_first" ]
}

@test "hub up: 死んでいれば立て直す（新しい会話で）" {
	run "$CCS_BIN" hub up
	_first=$(hub_field "$output" sessionId)
	ccs_kill_claude_of hub

	run "$CCS_BIN" hub up
	[ "$status" -eq 0 ]
	[ "$(hub_field "$output" state)" = 'healthy' ]
	[ "$(hub_field "$output" sessionId)" != "$_first" ]
	# 直前の会話は捨てずに控えておく（--resume で戻れるように）。
	[ "$(hub_field "$output" previousSessionId)" = "$_first" ]
}

@test "hub up: 立て直しを hub.log に残す" {
	"$CCS_BIN" hub up >/dev/null
	ccs_kill_claude_of hub
	"$CCS_BIN" hub up >/dev/null

	[ -f "${CCS_HUB_HOME}/hub.log" ]
	grep -q '"event":"restart"' "${CCS_HUB_HOME}/hub.log"
	# 1 行 1 JSON（hub 自身に読ませるため）。
	while IFS= read -r _line; do
		printf '%s' "$_line" | jq -e . >/dev/null
	done <"${CCS_HUB_HOME}/hub.log"
}

@test "hub up: 健全なときはログを増やさない" {
	# 5 分ごとの「異常なし」を積むと、肝心の異常が埋もれる。
	"$CCS_BIN" hub up >/dev/null
	_before=$(wc -l <"${CCS_HUB_HOME}/hub.log" 2>/dev/null || echo 0)
	"$CCS_BIN" hub up --quiet
	_after=$(wc -l <"${CCS_HUB_HOME}/hub.log" 2>/dev/null || echo 0)
	[ "$_before" = "$_after" ]
}

# --- restart --------------------------------------------------------------

@test "hub restart: 新しい会話で立て直す" {
	run "$CCS_BIN" hub up
	_first=$(hub_field "$output" sessionId)

	run "$CCS_BIN" hub restart
	[ "$status" -eq 0 ]
	[ "$(hub_field "$output" sessionId)" != "$_first" ]
	ccs_tmux has-session -t '=cc/hub'
}

@test "hub restart --resume: 同じ会話に戻る" {
	run "$CCS_BIN" hub up
	_first=$(hub_field "$output" sessionId)

	run "$CCS_BIN" hub restart --resume
	[ "$status" -eq 0 ]
	[ "$(hub_field "$output" sessionId)" = "$_first" ]
}

@test "hub restart --resume: 直前が分からなければ新しく立てる" {
	run "$CCS_BIN" hub restart --resume
	[ "$status" -eq 0 ]
	[[ "$output" == *"新しい会話"* ]]
	ccs_tmux has-session -t '=cc/hub'
}

# --- down / paused --------------------------------------------------------

@test "hub down: 畳んで、自動起動も止める" {
	"$CCS_BIN" hub up >/dev/null
	run "$CCS_BIN" hub down
	[ "$status" -eq 0 ]
	! ccs_tmux has-session -t '=cc/hub'
	[ -f "${CCS_HUB_HOME}/paused" ]
}

@test "hub down のあと up は何もしない（14）" {
	"$CCS_BIN" hub up >/dev/null
	"$CCS_BIN" hub down >/dev/null
	run "$CCS_BIN" hub up
	[ "$status" -eq 14 ]
	! ccs_tmux has-session -t '=cc/hub'
}

@test "hub up --force: 止めた状態から再開する" {
	"$CCS_BIN" hub up >/dev/null
	"$CCS_BIN" hub down >/dev/null
	run "$CCS_BIN" hub up --force
	[ "$status" -eq 0 ]
	[ ! -f "${CCS_HUB_HOME}/paused" ]
	ccs_tmux has-session -t '=cc/hub'
}

@test "hub restart: 止めていても人が打てば立つ" {
	"$CCS_BIN" hub up >/dev/null
	"$CCS_BIN" hub down >/dev/null
	run "$CCS_BIN" hub restart
	[ "$status" -eq 0 ]
	[ ! -f "${CCS_HUB_HOME}/paused" ]
}

# --- 暴走の歯止め ---------------------------------------------------------

@test "hub up: 短時間に再起動を繰り返していれば止まる（15）" {
	# **無限再起動は課金とレート制限に直結する。**
	mkdir -p "$CCS_HUB_HOME"
	_now=$(date +%s)
	jq -n --arg n "$_now" \
		'{restarts: [($n|tonumber) - 10, ($n|tonumber) - 5, ($n|tonumber) - 1]}' \
		>"${CCS_HUB_HOME}/state.json"

	run "$CCS_BIN" hub up
	[ "$status" -eq 15 ]
	[[ "$output" == *"--force"* ]]
	! ccs_tmux has-session -t '=cc/hub'
}

@test "hub up --force: 歯止めを越えて立てられる" {
	mkdir -p "$CCS_HUB_HOME"
	_now=$(date +%s)
	jq -n --arg n "$_now" \
		'{restarts: [($n|tonumber) - 10, ($n|tonumber) - 5, ($n|tonumber) - 1]}' \
		>"${CCS_HUB_HOME}/state.json"

	run "$CCS_BIN" hub up --force
	[ "$status" -eq 0 ]
	ccs_tmux has-session -t '=cc/hub'
}

@test "人が打った restart は歯止めに数えない" {
	# 歯止めは自動復帰を止めるためのもの。人がその場にいるなら要らない。
	"$CCS_BIN" hub up >/dev/null
	"$CCS_BIN" hub restart >/dev/null
	"$CCS_BIN" hub restart >/dev/null
	"$CCS_BIN" hub restart >/dev/null

	run "$CCS_BIN" hub status
	[ "$status" -eq 0 ]
	[[ "$output" == *"healthy"* ]]
}

@test "hub status: 歯止めが効いていれば needs-attention（15）" {
	mkdir -p "$CCS_HUB_HOME"
	_now=$(date +%s)
	jq -n --arg n "$_now" \
		'{restarts: [($n|tonumber) - 10, ($n|tonumber) - 5, ($n|tonumber) - 1]}' \
		>"${CCS_HUB_HOME}/state.json"

	run "$CCS_BIN" hub status
	[ "$status" -eq 15 ]
	[[ "$output" == *"needs-attention"* ]]
}

@test "古い再起動は歯止めに数えない" {
	mkdir -p "$CCS_HUB_HOME"
	_now=$(date +%s)
	jq -n --arg n "$_now" \
		'{restarts: [($n|tonumber) - 5000, ($n|tonumber) - 4000, ($n|tonumber) - 3000]}' \
		>"${CCS_HUB_HOME}/state.json"

	run "$CCS_BIN" hub up
	[ "$status" -eq 0 ]
}

# --- 認証切れ -------------------------------------------------------------

@test "認証を求めていれば needs-login（13）で、立て直さない" {
	# 立て直しても同じ画面で止まるだけなので、人を待つ。
	export FAKE_CLAUDE_NEVER_REGISTER=1
	export FAKE_CLAUDE_ECHO='Please run /login to renew your credentials'
	export CCS_NEW_TIMEOUT=2

	"$CCS_BIN" hub up || true
	ccs_tmux has-session -t '=cc/hub'

	run "$CCS_BIN" hub status
	[ "$status" -eq 13 ]

	run "$CCS_BIN" hub up
	[ "$status" -eq 13 ]
	[[ "$output" == *"/login"* ]]
	grep -q '"event":"needs-login"' "${CCS_HUB_HOME}/hub.log"
}

# --- 他のコマンドとの関係 -------------------------------------------------

@test "kill: 動いている hub は畳めない" {
	"$CCS_BIN" hub up >/dev/null
	run "$CCS_BIN" kill hub
	[ "$status" -eq 1 ]
	ccs_tmux has-session -t '=cc/hub'
}

@test "gc: 止まった hub は掃除の対象にしない" {
	"$CCS_BIN" hub up >/dev/null
	ccs_kill_claude_of hub

	run "$CCS_BIN" gc --yes
	[ "$status" -eq 0 ]
	[[ "$output" == *"gc の対象外"* ]]
	ccs_tmux has-session -t '=cc/hub'
}

@test "ls: hub も一覧に出る" {
	"$CCS_BIN" hub up >/dev/null
	run "$CCS_BIN" ls --json
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq -r '[.[] | select(.slug == "hub")] | length')" = '1' ]
}
