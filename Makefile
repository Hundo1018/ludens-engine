# Universal entry points (no pixi/magic required). Mirrors the mojoproject
# [tasks]. The wasm + test targets run on LLVM 18 + Node with no Mojo toolchain;
# see STATUS.md for the gated Mojo front-end step.
.PHONY: build test component serve golden hot-native hot-native-dev hot-reload hot-dev clean help

help:
	@echo "make build     - build every wasm artifact (scripts/build-all.sh)"
	@echo "make test      - build + run all runnable proofs (scripts/test-all.sh)"
	@echo "make component - WIT -> component -> typed JS bindings (needs npm/jco)"
	@echo "make serve     - http server for bindings/js browser demo (:8080)"
	@echo "make golden    - refresh golden LLVM-IR snapshots"
	@echo "make hot-native - hot reload phase 1: pure Mojo, native .so (needs mojo)"
	@echo "make hot-native-dev - hot compile: edit experiments/hot_reload/native/engine.mojo live"
	@echo "make hot-reload - hot reload phase 2: wasm matrix + bench + browser e2e"
	@echo "make hot-dev   - wasm hot-reload dev server (:8080/experiments/hot_reload/wasm/)"
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

hot-native:
	python3 experiments/hot_reload/native/run_native.py all

hot-native-dev:
	python3 experiments/hot_reload/native/dev_native.py --run-host

hot-reload:
	python3 experiments/hot_reload/wasm/run.py all

hot-dev:
	python3 experiments/hot_reload/wasm/dev_server.py

clean:
	rm -rf build
