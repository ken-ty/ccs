# スイート全体の前後に 1 度だけ走る（bats が自動で読む）。
#
# **取り残しを実際に拾うのは setup_suite のほう。** プロセスグループごと
# SIGKILL されると teardown も teardown_suite も見張りも一緒に死ぬので、
# 「終わったときに片付ける」では原理的に届かない。**次に走らせたときに前回の
# 残骸を拾う**のが、唯一確実な網になる。
#
# teardown_suite は正常系の念押し。テストごとの teardown と見張りで既に
# 片付いているはずなので、ここで何か出たら、その 2 つに穴がある。

_reap_tmux() {
	local _script="${BASH_SOURCE[0]%/*}/../reap-tmux"
	[ -x "$_script" ] || return 0

	# **fd 3 に書く。** bats は setup_suite の stdout を握り潰すので、素直に
	# printf すると「前回 Ctrl-C で止めた」ことに誰も気づけない。fd 3 は bats が
	# 結果を出すために開けているもので、ここに書けば画面に出る。
	if { true >&3; } 2>/dev/null; then
		"$_script" --quiet >&3 2>&1 || true
	else
		"$_script" --quiet || true
	fi
}

setup_suite() {
	_reap_tmux
}

teardown_suite() {
	_reap_tmux
}
