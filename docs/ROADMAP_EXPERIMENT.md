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

### H5 熱編譯涵蓋 import 的套件

- **問題**:`dev_native.py` 只監看 `engine.mojo`。改了 `ecs/`、`geometry/` 要手動重新 precompile。
- **假說**:監看這些套件目錄,依相依順序只重建有變的套件,再重建 engine。
- **預測**:改 `ecs/sparse_set.mojo` 的一個函式 → host 換上新版;延遲 = 該套件 precompile + engine build。
- **量測**:e2e 加一輪修改 `ecs/`;記錄各段耗時。
- **Gate**:e2e 通過;延遲數字寫入 native README。

---

## Later

### H6 縮短編譯:拆成多個 `.so`

- **問題**:存檔 → 換上的 1.08 s 裡,0.98 s 是 `mojo build` 編整個 engine。
- **假說**:把 engine 的系統拆成幾個小 `.so`,只重編被改到的那個,延遲下降。
- **預測**:只改其中一個系統時,build 時間和該 `.so` 的程式碼量成比例,低於 0.5 s。
- **量測**:先量 `mojo build` 的固定開銷(編空檔案的時間)。
  若固定開銷本身就接近 1 s,這題的上限就很低,先記錄再決定是否繼續。
- **Gate**:有量測數據支持才實作。

### W1 真的 Mojo → wasm

- **前置**:Mojo 能輸出整個模組的 LLVM IR([STATUS.md](../STATUS.md) 的 gate)。
- **內容**:以 Mojo 核心取代 C 替身,重跑 wasm 端的 differential test 和 hot reload 矩陣。
- **預測**:GlobalOpt 拆 struct 的現象也會出現在 Mojo(同一套 LLVM pass),
  所以 link-map 指紋仍然需要。
- **Gate**:wasm 矩陣用 Mojo 核心全部符合預測。

### W2 把 H1–H3 套到 wasm

- **內容**:回滾、無靜態指標、schema 遷移,在 wasm host(JS)上實作並重跑矩陣。
- **Gate**:同 native。

### 函式層級熱修補(僅記錄,不排程)

- Live++ 和 Subsecond 只換函式,不換整個模組。這需要編譯器和 linker 支援,Mojo 目前沒有。
- 等 Mojo 工具鏈提供類似功能再評估。

---

## 工具鏈與雜項

- **T1** dev 的完整套件建置在本環境失敗:缺 `max`,`pip install modular==26.6.0` 依賴衝突。
  要嘛找出可行的 pip 組合,要嘛讓 pixi 在此環境可用。
- **T2** `src/core/sparse_set.mojo` 在 Mojo 1.1 無法編譯,且與 dev 的 `ecs/sparse_set.mojo` 重複。
  改由 wasm 端的 differential oracle 參照 `ecs/`,然後刪除它。
- **T3** 分支整理:舊的 `experimental/wasm` 由使用者在 GitHub 上刪除或封存。
  本 session 無法推送到指定分支以外的分支。

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
