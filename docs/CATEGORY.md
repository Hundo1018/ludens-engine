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

| Seam(trait) | 檔案 | 範疇論解讀 | 定律測試 | Benchmark |
|---|---|---|---|---|
| `StorageBackend` | ecs/storage.mojo | 實作函子間的自然同構 | `test_backend_parity` | `bench_ecs`、`bench_locality` |
| 傳播策略 full/dirty/**motor** | ecs/transform_systems.mojo、ecs/motor_transform.mojo | 同一態射的三個實作;dirty 是 full 的等價優化 | `test_transform`、`test_motor_transform` | `bench_transform` |
| `Scheduler` ×(serial/parallel) | scheduler/scheduler.mojo | 態射合成的不同求值策略,結果不變 | `test_scheduler_parity` | `bench_scheduler` |
| `ContactSolver` | physics/solver.mojo | 同一物理不動點的不同迭代子 | `test_physics_dynamics` | `bench_physics` |
| `BroadPhase`(rebuild 5 種 + DBVH 持久化) | collision/broadphase.mojo、bp_dbvh.mojo | 同一謂詞的加速結構;結果集相等 | `test_broadphase`、`test_bvh`、`test_dbvh` | `bench_collision`、`bench_dbvh` |
| `NarrowPhase`(boolean,含 CGA 代數路徑) | collision/narrowphase.mojo | 同一謂詞的解析 vs 代數實作 | `test_narrowphase` 系列、`test_cga_narrowphase`、`test_cga_plane` | `bench_collision` |
| `ManifoldNarrowPhase`(AABB/SAT/OBB/GJK) | collision/manifold.mojo | 接觸謂詞的富化(點集+深度),normal/depth 與 boolean 路徑一致 | `test_manifold` | `bench_manifold` |
| `SceneQuery`(brute/bvh/grid/tree) | collision/queries.mojo | 同一查詢謂詞的加速結構 | `test_queries` | `bench_queries` |
| solver6 pair 收集 brute O(n²) vs BVH | physics/solver6.mojo(`_collect_pairs`) | 同一接觸對集合的加速枚舉;fat-AABB 保守超集 → 命中集相等、同序 → 逐位一致 | `test_solver_broadphase` | `bench_solver_scale` |
| BVH 建樹啟發式 median vs binned SAH | geometry/bvh.mojo(`build(sah=)`) | 同一加速結構的建構品質變體;查詢結果集/最近命中相等,SAH 樹更緊 | `test_sah` | `bench_sah` |
| `Rng` | scheduler/rng.mojo | 種子單子(state monad)的可交換實作 | `test_rng` | `bench_rng` |
| `for_each2` vs `query2+get/set` | ecs/storage.mojo | 同一態射的無配置實作 | `test_iter_parity` | `bench_ecs`(存取路徑 rows) |
| `Body6`(quat+tensor vs motor/screw) | physics/rigid6.mojo | SE(3) 動力學的兩個表示函子,比 action 不比係數 | `test_rigid6`、`test_solver6` | `bench_rigid6` |
| `SpinIntegrator`(Euler/RK2/Midpoint/**Lgvci** 變分) | physics/integrator6.mojo | 同一連續流的離散化家族(含 Moser–Veselov 變分積分子) | `test_integrator6` | `bench_rigid6` |
| 布料 CPU vs GPU | physics/gpu_cloth.mojo | 同一態射的裝置實作(host/device) | `test_gpu_cloth` | `bench_gpu_cloth` |
| 布料 solver XPBD vs VBD | physics/gpu_cloth.mojo、vbd_cloth.mojo | 同一變分能量的不同下降子(Jacobi 投影 vs 著色 Newton 塊下降) | `test_vbd_cloth`(物性 + CPU/GPU parity) | `bench_vbd_cloth`(同品質水準比成本) |
| 剛體變換表示 motor/DQ/mat4/quat | geometry/motor.mojo、dualquat.mojo、mat.mojo、quat.mojo | SE(3) 表示函子(§3) | `test_motor_parity` | `bench_ga` |
| 蒙皮 DLB vs LBS | geometry/skinning.mojo | 表示函子在蒙皮插值上的作用 | `test_skinning` | `bench_ga`(skin rows) |
| `Field`(RealF/DualReal/DualBatch/RevReal tape)+ `GMV` vs 特化 | geometry/field.mojo、gmv.mojo | 對偶數函子(切叢提升)+ 伴隨函子(反向掃);係數環參數化 | `test_diffsim`、`test_gmv_ad`、`test_laws` | `bench_diffsim` |
| CCD 階段 speculative vs swept/TOI | physics/solver6.mojo、collision/toi.mojo | 同一「不穿隧」謂詞的一階(裕度)與二階(掃掠)保證;慢速路徑逐位一致 | `test_ccd6` | `bench_ccd` |
| 變更偵測 push observers vs 輪詢 | ecs/reactive_backend.mojo | 同一成員變化事件流的推/拉實作;重播 ≡ 輪詢結果 | `test_observers` | `bench_ecs_events` |
| 組件寫入 直接 vs 延遲(SetBuffer) | ecs/commands.mojo | 同一寫入序列的即時與 sync-point 重播;錄製序保序 | `test_deferred_set` | `bench_ecs_events` |
| 線代 scalar vs SIMD | geometry/mat.mojo | 同一線性映射的 lane 寬度變體 | `test_mat` | `bench_linalg` |

**架構定律**:任何新 seam 實作必須附上它的自然性方格(parity 測試)。這是引擎
「swappability holds end-to-end」的形式化理由。
**架構定律 v2(2026-07-13)**:每個 seam 的**所有**變體必須同時出現在上表的
「定律測試」與「Benchmark」兩欄 —— parity 測試 + `BENCHMARK_REPORT.md` 對應
row,缺一不收(相對方法時刻有對應 benchmark)。新增 seam 或變體時,本表為
覆蓋矩陣,benchmark 欄不得留空。

**架構定律 v3(2026-08-11,使用者明令)**:v2 管「有沒有對應的量測」,v3 管
「實作本身是否完整」。每項交付另須滿足:

1. **接上專案** —— 新能力必須接進**真正會跑到的路徑**,不得留為孤島。
   反例:`geometry/quickhull.mojo` 寫好卻從未接進 narrowphase(grep 在
   `collision/` 與 `physics/` 零命中),能力等於不存在。若刻意不接(如
   `collision/bp_gpu.mojo` 不實作 `BroadPhase` trait —— trait 無處放 device
   context),**理由必須寫在檔頭**。
2. **普通案例** —— 名目輸入下行為正確。
3. **整合案例** —— 與其他子系統一起跑仍成立:換 backend 逐位相同、接進 solver
   後既有測試不變、CPU/GPU parity、序列化後續跑逐位相同。
4. **極端案例** —— 退化與邊界:零/單一元素、全部重合、共面共線、零長度法向、
   除零、超出容量、極大/極小步長、族群變動、瞬移(打破時間連續性假設)。
   **本專案至今最多真 bug 由這一類抓到** —— MPM 的 P2G stencil 偏移(自由落體
   動量暴衝 366000×)、PBF 的三個 bug、LBVH 的重複 Morton 碼、SAP 的瞬移、
   chunked backend 的鄰頁釋放、CGA rotor 的雙向量符號(只有跨實作比對才抓得到)。

**Phase 4 新增(2026-07-13,皆遵定律 v2)**:上表最後五列 —— CCD 兩階段
(speculative/swept)、變更偵測(push/poll)、組件寫入(直接/延遲)、布料 solver
(XPBD/VBD)—— 加上 `SpinIntegrator` 的 `LgvciSpin`(變分,入 `bench_rigid6`)與
`Field` 的 `RevReal` tape(入 `bench_diffsim`)。六個新變體各附 parity test +
report row。

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
