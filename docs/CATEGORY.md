# LudensEngine 的範疇論結構

引擎的「swap seam」架構不是偶然好用 —— 它是一組範疇論結構的具體實作。本文把既有
的 trait seam、parity 測試與 GA 數學層放進同一張圖,並指出哪些「定律」已由測試
機械化(`tests/test_laws.mojo` 與各 parity 套件)。

## 1. 基本圖景

- **對象(objects)**:世界狀態 —— `World[B]` 的完整元件內容(以查詢可觀察的
  值語意呈現,與 backend 無關)。
- **態射(morphisms)**:系統 —— `World → World` 的狀態轉移(movement、
  integrate、propagate、despawn⋯)。恆等態射 = 空系統;合成 = 依序執行。
  這構成範疇 **𝑾**(對象 = 世界狀態,態射 = 系統)。

## 2. Seam = 函子;parity 測試 = 自然性方格

每個 `StorageBackend` 決定一個「實作函子」`F_B : 𝑾 → Set`:把抽象世界狀態送到
該 backend 的具體儲存,把每個系統送到它在該儲存上的執行。兩個 backend 之間的
「swap」是自然變換 `η : F_sparse ⇒ F_archetype`(由值語意的 get/set 給出的逐
對象轉換)。

**自然性方格**(對每個系統 f):

```
F_sparse(W) ──F_sparse(f)──▶ F_sparse(W')
     │                             │
     η_W                           η_W'
     ▼                             ▼
F_arch(W) ───F_arch(f)────▶  F_arch(W')
```

「先換 backend 再跑系統」=「先跑系統再換 backend」。**這正是
`test_backend_parity` 逐值斷言的內容** —— 5 個 backend 對同一場景產生相同的查
詢計數與聚合值。同理:

| Seam(trait) | 檔案 | 範疇論解讀 | 定律測試 |
|---|---|---|---|
| `StorageBackend` | ecs/storage.mojo | 實作函子間的自然同構 | `test_backend_parity` |
| 傳播策略 full/dirty/**motor** | ecs/transform_systems.mojo、ecs/motor_transform.mojo | 同一態射的三個實作;dirty 是 full 的等價優化 | `test_transform`、`test_motor_transform` |
| `Scheduler` ×(serial/parallel) | scheduler/scheduler.mojo | 態射合成的不同求值策略,結果不變 | `test_scheduler_parity` |
| `ContactSolver` | physics/solver.mojo | 同一物理不動點的不同迭代子 | `test_physics_dynamics` |
| `BroadPhase`/`NarrowPhase`/`SceneQuery` | collision/ | 同一謂詞的加速結構;結果集相等 | pipeline/queries 測試 |
| `Rng` | scheduler/rng.mojo | 種子單子(state monad)的可交換實作 | `test_rng` |
| `for_each2` vs `query2+get/set` | ecs/storage.mojo | 同一態射的無配置實作 | `test_iter_parity` |

**架構定律**:任何新 seam 實作必須附上它的自然性方格(parity 測試)。這是引擎
「swappability holds end-to-end」的形式化理由。

## 3. SE(3) 的三個表示函子(GA 層)

剛體運動群 SE(3) 是單對象範疇(群 = 只有一個對象的 groupoid)。三個「表示」
各是一個忠實函子,把抽象運動送到可計算的載體:

```
           R_motor(8f 偶次子代數)
  SE(3) ──R_dq(8f 對偶四元數)──▶  (作用於 ℝ³ 的具體變換)
           R_mat(16f 齊次矩陣)
```

- **群律**(結合律/單位元/逆)—— `test_laws.mojo` 以「作用等價」逐點檢查
  (motor 與 −motor 是同一運動,故不比係數比作用)。
- **函子律** `F(m₁·m₂) = F(m₁)·F(m₂)` —— `to_mat4`、`DualQuat.from_motor`
  各自保持合成(`test_laws.mojo`)。
- **自然同構** —— 三個表示對每個點的作用一致(`test_motor_parity` 285 檢查:
  motor ≡ quat+t ≡ mat4 ≡ dq;`to_motor`/`from_motor` 是互逆的自然變換)。
- **Lie 對應** —— `exp/log`(geometry/galie.mojo)是李代數(bivector 空間)
  與李群(motor 流形)之間的局部同構;`geodesic` 是單參數子群的軌道。
  `exp(log(M)) = M` 與「1 大步 = 10 小步」(exact helix)由
  `test_motor_parity`/`test_motor_transform` 檢查。

## 4. 為什麼值得:定律 = 免費的重構保險

- 換 backend、換 solver、換傳播策略、換剛體表示 —— 每一種「換」都有一個已
  機械化的交換方格。破壞方格的變更會被測試立刻抓住。
- 新表示(如未來的 CGA 剛體、或 GPU 端矩陣)接入的驗收標準是明確的:提供到
  既有表示的自然變換 + 函子律測試,而非重寫遊戲邏輯。
- `Multivector[p,q,r]` 本身是「簽名 ↦ 代數」的(comptime)函子:同一份積表
  生成器對每個度規簽名給出一個代數,PGA2/PGA3/CGA3 只是它在三個對象上的值。

## 5. 已知的非定律(誠實清單)

- Motor 無法表示縮放 —— `MotorTransform` 只涵蓋剛體子群;含 scale 的層級請
  走矩陣路徑(`Transform`)。兩者的交集(scale=1)上 parity 成立
  (`test_motor_transform`)。
- 浮點下所有「定律」都是 ε-定律(容差 1e-3~1e-4);結合律在極端量級下會退化。
- `apply_point`(sandwich)比手工 DQ/矩陣慢(泛型積的代價)—— 批次點變換應
  `to_mat4()` 後走矩陣或 SIMD 欄(見 `bench_ga` 數據)。
- `CgaSphereNarrowPhase`(G4 已升格進 collision seam)精度與解析路徑 100%
  parity(`test_cga_narrowphase`),但每測約 4×(≈12 vs ≈3 ns;dual 球是 32
  float 的 multivector)。它的價值是統一 formalism,不是速度。
