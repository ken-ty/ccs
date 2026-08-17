# 開発用のタスク。CI もここを呼ぶ ── CI とローカルで手順がずれると、
# 「ローカルでは通る」が起きる。

SHELL := /bin/sh

BATS ?= bats
SHELLCHECK ?= shellcheck

.PHONY: help
help:
	@echo 'make lint   shellcheck をかける'
	@echo 'make unit   unit テストだけ走らせる（外部プロセスを起動しない）'
	@echo 'make test   全テスト（unit + integration）'
	@echo 'make check  lint + test'
	@echo 'make docs   ドキュメントをローカルで配信する'

.PHONY: lint
lint:
	$(SHELLCHECK) -s sh bin/ccs
	@# テストとフィクスチャも検査する。スタブが壊れると、テストは
	@# 「落ちる」のではなく「間違ったものを検証する」ので気づきにくい。
	@if [ -d test/fixtures ]; then \
		find test/fixtures -type f -perm -u+x -exec $(SHELLCHECK) -s sh {} +; \
	fi

.PHONY: unit
unit:
	$(BATS) test/unit

.PHONY: integration
integration:
	@if [ -d test/integration ] && [ -n "$$(find test/integration -name '*.bats' -print -quit)" ]; then \
		$(BATS) test/integration; \
	else \
		echo 'integration: まだテストがありません（ROADMAP S4 以降）'; \
	fi

.PHONY: test
test: unit integration

.PHONY: check
check: lint test

.PHONY: docs
docs:
	@echo 'docs: まだ未実装です（ROADMAP S10）'
