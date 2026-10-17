# ROADMAP

> 本檔只放**原則、邊界、優先序與各子系統的現況和待辦**。已完成條目的完整紀錄(做了什麼、通過的 gate、
> 量到的數字、commit)與過時的規劃文字,原文保存在 [ROADMAP_HISTORY.md](ROADMAP_HISTORY.md),依原 Phase 順序排列。
>
> **編號是永久 ID**:程式碼、commit、`BENCHMARK_REPORT.md` 以「ROADMAP 17.24」這種形式引用,整理只改分組與順序,
> 不改編號,也不重用編號。任一編號在哪裡,查 [編號索引](#編號索引)。
>
> **狀態符號**:✅ 完成 · 🔶 部分完成 · ⬜ 未開始 · ⏸ gated(等決策)· 不排(保留,但目前不安排)。
> **Wave**:A = 低風險 table stakes,B = 中風險 / 差異化,C = 大工程或綁平台決策;是風險等級,不是時間順序。
>
> 依據:[SOTA_GAP_ANALYSIS.md](SOTA_GAP_ANALYSIS.md)(2026-07-10 差距分析)、[ARCHITECTURE.md](ARCHITECTURE.md)
> (分層、錯誤政策、測試分層)、[CATEGORY.md](CATEGORY.md)(seam 與 parity 對照)。

## 目前位置(2026-10-13)

- **物理與數值核心**:角動力學、sub-stepped soft solver、CCD、islands / sleeping / warm-start、軟體與雙向耦合、
  縮座標關節體(ABA / RNEA / 致動器 / 腱 / 感測器)、FEM / MPM / SPH / PBF / 布料、LBM 風洞、可微模擬
  (reverse tape、comptime 伴隨)皆已交付,各附 parity 測試與 benchmark 列。
- **遊戲執行期外殼(Phase 17)**:Wave A / B 全數交付;Wave C 已交付 17.4 載具、17.5 破壞,以及
  2026-10-12 的剩餘順序各項(見下)。
- **已決定的剩餘順序(2026-10-12)**:8 項中 6 項 ✅ —— 17.14 導航(`99fe1d9`)、17.15 AI(`7c4f4d6`)、
  17.16 rollback(`fdfba02`)、12.1 C-ABI(`4e3ef8c`)、17.21 Python 綁定 + 12.2(`9cedbb5`)、
  17.8 大世界座標(`ee946e8`)。其餘 2 項 🔶:
  - **17.85 分級模擬**:第一刀(逐 island tier 表、`TierPolicy` seam、`TieredScheduler`,`8e7edcb`);
    剩 ECS `Tier[N]` tag、`BroadPhase.update_moved`、軟體 / LBM / 粒子的 per-object period、n = 1e5 量測等。
  - **17.17 GPU articulation / narrowphase**:程式碼已交付(`98a69cb`)。`test_gpu_narrow` 的裝置半段
    已在 GPU 主機上跑過,box / capsule 的容差因此放寬到 5e-3(`94493c2`);`test_gpu_artic` 裝置半段與
    bench 裝置列的 GPU 實跑結果尚未記入 17.17 進度註。「GPU 剛體 + CPU 軟體同幀」未達成。
- **17.75 嵌入契約**:宿主派發器注入 ✅(`71cb718`);2026-10-13 補上 job graph / work-stealing 派發、`FrameArena.from_block`、非同步步進、`UnitScale`、契約成文。
- **gate**:依裝置而變的檢查以 `Suite.begin_device()` 分段,有無 GPU 的主機共用同一份 golden(`f5ca7df`);
  2026-10-13 起測試以固定編譯目標跑,另一台主機(無 GPU、AVX-512)上也逐段重現 golden。
- **剩餘順序進度(2026-10-13)**:第 1 步 17.19 滾動球錨點 ✅;第 2–4 步 17.81(🔶,待 GitHub 上首次 CI)/ 17.83(🔶)/ 17.82(✅);
  第 5 步 17.75(🔶,剩 actor 靜態策略與 box / capsule 尺度殘差)。跨機 golden 探針結論:測試一律以 `--target-cpu skylake` 編譯。
  下一步 17.76 平台可攜。見[剩餘順序](#剩餘順序2026-10-13-決定同日修訂gpu-延後)與[編號索引](#編號索引)。
- **平台方向已定為 C**:被宿主引擎嵌入的模擬函式庫,RL 平台次要(2026-10-09,`a93c53d`)。
- **2026-10-09 負空間盤點**:對照 SOTA 引擎找出「不在路線上」的能力,RL / 機器人以外全數入路線,
  成為 17.44–17.84,並擴充尚未開工的 17.14 / 17.15 / 17.16。同一次盤點發現 9.1、13.8 標 ✅ 但程式碼
  不符,已改為 🔶。
- **2026-10-10**:17.44–17.84 的本文依表格重寫並逐條對原始碼審查(13.5 因此由 ✅ 校正為 🔶);
  新增 17.85 分級模擬(設計筆記 `docs/design/17.85-tiered-simulation.md`)並排進剩餘順序。
- **2026-10-11 整理**:本檔改為依子系統分組;已完成條目的原文移到 ROADMAP_HISTORY.md;未完成條目
  逐條改寫為現況與待辦,原文同樣保存在歷史檔。

## 子系統

| 子系統 | 範圍 | ✅ | 🔶 | ⬜ | ⏸ / 不排 |
|---|---|--:|--:|--:|--:|
| [幾何代數與數值基礎](#幾何代數與數值基礎) | geometry、numerics、AD 係數場、exact predicates | 2 | 0 | 0 | 0 |
| [剛體動力學、接觸與關節](#剛體動力學接觸與關節) | physics:solver6、接觸、最大座標關節、islands / sleeping、材質 | 18 | 3 | 2 | 0 |
| [碰撞形狀、寬窄相與世界查詢](#碰撞形狀寬窄相與世界查詢) | collision、spatial | 9 | 4 | 2 | 0 |
| [縮座標關節體與致動](#縮座標關節體與致動) | chain(ABA / RNEA)、致動器、腱、感測器、統一約束 | 9 | 2 | 0 | 0 |
| [軟體、布料、連續體與流體](#軟體布料連續體與流體) | softbody、cloth、FEM / MPM / SPH / PBF、LBM、繩索 | 13 | 0 | 9 | 0 |
| [可微模擬、批次世界與數值深化](#可微模擬批次世界與數值深化) | diffsim、diffsolver、tape、批次、稀疏線代 | 5 | 1 | 1 | 1 |
| [GPU 計算](#gpu-計算) | GPU kernels 與單一 device context | 2 | 1 | 0 | 0 |
| [動畫與程序化](#動畫與程序化) | procedural:anim / IK / tween / spline / noise / FSM / PCG | 7 | 0 | 3 | 0 |
| [角色、載具、破壞與 gameplay 物理](#角色載具破壞與-gameplay-物理) | gameplay:character / ragdoll / vehicle / fracture / interpolation | 7 | 0 | 5 | 0 |
| [gameplay 服務、AI、導航與網路](#gameplay-服務ai導航與網路) | 規則框架、AI、導航、rollback | 3 | 0 | 3 | 0 |
| [ECS、排程、執行期與診斷](#ecs排程執行期與診斷) | ecs、scheduler、diag、runtime、存檔 / 回放 | 16 | 1 | 3 | 2 |
| [嵌入、腳本與平台](#嵌入腳本與平台) | C-ABI、Python 綁定、宿主整合、平台 | 3 | 2 | 1 | 0 |
| [工程、測試、效能與工具鏈](#工程測試效能與工具鏈) | gate、benchmark、CI、Mojo 版本搬遷、範例 | 9 | 2 | 0 | 0 |

## 原則與決策

### 架構法則
- **架構定律**(`CATEGORY.md` §2):可替換子系統藏在 trait 後面、編譯期選擇;任何新 seam 實作必附
  自然性方格(parity 測試),證明各實作的可觀察行為相同。
- **架構定律 v2**(2026-07-13):每個 seam 的**所有**變體同時要有 parity 測試與 `BENCHMARK_REPORT.md`
  對應列,缺一不收;每個效能主張附數字與 baseline。
- **架構定律 v3**(2026-08-11):每項交付接上真正會跑到的路徑(刻意不接者在檔頭寫理由),並附普通 /
  整合 / 極端三類案例。
- **不設「不做」欄**(no-tech-exclusion,2026-08-02):有優勢區、有對照組、可規模化比較的能力一律列入,
  成本高只排後面的 Wave。每項標【現況 / 缺口 / 對照組 / 優勢區 / 規模軸 / seam?】。
- **負面結論前先測優勢區**:任何「不值得做」的判定,先跑該方法在其理論優勢區的量測。
- 行為不變的重構以「全套測試 stdout 逐位相同(去除計時行)」為身分閘門(`pixi run gate`)。

### 平台方向 C(2026-10-09 決定)
- 本庫是**被宿主引擎嵌入的模擬函式庫**;RL 平台(方向 B)次要。
- 12.1 C-ABI 嵌入邊界宣告 **v0.x 凍結**;腳本層先做 **Python 綁定**(17.21),hot reload 之後再接。
  Python 綁定放在核心 repo 的最上層獨立套件,測試以客戶端方式安裝進乾淨環境(不用 `-I build`)。
- **網路**:傳輸層與線路格式交給宿主;本庫提供 rollback 核心、預測策略 seam 與 byte payload API(17.16)。
- **場景格式**跟宿主走(glTF / USD),不自訂(17.12,目前不排)。
- **決定論**只承諾同工具鏈、同架構;不做跨平台定點 / 軟浮點。

## 邊界與排除

- **不在本 repo**(架構分離,不是「不做」):渲染主體、音訊、輸入裝置、圖形化編輯器本體(視窗、gizmo、
  inspector / outliner 面板、節點圖 UI、資產瀏覽器、undo 歷史 UI、play-in-editor 外殼)。若要做,以獨立層 /
  repo 建在本庫的 headless API 之上。
- **使用者明令排除**:場景描述格式 MJCF / URDF、MJX、MJWarp(Phase 13,格式綁定先於技術);
  RL 與機器人專屬能力(2026-10-09 盤點時排除:Gym 式介面、物理參數域隨機化、感測器雜訊 / 延遲、
  LiDAR / 深度感測器、引擎內 NN 推論、抓取、運動規劃、狀態估計、ROS 2、FMI)。
- **否決的路線**:CGA 作為效能主線(自家量測慢約 4×;保留為 curved-primitive 查詢與交叉驗證);
  GPU-driven rendering(Nanite 級)。
- **判定為非缺口**(17.41「拒絕(5)」):時間縮放 / 暫停(呼叫端縮放 `frame_dt` 即可)、transform 階層傳播
  (已在 `ecs/hierarchy.mojo`)、gameplay 粒子(既有 solver 可承載)、查詢結果快取(持久化 DBVH 已在)、
  hot config / CVar(併入 17.21)。
- **已刪除**:舊 2D 物理路徑(2026-09-29,使用者決定;`CollisionPipeline` 保留給其測試)。
- **範圍界線**:SBVH 與 GPU 建樹不在 7.1 範圍內。

### 編輯器依賴的核心功能
外部編輯器(若日後以獨立層出現)要建在下列 headless API 上。判準:把編輯器拿掉,這項功能的價值還剩多少;
全部還在的屬引擎核心,不列在這裡。

| 編輯器需要的能力 | 核心提供者 | 狀態 |
|---|---|---|
| Inspector:按名稱列出 / 讀寫任意型別的欄位 | 17.11 `TypeSchema` / `TypeRegistry` | ✅(非純資料型別未在編譯期擋) |
| 場景 / prefab / 實例覆寫的**可編輯、可 diff 資產格式** | 17.12 | ⬜ **編輯器的最大缺口**(gating 已解:跟宿主格式;本輪不排) |
| 視窗疊圖 / gizmo 的繪圖來源(接觸點、AABB、island 顏色) | 17.9 `DrawQueue` | ✅ |
| 滑鼠點選物件(picking) | 17.13 raycast / shapecast | ✅ |
| 跨存讀穩定的物件身分(選取、參照不因重載失效) | 17.0g `BodyId` · ECS entity id · 3.3 relationships(階層 / outliner) | ✅ |
| 編輯即時反映(欄位變更推播給視圖) | 4.4 push-based observers | ✅ |
| Undo / redo | 17.43(建在 4.4 command buffer(結構變更)+ 17.11 schema 欄位值 diff 上) | 🔶 **零件在,交易 / 反向操作層未做** |
| Play-in-editor:進入播放、停止後還原 | 6.10 快照 / 17.40 存檔 | ✅ |
| 時間軸拖動 / 回看模擬 | 17.39 `seek` / `first_divergence` | ✅ |
| Profiler 面板 | 17.10 trace(Chrome trace 匯出)· 17.80(執行期追蹤開關、物理擷取檔與回看) | ✅(runtime 開關與擷取檔 → 17.80 ⬜) |
| Console / log 面板 | 17.32 分級日誌 | ✅ |
| Live 參數調校、CVar、hot-reload | 17.21 | ⬜ gating 已解(2026-10-09):先 Python 綁定,hot reload 後接 |
| 動畫圖 / BT / navmesh 的**節點圖存檔** | 17.6 · 17.15 · 17.14 → 皆經 17.12 的資產格式 | 17.6 ✅(僅程式碼定義)· 其餘 ⬜ |
| 曲線 / 路徑的控制點編輯 | 17.36 樣條(控制點資料模型) | ✅ |
| 資產匯入(glTF / USD) | 17.12 對照組所列 · 17.45 碰撞網格烘焙(焊接 / 修復 / 簡化、mesh → SDF)· 17.63 模擬快取 / 稀疏體積交換 | ⬜(同 17.12;平台方向 C 下為主要場景來源) |

擋住外部編輯器的是 **17.12 場景 / prefab 格式** 與 **17.43 undo 交易層**(兩者目前不排),其次是 17.21 的 live 調校。

## 優先序

### 已決定的剩餘順序(2026-10-09,2026-10-10 修訂)
1. 17.14 導航
2. 17.15 AI(EQS 接 17.13、BT tick 可入 10.2 job graph)
3. 17.85 分級模擬(2026-10-10 插入:rollback 的 relevance 集合與 `CausalReach` 是同一張圖,先有 tier plan
   再做 rollback,避免兩套興趣管理)
4. 17.16 rollback 核心 + 預測策略 seam + 給宿主傳送的 byte payload API
5. 12.1 C-ABI 嵌入邊界(世界建構 / 系統註冊 / 查詢 / 事件訂閱,v0.x 凍結)
6. 17.21 Python 綁定
7. 17.17 GPU articulation / narrowphase
8. 17.8 大世界座標(先 f32 + rebasing + partition,f64 只參數化)

**不排**:17.12 場景格式、17.43 undo 交易層(編輯器相關)。

上列 1、2、4、5、6、8 已 ✅(2026-10-12);3(17.85)與 7(17.17)🔶,剩餘併入下方順序。

### 剩餘順序(2026-10-13 決定;同日修訂:GPU 延後)
排序依據:各條目的「相依」欄;能解鎖最多下游者先做;同層內 Wave A 先於 B、C。原「17.44–17.84 的插入建議」
四點(17.81 CI 先做、平台方向 C 前提、9.1 / 13.8 承接者先於其他 Wave B、17.55 為連續體前提)皆已併入。
**GPU 相關一律延後到第 7 層**(使用者決定,2026-10-13):第 0–6 層的條目只交付 CPU 路徑;條目內的 GPU 子項
移到第 7 層,GPU 解算器遇到新模式時先明確拒絕(沿用現行 `gpu_contact` 拒絕 ccd / 輸送帶的做法)。

**第 0 層 已開工的收尾**
1. 17.19 滾動球錨點缺陷(17.50 相依欄:「須先修」)

**第 1 層 工程閘門**
2. 17.81 CI / 授權 / 發行(相依:無;17.76 / 17.78 / 17.82 / 17.83 依賴)
3. 17.83 效能治理(17.79 依賴;同時以 `pixi run benchmark` 重產報告,補 17.4 / 17.5 遺留的 vehicle / fracture 列)
4. 17.82 品質工具

**第 2 層 平台方向 C 前提**
5. 17.75 剩餘:配置器、非同步步進、`UnitScale`、執行緒契約(17.54 / 17.73 / 17.76 / 17.78 / 17.79 依賴)
6. 17.76 平台可攜

**第 3 層 Wave A,無未完成的硬相依**
7. 17.45 網格碰撞品質(下游 17.52 / 17.56 / 17.58 / 17.63 / 17.69)
8. 17.48 剛體參數 API(17.50 依賴;快照升版時一併補 17.29 / 17.31 / 17.4 / 17.5 / 17.2 遺留的快照欄位)
9. 17.49 力回報 / 衝擊事件(17.70 / 17.71 依賴)
10. 17.53 查詢擴充(17.67 / 17.68 / 17.71 依賴;含 17.13 遺留待辦;GPU 批次對真實形狀 → 第 7 層)

**第 4 層 承接 9.1 / 13.8 校正與碰撞管線**
11. 17.47 最大座標關節補完(17.66 / 17.74 依賴)
12. 17.51 縮座標完整化(17.66 依賴)
13. 17.52 形狀種類(需 17.45)
14. 17.44 複合形狀
15. 17.46 CCD 形狀覆蓋(需 17.52 的新種類 TOI)
16. 17.50 接觸模型變體(需 17.48 與第 1 項;GPU 路徑先拒絕新模式,與 CPU 對齊 → 第 7 層)
17. 17.54 CPU 碰撞管線(需 17.75;2.3 持久 DBVH 接入一併處理)

**第 5 層 其餘 Wave B**
18. 17.77 ECS 表達力(17.85 `Tier[N]` tag、17.70 依賴)
19. 17.85 剩餘(ECS tag、`BroadPhase.update_moved`、per-object period、n = 1e5 量測)
20. 17.80 觀測(GPU 時間軌 → 第 7 層)
21. 17.79 資源治理(需 17.83 / 17.75;GPU 記憶體上限與緩衝收縮 → 第 7 層)
22. 17.55 連續體步進契約(17.56 / 17.58 / 17.59 的前提)
23. 17.56 布料(網格版 GPU 求解與 GPU 自碰撞 → 第 7 層)
24. 17.64 動畫執行期(17.65 / 17.66 / 17.67 / 17.68 / 17.71 依賴)
25. 17.67 移動模式
26. 17.68 攝影機 / 序列
27. 17.71 戰鬥物理

**第 6 層 Wave C(CPU)**
28. 17.78 宿主整合 / 綁定
29. 17.84 數值 / 可微深化(連續體消費者在後;GPU 批次 → 第 7 層)
30. 17.58 體積軟體
31. 17.57 毛髮 / 肌肉
32. 17.59 流固耦合
33. 17.60 水面 / 網格流體
34. 17.63 輸出 / 快取
35. 17.61 多物理
36. 17.65 形變資料
37. 17.66 物理角色
38. 17.74 載具家族
39. 17.69 PCG
40. 17.70 規則框架
41. 17.72 流程服務
42. 17.73 營運邊界

**第 7 層 GPU(延後)**
43. 17.17 收尾:在 GPU 主機實跑 `test_gpu_artic` 裝置半段與 bench 裝置列並記入進度註(`test_gpu_narrow` 已跑過,
    `94493c2`);「GPU 剛體 + CPU 軟體同幀」
44. 第 0–6 層延後的 GPU 子項:17.50 GPU 摩擦模型對齊、17.53 GPU 批次查詢對真實形狀、17.56 網格版 GPU 求解與
    GPU 自碰撞、17.79 GPU 記憶體上限 / 緩衝收縮、17.80 GPU 時間軌
45. GPU 遺留待辦:17.42 GPU LBM(效能定位、動量交換歸約、LES、插值 bounce-back)、17.18 GPU 批次、6.1 GPU 軟體
46. 17.62 GPU / 可微連續體(需 17.56 / 17.58 / 17.59)

相依互指時的取捨:17.67 先於 17.66(先定外力 / 速度擁有權);17.59 先於 17.60。
**不排 / ⏸**:17.12、17.43(不排);13.9(⏸,等平台決策)。9.1 / 13.5 / 13.8 / 13.7 的剩餘已移至
17.47 / 17.50 / 17.51 / 17.52 與 17.20 / 17.84,不另排。

---

## 幾何代數與數值基礎

範圍:geometry、numerics、AD 係數場、exact predicates。

| 編號 | 條目 | 狀態 | Wave | 說明 |
|---|---|:-:|:-:|---|
| 10.1 | [Exact predicates / interval 穩健層(SOTA_GAP M3)](ROADMAP_HISTORY.md#101-exact-predicates--interval-穩健層sota_gap-m3--完成2026-08-11) | ✅ |  | `geometry/predicates.mojo` 提供三階段自適應(float32 濾波 → float64 濾波 → 精確展開)的 orient2d/orient3d/incircle/insphere,`convex_hull_2d` 的側判斷預設改走此層,naive 路徑保留為 `exact=False` seam 變體。 |
| 15.1 | [稀疏線性代數層(CG / PCG + 稀疏矩陣)](ROADMAP_HISTORY.md#151-稀疏線性代數層cg--pcg--稀疏矩陣--完成2026-08-11) | ✅ |  | numerics 套件提供 CsrMatrix、matrix-free LinearOperator、cg/pcg(Jacobi 預條件,Krylov 遞迴用 float64),並接上 FEM 的 matrix-free 隱式 backward Euler,有 36 checks 測試與 bench_numerics。 |

---

## 剛體動力學、接觸與關節

範圍:physics:solver6、接觸、最大座標關節、islands / sleeping、材質。

| 編號 | 條目 | 狀態 | Wave | 說明 |
|---|---|:-:|:-:|---|
| 1.2 | [Screw dynamics 接進 contact solver](ROADMAP_HISTORY.md#12-screw-dynamics-接進-contact-solver) | ✅ |  | `physics/rigid6.mojo` 有 `Inertia3` 與兩套 parity 剛體表示(`QuatBody6` 四元數 / `ScrewBody6` Motor3 + twist bivector),`physics/solver6.mojo` 以表示無關的 `Body6` trait 與 `ContactScene6[B]` 做接觸 Gauss-Seidel 求解,雙箱堆疊在兩種表示下 parity。 |
| 1.3 | [Lie-group / variational integrator seam](ROADMAP_HISTORY.md#13-lie-group--variational-integrator-seam) | ✅ |  | `physics/integrator6.mojo` 的 `SpinIntegrator` seam(pose 走閉式 motor exp)有 `EulerSpin`/`Rk2Spin`/`MidpointSpin`,後於 4.1 加入 `LgvciSpin`,`bench_rigid6` 同表比較能量/動量漂移。 |
| 2.1 | [Sub-stepped soft-constraint solver(Box2D v3 "Soft Step" / TGS 系)](ROADMAP_HISTORY.md#21-sub-stepped-soft-constraint-solverbox2d-v3-soft-step--tgs-系) | ✅ |  | `ContactScene6.step_soft` 實作 Box2D v3 子步結構(warm start、soft 掃、relax、Coulomb 摩擦、body-frame anchors),搭配 `box_box_manifold` 3D 旋轉箱接觸,6 箱塔 1000 步站穩、100:1 質量比不壓爆。 |
| 2.2 | [Joints 最小集 + islands + sleeping + warm-starting](ROADMAP_HISTORY.md#22-joints-最小集--islands--sleeping--warm-starting) | ✅ |  | `Joint6`(ball / distance / hinge)進入 soft substep 迴圈並與接觸共用 warm start / relax,union-find islands 與能量閾值全島休眠/喚醒為確定性。 |
| 4.1 | [物理保真度:swept/TOI CCD + LGVCI](ROADMAP_HISTORY.md#41-物理保真度swepttoi-ccd--lgvci) | ✅ |  | OBB 對 OBB 的精確 15 軸 swept SAT TOI 與 substep CCD 推進已完成(50 m/s 子彈零過衝,114 ns/pair);Moser–Veselov LGVCI 是 SpinIntegrator 的第四個實作(183 ns/step,1e5 步 E 1.3e-4)。 |
| 6.2 | [Restitution(彈性碰撞)](ROADMAP_HISTORY.md#62-restitution彈性碰撞--readmehonest-status第一洞) | ✅ |  | Box2D v3 式恢復係數:prep 擷取逐點 vn0,子步後專屬 `_restitution_pass`(門檻 1 m/s、目標 vn=−e·vn0),`set_restitution` 逐體設定、pair 取 max。 |
| 6.3 | [Sphere / Capsule 形狀入 solver(脫離 box-only)](ROADMAP_HISTORY.md#63-sphere--capsule-形狀入-solver脫離-box-only) | ✅ |  | `collision/manifold.mojo` 新增 sphere/capsule 相關形狀對 manifold,ContactScene6 以 shape kind 派發,錨點、warm-start、摩擦、restitution、睡眠全形狀通用。 |
| 6.5 | [Islands 平行化(多執行緒 solver)](ROADMAP_HISTORY.md#65-islands-平行化多執行緒-solver) | ✅ |  | step_soft(parallel=True) 依 island 重排 pairs/joints,_solve_island 以 parallelize fan-out 各島整個子步迴圈,平行與串行 bit-identical,16 島 1.52×(單大島反慢 1.37×)。 |
| 6.11 | [島內著色平行(單大島的約束圖著色)](ROADMAP_HISTORY.md#611-島內著色平行單大島的約束圖著色) | ✅ |  | step_soft 的 colored 模式以貪婪著色(靜態體不入鄰接)把 pairs 排成色段,色內 parallelize、色間順序,排程決定且串行==平行逐位相同,120 盒單島平行 1.66×、iters=8 品質對齊行 1.21×。 |
| 9.1 | [關節庫深度(limits / motors / springs / prismatic / weld / cone-twist)](#91-關節庫深度limits--motors--springs--prismatic--weld--cone-twist) | 🔶 |  | 已有縮座標 revolute / prismatic 與上下限(physics/chain.mojo resolve_limits)、最大座標 weld(17.5)與 AngularDrive 姿態驅動(17.2);Joint6 仍沒有上下限、速度馬達、彈簧、滑軌、cone-twist,縮座標也沒有球關節 / 多自由度關節。 |
| 9.4 | [接觸事件(began / stay / ended)](ROADMAP_HISTORY.md#94-接觸事件began--stay--ended--完成2026-08-11) | ✅ |  | `events_on` 開啟時每步以排序合併差分本步與上步接觸集(鍵為 (a,b,feat) 打包的 Int)產生 began/stay/ended 事件,含 sensor 重疊,事件流在 brute 與寬相 seam 上逐位相同,開啟成本 <3%。 |
| 17.19 | [生產級 solver 硬化](#1719-生產級-solver-硬化) | 🔶 | B | F22 第一批已把 island 喚醒 / 入睡與 warm-start 快取比對改成線性(N=4096 簿記 82 → 20.6 ms/幀),但高質量比、大 island、接觸密集堆疊等壓力測試尚未做;滾動球的錨點缺陷已修(2026-10-13:球 / 膠囊維持解析滾動速度、不再下沉,`test_rolling_sphere`)。 |
| 17.23 | [物理材質與逐對組合模式](ROADMAP_HISTORY.md#1723-物理材質與逐對組合模式--wave-a) | ✅ | A | physics/material.mojo 提供四種組合模式(average/min/multiply/max,較高優先模式勝),BodySet 存逐 body 的 friction 與兩種組合模式,solver6 每對接觸算一次 pair_mu 與組合後的 restitution,並有 parity 測試與 bench(四模式成本在雜訊範圍內)。 |
| 17.24 | [Kinematic 剛體型別(通用可移動體)](ROADMAP_HISTORY.md#1724-kinematic-剛體型別通用可移動體--wave-a) | ✅ | A | solver6 支援 static/dynamic/kinematic 三種運動型別:kinematic 由腳本設定速度或用 move_to 指定目標位姿、會推動動態體,也會喚醒已入睡的動態體;零速度時與 static 逐位 parity,序列化格式升到 v2。 |
| 17.25 | [睡眠/喚醒生命週期公開 API](ROADMAP_HISTORY.md#1725-睡眠喚醒生命週期公開-api--wave-a) | ✅ | A | ContactScene6 提供公開的 is_sleeping、wake(整島喚醒)、set_can_sleep 與 teleport(瞬移、喚醒並清掉 warm-start 快取),無效 id 會 raise;本項不是新 seam,所以 CATEGORY 沒有對應列。 |
| 17.26 | [接觸修改 / 單向平台](ROADMAP_HISTORY.md#1726-接觸修改--單向平台--wave-b) | ✅ | B | physics/contact6.mojo 用資料驅動的 ContactRule(不是 callback)提供 RULE_ONE_WAY 單向平台、RULE_CONVEYOR 輸送帶表面速度與 RULE_FRICTION 逐接觸摩擦覆寫,由 ContactScene6.add_contact_rule 註冊,並有 seam parity 測試(規則不匹配時與無規則逐位相同)。 |
| 17.29 | [通用可斷裂關節](ROADMAP_HISTORY.md#1729-通用可斷裂關節--wave-b) | ✅ | B | ContactScene6.set_joint_break(j, force, torque) 對所有 Joint6 種類提供力 / 力矩閾值,有閾值時每子步取峰值負載(joints6.sample_loads)、步末 check_breaks 轉為 JOINT_BROKEN,斷裂事件經 scheduler.events.Channel 送達。 |
| 17.31 | [物理 LOD / 模擬預算調度](ROADMAP_HISTORY.md#1731-物理-lod--模擬預算調度--wave-b) | ✅ | B | ContactScene6.freeze / unfreeze 以暫時切成 STATIC 並保留速度實作凍結,physics/lod.mojo 提供 DistanceLOD(距離 + 遲滯)與 SimBudget(依量測步進時間調 iters 再調 substeps),全場 LOD + 天花板預算與原解算器逐位相同。 |
| 17.44 | [複合形狀](#1744-複合形狀--wave-b) | ✅ | B | 一 body 多形狀、質量性質聚合、配對分派、廣域 / 中域、快照 / 槽位 |
| 17.47 | [關節庫補完(最大座標)](#1747-關節庫補完最大座標--wave-b承-91) | ✅ | B | 限制、馬達、彈簧、新種類、`collide_connected` 開關 |
| 17.48 | [剛體參數 API](#1748-剛體參數-api--wave-a) | ✅ | A | 質量性質、阻尼、`gravity_scale`、軸鎖、速度上限、持續力 / 力矩累加器 |
| 17.49 | [力回報 / 衝擊事件](#1749-力回報--衝擊事件--wave-a) | ✅ | A | 接觸事件 payload、整步衝量估計器、查詢 API、逐 body 事件旗標 |
| 17.50 | [接觸模型變體](#1750-接觸模型變體--wave-b) | ✅ | B | 橢圓摩擦錐、滾動 / 扭轉摩擦、靜 / 動摩擦、逐材質 / 逐 body 接觸柔度、塊求解、黏附 / 吸附(CPU ✅;GPU 對齊屬第 7 層) |

### 已完成條目的遺留待辦

這些條目已完成並移到歷史檔,但各自記下了尚未做的部分:

- **1.3**([紀錄](ROADMAP_HISTORY.md#13-lie-group--variational-integrator-seam)):驗收 gate 要求 Dzhanibekov 10⁶ 步能量漂移曲線、三種 integrator 同圖;已量到的是 20k 步(test)與 1e5 步(bench)的單點漂移數字,未見 10⁶ 步或漂移曲線。
- **2.1**([紀錄](ROADMAP_HISTORY.md#21-sub-stepped-soft-constraint-solverbox2d-v3-soft-step--tgs-系)):驗收 gate 要求 10 箱塔 1000 步不倒;實際只驗到 6 箱塔(17.19 現況欄亦記「穩定堆疊只驗到 6 箱塔」,更大堆疊轉入 17.19 生產級 solver 硬化)。
- **2.1**([紀錄](ROADMAP_HISTORY.md#21-sub-stepped-soft-constraint-solverbox2d-v3-soft-step--tgs-系)):long-chain 場景 benchmark 未見交付。
- **2.1**([紀錄](ROADMAP_HISTORY.md#21-sub-stepped-soft-constraint-solverbox2d-v3-soft-step--tgs-系)):「四個 solver 同表對照(對齊 Solver2D 比較法)」的 benchmark 未見交付。
- **2.2**([紀錄](ROADMAP_HISTORY.md#22-joints-最小集--islands--sleeping--warm-starting)):驗收 gate 的雙擺週期 vs 解析解未在 2.2 進度註中報告(只有單擺 ball/distance 擺);後來 chain 路徑才有混沌雙擺能量漂移(見 reduced-coord chain 進度註),但不是 Joint6 的週期測。
- **2.2**([紀錄](ROADMAP_HISTORY.md#22-joints-最小集--islands--sleeping--warm-starting)):「warm-start 前後收斂迭代數 benchmark」未見交付(benchmarks/ 無此比較)。
- **4.1**([紀錄](ROADMAP_HISTORY.md#41-物理保真度swepttoi-ccd--lgvci)):Gate 原文要求「Dzhanibekov 10⁶ 步、四個 integrator 的能量漂移曲線同圖」;進度只記錄 test_integrator6 的 20k 步與 bench_rigid6 的 1e5 步漂移表,沒有記錄 10⁶ 步曲線的交付
- **6.3**([紀錄](ROADMAP_HISTORY.md#63-sphere--capsule-形狀入-solver脫離-box-only)):剛體 swept TOI 仍只有 OBB 掃掠(`swept_box_toi`);ccd=True 場景混用形狀需注意(physics/ccd6.mojo:75-77 另對 hull/trimesh/heightfield 直接跳過 CCD)
- **6.5**([紀錄](ROADMAP_HISTORY.md#65-islands-平行化多執行緒-solver)):soft bodies 或 ccd=True 時退回串行(island 平行不涵蓋)
- **6.5**([紀錄](ROADMAP_HISTORY.md#65-islands-平行化多執行緒-solver)):誠實行:單大島平行反慢 1.37×(執行緒開銷無可攤提)
- **6.11**([紀錄](ROADMAP_HISTORY.md#611-島內著色平行單大島的約束圖著色)):誠實行:21 盒 fan-out 場景 colored 反慢 1.78×;iters=4 時 colored 會讓島永不入睡,需 iters≥8 或改用平凡 GS(使用指引,非待辦程式工作)
- **17.26**([紀錄](ROADMAP_HISTORY.md#1726-接觸修改--單向平台--wave-b)):角色控制器(走世界查詢,不經接觸)尚未套用單向平台規則。
- **17.26**([紀錄](ROADMAP_HISTORY.md#1726-接觸修改--單向平台--wave-b)):可微規則(對相對速度的次梯度,供 17.20 學習式規則)未做。
- **17.26**([紀錄](ROADMAP_HISTORY.md#1726-接觸修改--單向平台--wave-b)):GPU 解算器不支援 RULE_CONVEYOR(會拒絕輸送帶規則),只支援摩擦覆寫。
- **17.29**([紀錄](ROADMAP_HISTORY.md#1729-通用可斷裂關節--wave-b)):~~斷裂閾值寫入快照~~ ✅ 2026-10-13 隨 17.48 的快照 format 4 完成(`write_state` 的 `any_break` 區塊;`test_fracture` case_snapshot 驗證)
- **17.29**([紀錄](ROADMAP_HISTORY.md#1729-通用可斷裂關節--wave-b)):島平行路徑內取樣(現在有閾值時島平行路徑退回串行)
- **17.31**([紀錄](ROADMAP_HISTORY.md#1731-物理-lod--模擬預算調度--wave-b)):凍結狀態(BodySet.frozen_motion)寫入快照(physics/serialize.mojo、state_io.mojo 目前無此欄位)
- **17.31**([紀錄](ROADMAP_HISTORY.md#1731-物理-lod--模擬預算調度--wave-b)):逐 island 的品質分級 —— 2026-10-12 由 17.85 的 tier 表交付(`ContactScene6.set_tier_table`)。

### 待辦與部分完成條目

#### 9.1 關節庫深度(limits / motors / springs / prismatic / weld / cone-twist)

> **狀態**:🔶 部分完成(縮座標 revolute / prismatic + 上下限、最大座標 weld 已有;最大座標的限制 / 馬達 / 彈簧 / 滑軌 / cone-twist 與縮座標多自由度關節未做,剩餘移至 17.47 / 17.51)
> **狀態校正(2026-10-09,負空間盤點)**:原標 ✅,但程式碼只交付了一部分。
> **已有**:
> - 縮座標:`physics/chain.mojo:96-97`(`JOINT_REVOLUTE` / `JOINT_PRISMATIC`)、`:108-109,130-139`(`lo` / `hi` 與 `limited()`)、`:785` `resolve_limits`(測試 `tests/test_joints_lib.mojo`)。
> - 最大座標 weld:來自 17.5(`physics/joints6.mojo:18` `JOINT_WELD`)。
> - 17.2 的 `AngularDrive`(`joints6.mojo:279`):姿態驅動 + `max_torque`,**不是**速度馬達。
> **未做**:
> - `Joint6`(`joints6.mojo:14-18` 只有 BALL / DISTANCE / HINGE / BROKEN / WELD)沒有上下限、速度馬達、彈簧、滑軌、cone-twist。`joints6.mojo` 與 `chain.mojo` grep `cone|twist|swing|spring` 只命中註解(`joints6.mojo:24` 寫明「no cone clamp」),沒有對應的欄位或關節型別。
> - 縮座標沒有球關節 / 多自由度關節(Phase 13 開頭「關節型別只有 revolute」的缺口,在球關節這部分仍在)。
> **剩餘工作去向**:最大座標部分 → **17.47**;縮座標多自由度關節 → **17.51**。
> **設計**:hinge / prismatic 加上下限(單邊不等式,錐外投影)、馬達(目標速度 + 力矩上限)、軟約束彈簧(復用 soft coefficient)、weld(6-DOF 剛接)、cone-twist(ragdoll 肩髖);全部走既有 soft substep sweep,warm-start 累積器擴充。
> **交付物**:`test_joints_ext`(限制擋停解析角、馬達達速、彈簧頻率、weld 剛度、**能量不注入**)+ bench row(關節種類 × 迭代)。
> **相依**:9.2 浮動基座 ragdoll 需 cone-twist。
> **歷史**:原「現況」寫「`Joint6` 僅 ball / distance / hinge **等式約束**;無限制/馬達/彈簧/滑軌/焊接」。其中焊接(weld)後來由 17.5 交付(見上)。

#### 17.19 生產級 solver 硬化

> **狀態**:🔶 部分完成(Wave B 持續工項;F22 第一批 ✅ 2026-09-29;滾動球錨點缺陷 ✅ 2026-10-13;靜止堆疊週期性踢動 ✅ 2026-10-13;壓力測試案例尚未處理)
> **進度註(2026-10-13,靜止堆疊踢動)**:ARM runner 上 `test_impact_report` 的 3 箱堆疊頂箱側向接觸力 1.24 N(x86 單步 0.0014 N)。
> 追查(x86 600 步探針):堆疊靜止後側向擾動累積,第 180 步踢動 2.05 N、ω 0.02。兩個原因:
> (1)暖啟動以索引對應接觸點,`box_box_manifold` 同四角每步順序不同,摩擦衝量交給錯的角 → 改為同 pair 內以 body a 局部錨點最近者對應(限 5 cm 內),沒有近點的沿用同索引舊點(`physics/contact6.mojo` `make_contact`;世界座標最近點強配曾讓 8 m/s 滑過 80 格網格的盒子在接縫彈起 |vy| 0.023,`test_active_edges` 上限 0.01;遠點改冷啟動則讓子彈撞牆反彈由 2.39 升到 3.52 m/s,`test_ccd6` 上限 3);
> (2)盒對盒 8 個裁切點深度相差 1e-7,「取最深 4 點」可能留兩點在同一角、漏掉另一角;改用 `spread4`(由 `collision/hull.mojo` 移到 `collision/manifold.mojo`),
> 且深度在最大值 1e-5 內時從離質心最遠的點起算(近平行的入射邊可在邊中段被裁切,從那點起算會漏角)。
> 量測:3 箱 60 s 最大 |ω| 0.11 → 5.8e-6;步 120–600 頂箱最大側向力 2.61 N → 5.8e-5 N;10 箱 30 s 頂箱水平漂移 3 mm。`test_impact_report` 新增 8 s 靜止檢查(24/24)。
> **現況**:穩定堆疊只驗到 6 箱塔(`tests/test_softstep6.mojo`);大 island / 高質量比 / 接觸密集堆疊未系統測試(17.17 的 `tests/test_gpu_contact.mojo` 有 10:1 質量比與 400 箱場,但那是 GPU/CPU parity,不是穩定性壓力測試)。
> **缺口**:高質量比(1:1000)、長鏈受載、單 island 數千體、接觸密集堆疊(碎石 / 骨牌)、warm-start 接觸點 feature-ID 穩定性、contact reduction。
> **對照組**:Jolt(Horizon FW 實戰)、Box2D v3 Soft Step、TGS Soft、AVBD 堆疊 demo。
> **優勢區**:中 —— sub-stepped soft(2.1)+ 著色平行(6.11)+ 變分積分子(4.1b)已是對的地基;缺的是壓力測試 + 調參。
> **規模軸**:body / contact 數 vs 穿透 / 發散;iters vs 殘差(已有量測設計:對齊睡眠)。
> **seam?**:否,不新增 seam —— 對既有 solver6 補極端案例覆蓋(定律 v3 §4)+ 擴大 `bench_solver_scale` / `bench_islands` 的規模軸。
> **交付**:普通(現有)/ 整合(高質量比 + island sleep + CCD 同場景)/ 極端(1:1e4 質量比、1e4 體單 island、瞬移入堆、零質量、退化接觸)。
>
> **發現(2026-09-29,`test_diffsolver`)—— 已修(2026-10-13,見下方進度)**:球在地面滑行後於 t = 2v0/(7μg) 正確進入 5/7·v0 的滾動,但之後持續減速(v0=3、μ=0.5:1.5 s 時 1.80、4 s 時 1.57),ω·r 高於 vx,並下沉約 7 mm。`ContactScene6` 與可微解算器逐幀一致,所以問題在正式解算器本身:body-frame 接觸錨點隨滾動的球旋轉,摩擦與分離量取在偏離真實接觸點的位置。修法候選:圓形 shape 每子步重新投影錨點到接觸點,或摩擦改在 manifold 點求相對速度。
>
> **進度 F22 第一批 ✅(2026-09-29)**:`islands.refresh_islands` 的整島喚醒與 `update_sleep` 的整島入睡改為兩趟 O(n)(先標 label 再套用);warm-start 比對改為每幀建一次 `(a,b,feat)` → 首位索引的 `Dict`(`contact6.cache_index`,從第一個鍵相符處續掃,保留原本「第一個相符」規則)。身分閘門 148/148 golden 逐節相同。`bench_gpu_contact`(寬相開):N=4096 CPU 簿記 82 → 20.6 ms/幀、GPU 整幀 84.5 → 23 ms、CPU 串行整幀 152 → 82 ms;N=1024 簿記 6.8 → 2.2 ms。
>
> **進度 滾動球錨點 ✅(2026-10-13)**:兩個原因,各自量到。(1)球 / 膠囊的錨點改為「核心點(球心 / 膠囊線段上的最近點,
> body frame)+ 世界座標偏移」(`ContactConstraint.oa / ob`,`contact6.round_core` / `anchor_world`),偏移不隨 body 轉;
> 其他形狀仍是 body-frame 錨點,算式逐位不變。只修這點時速度不再衰減(1.5 s 與 4 s 皆 2.066),但 ω·r = 2.187 ≠ vx。
> (2)球對盒的 manifold 點在膨脹 margin/2 的面上,離球面 2.75 cm,摩擦力臂 0.4725 而非 0.5;`make_contact` 把圓形側的點沿法向
> 移到其表面(兩個都圓則取兩表面中點;兩錨點一起移,分離量不變)。可微解算器(17.20)同步改為球心 + 世界偏移、平面接觸點取球面,
> `test_diffsolver` 26/26(原「rolling resistance present」改為「保持 5/7 v0」)。GPU 解算器上傳時把偏移折回 frame 起點的 body-frame
> 錨點(子步內仍是舊行為;GPU 的同等修正隨 GPU 延後,剩餘順序第 7 層)。
> 新測試 `test_rolling_sphere` 11/11,修前修後同一程式:
> v0=3、μ=0.5 的球 vx(1.5 s) 1.8054 → 2.1428554、vx(4 s) 1.5710 → 2.1428554(解析 5/7·v0 = 2.1428571);ω·r 1.6657 → 2.1428554;
> 球心高度 0.49543 → 0.49972(r = 0.5);只有自旋 ω0 = 8 的球 vx 1.1971 → 1.1428576(解析 2/7·ω0·r = 1.1428571);
> 橫躺膠囊繞自身軸滾 vx 2.033897(解析 v0/(1 + I/(m r²)) = 2.0338984);球在 1000 kg 動態板上相對滾動 ω·r == 相對 vx(2.1428573)。
>
> **進度 壓力測試(2026-10-13)**:`tests/test_solver_stress.mojo` 7/7。重壓輕(1 kg 箱上壓 M kg,5 s):重疊量服從軟接觸下垂律 M g / (m_eff ω²)
> (軟接觸 = 勁度 m_eff ω² 的彈簧,ω = 2π·30):1:100 量 0.0295 m、律 0.0276;1:1000 量 0.275、律 0.276 → 輕箱被壓入地板(0.25);1:1e4 有限。子步 4 → 16、
> 迭代 4 → 16 皆不改變(量);全域 hertz 60 / 120 → 重疊 0.110 / 0.044,240 以上重箱直接穿過(0.5)。現況以斷言鎖住,修法(依負載的接觸勁度、質量分割)待做。
> 20 節球關節鏈吊 100 kg(100:1):伸長 11.7 %。1000 箱單 island 方塊 300 步:最低中心 0.2461、全數入睡;60 張骨牌全倒;瞬移 10 cm 入 6 箱堆:最大速度 0.33 m/s、
> 1 s 內推出 0.499;兩箱同點:分開 0.4997。
> **待辦**:
> - 簿記仍略超線性(N ×4 → ×9),剩餘熱點待量:著色重排 O(色數 × 對數)、每幀重建 BVH、CCD 全對。
> - 重壓輕 ≥ 1:1000 的接觸(依負載的勁度或質量分割)、受載長鏈伸長、warm-start feature-ID 穩定性、contact reduction、高質量比 + 睡眠 + CCD 同場景。
>
> **歷史**:
> - 量測(2026-09-29,`bench_gpu_contact`,F22 修正前):寬相開啟後,N=4096 箱每幀 CPU 收集 + 簿記(不含求解)達 82 ms,N 每 ×4 成長約 ×12 —— `refresh_islands` 與 `update_sleep` 的 island 喚醒 / 入睡迴圈為 O(n²),warm-start 對快取的線性比對為 O(pairs × cache)(審計 F22)。這是 GPU 與 CPU 路徑共同的瓶頸,因此排為本項第一個工作(已由上面的 F22 第一批處理)。

#### 17.44 複合形狀 — Wave B

> **狀態**:✅ 完成(2026-10-14:一 body 多凸子形狀、質量性質聚合 + 主軸、配對 / 網格 / SDF 分派、查詢、軟體粒子、快照、槽位、圓形子形狀滾動錨點、`FractureSet` 凹零件走複合;CCD 見 17.46;GPU 屬 17.17)。
> **進度註(2026-10-13)**:
> - **分派重構**:`ShapeDesc`(kind、`half`、hull 列)取代以 collider 索引讀形狀;`pair_manifold` → `shape_pair(ShapeDesc, Pose3, ShapeDesc, Pose3)`,
>   `as_hull` / `hull_faces` / `ellipsoid_pair` 等皆有 `_d` 版;網格與 SDF 配對拆成逐形狀函式(`_mesh_pair_kid`、`_sdf_pair_kid`)。既有 golden 各段不變。
> - **資料**:`SHAPE_COMPOUND = 8`;`CompoundSpec`(box / sphere / capsule / ellipsoid / hull 子形狀 + 局部位姿)、`ColliderSet.kid_desc / kid_pos / kid_rot`,
>   `half` 為子形狀包圍盒的聯集;子形狀上限 1024。`ContactScene6.add_compound(b, spec, density, is_static)`。
> - **質量**:`physics/mass_props.mojo`:各子形狀質量 / 質心 / 張量(hull 以面扇形四面體積分),轉到父框(R I Rᵀ)、平行軸移到總質心、求和,
>   `geometry.mat3.sym_eigen3`(Jacobi)取主軸;body 原點移到質心、軸對齊主軸,子形狀重新表示(世界位置不變)。
> - **配對**:複合對凸形 = 子形狀對迴圈,先以子盒(各長半個 margin)剔除,再走 `shape_pair`;feat = 1 + 子 i × 1024 + 子 j。
>   對網格:逐子形狀 `_mesh_pair_kid`,feat = 子 << 16 | 三角形(三角形 < 2¹⁶);對 SDF:逐子形狀,feat = 1 + 子。
> - **查詢 / 軟體**:`ColliderSet.kid_probe`(子形狀的 support,GJK 外、EPA 內)、`compound_probe`(取最近子);`point_distance`、射線(聯集距離的 sphere tracing)、
>   `shape_distance` / `shape_cast` / `closest_points`(子形狀對)、`soft_particle_contact`。
> - **快照**:每個子形狀的 kind / 尺寸 / 局部位姿 / hull 頂點。
> - 量測(`tests/test_compound.mojo` 18/18):盒 + 球的總質量 73.51033(手算 73.510322)、質心 (0.22792937, 0.13675761)(手算 0.22792936, 0.13675762)、
>   主慣量 1.3993801 / 9.605963 / 10.202511 對手算張量(含積 −2.735)特徵值 1.3993802 / 9.605963 / 10.202511;L 形靜置最低角 y −0.00017;
>   單一子形狀與一般盒 120 步逐位相同;兩半盒 y 0.24985 對整盒 0.24959(8 對 4 個軟接觸點,皆在穿透 slop 0.005 內);4 個 L 堆疊 brute == BVH 逐位;
>   快照還原逐位相同;移除後槽位重用無殘留;射線 t 2.1 / 2.5、點距 0.5099(皆解析值);1000 球子形狀可建且靜止。
> - bench `bench_compound`(N 個立方體排成的棒):複合 44 / 96 / 469 / 1881 µs/步,焊接 77 / 163 / 689 / 2616 µs/步(N = 2 / 4 / 16 / 64),
>   焊接兩端相對漂移 1.8e-8 – 2.5e-8 m、複合為 0。

> **現況**:`ColliderSet` 的一個 collider 就是一個形狀,且 collider `i` ≡ body `i`(`collision/collider_set.mojo:13-14,75-107`);形狀種類只有 6 種(`:37-42`),`half` 是單一盒、hull 是單一頂點表(`:78-81`)。沒有「一個 body 掛多個形狀」的欄位,也沒有形狀相對 body 的局部位姿:盒 / 球 / 膠囊固定在 body 原點,hull 只能把偏移烤進頂點。grep `compound|child.?shape|sub.?shape|multi.?shape|shape_offset|local_pose|local_offset`(`physics collision gameplay geometry`)只命中 `geometry/polytope.mojo:373` 的英文動詞 compound,零命中於真實功能。
> 質量性質寫死「body 原點 = 質心、慣量 = 主軸對角」:`Inertia3` 只有 mass + 三個主軸矩(`physics/rigid6.mojo:45-52`),`Body6` 只有讀取 `get_inertia`(`:154`),沒有質心偏移,也沒有完整張量。`Polytope.inertia_diag` 自述「products of inertia are dropped: TODO rotate to the principal frame」(`geometry/polytope.mojo:168-173`);grep `eigen`(`geometry numerics physics`)零命中,沒有 3×3 對稱特徵分解。
> 現行替代路線是「多 body + 焊接」:17.5 把凹體凸分解成多個 hull 剛體,以 `JOINT_WELD` 連接,零件間的焊接由 `FractureSet.bond_overlapping` 以 AABB + GJK 找出,O(n²)(`physics/fracture.mojo:305-321`);被焊接的兩體互不碰撞(`physics/solver6.mojo:721-731`)。碎片以自身質心重設 body 原點、慣量只取對角(`physics/fracture.mojo:178-191`)。Ragdoll 也是每骨一個盒(`gameplay/ragdoll.mojo:68-70`)。
> hull 面表上限 30 面、建構 O(V³)(`collision/hull.mojo:131-133,161`),所以複合體的子 hull 本來就需要分解成小頂點數。接觸鍵 `pack_key(a, b, feat)` 的 `feat` 只有 21 位元(`collision/contact_events.mojo:34-37`),warm start 與事件都靠它區分同一對 body 的多個接觸。
> **缺口**:
> - **一 body 多形狀**:`ColliderSet` 增子形狀表(kind + 局部 `Pose3` + 該 kind 的參數),盒 / 球 / 膠囊 / hull 皆可為子形狀(例:車體 = 底盤盒 + 四個膠囊輪罩;桌子 = 一面盒 + 四根腳)。
> - **質量性質聚合**:由子形狀 + 密度(或指定總質量)算出質心、完整慣量張量(平行軸定理),**轉到主軸**(Jacobi 對稱特徵分解),把 body 原點移到質心、body 框轉到主軸(例:L 形桿的質心偏離幾何中心,舊 API 下施力點會算錯)。同時補上 17.5 待辦「慣量轉主軸」。
> - **配對分派**:複合 vs 任意形狀 = 子形狀對的 `pair_manifold` 迴圈,先以子 AABB 剔除;`feat` 打包 (子 i, 子 j)(各約 10 位元)後 warm start 與事件不需改。
> - **廣域 / 中域**:整體 `half` 由子形狀聯集算出(保守盒),`fat_aabb` 不變;sensor、過濾、`world_query` 的射線 / 掃掠 / 最近點對子形狀取最小。
> - **快照 / 槽位**:快照帶子形狀表(hull 已有同樣規則,`physics/solver6.mojo:1410-1552`),`remove_body` 後槽位重用要整列覆寫(`collision/collider_set.mojo:123-159` 的 `at` 規則)。
> **對照組**:Bullet `btCompoundShape`、PhysX 一個 actor 掛多個 `PxShape`、Jolt `StaticCompoundShape` / `MutableCompoundShape`、Box2D v3 一個 body 多個 shape、UE `FKAggregateGeom`、Unity 子物件 collider;質量側 PhysX `PxRigidBodyExt::updateMassAndInertia`、Jolt `MassProperties`。內部對照組 = 17.5 的「多 body + 焊接」。
> **優勢區**:單 body 複合對焊接多 body:焊接路線每個零件一個 body、每條焊接 6 列約束(`physics/joints6.mojo:215-248`),複合只有一個 body、零關節殘差;子形狀數 N 越大、越不需要斷裂的剛性凹體(車體、家具、載具、角色膠囊群)優勢越明顯。反向:需要斷裂的物件仍走 `FractureSet` 焊接,兩者並存而非取代。
> **規模軸**:子形狀數 N ∈ {1, 4, 16, 64} × 複合體數量 × 接觸密度;單 body 複合 vs N 個焊接 body 的每步成本與靜置抖動(焊接路線帶關節殘差)。
> **seam?**:是 —— 「多部件剛體的表示」:(a) 單 body 複合、(b) N body + `JOINT_WELD`(17.5 路線)、(c) 子形狀聯集恰為凸集時退化為單一 hull。parity:(a) 對 (c) 以兩個半盒拼成一個盒,法向、深度、靜置高度相等;(a) 對 (b) 以同一 L 形體從同高度落到地面 / 斜面 / 箱堆,質心軌跡與靜置姿態在誤差界內(界寫進測試,容許焊接殘差)。bench:N × 場景的複合 vs 焊接每步成本(列入 `docs/CATEGORY.md` §2)。
> **交付**:接真路徑 —— `ContactScene6.add_compound(...)` 進 `step` / `step_soft`,並讓 17.5 `FractureSet` 的凹體零件可選走複合。普通:L 形體落地靜置高度與質心對解析;複合總質量 / 質心 / 主慣量對盒 + 球的手算值。整合:broadphase 兩條 seam(brute 與 BVH)逐位相同、island / 睡眠、快照往返逐位相同、sensor / 過濾、疊在 17.45 網格地面上。極端:單一子形狀(須與非複合逐位相同)、子形狀完全重合、零體積子形狀(raise)、1000 子形狀、子形狀位姿含非單位四元數(raise)、`remove_body` 後槽位重用不殘留舊子形狀。
> **相依**:17.5(凸分解與多面體質量性質)、17.24 / 17.25(kinematic 與睡眠規則)、17.13(查詢)、17.46(CCD 對複合展開)、17.52(新形狀種類自動可作子形狀)。
> **邊界**:子形狀僅限凸基元(box / sphere / capsule / hull);靜態 trimesh / heightfield 不作子形狀(關卡走 17.45)。凹體自動凸分解已由 17.5 交付,本條只接收分解結果。GPU 剛體 solver 的收集階段在 CPU(ROADMAP §17.17),複合在 CPU 展開成 manifold 即可,kernel 不改,交付時以 `test_gpu_contact` 的判準確認;GPU 本身歸 17.17。與 17.85 無重疊。

> **進度(2026-10-14)**:
> - **圓形子形狀的滾動錨點 ✅**:`make_contact` 由 feat 解出是複合的哪個子形狀接觸(對形狀 1 + a·1024 + b、對網格 k << 16 + 三角形),
>   `round_core` / `round_reach` 用該子形狀的核心(球心、膠囊軸上的夾點,body 座標)與半徑。3 m/s 滾 2 s:雙球複合 2.0815 → 2.9999974、
>   膠囊子形狀複合 2.1081 → 2.9999936 m/s(球 body 3.0)。橢球子形狀仍為固定錨點。
> - **`FractureSet` 凹零件走複合 ✅**:`spawn_grouped` 把同一 Voronoi 種子在凹物體各凸零件中的格子合成一個複合 body(每格一個 hull 子形狀),
>   取代各自成 hull 再以 `bond_overlapping` 焊接;碎片記錄其格子(kid 表),`bond_neighbors / bond_overlapping / anchor` 逐 kid 走(hull 碎片一個 kid,
>   行為不變),複合碎片不能再切(raise),快照帶 kid 表。分解後的 L 板(36 格):27 個 body(9 個複合)vs 36 個 hull、質量 1199.9999 vs 1200.0、
>   跨縫焊接 11 vs 23,靜止入睡、一個 island。`test_fracture` 87/87。
> - **待辦**:無(CPU)。CCD 覆蓋複合見 17.46;GPU 屬 17.17。

#### 17.47 關節庫補完(最大座標) — Wave B(承 9.1)

> **狀態**:✅ 完成(2026-10-14:hinge / slider / rope / cone-twist 限制、速度 / 位置馬達、軟彈簧、`collide_connected`、快照、ragdoll 接線、與縮座標的 parity、universal / D6 / 滑輪 / 齒輪、ext 列計入斷裂負載;GPU 側屬 17.17)。
> **現況**:`Joint6` 的種類只有 `JOINT_BALL / DISTANCE / HINGE / BROKEN / WELD`(`physics/joints6.mojo:14-18`),全是等式約束,檔頭自述「no cone clamp」(`:23-26`);hinge = ball + 兩軸對齊(`:171-214`),weld = ball + 三軸角鎖(`:215-248`)。grep `limit|motor|spring|slider|prismatic|cone|twist|swing|stiff`(`physics/joints6.mojo`、`physics/solver6.mojo`)只命中檔頭字樣與 `AngularDrive` 的文件,沒有對應欄位。
> `AngularDrive`(`physics/joints6.mojo:278-298`)是姿態驅動:把 b 相對 a 的姿態拉向 `target`,自帶 hertz / zeta,累積衝量夾 `max_torque·h`,沿世界三軸各自求解(`:326-369`)—— 位置伺服,不是速度馬達,也沒有關節軸向的角度參照。distance 關節是雙向的,沒有鬆弛(ROADMAP §17.41 17.41 待辦)。
> 周邊契約:斷裂(17.29)靠 `acc` / `acc_ang` 的子步峰值,`sample_loads` + `check_breaks`(`physics/joints6.mojo:372-407`),新關節種類必須定義 `acc` 的語意;快照逐關節寫 kind / a / b / la / lb / rest / axis / acc(`physics/solver6.mojo:1494-1506`),新欄位要升 `_VERSION`(`physics/serialize.mojo:38`);`remove_body` 已檢查 joints / drives 引用(`physics/solver6.mojo:425-436`)。
> 只有 weld 讓相連兩體互不碰撞(`physics/solver6.mojo:721-731`);ragdoll 以球關節連每骨的盒且未設任何過濾(`gameplay/ragdoll.mojo:68-93`,該檔 grep `set_filter` 零命中)—— grep `collide_connected|ignore_connected|disable_collision`(`physics collision gameplay`)零命中。GPU 剛體 solver 拒絕任何關節 / 驅動(`physics/gpu_contact.mojo:347`),island 平行遇驅動器或斷裂門檻退回串行(`physics/solver6.mojo:1244-1251`)。
> 縮座標側已有 revolute / prismatic 與限制(`physics/chain.mojo:96-97,130-140,785-848`),那是 17.51 的現況。ROADMAP §9.1(9.1 狀態校正)與 ROADMAP §17.2(17.2 待辦「關節角度限制(膝單向)」)都把這些列為未做。
> **缺口**:
> - **限制**(單邊不等式、warm start、速度級 + 位置級):hinge 上下限(例:膝 0–150° 單向)、distance 的 min / max(繩、撐桿)、slider 行程。
> - **馬達**:速度馬達(目標角 / 線速度 + `max_force` / `max_torque`;例:輪、旋轉門、風扇)與位置馬達(軟彈簧 + 阻尼,以 hertz / zeta 表示)。與 `AngularDrive` 分工:drive = 姿態目標(動畫跟隨),motor = 沿關節軸的速度 / 位置。
> - **彈簧**:軸向彈簧 - 阻尼,用軟約束係數(Box2D v3 作法),例:活塞、自動歸位的門。
> - **新種類**:`JOINT_SLIDER`(prismatic,鎖 2 平移 + 3 旋轉)、`JOINT_CONE_TWIST`(swing 錐 + twist 範圍,ragdoll 肩 / 髖)、選做 `JOINT_UNIVERSAL` / 通用 6 軸(各軸 free / limited / locked)、滑輪、齒輪。
> - **`collide_connected` 開關**:相連兩體可選互不碰撞。(例:ragdoll 上臂與前臂的膠囊在肘部重疊,開關關閉時不再互推抖動)
> - 每個新種類:斷裂門檻語意、快照、引用檢查、島併入;`Ragdoll` 接線(肩 / 髖 cone-twist,膝 / 肘 hinge 限制,解掉 17.2 待辦)。
> **對照組**:Jolt(`HingeConstraint` 限制 + 馬達、`SliderConstraint`、`SwingTwistConstraint`、`SixDOFConstraint`、`DistanceConstraint` 彈簧)、PhysX `PxD6Joint` / `PxRevoluteJoint` / `PxPrismaticJoint`、Box2D v3(revolute / prismatic / wheel 的 limit + motor + spring)、Bullet(`btConeTwistConstraint`、`btGeneric6DofSpring2Constraint`、`btSliderConstraint`)。內部對照:縮座標的 `Chain.resolve_limits`(同一限制語意的另一座標)。
> **優勢區**:(1)縮座標對照:同一組「限制 + 馬達」在最大座標與縮座標上都存在後才量得出 13.2 定下的權衡(高剛度 / 長鏈下縮座標不抖、最大座標漂移);(2)swing-twist 限制可直接用 `drive_error`(`physics/joints6.mojo:301-312`,最短路徑旋轉向量)取得,不經歐拉角、無 gimbal,優勢區 = 肩關節大幅度、貼近奇異的姿態;(3)軟約束彈簧在大時間步仍穩定(對照顯式彈簧 - 阻尼的 `dt·k/m` 穩定界)。
> **規模軸**:關節數 × 種類 × `iters` × 子步;100 節長鏈受載下的限制殘差;馬達增益與質量比的極端值。
> **seam?**:是 —— 「限制 / 馬達」的座標變體:最大座標 `Joint6`(本條)vs 縮座標 `Chain.resolve_limits` + `Actuator`(已有)。parity:同一單擺 / 雙擺 / ragdoll 腿的停止角、馬達穩態速度、彈簧頻率兩邊相等(容差寫進測試,沿用 `test_chain` / `test_joints_lib` 的比法)。bench:關節種類 × iters(9.1 原設計的列);列入 `docs/CATEGORY.md` §2.1 的關節列(`:124`)旁。
> **交付**:接真路徑 —— `ContactScene6.add_joint` 進 `step`,並接上 `gameplay/ragdoll.mojo`。普通:hinge 擋停解析角、速度馬達達設定角速度、彈簧頻率對解析 √(k/m)/2π、slider 行程端點、cone-twist 錐外投影;**能量不注入**(限制 + 馬達關閉時總能量不增)。整合:ragdoll 肩髖膝肘接新關節,落地不穿插、不反折;車門(hinge 限制 + 彈簧);17.29 斷裂對受限關節仍成立;快照往返逐位相同;broadphase 兩 seam 與 island 睡眠一致;`collide_connected = false` 時相連骨不互撞。極端:lo = hi(鎖死)、lo > hi(raise)、範圍 ≥ 2π、馬達 `max_force = 0`(須與無馬達逐位相同)、質量比 1:1e4 的馬達、軸為零向量(raise)、兩端為同一 body(raise)、錨點相距很遠。
> **相依**:9.2(浮動基座 ragdoll)、17.2(`AngularDrive` / `Ragdoll`)、17.29(斷裂)、17.5(weld)、17.51(縮座標對照)、17.19。
> **邊界**:縮座標多自由度屬 17.51;GPU 上的關節屬 17.17;致動器 / 腱(13.3 / 13.4)屬縮座標側;繩 / 纜線屬 17.41;動畫目標與 IK 屬 17.2 / 17.3。與 17.85 無重疊。

> **進度(2026-10-13)**:
> - **`physics/joint_ext.mojo`**:每個關節一筆 `JointExt`(與 `joints` 平行;`Joint6` 欄位與既有快照欄位不變):關節座標 q(hinge 轉角、slider 行程、
>   rope 長度、cone-twist 的 twist 角;0 = 建立時的姿態)上的上下限(單邊不等式,未達時為 speculative、穿越時軟偏置,同接觸的 Box2D v3 作法)、
>   cone-twist 的擺錐、速度 / 位置馬達(累積衝量夾 `max_force · h`)、軟彈簧(hertz / zeta)、`collide`。新種類 `JOINT_SLIDER`(兩條垂直線性列 + 三條角鎖)、
>   `JOINT_CONE_TWIST`(球關節 + 擺錐 / twist)、`JOINT_ROPE`(只限 [0, max])。`ext_sweep` / `warm_start_ext` 在 serial 與 island 兩個子步迴圈都接上,
>   `any_ext` 為假時不執行(全套 golden 既有段落不變)。`collide_connected = False` 併入既有的 weld 配對排除。
> - **API**:`set_joint_limits / clear_joint_limits / set_cone_limit / set_joint_motor / set_joint_spring / set_collide_connected / joint_coordinate / reset_joint_ext`;
>   `Ragdoll.limit_hinge / limit_cone` 與建構參數 `collide_connected`。快照 format 4 加 ext 區塊。
> - **測試** `test_joints_ext` 18/18:1 m 桿落到 −0.5 rad 限位停在 −0.5014;速度馬達 3.0 rad/s;扭矩上限 0.1 N·m 一秒後 ω = 0.29999977(解析 cap / I · t = 0.3);
>   slider 上 2 Hz 無阻尼彈簧週期 0.5006 s;垂直 slider 行程 [−1, 0] 停在 −1.0003、側向 0、不轉;cone-twist 由 60° 拉回 30° 錐內(最大 30.10°)、
>   twist 限 ±0.2 時最大 0.19999754;2 m 繩拉緊於 y = 2.99973、上拋 4 m/s 峰值 3.8076(自由落體 3.8163,差為離散步長);重疊相連箱 collide False 不動、
>   True 推開 0.098;受限加馬達的 hinge 快照還原後逐位相同;非法輸入 raise;零扭矩馬達不施力。`test_ragdoll`:無力腿的膝改為限 ±0.2 rad 的 hinge,
>   最大 0.2037 rad,同腿球關節膝擺到 1.52 rad。
> - **bench** `bench_joints_ext`(已入報告範本):64 節鏈,球關節(無 ext pass)0.89 / 1.20 ms(iters 4 / 8),hinge + 限 1.37 / 1.97、cone-twist 1.20 / 2.21、
>   slider 1.36 / 2.13 ms。`docs/CATEGORY.md` 加一列 seam。
> - **ext 列計入斷裂負載 ✅(2026-10-14)**:限制 / 馬達 / 彈簧 / 錐列的衝量原本與 `Joint6.acc` 分開累積,停在限制上的鉸鏈、頂到行程端的滑軌讀不到負載:
>   1 kg、1 m 的桿以重力靠在 −0.5 rad 限制上,`joint_reaction` 扭矩讀 0.0、3 N·m 門檻也不斷。`ext_impulse` / `sample_ext_loads`(各列與關節本身的列正交,
>   直接相加)後讀 4.296776 N·m(解析 4.3001547),3 N·m 斷、6 N·m 不斷;20 N 推的滑軌在 10 N 門檻斷。`test_joint_break` 14/14。
> - **新種類 ✅(2026-10-14)**:`Joint6.universal`(ball + 兩軸保持垂直,一個角列)、`gear`(ratio·ω_a·a + ω_b·b = 0,兩側各自的 Jacobian,剛性速度列)、
>   `pulley`(|p_a − g_a| + ratio·|p_b − g_b| ≤ L,只拉)、`d6`(a 座標系 3 平移 + 3 旋轉各自 free / locked / limited,`set_d6_axis`;旋轉座標取相對旋轉的
>   rotation vector 分量 —— 單軸轉動時精確、多軸同時轉時是一個 rotation vector 的分量而非三個依序角)。`Joint6` 加 `ratio`、ext 加 D6 欄位,快照 format 5。
>   `test_joint_kinds` 10/10:Cardan 30°:輸出 / 輸入轉速 0.8659431 .. 1.1548681(解析 0.8660254 .. 1.1547005);齒輪 2:1 轉速比 −2.0、1 N·m 下
>   ω_a 1.5463916(解析 τ / (I_a + r² I_b) = 1.5463916);Atwood 1 / 3 kg 加速度 4.9000015;ratio 2 的滑車組以 1 kg 平衡 2 kg、張力 9.8;快照逐位相同;
>   鬆弛的滑輪不拉。`test_joint_d6` 8/8:全鎖 vs weld 尖端差 8.4e-8 m;只放 z 轉 vs hinge 角度差 2.7e-7 rad;只放 x 平移、重力斜 30° v_x 4.9000077;
>   x 行程 0.2 受 20 N 停在 0.20053;z 轉限制 0.5 受 6 N·m 停在 0.49929;全放 = 自由落體。
> - **與縮座標 parity ✅(2026-10-14)**:`test_joint_parity` 5/5,同一根桿分別是 `ContactScene6` hinge 與 `Chain` revolute:0.3 rad 自由擺 4 s 角度差 ≤ 0.0099
>   (軟鉸鏈錨點略有彈性)、週期 1.65 / 1.65 s(解析 1.6408,取樣 1/60 s);2 N·m 加阻尼停在 0.42432 / 0.42044(解析 0.42044);6 N·m 頂 0.5 rad 停止角
>   0.49998 / 0.5、過衝 0.0033 / 0。做這條時量到 17.48 的順序錯誤:`_props_pre` 先加力再除 (1 + c·dt),力被阻尼削掉、重力沒有,
>   有阻尼又被約束住的物體停在 τ / (1 + c·dt) 的平衡(上面那根桿停在 0.4091);改成先阻尼後加力。
> - **待辦**:GPU 側屬 17.17。

#### 17.48 剛體參數 API — Wave A

> **狀態**:✅ 完成(2026-10-13)。hull 的密度 → 質量(需多面體體積與質心)與質心偏移移交 17.44。
> **現況**:`ContactScene6` 目前對外的逐 body 屬性只有:過濾 / sensor(`physics/solver6.mojo:455-464`)、恢復係數與摩擦 + 組合模式(`:466-499`)、kinematic / 速度 / `move_to`(`:501-550`)、凍結(`:552-581`)、睡眠 API 與 teleport(`:583-634`);逐 body 重力只能經力場直接寫 `bset.grav_on` / `bset.grav`(`physics/fields.mojo:145,163-164`)。
> 質量 / 慣量只在建構時給:`Inertia3` 隨 `Body6` 進場(`physics/rigid6.mojo:45-52`),trait 只能讀(`get_inertia`,`:154`),要改只能直接寫具體型別的 `inertia` 欄位(`QuatBody6` `:167`、`ScrewBody6` `:278`)。質心 = body 原點(見 17.44)。
> 外力只有衝量入口,而且呼叫端是穿透 `sc.bset.bodies[i].apply_impulse`:`gameplay/ragdoll.mojo:116`、`gameplay/character.mojo:134`、`gameplay/vehicle.mojo:513,719-727`、`gameplay/replay.mojo:80`;力場每幀換成衝量(`physics/fields.mojo:125-171`)。沒有持續力 / 力矩累加器。
> 阻尼:grep `damping|angular_drag|linear_drag|lock_axis|axis_lock|allowed_dof|gravity_scale|max_linear|max_angular|set_mass|set_inertia|center_of_mass|com_offset|add_force|apply_force|add_torque|sleep_threshold`(`physics/solver6.mojo`、`body_set.mojo`、`rigid6.mojo`、`contact6.mojo`、`solver_config.mojo`、`gameplay/runtime.mojo`)**零命中**;唯一相近的是力場區域內的 `FIELD_DRAG`(`physics/fields.mojo:168`,線性、僅區域內)。睡眠門檻是全域 `SolverConfig.lin_sleep_tol / ang_sleep_tol / sleep_time`(`physics/solver_config.mojo:43-45`),`update_sleep` 全 body 共用(`physics/islands.mojo:133-152`)。
> `Runtime` 只有 `spawn_body / spawn_sphere / teleport / despawn`(`gameplay/runtime.mojo:106-153`),沒有任何參數入口。快照:新增逐 body 欄位必須進 `write_state` / `read_state` 並升版(`physics/solver6.mojo:1410-1552`、`physics/serialize.mojo:38`);現況先例是重力覆寫與凍結狀態**不在**快照(上述範圍內無 `grav_on` / `frozen_motion`,ROADMAP §17.31 17.31 待辦亦記載)。
> **缺口**:
> - **質量性質**:`set_mass`(縮放慣量保持形狀)、`set_inertia`、`compute_mass_from_density`(依 collider 形狀:盒 / 球 / 膠囊用 `Inertia3.*`,hull 用多面體體積;例:同一個箱子換材質密度)、質心偏移(接 17.44)、對應的讀取;`Body6` trait 補方法,兩個表示 parity。
> - **阻尼**:線 / 角阻尼係數,隱式形式 `v *= 1/(1 + c·h)`,對子步數不敏感(例:空氣中旋轉的木板自然減速)。
> - **`gravity_scale`**:逐 body 重力係數,與力場的 `grav` 覆寫共存,取代直接寫 `bset.grav_on`。
> - **軸鎖**:平移 / 旋轉各軸鎖(2.5D 遊戲、只繞 Y 的旋轉門):被鎖分量的有效質量逆置 0。
> - **速度上限**:最大線速 / 角速,穩定性護欄,觸發時記入 `diag` 計數器。(例:被 1e6 N 爆炸衝量命中的箱子速度夾到 500 m/s 而非穿越整個關卡)
> - **持續力 / 力矩累加器**:`add_force / add_torque / add_force_at`,附 force / impulse / velocity-change / acceleration 模式,下一步消耗並清空,取代呼叫端穿透 `bset.bodies[i].apply_impulse`。
> - **逐 body 睡眠門檻覆寫**(玩家載具、慢轉盤)。
> - 全部走 `BodyId` API(無效 id 一律 raise)、進快照、`Runtime` 暴露;讀取側補 `velocity / angular_velocity / pose`(目前要穿透 `bset`)。
> **對照組**:PhysX(`setLinearDamping`、`PxRigidDynamicLockFlag`、`setMaxLinearVelocity`、`PxRigidBodyExt::updateMassAndInertia`、`addForce(PxForceMode)`、`setCMassLocalPose`)、Jolt(`BodyCreationSettings` 的 `mLinearDamping / mAngularDamping / mGravityFactor / mAllowedDOFs / mMaxLinearVelocity / mOverrideMassProperties`,`BodyInterface::AddForce`)、Box2D v3(`b2BodyDef` 的 `linearDamping / angularDamping / gravityScale / fixedRotation / sleepThreshold / isBullet`,`b2Body_SetMassData`)、Unity `Rigidbody`(阻尼、`constraints`、`centerOfMass`、`AddForce(ForceMode)`)、UE `FBodyInstance`。
> **優勢區**:低 —— 純工程 table stakes,定位同 17.23 / 17.25。可辨別處:(1)阻尼由 `Body6` 方法定義,在 `ScrewBody6` 與 `QuatBody6` 上以 action 比 parity,不是各自拼係數;(2)全部參數進決定論快照,對重播 / rollback(17.39 / 17.16)友善,對照組多半不保證。
> **規模軸**:body 數 × 每步施力呼叫數(累加器 vs 直接 impulse 的成本);阻尼 / 軸鎖開關在 N = 1 … 1e4 的每步開銷(預設值路徑須逐位相同且成本在雜訊內)。
> **seam?**:否新 seam —— 是既有 `Body6` seam(`docs/CATEGORY.md:49`)的契約擴充:每個新特性在 `QuatBody6` / `ScrewBody6` 上作用等價(by action),預設值路徑與現況逐位相同(身分閘門)。
> **交付**:接真路徑 —— `ContactScene6` 與 `Runtime` 的公開 API,並把 `ragdoll` / `character` / `vehicle` / `replay` 的穿透呼叫改走新 API。普通:各 setter / getter 往返;阻尼指數衰減對解析 e^(−ct);`gravity_scale = 0` 懸浮;軸鎖下箱子只沿未鎖軸運動;速度上限夾住;密度 → 質量對盒 / 球 / 膠囊解析值;累加器施力一步等價於同量 impulse。整合:`Runtime` 暴露;力場重力區與 `gravity_scale` 共存;快照往返逐位相同;`BodySet.push` 的槽位重用把新屬性復位(`physics/body_set.mojo:157-192`);所有參數取預設值時全套 golden 各段逐位不變。極端:`set_mass(0)` / 負 / NaN(raise)、阻尼 c → ∞(速度歸零而不反向)、三軸全鎖的動態體、對 static / kinematic / removed id 設定(語意寫進測試)、質量比 1e6、對睡眠體施力(喚醒)、單步大量 `add_force`。
> **相依**:17.23 / 17.24 / 17.25 / 17.27 / 17.31(沿用其規則)、17.44(質心)、17.0g(`BodySet`)。
> **邊界**:材質(摩擦 / 恢復)已由 17.23 交付;分級模擬的逐 island 品質與睡眠 bookkeeping 屬 17.85,本條只給逐 body 睡眠門檻參數;軟體 / 流體參數不含;縮座標 link 的阻尼 / armature 屬 17.51;腳本層暴露屬 17.21 / 12.1。

> **進度(2026-10-13)**:
> - **API**(`physics/solver6.mojo`,全部走 `BodyId`,無效 / 已移除 id 一律 raise):`set_damping`、`set_gravity_scale`、`set_axis_locks`(世界軸,線性 x/y/z + 角 x/y/z)、
>   `set_max_velocity`、`set_sleep_thresholds`、`set_mass`(慣量同比例縮放)、`set_inertia`、`set_mass_from_density`(盒 / 球 / 膠囊;其他形狀 raise)、
>   `add_force`(`FORCE_MODE_FORCE / IMPULSE / VELOCITY_CHANGE / ACCELERATION`)、`add_force_at`、`add_torque`、`apply_impulse`、`apply_angular_impulse`、
>   讀取 `velocity / angular_velocity / pose`。逐 body 欄位在 `BodySet`(`push` 的槽位重用一併復位),`Body6` trait 補 `set_inertia`(`QuatBody6` / `ScrewBody6`)。
> - **身分閘門**:`step(dt, g, cfg)` = `_props_pre`(累加力 → 衝量、隱式阻尼)+ `_step_impl` + `_props_post`(速度上限 + 計數、軸鎖投影);兩個 pass 只在
>   `bset.any_props`(任一 setter 用過)時執行;軸鎖另在每個子步的 `integrate_pose` 前投影。全套 golden 除下列預期變動外逐位不變。
> - **快照 format 4**(`physics/serialize.mojo` `_VERSION = 4`):島標籤後依序是 17.29 重力覆寫、17.31 凍結 motion、17.48 參數、17.45 active-edge 旗標,
>   每塊前有存在旗標、沒用到就不寫。第一版逐 body 全寫,netcode 全量快照 4952 → 6200 bytes、每幀 delta 1574 → 1874;改成按需寫入後 4984 / 1582,
>   `test_serialize` blob 20553 → 20561(加上下列斷裂閾值與驅動器後 20565)。
> - **穿透呼叫改走 API**:`ragdoll.hit`、`character._push`、`replay` 的踢擊、`embed/world.apply_impulse` 改用 `apply_impulse`(喚醒語意同 `wake(id)`);
>   `vehicle` 的空氣動力、輪胎反作用力與車身合力改用 `apply_impulse / apply_angular_impulse(..., wake=False)`(車身每子步施力仍可在靜止時入睡,
>   地面體沿用「睡著才喚醒」)。`Runtime` 以 entity 暴露同一組 setter / 讀取,step 進行中呼叫 raise。
> - **測試**:`test_rigid_params` 32/32 —— 阻尼 c = 2 一秒後 1.3982166(隱式解 10/(1 + c·dt)^60 = 1.3982142,連續解 10e^−2 = 1.3534);
>   `gravity_scale` 0 / 2 / 1 → vy 0 / −9.799998 / −4.899999;密度 1000:盒 1000.0、球 523.5988、膠囊 452.3894 kg;60 N × 1/60 s = 衝量 1 = 1.0 m/s;
>   2.5D 鎖(lz、ax、ay)的箱子摔落翻滾 2 s,z 與 ωx、ωy 每步恆為 0;速度上限 3 m/s 擋住自由落體、計數 42 次;門檻 0 的箱子不睡、預設的會睡;
>   format 4 往返後再序列化逐字相同、各步進 90 步逐位相同;所有參數設回預設值 == 從未呼叫,逐位相同;c = 1e9 速度歸零不反向;三軸全鎖不受重力;
>   1000 次 0.06 N == 60 N;對睡眠體施力會喚醒;kinematic / static 忽略施力;5 種非法輸入 raise。`ScrewBody6` parity:同一組阻尼 / 鎖 / 重力係數 /
>   偏心力下兩種表示的位置差最大 1.7 mm,同場景不設參數的對照組為 3.7 mm(參數不放大表示差)。`test_runtime_params` 4/4。
> - **bench** `bench_rigid_params`(已入報告範本):N = 1000 / 10000 自由落體球,所有變體與預設路徑差在 ±5 % 內(雜訊)。量到一個真問題:
>   `add_force` 原本經 `wake_island`(每次 O(N) 掃描),每步對每個 body 施力是 O(N²),N = 10000 時步長 2.0 倍(4106 vs 2073 ms);
>   改成清醒 body 只重設自己的睡眠計時(island 一起睡)後 2308 vs 2371 ms。
> - **設計取捨**:軸鎖以速度投影實作(每子步 + 步末),不是把有效質量逆置 0:接觸求解時被鎖分量仍參與,隨後被投影掉;
>   量測上 2.5D 箱子仍正常落地靜置(y 0.348)。若出現鎖定體被接觸「吃掉」動量的案例,再改為求解器內的逐分量質量。
> - **快照遺留一併補完**(優先序第 8 項的附註):17.29 關節斷裂閾值、17.2 `AngularDrive` 進場景快照(負載峰值是每步暫態、不存);
>   17.4 `Vehicle.write_state / read_state`、17.5 `write_fracture / read_fracture`(與場景快照並存,`BinWriter / BinReader` 改為公開,
>   `state_io.f64_bits` 讓 Float64 精確往返)。量測:轉彎中的車存檔還原後 60 步車身位置逐位相同;射擊前存檔的碎牆還原後兩邊都斷 16 條鍵、
>   剩 13 條、每個碎片位姿逐位相同;`test_serialize` blob 20553 → 20565 bytes(全部區塊未使用時只多 6 個 token)。
> - **移交**:hull 的 `set_mass_from_density`(多面體體積與慣量,質心不在原點)→ 17.44;舊的一次性 `step(dt, g, iters)` 不跑 17.48 pass(僅舊測試使用)。

#### 17.49 力回報 / 衝擊事件 — Wave A

> **狀態**:✅ 完成(2026-10-13)。GPU 解算器路徑不產生 payload(第 7 層);以 payload 驅動 `FractureSet` 斷裂門檻未接。
> **現況**:`ContactEvent` 只有 `(a, b, feat, kind)`(`collision/contact_events.mojo:19-31`):知道誰碰誰、began / stay / ended,沒有衝量、接觸點、法向、相對速度。`_emit_events` 對鍵排序後做差分(`physics/solver6.mojo:905-927`),`Runtime` 再轉進 `Channel`(`gameplay/runtime.mojo:84`)。
> 求解器內有資料但沒有出口:`ContactConstraint` 帶逐點累積法向 / 摩擦衝量 `acc / acc_t1 / acc_t2`、接近速度 `vn0`、恢復衝量 `racc`(`physics/contact6.mojo:41-54`),步末存進 `self.cache`(`physics/solver6.mojo:1368`)只為下一幀 warm start。`cache` 是公開欄位(`physics/solver6.mojo:139`),測試會直接讀它的接觸集合(如 `tests/test_sleep_api.mojo:80`),所以末子步的逐點衝量技術上讀得到,但那是 warm-start 內部狀態、沒有語意契約,不算 API。`acc` 是**單一子步**的累積量 —— 每個子步先 warm start 再被 `isc·acc` 項衰減(`physics/contact6.mojo:383`),不是整步總和;恢復衝量 `racc` 另計。
> 關節:`Joint6.acc / acc_ang` 在子步內累積,17.29 為斷裂**改取子步峰值**(`sample_loads`,`physics/joints6.mojo:372-383`),而且只在設了門檻(`any_break`)時才取樣,沒有公開讀取;17.29 進度已量到「只看最後一個子步會漏掉衝擊」(ROADMAP §17.29)。grep `contact_impulse|impulse_of|joint_force|joint_load|total_impulse|net_force|contact_force|reaction_force|body_contacts|contacts_of`(`physics collision gameplay`)命中的全是 "touching" 之類的字面,**零個**真實 API。
> 縮座標:關節力矩感測 = 逆動力學(13.6,`physics/sensors.mojo`);`read_touch` 只回穿透深度,「touch pad 把它積成法向力」只是註解(`physics/sensors.mojo:125-132`)。傳輸層都已就位:碰撞 `Channel`(17.38)、斷裂 `broken_joints`(`physics/solver6.mojo:146`)、17.5 的 `FractureEvent`、debug-draw 的接觸箭頭(`physics/solver6.mojo:982`)—— 缺的是 payload。
> **缺口**:
> - **接觸事件 payload**:`began` 帶整步衝量、最大接觸點與法向、相對法向速度(取 `vn0`)、雙方材質 / 圖層;`stay` 帶當步法向力;`ended` 帶峰值;門檻過濾(例:只報衝量 > J_min 的 began,供破碎音效或傷害規則)。
> - **整步衝量估計器**:每個子步結束把 `acc` 累加,取代只看最後子步。
> - **查詢 API**:`contacts_of(body)`(對方、點、法向、衝量)、`net_contact_force(body)`(站台重量、壓力板、承重感測)、`joint_reaction(j)`(力 + 力矩,不需設斷裂門檻也可讀)。
> - **逐 body 事件旗標**(對照 PhysX `eNOTIFY_TOUCH_FOUND` / `eNOTIFY_THRESHOLD_FORCE_FOUND`),避免全場景付費。
> **對照組**:PhysX(`PxContactPairPoint.impulse`、`PxSimulationEventCallback::onContact`)、Jolt(`ContactListener::OnContactAdded` 的 `ContactManifold`、`Constraint::GetTotalLambda*`)、Box2D v3(`b2ContactHitEvent` 的 `approachSpeed` 與 `hitEventThreshold`、`b2Joint_GetConstraintForce`)、Unity(`Collision.impulse` / `relativeVelocity`、`Joint.currentForce`)。
> **優勢區**:(1)17.29 已證明「峰值取樣 vs 末子步」是關鍵設計選擇,本條把它推廣到接觸;優勢區 = **衝擊**(高速撞擊時末子步幾乎已被吸收);(2)決定論:payload 是快照狀態的純函數,可進 17.39 / 17.16 的比對(例:`first_divergence` 的雜湊可納入衝量);(3)沒有額外求解成本,資料本就在子步累積器內。
> **規模軸**:接觸數 × 子步數 × 事件門檻通過率;報告開 / 關每步成本;`contacts_of` 對 body 度數的查詢成本。
> **seam?**:是 —— 衝量估計器:末子步 `acc/h`(現成、免費)vs 全子步求和(正確、每子步多一次加法)。parity:穩態(靜置疊塔)兩者相等且等於重量 m·g(容差內);**衝擊時刻兩者分歧**,以行為斷言記錄分歧量(與 17.29 同款)。bench:報告開 / 關每步成本。
> **交付**:接真路徑 —— `ContactScene6.events` → `Runtime` → `Channel` 讀者端收到 payload。普通:盒落地 began 衝量 ≈ (1 + e)·m·v(解析);疊塔最底盒 stay 法向力 = 上方總重;關節懸掛 2 kg 的 `joint_reaction` = 19.6 N(沿用 17.29 / 17.41 的算例)。整合:門檻過濾後只剩強撞擊;與 `FractureSet.poll`(17.5)並用,破碎門檻取自 payload;睡眠體不報、sensor 不報力;兩條 broadphase seam 與 island 平行 / colored 路徑的 payload 逐位相同。極端:零衝量的恰好接觸、單步內建立又結束的接觸、mesh 多三角形(每個 feat 一筆)、body 被 remove 後的事件、衝量 NaN 隔離、1e5 接觸的報告開銷、門檻 0 與 ∞。
> **相依**:17.38(事件匯流排)、17.29(關節峰值)、17.9(debug-draw 可畫力箭頭)、17.5(破碎門檻的消費者)、17.80(擷取檔含 payload)。
> **邊界**:事件傳輸、訂閱、雙緩衝屬 17.38(已交付);聲音 / 特效 / 傷害規則屬宿主或 17.70 / 17.71;縮座標側力回報走 13.6 感測器,本條不重做;分級 tick(17.85)下事件的週期語意不在此條。

> **進度(2026-10-13)**:
> - **整步衝量估計器(seam)**:`SolverConfig.impulse_estimator` = `IMPULSE_SUBSTEP_SUM`(預設)/ `IMPULSE_LAST_SUBSTEP`。每個子步 relax 後,
>   各點的 `acc` 正是該子步施加的法向衝量(warm start 施加舊 `acc`、sweep 施加增量),`contact6.accumulate_step_impulse` 把它與摩擦衝量向量
>   加進 `ContactConstraint.jn / jf / span`,restitution 的 `racc` 另加;兩方都 impulse-inert(靜態或睡眠)的對不計 —— 求解器沒碰它,
>   它的 `acc` 只是留給下一步 warm start(第一版漏了這點,睡著的箱子仍回報 m g dt)。serial、colored、island 平行、分級四條路徑共用
>   `_report_substep`;關節同法累加 `jsum_f / jsum_t / jspan`。
> - **事件 payload**(`collision.contact_events.ContactEvent`):`impulse`、`force`(= impulse / 涵蓋時間)、最大衝量點 `point`、`normal`、
>   接近速度 `approach`(prep 時的 −vn0)、`peak`(自 began 起的最大單步衝量,ended 帶出)。`impacts(events, J)` 是無狀態的 began 門檻過濾。
>   `set_contact_reporting(id, on)`:有任一 body 被標記時只回報牽涉標記 body 的對。`Runtime` 的事件通道原樣帶出 payload。
> - **查詢**:`contacts_of(id)`(對方、點、指向對方的法向、法向衝量、作用於自身的衝量與力)、`net_contact_force(id)`、`joint_reaction(j)`
>   (不需設斷裂門檻)。快照 format 4 加回報旗標與事件峰值(還原後的事件流與峰值延續);逐步輸出(`jn` 等)不入快照,還原後第一步前讀到 0。
> - **測試** `test_impact_report` 23/23:1 kg 球以 5 m/s 落地,began 衝量 5.163334(解析 m v + m g dt = 5.1633334),e = 0.5 時 7.663334(7.6633334),
>   接近速度 5.0;三層疊塔 stay 力 29.401 / 19.601 / 9.8005(3 / 2 / 1 m g);頂箱 `net_contact_force` = 9.8005 向上;懸掛 2 kg 的 `joint_reaction` = 19.6;
>   靜置時末子步估計 29.414 vs 加總 29.401,5 m/s 衝擊時末子步 × 4 = 0.1633(衝擊完全看不到)vs 加總 5.1633;`impacts(J = 2)` 只留 8 m/s 那一下;
>   island 平行 vs serial、BVH vs brute broadphase 的 payload 逐位相同;回報旗標、sensor 零衝量、睡眠體零衝量;彈跳球 ended 帶峰值 11.563;
>   箱子壓在 4 三角形網格中心頂點,4 個逐三角形事件衝量和 0.16333303(m g dt = 0.16333334)。`test_runtime_params` 經 `Runtime` 通道讀到 4.163334。
> - **bench** `bench_impact_report`(已入報告範本):N = 256 / 1024 靜置接觸,各列差異小於重跑雜訊;N = 1024 交錯 A/B 加總 vs 末子步比 1.003
>   (每輪 0.92–1.12,未分辨)—— 預設開啟加總的成本量不出來。`docs/CATEGORY.md` 加一列 seam。
> - **未做**:payload 帶雙方材質 / 圖層(呼叫端可用 body 索引自查);`FractureSet` 以 payload 決定斷裂;1e5 接觸的回報開銷;GPU 路徑(第 7 層)。

#### 17.50 接觸模型變體 — Wave B

> **狀態**:✅ CPU 完成(2026-10-14:CPU 子項全部 ✅ —— 橢圓摩擦錐 seam、靜 / 動摩擦、滾動 / 扭轉阻力、逐 body 與逐材質接觸柔度、黏附、塊求解 seam、PGS / 子步量測;GPU 對齊(第 7 層)未做,GPU 求解器明確拒絕新模式)。
> **進度註(2026-10-13)**:`SolverConfig.friction_cone`(`FRICTION_PYRAMID` 預設 / `FRICTION_ELLIPTIC`):橢圓錐兩軸先不夾,再把 (t1, t2) 投影到半徑 μλₙ 的圓盤;
> 上限為 0 時仍走金字塔(μ = 0 兩錐逐位相同)。`ContactScene6.set_static_friction` / `set_rolling_resistance` / `set_spinning_resistance`(負值或索引越界 raise):
> 靜摩擦以 prep 時切向速度 < 1 cm/s 的點(`ContactConstraint.stick` 位元)取 μs,與 μk 用同一組合規則;滾動 / 扭轉阻力(單位 m,取兩 body 較大者)
> 為相對角速度上的角衝量,扭轉夾 `c·Σλₙ`、滾動在切平面夾於圓盤,每子步以 warm start 帶入。任一新欄位被設才開 `BodySet.any_contact_model`,
> `set_contact_softness(i, hertz, zeta)`:一對取 hertz 較低一側的 hertz / zeta,以與 `step` 相同的公式算軟係數(設成 cfg 值時逐位相同);
> `set_adhesion(i, force)`:兩面相距 1 cm 內時法向衝量可為負,下限 force·h / 點數(一對取較大者),負衝量不給摩擦。
> 預設場景不進新分支;快照帶新的逐 body 欄位(有旗標才寫);GPU 求解器拒絕新模式與橢圓錐。
> 量測(`tests/test_contact_model.mojo` 22/22):30° 斜坡 μ 0.3、1 s,解析 1.177 m:橢圓沿軸 1.182 / 對角 1.198,金字塔沿軸 1.182 / 對角 0.652
> (解析 √2 μN 上限 0.650);半徑 0.5 球 2 m/s、滾動阻力 0.05 停在 2.853 m(解析 7rv₀²/(10cg) = 2.857),無阻力 5 s 走 10.000 m;
> 自旋 10 rad/s、扭轉阻力 0.05,1 s 後 5.100 rad/s(解析 5.1);25° 斜坡 μk 0.3:μs 0.6 時 2 s 移動 0.12 mm,無 μs 滑 2.96 m,以 1 m/s 起滑 1 s 走 1.742 m
> (動摩擦解析 1.739);靜置箱兩錐差 3.1e-7 m(非逐位相同:仍有點的摩擦觸到上限);`ContactRule` 摩擦覆寫同時取代 μs;快照往返後續跑逐位相同;
> μ = 1e3 橢圓錐 1 s 移動 0.15 mm;0.5 m 落下的箱子峰值穿透 預設地面 0.29 mm、3 Hz 軟墊 13.2 mm,柔度設為 cfg 值逐位相同;
> 天花板下 1 kg 箱子(重 9.8 N)黏附 20 N 時 2 s 位移 0、5 N 時落下。bench `bench_contact_model`(µs/步,N = 16 / 256):斜坡方塊 金字塔 369 / 6304、橢圓 400 / 7518、橢圓 + 靜摩擦 + 滾動 / 扭轉 508 / 8581;
> 滾動球 93 / 2394、92 / 2405、140 / 2898(方塊各變體的運動不同,橢圓的方塊滑得較遠,所以差值是錐本身成本的上界)。
> **進度註(2026-10-14,逐材質柔度 / 摩擦)**:`ContactScene6.set_material_softness(material, hertz, zeta)`(id 超出 0..65535、hertz ≤ 0、zeta < 0 raise);
> `_collect_pairs` 在 `apply_rules` 之前以 `_apply_materials` 把三角形材質(`colliders.material(mesh, feat & 0xFFFF)`)的摩擦寫成 `mu_override`、柔度寫進
> `ContactConstraint.soft_hz / soft_zeta`(優先於兩 body 的柔度;`RULE_FRICTION` 規則仍覆寫材質摩擦);快照帶柔度表(格式 5);GPU 求解器有柔度表即拒絕。
> 量測(`tests/test_material_contact.mojo` 6/6):3 m/s 滑行,材質摩擦 0.05 的網格 9.177 m vs 摩擦 0.05 的箱子地面 9.177 m(解析 9.18,body 摩擦 0.8 被取代),
> 加 0.5 摩擦規則 0.912 m;落在 3 Hz 材質三角形上最深 27.546 mm,與網格 body 設 3 Hz 逐位相同,預設 0.31 mm;無柔度的材質逐位維持預設。commit fcedf97。
> **進度註(2026-10-14,塊求解 / TGS)**:`SolverConfig.contact_solver`(`CONTACT_GS` 預設 / `CONTACT_BLOCK`,`validated` 拒絕其他值;`BodySet.block` 帶到 `solve_contact`)。
> 塊求解:manifold 的 2–4 點法向一起解 —— A_ij 以極化恆等式由 `angular_factor(ri + rj)` 求交叉項,剛性 LCP(x ≥ 0、w = Ax + b ≥ 0、x·w = 0)以主動集
> 由大到小列舉、部分主元高斯消去;每點取 ms_k·x_k(即逐點軟更新 ms·(λ − (vn + bias)/A_kk) 以整塊 A 取代 A_kk);四點共面時 A 秩 3,加 1e-4 相對對角正則化取最小範數分配。
> 單點 manifold、黏附、奇異或無解時回到逐點 GS。摩擦仍逐點。
> 量測(`tests/test_contact_block.mojo` 8/8):球(單點)兩者逐位相同;靜置箱高度差 8e-6 m;1 次迭代下四點衝量 最大 / 最小 GS 1.291、塊 1.001;
> 10 箱疊塔 4 s:頂箱下沉 GS 28.4 mm / 塊 27.7 mm,側向漂移 GS 4.5 mm(1 iter)/ 1.6 mm(2 iter),塊 3e-7 / 1e-6 m;100 kg 壓 1 kg 穿透 GS 28.7 mm、塊 27.9 mm(不改善,
> 由軟接觸決定,17.19 的大質量比問題不歸塊求解)。bench `bench_contact_model` 第二表(µs/步):1 疊 1 iter GS 173 / 塊 354,16 疊 4 iter 5591 / 10101 —— 塊求解約 2 倍成本,換來無側向蠕移。
> TGS:`step` 本身就是子步軟步進(Box2D v3,TGS 家族);第三表以相同 16 次迭代比較 1 子步 × 16(PGS 式)與 4 × 4:16 疊 3996 vs 5252 µs,頂箱下沉 28.42 vs 28.40 mm,
> 蠕移 1.15 vs 2.10 mm —— 這組靜置疊塔上兩者差距在 1 mm 內,子步的優勢(高速衝擊、關節鏈)不在此場景顯現,不另設 seam。

> **現況**:`ContactScene6` 只有一種接觸模型:Box2D v3 軟接觸 —— 全域 `hertz` / `zeta`(`physics/solver_config.mojo:53-55`,所有接觸同剛度)+ 逐點 Gauss-Seidel,切向兩個衝量各自夾 `μ·λₙ`(`physics/contact6.mojo:394-430`,逐軸夾在 `:426`),即**金字塔摩擦錐**,上限依賴 `tangent_basis(n)` 的任意基底(`geometry/vec.mojo:161-173`)。
> 摩擦只有單一 μ(`combine` 後的 `pair_mu`,`physics/contact6.mojo:337`),沒有靜 / 動摩擦之分;grep `rolling|torsion|spin.?fric|elliptic|\bcone\b|adhesion|cohesion|stiction|static_fric|kinetic`(`physics/contact6.mojo`、`solver6.mojo`、`gpu_contact.mojo`、`material.mojo`、`solver_config.mojo`)**零命中** —— 沒有滾動 / 扭轉摩擦、黏附、橢圓錐。(`gameplay/vehicle.mojo:166` 的 `rolling_resistance` 是輪胎模型的 Crr·Fz·R 輪軸力矩,不是通用接觸屬性。)反而有**假的**滾動阻力:17.19 發現(ROADMAP §17.19)球進入純滾動後持續減速並下沉約 7 mm,根因是 body-frame 接觸錨點隨球旋轉,摩擦取在偏離真實接觸點的位置 —— 尚未修。恢復係數是後置 pass、門檻全域(`physics/contact6.mojo:444-504`、`physics/solver_config.mojo:49`);位置修正的最大推出速度是常數 −4 m/s(`physics/contact6.mojo:380`)。
> 橢圓錐只存在於縮座標:`ConstraintSet` 的 `CONE_PYRAMIDAL / CONE_ELLIPTIC`(`physics/constraints.mojo:44-45,191-225`),`bench_constraints` 量過(`docs/CATEGORY.md:130`:等工作量下打平,是能力差而非速度差);但該檔 `solve` 只有 PGS(`physics/constraints.mojo:124-174`),13.5 設計寫的 CG / Newton 在該檔零命中(grep `newton|conjugate|\bcg\b`)。
> GPU 求解器另有一份摩擦夾實作(`physics/gpu_contact.mojo:221,263`),任何摩擦模型改動都要與 CPU 同步(`test_gpu_contact` 的判準)。逐接觸覆寫已有:`ContactRule` 的摩擦覆寫與輸送帶(`physics/contact6.mojo:60-61`,17.26)。
> **缺口**:
> - **橢圓摩擦錐**:作為 `ContactScene6` 的 seam 變體(例:木箱沿斜坡斜向滑行,金字塔錐使滑動方向偏向基底軸、上限在對角線高 √2)。
> - **滾動 / 扭轉摩擦**:球與圓柱滾動減速、陀螺在地面自旋減速。
> - **靜 / 動摩擦**(μs > μk,stick-slip)。
> - **逐材質 / 逐 body 接觸柔度**:硬地面 vs 軟墊(目前全域 hertz / zeta)。
> - **求解法變體**:塊求解(同一 manifold 的 4 點聯立,而非逐點 GS)、TGS 風格;位置修正參數(最大推出速度、slop)進 `SolverConfig`。(例:深穿透箱子以 ≤ 3 m/s 推出,而非一步彈飛)
> - **黏附 / 吸附**:法向拉力在閾值內維持接觸。(例:磁吸靴的角色站在天花板上)
> **對照組**:PhysX(`PxFrictionType` patch / 單向 / 雙向、`PxSolverType` PGS vs TGS)、Jolt(`ContactSettings` 逐接觸覆寫與相對表面速度)、Box2D v3(`rollingResistance`、world 層的接觸 hertz / damping ratio / push 速度上限)、Bullet(`btRigidBody::setRollingFriction` / `setSpinningFriction`、摩擦錐求解選項)。內部對照:縮座標 `ConstraintSet` 的兩種錐、17.26 逐接觸規則、17.4 輪胎已手工做的摩擦橢圓(ROADMAP §17.4)。
> **優勢區**:橢圓錐 —— 斜向 / 轉彎滑動(17.4 已在輪胎上證明橢圓的必要);滾動摩擦 —— 球滾動停止距離(物理上無滾動摩擦時應永遠滾動;現況的減速是上述錨點漂移的假象而非可調參數,所以必須先修 17.19 的錨點問題,否則滾動摩擦的解析比對會被假阻力污染);塊求解 —— 疊塔與大質量比(17.19)。誠實反面:`bench_constraints` 的先例是橢圓錐成本與金字塔打平,差異是能力而非速度,本條預期同結論,必須實測而非假設。
> **規模軸**:摩擦錐 × 滑動方向角(0°–45°)× μ;接觸數 × 求解變體 × 迭代數(殘差對齊睡眠的既有量測設計);質量比。
> **seam?**:是 —— (1)摩擦錐:金字塔(現)vs 橢圓。parity 條件 = 滑動方向沿 `tangent_basis` 軸時兩者上限相同,μ = 0 或純黏著(未達上限)時逐位相同;45° 時橢圓上限比金字塔小 √2(行為斷言)。(2)求解法:逐點 GS vs 塊求解,單接觸點 / 無耦合時一致,靜置高度與睡眠對齊。(3)滾動摩擦係數為 0 時與現況逐位相同。bench:每接觸成本;三者皆列入 `docs/CATEGORY.md` §2.5。
> **交付**:接真路徑 —— `ContactScene6.step` 經 broadphase / island / colored / 平行各路徑;GPU 路徑要嘛通過 CPU 差的判準、要嘛明確拒絕新模式(如輸送帶)。普通:30° 斜坡沿 x 軸 vs 45° 斜向滑行距離(金字塔偏差 vs 橢圓無偏差,對解析 ½g(sinθ − μcosθ)t²)、球滾動停止距離對解析、陀螺自旋停止時間、靜 / 動摩擦 stick-slip。整合:17.26 規則與新摩擦並存;快照帶新的逐 body / 材質欄位;身分閘門:預設值下全套 golden 各段不變。極端:μ = 0 與 μ → 1e3、法向衝量為 0 時的摩擦上限、法向貼近 `tangent_basis` 種子軸切換點(`geometry/vec.mojo:170` 的 0.9 門檻)、半徑 0 的球滾動摩擦、接觸點數 1 與 4、質量比 1e4、hertz 極大 / 極小。
> **相依**:17.23(材質)、17.26(規則)、17.19(硬化量測設計;**滾動球錨點漂移須先修**,ROADMAP §17.19)、17.17(GPU parity)、17.48(承載新的逐 body 欄位)。
> **邊界**:縮座標 `ConstraintSet` 的 CG / Newton 補完歸 17.51;軟體 / 布料 / 流體的摩擦不含;輪胎模型本身屬 17.4(已交付)與 17.74;恢復係數的組合模式屬 17.23(已交付)。

---

## 碰撞形狀、寬窄相與世界查詢

範圍:collision、spatial。

| 編號 | 條目 | 狀態 | Wave | 說明 |
|---|---|:-:|:-:|---|
| 1.1 | [Contact manifold 生成(一切的前置)](ROADMAP_HISTORY.md#11-contact-manifold-生成一切的前置) | ✅ |  | `collision/manifold.mojo` 提供 `ContactManifold[dim]` 與 `ManifoldNarrowPhase` seam(AABB / SAT / OBB / GJK 實作),`collision/clip.mojo` 做 reference/incident 裁切,3D EPA 回真實深度與 witness points,並與既有 narrowphase 做 normal/depth parity。 |
| 2.3 | [持久化 broadphase + speculative CCD 第一步](ROADMAP_HISTORY.md#23-持久化-broadphase--speculative-ccd-第一步) | ✅ |  | `collision/bp_dbvh.mojo` 提供 Box2D 式 dynamic tree + fat-overlap pair 快取(與 BruteForce pair-set parity,N=4096 相干負載 70µs vs 全重建 18.9ms),solver 的 `_collect_pairs` 以速度比例 speculative margin 攔截高速體(`tests/test_ccd6.mojo`)。 |
| 7.1 | [SAH-BVH(建樹啟發式:median vs SAH seam)](ROADMAP_HISTORY.md#71-sah-bvh建樹啟發式median-vs-sah-seam--2026-07-22) | ✅ |  | 靜態 BVH 加入 binned SAH 建樹(每軸 12 桶,退化回退 median),與 median 樹 region-query/raycast 結果集相等,群聚 raycast 1.62×、樹緊 43%,且因 median 用插入排序,SAH 建樹反而更快。 |
| 7.2 | [solver6 接寬相(生產 solver 脫離 O(n²))](ROADMAP_HISTORY.md#72-solver6-接寬相生產-solver-脫離-on²--2026-07-22) | ✅ |  | solver6 的 pair 收集可改走 fat 世界-AABB 上的寬相(半徑設計使命中集與 brute 相同、依 (i,j) 字典序發出),400 幀混合場景 brute vs bvh bit-identical,N=512 快 1.76×。 |
| 8.1 | [凸包碰撞入 narrowphase](ROADMAP_HISTORY.md#81-凸包碰撞入-narrowphase---完成2026-08-11) | ✅ |  | 任意凸包經 ContactScene6.add_hull 進入生產解算器,以兩包面法向 SAT 求法向/深度、產生多點 patch 接觸,EPA 只留作邊-邊 fallback;test_hull 24 checks、test_quickhull 17 checks,bench_manifold 有兩列量測。 |
| 8.2 | [三角網格 / heightfield 靜態關卡幾何](ROADMAP_HISTORY.md#82-三角網格--heightfield-靜態關卡幾何---完成2026-08-11) | ✅ |  | 靜態 TriMesh(BVH midphase)與 HeightField(格點 midphase)接進 ContactScene6,窄相復用 8.1 hull_manifold,_CPair 以三角形索引 feat 為子鍵支援一對多接觸;test_trimesh 18 checks,bench_trimesh 量測 brute 線性、BVH 對數、heightfield 不隨三角形數成長。 |
| 9.3 | [碰撞過濾(layers / groups / masks)+ sensors / triggers](ROADMAP_HISTORY.md#93-碰撞過濾layers--groups--masks-sensors--triggers---完成2026-08-11) | ✅ |  | ContactScene6 在 _try_pair 開頭做 Box2D 式對稱 category/mask 過濾(brute 與寬相共用),sensor 接觸收在獨立的 sensor_pairs,solve / warm-start / islands 不需認識 sensor;tests/test_filter_events.mojo 21 checks(與 9.4 合測),bench_filter 顯示過濾決定場景能否收斂到靜止。 |
| 13.8 | [SDF / 橢球 / 圓柱 narrowphase](#138-sdf--橢球--圓柱-narrowphase) | 🔶 |  | geometry/sdf3.mojo 有 3D SDF 場與 SDF 對 SDF 接觸,collision/narrowphase.mojo 有 2D 的 SDFNarrowPhase,但兩者都沒有接進 solver6(collider_set 沒有 SDF 形狀種類);橢球與圓柱沒有任何形狀程式碼;交付物 test_sdf_narrowphase 不存在。 |
| 17.13 | [世界查詢完整度](ROADMAP_HISTORY.md#1713-世界查詢完整度--wave-a) | ✅ | A | `collision/world_query.mojo` 對真實 collider 幾何提供有號距離、ray / sphere / capsule cast、overlap、capsule penetration、batched raycast 與 QueryFilter,`test_world_query` 30/30、`bench_world_query` 已量測。 |
| 17.30 | [地形(HeightField)執行期變形](ROADMAP_HISTORY.md#1730-地形heightfield執行期變形--wave-b) | ✅ | B | HeightField 支援 set_height / deform(圓盤挖填)與 16×16 區塊 min/max 摘要增量重算 bounds,ColliderSet / ContactScene6.deform_heightfield 更新 AABB 並喚醒受影響的睡眠體,1024² 地形每次編輯 11.7 µs vs 全表重掃 2.87 ms。 |
| 17.45 | [網格碰撞品質](#1745-網格碰撞品質--wave-a資產前處理) | ✅ | A | 烘焙管線、內部邊 / ghost collision 修正、球 / 膠囊對三角形的解析 manifold、mesh → SDF、網格本地位姿、kinematic 網格 |
| 17.46 | [CCD 形狀覆蓋](#1746-ccd-形狀覆蓋--wave-b) | ✅ | B | 形狀覆蓋、通用凸對凸 TOI、角向 CCD、逐 body 旗標與啟用策略、配對枚舉、與 island 平行 / colored 相容 |
| 17.52 | [形狀種類](#1752-形狀種類--wave-b承接-138-的剩餘部分) | ✅ | B | SDF 作為 solver 形狀、取樣式 SDF(體素 / 格點場 + 三線性內插 + 解析梯度)、橢球、圓柱、support-mapping 凸形入口 |
| 17.53 | [查詢擴充](#1753-查詢擴充--wave-a承接-1713-的待辦) | ✅ | A | 一般凸形掃掠 / 重疊、距離 / 最近點對、多重命中與提前結束、命中中繼資料、單面網格選項、ray 對 mesh / heightfield 的遍歷 |
| 17.54 | [CPU 碰撞管線](#1754-cpu-碰撞管線--wave-b多執行緒) | ✅ | B | 先量再平行、narrowphase 平行、broadphase 平行、make_contact / 暖啟動比對、CCD 掃描、注入式 fan-out 介面 |

### 已完成條目的遺留待辦

這些條目已完成並移到歷史檔,但各自記下了尚未做的部分:

- **2.3**([紀錄](ROADMAP_HISTORY.md#23-持久化-broadphase--speculative-ccd-第一步)):持久化 DBVH(`bp_dbvh`)尚未接進生產 solver6:7.2 的 `_collect_pairs(use_bp=True)` 仍每幀重建 `geometry.bvh.BVH[3]`(7.2 限制/後續寫明「持久化 DBVH 接入是下一步優化」;physics/ 內無任何 bp_dbvh 引用)
- **2.3**([紀錄](ROADMAP_HISTORY.md#23-持久化-broadphase--speculative-ccd-第一步)):Gate 所寫 N=10⁴ 動態物體 benchmark 未照規模量:`benchmarks/bench_dbvh.mojo:18` 為 N=4096
- **7.1**([紀錄](ROADMAP_HISTORY.md#71-sah-bvh建樹啟發式median-vs-sah-seam--2026-07-22)):solver6 broadphase(7.2)的每幀重建改用 sah=True(一行後續;目前 collision/bp_bvh.mojo:25 的 build_boxes 仍未傳 sah,即仍為 median)
- **7.1**([紀錄](ROADMAP_HISTORY.md#71-sah-bvh建樹啟發式median-vs-sah-seam--2026-07-22)):(可選)median 建樹的插入排序改 quickselect(spatial/bvh.mojo 仍用 _sort_range)
- **7.1**([紀錄](ROADMAP_HISTORY.md#71-sah-bvh建樹啟發式median-vs-sah-seam--2026-07-22)):範圍外留後續:spatial split(SBVH)、GPU 建樹
- **7.1**([紀錄](ROADMAP_HISTORY.md#71-sah-bvh建樹啟發式median-vs-sah-seam--2026-07-22)):誠實行:均勻分布 raycast 打平(615 vs 635 ns),不在均勻分布宣稱 SAH 勝;SAH 平均葉深略高(8.90 vs 7.72)
- **7.2**([紀錄](ROADMAP_HISTORY.md#72-solver6-接寬相生產-solver-脫離-on²--2026-07-22)):誠實行:小 N(N=8)打平,幅度受每幀 16 sweeps 的 solve 主導,大 N 才顯著
- **8.2**([紀錄](ROADMAP_HISTORY.md#82-三角網格--heightfield-靜態關卡幾何---完成2026-08-11)):已知限制(非待辦):heightfield 表達不了懸空、牆、洞穴,這類幾何須用 TriMesh
- **17.13**([紀錄](ROADMAP_HISTORY.md#1713-世界查詢完整度--wave-a)):改用持久 broadphase 預篩並每步快取姿態(N≥256 起每次查詢被線性前置工作主導)
- **17.13**([紀錄](ROADMAP_HISTORY.md#1713-世界查詢完整度--wave-a)):四索引 seam parity(brute / BVH / grid / tree)與各自 bench row
- **17.13**([紀錄](ROADMAP_HISTORY.md#1713-世界查詢完整度--wave-a)):任意 convex(hull)的 shapecast / sweep 未做:目前只有 sphere_cast / capsule_cast(缺口所列「任意 convex 的 shapecast」)
- **17.13**([紀錄](ROADMAP_HISTORY.md#1713-世界查詢完整度--wave-a)):hull 外部距離與 mesh 三角候選距離只是下界,非精確 closest-point
- **17.30**([紀錄](ROADMAP_HISTORY.md#1730-地形heightfield執行期變形--wave-b)):編輯後讓持久寬相增量更新(現每幀由 fat AABB 重建)
- **17.30**([紀錄](ROADMAP_HISTORY.md#1730-地形heightfield執行期變形--wave-b)):連續變形(履帶壓痕)的批次 API

### 待辦與部分完成條目

#### 13.8 SDF / 橢球 / 圓柱 narrowphase

> **狀態**:🔶 部分完成(2026-10-09 負空間盤點時由 ✅ 改為 🔶;已有 3D SDF 場與 SDF 對 SDF 接觸,但沒有接進 solver6;剩餘工作移到 **17.52**)— 原屬 Wave A
> **狀態校正(2026-10-09)**:原本標 ✅,但本節沒有進度註,程式碼也對不上:
> - 3D SDF 場與 SDF 對 SDF 接觸在 `geometry/sdf3.mojo`,只被 `tests/test_sdf3.mojo` 與 `benchmarks/bench_sdf3.mojo` 使用。
> - `collision/collider_set.mojo:37-42` 的形狀種類只有 box / sphere / capsule / hull / trimesh / heightfield,沒有 SDF,所以 SDF 沒有接進 solver6。
> - 橢球與圓柱沒有任何形狀程式碼。
> - 本節交付物 `test_sdf_narrowphase` 不存在。
> 剩餘工作(SDF 作為 solver 形狀、橢球、圓柱)移到 **17.52**。
> **缺口**:`SDFNarrowPhase` 已存在但沒有接進 solver6(與 8.1 凸包當時一樣是「有碼未接線」;注意 `collision/narrowphase.mojo` 的 `SDFNarrowPhase` 是 2D,3D 版本在 `geometry/sdf3.mojo`);橢球與圓柱完全沒有。
> **設計**:先接線 SDF(接觸點 = 兩個 SDF 取最大值後,用梯度下降求得的極小點,MuJoCo 路線),再補橢球 / 圓柱的解析對。SDF 的賣點是接觸點數與網格解析度無關。
> **優勢**:任意隱式形狀(程序化地形、雕刻幾何)不需要先轉成網格;接觸數可以預測。
> **對照組**:同一形狀的解析對(球 / 膠囊已有):SDF 的通用性 vs 解析解的速度,正好是既有 narrowphase 表的比較軸;另外比較同一形狀用網格近似時的接觸數。
> **規模軸**:形狀複雜度 × 接觸點數;SDF 求值成本 × 梯度下降迭代數。
> **交付物**:`test_sdf_narrowphase`(SDF 球 vs 解析球 parity、SDF 對 SDF 收斂、接觸數與解析度無關)+ bench row。
> **相依**:8.1(narrowphase 接線的既有路徑)。
> **歷史**:原「現況」:`SDFNarrowPhase` 已存在但沒有接進 solver6;橢球與圓柱完全沒有。原標題為「✅ 已完成」。

#### 17.45 網格碰撞品質 — Wave A(資產前處理)

> **狀態**:✅ 完成(2026-10-13:烘焙管線、active edges、球 / 膠囊解析三角形 manifold、mesh → SDF、網格本地位姿、BVH 加速的 SDF 烘焙、heightfield active edges、kinematic 移動網格)。
> **現況**:網格接觸是靜態、單面、逐三角形獨立的:`TriMesh` 依繞序單面(`collision/trimesh.mojo:103-115`);`try_mesh_pair` 對每個候選三角形各跑一次 `hull_manifold`,各出一個 `RawContact`(`collision/contact_gen.mojo:124-138`);頂點是世界座標、body 位姿被忽略(`collision/collider_set.mojo:82-85,225`);永遠靜態(`physics/solver6.mojo:337-353`)。建構只驗索引範圍與 3 的倍數(`collision/trimesh.mojo:122-134`),零面積三角形以空法向略過(`:179-193`)。
> 烘焙與內部邊:grep `weld.?vert|simplif|decimat|\bqem\b|ghost|internal.?edge|active.?edge|clean_mesh|mesh_repair|hole.?fill|winding`(`collision geometry physics`)只命中繞序註解與 `Polytope.simplified`(凸多面體共線點清理,`geometry/polytope.mojo:368`),**沒有**頂點焊接、網格修復、簡化、內部邊 / ghost collision 處理。
> 球與膠囊對網格走盒近似:`try_mesh_pair` 以 `as_hull` 取本體(`collision/contact_gen.mojo:122`),其非 hull 分支把球換成邊長 2(r + margin)的盒、把膠囊換成包圍盒(`collision/collider_set.mojo:369-374`,docstring `:345-349` 自述「only APPROXIMATED」)。grep `sphere_tri|capsule_tri|sphere_mesh|tri_sphere` 零命中,沒有解析的球 / 膠囊對三角形 manifold。(以上為讀碼推論,未執行;滾球在斜面網格上的行為是否等同立方體,交付時以解析加速度實測。)查詢側則是精確的:`world_query` 用 `closest_point_on_triangle`(`collision/trimesh.mojo:60`)。
> mesh → SDF:`geometry/sdf3.mojo:37-55` 只有 4 種解析基元加兩層 CSG;grep `sdfgrid|sdf_grid|mesh_to_sdf|distance_field|sdf_from|SdfVolume|sample_sdf` 零命中,沒有格點取樣的 SDF。可重用的零件有:`voxelize`(閉合網格奇偶性佔據格,只有佔據、沒有距離,`geometry/convex_decomp.mojo:9-10,42,101`)、`closest_point_on_triangle`、`BVH` 的 `query_region`(沒有最近鄰查詢,`spatial/bvh.mojo:382,409`)。`geometry/predicates.mojo` 的 exact `orient3d`(10.1)可作 repair 與符號判斷的穩健謂詞。
> **缺口**:
> - **烘焙管線** `bake_collision_mesh`(載入期 / 離線,純 Mojo,輸出 `BakedMesh` + `BakeReport`):weld(容差內頂點合併,例:artist 匯出的分裂頂點使相鄰面沒有共享邊)、repair(移除退化 / 重複三角形、統一繞序,回報開邊 / 非流形邊 / 孔洞數)、simplify(二次誤差度量 QEM 邊收折,附誤差上限與保邊界;例:10 萬三角形岩石 → 2000 三角形的碰撞代理,Hausdorff 誤差 ≤ 容差)。
> - **內部邊 / ghost collision 修正**:烘焙時為每條邊記 active-edge 旗標(相鄰面夾角低於閾值者為平滑內部邊),接觸生成時對內部邊與頂點上的假法向降權或剔除(例:箱子滑過數萬三角形鋪成的平地,速度不被接縫擾動)。
> - **球 / 膠囊對三角形的解析 manifold**,取代盒近似。
> - **mesh → SDF**:烘焙 `SdfGrid`(均勻格距離值 + 三線性取樣 + 梯度);距離用 BVH 最近三角形(需補 `closest_triangle` 查詢),符號用廣義 winding number 或射線奇偶性(例:2000 三角形的雕像烘成 64³ 場,取樣成本與三角形數脫鉤)。本條只產出資產與取樣 API。
> - **網格本地位姿**(目前位姿被忽略):`add_trimesh` 帶 `Pose3`、`world_aabb` 隨位姿更新,讓同一份網格可實例化多次、可作 kinematic 移動平台。
> **對照組**:PhysX cooking(`PxMeshPreprocessingFlag::eWELD_VERTICES` + `meshWeldTolerance`、clean-mesh、active-edge 預計算)、PhysX 5 SDF triangle mesh(`PxSDFDesc`)、Jolt `MeshShape` active edges(`mActiveEdgeCosThresholdAngle`)、Bullet `btInternalEdgeUtility`、Unity `MeshColliderCookingOptions`(`WeldColocatedVertices` / `EnableMeshCleaning`);Garland–Heckbert 1997 QEM、Jacobson et al. 2013 generalized winding number、Macklin et al. 2020 SDF 接觸。內部對照:現行逐三角形 SAT manifold 與盒近似。
> **優勢區**:(1)內部邊修正:地面由大量細三角形鋪成、物體越小越快時最明顯(接縫數隨三角形密度成長);(2)簡化:`candidates` 數與三角形數成比例,簡化後候選數與每步成本下降,代價是形狀誤差,所以必須成對報(候選數 / 步、靜置高度誤差);(3)SDF:細節越多(三角形 ≥ 1e4)越有利,接觸點數與三角形數脫鉤,對照組是 manifold 數隨接觸面積成長;誠實反面:低面數或大尺度平面,SDF 受格解析度限制反而輸。差異化處:烘焙內的共面 / 退化 / 符號判斷用 10.1 exact predicates,對照組多為 epsilon。
> **規模軸**:三角形數 ∈ {1e3, 1e4, 1e5, 1e6} × 烘焙時間(weld / simplify / SDF 解析度 32³–256³);接縫密度 × 滑行速度偏差;簡化比例 × 形狀誤差 × 候選數;SDF 解析度 × 取樣成本 × 記憶體。
> **seam?**:是 —— (1)球 / 膠囊對網格:解析三角形 manifold vs 現行盒近似,parity 條件 = 球落在三角面中心的靜置(法向對齊)時兩者靜置高度相等,分歧處(滾動、邊緣)以行為斷言記錄,屬能力差;(2)active-edge 修正 on/off:無內部邊的場景(單一大三角形 / 凸網格)逐位相同;(3)距離表示:`SdfGrid` 取樣 vs 精確三角形距離,差 ≤ 一個格對角線。bench:烘焙各階段時間、接縫滑行每步成本、SDF 取樣 vs `closest_point_on_triangle` 掃描;列入 `docs/CATEGORY.md` §2.1 的 trimesh / SDF 列旁。
> **交付**:接真路徑 —— 烘焙結果餵 `ContactScene6.add_trimesh`、`BroadPhase` 全 seam、17.13 查詢與 17.5 `voxelize`。普通:weld 後頂點數下降且表面位置不變(Hausdorff ≤ 容差);箱子滑過 2×N 三角形平地,速度無接縫擾動;簡化 100:1 後箱子靜置高度誤差 ≤ 容差;網格烘成 SDF 後與 `Sdf3.sphere` 解析值比對。整合:`bench_trimesh` 擴列;同一岩石網格簡化前後仍可被 `convex_decomp` 吃進去;被查詢結果與未烘焙網格一致(射線 / 最近點)。極端:退化三角形、重複頂點、T 接點、開邊 / 非流形邊、單三角形、空網格、全共面、極薄三角形、繞序混合、座標 1e6 量級、簡化到 1 個三角形、SDF 解析度 1³、網格含自交。
> **相依**:10.1(exact predicates)、17.5(`voxelize` / 凸分解)、17.13(最近點查詢機件)。
> **邊界**:SDF 作為 solver 形狀種類(`SHAPE_SDF`)、橢球、圓柱屬 17.52,本條只給記憶體內的 `SdfGrid`;動態凹體屬 17.44 + 17.5 凸分解;烘焙結果的落檔與稀疏體積交換格式屬 17.63;glTF / USD 讀檔屬宿主(平台方向 C);heightfield 的洞與對角線方向、17.30 的變形不在此條;與 17.19 的通用 contact reduction 分工 —— 本條只處理網格專屬的共面三角形接觸合併。與 17.85 無重疊。

> **進度(2026-10-13)**:
> - **烘焙管線** `geometry/mesh_bake.mojo`:`weld`(空間雜湊、容差內併入最早的頂點)、`repair`(退化 / 重複三角形、繞序以洪泛統一、開邊與非流形邊計數)、
>   `simplify`(QEM 邊收折,成本由小到大分批、邊界頂點不動、會翻面的收折拒絕、超過誤差預算即停)、`active_edges`(每三角形三個旗標:邊界或二面角 > 閾值)、
>   `bake_collision_mesh` + `BakeReport`。`test_mesh_bake` 24/24:分裂頂點的 4×4 格 96 → 25 頂點且表面不動;翻面 + 退化 + 重複的立方體修成 12 面、無開邊、
>   每條邊兩向各走一次;平 20×20 格 800 → 78 三角形、誤差 0、四角不動;起伏 24×24 格(1152)在 0.05 誤差預算下停在 446,每個原頂點離烘焙後表面 ≤ 0.0216
>   (報告誤差 0.0499)。
> - **Ghost collision**:實測先確認缺陷 —— 無摩擦箱子以 2 m/s 滑過切成 80 / 400 quad 的平地,1.5 s 後速度 −0.26 / 0.03、|vy| 最大 0.77(2 個三角形的地面則保持 2.0)。
>   `TriMesh.active`(預設全 active = 舊行為)+ `contact_gen._fix_inactive_edge_normal`:法向不是面法向、且點不在 active 邊上時,改用面法向。
>   `test_active_edges` 12/12:有旗標時 2 / 8 m/s 在 80 / 400 quad 上保持在 1e-3 內、|vy| < 1e-2;真的 90° 折角(牆)仍擋下箱子(停在 x = 9.73,牆 10);
>   全 active == 無旗標逐位相同。
> - **球 / 膠囊對三角形的解析 manifold**(取代 `as_hull` 的盒近似):實測先確認 —— 球在 20° 網格斜面(μ = 0.8)上 1 s 後速度 −0.0006(像方塊一樣不動),
>   應為 5/7 g sinθ t = 2.394。`sphere_triangle_manifold` / `capsule_triangle_manifold` 後 2.3941434(有 active edges;無旗標時接縫讓它少 1.5 %:
>   前方鄰三角形在共享邊給前下方的 speculative 法向,`_round_on_flat_seam` 對非 active 邊改用面法向與平面高度)。`test_mesh_round` 12/12:
>   靜置於面中心 y = 0.4997、平躺膠囊 y = 0.29999 且軸水平、以 3 m/s 滾過 400 quad 保持 2.99996(對照:無旗標 1.94)、共享頂點上靜置、單面三角形背面穿過。
> - **mesh → SDF** `geometry/sdf_grid.mojo`:`bake_sdf_grid`(res³ 節點、最近三角形距離 + 廣義 winding number 決定內外)、三線性 `distance` 與解析 `gradient`。
>   `test_sdf_grid` 10/10:512 三角形的球、24³,200 個隨機點與精確網格距離差最大 0.012(格對角線 0.226)、與解析 |p| − 1 差 0.024;開口半球中心 winding = 0.5000000。
> - **網格本地位姿**:`ContactScene6.add_trimesh(..., local=True)` 以 body 位姿放置一份網格資產(實例化);`test_mesh_round` 中同一片地磚放在原點與 (20, 1, 0) 轉 90°,
>   兩顆球各靜置於 0.4997 / 1.4997。
> - **bench** `bench_mesh_bake`(已入報告範本):8192 三角形 weld 7.5 ms、repair 7.3 ms、active edges 3.6 ms、simplify 21.1 ms;SDF 取樣 31.9 ns / 次 vs 掃描 512 三角形 16159 ns;
>   16³ 烘焙 181 ms(暴力)。`docs/CATEGORY.md` 加三列 seam。
> - **SDF 烘焙 BVH ✅(2026-10-13)**:`geometry/sdf_grid.mojo` `bake_sdf_grid_bvh`:中位切分三角形 BVH 求最近三角形(與暴力法同一最小值);
>   封閉網格(先以逐位相同座標焊接頂點 —— 逐三角形建的網格共用頂點是重複的)以面 / 邊 / 頂點的角度加權偽法向量(Bærentzen & Aanæs 2005)定號,
>   開放網格與面上的點退回 winding number。`test_sdf_grid` 11/11:封閉 512 三角形球、開放 256 三角形半球、128 三角形球在 res 20 每個節點與暴力烘焙逐位相同;
>   `bench_mesh_bake`:res 8 / 16:22.2 → 2.25 ms、154 → 10.0 ms(15.5×)。首版只用面法向量、未焊接,加速只有 1.3×(多數節點落到 winding 退路),已量。
> - **heightfield active edges ✅(2026-10-13)**:`HeightField.set_active_angle(angle)` 啟用後,`active(t)` 由格點推出三角形的鄰接(同格或相鄰格共用兩個角點)、
>   比較兩面法向,依目前高度即時算(`deform` 後仍正確);預設全 active,行為逐位不變。`test_active_edges` 15/15:0.5 m 格、8 m/s 無摩擦箱:無旗標 vx 0.086、
>   |vy| 最大 2.83(箱被接縫絆停;2026-10-14 `hull_manifold` 深度修正後為 0.79 / 2.83,仍被絆住);有旗標 7.99994、|vy| 5.2e-4;z 向 0.1 坡的格網上橫越 4 m/s → 3.997(坡上共面接縫不作用)。
> - **kinematic 移動網格 ✅(2026-10-13)**:`set_kinematic` 用在三角網格 body 上時記下其頂點的 body 座標;`step` 前後各把網格重放到 body 目前位姿
>   (`ColliderSet.move_trimesh`:頂點、BVH、world AABB 重建,active-edge 旗標保留),body 沒動的網格跳過。`test_kinematic_mesh` 6/6:8×8 格 4 m 平台以 1 m/s
>   上升 2 s,網格頂點 y 2.999998 = body、箱底間隙 −2.5e-5;平台以 1 m/s 橫移 1.5 s,箱子靠摩擦 vx 1.0000001;120 次重放後旗標不變;靜態網格不動;
>   teleport 後網格跟著走。成本 O(三角形) / 移動網格 / 步,給平台與門,不給整個關卡。
> - **`hull_manifold` 深度修正(collision,2026-10-13)**:做上面那條時量到 —— 箱子靜置在 8×8 格上、跨兩格(x = −0.05)會在約 70 步後從左側格子翻下並漂走
>   (2 s 後 x −0.07、y 1.2476;x = 0 與 x > 0 正常),靜態網格同樣發生,與 kinematic 無關。原因:SAT 軸來自 b(三角形)時,裁切點在三角形上、
>   深度卻用 a 的面「第一個頂點沿 n 的高度」當參考平面,所有點同一深度,箱子微傾時看不到自己哪一側在下沉,左側四個 manifold 全讀成分離。
>   改為沿 a 自己的面法向量量點到面距離再換算到 n;軸來自 a 時公式不變。9 個偏移 x = −0.2 … 0.2 靜置 2 s 最大漂移 3.7e-5。

#### 17.46 CCD 形狀覆蓋 — Wave B

> **狀態**:✅ 完成(CPU;2026-10-14:通用凸對凸 TOI、hull / 橢球 / 複合 / 靜態網格 / SDF 覆蓋、角向上界、swept-box BVH 配對、逐 body 模式、island 平行相容、軟體粒子射線掃;GPU 屬 17.17)。
> **進度註(2026-10-13)**:`physics/ccd6.mojo`:盒 / 球 / 膠囊兩兩之間仍走閉式 swept box(慢速路徑與既有輸出逐位相同,`test_ccd6` golden 不變);
> 任一方為 hull / 橢球 / 複合 / trimesh / heightfield 時走 `ca_fraction`:Mirtich 保守推進,距離取子形狀對的精確凸距離(`world_query.desc_distance` /
> `kid_distance`,網格取掃掠盒內的候選三角形),每步前進 距離 / (沿分離法向的接近速度 + |ω_i| r_i + |ω_j| r_j);起點即接觸時以兩見證點的實際法向速度判斷,
> 靜止 / 滑動 / 分離不夾(以無號的 |ω| r 判斷曾把轉離柱子的木板凍住)。配對:以每個 body 的掃掠盒(起點盒 ∪ 終點盒,加旋轉半徑)建 BVH,取代 O(n²)。
> 量測(`tests/test_ccd_shapes.mojo` 10/10):60 m/s(每步 1 m,牆厚 20 倍)hull 子彈有 CCD 停在 x −0.125、無 CCD 穿到 10.8;橢球 / 複合子彈停在 −0.125
> (無 CCD 亦被其投機接觸攔下);盒對單一四邊形 trimesh 牆停在 −0.11;雙臂複合木板以 36 rad/s 轉向細柱,有 CCD 最大 |ω| 36.0、無 CCD 升到 253
> (見下方發現);8 m/s 滑動 hull(μ 0)vx 保持 8.0;慢速 hull 落地 CCD 開關逐位相同;1e4 m/s 停在 −0.53;兩顆對撞子彈不互穿。
> bench `bench_ccd_shapes`(µs/步):hull 子彈 N = 1 / 16 / 128 關 7 / 841 / 17681、開 40 / 947 / 12524;靜止控制組 25 / 219 / 1699 對 16 / 226 / 2096
> (靜止體仍有微小速度而建 BVH,N = 128 多 23 %;待以位移門檻跳過)。
> **發現**:細長板以 36 rad/s 旋轉撞細柱、不開 CCD 時角速度升到 253 rad/s(單一盒板亦同,非複合專屬)。推出速度有上限(`max_push_speed` 4 m/s),
> 不是無界的偏置;是旋轉穿隧的後果 —— 板掃過柱的中面後接觸法向翻轉,每一步都把它往前推,4 m/s 上限的推力乘上長力臂累積成轉速。CCD 開時不發生(上表)。

> **現況**:CCD 是全域開關 `SolverConfig.ccd`(`physics/solver_config.mojo:57`),開啟才跑第二階段 `ccd_advance`(`physics/solver6.mojo:1333-1334`);第一階段的 speculative margin 在 `step` 中恆開(`physics/solver6.mojo:1233` 以 `dt` 當 `spec_dt`,`collision/contact_gen.mojo:72-77`)。
> `ccd_advance` 只做盒對盒的 swept-SAT:任一方是 hull / trimesh / heightfield 就整對略過(`physics/ccd6.mojo:55-57,75-77`,檔頭 `:33-45` 自述);球與膠囊以保守盒掃,「只會過早夾、不會錯夾」(`:33-37`);旋轉被忽略,只做線性掃掠(`collision/toi.mojo:18-20`);配對迴圈是 i 對全部 j 的 O(n²)(`physics/ccd6.mojo:61`)。
> 不相容與缺漏:`cfg.parallel` 遇 ccd 退回串行並計 `PARALLEL_FALLBACK_SERIAL`(`physics/solver6.mojo:1244-1251`);GPU 剛體 solver 拒絕 `cfg.ccd`(`physics/gpu_contact.mojo:347`);軟體粒子對 hull / mesh / heightfield 沒有 ccd 掃(`physics/soft_couple.mojo:121-127`);沒有逐 body 旗標,grep `is_bullet|ccd_flag|ccd_enabled|motion_quality|angular.?ccd` 零命中。
> 現成機件與缺口:`world_query` 有 conservative advancement 的球 / 膠囊掃掠,但屬查詢、距離為下界(`collision/world_query.mojo:17-23`);`geometry/gjk.mojo` 的 `gjk_query` 只回傳是否相交(`:98-126`),grep `distance|closest`(該檔)零命中 —— 沒有凸對凸的分離距離,所以通用凸形的保守推進缺最關鍵的一塊。既有測試與量測:`tests/test_ccd6.mojo`(子彈對牆、TOI 單元)、`benchmarks/bench_ccd.mojo`(盒對盒,`docs/CATEGORY.md:56`)。
> **缺口**:
> - **形狀覆蓋**:球、膠囊的精確 TOI;hull 的 TOI(例:17.5 的碎片 hull 以高速撞薄牆);對 trimesh / heightfield 的 TOI(高速車 / 子彈穿越薄殼地形,speculative margin 之外)。
> - **通用凸對凸 TOI**:以 GJK 分離距離做保守推進(Mirtich 1996;距離輸出由 17.53 交付,本條只消費,不另寫一份);對網格逐候選三角形(重用中域)。
> - **角向 CCD**:目前旋轉被忽略,高速旋轉的細長體(門板、螺旋槳葉、棍棒)會穿透;以位移上界 `|v| + |ω|·r_max` 保守推進,或以螺旋運動求 TOI。
> - **逐 body 旗標與啟用策略**:單步位移超過自身最薄特徵 × 係數才進 CCD;子彈旗標;與已有的過濾 / sensor 規則一致。
> - **配對枚舉**:O(n²) 改走既有 `BroadPhase`(以掃掠 AABB;不新增 broadphase 種類)。(例:1e4 個子彈體的 CCD 配對不再是 5e7 對)
> - **與 island 平行 / colored 相容**(每 island 局部 frac),不再退回串行;軟體粒子(點)對 hull / mesh 的射線掃。
> **對照組**:Box2D v3(對靜態的 TOI 與 bullet 旗標)、Bullet(`btConvexSweepTest`、motion clamping)、PhysX(`eENABLE_CCD` / speculative CCD / `eENABLE_CCD_FRICTION`)、Jolt(`EMotionQuality::LinearCast`)、Rapier(`ccd_enabled`);Mirtich 1996 conservative advancement、Redon et al. 2002 螺旋運動連續碰撞、Coumans / Catto 的 GDC 2013 連續碰撞演講。內部對照:現行 speculative(一階)+ 盒 swept-SAT(二階)。
> **優勢區**:`ScrewBody6` 每步的位姿更新本來就是一個定螺旋 `exp_screw3`(`physics/rigid6.mojo:347-349`),螺旋運動 TOI 的運動模型與積分器一致,對照組多半用線性插值或角度近似。優勢區 = 高速旋轉 × 細長 × 薄牆(線性 CCD 抓不到的角向穿透);對 hull / mesh 的優勢區 = 薄殼(牆厚 < 單步位移)。反面:慢速場景 CCD 純屬成本,慢物體路徑須維持與現況逐位相同(現有保證延續),並量 N=1 控制組。
> **規模軸**:(單步位移 / 最薄特徵)∈ {0.5, 1, 4, 16, 64} × 形狀組合(盒 / 球 / 膠囊 / hull / mesh)× 物體數 n(O(n²) vs broadphase);角速度 × 長寬比;ccd 開 / 關每步成本。
> **seam?**:是 —— 擴充 `docs/CATEGORY.md:56` 既有的 CCD 列(speculative vs swept):TOI 求解變體 = 盒專用 swept-SAT(閉式)vs 保守推進(GJK 距離,通用凸)vs 角向螺旋上界。parity:盒對盒兩者 TOI 差 ≤ 容差(保守推進必 ≤ 精確值);球對球 / 球對盒對解析閉式;慢速路徑逐位相同。bench:每對 TOI 成本 × 形狀對。
> **交付**:接真路徑 —— `ContactScene6.step` 的 `cfg.ccd`,與 broadphase seam、island 平行、睡眠、過濾 / sensor 並存。普通:球 / 膠囊 / hull 各一例以 20× 厚度的單步位移撞薄牆不穿透。整合:17.4 車輛高速越過薄 heightfield 裂縫;17.5 碎片 hull 打薄牆;`cfg.parallel` 加 ccd 時 `PARALLEL_FALLBACK_SERIAL` 不再增加;旋轉門板撞細柱。極端:起始已重疊(t = 0)、零位移、相切擦邊、NaN 速度、1e4 m/s、兩個快物互撞、一物同時撞多面取最早、單三角形薄牆、1e3 體高速鏈。
> **相依**:17.13(conservative advancement 機件)、17.5(hull 碎片是主要受益者)、17.19(硬化量測)、17.53(凸對凸距離與查詢擴充共用)、17.52(新形狀種類需補 TOI)。
> **邊界**:候選配對只重用現有 `BroadPhase`,不擁有增量維護 —— `update_moved`、awake list、per-island 品質屬 17.85;GPU CCD 屬 17.17;`ccd_advance` 掃描本身的多執行緒化屬 17.54(本條只負責移除 `PARALLEL_FALLBACK_SERIAL` 退路);軟體 / 流體本體的連續碰撞不含(僅含軟體粒子對剛體 hull / mesh 的點掃);單步旋轉超過 π 的子步切分不含。

> **進度(2026-10-14)**:
> - **逐 body 模式 ✅**:`set_ccd_mode(id, CCD_AUTO | CCD_OFF | CCD_BULLET)`;BULLET 在 `cfg.ccd` 關時仍掃、且對每個候選不走「跳不過最薄特徵」捷徑,
>   OFF 永不夾(仍是別人的障礙);模式進快照 format 5。60 m/s hull:BULLET + 全域關 停在 −0.125;OFF + 全域開 穿到 10.8。
> - **island 平行相容 ✅**:`cfg.parallel` + CCD 不再退回串行:每個 island 的子步跑 `ccd_advance_island`(只動本 island 成員,候選 = 成員 + 靜態 body;
>   靜態位姿在步內不變,平行無資料競爭;跨 island 的對在本步沒有投機接觸,不掃)。8 顆子彈打 8 面靜態牆:平行 vs 串行逐位相同、`PARALLEL_FALLBACK_SERIAL` 0。
> - **軟體粒子對 hull / mesh / heightfield 等的射線掃 ✅**:`ccd` 開時位移超過半徑的粒子以 `world_query.ray_collider` 掃過該碰撞器,先停在第一個表面,
>   再做最近點推出。120 m/s 軟方塊打薄 hull / 單四邊形 trimesh 牆:無 CCD 穿到 x 9.2、有 CCD 停在 −1.02 / −1.00。
> - **SDF 的 TOI ✅**:`_dist_at` 對 SDF 以子形狀核心點(+ 半徑)取格點距離。300 m/s hull 打 0.2 m SDF 板停在 −0.196 —— 但量到無 CCD 時 SDF 的投機接觸
>   已在 −0.199 攔下,找不到穿隧的對照案例;此路徑是後備。
> - **待辦**:無(CPU)。tier 路徑遇 CCD 仍退回(`TIER_FALLBACK`);GPU 屬 17.17。

#### 17.52 形狀種類 — Wave B(承接 13.8 的剩餘部分)
> **狀態**:✅ 完成(2026-10-13:圓柱、凸包接觸點分散選取、SDF 作為 solver 形狀(格點場)、橢球、support-mapping 凸形入口、`Sdf3` 與格點場共用的 `DistanceField3`)。
> 不做 / 移出:SDF 對 SDF —— solver 的 SDF 只能是靜態,兩個靜態體不成對,無分派可做;動態 SDF 剛體屬 17.44(複合 / 凹體)。
> 圓柱端面仍是 16 邊形 hull(側面接觸已由膠囊流形精確、點到圓柱查詢由 `SupportCylinder` 精確,端面多點接觸片需要多邊形);
> 端面改走解析 support 須先有 support-mapping 的多點接觸片生成,留作 17.50(接觸模型變體)的子題。
> **進度註(2026-10-13,共用距離場介面)**:`trait DistanceField3`(`geometry/distance_field.mojo`:`distance`、`gradient`),`Sdf3` 與 `SdfGrid` 皆實作;
> `sphere_trace[F]` 共用(世界查詢 SDF 射線改呼叫它),`SdfGrid.from_field[F]` 把任一場(解析、CSG)取樣成 solver 用的格點。
> 量測(`tests/test_distance_field.mojo` 8/8):單位球從 5 m 外,解析 t 4.0(1 步)、41³ 格點 t 3.999996(9 步);300 點格點對解析最大差 0.0061(格距 0.1);
> 盒減球 CSG 的腔壁 t 0.6(解析)/ 0.599994(61³ 格點);`from_field(Sdf3.plane)` 與手填格點節點值逐位相同、盒靜止高度逐位相同 0.24972449。
> **進度註(2026-10-13,橢球 + support mapping)**:`trait Support3`(`geometry/gjk.mojo`:`support_point(d)`、`center_point()`),`ConvexPoly[3]` 與
> `geometry/support.mojo` 的 `SupportEllipsoid` / `SupportCylinder` / `SupportCapsule` / `SupportBox` 皆實作;`epa3`(原 `_epa3[dim]`,現對任兩個 `Support3`)
> 與 `support_distance`(GJK 距離,與點雲 `convex_distance` 共用驅動;單純形改固定四格,每次迭代不再配置,`support_distance` 橢球對盒 16 µs → 1.4 µs;
> 解析形停止準則相對 1e-6 + 絕對 0.1 µm,點雲維持 1e-10 不變)。`SHAPE_ELLIPSOID = 7`、`ContactScene6.add_ellipsoid(b, radii)`、
> `Inertia3.ellipsoid`、`set_mass_from_density` 支援;接觸 `collider_set.support_manifold`(GJK 距離 < margin → 投機點;重疊 → EPA)一點,
> 對 box / sphere / capsule / hull / 圓柱(解析 `SupportCylinder`)/ 橢球;對 trimesh 逐三角形;對 SDF 以梯度方向 support 點兩次細化。
> 接觸錨點:橢球側每個 substep 以目前姿態取法向 support 點(`contact6.anchor_world` 的 `e` / `toward`),固定世界偏移(球的做法)讓搖擺橢球
> 4 s 內能量 +2.6 %(60 Hz),改後 −0.3 %。查詢:`point_distance`(GJK / EPA)、`_ray_one`(縮放空間的單位球解析解)、`shape_distance` / `shape_cast`。
> 軟體粒子:`soft_particle_contact` 橢球分支。CCD:以 `half` 盒近似(同球,屬 17.46)。
> 量測(`tests/test_ellipsoid.mojo` 17/17、`tests/test_support3.mojo` 11/11):等軸橢球靜止 y 0.4997246 對球 0.49972457;斜面滾動 1 s 2.3941412 對球 2.3941434、
> 5/7 g sin θ 2.3941412;(1, 0.5, 0.7) 躺 y 0.4997246;長橢球 45° 釋放(角阻尼 2)躺平軸·上 0.0033;無阻尼搖擺中心最高 0.4301 < 釋放 0.4305;
> 射線 t 4.5 / 4.0(解析);點距 1.5、內點 −0.09997;10:1 圓盤 y 0.0997。點到 r = 1 圓柱:解析誤差 0,16 邊形 hull 0.0192 = r(1 − cos(π/16))。
> 成本(`bench_shapes`,64 / 256 體,每 body-step):球 6–7 µs、橢球 25–30 µs、16 段圓柱 38–39 µs、盒在盒上 24–27 µs、盒在 SDF 上 31–33 µs。
> 圓柱原量到 0.43–1.25 ms 且隨 N 上升:`step_soft` 預設不走 broadphase,暴力迴圈把每一對都交給窄相(64 圓柱 + 地板每步 2080 次 hull 測試),
> 盒對盒在 SAT 內很快就拒絕、hull 對卻跑完 GJK。暴力迴圈現先以 broadphase 用的同一組 fat AABB 篩(兩條路徑看到相同的配對;
> 此盒並非所有投機接觸的嚴格超集 —— 旋轉盒沿自身軸膨脹最多超出 √3 倍 margin、hull 對可回報相距 9 cm 的投機接觸,這些遠對過去只在暴力路徑進窄相,
> 現兩路徑皆不見;`test_fracture` 磚堆 island 17 → 16;`NARROWPHASE_PAIRS` 仍計列舉的候選對),64 圓柱每步 18 ms → 2.4 ms。
> **進度註(2026-10-13,SDF 形狀)**:`SHAPE_SDF = 6`(`collision/collider_set.mojo`),`ContactScene6.add_sdf(b, SdfGrid)`(世界座標,同 `add_trimesh`)。
> 接觸 `contact_gen.try_sdf_pair`:取凸側樣本點(球心;膠囊軸上 5 點;盒 26 點 = 8 角 + 12 邊中點 + 6 面心;hull 頂點),
> 距離 < 半徑 + margin 者為候選,`hull.spread4` 選至多 4 點,法向 = 深度加權梯度平均。查詢:`point_distance`(三線性距離 + 梯度)、
> `_ray_one`(sphere tracing,步長 0.9 × 距離)、`shape_distance` / `shape_cast`(取樣點 + 保守推進)、`closest_points`(同 mesh)。
> 軟體粒子:`soft_particle_contact` SDF 分支。存檔:`write_state` / `read_state` 側表(res、origin、cell、values;res 上限 512)。CCD:跳過(同 hull / mesh,屬 17.46)。
> 量測(`tests/test_sdf_shape.mojo`,12/12):球 r 0.5 靜止 y 0.49972454;盒 half 0.25 在 13³ 與 49³ 格點皆 4 接觸點,y 0.24972449 / 0.24972433,
> 對解析盒地板 0.24970722(差 1.7e-5);20 盒落入 SDF 碗 5 s 後最大速度 0.0;射線 t 4.99995(期望 5);存檔還原後逐位相同;
> 8 m/s 球最低 y 0.2997(不穿透);橫躺膠囊 y 0.29988545。另含 `tests/test_capi.mojo` 在 macOS 改用 `nm -g -U`(17.76 移植性)。
> **現況**:
> - solver 的形狀種類只有六種(`collision/collider_set.mojo:37-42`:box / sphere / capsule / hull / trimesh / heightfield);
>   `pair_manifold`(`collider_set.mojo:382`)對前四種窮舉,未知種類走 `abort`(`collider_set.mojo:484`)。
> - SDF 在 `geometry/sdf3.mojo`:四種基元(`:25-28` sphere / box / plane / capsule)+ 兩層 CSG(`:30-33`、`:37`),
>   距離 `Sdf3.distance`(`:121`)、梯度為中央差分 `H=1e-3`(`:134`);接觸是**單點**梯度下降 `sdf_contact`(`:156`,回傳單一 `SdfContact`,`:149`)。
>   `Sdf3.center` 是世界座標、沒有朝向欄位(`:37` 起的欄位表),不能直接當「有姿態的剛體形狀」。
> - SDF 沒接進引擎:grep `sdf3|Sdf3`(`*.mojo`,排除 build/.pixi/.claude)只命中
>   `geometry/sdf3.mojo`、`tests/test_sdf3.mojo`、`benchmarks/bench_sdf3.mojo`,引擎套件零 import;
>   BENCHMARK_REPORT「Collision — 3D signed distance fields」 自己寫「NOT yet wired into `solver6`」。13.8 校正註提到的 `SDFNarrowPhase`(`collision/narrowphase.mojo:158`)是 **2D**(`dim = 2`,吃 `geometry/sdf.mojo` 的 `Vec2` 場),
>   只被 `benchmarks/bench_collision.mojo:174` 使用,不是 3D solver 形狀的替身。
> - 量到的代價:SDF 球對球 195.7 ns vs 解析 7.9 ns(約 25×,BENCHMARK_REPORT「3D SDF contact vs the analytic pairs」);CSG(盒挖球)對球 828.6 ns,
>   無解析對照組(`:272`)。迭代上限 8/16/32 幾乎沒差(同表),因為單位梯度基元一步收斂。
> - 橢球 / 圓柱**沒有任何形狀程式碼**:grep -i `ellipsoid|cylinder`(`*.mojo`)只命中兩處 docstring
>   (`physics/rigid6.mojo:72`「cylinder + two hemispheres」、`geometry/dcga.mojo:24`),`Inertia3` 只有
>   `box` / `sphere` / `capsule` 三個建構子(`physics/rigid6.mojo:52-84`)。
> - 13.8 原交付物 `test_sdf_narrowphase` 不存在(`ls tests | grep sdf_narrow` 零命中);狀態校正見 ROADMAP §13.8。
> - 凸形接觸路徑吃的是**點雲**:`ConvexPoly` 只是 `List` 頂點(`geometry/gjk.mojo:19-26`),hull 路徑用 GJK+EPA 取法向再自建接觸片
>   (`collision/hull.mojo:11-24`);沒有「以 support function 描述的解析凸形」入口。
> - 新增一種形狀必須逐一補的分派點(本條的實作清單):`collider_set.mojo` 的 `pair_manifold`(`:382`)/ `as_hull`(`:342`)/
>   `hull_faces`(`:326`)/ `fat_aabb`(`:494`);`physics/ccd6.mojo:56,76`(hull/mesh/heightfield 被跳過,其餘種類以 `half` 當盒做 TOI);
>   `physics/soft_couple.mojo:111`(軟體粒子對碰撞器);`collision/world_query.mojo:187`(`point_distance`)與 `:483`(`_ray_one`);
>   `physics/solver6.mojo:1444-1486`(`write_state`)與 `:1628-1646`(`read_state`)。
> **缺口**:
> - **SDF 作為 solver 形狀**(新種類 `SHAPE_SDF`):側表存場資料(比照 hull 的 `hulls` / `hull_id`,`collider_set.mojo:80-81`);
>   以局部座標求值再把梯度轉回世界;`half` 取保守包圍盒;**多點 manifold**(在最深點周圍取樣場,取代單點;
>   BENCHMARK_REPORT「Collision — 3D signed distance fields」 的既有設計意圖;`ContactManifold` 上限 4 點,`collision/manifold.mojo:5`);
>   SDF 對解析形狀(球/盒/膠囊/hull)與 SDF 對 SDF 的分派;(例:程序化地形 SDF 上堆 20 個盒子能靜止,接觸數與場解析度無關)。
> - **取樣式 SDF(體素 / 格點場 + 三線性內插 + 解析梯度)**:現在只有解析基元;烘焙(mesh → SDF)由 17.45 提供,本條只定義消費端介面
>   (例:同一 trait 同時吃 `Sdf3` 與格點場,sphere tracing 查詢共用)。
> - **橢球**:解析 support function(球經仿射映射)、對平面/球/盒的接觸、慣量 `Inertia3.ellipsoid`(對角主慣量 m/5·(b²+c²)…)、
>   AABB;(例:長軸 2:1 的橢球在斜面上滾動,接觸點隨曲率移動)。
> - **圓柱**:解析 support function、**接觸片**(端面圓盤取樣 + 側面線接觸;單點會讓平放圓柱搖晃,同 hull 的理由,`collision/hull.mojo:11-17`)、
>   慣量 `Inertia3.cylinder`;(例:圓柱站立 / 側放 / 斜靠牆三種姿態都能靜止)。
> - **support-mapping 凸形入口**(`trait ConvexSupport`:點雲 hull 與解析 support 共用 GJK/EPA),取代「把圓柱/橢球取樣成 hull」的權宜法;
>   例:圓柱 = 32 邊形 hull 的近似誤差 vs 解析 support。
> - 查詢側:`point_distance` / `_ray_one` 補三種新種類(SDF 的 sphere tracing 與現有 capsule 分支的保守推進同型,`world_query.mojo:556-565`);
>   存檔側:SDF / 格點場進 `write_state` 側表;軟體粒子側:`soft_particle_contact`(`collider_set.mojo:530`)補三種。
> **對照組**:MuJoCo(ellipsoid / cylinder 為原生 geom;SDF 以梯度下降求接觸 —— 13.8 原設計即此路線)、Jolt(`CylinderShape`、`ConvexRadius` 與 support-function 為基礎的 GJK)、
> Bullet(`btCylinderShape` / `btMultiSphereShape`)、Rapier(cylinder / cone / round shapes)、UE Chaos(`FImplicitObject` 家族含 Cylinder / LevelSet);
> 論文:Macklin et al. 2020〈Local Optimization for Robust Signed Distance Field Collision〉(I3D)、van den Bergen 的 support-mapping GJK。
> **優勢區**:SDF —— 接觸數與成本跟網格解析度脫鉤、可表示 CSG / 程序化 / 雕刻幾何而不經網格(`geometry/sdf3.mojo` 檔頭論證);劣勢區 = 有解析解的對(實測 ~25× 慢),
> 所以規模軸必須包含「SDF 對解析對」的**劣勢端**,不只展示 CSG 這種解析根本無法表達的優勢端(優勢區規則)。
> 橢球 / 圓柱 —— 解析 support 免去取樣 hull 的近似誤差與頂點數成本;GA 側的假說(DCGA 的 Darboux 二次曲面族含橢球,`geometry/dcga.mojo:24`)目前只有「軸對齊的 incidence 測試」(`:31`),
> 不能當作接觸優勢主張,先量再說。
> **規模軸**:(a)SDF 求值成本 × 梯度下降迭代數 × 場解析度(格點場 32³ → 256³);(b)形狀複雜度(基元 → CSG → 取樣場)× 接觸點數;
> (c)圓柱 / 橢球解析 vs 取樣 hull 的頂點數(8 → 128)對應的接觸誤差與 ns/pair;(d)堆疊規模:20 / 200 個新形狀的靜止漂移。
> **seam?**:是 —— 同一個幾何的**多種表示**互為變體:球 = 解析球 = SDF 球 = 三軸相等的橢球;圓柱 = 解析圓柱 = 高解析度 hull;盒 = 解析盒 = SDF 盒。
> parity 條件:SDF 球對球 / 球對盒的深度與法向對解析路徑 ≤ 1e-6(沿用 `test_sdf3` 校準);橢球三軸相等時對球**逐位或 ≤1 ulp**一致;圓柱 vs N 邊形 hull 的接觸深度隨 N 單調收斂;
> 堆疊(5 個)靜止高度各表示之間 ≤ slop。bench 每種新種類一列,放進 `scripts/benchmark_report.md.in`,並在 `docs/CATEGORY.md` §2 補 seam 列。
> **交付**:`collision/collider_set.mojo` 新種類 + `geometry/` 的橢球 / 圓柱 support 與慣量,**全部經 `ContactScene6.add_*` 進 solver6**(不得再出現「有碼未接線」)。
> 普通:SDF 球落在平面 / 橢球落在平面 / 圓柱落在平面,靜止高度對解析值;SDF 球對解析球 parity。
> 整合:SDF 地形上堆盒 + 與 hull / mesh 同場景;存檔→還原→續跑逐位相同(`write_state` 路徑);軟體粒子落在 SDF 上;`world_query` 對新種類的 ray / 距離 / 掃掠與 `point_distance` 一致;`pixi run gate` 既有 golden 各段**完全不變**,只多新測試段。
> 極端:退化 SDF(全空 / 全實心 / 梯度為零的平坦區)、SDF 邊界上的種子點、橢球軸比 1:1000、扁平圓柱(高 ≪ 半徑)與細長圓柱、圓柱端面與 box 面完全共面、場外查詢、
> 高速撞擊(此時 CCD 仍視為盒,範圍見邊界)。
> **相依**:13.8(校正註)、17.45(mesh → SDF 烘焙是格點場的來源)、17.44(複合形狀可含新種類)、17.46(新種類的 CCD)、17.50(接觸模型變體可能影響 manifold 形狀)、
> 17.53(查詢補齊)、12.1(存檔格式凍結前先定新種類的側表編碼)。
> **邊界**:mesh → SDF 烘焙屬 17.45;新種類的**掃掠式 CCD**(TOI)屬 17.46 —— 本條完成後它們在 CCD 路徑上暫以 `half` 盒近似(`physics/ccd6.mojo:56,76` 的既有保守做法),須在 17.46 之前於檔頭寫明;
> 複合 / 多形狀剛體屬 17.44;GPU 端新種類(`physics/gpu_contact.mojo`)不在本條。

> **進度(2026-10-13)**:
> - **圓柱**:`ContactScene6.add_cylinder(b, r, hl, is_static, segments = 16)` + `Inertia3.cylinder`(另加 `Inertia3.ellipsoid`)。幾何為 n 角柱 hull
>   (端蓋與查詢);躺在盒上時(hull 法向與軸夾角 > 60°)側面接觸改用同軸同半徑的膠囊 manifold,並以 17.19 的圓形錨點(`round_core` 依法向判斷側面 / 端蓋),
>   所以滾動是圓柱而不是多邊形。實測先確認缺陷:純 hull 圓柱沿 20° 斜面 1 s 後 1.866 / 1.986 / 2.077 m/s(16 / 32 / 64 段),解析 ⅔ g sin θ = 2.2345;
>   修正後 2.2345238(與段數無關)。
> - **凸包接觸點選取**(既有缺陷,所有面多於 4 頂點的 hull):`hull_manifold` 原本取裁切多邊形的前四點,32 段圓柱端蓋四點全落在同一段弧上、站立時傾倒;
>   改為 `_spread4`(最深、離它最遠、離兩點連線最遠、連線另一側面積最大),≤ 4 點時順序不變(盒面結果逐位不變)。另查到 `HullShape` 每面最多保留 16 頂點、
>   最多 30 面,32 段端蓋被截成半圈,故 `segments` 夾在 [3, 16]。
> - **測試** `test_cylinder` 7/7:滾動 2.2345238(解析 2.2345319,8 段 2.234532);r 0.3、hl 0.7 站立 y = 0.6999、軸 y = 1.0;躺下 y = 0.2995;
>   慣量公式;64 段請求得 16 段;三角柱站立。
> - **橢球**:以 hull 細分超過 30 面上限,接觸幾何會被截斷,故本輪不提供 `add_ellipsoid`(只給慣量),待 support-mapping 接觸入口。

#### 17.53 查詢擴充 — Wave A(承接 17.13 的待辦)
> **狀態**:✅ 完成(CPU;2026-10-14:凸形掃掠 / 重疊、距離與最近點對、all-hits / any-hit、命中三角形與重心座標、單面選項、mesh BVH / heightfield DDA 射線遍歷、持久預篩 `QueryIndex`、批次派發、角色盒形選項、命中 / 載具輪表面材質、批次平行加速(LBVH + 共用 index)、CGA 假說(否定)✅;GPU 批次對真實形狀屬第 7 層)。
> **現況**:
> - 查詢有**兩套互不相通**的層。`collision/queries.mojo` 的 `SceneQuery`(`:28-32`:`rebuild` / `raycast` / `overlap`)有四個索引後端
>   (brute `:101`、BVH `:127`、grid `:155`、tree `:183`),只打 `BoxProxy` 的 AABB、`raycast` 只回最近一筆;
>   但它**在引擎內零使用**:grep `SceneQuery|BvhQuery`(`physics gameplay collision`,排除 `collision/queries.mojo` 本身)只命中
>   `collision/world_query.mojo:3` 與 `collision/gpu_raycast.mojo:19` 兩處 docstring。
> - 產品路徑是 `collision/world_query.mojo`(打真實幾何):`point_distance`(`:187`)、`nearest_surface`(`:266`)、`segment_distance`(`:297`)、
>   `overlap_capsule` / `overlap_sphere`(`:344` / `:354`)、`capsule_penetrations`(`:360`)、`capsule_cast` / `sphere_cast`(`:377` / `:418`)、
>   `ray_cast`(`:568`)、`ray_cast_batch`(`:587`);經 `ContactScene6` 薄包裝(`physics/solver6.mojo:643-682`)。
> - 候選收集是**線性掃描**(`_candidates`,`world_query.mojo:150-159`),且每次查詢都重建全部姿態(`query_poses`,`physics/solver6.mojo:644-648`,除 `closest_point`(`:675`)外每個包裝皆呼叫);
>   17.13 進度註自己記錄 N≥256 起被此線性前置工作主導、待辦為「持久 broadphase 預篩 + 姿態快取 + 四索引 seam parity」(ROADMAP §17.13)。
> - 只有球 / 膠囊能當掃掠形狀(`world_query.mojo:377,418`);grep `box_cast|hull_cast|convex_cast|shape_cast|overlap_box|overlap_hull|closest_points|ray_cast_all|raycast_all|ray_cast_multi|any_hit`
>   (`collision physics gameplay geometry`)**零命中**。
> - `ray_cast` 只回最近一筆(`world_query.mojo:568`);`Hit` 只有 `hit/body/t/point/normal/start_solid`(`:77-87`),**沒有三角形 / 特徵 / 材質 id**。
> - 射線對 trimesh / heightfield:以「射線線段的 AABB」收集候選再逐三角形測(`world_query.mojo:543-555`),沒有 BVH 射線遍歷、heightfield 沒有格線 DDA;
>   法線被翻成面向射線(`:552-553`),即永遠雙面,無單面選項。
> - GJK 只回 hit/miss 與終止單純形(`geometry/gjk.mojo:101-125`);EPA 只給**穿透**見證點(`geometry/epa.mojo:149-165`);**分離時的距離 / 最近點對**無 API。
> - `QueryFilter` 為類別遮罩 + 單一 `ignore` 索引 + sensor 開關(`world_query.mojo:59-73`);`ray_cast_batch` 是序列迴圈(`:587-597`);
>   GPU 路徑 `gpu_raycast.mojo` 只對 AABB 代理(檔頭 `:1-20`),不碰真實形狀。
> - 呼叫端:角色控制器的移動 / 階梯 / 落地探測全走**膠囊**掃掠(`gameplay/character.mojo:96-98` 的 `_cast` → `capsule_cast`,用於 `:148,178,186,190,242`)+ `capsule_penetrations`(`:108,209`),
>   另有一支向下 0.1 m 的射線取地面法向(`:230`);載具輪有 ray / sphere / capsule 三種 `WheelCast`(`gameplay/vehicle_wheel.mojo:98` 為 ray 輪)。角色形狀因此被限制為膠囊。
> **缺口**:
> - **一般凸形掃掠 / 重疊**:box / hull(以及 17.52 的新種類)作為查詢形狀(例:角色用盒掃過一階 0.3 m 的階梯,球 / 膠囊近似會多報或漏報稜角)。
>   可用 support-mapping + 保守推進,box 對 box 有現成 `swept_box_toi`(`collision/toi.mojo:42`)。
> - **距離 / 最近點對**:任意兩個碰撞器(或碰撞器對查詢形狀)的分離距離與雙側最近點(例:AI 判斷「伸手可及」、IK 腳掌找最近面);GJK 增 closest-points 輸出。
> - **多重命中與提前結束**:ray / sweep 的 all-hits(依 `t` 排序、數量上限)與 any-hit(例:子彈穿透數層牆、視線檢查只需知道有無遮蔽)。
> - **命中中繼資料**:三角形 / heightfield 格索引、重心座標、(接 17.23 材質)表面材質 id(例:腳步聲與彈孔依表面材質)。
> - **單面網格選項**與背面剔除(例:雙面牆從背後射不應命中的單面平面)。
> - **ray 對 mesh / heightfield 的遍歷**:BVH 射線下降與 heightfield DDA,取代射線 AABB 候選(例:一條 1 km 對角線射線穿過 1024×1024 heightfield,現在候選 = 整個 AABB 內的所有格)。
> - **持久寬相預篩 + 姿態快取**(17.13 待辦),並決定 `SceneQuery` 四索引的去留:要嘛作為 `world_query` 的候選預篩後端(四索引結果集相等的 parity 補上),要嘛正式退役並記入 CATEGORY。
> - **批次查詢平行化**(`ray_cast_batch` 現為序列)與 GPU 批次對真實形狀(目前只有 AABB 代理)。
> **對照組**:UE Chaos scene queries(`LineTrace` / `Sweep` / `Overlap`,multi / single / test 三型)、PhysX `PxScene::raycast|sweep|overlap`(`PxHitCallback` 多命中)、
> Jolt `NarrowPhaseQuery`(`CastRay` / `CastShape` / `CollideShape` / `CollectTransformedShapes`,collector 模式)、Rapier `QueryPipeline`、Box2D v3 `b2World_CastRay|CastShape|OverlapShape`。
> **優勢區**:(a)**決定論** —— 同一查詢在 brute / BVH / grid / tree、序列 / 平行下結果集逐位相同(`SceneQuery` 既有 parity 慣例,`tests/test_queries.mojo:1-9`),對照組多只保證結果「等價」;
> (b)shape-sweep 可重用既有 15 軸 SAT / GJK-EPA / TOI(`docs/ROADMAP.md` 17.13 條目優勢區);(c)CGA 對圓形基元給閉式最近點的假說尚未驗證,列為待量測。
> 優勢區量測:批次 ray ≥ 1e4 條時 DBVH 預篩 vs 線性掃描的交叉點;shape-sweep vs 「射線近似」在薄牆上的穿隧率。
> **規模軸**:碰撞器數 {16, 256, 4096, 65536} × 每幀查詢數;射線長度 × mesh 三角形數 / heightfield 格數;每條射線的命中數;查詢形狀頂點數(hull 8 → 256)。
> **seam?**:是 —— 沿用既有 `SceneQuery` seam 的擴充(CATEGORY §2 既有列):每個新查詢對候選預篩後端(線性 / BVH / DBVH / grid / tree)**結果集逐位相同**,
> 序列 vs 平行批次逐位相同,BVH 射線遍歷 vs 現行 AABB 候選的最近命中相同;每個後端一列 bench 進範本。
> **交付**:`collision/world_query.mojo`(+ 必要的 `geometry/gjk.mojo` 距離輸出),經 `ContactScene6` 包裝可用。
> 普通:box 掃過 hull 階梯命中階面且 `t` 為解析值;all-hits 依序穿過三面牆;`Hit` 帶出正確三角形索引;球 vs 凸形最近點對對解析值。
> 整合:`gameplay/character.mojo` 增加盒形角色選項,`_slide` / `_try_step` / 落地探測經一般凸形掃掠(現為膠囊專用,接 17.1);載具輪取材質(接 `vehicle_wheel.mojo:98`);各預篩後端結果集相等;
> 平行批次 vs 序列逐位相同。
> 極端:零長度掃掠、起點已穿透(`start_solid`)、相切、退化三角形、單條查詢對 1e5 個碰撞器、射線沿 heightfield 邊界 / 沿三角形接縫、NaN / 零向量方向依錯誤政策處置(`docs/ARCHITECTURE.md` §2)。
> **相依**:17.13(已交付)、17.52(新種類進查詢)、17.54(批次平行用同一個可注入的 fan-out)、17.45(mesh BVH 品質)、17.23 材質(材質 id)、17.46(共用掃掠機件)。
> **邊界**:導航網格 / AI 視線與 EQS 屬 17.14 / 17.15(它們消費本條);渲染拾取與可見性剔除不在本 repo(無渲染層);通用「查詢結果快取」已被排除(ROADMAP §17.23–17.41 增補「拒絕(5)」);
> 軟體 / 流體粒子對查詢的覆蓋屬各自條目;broadphase 本身的增量更新(`update_moved`)屬 17.85,本條只消費持久寬相做查詢預篩。

> **進度(2026-10-13)**:
> - **距離 / 最近點對** `geometry/gjk_distance.mojo`:GJK 距離形式(單純形最近點 + 重心權重,Float64 計算),形狀 = 核心點雲 + 半徑
>   (球、膠囊、盒、hull、三角形同一入口)。`test_gjk_distance` 15/15:兩單位立方體相距 3 → 1.0、見證點在相對面;球離角 1.2320508(解析同);
>   斜交膠囊 1.5;300 組隨機點雲每組以「見證點相距 dist(上界)+ 過見證點的兩平面分開兩雲(下界)」證明,最大偏差 2.4e-7。
>   第一版兩個錯:原點落在四面體內時權重數少一個(越界)、捨入時退回舊 v 但單純形已前進(見證點不一致);以每步前快照修正。
> - **查詢**(`collision/world_query.mojo`,經 `ContactScene6` 包裝):`QueryShape`(box / sphere / capsule / hull)的 `shape_cast`
>   (逐候選 Newton 步進:平移下凸集距離是 t 的凸函數,d + d'·Δt 不會越過根;停在半個 skin 外,法向才有定義)、`overlap_shape`、
>   `closest_points`、`ray_cast_all`(依 t / body / 三角形全序、上限)、`ray_cast_any`;`Hit` 加 `feat`(三角形索引)與 `bary`;
>   `QueryFilter.one_sided()` 跳過從背面命中的三角形。
> - **射線遍歷**:mesh 以三角形 BVH 下降(`BVH.ray_leaves`),heightfield 以格線 DDA(`HeightField.ray_candidates`,高度範圍外的格略過),
>   取代線段 AABB 候選。1 km 斜射線越過 1024×1024 地形:候選 88 vs 1,457,456。
> - **持久預篩** `QueryIndex`(一幀的姿態 + 碰撞器世界盒 BVH,候選依索引排序)與 `ray_cast_batch`(一次建 index、64 條一組派發)。
>   `SceneQuery` 的去留:保留為 broadphase 代理層的查詢 seam(既有 parity 測試),真實幾何查詢走 `QueryIndex`,兩者不接。
> - **順帶修正**:`ColliderSet.fat_aabb` 對膠囊不保守 —— `half` 是 (r, hl, r),盒子停在線段端點、少了端蓋半徑;index 查詢有一條射線打中端蓋卻不在盒內
>   而漏掉(線性掃描靠射線 AABB 較寬才沒露出)。broadphase 用同一個盒,膠囊端蓋接觸同樣可能漏候選;修正後全套 golden 見提交。
> - **測試** `test_query_ext` 19/19:0.5 m 盒沿 +x 掃向 hull 階面 t = 2.75(解析 3 − 0.25)、法向 −x;轉 0.3 rad 的盒落到階頂 t = 1.45(解析);
>   三面牆 all-hits t = 2 / 5 / 9、上限 2 留前兩個;mesh 命中的重心座標重建命中點;單面濾掉背面;300 條射線 mesh BVH 與 heightfield DDA 都找到與逐三角形
>   暴力相同的三角形(t 差在 1e-5 內:測試自己的 Moller-Trumbore 與套件分開編譯,末位捨入不同);兩球最近點 3.5;`overlap_shape` 恰為兩個盒;
>   400 條射線 × 300 碰撞器 indexed == linear 逐位;平行批次 == serial 逐位;起點接觸 start_solid、零長度掃掠、無物可撞皆正確。
> - **bench** `bench_query_ext`(已入報告範本):1024 條射線,線性 vs index(含建置)N = 16 / 256 / 1024 / 4096:783 / 6477 / 24816 / 93625 ns vs
>   216 / 726 / 1759 / 5227 ns;批次 N = 4096 serial 5.65 ms vs 平行 5.64 ms(其中 index 建置 3.4 ms 為序列,其餘每條約 2 µs 在 4 核容器上平行沒有變快)。
>   `scripts/run_benchmarks.sh` 加 bench 輸出快取與 `ONLY=` 模式(新增一節不必 26 分鐘全跑)。
> - **盒形角色 ✅(2026-10-13)**:`CharacterController(p, cfg, box_rounding=r)`(r ≥ 0)改掃軸對齊圓角盒(半邊長 (radius, half_height + radius, radius)),
>   `_cast` 走 `shape_cast`、推出與起身檢查走新的 `shape_penetrations`(`QueryShape.rounded_box`:核心是縮 r 的盒,深度在 r 內有推出方向;膠囊預設不變,
>   `test_character` 21/21 不動)。`test_character_box` 10/10:地面底部 0.01005(skin)、1 s 走 1.9999994 m、牆前停在面 2.98995(牆 3)、0.25 m 台階上去
>   (底 0.26005)、0.5 m 擋住;中心超出崖邊 0.2 m:盒子底部 1.01005 平穩站住,同半徑膠囊以圓底卡在邊上、底部 0.93365(解析 1 − 0.0764 + skin = 0.93361);
>   陷入地面 0.04 一次更新推出;1.5 m 天花板下站到 1.8 m 拒絕、1.4 m 允許;r = 0 尖角盒照常行走。`test_query_ext` 20/20 加 `shape_penetrations` 一條。
> - **表面材質 ✅(2026-10-13)**:`TriMesh` / `HeightField` 帶逐三角形材質 id(`ContactScene6.set_triangle_materials`,0..65535,空 = 無);
>   `hit_material(hit)` 由命中三角形回報、非網格回 −1;場景材質摩擦表 `set_material_friction(id, mu)`,`surface_friction(body, material, fallback)`
>   先查材質、未設時退回 body 摩擦。載具輪:`WheelHit.feat`(射線直接帶;球 / 膠囊輪以接觸點反向 10 cm 射線取回三角形),`WheelState.material`
>   每輪回報腳下材質,輪胎抓地取 `surface_friction`。`test_surface_material` 8/8:同一條路網格,柏油段(材質摩擦 0.5)15 m/s 煞停 13.6419325 m
>   = body 摩擦 0.5 的盒路 13.6419325;冰段(0.05)150.08862 m vs 盒路 0.05 的 150.08842;heightfield 第 3 格回報材質 8。
>   接觸求解器仍用 body 摩擦(逐三角形接觸摩擦未接,歸 17.23)。
> - **快照 format 5**:同時補上 17.45 的兩個缺口 —— kinematic 網格(body 座標頂點、上次放置位姿)與 heightfield 的 active-edge 角度原本不在快照裡,
>   還原後平台網格不再跟隨 body。現在連同材質與材質摩擦表寫入;`test_surface_material` 中途存讀的移動平台場景與不中斷的執行逐位相同。
> - **批次平行的實際加速 ✅(2026-10-14)**:先量 —— 舊 bench 每格只量一次冷啟動,含執行緒池啟動;1024 條射線時序列 index 建置(SAH 3.7 ms)比射線本身還貴。
>   `QueryIndex` 預設改 LBVH(4096 碰撞器建置 1.09 vs 4.39 ms,每條射線成本相同、結果與樹無關 —— 候選依索引排序),新增 `ray_cast_batch_in(idx, …)`
>   讓一幀內多批共用 index。`bench_query_ext`(暖池、7 次中位數):每批建 index 的 1024 條 序列 2.74 / 平行 2.19 ms;共用 index 的 16384 條
>   序列 30.42 / 平行 13.30 ms(2.29×,4 核)。
> - **CGA 圓形基元假說:否定 ✅**:球對球表面距離,4096 組隨機:GJK(查詢路徑)117 ns、CGA 對偶球內積 33.5 ns 且 f32 下最大偏差 3.6e-4
>   (r₁² + r₂² − 2 S₁·S₂ 的相消)、歐氏球心距 6.5 ns 精確。CGA 給的「閉式」就是歐氏閉式,更貴也更不準;點對圓已由 `bench_ga` 量過同樣結論。
> - **待辦**:GPU 批次對真實形狀(第 7 層)。

#### 17.54 CPU 碰撞管線 — Wave B(多執行緒)

> **狀態**:✅ 完成(2026-10-14:trace 拆段、narrowphase 平行、make_contact 平行、注入式 fan-out(沿用 17.75 `Dispatch`)、broadphase 候選查詢平行、BVH 建構的平方項修正、CCD 掃描平行、N = 1e5 量測 ✅)。
> **進度註(2026-10-13)**:`_collect_pairs` 先列舉候選對(span `broadphase`),再跑 `try_pair`(`narrowphase`)與 `make_contact` + `apply_rules`(`contact_prep`)。
> `SolverConfig.parallel_collision`(預設關)時,候選對 ≥ `NARROW_PAR_MIN`(256)就經 `cfg.dispatch` 分塊:narrowphase 每塊寫私有緩衝、依塊序串接;
> prep 每個 raw 接觸寫自己的槽(`physics/collide_par.mojo`)。候選順序不變,輸出與串行逐位相同:`tests/test_collide_par.mojo` 15/15
> (1024 箱堆;箱堆 + island 平行 + 著色 + CCD + BVH;heightfield 上 300 個 hull / 球 / 箱;六個 broadphase 後端;serial / reverse 派發;0 / 1 個物體、全 static、40 箱疊同點 780 對配 64 workers)。
> 量測(`bench_collide_par`,本容器 4 核,BVH broadphase,µs/步):拆段(串行,`-D LUDENS_TRACE`)—— 箱堆 N = 4096:broadphase 20658、narrowphase 4551、prep 2606、solve 114430;
> heightfield 混合形狀 N = 4096:broadphase 22947、narrowphase 125955、prep 29601、solve 190568。整步(三次執行):heightfield N = 4096 串行 → 4 workers
> 372 → 273、431 → 310、401 → 308 ms(−23 % 至 −27 %);箱堆 N = 4096 三次的串行 158 / 167 / 161 ms 與各 workers 列互有高低(±10 %,即本容器的執行間雜訊;
> narrowphase 只佔 3 %);N = 64 不分派(門檻前 64 對以 4 workers 反而慢 0.6 ms,故門檻 256)。
> 下一個熱點是串行的 broadphase(箱堆 N = 4096 佔 13 %,大於 narrowphase)。
> **進度註(2026-10-14)**:先量 broadphase 內部(N = 4097 箱堆,10 次平均):fat AABB 58 µs、BVH 重建 15775 µs、候選查詢 2648 µs、排序約 30 µs ——
> 熱點是重建,原因是 median 建樹每個節點以插入排序排範圍(未排序輸入 O(n²))。改成取左側的穩定 bottom-up 合併排序(與插入排序同一穩定順序,樹與查詢輸出順序不變:
> `test_bvh` / `test_sah` / `test_solver_bp_seam` / `test_trimesh` / `test_ccd6` / `test_fracture` 等輸出與 golden 逐字相同),重建 15.8 → 3.8 ms(commit 7dd31d2)。
> fat AABB 只佔 58 µs,不平行化。`parallel_collision` 且 body ≥ `BP_PAR_MIN`(1024)時,候選對改由 `pairs_parallel`:重建後每塊以 `query_region` 查本塊 item,
> 保留 j > i(去重、排序、去 static-static),塊內 i 遞增,依塊序串接即為 canonical 順序,省掉全域排序。`ccd_advance` 在 `parallel_collision` 且快速移動者 ≥ `CCD_PAR_MIN`(64)時,
> 各移動者的夾止比例經 `Dispatch` 計算(`_mover_frac` / `_FracTask`,每項只寫自己的 `frac` 槽)。兩者與串行逐位相同:`tests/test_collide_par.mojo` 25/25
> (六個 broadphase 後端在 1500 個散布箱上的候選清單與 `collect_bp_pairs` 相同,hash grid 72826 對、其餘 1889 對;1090 body 箱堆;200 顆 40 m/s 子彈於 parallel / serial / reverse 派發)。
> 量測(`bench_collide_par`,本容器 4 核,µs / 步):箱堆 N = 4096 串行 134103(原 158000 上下,差額即重建修正);N = 1e5 箱堆串行 3380763、4 workers 3316475(−2 %,
> 該規模由求解主導);heightfield N = 4096 全體 30 m/s 下落開 CCD:串行 4744047 → 4 workers 2750608(−42 %);heightfield N = 4096 不開 CCD 串行 366030 → 4 workers 282156(−23 %)。
> commit 7dd31d2、bca8064。
> **現況**:
> - `collision/` 整個套件**沒有任何 CPU 平行**:grep -c `parallelize`(`collision/*.mojo`)全部為 0(零命中)。GPU 端另有 `collision/bp_gpu.mojo` 與 `collision/gpu_raycast.mojo`(kernel,屬 17.17 / 17.53 範圍)。
> - 引擎現有的 CPU 平行都在求解端:island 展開(`physics/solver6.mojo:1393-1407`,`island_work` 閉包與 `parallelize`)、同色接觸對(`physics/contact6.mojo:526-536`)、
>   job graph level(`scheduler/jobgraph.mojo:175-177`)。
> - 因此 `step_soft` 的串行段落很重:BENCHMARK_REPORT「Physics — island-parallel solver (serial vs worker threads)」 反推平行比例僅約 **40%**,其餘 ~60%(broadphase、island labelling、pose 積分、sleep 更新、接觸快取管理)串行,
>   吞吐在 ~4 worker 後飽和於 ~1.6×(同節);單一大 island 的 honesty 列平行反而更慢(BENCHMARK_REPORT「island-parallel solver: serial vs threads」:`1 tower x8` 65.7 µs 串行 vs 79.3 µs 平行)。
> - 管線每一步都串行:`ContactScene6._collect_pairs`(`physics/solver6.mojo:696-824`)依序做 ① 每體 fat AABB(`:739`)→ ② `collect_bp_pairs`(重建 broadphase、取候選、**排序**成 `(a,b)` 升冪,
>   `collision/contact_gen.mojo:43-69`,排序在 `:67`)→ ③ 每對 `try_pair`(`:775-796`;brute 版 `:798-816`)→ ④ `cache_index` + 每個 raw 接觸 `make_contact` 暖啟動比對(`:820-822`)→ ⑤ `apply_rules`(`:823`)。
>   CCD 的 `ccd_advance` 對每個高速體掃全部 j(`physics/ccd6.mojo:52,61` 的雙層迴圈),也是串行。
> - 順序契約:Gauss-Seidel 求解與暖啟動對**接觸順序**敏感,所以 broadphase 任何後端都必須被規約成與 brute 相同的 `(i<j)` 升冪順序
>   (`contact_gen.mojo:43-52` docstring;`tests/test_solver_bp_seam.mojo` 六後端 parity)。任何平行化都必須保住這個順序。
> - 現有可複用機件:`scheduler/workstealing.mojo`(工作竊取池,任務順序不定,檔頭 `:1-30` 明言只適用順序無關的任務)、`scheduler/policy.mojo` 的 `DispatchPolicy`(Serial / Parallel);
>   **但** `collision`(層 3)與 `scheduler`(層 3)同層互引禁止(`scripts/arch_layers.toml:12-13`;`CLAUDE.md` 套件分層),所以 collision 不能直接 import 這些。
> - 熱點尚未量:17.19 進度註自己寫「剩餘熱點待量(著色重排 …、每幀重建 BVH、CCD 全對)」(ROADMAP §17.19);
>   `collect_pairs` 在 trace 裡是**單一 span**(`physics/solver6.mojo:1232-1233`),看不到 ①–⑤ 的拆分。
> **缺口**:
> - **先量再平行**:把 `collect_pairs` span 拆成 broadphase / narrowphase / make_contact / cache 四段(接 17.10 的 trace),在 N ∈ {1e3, 1e4, 1e5} 與 {箱堆, mesh 地形, 單一大 island} 上量佔比;
>   平行化的優先序由數字決定(探針先行)。
> - **narrowphase 平行**:`try_pair` 對 `colliders` / 姿態唯讀,各對獨立;分塊輸出到私有緩衝,再依 pair 順序串接,**輸出逐位等於串行**
>   (例:同一場景 workers ∈ {1,2,4,8,20} 的 `List[ContactConstraint]` 逐位相同)。mesh 對(`try_mesh_pair` 每對產生多個 manifold)成本差異大,
>   需評估靜態分塊 vs 工作竊取(後者只能用在「以索引寫入固定槽位」的任務,輸出順序才不受影響)。
> - **broadphase 平行**:fat AABB 計算(純映射)、BVH 建構的上層分割 / 候選對收集的分塊、排序改平行歸併;DBVH 增量更新的並行性另評。
> - **make_contact / 暖啟動比對**:`cache_index` 建一次、查詢唯讀,可分塊;與 `apply_rules` 的順序相依需先確認。
> - **CCD 掃描**:`ccd_advance` 外層迴圈對 `frac[i]` 各自獨立寫入,可平行(例:1e4 個高速體)。
> - **注入式 fan-out 介面**:collision 層需要自己的最小 trait(或由 physics 層注入閉包),預設實作用 `max.algorithm.parallelize`;介面形狀要讓宿主之後能換成自己的 job system(17.75)。
> - **誠實列**:小 N 時 fan-out 稅(`bench_islands` 的 honesty 列)—— 必須有「N 小於門檻就走串行」的決策規則與對應量測。
> **對照組**:Jolt(`PhysicsSystem::Update` 以 `JobSystem` 平行 broadphase 查詢與 narrowphase)、PhysX(`PxCpuDispatcher` 任務化的 broadphase / narrowphase)、
> Box2D v3(使用者提供的 task system 回呼)、Bullet(`btCollisionDispatcherMt` + `btTaskScheduler`);
> 論文:Pabst et al. 2010〈Fast and scalable CPU/GPU collision detection〉、Karras 2012(平行 BVH 建構,LBVH)。
> **優勢區**:**平行與串行逐位相同**(以 canonical pair 順序為合約,`contact_gen.mojo:43-69`)—— 對照組多數只保證「功能等價」或僅在限定條件下決定論;
> 優勢區 = pair 數大且單對成本高(mesh / hull)、且 island 少而大(此時 island 平行無用,正是 BENCHMARK_REPORT「Physics — island-parallel solver (serial vs worker threads)」 的 ~60% 串行段)。
> 劣勢區(要如實量):小 N、單對便宜的箱堆,fan-out 稅 > 收益。
> **規模軸**:物體數 N(1e3 / 1e4 / 1e5)、候選對數 P、單對成本(box-box / hull / mesh 三角形候選數)、workers ∈ {1,2,4,8,16,20}、
> island 結構(1 個大 island vs 16 個小 island)、主機拓撲(此機為 6 P-core + 8 E-core,BENCHMARK_REPORT「Physics — island-parallel solver (serial vs worker threads)」 —— 曲線讀平台段而非 argmax)。
> **seam?**:是 —— `CollisionExec` 的變體(串行 / 靜態分塊 / 工作竊取)。parity:同場景輸出的接觸序列**逐位相同**,對所有 workers 數與 `test_solver_bp_seam` 的六個 broadphase 後端皆成立;
> 預設仍為串行,故既有 golden 各段完全不變。bench:加速曲線(workers 掃描)+ 小 N honesty 列,放進範本「Physics — solver pair collection」一節。
> **交付**:`collision/` 內的平行執行路徑 + `ContactScene6` 的選項(`SolverConfig` 欄位),`step_soft` 實際走得到。
> 普通:箱堆 N=1024、workers=4 的 `_collect_pairs` 輸出與串行逐位相同。
> 整合:與 island 平行(`cfg.parallel`)、著色求解、sleep、CCD、warm-start 同場景,整步結果逐位相同;mesh 地形 + 箱堆(單對成本不均);六個 broadphase 後端皆通過。
> 極端:0 / 1 個物體、全部 static、單對、全部物體疊在同一點(P ≈ N²)、worker 數大於 P、mesh 候選數極端不均、`workers` 大於核心數。
> **相依**:17.10(trace 拆段)、17.19(熱點量測的延續)、17.75(宿主注入 job system —— fan-out 介面須相容)、6.11 / 10.2(既有平行機件);與 17.85 互補(見邊界)。
> **邊界**:17.85 的 `update_moved` 增量 broadphase 與 awake list 是「少做事」,本條是「把整步全量的事分給多核」,兩者可疊加,但**不在本條重做** 17.85 的範圍;
> GPU 碰撞管線屬 17.17;求解端的平行(island / 著色)已存在,不屬本條;BVH 最佳化(SAH 等)屬寬相自身的條目。

---

## 縮座標關節體與致動

範圍:chain(ABA / RNEA)、致動器、腱、感測器、統一約束。

| 編號 | 條目 | 狀態 | Wave | 說明 |
|---|---|:-:|:-:|---|
| 6.4 | [縮座標關節鏈(Featherstone 方向,CRBA+RNEA 切片)](ROADMAP_HISTORY.md#64-縮座標關節鏈featherstone-方向crbarnea-切片) | ✅ |  | `physics/chain.mojo` 以緊湊空間慣性 {m,h,I₀} 實作串聯 revolute 鏈的 CRBA 質量矩陣 + RNEA 偏置力,FK 走 motor 合成,並與 maximal-coordinate 解析互驗。 |
| 6.8 | [O(n) ABA(關節化剛體演算法)](ROADMAP_HISTORY.md#68-on-aba關節化剛體演算法) | ✅ |  | Chain.dynamics_aba/step_aba 實作 Featherstone RBDA 7.3 三趟掃描(新 _ABI 對稱 6×6 分塊與手推平移 shift),與 dense CRBA+RNEA parity 4.3e-6,n≈16 交叉、n=64 快 3.5×。 |
| 6.12 | [樹狀拓撲(分支關節樹/森林)](ROADMAP_HISTORY.md#612-樹狀拓撲分支關節樹森林) | ✅ |  | Chain 以 parent 索引支援分支樹與森林,fk/CRBA+RNEA/ABA/energy 全改沿父鏈,Y 樹 ABA vs dense parity 2.1e-7,既有串鏈結果逐位不變。 |
| 9.2 | [浮動基座關節(完整 ragdoll)](ROADMAP_HISTORY.md#92-浮動基座關節完整-ragdoll--已完成) | ✅ |  | physics/floating.mojo 的 FloatingChain 為縮座標鏈加上 6-DOF 自由根,以單位加速度組出 (6+n) 質量矩陣;tests/test_floating.mojo 驗證自由落體加速度 = g、鎖根時與 Chain 逐位 parity、內力不改變總動量,bench_floating 量測成本。 |
| 13.1 | [反向動力學(精確 τ = ID(q, q̇, q̈))](ROADMAP_HISTORY.md#131-反向動力學精確-τ--idq-q-q--已完成) | ✅ |  | `Chain.inverse_dynamics(qdd, gravity)` 用 O(n) RNEA 算出 τ,不建質量矩陣;tests/test_inverse_dynamics.mojo 驗證 2 / 8 連桿鏈、分支樹與森林的 τ→q̈→τ 往返,bench_chain 有「ID vs 稠密 O(n³) 正解」一列。 |
| 13.2 | [縮座標 ↔ 接觸耦合(關節體能碰到世界)](ROADMAP_HISTORY.md#132-縮座標--接觸耦合關節體能碰到世界--已完成) | ✅ |  | `Chain.point_jacobian` 加上 `Chain.resolve_contacts` 用 J H⁻¹ Jᵀ 在關節空間解接觸(速度與位置分兩趟),對象是 `collision.ColliderSet` 中的靜態碰撞體;tests/test_chain_contact.mojo 驗證 Jacobian 對有限差分 FK、不穿透、能量不增,bench_chain_contact 量 dynamics step 與 step+contact。 |
| 13.3 | [致動器模型(傳動 + 力生成 + 內部動力學)](ROADMAP_HISTORY.md#133-致動器模型傳動--力生成--內部動力學--已完成) | ✅ |  | physics/actuator.mojo 的 `Actuator` / `ActuatorBank` 用 MuJoCo 式三段:關節傳動加齒比、仿射力生成(涵蓋 motor / position / velocity servo)、內部動力學(無、一階濾波、Hill 型肌肉的非對稱啟動);tests/test_actuator.mojo 驗證 servo 與手寫 PD 逐步一致,bench_actuator 量致動器成本。 |
| 13.4 | [腱(fixed / spatial,含繞行)](ROADMAP_HISTORY.md#134-腱fixed--spatial含繞行--已完成) | ✅ |  | physics/tendon.mojo 提供 FixedTendon(L = Σ c_i q_i)與經附著點、可繞世界固定球體(WrapSphere)的 SpatialTendon;tension 經 tau = -F dL/dq 回到關節;test_tendon 驗證線性耦合、繞行時力臂 == dL/dq、繞行起始處長度連續、功 == -F·ΔL,bench_tendon 已在報告範本中。 |
| 13.5 | [統一約束求解器(equality / limit / friction-loss / contact 一體)](#135-統一約束求解器equality--limit--friction-loss--contact-一體) | 🔶 |  | physics/constraints.mojo 的 ConstraintSet 以單一 projected Gauss-Seidel 處理 equality / limit / friction-loss / contact 列,金字塔錐與橢圓錐用旗標(CONE_PYRAMIDAL / CONE_ELLIPTIC)切換,test_constraints 與 bench_constraints 都已存在;沒有 CG / Newton 求解器變體,而且只在縮座標(chain)空間使用,只有 tests 與 benchmarks 會用到它。 |
| 13.6 | [機器人感測器組](ROADMAP_HISTORY.md#136-機器人感測器組---已完成) | ✅ |  | physics/sensors.mojo 從模擬狀態導出唯讀量:IMU(proper acceleration + 陀螺,另有批次版 read_imu_batch)、由反向動力學算出的關節力矩、關節位置 / 速度、只支援平面的測距儀、觸覺;test_sensors 驗證自由落體時加速度計讀 0、靜止時讀 g、關節力矩 == m·g·lever,批次 IMU 與逐個讀取逐位相同。 |
| 17.51 | [縮座標完整化](#1751-縮座標完整化--wave-b承-91) | ✅ | B | 多自由度關節、多 DOF 限制、關節屬性、接觸補完、接觸效率、閉環 |

### 已完成條目的遺留待辦

這些條目已完成並移到歷史檔,但各自記下了尚未做的部分:

- **6.8**([紀錄](ROADMAP_HISTORY.md#68-on-aba關節化剛體演算法)):誠實行:n=4/8 dense 仍較快(ABA 常數大),交叉點約 n≈16
- **9.2**([紀錄](ROADMAP_HISTORY.md#92-浮動基座關節完整-ragdoll--已完成)):交付物中「與 solver6 maximal-coord ragdoll 交叉驗證」在 tests/test_floating.mojo 未見(無 solver6 / Joint6 引用),視為未做
- **9.2**([紀錄](ROADMAP_HISTORY.md#92-浮動基座關節完整-ragdoll--已完成)):「完整 ragdoll」的肩髖 cone-twist 依賴 9.1,仍未做(→ 17.47 / 17.51)
- **13.2**([紀錄](ROADMAP_HISTORY.md#132-縮座標--接觸耦合關節體能碰到世界--已完成)):設計寫「先做單一鏈接地,再推廣」:目前只對靜態碰撞體(physics/chain.mojo:694 `resolve_contacts` 的 docstring 寫碰撞體在該呼叫中視為靜態),與 ContactScene6 中動態剛體的雙向耦合還沒做。
- **13.2**([紀錄](ROADMAP_HISTORY.md#132-縮座標--接觸耦合關節體能碰到世界--已完成)):交付物的 bench「縮 vs 最大座標,同場景同精度」(對照最大座標 ragdoll / joints6)沒有做:bench_chain_contact 只比同一條鏈有無接觸的成本;關節剛度軸也沒有量。
- **13.4**([紀錄](ROADMAP_HISTORY.md#134-腱fixed--spatial含繞行--已完成)):繞行障礙只能是世界固定物體;障礙剛性附著在移動 link 上時,需要加上障礙自身運動那一項(physics/tendon.mojo 檔頭:"a further step")
- **13.4**([紀錄](ROADMAP_HISTORY.md#134-腱fixed--spatial含繞行--已完成)):設計寫的是「可繞球/圓柱」,但只實作了球體繞行(WrapSphere),沒有圓柱繞行
- **13.4**([紀錄](ROADMAP_HISTORY.md#134-腱fixed--spatial含繞行--已完成)):對照組「等效的多關節 equality 約束(13.5),比成本與穩定性」沒有量測紀錄
- **13.6**([紀錄](ROADMAP_HISTORY.md#136-機器人感測器組---已完成)):測距儀只支援平面,沒有接上 collision/queries 的 raycast(physics/sensors.mojo 檔頭:"natural extension ... not done here"),所以交付物「測距儀 == raycast」沒有達成
- **13.6**([紀錄](ROADMAP_HISTORY.md#136-機器人感測器組---已完成)):沒有腱的感測器(腱力矩、腱位置 / 速度);sensors.mojo 只有關節的讀數
- **13.6**([紀錄](ROADMAP_HISTORY.md#136-機器人感測器組---已完成)):觸覺 read_touch 回報的是穿透深度,不是設計中的接觸法向力積分
- **13.6**([紀錄](ROADMAP_HISTORY.md#136-機器人感測器組---已完成)):對照組「有限差分導出的等效量,比精度與成本」只做了精度檢查(加速度計 == 對世界速度做有限差分 - g),沒有成本比較紀錄

### 待辦與部分完成條目

#### 13.5 統一約束求解器(equality / limit / friction-loss / contact 一體)

> **狀態**:🔶 部分完成(只交付 PGS;CG / Newton 變體與 `ContactScene6` 雙向耦合移至 17.51,接觸模型變體移至 17.50)— 原屬 Wave C
> **狀態校正(2026-10-10,17.44–17.84 重寫時的對抗審查)**:原標 ✅,但本節沒有進度註,且設計要求的
> 「求解器 seam:PGS vs CG vs Newton」只交付了 PGS —— `physics/constraints.mojo:18-19` 自述「one projected
> Gauss-Seidel loop」,`solve`(`:124-174`)只有 PGS;grep `newton|conjugate|krylov` 於 `constraints.mojo`、
> `test_constraints`、`bench_constraints` 零命中(`numerics/cg` 存在但只被 `fem.mojo` 使用)。已交付:四類約束
> 收進同一 `ConstraintSet` + 金字塔 / 橢圓錐 seam。相關的 13.2「縮座標 ↔ 接觸耦合」也只對靜態碰撞體成立
> (`physics/chain.mojo:713`:碰撞體在該呼叫中視為靜止,無速度、無反作用衝量),`Chain` 未接 `ContactScene6`。
> 剩餘工作移至 **17.51**(CG / Newton 變體、與 `ContactScene6` 雙向耦合)與 **17.50**(接觸模型變體)。
> **已交付(依程式碼核對補記,原 ROADMAP 本節無進度註)**:`physics/constraints.mojo` 的 `ConstraintSet`:equality(不設上下限)、joint limit(f ≥ 0)、friction loss(|f| ≤ f_max)、contact normal(f ≥ 0)、contact friction(|f_t| ≤ μ f_n)全部放進同一個 projected Gauss-Seidel 迴圈,每列各有自己的 projection;`H⁻¹Jᵀ` 每列只算一次。摩擦錐用旗標 `CONE_PYRAMIDAL` / `CONE_ELLIPTIC` 選擇;橢圓錐把兩條切向列當成一對處理,做徑向投影。`tests/test_constraints.mojo`:equality 殘差歸零、stop 只推不拉、乾摩擦在上限以下保持靜止、橢圓錐等向而金字塔錐沿對角線多出 sqrt(2) 倍摩擦(最多偏 35°)、equality + limit + contact 同時成立。`benchmarks/bench_constraints.mojo`(報告範本有 `@bench` 行)。
> **量測結論(bench_constraints 檔頭)**:同等工作量下,單一系統與交替 pass 的違反量相同;交替 pass 能降到機器零,單一系統則停在約 3e-8(warm-start 累積衝量後重算殘差產生的抵消誤差)。所以統一求解的理由不是迭代數,而是摩擦錐把各列耦合在一起:不知道 f_n 的 pass 根本算不出 |f_t| ≤ μ f_n。
> **與設計 / 交付物的差距(依程式碼核對)**:
> - 求解器 seam:設計中的 PGS vs CG vs Newton,只有 PGS。
> - bench 只量了 PGS × 兩種錐,沒有「PGS / CG / Newton × 兩種錐,同精度比成本」。
> - `ConstraintSet` 只在縮座標(`Chain`)空間使用,除了 tests / benchmarks 沒有其他地方 import;solver6 的剛體接觸仍然走自己的路徑。
> - 錐型是執行期旗標,不是編譯期 trait seam。
> **設計**:把四類約束收進同一個凸優化(MuJoCo 路線),並提供摩擦錐 seam:金字塔錐(快、robust)vs 橢圓錐(物理正確)。求解器本身也做成 seam:PGS(當時的 `_solve_point`)vs CG vs Newton。
> **優勢**:一套機制涵蓋四類約束,新增約束種類只要加資料,不用加程式路徑;橢圓錐消除金字塔錐的方向性偏差(斜坡上的滑動方向會被錐面稜線吸引)。
> **對照組**:當時分開處理各類約束的做法;金字塔錐 vs 橢圓錐的斜坡滑動方向偏差是可量的物理量。
> **規模軸**:約束數 × 迭代數;錐型 × 摩擦係數。
> **交付物**:`test_constraints`(關節極限不越界、乾摩擦靜止不漂移、equality weld 剛性、橢圓錐的斜坡滑動方向沒有稜線偏差而金字塔錐有)+ bench(PGS / CG / Newton × 兩種錐,同精度比成本)。
> **相依**:9.1(關節極限的表達)。
> **歷史**:原「現況」:只有接觸 + ball/hinge 兩種關節,沒有關節極限、沒有乾摩擦、沒有 equality 約束,而且各自用不同機制處理;設計寫的 PGS 是當時的 `_solve_point`。

#### 17.51 縮座標完整化 — Wave B(承 9.1)
> **狀態**:✅ 完成(2026-10-14:關節屬性的隱式步、`Chain` / `FloatingChain` 快照、接觸摩擦、H 分解重用、閉環、直接 / CG 解、與最大座標 parity、球 / 萬向 / 平面 / 自由關節、swing-twist 限制、link 膠囊接觸與自碰撞、與 `ContactScene6` 雙向耦合、ABA 型 O(n) 接觸回應(量測:n ≤ 64 時比分解慢);GPU 屬 17.17)。

> **現況**:縮座標關節只有 `JOINT_REVOLUTE / JOINT_PRISMATIC`(`physics/chain.mojo:96-97`),每個 link 恰一個純量自由度與單一軸(`ChainLink`,`physics/chain.mojo:101-110`);限制 `lo / hi` 由衝量式 `resolve_limits` 處理(`physics/chain.mojo:130-140,785-848`)。grep `spherical|ball|universal|planar|free.?joint|multi.?dof|armature|damping|spring`(`physics/chain.mojo`、`physics/floating.mojo`)零命中:沒有球 / 萬向 / 平面 / 多自由度關節,也沒有關節阻尼、彈簧、armature。彈簧 / 伺服靠 `Actuator` 提供 τ(`physics/actuator.mojo:1-40`;其仿射式 `gain_q·q + gain_qd·q̇` 已能表達 PD 彈簧 - 阻尼,但為顯式 τ,非隱式處理),乾摩擦只能手組 `ConstraintSet` 的 `CON_FRICTION_LOSS` 列(`physics/constraints.mojo:100`),不是 link 屬性。9.1 狀態校正已把「縮座標沒有球關節 / 多自由度」記為剩餘(ROADMAP §9.1)。
> 與世界的耦合只有「link 上的材質點 ↔ 靜態 `ColliderSet`」:`resolve_contacts` 經 `nearest_surface` 找最近碰撞器(`physics/chain.mojo:694-783`),只有法向衝量、沒有摩擦(`physics/chain.mojo` grep `friction|mu` 零命中)、接觸是 link 上的點而非 link 形狀,也與動態 `ContactScene6` 剛體**完全不耦合**:全樹僅 `sensors / tendon / constraints / floating` 引用 `Chain`,`gameplay/` 與 `solver6` 零引用(grep `physics.chain|FloatingChain`)。ROADMAP「Phase 17 建議順序」 另記 F12 待辦「mesh / heightfield 接觸只有觸碰無深度」。
> 接觸路徑每個接觸每次迭代做一次稠密解 `solve_dense`(`physics/chain.mojo:650-670`,O(n³)),O(n) 的 ABA(`:875`)存在但接觸不走它;`FloatingChain` 提供 6-DOF 根(`physics/floating.mojo`);沒有閉環關節;`ConstraintSet.solve` 只有 PGS(`physics/constraints.mojo:124-174`)。`Chain` / `FloatingChain` 不在 6.10 快照內(`physics/serialize.mojo` grep `chain` 零命中)。
> **缺口**:
> - **多自由度關節**:球(3-DOF 旋轉,例:肩 / 髖 / 脊椎)、萬向(2-DOF)、平面(3-DOF)、自由(6-DOF,取代 `FloatingChain` 的偽關節)。運動子空間 S 從單一軸推廣為 6×k 矩陣,CRBA / RNEA / ABA 的 S 投影從純量改成 k 維;`q` 不再是向量空間(球關節在 SO(3)),積分走 exp 映射。
> - **多 DOF 限制**:swing-twist 錐限制(例:肩),沿用 `resolve_limits` 的速度 / 位置分離。
> - **關節屬性**:阻尼、彈簧(剛度 + 平衡位置)、乾摩擦、armature(轉子慣量,穩定高齒輪比),作為 `ChainLink` 欄位而非手組 `ConstraintSet` / `Actuator`;相對 `Actuator` 顯式 PD 的實質增量是**隱式**處理高剛度 / 高阻尼與 armature(例:剛度 1e5 的關節彈簧在 dt = 1/60 下,量 `Actuator` 顯式 vs 隱式欄位的穩定界),否則只是語法糖。
> - **接觸補完**:link 形狀(膠囊 / 盒 / 球)對 `ColliderSet`、link-link 自碰撞(鄰接排除)、接觸摩擦(接 `ConstraintSet` 的摩擦錐列);與動態剛體雙向耦合(articulation 站在 `ContactScene6` 的箱子上並推動它 —— 目前互不相通)。
> - **接觸效率**:H 因式分解一次重用(`ConstraintSet.solve` 已是這個做法)或 ABA 型 O(n) 接觸傳播,取代逐接觸稠密解。
> - **閉環**:loop closure 的 equality 列由 API 自動組 Jacobian(例:四連桿),目前手組。
> - **求解器變體**:CG / Newton(13.5 設計寫了但只交付 PGS)。(例:10 節 1:100 質量比的鏈條,PGS 100 迭代仍殘差大,Newton 數步收斂)
> - **快照**:`Chain` + `FloatingChain` 進 6.10 決定論快照。(例:機械臂場景存檔 → 讀回 → 續跑與不中斷逐位相同)
> **對照組**:PhysX `PxArticulationReducedCoordinate`(revolute / prismatic / spherical / fix、drive、joint friction、`setArmature`)、Bullet `btMultiBody`(spherical / planar / fixed 與 `btMultiBodyJointLimitConstraint`)、Drake `MultibodyPlant`(ball / universal / planar / floating 關節)、Pinocchio / RBDL 的 joint model 設計。內部對照:同場景的最大座標(`Joint6`,見 17.47)—— 13.2 已定的「縮 vs 最大座標」權衡。
> **優勢區**:縮座標在高剛度、長鏈、大質量比下約束由構造滿足,不漂移不抖(13.2 的量測軸);ABA 為 O(n);球關節以四元數 / motor 對數座標表示,無奇異點,`Chain.fk()` 本就以 `Motor3` 合成(`physics/chain.mojo:237`)。反面:目前接觸路徑 O(n³),大 n 時最大座標反而便宜 —— 本條的接觸效率項就是要消除這個交叉點。
> **規模軸**:連桿數 n ∈ {8, 32, 128, 512} × 接觸點數 × 關節剛度;球關節 vs 三個串接 revolute 偽關節的成本與奇異點;縮座標 vs 最大座標同場景;樹分支度。
> **seam?**:是 —— (1)球關節:原生 3-DOF 球 vs 三個串接 revolute(含萬向鎖奇異點)vs 最大座標 `Joint6.ball`。parity:非奇異區同初態的末端軌跡三者一致,奇異區以行為斷言記錄(偽關節失效、原生仍有限)。(2)接觸解:逐接觸稠密解 vs 因式分解重用 vs ABA 傳播,同場景落地高度 / 殘餘相等,bench 連桿數 × 接觸數。(3)PGS vs CG / Newton。列入 `docs/CATEGORY.md` §2.1 縮座標各列(`:120-124`)。
> **交付**:接真路徑 —— 球關節與 link 形狀進 `Chain` 的 `dynamics / step_aba`,接觸走 `ContactScene6` 的動態剛體,`FloatingChain` 改以自由關節重寫。普通:球關節單擺週期對解析;球關節無外力矩時角動量守恆;swing-twist 限制擋停解析角;關節阻尼指數衰減;彈簧頻率;armature 增加有效慣量(週期變化對解析)。整合:articulation 站上 `ContactScene6` 動態箱並推動它,動量守恆與反作用成立;link 形狀落在 17.45 的網格地面;與 `Actuator / Tendon / sensors` 並用;重寫後的 `FloatingChain` 與舊版 parity(`test_floating`);快照往返逐位相同。極端:球關節轉 180° 與四元數漂移重正規化、swing 錐半角 0 / π、零質量 link(raise)、n = 512 鏈的接觸成本、link 形狀初始即穿插、閉環機構冗餘約束(秩虧)、armature = 0 與缺省逐位相同。
> **相依**:9.1(本條是其縮座標剩餘)、13.1–13.6(已交付基礎)、17.47(最大座標對照)、17.45(網格地面)、17.50(摩擦錐)。
> **邊界**:最大座標關節補完屬 17.47;GPU articulation 屬 17.17(其 parity 基準可用本條的 CPU 版);致動器 / 腱已由 13.3 / 13.4 交付;URDF / MJCF 等機器人格式與 RL 批次不入路線(Phase 13 排除);ragdoll 目前走最大座標,是否改走縮座標由 17.66 物理角色決定,不在此條。與 17.85 無重疊。

---

## 軟體、布料、連續體與流體

範圍:softbody、cloth、FEM / MPM / SPH / PBF、LBM、繩索。

| 編號 | 條目 | 狀態 | Wave | 說明 |
|---|---|:-:|:-:|---|
| 6.1 | [CPU XPBD 體積軟體 + 剛體雙向耦合](ROADMAP_HISTORY.md#61-cpu-xpbd-體積軟體--剛體雙向耦合) | ✅ |  | `physics/softbody.mojo` 提供 box lattice XPBD 體積軟體,並在 ContactScene6 的 soft-step 子步內與動態剛體雙向耦合(推出衝量回饋剛體、喚醒睡眠體)。 |
| 6.6 | [軟-剛 CCD(粒子掃掠 vs 盒)](ROADMAP_HISTORY.md#66-軟-剛-ccd粒子掃掠-vs-盒) | ✅ |  | _softbody_pass(ccd=True) 讓軟體粒子 prev→x 線段在盒當前局部座標做 slab 掃掠(含盒自身子步位移 +v·h),擋下 120 m/s 子彈方塊與 40 m/s 薄板穿隧,慢場景 ccd on/off bit-identical。 |
| 6.7 | [Soft-vs-sphere/capsule 耦合(補 softbody pass 的形狀缺口)](ROADMAP_HISTORY.md#67-soft-vs-spherecapsule-耦合補-softbody-pass-的形狀缺口) | ✅ |  | _softbody_pass 對球(徑向推出)與膠囊(軸段最近點當球)做軟體粒子耦合與衝量回饋,ccd 以線段 vs 充氣球二次式掃掠且優先於徑向推出,drape 全程零穿透、動量守恆 0.02%、200 m/s 彈丸被擋。 |
| 6.9 | [軟接觸摩擦(位置級 Coulomb 錐)](ROADMAP_HISTORY.md#69-軟接觸摩擦位置級-coulomb-錐) | ✅ |  | SoftBody.mu(預設 0.5)與 _soft_fric 對 box/球/膠囊三種接觸做位置級 Coulomb 錐切向夾制,反作用折入耦合衝量保證動量守恆,15° 坡 drift 6.6e-7、35° 坡滑動、圓丘蠕滑 0.397→0.050。 |
| 14.1 | [LBM 核心(D3Q19 碰撞-傳播)](ROADMAP_HISTORY.md#141-lbm-核心d3q19-碰撞-傳播--完成2026-08-12cpu) | ✅ |  | `fluid/d3q19.mojo` 與 `fluid/lbm.mojo` 提供 SoA 佈局的 D3Q19 BGK 碰撞 + pull 串流 + 雙緩衝交換,CPU 約 3.7 MLUPS。 |
| 14.2 | [障礙物:bounce-back / 浸沒邊界](ROADMAP_HISTORY.md#142-障礙物bounce-back--浸沒邊界---完成2026-08-12半程-bounce-back) | ✅ |  | 半程 bounce-back 內建於 `stream()`,固體只需旗標,`set_solid_box` / `set_solid_sphere` 體素化障礙物,質量守恆 4e-6 相對誤差。 |
| 14.3 | [進出口邊界(開放流域)](ROADMAP_HISTORY.md#143-進出口邊界開放流域--完成2026-08-12) | ✅ |  | `BC_TUNNEL` 提供 x=0 以當地密度建平衡態的固定速度進口、x=nx-1 零梯度出口、其餘週期,`tests/test_lbm.mojo` 28 checks 驗證。 |
| 14.4 | [表面力積分(動量交換)→ Cd / Cl](ROADMAP_HISTORY.md#144-表面力積分動量交換-cd--cl---完成2026-08-12) | ✅ |  | 動量交換法內建在 `stream()` 的 bounce-back 連結上,`drag_coefficient()` 換算 Cd,對 Schiller-Naumann 關聯式偏差隨球半徑 3→4→5 格由 41.5% 單調降到 26.7%。 |
| 14.5 | [湍流模型(LES Smagorinsky)](ROADMAP_HISTORY.md#145-湍流模型les-smagorinsky--完成2026-08-12) | ✅ |  | Smagorinsky 次網格模型內建在 LBM collide(),由非平衡分布在格內取得應變率,讓 Re~1600 的風洞在純 BGK 會發散的情況下保持穩定,有 15 checks 測試。 |
| 14.6 | [LBM 驗證套件:對上文獻數值](ROADMAP_HISTORY.md#146-驗證套件對上文獻數值---完成2026-08-12) | ✅ |  | LBM 驗證測試拿解算器對照與引擎無關的參考值:剪切波黏度(誤差 0.99%)、音速、Poiseuille 收斂,以及 Stokes 極限 Cd(比值 1.58)。 |
| 15.2 | [布料自碰撞](ROADMAP_HISTORY.md#152-布料自碰撞---完成2026-08-11) | ✅ |  | 以均勻雜湊做 broadphase 的頂點-頂點厚度排斥,排除拓撲鄰居,XPBD 與 VBD 兩個布料解算器都接上;堆疊布的 gap 從 0.00034 回到 0.06,有 12 checks 測試與 bench_self_collide。 |
| 17.41 | [繩索 / 纜線約束](ROADMAP_HISTORY.md#1741-繩索--纜線約束--wave-b) | ✅ | B | `physics/rope.mojo` 的 `Rope` 是 XPBD 1D 鏈,兩端可釘在世界點或剛體局部點,會被碰撞器推出,張力超限時斷裂;載重由 `tie()` 加上的距離關節承擔。`test_rope` 12/12 量到的下垂與懸鏈線解析解相差在 0.2% 內;`bench_rope` 顯示比同長剛體鏈快約 5–6×。 |
| 17.42 | [LBM 風洞收尾(Phase 14 遺留併入)](ROADMAP_HISTORY.md#1742-lbm-風洞收尾phase-14-遺留併入--wave-b) | ✅ | B | D3Q19 LBM 已有 GPU kernel(`fluid/lbm_gpu.mojo` `LbmGpu`,1.77M 格 55.6 MLUPS,約 CPU 17×)、Bouzidi 插值 bounce-back(`Lbm.interp` + `link_q`)、控制面動量通量測力(`Lbm.momentum_flux_force`,與動量交換相差 ≤1.5%),以及 SPH Akinci 邊界粒子對照組(`physics/sph.mojo` `BoundaryParticles` / `sph_step_boundary`),各附 parity 測試。 |
| 17.55 | [連續體步進契約](#1755-連續體步進契約--wave-b連續體前置) | ✅ | B | `ContinuumSolver` 契約、登記與排序、統一失敗政策、快照參與、耦合埠(coupling port)、單位與時間慣例 |
| 17.56 | [布料](#1756-布料--wave-b) | ✅ | B | 任意三角網格布料、剪切 + 彎曲 + 拉伸上限、與場景碰撞、空氣動力、撕裂、網格自碰撞 |
| 17.57 | [毛髮 / 肌肉](#1757-毛髮--肌肉--wave-c) | 🔶 | C | 毛髮 / 毛皮股線、股線 – 場景碰撞、引導髮 + 插值、Hill 型肌肉完整曲線、體積肌肉、可微肌肉控制 |
| 17.58 | [體積軟體](#1758-體積軟體--wave-c) | 🔶 | C | FEM 進場景、本構模型庫、四面體網格化、塑性 / 黏彈、MPM 邊界、求解器變體 |
| 17.59 | [流固耦合](#1759-流固耦合--wave-c) | 🔶 | C | LBM ↔ 移動剛體(含輕物體隱式阻力、跨週期邊界)、SPH ↔ 剛體、MPM ↔ 剛體已做;PBF 雙向、柔性體 ↔ 流體未做 |
| 17.60 | [水面 / 網格流體](#1760-水面--網格流體--wave-c) | 🔶 | C | `WaterSurface` 水面查詢、歐拉式不可壓縮格網流體、氣體 / 煙霧、LBM 擴充、粒子 → 表面 |
| 17.61 | [多物理](#1761-多物理--wave-c) | 🔶 | C | `Coupler` 抽象、熱場、布料 / 毛髮 ↔ 氣流雙向、多相流 / 顆粒 – 流體、子步比與時間插值 |
| 17.62 | [GPU / 可微連續體](#1762-gpu--可微連續體--wave-cgpu--可微) | ⬜ | C | GPU 連續體求解器、持久裝置狀態、可微布料 / XPBD、可微 FEM / MPM、可微 LBM、批次 × 可微 × 連續體 |
| 17.63 | [輸出 / 快取](#1763-輸出--快取--wave-c資產管線提供者) | 🔶 | C | 模擬快取(cache)、Alembic(Ogawa)寫出、OpenVDB / NanoVDB 稀疏體積交換、`CachePlayer`、大小 / 重算取捨、格式治理 |

### 已完成條目的遺留待辦

這些條目已完成並移到歷史檔,但各自記下了尚未做的部分:

- **6.1**([紀錄](ROADMAP_HISTORY.md#61-cpu-xpbd-體積軟體--剛體雙向耦合)):單一實作,無 seam 變體;成本 benchmark row 留待有第二實作時補
- **6.1**([紀錄](ROADMAP_HISTORY.md#61-cpu-xpbd-體積軟體--剛體雙向耦合)):無 GPU 版(gpu_cloth 機制可移植)
- **6.6**([紀錄](ROADMAP_HISTORY.md#66-軟-剛-ccd粒子掃掠-vs-盒)):盒旋轉在掃掠中被忽略(一階掃掠)
- **6.7**([紀錄](ROADMAP_HISTORY.md#67-soft-vs-spherecapsule-耦合補-softbody-pass-的形狀缺口)):膠囊 ccd 僅用當前位置最近點球一階近似
- **14.1**([紀錄](ROADMAP_HISTORY.md#141-lbm-核心d3q19-碰撞-傳播--完成2026-08-12cpu)):CPU 效能:跨格 SIMD、融合 collide-stream、省第二緩衝的 in-place pattern 三項未做(3.7 MLUPS 遠不及公開 CPU 數十 MLUPS;`fluid/lbm.mojo` 註解判定 in-place 技巧不值得)
- **14.6**([紀錄](ROADMAP_HISTORY.md#146-驗證套件對上文獻數值---完成2026-08-12)):Stokes 極限 Cd 比 24/Re 高出 1.58 倍,原因是階梯體素球與阻塞比;Bouzidi 插值 bounce-back 列在後續 LBM 邊界項目,以 14.6 為對照組
- **15.2**([紀錄](ROADMAP_HISTORY.md#152-布料自碰撞---完成2026-08-11)):擋不住高速邊在一步內穿過兩個頂點之間的情況;要用 collision/toi.mojo 的掃掠(edge CCD)補,缺口已寫在檔頭
- **15.2**([紀錄](ROADMAP_HISTORY.md#152-布料自碰撞---完成2026-08-11)):VBD 只達到 0.0498 / 0.06 厚度:排斥跑在著色掃描之後,不在每頂點 Newton 之內,下一輪掃描會拉回一部分
- **15.2**([紀錄](ROADMAP_HISTORY.md#152-布料自碰撞---完成2026-08-11)):沒有摺疊的場景仍付約 14× 的純查詢開銷(雜湊重建 + 27 格查詢)
- **17.41**([紀錄](ROADMAP_HISTORY.md#1741-繩索--纜線約束--wave-b)):載重關節是雙向的,繩子不會鬆弛(`physics/rope.mojo:103`:「no slack in the load path」)
- **17.41**([紀錄](ROADMAP_HISTORY.md#1741-繩索--纜線約束--wave-b)):繩自碰撞(缺口原本要求可選自我碰撞,重用 `physics/self_collide.mojo`)
- **17.41**([紀錄](ROADMAP_HISTORY.md#1741-繩索--纜線約束--wave-b)):Cosserat 桿(彎曲 / 扭轉剛度);seam 原本規劃三種變體(distance-joint 鏈 / PBD 1D 鏈 / Cosserat),目前只有前兩種有 parity 測試
- **17.42**([紀錄](ROADMAP_HISTORY.md#1742-lbm-風洞收尾phase-14-遺留併入--wave-b)):GPU LBM kernel 效能定位:55.6 MLUPS 仍距記憶體頻寬上限約 20×,改 32 位元索引只從 43 升到 55,瓶頸未定位(待 profiler)
- **17.42**([紀錄](ROADMAP_HISTORY.md#1742-lbm-風洞收尾phase-14-遺留併入--wave-b)):GPU 上的動量交換歸約(測力)
- **17.42**([紀錄](ROADMAP_HISTORY.md#1742-lbm-風洞收尾phase-14-遺留併入--wave-b)):GPU 上的 LES(`LbmGpu` 目前拒絕 LES 格網)
- **17.42**([紀錄](ROADMAP_HISTORY.md#1742-lbm-風洞收尾phase-14-遺留併入--wave-b)):GPU 上的插值 bounce-back(`LbmGpu` 目前拒絕插值格網)
- **17.42**([紀錄](ROADMAP_HISTORY.md#1742-lbm-風洞收尾phase-14-遺留併入--wave-b)):SPH 邊界粒子的鄰居搜尋改走格網(現為暴力)
- **17.42**([紀錄](ROADMAP_HISTORY.md#1742-lbm-風洞收尾phase-14-遺留併入--wave-b)):SPH 邊界粒子的牆面取樣(目前只有地板 `box_floor_boundary`)

### 待辦與部分完成條目

> **進度(2026-10-13)**:
> - **關節屬性**:`Chain.set_joint_props(i, damping, stiffness, rest, armature, friction)`(與 `links` 平行的逐關節清單,`ChainLink` 欄位不變)與
>   `Chain.step_implicit`:M = H + diag(armature),後向 Euler 解 (M + dt·B + dt²·K) q̇' = M q̇ + dt(τ − C − K(q − rest)),乾摩擦以關節對角有效質量移除至多
>   `friction·dt` 的動量(停止而不反向)。性質全 0 時與 `step` 同為半隱式步。
> - **快照**:`write_chain / read_chain`(links、樹、q / q̇、根運動、關節屬性)。`FloatingChain` 尚未。
> - **測試** `test_chain_props` 10/10(單 revolute 連桿,I = 0.26):剛度 1e5、dt = 1/60(ω dt = 10.3)顯式 PD 力矩發散到 inf,隱式欄位最大 0.00093 並衰減;
>   armature 0.5 的小擺週期 2.4749 s(解析 2.4745);阻尼 0.52 一秒後 0.13982147(後向 Euler 因子 0.13982168,e^−2 = 0.1353);彈簧 50 對重力平衡在
>   −0.09753423(k q = −m g l cos q 的根 −0.09753424);乾摩擦 0.26 N·m 由 2 rad/s 在 2.017 s 停住(I ω / f = 2)並保持;三節鏈快照還原後 60 步逐位相同;
>   性質全 0 時 `step_implicit` 與 `step` 差 7.8e-6。
> - **bench** `bench_chain_props`(已入報告範本):N = 8 / 32 / 64,兩種步在雜訊內(8.4 vs 9.5、65.8 vs 56.9、297 vs 304 µs)。`docs/CATEGORY.md` 加一列 seam。
> - **FloatingChain 快照 ✅(2026-10-14)**:`write_floating / read_floating`(`write_chain` + 底座位姿、body 座標速度、慣量、pin / 組裝開關);
>   `test_floating` 15/15:50 步後存讀再走 100 步逐位相同。
> - **接觸效率 ✅(2026-10-14)**:`resolve_contacts` 原本每個衝量做一次 O(n³) 稠密消去;`numerics.dense` 加 `cholesky / cholesky_solve`,每個 pass 分解 H 一次、
>   每衝量兩次 O(n²) 三角解(`factor=False` 保留稠密路徑作 parity)。n = 32:`solve_dense` 31.7 µs vs `cholesky_solve` 2.3 µs、分解一次 13.5 µs。
>   `bench_chain_contact` 新表(每節都躺在地上):稠密 vs 分解 0.367 / 0.282 ms(n 8)、2.11 / 1.15(16)、18.9 / 4.24(32);原本擺動的列接觸少,不變。
>   首版 bench 場景把地板放在 y = −0.01,但根節點在 y = −1,整條鏈在地板下、沒有接觸,量不出差別 —— 已量、已改。
> - **接觸摩擦 ✅(2026-10-14)**:`resolve_contacts(..., mu)`:每個接觸在速度迭代中累積法向衝量,兩條切向列把滑動停下、總量限在 mu 倍內;mu = 0(預設)跳過。
>   1 kg 方塊(prismatic y + x)以 3 m/s 在地上滑:mu 0.5 滑 0.9237 m 停(解析 v² / (2 mu g) = 0.9174)、mu 0 一秒滑 3.000007 m。`test_chain_contact` 10/10
>   (分解 vs 稠密動作差 ≤ 1.8e-6)。
> - **閉環與直接解 ✅(2026-10-14)**:`LoopClosure`(link a 的點對 link b 的點或世界點)+ `resolve_loops`:每個閉環三條等式列,Jacobian 由 `point_jacobian`
>   自動組;速度解後以偽速度做位置投影。`ConstraintSet` 加 `residual`、`solve_active_set`(活躍列的稠密精確解,限制 / 接觸列進出活躍集;沒有座標能動的列
>   —— 平面鏈閉環的 z 列 —— 排除,遇冗餘列造成奇異才加相對對角位移)與 `solve_cg`(無矩陣 CG,等式列)。`test_loops` 6/6:平行四連桿 2 rad/s 轉 2 s,
>   閉環誤差 6.6e-7、連桿保持平行 9.1e-6、曲柄 1.94 .. 2.015 rad/s;1:100 交替的 10 節閉環鏈受破環扭轉:殘差 PGS 20 1.5e-4、PGS 100 4.1e-6、
>   直接 5.0e-6、CG 1.5e-6 —— 三條列 PGS 收斂得了,本條例子預期的 100 倍差距在這個系統上沒出現;同一閉環加兩次仍閉合。
> - **與最大座標 parity**:見 17.47(`test_joint_parity`)。
> - **球關節 ✅(2026-10-14)**:`Chain.add_ball` = 三個繞 body 自身 x / y / z 的 revolute(前兩個無質量)+ 第一個 link 上的四元數;每次積分後
>   `fold_balls` 把三個小角度併入四元數、歸零,並把角速率換成 body 角速度 —— 三個角度永遠在 0 附近,Euler 角奇異點(中間角 ±π/2)不會接近;
>   CRBA / RNEA / ABA 不變(只有 `_joint_rot` 讀四元數)。這不是把 S 推廣為 6×3 的寫法,而是「每步重設的局部座標」;已在文件與測試中寫明。
>   `test_ball_joint` 10/10:小擺週期 1.63958 s(解析 1.63878);無重力自由翻滾 2 s 能量 / 角動量漂移 4.66 % / 2.55 %(dt)、2.34 % / 1.27 %(dt/2,一階);
>   以 (0.3, 2, 0.3) rad/s 穿過中間軸奇異姿態:三個普通 revolute 外軸速率衝到 13.6 rad/s、能量誤差 14.9 %,球關節 0.49 rad/s、0.62 %;
>   對最大座標 `Joint6.ball` 3-D 擺動 2 s 尖端差 2.0 mm;10 rad/s 轉 8 圈四元數仍為單位;快照逐位。
> - **swing-twist 限制 ✅**:`set_ball_limits(body, axis, swing, twist_lo, twist_hi)`,`resolve_limits` 在球的三個 DOF 上解 swing 列(擺動旋轉軸)與
>   twist 列(軸本身)。3 rad/s 推向 0.5 rad 錐:最大 0.49999976;2 rad/s 扭向 ±0.3:0.3;錐 0 時軸不動(7.3e-4)、twist 自由。
> - **萬向 / 平面 / 自由關節 ✅**:`add_universal`(兩個垂直 revolute)、`add_planar`(兩個垂直 prismatic + 法向 revolute)、`add_free`(三個 prismatic + 球)。
>   `test_multidof` 5/5:萬向平面擺與球關節尖端差 2.9e-7 m、十字保持垂直 3.0e-8;平面關節在重力 (1, −9.8, 2) 下平面內加速度 0.9999992 / −9.800015、
>   z 不動、自轉保持;自由關節底座 + 三節手臂對 `FloatingChain` 尖端差 1.69 mm(dt 1/240)/ 0.85 mm(1/480)。`FloatingChain` 本身保留(重寫為自由關節
>   未做:兩者並存,parity 已量)。
> - **與 `ContactScene6` 雙向耦合 ✅**:`physics.chain_scene.couple_contacts`(有效質量 = 鏈 J H⁻¹ Jᵀ + 物體 1/m + (r×n)·I⁻¹(r×n),等大反向)。
>   `test_chain_scene` 5/5:擺錘撞 1 kg 箱(無摩擦地面)給出 1.4562792 N·s、箱子動量同值;5 kg 腿站在 1 kg 箱上壓 49.000023 N;靜態箱上與
>   `resolve_contacts` 落點差 0。
> - **link 形狀與自碰撞 ✅**:`physics.chain_shapes`(link 上的膠囊對世界走 `segment_distance`,非父子 link 之間取線段最近點,J = J_i − J_j)。
>   `test_chain_shapes` 4/4:1 m 手臂落在中段下方的平台上,中心線距平台邊 0.050000004(半徑 0.05);只有尖端接觸點時直接掃過(到 −1.5 rad);
>   折起的三節鏈第三節轉向第一節,中心線保持 0.10004(半徑和 0.1),不開自碰撞時 0.00015。
> - **O(n) 接觸傳播(量測後不採用為預設)**:`hinv_aba`(q̇、根運動、重力歸零時 ABA 的加速度即 H⁻¹τ),`resolve_contacts(..., aba=True)`。
>   每節都躺在地上,每步 分解 vs ABA:0.248 / 0.732 ms(n 8)、0.878 / 2.48(16)、3.34 / 8.89(32)、16.1 / 32.9(64)—— 到 n = 64 都還沒到交叉點,
>   ABA 每節的常數大過 n² 三角解;動作差 1.8e-6。
> - **待辦**:無(CPU)。GPU articulation 屬 17.17。

#### 17.55 連續體步進契約 — Wave B(連續體前置)

> **狀態**:✅ 完成(2026-10-14:`ContinuumSolver` 契約、統一失敗政策、快照參與、LBM 單位換算、耦合埠與固定的 tick 順序、`Runtime.advance_coupled`、
> 多求解器的組合登記、繩與軟體的契約化 ✅;布料在 17.56 已實作契約)。
> **進度註(2026-10-13)**:`physics/continuum.mojo`:`trait ContinuumSolver`(`advance(dt, gravity)`、`health()` → 非有限 / 越界 / 未收斂、`quarantine()`、
> `write_state` / `read_state` 經 `state_io`),實作 `FemContinuum`、`MpmContinuum`、`PbfContinuum`、`LbmContinuum`(住 `physics`,因 `fluid` 不得 import `physics`;
> 一個格子步 = `dt_lattice` 秒,`advance(dt)` 跑放得下的格子步並帶餘數)。`step_checked` 在 `advance` 前後各做一次健康檢查與隔離並計入新計數器
> `CONTINUUM_NAN` / `CONTINUUM_ESCAPED`;隔離政策:FEM 釘住非有限節點(位置取同一四面體的有限節點)、MPM 移除非有限與模板出格的粒子(原本在 P2G / G2P 被永久跳過且不計數)、
> PBF 移除非有限粒子、LBM 把非有限的格點重設為靜止平衡。
> 量測(`tests/test_continuum.mojo` 11/11):四個求解器經同一個泛型驅動,狀態寫出 → 讀入新實例 → 再跑 40 步,寫出的位元組相同;注入 NaN 的 FEM 節點 / MPM、PBF 粒子 / LBM 格點
> 被計數、隔離,之後 60 步維持有限;網格外的 MPM 粒子計入 `CONTINUUM_ESCAPED` 並移除;**發現**:只在步後檢查不夠 —— 一個 NaN 的 MPM 粒子經 P2G 在一步內汙染全部 64 個粒子
> (對照檢查),所以步前也檢查;步內自己產生的 NaN 仍可能在該步擴散。LBM 60 次 1/60 s(1 ms / 格子步)跑 999 個格子步(浮點累加)。
> bench `bench_continuum`(µs / 步,advance vs `step_checked`):FEM 275 節點 1223 vs 1289、MPM 1000 粒子 2941 vs 3246、PBF 1000 粒子 23377 vs 25726、LBM 16³ 1662 vs 1768(約 5–10 %)。

> **進度註(2026-10-14)**:`physics/coupling.mojo`:`trait CouplingPort`(關聯型別 `comptime S: ContinuumSolver`;`before` 把剛體狀態送進連續體、`after` 把連續體的
> 力 / 力矩加回 body)、`OneWay[S]`(不交換)、`couple_step`(固定順序:`before` → `step_checked` → `after` → 剛體步,同一 dt);`Both[A, B]` / `BothPorts[PA, PB]`
> 以巢狀組合登記多個求解器,順序在編譯期決定。`fsi.LbmSpherePort`:`LbmCoupler` 的交換改寫成埠,作用於 `LbmContinuum`。`Runtime.advance_coupled(frame_dt, port, solver)`
> 每個固定 tick 依 `couple_step` 的順序,計數記入場景的 `counters`。`Rope` 與 `SoftBody` 實作 `ContinuumSolver`(無場景的 `advance`、`health`、隔離時釘在有限鄰點、狀態讀寫);
> 其子步拆成與場景路徑共用的片段(`Rope._solve` / `_velocities`、`SoftBody.predict` / `solve_edges` / `finish`),`test_rope` 與全部軟體測試的輸出與 golden 逐字相同。
> 量測:`tests/test_coupling.mojo` 5/5(150 步 `couple_step` + `LbmSpherePort` 與 `LbmCoupler.step` 逐位相同,球 x 0.005397233;`Both[LBM, 繩]` 與兩者依序各自步進逐位相同;
> `Runtime.advance_coupled` 與 `couple_step` 逐位相同;`OneWay` 下格子在旁步進、body 與 `advance` 相同,幀間寫入的 NaN 格點被隔離並計 `CONTINUUM_NAN` 1 次);
> `tests/test_continuum.mojo` 15/15(繩、軟體快照往返後再跑 40 步位元組相同;NaN 粒子計數並釘住,其餘照常)。commit 6926060、ac21cdf。
> **現況**:連續體求解器今天有**七種互不相容的步進形狀**,沒有任何共同介面(`trait` 全表於 `physics/`、
> `fluid/`、`numerics/` 內只有 `SpinIntegrator`、`LinearOperator` 等與連續體無關者;`grep "^trait "` 後無
> 連續體 trait)。逐一核對:
> `SoftBody` 無 `step`,由 `ContactScene6.step` 子步迴圈在剛體位姿積分之後呼叫自由函式
> `softbody_pass`(`physics/solver6.mojo:1341`、`physics/soft_couple.mojo:46`),`h` 沿用剛體子步;
> `FemBody.step(dt, gravity, floor_y)`(`physics/fem.mojo:321`)與 `step_implicit(...) -> CgResult`
> (`:227`);`MpmSolver.step(dt, gravity)`(`physics/mpm.mojo:107`);`PbfFluid.step(dt, gravity, iters)`
> (`physics/pbf.mojo:235`)與 `sph_step`(`physics/sph.mojo:89`);`Lbm.step()` 無參數、dt 隱含為格子單位 1
> (`fluid/lbm.mojo:535`)、`LbmGpu.step(ctx, steps)`(`fluid/lbm_gpu.mojo:188`);布料是**整段 rollout 函式**
> `cpu_cloth_run(steps, iters, dt, rest)`(`physics/gpu_cloth.mojo:213`)與 `cpu_vbd_run`
> (`physics/vbd_cloth.mojo:254`),不是可逐步呼叫的物件;`Rope.step(sc, dt, gravity, substeps, iters)`
> (`physics/rope.mojo:134`)自帶子步並讀 `ContactScene6`,卻**不在**場景裡(`grep "Rope\b"` 於
> `physics/solver6.mojo`、`gameplay/` 零命中)。
> 宿主端同樣沒有位置:`Runtime` 只持有 `ContactScene6`(`gameplay/runtime.mojo:80`)並只呼叫
> `scene.step`(`:195`);`grep "FemBody|MpmSolver|PbfFluid|\bLbm\b|Rope\b"` 於 `physics/solver6.mojo`、
> `physics/body_set.mojo`、`collision/`、`gameplay/runtime.mojo` 零命中,`\bLbm\b` 於 `gameplay/` 只有
> `vehicle_tunnel.mojo` 的單向 Cd 取值(檔頭 `:1-20`,使用處 `:21`、`:88`)。
> 快照只涵蓋 `SoftBody`(`physics/solver6.mojo:1507-1521`);`StateWriter` / `write_state` 於 FEM、MPM、PBF、LBM、
> 布料、繩皆零命中(僅 `physics/serialize.mojo`、`state_io.mojo`、`runtime.mojo`、`solver6.mojo` 引用)。
> 失敗政策不一致:NaN 隔離只掃剛體(`physics/solver6.mojo:956-971` 迴圈 `bset.bodies`),`grep "isfinite|NAN"`
> 於 `soft_couple.mojo`、`softbody.mojo`、`mpm.mojo`、`pbf.mojo`、`sph.mojo`、`lbm.mojo`、`rope.mojo`、兩個布料檔皆零
> 命中(改用 `grep -i` 時命中 3 行,皆為註解字樣);FEM 隱式有 `CG_NOT_CONVERGED`(`physics/fem.mojo:299-301`,
> `diag/counters.mojo:58`);MPM 的粒子一旦離開 3 格模板範圍就在 P2G 與 G2P 兩處被 `continue` 跳過
> (`physics/mpm.mojo:126-129`、`:244-247`)——**永久凍結且不計數**。
> **架構限制(實查)**:`fluid` 與 `numerics` 同為第 2 層、同層互引禁止、`fluid` 不得引 `physics`
> (`scripts/arch_layers.toml:4-13`、`docs/ARCHITECTURE.md:21`;`fluid/*.mojo` 只 import `geometry`),
> 所以契約 `trait` 不能放在 `fluid`,LBM 要經 `physics` 內的轉接器才能符合契約。
> 已交付且**不重複主張**:softbody 與剛體雙向耦合 / CCD / 摩擦(6.1、6.6、6.7、`soft_couple.mojo:22` 的
> `soft_fric`)、17.41 繩、15.1 CG 回報、17.31 `SimBudget`。
> **缺口**:
> - **`ContinuumSolver` 契約**:`step(dt)`、子步比(連續體子步 : 剛體子步)、`state` 序列化鉤子、
>   `diagnose()`(回報有限性 / 越界 / 未收斂)。(例:`FemBody`、`MpmSolver`、`PbfFluid`、LBM 轉接器、
>   以及現有 `softbody_pass` 都以同一型別註冊)
> - **登記與排序**:場景(或 `Runtime`)持有一組連續體求解器,明定相對剛體求解的順序與耦合時點
>   (剛體子步內 = 現有 `softbody_pass` 位置;剛體步之後 = 單向)。(例:`Rope` 與一個 `FemBody` 同場景,
>   登記順序決定結果,必須是決定性的)
> - **統一失敗政策**:每個連續體求解器步末檢查有限性、隔離並記入 `diag.counters`
>   (新增例:`CONTINUUM_NAN`、`CONTINUUM_ESCAPED`)。(例:MPM 粒子飛出網格要計數而非靜默凍結)
> - **快照參與**:所有已登記求解器進 `write_state` / `read_state`,續跑逐位相同。(例:`FemBody` 載荷序列化
>   後讀回,再跑 100 步與不中斷版本逐位相同)
> - **耦合埠(coupling port)**:把 `soft_couple.mojo` 的「粒子被推出 + 反作用衝量回饋剛體」抽成
>   求解器無關的介面,宣告單向 / 雙向。(例:FEM 節點與 PBF 粒子日後共用同一個推出 + 回饋實作,不各寫一份)
> - **單位與時間慣例**:LBM 格子單位與 SI 之間的換算在契約邊界做一次(`tau_from_viscosity`
>   在 `fluid/d3q19.mojo:102`),不洩漏到呼叫端。
> **對照組**:Genesis(多求解器 + `Coupler` 的單一 `Simulator`)、PhysX 5(PBD 粒子 / 軟體 / 剛體共用一個
> `PxScene` 步進)、Houdini DOP(求解器鏈)、Unity Obi(`ObiSolver` 持有各 actor)、UE Chaos(solver 持有
> 各 physics proxy)。
> **優勢區**:決定論 + 單一快照 spine —— 契約化之後所有連續體免費進入 17.16 rollback / 17.39 回放 / 6.10
> 快照,別家多求解器引擎各自快照、跨求解器重現需額外工作。
> **規模軸**:已登記求解器數 × 子步比;轉接器每步的分派額外成本(comptime 泛型 vs 動態分派)。
> **seam?**:是 —— 「自由函式直呼(今日 `softbody_pass`)」vs「契約轉接器」:同一 `SoftBody` 場景走兩條路徑
> 後 golden 各段**逐位相同**(parity,行為不變重構的一貫要求);LBM 轉接器 vs 裸 `Lbm.step()` 同樣逐位相同;
> bench row:分派額外成本佔單步比例。
> **交付**:普通(`SoftBody`、`FemBody`、`Lbm` 各以契約登記並步進,結果等同直呼)/ 整合(`ContactScene6` 含
> 剛體 + 軟體 + FEM + 繩同場景,快照往返後續跑逐位相同;`Runtime.advance` 內步進;`gate` golden 既有各段
> 不變)/ 極端(零個求解器、一個求解器 `diagnose` 回報 NaN 其餘繼續、子步比 > 子步上限、登記順序顛倒、
> 求解器在步中被移除、dt = 0、MPM 粒子全部出界)。接線點 = `ContactScene6.step` 子步迴圈與
> `solver6.write_state`。
> **相依**:6.1(softbody pass)、6.10(快照)、17.42(LBM)、17.41(繩作為首個場景外求解器的先例)。
> **邊界**:只定契約與登記,不實作 17.56–17.62 的新求解器;每物件步進頻率 / 空間解析度分級屬 17.85
> (`docs/design/17.85-tiered-simulation.md:88` 已把軟體 / LBM / 粒子的 `period` 留在同一計畫,本條只提供
> 它掛載的物件);執行緒與 job system 注入屬 17.75;層級調整(契約 `trait` 放置)須與
> `arch_layers.toml` / `docs/ARCHITECTURE.md` §1 同一 commit。

#### 17.56 布料 — Wave B

> **狀態**:✅ CPU 完成(2026-10-14:任意三角網格布料、面積質量、釘點 / 附著剛體、與場景碰撞(含摩擦)、逐三角形風阻、撕裂、`ContinuumSolver` 契約、
> 帶號雙面角彎曲、拉伸上限、各向異性、雙向衝量、頂點對三角形自碰撞、著色平行求解 ✅;網格版 GPU 求解與 GPU 自碰撞屬第 7 層)。
> **進度註(2026-10-13)**:`physics/cloth.mojo` `MeshCloth`:每條網格邊一個 XPBD 距離約束、每條內部邊一個跨邊彎曲約束(兩個對頂點的距離,獨立柔度 —— 不是雙面角模型)、
> 頂點質量 = 三角形面積 × 面密度 / 3、`pin` / `attach`(頂點每子步跟隨剛體上的點)、`step(scene, dt, gravity)` 經 `collision.world_query` 對所有碰撞器做球形推出與摩擦
> (單向,每步只算一次位姿)、風阻 `drag · 面積 · (w·n) n`、邊力 |λ|/h² 超過 `break_force` 即撕裂(連同跨它的彎曲約束)、`advance` / 健康檢查 / 隔離 / 狀態讀寫(17.55 契約)。
> 每次迭代先投影彎曲、再投影拉伸 —— 相反順序時,硬的彎曲設定反而讓布被拉長、垂得更多(實測:軟 / 硬彎曲的條帶垂度 0.763 / 0.873 m)。
> 量測(`tests/test_cloth_mesh.mojo` 10/10):1 m² × 0.2 kg/m² 質量 0.2;12 三角形扇形 24 條邊、12 個彎曲約束;兩角懸掛 2 s 最低 y 0.253、最大邊應變 0.96 %;
> 0.3 m 夾持條帶自由端垂度 軟彎曲 0.209 / 硬彎曲 0.157 m(跨邊模型的彎曲效果有限);落在 0.6 m 箱上無頂點進入箱內(最低 0.31);重力下的旗幟平均 z:無風 0、4 m/s 0.259、8 m/s 0.428;
> 附著於 1 m/s 運動學 body 的頂點 1 s 後與 body 同位(差 < 1e-5);break force 0.5 N 時斷 238 條邊、預設 0 條;狀態往返續跑逐位相同;壞網格 raise。
> bench `bench_cloth_mesh`(8 子步 × 4 迭代):289 / 1089 / 10201 頂點時有箱碰撞每步 1346 / 5329 / 54401 µs,每頂點子步約 600 ns(隨規模持平)。

> **進度註(2026-10-14)**:`MeshCloth.set_bend_model(BEND_DIHEDRAL)`:跨內部邊的帶號彎曲角(atan2)做 XPBD,梯度依 Bridson et al. 2003,
> 以有限差分核對符號(q 向量為 −∇d);先實作的 acos 形式在接近平面時修正量 ∝ θ²,勁 / 軟兩條懸臂都垂 6.5 mm,故改用帶號角。`set_max_stretch(ratio)`:每子步解完後
> 以硬約束把邊長夾在 ratio × 靜止長(至少 4 輪);`set_anisotropy(axis, along, across, shear)`:依靜止方向給經 / 緯 / 斜向邊各自柔度(45° 斜邊單獨一類,否則勁的斜邊鎖住拉伸)。
> `step_two_way(mut scene)`:每次碰撞修正 dx 給動態 body 衝量 −m dx / h;碰撞迴圈抽成 `_collide` 與單向 `step` 共用(`test_cloth_mesh` 輸出與 golden 逐字相同)。
> `set_self_collision(radius)`:三角形入雜湊格,自由頂點對非其角點的三角形維持 radius,側別取子步起點,修正依逆質量與重心座標分配。
> `set_colored(on, workers, dispatch)`:彎曲 / 拉伸約束貪婪著色(同色不共點),各色經 `Dispatch` 以 256 個一塊並行。
> 量測(`tests/test_cloth_models.mojo` 11/11):平面內等比放大 10 %,一步後跨邊彎曲移動 0.078 m、雙面角 1.3e-17 m;懸臂(雙面角)柔度 100 垂 0.142 m、1e-6 垂 0.0065 m;
> 兩角懸掛軟布邊長比 1.689,上限 1.1 時 1.1000;垂直布在垂直軸勁時垂直邊比 1.0003、水平軸勁時 1.850;0.2 kg 布以 −2 m/s 落在 1 kg 自由箱(無重力)上,
> 箱得 −0.39999968 / 初始 −0.39999986 kg·m/s,單向時箱不動;兩層布落地,自碰撞 0.01 m 時平均高差 0.0091 m、無自碰撞 1e-8 m;著色解 4 workers 與 reverse 派發與串行逐位相同
> (拉伸 8 色、彎曲 8 / 18 色),懸垂最低點與逐點掃描差 2 cm 內。`bench_cloth_mesh`(32 × 32,含箱碰撞,µs / 步):跨邊 5798、雙面角 11232、拉伸上限 6579、自碰撞 16971
> (量於 gate 同時跑的機器上;著色 workers 表待安靜機器重量)。commit e7c613a、dc0a900、75b32ce、bc23e9b。
> **現況**:引擎的「布料」是**基準測試 / parity 原型**,不是可用的布料系統。
> `physics/gpu_cloth.mojo`(XPBD,gather 式 Jacobi,`:1-16`)與 `physics/vbd_cloth.mojo`(VBD,棋盤 2 著色
> Gauss-Seidel,`:1-20`、`:312-316`)都只處理 **`W×H` comptime 格網**(`cpu_cloth_run[W, H]` `:213`、
> `cpu_vbd_run[W, H]` `vbd_cloth.mojo:254`):只有 4 鄰結構彈簧(`gpu_cloth.mojo:272-284`)、單一 `rest`、
> **頂列寫死釘住**(`:240`)、只有 `y ≥ 0` 的地板夾制(`:305-306`)、單位質量(`vbd_cloth.mojo:270`)。
> `grep -iE "wind|aero|drag|friction|collider|triangle|mesh|bend|tear"` 於兩檔,有效命中**零**
> (命中的 4 行是 `self_collide` 字樣):無剪切 / 彎曲、無三角網格、無風 / 空氣動力、無摩擦、無與場景
> 碰撞器的碰撞、無撕裂。布料**不在場景內**:`grep -i cloth` 於 `physics/solver6.mojo`、`gameplay/runtime.mojo`、
> `physics/body_set.mojo`、`physics/serialize.mojo`、`physics/state_io.mojo` 零命中——與 17.41 繩
> (`Rope.attach` `physics/rope.mojo:86` 能掛剛體、被推出碰撞器 `:183-195`)相比差一整層。
> 自碰撞(15.2)是頂點對頂點排斥(`physics/self_collide.mojo:1-30`),以格網距離 `SKIP = 2` 排除拓撲鄰居
> (`:35`)——這個排除規則**綁定格網座標**,無法直接套到任意網格;檔頭自述不擋高速邊穿過兩頂點之間
> (`:14-16`,需 `collision/toi.mojo` 掃掠)。自碰撞只在 CPU 路徑(`self_thickness` 只出現在
> `gpu_cloth.mojo:215`、`vbd_cloth.mojo:256`),`gpu_cloth_run_ctx_timed`(`gpu_cloth.mojo:350`)沒有此參數。
> 已交付且**不重複主張**:GPU XPBD / VBD 與 CPU parity(2.4e-6 / 4.9e-5,ROADMAP 4.3 進度)、15.2 自碰撞及其
> 量測(XPBD gap 0.00034 → 0.05999)、`softbody` 體積格(不是布料:`box_lattice` 是實心 n³ 格,
> `physics/softbody.mojo:67`)。
> **缺口**:
> - **任意三角網格布料**:邊 / 彈簧由網格拓撲導出、頂點質量由面積導出、釘點與附著由資料給定。(例:一件
>   10⁴ 頂點的披風網格;著色改用貪婪圖著色,沿用 `solver6._color_pairs` 的思路 `physics/solver6.mojo:1016`,
>   取代棋盤 2 著色)
> - **剪切 + 彎曲 + 拉伸上限**:雙面角彎曲(dihedral / isometric bending)與各向異性經緯參數;嚴格拉伸
>   上限(超彈性織物)。(例:平放後垂掛的褶皺,彎曲剛度 0 → 大時褶皺由無到有)
> - **與場景碰撞**:重用 `ColliderSet` 的最近點(`softbody_pass` 對 box / hull / mesh 已有 `:108-` 的推出
>   路徑),加庫倫摩擦與可選雙向衝量回饋;可附著於剛體 / 布娃娃骨(如 `Rope.attach` `rope.mojo:86`)。
>   (例:披風掛在移動中的角色胸甲上,擦過牆不穿)
> - **空氣動力**:逐三角形風阻 / 升力,風速取自 `WindGrid`(`physics/fields.mojo:75`)或 LBM 速度場。
>   (例:旗幟在風場中飄動、風速加倍時展開角變化)
> - **撕裂**:邊張力超限即斷,重用 17.29 的斷裂閾值語意。
> - **網格自碰撞**:三角形 – 頂點 / 邊 – 邊近距檢測 + 以網格鄰接(而非格網座標)排除拓撲鄰居;高速以
>   `collision/toi.mojo` 掃掠補洞。(例:一塊布對摺後高速甩動不互穿)
> - **GPU 路徑補齊**:網格版 GPU 求解 + 自碰撞 GPU 版(今日 GPU 沒有)。
> **對照組**:NVIDIA NvCloth / UE Chaos Cloth(遊戲級)、Houdini Vellum、Marvelous Designer(服裝)、
> Baraff–Witkin 1998(隱式布料)、Bridson 等 2002(碰撞與摩擦)、ARCSim(自適應布料)、
> VBD(arXiv:2403.06321)。
> **優勢區**:**VBD 的理論優勢區在高剛度**——ROADMAP 4.3 進度已誠實記錄:簡單結構布料上 XPBD 收斂更快更省,
> VBD 的無條件穩定在高剛度 / 體積材質才顯現。因此 17.56 的 bench **必須含高剛度 + 強彎曲掃描軸**
> (優勢區規則),不得只在低剛度格網上下「VBD 輸」的結論。GPU gather 式無 atomics 保決定論
> (`gpu_cloth.mojo:5-8`)是對 PhysX / Warp 常見 atomics 路徑的差異點。
> **規模軸**:頂點數(10³ → 10⁶)× 剛度 / 彎曲剛度比 × 迭代數;著色數(網格價數不規則時增長,
> 注意 `_color_pairs` 的 64 色上限 `physics/solver6.mojo:1239` 與 `COLOR_OVERFLOW` `diag/counters.mojo:53`);自碰撞開關 × 褶皺密度;CPU–GPU 交叉點
> (傳輸成本隔離列,沿用 17.17 教訓)。
> **seam?**:是 —— 布料求解器變體(XPBD-Jacobi / VBD-著色 / 日後 Projective Dynamics)在同一網格:
> parity ① 規則格網網格化後與現有 `cpu_cloth_run` / `cpu_vbd_run` **逐位相同**(既有測試不改);
> ② CPU / GPU 容差沿用「GPU − CPU ≤ 2 × CPU 自身對擾動的發散」判準;③ 彎曲變體:平放布零彎曲力、
> 單一摺線的靜止角度兩變體一致。bench:每變體每頂點每步 ns,附最差邊拉伸誤差(公平準則 = 同品質比成本)。
> **交付**:普通(網格化格網 == 現有結果;披在球上靜止、不穿)/ 整合(掛在移動剛體上、風場吹動、
> 與 `ContactScene6` 同場景快照往返逐位相同、經 17.55 契約登記)/ 極端(零面積三角形、非流形邊、
> 單一三角形、全頂點釘住、重合頂點、價數 > 色數上限、dt 極大、NaN 輸入被隔離計數、撕裂到只剩孤立頂點);
> GPU(網格版 GPU 求解與 GPU 自碰撞各對 CPU parity,判準同 seam ②;無 accelerator 自動跳過)。
> **相依**:17.55(前提)、17.45(輸入網格焊接 / 修復)、15.2、17.29(撕裂閾值)、17.27 / 17.60(風 / 流場)。
> **邊界**:布料 authoring(權重繪製、圖樣縫合)、蒙皮渲染、LOD 切換屬宿主;毛髮屬 17.57;布料 – 流體屬
> 17.59 / 17.61;輸出 / 快取屬 17.63;形變資料(blend shape 等)屬 17.65。

#### 17.57 毛髮 / 肌肉 — Wave C
> **進度註(2026-10-13)**:(1)股線:`physics/strand.mojo` `StrandSet` —— Follow-The-Leader(Müller 2012,速度以下一粒子位移修正,`ftl_damping` 0.9)
> + 直線靜止形的彎曲拉回(`bend`)+ 根部隨骨骼 `Pose6` + 球 / 膠囊推出 + 常數風或 `WindGrid` + `teleport`。(2)肌肉:`physics/actuator.mojo` `HillParams`
> (力 – 長度高斯、力 – 速度雙曲 / 離心 → 1.8、被動指數,常數力臂、剛性腱;各曲線獨立開關)與 `ActuatorBank.add_hill` / `muscle_force`。
> 量測:`tests/test_strand.mojo` 12/12 —— 自由股線(16 粒子、空氣阻力 2/s)5 s 後尖端在根正下方 0.6 mm 內、最大伸長 9.5e-7;bend 0.5 時 1 s 下垂 8.3 cm(自由 70 cm);
> 頭 0.2 s 轉 90°:馬尾尖端擺出 39 cm、3 s 後離轉頭後靜止形 2.3 mm;32 股披在 10 cm 頭上最深 −1.8e-8(碰撞推出使該段伸長至多 1.8 %);均勻 `WindGrid` 與常數風逐位相同;
> 100 m 根部瞬移配 `teleport` 形狀差 2.3e-6、不配則尖端速度 1.2e4 m/s 但有限。`tests/test_muscle_hill.mojo` 9/9 —— 曲線全關時 2 s 軌跡與 `Actuator.muscle` 逐位相同;
> 等長力峰在纖維 = l_opt 處、±30 % 為 0.819;縮短 vmax/2 為 1/6、vmax 為 0、快速伸長 1.797;被動力在 +60 % 為 1.0;啟動度 0.5 的屈肌對抗重力靜止於 q = 1.68,
> 力矩 4.86999 vs 重力 4.86999。`bench_hair_muscle`:股線 37 ns / 粒子·步(加頭球 + 兩肩膀囊 47);肌肉 23 ns / 致動器(Hill 44)。
> **進度註(2026-10-17)**:
> - `physics/strand_ext.mojo`(自由函式,`StrandSet.step` 不動):`strands_write` / `strands_read` 快照、`strands_collide`(根到梢先回復段長再對場景碰撞體推出 + 摩擦,
>   共用 `fem_scene.point_contact`)、`strands_interact`(Petrovic 2005 式體素平均速度,雜湊格,無 O(n²))、`interpolate_strand`(引導髮偏移加權)。
>   `test_strand_ext` 5/5:還原後 60 步逐位相同;單一引導 = 平移到新根、兩引導各 0.5 = 偏移平均;16 股披在場景盒上 0 粒子在內、最差段伸長 7 %(盒緣:推出後再拉長,
>   先只做事後推出時為 20 %);體素速度離散 0.477 → 0.334(k 0.3),體素動量守恆。
> - 體積肌肉(`FemBody.set_fibers` / `activation` / `active_forces`,`step_ext`;主動應力 P = a σ (F d)⊗d):`test_fem_muscle` 6/6:0.6 m 自由肌塊 E = 1e5、ν = 0.45、
>   啟動 1 時縮短 16.7 %、寬 0.2 → 0.215 m、體積 −3.7 %(線性共旋轉在 17 % 應變下非不可壓);釘住一端時長度隨啟動度 0.25 / 0.5 / 1 為 0.574 / 0.550 / 0.508 m、
>   σ 加倍 0.441 m;啟動 0 與無纖維逐位相同;與塑性同在 `step_ext`。
> - **股線停不下來(修正)**:macOS CI 上 `test_strand`「ponytail settles」失敗(3 s 後梢距 2.8 cm,x86 為 2.3 mm)。量測:頭不動時 bend 0.3 的股線
>   第 10 秒粒子速度仍達 2 m/s;梢在 3–8 s 間於 0.2–4.7 cm 間遊走,±1e-6 rad 擾動就換一條軌跡——x86 的通過只是那一瞬間剛好近。原因:Müller 的速度修正
>   −0.9 · (下一粒子 FTL 位移)/dt 中位移含重力預測下落 g dt²,靜止時固定點 v* = 0.9/(1 − 0.9) g dt ≈ 0.73 m/s 沿鏈。改為從慣性預測 x + v dt 量位移
>   (固定點 v = 0);但那個偏差原本是主要耗散(ftl_damping 0 時自由鏈升到 10 m/s),故加第 5 步:相對前一粒子的速度以 `inner_damping`(預設 20 /s,
>   16 × 5 cm 鏈約臨界)衰減,剛體運動與靜止不受影響。結果:靜止頭第 10 秒最大速度 2.3e-4 m/s;轉頭擺幅峰值 0.448 m(原 0.394),6 s 後距 20 s 參考形 4e-6 m,
>   約每 2 s 縮 4 倍;自由鏈 8 s 後梢 x 1.7e-4 m(檢查改 5 → 8 s:原 5 s 的收斂靠的是那個偏差);5 m/s 風的穩態偏移 4.7 cm(原檢查 > 5 cm 取自 2 s 時的過衝,改 > 3 cm)。
>   `test_strand` 13/13(新增「靜止頭會停」);`test_strand_ext` 盒上最差段伸長 7.2 %。`bench_hair_muscle` 每粒子步 37.4 → 40.8 ns(+9 %)。
> **未做**:DER 扭轉、捲曲靜止形、與 `Rope` 懸鏈線的 parity、串聯腱順應、`SpatialTendon` 力臂、可微肌肉控制。

> **現況**:**毛髮不存在**:`grep -iE "\bstrand|cosserat|\bfur\b|\bhair\b|fib(er|re)"` 於全部引擎套件只有兩處
> 慣用語註解(`physics/sensors.mojo:107`、`physics/ccd6.mojo:25`,皆為「a hair off」)。最近的是 17.41
> 繩——1D XPBD 鏈、**無彎曲 / 扭轉剛度**(`physics/rope.mojo:17`),且其進度註自列待辦「繩自碰撞、Cosserat 桿」
> (ROADMAP 17.41 進度,ROADMAP §17.41)。
> **肌肉只存在於關節空間**:`Actuator.muscle`(`physics/actuator.mojo:70-80`)= 不對稱啟動動力學
> (收縮快、放鬆慢,`:125-133`)+ 單邊力 `f_min = 0`;力為「增益 × 啟動度」的仿射形式(`:135-`),
> 沒有力 – 長度 / 力 – 速度 / 被動彈性曲線(`grep -iE "force.?length|force_velocity|pennation|passive.?force"`
> 於 `actuator.mojo`、`tendon.mojo` 零命中,僅「Hill-type」一句 docstring 命中)。腱 `FixedTendon` /
> `SpatialTendon`(`physics/tendon.mojo:64`、`:188`)作用在 `Chain` 關節,繞行障礙為**世界固定**
> (`:29`);軟組織肌肉(體積、纖維方向、主動應力)無:`FemBody`(`physics/fem.mojo:91`)與 MPM
> (`physics/mpm.mojo:147-159`)都只有被動本構。已交付(13.3 致動器、13.4 腱、17.2 主動布娃娃)**不重複主張**。
> **缺口**:
> - **毛髮 / 毛皮股線**:離散彈性桿(DER)或 FTL(Follow-The-Leader)股線,含彎曲 + 扭轉、根部附著於骨骼
>   (`geometry/skinning.mojo` 的馬達蒙皮提供根部運動)。(例:一條 16 節馬尾,頭部急轉後的擺盪與回復)
> - **股線 – 場景碰撞**:對頭 / 肩膀的膠囊 / SDF 推出,摩擦;**股線 – 股線**:格網式密度 / 摩擦(Petrovic 2005 式
>   體素速度場)取代 O(n²)。(例:10⁴ 股線的整頭髮不穿頭)
> - **引導髮 + 插值**:只模擬引導股線,輸出插值規則給宿主增生;風取自 `WindGrid`。
> - **Hill 型肌肉完整曲線**:力 – 長度、力 – 速度、被動彈性、串聯腱順應,作為 `Actuator.muscle` 的變體;
>   肌腱路徑重用 `SpatialTendon` 的力臂。(例:二頭肌在不同關節角下的等長力曲線)
> - **體積肌肉**(依賴 17.58):FEM 四面體上的纖維方向各向異性主動應力 + 體積保持,與骨骼(`Chain` / 剛體)附著。
>   (例:前臂肌腹隨啟動度鼓起且體積守恆)
> - **可微肌肉控制**:啟動度 → 軌跡的梯度(接 17.62)。
> **對照組**:Houdini Vellum Hair / Ziva VFX(肌肉 + 脂肪)、Maya XGen / nHair、UE Groom + Chaos 毛髮、
> OpenSim / MuJoCo(Hill 型肌肉含 F-L-V 曲線)、Bergou 等 2008 Discrete Elastic Rods、Müller 等 2012
> Fast Simulation of Inextensible Hair and Fur、Thelen 2003 肌肉模型、Teran 等 2005 骨骼肌 FEM。
> **優勢區**:股線之間天然獨立 → 沿用 6.11 / 4.3 的「著色 / gather 式無 atomics」平行與決定論;股線數 10⁵ 以上
> 的 GPU 吞吐是理論優勢區(17.62)。肌肉:決定論 + 可微(啟動度優化)——MuJoCo 肌肉不可微(MJX 才可微),
> 與 17.18 / 17.20 的「批次 × 可微」主張同線。
> **規模軸**:股線數(10² → 10⁶)× 每股節數 × 股線互作開關;肌肉數 × 路徑點數;FEM 肌肉四面體數。
> **seam?**:是 —— 股線求解器變體(XPBD 鏈 / FTL / DER):parity = 零彎曲零扭轉極限下與 17.41 `Rope` 懸鏈線
> 一致(沿用 `test_rope` 的 5% 懸鏈線判準);肌肉變體:F-L-V 曲線全設為 1、無被動項、無串聯腱時與現有
> `Actuator.muscle` **逐位相同**。bench:每股線每步 ns、股線互作開關成本。
> **交付**:普通(單股線垂掛 = 懸鏈線;肌肉啟動階躍響應 = 現有 `test_actuator`)/ 整合(股線根部跟隨移動中的
> 骨骼馬達、對 `ColliderSet` 碰撞、風場吹動、快照往返逐位相同;肌肉驅動 `Chain` 的關節)/ 極端(單節股線、
> 零長度節、全股線釘住、根部瞬移、肌肉啟動度越界 [0,1]、纖維長度 → 0 的 F-L 曲線奇異點、股線數 0)。
> **相依**:17.55、17.41(繩)、17.58(體積肌肉)、17.2、17.62、13.3 / 13.4。
> **邊界**:髮型 authoring、毛髮渲染 / 卡片 LOD 屬宿主;骨骼肌可見形變輸出屬 17.65;肌肉生理學驗證
> (對 OpenSim 資料)是 benchmark 軸,不是臨床宣稱;完整物理角色屬 17.66。

#### 17.58 體積軟體 — Wave C
> **進度註(2026-10-13)**:本構模型 seam 先行。`physics/fem_material.mojo`:`Material` trait(`pk1(F, mu, lam)`,編譯期選擇)與三個實作
> `Corotational`(與 `FemBody.elastic_forces` 逐位相同)/ `StableNeoHookean`(Smith 2018 去 log 項:λ_s = λ + μ、α = 1 + μ/λ_s,P = μF + λ_s(J − α) cof F,
> 反轉時仍有定義)/ `StVK`;`material_forces[M]`、`step_material[M]`(與 `FemBody.step` 共用新拆出的 `FemBody.integrate`)、`inverted_count`。
> `add_tet` 的註解改正:負向四面體以 |det| 保留是對的(F 與頂點順序無關,靜止時 det F > 0),原註解稱「略過」不實。
> 量測(`tests/test_fem_material.mojo` 10/10):應變 1e-3 時 NH / StVK 對共旋轉差 0.077 % / 0.21 %;63° 剛體旋轉 |P| 0 / 1.1e-4 / 1.2e-5(μ = 1000);
> 懸臂樑 12×2×2、E = 1e7、隱式 600 步:尖端撓度 6.20 mm,Euler–Bernoulli 8.57 mm,比 0.72(線性四面體彎曲鎖死);E = 1e5 顯式 3 s:共旋轉與 NH 尖端差 0.04 %;
> 單一四面體推過對面(det F = −0.2)放開 2 s:NH 回到 det F = 1.02,StVK −0.98、共旋轉 −1.02 維持反轉;單軸壓到 2 %:StVK 回復應力 35(峰值 674),NH 3430。
> `bench_fem_material`(960 四面體):共旋轉 1545 ns/四面體(內建路徑 1793)、NH 163、StVK 185 —— 極分解占主要成本。
> **進度註(2026-10-17)**:
> - **FEM 進場景**(`physics/fem_scene.mojo` `FemContactPort`,經 17.55 `couple_step`):每個節點(半徑球)對場景所有碰撞體推出(盒取**進入面**、球 / 膠囊徑向、
>   其他形狀走 `soft_particle_contact`)+ 位置級 Coulomb 摩擦 + 對動態剛體的等大反向衝量;`fem_coupled_step` 以子步跑整個耦合步。
>   **發現**(皆量過):隱式 FEM 在解外處理接觸時,後向 Euler 只回傳輕節點彈性衝量的 m / (m + dt²k)(此處約 1/29),50 kg 箱子陷入方塊 9 cm(同負載作為質量時壓縮 3 mm);
>   顯式 24 子步 + 每幀一次接觸會爆;每子步接觸 + 每幀剛體步會抖且漂 9 cm;盒子以最小穿透推出時箱緣切入方塊。
>   `test_fem_scene` 6/6:顯式 16 子步,箱底距節點頂 ≤ 1.6 mm、3 s 漂移 2.4 cm、殘留 8 Hz 彈跳 ≤ 0.17 m/s(未靜止,如實記錄);
>   零重力球撞方塊動量守恆至 1e-7(方塊得 3.45 kg·m/s);場景 + FEM 快照續跑 30 步逐位相同;`FemContinuum` 加 `implicit` / `substeps`。
> - **四面體網格化**(`geometry/tetmesh.mojo`):閉合三角網格 → 體素(`convex_decomp.voxelize`)→ 每格 5 四面體(與 `make_beam` 同交替分割,共角點)、`embed` / `place`
>   重心嵌入;`physics.fem.fem_from_tetmesh`(集中質量)。`test_tetmesh` 7/7:24×12 UV 球,體積誤差對網格本身 8 / 16 / 24 格 3.6 % / 0.37 % / 0.03 %;
>   266 個表面頂點嵌入重建 4.3e-8 m、剛體運動後跟隨 1.3e-7 m;E = 5e5 的球落地 3 s 後最快節點 0.012 m/s、體積變 0.39 %。
> - **塑性 / 元素移除**(`FemBody.set_plasticity` / `step_ext` / `remove_overstrained`;Müller & Gross 2004 的屈服 + 潛變 + 上限):
>   `test_fem_plastic` 4/4:1 m 懸臂 E = 1e7 10 g 下彈性下垂 0.298 m、卸載後回到 0.3 mm;塑性下垂 0.872 m、卸載後永久 0.652 m;
>   拉桿 0.3 應變上限移除 104 個四面體分成 4 塊,不移除則只拉長到 1.60 m;關閉時既有 FEM golden 不變。
> - **MPM 靜態障礙 + 實驗性沙**(`MpmSolver.add_obstacle` / `set_sand` / `step_ext`):格點在 `Sdf3` 內時去掉進入速度並施 Coulomb 摩擦,仍落在內部的粒子推回表面
>   (只靠格點投影時 288 個沙粒有 80 個陷入盒內半格以上)。`test_mpm_sand` 5/5:2 m/s 方塊在 μ 0.6 障礙地板上滑 0.346 m(v²/2μg = 0.340),μ 0 時 0.83 m;
>   倒在盒上的沙 0 粒在內、9 粒在頂。**沙未達標**(如實記錄):Klár 2016 對數應變回映射在單一 F 上行為正確(純壓縮不變、剪切被削減而體積保持),
>   但 0.42 m 沙柱 0.3 s 後頂高 30° 0.084 m、60° 0.176 m、85° 0.345 m(彈性 0.372)—— 隨摩擦角單調,85° 能站,30° / 60° 卻持續攤開而不停在休止角;
>   疑因(未證):回映射是對 Hencky 應力定義的錐,本求解器應力律是 fixed-corotated。另:網域牆只去法向速度(無摩擦),沙需以障礙作地板。
> - **發現**:在 `FemBody.step` / `MpmSolver.step` 函式體內加任何分支(即使從未執行的提早 return)或把函式體搬進 comptime 參數化的 helper,都改變編譯結果、
>   動到 `test_thermal`(0.011999987 → 0.0119999945)與 `test_mpm`(spread 0.20055819 → 0.20055932)的末位;兩者保持原函式體逐位不動,
>   擴充改走 `FemBody.step_ext` / `MpmSolver.step_ext`(`FemContinuum` / `MpmContinuum` 依設定選用)。
> **未做**:隱式步的 NH 切線、近不可壓鎖死對策、沙的休止角(應力律與回映射一致化)、VBD / PD 求解器變體、節點 CCD。

> **現況**:引擎有**三條**體積可變形路徑,但只有一條在場景裡。
> ① `SoftBody`(`physics/softbody.mojo:50`):只有 `box_lattice`(`:67`;`n < 2` 直接 raise `:82-83`)產生的實心 n³ 粒子格、
> 13 方向**純距離約束**(`:101-119`),剛度由格連接方式決定而非材料(`physics/fem.mojo:3-6` 自述);已進場景
> (`physics/solver6.mojo:151`、`:209`、`:1341`)、有摩擦 `mu`(`softbody.mojo:56`)、CCD、快照
> (`solver6.mojo:1507-1521`)。② `FemBody`(`physics/fem.mojo:91`):**共旋轉線性**四面體(`:182-225`),
> 顯式 `step`(`:321`)與隱式 CG `step_implicit`(`:227`,15.1);碰撞只有一個 `floor_y` 平面
> (`:315`、`:349`);**不在場景內、無快照**(`FemBody` 只出現於 `physics/fem.mojo` 與
> tests / benchmarks / examples);唯一網格產生器是 `make_beam` 的 5 四面體 / 格
> (`:491`)。③ `MpmSolver`(`physics/mpm.mojo:44`):固定共旋轉應力(`:147-159`)+ 行列式夾制塑性
> (`:305-318`);邊界只有 3 格「黏牆」(`:221-233`);粒子出界即靜默凍結(`:126-129`、`:244-247`);**無剛體耦合**。
> 零命中:`grep -iE "neo.?hook|stvk|saint.?venant|mooney|ogden|hyperelastic"` 於全部引擎套件 **零**(只有共旋轉線性,
> 與 `corotational = False` 時的純線性 `:195`);`grep -iE "delaunay|tetgen|tet_mesh|tetrahedraliz|from_surface"` **零**(沒有從表面網格生成四面體);
> 執行期四面體翻轉(inversion)無處理——`add_tet` 只在**建立時**略過退化(`|det| < 1e-12`)四面體,
> 反向四面體以 `abs(det)` 體積照收(`fem.mojo:161-165`;註解稱 inverted 亦略過,程式並未檢查符號),`polar_rotation`(`:64-78`)僅 12 次 Newton。`GpuContactSolver` 遇軟體直接拒絕
> (`physics/gpu_contact.mojo:347-348`)。`geometry/sdf3.mojo` 只被 tests / bench 使用(`grep -rl sdf3`:
> `tests/test_sdf3.mojo`、`benchmarks/bench_sdf3.mojo`),MPM 的碰撞體沒有 SDF 來源。
> 已交付且**不重複主張**:FEM 共旋轉性質(剛體旋轉零力)、隱式 vs 顯式剛性材料對照(15.1:E = 2e5 顯式發散)、
> MPM 彈 / 塑性(`test_mpm`)、軟-剛雙向耦合與 CCD(6.1 / 6.6 / 6.7)。
> **缺口**:
> - **FEM 進場景**:`FemBody` 以 17.55 契約登記,節點對 `ColliderSet` 推出 + 摩擦 + 反作用衝量(把
>   `soft_couple.softbody_pass` 的粒子接觸泛化到 FEM 節點)。(例:50 kg 箱壓在 FEM 橡膠塊上,橡膠被壓扁、
>   箱停住,動量守恆)
> - **本構模型庫**:穩定 Neo-Hookean / StVK(含反轉安全能量:Irving 2004 / Smith 2018),與現有共旋轉並列為
>   變體;近不可壓縮(ν → 0.5)的鎖死對策(混合 / F-bar)。(例:ν = 0.49 的橡膠立方體在壓縮下不鎖死)
> - **四面體網格化**:閉合表面三角網格 → 四面體(BCC 格 / 受限 Delaunay),加嵌入式視覺網格的重心座標。
>   (例:一個 3k 三角形的茶壺表面 → 可模擬四面體)
> - **塑性 / 黏彈**:FEM 的 J2 塑性、MPM 的 Drucker–Prager(沙 / 雪)。
> - **MPM 邊界**:滑移 / 分離邊界、以 SDF 碰撞體(`geometry/sdf3.mojo`)作靜態邊界;出界粒子計數
>   (與動態剛體的雙向格點耦合屬 17.59,本條不重列)。
> - **求解器變體**:FEM 的 VBD / Projective Dynamics / XPBD-FEM 約束,與現有顯式、CG 隱式並列。
> - **元素移除式斷裂**:應力超限刪四面體(與 17.5 破壞分工,見邊界)。
> **對照組**:PhysX 5 軟體(FEM 四面體)、Houdini Vellum / FEM、Ziva、Abaqus / Ansys(精度基準)、
> Genesis FEM / MPM、Taichi MPM88、Warp FEM、Stomakhin 2013(雪)、Macklin 2016(XPBD 四面體)、
> VBD(arXiv:2403.06321)。
> **優勢區**:已量到的——剛性材料同 dt 下顯式發散、隱式穩定(15.1);故本條的優勢區軸是**高剛度 × 大 dt × 近不可壓**
> (隱式 / VBD 區),以及 MPM 的拓撲變化(流動、堆積、合併:FEM 做不到)。本構庫的優勢區 = 大壓縮 / 反轉
> (共旋轉線性的薄弱處)。決定論的 CG(固定歸約順序)是對 GPU atomics 路徑的差異點。
> **規模軸**:四面體數(10³ → 10⁶)× 楊氏模量(剛度比)× ν × dt;CG 迭代數(Jacobi 預條件 `numerics/cg.mojo:73`
> 已有,可加更強預條件);MPM 每格粒子數、格數。
> **seam?**:是 —— ① 本構(共旋轉 / Neo-Hookean / StVK):小應變下一致、剛體旋轉皆零力、大壓縮處分歧(量給出);
> ② FEM 時間積分(顯式 / CG 隱式 / VBD / PD):收斂到同一靜態解——懸臂樑尖端撓度對 Euler–Bernoulli 解析解;
> ③ 場景內 FEM vs 晶格 `SoftBody` 在同一箱子落地場景的「落地靜置 + 動量守恆」可觀察量一致(各自容差)。
> 每變體附 bench row。
> **交付**:普通(懸臂樑撓度對解析解;剛體旋轉零力;體積守恆)/ 整合(FEM + 剛體 + `SoftBody` 同場景、快照
> 往返逐位相同、經 17.55 登記、MPM 沙堆在 SDF 靜態碰撞體上堆積靜止)/ 極端(單一四面體、零體積 / 翻轉四面體、ν = 0.5 邊界、
> 全節點釘住、MPM 全部粒子出界、E 相差 10⁶ 的雙材料、dt 極大時 `CG_NOT_CONVERGED` 計數且世界繼續)。
> **相依**:17.55(前提)、17.45(網格焊接 / 修復,四面體化的輸入)、15.1、17.5、17.62。
> **邊界**:肌肉屬 17.57;皮膚 / 脂肪的可見形變輸出屬 17.65;剖開與碎裂的幾何屬 17.5(本條只做元素移除);
> 流體 – 結構屬 17.59;DCC 內的網格 authoring 屬宿主。

#### 17.59 流固耦合 — Wave C
> **進度註(2026-10-13)**:LBM ↔ 移動剛體先行。`fluid/lbm.mojo`:Ladd 1994 移動壁面 bounce-back(反射分布加 6 w_i (c_i · u_w))、`set_wall_velocity`、
> `add_moving_sphere` / `move_sphere`(重新標記格點;離開的格以鄰格平均密度 + 壁速平衡態補上,被覆蓋的格的動量以衝量交給球,Aidun 1998)、
> 每物體力 / 力矩(`obj_f` / `obj_t`,動量交換);無移動固體時程式路徑不變。`physics/fsi.mojo` `LbmCoupler`:物體位姿 / 速度 → 格點單位 → `Lbm.step` →
> 力 F_lat ρ dx⁴/dt²、力矩 ×dx 與解析浮力 −ρVg → `add_force` / `add_torque` → `ContactScene6.step`(同 dt,一格點步一物理步,顯式分區)。
> 量測:`tests/test_lbm_moving.mojo` 6/6 —— Couette(H = 16、lid 0.05)剖面誤差 1.3e-6(0.003 % U);R = 4 的平移球阻力對 Stokes-Hasimoto(以相對平均流速)比 0.97
> (週期箱中阻力會把整個流體帶動:平均流速達 U 的 41 %,未扣除時比值只有 0.57);旋轉球力矩對 rotlet 比 1.04;壁速 0 時與靜止格子逐位相同;每步跳 0.3 格 40 步質量變化 0.7 %。
> `tests/test_fsi.mojo` 5/5 —— 1 mm 格、1 ms 步、ρ = 1000:密度 1500 的 3 mm 球終端速度對 Stokes-Hasimoto 0.997(流體以均勻體力承擔淨重,Hasimoto 設定);
> 球落到場景中的靜態板上停住(中心 9.97 mm,理想 10);密度比 1.0 以 5 cm/s 發射 0.3 s 後 0.47 mm/s;**密度比 0.5 發散**(1.2e4 m/s,added-mass 不穩定,已斷言為現況)。
> `bench_fsi`(32³,與 gate 同時執行故絕對值偏高):無固體 / 靜止球 / 1 移動球 / 8 移動球每格步 397 / 398 / 364 / 384 ns;耦合一步 14 ms。
> **未做**:強耦合迭代(Aitken)與輕物體、移動球跨週期邊界、`move_sphere` 的 O(格數) 掃描改局部、Galilean 不變修正(Wen 2014)、SPH / PBF 邊界粒子雙向、
> MPM ↔ 剛體、柔性體 ↔ 流體、17.55 登記與快照。
>
> **進度註(2026-10-17,輕物體)**:先量後修。`experiments/exp_lbm_added_mass.mojo` 以隨機速度驅動 R = 3 格的球、
> `scripts/added_mass_fit.py` 以最小平方擬合 F_n = Σ c_k v_{n−k}(相對殘差 0.07–0.11),再算各更新式的譜半徑:同步項 c₀ = −75(0.66 ρV);
> 顯式在密度比 0.5 為 1.22、0.2 為 2.95(發散)。**第一個嘗試失敗**:虛擬附加質量 (m + m_a)Δv = F + m_a a_prev(C_a 0.5)模型上穩定,
> 實際在密度比 0.5 跑到 6.6e6 m/s——後段流體力與加速度同號,a_prev 項注入流體沒給的動量;已移除。
> 採用 Ladd & Verberg 2001 的隱式壁面阻力:Ladd 力中對壁速線性的部分 −Z u_w(Z = Σ 6 w_i c_i c_i,新方法 `Lbm.wall_drag`,
> 量得 0.684 ρV,與擬合 0.66 一致)改用新速度,(m + ρZdx³)Δv = (F + mg)dt;力矩同理 (I + ρZ_r dx⁵)Δω = T dt(Z_r = 0.905 · 0.4ρVR²)。
> 只做平移時自轉每步變號放大(5 步 ×2.6),加上轉動項後才穩定。`LbmSpherePort.set_implicit(True)`(預設關,關時與 `LbmCoupler` 逐位相同;
> `test_coupling` / `test_fsi` / `test_lbm*` golden 段不變)。`tests/test_fsi_added_mass.mojo` 5/5:密度比 0.5 / 0.2 / 0.05 以 5 cm/s 發射,
> 0.3 s 後 |v| 0.55 / 0.42 / 0.40 mm/s,全程不超過發射速度;顯式同設定 1.97e4 m/s;密度比 1.5 沉降 0.4 s 速度 38.5 vs 顯式 40.4 mm/s(4.8 %,斷言 < 5 %)。
> Z 只在 `add_sphere` 時量一次(球移動後連結數會變幾 %)。
> `move_sphere` 的「離開的格」改掃舊位置的包圍盒(升序同全格掃描,故 `test_lbm*` / `test_fsi*` / `test_coupling` golden 逐位不變):64³、R = 4 每次
> 437 → 11 µs;但一個 stream 步 100 ms,耦合一步只省約 0.4 %(`bench_fsi` 的列在雜訊內,未更新)。
> 移動球跨週期邊界:中心保持未折返座標,`_place` 在週期軸上以未夾制的包圍盒走訪、索引時折返,`stream` / `wall_drag` 的力矩臂取最小映像(tunnel 模式 x 不折返)。
> `tests/test_lbm_periodic.mojo` 5/5:R = 3 球自 x = 18.3 等速 + 自轉穿過 x = 24,與平移 12 格不靠邊的雙胞胎比,力 / 力矩序列誤差 1.1e-5 / 1.1e-5(峰值比),
> 質量相同至 1e-7;耦合物體穿越後速度與雙胞胎差 4e-6;中心在四個週期外與折返位置同;舊程式碼同測試 4/5 失敗(力誤差 27 %、力矩 50 %、質量多 0.9 %)。
> 既有 golden 只有兩個已發散的情形改變(顯式密度比 0.5:球飛出盒後舊程式碼不再受力,現在折返後繼續受力而變 inf;兩測試仍通過)。
> **SPH ↔ 剛體雙向**(`physics/sph_rigid.mojo` `SphRigidCoupler` / `sph_rigid_step`,Akinci 2012 的邊界取樣 + Adami 2012 的牆壓):
> 物體表面取樣(箱每面格心、球 Fibonacci)存法向與面積;流體側用 Akinci 的壓力推力與黏滯,物體側的黏滯逐對回饋,**壓力改為表面積分**
> F = −Σ m_p p_b A_b n_b(p_b:Shepard 加權流體壓力 + 靜水差 ρ g·(x_b − x_i));穿入物體的流體粒子推回表面、去掉向內相對速度,動量交給物體。
> 量測先行:原本 Akinci 的逐對反作用力在 10 cm 核 / 10 cm 箱上給出 2.3 倍排開重量——拆成六片量,每個垂直面被往上推 9.4 N(單側壓力項沿壓力梯度的偽力,
> 與面積成比例);表面積分後 0.98–1.00。這個 SPH 很軟(剛度 8):靜置水槽平均約 1500 kg/m³、底層 2373,所以阿基米德對照的是量到的密度剖面,不是 1000。
> `tests/test_sph_rigid.mojo` 6/6:無耦合物體時與 `sph_step_boundary` 逐位相同;靜置 10 cm 箱浮力 / 排開重量 1.002;密度 500 的 15 cm 箱 2 s 後
> 浮著(vy −7.7 mm/s、流體力 / 重量 1.016、頂面高於液面 11 cm);密度 3000 的箱深 11 cm 且仍下沉(2 s 時 2.8 cm/s,4 s 時 7.5 mm/s:
> 底下被擠壓的流體承擔部分重量、慢慢流出);兩箱內皆無流體粒子。代價:流體受的壓力推力與物體受的壓力不再逐對相等(黏滯與推回仍守恆)。
> 未做:PBF 版(剛體粒子進密度約束,Macklin 2014)、取樣點的鄰居搜尋(現為 O(粒子 × 取樣點);1152 粒子 + 216 取樣點的耦合一步約 18 ms,由測試總時間 200 s / 約 11000 步得出)。
> **MPM ↔ 剛體雙向**(`MpmSolver.rigids` / `MpmRigid`,`physics/mpm_rigid.mojo` `MpmRigidCoupler` / `mpm_rigid_step`):剛體在 MPM 裡是移動障礙(物體座標的 `Sdf3`,
> 每步由場景取位姿與速度);格點在物體內時,相對物體的速度去掉法向流入、切向 Coulomb;粒子進入物體時推回表面。兩者改變的動量加總為物體的力 / 力矩
> 交給場景,再以同一 dt 積分。只在 `step_ext` 走(兩行掛鉤),無剛體時 `test_mpm` / `test_mpm_sand` golden 逐位不變。`tests/test_mpm_rigid.mojo` 6/6:
> 0.15 m、3.375 kg 箱落在彈性塊上,1 s 後速度 8e-5 m/s、格點力 / 重量 1.001、箱內無粒子;箱底比旁邊塊頂高 4.2 cm(0.84 格:接觸在格點上判定,
> 物體停在材料上方約一格,未修);零重力下 1 kg 球以 1 m/s 撞 16.6 kg 自由塊,材料 + 物體動量變化 1.4e-6(相對),球反彈 −0.15 m/s。
> **PBF ↔ 剛體:試做後未交付**(量測記在此,程式碼未提交)。做法:物體取樣進密度約束,取樣點對流體的推力只沿其外法向(|∇W·n|),推了多少逐對還給物體
> (動量精確)。量到:流體下的靜止板承擔流體重量至 0.1 %;但浸沒的靜止箱讀到 2.05 / 1.56 / 1.25 倍排開重量(10 / 20 / 30 cm,6 cm 間距、10 cm 核:
> 每個面讀到的是一個核半徑內的流體,底面讀得比自己深、頂面比自己淺,差約 ρgH);改用 Σλ 當壓力做表面積分則在板上高估 2 倍(6 次 Jacobi 的 λ
> 不是壓力);以 Adami 外插修正 λ 反而更糟(2.77 / 1.69 / 1.29)。致命的是輕物體:密度 300 的箱被推出水槽(−11 m、15 m/s)——流體位置修正以為邊界不動,
> 把 m_p Δx / dt² 當顯式力給輕物體會放大。需要的是統一解算(Macklin 2014:剛體粒子以反質量權重參與約束、形狀匹配),另列待辦。
> **耦合快照**(`physics/fsi.mojo` `lbm_write` / `lbm_read`、`lbm_continuum_write` / `_read`、`sphere_port_write` / `_read`,走 `StateWriter` / `StateReader`):
> 格點的分布、旗標、移動壁面欄位與移動球,連續體的 carry / 步數,埠量到的壁面阻力與模式;尺寸、黏度等屬建構。`tests/test_fsi_snapshot.mojo` 3/3:
> 密度比 0.5、隱式阻力的耦合球 0.1 s 時連同場景(`write_state`)存下,以相同方式建好的場景 / 格點 / 埠還原後再跑 100 步,物體與每個分布逐位相同;
> 球心在格外(x 24.9 mm,週期)時存的也一樣;格點尺寸或移動球數不同時 raise。
> **柔性體 / 布料在靜水中**(`physics/soft_water.mojo` `soft_water` / `cloth_water`,對 `WaterVolume` 的解析水面,單向):`SoftBody` 每粒子代表 volume / n 的水平薄片
> (厚 a = (volume/n)^(1/3)),浸沒比例給浮力與線性阻尼;`MeshCloth` 每個水下三角形給浮力(ρgA·厚度)與法向壓力阻力 ½ρ·cd·A·v_n²,以法向速度隱式解
> (含布料自己的步接著加上的重力:先前在重力之前解,輕布以 3 倍終端速度下沉,1/60 s 的 g dt = 0.16 m/s 大於 0.13 m/s),動量按三角形質量的三分之一分給角點,
> 所有三角形讀同一份起始速度(依序讀被前面三角形改過的速度時,內部頂點只拿到 60 % 的阻力、布會皺)。`tests/test_soft_water.mojo` 6/6:單粒子(5 cm 格)
> 密度 500 / 250 停在 −3.4 / +2.2 mm 對阿基米德 0 / 12.5 mm(差來自每幀一次的浮力對軟體四個子步的重力);0.2 m 軟立方體密度 500 浮在水面、轉成角朝上
> (垂直範圍 0.345 ≈ 0.2√3,真實的這種密度立方體也斜浮);1 kg/m² 水平布 2 s 後 0.1272 m/s 對終端 0.1278(0.5 %),0.5 mm 厚 0.0901 對 0.0904,
> 平整度 2e-6 m;2 mm 厚的布上浮。試過的軟板(9×3×9)以軟體 4×4 XPBD 撐不住 0.4 m 寬而折起,不作為測試。
> **仍未做**:Aitken 迭代(隱式阻力已涵蓋本格點法,不另做)、PBF 雙向(見上)、柔性體與 SPH / LBM 的雙向耦合(目前只對解析水面)、MPM 接觸的一格間隙、SPH / MPM 耦合的快照。

> **現況**:流體與剛體**幾乎沒有耦合**。Phase 14 起因即記載 PBF / SPH 零固體耦合
> (ROADMAP「Phase 14」);之後只補了 SPH 的 Akinci 邊界粒子 `BoundaryParticles`
> (`physics/sph.mojo:42`),且**只有地板取樣**(`box_floor_boundary` `:76`),牆面仍是夾制
> (`physics/pbf.mojo:211-224`);邊界粒子與流體粒子的鄰居是暴力雙迴圈(`sph.mojo:110`、`:149`,
> ROADMAP 17.42 待辦自列 ROADMAP §17.42)。LBM 的固體只在**建場時**設定
> (`set_solid_box` / `set_solid_sphere` `fluid/lbm.mojo:185`、`:197`);`grep -iE
> "moving.?(wall|solid|boundary)|wall_vel|moving_bounce"` 於全部引擎套件 **零命中**——沒有移動壁面。
> 力的方向是**單向**:動量交換(`stream()` 內累加力 `fluid/lbm.mojo:369`)與控制面通量(`momentum_flux_force` `:242`)兩條測力路徑 → 車體阻力
> (`gameplay/vehicle_tunnel.mojo:1-20`);LBM 速度場 → `WindGrid` 的接線列為待辦(ROADMAP §17.27)。
> 浮力是解析式:`WaterVolume` 為平面水位 AABB(`physics/fields.mojo:181`)、`apply_buoyancy`(`:235`)。
> `grep "FemBody|MpmSolver|PbfFluid|\bLbm\b"` 於 `physics/solver6.mojo`、`physics/body_set.mojo`、
> `collision/`、`gameplay/runtime.mojo` 零命中:PBF / SPH / MPM / LBM 都與 `ContactScene6` 無介面。
> 軟體 – 剛體雙向耦合存在,但只對晶格 `SoftBody`(`physics/soft_couple.mojo:46`),**不是流體**。
> 已交付且**不重複主張**:17.28 解析浮力(球冠 / 盒取樣 vs 閉式 seam)、17.42(d) SPH 邊界粒子(地板)、
> LBM 動量交換 / 控制面測力兩條路徑(17.42 c)、`soft_couple` 的雙向衝量模式。
> **缺口**:
> - **粒子流體 ↔ 剛體雙向**:剛體表面取樣為邊界粒子(沿用 `BoundaryParticles.psi`),每步隨剛體位姿更新,
>   流體壓力反作用力與力矩以衝量回饋 `ContactScene6` 剛體;浮力自然湧現。(例:木箱落入水槽,吃水深度
>   由粒子解析而非 `WaterVolume` 公式)
> - **PBF 雙向**:剛體粒子參與密度約束(Macklin 2014 統一粒子)。
> - **LBM ↔ 移動剛體**:移動壁面 bounce-back(Ladd 1994)或浸沒邊界法;壁面速度項;力 / 力矩回饋剛體。
>   (例:球在 LBM 管道中被流體帶動,終端速度對 Stokes 解)
> - **MPM ↔ 剛體**:格點層級耦合(沙堆承載車輛)。
> - **強耦合穩定性**:輕物體的 added-mass 不穩定——分區耦合需迭代 / 鬆弛(Aitken)。(例:質量比 ρ_body/ρ_fluid → 1)
>   **本條擁有 added-mass 強耦合迭代**;17.61 的 `Coupler` 把它當成一個耦合方案變體取用,不另做。
> - **柔性體 ↔ 流體**:水中的布料(17.56)、`SoftBody` 浮力(今日 `apply_buoyancy` 只管剛體)。
> **對照組**:PhysX 5 PBD 粒子 – 剛體耦合、Houdini FLIP + RBD、Akinci 等 2012(SPH 剛體耦合)、Ladd 1994
> (LBM 移動粒子)、Peskin 浸沒邊界、Macklin 等 2014(統一粒子物理)、waLBerla(LBM 移動障礙)。
> **優勢區**:LBM 的移動壁面是**局部運算**、無需網格重建;**added-mass 區**(中性浮力、輕物體)是強耦合的理論
> 優勢區也是最難的測點,依優勢區規則必須測;解析浮力(17.28)與粒子解析浮力的吃水深度差是現成的量測軸。
> **規模軸**:流體粒子 / 格數 × 剛體數 × 質量比 ρ_body/ρ_fluid;耦合子步比;邊界粒子鄰居搜尋由暴力改格網的交叉點。
> **seam?**:是 —— 「浮力 / 流體力估計器」變體:解析(17.28)/ SPH 邊界粒子 / LBM 動量交換,在**靜止漂浮**這個
> 共同可觀察量上 parity(吃水深度 vs 阿基米德 ρ_box/ρ_fluid·h,容差隨解析度收斂);bench:每剛體每步成本。
> **交付**:普通(漂浮箱吃水 vs 阿基米德;沉底重球)/ 整合(落入水槽的箱子在 `ContactScene6` 內與其他剛體
> 碰撞、經 17.55 登記、快照往返逐位相同;LBM 管道中的球)/ 極端(ρ 比 = 1 中性浮力、物體瞬移入流體、
> 物體完全在流體域外、零流體粒子、高速物體單步位移 > 邊界粒子間距而穿透(需 CCD / 子步)、剛體全埋入固體格)。
> **相依**:17.55(前提)、17.28、17.42、17.60、17.62、17.19(solver 硬化的穿透判準)。
> **邊界**:水面 / 海洋與波浪屬 17.60;多物理的通用耦合排程與守恆診斷屬 17.61(本條只做流 – 剛的具體耦合);
> 流體渲染 / 泡沫著色屬宿主;載具浮筒 / 船體屬 17.74。

#### 17.60 水面 / 網格流體 — Wave C
> **進度註(2026-10-13)**:`WaterSurface` seam 先行。`physics/water.mojo`:`WaterSurface` trait(`height(x, z, t)`、`velocity`)與
> `FlatWater` / `GerstnerWater`(深水色散 ω² = g k,陡度 Q 的水平位移以 4 次定點迭代反解,t 為閉式參數、免步進)/ `ShallowWaterGrid`
> (線性淺水波動方程、蛙跳 + 阻尼、反射壁、`disturb`、CFL 超限 raise);`float_body[W]` 以 n³ 取樣點對任一水面施浮力(含力矩)與相對水速阻力。
> 量測(`tests/test_water.mojo` 10/10):振幅 0 的 Gerstner 與平面逐位相同;Q = 0 單波對 A cos(kx − ωt) 誤差 0;Q = 0.8 反解誤差 8.9e-7、波峰 0.5;
> 密度 500 的 2×1×2 箱在平水上中心 y = 0.062(取樣層 1/8 容許 ±0.0625);40 m、A = 0.5 的湧浪上起伏 1.08 m、週期 5.067 s(波 5.064 s);
> 1 m 深格網漣漪到 5 m 外 1.55 s(5/√(gH) = 1.60 s);阻尼 0.5/s 時 400 步後 Σeta² 剩 2 %。`bench_water`:Gerstner 4 波查詢 300 ns、格網取樣 7.9 ns、
> 格網每格步 8.6 ns、`float_body` 4³ 取樣在 4 波海面上 22.5 µs / 物體。
> **進度註(2026-10-17,FFT 海洋)**:`numerics/fft.mojo`(基 2 迭代複數 FFT、`fft2`,非 2 的冪 raise)與 `physics/water.mojo` `FftOcean`(`WaterSurface` 的第四個變體):
> n×n 波向量 k = 2π m / size 各帶複振幅 h0,η = level + Re Σ h0 e^{i(k·x − ωt)},ω² = g|k|;`phillips(seed, A, wind)` 以 SplitMix64 + Box–Muller 填 Phillips 頻譜
> (同種子逐位相同、任意 t 免步進);`update(t)` 一次反 2-D FFT 得整格,`height` 在該 t 用雙線性取格、其他 t 直接加總(精確,O(n²))。
> `tests/test_fft_ocean.mojo` 8/8:FFT 對直接 DFT 7.3e-5(峰值 8.4)、往返 5.8e-7;單一模態對陡度 0 的 Gerstner 200 個隨機點 / 時間最差 2.3e-6 m(seam parity),
> 垂直速度差 8e-4 m/s(Gerstner 以數值微分);64²、200 m、風 10 m/s、A = 3e-6 的海有效波高 4σ = 2.26 m,格點上 FFT 對加總 3.7e-6 m,格點間雙線性最差 0.147 m
> (最大 |η| 1.56 m 的 9 %);2×1×2 箱(密度 500)以 `float_body` 浮在上面 5–10 s 起伏 0.66 m;無模態時 = 水位,patch 週期重複。
> `bench_water`:update 32² / 64² / 128² = 0.06 / 0.26 / 1.18 ms,已更新 t 的格點查詢 33 ns,其他 t 的直接加總 67 µs。
> **`WaterVolume` 走 seam**:`apply_buoyancy_surface[W: WaterSurface]`(`physics/water.mojo`):水體保留範圍、密度與阻尼,水位改由水面查詢——箱的每個取樣格
> 對其所在位置的水面比較,球用球心上方的水面。`tests/test_water_seam.mojo` 3/3:箱與球 3 s 內與 `apply_buoyancy`(`FlatWater` 在水體頂)逐位相同;
> 1 m 箱(密度 500)在 40 m、A = 0.5 的 Gerstner 湧浪上起伏 1.18(2A = 1;自身起伏週期約 1.4 s 對波 5.06 s 的受迫放大,無阻尼為 1.085),
> 在同一波的 FFT 單模態上起伏完全相同。
> **LBM 任意方向體力**:`Lbm.force_y` / `force_z`(x 仍是 `collide` 內的速度平移),以碰撞後的源項 f_i += 3 w_i (c_i·F) 加入(每格每步正好 F 的動量、
> 不加質量);放進 `collide` 的分支會改變它的編譯結果、讓 `test_vehicle_aero` 的阻力係數第 7 位數變動,所以獨立一趟,現有 LBM golden 全部逐位不變。
> GPU 版遇到 y / z 體力 raise(只在 CPU)。`tests/test_lbm_body_force.mojo` 4/4:沿 z、沿 y 驅動的 Poiseuille 通道對解析拋物線 0.25 % / 0.27 %
> (沿 x 0.17 %),與 x 驅動的剖面差 0.08 % / 0.10 % 峰值;開放週期箱沿 z 200 步平均速度對 200 F/ρ 差 8e-4。
> **MAC 格網流體與 Taylor–Green parity**:`physics/mac_fluid.mojo` `MacFluid2`(2-D 週期交錯網格:半拉格朗日 RK2 回溯、顯式黏滯(νdt/dx² > 1/4 raise)、
> 以 `numerics.pcg` 走無矩陣 5 點 −∇² 做壓力投影,週期奇異性以去掉右端平均處理;放在 `physics` 因 `fluid` 與 `numerics` 同層不得互引)。
> `tests/test_taylor_green.mojo` 5/5:32² MAC(ν 0.05、U 0.01、dt 0.05,t = 10)衰減率 / 2νk² = 1.0048,每次投影後散度 ≤ 4.7e-9(U/dx 的 1e-7);
> 32×32×1 D3Q19 同一渦 400 步 1.0041;兩者 0.07 % 內一致。`bench_grid_fluid`:MAC 32² / 64² 每格步 2.0 / 4.8 µs(PCG 43 / 87 次),LBM 0.35 µs。
> **煙霧**:`Smoke2`(`physics/mac_fluid.mojo`):格心溫度隨流以半拉格朗日平流,Boussinesq 浮力 fy = b (T − 平均 T)(減平均:週期盒整體不加速),
> 渦度限制 ε dx (N × ω)(Fedkiw 2001)。`tests/test_smoke.mojo` 4/4:64² 盒熱團 2 s 內溫度質心 0.20 → 0.62 m;浮力 0 時速度維持 0;
> 第一步後淨垂直動量為 Σ|v| 的 2.3e-4(浮力本身淨零);2 s 後漂移 3 %(半拉格朗日平流不守恆動量,記錄不修);ε = 2 對 0:動能 1.15 倍、
> 擬渦度(enstrophy)1.38 倍;溫度保持在初值範圍內。
> **FFT 海洋的 choppy 與法線**:`FftOcean.choppy`(λ)、`displaced`、`normal`:水平位移 −λ Σ k̂ Im(h0 e^{ia})(Tessendorf 的 D),單一模態正好是 Q = λ 的 Gerstner;
> choppy 時 `height` 以 4 次定點迭代反解(同 `GerstnerWater`,精確加總)。`tests/test_fft_choppy.mojo` 4/4:單模態 λ 0.6 對 Gerstner Q 0.6 最差 1.7e-6 m;
> 一個波長中高於水位的比例 0.4725 對擺線 1/2 − QkA/π = 0.4712;Phillips 海的解析法線對高度有限差分 1.0e-4、單位長誤差 1.2e-7;無模態時法線朝上。
> **非線性淺水**:`ShallowWaterFV`(`WaterSurface` 的第五個變體):Saint-Venant 有限體積,h 與 (hu, hv),一階 Rusanov 通量、反射壁、乾格(h ≤ 1e-6 速度歸零)、
> CFL 超限 raise。`tests/test_shallow_fv.mojo` 5/5:Stoker 濕潰壩(1 / 0.5 m,20 s)平台水深 0.7260 對解析 0.7269、流速 0.9195 對 0.9229、湧浪位置差 0.13 格,
> 體積守恆 2e-7;Ritter 乾潰壩 10 s 時 1/4 水深點差 2.72 m(1 m 格)→ 1.66 m(0.5 m 格),一階收斂;1 mm 前緣 246.5 m 對解析 259.6(一階格式在乾前緣的已知落後,記錄);
> 靜水保持逐位不動。
> **粒子 → 表面**:`geometry/isosurface.mojo`:`ScalarGrid`、`marching_tetrahedra(grid, iso)`(每格沿主對角切 6 個四面體,16 種情形、無查表,邊上線性內插,
> 以邊鍵焊接頂點;相鄰格切法一致,封閉等值面輸出封閉、向外繞向的網格)、`splat_particles`(poly6 核疊加到格點)、`TriMesh`(面積、體積、開放邊數)。
> `tests/test_isosurface.mojo` 4/4:41³ 格上 R = 0.4 的距離場零等值面 28 560 個三角形、開放邊 0,面積 2.0086 對 4πR² = 2.0106、體積 0.26756 對 0.26808;
> 1791 個粒子的球(半徑 0.3)以 R 0.1 疊加、取內部值一半切出 16 104 個三角形、封閉,球形度 A³/(36πV²) = 1.021;全內 / 全外無三角形。
> **淺水底床與摩擦**:`ShallowWaterFV.set_bed` / `manning`:有底床或摩擦時走 `_step_bed`(Audusse 2004 靜水重建:面上以較高底床重建水深、兩側補 g/2(h² − h*²)),
> Manning 摩擦隱式;原平底路徑不變(`test_shallow_fv` golden 逐位相同)。`tests/test_shallow_bed.mojo` 4/4:0.5 m 高斯凸起上的靜水 2 s 後水面偏差 2.4e-7 m、
> 速度 6.8e-7 m/s,同湖用樸素坡度源項則攪出 0.18 m/s;Manning n 0.03、1 m 深 2 m/s 均勻流 5 s 後 1.83790 對解析 1.83790;
> 高出水面的島保持乾、湖靜止、體積差 3e-7。
> **FLIP 自由表面水(有牆)**:`physics/flip.mojo` `FlipWater2`(Zhu–Bridson 2005:標記粒子帶水、2-D MAC 只做壓力;四面牆無通量、空氣格 p = 0、
> 只在水格解 `numerics.pcg`,FLIP 0.95 / PIC 0.05)。`tests/test_flip.mojo` 3/3:1 m 箱 0.3 m 靜水 1 s 後粒子最大速度 1.7e-7 m/s,各水格 p/g 對
> h + dx/2 − y 差 1.2e-7(自由表面落在第一個空氣格中心,一階);0.25 × 0.5 m 水柱潰壩,前緣始終在 Ritter 2√(gh0) 之後,0.3–0.5 s 速度 1.48√(gh0),
> 粒子全在箱內、壓力解全收斂。
> **LBM TRT(MRT 族)**:`Lbm.trt_lambda` / `collide_trt`(Ginzburg 2008,對稱部以 1/τ、反對稱部以 1/τ⁻ 鬆弛,(τ−½)(τ⁻−½) = Λ;BGK 的 `collide` 不動,
> BGK golden 全部逐位不變;GPU 遇 TRT raise)。量到:速度平移體力在 TRT 下須以 τ⁻F/ρ 平移(以 τF/ρ 時 τ 0.8 的 Poiseuille 誤差 29 %)。
> `tests/test_lbm_trt.mojo` 3/3:11 點通道 τ 0.8 / 2.0 / 3.5 的 Poiseuille 誤差 BGK 1.2 % / 11 % / 53 %,TRT Λ = 3/16 為 0.56 % / 2.5 % / 5.1 %
> (仍隨 τ 增:Λ = 3/16 的精確壁面位置假設二階體力項,這裡是速度平移);剪切波黏度 0.030157 對 0.03;Λ = (τ−½)² 與 BGK 差 7e-7。
> **未做**:完整 19 矩 MRT / cumulant、TRT 的 Guo 二階體力、MAC 的 level-set 自由表面、APIC、3-D MAC / FLIP、LBM MRT、各向異性核與泡沫 / 水花次級粒子、choppy 的 FFT 格點路徑。

> **現況**:流體只有三種,**沒有自由表面,也沒有網格投影法**。LBM(D3Q19 BGK,`fluid/lbm.mojo:48`)只有
> 週期 / 風洞兩種邊界(`BC_PERIODIC`、`BC_TUNNEL` `:42-43`),**體力只有 x 分量**(`force_x` `:69`、
> `:314-315`)——沒有重力方向的體力,所以無法做重力驅動的水;`d3q19.mojo:5-8` 自述「無全域壓力求解、無
> Poisson」。粒子流體 PBF / SPH 只有盒狀容器夾制(`physics/pbf.mojo:84-85`、`:211-224`),核半徑是全域
> comptime 常數(`:37`)。`grep -iE "free.?surface|level.?set|\bvof\b|volume.of.fluid|ocean|gerstner|fft\b|shallow.?water"`
> 於全部引擎套件只命中 `physics/pbf.mojo:16` 一句註解;`grep -iE "marching|isosurface|surfacing"` **零**;
> `grep -iE "foam|spray|whitewater"` **零**;`grep -iE "mrt|cumulant|trt"` 於 `fluid/` **零**(只有 BGK,`d3q19.mojo:12-14`
> 提到 D3Q27 的取捨)。遊戲用水是平面 AABB 水體(`physics/fields.mojo:181`),17.30 地形 heightfield 是固體
> 不是水。數值底座已在:`numerics` 有 `pcg`(`numerics/cg.mojo:73`)、`CsrMatrix`(`numerics/sparse.mojo:54`)、
> `poisson_1d`(`:163`),Phase 15 建議順序也明記「若日後要做投影法 Navier-Stokes,15.1 是前提」
> (ROADMAP「Phase 15 建議順序」)。
> **架構陷阱(實查)**:`fluid` 與 `numerics` 同為第 2 層、互引禁止(`scripts/arch_layers.toml:4-13`、
> `docs/ARCHITECTURE.md:21`,且該表列 `fluid` 不得擁有粒子流體),所以**網格投影法流體不能放在 `fluid`
> 裡用 `numerics.pcg`**——須放 `physics`(第 4 層)或調整層級,並同一 commit 修改 `arch_layers.toml` 與
> `docs/ARCHITECTURE.md` §1。
> 已交付且**不重複主張**:LBM 核心 / 障礙 / 進出口 / 測力 / LES / 驗證套件(14.1–14.6)、17.42 的 GPU 與插值
> bounce-back、PBF / SPH 與其對照(自由表面、潰壩正是它們的優勢區:ROADMAP「Phase 14」)。
> **缺口**:
> - **`WaterSurface` 水面查詢**:`height(x, z, t)` / 法線 / 流速,供浮力(接 `WaterVolume` 的平面水位位置)與
>   載具使用;變體 = 平面(現況)/ Gerstner / FFT 海洋頻譜(Tessendorf 2001)/ 淺水波方程格網(可互動漣漪)。
>   (例:船身多點取樣水面高度,浪高 1 m 時船隨浪起伏)
> - **歐拉式不可壓縮格網流體**:MAC 網格壓力投影(Stable Fluids)+ PCG、FLIP / APIC-FLIP 粒子 – 格網混合;
>   窄帶 level set 自由表面。(例:水槽潰壩,與 PBF 同場景對比)
> - **氣體 / 煙霧**:溫度驅動浮力、渦度限制(vorticity confinement)(Fedkiw 2001)。(`grep "vorticity|temperature|smoke"`
>   零命中)
> - **LBM 擴充**:任意方向體力、壓力出口 / 滑移邊界(移動壁面屬 17.59)、MRT / cumulant 碰撞(BGK 的變體)、自由表面
>   質量追蹤(Körner 2005)。
> - **粒子 → 表面**:粒子場 → 等值面 / SDF(各向異性核、marching cubes)作為輸出(供宿主渲染),及泡沫 / 水花
>   次級粒子(Ihmsen 2012)。
> **對照組**:Houdini FLIP + Ocean Toolkit、Blender Mantaflow / Ocean 修改器、Crest Ocean(Unity)、UE Water 系統、
> NVIDIA Flow(格網煙霧)、Bridson《Fluid Simulation for Computer Graphics》、Stam 1999、Zhu–Bridson 2005 FLIP、
> Ihmsen 2012。
> **優勢區**:海洋頻譜是**解析式、種子決定論、可在任意 t 直接取值**——不需步進,對 rollback(17.16)與回放
> (17.39)友善;大水域(10⁶ m²)用 heightfield 遠比 3D 網格便宜(規模軸即可量出交叉點)。LBM 的局部性在 GPU 上
> 已量到 55.6 MLUPS(17.42 進度,ROADMAP §17.42),是 3D 自由表面的 GPU 優勢區。
> **規模軸**:格數(10⁴ → 10⁸)/ 粒子數 × CFL / Re;海洋頻譜解析度 N² × 每體水面查詢數;水域面積。
> **seam?**:是 —— ① `WaterSurface` 變體:振幅 0 時與平面水位逐位相同;單一正弦分量時 Gerstner 與 FFT 單頻
> 解析式一致;② 格網流體變體(MAC-PCG / LBM / 現有 PBF)在 **Taylor–Green 渦衰減**這個共同可觀察量上對解析衰減率
> parity(LBM 已有剪切波衰減驗證 `test_lbm_validation`,本條擴成跨求解器);bench:每格 / 粒子每步 ns、MLUPS。
> **交付**:普通(平靜水面 = 平面;Taylor–Green 衰減率對解析;潰壩前緣位置對 Martin & Moyce 1952 實驗資料)/ 整合(浮力用 `WaterSurface`
> 驅動 `ContactScene6` 中的剛體;與 17.59 剛體耦合;經 17.55 登記)/ 極端(零振幅、單格網格、CFL 超限
> 的計數與隔離、整個域是固體、水面查詢在域外、浪高 > 水深、粒子數 0)。
> **相依**:17.55、17.28、15.1、17.42、17.59、17.63(VDB 輸出)、17.62。
> **邊界**:水的渲染(折射 / 焦散 / 泡沫著色)屬宿主;船 / 浮筒動力學屬 17.74;天氣 / 大氣屬宿主;固體耦合的
> 具體機制屬 17.59。

#### 17.61 多物理 — Wave C
> **進度註(2026-10-13)**:熱場先行。`physics/thermal.mojo`:`HeatGrid`(7 點有限差分、外表面絕熱、`fix` Dirichlet、dt ≤ dx²/(6α) 否則 raise)、
> `HeatTets`(`FemBody` 四面體上的線性元素、集中熱容、靜止形梯度的傳導矩陣、建構時算 Gershgorin 步長上限)、`expand`(依四節點均溫縮放各四面體的靜止形與體積);
> 溫度 ≤ 0 K 或非有限值在設定時 raise。量測(`tests/test_thermal.mojo` 7/7):α = 1e-5、端點 400 K、10 s 後:格網對 erf 解 0.014 K、300 個四面體 0.025 K、兩者互差 0.016 K;
> 自由棒加熱 100 K、α_L = 1.2e-3:伸長 0.0119999 m vs 0.012 m;絕熱域總熱量漂移 1.4e-7(格網)/ 1.2e-6(四面體,f32);單一四面體有界。
> `bench_thermal`(1 mm、60×4×4 mm):格網 14 ns / 節點·步(dt 上限 16.7 ms)、四面體 181 ns(上限 8.3 ms)。
> **粒子熱傳導**:`HeatParticles`(Brookshaw 1985,三次樣條核;每粒子把 Σ vol r |W′| 正規化為 3,使晶格上的離散和重現拉普拉斯,成對用兩者因子平均以保反對稱;
> 鄰居以雜湊格建一次,27 格去重;Gershgorin 步長上限)。量到的兩個錯:雜湊格座標以 f32 的 x + 1e6 取整(ulp 1/16)與 27 格雜湊碰撞重複計入,
> 絕熱塊熱量漏 0.8 %(修後 3.8e-8);未正規化時 1 mm 棒偏 erf 3.7 K。`tests/test_thermal_particles.mojo` 3/3:60×11×11 粒子棒 10 s 後中心線對 erf 1.24 K、
> 對格網 1.23 K(核延伸 2.4 格對格網的 1 格,截斷誤差較大;格網本身 0.014 K);邊緣附近粒子被正規化放大,7 格寬時中心線偏熱 2 K,故用 11 格寬。
> **`tau(T)` 黏度**:`Lbm.set_viscosity_field(nu)` 給每格 ν(長度不符或 ν ≤ 0 raise,空表還原),`collide_var` 以各格 τ 做 BGK,體力位移也用該格 τ;`collide` / `collide_trt` 函式體不動(LBM 各測試 golden 不變)。GPU 晶格遇非空 `tau_cell` raise。`tests/test_lbm_tau_field.mojo` 3/3:均勻場與原晶格差 0.0;兩層通道(下 ν 0.05 / 上 0.2,體力驅動)速度峰值 0.0010048 位於 y = 11(偏向稀的一層,中線 15),對兩層 Poiseuille 解析解最大誤差為峰值的 2.6 %。T → ν 的換算(例:Arrhenius)由呼叫端從 `HeatGrid` 取值後給入。
> **`Coupler` 排程**:`physics/coupler.mojo`。`CoupledPart` trait(`advance` / `send` / `recv` / `impulse` / `save` / `restore`),`Coupler[A, B]` 讓 A 走 dt、B 走 `ratio` 個子步;方案 `EXPLICIT`(B 各子步用 A 的步末狀態)、`INTERP`(線性插值於 (k+1)/ratio,ratio 1 時與 `EXPLICIT` 逐位元相同)、`ITERATED`(自檢查點重做,給 A 的是 B 起末狀態的中點,Aitken 鬆弛)。每步記錄介面衝量和的範數 `imbalance` / `max_imbalance`;非有限或長度不符的介面資料不轉送,接收方沿用上一筆有限值,記 `COUPLING_REJECTED`(新 counter 24)。`tests/test_coupler.mojo` 10/10(兩質點經彈簧分割):最差 |E/E0 − 1|(dt 4 ms、2 s)kc 400:子步比 2 / 4 / 8 / 16 顯式 1.04 / 0.48 / 0.27 / 0.23,插值 0.29 / 0.26 / 0.21 / 0.14;kc 40:顯式 0.157 / 0.121 / 0.104 / 0.096,插值 0.109 / 0.056 / 0.036 / 0.029。`ITERATED` 每步 ≤ 3 次,但在彈簧耦合上能量誤差高於顯式(kc 400、比 2:3.42;給 A 步末狀態時 19.8,改中點後如上),它的用途是 17.59 的 added-mass 強耦合,不是能量;三方案 B 位置互差 dt 2 / 1 / 0.5 ms:1.84e-3 / 9.2e-4 / 4.6e-4 m(一階收斂到彼此);介面衝量不平衡每步最大 dt 4 ms 0.049、2 ms 0.012 N·s;A 中途 NaN:199 次拒收,B 持續;子步比 1000:1 能量誤差 3.6 %。`bench_coupler`:每耦合步 0.5 µs(顯式)/ 0.67 µs(插值,比 4)/ 2.2 µs(迭代,比 4),同系統單迴圈 42 ns,差額是介面 `List` 配置,對真實求解器(ms 級)可忽略。Mojo 1.1 編譯器在測試中「從外部寫入泛型結構欄位為 NaN 後再讀」時崩潰,改在 part 內部注入失敗。尚未把現有逐對耦合(布料 – 風、剛體 – 水)改寫成 `CoupledPart`。
> **加熱板上的煙柱**(第一個真實求解器對):`physics/thermal_smoke.mojo` 的 `HeatPlate`(包 `HeatGrid`)與 `SmokeGas`(包 `Smoke2`)兩個 `CoupledPart`,介面為板頂列與氣體列之間的對流 q = h dx ΔT dt,各自以對方送來的溫度計入自己的格。`tests/test_thermal_smoke.mojo` 7/7:64² 氣體、16 × 3 板(底列 600 K)、h 50、板 0.1 s / 氣體 10 子步(`INTERP`):3 s 後氣體多餘熱的質心 0.14 m(1.5 s)→ 0.40 m,板上方平均上升 0.53 m/s;板放出 9618.6、氣體收到 9595.1 J/m,分割交換的累積不平衡 0.24 %(顯式 0.247 %:板熱容大,板頂溫度幾乎不變,插值幾乎無差);氣體內多餘熱 / 收到的熱 0.94(半拉格朗日平流不守恆);浮力 0 時速度恆為 0。過程中找到 `MacFluid2.project` 的錯:週期 Laplacian 奇異,右手側均值以 f32 對 n² 格求和後扣除,殘留均值高於 CG 容差,CG 永不收斂、跑滿 4n² 次並把常數堆進 p,f32 失去壓力差,加熱列下的 `Smoke2` 0.3 s 內速度到 1e11 m/s;改以 f64 求均值後每步收斂。`test_smoke` / `test_taylor_green` golden 第 6–7 位數變動(衰減比 1.0048347 → 1.0048348)。
> **相變(MPM)**:`physics/mpm_melt.mojo` 的 `MpmMelt` 疊在 `MpmSolver` 上:每粒子比焓 H(f64),焓法換算 T 與熔化分率 phi(H ≤ c Tm 固、平台上 T = Tm、≥ c Tm + L 液);每步 `step_ext` → `HeatParticles` 依新位置重建鄰居並傳導(ΔT 換成 c ΔT 的焓,平台上也守恆)→ 熱地板 h (T_floor − T) dx² dt → 由 H 求 T / phi;全熔粒子 F ← J^(1/3) I(保留體積抗壓、忘掉剪切記憶),再凝固時以該等向 F 為新靜止態。`tests/test_mpm_melt.mojo` 8/8(8×6×8 粒子、2.5 cm、蠟類參數,α 放大到 1e-3):1.2 s 後固體高 0.121 m(初 0.125)、液體 0.042 m 且寬 0.175 → 1.35 m、600 K 地板加熱者熔 51 %、高 0.101 m、寬 0.29 m;焓變化 vs 地板熱相對誤差 3.7e-7。半熔(0 < phi < 1)粒子仍當固體;剪切模數不隨 phi 漸變(`MpmSolver` 的 mu 是全域的)。
> **布料 ↔ 氣流雙向**:`physics/cloth_air.mojo` 的 `ClothAir` 擁有一個 `Lbm`,把 `MeshCloth` 頂點當浸沒點:三線性取樣格子速度,法向拖曳 F = k A n (n·(u − v)) 沿 n 隱式積分(任意 k dt / m 不過衝;釘住的頂點不動但承受 k A n (n·u)),雙向時以相同三線性權重把 −J 以格子動量 J dt / (ρ dx⁴) 寫回 8 格(新 `Lbm.add_cell_force` / `_force_cells`,碰撞後的獨立 pass,f_i += 3 w_i (c_i·F),恰好加 F 動量、不加質量;LBM 各 golden 不變;GPU 晶格遇非空 `cell_force` raise)。`tests/test_cloth_air.mojo` 9/9(24³ 週期格、dx 2 cm、1 ms、格子黏度 0.05;0.2 m 方布 4 g、k 2):單向終端速度 0.485 vs m g / (k A) 0.490 m/s;雙向布料帶動空氣、0.3 s 後下落 0.725 m/s;空氣動量變化 −0.0085097 vs 給它的衝量 −0.0085096 N·s,兩衝量等值反向;單向時空氣動量變化恰為 0;釘住的布橫在 0.4 m/s 上升流中,0.2 s 後其上方 0.19 m/s、旁邊 0.41 m/s(尾流)。布 + 空氣動量比重量衝量少 2.8 %,無拖曳自由落體本身已少 1.4 %:XPBD 由 f32 位置差求速度的誤差,屬布料求解器。股線 ↔ 氣流與網格氣體(`Smoke2`)的雙向未做。
> **多相流(油水)**:`physics/multiphase.mojo` 的 `MultiphaseSph`(Solenthaler & Pajarola 2008 數密度式):δ_i = Σ W、ρ_i = m_i δ_i(只用自己的質量,介面不抹平)、p = B(ρ/ρ0 − 1) 截 0、成對壓力 (p_i/δ_i² + p_j/δ_j²)∇W 加對稱 Monaghan 人工黏性;每粒子自帶 ρ0 與 m = ρ0 / δ_ref(靜止晶格 p = 0)。牆:每個面加上牆外虛擬晶格的數密度(建構時依距離製表)並以粒子自身壓力經其梯度推回;沒有這項時 4 粒子深的盒子 0.2 s 內沿牆壓實 45 %、底部壓力只有靜水壓的 55 %。`tests/test_multiphase.mojo` 3/3(0.16 × 0.5 × 0.08 m 盒、2 cm、B 1.8e5、α 0.5、1 mm 擾動):油(800)放在水(1000)下方,3 s 後油的平均高度比水高 0.104 m(初 −0.160);等密度對照仍維持上下順序(−0.044)但也部分混合;底兩列平均壓力 2834 Pa vs 靜水壓 2528。量到的缺點:靜止等密度柱有假流動(α 0.1 時動能 0.15 J、均方根 0.28 m/s,會把兩層混掉;α 0.5 降到 ~0.01 J),來源未定位(初始無靜水壓的聲波、牆角兩面表疊加缺角落、位置截斷都可能);水平動量到 0.44 kg·m/s(牆只吸收法向)。泥沙懸浮(顆粒 – 流體)未做。
> **膨脹後的傳導矩陣**:`HeatTets.refresh(body)` 依 `expand` 後的靜止形重算元素傳導(vol ∇Ni·∇Nj)與 Gershgorin 步長;熱容(代表質量)不變。`tests/test_thermal_refresh.mojo` 6/6:4×2×2 梁 400 K、α_L 1.2e-3(s = 1.12):`expand` 單獨不動傳導;`refresh` 後傳導 / (s × 靜止) 最差相對誤差 1.2e-7,`max_dt` 0.833 → 0.744(比 1.1200003);膨脹後絕熱梁 200 步熱量漂移 3.1e-6;元素數不符 raise。
> **股線 ↔ 氣流雙向**:`physics/strand_air.mojo` 的 `StrandAir`(與 `ClothAir` 共用 `lattice_corners` / `lattice_velocity` / `lattice_momentum`):非根粒子以股線自身的 drag 率朝格子風速隱式拖曳,每粒子代表 `particle_mass`,−J 三線性寫回格子;股線自身步驟時暫關其 drag。`tests/test_strand_air.mojo` 7/7(24³ 格、0.4 m/s 風、6×6 股 × 8 粒子、20 /s、每粒 0.1 g):0.4 s 後梢端平均順風偏移 單向 0.120 m、雙向 0.055 m(空氣被減速);刷後下游 vx 0.068 vs 旁邊 0.386 m/s;空氣動量變化 −0.0104942 vs 衝量 −0.0104930;單向時均勻流動量只因 f32 捨入漂 7.5e-8(1.5e-6 相對)。
> **顆粒 – 流體(泥沙懸浮)**:`physics/sediment.mojo` 的 `Sediment`:點顆粒(d、ρp)在 `Lbm` 流體中,Stokes 拖曳率 β = 18 ρ ν / (ρp d²)、浮力修正重力,隱式積分(任意 β dt 下靜水終端速度恰為 g' / β),拖曳衝量反向寫回 8 格;只交換拖曳(重量 / 浮力的靜水部分留在格子自身壓力)。顆粒彼此不碰撞,密堆屬 17.58 MPM 砂。`tests/test_sediment.mojo` 8/8(24³、dx 2 mm、1 ms、ν 4e-5;石英 0.5 mm,β 1087 /s):靜水終端 5.6146 mm/s 與 Stokes 一致;上升流 2 倍終端速度時 0.5 s 上升 2.802 mm(預期 2.807),0.5 倍時下沉 1.401 mm(預期 1.404);400 顆雲雙向 0.3 s 下沉 3.46 mm vs 單向 1.68 mm;流體動量變化 −1.25895e-4 vs 衝量 −1.25891e-4。
> **整合**:`tests/test_coupler_snapshot.mojo` 3/3:加熱板 / 煙(32² 氣體)經 `Coupler` 跑 5 步後 `save()`、再 5 步記錄、`restore()` 後重跑 5 步,板溫、氣溫、速度逐位相同;`ITERATED` 於此對每步 ≤ 3 次收斂,1 s 後氣體多餘熱與 `INTERP` 相對差 3.0e-6(板熱容大、弱耦合)。
> **未做**:布料 + 風 + 剛體三方經 `Coupler`(`ClothAir` / `StrandAir` / `Sediment` 自帶排程,尚未改寫成 `CoupledPart`);`Coupler` 狀態未接 `state_io` 快照(各 part 的 save / restore 為記憶體內)。

> **現況**:耦合是**逐對手寫**,沒有耦合排程,也沒有除溫度以外的場種類(溫度也不存在)。已有的耦合:
> 剛體 ↔ 晶格軟體雙向(`physics/soft_couple.mojo:46`,有動量守恆量測 0.03%,ROADMAP 6.1);
> 繩 ↔ 剛體(粒子只跟隨掛點,剛體 → 繩粒子單向、不回饋 `physics/rope.mojo:7-12`;載重由
`Rope.tie` 加的距離關節經解算器承擔 `:96`);
> 風場 → 剛體(`apply_fields` `physics/fields.mojo:125`,`WindGrid` `:75` 可由 LBM 填入但**接線未做**,
> ROADMAP §17.27);LBM 動量交換 Cd → 載具阻力(`gameplay/vehicle_tunnel.mojo:1-20`)。
> 零命中:`grep -iE "temperature|thermal|combust"` 於全部引擎套件 **零**——無熱傳導、熱膨脹、相變、燃燒;
> 多相流(兩種流體)、顆粒 – 流體無;`grep "Coupler|coupling"` 作為排程抽象不存在(耦合只以各檔頭的敘述
> 存在)。各求解器的穩定步長不同(LBM 格子 dt = 1,`fluid/lbm.mojo:535`;PBF / SPH 自帶 CFL 敘述
> `physics/sph.mojo:14-19`;MPM 自帶 dx),跨求解器子步比管理無處可放(17.55 之前沒有契約)。
> 已交付且**不重複主張**:上列各對的現有耦合。
> **缺口**:
> - **`Coupler` 抽象**:宣告求解器對 (A, B, 方向, 方案),方案 = 顯式交錯 / 迭代(Aitken 鬆弛);交換場 = 力 / 衝量 /
>   速度 / 溫度;**跨介面守恆診斷**(動量 / 能量 / 質量)記為 counters。(例:布料 – 風 – 剛體三方,每步
>   回報介面動量不平衡)
> - **熱場**:熱傳導(四面體 / 格網 / 粒子三種離散)、熱膨脹(改 FEM 靜止長度)、相變(蠟融化:MPM)、
>   溫度相依黏度(LBM 的 `tau(T)`)、浮力驅動煙 / 火(接 17.60 的氣體)。(例:加熱的金屬板上方煙柱上升)
> - **布料 / 毛髮 ↔ 氣流雙向**:布料 / 股線對 LBM 流場的反作用(遮擋、尾流)回寫流體;單向「風 → 布料 / 股線」
>   的逐三角形空氣動力屬 17.56 / 17.57,本條不重列。
> - **多相流 / 顆粒 – 流體**:油水分層、泥沙懸浮。
> - **子步比與時間插值**:各求解器各用自己的穩定 dt,介面資料在子步間線性插值,避免能量注入。
> **對照組**:Genesis(`Coupler` 家族)、PhysX 5 統一粒子、Houdini DOP 多求解器、preCICE(分區耦合函式庫:
> Gauss–Seidel / Aitken / IQN-ILS)、COMSOL(單體式多物理)、Macklin 2014。
> **優勢區**:同行程、同二進位的零拷貝介面交換與**決定論單一快照**(preCICE 跨行程需映射與同步);
> 強耦合區(added-mass,輕物體)的 Aitken 迭代由 17.59 擁有並量測;本條只把它接成 `Coupler` 的一個方案變體。
> **規模軸**:耦合對數 × 介面自由度 × 耦合迭代數 × 子步比。
> **seam?**:是 —— 耦合排程(顯式交錯 / 子步插值 / 17.59 的迭代 Aitken):弱耦合極限三者一致,子步插值版在子步比 > 1
> 時能量注入低於無插值版(量出注入量 vs 子步比);熱傳導的三種離散在 1D 半無限介質的 erf 解析解上 parity。bench:每耦合每步成本、迭代數 vs 質量比。
> **交付**:普通(兩求解器單向耦合 = 單獨跑 + 外力;熱傳導對 erf 解)/ 整合(布料 + 風 + 剛體,或水 + 浮體 + 熱,
> 經 17.55 登記、快照往返逐位相同)/ 極端(零耦合對、循環耦合 A→B→A、一方 NaN 被隔離而另一方繼續、
> 子步比 1000:1、溫度輸入 ≤ 0 K / NaN / 1e9 K 被拒或隔離並記 counter、介面無重疊)。
> **相依**:17.55、17.56、17.58、17.59、17.60、(17.57)。
> **邊界**:各求解器內部機制屬各自條目(17.56–17.60);電磁 / 化學反應網路超出首批場種類(溫度、力、速度),以 `Coupler`
> 的可擴充場種類為接口,後續追加;宿主端的 FX 觸發邏輯屬宿主。

#### 17.62 GPU / 可微連續體 — Wave C(GPU / 可微)

> **現況**:**GPU**:連續體裡只有三塊在裝置上——布料 XPBD(`physics/gpu_cloth.mojo:35`、`:75`、`:139`、`:163` 四個 kernel)與
> VBD(`physics/vbd_cloth.mojo:114`、`:160`、`:228`),以及 LBM(`fluid/lbm_gpu.mojo:149`,BGK + 體力 + 風洞進出口,
> 不含 LES / 插值 bounce-back / 動量交換歸約,`:11-14`);剛體 GPU 求解器遇軟體直接拒絕
> (`physics/gpu_contact.mojo:347-348`)。`grep -E "max\.gpu|has_accelerator|DeviceContext"` 於 `fem.mojo`、
> `mpm.mojo`、`pbf.mojo`、`sph.mojo`、`softbody.mojo`、`soft_couple.mojo`、`rope.mojo` **零命中**。布料 GPU 沒有自碰撞
> (見 17.56)。LBM GPU 55.6 vs CPU 3.2 MLUPS 且「瓶頸未定位」(ROADMAP §17.42 進度與待辦)。裝置紀律:每個 process 單一 `DeviceContext`,由呼叫端傳入(`lbm_gpu.mojo:161`、17.17 單一擁有者)。
> **可微**:可微範圍是玩具與球 / 平面子集——`diffsim`(拋射體 + 平滑地面,`physics/diffsim.mojo:1-24`)、
> `diffrigid`(剛性 vs 罰函數接觸,`physics/diffrigid.mojo:1-30`)、`diffsolver.SphereWorld[F]`
> (`physics/diffsolver.mojo:22` 自述「**no soft bodies**」)、comptime 伴隨式(僅線性程式,`physics/adjoint.mojo:1-30`)。
> `grep -E "Field|RevReal|Dual"` 於 `fem.mojo`、`mpm.mojo`、`pbf.mojo`、`softbody.mojo`、`vbd_cloth.mojo`、`lbm.mojo`
> **零命中**——沒有任何連續體求解器是 `Field` 泛型;FEM 的隱式步 `cg(...)`(`fem.mojo:287`)也沒有線性解的伴隨。
> 已交付且**不重複主張**:17.17 剛體 GPU、17.18 / 17.20 可微 + 批次(可微子集)、15.3、GPU 布料 / VBD / LBM 與其 parity。
> **缺口**:
> - **GPU 連續體求解器**:MPM(P2G 散射需決定論方案:atomics 浮點加法不決定,須用格內排序 gather 或定點整數
> atomics,並量成本)、PBF / SPH(鄰居格網的 counting sort `pbf.mojo:156` 上 GPU)、FEM(matrix-free CG 於裝置、
> 單元 gather)、`SoftBody` 晶格(著色)、LBM 的 LES / 插值 / 動量歸約與瓶頸定位。
> (例:10⁶ 粒子 MPM 沙崩的 GPU vs CPU 交叉點)
> - **持久裝置狀態**:不每幀整包上下傳(今日 GPU 布料每個 rollout 上傳 / 下載,`gpu_cloth.mojo:324` 的
> `GpuClothTiming` 已量出傳輸 vs 計算);快照時才讀回。
> - **可微布料 / XPBD**:`Field` 泛型的 XPBD 約束求解(梯度對靜止長度 / 柔度 / 風力)。(例:由目標垂墜形狀反推柔度)
> - **可微 FEM / MPM**:逐步狀態檢查點 + 反向掃描;FEM 的 CG 線性解以隱函數定理(一次額外 CG 解)取梯度;MPM 非線性,
> 無法用 `adjoint.mojo` 的 1 bit / 步技巧,須 tape / 檢查點。(例:由目標位置反推 MPM 材料楊氏模量)
> - **可微 LBM**:格子運算局部且平滑,伴隨法形狀最佳化(Pingen 等 2007)。
> - **批次 × 可微 × 連續體**:`BatchReal[W]` 沿用到布料 / FEM 小件(如多組織物參數辨識)。
> **對照組**:NVIDIA Warp(可微布料 / MPM / FEM kernel)、DiffTaichi / ChainQueen、DiffCloth(Li 等 2022)、
> DiffXPBD、PhysX 5 GPU(FEM 軟體、PBD 粒子)、Genesis(GPU MPM / SPH)、Newton、MJX。
> **優勢區**:記憶體受限的 stencil / gather kernel(LBM、布料 Jacobi)Mojo GPU 與 CUDA 相當(17.17 優勢區 a);
> **gather 式無 atomics 保決定論**(`gpu_cloth.mojo:5-8`)是本專案的 GPU 立場;「批次 × 可微 × Mojo 原生是本專案唯一可能
> 領先的方向」(ROADMAP §17.18)可延伸到連續體——MPM 可微在 Taichi / Warp 已有,但**決定論可微**是差異點。
> **規模軸**:粒子 / 格 / 四面體數的 CPU–GPU 交叉點(隔離傳輸成本,17.17 教訓);參數數 NP 的前向 vs 反向交叉
> (沿用 `bench_diffsolver` 設計);檢查點間隔 × 記憶體;每幀讀回 vs 批次讀回。
> **seam?**:是 —— 裝置(CPU / GPU):每個求解器的 parity 判準沿用「GPU − CPU ≤ 2 × CPU 對 1e-6 擾動的自身發散」;
> 係數環(`RealF` / `DualReal` / `RevReal`):`RealF` 路徑與現況**逐位相同**、前向 / 反向 / 有限差分三方梯度一致。
> bench:MLUPS / 粒子步 per s、梯度 vs 有限差分加速比。
> **交付**:普通(GPU FEM / MPM / PBF 各對 CPU parity;可微布料梯度對有限差分)/ 整合(GPU 連續體 + CPU 剛體同幀,
> 單一 `DeviceContext`;可微 rollout 與 17.18 批次串接)/ 極端(accelerator 缺席自跳過、單粒子、零粒子、
> 全部出界、梯度穿過撕裂 / 接觸開關不連續點(梯度須有限、不得 NaN,該步記 counter 並排除於有限差分對照)、
> NP ∈ {1, 10², 10⁴} 的前向 / 反向交叉點、CG 未收斂(記 `CG_NOT_CONVERGED` 並把該步梯度標為無效,不得靜默回傳)、
> 10⁶ 粒子 MPM)。
> **相依**:17.55、17.56、17.58、17.59、17.17、17.18、17.20。
> **邊界**:17.84「數值 / 可微」(條目本體同樣遺失,以表格名稱為準)若先行提供通用 AD 設施 / 檢查點 / 線性解伴隨,本條取用;
> 否則本條只自備連續體所需的最小版,不擴成通用基礎設施。剛體 GPU articulation 屬 17.17;批次剛體可微屬 17.18 / 17.20;
> 渲染 / 網格輸出屬 17.63。

#### 17.63 輸出 / 快取 — Wave C(資產管線提供者)
> **進度註(2026-10-13)**:點快取先行。`physics/sim_cache.mojo`:`PointCacheWriter`(量化到 2·err、關鍵幀存 zig-zag varint、差分幀存整數差 → 無漂移;
> 點數變動強制關鍵幀;含非有限值的幀與 err = 0 存原始 f32,NaN 保留)、`PointCacheReader`(魔數 "LDPC"、版本 1、幀偏移表、FNV-1a 64 校驗;
> 截斷 / 校驗不符 / 未知版本 / 錯誤魔數 / 偏移越界一律 raise)、`CachePlayer`(17.55 `ContinuumSolver` 實作,建構時解碼全部幀驗證)。
> 量測(`tests/test_sim_cache.mojo` 10/10):16×16 布料 240 幀、err = 1 mm:快取 197494 bytes = 原始 f32 的 26.8 %,最大誤差 0.99998 mm;err = 0 逐位相同;
> `CachePlayer` 經 `step_checked` 與即時布料逐幀差 ≤ err;隨機取幀與循序播放相同;播放器狀態往返後續播相同;零幀、單點、點數變動、NaN 點皆正確。
> `bench_sim_cache`:每點每幀 3.05 / 3.21 / 3.80 / 12.05 bytes(err 1 cm / 1 mm / 0.1 mm / 無損;每座標至少 1 byte 是下限),編碼 28 ns、隨機取幀解碼 93 ns / 點·幀;
> 跳到第 200 幀:快取 25 µs vs 第 192 幀快照 + 重算 9 幀 9.7 ms。
> **進度註(2026-10-17,稀疏體積)**:`geometry/sparse_volume.mojo`:`SparseVolume`(VDB 葉層:8³ 葉以雜湊找、每葉活躍遮罩、背景值;負座標可)、
> 位元組格式("LDSV"、版本 1、背景、葉數、每葉原點 + 512 位遮罩 + 活躍值 f64、FNV-1a 64 校驗;壞魔數 / 版本 / 截斷 / 校驗不符 raise)、`from_dense` / `to_dense`。
> `tests/test_sparse_volume.mojo` 5/5:64³ 場在佔用 0 / 1 / 10 / 100 % 下往返逐位相同,編碼大小對稠密 f64(2 MiB)為 1.5e-5 / 2.8 % / 12 % / 101.9 %
> (稠密在滿佔用時反勝,兩邊都量);LBM 密度場(24³、移動球)輸出再讀回逐位相同(13 714 活躍體素、27 葉)。`bench_sparse_volume`:編碼 27–448 ns / 活躍體素、
> 解碼 47–488 ns(佔用越低每體素越貴:遮罩與葉頭攤在較少體素上)。這是 repo 自己的交換容器;OpenVDB / NanoVDB 檔案格式本身未寫(環境無工具可驗)。
> **位元打包**:`PointCacheWriter(pack=True)`:差分幀改存一個位元組寬度 b(該幀最大 zig-zag 差所需)+ 每個差 b 位元的位元流(新幀種 3,檔案版本 2);
> 不打包時位元組與版本 1 完全相同(1 mm 布料快取仍是 197 494 bytes),讀取器兩版都收。`tests/test_sim_cache_pack.mojo` 4/4:16×16 布料 240 幀,
> 每點每幀 bytes(varint → 打包):err 1 cm 3.05 → 1.10、1 mm 3.21 → 2.26、0.1 mm 3.80 → 3.44,每幀讀回誤差 ≤ err;靜止幀寬度 0;壞位元組 / 截斷 raise。
> **未做**:Alembic(Ogawa)寫出、OpenVDB / NanoVDB 檔案格式、VDB 的內部樹層級、拓撲變動網格、外部工具讀取驗證。

> **現況**:引擎套件**不做任何檔案 I/O**——`grep -E "open\(|read_text|write_text|write_bytes|read_bytes|\bPath\b"`
> 於 `physics/`、`geometry/`、`fluid/`、`numerics/`、`collision/`、`gameplay/`、`ecs/`、`scheduler/`、`diag/`、`procedural/` **零命中**;
> 現有格式都在記憶體裡:`scene_to_string`(`physics/serialize.mojo:118`,f32 位元型態整數 token 串,檔頭
> `:21-22` 自述為固定 f32 的「wire format」,帶版本標籤 `_VERSION = 2` `:38`)、`SaveWriter.bytes() -> List[UInt8]`
> (`gameplay/save.mojo:91`,`SAVE_FORMAT = 1` `:35`)、Chrome Trace 的 `to_chrome_json() -> String`
> (`diag/trace.mojo:133`)。實際落檔交給呼叫端 / 宿主,與平台方向 C(場景格式「跟宿主走」、「不自訂檔案格式」,
> 17.12 決定 ROADMAP §17.12)一致。業界交換格式零命中:`grep -iE
> "openvdb|alembic|nanovdb|\.vdb|\.abc|\.ply\b|\.usd|\.obj\b|gltf"` 於全部引擎套件 **零**。
> 連續體狀態**不在**任何快照或回放內(見 17.55:只有 `SoftBody` 在 `solver6.write_state`);17.39 回放
> (`gameplay/replay.mojo:1-25`)= 輸入 + 週期性 `SimState` 快照,`seek` 重跑到目標 tick,與從頭重放逐位相同——
> 這是「重算」而非「快取」。`geometry/skinning.mojo` 的馬達蒙皮是姿態 → 頂點的**計算**,不是輸出格式。
> 已交付且**不重複主張**:6.10 決定論快照、17.40 存檔、17.39 回放 / seek、17.10 trace 匯出。
> **缺口**:
> - **模擬快取(cache)**:連續體逐幀狀態(粒子位置 / 速度 / 屬性、固定拓撲網格的點快取、股線)以時間取樣陣列
>   輸出,可隨機取幀、增量 + 量化壓縮(誤差上限可設);**快取 ≠ 快照**(允許有損,不保證續跑逐位相同)。
>   (例:10⁵ 粒子 × 600 幀的沙崩快取,取任意幀 < 1 個 chunk 的讀取)
> - **Alembic(Ogawa)寫出**:點 / 多邊形網格 / 曲線(布料、毛髮、粒子),可被 Blender / Houdini / Maya / UE 讀取。
> - **OpenVDB / NanoVDB 稀疏體積交換**:LBM 密度 / 速度場、粒子流體轉出的 level set(17.60)、煙霧;同時能**讀入**
>   VDB SDF 作為初始條件 / 碰撞體(接 17.45 的網格 → SDF 與 17.52 的 SDF 形狀)。
> - **`CachePlayer`**:符合 17.55 契約的播放器,以快取取代即時模擬(烘焙特效在決定論遊戲迴圈裡重現)。
> - **大小 / 重算取捨**:決定論讓「存輸入 + 種子、需要時重算」成為快取的替代(17.39 `seek` 即此);
>   這是一個要量的取捨,不是結論。
> - **格式治理**:魔數、版本、校驗和(沿用 `save.mojo:35` 的版本欄做法),未知版本明確拒絕。
> **對照組**:Alembic(Sony / ILM)、OpenVDB(DreamWorks)/ NanoVDB(NVIDIA)、USD 時間取樣屬性(Pixar)、
> Houdini bgeo、Blender MDD / PC2 點快取、UE Geometry Cache / Chaos Cache Collection、Unity VFX Graph 點快取。
> **優勢區**:決定論下**重算 vs 快取**的交叉(長時間 + 小輸入 → 重算勝;昂貴求解 + 反覆 seek → 快取勝);
> 稀疏體積在佔用率低的 LBM / 煙霧場上的容量優勢(**佔用率高時稠密陣列反勝**,依優勢區規則兩邊都量)。
> **規模軸**:點數 / 體素數 × 幀數;稀疏佔用率;壓縮比 vs 誤差上限;寫入吞吐(MB/s);seek 延遲(快取 vs
> 快照 + 重算 K 步)。
> **seam?**:是 —— 狀態來源:「即時重算(17.39 式)/ 快照關鍵幀 + 重算 / 快取播放」:前兩者逐位相同,快取播放在
> 錄製幀上與即時結果的差 ≤ 量化誤差上限(parity);稀疏樹 vs 稠密陣列的場輸出:讀回數值相同,bench = 容量與寫入 /
> 讀取吞吐 vs 佔用率曲線。
> **交付**:普通(輸出一段布料 / 粒子快取再讀回,逐幀誤差 ≤ 上限;LBM 場往返 VDB 數值相同)/ 整合(快取在 17.55
> 契約下由 `CachePlayer` 驅動並與即時求解器於錄製幀對齊;Alembic / VDB 以 repo 內讀取器往返逐位相同;外部官方工具讀取驗證為選用測試,工具不在環境時自動跳過)/ 極端(零幀、單點、全空體積、無效 / 截斷 / 未知版本檔案 raise 而非讀超界、幀間點數變動、
> NaN 點、佔用率 0% 與 100%、10⁷ 體素)。
> **相依**:17.55(狀態存取契約)、17.12(宿主格式政策)、17.45(網格 → SDF)、17.52(SDF 形狀)、17.60(level set 輸出)、
> 17.39、17.56 / 17.57 / 17.58(輸出來源)。
> **邊界**:實際開檔 / 落盤 / 網路傳輸屬宿主(編碼器只產生 / 消費位元組緩衝,如 `save.mojo`);場景組合(USD stage、
> glTF 場景)屬 17.12;物理世界的除錯擷取檔與回放屬 17.80(剛體世界 / 觸點為主,與本條的連續體 DCC 交換分工);
> 骨架 / blend shape 的形變資料屬 17.65;DCC 外掛屬 repo 之外。新增 `exchange` 類套件時須同一 commit 修改
> `scripts/build_engine.sh`(`pc <pkg>`)與 `scripts/arch_layers.toml`:編碼器以平坦 SoA 欄位為輸入、不依賴物理型別,
> 才能放在低層而不違反分層。

---

## 可微模擬、批次世界與數值深化

範圍:diffsim、diffsolver、tape、批次、稀疏線代。

| 編號 | 條目 | 狀態 | Wave | 說明 |
|---|---|:-:|:-:|---|
| 3.1 | [可微模擬(與 GA 核心契合度最高)](ROADMAP_HISTORY.md#31-可微模擬與-ga-核心契合度最高) | ✅ |  | `Field` trait 擴充 + `DualBatch`(SIMD 4 lane 多方向導數)+ `physics/diffsim.mojo` 拋體 rollout,`tests/test_diffsim.mojo` 驗證對偶 vs 中央差分穿過彈跳 parity、梯度下降控制任務收斂與 `GMV[3,0,1,DualReal]` GA 原生 AD。 |
| 4.2 | [可微模擬深化:reverse-mode AD tape](ROADMAP_HISTORY.md#42-可微模擬深化reverse-mode-ad-tape) | ✅ |  | Field trait 已有 reverse-mode 成員 RevReal 與 append-only Tape(grad() 一次反向掃即得全部 adjoint),reverse / DualBatch / FD 三方 parity 通過;bench_diffsim 顯示成本對參數數 N 持平,外推交叉點約 N=76。 |
| 13.7 | [剛體求解器可微(把 `Field` 推進 solver6)](#137-剛體求解器可微把-field-推進-solver6) | 🔶 |  | 可微剛體接觸有兩個實作:physics/diffrigid.mojo(Field 泛型的衝量式 rollout)與 17.20 的 physics/diffsolver.mojo(SphereWorld[F]:用指示函數改寫 ContactScene6 的同一套演算法,範圍限定動態球 + 靜態平面,並在檔頭寫明子集邊界);solver6.mojo 本身沒有泛型化。 |
| 13.9 | [批次多世界步進](#139-批次多世界步進) | ⏸ |  | 多個獨立世界一起步進的通用 RL 能力;目前只在可微子集上以 17.18 的 `BatchReal[W]` / `step_worlds_parallel[W]` 落地,完整 solver6 批次仍待平台整合方向決定。 |
| 15.3 | [comptime 自動伴隨式生成](ROADMAP_HISTORY.md#153-comptime-自動伴隨式生成---完成2026-08-11) | ✅ |  | 步驟以小型線性直線程式描述,用 comptime for 在編譯期展開前向與伴隨,8.48 ns,比 runtime tape 快 5.9×,有 27 checks 測試與 bench_diffsim 一列。 |
| 17.18 | [批次多世界步進(13.9 落地)](ROADMAP_HISTORY.md#1718-批次多世界步進139-落地--wave-b) | ✅ | B | `BatchReal[W]` 讓 17.20 的 `SphereWorld` 每個 SIMD lane 跑一個世界,`step_worlds_parallel[W]` 再把批次分到各核,N ≥ 64 時約 7.4×(lane)/ 22×(lane × 核)於純量循序。 |
| 17.20 | [剛體 solver 可微化收尾(13.7)](ROADMAP_HISTORY.md#1720-剛體-solver-可微化收尾137--wave-b) | ✅ | B | `SolverField` 係數環加上 `physics/diffsolver.mojo` 的 `SphereWorld[F]`(動態球 + 靜態平面)以與 `ContactScene6` 相同的每幀演算法提供可微接觸 / 摩擦步進,四種係數環梯度一致,並有 μ 系統識別範例。 |
| 17.84 | [數值 / 可微深化](#1784-數值--可微深化--wave-c) | 🔶 | C | 共用 gradcheck、精度與可重現性政策、求解器多樣性、AD 深度、接觸梯度的平滑變體 |

### 已完成條目的遺留待辦

這些條目已完成並移到歷史檔,但各自記下了尚未做的部分:

- **3.1**([紀錄](ROADMAP_HISTORY.md#31-可微模擬與-ga-核心契合度最高)):learned physics:`experiments/exp_clifford_nn.mojo` 升級為 learned-physics 原型(GATr/CGENN 方向,arXiv:2305.18415)— 3.1 與 4.2 stretch 皆標未做,頂部 2026-07-13 狀態列為「明確留待後續」
- **3.1**([紀錄](ROADMAP_HISTORY.md#31-可微模擬與-ga-核心契合度最高)):接觸梯度高原(settled 軌跡 dy/dv≈0,同 Brax 病態梯度)僅重現並記錄,未處理
- **4.2**([紀錄](ROADMAP_HISTORY.md#42-可微模擬深化reverse-mode-ad-tape)):Stretch:experiments/exp_clifford_nn.mojo 升級為 learned physics 原型(GATr/CGENN 方向),未做(目前該實驗仍以 SPSA 訓練,沒有接 tape)
- **15.3**([紀錄](ROADMAP_HISTORY.md#153-comptime-自動伴隨式生成---完成2026-08-11)):比手寫伴隨式(5.27 ns)仍慢 1.61×,剩餘差距照實報
- **15.3**([紀錄](ROADMAP_HISTORY.md#153-comptime-自動伴隨式生成---完成2026-08-11)):OP_MUL(變數×變數)刻意沒有微分規則:子語言只支援線性程式,非線性程式會在編譯期被判為非線性
- **17.18**([紀錄](ROADMAP_HISTORY.md#1718-批次多世界步進139-落地--wave-b)):批次 × 反向梯度(batched tape)
- **17.18**([紀錄](ROADMAP_HISTORY.md#1718-批次多世界步進139-落地--wave-b)):`ContactScene6` 本體的 SoA 批次(目前只在可微子集上)
- **17.18**([紀錄](ROADMAP_HISTORY.md#1718-批次多世界步進139-落地--wave-b)):GPU 批次
- **17.18**([紀錄](ROADMAP_HISTORY.md#1718-批次多世界步進139-落地--wave-b)):完整 solver6 批次隨 RL 平台(B)需求再擴(13.9 決定 2026-10-09)
- **17.20**([紀錄](ROADMAP_HISTORY.md#1720-剛體-solver-可微化收尾137--wave-b)):可微子集外擴:盒 / 膠囊
- **17.20**([紀錄](ROADMAP_HISTORY.md#1720-剛體-solver-可微化收尾137--wave-b)):可微子集外擴:關節
- **17.20**([紀錄](ROADMAP_HISTORY.md#1720-剛體-solver-可微化收尾137--wave-b)):可微子集外擴:恢復係數 pass
- **17.20**([紀錄](ROADMAP_HISTORY.md#1720-剛體-solver-可微化收尾137--wave-b)):全部球對每幀都攜帶是 O(n²),大 n 需寬相
- **17.20**([紀錄](ROADMAP_HISTORY.md#1720-剛體-solver-可微化收尾137--wave-b)):RevReal tape 每運算一次 `List.append` + `Optional` 指標,是反向模式偏慢的主因
- **17.20**([紀錄](ROADMAP_HISTORY.md#1720-剛體-solver-可微化收尾137--wave-b)):`Field` 未穿過 solver6 本體(取第二條路:可微子集);solver6 係數環 parity seam 未建

### 待辦與部分完成條目

#### 13.7 剛體求解器可微(把 `Field` 推進 solver6)

> **狀態**:🔶 部分完成(衝量式玩具 `diffrigid` 與 17.20 的可微子集 `diffsolver` 已交付;`solver6.mojo` 本身沒有穿過 `Field`,收尾見 17.20)— 原屬 Wave D
> **進度(2026-08-11)**:完成 `physics/diffrigid.mojo`:Field 泛型的衝量式剛體接觸 rollout(鏡射反射 + 恢復係數),含 `tests/test_diffrigid.mojo` 與 `benchmarks/bench_diffrigid.mojo`。先做衝量接觸,是因為接觸才是可微剛體模擬真正困難的部分,量測也證實了這點:接觸排程的身分是觸發步索引,不是反彈次數;y0 ∈ [0.5, 1.0] 的 499 個取樣點中有 366 次排程改變;可用的有限差分探針隨 dt 縮小(dt = 1/120 時從 2.5e-3 降到 1.6e-4)。在這些性質確立之前就把 solver6 泛型化,只會得到一個更大、而且有同樣陷阱的東西。
> **進度(2026-09-29,見 17.20)**:沒有把 `Field` 穿過具體的 `Vec3` / `Body6` solver6,而是改為明確定義「可微子集」並寫在檔頭。`geometry/field.mojo` 的 `SolverField`(`positive` 的導數定義為 0,也就是接觸開關的次梯度約定);`physics/diffsolver.mojo` 的 `SphereWorld[F]` 以同一套 per-frame 演算法處理動態球 + 靜態平面;`tests/test_diffsolver.mojo` 26/26(與 `ContactScene6` parity,四方梯度一致);`bench_diffsolver`;`examples/22_diffsolver_sysid.mojo`。
> **剩餘**:
> - 把 `Field` 穿過 `physics/solver6.mojo`(現在 1770 行,大量具體化的 Vec3 / Real,泛型化風險高,需要獨立一個 wave),或繼續擴大可微子集,由 17.20 承接。
> - 子集外擴:盒 / 膠囊、關節、恢復係數 pass(17.20 待辦)。
> - diffsolver 每幀攜帶全部球對,是 O(n²),n 大時需要寬相(17.20 待辦)。
> - RevReal tape 每個運算都做一次 `List.append` 加一個 `Optional` 指標,這是反向模式偏慢的主因(17.20 待辦)。
> - 對照 4.1 玩具的交叉點是否搬移:`bench_diffsolver` 中 RevReal 對 FD 的交叉點在 NP ≤ 16 的掃描範圍之外。
> **設計**:`ContactScene6[B, F: Field]` 係數泛型化,讓 DualBatch / RevReal / emitted adjoint 都能穿過真實求解器。接觸的不可微性是核心難點:接觸開關是分支,在切換處梯度不存在,需要平滑接觸(既有 softbody 已經是平滑懲罰)或次梯度約定,兩者都要明確標示。
> **優勢**:這是最大的差異化:把 4.1 的 emitted-adjoint 9× 從玩具搬到真實求解器,系統辨識、軌跡優化、可微控制都因此可行。
> **對照組**:有限差分(必要的正確性 oracle)、runtime tape、DualBatch,三方 parity,方法論與 `bench_diffsim` 相同。
> **規模軸**:剛體數 × 接觸數 × 參數數(reverse 的優勢區在參數多的時候)。
> **交付物**:`test_diffsolver`(三方梯度 parity、明確記錄接觸切換處的梯度行為、在平滑接觸極限下收斂到解析解)+ bench(參數掃描,對照 4.1 的玩具交叉點是否搬移)。
> **相依**:沒有硬相依,但成本最高;建議在 13.1 / 13.2 之後做,屆時才有真實場景可以微分。
> **歷史**:原「現況」:AD 只覆蓋 `physics/diffsim.mojo` 的玩具拋體,`ContactScene6` 完全不可微;4.1 中 emitted-adjoint 比 tape 快 9× 的結果只在玩具上成立。2026-08-11 註記 solver6 為 1555 行。

#### 13.9 批次多世界步進

> **狀態**:⏸ 決策點(與平台整合綁定)—— **不排入實作,先標記**。
> **決定(2026-10-09)**:平台方向以 C 為主、RL 平台(B)為次要。批次能力的現行落點是 17.18(可微子集上的 `BatchReal[W]`);完整 solver6 批次等 B 有需求時再擴。
> **背景**:這是 MJX / MJWarp 提供的能力,而使用者明令 MuJoCo 特定實作不入路線;但「多個獨立世界一起步進」是**通用 RL 需求**,不是 MuJoCo 專屬。
> **與被排除項的關係**:實作方式(SoA 批次 vs 多執行緒多世界 vs GPU 批次)取決於**要與哪個 RL 平台整合** —— 與場景格式是同一個待決策。
> **若日後開做**:優勢 = 取樣吞吐;對照組 = 單世界 × N 的序列步進與既有 islands 平行;規模軸 = 世界數 × 每世界剛體數。
> **相依**:平台整合方向拍板。

#### 17.84 數值 / 可微深化 — Wave C
> **進度註(2026-10-13)**:三塊先行。(1)`harness/gradcheck.mojo`:`GradProblem` trait(`dim` / `value` / `gradient` / `schedule`)+ `gradcheck(p, x, steps)`
> 回傳每個步長的誤差(max |fd − g| / max(1, max |g|))、每個步長因分支改變而略過的分量數與最佳步長;`max_rel_diff` 比兩個解析梯度(前向 vs 反向)。
> (2)`numerics/bicgstab.mojo`:`bicgstab[Op: LinearOperator]`(Float64 遞迴、可選 Jacobi),`residual` 回報**真殘差**而非遞迴估計,
> 真殘差高於 max(tol, 1.2e-4) 即不算收斂。(3)`numerics/dense.mojo`:`condition_1`(Float64 LU 的精確 1-範數條件數)與 `solve_dense_refined`
> (f32 消去 + Float64 殘差 + Float64 累加的混合精度迭代改良)。
> 量測(`tests/test_numerics_deep.mojo` 13/13):Rosenbrock 正確梯度最佳誤差 7.9e-11(h=1e-6),一個分量變號 1.04;diffsim 落點 x 對 6 個控制量,
> 反向 vs 前向(`DualReal`)1.8e-7、反向 vs 中央差分 1.0e-5(f32 primal,h=1e-2);|x| 在 1e-4 處 h=1e-2、1e-3 各 1 個分量跨折點被計數略過。
> 迎風對流擴散 n=200(列 (−2, 3.1, −1)):BiCGStab 181 次、誤差 4.5e-6;CG 800 次不收斂、誤差 139。c=4 無反應項時 BiCGStab 遞迴殘差達 1e-6、
> 真殘差 9e8、誤差 6e9 —— 加真殘差檢查前會回報收斂,現在回報不收斂。Hilbert 條件數 9.43e5 / 2.81e7(公開值 9.44e5 / 2.91e7;項先捨入到 f32);
> Hilbert(5) 改良 3 輪殘差 1.6e-8 → 5e-17、對 Float64 解的誤差 3.8e-4 → 0。`bench_numerics_deep`:BiCGStab n=256 / 1024 / 4096 為 215 / 111 / 71 次;
> **n=1024 加 Jacobi 時發散**(1136 次不收斂、誤差 4e14,同矩陣不加則收斂)—— 非正規矩陣上 BiCGStab 收斂不規則,GMRES 尚缺;
> 稠密 n=32:f32 解 29 µs、改良 3 輪 123 µs、條件數 104 µs;一次 gradcheck(6 控制 × 6 步長)33 µs。
> **進度註(2026-10-17)**:
> - `numerics/gmres.mojo`:GMRES(m)(MGS Arnoldi、Givens、右 Jacobi 前條件、Float64、真殘差收斂判定)。`test_solvers`:對流擴散 n=1024(bench 的解)上 BiCGStab + Jacobi
>   發散(誤差 4.1e14),GMRES(30) 有無 Jacobi 皆 120 步收斂、誤差 7e-5。
> - `numerics/cholesky.mojo`:RCM 排序、消去樹 + `ereach` 的上視 sparse Cholesky(Float64,非正定 raise)、IC(0) 與 `pcg_ic0`。2D Poisson 32×32:Cholesky 誤差 7.2e-7;
>   CG 69 次 vs IC(0)-PCG 22 次;節點打亂的網格 nnz(L) 自然序 81326 → RCM 23344;不定、奇異、非排列 raise。
> - `physics/fem.mojo`:`FemImplicitOp.assemble`(與 `stiffness_apply` 共用逐元素微分,釘住節點的列行改單位,保持對稱)、`FemBody.solver` seam(CG / Cholesky / IC(0)-PCG)。
>   `test_fem_solvers` 6/6:組裝矩陣 vs matrix-free 2.7e-5 / 57.9;2 s 懸臂三解法尖端軌跡差 2.1e-7 m;迭代 CG 4896 vs IC(0) 1438;既有 FEM 測試輸出不變。
>   `bench_fem`(ms / 步):6×2×2 CG 2.22、Cholesky 2.09、IC(0) 2.22;12×4×4 CG 23.1、Cholesky 28.3(每步重新分解)、IC(0) 19.8。
> - `geometry/checkpoint.mojo`:`RevSystem` + `grad_full` / `grad_checkpointed`(段尾狀態 adjoint 與參數的累加 adjoint 帶入重算段)。`test_checkpoint`:600 步彈簧鏈,
>   每 1 / 7 / 50 / 600 步檢查點的梯度與完整 tape **逐位相同**;峰值節點 72050 → 6050(每 50 步);對中央差分 0.07 %。
> - `SolverField.smooth_positive(k)`(五種 scalar,真導數)與 `SphereWorld.contact_k`(預設 0 = sharp,既有 diffsolver 輸出不變)。`test_smooth_positive`:
>   **發現**:球落地滑行的 d x / d 落下高度,sharp 0.5 vs 中央差分 0.271;平滑「接觸存在」開關只在 k=30 改成 0.497、k ≥ 100 即等於 sharp —— 這個偏差不來自存在開關
>   (衝量夾限與摩擦錐仍是 sharp),平滑存在開關不解決它。
> **未做**:四個既有可微測試改用 gradcheck、排程雜湊接到 diffrigid / diffsim 的分支位元、精度 / 縮併政策文件與旗標漂移測試、多重網格 / MINRES / 平行 SpMV、
> 批次 × 反向、Hessian-vector、隱式微分、平滑化衝量夾限 / 摩擦錐(上面的偏差來源候選)。
> **現況**:
> - **線性代數**(`numerics/`):CSR 矩陣與三元組組裝(`numerics/sparse.mojo:54`、`from_triplets` `:89`)、matrix-free 的 `LinearOperator`(**僅限對稱正定**,`:35-43`)、
>   `cg` / `pcg`(只有 Jacobi 預條件,`numerics/cg.mojo:61,73`)、`jacobi_solve`(`:175`)、稠密高斯消去含部分選主元(`numerics/dense.mojo:84,97`)。
>   grep -rniw `cholesky|multigrid|gmres|bicgstab|minres|ilu|ic0|ldl|ldlt|eigen|svd|amg`(`numerics physics geometry`,`*.mojo`)**零命中**(須用 `-w`:不加時 `ilu` 會命中 "failure");grep `parallelize`(`numerics`)零命中,`CsrMatrix.apply` 為串行迴圈。
> - 引擎內的消費者很少:`physics/fem.mojo:287`(`step_implicit` 的 `cg`)與稠密解(`physics/chain.mojo:27`、`constraints.mojo:35`、`floating.mojo:36`)。
> - **精度政策是零碎的**:引擎純量是 float32(`geometry/vec.mojo:14-15`);Krylov 遞迴用 float64,是量到的必要性(float32 在 n=256 發散,ROADMAP §15.1);
>   稠密消去在 `Real`(float32)上做,檔頭明言不估計條件數(`numerics/dense.mojo:33`)。
>   浮點縮併 / FMA 策略沒有文件:grep `fma|contraction|fast.?math`(`docs README.md CLAUDE.md`)唯一命中是 GA 乘積展開的敘述(`docs/SOTA_GAP_ANALYSIS.md:27`);
>   實際後果已出現 —— 批次 lane 對純量世界差 2.4e-6、非逐位(ROADMAP §17.18)。
> - **自動微分**(`geometry/field.mojo`):`Field`(`:25`)、`SolverField`(`:39`,`recip` / `root` / `positive`,`positive` 導數為 0 的次梯度約定)、`RealF`(`:61`)、`DualReal`(`:97`)、
>   `DualBatch`(`:141`)、`BatchReal[W]`(`:191`)、`Tape` 與 `RevReal`(`:254` / `:299`);`TapeNode` 只有二元運算元(`:244-251`),`Tape.grad` 反向掃一次得全部輸入的梯度(`:272-291`)。
> - **可微求解器的範圍很窄**:`physics/diffsolver.mojo:1-40` 檔頭明載子集 = 動態球 + 靜態平面、有摩擦接觸,**無關節、無恢復係數 pass、無睡眠、無 CCD、無軟體**;
>   17.20 的待辦列「盒 / 膠囊、關節、恢復係數 pass、寬相、RevReal tape 效率」(ROADMAP §17.20);17.18 的待辦列「批次 × 反向梯度、`ContactScene6` 本體 SoA 批次、GPU 批次」(ROADMAP §17.18)。
> - **comptime 伴隨式只涵蓋線性程式**:`physics/adjoint.mojo:38-45` 的運算碼中 `OP_MUL`(變數 × 變數)刻意不給規則,`program_is_linear` 於編譯期拒絕(`:67-75`)。
> - **沒有檢查點 / 重算**:grep -i `checkpoint|revolve`(`geometry`)零命中;`physics` 的三處命中(兩檔)都是每步 1 bit 的分支記錄(`physics/diffsim.mojo:97,119`、`adjoint.mojo:94`)。Tape 每個運算一個節點,記憶體隨 rollout 長度線性成長。
> - **沒有 Hessian-vector / 二階、沒有對線性解的隱式微分**:grep -i `implicit.diff|second.order`(`numerics physics geometry`)零命中;`hessian` 只在 `physics/vbd_cloth.mojo` 的 docstring。
> - **梯度檢查是各測試自備**:`harness/runner.mojo` 只有 `check` / `eqi` / `almost` / `finish`(`:29-65`);有限差分散落在各測試(例:`tests/test_adjoint.mojo:50` 的 `_fd`、`tests/test_gmv_ad.mojo:5`),沒有共用的 gradcheck。
> - 接觸不連續處:現行是「凍結排程」的次梯度(`physics/diffrigid.mojo` 檔頭;`rollout_rigid` `:49` 與平滑懲罰版 `rollout_soft` `:82` 並存為玩具層的兩個模型),`SolverField.positive` 尚無平滑變體。
> **缺口**:
> - **共用 gradcheck**(`harness/`):中央差分 / 前向 / 反向三方比對的標準函式,含步長掃描與排程雜湊(「同一排程」判定,`diffrigid` 的教訓);例:現有四個可微測試改用它。(先做,成本最低,解鎖其餘。)
> - **精度與可重現性政策**:何處逐位、何處容差(例:批次 vs 純量的 2.4e-6 要有出處);編譯旗標 / 縮併的明文政策與一個會抓出旗標漂移的測試;稠密解的條件數估計與迭代改良(float32 消去 + float64 殘差)。
> - **求解器多樣性**(由 17.55 / 17.58 / 17.59 的需求驅動,不先驗做):稀疏 Cholesky(含 AMD 排序)、不完全 Cholesky 預條件、(代數)多重網格、MINRES / BiCGStab(非對稱 / 不定,17.59 流固耦合與壓力投影會需要)、平行 SpMV。
>   例:體積軟體(17.58)的剛性隱式步,CG-Jacobi 迭代數 vs 稀疏 Cholesky 的時間。
> - **AD 深度**:可微子集外擴(盒 / 膠囊 → 關節 → 恢復係數);**批次 × 反向**(batched tape);**檢查點 / 重算**(Revolve 式,記憶體 ↔ 重算的曲線);
>   Tape 效能(逐運算 `List.append` + `Optional` 指標是已知主因,ROADMAP §17.20);二階(Hessian-vector,forward-over-reverse);
>   對線性解 / 接觸 LCP 的**隱式微分**(以隱函數定理反傳,不穿過迭代);comptime 伴隨式擴到含非線性運算(儲存必要中間值)。
> - **接觸梯度的平滑變體**:`SolverField.positive` 的 sharp / smooth 兩版(溫度參數),量梯度偏差 vs 有限差分,而不只是宣稱。
> **對照組**:線性代數 —— Eigen / SuiteSparse(CHOLMOD)、AMGCL、PETSc、Intel MKL 的稀疏求解器;可微 —— Warp(tape + 自訂伴隨)、Taichi / DiffTaichi、JAX、Enzyme、
> Nimble Physics(Werling et al. 2021,接觸 LCP 的隱式微分)、Brax;理論 —— Griewank & Walther 2000(Revolve 檢查點)、Pearlmutter 1994(Hessian-vector)、Amos & Kolter 2017(OptNet,對最佳化層的隱式微分)。
> **優勢區**:(a)comptime 伴隨式免執行期生成成本 —— 已量 8.48 ns vs runtime tape 49.9 ns(5.9×),仍比手寫慢 1.61×(ROADMAP §15.3,15.3 進度註);
> (b)螺旋(screw)動力學可微天生免 gimbal / 重正規化(17.20 條優勢區);(c)混合精度 Krylov 的必要性已有量測。
> 劣勢區(要量):稀疏直接法與 AMG 是成熟函式庫的主場,本條的目標是**夠用且與引擎資料佈局相容**,不與 CHOLMOD 比極限;反向模式在 NP 小時 DualBatch 更便宜(ROADMAP §17.20 的 `bench_diffsolver` 結果)。
> **規模軸**:稀疏系統 n ∈ {1e3, 1e4, 1e5, 1e6} × 條件數 × nnz/列;SpMV worker 數;tape 長度(步數 × 每步運算數)vs 記憶體;檢查點段數 vs 重算開銷;參數數 NP;批次 W。
> **seam?**:是 —— (1)`LinearSolver` 變體(CG / PCG-Jacobi / PCG-IC0 / 稀疏 Cholesky / 多重網格):同一 SPD 系統的解在容差內一致,bench 為「達容差時間 vs n、條件數」;
> (2)梯度記錄變體(完整 tape / 檢查點 tape):梯度**逐位相同**(重算是確定性的);(3)`positive` sharp / smooth:溫度 → 0 時收斂回 sharp。每個變體一列 bench 進範本。
> **交付**:每個新求解器 / AD 功能都要接上真實路徑 —— 稀疏 Cholesky 接 `physics/fem.mojo` 的 `step_implicit`(與現行 `cg` 並存為變體);子集外擴接 `examples/22_diffsolver_sysid.mojo`(把它的辨識目標從現行參數擴到盒堆摩擦係數 μ 與恢復係數 e);gradcheck 接現有四個可微測試。
> 普通:Poisson / FEM 小系統上各求解器對閉式解;箱落地的 μ 辨識梯度對有限差分;檢查點梯度 == 完整 tape 梯度。
> 整合:`step_implicit` 換求解器後整步結果在容差內相同且穩定;盒堆的可微子集與 `ContactScene6` 對照(沿用 `test_diffsolver` 的 parity 寫法);批次 × 反向與逐世界迴圈的梯度一致。
> 極端:奇異 / 半正定系統(必須回報破裂且回傳有限值,沿用 15.1 的紀律)、病態(對角跨 1e6)、tape 長度 1e6 節點、接觸開關跨越點、零梯度路徑、NaN 世界不污染其他 lane、float32 溢出邊緣。
> **相依**:15.1、4.2、15.3、17.18、17.20(本條承接其待辦);消費者 17.55 / 17.58 / 17.59 / 17.56(隱式布料);17.82(gradcheck 放在 `harness/`,只供 tests / benchmarks 使用,符合分層規則)。
> **邊界**:**連續體的 GPU / 可微**屬 17.62(本條只供應求解器與 AD 機件);RL / 機器人的訓練迴圈已被使用者排除;Python 端的梯度介面屬 17.21;
> 剛體 GPU 求解器屬 17.17;f64 世界座標屬 17.8(本條只定精度政策,不改 `WorldType`)。

---

## GPU 計算

範圍:GPU kernels 與單一 device context。

| 編號 | 條目 | 狀態 | Wave | 說明 |
|---|---|:-:|:-:|---|
| 3.2 | [GPU 物理(Mojo kernels)](ROADMAP_HISTORY.md#32-gpu-物理mojo-kernels) | ✅ |  | 引擎首個 GPU 常駐物理:gather 式 Jacobi XPBD 布料 4 kernels、`has_accelerator` 守衛,CPU/GPU parity 2.4e-6,RTX 3060 上 16k 粒子 8.3×、65k 粒子 1.08 ms/step。 |
| 4.3 | [GPU 物理擴張:VBD 原型](ROADMAP_HISTORY.md#43-gpu-物理擴張vbd-原型) | ✅ |  | VBD 布料原型(每頂點 3×3 局部 Newton、棋盤 2 著色 Gauss-Seidel、4 個 kernel)與 XPBD 同場景比較:在簡單布料上 XPBD 收斂較快較省;另修好多 DeviceContext 掛死問題(共享單 context,128² XPBD GPU 28×)。 |
| 17.17 | [GPU 剛體 / articulation solver](#1717-gpu-剛體--articulation-solver) | 🔶 | B | `GpuContactSolver` 把 `ContactScene6` 著色模式的接觸子步迴圈搬到 GPU(CPU 保留收集、island、著色與簿記),以量測出的擾動界通過 parity 測試 22/22。2026-10-12 加上批次 articulation(ABA,每個 thread 一個實例,支援轉動 / 滑動關節)與批次 narrowphase(box / sphere / capsule),裝置程式碼已為 sm_86 編譯並檢查 PTX,但尚未在 GPU 主機上執行。 |

### 已完成條目的遺留待辦

這些條目已完成並移到歷史檔,但各自記下了尚未做的部分:

- **3.2**([紀錄](ROADMAP_HISTORY.md#32-gpu-物理mojo-kernels)):GPU rigid(6-DOF 剛體 solver 上 GPU)— 4.3 stretch 未做,後續歸入 17.17 GPU articulation / 剛體
- **3.2**([紀錄](ROADMAP_HISTORY.md#32-gpu-物理mojo-kernels)):Gate 所寫粒子數 scaling 10⁴→10⁶ 只量到 65k 粒子(bench_gpu_cloth 記錄 16k、65k),10⁶ 端未見數字
- **4.3**([紀錄](ROADMAP_HISTORY.md#43-gpu-物理擴張vbd-原型)):Stretch:GPU rigid(6-DOF 剛體 solver 上 GPU)— 本節未做;已轉到 17.17,剛體接觸部分於 2026-09-29 完成,GPU articulation(Featherstone)、GPU narrowphase、kernel 融合、持久裝置狀態仍是 17.17 的待辦

### 待辦與部分完成條目

#### 17.17 GPU 剛體 / articulation solver

> **狀態**:🔶 部分完成(Wave B;GPU 剛體接觸 ✅ 2026-09-29;GPU articulation / narrowphase 程式碼 2026-10-12 交付,**裝置端尚未在 GPU 上執行** —— 本機無加速器,見下方進度;剩餘順序第 (7) 項)
> **缺口**:GPU 端 contact solver(著色 / Jacobi PGS)、GPU narrowphase / manifold、GPU articulation(Featherstone on device),以及 CPU↔GPU parity。
> **對照組**:PhysX 5 GPU rigid bodies、Newton(Warp)、Genesis、AVBD(SIGGRAPH 2025 擴到剛體)。SOTA_GAP 自述「領域已決定性轉向 GPU-first」。
> **優勢區**:中 ——(a)Mojo GPU kernels 在 memory-bound 負載與 CUDA 相當(ORNL);(b)著色平行(6.11)的 CPU 版可作 parity 基準;(c)motor / screw 狀態緊湊(8 float)利於頻寬。
> **規模軸**:剛體數 / 接觸數的 GPU vs CPU 交叉點;每幀 readback 成本分開量(Wave 1 教訓:傳輸成本依情境而定)。
> **seam?**:是 —— contact solver 裝置實作(CPU islands / GPU colored)→ parity(同場景 rest 態 by action,對齊睡眠)+ bench(N 掃描 + 傳輸成本獨立一列)。
> **交付**:普通(箱堆 GPU / CPU 同 rest)/ 整合(GPU 剛體 + CPU 軟體同幀、island 邊界)/ 極端(單體、百萬接觸、高質量比、無 accelerator 時自動跳過)。
>
> **進度(剛體接觸 ✅ 2026-09-29)**:`physics/gpu_contact.mojo` 的 `GpuContactSolver` 把 `ContactScene6.step(cfg.colored=True)` 的子步迴圈(重力 / 各色 warm start / 各色 iters 次軟求解 / 位姿積分 / 各色兩次 relax)搬到裝置上,一個 thread 處理一個接觸(同色接觸不共用動態體)。kernel 內把 body 載入成真正的 `QuatBody6`,呼叫它自己的 `velocity_at` / `angular_factor` / `apply_impulse` / `integrate_*`,執行的是正式的 body 算術。CPU 保留收集、island、著色(`ContactScene6.begin_external_solve`)以及恢復係數 / 睡眠 / NaN 隔離 / 事件 / 快取(`end_external_solve`;`_color_pairs` 從 `step` 機械抽出)。
> - **判準是量出來的**:箱堆的接觸裁剪是離散分支,CPU 自己對 1e-7 的擾動在 20 幀內會放大到約 3e-3。因此 `tests/test_gpu_contact.mojo`(22/22)的判準是「GPU−CPU ≤ 2 × CPU 對每個動態體施加 1e-6 擾動時的自身發散」+ 靜止狀態 by action。案例:五箱塔、雙 island + 材質 + 滾球(事件開)、10:1 質量比、400 箱場(差 7.6e-6);單體無接觸時與 CPU 相同;關節 / 軟體 / CCD 場景會被拒絕。
> - `bench_gpu_contact`(RTX 3060,寬相開,箱子全醒):GPU 子步迴圈在 N=64..4096 約 0.7–1.0 ms/幀,幾乎持平(由 kernel 啟動次數主導),傳輸 0.15–1.6 ms;N=4096 時 CPU 串行求解約 70 ms → 只看求解,GPU 約 28×(含傳輸)。
> - 當時整幀被 CPU 端收集與簿記主導(N=256/1024/4096:0.6 / 6.8 / 82 ms,近平方),即審計 F22 的 O(n²) 熱點,交給 17.19 優先處理。
> - 相關前置:單一 device context 擁有者 ✅ 2026-09-29(Wave B 入口前置,標為 17.17):引擎內不再建立 `DeviceContext()`。
>
> **進度(articulation + narrowphase,2026-10-12)**:
> - 做法:kernel 每個 thread 的本體寫成扁平陣列上的一般函式,裝置 kernel 與主機迴圈呼叫**同一個函式**;主機版與既有 CPU 求解器做 parity,
>   裝置版以 `pixi run gpu-compile`(`scripts/gpu_compile_check.sh`,`--target-accelerator sm_86` 建置所有 GPU 測試與 bench,15 / 15)證明可編譯,
>   並檢查 PTX:articulation kernel 2624 行、narrowphase kernel 3682 行,零 malloc / call(全內聯),每 thread 堆疊 448 / 928 B。
>   **未做到的是在真 GPU 上執行**:`test_gpu_artic` / `test_gpu_narrow` 的裝置半段(容差 1e-3 / 99.9 % 一致 + 1e-4)與 bench 的裝置列需在有加速器的主機跑。
> - `physics/artic_batch.mojo`:`aba_instance`(Featherstone RBDA 7.3 三趟掃描,沿用 `chain.mojo` 的空間代數 helper,motion subspace 一般化為 (s_w, s_v),
>   故支援滑動關節 —— 既有 `Chain.dynamics_aba` 只支援轉動;每 link 64 float 工作區,不配置)、`artic_step_instance`(半隱式 Euler)、`ArticBatch`(同一模型的多個實例,
>   主機執行);`physics/gpu_artic.mojo`:`GpuArticBatch`(模型 / 狀態 / 工作區常駐裝置,`step(ctx, steps, ...)` 一次啟動跑 `steps` 步 —— 本條「kernel 融合」與
>   「持久裝置狀態」對 articulation 已做;`download` 只在需要時回傳)。
> - `collision/narrow_batch.mojo`:`narrow_pair`(`ColliderSet.pair_manifold` 對 box / sphere / capsule 的分派,同一算術、同一組 `*_manifold` 函式)、
>   `NarrowBatch`(扁平 pair 紀錄);`collision/gpu_narrow.mojo`:`GpuNarrow`(緩衝倍增成長、常駐)。hull / 靜態網格留在 CPU 路徑(可變長資料)。
> - 測試:`test_artic_batch`(11:轉動鏈與 Y 樹 qdd 與 `dynamics_aba` **逐位相同**(差 0.0)、與 CRBA 差 6.5e-6;混合滑動 / 轉動樹與 CRBA 差 4.0e-7;
>   珠子在旋轉桿上的解析解;64 實例互不干擾逐位相同;2 s 軌跡與 `Chain.step` 差 2.4e-7、能量漂移 0.124 J 與 CPU 路徑相同)、
>   `test_narrow_batch`(4:2000 對、9 種有序形狀組合各 ≥ 203 對、806 對接觸,與 `pair_manifold` **逐位相同**;hull 被拒)、
>   `test_gpu_artic` / `test_gpu_narrow`(主機半段本機通過;裝置半段待 GPU 主機)。
> - 開發中發現並修正 `Chain` 的兩個既有錯誤(commit `fix(physics)`):`link_motion` 把滑動關節的速度積項 w × (s_v q̇) 算兩次(轉動父體下的滑塊,
>   θ'' 錯 1.5 倍:−1.4757 vs 解析 −0.98378),`energy()` 把所有關節當轉動(滑塊動能 0.4225 vs 解析 1.4106);`test_joints_lib` 加上解析檢查(修正前 2 項失敗),
>   其他 188 個測試輸出不變。
> - 量測(`bench_gpu_batch`,本機 CPU):articulation 每實例步 `ArticBatch.step_host` 1.66–1.69 µs vs `Chain.step_aba` 4.19–4.44 µs(2.5–2.6×,差在每次呼叫配置約 14 個 List;
>   另一次執行 4.00–6.93 µs,64 實例時波動大);narrowphase 每對 `run_host` 370–404 ns vs `pair_manifold` 368–389 ns(同一函式,僅多扁平化)。裝置列只在有加速器時輸出。
>
> **待辦**:
> - 在 GPU 主機執行 `test_gpu_artic` / `test_gpu_narrow` / `bench_gpu_batch` 的裝置半段,並把量到的數字補進本條
> - 接觸求解器(`GpuContactSolver`)的 kernel 融合與常駐狀態(articulation 已做)
> - narrowphase 接進 `GpuContactSolver`(目前收集仍在 CPU)、hull 上 GPU
> - articulation 的接觸 / 限位(`resolve_contacts` / `resolve_limits`)與浮動基座上裝置
> - 整合交付「GPU 剛體 + CPU 軟體同幀」尚未達成(目前關節 / 軟體 / CCD 場景被 GPU 解算器拒絕)
>
> **歷史**:
> - 原現況(開工前):GPU 只覆蓋布料(4.3 / 6)、broadphase(3.2)、LBVH、raycast;剛體 solver 全在 CPU(islands 多執行緒 6.11)。
> - 上述 82 ms 簿記成本已由 17.19 F22 第一批降到 20.6 ms/幀(GPU 整幀 84.5 → 23 ms)。

---

## 動畫與程序化

範圍:procedural:anim / IK / tween / spline / noise / FSM / PCG。

| 編號 | 條目 | 狀態 | Wave | 說明 |
|---|---|:-:|:-:|---|
| 11.1 | [Noise 家族](ROADMAP_HISTORY.md#111-noise-家族---2026-07-22) | ✅ |  | 新 `procedural/` 套件的 `noise.mojo` 提供純函式、跨機器決定性的 value3、perlin2/perlin3、worley3、fbm2/fbm3(整數格點雜湊,無置換表),附 `bench_noise` 數字。 |
| 11.2 | [狀態機(FSM / HSM)](ROADMAP_HISTORY.md#112-狀態機fsm--hsm--2026-07-22) | ✅ |  | procedural/fsm.mojo 提供資料驅動的階層狀態機:轉移由 leaf 向上冒泡、做 LCA exit/enter、有淺歷史、不用 callback,改把 entered/exited 記錄給 caller 讀,tests/test_fsm.mojo 17/17 通過。 |
| 11.3 | [動畫 runtime(clip / blend / 狀態機驅動)](ROADMAP_HISTORY.md#113-動畫-runtimeclip--blend--狀態機驅動--完成2026-08-11) | ✅ |  | procedural/anim.mojo 提供 AnimClip、三種混合(linear / DLB / geodesic)、可 cross-fade 的 AnimPlayer 與 pose_to_motors,由 FSM 驅動;tests/test_anim.mojo 34 checks,bench_anim 量到每骨每幀 43–157 ns。 |
| 17.3 | [角色 IK](ROADMAP_HISTORY.md#173-角色-ik--wave-b) | ✅ | B | `procedural/ik.mojo` 提供 two_bone、fabrik、fabrik_multi、look_at、foot_plant，有 `test_ik` 27/27(解析 vs FABRIK parity)、`bench_ik`,並接進 `examples/24_locomotion_graph.mojo`。 |
| 17.6 | [動畫圖深度](ROADMAP_HISTORY.md#176-動畫圖深度--wave-b) | ✅ | B | `procedural/anim_graph.mojo` 提供 Pose、BlendSpace1D/2D、層 + 骨骼遮罩、加法動畫(motor 商)、root motion、retarget、暴力 MotionDB，有 `test_anim_graph` 29/29、`bench_anim_graph`,並接進範例 24。 |
| 17.35 | [計時器 / 補間 / 緩動曲線](ROADMAP_HISTORY.md#1735-計時器--補間--緩動曲線--wave-a) | ✅ | A | `scheduler/timers.mojo` 提供 `TimerQueue` seam(`TimerHeap` 與 `TimerWheel`,以 due_tick 加排程序號決定觸發順序),`procedural/tween.mojo` 提供 31 條 Penner 緩動曲線,以及對 Real / Vec3 做 lerp、對 Motor2 / Motor3 走 galie geodesic 的 `Tween`;附 parity 測試、整合測試、兩個 bench,並列在 CATEGORY §2.3。 |
| 17.36 | [樣條 / 曲線(路徑)](ROADMAP_HISTORY.md#1736-樣條--曲線路徑--wave-a) | ✅ | A | `geometry/spline.mojo` 提供維度泛型的 Catmull-Rom(comptime alpha:uniform / centripetal / chordal)與分段三次 Bezier;Catmull-Rom 段會精確轉成 `CubicBezier`,所以弧長表、`closest_point` 與 RMF motor 標架只需實作一次。有三個測試檔共 577 項檢查、`bench_spline` 與範例 15。 |
| 17.64 | [動畫執行期](#1764-動畫執行期--wave-b) | ✅ | B | Animator 狀態圖、clip 事件與同步標記、慣性化轉場(inertialization)、無配置求值、進 ECS / Runtime 的組裝、動畫狀態入快照 / 回放 |
| 17.65 | [形變資料](#1765-形變資料--wave-cheadless-資料--邏輯) | 🔶 | C | N 影響蒙皮、綁定資料、Morph targets / blend shapes、修正形狀(pose-space deformation)、縮放 / 擠壓伸展通道、蒙皮 → 模擬耦合 |
| 17.69 | [PCG](#1769-pcg--wave-c) | 🔶 | C | 點分佈、地形生成、結構 / 關卡、2D Voronoi / Delaunay、等值面抽取、決定論契約 |

### 已完成條目的遺留待辦

這些條目已完成並移到歷史檔,但各自記下了尚未做的部分:

- **11.1**([紀錄](ROADMAP_HISTORY.md#111-noise-家族---2026-07-22)):Simplex 跳過(專利 + 複雜),OpenSimplex2 留後續
- **11.1**([紀錄](ROADMAP_HISTORY.md#111-noise-家族---2026-07-22)):SIMD 批次採樣留後續優化(目前為 scalar)
- **17.3**([紀錄](ROADMAP_HISTORY.md#173-角色-ik--wave-b)):關節角度限制(膝只能單向、肩錐)
- **17.3**([紀錄](ROADMAP_HISTORY.md#173-角色-ik--wave-b)):IK 結果轉回逐骨旋轉寫入 `Pose`
- **17.3**([紀錄](ROADMAP_HISTORY.md#173-角色-ik--wave-b)):全身 IK 的質心 / 平衡約束
- **17.6**([紀錄](ROADMAP_HISTORY.md#176-動畫圖深度--wave-b)):姿勢改用預配置緩衝(現每節點配置 `List`)
- **17.6**([紀錄](ROADMAP_HISTORY.md#176-動畫圖深度--wave-b)):方向性(polar)2-D blend space
- **17.6**([紀錄](ROADMAP_HISTORY.md#176-動畫圖深度--wave-b)):骨架階層世界矩陣組合(範例以局部 motor 直接蒙皮)
- **17.6**([紀錄](ROADMAP_HISTORY.md#176-動畫圖深度--wave-b)):motion matching 加速結構(目前暴力最近幀)
- **17.6**([紀錄](ROADMAP_HISTORY.md#176-動畫圖深度--wave-b)):動畫圖節點圖存檔：目前只有程式碼定義，須經 17.12 資產格式(編輯器需求表)

### 待辦與部分完成條目

#### 17.64 動畫執行期 — Wave B
> **狀態**:✅ 完成(2026-10-14:Animator 狀態圖、clip 事件與同步標記、慣性化轉場(seam,含 motor 空間)、預配置緩衝、值型別快照、`gameplay.animator`
> 與 `Runtime` 組裝(root motion、事件進 `Channel`)、`SimState` 帶動畫狀態、clip 關鍵幀精簡 ✅)。
> **進度註(2026-10-13)**:`procedural/anim_events.mojo` `EventTrack.fire(t0, t1, length, loop)`:半開區間 [t0, t1) 的「每次經過恰一次」(迴圈內每圈一次、非迴圈末端事件一次、倒放用 (t1, t0]);
> `marker_phase` / `sync_time` 依同步標記對齊不同長度的 clip。`procedural/inertialize.mojo` `Inertializer`:切換時記錄每骨位移與旋轉殘差,以五次多項式衰減(兩端斜率 0),結束後不再套用(逐位等於目標)。
> `procedural/anim_state.mojo` `AnimGraph`:float / bool / trigger 參數(trigger 被用到即清除)、條件轉場(任意來源、exit time、時長、`tween` 緩動、可否打斷)、`TRANS_FADE` / `TRANS_INERTIAL`、
> 事件只由目前狀態的 clip 觸發、所有姿態緩衝在建構時配置;是值型別,複製即快照。
> 量測(`tests/test_anim_runtime.mojo` 14/14):0.31 s 的腳步事件在 10 s 內,tick 1/60 s、0.3 s 或一次跳 10 s 都恰 10 次,速率 2 時 20 次,倒放經過 1 次;邊界事件只發一次;
> walk 0.25 / 0.75 對到 run 0.15 / 0.45;參數驅動 idle → walk → run → jump(trigger,不可打斷)→ idle(exit time);兩種轉場結束後都逐位等於目標 clip;慣性化切換那一 tick 位置跳 3.4 mm
> (一個 tick 的行走位移);轉場中複製的圖續跑逐位相同。bench `bench_anim_runtime`(100 角色 × 32 骨,ns / 角色):轉場佔比 0 % 淡入 4187 / 慣性化 3725、50 % 7227 / 6326、100 % 12132 / 6478。
> **進度註(2026-10-14)**:`gameplay/animator.mojo`:`AnimatorRef[ID]` 元件指向 `Animators` 表(圖不能隱式複製,如 body 住在場景),`AnimLibrary`(clip + 事件軌);
> `tick_animators(runtime, animators, library, dt, channel)` 推進每個動畫、事件以 `AnimEvent(entity, id)` 送進 `Channel`、有 root bone 與 `RigidBodyRef` 時把根骨位移
> (`root_motion`,跨 loop,轉到 body 座標)變成 body 的水平速度並自姿勢剝除。`SimState.anims`:入快照、還原、進 checksum(無動畫時不變,`test_replay` 與 golden 相同)。
> `procedural/anim_compress.mojo`:`reduce_clip(clip, pos_tol, rot_tol)` 逐骨逐通道只留內插誤差超限所需的關鍵幀,`ReducedClip.sample` 時間映射同 `AnimClip`;
> 角度用弦長式 4 asin(|a ∓ b| / 2)(2 acos(|a·b|) 在 f32 下相同四元數也讀出 7e-4 rad)。首版巢狀 while / for + break 讓 Mojo 1.1 編譯器卡 5 分鐘以上,改成輔助函式提前 return 後 5 秒編完。
> `Inertializer(bones, INERT_MOTOR)`:殘差為單一剛體運動 M_src M_dst⁻¹,沿其螺旋衰減。
> 量測:`tests/test_animator.mojo` 7/7(1 m/s 走路 clip 3 秒推箱 2.99997 m;轉 90° 時沿 −z;0.5 s 腳步事件 3 次且標記實體;速度 2 的動畫事件加倍;轉場途中快照還原 checksum 相同);
> `tests/test_anim_compress.mojo` 5/5(2 秒走路 726 → 60 鍵,10164 → 1096 bytes,500 個非幀時間最大誤差 0.99 mm / 0.48°;容差 0 逐幀相同);
> `tests/test_inertialize_motor.mojo` 4/4(繞樞軸 90° 回彈到一半,motor 距樞軸 1.0、分開式 0.707;純平移與繞原點旋轉兩者一致)。
> `bench_anim_runtime`:精簡 clip 取樣 2648 vs 2685 ns(32 骨);全員轉場時 motor 空間 372 vs 分開式 193 ns / 骨。commit 7001aeb、a0aa2f7、d30dbd6、bd53fb5。
> **現況**:積木齊、**組裝層缺**。`procedural/anim.mojo:46` `AnimClip`(等間隔取樣)與 `:117` `sample`;`:243-322` `AnimPlayer` 只做「一個 clip 淡入另一個」,`evaluate` 在淡入期間每次呼叫配置 4 個 `List`(`:294-322`;非淡入時取樣後即 return)。圖節點(`procedural/anim_graph.mojo:122` `BlendSpace1D`、`:174` `BlendSpace2D`、`:243` `layer`、`:258-278` additive、`:284` `root_motion`、`:326` `retarget`、`:346` `MotionDB`、`:405` `to_world`)是**自由函式或只存參數 / 特徵的資料 struct**(`BlendSpace1D/2D`、`MotionDB` 無播放狀態)——沒有「圖」這個物件,呼叫端每幀手寫整條管線(`examples/24_locomotion_graph.mojo:94-133` 一個 240 幀迴圈裡手接 `fsm.fire` → `sample_phase` → `layer` → `root_motion` → `skin_motor` → `foot_plant` → `two_bone`)。`procedural/fsm.mojo:18` `StateMachine` 只吃整數事件(`:96` `fire(event: Int)`),沒有參數條件、退出時間、逐轉場的混合時長 / 曲線。**沒有 Animator**:grep `AnimPlayer|anim_graph|procedural\.` 於 `gameplay/ ecs/ scheduler/ collision/ physics/` 只命中 `gameplay/ragdoll.mojo:23,34`(吃 `Pose`);`gameplay/runtime.mojo`(`:70-101`)grep `CharacterController|Vehicle|Ragdoll|AnimPlayer` 零命中,動畫狀態不在 `Runtime`、不在 `gameplay/replay.mojo:38-49` `SimState`(場景 + 控制器 + RNG),所以動畫驅動的位移 / 碰撞體不可重播、不入快照。clip 事件:grep `notify|AnimEvent|anim_event|sync.?group|inertial` 於 `procedural gameplay geometry ecs scheduler` 與 anim 測試零命中;匯入 / 壓縮:grep `gltf|quantiz|keyframe_reduce` 同範圍零命中;蒙皮調色盤:grep `inverse.?bind|bind.?pose` 零命中(`geometry/skinning.mojo:57-68` `skin_motor` 吃已算好的 bone motor 與兩個骨索引)。層級限制:`procedural` 是層 2(`scripts/arch_layers.toml:1-14`、`docs/ARCHITECTURE.md:20`),不能 import `scheduler`(層 3)或 `ecs`(同層),故 `Animator` 元件與系統只能落在 `gameplay`(層 5),`procedural` 端只產純資料。
> **缺口**:
> - **Animator 狀態圖**:參數塊(float / bool / trigger)+ 帶條件的轉場(`speed > 0.1`、退出時間、可打斷規則)+ 逐轉場混合時長與緩動(重用 `procedural/tween.mojo:63-94` 的 31 條曲線),把 `StateMachine` / `BlendSpace*` / `layer` 組成一個可每 tick 求值的物件(例:idle→run 0.15 s cubic-out,跳躍可打斷)。
> - **clip 事件與同步標記**:以 clip 時間戳記的事件(腳步 0.31 s、揮擊有效幀 8–14),在 tick 區間內**恰好觸發一次**(含 loop 迴繞、播放速率改變、被混合權重 0 略過時的處理規則)—— 這個「區間恰一次」
>   語意做成本條擁有的共用 `EventTrack` 原語(層 2 `procedural`),17.68 的序列事件軌直接重用;同步標記讓不同週期的 walk / run 依「左腳著地」對齊(17.6 只有正規化相位)。
> - **慣性化轉場(inertialization)**:轉場時不同時取樣兩個 clip,而是把「轉場瞬間的姿態差」存成殘差並衰減(Bollinger, GDC 2018);殘差在 motor 空間以 geodesic 衰減。單一 clip 取樣 / 轉場 vs 現有淡入(兩次取樣 + 混合)。
> - **無配置求值**:預配置 pose 緩衝與依賴序求值(17.6 待辦「姿勢改用預配置緩衝」,ROADMAP §17.6),1e4 角色不得每幀配置。
> - **進 ECS / Runtime 的組裝**:`gameplay` 的 `Animator` 元件 + 系統,輸出骨 motor(經 `ecs/motor_transform.mojo:9-12` 的剛體階層,骨骼是其明列用途)並每 tick 呼叫 17.65 的蒙皮調色盤計算(調色盤與逆綁定資料歸 17.65 擁有,本條只負責呼叫時機);事件寫入 `scheduler/events.mojo` 的 `Channel`;root motion 以速度交給 17.1 控制器(17.6 範例已證可行,缺正式 API)。
> - **動畫狀態入快照 / 回放**:時間以 tick 計(不用牆鐘)、狀態為值型別,納入 6.10 / 17.39 的 `SimState` 與逐 tick 雜湊(`gameplay/replay.mojo:86`),轉場途中快照→還原→續跑逐位相同。
> - **clip 儲存變體**:均勻取樣原始 vs 量化 + 分段壓縮(ACL 式,誤差界以最大骨端點誤差表示)。
> **對照組**:UE AnimGraph / Anim Notifies / Sync Groups / Inertialization(UE5)、Unity Animator + Playables、Godot AnimationTree、ozz-animation(SoA 批次取樣)、ACL(Animation Compression Library)、Bollinger 慣性化(GDC 2018)。
> **優勢區**:中 ——(a)慣性化在轉場中的角色比例高(群眾切換、戰鬥)時每角色只取樣一個 clip,理論上省掉淡入的第二次取樣(11.3 量到淡入中 170 ns/骨 vs 單 clip 51–60 ns/骨,ROADMAP §11.3);**依優勢區規則,兩側都量**:轉場佔比 0–100 % 掃描,不只量常態。(b)殘差衰減與 additive 同走 PGA motor geodesic(`anim_graph.mojo:267`),無 gimbal。(c)固定 tick + 決定論快照 ⇒ 動畫姿態可做伺服器端命中驗證與逐位重播(對照組多為牆鐘驅動、不保證重現)。
> **規模軸**:角色數 N(1e2–1e4)× 骨數(32–256)× 同時轉場比例;圖節點數;事件密度(每 clip 事件數 × 角色數);clip 記憶體 vs 壓縮誤差界。
> **seam?**:是 ——(1)轉場實作:淡入(現狀)vs 慣性化 → parity:轉場完成後姿態逐位等於目標 clip、轉場起點連續(t=0 等於來源姿態)、權重 / 殘差為 0 時退化為單 clip;bench 掃轉場佔比。(2)clip 儲存:均勻原始 vs 量化壓縮 → 取樣姿態差 ≤ 設定誤差界;bench 取樣 ns/骨與位元組。
> **交付**:`procedural/anim_events.mojo`(事件抽取、同步標記)、`procedural/inertialize.mojo`、`procedural/anim_state.mojo`(參數 + 條件轉場)、`gameplay/animator.mojo`(`Animator` 元件 / 系統)。測試:普通(參數驅動 idle→walk→run、事件每次恰一發、慣性化終點 == 目標 clip)/ 整合(`Animator` 掛進 `Runtime`,root motion 走 17.1 控制器、骨 pose 餵 17.2 `Ragdoll.follow` 與 17.3 IK、事件經 `Channel` 被 17.71 命中窗口消費、`SimState` 含動畫狀態後 `first_divergence` 無分歧、轉場中途快照還原逐位相同)/ 極端(事件剛好落在 loop 邊界與 `dt` 邊界、零長轉場、轉場被打斷 1000 次、NaN 參數、單幀 / 零幀 clip、負播放速率、`dt = 0`、1e4 角色、權重全 0)。`bench_animator` 每個 seam 一列 + 範本一列。
> **相依**:17.6(已交付,節點庫)、17.3、17.2、17.1、17.35(緩動)、17.38(事件通道)、17.39 / 17.40(狀態入快照)、17.11(參數反映)、17.65(蒙皮資料)、17.85(動畫更新頻率分級由其 `period` 決定,本條只留可被分頻的接口)。
> **邊界**:骨架 / clip 的匯入與 DCC 製作屬宿主(17.12 決定跟 glTF / USD 走,引擎只收 flat arrays);GPU 蒙皮與繪製屬宿主;動畫圖編輯器 UI 屬編輯器;腳步音效 / VFX 由宿主訂閱事件;距離分級的更新頻率歸 17.85,不在此重複。

#### 17.65 形變資料 — Wave C(headless 資料 / 邏輯)
> **進度註(2026-10-13)**:`geometry/skinning.mojo`:`blend_k`(K 骨 DLB,各骨對第一骨取半球、全 0 權重 → 恆等)、`skin_motor_k` / `skin_lbs_k`
> (SoA `idx[v*K+j]` / `w[v*K+j]`,邊界一次驗證索引與長度並 raise;LBS 權重重正規化)、`bind_palette`(世界 × 逆綁定)、`inverse_bind`;K = 2 與 `skin_motor`
> 共用一個 `@no_inline` 的逐頂點函式 —— 分別內聯時同一式子在 500 頂點中有 41 個末位不同(最大 3.1e-7),共用後逐位相同,`test_skinning` / `test_anim` 輸出不變。
> `geometry/morph.mojo` `MorphSet`(稀疏 delta、`from_shape`、權重不夾制、先 morph 後蒙皮)。量測(`tests/test_skin_k.mojo` 13/13):K = 1 等於該骨;
> 全骨同一運動時 DLB / LBS 誤差 4.9e-7;綁定姿態調色盤誤差 6e-8、全骨上抬 1 m 誤差 2.5e-7;4 骨 0..170° 扭轉:DLB 半徑 0.2(不變)、LBS 0.097;
> q 與 −q 相同;NaN 骨只污染自己的頂點。`bench_skin_k`(4096 頂點、與 gate 同時執行):DLB K = 2 / 4 / 8:66 / 103 / 96 ns,LBS 18 / 31 / 60 ns;
> morph 每頂點 3.8 ns(60 個中 6 個啟用)。
> **進度註(2026-10-17)**:`MorphSet.add_target_n` / `apply_normals`(法線 delta,結果正規化,零長度保留原法線;`apply` 函式體不動)、`InbetweenMorph`(遞增權重的稀疏形狀、自 0 起分段線性、末段外插;單一形狀於 1 時與一般目標一致)、`geometry/pose_space.mojo` `PoseSpaceRbf`(高斯 RBF,f64 部分選主元消去,重複樣本 raise)、`skin_motor_k_scaled`(逐骨縮放繞綁定關節中心,權重混合後再 DLB;全為 1 時直接走 `skin_motor_k`,逐位相同)、`gameplay/skin_link.mojo`(`animator_palette`:`Animators` 槽 → `to_world` → `bind_palette`;`pin_cloth_to_skin`;`fit_bone_boxes` / `fit_bone_capsules` 由蒙皮權重 ≥ 門檻的頂點在骨綁定座標系擬合,盒的 (half, offset) 正是 `Ragdoll` 的參數)。量測:`tests/test_morph_ext.mojo` 12/12(RBF 0 / 60 / 120° → −8.4e-10 / 0.3 / 0.99999994,90° → 0.741;壓扁 (1, 0.5, 1) 於 y = 1:1.5 → 1.25、2.0 → 1.5);`tests/test_skin_link.mojo` 6/6(綁定姿態調色盤位移 0.0;骨 1 轉 90°:(0, 2.4, 0) → (−1.0000002, 1.4000003, 0);圓柱擬合骨 0 盒 half (0.2, 0.45, 0.2)、膠囊半徑 0.2、軸 y 0.2..0.7;由擬合盒建的 ragdoll 1 s 後骨 1 位於 y 2.3997);`tests/test_skin_vectors.mojo`:6 骨、64 頂點、K = 4 的 DLB / LBS 參考輸出與 FNV 校驗和(十進位印出:DLB 3039826071626799574、LBS 11624641202192189416;golden 過濾器把「數字後接 x」當成倍率行丟掉,0x… 形式曾因此沒進 golden)寫入 golden,供宿主 shader 比對。既有 `test_skin_k` / `test_skinning` / `test_anim` / `test_animator` / `test_ragdoll` golden 不變。
> **第三批(2026-10-17)**:DIB(`blend_k_iter` / `skin_dib_k`,Kavan 2008 在 motor 李群上:m ← m exp(Σ w log(~m M_j)),起點為投影到 motor 流形的 DLB)。量到 DLB 的重新正規化只縮放轉子,平移部分違反 s pss = b12 b30 − b13 b20 + b23 b10(兩骨例殘差 −0.179);這不影響 `apply_point`(投影前後點差 4e-8),但 log / exp 會讀到,未投影時 DIB 停在離 geodesic 中點係數差 0.26 處;投影後兩骨 0.5 / 0.5 的 DIB 與 `geodesic3` 中點係數差 1.8e-7、點差 2.5e-7(DLB 點差 6.0e-7);DLB 路徑不改(golden 不變)。0..170° 扭轉:DIB / DLB 最小半徑 0.2、LBS 0.176。關節角座標:`rotation_angle`、`joint_angle`、`twist_angle`(swing–twist;swing x 30° × twist y 50° 量到 50.000004°)。`pin_softbody_to_skin`:`SoftBody.predict` 對 w = 0 的粒子也加重力(`test_continuum` / `test_error_wiring` 依賴此行為),故釘點在柔體步驟之後施加;3³ 晶格頂層 9 點釘住 1 s,底部吊在下方 0.206 m(靜止 0.2)。另見 `SoftBody.momentum` 以 v / w 計,w = 0 時為 inf(未修)。`tests/test_skin_dib.mojo` 8/8。`bench_skin_k` 第二表:DLB K=4 67 ns、DIB(≤ 10 次)2347 ns / 頂點;1e6 頂點 DLB 67.4 ns、LBS 32.0 ns / 頂點(與 4096 頂點同,線性)。
> **未做**:FEM 體積柔體的蒙皮釘點、`SoftBody` 的 w = 0 語意與 momentum 除零。
> **現況**:`geometry/skinning.mojo:39-68` 只有**每頂點 2 個影響**:`blend2` 做兩個 motor 的 DLB,`skin_motor(bones, rest, idx_a, idx_b, w_a, out)` 以 `w_b = 1 − w_a` 取權重;`:71-89` `skin_lbs`(Mat4 LBS)為對照基準。成本 DLB ≈ 40 vs LBS ≈ 9.5 ns/頂點(檔頭 `:11-16` 自註)。motor 是剛體運動、無縮放(`ecs/motor_transform.mojo:9-12`)。**形變資料全缺**:grep `\bmorph|[Bb]lend.?[Ss]hape|MorphTarget|pose.?space|corrective` 全樹(`.mojo`,排除 build/.pixi/worktrees)零命中;grep `inverse.?bind|bind.?pose` 零命中。`skin_motor` / `skin_lbs` 只被測試 / 範例 / bench 呼叫(`tests/test_skinning.mojo:77`、`tests/test_anim.mojo:159`、`benchmarks/bench_ga.mojo:141`、`examples/07_motor_skinning.mojo:66`、`examples/24_locomotion_graph.mojo:124`),引擎套件只借用 `blend2` 做姿態混合(`procedural/anim.mojo:39,205`),沒有任何套件消費蒙皮後的頂點:柔體 / 布料(`physics/softbody.mojo`、`physics/vbd_cloth.mojo`)不能把頂點釘在蒙皮骨上,17.2 的 ragdoll 碰撞體是每骨一個手給的盒(`gameplay/ragdoll.mojo:37-68`)。引擎無渲染層,故本條的存在理由是**模擬端與宿主 GPU 之間的資料契約**,不是繪製。
> **缺口**:
> - **N 影響蒙皮**:每頂點 4 / 8 個 (索引, 權重),SoA 佈局,重新正規化,K=2 時逐位退化為現有 `skin_motor`(例:肩部 4 骨影響)。
> - **綁定資料**:逆綁定 motor、`世界骨 motor × 逆綁定` 調色盤輸出(宿主 shader 的輸入)。
> - **Morph targets / blend shapes**:稀疏 delta(位置 + 法線)、權重、in-between;次序固定為 morph → skin(例:臉部 60 個 shape 中同時啟用 6 個)。
> - **修正形狀(pose-space deformation)**:以關節角 / motor 距離為座標的 RBF 修正(例:肘彎曲 120° 時的體積補償)。
> - **縮放 / 擠壓伸展通道**:motor 無縮放,以側通道承載逐骨 scale(例:卡通 squash & stretch)。
> - **蒙皮 → 模擬耦合**:蒙皮後頂點作為柔體 / 布料(17.56)的 kinematic 目標、由蒙皮權重擬合每骨碰撞膠囊(取代 ragdoll 手給盒)。
> - **宿主參考實作**:本條的 CPU 結果就是宿主 GPU shader 的 oracle(附 golden 向量,宿主端驗證自己的 shader)。
> **對照組**:UE Skeletal Mesh(LBS、4 / 8 影響、Morph Targets、corrective)、Unity SkinnedMeshRenderer(blendShapes)、Kavan 2007 雙四元數蒙皮、Lewis 2000 pose space deformation、glTF skins / morph targets 規格(`JOINTS_0` / `WEIGHTS_0`,宿主匯入格式)、SSDR(蒙皮分解)。
> **優勢區**:中 —— DLB 在 motor 流形上已能避免 candy-wrapper(`tests/test_skinning.mojo` 與範例 07),LBS / DLB / DIB(dual-quaternion iterative blending,Kavan 2008)是**可比較**的三種蒙皮,體積保持 vs 成本是現成的量測軸;蒙皮可微(AD 同一表示)⇒ 以梯度擬合權重 / 修正形狀(SSDR 類),對照組為離線 DCC 工具。**未量測前不下結論**。
> **規模軸**:頂點數 N(1e3–1e6)× 影響數 K(2 / 4 / 8)× 啟用 morph 數 M;ns/頂點(基準:上述 40 / 9.5 ns);調色盤上傳位元組 vs 骨數。
> **seam?**:是 —— 蒙皮方法族(LBS / DLB / 全雙四元數)× 影響數 K:parity 條件 =(a)全骨同一剛體運動時三者結果相同、(b)K=2 與現有 `skin_motor` 逐位相同、(c)單一影響時等於該骨 motor;差異(180° 扭轉的體積)寫成行為斷言;bench 每方法一列。
> **交付**:`geometry/skinning.mojo` 擴充 K 影響與 `geometry/morph.mojo`;`gameplay` 端蒙皮 → 柔體釘點。測試:普通(K=4 對手算、morph 單 shape 權重 1 == 目標形狀)/ 整合(17.64 `Animator` 調色盤 → 蒙皮 → 布料頂點跟隨骨;由權重擬合的膠囊接 17.2 ragdoll;K=2 與舊路徑逐位相同)/ 極端(權重和 ≠ 1、全 0 權重 → 綁定姿態、`q` 與 `−q` motor、NaN 骨、骨索引越界(邊界驗證一次並 raise)、0 頂點、1e6 頂點、morph 權重負 / > 1、1e5 稀疏 delta)。
> **相依**:17.64、17.6、17.56(布料釘點)、17.57 / 17.58(毛髮 / 體積軟體的蒙皮目標)、17.66(膠囊擬合)、12.1(資料佈局契約)。
> **邊界**:繪製、GPU 蒙皮 shader、網格 / rig 的製作與匯入屬宿主 —— 宿主接手點是「調色盤 + morph 權重緩衝」;權重繪製 / rig 工具屬 DCC。

#### 17.69 PCG — Wave C
> **進度註(2026-10-13)**:`procedural/scatter.mojo`(`poisson_disk` Bridson、`dart_throwing`、`jittered_grid`、`thin`、`min_distance`;亂數取自 `noise._hash`,
> 不需 RNG 下沉)、`procedural/delaunay.mojo`(Bowyer–Watson + 精確 `orient2d` / `incircle`、重複點略過、`is_delaunay`)、`procedural/terrain_gen.mojo`
> (`TerrainParams`、`terrain_height` 為世界座標的純函式:fBm / ridged / domain warp;`height_tile` 產 `HeightField` 頂點陣列;`thermal_erosion` 質量守恆;`max_slope`)。
> 量測(`tests/test_pcg.mojo` 13/13):Poisson 100×100、r = 2:1614 點、最小距 2.00002;dart 5000 次 1186 點;抖動格最小 1.036;同 seed 逐位相同;
> 400 點 Delaunay 784 三角形 = 2n − 2 − h(h = 14);正 12 邊形 + 中心 12 個、6×6 格點 50 個(全共圓)皆 Delaunay;共線 0、重複略過;相鄰圖塊邊逐位相同;
> 侵蝕 400 次最大坡度 2.92 → 0.80000097、總高度 288.16944 → 288.16949;箱子落在生成的 `HeightField` 上靜止。
> `bench_pcg`:Poisson 5.3 µs / 點、dart 1.5 µs、抖動格 16 ns;Delaunay 250 / 500 / 1000 點每點 12.7 / 21.6 / 43.6 µs(空腔搜尋線性 → 整體 O(n²));
> 地形取樣 116 ns(fBm 5 層)/ 257 ns(warp);侵蝕 84 ns / 格·次。
> **未做**:WFC、BSP / 迷宮 / L-system、等值面抽取(marching cubes)、水力侵蝕、Delaunay 點定位走訪、分治 Delaunay parity、圖塊平行、依坡度散佈、`WorldPartition` 接線。
> **現況**:只有**雜訊原語且無人使用**。`procedural/noise.mojo:72` `value3`、`:102` `perlin3`、`:133` `perlin2`、`:151` `worley3`、`:181` `fbm3`、`:198` `fbm2`,皆為 `(座標, seed)` 的純函式(整數格點雜湊 `:19`,無 RNG 狀態),可決定論重現。grep `fbm2|fbm3|perlin|worley` 全樹只命中 `procedural/noise.mojo`、`tests/test_noise.mojo`、`benchmarks/bench_noise.mojo`——**沒有任何生成器 / 地形 / 引擎路徑呼叫它**(孤島,雖有測試與 bench)。生成演算法:grep `WFC|wave.?function|poisson.?disk|blue.?noise|L.?system|maze|dungeon|erosion|Delaunay|marching.?cubes|isosurface` 於 `geometry collision procedural spatial numerics ecs scheduler gameplay physics fluid examples experiments tests benchmarks` 零命中;唯一的 Voronoi 是 3D **凸體切割**(`geometry/fracture_cut.mojo:6,169`,破碎用,非 2D 圖 / 非 Delaunay)。可接的下游:`collision/trimesh.mojo:215` `HeightField`(建構吃 `List[Real]` 高度,`:288` `set_height`、`:295` `deform`、`:321` `bounds_blocks`,17.30)與 `physics/solver6.mojo:355` `add_heightfield`;穩健幾何 `geometry/predicates.mojo:175` `orient2d`、`:292` `incircle` 已有(Delaunay 的前提)。層級限制:`procedural` 層 2 不能 import `scheduler.rng`(層 3,`scripts/arch_layers.toml:1-14`;`scheduler/rng.mojo:79` `Pcg32`),故新演算法應像 noise 一樣吃整數 seed + 雜湊,或把 `Rng` 下沉(需改 `arch_layers.toml`,是一個要決定的設計點);輸出 `HeightField` 需 `collision`(層 3),所以 `procedural` 只產 flat 陣列,由呼叫端建場。
> **缺口**:
> - **點分佈**:Poisson-disk(Bridson 2007)/ 密度圖加權(例:1 km² 內 1e5 棵樹、最小間距 r、依坡度過濾)。
> - **地形生成**:fBm + domain warp + ridged / billow、熱 / 水力侵蝕(Musgrave 1989 / Mei 2007),直接寫成可碰撞的 `HeightField`;圖塊獨立生成,邊界逐位連續(純雜湊的優勢)。
> - **結構 / 關卡**:BSP 房間走廊、迷宮(生成樹)、L-system、Wave Function Collapse(Gumin;含傳播與回溯)、輸出格 + 鄰接,餵 17.14 導航烘焙。
> - **2D Voronoi / Delaunay**(Bowyer–Watson,走 `orient2d` / `incircle` 的精確謂詞)作生態區 / 聚落分區。
> - **等值面抽取**(marching cubes / surface nets / dual contouring)從 SDF / 密度到 `add_trimesh` 的碰撞網格(洞穴、可挖地形;與 17.45 的 mesh→SDF 互逆)。
> - **決定論契約**:同 `(seed, params)` ⇒ 逐位相同輸出,且與生成順序 / 圖塊順序無關;快照存 seed + params 而非資料(接 17.40)。
> **對照組**:Houdini heightfield 侵蝕與 WFC、UE PCG Framework / Landscape、Unity Terrain、Godot FastNoiseLite、Gumin WFC、Bridson 2007、FastNoise2(SIMD 批次)、libnoise。
> **優勢區**:中 ——(a)純雜湊雜訊 ⇒ 圖塊平行生成與順序無關,核數擴展不影響結果(對照組多依賴執行緒排序);(b)與 `HeightField` / `trimesh` 同庫,生成物即碰撞物,無匯入轉換;(c)精確謂詞使 Delaunay 在共圓 / 共線輸入下不崩。**待量測**:雜訊吞吐以 `bench_noise` 為基準。
> **規模軸**:輸出尺寸(高度場 1024²–8192²、點數 1e5–1e7、WFC 格 64²–512²)× 核數(圖塊平行);雜訊 ns/樣本;侵蝕迭代數。
> **seam?**:是 ——(a)點分佈取樣器:Bridson Poisson-disk vs dart-throwing vs 抖動格 → 凡宣稱最小間距者最小距離不變式成立,並量藍雜訊品質(最小距離 / 功率譜);(b)Delaunay:增量 Bowyer–Watson vs 分治 → 三角剖分相同(共圓並列除外),bench 每變體一列。
> **交付**:`procedural/scatter.mojo`、`procedural/terrain_gen.mojo`、`procedural/wfc.mojo`、`procedural/delaunay.mojo`、`geometry` 等值面。測試:普通(同 seed 兩次 == 逐位相同、點間距 ≥ r)/ 整合(生成高度場 → `add_heightfield`,箱子落上並入睡;依坡度用 `ray_cast` 散佈;WFC 輸出轉碰撞體;迷宮餵 17.14)/ 極端(WFC 矛盾與回溯耗盡、0 種圖塊、1×1 格、密度 0、間距 > 區域、重合 / 共線 / 共圓點、負 seed 與 ±2³¹ 座標處圖塊接縫、1e7 點)。
> **相依**:17.30、17.36(道路)、17.14(導航輸入)、17.45 / 17.52(SDF)、17.40(存 seed)、10.1 謂詞、`scheduler/jobgraph.mojo`(圖塊平行)、17.8(world partition cell 為生成單位)。
> **邊界**:貼圖 / 材質混合繪製、植被實例化繪製、美術圖塊內容與任務 / 敘事內容生成屬宿主與內容端;編輯器內的筆刷工具屬編輯器。

---

## 角色、載具、破壞與 gameplay 物理

範圍:gameplay:character / ragdoll / vehicle / fracture / interpolation。

| 編號 | 條目 | 狀態 | Wave | 說明 |
|---|---|:-:|:-:|---|
| 17.1 | [Kinematic 角色控制器](ROADMAP_HISTORY.md#171-kinematic-角色控制器--wave-a) | ✅ | A | `gameplay/character.mojo` 的 `CharacterController` 以 capsule sweep 做 move-and-slide,支援台階、斜坡上限、天花板、移動平台速度繼承、推擠動態剛體、擠出、蹲伏與 teleport;空地每次 update 約 3.5 µs,256 個障礙約 33 µs。 |
| 17.2 | [主動布娃娃 / 物理動畫](ROADMAP_HISTORY.md#172-主動布娃娃--物理動畫--wave-b) | ✅ | B | `physics/joints6.mojo` 的 `AngularDrive`(Box2D v3 軟係數姿態驅動、`max_torque` 上限)與 `gameplay/ragdoll.mojo` 的 `Ragdoll`(逐骨遮罩部分布娃娃、follow / set_strength / hit / blend_world 起身過渡)已交付，有 `test_ragdoll` 13/13 與 `bench_ragdoll`。 |
| 17.4 | [載具動力學](ROADMAP_HISTORY.md#174-載具動力學--wave-c) | ✅ | C | `gameplay/vehicle*.mojo` 提供以 impulse 驅動 ContactScene6 底盤的載具：懸吊、隱式 Pacejka 輪胎與摩擦橢圓、引擎 / 變速 / 三種差速、ABS / TC、Aero，以及 `WheelCast` seam(射線 / 球掃 / 膠囊掃)和 LBM 風洞 Cd 回饋，有 4 個測試檔和 `bench_vehicle`。 |
| 17.5 | [破壞 / 破碎](ROADMAP_HISTORY.md#175-破壞--破碎--wave-c) | ✅ | C | 已交付凸多面體 / 凸分解 seam(Split / Cluster)/ Voronoi 預切與多平面執行期切割(geometry)、JOINT_WELD 和 `physics/fracture.mojo` 的 `FractureSet`(生成、鍵結、斷裂事件、碎片預算、執行期切割),並順帶修正不規則 hull 沉陷，有 5 個新測試檔和 `bench_fracture`。 |
| 17.7 | [固定步 ↔ 繪製率解耦的狀態插值](ROADMAP_HISTORY.md#177-固定步--繪製率解耦的狀態插值--wave-a) | ✅ | A | `gameplay/interpolation.mojo` 提供每 body 前一 / 當前 tick 姿態環 `PoseHistory`(含 `mark_teleport`)與插值子 seam `LerpNlerp` / `DqNlerp` / `MotorGeodesic`,`Runtime.render_pose` 依 `loop.alpha` 取繪製姿態,經 test_interpolation 21/21、test_system_render 5/5 與 bench_interpolation 驗證。 |
| 17.27 | [力場 / 區域效果](ROADMAP_HISTORY.md#1727-力場--區域效果--wave-b) | ✅ | B | physics/fields.mojo 提供 ForceField(重力區 / 徑向 / 風 / 阻尼)與 apply_fields:重力區以逐 body 重力覆寫 BodySet.grav 實作,風速可取自 WindGrid(三線性),並以常數網格 == 常數風逐位作為 seam parity。 |
| 17.28 | [浮力 / 水體積](ROADMAP_HISTORY.md#1728-浮力--水體積--wave-b) | ✅ | B | WaterVolume + apply_buoyancy 以 ρ g V_sub 施於浮心並加隱式線性 / 角阻尼,浸沒體積有球解析、盒取樣積分與軸對齊盒閉式解,取樣 vs 閉式為 seam parity。 |
| 17.66 | [物理角色](#1766-物理角色--wave-c) | 🔶 | C | 平衡控制、物理驅動移動、動態角色本體、模式狀態機、抓取 / 攜帶、ragdoll 質量與限制 |
| 17.67 | [移動模式](#1767-移動模式--wave-b) | 🔶 | B | 模式機、加速度模型、跳躍手感、任意向上軸、外部速度 / 衝量累加器、移動平台完整繼承 |
| 17.68 | [攝影機 / 序列](#1768-攝影機--序列--wave-bheadless-資料--邏輯) | ✅ | B | 鏡頭資料與 rig、鏡頭混合與優先序、震動、視錐數學(模擬端用途)、序列 / 時間軸 |
| 17.71 | [戰鬥物理](#1771-戰鬥物理--wave-b) | ✅ | B | 受擊 / 攻擊體積、近戰掃掠、hitscan 與穿透 / 跳彈、彈道投射物、爆炸、受擊反應 |
| 17.74 | [載具家族](#1774-載具家族--wave-c) | 🔶 | C | 履帶車、水上載具、飛行器、懸浮 / 推進器陣列、機車 / 自行車、通用服務 |

### 已完成條目的遺留待辦

這些條目已完成並移到歷史檔,但各自記下了尚未做的部分:

- **17.1**([紀錄](ROADMAP_HISTORY.md#171-kinematic-角色控制器--wave-a)):seam 對照:掃掠底層 raycast 近似 vs 真 shape-sweep 的 parity 測試(同場景落點一致)+ bench 尚未做
- **17.1**([紀錄](ROADMAP_HISTORY.md#171-kinematic-角色控制器--wave-a)):接 `gameplay.runtime`:目前由呼叫端每步呼叫 `update`(examples/21_runtime_character.mojo:54 仍是手動呼叫 `c.update(rt.scene, ...)`)
- **17.2**([紀錄](ROADMAP_HISTORY.md#172-主動布娃娃--物理動畫--wave-b)):~~驅動器序列化~~ ✅ 2026-10-13 隨 17.48 的快照 format 4(`AngularDrive` 全欄位含累積衝量)
- **17.2**([紀錄](ROADMAP_HISTORY.md#172-主動布娃娃--物理動畫--wave-b)):關節角度限制(膝單向)
- **17.2**([紀錄](ROADMAP_HISTORY.md#172-主動布娃娃--物理動畫--wave-b)):起身時的姿態匹配與地面對齊
- **17.2**([紀錄](ROADMAP_HISTORY.md#172-主動布娃娃--物理動畫--wave-b)):以 PD 積分項消除穩態下垂(可選;目前 8 Hz 下垂 3.8°、20 Hz 0.7°)
- **17.4**([紀錄](ROADMAP_HISTORY.md#174-載具動力學--wave-c)):開放差速目前是平分扭矩;真開放差速應被抓地較差的輪限制(分裂 μ 路面抓地輪應一併削弱)
- **17.4**([紀錄](ROADMAP_HISTORY.md#174-載具動力學--wave-c)):Ackermann 轉向、前束 / 外傾
- **17.4**([紀錄](ROADMAP_HISTORY.md#174-載具動力學--wave-c)):輪的非懸吊質量(輪目前是運動學的)
- **17.4**([紀錄](ROADMAP_HISTORY.md#174-載具動力學--wave-c)):~~車輛狀態未入快照~~ ✅ 2026-10-13 `Vehicle.write_state / read_state`(`test_vehicle`:轉彎中存檔、還原後 60 步逐位相同)
- **17.4**([紀錄](ROADMAP_HISTORY.md#174-載具動力學--wave-c)):拖車 / 多軸 / 每軸 > 2 輪
- **17.4**([紀錄](ROADMAP_HISTORY.md#174-載具動力學--wave-c)):進階輪胎(鬆弛長度、溫度、載重敏感度)
- **17.4**([紀錄](ROADMAP_HISTORY.md#174-載具動力學--wave-c)):`CapsuleWheel` 接觸點固定在輪中央平面下(側緣接觸只影響法向)
- **17.4**([紀錄](ROADMAP_HISTORY.md#174-載具動力學--wave-c)):引擎轉動慣量(換檔時 rpm 瞬變)
- **17.4**([紀錄](ROADMAP_HISTORY.md#174-載具動力學--wave-c)):LBM 風洞 Cd 為格子數(Re 差 4 個數量級、階梯體素、無地面);高解析度 / GPU 風洞(`lbm_gpu`)Cd 可接入但未做
- **17.4**([紀錄](ROADMAP_HISTORY.md#174-載具動力學--wave-c)):BENCHMARK_REPORT.md 尚未以 `pixi run benchmark` 重產，bench_vehicle 列只在範本(2026-10-09 修訂;目前報告無 vehicle 列)
- **17.5**([紀錄](ROADMAP_HISTORY.md#175-破壞--破碎--wave-c)):碎片慣量只取張量對角，需轉主軸(`TODO`)
- **17.5**([紀錄](ROADMAP_HISTORY.md#175-破壞--破碎--wave-c)):`polytope_split` 的符號判斷改走 `geometry/predicates.orient3d`(目前是 epsilon 帶)
- **17.5**([紀錄](ROADMAP_HISTORY.md#175-破壞--破碎--wave-c)):`bond_overlapping` 為 O(n²),需 broadphase(physics/fracture.mojo:316 TODO);跨零件接縫面積以 `min(V)^(2/3)` 估
- **17.5**([紀錄](ROADMAP_HISTORY.md#175-破壞--破碎--wave-c)):`HullShape` 面表上限 30 面、O(V⁴) 建構，單碎片頂點數宜 ≲ 60
- **17.5**([紀錄](ROADMAP_HISTORY.md#175-破壞--破碎--wave-c)):只切凸實體(凹體須先分解)
- **17.5**([紀錄](ROADMAP_HISTORY.md#175-破壞--破碎--wave-c)):~~`FractureSet` 與斷裂閾值未入快照~~ ✅ 2026-10-13 `write_fracture / read_fracture`(Float64 以位元樣式精確保存;`test_fracture` case_snapshot:還原後斷同樣 16 條鍵、碎片位姿逐位相同)
- **17.5**([紀錄](ROADMAP_HISTORY.md#175-破壞--破碎--wave-c)):單塊不規則碎片孤立落地 6 秒內約 6 成入睡，其接觸片品質需單獨處理
- **17.5**([紀錄](ROADMAP_HISTORY.md#175-破壞--破碎--wave-c)):一次切上千片的 O(pieces × planes) 分類尚未加空間索引
- **17.5**([紀錄](ROADMAP_HISTORY.md#175-破壞--破碎--wave-c)):軟體不睡，壓在其上的碎片保持清醒
- **17.5**([紀錄](ROADMAP_HISTORY.md#175-破壞--破碎--wave-c)):BENCHMARK_REPORT.md 尚未重產，bench_fracture 列只在範本(2026-10-09 修訂;目前報告無 fracture 列)
- **17.27**([紀錄](ROADMAP_HISTORY.md#1727-力場--區域效果--wave-b)):LBM 速度場直接接成 WindGrid 的範例
- **17.27**([紀錄](ROADMAP_HISTORY.md#1727-力場--區域效果--wave-b)):力場的空間索引(現為 bodies × fields 全掃)
- **17.28**([紀錄](ROADMAP_HISTORY.md#1728-浮力--水體積--wave-b)):hull / 膠囊浸沒
- **17.28**([紀錄](ROADMAP_HISTORY.md#1728-浮力--水體積--wave-b)):以平面切割凸體求精確體積取代取樣
- **17.28**([紀錄](ROADMAP_HISTORY.md#1728-浮力--水體積--wave-b)):LBM 阻力耦合

### 待辦與部分完成條目

#### 17.66 物理角色 — Wave C
> **進度註(2026-10-13)**:`gameplay/phys_character.mojo` `DynamicCharacter`(進 solver 的膠囊:旋轉鎖、摩擦 0、睡眠關;向下射線的接地彈簧阻尼含重力補償,
> 反作用力施於腳下動態物體;水平力朝 wish 速度、上限 `max_accel`、空中 `air_control`)與 `gameplay/balance.mojo`(質心 / 速度、支撐多邊形(單調鏈凸包)、
> capture point、邊界距離、`is_balanced`)。發現:solver 把累積力在步首一次施加、重力逐子步施加,靜止物體步末速度讀數為 −0.061 m/s(4 子步、1/60 s),
> 以它阻尼使膠囊高 6.5 mm;改用每 tick 高度差後落在 1.0000001。量測(`tests/test_phys_character.mojo` 12/12):5 m/s 穩態 5.0;煞停 0.58333 m,
> `Mover`(MODEL_ACCEL)0.583333,離散解 v²/2a − v dt/2 = 0.58333;100 N·s 衝量 dv = 1.25 = J/m;懸停於 10 kg 箱上時箱 0.1 s 內被壓下(−3.02 m vs 單獨 −0.05);
> 質心、支撐多邊形(4 頂點、逆時針)、中心邊距 0.1、capture point x = √(h/g) 皆對解析值。`bench_phys_character`(64 個):kinematic 1.89 µs、動態 2.62 µs / 角色·tick。
> **進度註(2026-10-17)**:`gameplay/ragdoll_ctl.mojo`:`segment_masses`(依盒體積的每骨質量,`Ragdoll` 新增可選 `masses` 參數,預設路徑不變);`RagdollModes`(ACTIVE → STUMBLE(衝量 ≥ 30 N·s 或失衡,強度 0.3、0.6 s 後平衡回 ACTIVE 否則 LIMP)→ LIMP(≥ 120 N·s,強度 0)→ GETUP(著地且慢於 0.2 m/s 達 0.5 s;依軀幹朝向選仰 / 俯臥 clip,`blend` 1 → 0 歷 0.8 s)→ ACTIVE;`write_state` / `read_state` 經 `state_io`);`balance_assist`(質心 / capture point;在支撐多邊形內時以 kp (中心 − capture) − kd v 推根部(上限);在外時回報 `need_step` 與落點 = capture point);`grab` / `release`(焊接關節 + `set_joint_break`;放開設為 `JOINT_BROKEN`)。量到:原先以 kp (中心 − COM) 追質心,踏步後新中心在身體前方,反而加速(188 步後 9 m/s 失控);改為追 capture point 後一步即停。`tests/test_ragdoll_ctl.mojo` 13/13:質量 10 / 20 kg(體積 1:2);模式機腳本序列與 BinWriter 往返後續行逐位相同;零重力兩骨 ragdoll:COM 0 → 0.0994(中心 0.1);60 N·s 推後 capture point 0.869、要求踏步,踏一步後 COM 0.86903 vs 中心 0.86913、速度 1.7e-4;手(運動學)攜帶 2 kg 盒到 (0.6, 1.80);500 kg 負載拉斷 500 N 焊接;放開後 0.5 s 落 2.05 m。既有 `test_ragdoll` / `test_phys_character` golden 不變。
> **未做**:有重力的雙足站立(踝 / 髖力矩、腳的實際碰撞)與真正踏步(移動腳骨而非支撐多邊形)、以動畫為參考的 PD 追蹤(現為角度 drive + 根部力)、負重改變步態。
> **現況**:兩端各有,中間沒接。17.1 是 kinematic 膠囊(`gameplay/character.mojo:61` `CharacterController`),**不進 solver**;17.2 是主動布娃娃(`gameplay/ragdoll.mojo:37` `Ragdoll`:每骨一個盒、父子球關節、`AngularDrive`(`physics/joints6.mojo:279`)追動畫目標,`:108` `set_strength` 0=軟癱、`:113` `hit`、`:127` `blend_world` 做起身混合)。**沒有的**:平衡 / 支撐判斷——grep `center_of_mass|zmp|support.?polygon|capture.?point|centroidal|footstep` 全樹 `.mojo` 零命中;ragdoll 質量是每骨統一預設 5 kg 的盒(`gameplay/ragdoll.mojo:53` `mass: Real = 5`);ragdoll 用的最大座標關節無角度限制(縮座標 `Chain` 有 joint-limit 列,`physics/constraints.mojo:1-14`,但 ragdoll 不走 chain;17.2 待辦「膝單向」,ROADMAP §17.2;關節庫缺口歸 17.47);起身無姿態匹配 / 地面對齊(同待辦)。控制器**無法被外力推動**:`character.mojo:279` 每次 `update` 把水平速度整個覆寫為 `walk`,knockback 不可能殘留。動態(進 solver 的)角色本體不存在。縮座標模型可作控制器端的分析模型:`physics/chain.mojo:321` `rnea_root`、`:404` `inverse_dynamics`、`:416` `mass_matrix`、`:610` `point_jacobian` 已有,但與 ragdoll 的最大座標關節是兩套,沒有橋。`Runtime` 不擁有角色 / ragdoll(`gameplay/runtime.mojo` grep 零命中,見 17.64)。
> **缺口**:
> - **平衡控制**:質心(COM)與支撐多邊形,踝 / 髖回饋力矩,被推後踏步復原(例:1.8 m ragdoll 受 100 N·s 水平衝量仍站穩或踏一步)。
> - **物理驅動移動**:以動畫為參考的 PD 追蹤 + 根部輔助力(17.2 只有純角度追蹤、無根部力與平衡)。
> - **動態角色本體**(浮動膠囊 + 彈簧腿 / 接地彈簧):被爆炸 / 車撞 / 質量比正確地推開,對照 17.1 的 kinematic 版。
> - **模式狀態機**:活動(動畫 kinematic)↔ 踉蹌(部分 ragdoll 遮罩)↔ 軟癱 ↔ 起身,切換準則(速度低於門檻、接地、仰 / 俯臥選起身 clip)。
> - **抓取 / 攜帶**:手到物體的可斷裂關節(17.29),負重改變質心與步態。
> - **ragdoll 質量與限制**:依體型比例分配質量與慣量(取代統一 5 kg 盒)、鄰骨自碰撞過濾(`physics/solver6.mojo:455` `set_filter`)、接 17.47 的關節限制;由蒙皮權重擬合碰撞膠囊(17.65)。
> - **驅動器 / 角色狀態序列化**(17.2 待辦),納入快照。
> **對照組**:UE Physical Animation / Physics Control、Chaos Mover、Unity Active Ragdoll 類套件、SIMBICON(Yin 2007)、Jolt `Ragdoll` 與 `CharacterVirtual` 並存、PhysX `PxController` vs articulation、NaturalMotion Euphoria(閉源,僅概念對照)。
> **優勢區**:中 —— 控制器端用 `chain.mojo` 的 RNEA / CRBA 做前饋與 COM Jacobian(對照組多為純 PD),模擬仍在最大座標 `ContactScene6`(「分析模型 vs 模擬模型」分離);決定論使「推力 × 增益 → 站穩 / 跌倒」可逐位重現;增益可交給 17.20 的可微子集調(該子集尚未涵蓋關節,ROADMAP §17.20)。
> **規模軸**:同時活動的物理角色數 × 骨數 × 子步;衝擊大小 vs 復原成功率曲線(穩健性);增益掃描下的追蹤誤差 vs 成本(延伸 `bench_ragdoll`)。
> **seam?**:是 —— 角色本體後端:kinematic 掃掠(17.1)vs 動態膠囊(本條)→ parity:平地同輸入的穩態速度 / 煞停距離一致;差異(外力響應、質量比)寫成行為斷言;bench 每後端一列。
> **交付**:`gameplay/balance.mojo`、`gameplay/phys_character.mojo`、ragdoll 模式機。測試:普通(靜立 5 s 不倒、拉開增益掃描)/ 整合(接 17.2 `Ragdoll` + 17.3 IK + 17.64 動畫參考,被 17.71 命中後進踉蹌再起身、被 17.74 載具撞飛)/ 極端(增益掃到 1e6 與 0(高增益端須維持穩定或被夾限並記 counter)、參考姿態跳變、單腳支撐、零質量 link、懸空無接觸時不除以零、衝量方向沿支撐邊界)。
> **相依**:17.1、17.2、17.47(關節限制)、17.51(縮座標 / 多自由度關節)、17.64、17.65、17.67(外力 / 速度擁有權)、17.29、17.20。
> **邊界**:強化學習式步態(使用者已排除 RL)不在此;人形 rig 的製作屬 DCC / 宿主;死亡動畫的藝術選擇屬內容。

#### 17.67 移動模式 — Wave B
> **狀態**:🔶 部分完成(2026-10-13:模式機(走 / 落 / 游 / 飛)、三種速度整合模型、跳躍手感、外部速度累加器、平台朝向繼承 ✅;2026-10-17:任意向上軸、
> 攀上 / 翻越、Driving 模式、`replay` 快照接線 ✅;梯子 / Sliding / Gliding、形狀泛化(水平膠囊、球)、電梯夾擠未做)。
> **進度註(2026-10-17)**:
> - **任意向上軸**(`0564c96`、`cb64ed1`):`CharacterController.up` + `set_up`(零向量 raise);膠囊 / 圓角盒沿 `up` 站立,台階、坡度、貼地、跳躍、重力皆沿 `up` 量
>   (`_h(v) = v − up·(v·up)`、`_v(v) = v·up`;對 +y 這兩式逐位等於舊的取分量,既有角色測試 golden 不變)。`Mover` 的跳躍、游泳 / 飛行的垂直 wish、外部垂直速度、
>   平台朝向同樣沿 `cc.up`(設定分量用 `_h(v) + up·s`,對 +y 逐位精確);`WaterVolume` 仍是 +y 水面的軸對齊盒。
>   `test_character_up` 7/7:場景繞 z 轉 90°(地板變 x < 0 的牆、重力 −x、up = +x)時膠囊路徑轉回後相距 0.0 m、圓角盒 1.2e-7 m;4 m/s 跳躍頂點兩框架皆 1.76;
>   `Mover`(加速度模型、二段跳、tick 120 沿 up 6 m/s 跳墊、tick 170 起 FLY 且 wish 含 1 m/s 沿 up)兩框架終點相同、頂點皆 6.1224046、皆用 2 跳。
>   `test_movement` / `test_replay` 等 14 個用到 `Mover` 或 runtime 的測試輸出與 golden 逐字相同。
> - **攀上 / 翻越 / Driving**(`003c4a7`):`climb_height` > 0 時,撞牆(沿 wish 方向)從上方射線找牆頂,頂高 ≤ `climb_height` 就進 `MODE_CLIMB`,
>   以 `climb_time` 經「上升到牆頂 → 前進」兩段移到頂上;牆厚 < `vault_depth` 且牆後地面在台階高內則翻到牆後。`enter_vehicle(body, seat)` 進 `MODE_DRIVE`,
>   每 tick 位置 = `act(seat)`、速度 = 該點剛體速度;`exit_vehicle(offset)` 放到車旁並回到走 / 落。`SimState.movers` 入快照 / 還原 / checksum。
>   `test_movement_modes` 8/8:1.0 m 牆攀上後腳高 1.0073;0.9 m × 0.2 m 牆翻越後腳高 0.0073、z 6.40;0.2 m 台階只跨步、2.0 m 牆不攀、預設不攀;
>   3 m/s 車上 1 s 後下車,x 1.0000069、著地且回到走;攀爬中途快照還原後 checksum 相同;壞車輛索引與未駕駛時下車 raise。
> **進度註(2026-10-13)**:`gameplay/movement.mojo` `Mover` 包住 `CharacterController`:`MODE_WALK / FALL / SWIM / FLY`(游泳以膠囊高度在 `WaterVolume` 水面下的比例判定,進 0.6、出 0.4 的遲滯;
> 水中重力乘 `1 − buoyancy`、垂直 wish 驅動並以 `water_drag` 阻尼;飛行無重力);`MODEL_DIRECT`(原行為)/ `MODEL_ACCEL`(趨近 wish,無 wish 時煞車,空中乘 `air_control`)/
> `MODEL_QUAKE`(PM_Friction + PM_Accelerate);以 tick 計的 coyote time、跳躍緩衝、放開即減半的可變跳高、`max_jumps`(空中跳需新的按壓);`add_velocity` 外部速度逐 tick 疊加並指數衰減;
> 站在旋轉平台上時 `heading` 隨平台角速度轉。值型別,複製即快照。**發現**:測試中直接寫 `mh.cc.position` / `mh.cc.velocity` 讓 Mojo 1.1 編譯器卡住(5 分鐘無結果,二分確認),改用 `teleport` 方法即正常(36 s)。
> 量測(`tests/test_movement.mojo` 13/13):3 m/s wish 3 s 後三種模型速度皆 3.0,距離 9.000 / 8.800 / 8.944 m;離開平台 3 tick 後按跳會跳、12 tick 不會;落地前 4 tick 按跳於落地時起跳、10 tick 前則否;
> 按住 / 3 tick 後放開的跳躍頂點 2.227 / 1.411 m;二段跳可、三段不可;走進水池轉游泳;以波浪把身體維持在 50 % ± 6 % 入水時,遲滯下模式切換 0 次、無遲滯 23 次;
> 行走 2 m/s 時受 5 m/s 側向擊退,1 s 內側移 1.62 m 且行走速度仍 2.0;1 rad/s 旋轉平台上 1 s 後朝向 0.983 rad;複製 + 場景快照續跑逐位相同;`dt = 0` 不動、NaN wish 視為無輸入。
> bench `bench_movement`(16 角色,ns / 次):直設 1111、加速度式 974、Quake 式 968、游泳 1767。
> **現況**:控制器只有**一個模式(走 / 空中二態)**。`gameplay/character.mojo:257` `update(sc, walk, jump_speed, dt, gravity)`:`walk` 是期望水平**速度**,`:278-279` 直接設 `velocity = (walk.x, vy, walk.z)`——沒有加速度 / 摩擦 / 空中操控模型,也使任何外部速度被覆寫(見 17.66)。向上軸寫死:`:40` `_UP = (0,1,0)`、`:278` 只讀 `gravity[1]`,所以 17.27 的重力區(`physics/fields.mojo:1-28` 檔頭自述「牆上可走」的 GRAVITY 區)對控制器無效。形狀只有直立膠囊(`:61-90`),可蹲(`:100` `set_half_height`)。平台只以腳點線速度帶動位置(`update` 內 `velocity_at(foot) * dt`,旋轉平台的切向速度含在內),控制器**沒有朝向狀態**(欄位只有 `cfg / position / velocity / on_ground / ground_normal / ground_body / hit_ceiling / pushed`,`:61-76`),平台旋轉不帶動朝向。水體存在(`physics/fields.mojo:20-28` `WaterVolume`)但控制器不查詢。grep `[Ss]wim|[Cc]limb|[Ll]adder|[Ll]edge|mantle|wall.?run|coyote|jump_buffer|MovementMode` 於 `gameplay procedural` 只命中 `character.mojo:173` 一則註解(「斜坡不會把人抬起」),其餘零命中。輸入契約窄:`gameplay/replay.mojo:31-36` `InputFrame` = `(tick, move, jump, buttons)`。單向平台規則尚未套用於控制器(17.26 待辦,ROADMAP §17.26)。
> **缺口**:
> - **模式機**:Walking / Falling / Swimming / Flying / Climbing(梯、攀緣)/ Sliding / Gliding / Driving(上下車)——每模式自有速度整合、重力倍率、碰撞形狀;用 `procedural/fsm.mojo` 階層狀態機表達(例:膠囊浸水比例 > 0.6 且 `WaterVolume` 命中 → 進游泳,帶遲滯避免水面抖動)。
> - **加速度模型**:走路加減速 / 地面摩擦 / 空中操控 / 煞車;三種手感變體並存(現有速度直設、UE CMC 式、Quake `PM_Accelerate` 式)。
> - **跳躍手感**:coyote time、跳躍緩衝、可變跳高、二段跳——全以 tick 計數(確定性,可用 17.35 計時器)。
> - **任意向上軸**:up 向量由重力區或星球中心決定,取代 `_UP`(例:球形小行星繞一圈)。
> - **外部速度 / 衝量累加器**:knockback、彈跳墊、風;帶衰減,與 `walk` 疊加而非覆寫(供 17.71)。
> - **移動平台完整繼承**:平移 + 旋轉(朝向 / 位置繞平台軸),電梯夾擠。
> - **攀爬 / 翻越**:以形狀掃掠偵測(需 17.53 的盒 / 一般形狀掃掠)+ 可選 root motion 驅動(17.64)。
> - **形狀泛化**:水平膠囊(四足)、球。
> - **狀態入快照**:新欄位須走 `replay.mojo` 的 `Snapshot`(控制器以副本入快照,`:52-58`)。
> **對照組**:UE `CharacterMovementComponent`(`MOVE_Walking/Falling/Swimming/Flying/Custom`)與 Mover、Unity Kinematic Character Controller 與 DOTS Character Controller、Godot `CharacterBody3D`(`up_direction`、GROUNDED / FLOATING)、Jolt `CharacterVirtual`、Quake / Source 移動。
> **優勢區**:低-中 —— 多為 table stakes;可主張的差異:(a)全 tick 計數 + 值型別狀態 ⇒ 模式切換可逐位重播 / 回滾(`first_divergence` 可驗);(b)任意 up 軸沿用 17.27 重力區,不另造;(c)平台相對座標以 motor 表示,與變換層一致。
> **規模軸**:控制器數 N × 模式 × 每次 `update` 的掃掠次數(基準:17.1 空地 ~3.5 µs、N=256 障礙 ~33 µs,ROADMAP §17.1);模式切換頻率。
> **seam?**:是 —— 速度整合模型(直設 / 加速度式 / Quake 式)→ parity:平地等速直行的穩態速度相同;暫態差異寫成斷言;bench 每模型一列。
> **交付**:`gameplay/movement.mojo`(模式機 + 整合模型)、`character.mojo` 去除 `_UP` 寫死。測試:普通(走→跳→落;入水游泳、出水)/ 整合(旋轉平台載運且朝向跟隨;17.71 knockback 疊加不被覆寫;含模式切換的錄製在 17.39 `first_divergence` 無分歧;上下車切 Driving)/ 極端(水面抖動遲滯、梯頂 / 梯底、up 軸翻轉(極點)、零重力、傳送中途換模式、平台被移除時乘載中、低天花板蹲伏(既有)、`dt = 0`、NaN 輸入)。
> **相依**:17.1、17.13 / 17.53、17.26、17.27 / 17.28、17.35、17.39、17.64(root motion)、17.66、17.71(外力)、17.74(上下車)。
> **邊界**:輸入映射 / 手把死區屬宿主;依模式選動畫由宿主(或 17.64 參數)處理;攝影機行為屬 17.68;音效屬宿主。

#### 17.68 攝影機 / 序列 — Wave B(headless 資料 / 邏輯)
> **狀態**:✅ 完成(2026-10-13:鏡頭資料、參考投影、視錐測試、臨界阻尼彈簧、trauma 震動、吊臂鏡頭、鏡頭混合與優先序、序列(純量 / Vec3 / 四元數 / 事件軌,seek 與游標兩種求值);
> 2026-10-17:軌道車 / 多目標取景、motor 空間彈簧變體(seam)、動畫 clip 軌、序列驅動 kinematic 剛體與事件進 `Channel`)。
> **進度註(2026-10-17)**:
> - `procedural/camera_math.mojo`:`CamSpring`(seam:`SPRING_SPLIT` 位置與旋轉向量分開 / `SPRING_MOTOR` 相對目標的 motor 取 6 維 log;兩者皆為帶速度狀態的臨界阻尼彈簧)、
>   `frame_targets`(各球的包圍球放進兩個視角半角中較窄者)、`Frustum.sphere_inside`、`DollyRail`(17.36 弧長表 + RMF;最近點的弧長以彈簧追、看向目標、以 RMF 法向為 up)。
>   `test_camera_spring` 8/8:純平移(3.7 m)兩者差 1.4e-5 m(float32 motor 乘積捨入)、純旋轉(60°)差 2.9e-7 rad;兩個半步 = 一步(兩模式);
>   繞 5 m 外樞軸 90°:motor 與樞軸最近距離 4.9999995、分開者 3.54(走弦);三球取景全在視錐內,單球拉近 2 % 即出界;24 m 直軌追 2 m/s 目標,5 s 後軌上速度 1.99985、
>   離軌 1.4e-6 m、視線餘弦 ≥ 0.9999999,目標走過軌端時停在 x 11.99999;壞 mode、半衰期 0、無目標、零方向、fov ≥ π raise;`dt = 0` 與 NaN 目標不改變狀態。
> - `procedural/sequence.mojo` clip 軌:`key_clip(k, start, clip, offset, speed, blend)`、`clip(k, t)` → `ClipSample`(新 / 舊 clip 的區域時間與權重;t 的純函式)。
> - `ContactScene6.set_dynamic`(kinematic → dynamic,保留質量與速度;非 kinematic、三角網格 raise)。
> - `gameplay/sequence_player.mojo` `SequencePlayer`:游標播放;跨過的事件以 `SeqEvent(sequence, event, time)` 送進 `Channel`;綁定的剛體設為 kinematic 並每 tick `move_to` 軌道姿勢;
>   結束後的下一 tick 把 `release` 的剛體交還動力學,速度取軌道在最後一個 `dt` 上的導數。**發現**:首版用最後一個 tick 的 `move_to` 速度,
>   但游標累加 1/60 的 float32 和,第 121 個 tick 只前進殘差,交還速度 0.0003 m/s;改用軌道導數後 1.9999。
>   `test_sequence_player` 8/8:1.125 s 時 run 區域時間 0.1875、權重 0.5、walk 1.125;0.51 / 1.51 s 的事件於 tick 31 / 91 各到一次;平台到 x 4.0、載著箱子(瞬間起步滑後 0.17 m);
>   交還時 vx 1.9999,0.5 s 後 x 與拋體公式差 3e-5 m、y 差 0.010 m(子步積分);缺軌、對非 kinematic 剛體 `set_dynamic`、負 blend、逆序 key raise。
> - bench `bench_sequence`(ns / 次):`CamSpring` split 222、motor 221;軌道車(3 段、256 取樣)577;`frame_targets` 16 球 115。
> **進度註(2026-10-13)**:`procedural/camera_math.mojo`:`CameraPose`、`look_rotation`(看正上 / 正下時改用 +z 當 up,不退化)、`perspective` / `ortho`(OpenGL 慣例)、`Frustum`(六個朝內平面,球 / AABB 測試)、
> `spring_damp`(精確解,與步長無關)/ `spring_damp_quat`、`Shake`(trauma² × 種子 Perlin)。`procedural/sequence.mojo`:`Sequence`(依時間的純函式,二分找段)與 `SeqCursor`(從上一段走,事件經 17.64 `EventTrack`)。
> `gameplay/camera_rig.mojo`:`SpringArm`(球掃,拉近立即、放長用彈簧)、`CameraBrain`(優先序最高者勝,換鏡時以緩動混合位置 / 方向 / fov)。
> **發現**:Mojo 1.1 編譯器在「迴圈內對 struct 欄位賦值,且同一迴圈對該 struct 呼叫泛型 mut 方法」時卡住(`bench_sequence` 的 `arm.yaw = ...` 與 17.67 的 `mh.cc.position = ...` 皆 5 分鐘以上無結果),改成方法(`SpringArm.aim`)後 10 s 編譯完成。
> 量測(`tests/test_camera_seq.mojo` 14/14):`look_rotation` 各方向(含兩極)誤差 1.7e-7;視錐與參考投影裁切在 2000 個隨機點上全部一致(218 個在內;初版四個側面法向全部朝外,此測試抓到);
> 彈簧兩步 0.05 與一步 0.1 一致;游標以不等步長(含負步)播放 400 次,與隨機 seek 逐位相同;事件正向各一次、倒拖反序各一次;牆在 2 m 處時吊臂停在 z 1.78(加半徑不入牆),牆移除後 39 幀放長到 4.95 m;
> 目標在牆內時臂長 0;優先序切換混合半途 x 5.0、fov 0.75,結束時逐位等於目標鏡頭;零 trauma 不震、同種子重現、trauma 1 s 內歸零。
> bench `bench_sequence`(64 軌 / 幀,ns):每軌 8 / 128 / 2048 個 key 時 seek 2394 / 2697 / 7104、游標 2391 / 2449 / 5307;吊臂 空場景 21、一面牆 175 ns / 次。
> **現況**:攝影機與序列**完全不存在**。grep `[Cc]amera|[Ff]rustum|perspective|view_matrix|\bfov\b|\bFOV\b|orbit|shake|Timeline|Sequencer|[Cc]utscene` 全樹 `.mojo`(排除 build/.pixi/worktrees)零命中。可重用的積木:twist-free 樣條標架 `geometry/spline.mojo:454` `build_rmf_frames`、`:485` `frame_at_distance`(軌道 / 吊臂鏡頭,範例 `examples/15_spline_rmf.mojo`);緩動與 motor geodesic 補間 `procedural/tween.mojo:63-94,220`;球掃 `collision/world_query.mojo:418` `sphere_cast`(+ `QueryFilter` `:59` 類別遮罩,`physics/solver6.mojo:655` 包裝)可做鏡頭防穿牆;`gameplay/interpolation.mojo:87` `MotorGeodesic` 與 `gameplay/runtime.mojo:135` `render_pose` 給 tick→繪製的插值;`scheduler/events.mojo` 事件通道;`scheduler/timers.mojo` 決定論計時;`procedural/noise.mojo:102-212` 種子雜訊可做鏡頭震動;`procedural/ik.mojo:174` `look_at` 是**IK 錐角限制旋轉,不是視圖矩陣**。`geometry/mat.mojo` 無投影矩陣(上述 grep 含 `perspective` 零命中)。
> **缺口**:
> - **鏡頭資料與 rig**:`CameraPose`(motor + 鏡頭參數 fov / near / far / 寬高比)純資料;rig 邏輯:跟隨 / 軌道(orbit)/ 吊臂(spring arm,球掃拉近防穿牆)/ 第一人稱 / 軌道車(樣條 RMF)/ 多目標取景 / 鎖定目標;臨界阻尼彈簧平滑(motor 空間)。
> - **鏡頭混合與優先序**:多鏡頭 + 優先序 + 混合曲線(Cinemachine brain 式),切鏡 / 淡入。
> - **震動**:trauma 模型(Eiserloh, GDC 2016)以種子雜訊驅動,同種子同 tick 逐位重現。
> - **視錐數學(模擬端用途)**:從視圖 / 投影參數取六平面;球 / AABB / OBB 視錐測試,供 AI 視野錐(17.15)、相關性 / 觀察者集合(17.85);繪製用的視錐剔除屬宿主(本條的視錐測試只服務模擬端查詢);並提供標準 `perspective` / `ortho` 參考矩陣,使宿主與模擬端對投影達成一致。
> - **序列 / 時間軸**:軌道 —— motor 軌、純量曲線軌、事件軌(重用 17.64 的 `EventTrack` 原語)、動畫 clip 軌(17.64)、鏡頭切換軌;**求值是時間的純函式**(可前後 scrub、跳過、快轉結果一致),事件在 tick 區間內恰一次(語意與實作即 17.64 `EventTrack`,本條不另定義);序列可驅動 kinematic 剛體(`physics/solver6.mojo:501` `set_kinematic`、`:529` `move_to`),結束時以軌跡導數把速度交還給動力學。
> **對照組**:Unity Cinemachine + Timeline / Playables、UE Camera Modifiers / Spring Arm / Sequencer(Level Sequence)/ CineCamera Rig Rail、Godot `SpringArm3D` + `AnimationPlayer` 軌道、Eiserloh 鏡頭震動、Holden 的彈簧阻尼推導。
> **優勢區**:中 ——(a)序列求值為純函式 + 事件恰一次 ⇒ 過場可逐位重播 / 跳過而不分歧(對照組的 Timeline 常與牆鐘 / 幀率耦合);(b)軌道鏡頭走 RMF motor 標架,極點不翻滾(`geometry/spline.mojo:1-30` 自述優勢);(c)震動走既有純函式雜訊,可重播。皆**待量測**。
> **規模軸**:鏡頭數(分割畫面 / 觀戰 4–16)× 防穿牆探測數 vs 場景碰撞體數(ROADMAP §17.13 記 N≥256 起被線性前置主導);時間軸軌道數 × 關鍵幀數;隨機 seek vs 順序游標成本;視錐測試的包圍體數。
> **seam?**:是 ——(1)時間軸求值:順序游標 vs 隨機存取 seek → parity:同一 t 輸出逐位相同、事件序列相同(與 17.39 `seek` vs `replay_from_start` 同構);(2)鏡頭平滑:分量彈簧(位置 + 四元數)vs motor 空間彈簧 → parity:純平移與小角度下一致;bench 每變體一列。
> **交付**:`procedural/camera_math.mojo`(視錐、參考投影、彈簧)、`procedural/sequence.mojo`(軌道求值,純資料)、`gameplay/camera_rig.mojo`(需碰撞查詢,故在層 5)、序列 → 事件 / kinematic 剛體的轉接。測試:普通(軌道鏡頭沿樣條勻速、序列播三軌)/ 整合(吊臂鏡頭跟 17.1 控制器並用 `sphere_cast` 拉近、以 `render_pose` alpha 平滑;序列事件經 `Channel`;序列驅動 kinematic 平台結束後放手成動態;視錐剔除結果與 `ray_cast` 一致)/ 極端(鏡頭在牆內、目標完全被遮、目標 == 鏡頭位置、up 平行 forward(極點)、零長軌道、切鏡中途被打斷、向後 scrub 越過事件、重複關鍵幀、`dt = 0` / 巨大 `dt`、NaN 目標、fov→0 或→π)。
> **相依**:17.36、17.35、17.7、17.13 / 17.53(掃掠)、17.38、17.64(clip 軌)、17.1 / 17.67(跟隨目標)、17.39(killcam)、17.85(觀察者介面僅留接口)。
> **邊界**:繪製、後處理、視埠 / 視窗管理、最終投影矩陣上傳屬宿主;序列編輯器 UI 屬編輯器。宿主接手點 =(a)每幀最終 `CameraPose`,(b)序列發出的事件(燈光 / VFX / 音效觸發)。過場的畫面內容由宿主繪製。

#### 17.71 戰鬥物理 — Wave B
> **狀態**:✅ 完成(2026-10-13:受擊 / 攻擊體積與去重、三種近戰偵測(seam)、hitscan、彈道投射物(線性 / 二次阻力、分段射線、池化)、帶遮擋的爆炸、hit-stop;
> 2026-10-17:穿透 / 跳彈、導引與近炸引信、提前量、衝擊波擴張、與動畫事件 / 17.70 傷害 / 破碎的接線、角色走 17.67 累加器的擊退與爆炸推力)。
> 穿透用每個 body 的阻力係數(`set_resistance`),尚未接 17.23 的逐三角形材質 id。
> **進度註(2026-10-17)**:
> - `gameplay/projectile.mojo`:命中帶種類(`HIT_STOP / PENETRATE / RICOCHET / FUSE`)與已飛距離(供 17.70 距離衰減)。跳彈:入射角 < `ricochet_deg` 時反射速度乘 `restitution`;
>   穿透:每發帶 `penetration` 公尺的參考材料,body 厚度(從入射點後方 `penetration / 阻力` 處反向 `ray_cast_all` 求出口)乘阻力,夠則從另一側出去、速度乘 sqrt(剩 / 原),不夠則停;
>   導引:每秒最多轉 `turn_rate` 弧度、速率不變;近炸:步內經過 `fuse_targets` 中心 `fuse_radius` 內(且早於表面命中)即於最近點引爆;`lead_direction`(等速目標的最早攔截方向,追不上回零)。
>   跳彈 / 穿透 / 引爆都在該點結束該 tick 的飛行。
>   `test_projectile_pen` 9/9:300 m/s、0.3 m 穿透:穿過 0.1 m 牆(出口 244.949 m/s = 300·sqrt(0.2/0.3)、入口 x 4.95)、停在阻力 3 的牆(9.95,已飛 9.9499 m);
>   10° 擦地跳彈(法向分量反向、×0.6)、45° 停、跳彈關閉時停;垂直方向目標:無導引不中、3 rad/s 導引命中;離目標 1 m 通過時於 x 10.0 引爆(牆之前);
>   提前量對 5 m/s 橫越目標最近 7.5e-4 m,追不上回零;阻力 ≤ 0、負 body、壞導引索引 raise;1 m 牆擋下 0.3 m。
> - `gameplay/explosion.mojo`:`explode(..., only)` 限定 body;`Shockwave`(前緣以 `speed` 擴張,每個 body 在前緣到達的那一步被推一次,遮擋與衰減同 `explode`)。
> - `gameplay/hit_pipeline.mojo`:`HitWindow`(實體的動畫事件 open / close 開關 `Swing`,開時清去重集)、`deal_damage`(基礎傷害 × 部位倍率 → `Rules.damage` → `DamageEvent` 進 `Channel`,
>   擊殺只報一次)、`knockback`(沿刀身運動方向加到 `Mover` 外部速度)、`explode_movers`(角色的爆炸推力,中心到角色的射線先打到東西即擋下)。
>   `test_hit_pipeline` 7/7(system):1 s 循環的攻擊 clip 於 0.2 / 0.5 s 發 open / close,刀身每秒一圈,2 s 內窗開 2 次、命中 2 次,窗不開則 0;
>   頭部 2.0 × 30、抗性 10 %:生命 100 → 46 → 0,兩個事件(54、46),擊殺 1 次;擊退 3 m/s 時 1 s 側滑 0.97 m 且行走 vz 仍 2.0;
>   爆炸推開闊處角色(ext 5.0 = 10·(1 − 3/6))、牆後角色 0;衝擊波 40 m/s 於 tick 4 / 30 推到 2.2 / 19.5 m 的箱子各一次;
>   12 格黏結破碎牆前 0.6 m 的 6000 N·s 爆炸斷 19 條黏結(對照組 0;300 N·s 只讓 ~300 kg 的格子動 0.4 m/s,一條不斷)。
>   受擊 ragdoll 仍用既有的 `Ragdoll.hit`。
> - bench `bench_combat` 表 3(1000 發 300 m/s,µs / 步):開闊處 一般 65、導引 95、16 目標近炸 212;每 1 m 一道 0.1 m 牆的 0.5 m 穿透 161。
> **進度註(2026-10-13)**:`gameplay/combat.mojo`:`Hurtbox`(擁有者、骨、隊伍、部位倍率、膠囊)、`Swing`(刀身膠囊,`begin` 清去重集,`step` 回傳命中且每個擁有者每次揮擊只算一次)與
> `DETECT_DISCRETE / LINEAR / ARC`(後兩者取樣使刀身任一點每段位移 ≤ `max_step`;ARC 以 slerp 沿真實弧線)、`closest_segments`(Ericson)、`hitscan`(精確射線–膠囊)、`HitStop`(以 tick 計的凍結)。
> `gameplay/projectile.mojo` `ProjectileSet`:固定容量池(滿則丟最新並計數)、線性阻力每步用閉式解、二次阻力每步一次 RK4、沿每步位移打一條射線(不靠 CCD)、可選把動量當衝量給被打中的 body。
> `gameplay/explosion.mojo` `explode`:對 body 中心與箱的 8 個角(內縮 20 %)做視線取樣,暴露比例乘衝量,線性距離衰減,衝量施於暴露點的平均位置(半遮擋時產生力矩),喚醒睡眠體;中心重合時往上推。
> 量測(`tests/test_combat.mojo` 16/16):0.05 rad / tick 時三種偵測都命中 2 cm 盾一次;1.2 rad / tick(刀尖 72 m/s)時離散 0、線性 0(弦從弧內側穿過)、弧線 1;同一擁有者的兩個受擊體只算一次;
> hitscan 命中頭部骨 t 3.85、軀幹 t 4.80;線性阻力落點 32.0914 vs 閉式解 32.0916;二次阻力 1/60 s RK4 39.0946 vs 細 100 倍 39.0946;300 m/s 子彈停在 2 cm 牆;100 格池生成 150 個丟 50;
> 爆炸:暴露的箱 vx 12.0、牆後的箱不受推、半遮擋的箱暴露 0.22 且 |ω| 13.2、睡眠箱被喚醒、中心重合時上推且有限;hit-stop 恰凍結 3 tick。
> bench `bench_combat`(200 個隨機位置的薄盾):角速度 0.05 / 0.3 / 0.6 / 1.2 rad/tick 時命中率 離散 98 / 26 / 14 / 5 %、線性 100 / 100 / 97 / 87 %、弧線 100 % 皆是;每步成本 離散 75–101 ns、
> 線性 118–1382 ns、弧線 299–5312 ns;投射物 1e3 / 1e4 個每步 169 / 1208 µs。
> **現況**:原語在,戰鬥語意不在。查詢:`collision/world_query.mojo:568` `ray_cast` 只回**最近一筆**(`:568-584`),`:377` `capsule_cast` / `:418` `sphere_cast` 回第一筆,`Hit`(`:77`)有 `body` 但沒有骨 / 部位;`ray_cast` 吃外部 `poses`(`:568`,17.16 回溯命中的零件)。分層與觸發:`physics/solver6.mojo:455` `set_filter`(category / mask)、`:460` `set_sensor`。接觸事件只有 `(a, b, feat, kind)`(`collision/contact_events.mojo:19-31`),**無衝量 / 接觸點**(歸 17.49)。CCD:`physics/ccd6.mojo:1-40` 的掃掠只涵蓋盒 / 球 / 膠囊保守盒,hull / trimesh / heightfield 無精確 TOI(歸 17.46);`tests/test_ccd6.mojo:37-46` 有 50 m/s 子彈對薄牆。爆炸:`physics/fields.mojo:154-159` 的 `FIELD_RADIAL` 線性衰減、**無遮擋**、衝量施於質心(`:174` `apply_impulse(f * dt, p)` 的 `p` 即質心,無力矩);`physics/solver6.mojo:593` 的喚醒示例提到「爆炸傷害查詢」但無傷害查詢本體。角色:控制器不吃外力(`gameplay/character.mojo:279`);`gameplay/ragdoll.mojo:113` `Ragdoll.hit` 可對骨施衝量。投射物池:`ecs/pool.mojo:1-12` 自述用途含 projectiles。grep `hitbox|hurtbox|knockback|hit.?stop|melee|ricochet` 於 `gameplay collision physics scheduler` 零命中。`physics/solver6.mojo:552` `freeze` 可暫停單一剛體(17.31)。
> **缺口**:
> - **受擊 / 攻擊體積**:逐骨 hurtbox(膠囊,跟隨 17.64 / 17.2 的骨 pose,隊伍 / 部位分層)、hitbox 有效窗口由動畫事件開關、**一次揮擊對同一目標只算一次**(去重集),命中結果含 (目標, 骨, 點, 法線, 衝量方向, 部位倍率)。
> - **近戰掃掠**:揮動武器每 tick 位移可達數十 cm,需沿 tick 內軌跡掃掠避免穿透薄物;軌跡用 motor 的螺旋插值給弧線,而非端點直線(例:40 m/s 揮擊不漏過 2 cm 盾)。
> - **hitscan 與穿透 / 跳彈**:多命中射線(17.53)+ 材質穿透深度表(17.23 材質)+ 跳彈角 + 距離衰減。
> - **彈道投射物**:重力 + 阻力(+ 17.27 風場)、提前量、近炸引信、導引;以分段射線打擊(不依賴 17.46)、池化(17.37)、預算滿時 drop-newest 並計數。
> - **爆炸**:徑向衝量 + 傷害,對每個受影響體以多取樣點做視線遮擋、衝量施於點(產生力矩)、衝擊波隨時間擴張、喚醒睡眠體(17.25)、觸發破碎(17.5)、對角色走外力累加器(17.67)。
> - **受擊反應**:knockback / 踉蹌、對 ragdoll 的 `hit`、**hit-stop**(攻守雙方局部時間暫停數 tick:凍結 + 動畫速率 0;與 17.85 的 `period` 分工)。
> **對照組**:UE `ApplyRadialDamage`(含可見性追蹤)與 Projectile Movement、Jolt 查詢 collectors(全命中)、PhysX `PxQueryFilter` touch vs block、Source / Overwatch 命中登錄與牆後穿透表(Counter-Strike 風)、Havok 查詢。
> **優勢區**:中 ——(a)螺旋 / geodesic 軌跡掃掠對高角速度近戰的漏判率,比端點線性掃掠低(**待量測**:漏判率 vs 角速度 vs 成本);(b)決定論 + 17.39 重播 ⇒ 命中可逐位重現(killcam、伺服器複驗);(c)與破碎 / 柔體 / 流體同庫,爆炸一次影響多種體。
> **規模軸**:投射物數(1e3–1e5)× 場景碰撞體數(ROADMAP §17.13 記查詢在 N≥256 被線性前置主導);每角色受擊體積數(15–60)× 角色數;爆炸半徑內物體數;揮擊角速度 vs 漏判率。
> **seam?**:是 —— 近戰命中偵測:每 tick 離散重疊 vs 端點線性掃掠 vs 螺旋自適應掃掠 → parity:當每 tick 位移 < 目標厚度時三者命中集合相同;高速下的差異(漏判率)寫成行為斷言;bench 每變體一列。
> **交付**:`gameplay/combat.mojo`(受擊 / 攻擊體積、去重、掃掠)、`gameplay/projectile.mojo`、`gameplay/explosion.mojo`。測試:普通(hitscan 打中指定骨、線性阻力彈道落點對解析解(相對誤差 ≤ 1e-3;二次阻力無閉式解,改對 RK4 細步參考解)、爆炸推動木箱)/ 整合(動畫事件開 hitbox → 命中 → 17.70 傷害 → 17.38 事件;knockback 經 17.67 累加器;ragdoll 受擊;爆炸炸開 17.5 牆;重播 / 回溯用 17.16 的位姿環;命中結果重播逐位相同)/ 極端(40 m/s 揮擊 vs 薄盾、剛好相切的接縫、掃掠途中目標 despawn、零長射線、投射物生在碰撞體內、1e5 投射物超預算、爆炸中心 == 物體質心(距離 1e-9 防護)、遮擋物在中間、友軍 / 自身過濾、hit-stop 與睡眠互動)。
> **相依**:17.49、17.53、17.46、17.64、17.66、17.67、17.70、17.37、17.5、17.27、17.25、17.31、17.23、17.16(回溯為其邊界)。
> **邊界**:傷害公式與數值屬 17.70;VFX / 貼花 / 音效以事件交宿主;網路命中登錄與延遲補償屬 17.16(本條只保證查詢可吃外部位姿);瞄準輔助與後座力的鏡頭效果屬 17.68;動畫選擇屬 17.64。

#### 17.74 載具家族 — Wave C
> **進度註(2026-10-13)**:力元件骨架先行。`gameplay/force_element.mojo`:`ForceElement` trait(`apply(scene, id, t)` 累積力並回傳)與 `Thruster`;
> `gameplay/watercraft.mojo` `HullBuoyancy[W: WaterSurface]`(凸殼以水面高度的水平面 `polytope_split` 精確切割 → 體積 + 形心 → 浮力;阻尼依浸沒量;
> 平面殼 raise);`gameplay/aircraft.mojo` `Wing`(攻角取自弦 – 法向平面內的相對風,CL = 2πα 至失速、平板 sin 2α / 2 sin²α,其間線性混合;±π 有限)。
> 量測(`tests/test_force_elements.mojo` 12/12):盒殼密度 500 浮於中心 y = 0.003(吃水 0.25 的 1.2 %);切割體積 0.6 = 閉式 0.6、形心 −0.075 = −0.075;
> 0.6 m 寬、龍骨 0.1 m 的殼從 150° 自扶正(up.y 1.0;2 m 寬殼正反皆穩定,留在翻覆 —— 先以此量到);高窄殼(GM < 0)從 3° 倒向側面(up.y 1e-6);
> 5° / 20 m/s 升力 268.6727 vs q A 2πα 268.6726;失速處 CL 1.6330 / 1.6325 連續、30° 降到 0.86;半油門 100 N 推 10 kg 1 s 後 5.0 m/s;
> 2 kN 螺旋槳的船在 0.3 m 湧浪 10 s 前進 32 m、起伏 0.92 m。`bench_force_elements`:精確切割 8.7 µs(誤差 0)vs 取樣 4³ / 8³ / 16³ 0.27 / 1.97 / 15.2 µs(誤差 0.22 / 0.03 / 0.03 m³);
> `Wing.apply` 110 ns、`Thruster.apply` 47 ns。
> **進度註(2026-10-17)**:`gameplay/vehicle_kinds.mojo`:`QuadRotor`(四旋翼混控:集體推力 / 滾轉 / 俯仰 / 偏航力矩 → 各旋翼推力,旋翼反扭矩 drag_ratio × 推力)與 `QuadController`(高度 / 姿態 / 航向 PD;垂直速度取每 tick 高度差——以 body 速度時穩態偏高 3.8 cm,同 17.66 的步首施力 / 子步重力讀數偏差);`TrackDrive`(左右履帶各 n 個接觸點,縱向 k (v_track − v) 與側向 −c v_side,上限 μ × 每點重量;車殼與地面碰撞摩擦須為 0,否則以 μ 0.5 時 2 m/s 履帶只帶到 1.59 m/s 且無法原地轉);`hitch`(拖車球關節)。`tests/test_vehicle_kinds.mojo` 8/8:混控滾轉力矩 0.4 = 指令、總推力不變、偏航反扭矩 0.05 = 指令;1 kg 四旋翼 4 s 後 y 2.000018、up.y 1.0、航向 0.999998 rad(目標 1);2 t 履帶車兩側 2 m/s 前進 1.9999998 m/s;±1 m/s 原地轉向中心移 0.45 mm、角速度 0.227 rad/s(無滑移 1.11:履帶兩端側滑,滑移轉向);拖車跟隨 4.0 m、掛點間距最大 0.3 mm。
> **上下車**:`gameplay/vehicle_seat.mojo` `Seat`(座位在車體座標、門點與可達距離、依序嘗試的下車點;`try_enter` 需空位且在門點 reach 內;`seat_pose` = 車姿 × 座位;`try_exit` 取第一個自座位直線無阻(`ray_cast_any`,忽略車體)的下車點,全被擋則留在車上)。`tests/test_vehicle_seat.mojo` 5/5:距門 3 m 拒、0.5 m 准、有人時拒;車轉 90° 移 5 m 後座位姿態 = 車姿 × 座位(1e-5);左側貼牆時從右側 x 1.6 下車;兩側皆牆則留在車上。載具快照早已存在(`Vehicle.write_state` / `read_state`,17.48,`test_vehicle` 往返),此處原列為未做是誤記。
> **未做**:轎車改寫為元件組合的 parity、機車、直升機(單旋翼 + 尾槳)、LBM 風洞取 CL(α)、`Runtime` 擁有、浪面斜率、履帶的坡道行為與地形壓痕。
> **現況**:17.4 交付的是**輪式 raycast 車**(`gameplay/vehicle.mojo:1-35` 檔頭)。輪以 `axle`(0 前、1 後)配對(`:102-111` `WheelConfig`;`:274-290` `Vehicle.__init__` 以同 axle 的另一輪為 `partner`),所以每軸超過 2 輪不支援(17.4 待辦「拖車 / 多軸 > 2 輪每軸」,ROADMAP §17.4);座標軸寫死:`:53-58` `_UP / _FWD`;輸入固定為 4 軸 `VehicleInput`(`:87-100`:油門 / 煞車 / 轉向 / 手煞);空氣動力是**單一純量**`Aero`(`:126-150`:`cd` / `cl` / 面積,無攻角);`VehicleSet`(`:733-755`)只是清單,`Runtime` 不擁有車(`gameplay/runtime.mojo` grep `Vehicle` 零命中);車輛狀態(輪速、檔位、轉向角)不入快照(同待辦)。LBM 風洞已給 Cd(`gameplay/vehicle_tunnel.mojo` 全檔,`:36` 的 boat tail 只是車形參數)。水:`physics/fields.mojo:20-28` 浸沒體積僅球 / 盒,「hull / mesh / capsule: not implemented」,水面是 AABB 頂面(無波);17.28 待辦「以平面切割凸體求精確體積取代取樣」(ROADMAP §17.28),而 `geometry/polytope.mojo:92,116,622`(`volume` / `centroid` / `polytope_split`)已有凸體切割 + 體積 / 質心。grep `\bsail|\bboat\b|hover|aircraft|airfoil|propeller|\brotor|\bthrust|\btread|caterpillar|trailer|motorcycle` 於 `gameplay physics fluid collision` 只命中 `vehicle_tunnel.mojo:36`(形狀參數)、`physics/diffsim.mojo:67`(推力衝量,非載具)與 `physics/screw.mojo:29`(rotor 指 GA 轉子)——履帶、船、飛行器、懸浮、機車、拖車皆零命中。軌道可用樣條:`geometry/spline.mojo:454-515`。載具上的 17.4 設計決定「不實作約束式車輪」(ROADMAP §17.4)。
> **缺口**:以「力元件組合」為共同骨架——現在已有部分拆分——輪地探測是 seam(`gameplay/vehicle_wheel.mojo:62` `WheelCast`:`RayWheel` / `SphereWheel` / `CapsuleWheel`)、輪胎在 `gameplay/vehicle_tire.mojo:71` `TireModel`、傳動在 `gameplay/vehicle_drive.mojo:87` `DriveConfig`——但 `Vehicle.update` 的組合是寫死的輪式管線(懸吊 → 輪胎 → 傳動 → 空氣動力),無法插入翼面 / 推進器 / 履帶等其他力元件;各載具型別拆成可組合的力 / 力矩元件(PhysX Vehicle 2 式模組化):
> - **履帶車**:左右履帶速度差的滑移轉向、側向摩擦(原地轉向)、斜坡行為;配 17.30 的履帶壓痕(ROADMAP §17.30 已提)。
> - **水上載具**:任意凸殼的精確浸沒體積(`polytope_split`)、推進器(螺旋槳推力 / 舵升力)、波面高度(解析 Gerstner)取代平面 AABB、滑行阻力。
> - **飛行器**:翼面 CL(α) / CD(α) 表含失速、操縱面偏角、推力(螺旋槳 / 噴射)、地面效應;直升機旋翼盤(總距 / 週期距);四旋翼混控。**極化曲線來源**:沿用 17.4 的做法,用 LBM 風洞 sweep 攻角取 CL / CD(`gameplay/vehicle_tunnel.mojo:1-126` 的 `car_cd` 延伸)。
> - **懸浮 / 推進器陣列**(含太空載具的 RCS 推力分配)。
> - **機車 / 自行車**(單軌傾斜與平衡)、**多軸卡車**、**拖車 / 鉸接**(掛接關節,需 17.47 的限制與馬達)、**軌道車**(輪組約束在樣條上)。
> - **通用服務**:座位 / 上下車(接 17.67 Driving 模式)、零件脫落(17.29 可斷關節)、狀態入快照、`VehicleInput` 泛化為軸陣列、`Runtime` 擁有與 ECS 元件化、17.85 分級。
> **對照組**:PhysX Vehicle SDK 2(模組化)、Jolt `VehicleConstraint`(含 `TrackedVehicleController`、`MotorcycleController`)、UE Chaos Vehicles(輪式為主,其他靠自訂 movement component)、JSBSim / X-Plane(飛行動力學)、Unity WheelCollider(僅輪式)、Godot `VehicleBody3D`。
> **優勢區**:中 ——(a)**風洞導出極化曲線**(承襲 17.4 的差異化:對照組以手填表或離線 CFD);(b)浸沒體積走自家 `polytope` 精確切割,對照取樣積分(17.28 已量:盒 8³ 約 2.3 µs、16³ 約 18 µs);(c)氣動 / 水動係數可用 17.20 可微子集由飛行紀錄反推(範例 `examples/22_diffsolver_sysid.mojo` 已示範摩擦係數的反推,載具係數尚未)。皆**待量測**。
> **規模軸**:載具數 × 力元件數(輪 / 翼面 / 推進器);極化表解析度 vs 誤差;浸沒體積取樣 vs 精確切割(成本與誤差);波面取樣點數。
> **seam?**:是 ——(1)載具建構:單體 `Vehicle.update`(現狀)vs 力元件組合 → parity:把既有轎車重寫為元件組合後,330 步加速 + 轉向的終點與現狀一致(沿用 `tests/test_vehicle.mojo` 的場景);bench 每變體一列。(2)浸沒體積:取樣積分 vs `polytope` 精確切割(17.28 seam 的延伸)→ 規則形狀下兩者一致。
> **交付**:`gameplay/force_element.mojo`(元件介面)、`gameplay/tracked.mojo`、`gameplay/watercraft.mojo`、`gameplay/aircraft.mojo`、`gameplay/hitch.mojo`;`bench_aircraft` / `bench_watercraft`。測試:普通(履帶原地轉向、船靜浮吃水深度對阿基米德(誤差 ≤ 2%,沿用 17.28 判準)、飛機爬升對解析升力)/ 整合(元件版轎車與現狀 parity;拖車隨車以 10 m/s 繞 20 m 半徑轉彎,掛接角穩態 ≤ 30° 且不發散;船受 17.27 風與 17.28 水;飛機穿過 LBM 風場;玩家上下車切 17.67 模式;載具快照→還原→續跑逐位相同)/ 極端(失速與攻角 ±π、翻覆船:穩心高度 GM > 0 的船殼自扶正、GM < 0 的船殼保持翻覆(兩組船殼各斷言其一)、履帶單側卡死、拖車 90° 折疊(jackknife)、極低 / 高密度流體、浸沒體積在殼面共面時、載具瞬移、零推力零油門)。
> **相依**:17.4、17.28、17.27、17.29、17.47(關節限制 / 馬達 / 掛接)、17.30、17.36、14.4(LBM 風洞)、17.67、17.40、17.85。
> **邊界**:載具模型與音效(引擎聲)屬宿主;AI 駕駛屬 17.15(轉向行為);鏡頭屬 17.68;大範圍水面 / 波浪的網格流體模擬屬 17.60,本條只取解析波面;完整 CFD 不在此。

---

## gameplay 服務、AI、導航與網路

範圍:規則框架、AI、導航、rollback。

| 編號 | 條目 | 狀態 | Wave | 說明 |
|---|---|:-:|:-:|---|
| 17.14 | [導航](#1714-導航) | ✅ | C | 新套件 `nav`(layer 3):navmesh bake(體素 → 緊湊場 → 侵蝕 → tile 矩形)、尋路 seam(多邊形 A* + funnel / 格 A* / 流場 / HPA*)、off-mesh link、動態障礙增量挖洞、crowd 與避讓 seam(ORCA / 取樣 RVO / 社會力)、3D 體積導航(稀疏體素八叉樹 A* vs 稠密體素 A*)。 |
| 17.15 | [AI 框架](#1715-ai-框架) | ✅ | C | 新套件 `ai`(layer 4):blackboard、behavior tree(迭代 tick)、utility AI、GOAP / HTN、決策 seam(BT / FSM / utility / GOAP)、感知(視錐 + 宿主視線批次、聽覺、記憶)、EQS、轉向 / 群聚 / 隊形、smart objects、影響力圖與隊伍戰爭迷霧。 |
| 17.16 | [網路 / rollback](#1716-網路--rollback) | ✅ | C | `gameplay/netcode.mojo`:`NetSim` 契約、預測策略 seam(`LockstepPeer` / `RollbackPeer` / `SnapshotServer` + `SnapshotClient`)、位元組訊息(冗餘輸入 + ack、XOR + RLE 差分快照)、雜湊交換失步偵測、輸入驗證、延遲補償(`PoseRing` + `rewind_ray_cast`);傳輸層交宿主。 |
| 17.70 | [規則框架](#1770-規則框架--wave-c) | 🔶 | C | 屬性集、Gameplay tags、效果、技能、傷害管線、資料驅動 |
| 17.72 | [流程服務](#1772-流程服務--wave-c) | 🔶 | C | 流程狀態堆疊、全域旗標 / 黑板、任務 / 目標圖、對話 / 敘事狀態、關卡切換協定、檢查點 / 重生 |
| 17.73 | [營運邊界](#1773-營運邊界--wave-c) | 🔶 | C | 對外 outbox、遙測分流、成就 / 統計計數、本地化鍵、入站資料決定論、黑盒記錄器 |

### 待辦與部分完成條目

#### 17.14 導航

> **狀態**:✅ 完成(Wave C;剩餘順序第 (1) 項)。2026-10-11 交付,設計筆記 `docs/design/17.14-navigation.md`。
> **進度(2026-10-11)**:新套件 `nav`(layer 3,只依賴 `geometry`)。
> - `nav/heightfield.mojo`:Recast 式體素化(逐格裁切三角形,排除格線上的零寬切片)、low-hanging / low-height 過濾、緊湊場(4 鄰接)、2/3 chamfer 侵蝕;`erode_window` 是視窗版,窗內結果與全場相同(單調最短路論證寫在註解,測試逐位驗證)。
> - `nav/navmesh.mojo`:每 tile 貪婪矩形合併成凸多邊形(取代 watershed / 輪廓 / 三角化)、portal 連結(建立時定好左右)、`raycast`(Amanatides–Woo,沿連通關係走)、off-mesh link(單 / 雙向、成本倍率)、動態障礙 `add_obstacle` / `remove_obstacle` / `update`(只重算變動窗並重建被觸及的 tile)、`height_at`(span 地板 + 中央差分坡度)。
> - `nav/path.mojo`:`PathFinder` seam —— `PolyFunnel`(多邊形 A*,Detour 成本模型 + simple stupid funnel + 可見性平滑)、`GridAStar`(8 連通 span,不切角)、`FlowFieldPath` / `FlowField`(每目標一張 Dijkstra 積分場,O(1) 方向讀取,依 `mesh.version` 失效)。
> - 測試:`test_nav`(44:繞牆、窄於 2r 的縫、坡道、0.3 / 0.6 m 台階、1.0 m 低天花板、地板洞、off-mesh 單向、挖洞 == 全量重建、移除後還原、起點離網、起終點相同、錯誤輸入)、`test_nav_parity`(5:300 個種子查詢,三變體可達性相同、格 A* 長度 == 流場長度、所有行走段通過 raycast、funnel 與 octile 長度在寫明的經驗界內;octile / funnel 平均 1.063)、`test_nav_world`(6,integration:同一三角形給 `bake_navmesh` 與 `ContactScene6.add_trimesh`,路徑上 109 個取樣點的 navmesh 高度與物理射線地面差最大 0.125 m;落在坡上的箱子停在 navmesh 高度;12 次隨機增刪障礙每步 == 全量重建)。
> - 量測(`bench_nav`,64 m 迷宮,65 k span):烘焙 47 ms(32 m 12 ms、128 m 210 ms,線性);每查詢 `PolyFunnel` 16 µs(展開 41 個多邊形)、`GridAStar` 1.2 ms(展開 2347 span)、`FlowFieldPath` 12.6 ms(每目標建場);5000 agent 同目標:逐 agent funnel 168 ms vs 建一張流場 15 ms + 5000 次讀取 1.1 ms;1 m 障礙 incremental update 1.2 ms(4 tiles)vs 全 tile 重建 8.2 ms vs 重新烘焙 43 ms。
> - 與 Recast 的差異:多邊形是 tile 內矩形(數量較多,無輪廓簡化參數);ledge 過濾由侵蝕吸收;連結重建是全域(與多邊形數線性),是 incremental update 的主要剩餘成本。
> - Crowd(`nav/crowd.mojo`):`Crowd[A: Avoidance]`(均勻格鄰居、偏好速度含 5 % 右手偏置、`NavMesh.move_along` 逐格滑牆、可見性推進 corner、corner 看不見時冷卻式重新規劃、off-mesh 直線穿越);避讓 seam `Orca`(RVO2 LP 逐行移植)/ `SampledRvo` / `SocialForce`。`test_crowd`(52:對心交換 16、走廊對衝 12、單門 12、4 個重疊出生、off-mesh 跳躍,三變體全員到達、不離網、逐位決定論,重疊依場景設界)。`bench_crowd`(64 m 柱陣、目標 20 m 內、40 s):每 agent-tick ORCA 0.32 / 0.43 / 1.37 µs(N = 64 / 256 / 1024)、社會力 0.34 / 0.51 / 1.41 µs、取樣 RVO 2.7 / 6.3 / 15.0 µs;N = 1024 最深重疊 ORCA 34 mm、社會力 43 mm、取樣 RVO 512 mm;到達率 91–100 %。
> - 3D 體積導航(`nav/volume.mojo`):三角形經同一個逐格裁切光柵器成為佔據體素,依 agent 半徑做可分離盒膨脹,補成 2 的冪立方體後以 summed-volume table O(1) 判斷節點是否均勻,建稀疏體素八叉樹;自由葉為圖節點,共面者相鄰。seam `VolumeFinder`:`SvoAStar`(portal 成本模型 + 視線平滑)vs `SmoothedVoxelAStar`(26 連通不切角 + 同一平滑);`line_of_sight` 是 3D Amanatides–Woo,過邊 / 角時所有碰到的體素都要空。`test_nav_volume`(19:無人機從窗戶進入建築、窗寬 < 直徑時無路、目標在牆內、空體積一個葉、60 個種子查詢兩變體可達性相同、所有線段有視線、長度差 15 % 內)。`bench_nav`:64 × 16 × 64 m(433 萬體素)建樹 271 ms、7.3 萬自由葉;每查詢 SVO 1.4 ms(展開 1705)vs 稠密體素 246 ms(展開 12.7 萬),同長度。
> - 階層式長程尋路(`nav/hpa.mojo`):HPA*,cluster = navmesh tile;portal 圖(portal 中點 + off-mesh 端點,同一凸多邊形上的兩點以直線相連)、tile 邊界上的 entrance、每個 entrance 在其 tile 內一次 Dijkstra 得到抽象邊;查詢在抽象圖上 A*,再以粗路徑經過的 tile 為遮罩跑 `PolyFunnel`。依 `mesh.version` 重建。`test_nav_parity` 把它列為第四個變體(400 個查詢含挖洞後 100 個:可達性一致、長度界相同、長查詢只細搜粗路徑上的 tile)。`bench_nav`(128 m 迷宮、1089 tiles、100 個長查詢):抽象圖建置 3.6 ms(2305 entrances);每查詢 HierFunnel 171 µs vs 平面 `PolyFunnel` 123 µs —— 在這個尺度上**更慢**,量到的好處是局部性:只細搜 1089 個 tile 中的 32 個(串流世界只需載入這些 tile 的細 navmesh)。
> **遺留待辦**:連結的增量重建(incremental update 的主要剩餘成本)、navmesh 邊界作為 ORCA 靜態障礙線(恢復牆邊的無碰撞保證)、學習式避讓權重(可微 ORCA)、HPA 抽象圖只重建髒 tile(目前 version 變動即全量重建,3.6 ms)、與 17.8 world partition 串流接線(HPA 的 cluster 改用 partition cell)。
> **現況(開工前)**:無(舊「明確不做」,已被 [[no-tech-exclusion-principle]] 推翻)。
> **缺口**:navmesh bake(voxel → region → contour → 三角化)、A* / funnel(string-pulling)、動態障礙挖洞、crowd + 區域避讓(RVO / ORCA)、off-mesh link、tile 重烘。
> **增補缺口(2026-10-09 負空間盤點,本節尚未開工故直接擴充範圍)**:
> - **流場尋路**:每個目標算一次 integration field + 方向場,同目標的大量單位 O(1) 讀方向(例:5000 個 RTS 單位走向同一集結點,不跑 5000 次 A*)。grep `flow.?field|流場尋路` 於 docs / 程式碼只命中 LBM 的「流場」。pathfinder seam 加一個變體。
> - **3D 體積導航**(飛行 / 游泳 agent):稀疏體素八叉樹 + 3D A*(例:無人機敵人穿過建築內部空間)。navmesh 只處理可行走表面;既有 `spatial/` 八叉樹是寬相索引,不是導航圖。
> - **階層式長程尋路**(HPA* / 每個 partition cell 一份 navmesh):公里級分區世界先在抽象 cluster graph 上粗規劃,只有已載入的 cell 持有細 navmesh;接 17.8 world partition。
> **對照組**:Recast / Detour、DotRecast、UE Navigation System、Unity NavMesh;避讓:ORCA(van den Berg);增補:Unity DOTS 流場範例 / Supreme Commander 2 flow field、UE Mass 的 3D 導航插件、HPA*(Botea 2004)。
> **優勢區**:中 ——(a)navmesh bake 是體素 / 幾何運算,可用既有 SDF3(13.8)/ predicates(10.1)/ BVH;(b)ORCA 的線性規劃可微 → 學習式避讓權重(對照 hand-tuned);(c)island 平行(6.11)可平行 agent 更新。
> **規模軸**:agent 數(crowd 鄰居前的規模軸)、navmesh 多邊形數、動態重烘的 tile 成本。
> **seam?**:是 —— 避讓演算法(RVO / ORCA / 力場)對同場景的無碰撞率 + 到達時間 parity;pathfinder(A* / JPS / funnel / 流場)路徑等價類。
> **交付**:普通(單 agent 繞牆)/ 整合(crowd 對衝不卡死、動態障礙即時挖洞、與物理地面一致)/ 極端(無路徑、瓶頸門、agent 重疊出生、navmesh 破洞)。
> **相依**:17.8(partition 與串流,階層式尋路用)。

#### 17.15 AI 框架

> **狀態**:✅ 完成(Wave C;剩餘順序第 (2) 項)。2026-10-12 交付,設計筆記 `docs/design/17.15-ai.md`。
> **進度(2026-10-12)**:新套件 `ai`(layer 4,依賴 `nav` 與 `procedural.fsm`;不依賴 `collision`,視線由宿主批次查詢)。
> - `ai/blackboard.mojo`:整數鍵、`Vec3` 值、set 位元與版本;`CMP_*` 資料驅動條件。
> - `ai/bt.mojo`:共享定義(扁平陣列)+ 每 agent `BtState`;sequence / selector(記憶式或 reactive,後者搶占並經 `BtHost.abort` 中止低優先分支)、parallel(N 成功門檻,已完成子節點保留狀態)、inverter / succeeder / repeat / cooldown / guard(含 abort)/ service、action / condition / check / wait。tick 是**迭代**(顯式 frame 堆疊放在 `BtState` 重用):遞迴第一版在 ~2000 深度爆堆疊,現在測 20 000 深;13 節點樹 249 ns / tick。
> - `ai/utility.mojo`:考量(線性 / 多項式 / logistic / 階躍 / 反階躍曲線)、Dave Mark 補償因子、momentum 遲滯。
> - `ai/planner.mojo`:GOAP(64 位事實集,A*,啟發式 = 錯誤位元數 × 最便宜動作成本 / 64,可採納;展開預算)與 HTN(依序方法、回溯、深度上限)。
> - `ai/decision.mojo`:seam `Decider` —— `BtDecider` / `FsmDecider`(`procedural.fsm.StateMachine` + 黑板守衛)/ `UtilityDecider` / `GoapDecider`(目標優先序 + 相關性條件)。
> - `ai/perception.mojo`:兩階段視覺(候選射線 → 宿主批次視線 → commit)、聽覺(半徑 × 聽力倍率)、記憶(過期、同 tick 視覺蓋過聽覺)、寫入黑板。
> - `ai/eqs.mojo`:grid / ring / 清單生成、投到 navmesh、距離 / 朝向 / 路徑長 / navmesh 可見 / 宿主外部值測試、過濾、正規化計分。
> - `ai/steering.mojo`:seek / flee / arrive / pursue / evade / wander / 沿路徑;`Flock`(均勻格 boids,最低速度);`Formation`(line / column / wedge 槽位)。
> - `ai/smart_objects.mojo`:槽位 tag、保留 → 佔用 → 釋放、保留逾時、停用物件、每 agent 一槽。
> - `ai/influence.mojo`:影響力圖(stamp、Champandard 傳播、牆擋、層組合)與 `TeamVision`(supercover 格線視線、可見 / 已探索)。
> - 測試:`test_ai_decision`(12:同一守衛行為四種寫法,600 tick 劇本與 2000 個隨機黑板逐一與規則一致;小隊共享黑板)、`test_ai_bt`(25:記憶 / reactive 搶占與中止、guard abort、parallel、repeat、cooldown、wait、service、20 000 深鏈、結構錯誤、1 萬 agent)、`test_ai_planner`(19)、`test_ai_steering`(19:arrive / pursue 比 seek 快 / evade / 沿 L 路徑 / wander 決定論 / 群聚局部對齊 > 0.95 / 隊形)、`test_ai_smart`(17:三 NPC 佔三座位、第四個沒有)、`test_ai_influence`(18:牆擋影響力、控制層變號、牆後不可見、已探索保留)、`test_ai_perception`(21)、`test_ai_world`(15,integration:物理世界射線當視線 → 黑板 → BT:巡邏 → 追擊 → 搜索 → 記憶過期回巡邏、聽覺喚醒、EQS 搜索點在 navmesh 上且不在牆內)。
> - 量測(`bench_ai`,1 萬 agent × 10 tick 每次決策):utility 103 ns、FSM 180 ns、BT 747 ns、GOAP(每次決策都規劃)1.07 µs;GOAP 鏈式領域 64 個動作規劃 39 µs;BT 13 / 769 節點 249 ns / 14 µs;群聚 1 萬條魚 0.50 µs / boid-step;感知候選 1000 × 1000 暴力 7.4 ns / 對;EQS 441 點 149 µs;影響力傳播 68 ns / cell-iteration。
> - 量測中發現並修正:群聚用全速 seek 做 cohesion 且無最低速度時,密集魚群停滯、方向抖動(局部對齊 ~0.5);加最低速度後 0.999。
> **遺留待辦**:BT tick 入 10.2 job graph 依讀寫集平行(目前逐 agent 串行)、EQS 打分可微、感知候選用空間格取代暴力 O(N·M)、EQS 排序改 O(n log n)(現為插入排序)。
> **現況(開工前)**:僅 FSM / HSM(`procedural/fsm.mojo`)。
> **缺口**:behavior tree(decorator / service / 平行節點)、utility AI、blackboard、perception(視錐 / 聽覺 / 記憶)、EQS 式空間查詢(接 17.13)。
> **增補缺口(2026-10-09 負空間盤點,本節尚未開工故直接擴充範圍)**:
> - **轉向行為 / 群聚 / 隊形**:Reynolds seek / flee / arrive / pursue / evade / wander / path-follow、boids(separation / cohesion / alignment)、隊形槽位與跟隨隊長(例:1 萬條魚群用 hash grid 鄰居查詢、8 人小隊沿 navmesh 路徑保持楔形)。17.14 只規劃了避讓(RVO / ORCA / 力場),seek / arrive / 群聚 / 隊形不在其中。
> - **GOAP / HTN 規劃器**:以前置條件 / 效果搜尋動作序列(例:冷了 → 拿斧 → 砍樹 → 生火);作為決策 seam 的第四個變體(BT / FSM / utility / planner)。grep `GOAP|HTN|planner` 零命中。
> - **Smart objects / 互動點**:物件公告可佔用的互動槽(坐、使用、開門),含預約與標籤(例:三個 NPC 各佔一個長椅座位,第四個找不到空位)。
> - **影響力圖 / 戰爭迷霧 / 可見性格**:戰術用純量格(威脅、控制)與以視線計算的每隊可見性(例:RTS 只顯示各單位視野半徑內、被地形遮擋後的區域)。本節 perception 是單 agent 感知,不是隊伍層級的格;視線查詢用 17.13 `ray_cast`(`collision/world_query.mojo:5` 模組說明已點名 AI line-of-sight 為用途)。
> **對照組**:UE Behavior Trees + EQS、Unity Behavior、通用 BT 函式庫;增補:Craig Reynolds steering、F.E.A.R. 的 GOAP、Horizon / Killzone 的 HTN、UE Smart Objects、RTS 迷霧實作。
> **優勢區**:低 —— 純 gameplay。小加值:BT tick 可入 10.2 job graph 依讀寫集自動平行;EQS 打分可微。
> **規模軸**:agent 數 × 樹節點數 × tick 率;EQS 查詢取樣密度;boids 數 × 鄰居半徑;planner 動作數 × 搜尋深度;格解析度。
> **seam?**:是 —— BT vs FSM vs utility(vs planner)對同一決策問題的行為等價(可定義的情境集)+ tick 成本 row。
> **交付**:普通(巡邏→追擊→搜索)/ 整合(perception 接 17.13、多 agent 共享 blackboard)/ 極端(空樹、深遞迴、每 tick 目標消失、1e4 agent)。
> **歷史**:原現況寫「僅 `scheduler/fsm.mojo`」,實際檔案位置為 `procedural/fsm.mojo`。

#### 17.16 網路 / rollback

> **狀態**:✅ 完成(Wave C;剩餘順序第 (4) 項)。2026-10-12 交付,設計筆記 `docs/design/17.16-netcode.md`。
> **進度(2026-10-12)**:`gameplay/netcode.mojo`。
> - 契約 `NetSim`(players / tick / step(每人一個輸入)/ save / load 精確位元組 / hash);具體實作 `ArenaSim`(箱子玩家 + 可推木箱,`ContactScene6`)。`physics/serialize.mojo` 新增固定寬度二進位快照 `scene_to_bytes` / `scene_from_bytes`(欄位位移固定,XOR 差分才大多為零)。
> - `PlayerInput` 12 位元組;輸入訊息帶寄送者、對收件者輸入的 ack、最新最終雜湊與收件者尚未 ack 的全部本地輸入(冗餘,丟包與亂序不需重傳協定)。
> - 預測策略 seam `NetPeer`:`LockstepPeer`(全員輸入到齊才步進)、`RollbackPeer`(GGPO:以「重複上一個確認輸入」預測、快照環、遲到輸入與預測不同就載回該 tick 快照重模擬;預測深度不超過環,寧可停也不超前)、`SnapshotServer` + `SnapshotClient`(伺服器對客戶端輸入做 lockstep,每 3 tick 取快照,對每個客戶端已 ack 的快照做 XOR + 零位元組 RLE 差分,新快照送一次、未 ack 8 次 update 後重送)。
> - 失步偵測:每個 peer 保存以確認輸入步進的每 tick 雜湊(rollback 在 tick 全部輸入確認且無待處理回滾時才轉為最終),訊息帶最新一筆,不同即記 `desync_tick`。
> - 輸入驗證 `InputValidator`(冒名、過舊、過遠、與已收到同 tick 輸入矛盾)與 `motion_plausible`(宿主信任位置的速度檢查);延遲補償 `PoseRing` + `rewind_ray_cast`(以過去 tick 的碰撞體位姿做射線)。`SimLink` 是測試用的決定論行程內連線(延遲、抖動、丟包),不是傳輸層。
> - 開發中發現並修正:快照沒有存 island 標籤,還原後 `wake` 把所有睡眠 body 都喚醒(而非一個 island),rollback 重模擬在第一次喚醒時與原始執行分岔(第 30 tick);標籤已入快照 v3。
> - 測試 `test_netcode`(28,integration:3 玩家、240 tick、延遲 + 抖動 + 10 % 丟包,lockstep / rollback / 快照伺服器 + 3 客戶端最終世界雜湊皆 == 離線套用同一輸入;rollback 實際回滾 181 次、重模擬 1094 tick;2-tick 環在 8 tick 延遲下仍精確;一個 peer 的世界被改動時雜湊交換回報失步;差分快照 1574 B / frame vs 全快照 4952 B;驗證、速度檢查、差分編解碼、截斷訊息、延遲補償:目標 7 tick 前的位置對現在射線落空、回溯命中)。
> - 量測(`bench_netcode`,3 玩家、240 tick、2 tick 抖動、5 % 丟包):延遲 2 / 6 tick 時,lockstep 顯示落後 3 / 7 tick、每 frame 0.25 / 0.24 ms;rollback 落後 0、每 frame 1.15 / 2.19 ms(615 / 605 次回滾、2084 / 4471 tick 重模擬);快照客戶端落後 7 / 15 tick、每 frame 0.14 / 0.16 ms、1.8 / 2.3 kB / frame(3 個客戶端合計)。
> **遺留待辦**:interest management(依 17.85 `CausalReach` 只送相關 body 的部分快照)、authority / ownership(目前全部由輸入驅動)、客戶端插值顯示(`SnapshotClient` 只保留最新快照)、時鐘漂移與動態輸入延遲、跨平台 f32(依決定論邊界不做)。
> **決定(2026-10-09)**:平台方向 C → **傳輸層與線路格式交給宿主**;引擎提供 rollback 核心、預測策略 seam(lockstep / predict-rollback / snapshot-interp)與給宿主傳送的 byte payload API。權威模型以 lockstep + rollback 為主;決定論只承諾**同工具鏈、同架構**(不做跨平台定點 / 軟浮點)。
> **現況**:刻意未做。**地基已在**:決定論 RNG(`scheduler/rng.mojo`)、actor model(10.3)、全狀態快照(6.10)、17.39 replay 的逐 tick FNV-1a 雜湊與 `first_divergence`(目前只用於 replay QA)。
> **缺口(引擎內)**:snapshot ring buffer + 重模擬(rollback)、input prediction / server reconciliation、delta 壓縮 state replication、authority / ownership、interest management、給宿主傳送的 byte payload API。
> **增補缺口(2026-10-09 負空間盤點,本節尚未開工故直接擴充範圍)**:
> - **延遲補償 / 伺服器回溯命中**:保留短期 collider 位姿環形緩衝,讓伺服器對「射擊者 N ms 前看到的世界」做 raycast / overlap,不必整個世界 rollback(例:120 ms 延遲的爆頭,對目標 7 tick 前的位姿判定)。零件:`collision/world_query.mojo:566-573` 的 `ray_cast` 已接受外部 `poses: List[Pose3]`;缺的是位姿歷史環(`gameplay/interpolation.mojo:96` 的 `PoseHistory` 只存 prev / curr)與回溯查詢服務。
> - **伺服器端輸入驗證與失步偵測**:拒絕不可能的輸入 / 位移(速度上限、瞬移偵測),各端交換每 tick 狀態雜湊偵測 desync(例:回報速度超過衝刺上限 3 倍的客戶端被拉回)。零件:17.39 的逐 tick FNV-1a 雜湊(`gameplay/replay.mojo:86` `checksum`)與 `first_divergence`。
> **邊界**:lockstep 傳輸層與線路格式交宿主;跨平台決定論(不同編譯器 / 架構)不做,只保證同工具鏈(16 章鎖版本是半個答案);反作弊的帳號 / 封禁 / 用戶端防護屬宿主與線上服務。
> **對照組**:GGPO / rollback netcode、UE Iris / Replication Graph、Unity Netcode for Entities、Photon Quantum(決定論 lockstep);增補:Valve Source 的 lag compensation、Overwatch 的 hit registration、GGPO desync 檢查。
> **優勢區**:中高 —— **差異化方向**:(a)既有 bit-identical 決定論 + 快照 → rollback 最難前提已滿足;(b)actor model 訊息重放天生對 lockstep 友善;(c)可微 + 決定論 → 學習式預測補償。
> **規模軸**:rollback 幀深 × 每幀重模擬成本、封包大小 vs 實體數、玩家數;回溯深度(tick)× collider 數的記憶體;每 tick 雜湊成本。
> **seam?**:是 —— 預測策略(pure lockstep / predict-rollback / snapshot-interp)對同輸入序列的最終世界 parity;各自頻寬 / CPU row。
> **交付**:普通(2 端同輸入 → 逐位相同世界)/ 整合(丟包重排下重模擬收斂、與 CCD / island sleep 相容)/ 極端(rollback 深度上限、當幀族群變動、時鐘漂移、跨平台 f32)。
> **歷史**:原標「部分 gated」—— 傳輸層 / 線路格式綁定平台整合(同 13.9 / 17.12);原缺口列有「lockstep 傳輸層」與「跨平台決定論(不同編譯器 / 架構 —— 目前只保證同工具鏈,16 章鎖版本是半個答案)」。2026-10-09 決定後兩者改為交宿主 / 不做。

#### 17.70 規則框架 — Wave C
> **進度註(2026-10-13)**:`gameplay/rules.mojo`:`Attributes`(定點 1/1000 整數、加 / 乘(千分比和)/ 覆寫(最高優先序)、夾限、三種求值器
> `EVAL_FULL` / `EVAL_INCREMENTAL` / `EVAL_DIRTY`)、`TagRegistry`(階層名稱駐留、父 tag 位元一併設定、≤ 64 個)、`EffectDef` / `Rules`(瞬發 / 持續 / 無限 / 週期,
> `STACK_REFRESH` / `STACK_COUNT`,授予 tag、免疫 tag 擋下,冷卻 = 授予自身擋 tag 的效果)、傷害管線(抗性 → 護盾 → 生命、死亡回報一次)、`actor_to_bytes` / `actor_from_bytes`
> (效果實例與到期 tick 一併入位元組,解決計時器不入快照)。量測(`tests/test_rules.mojo` 15/15):+20 % buff 5.000 → 6.000、於 tick 300 恰好結束;
> 火焰 DoT 10 / 30 tick × 300 tick 恰扣 100;冷卻期間拒絕、到期後可用;STACK_COUNT 上限 3、STACK_REFRESH 延長到期 +100;三求值器在 20000 步種子序列的 4002 次讀取全同;
> 效果進行中存檔 → 還原 → 400 tick 後位元組相同;25 % 抗性 + 30 護盾使 100 傷害扣 45;同 tick 兩次致命一個死亡;重複移除回 False;零持續至下一 tick。
> `bench_rules`(1000 角色 × 4 屬性、每 tick 10 % 變動):每次讀取 K = 4 / 16 / 64:全量 87 / 148 / 888 ns、增量 48 / 92 / 576 ns(仍掃覆寫)、髒快取 17 / 29 / 137 ns。
> **未做**:技能(消耗 / 取消 / 目標)、資料驅動表(17.11 反射)、17.71 命中 → 傷害接線、`Runtime` / ECS 元件化、覆寫的增量索引、`oop` 對照、1e6 修飾器量測。
> **現況**:引擎內**沒有**。grep `GameplayEffect|GameplayTag|AttributeSet|cooldown|[Ss]tatus.?effect|\bbuffs?\b|\b[Mm]odifier` 於 `gameplay ecs scheduler physics procedural` 只命中 `scheduler/timers.mojo:20` 一則註解(「冷卻、短延遲」是計時器的常見用途);health / damage 只存在於 benchmark / 測試 / 範例的玩具 fixture(`benchmarks/bench_scheduler.mojo:49-61`、`tests/test_scheduler_parity.mojo:49-63` 的 `Health` / `Damage` / `DamageCmd`,`examples/19_reactive_commands.mojo:28` 的 `Health` + `Poisoned`),引擎套件(排除 `tests benchmarks examples`)grep `health|Health|damage|Damage` 僅命中文件字串(`scheduler/scheduler.mojo:9,11`、`physics/solver6.mojo:593` 的爆炸示例、`ecs/hierarchy.mojo:5`)與無關的 `collision/hull.mojo:57`。可用積木:決定論計時器 `scheduler/timers.mojo:1-50`(`TimerHeap` / `TimerWheel`,觸發序 = `(due_tick, 排程序號)`);事件通道 `scheduler/events.mojo:1-40`;反射 `ecs/schema.mojo:47` `TypeSchema`;存檔 `gameplay/save.mojo:70-196` 按欄位名讀寫;回放雜湊 `gameplay/replay.mojo:86`;ECS 元件 `ComponentType`(`comptime ID`,見 `bench_scheduler.mojo:49-52`);關係 `ecs/relations.mojo:55` `RelationStore`。**注意**:`Runtime` 的 `timers`(`gameplay/runtime.mojo:85`)與 `SimState`(`gameplay/replay.mojo:38-49`)都不含計時器狀態——grep `TimerHeap|TimerWheel` 於 `physics gameplay` 只命中 `runtime.mojo`,計時器不入快照,效果持續時間若靠它就無法存檔 / 回放。比較基準:`oop/engine.mojo`(層 6,OOP 對照引擎)。
> **缺口**:
> - **屬性集**:基礎值 + 修飾器堆疊(加 / 乘 / 覆寫、優先序、來源 handle)→ 衍生當前值;夾限;meta 屬性(傷害 → 生命)。
> - **Gameplay tags**:階層名稱(`State.Burning.Fire`)駐留成整數,tag 容器以位元集存放,查詢 has-any / has-all / blocked(例:免疫火焰)。
> - **效果**:瞬發 / 持續 / 無限 / 週期(以決定論計時器 tick)、堆疊策略(刷新 / 層數 / 逐來源)、授予 tag、到期移除、套用條件與免疫。
> - **技能**:啟動條件(消耗、冷卻 = 效果、tag 閘)、取消;目標由 17.71 命中結果餵入;cue = 事件(宿主播 VFX / SFX)。
> - **傷害管線**:生命 / 護盾 / 護甲分層、依類型抗性、暴擊、過量傷害、死亡事件、治療,順序確定。
> - **資料驅動**:定義放表(17.11 反射),而非寫死函式;裝備 / buff 作修飾器來源。
> - **狀態入快照**:效果實例與其計時器納入 6.10 / 17.40 / 17.39(解決上面的計時器未入快照問題)。
> **對照組**:UE Gameplay Ability System(GAS:AttributeSet / GameplayEffect / GameplayTag)、Godot 與 Unity 社群的 GAS 類外掛、Dota 2 式 modifier 堆疊、4X / RPG 遊戲的 stat modifier 慣例。
> **優勢區**:低-中 —— 純 gameplay。可主張的:(a)全狀態是值型別 + tick 計時 ⇒ 回滾 / 回放 / 存檔相容(多數對照組以物件圖 + 牆鐘計時,不保證重現);(b)SoA 屬性欄位 vs OOP 物件圖,`oop` 套件正是量測對照組的地方。**不預設優勢,先量**。
> **規模軸**:實體數 N(1e3–1e6)× 每實體修飾器數 K(0–64)× 每 tick 變動比例;週期效果 tick 率。
> **seam?**:是 —— 屬性求值:每次從堆疊全量重算 vs 增量(加減差)vs 髒標記延遲重算 → parity:任意(種子化)套用 / 移除序列後三者的當前值相同;條件 =**規範化求值序**,增量變體限定在精確可交換的運算(定點整數),避免浮點漂移;bench 掃 K × 變動比例。
> **交付**:`gameplay/rules.mojo`(屬性 / tag / 效果 / 技能 / 傷害管線)。測試:普通(+20 % buff 到期、冷卻、堆疊上限)/ 整合(17.71 命中 → 傷害管線 → 死亡事件經 `Channel` → `Runtime.despawn`;效果狀態存檔再載入 / 回放雜湊一致;`oop` 對照)/ 極端(層數溢位夾限、同一修飾器移除兩次、對已 despawn 實體套用(陳舊 handle)、零長持續時間、負屬性夾限、同 tick 雙方致命傷害的結算序、1e6 修飾器、整數溢位)。
> **相依**:17.11、17.35、17.38、17.39 / 17.40、17.37(效果實例池)、17.77(ECS 表達力)、17.71、17.15(utility AI 讀屬性)、17.49。
> **邊界**:血條等 UI、VFX / SFX 播放(以事件交宿主)、平衡數值與內容屬設計;背包 / 戰利品 / 任務屬 17.72;網路複製屬 17.16。

#### 17.72 流程服務 — Wave C
> **進度註(2026-10-13)**:`gameplay/flow.mojo`(`FlowStack`:push / pop、頂端狀態以 `TICK_SIM` / `TICK_TIMERS` / `TICK_EVENTS` 遮罩決定誰 tick;`Flags`:
> INT / BOOL / FX 型別旗標、僅實際變更進 `changed`、按名稱 `to_bytes` / `load`,型別改變 raise)、`gameplay/objectives.mojo`(`ObjectiveLog`:事件型別計數目標、
> 前提、選用、`DISPATCH_LINEAR` / `DISPATCH_INDEXED`;前提只能指向較早目標 → 循環在 `add` 時 raise;解鎖於同一事件者從下一事件起算)、`gameplay/inventory.mojo`
> (`Inventory` 堆疊上限、溢出回傳;`LootTable` 權重 + `Pcg32` 種子)。量測(`tests/test_flow.mojo` 14/14):暫停 / 選單堆疊依序;任務依事件序完成、鎖定時事件不計;
> 線性與索引派發 300 目標 × 5000 事件完成序相同;10 萬次掉落 70.011 / 25.002 / 4.987 %(權重 70 / 25 / 5)、權重 0 未出現;檢查點(旗標位元組 + 目標 / 背包複本)死亡後還原相同。
> `bench_flow`:每事件 N = 100 / 1000 / 10000:線性 434 / 3115 / 26267 ns、索引 197 / 588 / 4784 ns(首版每事件快照全部目標的活躍狀態,索引只快 2×;改為只快照聆聽者)。
> **未做**:`checkpoint.mojo`(與 17.40 存檔 / 6.10 快照的正式接線、RNG 狀態)、對話圖、關卡切換協定、世界分區事件、`Recorder` 含流程狀態、旗標事件 → 目標的接線。
> **現況**:只有零件,沒有流程。`gameplay/runtime.mojo:70-101` `Runtime` 擁有 world、scene、固定步迴圈、事件通道、計時器,但**沒有遊戲狀態 / 關卡 / 暫停概念**;時間縮放與暫停被路線圖明列為「由呼叫端縮放或跳過 `frame_dt` 即可」(ROADMAP §17.23–17.41 增補「拒絕(5)」,`scheduler/gameloop.mojo:31-45` `advance(…, frame_dt)`)。grep `[Qq]uest|[Dd]ialogue|[Oo]bjective|[Cc]heckpoint|[Ii]nventory|\bloot|GameState|ScreenStack|LevelStream|[Cc]utscene|Timeline|\bpause` 於全樹 `.mojo` 命中的 `checkpoint` 僅是自動微分的檢查點(`physics/diffsim.mojo:97`、`physics/adjoint.mojo:94`、`benchmarks/bench_diffsim.mojo:142`),`inventory` / `quests` 只是存檔測試的區段名 fixture(`tests/test_save.mojo:73,127`),其餘為無關的英文字串,引擎套件內遊戲層面零命中。全域旗標 / 黑板:grep `resource|singleton|blackboard` 於 `ecs scheduler gameplay` 零命中(17.15 只在計畫中提 blackboard,ROADMAP §17.15)。已有的可組裝件:階層狀態機 `procedural/fsm.mojo:18`(history、事件冒泡,無堆疊 / push-pop)、事件 `scheduler/events.mojo:1-40`、計時器 `scheduler/timers.mojo:1-50`、存檔 `gameplay/save.mojo:70-196`(具名區段、按欄位名升版)、回放 / 快照 `gameplay/replay.mojo:101-158`(`Recorder`、`seek`)、反射 `ecs/schema.mojo:47`。17.12 場景格式「跟宿主走、本輪不做」(ROADMAP §17.12)。
> **缺口**:
> - **流程狀態堆疊**:Boot → Menu → Loading → Playing → Paused → GameOver,可 push / pop(暫停疊在遊玩上),各狀態宣告哪些子系統 tick(模擬 / 計時器 / 事件)——把「呼叫端跳過 `frame_dt`」正式化。
> - **全域旗標 / 黑板**:型別化 key→value、變更發事件、入存檔。**本條擁有世界 / 工作階段層級的旗標**;17.15 的黑板僅限
>   單一 agent 的決策記憶,可讀本條旗標但不擁有它。
> - **任務 / 目標圖**:節點帶條件(事件謂詞)、序列 / 平行 / 可選、獎勵;進度是值型別狀態(例:「收集 3 個零件」由 `ItemPickedUp` 事件推進)。
> - **對話 / 敘事狀態**:對話圖遍歷狀態 + 條件 / 副作用(寫旗標),只含文字鍵不含文字(鍵見 17.73)。
> - **關卡切換協定**:引擎發出 `LoadLevel(id)` 指令資料與出生點,宿主載入資產並經 12.1 邊界重建世界,回報載入完成;跨關卡持久實體;世界分區 cell 載入 / 卸載事件(接 17.8)。
> - **檢查點 / 重生**:以 17.40 選擇性存檔或 6.10 全快照作檢查點,重生政策,快速存讀;RNG 狀態一併還原。
> - **背包 / 戰利品資料**:槽位、堆疊、加權掉落表(決定論 RNG)。
> **對照組**:UE GameMode / GameState / Level Streaming / SaveGame、Unity SceneManager + Addressables、Godot SceneTree 切換與 autoload、Yarn Spinner / Ink(敘事狀態)、社群任務外掛。
> **優勢區**:低-中 —— 工程為主;可主張:整個流程狀態是值型別 ⇒ 檢查點 = byte blob,回放 / 回滾自動涵蓋流程,schema 升版(17.40)自動遷移任務旗標。皆**待量測 / 待驗證**。
> **規模軸**:旗標數(1e2–1e6)、活躍目標數、事件率;目標條件派發成本。
> **seam?**:是 —— 目標條件派發:線性掃描所有目標 vs 依事件型別倒排索引 → parity:同一(種子化)事件序列下完成集合與完成序相同;bench 掃目標數 × 事件率。
> **交付**:`gameplay/flow.mojo`(狀態堆疊 + 黑板)、`gameplay/objectives.mojo`、`gameplay/checkpoint.mojo`、`gameplay/inventory.mojo`。測試:普通(暫停 / 恢復、目標依事件完成、掉落表種子重現)/ 整合(死亡→回檢查點→世界與旗標逐位相同;關卡切換帶走背包;`Recorder` 含流程狀態後 `first_divergence` 無分歧;存檔跨 build 升版)/ 極端(目標互為前提的循環、轉場中到達的事件、載入中存檔、缺關卡 id、旗標型別跨 build 改變、暫停中計時器到期、巢狀暫停)。
> **相依**:17.38、17.35、17.39、17.40、17.11、17.15(黑板)、17.70、17.8 / 17.12(關卡 / 分區)、12.1(宿主載入回報)、17.73(文字鍵)。
> **邊界**:選單 / HUD / 對話文字繪製、音訊、資產載入與串流 I/O、場景編輯與格式(17.12 屬宿主)、平台存檔槽與雲端(17.73)、過場內容(17.68)屬宿主或其他條目。

#### 17.73 營運邊界 — Wave C
> **進度註(2026-10-13)**:`diag/outbox.mojo` `Outbox`(型別化數值記錄 (kind, tick, key, a, b),無字串 → 構造上無 PII;滿則丟最新並計數,新計數器 `OUTBOX_DROPPED`(23,COUNT = 24);
> `sample_every` 以雜湊決定論抽樣;`drain` 記住已送達 tick,回滾重模擬時不重送,`rewind` 丟棄未送達的後續記錄)、`gameplay/achievements.mojo`(事件計數謂詞、恰解鎖一次、
> 進度存 17.72 `Flags`、解鎖寫 outbox)、`gameplay/loc_keys.mojo`(FNV-1a 32 穩定鍵 id、碰撞 raise、`missing`)、`gameplay/blackbox.mojo`(log + 全部計數器 + 快照 + 輸入尾段,
> 魔數 / 版本 / FNV 校驗)。量測(`tests/test_ops.mojo` 11/11):40 箱場景 300 步遙測開 / 關逐位相同;10 次擊殺於第 10 次恰解鎖一次;1/4 抽樣 10000 筆留 2496 且兩次相同;
> 回滾後已送達 tick 被拒、`rewind` 正確;黑盒 19585 bytes,於乾淨場景還原 tick 100 快照並重放 50 個輸入到 tick 150:逐位相同;損壞 / 截斷 / 版本錯 raise。
> `bench_ops`:push 80 ns、抽樣 5.5 ns、滿時 0.6 ns;遙測開 / 關每步 725 / 768 µs(雜訊內;首版 `drain` 每 tick 從空重長串列,開時多 16 %、每筆 2.8 µs,已改預配容量)。
> **未做**:`Runtime` tick 末排空與計數轉送、`HostServices` 服務項登記(17.75)、遠端設定 / 資格以輸入幀注入、黑盒接 17.33 不變式失敗與 17.80 擷取格式、C-ABI 取 outbox。
> **現況**:引擎端**只有診斷設施,沒有營運介面**。`diag/log.mojo:44-97` `LogRing`(分級 + 分類、drop-newest,引擎不 `print`)、`diag/counters.mojo:79,117`(`COUNT = 15` 個計數器;有 `get` / `dump`(`:129,135`),但無給宿主的匯出契約)、`diag/trace.mojo:63` `TraceBuffer`(Chrome trace 匯出);存檔給 bytes、無檔案 I/O(ROADMAP §17.40 17.40 待辦);回放錄製在記憶體(ROADMAP §17.39 17.39 待辦)。營運類能力:grep `telemetry|achievement|locali[sz]|analytics|leaderboard|entitlement|crash.?report`(不分大小寫)於全樹 `.mojo` 零命中。已定的邊界決定:17.16「傳輸層 / 線路格式交宿主」(ROADMAP §17.16)、「反作弊的帳號 / 封禁 / 用戶端防護屬宿主與線上服務」(ROADMAP §17.16)、hot config / CVar 併入 17.21(ROADMAP §17.23–17.41 增補「拒絕(5)」)、平台方向 C = 被宿主嵌入的函式庫。
> **缺口**:本條定義**引擎對營運服務的接口與資料契約**,而非實作營運服務:
> - **對外 outbox**:模擬在 tick 內只寫入有界佇列(drop-newest + 計數,同 `LogRing` / `DrawQueue`),tick 末由宿主取走;**模擬步內絕不呼叫宿主**,以保決定論。遙測是型別化數值欄位(構造上無 PII 字串)。
> - **遙測分流**:可抽樣、可開關,開 / 關兩路徑模擬狀態逐位相同(同 17.10 的準則)。
> - **成就 / 統計計數**:對事件流(17.38)的謂詞,產出「解鎖」事件,狀態存為旗標(17.72);平台 API 呼叫由宿主做。
> - **本地化鍵**:穩定的字串鍵 id + 註冊檢查(缺鍵回報),引擎不含文字、不含語系格式化。
> - **入站資料決定論**:遠端設定 / 資格(entitlement)/ 功能旗標由宿主注入,**以輸入幀記錄**(同 `InputFrame` 作法,`gameplay/replay.mojo:31-36`),否則重播會分歧。
> - **黑盒記錄器**:不變式失敗(17.33)時打包最近 N 條 log + 計數器 + 最近快照 + 回放尾段成一個 bytes blob,宿主上傳;乾淨環境以 `seek` / `first_divergence`(`gameplay/replay.mojo:130-148`)重現(重用 17.80 的擷取格式,本條不另立)。
> - **回滾去重**:17.16 回滾重模擬時,遙測 / 成就事件以 tick 為鍵去重,不重複發出。
> **對照組**:UE Analytics Provider 介面 / Online Subsystem(成就、資格、雲存檔)/ Crash Reporter / FText 字串表、Unity Analytics / Localization 套件 / Cloud Diagnostics、Godot `TranslationServer`、Steamworks 與各平台 SDK 包裝、Sentry / Crashpad 類回報。
> **優勢區**:中 —— **決定論 ⇒ 當機報告即重現**:黑盒 blob 在同工具鏈同架構(17.16 的承諾範圍)下可逐位重放到分歧 tick,對照組多只有符號化堆疊(**待驗證**:重現率與 blob 大小 vs 回放尾段長度)。
> **規模軸**:事件率(每 tick 事件數)× outbox 容量 → 遙測開 / 關的額外成本(應在雜訊內);blob 大小 vs 快照間隔(`bench_replay` 既有曲線)。
> **seam?**:否 —— 這是邊界契約而非可替換演算法;但「遙測 on / off 的模擬狀態 parity」與 outbox 溢位行為是必測項。
> **交付**:`diag` 側的有界 outbox 型別、`gameplay` 側的成就謂詞與黑盒打包、`HostServices` 中營運相關的服務項(遙測 outbox 取走、黑盒落地;空實作為預設)—— 注入機制本身歸 17.75 嵌入契約擁有,
> 本條只登記這幾項。測試:普通(發遙測 → 取走、成就恰解鎖一次)/ 整合(`Runtime` tick 末排空 outbox;強制不變式失敗 → blob → 乾淨行程重放到同一分歧 tick;遙測開關 parity)/ 極端(outbox 滿 → drop-newest 計數、宿主取走過慢、回滾重模擬不重複發事件、缺本地化鍵、遠端設定在 tick 中途到達(排到下一輸入幀)、容量 0、重複解鎖)。
> **相依**:17.32 / 17.33 / 17.10(診斷)、17.38、17.39 / 17.40、17.72(旗標)、17.75(宿主注入)、12.1、17.16(回滾去重;反作弊為其邊界)、17.80(擷取格式)。
> **邊界**:所有網路 I/O、帳號、商店 / 資格伺服器、遙測儲存與儀表板、平台 SDK、同意 / GDPR 流程、翻譯內容、反作弊用戶端皆屬宿主與線上服務;CVar 熱調屬 17.21。

---

## ECS、排程、執行期與診斷

範圍:ecs、scheduler、diag、runtime、存檔 / 回放。

| 編號 | 條目 | 狀態 | Wave | 說明 |
|---|---|:-:|:-:|---|
| 3.3 | [ECS table stakes](ROADMAP_HISTORY.md#33-ecs-table-stakes) | ✅ |  | `ecs/relations.mojo` 提供 flecs pair 式一級實體關係(正/反向索引、wildcard 枚舉、局部 despawn 清理),`ecs/commands.mojo` 提供結構變更延遲緩衝,`tests/test_relations.mojo` 19/19。 |
| 4.4 | [ECS 完備:push-based observers + 延遲 component set](ROADMAP_HISTORY.md#44-ecs-完備push-based-observers--延遲-component-set) | ✅ |  | reactive_backend 已有事件驅動 observers(observe1/observe2、ObsEvent inbox、drain;push 56.9 vs 輪詢 73.2 ns/event),command buffer 已有型別抹除的延遲 component set,依錄製順序重播(37.1 vs 直接 15.0 ns/write)。 |
| 6.10 | [場景序列化(精確存檔/載入)](ROADMAP_HISTORY.md#610-場景序列化精確存檔載入) | ✅ |  | physics/serialize.mojo 的 scene_to_string/scene_from_string 把 ContactScene6[QuatBody6] 的全部動力學狀態(含 warm-start cache、joint 累積器、sleep timer、軟體)以 f32 位元模式存成 token 流,save→load→save byte-identical、續跑 bit-identical。 |
| 10.2 | [自動依賴 job graph(DOTS 式讀寫衝突)](ROADMAP_HISTORY.md#102-自動依賴-job-graphdots-式讀寫衝突--完成2026-08-11) | ✅ |  | `DeclaredSystem` trait 讓系統宣告 component 讀/寫遮罩,`JobGraphScheduler` 依 RAW/WAW/WAR 衝突律以最長路徑分層,與 `SequentialScheduler` 逐位相同,同層並行 1.40×(推導 228 ns 只建構一次)。 |
| 10.3 | [Actor Model 硬化(既有雛形 → 生產)](ROADMAP_HISTORY.md#103-actor-model-硬化既有雛形--生產--完成2026-08-11) | ✅ |  | `EntityActorScheduler` 加上可觀測背壓(`max_rounds`、`mailbox_cap`,回報 `rounds_used`/`truncated`/`dropped`/`delivered`),溢位丟最新、保留 sender id 最小的訊息,serial 與 parallel dispatch 的世界摘要、投遞數與級聯輪數逐位相同。 |
| 17.8 | [大世界座標](#178-大世界座標) | ✅ | C | `gameplay/large_world.mojo`:座標策略 seam(`AbsoluteF32` / `RebasedF32`,origin 以 f64 保存、位移貼齊 2 的冪格點)、`ContactScene6.shift_origin`、`WorldPartition`(cell 串流、遲滯、跨格換主);f64 為整引擎可建置的變體(`pixi run build-f64`),小世界與 f32 一致;精度曲線見 `bench_large_world`。 |
| 17.9 | [Debug-draw 指令佇列](ROADMAP_HISTORY.md#179-debug-draw-指令佇列--wave-a工具) | ✅ | A | `diag/draw.mojo` 的 `DrawQueue[dtype]` 是固定容量的 immediate-mode 指令佇列(line / sphere / box / arrow / text / contact-point,帶生命期、溢位 drop + 計數),由 test_diag_draw 與 bench_diag 表 (c) 覆蓋。 |
| 17.10 | [Profiling / tracing hooks](ROADMAP_HISTORY.md#1710-profiling--tracing-hooks--wave-a工具) | ✅ | A | `diag/trace.mojo` 提供 begin/end 與 with-scoped span(`-D LUDENS_TRACE` 關閉時編譯為無)、計數器與 Chrome trace 匯出,並在 `ContactScene6` 每步標註 5 組階段 span。 |
| 17.11 | [反射 / 型別註冊表](ROADMAP_HISTORY.md#1711-反射--型別註冊表--wave-b架構解鎖多項) | ✅ | B | `ecs/schema.mojo` 以 Mojo 1.1 `reflect[T]` 在編譯期產生 `TypeSchema`(含巢狀點號路徑)、按欄位名的版本容忍讀寫與 `TypeRegistry` 型別擦除存取,並有 parity 測試、bench_schema 與範例 23_reflection_inspector。 |
| 17.12 | [可編輯場景 / prefab / 實例化](#1712-可編輯場景--prefab--實例化) | 不排 | C | 規劃一套 schema 化、可 diff、版本化的場景 / prefab 格式(實際走宿主的 glTF / USD 匯入),與現有決定論快照分開並以 parity 連結;尚未開工。 |
| 17.32 | [執行期分級日誌設施](ROADMAP_HISTORY.md#1732-執行期分級日誌設施--wave-a工具錯誤政策的記錄層) | ✅ | A | `diag/log.mojo` + `diag/level.mojo` 提供分級加分類的 `LogRing` 環形緩衝,用 comptime `LUDENS_LOG_LEVEL` 閘門,溢位時丟最新一筆並計數,`bench_diag` 表 (a) 量到關閉的層級零成本;solver6 的 NaN 隔離會發 WARN 日誌。 |
| 17.33 | [執行期斷言 / 不變量檢查層](ROADMAP_HISTORY.md#1733-執行期斷言--不變量檢查層--wave-a工具錯誤政策的立即終止層) | ✅ | A | `diag/invariant.mojo` 把引擎的 `debug_assert` 慣例寫成文件,另加熱路徑用的 `invariant_finite`(NaN / Inf 檢查);測試以 `-D ASSERT=all` 執行,由 `tests/test_diag_invariant.mojo` 驗證。 |
| 17.34 | [每幀 / 暫存集區配置器(frame arena)](ROADMAP_HISTORY.md#1734-每幀--暫存集區配置器--wave-a) | ✅ | A | `diag/arena.mojo` 的 `FrameArena` 是在單一次配置上運作的 bump allocator,提供型別化的 `alloc[T]` 與 `reset()`,溢位時 raise 並計數;已有與 List 的 parity 測試,`bench_diag` 表 (b) 量到每筆約 1.9 ns,List-per-frame 慢 1.5–4 倍;seam 列在 CATEGORY §2.2。 |
| 17.37 | [實體池化](ROADMAP_HISTORY.md#1737-實體池化--wave-a) | ✅ | A | `ecs/pool.mojo` 提供 `Pool` / `PooledEntity` / `Disabled`,支援全部六個 `StorageBackend`,有六後端 parity 測試、`bench_pool`(N≥1000 時快 1.08–1.51×)和子彈池範例 `examples/16`。 |
| 17.38 | [遊戲事件匯流排 / 訊息系統](ROADMAP_HISTORY.md#1738-遊戲事件匯流排--訊息系統--wave-a) | ✅ | A | `scheduler/events.mojo` 提供 `EventChannel` seam:`Channel[E]`(pull,正式路徑)對照 `PushChannel[E]`(fan-out),投遞依呼叫序決定、雙緩衝、每個讀者有自己的游標,未讀而丟棄的事件計入 `diag.counters`;測試有 `test_events` / `test_events_gameloop` / `test_events_contacts`,bench 為 `bench_events`。 |
| 17.39 | [輸入錄製 / 決定論回放(QA・ghost,非網路)](ROADMAP_HISTORY.md#1739-輸入錄製--決定論回放qaghost非網路--wave-b) | ✅ | B | `gameplay/replay.mojo` 提供 `SimState` / `Recorder`(錄製輸入、定期存快照、每 tick 存 FNV-1a 狀態雜湊)以及 `replay_from_start` / `seek` / `first_divergence` / `ghost`;`test_replay` 8/8 驗證 seek 與全程重跑逐位相同;`bench_replay` 在快照間隔 10 時尋位只要 0.10 ms,全程重跑則是 32.6 ms。 |
| 17.40 | [存檔系統(相對於決定論快照)](ROADMAP_HISTORY.md#1740-存檔系統相對於決定論快照--wave-b) | ✅ | B | `gameplay/save.mojo` 建在 17.11 schema 上,提供 `SaveWriter` / `SaveReader`:具名區段,按欄位名載入,處理新增、刪除、改型的欄位並以 `ReadReport` 回報;`save_bodies` / `load_bodies` 只存動態體的姿態與速度;`test_save` 11/11 驗證存檔涵蓋的欄位與 6.10 快照逐位相同;`bench_save` 的存檔大小為 74 KB,快照為 932 KB。 |
| 17.43 | [Undo / redo 交易層(編輯器前置)](#1743-undo--redo-交易層編輯器前置) | 不排 | B | 規劃在 `CommandBuffer`(4.4)與 17.11 `TypeSchema` 之上建交易式 undo / redo 層(begin/commit/abort、反向操作記錄、物理場景 inverse op),以 `UndoLog` 差分 vs `SnapshotUndo` 全快照為 seam;目前只有零件,交易與反向操作層未做。 |
| 17.77 | [ECS 表達力](#1777-ecs-表達力--wave-b) | ✅ | B | N 元查詢與迭代、過濾器、變更偵測、單例 / 資源、有狀態系統與使用者系統註冊、延遲結構變更補齊 |
| 17.79 | [資源治理](#1779-資源治理--wave-b) | 🔶 | B | 記憶體記帳、容量上限與滿載政策、預留與穩態零配置、收縮、執行緒 / GPU 資源政策、資源上限觸發的退讓 |
| 17.80 | [觀測](#1780-觀測--wave-b工具執行期追蹤開關物理擷取檔與回看) | 🔶 | B | (a)runtime 追蹤開關、(b)緩衝政策、(c)多執行緒與 GPU 軌、(d)counter 軌、(e)物理擷取檔、(f)回看 |
| 17.85 | [分級模擬:依因果可達性分配時間 / 空間解析度](#1785-分級模擬依因果可達性分配時間--空間解析度--wave-c架構) | 🔶 | C | 逐 island tier 表(iters / substeps / period,catch-up)、`TierPolicy` seam(距離 / 因果 / 輪轉 / 預算)、`TieredScheduler`、`Runtime.advance_tiered`、快照 v3 已交付;ECS `Tier[N]` tag(待 17.77)、awake list、`update_moved` / 窄相跳過未做 |

### 已完成條目的遺留待辦

這些條目已完成並移到歷史檔,但各自記下了尚未做的部分:

- **6.10**([紀錄](ROADMAP_HISTORY.md#610-場景序列化精確存檔載入)):ScrewBody6 場景需對應的序列化變體(目前只綁 QuatBody6,physics/serialize.mojo:118)
- **6.10**([紀錄](ROADMAP_HISTORY.md#610-場景序列化精確存檔載入)):格式 v1 無向後相容承諾(版本化/按欄位載入的存檔走 17.40 gameplay/save.mojo)
- **10.2**([紀錄](ROADMAP_HISTORY.md#102-自動依賴-job-graphdots-式讀寫衝突--完成2026-08-11)):誠實弱點:沒有機制驗證系統宣告的讀寫集與 `apply` 實際存取一致,宣告錯就排程錯(寫在檔頭,未處理)
- **10.3**([紀錄](ROADMAP_HISTORY.md#103-actor-model-硬化既有雛形--生產--完成2026-08-11)):網路 rollback 的地基(決定性 RNG + actor + 序列化)已收口,網路本體仍為外殼、不做
- **17.10**([紀錄](ROADMAP_HISTORY.md#1710-profiling--tracing-hooks--wave-a工具)):同一行程交錯量測 trace on/off 以取得乾淨的 overhead 數字(需 runtime 開關;runtime 開關已歸入 17.80)
- **17.11**([紀錄](ROADMAP_HISTORY.md#1711-反射--型別註冊表--wave-b架構解鎖多項)):批次讀寫(`write_values` / `read_values`)仍逐 byte `append`,改為整段複製
- **17.11**([紀錄](ROADMAP_HISTORY.md#1711-反射--型別註冊表--wave-b架構解鎖多項)):非純資料型別(`List` / `String`)目前靠契約排除,未在編譯期擋下
- **17.11**([紀錄](ROADMAP_HISTORY.md#1711-反射--型別註冊表--wave-b架構解鎖多項)):17.12 場景格式改用此 schema(17.12 於 2026-10-09 列為不排)
- **17.11**([紀錄](ROADMAP_HISTORY.md#1711-反射--型別註冊表--wave-b架構解鎖多項)):17.16 replication 改用此 schema
- **17.32**([紀錄](ROADMAP_HISTORY.md#1732-執行期分級日誌設施--wave-a工具錯誤政策的記錄層)):seam? 欄位的定律 v3 要求 broadphase 容量溢位必須真的發出日誌:collision/ 與 spatial/ 內 grep 不到 LogRing / diag.log 的使用,進度紀錄也只提到 solver6;broadphase 是否有容量上限、是否需要接日誌待確認
- **17.39**([紀錄](ROADMAP_HISTORY.md#1739-輸入錄製--決定論回放qaghost非網路--wave-b)):錄製檔案化(目前錄製只存在記憶體)
- **17.39**([紀錄](ROADMAP_HISTORY.md#1739-輸入錄製--決定論回放qaghost非網路--wave-b)):快照差分壓縮
- **17.39**([紀錄](ROADMAP_HISTORY.md#1739-輸入錄製--決定論回放qaghost非網路--wave-b)):接上 17.16 的網路 rollback
- **17.40**([紀錄](ROADMAP_HISTORY.md#1740-存檔系統相對於決定論快照--wave-b)):ECS 世界整批存讀的便利層
- **17.40**([紀錄](ROADMAP_HISTORY.md#1740-存檔系統相對於決定論快照--wave-b)):檔案 I/O(目前只回傳 bytes)
- **17.40**([紀錄](ROADMAP_HISTORY.md#1740-存檔系統相對於決定論快照--wave-b)):壓縮

### 待辦與部分完成條目

#### 17.8 大世界座標

> **狀態**:✅ 完成(Wave C;剩餘順序第 (8) 項)。2026-10-12 交付,設計筆記 `docs/design/17.8-large-world.md`。
> **進度(2026-10-12)**:
> - 座標策略 seam(`gameplay/large_world.mojo`):`CoordStrategy` trait,`AbsoluteF32`(不位移,17.8 前的行為)、`RebasedF32(threshold, grid)`(觀察者離原點超過
>   `threshold` 時把原點移到觀察者位置,貼齊 2 的冪格點 —— 原點與位移都可精確表示);`Rebaser` 以 f64 保存 `origin`、記錄每次位移的 tick;宿主以 f64 `WorldPos` 給座標,
>   `local = world - origin` 在 f64 內算完才轉 f32。第三個設定 f64 是**建置變體**:`WorldType` 是普通 comptime 別名(條件式別名會失去 `cos` / `sin` 需要的靜態浮點證據,
>   且 `mojo precompile` 不收 `-D`),`scripts/build_f64.sh`(`pixi run build-f64`,約 1 分鐘)以切換該行的原始碼副本建出 `build64/`。為此修掉 13 個檔案中寫死 f32 的地方
>   (GPU 模組改用 `WorldType` / `Real`;C-ABI 邊界維持 C `float` 並顯式轉換;f32 建置下全是 no-op)。
> - `ContactScene6.shift_origin(d)`:所有 body 位置、warm-start 與 sensor 快取的世界座標接觸點、軟體粒子、靜態三角網格與高度場(經各自建構子以位移後資料重建,
>   BVH / 法線 / 區塊界自然一致;`ColliderSet.shift_static`)移 `-d`;關節錨點、`ra` / `rb`、速度、衝量、island / 睡眠是相對量,不動;broadphase 每步重建,無狀態可移。
> - `WorldPartition`:宿主以世界座標登記 body;cell 在觀察者 `load_radius` 內才在場景中,所有觀察者都超過 `unload_radius` 時把 body(姿態 + 速度)擷取回世界座標規格並移除
>   (遲滯);動態 body 跨格後下一次 `update` 換主;載入 / 卸載事件帶 tick,依 cell key 與規格序決定順序。`save_large_world` / `load_large_world`:origin + 位移記錄 + 17.16 的精確快照。
> - 測試 `test_large_world`(22,integration):1e6 m 處以 `RebasedF32` 建的三箱堆與原點處**逐位相同**;不位移時 0.5 m/s 物體在 1e6 m 完全不動(誤差 0.5 m,
>   每 tick 8.3 mm < 半個 ulp 31 mm),位移後誤差 3.9e-7 m;靜止箱堆在 tick 120 位移:接觸數不變、之後最大速度 0(無 warm-start 衝擊)、60 tick 後與未位移者差 3.5e-6 m;
>   位移後存檔 → 載入續跑 == 不中斷(逐位),origin 與記錄還原;(1e7, 0, −1e7) m 的箱堆與原點逐位相同;150 m/s 球在位移當 tick 仍被 CCD 擋在牆前;非有限位移被拒;
>   小世界 `RebasedF32`(未觸發)== `AbsoluteF32` 逐位;partition:觀察者在格界來回無事件、跨格 body 換主且不隨舊格卸載、卸載 + 重載姿態與速度逐位還原、
>   觀察者瞬移 5 km 後條帶全部卸載、兩次相同行走事件記錄相同。`test_world_f64`(5,integration):整引擎以 f64 建置成功;f64 在 1e7 m 誤差 3.0e-8 m;
>   小世界 f32 / f64 慢速物體皆 < 1e-5 m,箱堆頂盒差 0.85 mm。
> - 量測(`bench_large_world`,0.5 m/s 物體 1 s 的行程誤差):1 m:f32 7.6e-6 / f32 位移 7.6e-6 / f64 2.5e-14 m;1e4 m:3.1e-2 / 1.2e-4 / 1.2e-10;
>   1e5 m:0.5(不動)/ 1.2e-4 / 1.6e-9;1e7 m:0.5 / 3.9e-7 / 3.0e-8。`shift_origin` 每 body 5.3–8.3 ns;`WorldPartition.update` 1024 body / 64 cell 每次 16.1 µs(含 607 次載入 / 卸載)。
> **遺留待辦**:`Runtime` / `EmbedWorld` / C-ABI 接上位移與分區(目前在 `ContactScene6` 層使用);導航(17.14)與 AI 的世界座標資料隨位移移動、cluster graph 接分區;
> 分區 cell 只依 xz;分區載入的 body 形狀只有 box / sphere;關節跨 cell 的 body 尚未處理(卸載時需整組);f64 完整精度曲線以外的 f64 效能量測。
> **決定(2026-10-09)**:先做 f32 + origin rebasing + world partition;f64 只做到 `WorldType` 參數化與小世界 parity,完整精度曲線視代價再補。
> **現況**:全部使用 `f32`(`WorldType`),以維持 bit-identical 決定論。世界尺度上限約為單一關卡。
> **缺口**:
> - 64-bit 世界座標,**或** origin rebasing(世界原點位移);
> - world partition / cell streaming;
> - 與決定論相容的方案:rebasing 事件也要進序列化。
> **對照組**:UE5 Large World Coordinates + World Partition、Unity origin shifting、使用 64-bit 位置的自研引擎。
> **優勢區**:低 —— 純架構。**f64 化會讓 16.3 的 Vec3 / SIMD 寬度重構重做一次**,因此排在 Wave C 末。
> **規模軸**:世界跨度(m)vs 位置誤差;streaming cell 進出的每幀成本。
> **seam?**:是 —— 座標策略(f32 / f32+rebasing / f64):
> - parity:小世界下三者在 ε 內一致;
> - bench:遠離原點的精度退化曲線(即優勢區的量測)。
> **交付**:
> - 普通:遠離原點的物件不抖動;
> - 整合:rebasing 後 warm-start cache 與序列化續跑皆一致;
> - 極端:1e7 m 外、在 cell 邊界瞬移、rebasing 當幀有 CCD。
> **相依 / 被依賴**:17.14 導航的 cluster graph 粗規劃要接本項的 world partition 與串流。

#### 17.12 可編輯場景 / prefab / 實例化

> **狀態**:不排(2026-10-09 平台方向 C 拍板後 gating 已解,但屬編輯器相關,本輪不做;原 Wave C)
> **決定(2026-10-09)**:平台方向 C → 場景格式**跟宿主走**(glTF / USD 匯入),不自訂檔案格式;場景(作者資料)與決定論快照分開,以 parity 連結。屬編輯器相關,本輪不做。
> **現況**:`physics/serialize.mojo` = 全狀態 f32 bit-pattern 決定論快照(自註「非 asset reference」)。
> **缺口**:schema 化、可 diff、版本化的場景格式、prefab / blueprint、nested scene 組合、實例覆寫(override)、entity template。
> **對照組**:UE `.umap` + Blueprint、Unity prefab + YAML scene、Godot `.tscn` + PackedScene、glTF / USD 匯入。
> **優勢區**:低 —— 工程;差異化在依賴 17.11 反射 → 格式免手寫(17.11 `ecs/schema.mojo` 已交付,其待辦列有「17.12 場景格式改用此 schema」)。
> **規模軸**:場景實體數的載入時間;prefab 覆寫深度。
> **seam?**:是 —— 場景格式讀寫 vs 決定論快照 → parity(同場景兩路徑載入後逐位相同)。
> **交付**:普通(存讀一個場景)/ 整合(prefab 實例 + 覆寫、warm-start cache 保留)/ 極端(空場景、循環 prefab 參照、缺資源、格式版本升級)。
> **歷史**:原標「⚠️ gated」—— 檔案格式綁定是「先於技術的架構決策」(同 Phase 13 排除 MJCF/URDF、同 13.9),待平台整合方向確定;2026-10-09 方向拍板 C 後此 gating 解除,改為「跟宿主格式、本輪不排」。

#### 17.43 Undo / redo 交易層(編輯器前置)

> **狀態**:不排(2026-10-09 修訂把編輯器相關的 17.12 / 17.43 列為不排;原標 Wave B。零件已在,交易 / 反向操作層未做)
> **緣起**:2026-09-30 編輯器邊界分類找出的缺口 —— 外部編輯器依賴的 15 項核心能力中,除 17.12(gated)外唯一未編號者。編輯器邊界分類表把 Undo / redo 標為 🔶「零件在,交易 / 反向操作層未做」,並指出真正擋住外部編輯器的是 17.12 場景 / prefab 格式與 17.43 undo 交易層。
> **現況**:零件已在但未組合:
> - `ecs/commands.mojo` `CommandBuffer`(4.4)只記**正向**結構變更(實際只有 despawn / relate / unrelate,`ecs/commands.mojo:43-49`;延遲 add 在 `SetBuffer.set`,延遲 remove 不存在 —— 2026-10-10 校正),`apply` 後不留反向資訊。
> - 17.11 `TypeSchema` 能按欄位名讀寫值,但沒有「前值 / 後值」記錄。
> - `ContactScene6` 的變更(`add*` / 關節 / 材質 / 規則 / `deform_heightfield`)只能靠 6.10 全快照回復。
> **缺口**:
> - **交易**(`begin` / `commit` / `abort`):一組變更成為一個 undo 步;可巢狀、可合併(連續拖曳同一欄位合為一步)。
> - **反向操作記錄**:結構變更記下被刪實體的全部 component(經 17.11 schema 序列化)以便復原;欄位變更記 (entity, type, path, 前值, 後值) 位元組。
> - **物理場景變更**:body / collider / 關節 / 規則 / 地形編輯的 inverse op(地形記受影響區塊的舊高度,接 17.30 的區塊摘要)。
> - undo / redo 堆疊、深度 / 記憶體上限、redo 在新變更時截斷。
> - 與 4.4 observers 相容:undo 觸發的變更照常推播(編輯器視圖同步)。
> **對照組**:UE `FTransaction` / `FScopedTransaction`(物件快照差分)、Unity `Undo.RecordObject`、Godot `UndoRedo`(do / undo 方法對);**本庫內部對照**:6.10 全快照回復(seam 的另一端)。
> **優勢區**:差分記錄 vs 全快照 —— 場景越大、每步變更越小,差分的記憶體 / 時間優勢越大;理論優勢區 = 大場景 × 單欄位編輯。反向:整批變更(全場景變形)時快照可能較省,需一併量。
> **規模軸**:場景實體數 × 每交易變更數;undo 深度。
> **seam?**:是 —— `UndoLog`(inverse op 差分)vs `SnapshotUndo`(每交易一次 6.10 快照):同一編輯序列 undo 到任一步後**世界逐位相同**(parity)+ 記憶體 / 延遲 bench row。
> **交付**:
> - 普通:改一欄位 → undo → redo。
> - 整合:刪一個帶關節的剛體 → undo 後關節、材質、睡眠狀態、warm-start 以外的欄位逐位還原,並能繼續步進;經 observers 推播。
> - 極端:空交易、巢狀 abort、undo 超過深度上限、redo 被新變更截斷、復原已被其他交易刪除的實體參照、1e5 實體場景單欄位編輯的差分 vs 快照成本。
> **邊界**:本條只做 headless 核心 API;undo 歷史的 UI 屬編輯器本體(不在本 repo)。
> **決定**:2026-10-09 修訂(Wave C 暫停點,平台方向 = C 嵌入式模擬函式庫)列為不排。

#### 17.77 ECS 表達力 — Wave B

> **狀態**:✅ 完成(2026-10-14:過濾器 with / without / any(六後端原生)、N 元查詢、`for_each3`、pull 變更偵測、資源、延遲 remove / despawn / spawn、
> 型別規模防護、`Runtime.advance_with` 使用者系統註冊 ✅)。
> **進度註(2026-10-13)**:`ecs/storage.mojo`:`Filter().with_[A]().without[B]().any[C]()`(以元件 ID 記錄;pack 外的 `with_` 型別使結果為空,`without` / `any` 則忽略),
> `StorageBackend.select` 由六後端各自原生實作 —— archetype 每個簽名測一次 mask、bitset 字級 AND / AND-NOT / OR、sparse-set / reactive 走最小的 `with_` 集合再探測、
> naive / chunked 逐 id 掃。`check_pack` 在每個後端建構時 comptime 檢查 ID 重複與 > 63 型別(`test_ecs_pack_guard` 以子程序編譯三個生成程式:對照組可建、
> 重複 ID 與 64 型別皆編譯失敗並帶訊息)。`World`:`select`;`track_changes(window)` / `advance_tick` / `changed[C](since)` / `added[C](since)` / `mark_changed`
> (逐元件寫入日誌保留最近 window 個 tick,較舊的 `since` 退回全掃描;despawn 清除該 id 的紀錄,id 重用不誤報;`for_each2` 的就地寫入不被追蹤);
> `set_resource[T]` / `resource[T]`(一個保留實體上的元件,flecs 的 singleton 作法)。`SetBuffer` 成為單一錄製序緩衝:`set` / `remove[C]` / `despawn` / `spawn`
> (佔位 `Entity` 可在同一緩衝內被後續紀錄引用,`apply` 回傳實體)。`Pool.active_query*` 改走 `without[Disabled]`。
> 量測(`tests/test_ecs_query.mojo` 24/24):n = 40 / 130 的建構腳本(含 despawn、id 重用、remove)後,七個過濾器在六後端上與逐個 `has` 的暴力結果相等且彼此相等;
> `changed` / `added` 只回本 tick 的寫入;9 型別、300 個不同 archetype 簽名的查詢正確(舊註解寫的 256 只是初始容量)。
> bench `bench_ecs_query`(N = 20000,µs):`select` without vs `query1` + `has` —— disabled 佔 99 % 時 archetype 3 vs 385、bitset 5 vs 209、sparse-set 111 vs 277;
> 佔 1 % 時 sparse-set 208 vs 175、naive 218 vs 196(較慢:逐槽 comptime 分派探測);`changed[C]`(1 % 被寫)9–25 vs 手工 dirty 欄位全掃描 171–492。
> **進度註(2026-10-14)**:`StorageBackend.for_each3[A, B, C](func(mut a, b, c))` 與 `World.for_each3`,六後端各自實作(archetype 欄直取、bitset 字級 AND、
> sparse-set / reactive 以三個 dense 集合中最小者驅動再探測、chunked 逐頁、naive 逐槽)。`Runtime.advance_with(frame_dt, sched: JobGraphScheduler[B, *Systems])`:
> 每個固定 tick 在物理步、事件發布與 transform 同步之後 tick 一次使用者系統(排序由宣告的 reads / writes 推出,`parallel` 與串行逐位相同);
> 系統本身是無狀態 static,跨 tick 的狀態放在 world 資源,並以資源元件的 ID 進遮罩 —— 這就是「有狀態系統」的作法,不另設可變系統物件。
> 量測:`tests/test_ecs_query.mojo` 24/24(`for_each3` 在六後端與 has / get / set 迴圈結果相同);`tests/test_runtime_systems.mojo` 6/6(30 個 0.2–3 tick 不等的幀共 31 個固定 tick,
> 系統各跑 31 次;每幀 `Height` 等於場景 body y;`Lowest` 資源 8.681425 等於 4 子步半隱式 Euler;parallel 排程與串行同值;`advance` 與 `advance_with` 的 body 位置相同;
> 步驟進行中呼叫 raise)。bench `bench_ecs_query` 第二表(N = 20000,µs):`for_each3` vs `query3` + get / set —— archetype 16 vs 1084、bitset 107 vs 652、naive 99 vs 286、
> chunked 243 vs 1107、reactive 688 vs 1607、sparse-set 782 vs 1027(sparse 以 get 取三者,省下的只有 entity 清單)。commit c1acc93、f79a09a。
> **緣起**:ECS 的儲存後端已有六種(archetype / sparse-set / bitset / reactive / chunked / naive),但**查詢語言**停在「AND 交集 + 固定元數」,
> 宿主嵌入與 gameplay 都會碰到同一批缺口。
> **現況**:
> - **查詢只有 AND**:`StorageBackend` 僅 `matching1/2/3`(`ecs/storage.mojo:41-45`)與 `for_each2`(`storage.mojo:50-54`、`ecs/world.mojo:104`);
>   `ecs/query.mojo:1-9` 自述為空模組。grep `Without|Changed|Added|Resource|Singleton|change_tick|has_not|exclude` 於 `ecs/` 只命中
>   `ecs/sparse_backend.mojo:31` 註解的英文句首 "Without this",零個查詢功能
>   (`Optional` 的命中全是 `chunked_backend.mojo` 的內部儲存,不是查詢功能)。
> - **排除過濾靠事後篩**:`ecs/pool.mojo:44-48` 明載「六個後端皆無排除過濾」,`Pool.active_query1/2/3`(`:265-291`)先取全部匹配再逐個
>   `has[Disabled]` 剔除,成本仍是 O(全部匹配)。
> - **延遲結構變更不完整**:`CommandBuffer` 只有 `despawn` / `relate` / `unrelate`(`ecs/commands.mojo:43-49`);`SetBuffer`(`:76`)只有延遲 `set`(`:109`);
>   grep `def remove|def spawn` 於 `commands.mojo` 零命中 —— 無延遲 `remove[C]`、無延遲「帶元件 spawn」。
> - **推播只在一個後端**:`observe1` / `observe2` 僅 `ecs/reactive_backend.mojo:115,123`(其餘五個後端無);無 pull 式變更偵測。手工旗標代替:
>   `ecs/transform.mojo:30,32` 的 `local_dirty` / `world_dirty`,`Runtime._sync_transforms` 手動設(`gameplay/runtime.mojo:247-248`)。
> - **無單例 / 資源**:全域資料(gravity、`SolverConfig`、時間)放在 `Runtime` 欄位(`gameplay/runtime.mojo:79-86`),而 `System.apply[B](mut world)`
>   無狀態(`scheduler/scheduler.mojo:26-34`)摸不到;`Runtime` 自述不走 `Scheduler`(`runtime.mojo:174-184`),且 grep `JobGraphScheduler` 於
>   `gameplay physics collision` 零命中(只有測試用)—— 使用者系統**無法註冊進 `Runtime`**。
> - **元件型別規模無防護**:`ComponentType.ID` 是使用者自選 comptime 整數,「須唯一、從 0 密集」只寫在註解(`ecs/component.mojo:3-7`);grep
>   `comptime assert|constrained` 於 `ecs/*.mojo` 零命中 —— 重複 ID 不會編譯失敗。job graph 遮罩是 `UInt64`(`scheduler/jobgraph.mojo:41-49`,自述 64 型別上限);
>   archetype 遮罩是 `Int`、`1 << slot`(`ecs/archetype.mojo:123,199`),表容量常數註解寫「支援 8 型別」(`archetype.mojo:42`),超過時的行為無測試。
> - **已具備、不重做**:關係存儲(`ecs/relations.mojo:55`)、階層(`ecs/hierarchy.mojo:19`)、推播 observers(reactive 後端)、物件池(17.37)、
>   `TypeSchema` / `TypeRegistry`(`ecs/schema.mojo:47,271`)。
> **缺口**:
> - **N 元查詢與迭代**:`matching4+` / `for_each3+`(或以 comptime 型別包的 `for_each[*Cs]`);例:`Transform + Velocity + RigidBodyRef + Health`
>   四件組,現況只能 `query3` 後手動 `has` / `get`。
> - **過濾器**:`Without[C]` / `Or[...]` / `Optional[C]`,在六個後端各自原生實作(archetype 於 mask 層、bitset 於字級 AND-NOT、sparse-set 取最小集合後探測),
>   並讓 `Pool.active_query*` 改走它。
> - **變更偵測**:`Added[C]` / `Changed[C]`(pull,所有後端),與 reactive 的 push observers 互補;例:只對本幀被 `set` 的 Transform 重算世界矩陣,而非全掃 + 手工旗標。
> - **單例 / 資源**:`World.resource[T]()`(型別唯一的全域資料),並讓系統可宣告讀寫它(進 `reads()` / `writes()` 遮罩);`Runtime` 的 gravity / cfg 可由此取得。
> - **有狀態系統與使用者系統註冊**:系統可持有狀態或資源;`Runtime` 提供註冊點,以 `JobGraphScheduler` 排序後與內建管線(`runtime.mojo:192-201`)同 tick 執行。
> - **延遲結構變更補齊**:`CommandBuffer` / `SetBuffer` 合併為單一錄製序緩衝,補 `add` / `remove[C]` / 「帶元件 spawn」,錄製序決定論(replay 友善),遍歷中可安全使用。
> - **型別規模防護**:重複 `ID` 與 > 64 型別於 comptime 報錯(或遮罩自動加寬);> 8 型別 / > 256 個 archetype 簽名的行為有測試。
> **對照組**:Bevy(`Query<(&A, Option<&B>), (With<C>, Without<D>)>`、`Changed<T>`、`Res<T>`、`Commands`)、flecs(查詢 DSL 的 `!` / `?` / `or`、變更追蹤、
> singleton)、Unity DOTS(`EntityQuery` 的 `WithNone` / `WithAny`、變更版本過濾、`EntityCommandBuffer`、singleton 元件)、EnTT(`exclude<>` view、context 變數)。
> **優勢區**:中 —— 六後端 swap seam 本身就是優勢:同一查詢語意跑在不同儲存上,能量出「過濾器成本」各後端的優勢區(archetype 在簽名層排除、bitset 字級 AND-NOT
> 跳過空字 `ecs/bitset_backend.mojo:4-8`、sparse-set 靠最小集合),對照組多為單一儲存模型,無此對照。
> **規模軸**:實體數 1e3–1e6 × 元件型別數 4–32 × 過濾器選擇度(匹配 1% / 50% / 99%)× 每幀變動比例(0.1%–100%);`Changed` 查詢 vs 全掃 + 手工旗標。
> **seam?**:是 —— 過濾器與變更偵測在六後端上的實作變體。parity:同一建構腳本(含 despawn 與 id 重用)後,六後端對 `(With A, Without B, Optional C, Changed D)` 回傳的
> 實體集合(排序後)相等,`for_each` 對每個實體看到的值相等(沿用 `tests/test_backend_parity.mojo` 的固定場景寫法);bench 每後端一列 × 選擇度。
> **交付**:普通(`Without` 與手工 `has` 過濾結果一致;`Changed` 只回本幀被 `set` 者;resource 讀寫;延遲 `remove`)/ 整合(`Runtime` 註冊兩個讀寫 resource 的使用者系統,
> 經 `JobGraphScheduler` 排序後與 `_sync_transforms` 同 tick 運行,結果與手寫順序逐位相同;`Pool.active_query*` 改走 `Without` 後與舊結果相同且不再 O(全部))/
> 極端(0 實體、全匹配、零匹配;同一型別同時 `With` 與 `Without`(comptime 錯誤);遍歷中 despawn / remove(延遲套用);id 重用後 `Changed` 不誤報;變更版本計數回繞;
> 65 型別與重複 ID 的 comptime 錯誤訊息;257 個不同簽名的 archetype)。
> **相依**:4.4 observers、10.2 job graph、17.11 schema、17.37 池(第一個消費者)、17.43 undo(使用延遲 add / remove 的反向操作)、17.78(runtime 定義元件另案)。
> **邊界**:**與 17.85 的分界**:17.85 擁有 tier 標籤元件 `Tier[N]`、「O(active set) 迭代」、tick 週期與相位、逐 island 品質、LOD / 分級策略與 awake list;本條**不**定義任何 tier
> 概念,也不做 per-system period。17.85 的 active set 只需正向 AND 查詢 `(Tier[0], ...)`,**不依賴**本條的 `Without` / `Changed`。介面關係有三,皆為 17.85 依賴本條的子項:
> (1)retag 要用延遲 `remove` —— 17.85 設計筆記明載「deferred `remove` must land first (17.77 gap)」(`docs/design/17.85-tiered-simulation.md:78-80`),
> 故本條的「延遲結構變更補齊」須早於 17.85 的 retag 路徑,可單獨先交付;(2)`Tier[N]` 標籤各占一個元件 ID 與 archetype 簽名,
> 撞上本條的型別規模防護(`ecs/archetype.mojo:42` 表註「8 型別 / 256 簽名」);(3)17.85 的 `TieredScheduler` 包的是 `Scheduler`,
> 但 `Runtime.advance` 不走 `Scheduler`(`gameplay/runtime.mojo:174-184`),要讓分頻作用於 `Runtime` 內的使用者系統,需本條的「`Runtime` 註冊點」。
> 場景 / prefab(17.12)、runtime 定義的元件型別(17.78)、undo 歷史(17.43)不在本條。

#### 17.79 資源治理 — Wave B

> **狀態**:🔶 部分完成(2026-10-14:記憶體記帳、body / joint 上限檢查、接觸數上限、`Runtime` 接 `SimBudget`、ECS 儲存的記帳 ✅;預留 / 穩態零配置量測、
> `BodySet` 尾端墓碑裁切、快取收縮未做;GPU 緩衝收縮屬第 7 層)。
> **進度註(2026-10-13)**:`physics/resources.mojo`:`resource_report(scene)` 回傳 bodies / colliders / shapes(hull、mesh 含 BVH 節點、heightfield、SDF)/ contacts / joints / soft
> 的使用中位元組(`len × size_of`,不含 broadphase 自身結構,所以是下界);`bytes_per_body` 給「再加 n 個 body 要多少」;`Limits(max_bodies, max_joints)` +
> `check_room(scene, limits, bodies, joints)` 在公開邊界 raise(只算存活 body,移除的槽不算);`SolverConfig.max_contacts` 在熱路徑丟最新的 manifold 並計入新計數器
> `CONTACT_DROPPED`。量測(`tests/test_resources.mojo` 8/8):每 body 329 bytes,預測再加 5000 個箱子 1645000 bytes,實測 1645000;一個 2 三角形網格 +314 bytes;
> 上限 12 時 10 + 2 通過、10 + 3 raise、移除 1 個後 9 + 3 通過;地面 10 箱、上限 3 時快取留 3 個、60 步丟 515 個、狀態有限;無上限時不丟。
> **進度註(2026-10-14)**:`Runtime.advance_budgeted(frame_dt, budget: SimBudget)`:每個固定 tick 前由 budget 設 `cfg.iters` / `cfg.substeps`,tick 的牆鐘時間回饋給
> `SimBudget.update`(超過目標 110 % 先減迭代再減子步,低於 70 % 依序恢復)。`tests/test_runtime_budget.mojo` 4/4:200 箱、1 ns 預算降到 1 × 1(每幀平均 4736 → 1274 µs),
> 10 s 預算維持 4 × 4 且與 `advance` 逐位相同,步驟進行中呼叫 raise。commit adfa2fc。
> ECS:`StorageBackend.storage_bytes` / `World.storage_bytes`(長度 × 元素大小,下界;不含容量餘裕與變更日誌),六後端各自實作,`SparseSet.bytes`。
> `tests/test_ecs_bytes.mojo` 13/13:1000 個實體(A 16 bytes、半數另有 B 8 bytes,payload 20000 bytes)—— sparse-set / reactive 80576、archetype 92408、bitset 48384、
> naive 49000、chunked 49960 bytes;2000 個實體在六後端皆為 2.00 倍(archetype 1.9998);sparse-set 全部 despawn 後 80576 → 40576(稀疏索引保留)。
> **緣起**:被嵌入的函式庫必須能回答「你用了多少記憶體、最多會用多少、超限時怎麼辦」。現況每個容器各自為政:有的有上限、有的無上限成長,沒有統一的用量讀數,
> 「穩態不配置」也無從驗證。
> **現況**:
> - **計數器是事後記帳**:`Counters`(`diag/counters.mojo:117-143`,`COUNT = 15`,`:79`)有 `POOL_GROWN`(`:39`)/ `POOL_EXHAUSTED`(`:41`)/ `ARENA_OVERFLOW`(`:37`)/
>   `EVENT_DROPPED_UNREAD`(`:44`)/ `FRAGMENT_EVICTED`(`:70`)等,記的是「發生過幾次」,沒有「用了多少位元組」。
> - **各處自帶上限、互不相通**:`TraceBuffer(capacity=512)` / `LogRing[256]` / `DrawQueue(capacity=1024)`(`physics/solver6.mojo:200-202`)、`Pool(cap)`(`ecs/pool.mojo:145`)、
>   `FractureSet.enforce_budget`(`physics/fracture.mojo:446`)、`Channel` 的雙緩衝(`scheduler/events.mojo`)。
> - **主容器無上限、不收縮**:`ContactScene6` 的 per-body 列與 `cache` / `joints` 等都是 `List`(`solver6.mojo:187-205`);`BodySet.remove` 墓碑並重用最低空 slot
>   (`physics/body_set.mojo:85-91,143-153`),slot 數只增不減、無壓實;GPU 緩衝只增不減(`physics/gpu_contact.mojo:327-336` 的 `_reserve`)。
> - **無用量 / 上限 / 預留 API**:grep `memory_usage|bytes_used|footprint|max_bodies|max_entities|MAX_BODIES|def reserve|def shrink|def defrag` 於
>   `ecs physics collision gameplay scheduler diag` 只命中 `ecs/chunked_backend.mojo:153`(單一後端的 `compact`)與註解中的 "footprint" 字樣。
> - **「穩態零配置」目前不成立,也無法驗證**:每 tick 仍配置 `fired`(`gameplay/runtime.mojo:193`)、`_sync_transforms` 四個 List(`:231-234`)、`_capture_history`(`:130`)、
>   `_collect_pairs` 的回傳 List(`solver6.mojo:1233`);`FrameArena` 引擎內零使用者(見 17.75 現況的 grep);沒有任何配置次數的計數。17.34 的量測已顯示 List-per-frame 比 arena 慢
>   1.5–4×(`docs/ROADMAP.md` 17.34 進度註),所以接線有量化的預期收益。
> - **時間預算有、但沒接到 Runtime**:`SimBudget`(`physics/lod.mojo:58-94`)吃呼叫端量測的 ns;grep `DistanceLOD|SimBudget` 於 `gameplay` 零命中。
> - **執行緒預算僅一個寬度欄位**(`SolverConfig.workers`,`solver_config.mojo:61`);GPU 為每進程單一 `DeviceContext`(`CLAUDE.md`)。
> **缺口**:
> - **記憶體記帳**:`ResourceReport`(每子系統位元組:`BodySet` / `ColliderSet` / warm-start `cache` / islands / broadphase / ECS 儲存 / 暫存 / GPU 緩衝),宿主可查。
>   例:載入關卡前問「再加 5k 個 body 會多用多少」。
> - **容量上限與滿載政策**:`Limits{max_bodies, max_contacts, max_joints, max_entities, max_scratch_bytes}`;依 `ARCHITECTURE.md` §2 的兩列分流 —— 公開 API 邊界超限 → `raise`
>   (例:`add` 超限回錯而非 OOM abort),熱路徑超限 → 丟最新並計數。
> - **預留與穩態零配置**:`reserve(...)` 預先配置;`AllocStats`(每 tick 配置次數 / 位元組)成為可斷言的量測 —— std `List` 沒有 allocator 參數(17.75 已驗),
>   所以量測走測試端的 `LD_PRELOAD` malloc 計數 shim,或改用引擎自有容器內建計數;`Runtime` 的每 tick 暫存全數改走 `FrameArena`(注入點由 17.75 提供),
>   「穩態 tick 配置次數 == 0」變成測試。
> - **收縮**:`BodySet` 只裁切**尾端連續墓碑** slot 並收縮容量 —— 不重編號,保留 `physics/body_set.mojo:85-91` 的穩定 slot
>   約束(任意位置壓實會重編號所有以 slot 為鍵的側表,與 `BodyId` 的設計目的衝突);快取回收、GPU 緩衝收縮;
>   例:關卡切換後峰值記憶體不應永久占用。
> - **執行緒 / GPU 資源政策**:worker 預算由誰決定(與 17.75 的派發器互補:派發器決定怎麼跑,本條決定最多用幾個)、GPU 設備記憶體上限。
> - **資源上限觸發的退讓**僅限「一次性退讓並計數」(例:暫存 arena 滿 → 本 tick 該批資料改走 List 並 `ARENA_OVERFLOW++`),不涉逐實體品質。
> **對照組**:Jolt `PhysicsSystem::Init(maxBodies, maxBodyPairs, maxContactConstraints, ...)` 的初始化即定容量 + `TempAllocator` 預留每步暫存;PhysX `PxSceneDesc` 容量提示與 GPU 的
> `PxgDynamicsMemoryConfig`;Box2D v3 的每步 arena 配置器(依上一步用量成長);MuJoCo `mjModel` 的 `nconmax` / `njmax` 與 `mjData` arena;Unity DOTS `Allocator.Temp` / `TempJob` / `Persistent`;UE `FMemStack` + LLM。
> **優勢區**:中 —— Mojo 無 GC,用量是確定的,「穩態零配置」可以做成**機器斷言**(配置計數 == 0)而非靠 profiler 觀察(對照:託管引擎要調 GC);引擎已有「丟最新並計數」政策與 `Counters`,
> 延伸成統一用量面架構一致。
> **規模軸**:body / contact 數 1e3–1e6 × 每 tick 配置次數與位元組;峰值記憶體 vs 最終活躍數(碎片);有無 `reserve` 的首幀延遲尖峰;壓實的成本 vs 回收量。
> **seam?**:否 —— 本條是政策與記帳層;暫存配置的可替換 seam(`List` / `FrameArena` / 宿主區塊)屬 17.75。本條的機器驗證:`Limits` / `ResourceReport` 開啟與否 `write_state` 位元組全等
> (on/off parity,同 17.10 的寫法)+ 記帳開銷 bench。
> **交付**:普通(`ResourceReport` 在 N 個 box 的已知場景下位元組與手算上界吻合;超限 `add` 回錯)/ 整合(`Runtime` 跑 10 箱疊塔 300 tick 後穩態 `AllocStats == 0`;尾端裁切後被裁 slot 的舊 `BodyId`
> 被偵測為 stale、其餘 `BodyId` 不變,世界逐位續跑相同)/ 極端(容量 0、容量 1、剛好等於上限、超限後 despawn 再 add 恢復、1e6 body `reserve` 失敗時的行為 —— Mojo `alloc` 失敗是否可回報**待探針**、裁切發生在 island 睡眠中、`reserve` 後仍超限)。
> **相依**:17.34(arena)、17.75(注入點)、17.32 / 17.33(log / 斷言輸出)、17.37(池)、17.0g `BodySet`、17.31(`SimBudget` 時間預算)、17.83(效能回歸基準)。
> **邊界**:**與 17.85 的分界**:17.85 擁有 tier plan(逐實體 / island 的時間與空間解析度)、tick 週期、active set、逐 island 品質、LOD 策略、`BudgetTiers`(依量測步進成本移動 tier 門檻)、
> awake list 與增量 broadphase。本條**不**決定誰拿到多少品質,只提供**硬上限與用量讀數**;`ResourceReport` 可作為 `BudgetTiers` 的輸入之一,但 tier 門檻的調整屬 17.85。
> 幀時間預算(`SimBudget`)仍屬 17.31 / 17.85;17.83 是 CI 層的效能回歸治理(基準線與門檻),本條是執行期資源;宿主配置器的注入點屬 17.75。

#### 17.80 觀測 — Wave B(工具;執行期追蹤開關、物理擷取檔與回看)

> **狀態**:🔶 部分完成(2026-10-14:(a)執行期開關、(b)環形模式與 `TRACE_DROPPED`、(d)counter 軌、(e)擷取檔含 delta 編碼與只記接觸變化、(f)隨機讀取、重模擬驗證與
> `DrawQueue` 回放、(g)C-ABI 出口 ✅;(b)span 名 interned id 量測後不採用;(c)平行工作者各自的 trace 軌未做,GPU 軌屬第 7 層)。
> **進度註(2026-10-13)**:`diag/trace.mojo`:`TraceBuffer.enabled`(`-D LUDENS_TRACE` 編入時的執行期開關;關閉時 span 只記深度,開關切在 span 中間也不會讓巢狀錯位)、
> `ring`(滿了覆寫最舊者)、`sample(name, value)` 與 Chrome 匯出的 `C` 事件(solver 每步記 `contact_manifolds` / `bodies`)、`take_dropped()`;`ContactScene6.step` 步末把新丟棄數加進
> `Counters` 的 `TRACE_DROPPED`(原本無人遞增)。`physics/capture.mojo`:`Capture.record`(每步:body 位姿 / 速度 / 睡眠 / island,接觸的法向 / 點 / 深度 / 累積衝量;
> 每 `key_every` 幀一個 `scene_to_bytes` 關鍵幀;`set_region` 只記中心在區域內的 body 與碰到它們的接觸)、`to_bytes`(引擎不寫檔,交給宿主)、`CaptureReader.frame(k)`
> 隨機讀取、`verify(reader, start, frames, dt, gravity, cfg)` 從 ≤ start 的關鍵幀重模擬並回報第一個逐位不符的幀。
> 量測:`tests/test_trace_runtime.mojo` 以子程序跑 `-D LUDENS_TRACE` 的 `tests/probes/trace_on_probe.mojo`(6/6:5 步 35 個 span、關閉後 5 步仍 35;span 中切換不錯位;
> 4 格環形 10 個 span 後保留 s6–s9;匯出有 `C` 事件;8 格緩衝 10 步丟 74,`TRACE_DROPPED` = 74)。`tests/test_capture.mojo` 9/9:120 幀每幀與重跑的即時狀態逐位相同(body、island、接觸);
> 從幀 45 驗 60 幀無差異,竄改幀 70 的一個位元時回報 70;區域擷取只留堆疊的 3 個 body 與 3 個接觸(600 vs 808 bytes)。
> bench `bench_capture`:N = 64 / 1024 時每步 2246 / 36898 µs,記錄 41 / 362 µs(約 1–2 %),每幀 12388 / 196708 bytes(約 192 bytes / body,無 delta),
> 關鍵幀 30556 / 483676 bytes,解碼一幀 49 / 432 µs,約十分之一地面的區域擷取每幀 792 / 17688 bytes。
> **進度註(2026-10-14)**:
> - (b)interned span id 實作後量測(`-D LUDENS_TRACE`,10 萬個 span,7 次取最佳):原本複製字串 62 ns / span;預先 intern 後 `begin_id` 64 ns;`begin(name)` 經 Dict 查詢 100 ns。
>   名稱複製沒有可量到的成本,interning 只會讓既有的 `begin(name)` 變慢,所以撤回不提交。
> - (e)擷取檔格式 2(預設):一幀只記位元組有變的 body 紀錄與不再記錄的 slot;接觸在 (a, b, feat) 序列與上一幀相同時依位置只記有變的紀錄,否則整份;
>   關鍵幀那一幀是完整幀,`frame(k)` 從它往後套用。`Capture(delta=False)` 仍寫格式 1,讀取兩者皆可。`tests/test_capture.mojo`:240 幀的 delta 解碼與完整幀逐欄位相同;
>   堆疊入睡後 60 幀 13096 vs 48480 bytes(球仍在滾)。`bench_capture`(1024 箱):入睡時每幀 48 vs 196708 bytes;清醒時 212831 vs 196708 bytes(+8 %,位置索引與 feat),
>   記錄 1114 vs 339 µs(步長 32 ms 的 3.5 %),解碼 13.7 vs 0.46 ms(從關鍵幀重放,隨機讀取要快就調小 `key_every`)。
> - (f)`draw_frame(frame, queue)`:每個 body 一個點(睡眠為灰、否則 island 色),每個接觸點一支沿法向的箭頭(與場景 debug draw 相同,調色盤移到共用的 `contact6.island_color`);
>   幀 100 自檔案繪出的 13 支箭頭與即時場景的點、法向、顏色相同,另 5 個 body 點。
> - (g)C-ABI 0.3:`ld_world_capture_begin` / `end` / `size` / `read`(凍結清單追加),Python `World.capture_begin` / `capture_end` / `capture_bytes`;
>   `test_capi` 58/58(記 25 tick、end 後不再記、小緩衝與 key_every 0 被拒),`test_python_binding` 14/14。
> - commit e2f3972、4dda989、881f932。
> **緣起**:17.10 只做到「編譯期開關 + Chrome trace 匯出」,其進度註自列待辦「需 runtime 開關」(ROADMAP §17.10);編輯器邊界表也把「Profiler 面板」的 runtime 開關與擷取檔
> 掛在本條(ROADMAP「(II) 圖形化編輯器依賴的核心功能」)。嵌入場景下宿主需要的是:隨時打開 / 關掉追蹤、事後看一段模擬發生了什麼。
> **現況**:
> - **追蹤開關是編譯期的**:`TRACE_ON = is_defined["LUDENS_TRACE"]()`(`diag/level.mojo:45`),`TraceBuffer.begin/end` 以 `comptime if TRACE_ON` 閘控(`diag/trace.mojo:83,90`)—— 開關需重編;
>   `diag.md` 與 `ARCHITECTURE.md` 禁全域可變狀態(`docs/design/diag.md:18`、`docs/ARCHITECTURE.md:16`),所以 runtime 開關只能是實例欄位。
> - **緩衝政策不適合長時間開著**:容量滿即 drop-newest(`trace.mojo:95-98`),`scene.trace` 容量 512(`physics/solver6.mojo:200`),每步 4–5 個 span(`solver6.mojo:1232-1275,1302-1360`)→ 約 100 步後只剩舊資料;
>   grep `trace.clear` 於 `physics gameplay scheduler collision diag` 零命中(沒有任何自動清除);`TRACE_DROPPED`(`diag/counters.mojo:35`)只有定義與名稱表(`:91`),grep 全樹 `*.mojo`(排除 build / .pixi)無遞增處 —— 丟棄只記在實例欄位
>   `TraceBuffer.dropped`(`diag/trace.mojo:70,98`),未進共用 `Counters`;
>   span 名是 `String` 複製(`trace.mojo:47,84`)。
> - **匯出只有 X 事件**:`to_chrome_json`(`trace.mojo:133-152`)無 counter 軌(`ph:"C"`)、無執行緒名 metadata;`tid` 是建構期常數(`trace.mojo:74-79`),並行 island 區(`solver6.mojo:1393-1407`)內沒有 span;
>   GPU 路徑只有各自的 `perf_counter_ns` 計時欄位(`physics/gpu_contact.mojo:316,368-479`),未併入時間軸。
> - **沒有「結果擷取」**:`ContactScene6` 只留當步的 `events`(`solver6.mojo:178-179`)與編譯期旗標 `LUDENS_DEBUG_DRAW`(`diag/level.mojo:48`)下的接觸箭頭(`solver6.mojo:982-1014`,`DrawQueue` 容量 1024);
>   決定論快照 `write_state` 只支援 `ContactScene6[QuatBody6]`(`solver6.mojo:1410`);`gameplay/replay.mojo` 的 `Recorder`(`:101`)錄的是**輸入 + 每 `interval` 快照 + 每 tick FNV 雜湊**(`:86-98`),
>   為「重新模擬」而設,且在記憶體中(17.39 待辦「錄製檔案化」);沒有每步 body 位姿 / 接觸點 / 衝量 / 關節力 / island 的記錄,無法不重跑就回看。
> - **格式落點受限**:`ARCHITECTURE.md:16` 的 diag 列「Must NOT own: file formats beyond a trace dump」→ 擷取格式不能住 `diag`;引擎不做檔案 I/O(grep `open(|write_text|read_text` 於引擎套件只命中
>   `w.write(` 的 `Writable` 實作)—— 輸出 bytes,由宿主 / 工具落檔(同 `gameplay/save.mojo` 與 17.39 的待辦口徑)。
> **缺口**:
> - **(a)runtime 追蹤開關**:`TraceBuffer.enabled`(實例欄位),三態 —— 編譯期剔除(現況零成本)/ 執行期關(一次分支)/ 開;加過濾(類別、最小時長、取樣率)讓它能長時間開著;
>   「同一行程交錯量測 on/off」取得 17.10 待辦的乾淨 overhead 數字。
> - **(b)緩衝政策**:環形模式(保留最新)與 drop-newest 可選;每步自動 frame marker / 清除;span 名 interned id(免每 span 配置 String);遞增 `TRACE_DROPPED`。
> - **(c)多執行緒與 GPU 軌**:每 worker 一個無鎖緩衝 + 匯出時合併,island 並行區與 job graph 同層系統內有 span 與 `tid`;GPU 計時段併入同一時間軸。
> - **(d)counter 軌**:`Counters`(接觸數 / pairs / islands / iters)以 Chrome `C` 事件匯出,Perfetto 可載入。
> - **(e)物理擷取檔**:每 tick 記 body 位姿 / 速度 / 睡眠 / island 標籤、接觸(點、法向、深度、累積衝量)、關節反力、事件、solver 設定;版本頭 + schema(接 17.11)+ 週期關鍵幀 + 其間 delta 編碼
>   (與 17.39 同思路);選擇性擷取(AABB 區域 / 指定 body / 只記接觸變化),因 1e5 body 全記太大。住 `physics`(`serialize.mojo` 旁),不住 `diag`。
> - **(f)回看**:`CaptureReader` 可隨機 seek 任一 tick 取狀態(不模擬)、逐 tick 驅動 `DrawQueue` 重現接觸與 island 視圖;另有「擷取 → 關鍵幀快照重模擬 → 與擷取的後續 tick 逐位比對」橋(重用 17.39 `first_divergence` 的概念),
>   使擷取檔**可驗證**。
> - **(g)宿主面板出口**:Chrome-trace JSON 與擷取 bytes 皆可經 C-ABI 讀出(→ 17.78)。
> **對照組**:PhysX Visual Debugger(PVD)擷取檔、Jolt 的 `DebugRenderer` 錄製 + `StateRecorder` 與 JoltViewer 回放、Unreal Chaos Visual Debugger(CVD)擷取檔、Havok Visual Debugger;追蹤側:Tracy、Perfetto、UE Insights、Unity Profiler 擷取。
> **優勢區**:中高 —— 決定論快照(6.10 逐位相同)+ 17.39 的 `seek` / `first_divergence` 讓「擷取 + 重模擬 + 逐 tick 雜湊比對」成為可能:本庫的擷取檔可被驗證(關鍵幀重跑須與擷取的後續 tick 逐位相同),
>   PVD / CVD 類擷取只是不可驗證的錄影。
> **規模軸**:body 數 × 每 tick 記錄位元組;關鍵幀間隔 × seek 延遲 × 檔案大小(沿用 17.39 `bench_replay` 的設計:間隔 10 → 0.10 ms、120 → 4.2 ms);trace on/off 的交錯 overhead × span 密度;
>   擷取選擇度(全記 / AABB 區域 / 只記接觸變化)。
> **seam?**:是 —— (a)追蹤三態(編譯期關 / 執行期關 / 開):`write_state` 位元組全等(追蹤不影響模擬)+ 同行程交錯 overhead bench;(b)擷取編碼 全量逐 tick vs delta + 關鍵幀:讀回任一 tick 的狀態逐位相同 +
>   檔案大小 / seek 延遲 bench 列。
> **交付**:普通(開 runtime 開關跑 stack 場景 → JSON 含各階段 span;關 → 0 事件;擷取 100 tick → 讀回第 k tick 的位姿逐位等於實況)/ 整合(擷取 + 關鍵幀重跑 → 與擷取後續 tick 逐位相同,`Runtime` 場景含 `ContactEvent` 流;
>   JSON 欄位 `ph / ts / dur / pid / tid` 合 Chrome Trace 格式;並行 island 場景每 worker 有 `tid` 軌)/ 極端(緩衝容量 0、1,滿載後環形覆蓋;開關每步翻轉;擷取中途 body despawn 與 slot 重用(記錄 generation);
>   截斷檔 / 壞 magic / 較新版本拒載(同 `gameplay/save.mojo` 規格);1e5 body 選擇性擷取;擷取期間發生 NaN 隔離事件;擷取不改變模擬位元)。
> **相依**:17.10(`TraceBuffer`)、17.9(`DrawQueue` 重現)、17.32(log 併入時間軸)、17.39(快照 / seek / 雜湊)、17.11(schema 版本化)、17.40(版本拒載風格)、17.75(arena)、17.78(C 讀出)。
> **邊界**:檔案 I/O 與視覺化 UI(時間軸、面板)屬宿主 / 工具;擷取格式住 `physics`,`diag` 只持 runtime 開關與緩衝;17.63 輸出 / 快取是**成品資料交換**(模擬快取 / 稀疏體積,給 DCC 或宿主播放),
> 本條是**診斷擷取**(給人除錯),兩者不共用格式;反作弊與線上遙測屬宿主;GPU kernel 內部剖析(Nsight 類)屬廠商工具,本條只併入時間區段。

#### 17.85 分級模擬:依因果可達性分配時間 / 空間解析度 — Wave C(架構)
> **狀態**:🔶 部分完成(2026-10-12 第一刀;2026-10-14 ECS `Tier[N]` tag、軟體逐物件 period、n = 1e4 重量測 ✅)。設計筆記末段「Delivered」記錄與原設計的差異。
> **進度(2026-10-12)**:
> - 物理逐 island 分級(`ContactScene6.set_tier_table` / `set_body_tiers` / `_step_tiered`):tier 表 = 每 tier 的 (iters, substeps, period);island 取成員中最細的 tier(合併取較細者),相位 = 首個成員 slot,到期的 island 以 period × dt **catch-up** 解(不丟模擬時間;原設計的「off-phase 只以速度積分位姿」會讓靜止堆疊在兩次解之間互相沉入,因此改掉),period 0 = 不解(凍結端,不轉 static)。關掉 17.31 的「逐 island 品質分級」待辦。
> - 全 0 計畫(tier 0 = 該步設定)與不分級**逐位相同**:QuatBody6 × BVH / 持久 DBVH、ScrewBody6(`test_tiers_parity`)。
> - 策略 seam `TierPolicy`(`gameplay/tiers.mojo`):`DistanceTiers`(多圈 + 遲滯)、`CausalReach`(沿上一步接觸 + 關節 BFS,static 不傳導)、`RoundRobin`、`BudgetTiers`;`Runtime.advance_tiered[P]`;`scheduler/tiered.mojo` `TieredScheduler[S]`(系統包的時間解析度)。
> - 快照格式 v3:`step_index`、tier 表、計畫入快照,還原後逐位續跑(`test_system_tiers`:150 步快照 + 60 步 == 不中斷 210 步)。
> - 順帶修掉 island 路徑的兩個平方項:`_solve_island` 每島掃全部 body(O(bodies × islands))與 pair 分島的 O(pairs × islands) 過濾 —— 改成線性分割(`_island_partition`)後,1e4 body 的全 0 計畫從 885 ms / 步降到 322 ms(與不分級 333 ms 持平),既有 island 平行路徑同樣受益,結果逐位不變(`test_islands_par`)。
> - 測試:`test_tiers`(26)、`test_tiers_parity`(11)、`test_system_tiers`(7,1800 個 awake body,觀察者斜穿世界:3430 次 tier 變動,位置跳變最大 7 mm、速度跳變 ≤ 一個粗步重力、穿透比全品質多 4.3 cm、每步解的 body 627 vs 1800)。
> - 量測(`bench_tiers`,awake 兩箱堆疊,觀察者在角落):n = 1e3 不分級 28 ms / 步 → DistanceTiers 7.3、CausalReach 5.5、RoundRobin 5.0、BudgetTiers 5.0 ms(粗 tier 穿透 +35 mm);n = 1e4 333 ms → 138–145 ms。1e4 時剩下的約 70 ms 是收集 pair(寬相 + 窄相)的全量成本,tier 還沒碰到它。
> **進度(2026-10-13)**:「兩端都沒動的 pair 跳過窄相」—— `SolverConfig.reuse_still_pairs`(預設關):`try_pair` 只依賴碰撞器、兩端位姿與線速度、`spec_dt` 與裕度,
> 所以兩端位姿與速度與上次收集逐位相同(且 `ColliderSet.epoch` —— 每個改動碰撞器的方法都會遞增 —— 與 `spec_dt` / 裕度不變)的候選對直接複製上次的窄相輸出,
> 依候選順序串接,輸出與一般路徑相同(`ContactScene6._narrow_reuse`)。`tests/test_np_reuse.mojo` 8/8 皆與一般路徑逐位相同:DistanceTiers 下 200 箱的分級堆疊
> (120 步複製 16358 個候選對);睡著的堆疊中途改 filter 並開 `parallel_collision`;中途抬高 heightfield 0.1 m(箱被抬到 y 0.2999);無物體;全部在落(不複製);中途移除 body。
> 量測(`bench_tiers`,n = 1e4,兩次執行):BVH 後端時 reuse 的差在執行間雜訊內(DistanceTiers 163 / 196 ms vs 加 reuse 166 / 211 ms);
> 換成持久 `DbvhBroadPhase`(只重插移動者)後 DistanceTiers 為 56 / 58 ms(約 3 倍),再加 reuse 52 / 54 ms(兩次皆省約 7 %)。
> 也就是 1e4 時的剩餘成本主要是每步全建的 BVH,而不是窄相。為此 `TierPolicy.assign` 改為對 broadphase 泛型(原本只接受預設 BVH 的場景)。
> **進度(2026-10-14)**:
> - ECS tag:`gameplay.tiers.Tier[N, BASE]`(元件 ID = BASE + N),`Runtime.sync_tier_tags[NT, BASE]()` 依 `scene.tier_of` 給每個 body 實體掛上其 tier 的 tag、拿掉其他 tag,
>   只寫有變的實體;`tests/test_tier_tags.mojo` 8/8(sparse-set 與 archetype:每個 body 恰一個 tag 且等於場景 tier,觀察者移動後跟著變,計畫外的 body 為 tier 0)。commit 9314530。
> - 軟體逐物件 period:`ContactScene6.set_soft_period(s, period, phase)`,到期步以 period × 子步追上(不丟模擬時間),快照帶 period / phase;
>   `tests/test_soft_period.mojo` 5/5(period 1 與預設逐位相同;period 4 靜止高度 0.0333 m 與 period 1 相同;60 步中動 15 步;中途快照續跑逐位相同)。commit 84b0385。
>   LBM 不做 period:格子步長由格子單位固定,追上就是連跑 period 個格子步,省不到計算,與凍結等價;粒子系統同理需要先有逐粒子的步長契約(17.55)。
> - 重量測(`bench_tiers`,n = 1e4,本容器 4 核,ms / 步):不分級 340;DistanceTiers 66(原 138–163)、CausalReach 66、RoundRobin 71、BudgetTiers 78;
>   DistanceTiers + 持久 DBVH 51(原 56–58),再加 reuse 46。下降來自 17.54 的 BVH 建樹平方項修正(7dd31d2):原本剩下的約 70 ms 大半是每步重建 BVH。
> **剩餘**:睡眠 bookkeeping 的 awake list(`update_sleep` / `refresh_islands` 已是 O(n) 線性迴圈,需先量佔比)、`BroadPhase.update_moved`(BVH 重建已降到 3.8 ms / 4097 個,
> 是否還值得增量更新待量)、`Aggregate` 策略、n = 1e5 量測(預設 brute pair 路徑在此規模不可用,須 `broadphase=True`)。
> **緣起**:2026-10-10 使用者提問 —— 世界中實體數遠大於玩家能產生因果交互的實體數時,
> 引擎能否以適當的時間 / 空間解析度維護 simulation state,且分級(LOD)模組本身可替換。
> 設計筆記:`docs/design/17.85-tiered-simulation.md`。
> **現況**(已核對原始碼):**做不到**。執行模型是「每個 fixed step × 所有系統 × 所有實體 ×
> 全精度」。`System.apply` 無狀態、`Scheduler.tick` 跑整個 pack、`FixedLoop` 單一 dt、job graph
> 的 level 只給並行度(`scheduler/scheduler.mojo:26-46`、`gameloop.mojo:45-49`);ECS 查詢只有
> AND 交集,`Disabled` 是事後過濾仍 O(全部)(`ecs/pool.mojo:264-290`);17.31 的 `DistanceLOD`
> 只有凍結 / 不凍結二值且單一觀察點,`SimBudget` 的 iters / substeps 是全域(
> `solver6.mojo:1393-1396` 對每個 island 傳同一組值),而且 **`Runtime` 根本沒接它們**;
> island 睡眠的 bookkeeping(`refresh_islands` / `update_sleep` / `wake_island`)全是 O(全部
> bodies),睡–睡 pair 仍每步進 narrowphase 再早退;`BroadPhase.rebuild(items)` 每步餵全部 n;
> 軟體 / LBM / SPH 每個 substep 全跑。「可交互集合 ≪ 總數」這個條件沒有任何地方被利用。
> **缺口**:
> - **時間解析度**:系統 / 實體群的 tick 週期(每 N 步、分相錯開),現在完全不可調。
> - **空間解析度**:逐 island 的 iters / substeps / period(17.31 TODO),以及介於全速與凍結
>   之間的「低頻步進 + 速度積分」中間檔。
> - **active set**:ECS 以 tag 元件 `Tier[N]` 讓系統 O(active set) 迭代;睡眠 bookkeeping 改
>   awake list;`BroadPhase` 加 `update_moved(items, moved)`(預設退回 `rebuild`,DBVH 增量)。
> - **分級策略本身可替換**(`trait TierPolicy`,輸入 world + scene + 觀察者**集合** + step_index,
>   輸出每實體 / island 的 (tier, period, phase)),且是快照狀態 + step_index 的純函數(接 17.39 /
>   17.40)。
> **對照組**:UE World Partition + Significance Manager、Unity DOTS 的 per-system rate 手工實作、
> Havok 自適應求解、MMO 興趣管理(AoI);**本庫內部對照**:17.31 freeze(seam 的最粗一端)。
> **優勢區**(策略間互為對照,各有規模軸):`DistanceTiers`(單觀察者、開放地形)vs
> `CausalReach`(沿 island / 接觸圖 / 事件訂閱圖 BFS;多觀察者、室內分隔空間 —— 距離近但因果遠)
> vs `BudgetTiers`(硬幀率上限)vs `RoundRobin`(無焦點的均勻群體)vs `Aggregate`(極遠處聚合替身,
> 後排)。後三者目前**都不存在**,seam 不是空設計。
> **規模軸**:總實體數 n ∈ {1e3, 1e4, 1e5} × 固定約 1e2 的可交互集合;每步成本、相對全品質
> 的穿透誤差、升級(re-promotion)瞬間的速度誤差。
> **seam?**:是 —— `TierPolicy` 各變體;parity 錨點:全零 plan(tier 0 / period 1)必須與現在的
> `Runtime.advance` **逐位相同**(沿用 17.31 的寫法),且在既有 parity 矩陣的每個 backend ×
> broadphase 組合上成立;bench 每策略一列。CATEGORY.md §2.14 的「品質參數 seam」(無 trait)由此取代。
> **交付**:`gameplay/tiers.mojo`(`TierPlan` / `TierPolicy` / 四個策略)、`scheduler/tiered.mojo`
> (`TieredScheduler` 包既有 scheduler,`DeclaredSystem` 加 `period()`)、物理三處(逐 island
> 品質、awake list、`update_moved`)。測試:普通(plan 形狀、遲滯、`RoundRobin` 每週期每實體恰一次、
> `CausalReach` 深度單調)/ 整合(全零 plan == 現狀逐位;距離與因果一致的場景下兩策略結果相同)/
> 系統(1e4 bodies、觀察者橫越世界:無分級切換造成 > slop 的穿透跳變、速度連續、快照→還原→續跑
> 與不中斷逐位相同)/ 極端(觀察者在牆內、接觸中改 period、觀察者全部移除、遲滯帶抖動、
> 不同 tier 的 island 合併取較細者)。`bench_tiers` + 範本一列。
> **相依**:用 17.31 freeze、6.11 島著色、17.10 profiling(預算輸入)、17.11 反射(tag 註冊)、
> 17.39 / 17.40(plan 必須是快照狀態的函數);**前置 17.77**(延遲 `remove` —— `CommandBuffer` 今日只有
> despawn / relate / unrelate;`Tier[N]` tag 吃 archetype 簽名上限;`Runtime.advance` 不經 `Scheduler`,
> `TieredScheduler` 需要 17.77 的系統註冊點才有消費者);餵 17.16 rollback(relevance 集合就是 `CausalReach`
> 走的同一張圖)、17.8 大世界(分區 cell 是天然的 tier 邊界)、17.14 / 17.15(導航 / AI 依 tier tick)。
> **邊界**:軟體 / LBM / 粒子第一刀只拿同一 plan 的 per-object period,不改內部;`Aggregate` 替身排後。

---

## 嵌入、腳本與平台

範圍:C-ABI、Python 綁定、宿主整合、平台。

| 編號 | 條目 | 狀態 | Wave | 說明 |
|---|---|:-:|:-:|---|
| 12.1 | [Core embedding 邊界(C-ABI)](#121-core-embedding-邊界c-abi) | ✅ | C | `embed` 套件 + `build/libludens.so`(`pixi run capi`)+ `embed/ludens.h`:35 個 C 函式涵蓋世界建構、系統註冊(C 回呼)、查詢、事件訂閱、存讀檔、導航;v0.x 凍結清單 `embed/abi_v0.txt` 由測試機械檢查。 |
| 12.2 | [Mojo / Python 雙腳本](#122-mojo--python-雙腳本) | ✅ | C | Python(`ludens` 套件,ctypes 包 12.1 C-ABI)與 Mojo 原生系統(`EmbedWorld`)雙腳本,同場景逐位相同;落地見 17.21。 |
| 17.21 | [腳本層(Phase 12 落地)](#1721-腳本層phase-12-落地) | ✅ | C | `python/ludens`(ctypes 包 C-ABI)+ `python/build_wheel.py`(wheel 內含函式庫與 Mojo runtime);乾淨 venv 安裝測試;Python 系統 / 接觸訂閱、CVar(tick 邊界套用)、hot reload(保留狀態、失敗保留舊版)。 |
| 17.75 | [嵌入契約](#1775-嵌入契約--wave-b平台方向-c-前提與-121-同期) | 🔶 | B | 宿主 job system 注入、宿主配置器(分兩層)、非同步步進、單位與座標契約成文 + `UnitScale`、錯誤與執行緒契約 |
| 17.76 | [平台可攜](#1776-平台可攜--wave-b平台方向-c-前提) | 🔶 | B | 目標矩陣 + 實測、每目標一份 golden + 跨目標容差表、浮點位元因子清單、降級矩陣、wasm 核心切分的機器檢查 |
| 17.78 | [宿主整合 / 綁定](#1778-宿主整合--綁定--wave-c) | 🔶 | C | per-host 適配層、批量 SoA 交換、POD 事件緩衝、宿主定義元件、綁定產生、多實例與執行緒 |

### 待辦與部分完成條目

#### 12.1 Core embedding 邊界(C-ABI)

> **狀態**:✅ 完成(剩餘順序第 (5) 項)。2026-10-12 交付,設計筆記 `docs/design/12.1-embedding.md`。
> **進度(2026-10-12)**:
> - 新套件 `embed`(層 6,與 `oop` 同層互不引用):`embed/world.mojo` `EmbedWorld`(值語意 API:body 為 `slot | generation << 32` 的 `Int64` 把手、姿態為 f32 與 x,y,z,w 四元數、
>   接觸事件為五個 `Int64`;非法輸入在此 raise 一次)、`embed/navigation.mojo` `EmbedNav`(三角形湯烘焙 + 平滑路徑)、`embed/capi.mojo`(C-ABI 薄殼,
>   `pixi run capi` 建出 `build/libludens.so`)、`embed/ludens.h`(35 個函式、狀態碼 `LD_ERR_*`、`ld_contact_event`、系統 / 接觸回呼型別)。
> - 契約:回傳 `>= 0` 成功、`< 0` 為錯誤碼並可取 `ld_world_last_error`;輸出緩衝由宿主擁有,過小回 `LD_ERR_BUFFER` 不寫入;每 tick 為 PRE 系統 → 物理 → 接觸訂閱者 → POST 系統,
>   回呼非零即停步並回 `LD_ERR_CALLBACK`;回呼可重入同一世界(destroy / load 被拒為 `LD_ERR_STATE`),tick 迴圈在 C 薄殼,回呼期間不持有 Mojo 參照;
>   一個世界同時只由一個執行緒使用。可空指標以 `Optional[Pointer]` 接(Mojo 1.1 的指標非空;已探針 C 端傳 NULL 為 `None`,測試每次建置都驗)。
> - 凍結:`embed/abi_v0.txt` 列出所有宣告、typedef 與常數行;`test_capi` 檢查每行仍逐字在標頭內,且 `nm -D` 匯出集合 == 標頭宣告集合。之後的 minor 版只能加。
> - 測試 `test_capi`(54,integration):建出共享庫、以 `gcc -Werror` 編譯 `tests/capi/host.c` 並執行;C 端以 C 回呼當 PRE / POST 系統、C 訂閱者計接觸,
>   跑 120 frame(累加器)+ 120 tick;同場景以 Mojo 原生迴圈在 `EmbedWorld` 上跑 —— **世界雜湊相同**,BEGAN / ENDED 數、事件總數、玩家位置、射線、導航路徑點數與長度皆相同;
>   每個錯誤碼路徑都有一條(slot 重用後的舊把手、NaN、零質量、短緩衝、壞 blob、回呼失敗於第 3 次停在 2 tick、回呼內 destroy)。
> - 量測(`bench_capi`,20 tick 熱身後計 120 tick;逐 body 取狀態各 1e6 次):同一步進(每 10 個 box 由系統推動)C 宿主 vs 原生,100 / 1000 body 每 tick
>   0.95 / 13.98 ms vs 0.96 / 14.07 ms(差 1 % 內,兩邊雜湊相同);逐 body 取狀態 C 8.6–8.8 ns vs 原生 11.0–11.5 ns;一次取全部姿態 6.0–7.4 ns / body;
>   存檔 C 1.23 / 13.65 ms vs 原生 0.89 / 13.72 ms(多一次複製進宿主緩衝),讀檔 4.49 / 46.3 ms vs 4.21 / 44.9 ms。
>   首版批次取姿態經 `List` 中轉、存讀檔逐位元組解 `Optional`,前者比逐個呼叫慢、存檔比原生慢 3.6×,已改為直接走 slot 與單次解指標。
> **遺留待辦**:關節 / 其他形狀 / 過濾與材質 / 角色控制器 / AI 的 C 函式(以 minor 版追加);宿主注入派發器、配置器、非同步步進與 `UnitScale` 屬 17.75;
> 其他平台屬 17.76;Python 綁定屬 17.21。
> **內容**:定義穩定介面(世界建構、系統註冊、查詢、事件訂閱)的 C-ABI / 值語意契約,核心零腳本依賴;
> 以 C-ABI 共享庫提供給宿主,邊界宣告 **v0.x 凍結**。前面各項(17.14 / 17.15 / 17.16)的資料導向 API 由此包出。
> **交付(實作時)**:腳本層 vs 原生系統同場景 **parity**(腳本不改變模擬結果)。
> **相依**:17.75 嵌入契約(宿主注入 job system / allocator、非同步步進、單位慣例)、17.76 平台可攜、
> 17.81 授權與發佈管道。
> **歷史**:原為 Phase 12「架構分離定律」下 gated on 核心 API 凍結 + 使用者確認;2026-10-09 平台方向拍板 C
> 後解除 gating。原文見 ROADMAP_HISTORY.md「Phase 12」。

#### 12.2 Mojo / Python 雙腳本

> **狀態**:✅ 完成(2026-10-12,隨 17.21 交付)。Python 端 = `python/ludens`;Mojo 端 = `embed.world.EmbedWorld`(12.1);兩者驅動同一場景世界雜湊相同(`test_python_binding`,
> 亦 == C 宿主 `test_capi`)。
> **決定(2026-10-12)**:Python 綁定走 ctypes 包 12.1 C-ABI,而非 PythonModuleBuilder 擴充模組 —— 只有一個凍結 ABI 面;wheel 與 CPython 版本無關(`py3-none`,
> 實測以 3.13 venv 安裝、repo 的 pixi 為 3.14);代價是每次呼叫的 ctypes 開銷(見 17.21 量測),批次介面抵銷。
> **內容**:Python(PythonModuleBuilder 擴充模組,快速迭代)+ Mojo(原生系統,零開銷);使用者可選其一或混用。
> **決定(2026-10-09)**:Python 綁定是腳本層,放核心 repo 的最上層獨立套件(修正原「不入核心 repo」);
> 其測試須**環境隔離** —— 建出的擴充模組以客戶端方式安裝進乾淨環境(不用 repo 的 `-I build` / repo 路徑)再測。
> hot reload 參考 experiment 分支 H1–H6、R1/R2。
> **歷史**:此為 2026-07 撤銷的「引擎-UI / 腳本」方向的重生形態 —— 分離、可選、核心先穩。原文見
> ROADMAP_HISTORY.md「Phase 12」。

#### 17.21 腳本層(Phase 12 落地)

> **狀態**:✅ 完成(Wave C;剩餘順序第 (6) 項)。2026-10-12 交付,設計筆記 `docs/design/17.21-python.md`。
> **進度(2026-10-12)**:
> - `python/ludens`(無 Mojo,不入分層):`_capi.py`(ctypes 原型表,與 `embed/ludens.h` 函式集合由測試比對)、`world.py`(`World` / `Body` / `NavMesh`;狀態碼 → 例外階層
>   `ArgumentError` / `StaleBodyError` / `FormatError` / `CallbackError` / `StateError` / `HandleError`;Python 系統 `fn(world, dt, tick)` 與接觸訂閱者,
>   系統內丟出的 Python 例外停步並由 `step` 原樣重丟(cause 為 `CallbackError`);`poses_into` 寫入呼叫端緩衝的批次姿態)、
>   `cvar.py`(型別 / 範圍檢查的 CVar、主控台列 `name value`、設定檔整批驗證後才套用、`dump` ↔ `load` 往返;`bind_world` 把 `physics.iterations` / `substeps` /
>   `gravity_{x,y,z}` 接到世界,變更於下一個 tick 邊界由 PRE 系統套用)、`hot.py`(`HotSystem`:檔案內容雜湊變更即重新執行模組並換上新 `system`,
>   `state` dict 跨版本保留、可選 `migrate(state)`;語法錯誤 / 匯入例外時保留舊函式並記 `last_error` / `failures`)。
> - `python/build_wheel.py`(`pixi run wheel`):建 `libludens.so`、隨附非系統來源的相依(Mojo runtime 4 個 + 其建置用的 libstdc++ / libgcc_s,runtime 需 GLIBCXX_3.4.30),
>   strip 除錯段(libstdc++ 24 MB → 2.8 MB)、以 Python 改寫 ELF `RUNPATH` 為 `$ORIGIN`(不需 patchelf)、輸出 `py3-none-linux_x86_64` wheel(2.6 MB)。
> - 隔離測試 `test_python_binding`(14,integration):建 wheel → 系統 python3 建全新 venv → `pip install --no-index` → 在暫存目錄以 `env -i PATH=/usr/bin:/bin`
>   執行 `python/tests/client_check.py`(40 項:自身隔離 —— `/proc/self/maps` 無 repo 下的函式庫、`sys.modules` 無 repo 下的模組;綁定、錯誤、事件、存讀檔、
>   導航、CVar、hot reload)→ Mojo 端比對:Python 驅動的世界雜湊 == 原生 `EmbedWorld` 同場景(== C 宿主);CVar 於 tick 60 改 `physics.iterations 1` /
>   `physics.gravity_y -3` 的雜湊 == 同 tick 直接 `set_solver` / `set_gravity`,且 ≠ 不改;綁定預設值不改變模擬;hot reload 於 tick 60 換版 == 同 tick 切換函式。
> - 量測(`bench_python`):1000 body 步進(每 10 個 box 由 Python 系統推動)14.70 vs 原生 14.28 ms / tick(+3 %,雜湊相同);每次 Python 系統回呼 0.34–0.36 µs;
>   `Body.state()` 1.43–1.45 µs vs 原生 13–15 ns(ctypes 每次呼叫約 0.2 µs + 每個參數約 0.2 µs;首版 2.2 µs,改用 `struct.unpack_from` 後降低);
>   `World.poses_into` 7.8–13.4 ns / body(與原生同級);`World.bodies()`(每 body 建 Python 物件)0.56–0.60 µs / body。
> **遺留待辦**:更低的單次呼叫開銷(PythonModuleBuilder 或 CPython 擴充直連 `EmbedWorld`,以同一套 client 測試驗證)、NumPy 零複製視圖、
> 引擎端更多可調參數的 CVar(睡眠門檻、恢復係數門檻等需先在 C-ABI 加函式)、Mojo 系統的 hot reload(experiment 分支 H1–H6)、wheel 發佈(17.81)。
> **決定(2026-10-09)**:gating 解除 —— 見 Phase 12 決定註:平台方向 = C(被宿主引擎嵌入的模擬函式庫);12.1 core embedding 邊界宣告 v0.x 凍結,以 C-ABI 共享庫提供;先做 Python 綁定,hot reload 之後再接。Python 綁定放核心 repo 的最上層獨立套件(修正 Phase 12 原本的「不入核心 repo」);其測試須環境隔離 —— 建出的擴充模組以客戶端方式安裝進乾淨環境(不用 repo 的 `-I build` / repo 路徑)再測,確保客戶端實際可用。
> **前提與範圍**:
> - core embedding 邊界定義(12.1 C-ABI)
> - Mojo / Python 雙腳本(技術偵察已在 [[roadmap-2026-07]]:`PythonModuleBuilder` 擴充模組驗證過 rest y=0.2497、跨語言 bit-identical)
> - hot reload(experiment 分支 H1–H6、R1/R2)
> - CVar / 設定系統(hot config / CVar 已併入本項)
> - live 參數調校
> **對照組**:UE Blueprint + Verse、Unity C# domain reload、Godot GDScript hot-reload。
> **優勢區**:不適用(架構分離決策)。
> **交付順序**:12.1 C-ABI → Python 綁定(含隔離環境測試)→ hot reload。CVar / 設定系統與 live 參數調校在順序中的位置尚未決定。
>
> **歷史**:
> - 原現況:Phase 12 ⏸ gated on 核心 API 凍結;本項「保持 gated」,交付寫「gated —— 使用者確認架構後才動」。已由 2026-10-09 決定取代。

#### 17.75 嵌入契約 — Wave B(平台方向 C 前提,與 12.1 同期)
> **狀態**:🔶 部分完成(2026-10-12:宿主派發器注入 ✅;2026-10-13:job graph 與 work-stealing 派發、暫存層宿主區塊、非同步步進、`UnitScale`、執行緒 / 錯誤 / 單位契約成文 ✅;actor 排程器宿主派發 ✅;剩 box / capsule 的尺度殘差(現 ≤ 3.1e-5)來源未定位,見進度)。
> **進度(派發器,2026-10-12)**:`scheduler/dispatch.mojo`:`Task` trait(`run(i)`)+ `Dispatch` 值(`parallel` 預設 = `max.algorithm.parallelize` /
> `serial` / `reverse` / `from_host(fn, ctx)`)+ `dispatch_for`;宿主形式經 C ABI:`host(ctx, n, task, data)`,`task` 是每個 Task 型別一個的 thin C 函式
> (`_task_trampoline[T]`,先以閉包嘗試 —— 對閉包型別泛型的函式會變成 capturing、不能當 C 函式指標,故改為 struct Task)。`SolverConfig.dispatch` 選擇派發器;
> 物理的三處 fan-out 改為 Task:island(`solver6._IslandTask`)、同色接觸對(`contact6._ColorTask`)、批次可微世界(`diffsolver._WorldsTask`)。
> 測試 `test_dispatch`(8,integration):40 個 island、120 tick,island fan-out 在 parallel / serial / reverse / 宿主 C 回呼(反序)四種派發下快照位元組相同;
> 同色 fan-out 四種派發皆 == 一般串行 step。受影響的 22 個既有測試輸出不變。scheduler 內部的 jobgraph / policy / workstealing 仍直接呼叫 `parallelize`(待辦)。
> **進度(2026-10-13)**:契約全文 `docs/design/17.75-embedding-contract.md`(執行緒、錯誤、單位 / 座標、記憶體、決定論)。
> - **派發器擴到 scheduler**:`JobGraphScheduler.dispatch`(同層系統改為 `_LevelTask`,經 `dispatch_for`);`Dispatch.work_stealing()`
>   以 `scheduler.workstealing.ws_parallel_for` 為第五種派發器。`test_dispatch` 10/10(island 與同色 fan-out 在 parallel / serial / reverse /
>   宿主 C 回呼 / work stealing 下快照位元組相同)、`test_jobgraph` 34/34(同層系統經 serial / reverse / work stealing / 宿主回呼 == 循序)。
>   途中找到一個生命週期錯誤:`_LevelTask` 指向的 `order` 副本在建構後即被 Mojo 結束生命週期(讀到空 List),以 `_ = ord^` 延長。
>   未改:actor 排程器的 `DispatchPolicy`(`scheduler/policy.mojo`)是無實例的編譯期策略,無處攜帶宿主 context。
> - **暫存層宿主區塊**:`FrameArena.from_block(span)` 在宿主記憶體上 bump 配置、不釋放它;`test_diag_arena` 19/19(寫入落在宿主記憶體、
>   溢位照樣 raise + 計數、arena 消失後宿主區塊完好)。求解器暫存改走它屬 17.79。
> - **非同步步進**:`Runtime.begin_advance(frame_dt) -> StepHandle` / `execute(handle)`(可在宿主任一 worker 上)/ `finish(handle) -> alpha`;
>   進行中宿主讀 `Runtime.published`(上一個完成 tick 的姿態)。`test_async_step` 11/11:90 個不等長 frame(每 frame 欠 1 / 2 / 0 tick)
>   下 alpha 每 frame 相同、場景快照位元組相同、內插歷史相同;begin 兩次、stale handle、finish 先於 execute、finish 兩次、進行中 teleport 皆 raise。
> - **`UnitScale` + 相似性測試**:`UnitScale(per_meter).apply(cfg)` 縮放 `margin_base`、`lin_sleep_tol`、`restitution_threshold`、新增的
>   `max_push_speed`;`margin_base` 原本只存在於設定、未接線,這次一路接到 `fat_aabb` / `speculative_margin` / `try_pair` / `_collect_pairs`。
>   相似性測試(長度 × 2^k)找到的缺陷:soft 推出速度上限寫死 4 m/s(`contact6.solve_contact`)→ 改為 `SolverConfig.max_push_speed`,
>   s = 2^4 的偏差 0.235 → 5.7e-4。`test_unit_scale` 12/12:球在 2^-7…2^10 每個尺度逐位相同;盒塔與膠囊在 5e-3 內(2^7 最大 1.1e-3);
>   對照組(不套 `UnitScale`)偏差 0.249。**未解**:盒 / 膠囊對地的 manifold 對精確縮放的輸入不是逐位等變(膠囊 step 0 深度 0.2816667 vs 0.28166664;
>   盒塔 step 1 的法向衝量 0.0304 vs 0.0364),已排除 `manifold.mojo:347` 與 `clip.mojo:99` 的 1e-6 門檻,來源未定位。
> - **actor 排程器的宿主派發(2026-10-13)**:`EntityActorScheduler` / `SystemActorScheduler` 新增 `host: Optional[Dispatch]`(設定時取代靜態 `DispatchPolicy`),
>   以 `_WakeTask` / `_DeliverTask` / `_SystemTask` 經 `dispatch_for` 執行。`test_scheduler_parity` 147/147:兩種排程器 × 兩種 backend 在 serial / reverse / work stealing /
>   C-ABI 宿主回呼下皆 == 循序排程器。途中重現 `_LevelTask` 的生命週期陷阱:任務的 untracked 指標不算使用,`inboxes` 在建構任務後即被結束(讀到垃圾 hp、
>   system actor 崩潰),以派發後的 `_ = len(...)` 延長。
> - **尺度殘差(2026-10-13 重量)**:現況盒塔 / 膠囊 300 步 |pos/s − pos_1| 在 2^-7…2^10 為 1.2e-7 … 3.1e-5(先前記錄 1.1e-3)。暖啟動配對半徑原為絕對 (5 cm)²,
>   改為乘 `margin_base / SPEC_BASE`(`UnitScale` 會縮放;尺度 1 逐位不變);把 `spread4` 的 1e-5 與盒面 1e-6 門檻改為相對值試驗後殘差不降 → 非來源,已還原。
>   2 的冪縮放下浮點運算本應逐位等變,殘差來源仍未定位(剩餘的絕對 epsilon 尚未逐一排除)。
> - **慣例釘死**:`test_conventions` 8/8:右手系(X × Y = +Z)、+90° 繞 +Y 把 +X 轉到 −Z、`Quat` 欄位 x, y, z, w(w 為純量)、`UnitScale(100)` 只縮放長度類旋鈕。
> **緣起**:2026-10-09 平台方向拍板為 C(被宿主引擎嵌入的模擬函式庫)。嵌入者(Godot / Unity / Unreal)
> 已有自己的 job system、配置器、frame graph 與單位約定;引擎若自起執行緒、自管記憶體、同步獨佔一個
> 呼叫,就只能「旁邊跑」而不能「被整合」。本條定義宿主與引擎之間的**執行契約**;C-ABI 的簽名與凍結屬 12.1。
> **現況**:
> - **派發點全是硬編**:`max.algorithm.parallelize` 在五處被直接呼叫 ——
>   `physics/solver6.mojo:1405-1407`(island 並行)、`physics/contact6.mojo:534-536`(同色 pair)、
>   `physics/diffsolver.mojo:464-466`(批次 world)、`scheduler/jobgraph.mojo:175-177`(job graph 同層系統)、
>   `scheduler/policy.mojo:41`(`Parallel`);`scheduler/workstealing.mojo:93` 的 `ws_parallel_for` 也以它起 worker。
>   宿主唯一能調的是寬度:`SolverConfig.workers`(`physics/solver_config.mojo:61`,0 = 用全部核心)。
>   `DispatchPolicy`(`scheduler/policy.mojo:20-24`)是「never instantiated」的靜態策略(`policy.mojo:3-5`),
>   無處攜帶宿主的函式指標 / context,也只有 actor 排程器用它,求解器不走它。
> - **結果與派發無關,已被證明**:island 與同色 pair 的分割使「任何 `workers` 皆與串行逐位相同」
>   (`physics/solver6.mojo:1191-1194`;`tests/test_islands_par.mojo` 把關,`solver6.mojo:1403`);
>   `ws_parallel_for` 明載 body 須與呼叫順序無關(`scheduler/workstealing.mojo:28-31`)。
> - **配置器無注入點**:grep `Allocator|allocator` 於 `collision physics scheduler gameplay fluid ecs geometry
>   numerics spatial procedural diag` 只命中 `diag/arena.mojo` 的說明文字,零個可注入的配置器介面。
>   唯一的 arena `FrameArena`(`diag/arena.mojo:60-110`)在建構時自配 `alloc(Layout[UInt8](count=capacity))`
>   (`:73`),不能接宿主給的區塊;且 grep `FrameArena|diag.arena` 於上列各套件 + `oop` 零命中(僅 `diag/arena.mojo`
>   自身與 `diag/counters.mojo:21,38` 的說明文字;使用者只有 `benchmarks/bench_diag.mojo`、`tests/test_diag_arena.mojo`)—— 17.34 標 ✅ 但引擎內沒有任何
>   使用者(`docs/design/diag.md:39` 原擬給 DrawQueue / batched query 使用)。每 tick 暫存仍是 `List`:
>   `gameplay/runtime.mojo:130,193,231-234`、`physics/solver6.mojo:1233`(`_collect_pairs` 回傳新 List)。
> - **步進是同步獨佔**:`Runtime.advance`(`gameplay/runtime.mojo:169-211`)在一次呼叫內做完最多
>   `max_steps`(預設 8,`:88`)個 tick,每 tick 依序 timers → `scene.step`(`solver6.mojo:1173`,不 raise)→ 事件 →
>   transform 同步 → 歷史擷取(`runtime.mojo:192-201`);`FixedLoop.advance`(`scheduler/gameloop.mojo:31-61`)同形。
>   無 begin / finish 分離,宿主無法把物理塞進自己的 frame graph 與其他工作重疊。grep `async|Future|Coroutine|Task`
>   於 `collision physics scheduler gameplay ecs diag` 僅命中 `physics/gpu_cloth.mojo:433` 的註解,零實質命中。
> - **GPU 已是「單一擁有者傳入」**:`physics/gpu_contact.mojo:22,318`、`physics/gpu_cloth.mojo:342-348`、
>   `physics/vbd_cloth.mojo:361`(`*_run_ctx`)皆吃呼叫端的 `DeviceContext` —— 但那是 Mojo 的 context,不是
>   宿主圖形裝置。
> - **單位 / 座標只有零散事實,沒有契約**:`WorldType = float32`(`geometry/vec.mojo:14`)、`Vec3` 為 4-lane 填充
>   (`vec.mojo:31`)、`Quat` 欄位序 x,y,z,w(`geometry/quat.mojo:17-20`);重力由呼叫端傳入(`runtime.mojo:88`),
>   但 gameplay 寫死 Y 向上:`gameplay/character.mojo:40`、`gameplay/vehicle.mojo:53`,車體標架「前 +X、上 +Y、右 +Z」
>   (`vehicle.mojo:21`)、預設重力 `Vec3(0, -9.8, 0, 0)`(`vehicle.mojo:206`)。求解器容差是絕對數值:睡眠
>   `lin_sleep_tol` / `ang_sleep_tol`、`restitution_threshold`(單位 m/s)(`solver_config.mojo:43-49`)、`margin_base`
>   (`:40`)。grep `right-handed|left-handed|y-up|z-up|up axis` 於 `docs/ARCHITECTURE.md`、`README.md`、
>   `docs/CATEGORY.md` 零命中(加 `-i` 重跑亦零命中;`ARCHITECTURE.md:123` 的 "parameters" 只會被含 `meters` 的樣式命中,不屬上列樣式)。
> **缺口**:
> - **宿主 job system 注入**:一個**可實例化、可攜帶 context** 的 `Dispatcher`(`parallel_for(body, n)`),取代上列五處硬編,
>   預設實作 = 現行 `parallelize`(例:Godot 的 `WorkerThreadPool` 或 Unity Job 接手 island 並行,引擎不再自起第二個執行緒池)。
>   維持「body 與呼叫順序無關」契約,並新增「宿主派發器可重入 / 可同執行緒內聯執行」的規則。
> - **宿主配置器(分兩層)**:(a)暫存層 —— `FrameArena` 可由宿主供區塊建構(`from_block(ptr, bytes)`),求解器的 pair /
>   manifold / debug-draw / 查詢暫存改走它(接線屬 17.79);(b)持久層(`BodySet`、`ColliderSet`、ECS 儲存)**不能**經 `List` 走宿主配置器
>   —— **已探針(2026-10-10,Mojo 1.1.0)**:`List[Int, Int, ...]` 的編譯錯誤回報 `struct List[T: AnyType, /]`
>   (Mojo 1.1.0 stdlib `collections/list.mojo` 的宣告),`List` 只有元素型別參數、無配置器參數。故持久層要走宿主配置器只能改用自有容器
>   (宿主區塊上的 `Span` / 自訂 SoA 容器);未換容器前契約降為「持久記憶體用量可查、可上限」(→ 17.79)。
> - **非同步步進**:`begin_advance(frame_dt) -> StepHandle` / `finish(handle)`,把 `collect_pairs → solve → sleep → nan_scan`
>   (`solver6.mojo:1232-1275`)暴露為可掛進宿主 job graph 的節點;完成前禁止存取 scene(`debug_assert`),完成後才可讀;
>   中間給宿主一份「上一個完成 tick 的姿態」只讀緩衝(`gameplay/interpolation.mojo:96` 的 `PoseHistory.curr` 已是同形資料)。
>   例:宿主在 tick N 的物理跑在 worker 上時,主執行緒仍用 tick N-1 的姿態做動畫與渲染(PhysX `simulate` / `fetchResults` 語意)。
> - **單位與座標契約成文 + `UnitScale`**:明載 SI(m / kg / s / rad)、`Quat` 欄位序、上軸與手性(以測試釘死,例:+angle 繞 +Y 的旋轉方向);
>   `UnitScale`(每公尺幾個宿主單位)讓睡眠 / slop / `restitution_threshold` / `margin_base` 隨尺度縮放;宿主座標系
>   (Unity 左手 Y 上、Unreal 左手 Z 上且公分、Godot 右手 Y 上、Blender 右手 Z 上)的轉換**只在邊界做一次**,核心內部不變。
> - **錯誤與執行緒契約**:哪些呼叫可從哪個執行緒進入、哪些回傳錯誤碼(`step` 目前以 `debug_assert` 守門而不 raise,
>   `solver6.mojo:1199-1211`),供 12.1 直接引用。
> **對照組**:Box2D v3 `b2WorldDef` 的 `workerCount` / `enqueueTask` / `finishTask` / `userTaskContext` 與
> `b2SetLengthUnitsPerMeter`;Jolt `JobSystem` 抽象類 + `TempAllocator` + 可註冊的全域配置函式;PhysX `PxCpuDispatcher` /
> `PxAllocatorCallback` / `PxTolerancesScale` 與 `simulate` / `fetchResults`;Bepu `IThreadDispatcher` + `BufferPool`;
> MuJoCo `mju_user_malloc` 與 `mjData` arena 預算。
> **優勢區**:中 —— 對照組多把「派發器怎麼排」當成決定論的一部分;本庫的分割(island、同色 pair)已使結果與派發順序無關,
> 因此**任何宿主派發器都不破壞逐位一致**,宿主不必實作確定性排程器。這是可量測的主張,見 parity。
> **規模軸**:派發器 × island 數(1e1–1e4)× 任務粒度的每步派發開銷;worker 數 1…核心數的 scaling;非同步步進下
> 「物理與宿主其他工作的重疊率」(frame 時間);`UnitScale` 2^-10…2^10 的穩定性。
> **seam?**:是,三條 —— (a)派發器 `parallelize`(預設)/ `Serial` / `WorkStealing` / `Host`:同場景(固定種子 1e3 body)
> `write_state`(`solver6.mojo:1410`)位元組全等 + 每步開銷 bench 列;(b)步進 blocking `advance` vs `begin/finish`:世界與
> `PoseHistory` 逐位相同;(c)暫存配置 `List` vs `FrameArena`(宿主區塊):結果逐位相同 + 每 tick 配置次數 bench。
> 單位契約不是 seam,是**相似性測試**:以 2 的冪次縮放長度(f32 下乘 2^k 精確),輸出應隨之縮放,偏差只能來自寫死的絕對容差 ——
> 偏差清單即缺陷清單。
> **交付**:普通(注入 `Serial` 跑 `test_islands_par` 場景逐位相同;以 Mojo 閉包模擬宿主回呼;`begin/finish` 走一個 tick;
> `UnitScale = 1` 零變化)/ 整合(`Runtime.advance` 搭宿主派發器 + 非同步步進走完 `test_system_stack` 場景,結果與現狀逐位相同;
> 與 GPU context 擁有者並存;`from_block` arena 供 `_collect_pairs` 暫存)/ 極端(`n = 0` / `n = 1`、宿主只有 1 worker、
> body 呼叫順序被反轉或亂序仍逐位相同、`begin` 後未 `finish` 就丟棄、`finish` 兩次、`begin` 期間存取 scene 被 `debug_assert` 抓到、
> arena 區塊過小 → 溢位計入 `ARENA_OVERFLOW` 並回退 `List`、重力非 Y 向、`UnitScale` 極值)。
> **相依**:17.34(`FrameArena`)、10.2 job graph、17.7(`PoseHistory`)、17.18(批次 world 的派發點);12.1 以本條為語意來源;
> 17.79 接線暫存;17.76 讓單執行緒 / wasm 成為一個派發器變體。
> **邊界**:宿主 job system / 執行緒池本體屬宿主;C-ABI 簽名、符號匯出、凍結政策屬 12.1;綁定屬 17.21 / 17.78;跨平台決定論屬 17.76
> 與 17.16 決定(同工具鏈同架構,ROADMAP §17.16);GPU 與宿主圖形 API 的緩衝共享不在此(只保 `DeviceContext` 單一擁有者);
> tick 週期與逐 island 品質屬 17.85(`TieredScheduler`),本條只提供它可掛的派發器。

#### 17.76 平台可攜 — Wave B(平台方向 C 前提)
> **狀態**:🔶 部分完成(2026-10-13:目標矩陣、per-platform golden 機制、CI 可攜工作、wasm leaf kernel 探針 ✅;ARM / macOS golden 待 CI 首跑記錄,浮點位元因子探針 ✅;跨目標容差表、降級矩陣未做)。
> **進度註(2026-10-13,CI 可攜工作首輪失敗清單)**:macos-14 依序修掉 `test_capi`(Mach-O 無動態符號表 → `nm -g -U`)、`test_bench_ab`
> (同參數的純函數兩次呼叫被合併 → 每個閉包自帶呼叫計數)、`test_python_binding`(`build_wheel.py` 靠 `ldd` 與 ELF RUNPATH,非 Linux 改為明確拒絕,
> 測試檢查該訊息;wheel tag 改隨建置機器 `linux_<machine>`,aarch64 不再標成 x86_64)。ubuntu-24.04-arm:`test_fracture` 碎片堆 48 塊中 6 塊入睡、
> 末速 2.39 m/s(x86 48/48、0.09);x86 上以投放位置抖動 0 – 3e-4 m × 目標 CPU x86-64 / x86-64-v3 / znver3 / sapphirerapids 共 12 組全部 48/48 入睡,
> 未能重現 —— 差異來自 ARM codegen 而非初值敏感,待 ARM 機器上逐步比對。
> **緣起**:被嵌入的函式庫要在宿主所在的平台上跑;目前引擎只在單一 Linux x86-64 + NVIDIA 環境被驗證過,
> 「可攜」是未知而非已知。LICENSE 與發行管線(17.81)和本條共同構成方向 C 的前提。
> **現況**:
> - **建置與驗證只有一個目標**:`pixi.toml:5` `platforms = ["linux-64"]`;所有腳本為 bash(`scripts/build_engine.sh:1` 等);
>   golden 只有一份 `tests/golden/test_stdout.txt`,由 `scripts/agent_gate.sh:13,30` 比對。
> - **引擎碼沒有平台分支**:grep `CompilationTarget|is_apple|is_linux|os_is|is_x86|is_arm` 於 `collision physics scheduler gameplay
>   fluid ecs geometry numerics spatial procedural diag harness` 零命中 —— 可攜性沒有被刻意處理過,也沒有被刻意破壞過。
> - **唯一的硬體分支是 GPU**:`has_accelerator()` 於 `collision/bp_gpu.mojo:27`、`collision/gpu_raycast.mojo:22`、
>   `physics/gpu_cloth.mojo:21`、`physics/vbd_cloth.mojo:25`、`spatial/gpu_lbvh.mojo:30`;無加速器時 GPU 測試自動跳過
>   (`tests/test_gpu_raycast.mojo:35`)。GPU 路徑實測只在單張 NVIDIA 卡上做過(記憶 `mojo-nightly-runtime-hazards`:RTX 3060 Laptop),
>   AMD / Apple 的 `max.gpu` 路徑未跑。
> - **決定論承諾範圍已決**:只保證同工具鏈、同架構,不做跨平台定點 / 軟浮點(ROADMAP §17.16)。位元一致性依賴 codegen:
>   17.18 量到「接觸後 SIMD 與純量路徑的乘加收縮不同,非逐位」(ROADMAP §17.18),可見同一台機器上不同路徑就會差。
> - **SIMD 寬度隨目標**:`ecs/system.mojo:22,42` 以 `simd_width_of` 決定向量寬度。
> - **建置產物只有 Mojo 內部格式**:`scripts/build_engine.sh:14-33` 只產 `build/*.mojoc`(跨檔 import 只經它,見 `CLAUDE.md`),
>   沒有共享 / 靜態庫,宿主無法連結(→ 12.1 / 17.78)。
> - **wasm**:Modular 附的 LLVM 沒有 wasm 後端;「`mojo build --emit=llvm` → 外接 llc」對純計算 leaf kernel 的 PoC 成功,含指標 / struct 的
>   模組須 wasm64、未驗(記憶 `wasm-retarget-path`,2026-07-24 實測於 Mojo 1.0.0b3;1.1.0 未重驗)。引擎內沒有「純計算核心 vs 外殼」的切分檢查。
> **缺口**:
> - **目標矩陣 + 實測**:linux-aarch64、osx-arm64 各自 `pixi run build` + `pixi run test`。套件可得性**已核實(2026-10-10
>   `pixi search -c https://conda.modular.com/max -c conda-forge`)**:`mojo-compiler ==1.1.0` 與 `modular ==26.6.0` 在
>   linux-aarch64、osx-arm64 皆有;win-64 與 osx-64 **無** `mojo-compiler ==1.1.0`(Windows 只能經 WSL 的 linux-64)。
>   「有套件」不等於「全套測試綠」,第一步是以 aarch64 Linux 跑全套,把失敗清單入帳。
> - **每目標一份 golden + 跨目標容差表**:以現有 golden 機制(`tests/golden/test_stdout.txt` 逐段比對)擴成 per-target;另列「同場景在
>   目標 A / B 跑 300 步的姿態差」實測值,取代口頭承諾(例:塔堆疊 vs 球堆崩塌 —— 穩定與混沌場景的分歧增長率不同,兩者都要量)。
> - **浮點位元因子清單**:FMA 收縮、SIMD 寬度、libm `sin / cos / sqrt`、優化等級各自是否影響位元,以探針釘死哪些在 1.1.0 下可控(**待探針**)。
> - **降級矩陣**:無 GPU(已有 `has_accelerator`)、無執行緒(`workers = 1` / wasm 無 threads,與 17.75 的 `Serial` 派發器同)、
>   無 SIMD 寬度假設;每格有一個測試證明結果等價。
> - **wasm 核心切分的機器檢查**:列出哪些套件(`diag geometry numerics collision` 窄相…)可出「零 external declare」的 IR;Modular 若補上
>   wasm 後端即一步到位。
> **對照組**:Jolt 的 `CROSS_PLATFORM_DETERMINISTIC` 建置選項;Rapier 的 `enhanced-determinism` feature;Box2D v3 的跨平台決定論宣稱與其
>   x64 / arm64 CI;Bevy / Godot 的多平台 CI 矩陣。
> **優勢區**:低-中 —— 本庫已有逐段 golden 比對閘門,擴成 per-target 的邊際成本低;Mojo `comptime` 可在編譯期剔除不可攜路徑(GPU、平台特化),
> 對照組多靠前處理器巨集。
> **規模軸**:目標數 × 全套測試時間;跨目標姿態分歧 vs 模擬步數(穩定場景 / 混沌場景各一條曲線);wasm 核心 kernel 吞吐 vs native。
> **seam?**:否 —— 平台矩陣不是引擎內的可替換子系統;每新增一個目標,必須過**同一套** test + golden,偏差入表。執行緒 / GPU 的退化路徑
> 由 17.75 的派發器 seam 與既有 `has_accelerator` 分支承擔 parity。
> **交付**:普通(第二個目標 `pixi run build` + `pixi run test` 全綠,golden 另存)/ 整合(跨目標容差表 3 場景 × 300 步;17.81 的 CI 矩陣掛上;
> `workers = 1` 與預設的 `write_state` 位元組全等)/ 極端(單執行緒、無 GPU、wasm leaf 核心 IR 的 `declare` 計數為 0、SIMD 寬度 1 的純量回退與預設寬度在容差內
> (若編譯器不允許覆寫寬度,改用以寬度為 comptime 參數的測試核心驗證)、linux-aarch64 上的 `write_state` 位元組與 x86-64 比對,
> 差異逐項列冊說明)。
> **相依**:17.81(CI / 發行矩陣)、17.75(派發器變體)、12.1 / 17.78(共享庫產物)、17.16(決定論範圍)、17.8(`WorldType` 參數化後的 f64 parity)。
> **邊界**:不做跨平台定點 / 軟浮點(使用者 2026-10-09 決定);主機 / 行動平台的 SDK 與 NDA 部分屬宿主;Modular 不支援的平台只記錄不繞道
> (wasm 的 IR 外接路徑除外,因 PoC 已存在);渲染後端不在本倉。

> **進度(2026-10-13)**:
> - **目標矩陣**:`pixi.toml` platforms 加 `linux-aarch64`、`osx-arm64`(兩者都解得到 `mojo-compiler ==1.1.0` / `modular ==26.6.0`);
>   valgrind 無 osx-arm64 版 → 只在 Linux;osx-arm64 從 conda-forge 取 bash ≥ 5 與 coreutils(`run_tests.sh` 用 `declare -A`、`agent_gate.sh` 用 `timeout`)。
>   `pixi.lock` 的 linux-64 套件集合不變(364 = 364)。commit cf2884a。
> - **位元因子的第一個實測**:golden 的浮點值隨 **CPU 型號**變:同一份程式碼在兩台 x86-64 主機上 `test_mpm` 等段落不同,
>   `--target-cpu x86-64-v3` 與 `haswell` 仍不夠,釘 `--target-cpu skylake` 後兩台一致(`run_tests.sh` 只在 x86-64 釘;其他架構用主機目標)。
>   CI 的 x86 `gate` 工作在 GitHub runner 上與本機 golden 逐段相同(run 38315149592)。
> - **per-platform golden**:`agent_gate.sh` 在 linux-x86_64 以外讀 `tests/golden/test_stdout.<os>-<arch>.txt`;CI `portability` 工作
>   (ubuntu-24.04-arm、macos-14)在該檔不存在時以 `--update-golden` 跑全套並把 golden 印在 log 的標記之間,讀回後提交。
>   首跑:兩個平台的 build 與 arch-check 都過;測試在 `test_bench_ab` 的 A-vs-A 比值斷言([0.8, 1.25])失敗,
>   兩邊都改 31 輪、A-vs-A 放寬到 [0.5, 2]。
>   第二輪(2c7fb1a):macOS 在 [0.5, 2] 仍失敗(Apple silicon 的效能 / 效率核心讓同一工作的最小時間不穩),改為斷言「A 對 A 不被判定為不同」(31 輪交替順序兩邊都有);
>   ARM 的 unit / component 全過,`test_fracture` 的碎片堆睡眠比例 5 / 48(x86 47 / 48;磚塊 51 / 54 vs 54 / 54),島數 14 vs 18 ——
>   與「堆在箱上的碎片碰到軟體上的碎片、軟體永不睡而整島不睡」一致,是混沌堆疊的排列差,不是求解器錯誤;本機無 ARM 無法重現,列入跨目標容差表待辦。
> - **wasm leaf kernel 探針** `scripts/wasm_probe.py`(selftest 4/4、`pixi run wasm-probe`、CI):對 `tools/wasm/kernel_*.mojo` 每個 `@export` 函式
>   產 LLVM IR,從該函式沿呼叫圖列出所有只有 declare 的外部符號。`geometry.vec` 的 dot / cross 與 `collision.manifold` 的球-盒查詢:0 個(可出 wasm);
>   配置 `List` 的對照組需要 `KGEN_CompilerRT_AlignedFree`(要 Mojo runtime)。在 1.1.0 上重驗了 2026-07-24 的 PoC 結論。
> - **浮點位元因子探針 ✅(2026-10-13)**:`scripts/fp_probe.py`(`pixi run fp-probe`)以 7 種變體編譯 `benchmarks/probes/fp_probe.mojo`(40 箱堆 / 滾動球 / 6 箱塔各 300 步)
>   比較狀態雜湊與最大漂移(參考 skylake 預設優化):`-O1` / `-O2` / haswell(AVX2 + FMA)/ skylake-avx512 / 本機 CPU 皆逐位相同;**改變位元的只有 FMA 有無與 -O0**:
>   x86-64 基線(無 FMA)漂移 6.65e-3 / 1.07e-6 / 3.05e-7、`-O0` 7.20e-3 / 9.55e-7 / 1.43e-6(堆 / 球 / 塔;混沌堆疊放大到 mm 級,單體與塔在 1e-6)。
>   → SIMD 寬度與一般優化等級不影響結果,FMA 縮併是跨目標差異的來源;ARM(皆有 FMA,但縮併由編譯器決定)的差異屬同類,容差表以此為基準。
> - **待辦**:ARM / macOS golden 記錄並轉為阻擋式檢查;跨目標容差表(3 場景 × 300 步);FMA / SIMD 寬度 / libm / 優化等級的位元探針;
>   降級矩陣(`workers = 1`、無 GPU、SIMD 寬度 1)各一個等價測試;aarch64 與 x86-64 的 `write_state` 位元組逐項比對。

#### 17.78 宿主整合 / 綁定 — Wave C
> **狀態**:🔶 部分完成(2026-10-13:批量姿態寫入、診斷計數器經 C 讀出、宿主定義元件、跨語言的逐物件 vs 批量量測 ✅;2026-10-17:宿主對映(layer、user 值)、
> 多實例與執行緒契約、綁定產生(Rust)✅;Godot / Unity 實機適配、C 邊界的單位轉換、C# 綁定、宿主元件進查詢語言 / 快照未做)。
> 批量讀(`ld_world_get_bodies`)與 POD 事件緩衝(`ld_world_get_events`)在 12.1 已存在。
> **進度註(2026-10-17)**:C-ABI 0.4(`embed/ludens.h`、`abi_v0.txt` 只追加):`ld_body_set_layer`(category / mask)、`ld_world_raycast_mask`、
> `ld_body_set_user` / `ld_body_get_user` / `ld_world_find_user`(宿主節點 id ↔ body;隨 world 存讀,只在有 user 值時於存檔尾附 `LDU0` 段,
> 沒有 user 值的 world 存檔與雜湊與 0.3 逐位相同)、`ld_world_bind_thread` + `LD_ERR_THREAD`(-8):綁定後其他執行緒的呼叫一律拒絕且不碰 world
> (每次呼叫一次 `pthread_self`)。標頭明載:不同 world 可同時在不同執行緒步進;GPU 每進程一個 context,C-ABI world 只走 CPU。
> Python 綁定:`Body.set_layer`、`Body.user`、`World.find_user`、`World.bind_thread`、`raycast(mask=)`、`ThreadError`。
> `scripts/gen_bindings.py`(`pixi run bindings`;`--check`、`--selftest` 進閘門自測):解析標頭的常數、typedef、struct、函式指標與 49 個函式,
> 產生 `bindings/rust/ludens_sys.rs`(Rust 關鍵字參數名加 `r#`)。
> 量測:`test_capi` 66/66:C 主機以兩條 pthread 同時各步進一個 world 120 tick,兩者雜湊都等於單獨步進的 world;綁定後另一執行緒得 -8、本執行緒正常、解除後另一執行緒正常;
> layer 2 遮罩只打到遠的盒子、遮罩 4 不中;user 值設定 / 讀回 / 反查,未知值得 -3;`gen_bindings --check` 為最新;以生成綁定寫的 Rust 主機(`tests/capi/host.rs`,rustc 1.97)
> 跑 C 主機的第一個情境,雜湊 `6099cef27541034c` 與 C 主機相同,系統呼叫皆 240 次。`test_python_binding` 14/14(client 加 6 項:遮罩、user 值、存讀、刪除、執行緒綁定、
> user 值不改變模擬)。
> **進度註(2026-10-13)**:C-ABI 0.2(`embed/ludens.h`、`embed/abi_v0.txt` 只追加):`ld_world_set_poses`(先驗證全部,失敗則一個都不動)、`ld_counter_count` / `ld_counter_name` /
> `ld_world_get_counters`;Python 綁定 `World.set_poses` / `set_poses_from` / `counters()`。`ContactScene6.teleport_many`:對 body 一次喚醒 pass、對暖啟動快取一次過濾,
> 結果與逐一 `teleport` 相同(原本每次 teleport 各掃一次快取與全部 body,1e4 個 body 的批量寫入 217 ms / 幀,改後 0.73 ms)。`ecs/host_components.mojo` `HostComponents`:
> 執行期以 (名稱, 位元組數) 註冊、每元件稠密 byte 列、世代檢查、`set_f64` / `get_f64`、`matching_all`、`to_bytes` / `from_bytes`。
> 量測:`tests/test_host_bulk.mojo` 7/7(20 個 body 的 `teleport_many` 與 20 次 `teleport` 狀態相同且之後 60 步逐位相同;同一腳本下宿主 `Health` 與編譯期 `Health` 的實體集合與值相同;
> 回收 id 的舊 handle 讀為不存在);`test_python_binding` 14/14(client 加 3 項)。`python/bench_bulk.py`(Python ctypes,µs / 幀):N = 100 / 1000 / 10000 時
> 讀 逐物件 81 / 840 / 9620、批量 2 / 8 / 78;寫 逐物件 258 / 4830 / 354126、批量 11 / 64 / 730。`bench_host_components`(ns / 實體,N = 1e5):寫 編譯期 29 / blob 275、讀 7 / 145、查詢 19 / 3。
> **緣起**:12.1 定義 C-ABI 邊界、17.21 先做 Python 綁定;本條是**在那之上**讓真實宿主(Godot / Unity / Unreal)用得順的部分 —— 批量資料交換、宿主對映、
> 宿主定義的元件、綁定產生。平台方向 C 下引擎沒有渲染也沒有編輯器,宿主整合的品質就是產品品質。
> **現況**:
> - **零對外綁定**:grep `@export|PythonModuleBuilder|\bextern\b|external_call|DLHandle` 於 `collision physics scheduler gameplay fluid ecs geometry numerics spatial
>   procedural diag harness` 零命中;唯一的 Python 互通是開發工具 `tools/archindex.mojo:30`。12.1 仍 ⏸(ROADMAP「Phase 12」);17.21 的 gating 已解、尚未開工
>   (ROADMAP §17.21)。Mojo 1.1.0 匯出 C 符號 / 建共享庫**已探針(2026-10-10)**:`@export` + `abi("C")` 效應
>   (缺 `abi(...)` 時編譯器警告「@export requires an explicit 'abi()' effect」)+ `mojo build --emit=shared-lib` 產出 `.so`,`nm -D` 見
>   `T ludens_add`,經 Python `ctypes` 呼叫回傳正確值;產物 `ldd` 為 statically linked。引擎套件接上此路徑(型別面、全域狀態、錯誤碼)仍屬 12.1。
> - **型別面是編譯期泛型**:`World[B: StorageBackend]`(`ecs/world.mojo:34`)、`ContactScene6[Body, BP]`(`physics/solver6.mojo:133`)、`Runtime[B, Body]`
>   (`gameplay/runtime.mojo:70`)、元件 `comptime ID`(`ecs/component.mojo:15-16`)。宿主無法在執行期定義元件;唯一的執行期型別面 `TypeRegistry`
>   (`ecs/schema.mojo:271-334`)能按名稱讀寫純量(`get_f64` / `set_f64`,`:305,319`),但 `register[T]` 需要編譯期的 `T`(`:281`)。
> - **穩定 handle 已有**:`Entity{id, gen}`(`ecs/entity.mojo`)、`BodyId{slot, gen}`(`physics/body_set.mojo`,`gameplay/runtime.mojo:58-67`)、碰撞 category / mask
>   (Box2D 同款,`collision/collider_set.mojo:98-104,270`)—— 宿主物件對映的素材齊備。
> - **資料交換是逐物件**:姿態取自 `scene.bset.bodies[i].position()` / `rotation()`(`runtime.mojo:236-237`),同步進 ECS `Transform` 時每 tick 複製四個 List
>   (`runtime.mojo:231-234`);事件是 `scene.events: List[ContactEvent]`(`solver6.mojo:178-179`、`collision/contact_events.mojo:19-31`)或 `Channel` pull(`scheduler/events.mojo`)。
>   沒有「一次把 N 個 body 的姿態寫進宿主提供的緩衝」的 API,也沒有 flat POD 事件緩衝。`Vec3` 是 4-lane 填充(`geometry/vec.mojo:31`),直接暴露會與宿主的 `float3` 陣列步幅不合。
> - **診斷可讀但不可跨邊界**:`Counters.dump()`(`diag/counters.mojo:135`)、`LogRing`、`TraceBuffer` 皆為 Mojo 型別。
> **缺口**:
> - **per-host 適配層**(建在 12.1 之上):handle 對映(宿主節點 / entity ↔ `BodyId`)、層級對映(宿主 layer ↔ category / mask)、座標 / 單位轉換(使用 17.75 契約)、
>   生命週期(宿主刪節點 → `Runtime.despawn`,含「仍有關節引用」的 raise 對映成錯誤碼)。優先序:C header + Python(17.21)→ 一個真實宿主(Godot GDExtension 或 Unity 原生外掛)。
> - **批量 SoA 交換**:單次呼叫把 N 個 body 的姿態(位置 xyz 連續、四元數 xyzw 連續)寫進宿主緩衝;反向,宿主 kinematic 目標一次寫入。例:1e4 body 每 tick 同步,成本
>   不隨宿主語言呼叫次數成長(P/Invoke、GDScript、Python 的逐物件 getter 是熱點)。
> - **POD 事件緩衝**:`ContactEvent` 打包成 C struct 陣列,宿主每幀 pull 一次(雙緩衝,契約與 `Channel` 一致)。
> - **宿主定義元件**:runtime 註冊 (name, size, align, 欄位) → type-erased 欄位儲存(archetype / sparse-set 上以 byte blob 實作),可被查詢與序列化;與編譯期元件**並存**,不改
>   `StorageBackend` 的泛型契約(例:宿主腳本新增 `Health` 元件並在查詢中使用)。
> - **綁定產生**:由 17.11 `TypeSchema` + 12.1 簽名產生 C header / 其他語言宣告(C#、Rust、GDExtension 描述),schema 版本進 ABI 版本,避免手寫漂移。
> - **多實例與執行緒**:同進程兩個 world(例:編輯器預覽 + 遊戲)、每個呼叫的執行緒歸屬;GPU 受「每進程一個 `DeviceContext`」限制,需在契約中明載。
> - **診斷出口**:`Counters`、log、trace(17.80)經 C 讀出,供宿主 console / profiler 面板。
> **對照組**:flecs(C 核心 + C++ / C# / Rust / Zig 多綁定)、Box2D v3(為 FFI 設計的純 C API)、godot-jolt(GDExtension 整合 Jolt)、JoltPhysicsSharp(C# 綁定)、
> MuJoCo(`mujoco.h` + Python / Unity 外掛)、PhysX 的 Unity / Unreal 原生整合。
> **優勢區**:中 —— 方向 C 的賣點是決定論 + 可微 + 批次:宿主一次整合就得到 rollback(17.16)、批次模擬(17.18)、反向梯度(17.20)。批量 SoA 交換使跨語言呼叫次數與 N 無關,
> 這是可量測的主張(對照:逐物件 getter)。
> **規模軸**:body 數 N(1e3–1e5)× 交換頻率(每 tick / 每 render frame)× 宿主語言(C / C# / GDScript / Python)的每 tick 呼叫次數與耗時;事件緩衝大小。
> **seam?**:是 —— (a)姿態 / 事件交換路徑:逐物件 getter vs 批量 SoA 緩衝,取回的姿態逐位相同 + bench(N 掃描 × 宿主語言);(b)元件儲存:編譯期 `ComponentType` vs 宿主定義 blob,
> 同一讀寫 / 查詢腳本的結果相同 + bench。
> **交付**:普通(純 C 或 Python 客戶端:建 world → 加 body → 步進 → 批量讀姿態,結果與 Mojo 原生同場景逐位相同;沿用 12.2 的環境隔離測試:以客戶端方式安裝、不靠 `-I build`)/
> 整合(repo 內一支 C 撰寫、CI 可編譯執行的最小測試宿主載入 header 跑 stack 場景並完成 layer / ID 對映;宿主定義元件進查詢;
> Godot / Unity 適配層的實機驗證列入發行檢查單,不入 CI)/ 極端(NULL 或過短緩衝、對齊錯誤、stale `BodyId`(generation 不符)、同進程兩個 world、
> 跨執行緒誤用被 `debug_assert` 抓到、ABI 版本不符拒載、`N = 0`、`N = 1e5` 批量、宿主在事件讀取中途刪除 body)。
> **相依**:12.1(邊界凍結,前提)、17.21(Python 先行)、17.75(派發 / 單位契約)、17.76(各平台共享庫產物)、17.11(綁定產生)、17.80(診斷出口)、17.81(發行產物)、17.77(查詢語意)。
> **邊界**:12.1 擁有 C-ABI 簽名 / 凍結 / 版本政策;17.21 擁有 Python 綁定與 hot reload / CVar;本條只擁有 12.1 之上的 per-host 適配、批量交換、宿主定義元件、綁定產生。
> 場景格式(17.12,跟宿主 glTF / USD)、網路傳輸(17.16,byte payload 交宿主)、編輯器 UI(`docs/ROADMAP.md` 編輯器邊界 (III))、宿主渲染皆不在本條。

---

## 工程、測試、效能與工具鏈

範圍:gate、benchmark、CI、Mojo 版本搬遷、範例。

| 編號 | 條目 | 狀態 | Wave | 說明 |
|---|---|:-:|:-:|---|
| 3.4 | [最低限渲染 demo](ROADMAP_HISTORY.md#34-最低限渲染-demo) | ✅ |  | 曾以 wgpu-mojo 做 `examples/08_wgpu_motor_skinning.mojo` 糖果紙效應上屏(DLB 寬 0.300 vs LBS 塌至 0.063),後依使用者指示整個移除,CPU 版演示保留於 `examples/07_motor_skinning`,引擎現無渲染層。 |
| 4.0 | [Benchmark 覆蓋補齊(不變式基線)](ROADMAP_HISTORY.md#40-benchmark-覆蓋補齊不變式基線) | ✅ |  | 五個只有 parity 測試、沒有 benchmark 的 seam(SceneQuery、ManifoldNarrowPhase、CGA narrowphase、motor vs matrix 階層傳播、AD)都已補上 benchmark 並寫入 report(bench_queries 接線、bench_manifold、bench_collision CGA rows、bench_transform、bench_diffsim)。 |
| 4.5 | [工程債:bench_ga teardown flake 根因](ROADMAP_HISTORY.md#45-工程債bench_ga-teardown-flake-根因背景) | ✅ |  | bench_ga teardown 當機的根因已定位為多個裸 List[Vec3](width-3 SIMD)被不同閉包捕獲、在 teardown 時崩潰;已修復,run_bench 重試降為單一安全網並記錄原因。 |
| 16.1 | [API 搬遷(std.gpu.host / std.algorithm → max.*)](ROADMAP_HISTORY.md#161-api-搬遷---完成分支-mojo-stable) | ✅ |  | GPU host API 與 parallelize 已改由 `max.gpu.host`、`max.algorithm.parallelize` 匯入,`barrier` 移到 `max.gpu.sync`;device 端 intrinsics 仍在 `std.gpu`。 |
| 16.2 | [`InlineArray` 不再 `ImplicitlyCopyable`](ROADMAP_HISTORY.md#162-inlinearray-不再-implicitlycopyable---完成) | ✅ |  | 持有 `InlineArray` 的結構都補了顯式複製建構子,回傳與傳參處補了 `^` 所有權轉移。 |
| 16.3 | [Vec3 重構(width-3 SIMD 被禁)](ROADMAP_HISTORY.md#163-vec3-重構width-3-simd-被禁--完成2026-08-12分支-mojo-stable) | ✅ |  | `Vec3` 改為 lane 3 恆為 0 的 `SIMD[WorldType, 4]`,維度泛型容器用 `PadW`,同時完成 API 搬遷、`InlineArray` 複製、棄用清理,並拆掉 `SkinVert`、`_Pt`、`_LV`、`_Half` 包裝;`AABB.symmetric()` 會把 pad lane 設為 0。 |
| 17.0 | [架構前置(Wave A 之前必做;2026-09-27 架構審計)](ROADMAP_HISTORY.md#170-架構前置wave-a-之前必做2026-09-27-架構審計) | ✅ | A | 架構閘門(archindex check)、測試 tier、分層修正(diag 在第 0 層,bvh / gpu_lbvh 在 spatial)、collider_set / contact_gen 移到 collision、BodySet、錯誤政策、gameplay/runtime.mojo 都已落地;solver6 拆成 contact6 / joints6 / islands / ccd6 / soft_couple;舊 2D 物理路徑已刪除。 |
| 17.22 | [範例覆蓋補完](ROADMAP_HISTORY.md#1722-範例覆蓋補完--wave-a文件) | ✅ | A | examples/ 新增 17_spin_integrators、18_cloth_xpbd_vbd、19_reactive_commands、21_runtime_character,讓 README / CATEGORY §2 列出的 seam swap 都有可跑的範例,且每支都印出兩條路徑的對照數字。 |
| 17.81 | [CI / 授權 / 發行](#1781-ci--授權--發行--wave-a工程先於其他各項) | ✅ | A | CI 工作流、golden 跨機決定論探針、授權、發行管線、衛生、工具鏈升版金絲雀 |
| 17.82 | [品質工具](#1782-品質工具--wave-a工程) | ✅ | A | 格式 / 靜態檢查決策、孤島 / 接線報告、路線圖 / 文件引用 linter、執行緒 / 記憶體檢查、種子掃描 fuzz、穩定性 / 決定論重跑 |
| 17.83 | [效能治理](#1783-效能治理--wave-a工程) | 🔶 | A | 基準結果的機器可讀輸出、比較工具、確定性閘門、牆鐘閘門、漸近斜率閘門、影格預算表 |

### 已完成條目的遺留待辦

這些條目已完成並移到歷史檔,但各自記下了尚未做的部分:

- **16.3**([紀錄](ROADMAP_HISTORY.md#163-vec3-重構width-3-simd-被禁--完成2026-08-12分支-mojo-stable)):f64 化(17.8 大世界座標)會讓這次的 Vec3 / SIMD 寬度重構重做一遍,所以 17.8 排在 Wave C 末(出自 Phase 17 相依骨牌與 17.8 優勢區)

### 待辦與部分完成條目

#### 17.81 CI / 授權 / 發行 — Wave A(工程,先於其他各項)
> **狀態**:✅ 完成(2026-10-13:CI / 發行工作流、授權、衛生、跨機 golden 探針、首次 CI 實績、可重現性探針;選配的工具鏈升版金絲雀未做)。
> **現況**:
> - **沒有 CI**:`.github/` 目錄不存在(`ls .github` 失敗);`git ls-files` 中 `\.github|\.ya?ml$` 零命中。`origin` 是 GitHub(`git@github.com:Hundo1018/ludens-engine.git`),
>   且已有 PR 合併(`git log --merges` 見 `Merge pull request #10 / #11`),但沒有任何自動檢查掛在 PR 上。
> - **沒有授權**:`git ls-files | grep -iE "licen|copying"` 零命中;`README.md`、`pixi.toml` 對 `licen` 零命中;`pixi.toml:1-7` 的 `[workspace]` 無 license 欄位。
>   `git tag` 為 0 個(沒有任何版本標記);`pixi.toml:6` 版本固定 `0.1.0`。
>   作者分佈(`git log --format=%an`):Tien Chueh Wang 188 / Hundo1018 19 / Claude 5 —— 著作權人聲明與貢獻者政策需要使用者決定。
> - **閘門只在本機**:`scripts/agent_gate.sh:22`(`timeout 1800 pixi run test`)+ golden 比對(`tests/golden/test_stdout.txt`,688 行;`tools/golden.mojo:78-104` 丟掉計時行)+ 閘門工具自測(`agent_gate.sh:17-18`)。
>   `pixi run test` = `arch-check` → unit → component → integration → system(`pixi.toml` 的 `test` 任務);`stress` 與 examples / experiments / spikes / benchmark 不在其中。
> - **建置不增量**:`scripts/build_engine.sh:14-18` 的 `pc` 每次先 `rm -f` 再整個重新 precompile 十三個套件;每個測試是一次 `mojo run`(`scripts/run_tests.sh:68`),
>   171 個 `tests/test_*.mojo`(README.md:49 寫 160,已過時)。完整耗時沒有記錄。
> - **環境**:工具鏈精確釘死(`pixi.toml:50-51` `modular ==26.6.0` / `mojo ==1.1.0`),`pixi.lock` 存在,平台僅 `linux-64`(`pixi.toml:5`);
>   `valgrind` 在依賴內(`:52`);`glfw`(`:53`)在 `*.mojo` 中零命中(grep `glfw`),是殘留依賴。
> - **GPU 測試自動跳過**:14 個 tests / benchmarks 檔使用 `has_accelerator`(`grep -l has_accelerator tests/*.mojo benchmarks/*.mojo | wc -l` = 14),無加速器主機不會失敗。
> - **決定論 golden 的跨機風險未知**:golden 含浮點輸出(例:`tests/golden/test_stdout.txt:5` 的 `worst relative qdd error … 4.652469621901885e-06`);
>   ROADMAP「Phase 17 建議順序」 已寫「決定論只承諾同工具鏈同架構」,但 CI runner 的 CPU 型號與開發機不同,是否逐字相同沒有人量過。
> - **出處檢核起點**:grep `ported from|adapted from|copied from|translated from`(`*.mojo`,排除 build/.pixi/.claude)零命中;文內引用演算法(Box2D v3、Akinci 2012 等)皆是思想引用,尚無系統化的出處 / NOTICE 盤點。
> **缺口**:
> - **CI 工作流**(GitHub Actions + `prefix-dev/setup-pixi`,`pixi install --locked`):PR 閘門 = build → `arch-check` → unit/component/integration/system → golden 比對 + 閘門工具自測;
>   夜間 = stress tier + examples + experiments + spikes + benchmark 冒煙(不比數字,比數字屬 17.83)。快取 `.pixi` 與 `build/`(以原始碼雜湊為鍵)。逾時、log 上傳。
>   (例:一個故意壞掉的測試、一個違反分層的 import、一個改變 golden 的修改,各自讓 PR 變紅 —— 反向對照)。
> - **golden 跨機決定論探針**:先在 runner 上跑一次,若與開發機 golden 不同,結論是一個**問題**(CPU 目標 / FMA 縮併差異),要記入 17.76 與 17.16,
>   再決定「golden 分 CPU 級」或「釘編譯目標」,**不是**直接放寬比對。
> - **授權**:選定授權並加入 `LICENSE`、`pixi.toml` 的 license 欄位、README 一節、(必要時)`NOTICE` 與第三方出處盤點;
>   **授權種類與著作權人是使用者的決定**(候選:MIT / Apache-2.0 / 雙授權;嵌入式函式庫的專利授權條款值得比較)。
>   待查證:`build/*.mojoc` 內含 stdlib 片段時,Modular 工具鏈對再散布的條款 —— 在發行 binary 型產物之前必須讀完並記下結論。
> - **發行管線**(標籤 `vX.Y.Z` 觸發):build → 全閘門 → 打包 `build/*.mojoc` + 工具鏈釘版資訊 + LICENSE + 校驗和 → GitHub Release;
>   版本 / 相容性政策(平台方向 C 的 12.1 邊界凍結後,C header 與共享庫、Python wheel〔17.21〕加入同一條管線);
>   可重現性探針(同一 commit 建兩次,`.mojoc` 校驗和是否相同 —— 未知,先量)。
> - **衛生**:CHANGELOG(自 Conventional Commits 產生)、CONTRIBUTING / 提交規範、安全回報管道、移除殘留 `glfw`、README 的測試數量改由腳本產生而非手寫。
> - **工具鏈升版金絲雀**(選配):排程工作在下一個 Mojo 版本上跑同一組閘門,紅燈不擋 PR,只回報 —— 對應 CLAUDE.md「升版是刻意變更」。
> **對照組**:Jolt Physics(GitHub Actions 矩陣 + 跨平台 determinism 雜湊比對)、Box2D v3(CMake 矩陣 + 單元測試)、Bevy(fmt / clippy / 測試矩陣 + 範例編譯)、
> 以及使用 conda / pixi 的 C++ 函式庫的發行流程。
> **優勢區**:不適用(工程)。小差異化點:CI 能直接跑**位元決定論的 golden 比對**與**架構分層閘門**,比一般引擎 CI 的「測試綠燈」訊號更強。
> **規模軸**:PR 回饋時間 vs 測試檔數(171)、冷 / 熱快取、分層分流(快速層 unit+component vs 全量);runner 分鐘數。實際預算於第一次完整跑完後才定。
> **seam?**:否 —— 工程基礎設施,不是可替換子系統。但閘門本身須經 selftest 與反向對照才算可用(`~/.claude` 專案記憶〈代理工具須受測〉):每條 CI 規則附一個會讓它變紅的 fixture。
> **交付**:`.github/workflows/`(PR 閘門、夜間、發行三個流程)、`LICENSE` 與相關檔、發行腳本(放 `scripts/`,附 selftest)。
> 普通:乾淨 clone 在 runner 上 `pixi run build && pixi run test` 全綠並上傳 log;PR 上看得到狀態檢查。
> 整合:反向對照 —— 壞測試 / 分層違規 / 缺 tier 標頭 / golden 變動 / `pixi.lock` 與 `pixi.toml` 漂移(`--locked` 失敗)各自使 CI 變紅;打標籤產生含校驗和的 Release 草稿(**首次對外發佈前須使用者明確同意**)。
> 極端:冷快取、逾時(`timeout 1800` 等價)、無 GPU runner、runner CPU 與開發機不同、fork PR(無 secrets)、同一 commit 重跑可觸發(重跑一致性的檢查本身歸 17.82)、`stress` tier 僅夜間。
> **相依**:無(Wave A,先做);12.1 / 17.21 / 17.76 的產物之後接入發行流程;17.82 / 17.83 的檢查之後掛上同一條閘門。
> **邊界**:套件發佈到外部管道(conda channel、PyPI)屬後續且須使用者同意;跨平台(macOS / Windows / wasm)矩陣屬 17.76;GPU runner 屬另案(目前 GPU 測試靠自動跳過);
> 效能數字的比對與預算屬 17.83,本條只提供其執行的場所。

> **進度(2026-10-13)**:
> - **跨機 golden 探針(結論:有差,已處理)**:第一台既非開發機也非 GPU 工作站的主機(無 GPU、AVX-512 Xeon)上,golden 有 9 段的末位數字不同,
>   且與本次變更無關的測試也在其中(例:`test_tree` Y-tree energy drift 0.011868272829287659 vs 錄製值 0.011869547291799025);未改的 `origin/main`
>   在同主機上輸出同樣的新值。原因是編譯目標:`--target-cpu skylake` 或 `alderlake` 下每段都重現 golden,`x86-64-v3` / `haswell` 仍讓 `test_mpm`
>   末位不同(CPU 型號而非只是 ISA 等級)。`run_tests.sh` 改為一律 `--target-cpu ${LUDENS_TARGET_CPU:-skylake}`(任何 AVX2 主機可跑)。
>   決定論範圍的含義記入 17.76 / 17.16:承諾的是「同工具鏈 + 同編譯目標」,而非「同架構」。
> - **無 GPU 主機的編譯失敗**:五個 GPU 測試以 `comptime if not has_accelerator(): ... return` 後接裝置程式碼,return 之後仍被具現化,
>   `DeviceContext()` 報 "Unknown GPU architecture detected",檔案編不過、runner 停在它(main 亦然)。裝置半段移進 `else`;`gpu-compile` 15 / 15。
> - **locale**:`arch-check` 在未設 locale 的主機上以 "'ascii' codec can't decode byte 0xe2" 失敗;`tools/archindex.mojo` 讀 `mojo doc` 輸出改為明示 UTF-8,
>   在 `LANG` / `LC_ALL` 皆未設下通過。
> - **CI**:`.github/workflows/ci.yml`(PR / push main:`setup-pixi --locked` → 閘門自測 → `doclint` → `orphans` → `pixi run gate`,上傳 gate log;
>   夜間:stress / examples / experiments / spikes / benchmark 冒煙);`release.yml`(`vX.Y.Z` 標籤且與 `pixi.toml` 版本相符 → 閘門 → `capi` + `wheel` →
>   Release:`.mojoc`、`libludens.so`、`ludens.h`、授權、工具鏈釘版、`SHA256SUMS`、changelog)。
> - **授權**(使用者決定):MIT OR Apache-2.0,著作權人 Tien Chueh Wang(`LICENSE-MIT`、`LICENSE-APACHE`、`pixi.toml`、README)。
>   Modular 工具鏈再散布條款已讀(Modular Community License,last modified 2026-08-18):可在「有實質額外功能的應用」內以 object code 再散布 MAX 元件、
>   須保留其標示;Mojo 為 Apache-2.0 with LLVM exceptions。結論寫入 `NOTICE`,wheel 的 dist-info 帶 `LICENSE-MIT` / `LICENSE-APACHE` / `NOTICE`。
> - **衛生**:`CONTRIBUTING.md`、`SECURITY.md`(私下回報)、`CHANGELOG.md` 由 `scripts/changelog.py` 產生(`pixi run changelog`;淺 clone 拒絕執行)、
>   README 測試數不再手寫、移除殘留 `glfw`(`pixi lock` 只刪 glfw 與 xorg-libxinerama 兩項)。
> - **CI 實績(2026-10-13)**:PR #30 / #31 的 `gate` job(linux-x86_64 runner,skylake 釘選)與本機 golden 逐字相同而通過;portability 的
>   linux-aarch64 抓到一個本機抓不到的錯 —— `test_trace_runtime` 以固定 `--target-cpu skylake` 啟動子行程(`unknown target CPU`),已改為與
>   `run_tests.sh` 同規則(`39f5b64`)。
> - **可重現性探針 ✅**:`scripts/repro_probe.py`(`pixi run repro-probe`,`--selftest` 3/3):同 commit 連建兩次,16 個 `build/*.mojoc` 的 SHA-256 全數相同(2 m 43 s)。
> - **CI 套件逾時(2026-10-17)**:PR #31 / #32 的 `gate` job 在約 270 個測試檔時超過 `agent_gate.sh` 的 3600 s 套件預算(exit 124,停在 `test_softstep6`;
>   linux-aarch64 / macOS 的 portability 失敗則是另一個問題,`test_fracture`「shards」,x86 上 7 種編譯變體與 12 種擾動皆重現不出)。`run_tests.sh` 加 `LUDENS_TEST_JOBS=N`:
>   N 個檔案同時跑,各自的輸出先寫入緩衝,再依原順序印出,所以 stdout 與循序執行逐位元相同;依該順序第一個失敗的檔案以其結束碼停止。
>   本機 4 核:unit tier 374 s → 106 s,輸出 `cmp` 相同;整個閘門 278 檔 14 m 14 s,既有 golden 段全部相同;以假 `mojo` 讓一個檔回傳 3 時,平行與循序都印到該檔並回傳 3。
>   `ci.yml` 的 gate job 設 4、portability 設 3。
> - 選配未做:工具鏈升版金絲雀。

#### 17.82 品質工具 — Wave A(工程)
> **狀態**:✅ 完成(2026-10-13;格式化與執行緒 / 記憶體檢查的探針結論為「目前不可閘門」,理由見進度)。
> **現況**:
> - 已有的機器閘門:分層 / 循環 / 私有名稱穿透(`tools/archindex.mojo` 的 `check`,指令表 `:15-27`;`pixi run arch-check`)、測試 tier 標頭驗證(`scripts/run_tests.sh:57-64`,啟動即失敗)、
>   `-D ASSERT=all` 讓 `debug_assert` 生效(`scripts/run_tests.sh:19,68`)、golden 各段比對(`tools/golden.mojo`)、閘門工具自測(`scripts/agent_gate.sh:17-18`;`archindex selftest` `tools/archindex.mojo:27`)。
> - **沒有**下列任一(皆為 grep 零命中):格式化 / lint 設定(`git ls-files` 無 `format|lint|pre-commit|editorconfig` 路徑,`.gitattributes` 只有 linguist 標記);
>   `helgrind|drd|sanitiz|memcheck|tsan|asan`(`scripts tests harness tools pixi.toml docs`);`coverage` 於 `scripts tools harness`(僅 `scripts/benchmark_report.md.in` 三處為一般用語,`:710,2008,2027`);
>   fuzz 目標(`fuzz` 於 `tests scripts harness tools` 只出現在 `scripts/arch_layers.toml:44` 與 `tools/archindex.mojo:1206` 的詞彙說明)。
> - `valgrind` 已裝(`pixi.toml:52`)但只被用於 cachegrind 量測(`ECS_VS_OOP_INVESTIGATION.md:211-214`),沒有任何 memcheck / 執行緒檢查閘門 ——
>   而引擎的核心主張之一正是「平行與串行逐位相同、island 互不共享」(BENCHMARK_REPORT「Physics — island-parallel solver (serial vs worker threads)」,`test_islands_par`)。
> - 隨機輸入:21 個測試用 `SplitMix64` 產生輸入(`grep -l SplitMix64 tests/* | wc -l` = 21),但種子固定、無種子掃描 / 失敗輸入縮減。
> - 「接上專案」(測試標準 v3)只靠人工:`archindex uses TARGET`(`tools/archindex.mojo:19`)可逐模組查 importer,但**沒有**「引擎內無 importer 的模組」彙整或閘門。
>   粗略 grep(臨時腳本,**未經 selftest,僅供估量**):156 個引擎模組中 65 個在引擎套件內零 importer —— 其中大量是合法的「葉節點變體」(只被 tests / examples / benchmarks 使用的 seam 實作),需要分流,不是 65 個孤島。
> - **文件 / 路線圖與程式碼脫節只能靠人工發現**:13.8 曾標 ✅ 卻無對應程式與測試(ROADMAP §13.8 的 2026-10-09 校正);本次 41 條新增條目的本文遺失;
>   `README.md:49` 寫 160 個測試而實際為 171。粗略 grep:`docs/ROADMAP.md` 內反引號引用的 `tests|benchmarks|examples|experiments/*.mojo` 共 92 個唯一路徑,
>   其中 2 個不存在(`examples/08_wgpu_motor_skinning.mojo`、`examples/20_contact_solver_2d.mojo`);引用的引擎原始碼路徑另有約 11 個不存在(regex 涵蓋全部引擎套件 + `harness` 時;數字隨抽取規則而變,臨時腳本未經 selftest;部分是已移動 / 已刪除的歷史路徑如 `physics/solver.mojo`,部分是計畫中的檔案如 `gameplay/tiers.mojo`)。
> - 測試耗時沒有記錄:`golden` 刻意丟掉計時行(`tools/golden.mojo:78-104`),`agent_gate.sh` 只有整體 `timeout 1800`(`:22`)。
> **缺口**:
> - **格式 / 靜態檢查決策**:先探針 `mojo` 工具鏈在 1.1.0 提供什麼(格式化、doc 檢查),再決定是否加閘門;不假設有。例:若有 formatter,是 `--check` 模式進 CI,而不是自動改寫。
> - **孤島 / 接線報告**(`archindex` 新子命令或獨立工具,附 selftest):列出「引擎與 examples 皆無 importer 的模組」,以白名單標記合法葉節點;把測試標準 v3 的「接上專案」從人工變成機器閘門。
> - **路線圖 / 文件引用 linter**(附 selftest):抽取 ROADMAP / README / CLAUDE 中的檔案路徑與測試 / bench 名稱,檢查存在性與數量(例:README 測試數由腳本產生);歷史路徑以標記豁免。
> - **執行緒 / 記憶體檢查**:對一小組平行測試(`test_islands_par`、`test_colored`、`test_workstealing`)跑 valgrind `helgrind` / `drd`;對一小組 unit 測試跑 `memcheck`。先探針 Mojo 執行期在 valgrind 下的噪音量(誤報基線),才決定可閘門的子集。
> - **種子掃描 fuzz**:把 21 個 SplitMix64 測試中適合的幾個擴成可由環境變數指定種子範圍的版本(夜間掃 1e3 個種子),失敗時印出種子重現;對照現在的固定種子。
> - **穩定性 / 決定論重跑**:同一 commit 跑兩次,輸出逐段相同(補 golden 抓不到的「與上次一致但每次不同」型不穩定);測試耗時表(最慢 N 個、逐檔預算)。
> - **覆蓋率**:先探針是否存在可用的覆蓋率機制;若無,以 `archindex` 的 `def NAME` 對「公開符號是否被任何測試 import」做符號級近似,並如實標註它不是行覆蓋。
> **對照組**:Box2D(CI 內 sanitizer 與 warnings-as-errors)、Jolt(determinism 檢查 + 多編譯器矩陣)、Bevy(fmt / clippy / doc 測試 / 範例編譯)、Rust 生態的 `cargo-udeps` / `cargo-deny`(孤島與依賴檢查的概念對照)。
> **優勢區**:不適用(工程)。差異化:`archindex` 已把「分層」變成機器閘門,孤島報告 / 路線圖引用 linter 是同一思路的延伸 —— 把本專案兩條明令(接上專案、量測優先於形容詞)落成可執行規則。
> **規模軸**:每個工具的誤報 / 漏報率(以植入缺陷的 fixture 量:孤島、壞路徑、競態)、閘門額外耗時(佔整體 CI 的比例)、可閘門子集大小。
> **seam?**:否 —— 工具,不是引擎子系統。但每個新工具須**先 selftest、有預期輸出與反向對照**才能掛閘門(專案記憶〈代理工具須受測〉):例如 helgrind 工具要用一個**故意有競態**的 fixture 證明它抓得到。
> **交付**:`tools/` 下的工具(Mojo 優先,與 `golden` / `archindex` 同風格)+ `pixi` 任務 + 接進 17.81 的 CI;結果以 `pixi run gate` 同樣的固定格式摘要輸出。
> 普通:孤島報告在現有樹上產出清單,人工分流後白名單化;引用 linter 找出上述 2 個測試 / 範例路徑與全部失效的引擎路徑(以人工清單逐條核對,不以固定數字為準)並分類(歷史 / 計畫中 / 真錯)。
> 整合:掛進 CI,植入的孤島模組 / 壞路徑 / 競態 fixture 各自使對應檢查失敗(反向對照);夜間 fuzz 掃描接進 17.81 的夜間流程;
> 探針結論落地:每個「先探針」項(格式化、覆蓋率、valgrind 下的 Mojo 執行期)的探針程式與預期輸出入庫並附 selftest,
> 結論為「有」→ 對應閘門有一個植入違規使其失敗的測試;結論為「無」→ 記錄於本條進度註並以替代方案(如符號級覆蓋)的測試取代。
> 極端:空套件、迴圈 import、只被測試 import 的模組、含 `#` 的路徑、valgrind 下 Mojo 執行期噪音、單檔超長輸出、種子 0 與最大種子。
> **相依**:17.81(閘門執行場所)、17.80(執行期擷取可作為決定論重跑的比對來源,後做)、既有 `archindex` / `golden` 工具。
> **邊界**:效能回歸偵測屬 17.83;測試**內容**的覆蓋(哪些行為要測)不是本條 —— 屬測試標準 v3 與各條目自己的交付;引擎執行期診斷(`diag/`、17.80)不在本條。

> **進度(2026-10-13)**:工具皆為 `scripts/*.py`(pixi 環境的 Python),各附 `--selftest`(植入違規):
> - **路線圖 / 文件引用 linter** `pixi run doclint`(6/6):反引號內的 repo 路徑須存在,否則須在 `scripts/doclint_allow.txt` 附理由;README 若寫測試數須相符。
>   782 個引用;找到一個寫錯的路徑 geometry/clip.mojo(實為 `collision/clip.mojo`,已修正)與 33 個失效路徑,分類為「計畫中」(17.64–17.74 規劃的檔案)或「歷史」。
>   selftest 進 `pixi run gate -- --selftest`,檢查本身進 CI。
> - **孤島 / 接線報告** `pixi run orphans`(7/7):引擎與 examples 皆無 importer 的模組。128 個已接線、54 個只被 tests / benchmarks 使用、3 個無人 import,
>   全數在 `scripts/orphans_allow.txt` 分流(seam 變體 / GPU 後端 / 宿主 API / 入口 / 文件 / 缺口)。真缺口一個:`geometry.mat3`(遷移已回退,
>   連測試都沒有)。進 CI。
> - **種子掃描** `pixi run fuzz`(2/2):`harness.runner.fuzz_seed(default)` 在設了 `LUDENS_SEED` 時回傳它;`test_sap` / `test_lbvh` / `test_predicates` /
>   `test_laws` 改經它取種子(預設輸出不變)。種子 1..1000 四者全過(65 s)。
> - **穩定性 / 耗時** `pixi run stability`(3/3):每個測試建一次跑兩次,以 golden 正規化比較,並列出最慢的檔案。
> - **覆蓋率**:Mojo 1.1.0 無行覆蓋工具;以符號級近似 `pixi run symcov`(3/3):測試 import 到的公開引擎名稱 666 / 1141(58.4 %),逐套件列出;
>   `embed` 18.8 % 是低估(測試經編譯出的 C ABI 呼叫,不經 Mojo import)。只回報,不閘門。
> - **探針,結論為不閘門**:`mojo format` 在釘選環境中無法執行("unable to resolve Mojo formatter in PATH");helgrind 對 `test_islands_par`
>   (平行與串行逐位相同)報 160 個 race context,大多在 `libKGENCompilerRTShared.so`(其同步 helgrind 看不見);memcheck 看不見 Mojo 的堆積記憶體 ——
>   1e6 元素的 `List` 與刻意洩漏的 64 個 4 KiB 區塊都不改變 valgrind 的堆積統計(兩者皆 499 allocs),乾淨報告不構成證據,故不加 memcheck 閘門。

#### 17.83 效能治理 — Wave A(工程)
> **狀態**:🔶 部分完成(2026-10-13:機器可讀輸出、比較工具、確定性計數器閘門、斜率閘門、影格預算表、報告治理、bisect 判定器、交錯 A/B harness ✅;cachegrind 指令數探針 ✅;夜間牆鐘閘門需固定主機)。
> **現況**:
> - 基準規模:`benchmarks/bench_*.mojo` 共 79 支,皆已登記於 `scripts/benchmark_report.md.in`(79 條 `@bench`;逐一核對無缺漏),報告 `BENCHMARK_REPORT.md` 4026 行。
> - 量測方法:`harness/bench.mojo:25-37` 的 `measure` = 暖機後取 `reps` 次的**最小**牆鐘時間;檔頭建議用 `taskset` 釘核。報告自述「絕對數字與機器相關,讀相對欄位」(BENCHMARK_REPORT 開頭說明)。
> - **沒有回歸偵測**:grep `baseline|regress|threshold|budget`(`scripts/*.sh`、`harness/bench.mojo`)零命中;`scripts/run_benchmarks.sh` 只負責執行並組報告(重試機制 `:37`),不存結果、不比較。
>   (範本 `scripts/benchmark_report.md.in:350` 的「gated on physics rather than on regression」只是 LBM 段的正確性說明,不是全報告的效能政策;全範本沒有任何效能回歸政策。)
> - **雜訊量級已知**:同機跨行程約 ±15%(ROADMAP §17.10,17.10 進度註);當時的待辦是「同一行程交錯量測 on/off」。曲線的 argmax 在平台段會跳動(BENCHMARK_REPORT「Physics — island-parallel solver (serial vs worker threads)」)。
> - **機器相依**:報告數字來自特定主機(README.md:34「RTX 3060 laptop」;6 P-core + 8 E-core,BENCHMARK_REPORT「Physics — island-parallel solver (serial vs worker threads)」),沒有主機指紋隨結果保存。
> - **報告新鮮度無人把關**:ROADMAP「Phase 17 建議順序」 記錄 `BENCHMARK_REPORT.md` 尚未以 `pixi run benchmark` 重產。
> - **漸近行為退化只靠人工發現**:F22 的 O(n²) 簿記(N ×4 → 成本 ×12)由人讀 bench 輸出發現(ROADMAP §17.19)。
> - **確定性的代理量測已有零件,但沒接成閘門**:`diag/counters.mojo`(comptime id 計數器,目前 15 個 id 全是失敗 / 溢出事件類,`:27-79`;**沒有**工作量計數如接觸數 / 候選對數 / 迭代數)、`diag/trace.mojo` 的 span(ROADMAP §17.10)、
>   valgrind(`pixi.toml:52`;cachegrind 流程見 `ECS_VS_OOP_INVESTIGATION.md:211-214`)。
> - 執行期預算旋鈕是另一回事:`SimBudget`(`physics/lod.mojo:58`)是 17.31 的遊戲內 iters / substeps 控制器。
> **缺口**:
> - **基準結果的機器可讀輸出**與**基準線檔**(TSV / JSON,含主機指紋:CPU 型號、核心拓撲、工具鏈版本、`Real` 型別),進 repo 受審查;報告仍由範本產生。
> - **比較工具**(Mojo,仿 `golden.mojo`,附 selftest):依各列自己的雜訊(重複量測的離散度)定門檻,而不是固定 5%;主機指紋不符則**拒絕比較**而非誤報。
> - **確定性閘門**(可在託管 CI 跑):(a)新增工作量計數器(接觸數、候選對數、solver 迭代數,`diag/counters.mojo` 增 id;與 17.80 (d) counter 軌匯出的是同一組 id,先落地者新增、另一條只消費)後對其做**精確**斷言(機器無關,託管 CI 可跑);(b)以 cachegrind / callgrind 的指令數作牆鐘代理(先探針 Mojo 二進位在其下是否穩定);(c)每步配置次數:執行期 `AllocStats` 屬 17.79,本條只在 CI 對其值做斷言,或以 valgrind `dhat` 外部量(先探針)。
> - **牆鐘閘門**(自架或固定主機,夜間):通用的同一行程交錯 A/B 量測機制(17.10 待辦的 trace on/off 數字本身屬 17.80 (a),需其 runtime 開關;本條只提供可被它重用的交錯 harness)、釘核、重測仲裁;注入已知回歸(+5% / +10% / +25%)量偵測率與誤報率。
> - **漸近斜率閘門**:同一 bench 在 N 掃描上擬合 log-log 斜率,與宣稱的複雜度比對(例:F22 型 O(n²) 會在 N=1024→4096 的斜率上現形)。
> - **影格預算表**:規範場景(箱塔、碎石堆、ragdoll、載具、mesh 地形)在宣告 N 與宣告主機上的 ms/step 預算,隨程式碼審查;超出預算帶雜訊帶才失敗。
> - **報告治理**:範本 ↔ bench 檔 ↔ 報告三方一致性檢查(現在 79 = 79 是人工維持)、報告新鮮度(commit 距上次重產的門檻)。
> - **回歸定位**:閘門紅燈時以 `git bisect run` 自動定位的腳本(同一個比較工具當判定器)。
> **對照組**:Box2D / Jolt 的效能測試場景與跨版本比較表、Bevy 的 benchmark CI(`critcmp` 式比較)、Chromium / Firefox 的 perf alert 雜訊模型、LLVM 的 `llvm-lit` 指令數追蹤。
> **優勢區**:不適用(工程)。可說的優勢:本專案已有 comptime 計數器與 trace 可直接當確定性指標,多數引擎的回歸偵測只能靠牆鐘。
> **規模軸**:閘門自身 —— 偵測率與誤報率 vs 注入回歸大小(特別是**貼近雜訊底的小回歸**,這是方法的理論弱點,依優勢區規則必須測它);bench 數(79)× 每支耗時;基準線儲存大小;確定性閘門覆蓋的規範場景數。
> **seam?**:否 —— 工程治理。但比較工具須 selftest、含反向對照(植入回歸必被抓、純雜訊必不報);「通過」的判定須附該列的雜訊估計當證據。
> **交付**:`tools/` 的比較工具 + `scripts/` 的包裝 + 基準線檔 + 夜間 CI 任務(掛 17.81)。
> 普通:無改動重跑對基準線通過;報告一致性檢查在現有樹上全綠(79 = 79);影格預算表的每個規範場景在宣告主機上
> 於預算內通過(首次登記時以實測中位數 × 1.2 定預算)。
> 整合:在某支 bench 內植入 +20% 忙迴圈 → 被牆鐘閘門抓到;植入一個 O(n²) 迴圈 → 被斜率閘門抓到;植入多一次配置 → 被確定性閘門抓到;把某規範場景的 N 加倍 → 該場景的影格預算列失敗;接 17.81 的夜間流程。
> 極端:不同主機指紋(拒絕比較)、極度吵雜的主機(重測仲裁後仍不穩 → 標記為不可判定,而非通過)、bench 崩潰(`run_benchmarks.sh:37` 的重試路徑)、新增 bench 無基準線(強制登記)、GPU 缺席的列、單次量測 < 時鐘解析度。
> **相依**:17.81(場所)、17.10(已交付的 trace / 計數器)、17.80(執行期擷取,後做)、17.82(工具風格與 selftest 慣例)。
> **邊界**:**與 17.85 分級模擬的界線** —— 17.85 改變引擎每步**算什麼**(tick 週期、active set、分級品質、增量 broadphase;屬執行期 LOD),本條不改引擎行為,只治理**如何發現、阻擋效能回歸**(基準線、預算、CI 閘門);
> 17.85 完成後其 `bench_tiers` 各列成為本條的閘門輸入,但分級策略的設計與預算旋鈕不在本條。
> 同理:17.79 資源治理 / 17.80 觀測 / 17.31 `SimBudget` 是**宿主在執行期使用**的預算與擷取機制,本條的預算是**CI 對引擎量測值的斷言**,二者名稱相近、用途不同,本條只消費它們的輸出。

> **進度(2026-10-13)**:`scripts/perf.py`(`pixi run perf -- ...`,selftest 17/17,含植入回歸):
> - **機器可讀輸出 + 主機指紋**:`collect` 把每支 bench 跑 `--reps` 次,解析標準 `BenchTable` 表為 `bench :: 表 :: 變體 :: N :: op` → ns/op 樣本,
>   附指紋(CPU 型號、邏輯核數、編譯目標、mojo / modular 釘版、`Real` 型別);非標準表只計數、不猜。首份基準線
>   `benchmarks/perf_baselines/scale-xeon2.8-4c-skylake.json`(4 支擴展 bench、95 列、3 reps)。
> - **比較**:`compare` 指紋不同即拒絕(exit 2);每列雜訊 = 兩組樣本相對全距的較大者(下限 3 %),中位數超過基準線 × (1 + 3 × 雜訊) 才算回歸;
>   雜訊 > 50 % 標為不可判定(不當通過);新列無基準線必須登記。實測雜訊(上述 95 列):中位 5.5 %、p90 17.4 %、最大 71.8 %(2 列不可判定)——
>   即典型列可抓 ~16 % 以上的回歸,貼近雜訊底的小回歸抓不到(方法弱點,照實記)。`bisect-check` 是 `git bisect run` 的判定器(0 / 1 / 125)。
> - **確定性閘門(託管 CI 可跑)**:`diag.counters` 新增工作量計數 `NARROWPHASE_PAIRS` / `CONTACT_MANIFOLDS` / `CONTACT_POINTS`(`ContactScene6` 收集時累加);
>   `test_work_counters`(16/16)對解析值做精確斷言:N 顆不相觸的球,暴力列舉 N + N(N-1)/2 對、寬相 N 對,N×4 時暴力 ×15.29、寬相恰 ×4 ——
>   F22 型 O(n²) 由計數器而非計時抓到。
> - **斜率閘門**:`slopes` 以 log(ns/op) 對 log(N) 擬合(變體名中的 `N=…` 會被去除以成序列),與 `scripts/perf_slopes.toml` 宣告比較(容差 +0.25)。
>   實測:solver broadphase seam 的五個後端 1.06–1.10(宣告 1.0)、BVH pair collection 1.03、brute 1.23(N ≤ 512 時窄相仍主導;宣告 2.0)。
> - **影格預算表**:`budgets` 以註冊時中位數 × 1.2 為預算(`scripts/perf_budgets.json`,39 列:broadphase seam 各 N、island 平行塔場景),
>   超出預算 + 該列雜訊帶才失敗;預算屬單一主機,換主機拒絕。
> - **報告治理**:`governance` 檢查範本 `@bench` ↔ `benchmarks/bench_*.mojo` ↔ 報告章節(現況 88 = 88、報告已含全部章節;本條「現況」所記
>   vehicle / fracture 列缺漏在 2026-10-12 的重產中已補上);進 CI。
> - **交錯 A/B harness**:`harness.bench.measure_ab(a, b)` 在同一行程內交錯執行兩個變體(輪流先後),回傳各自最小值與每輪 b/a 比值的範圍,
>   `resolved()` 只在每輪都同向時為真;`test_bench_ab`(5/5):植入的 2 倍工作量量得比值在 [1.5, 2.5] 且每輪皆較慢,A 對 A 比值在 [0.8, 1.25]。
> - **cachegrind 指令數探針 ✅(2026-10-13)**:`scripts/icount.py`(`pixi run icount`)編譯 `benchmarks/probes/icount_probe.mojo`(40 箱、60 步)於
>   `valgrind --tool=cachegrind --cache-sim=no` 下跑 3 次:414,534,889 / 414,167,479 / 414,545,207 指令,相對散佈 9.1e-4(牆鐘同機跨行程約 ±15 %);
>   `--selftest` 以 `-D STEPS=66` 注入 +10 % 工作量:+9.37 %,為散佈的 103 倍 → 可作不受主機負載影響的回歸閘門。
> - **待辦**:夜間牆鐘閘門需要固定主機(託管 runner 的指紋每次不同,`compare` / `budgets` 會拒絕)—— 需基礎設施,本環境無法提供;每步配置次數屬 17.79 的 `AllocStats`。

---

## 編號索引

所有編號依數字排序。已完成者的完整紀錄在 [ROADMAP_HISTORY.md](ROADMAP_HISTORY.md)。

| 編號 | 條目 | 子系統 | 狀態 |
|---|---|---|:-:|
| 1.1 | [Contact manifold 生成(一切的前置)](ROADMAP_HISTORY.md#11-contact-manifold-生成一切的前置) | 碰撞形狀、寬窄相與世界查詢 | ✅ |
| 1.2 | [Screw dynamics 接進 contact solver](ROADMAP_HISTORY.md#12-screw-dynamics-接進-contact-solver) | 剛體動力學、接觸與關節 | ✅ |
| 1.3 | [Lie-group / variational integrator seam](ROADMAP_HISTORY.md#13-lie-group--variational-integrator-seam) | 剛體動力學、接觸與關節 | ✅ |
| 2.1 | [Sub-stepped soft-constraint solver(Box2D v3 "Soft Step" / TGS 系)](ROADMAP_HISTORY.md#21-sub-stepped-soft-constraint-solverbox2d-v3-soft-step--tgs-系) | 剛體動力學、接觸與關節 | ✅ |
| 2.2 | [Joints 最小集 + islands + sleeping + warm-starting](ROADMAP_HISTORY.md#22-joints-最小集--islands--sleeping--warm-starting) | 剛體動力學、接觸與關節 | ✅ |
| 2.3 | [持久化 broadphase + speculative CCD 第一步](ROADMAP_HISTORY.md#23-持久化-broadphase--speculative-ccd-第一步) | 碰撞形狀、寬窄相與世界查詢 | ✅ |
| 3.1 | [可微模擬(與 GA 核心契合度最高)](ROADMAP_HISTORY.md#31-可微模擬與-ga-核心契合度最高) | 可微模擬、批次世界與數值深化 | ✅ |
| 3.2 | [GPU 物理(Mojo kernels)](ROADMAP_HISTORY.md#32-gpu-物理mojo-kernels) | GPU 計算 | ✅ |
| 3.3 | [ECS table stakes](ROADMAP_HISTORY.md#33-ecs-table-stakes) | ECS、排程、執行期與診斷 | ✅ |
| 3.4 | [最低限渲染 demo](ROADMAP_HISTORY.md#34-最低限渲染-demo) | 工程、測試、效能與工具鏈 | ✅ |
| 4.0 | [Benchmark 覆蓋補齊(不變式基線)](ROADMAP_HISTORY.md#40-benchmark-覆蓋補齊不變式基線) | 工程、測試、效能與工具鏈 | ✅ |
| 4.1 | [物理保真度:swept/TOI CCD + LGVCI](ROADMAP_HISTORY.md#41-物理保真度swepttoi-ccd--lgvci) | 剛體動力學、接觸與關節 | ✅ |
| 4.2 | [可微模擬深化:reverse-mode AD tape](ROADMAP_HISTORY.md#42-可微模擬深化reverse-mode-ad-tape) | 可微模擬、批次世界與數值深化 | ✅ |
| 4.3 | [GPU 物理擴張:VBD 原型](ROADMAP_HISTORY.md#43-gpu-物理擴張vbd-原型) | GPU 計算 | ✅ |
| 4.4 | [ECS 完備:push-based observers + 延遲 component set](ROADMAP_HISTORY.md#44-ecs-完備push-based-observers--延遲-component-set) | ECS、排程、執行期與診斷 | ✅ |
| 4.5 | [工程債:bench_ga teardown flake 根因](ROADMAP_HISTORY.md#45-工程債bench_ga-teardown-flake-根因背景) | 工程、測試、效能與工具鏈 | ✅ |
| 6.1 | [CPU XPBD 體積軟體 + 剛體雙向耦合](ROADMAP_HISTORY.md#61-cpu-xpbd-體積軟體--剛體雙向耦合) | 軟體、布料、連續體與流體 | ✅ |
| 6.2 | [Restitution(彈性碰撞)](ROADMAP_HISTORY.md#62-restitution彈性碰撞--readmehonest-status第一洞) | 剛體動力學、接觸與關節 | ✅ |
| 6.3 | [Sphere / Capsule 形狀入 solver(脫離 box-only)](ROADMAP_HISTORY.md#63-sphere--capsule-形狀入-solver脫離-box-only) | 剛體動力學、接觸與關節 | ✅ |
| 6.4 | [縮座標關節鏈(Featherstone 方向,CRBA+RNEA 切片)](ROADMAP_HISTORY.md#64-縮座標關節鏈featherstone-方向crbarnea-切片) | 縮座標關節體與致動 | ✅ |
| 6.5 | [Islands 平行化(多執行緒 solver)](ROADMAP_HISTORY.md#65-islands-平行化多執行緒-solver) | 剛體動力學、接觸與關節 | ✅ |
| 6.6 | [軟-剛 CCD(粒子掃掠 vs 盒)](ROADMAP_HISTORY.md#66-軟-剛-ccd粒子掃掠-vs-盒) | 軟體、布料、連續體與流體 | ✅ |
| 6.7 | [Soft-vs-sphere/capsule 耦合(補 softbody pass 的形狀缺口)](ROADMAP_HISTORY.md#67-soft-vs-spherecapsule-耦合補-softbody-pass-的形狀缺口) | 軟體、布料、連續體與流體 | ✅ |
| 6.8 | [O(n) ABA(關節化剛體演算法)](ROADMAP_HISTORY.md#68-on-aba關節化剛體演算法) | 縮座標關節體與致動 | ✅ |
| 6.9 | [軟接觸摩擦(位置級 Coulomb 錐)](ROADMAP_HISTORY.md#69-軟接觸摩擦位置級-coulomb-錐) | 軟體、布料、連續體與流體 | ✅ |
| 6.10 | [場景序列化(精確存檔/載入)](ROADMAP_HISTORY.md#610-場景序列化精確存檔載入) | ECS、排程、執行期與診斷 | ✅ |
| 6.11 | [島內著色平行(單大島的約束圖著色)](ROADMAP_HISTORY.md#611-島內著色平行單大島的約束圖著色) | 剛體動力學、接觸與關節 | ✅ |
| 6.12 | [樹狀拓撲(分支關節樹/森林)](ROADMAP_HISTORY.md#612-樹狀拓撲分支關節樹森林) | 縮座標關節體與致動 | ✅ |
| 7.1 | [SAH-BVH(建樹啟發式:median vs SAH seam)](ROADMAP_HISTORY.md#71-sah-bvh建樹啟發式median-vs-sah-seam--2026-07-22) | 碰撞形狀、寬窄相與世界查詢 | ✅ |
| 7.2 | [solver6 接寬相(生產 solver 脫離 O(n²))](ROADMAP_HISTORY.md#72-solver6-接寬相生產-solver-脫離-on²--2026-07-22) | 碰撞形狀、寬窄相與世界查詢 | ✅ |
| 8.1 | [凸包碰撞入 narrowphase](ROADMAP_HISTORY.md#81-凸包碰撞入-narrowphase---完成2026-08-11) | 碰撞形狀、寬窄相與世界查詢 | ✅ |
| 8.2 | [三角網格 / heightfield 靜態關卡幾何](ROADMAP_HISTORY.md#82-三角網格--heightfield-靜態關卡幾何---完成2026-08-11) | 碰撞形狀、寬窄相與世界查詢 | ✅ |
| 9.1 | [關節庫深度(limits / motors / springs / prismatic / weld / cone-twist)](#91-關節庫深度limits--motors--springs--prismatic--weld--cone-twist) | 剛體動力學、接觸與關節 | 🔶 |
| 9.2 | [浮動基座關節(完整 ragdoll)](ROADMAP_HISTORY.md#92-浮動基座關節完整-ragdoll--已完成) | 縮座標關節體與致動 | ✅ |
| 9.3 | [碰撞過濾(layers / groups / masks)+ sensors / triggers](ROADMAP_HISTORY.md#93-碰撞過濾layers--groups--masks-sensors--triggers---完成2026-08-11) | 碰撞形狀、寬窄相與世界查詢 | ✅ |
| 9.4 | [接觸事件(began / stay / ended)](ROADMAP_HISTORY.md#94-接觸事件began--stay--ended--完成2026-08-11) | 剛體動力學、接觸與關節 | ✅ |
| 10.1 | [Exact predicates / interval 穩健層(SOTA_GAP M3)](ROADMAP_HISTORY.md#101-exact-predicates--interval-穩健層sota_gap-m3--完成2026-08-11) | 幾何代數與數值基礎 | ✅ |
| 10.2 | [自動依賴 job graph(DOTS 式讀寫衝突)](ROADMAP_HISTORY.md#102-自動依賴-job-graphdots-式讀寫衝突--完成2026-08-11) | ECS、排程、執行期與診斷 | ✅ |
| 10.3 | [Actor Model 硬化(既有雛形 → 生產)](ROADMAP_HISTORY.md#103-actor-model-硬化既有雛形--生產--完成2026-08-11) | ECS、排程、執行期與診斷 | ✅ |
| 11.1 | [Noise 家族](ROADMAP_HISTORY.md#111-noise-家族---2026-07-22) | 動畫與程序化 | ✅ |
| 11.2 | [狀態機(FSM / HSM)](ROADMAP_HISTORY.md#112-狀態機fsm--hsm--2026-07-22) | 動畫與程序化 | ✅ |
| 11.3 | [動畫 runtime(clip / blend / 狀態機驅動)](ROADMAP_HISTORY.md#113-動畫-runtimeclip--blend--狀態機驅動--完成2026-08-11) | 動畫與程序化 | ✅ |
| 12.1 | [Core embedding 邊界(C-ABI)](#121-core-embedding-邊界c-abi) | 嵌入、腳本與平台 | ✅ |
| 12.2 | [Mojo / Python 雙腳本](#122-mojo--python-雙腳本) | 嵌入、腳本與平台 | ✅ |
| 13.1 | [反向動力學(精確 τ = ID(q, q̇, q̈))](ROADMAP_HISTORY.md#131-反向動力學精確-τ--idq-q-q--已完成) | 縮座標關節體與致動 | ✅ |
| 13.2 | [縮座標 ↔ 接觸耦合(關節體能碰到世界)](ROADMAP_HISTORY.md#132-縮座標--接觸耦合關節體能碰到世界--已完成) | 縮座標關節體與致動 | ✅ |
| 13.3 | [致動器模型(傳動 + 力生成 + 內部動力學)](ROADMAP_HISTORY.md#133-致動器模型傳動--力生成--內部動力學--已完成) | 縮座標關節體與致動 | ✅ |
| 13.4 | [腱(fixed / spatial,含繞行)](ROADMAP_HISTORY.md#134-腱fixed--spatial含繞行--已完成) | 縮座標關節體與致動 | ✅ |
| 13.5 | [統一約束求解器(equality / limit / friction-loss / contact 一體)](#135-統一約束求解器equality--limit--friction-loss--contact-一體) | 縮座標關節體與致動 | 🔶 |
| 13.6 | [機器人感測器組](ROADMAP_HISTORY.md#136-機器人感測器組---已完成) | 縮座標關節體與致動 | ✅ |
| 13.7 | [剛體求解器可微(把 `Field` 推進 solver6)](#137-剛體求解器可微把-field-推進-solver6) | 可微模擬、批次世界與數值深化 | 🔶 |
| 13.8 | [SDF / 橢球 / 圓柱 narrowphase](#138-sdf--橢球--圓柱-narrowphase) | 碰撞形狀、寬窄相與世界查詢 | 🔶 |
| 13.9 | [批次多世界步進](#139-批次多世界步進) | 可微模擬、批次世界與數值深化 | ⏸ |
| 14.1 | [LBM 核心(D3Q19 碰撞-傳播)](ROADMAP_HISTORY.md#141-lbm-核心d3q19-碰撞-傳播--完成2026-08-12cpu) | 軟體、布料、連續體與流體 | ✅ |
| 14.2 | [障礙物:bounce-back / 浸沒邊界](ROADMAP_HISTORY.md#142-障礙物bounce-back--浸沒邊界---完成2026-08-12半程-bounce-back) | 軟體、布料、連續體與流體 | ✅ |
| 14.3 | [進出口邊界(開放流域)](ROADMAP_HISTORY.md#143-進出口邊界開放流域--完成2026-08-12) | 軟體、布料、連續體與流體 | ✅ |
| 14.4 | [表面力積分(動量交換)→ Cd / Cl](ROADMAP_HISTORY.md#144-表面力積分動量交換-cd--cl---完成2026-08-12) | 軟體、布料、連續體與流體 | ✅ |
| 14.5 | [湍流模型(LES Smagorinsky)](ROADMAP_HISTORY.md#145-湍流模型les-smagorinsky--完成2026-08-12) | 軟體、布料、連續體與流體 | ✅ |
| 14.6 | [LBM 驗證套件:對上文獻數值](ROADMAP_HISTORY.md#146-驗證套件對上文獻數值---完成2026-08-12) | 軟體、布料、連續體與流體 | ✅ |
| 15.1 | [稀疏線性代數層(CG / PCG + 稀疏矩陣)](ROADMAP_HISTORY.md#151-稀疏線性代數層cg--pcg--稀疏矩陣--完成2026-08-11) | 幾何代數與數值基礎 | ✅ |
| 15.2 | [布料自碰撞](ROADMAP_HISTORY.md#152-布料自碰撞---完成2026-08-11) | 軟體、布料、連續體與流體 | ✅ |
| 15.3 | [comptime 自動伴隨式生成](ROADMAP_HISTORY.md#153-comptime-自動伴隨式生成---完成2026-08-11) | 可微模擬、批次世界與數值深化 | ✅ |
| 16.1 | [API 搬遷(std.gpu.host / std.algorithm → max.*)](ROADMAP_HISTORY.md#161-api-搬遷---完成分支-mojo-stable) | 工程、測試、效能與工具鏈 | ✅ |
| 16.2 | [`InlineArray` 不再 `ImplicitlyCopyable`](ROADMAP_HISTORY.md#162-inlinearray-不再-implicitlycopyable---完成) | 工程、測試、效能與工具鏈 | ✅ |
| 16.3 | [Vec3 重構(width-3 SIMD 被禁)](ROADMAP_HISTORY.md#163-vec3-重構width-3-simd-被禁--完成2026-08-12分支-mojo-stable) | 工程、測試、效能與工具鏈 | ✅ |
| 17.0 | [架構前置(Wave A 之前必做;2026-09-27 架構審計)](ROADMAP_HISTORY.md#170-架構前置wave-a-之前必做2026-09-27-架構審計) | 工程、測試、效能與工具鏈 | ✅ |
| 17.1 | [Kinematic 角色控制器](ROADMAP_HISTORY.md#171-kinematic-角色控制器--wave-a) | 角色、載具、破壞與 gameplay 物理 | ✅ |
| 17.2 | [主動布娃娃 / 物理動畫](ROADMAP_HISTORY.md#172-主動布娃娃--物理動畫--wave-b) | 角色、載具、破壞與 gameplay 物理 | ✅ |
| 17.3 | [角色 IK](ROADMAP_HISTORY.md#173-角色-ik--wave-b) | 動畫與程序化 | ✅ |
| 17.4 | [載具動力學](ROADMAP_HISTORY.md#174-載具動力學--wave-c) | 角色、載具、破壞與 gameplay 物理 | ✅ |
| 17.5 | [破壞 / 破碎](ROADMAP_HISTORY.md#175-破壞--破碎--wave-c) | 角色、載具、破壞與 gameplay 物理 | ✅ |
| 17.6 | [動畫圖深度](ROADMAP_HISTORY.md#176-動畫圖深度--wave-b) | 動畫與程序化 | ✅ |
| 17.7 | [固定步 ↔ 繪製率解耦的狀態插值](ROADMAP_HISTORY.md#177-固定步--繪製率解耦的狀態插值--wave-a) | 角色、載具、破壞與 gameplay 物理 | ✅ |
| 17.8 | [大世界座標](#178-大世界座標) | ECS、排程、執行期與診斷 | ✅ |
| 17.9 | [Debug-draw 指令佇列](ROADMAP_HISTORY.md#179-debug-draw-指令佇列--wave-a工具) | ECS、排程、執行期與診斷 | ✅ |
| 17.10 | [Profiling / tracing hooks](ROADMAP_HISTORY.md#1710-profiling--tracing-hooks--wave-a工具) | ECS、排程、執行期與診斷 | ✅ |
| 17.11 | [反射 / 型別註冊表](ROADMAP_HISTORY.md#1711-反射--型別註冊表--wave-b架構解鎖多項) | ECS、排程、執行期與診斷 | ✅ |
| 17.12 | [可編輯場景 / prefab / 實例化](#1712-可編輯場景--prefab--實例化) | ECS、排程、執行期與診斷 | 不排 |
| 17.13 | [世界查詢完整度](ROADMAP_HISTORY.md#1713-世界查詢完整度--wave-a) | 碰撞形狀、寬窄相與世界查詢 | ✅ |
| 17.14 | [導航](#1714-導航) | gameplay 服務、AI、導航與網路 | ✅ |
| 17.15 | [AI 框架](#1715-ai-框架) | gameplay 服務、AI、導航與網路 | ✅ |
| 17.16 | [網路 / rollback](#1716-網路--rollback) | gameplay 服務、AI、導航與網路 | ✅ |
| 17.17 | [GPU 剛體 / articulation solver](#1717-gpu-剛體--articulation-solver) | GPU 計算 | 🔶 |
| 17.18 | [批次多世界步進(13.9 落地)](ROADMAP_HISTORY.md#1718-批次多世界步進139-落地--wave-b) | 可微模擬、批次世界與數值深化 | ✅ |
| 17.19 | [生產級 solver 硬化](#1719-生產級-solver-硬化) | 剛體動力學、接觸與關節 | 🔶 |
| 17.20 | [剛體 solver 可微化收尾(13.7)](ROADMAP_HISTORY.md#1720-剛體-solver-可微化收尾137--wave-b) | 可微模擬、批次世界與數值深化 | ✅ |
| 17.21 | [腳本層(Phase 12 落地)](#1721-腳本層phase-12-落地) | 嵌入、腳本與平台 | ✅ |
| 17.22 | [範例覆蓋補完](ROADMAP_HISTORY.md#1722-範例覆蓋補完--wave-a文件) | 工程、測試、效能與工具鏈 | ✅ |
| 17.23 | [物理材質與逐對組合模式](ROADMAP_HISTORY.md#1723-物理材質與逐對組合模式--wave-a) | 剛體動力學、接觸與關節 | ✅ |
| 17.24 | [Kinematic 剛體型別(通用可移動體)](ROADMAP_HISTORY.md#1724-kinematic-剛體型別通用可移動體--wave-a) | 剛體動力學、接觸與關節 | ✅ |
| 17.25 | [睡眠/喚醒生命週期公開 API](ROADMAP_HISTORY.md#1725-睡眠喚醒生命週期公開-api--wave-a) | 剛體動力學、接觸與關節 | ✅ |
| 17.26 | [接觸修改 / 單向平台](ROADMAP_HISTORY.md#1726-接觸修改--單向平台--wave-b) | 剛體動力學、接觸與關節 | ✅ |
| 17.27 | [力場 / 區域效果](ROADMAP_HISTORY.md#1727-力場--區域效果--wave-b) | 角色、載具、破壞與 gameplay 物理 | ✅ |
| 17.28 | [浮力 / 水體積](ROADMAP_HISTORY.md#1728-浮力--水體積--wave-b) | 角色、載具、破壞與 gameplay 物理 | ✅ |
| 17.29 | [通用可斷裂關節](ROADMAP_HISTORY.md#1729-通用可斷裂關節--wave-b) | 剛體動力學、接觸與關節 | ✅ |
| 17.30 | [地形(HeightField)執行期變形](ROADMAP_HISTORY.md#1730-地形heightfield執行期變形--wave-b) | 碰撞形狀、寬窄相與世界查詢 | ✅ |
| 17.31 | [物理 LOD / 模擬預算調度](ROADMAP_HISTORY.md#1731-物理-lod--模擬預算調度--wave-b) | 剛體動力學、接觸與關節 | ✅ |
| 17.32 | [執行期分級日誌設施](ROADMAP_HISTORY.md#1732-執行期分級日誌設施--wave-a工具錯誤政策的記錄層) | ECS、排程、執行期與診斷 | ✅ |
| 17.33 | [執行期斷言 / 不變量檢查層](ROADMAP_HISTORY.md#1733-執行期斷言--不變量檢查層--wave-a工具錯誤政策的立即終止層) | ECS、排程、執行期與診斷 | ✅ |
| 17.34 | [每幀 / 暫存集區配置器(frame arena)](ROADMAP_HISTORY.md#1734-每幀--暫存集區配置器--wave-a) | ECS、排程、執行期與診斷 | ✅ |
| 17.35 | [計時器 / 補間 / 緩動曲線](ROADMAP_HISTORY.md#1735-計時器--補間--緩動曲線--wave-a) | 動畫與程序化 | ✅ |
| 17.36 | [樣條 / 曲線(路徑)](ROADMAP_HISTORY.md#1736-樣條--曲線路徑--wave-a) | 動畫與程序化 | ✅ |
| 17.37 | [實體池化](ROADMAP_HISTORY.md#1737-實體池化--wave-a) | ECS、排程、執行期與診斷 | ✅ |
| 17.38 | [遊戲事件匯流排 / 訊息系統](ROADMAP_HISTORY.md#1738-遊戲事件匯流排--訊息系統--wave-a) | ECS、排程、執行期與診斷 | ✅ |
| 17.39 | [輸入錄製 / 決定論回放(QA・ghost,非網路)](ROADMAP_HISTORY.md#1739-輸入錄製--決定論回放qaghost非網路--wave-b) | ECS、排程、執行期與診斷 | ✅ |
| 17.40 | [存檔系統(相對於決定論快照)](ROADMAP_HISTORY.md#1740-存檔系統相對於決定論快照--wave-b) | ECS、排程、執行期與診斷 | ✅ |
| 17.41 | [繩索 / 纜線約束](ROADMAP_HISTORY.md#1741-繩索--纜線約束--wave-b) | 軟體、布料、連續體與流體 | ✅ |
| 17.42 | [LBM 風洞收尾(Phase 14 遺留併入)](ROADMAP_HISTORY.md#1742-lbm-風洞收尾phase-14-遺留併入--wave-b) | 軟體、布料、連續體與流體 | ✅ |
| 17.43 | [Undo / redo 交易層(編輯器前置)](#1743-undo--redo-交易層編輯器前置) | ECS、排程、執行期與診斷 | 不排 |
| 17.44 | [複合形狀](#1744-複合形狀--wave-b) | 剛體動力學、接觸與關節 | ✅ |
| 17.45 | [網格碰撞品質](#1745-網格碰撞品質--wave-a資產前處理) | 碰撞形狀、寬窄相與世界查詢 | ✅ |
| 17.46 | [CCD 形狀覆蓋](#1746-ccd-形狀覆蓋--wave-b) | 碰撞形狀、寬窄相與世界查詢 | ✅ |
| 17.47 | [關節庫補完(最大座標)](#1747-關節庫補完最大座標--wave-b承-91) | 剛體動力學、接觸與關節 | ✅ |
| 17.48 | [剛體參數 API](#1748-剛體參數-api--wave-a) | 剛體動力學、接觸與關節 | ✅ |
| 17.49 | [力回報 / 衝擊事件](#1749-力回報--衝擊事件--wave-a) | 剛體動力學、接觸與關節 | ✅ |
| 17.50 | [接觸模型變體](#1750-接觸模型變體--wave-b) | 剛體動力學、接觸與關節 | ✅ |
| 17.51 | [縮座標完整化](#1751-縮座標完整化--wave-b承-91) | 縮座標關節體與致動 | ✅ |
| 17.52 | [形狀種類](#1752-形狀種類--wave-b承接-138-的剩餘部分) | 碰撞形狀、寬窄相與世界查詢 | ✅ |
| 17.53 | [查詢擴充](#1753-查詢擴充--wave-a承接-1713-的待辦) | 碰撞形狀、寬窄相與世界查詢 | ✅ |
| 17.54 | [CPU 碰撞管線](#1754-cpu-碰撞管線--wave-b多執行緒) | 碰撞形狀、寬窄相與世界查詢 | ✅ |
| 17.55 | [連續體步進契約](#1755-連續體步進契約--wave-b連續體前置) | 軟體、布料、連續體與流體 | ✅ |
| 17.56 | [布料](#1756-布料--wave-b) | 軟體、布料、連續體與流體 | ✅ |
| 17.57 | [毛髮 / 肌肉](#1757-毛髮--肌肉--wave-c) | 軟體、布料、連續體與流體 | 🔶 |
| 17.58 | [體積軟體](#1758-體積軟體--wave-c) | 軟體、布料、連續體與流體 | 🔶 |
| 17.59 | [流固耦合](#1759-流固耦合--wave-c) | 軟體、布料、連續體與流體 | 🔶 |
| 17.60 | [水面 / 網格流體](#1760-水面--網格流體--wave-c) | 軟體、布料、連續體與流體 | 🔶 |
| 17.61 | [多物理](#1761-多物理--wave-c) | 軟體、布料、連續體與流體 | 🔶 |
| 17.62 | [GPU / 可微連續體](#1762-gpu--可微連續體--wave-cgpu--可微) | 軟體、布料、連續體與流體 | ⬜ |
| 17.63 | [輸出 / 快取](#1763-輸出--快取--wave-c資產管線提供者) | 軟體、布料、連續體與流體 | 🔶 |
| 17.64 | [動畫執行期](#1764-動畫執行期--wave-b) | 動畫與程序化 | ✅ |
| 17.65 | [形變資料](#1765-形變資料--wave-cheadless-資料--邏輯) | 動畫與程序化 | 🔶 |
| 17.66 | [物理角色](#1766-物理角色--wave-c) | 角色、載具、破壞與 gameplay 物理 | 🔶 |
| 17.67 | [移動模式](#1767-移動模式--wave-b) | 角色、載具、破壞與 gameplay 物理 | 🔶 |
| 17.68 | [攝影機 / 序列](#1768-攝影機--序列--wave-bheadless-資料--邏輯) | 角色、載具、破壞與 gameplay 物理 | ✅ |
| 17.69 | [PCG](#1769-pcg--wave-c) | 動畫與程序化 | 🔶 |
| 17.70 | [規則框架](#1770-規則框架--wave-c) | gameplay 服務、AI、導航與網路 | 🔶 |
| 17.71 | [戰鬥物理](#1771-戰鬥物理--wave-b) | 角色、載具、破壞與 gameplay 物理 | ✅ |
| 17.72 | [流程服務](#1772-流程服務--wave-c) | gameplay 服務、AI、導航與網路 | 🔶 |
| 17.73 | [營運邊界](#1773-營運邊界--wave-c) | gameplay 服務、AI、導航與網路 | 🔶 |
| 17.74 | [載具家族](#1774-載具家族--wave-c) | 角色、載具、破壞與 gameplay 物理 | 🔶 |
| 17.75 | [嵌入契約](#1775-嵌入契約--wave-b平台方向-c-前提與-121-同期) | 嵌入、腳本與平台 | 🔶 |
| 17.76 | [平台可攜](#1776-平台可攜--wave-b平台方向-c-前提) | 嵌入、腳本與平台 | 🔶 |
| 17.77 | [ECS 表達力](#1777-ecs-表達力--wave-b) | ECS、排程、執行期與診斷 | ✅ |
| 17.78 | [宿主整合 / 綁定](#1778-宿主整合--綁定--wave-c) | 嵌入、腳本與平台 | 🔶 |
| 17.79 | [資源治理](#1779-資源治理--wave-b) | ECS、排程、執行期與診斷 | 🔶 |
| 17.80 | [觀測](#1780-觀測--wave-b工具執行期追蹤開關物理擷取檔與回看) | ECS、排程、執行期與診斷 | 🔶 |
| 17.81 | [CI / 授權 / 發行](#1781-ci--授權--發行--wave-a工程先於其他各項) | 工程、測試、效能與工具鏈 | ✅ |
| 17.82 | [品質工具](#1782-品質工具--wave-a工程) | 工程、測試、效能與工具鏈 | ✅ |
| 17.83 | [效能治理](#1783-效能治理--wave-a工程) | 工程、測試、效能與工具鏈 | 🔶 |
| 17.84 | [數值 / 可微深化](#1784-數值--可微深化--wave-c) | 可微模擬、批次世界與數值深化 | 🔶 |
| 17.85 | [分級模擬:依因果可達性分配時間 / 空間解析度](#1785-分級模擬依因果可達性分配時間--空間解析度--wave-c架構) | ECS、排程、執行期與診斷 | 🔶 |
