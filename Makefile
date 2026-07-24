# Universal entry points (no pixi/magic required). Mirrors the mojoproject
# [tasks]. The wasm + test targets run on LLVM 18 + Node with no Mojo toolchain;
# see STATUS.md for the gated Mojo front-end step.
.PHONY: build test component serve golden clean help

help:
	@echo "make build     - build every wasm artifact (scripts/build-all.sh)"
	@echo "make test      - build + run all runnable proofs (scripts/test-all.sh)"
	@echo "make component - WIT -> component -> typed JS bindings (needs npm/jco)"
	@echo "make serve     - http server for bindings/js browser demo (:8080)"
	@echo "make golden    - refresh golden LLVM-IR snapshots"
	@echo "make clean     - remove build/"

build:
	bash scripts/build-all.sh

test:
	bash scripts/test-all.sh

component:
	bash scripts/componentize.sh

serve:
	python3 -m http.server 8080

golden:
	bash scripts/ir-snapshot.sh --update

clean:
	rm -rf build
