# 上游改動的優先順序

> 2026-09-30。對象是 `modular/modular`(commit `e700d92`),工具鏈是 Mojo 1.1.0 和 nightly 1.2.0.dev2026093005。
> 所有「實測」都可以用 `python3 experiments/upstream_probes/run.py <mojo>` 重跑。

## 0. 問題

第一輪列出「必須改編譯器」的功能。這一輪要回答三件事:

1. 每一項除了本專案,還有哪些領域受益?
2. 官方要付出什麼代價?會碰到哪些官方模組?
3. 依「改動最小、衝擊最小、受益最廣」排序,好讓提案最容易被接受。

## 1. 限制條件:上游接受什麼

來源:`Mojo/docs/contributing/contribution-areas.md`。

| 區域 | 接受的 PR | 不接受的 |
|---|---|---|
| Compiler | **只收 bug fix**:錯誤的診斷、crash、miscompile,且要有使用者看得到的效果 | 改語言語意、改 MLIR dialect 的 IR 語意、**改編譯流程** |
| Standard library | 附測試的 bug fix、附 benchmark 的效能改善、文件、測試 | 「esoteric platform」支援、沒走 proposal 的新模組、需要社群共識的變更、破壞既有 API |
| 通則 | 超過小修正的都要**先開 issue**,等維護者同意(`accepted` 標籤)才動工 | |

所以:

- 只有 bug fix 能直接送 PR。
- 新功能要先開 issue,並且對上 roadmap。
- 語意變更很難被接受。

roadmap(`Mojo/docs/site/roadmap.mdx`)Phase 2 列了幾項相關工作:

- ⬜ Existentials / dynamic traits
- ⬜ Expand platform support,範圍寫到 "microcontrollers and robotics"
- 🚧 cross-compilation

## 2. 更正第一輪的清單

上游原始碼和兩個版本的實測推翻了第一輪的 4 項:

| 第一輪的說法 | 實測 | 結論 |
|---|---|---|
| struct 欄位不能放函式指標 | `var f: def(Int) thin -> Int` 可以編譯,呼叫得到 42(1.1.0、nightly)。stdlib 的 `format/tstring.mojo:32` 也這樣寫 | **撤回**。native README §11 用的是非 `thin` 寫法 |
| 同一個 C 符號不能用兩種簽章宣告,需要修 | 這是刻意的檢查:`LowerPOPToLLVMExternalCalls.cpp:301`,並有專屬測試 `test_conflicting_signatures_error.mojo` | **撤回**。本專案的 `bsd_signal` 是正確做法 |
| 沒有型別相等運算 | 比較 `reflect[T].name[qualified_builtins=True]()` 在編譯期就能分辨 `Int`/`Int64`、`List[Int]`/`List[Float32]` | **不需要改編譯器**。頂多在 stdlib 加一個小工具函式 |
| 沒有全域變數,需要語言支援 | 語言層的全域變數是官方在 v25.4 **刻意棄用**的(release notes:"only partially implemented … cryptic errors")。stdlib 已有私有的 `std.ffi._Global`,以名字為鍵、存在 CompilerRT,1.1.0 可用 | **改成 stdlib 議題**,不重新加入語言全域 |

驗證 `_Global` 時多發現一個 bug,已列為 U1:

- 在 `.so` 換版之後,全域值會保留(1、2、102)。
- 但 host 卸載過任何碰過 stdlib 全域的 Mojo `.so` 之後,程序結束時會 SIGSEGV。
- 只用公開的 `std.random` 就能觸發。
- 1.1.0 與 nightly 都是 5/5 重現,對照組 5/5 正常。

## 3. 排序

排序依據三項:改動大小、官方負擔、受益範圍。另外看貢獻路徑是否屬於上游現在接受的類型。

| 順位 | 項目 | 我們要送的東西 | 改動大小(預估) | 官方負擔 | 受益範圍 |
|---|---|---|---|---|---|
| **U1** | 卸載 Mojo `.so` 後結束時 SIGSEGV | issue,然後 bug-fix PR | CompilerRT 2 個檔案、數十行,加 1 個整合測試 | 低:不改語意,只影響結束時的清理 | 所有會卸載 Mojo `.so` 的 Mojo 程式 |
| **U2** | 編譯固定開銷(空程式約 1.5 s) | 附量測的 issue(不送程式碼) | 我們 0 行;官方要做效能工作 | 中:要在不破壞快取正確性的前提下加速 | 所有 Mojo 使用者,包括官方自己的 CI |
| **U3** | wasm32 A 段:只輸出 IR 或 object | issue,附最小 patch 構想 | 1 行 bazel、約 10 行 target traits、1 行測試、stdlib 1 個 predicate | 中:每個 release 多帶一個 LLVM 後端,多一個 CI 目標,多一類支援問題 | web、edge、plugin 沙盒、教學 |
| **U4** | wasm32 B 段:freestanding runtime 契約 | 文件,之後是 stdlib gating | 文件,加上 stdlib 條件編譯 | 中:要承諾 runtime 符號清單 | 同 U3,真正能「用」的那一段 |
| **U5** | 公開 `_Global`(或同等 API) | stdlib proposal | stdlib `ffi` 一個型別更名並補文件 | 中:長期 API 承諾,要定義 thread-safety 語意 | plugin、快取、logger、hot reload 狀態 |
| **U6** | Existentials | 提供使用案例,不送程式碼 | 0 | 高(型別系統、ABI),但已在 roadmap 上 | ECS、事件系統、GUI、剖析器 |

**不做**:

- 語言層全域變數:官方已明確移除。
- 函式層級熱修補:屬於「改編譯流程」,且瓶頸在編譯時間(換版 0.1 ms 對 build 3 s)。
- 開放 ORC JIT 給使用者:`ExecutionEngine.h` 是內部 C++ API,沒有卸載介面;以換版延遲來看量不到收益。

## 4. 各項細節

### U1 卸載後結束時 SIGSEGV

草稿:[unload-global-destroy.md](unload-global-destroy.md)。

- **本專案以外的影響**:
  - plugin host,包括遊戲引擎、編輯器、伺服器擴充;
  - hot reload 迴圈;
  - 把 kernel 變體逐一 build 成 `.so`、載入量測再卸載的 benchmark 或 autotuning 工具,屬於 HPC 和 AI 的使用型態。
  - 以上是依機制推論的使用型態,只有 hot reload 在本 repo 實測過。
- **會碰到的官方模組**:
  - `Mojo/lib/CompilerRT/Globals.cpp`;
  - `Support/lib/ADT/GlobalTable.cpp` 與 `.h`(`Support/` 被多個元件共用,但 repo 內引用 `GlobalTable` 的只有這 3 個檔案);
  - 新增一個 `Mojo/test/mojo-integration` 測試。
- **可預見的隱患**:
  - 修法 1 在結束時跳過已卸載模組的 destroy,讓值洩漏。程序正在結束,記憶體由 OS 回收,但那個 destroy 的副作用(例如 flush)會消失。
  - stdlib 共有 6 個具名全域:`random_state`、`IS_STDOUT_TTY`、`assert_aborts_visits`、Python 的兩個,以及 `_startup.mojo:44` 的 `Runtime`。
  - 只有 `Runtime` 的 destroy 有明確副作用:釋放 AsyncRT 的 CPU device。它在 `main` 之前由執行檔本身註冊,所以跳過路徑不會碰到它。Python 那兩個的 destroy 內容要再確認。
  - `dladdr` 在 Windows 上沒有。CompilerRT 若要支援 Windows,需要對應實作。
- **可檢驗的預測**(在 fork 上驗證,屬於 P0):套用修法 1 後,`run.py` 的兩個 "unloaded" 列從 SIGSEGV 變成 0,其餘列不變。

### U2 編譯固定開銷

空的 `def main(): pass`、未快取、n = 5:

| Mojo | wall(s) | 前三名 pass(平均) |
|---|---|---|
| 1.1.0 | 1.58–2.23 | Import Mojo 0.35 s,LowerLIT 0.27 s,VerifyParameters 0.25 s |
| nightly | 1.58–2.62 | Import Mojo 0.43 s,VerifyParameters 0.31 s,LowerLIT 0.27 s |

MLIR 總時間約等於 wall,所以時間不在 LLVM codegen 或連結。

- **本專案以外的影響**:
  - 每個 Mojo 程式的每次編譯都要付這筆固定開銷。
  - 上游 repo 有 332 個 stdlib 測試、1030 個 compiler 的 `.mojo` 測試、833 個 max kernels 測試。若每個都單獨編譯一次,單是固定開銷就約 2195 × 1.6 s ≈ 58 CPU 分鐘。這是上限估計,實際 lit 的編譯次數未量。
- **會碰到的官方模組**:MojoParser 的 import(載入預編譯的 stdlib)、LowerLIT、參數驗證。
- **為什麼只開 issue**:compiler 不收效能 PR。
- **合併的小項**:`-O0` 並不比較快(草稿 [o0-build-time.md](o0-build-time.md))放進同一個 issue 當附帶觀察,不單獨提交。
- **隱患**:若官方以快取 stdlib 的 elaboration 結果來加速,快取失效的正確性是主要風險。這由官方判斷。

### U3 wasm32 A 段:只輸出 IR 或 object

草稿:[wasm32-backend.md](wasm32-backend.md)(已補「最小改動」一節)。

- **最小 patch**:
  1. `bazel/public-patches/llvm_project.bzl` 的 `BACKENDS` 加 `"WebAssembly"`。
  2. 新增一個 wasm target traits,放在 `Mojo/lib/Target/`,結構參考 `Host/HostTraits.h`:
     - `matches` 用 `triple.isWasm()`;
     - `supportedEmissionKinds` 只列 `llvm`、`llvm-bitcode`、`asm`、`object`,**不列** `exe`、`shared-lib`,因為沒有 linker 和 runtime。
  3. `Mojo/test/mojo-tool/build/mojo_targets.mojo` 加一行 RUN。已有 `riscv32-unknown-none-elf --emit=llvm` 的先例。
  4. `stdlib/std/sys/info.mojo` 加 `CompilationTarget.is_wasm()`,並在 `test_arch_predicates.mojo` 加測試。
- **不做**的部分:runtime、stdlib 在 wasm 上能不能連結、threads、檔案 I/O。這些是 U4。
- **本專案以外的影響**:
  - 瀏覽器端應用和遊戲;
  - edge 或 serverless 的 wasm runtime;
  - plugin 沙盒,例如 proxy-wasm、資料庫的 wasm UDF;
  - 線上教學與 playground;
  - 小型 CPU kernel 在瀏覽器端推論(wasm SIMD128)。
  - HPC 沒有直接受益。
- **官方負擔**:
  - 每個 release 的 `mojo` 多帶一個 LLVM 後端。檔案大小和 build 時間增量**未量**,是 P0 要量的第一個數字。
  - 多一個 CI 目標。
  - 會多出一類 issue,例如「為什麼 wasm 上不能用 print 或 File」。
- **隱患**:
  - 32 位元 `Int` 暴露 stdlib 裡的 64 位元假設。這一類風險 riscv32 已經有了(本 repo W1 實測 riscv32 IR 的 `Int` 是 4 bytes),不是新類別。
  - stdlib 規則寫「不收 esoteric platform」。wasm 算不算 esoteric,由維護者判斷。issue 要以 roadmap 的 "Expand platform support" 和 cross-compilation 為論據。
- **本 repo 的證據**:W1、W2 已用 riscv32 IR 走完 Mojo 到 wasm 的全程:differential 3 seeds × 20000 步通過,hot reload 矩陣 25/25 與 40 格符合預測。

### U4 wasm32 B 段:freestanding runtime 契約

- 內容:列出 freestanding 模組必須提供的符號(`KGEN_CompilerRT_AlignedAlloc`、`AlignedFree`,以及錯誤路徑的 stub),以本 repo 的 `experiments/wasm_mojo/mojo_rt.c` 為參考實作。
- 之後才是 stdlib 在 `is_wasm()` 下的條件編譯,涉及:
  - `builtin/_startup.mojo`(argv、signal handler);
  - AsyncRT(threads);
  - `ffi` 的 `dlopen`。
- 前置條件:U3 被接受。

### U5 公開 `_Global`

- **現況**(實測):
  - 以名字為鍵;命中路徑無鎖(`GlobalTable::getOrCreate`);
  - 值跨 `.so` 換版保留;
  - 原始碼註解寫明「vending shared mutable pointers without locking」。
- **本專案以外的影響**:plugin 共用狀態、程序層級快取、logger 設定、hot reload 要保留的狀態。這些原本需要語言層全域變數的用途,不必走官方已放棄的路線。
- **官方負擔**:公開 API 是長期承諾,要定義:
  - thread-safety:初始化競賽時會多呼叫一次 `init_fn` 再丟棄;
  - 名字衝突的規則;
  - destroy 的時機。
- **順序**:排在 U1 之後。否則公開的 API 會直接帶著 U1 的 crash。
- **路徑**:stdlib proposal(`Mojo/docs/contributing/stdlib/proposal-process.md`)。

### U6 Existentials

已是 roadmap Phase 2 的 ⬜ 項目。我們只提供使用案例,不送程式碼:

- `ecs/commands.mojo`:異質 `List[C]` 改用 type-erased `Slot`;
- `scheduler/system_actor.mojo`:型別 pack 的 `comptime for … if i == k` 分派梯子。

這些是具體的「沒有 existentials 時要寫多少繞道」的數據。

## 5. 執行順序與關卡

```
P0  在 fork 上用 bazel 建出 mojo,跑 run.py,結果與 pip 版相同
 ├─► U1  fork 上實作修法 1 → run.py 兩列變 0 → 開 issue → accepted 後送 PR
 ├─► U2  開 issue(數據已有,只補 nightly n ≥ 10)
 └─► U3  fork 上加後端 → 量 mojo 大小與 build 時間增量 → 開 issue 附數字
          └─► U4 → U5(需 U1 已合併)
U6  任何時候,在 roadmap 的 existentials 討論附使用案例
```

每一項送出前:

- 搜尋上游 tracker 有無重複。本 session 無法使用 GitHub 搜尋,**尚未做**。
- 描述由 repo 擁有者用自己的話改寫,並標 `Assisted-by: AI`(上游 `AI_TOOL_POLICY.md`)。
