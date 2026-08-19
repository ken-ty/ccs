# 開発用のタスク。CI もここを呼ぶ ── CI とローカルで手順がずれると、
# 「ローカルでは通る」が起きる。

SHELL := /bin/sh

BATS ?= bats
SHELLCHECK ?= shellcheck

# **LC_ALL=C で走らせる。** macOS 標準の bash 3.2 + bats 1.14 の組み合わせだと、
# 日本語を含むテスト名が化けて「unknown test name」で 1 件も実行されない。
# ロケールを固定すると通る（bash を新しくしなくてよい）。
BATS_ENV ?= LC_ALL=C

.PHONY: help
help:
	@echo 'make lint   shellcheck をかける'
	@echo 'make unit   unit テストだけ走らせる（外部プロセスを起動しない）'
	@echo 'make test   全テスト（unit + integration）'
	@echo 'make check  lint + test'
	@echo 'make docs   ドキュメントをローカルで配信する'
	@echo
	@echo 'make setup-hooks  git のフックを張る（新しい clone / worktree で毎回）'

.PHONY: lint
lint:
	$(SHELLCHECK) -s sh bin/ccs
	@# テストとフィクスチャも検査する。スタブが壊れると、テストは
	@# 「落ちる」のではなく「間違ったものを検証する」ので気づきにくい。
	@if [ -d test/fixtures ]; then \
		find test/fixtures -type f -perm -u+x -exec $(SHELLCHECK) -s sh {} +; \
	fi
	@# フックも検査する。**CI は main でしか回らない**ので、hooks/pre-push が
	@# 唯一の関門になった。壊れたフックは「落ちない」＝素通しになるため、
	@# bin/ccs と同じ基準で見る。
	@if [ -d hooks ]; then \
		find hooks -type f -perm -u+x -exec $(SHELLCHECK) -s sh {} +; \
	fi

# core.hooksPath は .git/config に入る**リポジトリごとのローカル設定**で、
# clone にも worktree の追加にも付いてこない。だから作業ディレクトリごとに
# 明示的に張る必要がある。hooks/ をそのまま指すので、フックを直せば
# すぐ反映される（.git/hooks へコピーする方式だと配ったきり古くなる）。
#
# **CI は main への push でしか回らない。**このフックが唯一の関門なので、
# 新しい clone / worktree では必ずこれを実行すること。
.PHONY: setup-hooks
setup-hooks:
	git config core.hooksPath hooks
	@echo "core.hooksPath = $$(git config core.hooksPath)"
	@if [ -x hooks/pre-push ]; then \
		echo 'hooks/pre-push: 実行可'; \
	else \
		echo 'hooks/pre-push: **実行権がありません** chmod +x hooks/pre-push' >&2; \
		exit 1; \
	fi

.PHONY: unit
unit:
	$(BATS_ENV) $(BATS) test/unit

.PHONY: integration
integration:
	@if [ -d test/integration ] && [ -n "$$(find test/integration -name '*.bats' -print -quit)" ]; then \
		$(BATS_ENV) $(BATS) test/integration; \
	else \
		echo 'integration: まだテストがありません（ROADMAP S4 以降）'; \
	fi

.PHONY: test
test: unit integration

.PHONY: check
check: lint test

# uvx 経由で動かす。グローバルに mkdocs を入れさせない ── 入れさせると
# 手元と CI で版がずれる。requirements-docs.txt で固定してあるので、
# どちらも同じものを使う。
UVX ?= uvx --quiet --with-requirements requirements-docs.txt

.PHONY: docs
docs:
	$(UVX) mkdocs serve

.PHONY: docs-build
docs-build:
	$(UVX) mkdocs build --strict

.PHONY: shots
shots:
	@echo 'スクリーンショットは実際の実行結果から作る（作り物の画面は置かない）:'
	@echo '  ccs ls | python3 scripts/termshot.py -o docs/img/ls.svg --title "ccs ls"'
