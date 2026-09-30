# ROADMAP(experiment 分支):實驗題目路線圖

> 2026-09-30 制定。範圍只限 `experiment` 分支。主線路線圖是 [ROADMAP.md](ROADMAP.md)(dev)。
>
> **這個分支做什麼**:驗證主線還沒採用的技術題目。每題產出可重跑的實驗、數據和結論,
> 決定是否併回 dev。目前兩題:**wasm retarget** 和 **hot reload**。
>
> **每一項的格式**(科學方法):
> - 問題
> - 假說
> - 可檢驗預測(**執行前**寫進測試檔)
> - 量測設計
> - 通過條件(gate)
> - 進度
>
> 預測被推翻時照實記錄,不改寫預測。
>
> **工具鏈**:Mojo 1.1.0(與 `pixi.toml` 相同)。本環境用 `pip install mojo==1.1.0` 裝在 `.venv/`。

---

## 已完成

### E1 wasm retarget 骨架

> 進度:✅ 2026-09-30 之前 `toolchain/`、`bindings/`、`wit/`、`scripts/emit-and-link.sh`。
> C 替身 → LLVM IR → `wasm32`;layer A(C 共享 linear memory)、layer B(WIT/jco)、
> differential test 全部通過(`make test`)。
> **仍卡住**:Mojo 輸出整個模組的 LLVM IR([STATUS.md](../STATUS.md))。

### E2 hot reload phase 1:純 Mojo、native

> 進度:✅ 2026-09-30 `experiments/hot_reload/native/`
> - 矩陣:7 策略 × 5 種修改,35 格全部符合預測。
> - 已確認的事實:
>   1. heap 狀態在舊 `.so` 卸載後仍可用(所有模組共用 `libKGENCompilerRTShared`)。
>   2. 指向舊 `.so` 靜態資料的 `StaticString` 會懸空,讀取就 SIGSEGV。
>   3. layout 改變時,需要 size + offset 檢查才能避免錯亂。
>   4. `dlopen` 已載入的路徑會回傳舊的函式庫。
> - 延遲:換一次約 0.1 ms。

### E3 熱編譯(native)

> 進度:✅ 2026-09-30 `dev_native.py` + `live_host.mojo`(`make hot-native-dev`)。
> - e2e:6 次 code 修改、1 次語法錯誤、1 次 layout 修改,全部通過。
> - 延遲:存檔 → 換上,中位數 1.08 s,最大 3.29 s;其中 `mojo build` 約 0.98 s。
> - **更正(2026-09-30)**:1.08 s 大多是編譯快取命中(e2e 只在兩個 `SPEED` 值之間切換)。
>   快取以(路徑, 去掉註解後的程式碼)為鍵。每輪改成從未編過的值後:中位數 3.03 s,`mojo build` 2.94 s。

### E4 hot reload phase 2:wasm

> 進度:✅ 2026-09-30 `experiments/hot_reload/wasm/`
> - 矩陣全部符合預測。事前預測有 2 項被推翻(GlobalOpt 拆開 struct、linker 放在 padding),已照實記錄。
> - 瀏覽器 dev loop 的 e2e 6/6 通過。
> - 限制:引擎核心是 C 替身,不是 Mojo。

### E5 他語言做法調查

> 進度:✅ 2026-09-30 [experiments/hot_reload/PRIOR_ART.md](../experiments/hot_reload/PRIOR_ART.md)
> - 14 個系統,分成四種做法,每項附一手來源。
> - 下方 H1–H3 的想法來自這份調查。

---

## Now

### H1 新版當機時回滾(參考 cr.h)

- **問題**:新版的 `engine_update` 一旦 SIGSEGV,`live_host` 整個掛掉,狀態全失。
- **假說**:換版後的前 N 幀在 signal handler(`sigsetjmp`/`siglongjmp`)保護下執行。
  當機時回到上一個可用版本和它的狀態副本,host 可以繼續跑。
- **預測**(執行前寫進 `e2e_native.py`):
  - 在 `engine_update` 解參照 null 的修改 → host 不結束,印出 `rollback version=N`;
  - frame 回到交換前的值,之後繼續遞增;實體數不變;
  - 下一次正常修改仍能換上。
- **量測**:
  - e2e 加一輪「當機修改 → 修好」;
  - 記錄回滾耗時、狀態副本的大小與複製時間。
- **設計重點**:
  - `rebind` 會原地改動狀態,回滾前必須先複製狀態區塊。這是 cr.h 沒處理的部分,要先量副本成本。
  - Mojo 能否呼叫 `sigsetjmp`/`siglongjmp`(`external_call`)要先做 probe。
- **Gate**:e2e 通過,既有 35 格矩陣不退步。

> **進度:✅ 2026-09-30**
> - Probe:`__sigsetjmp`/`siglongjmp` 可經 `external_call` 從 SIGSEGV 恢復。
>   Mojo 1.1 沒有全域變數,jmp_buf 放在固定位址 mmap 的頁面(`MAP_FIXED_NOREPLACE`)。
> - `guard.mojo` + `live_host.mojo`:換版前舊模組存 snapshot 且不卸載;之後 60 幀在保護下執行;
>   fault 時由舊模組從 snapshot 重建狀態;60 幀無事則卸載舊模組(`commit`)。
> - e2e 預測全部成立:in-place 與 snapshot 兩條路徑的當機都回滾到交換前的 frame(880、1102),6 個實體,舊模組繼續跑;修好後正常換上並 commit。
> - 成本(6 實體):副本 144 B、1.3–2.2 µs;回滾 6–7 µs。
> - 未保護時的 fault 仍讓行程結束(exit 139);30 格矩陣不退步(原 35 格,H2 已去掉 `rebind` 列)。
> - 限制:只保護換版後 60 幀;engine 持有鎖(如 malloc 內)時當機未測。

### H2 狀態中不放靜態指標

- **問題**:`EngineState.label` 指向 `.so` 的唯讀資料。卸載舊 `.so` 後它懸空,
  目前靠 `engine_rebind` 手動重新指向,而這件事沒有自動檢查。
- **假說**:把 `StaticString` 換成索引(查表在程式碼裡),狀態就只剩數值和 heap 資料。
  `close` 策略不需要 `rebind` 也安全。
- **預測**:
  - `close` × v2/v3 由 `ok/trap` 變成 `ok/new`;
  - `engine_rebind` 刪除後矩陣其餘格不變。
- **量測**:重跑 35 格矩陣,預測表先改,再執行。
- **Gate**:矩陣全部符合新預測;e2e 通過。
- **附帶**:研究能否在編譯期檢查 `EngineState` 沒有指標型別的欄位(`comptime assert`),把這條規則機械化。

> **進度:✅ 2026-09-30**
> - `label: StaticString` 改成 `label_id: Int`,`engine_rebind` 與 `rebind` 策略刪除(沒有 rebind 步驟時它就是 `close`)。
> - 矩陣 6 策略 × 5 修改 = 30 格,全部符合事前預測:`keep`/`close` × v2/v3/v6 由 `ok/old`、`ok/trap` 變成 `ok/new`,其餘不變。
> - 編譯期規則 `nostatic.mojo`:直接欄位的型別是 `StringSpan`/`Pointer`/… 時 build 失敗;`run_native.py test` 驗證加了 `StaticString` 欄位的版本無法編譯。
> - 缺口:容器的型別參數不檢查,`SparseSet[StaticString]` 會通過(`probes/probe_nostatic.mojo`)。
> - e2e 通過(4 次程式碼修改走 `inplace`)。

---

## Next

### H3 版本化遷移:改用 `ecs/schema.mojo`

- **問題**:snapshot 格式是手寫的 word 陣列。新增、刪除、改名欄位都要手改 `engine_save`/`engine_load`。
- **假說**:用 dev 的 reflection schema(`ecs/schema.mojo`,原本用於存檔)序列化狀態。
  `engine_load` 收到舊 schema,就能得到新增欄位、刪除欄位和它們的值,
  做法類似 Common Lisp 的 `update-instance-for-redefined-class`、Erlang 的 `code_change(OldVsn, …)`。
- **預測**:
  - v4(插入欄位)、v6(追加欄位)不寫任何遷移碼即可正確換上,新欄位取預設值;
  - 新增 v7(刪除欄位)、v8(改名欄位):v7 自動通過;
    v8 需要一行遷移規則,沒寫時要**報錯**,不能靜默丟資料。
- **量測**:
  - 矩陣加 v7、v8;
  - snapshot 時間對實體數作圖(10、1k、100k),和現在的手寫格式比較。
- **Gate**:矩陣全部符合預測;snapshot 在 100k 實體時 < 16.7 ms,否則記錄實際數字並說明。

> **進度:✅ 2026-09-30**
> - `EngineState { entities; core: Core }`:`Core` 以 `write_value`、實體以 `write_values[Entity]` 序列化;
>   `engine_layout_id` 改由 `schema_of[EngineState]` 雜湊,不再手寫欄位清單。
> - 規則:一次載入同時「丟掉舊欄位」且「新欄位取預設」視為改名,先套 `migrate()` 的別名重試,仍不成立則拒絕(code 2)。
> - 矩陣 6 策略 × 8 修改 = 48 格全部符合事前預測:v7 自動通過;v8 無規則被拒;v8 加一行 `alias_field` 通過。
>   第一次跑 47/48:host 在拒絕時沒印 `used=`(harness 錯誤,已修)。
> - snapshot 成本(save + load):100k 實體 9.30 ms(手寫 1.57 ms),gate 通過;大小少 25%(每實體 12 B 對 16 B)。
> - 代價:engine 每次編譯多約 0.3 s(2.74 → 3.04 s,未快取)。

### H4 v6 越界寫入的 sanitizer 驗證

- **問題**:v6(追加欄位)在 `keep`/`rebind` 下輸出正確,
  但新程式碼寫出了 host 區塊的邊界,目前的矩陣看不到。
- **假說**:用 ASan 或 valgrind 可以抓到。
- **預測**:
  - `keep`/`rebind` × v6 報出 heap-buffer-overflow(或 invalid write);
  - `auto` × v6 不報錯(走 snapshot)。
- **量測**:
  - 先確認 Mojo 1.1.0 是否支援 sanitizer 選項;
  - 否則安裝 dev 的 `valgrind` 依賴,在 valgrind 下跑該 3 格。
- **Gate**:預測成立;不成立時照實記錄原因。

> **進度:✅ 2026-09-30** `sanitize_native.py`
> - ASan(`--sanitize address`):6 格全部符合預測。`keep`/`close` × v6 報 `heap-buffer-overflow`,
>   在 `engine_update`,第一個越界存取是 `s.extra += 1` 的讀取;`auto` × v6 與對照組沒有報告。
> - valgrind 經三輪才可用:
>   1. host CPU 版含 AVX-512,valgrind 3.22 SIGILL → 改用 `--target-cpu x86-64-v3` 編譯;
>   2. 全部 0 錯誤,違反預測 → probe 證明 Mojo `alloc` 用自己的 arena,valgrind 看不到區塊邊界
>      → host 的狀態區塊改用 libc `malloc`;
>   3. 60 個錯誤、沒有一個標成 "Invalid write" → `incq` 是讀改寫,memcheck 把 load + store 記成 2 個 "Invalid read"(probe 驗證)。
>   判準改為「`engine_update` 存取 host 區塊之後的位址」後,6 格全部符合。
> - 預測的措辭「invalid write」對存取本身成立,對 valgrind 的標籤不成立。

### H5 熱編譯涵蓋 import 的套件

- **問題**:`dev_native.py` 只監看 `engine.mojo`。改了 `ecs/`、`geometry/` 要手動重新 precompile。
- **假說**:監看這些套件目錄,依相依順序只重建有變的套件,再重建 engine。
- **預測**:改 `ecs/sparse_set.mojo` 的一個函式 → host 換上新版;延遲 = 該套件 precompile + engine build。
- **量測**:e2e 加一輪修改 `ecs/`;記錄各段耗時。
- **Gate**:e2e 通過;延遲數字寫入 native README。

> **進度:✅ 2026-09-30**
> - `dev_native.py` 監看 `diag/`、`geometry/`、`ecs/` 的所有 `.mojo`;有變的套件與依賴它的套件依序 precompile,再 build engine。
> - e2e(在套件複本上):`SparseSet.__len__` 改成 `+100` → `pkgs=ecs`,precompile 2.48 s + engine 3.97 s,in-place 換上,`count=106`;存檔 → 換上 6.56 s。
> - 第一次跑:build 行與 host 的 swap 行由兩個執行緒同時印出而黏成一行,檢查逾時;已改為加鎖輸出,並先印 build 行再發布。

---

## Later

### H6 縮短編譯:拆成多個 `.so`

- **問題**:存檔 → 換上的 1.08 s 裡,0.98 s 是 `mojo build` 編整個 engine。
- **假說**:把 engine 的系統拆成幾個小 `.so`,只重編被改到的那個,延遲下降。
- **預測**:只改其中一個系統時,build 時間和該 `.so` 的程式碼量成比例,低於 0.5 s。
- **量測**:先量 `mojo build` 的固定開銷(編空檔案的時間)。
  若固定開銷本身就接近 1 s,這題的上限就很低,先記錄再決定是否繼續。
- **Gate**:有量測數據支持才實作。

> **進度:✅(量測完成,決定不實作)2026-09-30** `h6_fixed_cost.py`
> - 未快取、交錯、各 5 次:空模組 **2.52 s**,+SparseSet 2.91 s,+schema 3.16 s,engine 4.17 s。固定開銷佔 engine build 的 60%。
> - 固定開銷不在:行程啟動(`mojo --version` 0.05 s)、`-I build`(去掉仍 2.50 s)、連結(`--emit object` 2.51 s)。
> - 每個系統一個 `.so`,每次修改至少 2.4 s,達不到 < 0.5 s 的目標 → 不拆。

### W1 真的 Mojo → wasm

- **前置**:Mojo 能輸出整個模組的 LLVM IR([STATUS.md](../STATUS.md) 的 gate)。
- **內容**:以 Mojo 核心取代 C 替身,重跑 wasm 端的 differential test 和 hot reload 矩陣。
- **預測**:GlobalOpt 拆 struct 的現象也會出現在 Mojo(同一套 LLVM pass),
  所以 link-map 指紋仍然需要。
- **Gate**:wasm 矩陣用 Mojo 核心全部符合預測。

> **進度:✅ 2026-09-30** [experiments/wasm_mojo/](../experiments/wasm_mojo/README.md)
> - 前置 gate 以另一條路解開:Mojo 1.1.0 沒有 wasm 後端(`--target-triple wasm32` 失敗),
>   但 `--emit llvm` 可輸出整個模組的 host IR。`retarget_ir.py` 改 triple/datalayout、移除 x86 屬性、
>   刪 lifetime intrinsic、移除 LLVM 18 不認得的語法,再走原本的 llc → wasm-ld。
> - `mojo_rt.c` 提供 KGEN 配置器與錯誤路徑的 stub;SparseSet 核心(dev 的 `ecs.SparseSet`)36 KB、無 import。
> - differential 3 seeds × 20000 步通過;native Mojo / Mojo→wasm / C→wasm 三方 digest 相同。
> - `engine_hot.mojo` 上的 hot reload 矩陣 25/25 格、guard 5/5 列符合事前預測。
> - 「GlobalOpt 拆 struct」的預測無法檢驗:Mojo 沒有全域變數,狀態在 heap 上;因此 map guard 看不到任何 struct 修改。
> - 已量到的限制:Mojo 在編譯期以 host(64 位元指標)計算 `size_of`/`reflect` offset。
>   `{ptr, ptr, Int}` 的 `c` 編譯期 offset 16、wasm 執行期 8。

### W2 把 H1–H3 套到 wasm

- **內容**:回滾、無靜態指標、schema 遷移,在 wasm host(JS)上實作並重跑矩陣。
- **Gate**:同 native。

> **進度:✅ 2026-09-30**(Mojo 核心,[wasm README](../experiments/hot_reload/wasm/README.md) W2 節)
> - H2:`nostatic` 用在 wasm 引擎;加 `StaticString` 欄位的版本無法編譯。
> - H3:5 策略 × 8 修改 = 40 格、guard 8 列。預測推翻 1 項:v8_rename 的位址不變
>   (Mojo 字串常數以 16 bytes 對齊,`box_x` 與 `offset_x` 佔同一格),in-place 複製因此正確;
>   已照實記錄在 `REFUTED_MOJO`,未改寫預測。`auto` 每欄都正確,沒有別名的改名被拒絕。
> - H1:`LiveEngine`。trap 後回到交換前的 frame(40)、6 實體,之後與 v1 oracle 相同,下一版正常 commit。
>   回滾 7–11 µs,不需要複製狀態(wasm instance 不共用記憶體)。
> - 前置修正:
>   1. x86-64 IR 的 `String` 短字串布局在 wasm 錯誤(schema 欄位名被截成 4 bytes)→ IR 改為以 riscv32 輸出;
>   2. 各變體從不同目錄編譯,原始碼路徑進入 `.rodata` 而改變位址 → 統一從同一路徑編譯。
> - 成本:模組 98.8 KB,1000 實體 snapshot 1.66 ms(W1 手寫格式 0.43 ms)。

### 函式層級熱修補(僅記錄,不排程)

- Live++ 和 Subsecond 只換函式,不換整個模組。這需要編譯器和 linker 支援,Mojo 目前沒有。
- 等 Mojo 工具鏈提供類似功能再評估。

---

## 第二輪:驗證與測試改善(2026-09-30 起)

> 起因:審查第一輪後發現三個缺口。
> 1. 修改種類只涵蓋 `Core` 的純量欄位:沒有 heap 容器的元素型別、容器內的巢狀 struct、comptime 決定的大小、trait、改型別、ABI、邊界情形。
> 2. 熱編譯沒有和一般編譯比較;H6 沒把固定開銷拆成階段就下了結論。
> 3. 預測與結果在同一個 commit,「先預測」無法由 git 歷史驗證。
>
> 另外,Mojo 編譯器原始碼在 `modular/modular`(C++,Apache 2.0),先前的 retarget 是在不知道這點的情況下選的路。
> 改編譯器只為驗證:修改放在使用者的 fork(`Hundo1018/modular`)的 branch 與 draft PR(base 為 fork 自己的 main),
> 不放進本 repo,也不向上游提交。欲提交上游的內容寫成 `docs/upstream/` 下的檔案,由使用者審查。

### R4 預測先行(本輪起的規則)

- 每題的預測是獨立的 commit,在實作與執行之前 push。結果 commit 的訊息寫出預測 commit 的 hash。
- 實作時若發現某個預測描述的修改做不出來,修正也是獨立的 commit,在執行之前 push,並寫明原因。
- R1、R2 的預測:`experiments/hot_reload/native/predictions_r1.py`、`predictions_r2.py`。

### R1 修改種類與邊界

- **問題**:第一輪矩陣只測 `Core` 的純量欄位,各種記憶體用法、comptime、trait、struct 的情況未知。
- **做法**:EngineState 在 `core` 之前加入 `trail: List[TRAIL_T]`、`bodies: List[Body]`、
  `aux: Aux{grid: InlineArray[Int, GRID_N], mover: ActiveMover}`(`ActiveMover` 經 trait `Mover` 泛型呼叫)。
  新增 8 種修改 × 6 策略 = 48 格,另有邊界情境 B1–B3;舊的 48 格作為回歸。
- **假說與預測**:見 `predictions_r1.py`。要點:
  - `List[Body]` 內的 `Body` 改 layout 時,layout id 不變,`auto` 走 in-place 而錯(guard 缺口);
  - `InlineArray` 的長度改變、欄位改型別 → snapshot 拒絕載入;
  - trait 實作與 trait 預設方法的修改等同只改程式碼;
  - 匯出函式簽章改變時,沒有任何 guard 擋得住,連 snapshot 也錯;
  - ASan 看不到 Mojo `alloc` 區塊的邊界;
  - 連續 100 次換版,RSS 成長 < 2 MiB。
- **不涵蓋**(記錄在案):換版時另一執行緒在 `engine_update` 裡;持有鎖時當機;10 萬實體跑完整矩陣;狀態內的裸指標。
- **Gate**:所有格子與預測比對的結果照實記錄;推翻的預測不改寫,並寫出原因。

### R2 熱編譯與一般編譯的速度比較

- **問題**:熱路徑(改檔 → build `.so` → 換上)和一般路徑(build 執行檔 → 啟動 → 重跑到同一狀態)差多少;
  `-O0`、JIT(`mojo run`)的影響。先導量測(n=3)雜訊 ±50%,engine 的 `-O0` 比 `-O3` 慢。
- **量測**:`compile_speed.py`。6 種條件 × 10 次,每次空快取、每輪順序打亂;報中位數、IQR、最小/最大、機器規格;
  另跑一次 `--mlir-timing`,拆出各階段。
- **預測**:見 `predictions_r2.py`。要點:
  - 執行檔與 `.so` 的 build 時間差在 −0.3 到 +0.5 s;
  - 冷路徑減熱路徑 < 0.5 s;
  - `mojo run` 比 build 執行檔快 0.05–0.4 s;
  - `-O0`/`-O3` 比值在 0.8–1.2;
  - 空模組 ≥ engine 的 50%。
- **Gate**:同 R1。

### P0 在本環境從原始碼建出 `mojo`(改編譯器的前提)

- **量測**:`./bazelw build --config=build-mojo //Mojo:mojo` 的時間、磁碟用量。
- **Gate**:自建的 `mojo` 跑 native 矩陣、W1 differential、W2 矩陣,結果與 pip 版 1.1.0 相同。
  建不起來或結果不同,就跳過 C1/J1/J2 並記錄原因。

### C1 原生 wasm32 目標(fork)

- 依據:`bazel/public-patches/llvm_project.bzl` 的 `BACKENDS = [AArch64, RISCV, X86]`,解釋了 W1 的 wasm32 被拒、riscv32 可用。
- 做法:`extra_targets` 加 `WebAssembly`,新增 wasm32 的 `TargetTraits`。
- 預測:`--target-triple wasm32-unknown-unknown` 可用;`probe_layout` 直接得到 8/8、12;
  不經 `retarget_ir.py`,W1 digest 與 W2 矩陣不變。

### J1 / J2 以 JIT 取代 `dlopen`(fork 或連結 `ExecutionEngine` 的工具)

- 依據:`Mojo/lib/ExecutionEngine` 是 LLVM ORC(具名 `JITDylib`),`mojo run` 用它。
- J1:每個版本一個 `JITDylib`。預測 `samepath` 陷阱消失、不需要 `cc`/`ld`、heap 狀態可用。
- J2:透過 ORC 間接 stub 做函式層級修補。預測只改程式碼的修改換版 < 1 ms,不需要 snapshot;
  已 inline 的呼叫換不掉。

### U 欲提交上游的內容(只寫成檔案,不提交)

- 位置:`docs/upstream/<題目>.md`,內容包括問題、最小重現、數據、nightly 重測結果、建議的修改或 fork PR 連結。
- 候選:wasm32 後端(C1)、前端固定成本(R2)、`-O0` 比 `-O3` 慢(R2 若重現)、R1 發現的 bug。

---

## 工具鏈與雜項

- **T1** dev 的完整套件建置在本環境失敗:缺 `max`,`pip install modular==26.6.0` 依賴衝突。
  要嘛找出可行的 pip 組合,要嘛讓 pixi 在此環境可用。
- **T2** `src/core/sparse_set.mojo` 在 Mojo 1.1 無法編譯,且與 dev 的 `ecs/sparse_set.mojo` 重複。
  改由 wasm 端的 differential oracle 參照 `ecs/`,然後刪除它。
  > **進度:✅ 2026-09-30** 已刪除。native oracle 改為 `experiments/wasm_mojo/native_oracle.mojo`(dev 的 `ecs.SparseSet`),
  > 由 `native_vs_wasm.py` 與 Mojo→wasm、C 替身比對;CI 的 best-effort Mojo 步驟改跑它。
- **T3** 分支整理:`experiment` 已於 2026-09-30 建立,從此作為本分支。
  舊的 `experimental/wasm`(停在 `b150fe4`,內容已包含在 `experiment` 中)由使用者在 GitHub 上刪除;
  本 session 刪除遠端分支會被拒絕(HTTP 403)。

---

## 依賴順序

```
H2 ──► H1 (無靜態指標後,回滾只需複製數值與 heap 狀態)
H2 ──► H3 (schema 不需處理指標型欄位)
H3 ──► W2
H5 ──► H6 (先能監看多個套件,才談拆多個 .so)
E1 gate(Mojo 輸出 LLVM IR) ──► W1 ──► W2
H4 獨立,可隨時做
```

## 明確不做(本輪)

- 在正式上線環境做熱更新(Erlang 式 release upgrade):目前只服務開發迴圈。
- 自動遷移任意 layout:調查的 14 個系統沒有一個做到;改走 H3 的 schema + 明確規則。
