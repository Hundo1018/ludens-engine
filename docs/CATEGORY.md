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
| `StorageBackend`(sparse-set / archetype / bitset / reactive / chunked / naive) | ecs/storage.mojo、chunked_backend.mojo | 實作函子間的自然同構 | `test_backend_parity`、`test_iter_parity` | `bench_ecs`、`bench_locality`、`bench_chunked` |
| 傳播策略 full/dirty/**motor** | ecs/transform_systems.mojo、ecs/motor_transform.mojo | 同一態射的三個實作;dirty 是 full 的等價優化 | `test_transform`、`test_motor_transform` | `bench_transform` |
| `Scheduler`(sequential / system-actor / entity-actor)×(serial/parallel) | scheduler/scheduler.mojo、system_actor.mojo、entity_actor.mojo | 態射合成的不同求值策略(直接迭代 vs mailbox dataflow),世界逐位相同 | `test_scheduler_parity` | `bench_scheduler` |
| `ContactSolver` | physics/solver.mojo | 同一物理不動點的不同迭代子 | `test_physics_dynamics` | `bench_physics` |
| `BroadPhase`(rebuild 5 種 + DBVH 持久化) | collision/broadphase.mojo、bp_dbvh.mojo | 同一謂詞的加速結構;結果集相等 | `test_broadphase`、`test_bvh`、`test_dbvh` | `bench_collision`、`bench_dbvh` |
| `NarrowPhase`(boolean,含 CGA 代數路徑) | collision/narrowphase.mojo | 同一謂詞的解析 vs 代數實作 | `test_narrowphase` 系列、`test_cga_narrowphase`、`test_cga_plane` | `bench_collision` |
| `ManifoldNarrowPhase`(AABB/SAT/OBB/GJK/hull) | collision/manifold.mojo、hull.mojo | 接觸謂詞的富化(點集+深度),normal/depth 與 boolean 路徑一致 | `test_manifold`、`test_hull` | `bench_manifold` |
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
| `Field`(RealF/DualReal/DualBatch/RevReal tape / comptime 生成伴隨)+ `GMV` vs 特化 | geometry/field.mojo、gmv.mojo、physics/adjoint.mojo | 對偶數函子(切叢提升)+ 伴隨函子(反向掃,執行期 tape 與編譯期展開兩實作);係數環參數化 | `test_diffsim`、`test_gmv_ad`、`test_adjoint`、`test_laws` | `bench_diffsim` |
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
   立法當下的反例:`geometry/quickhull.mojo` 寫好數月卻從未接進 narrowphase
   (當時 grep 在 `collision/` 與 `physics/` 零命中),能力等於不存在。該孤島已於
   同日 `947a37f` 補上生產入口 `SATNarrowPhase.add_cloud` /
   `SATManifoldNarrowPhase.add_cloud`,反例僅存為立法緣由。若刻意不接(如
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

### 2.1 Phase 6–13 補齊的 seam(2026-09-03)

§2 的表定型於 Phase 4。Phase 6–13 長出的物理、流體、可變形體、GPU 與排程 seam
同受定律 v2 約束(parity 測試 + `BENCHMARK_REPORT.md` row,缺一不收),整理如下。
每列的「範疇論解讀」仍是「同一態射／謂詞,不同求值」——swap 的自然性方格由
「定律測試」欄機械化。補這張表時關掉了一個既存的 v2 缺口:`bench_lbm` 先前沒有
LES 對照列,`test_lbm_les` 的 seam 從此有量測(見末列)。

**加速結構、Morton 排序、平行求值**

| Seam | 檔案 | 範疇論解讀 | 定律測試 | Benchmark |
|---|---|---|---|---|
| SAP 掃掠剪除(時間連續性)vs DBVH/hashgrid/rebuild | collision/bp_sap.mojo | 同一重疊謂詞的加速結構;命中集與 brute 相等,成本由逆序數而非 fat margin 決定 | `test_sap` | `bench_sap` |
| GPU 全對 broadphase vs CPU 加速結構 | collision/bp_gpu.mojo | 同一謂詞的 host/device 實作;命中集相等、次序不定(原子游標)→ 刻意不實作 `BroadPhase` trait,理由在檔頭 | `test_gpu_broadphase` | `bench_gpu_broadphase` |
| GPU 批次 raycast vs CPU BVH 走訪 | collision/gpu_raycast.mojo | 同一射線查詢的裝置實作;逐 proxy-id 相等 | `test_gpu_raycast` | `bench_gpu_raycast` |
| LBVH 建樹(第三種啟發式)+ CPU LSD-radix vs GPU bitonic Morton 排序 | geometry/bvh.mojo(`morton_order`)、gpu_lbvh.mojo | median/SAH 之外的第三個建構函子;查詢結果集相等,建樹支配 median | `test_lbvh`、`test_gpu_lbvh` | `bench_gpu_lbvh` |
| 島求解 serial vs threaded | physics/solver6.mojo(`_solve_islands_parallel`) | 態射合成的求值策略;任一 worker 寬度下世界逐位相同(須先對齊睡眠行為) | `test_islands_par` | `bench_islands` |
| 島內圖著色 vs 純 Gauss–Seidel | physics/solver6.mojo(`_sweep_colored`) | 同一不動點迭代的掃描序變體;決定性、與執行緒數無關 | `test_colored` | `bench_colored` |
| work-stealing `ws_parallel_for` vs 靜態 `parallelize` | scheduler/workstealing.mojo | 同一平行 for 的排程策略;每個索引恰執行一次,結果不變 | `test_workstealing` | `bench_workstealing` |
| job graph 由讀寫集推導 vs 註冊序 | scheduler/jobgraph.mojo | 態射合成序的自動化;拓撲序下世界逐位相同 | `test_jobgraph` | `bench_jobgraph` |

**縮座標多體動力學**

| Seam | 檔案 | 範疇論解讀 | 定律測試 | Benchmark |
|---|---|---|---|---|
| 關節鏈:縮座標 CRBA+RNEA vs O(n) ABA vs 極大座標 solver6 | physics/chain.mojo(`step`／`step_aba`) | SE(3)ⁿ 動力學的三個實作;同初態下關節角一致 | `test_chain`、`test_aba` | `bench_chain` |
| 反向動力學(RNEA 掃)vs 正向動力學(CRBA 稠密解)往返 | physics/chain.mojo(`inverse_dynamics`／`mass_matrix`) | 同一運動方程的兩向;τ→q̈→τ 還原 | `test_inverse_dynamics` | `bench_chain`(idt 表) |
| 縮座標接觸(point-Jacobian `J H⁻¹ Jᵀ`)vs 極大座標接觸 | physics/chain.mojo(`point_jacobian`／`resolve_ground`) | 同一接觸不動點在兩種座標下;落地高度一致 | `test_chain_contact` | `bench_chain_contact` |
| 浮動基座 vs 六個偽關節;複合慣量 vs 單位加速度 兩種 H 組裝 | physics/floating.mojo(`mass_matrix`／`_mass_matrix_units`) | 6-DOF 根的兩個表示 + 質量矩陣兩獨立推導互為 parity | `test_floating` | `bench_floating` |
| 關節運動子空間 revolute vs prismatic + 關節極限 | physics/chain.mojo(`revolute`／`prismatic`／`resolve_limits`) | 同一 link 態射的運動子空間變體;極限為投影 | `test_joints_lib`、`test_joints6` | `bench_chain`(jt 表) |

**統一約束、致動、腱、感測**

| Seam | 檔案 | 範疇論解讀 | 定律測試 | Benchmark |
|---|---|---|---|---|
| 統一約束求解器 vs 交替通道;金字塔 vs 橢圓摩擦錐 | physics/constraints.mojo(`CONE_PYRAMIDAL`／`CONE_ELLIPTIC`) | equality/limit/friction/contact 一體 vs 分通道;等工作量下打平,錐耦合列是能力差而非速度差 | `test_constraints` | `bench_constraints` |
| 致動器(仿射傳動 + 內部動力學低通)vs 直接 PD 伺服 | physics/actuator.mojo | 力生成態射的抽象層;高增益極限下兩者收斂 | `test_actuator` | `bench_actuator` |
| 腱力臂:解析 Jacobian vs 中央差分;`FixedTendon` vs `SpatialTendon`、繞行 on/off | physics/tendon.mojo | 同一長度映射的解析與數值梯度;1–2 DOF 差分勝、交叉點 2–8 DOF | `test_tendon` | `bench_tendon` |
| 感測:逐呼叫 `read_imu`(O(S·L))vs 共享掃描 `read_imu_batch`(O(L+S))vs 差分 | physics/sensors.mojo | 同一觀測函子的攤銷實作;N=1 控制組須略慢方為可信 | `test_sensors` | `bench_sensors` |

**可變形體**

| Seam | 檔案 | 範疇論解讀 | 定律測試 | Benchmark |
|---|---|---|---|---|
| FEM:線性 vs co-rotational 彈性;顯式 `step` vs 隱式 `step_implicit` | physics/fem.mojo | 同一彈性能量的線性化變體 + 時間積分子(隱式走 CG) | `test_fem`、`test_numerics` | `bench_fem`、`bench_numerics` |
| MPM:彈性 vs 塑性(行列式夾限回映)於同場景 | physics/mpm.mojo(`set_plastic`) | 同一 P2G/G2P 態射 + 本構回映;塑性僅 +0.5% 成本 | `test_mpm` | `bench_mpm` |
| SPH(密度誤差→壓力**力**,CFL 限步)vs PBF(密度誤差→**約束**投影) | physics/sph.mojo、pbf.mojo | 同一不可壓縮謂詞的力法與投影法;PBF 步長 4× 但每模擬秒成本相當 | `test_sph`、`test_pbf` | `bench_sph`、`bench_pbf` |
| 布料自碰撞 on/off,橫跨 XPBD 與 VBD 兩 solver | physics/self_collide.mojo | 同一自碰撞約束在兩下降子上的加入;結果集一致 | `test_self_collide` | `bench_self_collide` |

**幾何謂詞與代數**

| Seam | 檔案 | 範疇論解讀 | 定律測試 | Benchmark |
|---|---|---|---|---|
| 精確幾何謂詞 vs 裸浮點符號(orient2d/3d、incircle、insphere) | geometry/predicates.mojo(`*` vs `*_naive`) | 同一符號謂詞的精確與近似實作;退化輸入下符號一致 | `test_predicates` | `bench_predicates` |
| 靜態關卡中相:brute vs BVH;`TriMesh` vs `HeightField` | collision/trimesh.mojo | 同一靜態幾何查詢的加速結構 + 兩種關卡表示;靜置高度一致 | `test_trimesh` | `bench_trimesh` |
| 3D SDF 迭代接觸 vs 解析 sphere/box 對(+ CSG 無解析對照) | geometry/sdf3.mojo(`sdf_contact`、`OP_SUBTRACT`) | 同一接觸謂詞的隱式場實作;解析對照存在處 parity | `test_sdf3` | `bench_sdf3` |
| DCGA `Cl(4,1)⊗Cl(4,1)` 統一四次 incidence vs 手寫 plane/sphere/torus | geometry/dcga.mojo | 「簽名 ↦ 代數」函子在張量積代數上的值;成本恆定不分曲面(統一性),1.6–1.9× | `test_dcga` | `bench_dcga` |

**其他**

| Seam | 檔案 | 範疇論解讀 | 定律測試 | Benchmark |
|---|---|---|---|---|
| 可微接觸模型:剛性衝量 vs 軟性罰函數 | physics/diffrigid.mojo(`rollout_rigid`／`rollout_soft`) | 同一接觸態射的兩個可微化;梯度對兩模型各自定義 | `test_diffrigid` | `bench_diffrigid` |
| 動畫混合:線性(norm-lerp)vs DLB vs 測地(等速螺旋) | procedural/anim.mojo(`BLEND_LINEAR`／`BLEND_DLB`／`BLEND_GEODESIC`) | §3 表示函子在姿態混合上的作用;測地留在運動流形上 | `test_anim` | `bench_anim` |
| 線性解:全域 CG/PCG vs 局部 Jacobi 掃;Jacobi 前條件子 on/off | numerics/cg.mojo、sparse.mojo | 同一線性系統的迭代子家族;matrix-free 與顯式 CSR 兩路徑 | `test_numerics` | `bench_numerics` |
| LBM Smagorinsky LES vs 純 BGK(常數為 0 ⇒ 逐位相同) | fluid/lbm.mojo(`eddy_viscosity`) | 同一碰撞算子的湍流閉合變體;優勢區是粗網格高 Re(BGK 發散、LES 收斂) | `test_lbm_les` | `bench_lbm`(LES 表) |

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
