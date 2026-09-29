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
| solver6 pair 收集 brute O(n²) vs `BroadPhase` 全 seam(17.0e:`ContactScene6[B,BP]`,collider 註冊表移至 `collision/collider_set.mojo`) | physics/solver6.mojo(`_collect_pairs`)、collision/contact_gen.mojo(`collect_bp_pairs`) | 同一接觸對集合的加速枚舉,現貫穿真正會跑的 `BroadPhase` trait(brute/BVH/DBVH/SAP/hashgrid/octree);fat-AABB 保守超集 + 逐對正規化排序 → 命中集相等、同序 → 逐位一致,與後端無關 | `test_solver_broadphase`、`test_solver_bp_seam`(6 後端 × 6 案例矩陣,含極端案例) | `bench_solver_scale`(N=64…4096 全後端矩陣 + SAP/hashgrid 20:1 尺寸展延列) |
| BVH 建樹啟發式 median vs binned SAH | spatial/bvh.mojo(`build(sah=)`) | 同一加速結構的建構品質變體;查詢結果集/最近命中相等,SAH 樹更緊 | `test_sah` | `bench_sah` |
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
| 曲線表示:generalized Catmull-Rom(comptime `alpha`:uniform/centripetal/chordal)vs 分段三次 Bezier(17.36) | geometry/spline.mojo(`CatmullRom.segment_bezier`) | 同一段曲線的兩個表示函子;`alpha=0` 化簡為教科書封閉式「均勻 CR = Bezier(P1, P1+(P2-P0)/6, P2-(P3-P1)/6, P2)」,任意 `alpha` 走同一 Barry-Goldman 構造的 Hermite→Bezier 轉換,不是特例分支 | `test_spline`、`test_spline_parity`、`test_spline_frames`(RMF motor 幀 + galie 測地線內插,同層跨模組整合) | `bench_spline` |
| 高頻生滅實體:直接 `spawn`+set+`despawn` vs entity pool `acquire`/`release`,跨六個 `StorageBackend`(17.37) | ecs/pool.mojo | 同一「取得一個帶模板值的活實體」態射的兩個實作;`acquire` 對已存在的模板欄位是 in-place overwrite(archetype 不遷移,只有 `Disabled[DID]` 標記自己遷移),`spawn`+逐一 `set` 是逐欄新增(每次遷移一個 archetype)——同一終態(值相等、查詢集相同),路徑成本不同 | `test_pool`(六 backend parity;耗盡 grow/refuse、雙重釋放、外來實體、跨 release/re-acquire 的過期 handle 四個極端案例) | `bench_pool`(churn N=1..1e5;N=1 對照組——含一次性 `prime`——之下 pool 全六 backend 皆較慢,1.19x-1.74x,N=1e5 轉為較快,1.08x-1.51x,矩陣見報告) |

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
| LBVH 建樹(第三種啟發式)+ CPU LSD-radix vs GPU bitonic Morton 排序 | spatial/bvh.mojo(`morton_order`)、spatial/gpu_lbvh.mojo | median/SAH 之外的第三個建構函子;查詢結果集相等,建樹支配 median | `test_lbvh`、`test_gpu_lbvh` | `bench_gpu_lbvh` |
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

### 2.2 `diag`(可觀測性層,Phase 17.9/17.10/17.32–17.34,2026-09-27)

`diag` 是 layer 0(見 `docs/ARCHITECTURE.md` §1),零引擎依賴,錯誤處理政策
(§2)的 detect/record/terminate 三層都落在這裡。它自己也長出兩個效能 seam:

| Seam | 檔案 | 範疇論解讀 | 定律測試 | Benchmark |
|---|---|---|---|---|
| 每幀暫存記錄:`FrameArena` bump 配置(一次配置、`reset()` 重用)vs 每幀新建 `List` | diag/arena.mojo | 同一「每幀 N 筆暫存記錄」需求的兩個配置策略;逐值內容相等(`test_diag_arena` 的 parity 檢查),配置開銷不同 | `test_diag_arena` | `bench_diag`(arena vs list 表) |
| 分級日誌 / 追蹤 span 的 compile-time on/off(`LUDENS_LOG_LEVEL`／`LUDENS_TRACE`) | diag/log.mojo、diag/trace.mojo | 同一呼叫點在兩個編譯期特化下的行為;停用側必須是「本來就沒呼叫」的自然態射(單位態射),而非「呼叫了但跳過」 | `test_diag_log`、`test_diag_trace` | `bench_diag`(log 表量到 disabled==no-call within noise;trace 表量到 on/off 皆為 few% of a phase-sized span) |

第一列沒有共用 trait 統一 `FrameArena`/`List`(曾考慮做一個
`FrameAllocator`-風格 trait,後放棄):兩者的呼叫形狀本質不同
——`List` 不需要預知總數就能逐步成長,`FrameArena.alloc[T]` 需要一次要求
`n`——沒有生產呼叫點需要在兩者間透過共用介面切換(切換只發生在 benchmark 這一
層),強行做出的 trait 不會反映任何真實呼叫點的用法。定律 v2 要求的是「parity
測試 + benchmark row」,不是「必須有 trait」——這裡以逐值內容相等的 parity 檢
查(`test_diag_arena`)取代,量測仍在 `bench_diag`。

第二列的「定律」跟其他 seam 不同:不是「兩個變體算出同一個答案」,而是「停用
的那一側必須什麼都沒發生」——`log[level]`﹑`TraceBuffer.begin`/`end` 用
`comptime if` 把停用分支消去到空函式體,`test_diag_log`/`test_diag_trace` 直接
斷言停用時 ring/buffer 保持空;`bench_diag` 則把這個「什麼都沒發生」換算成數
字(log 停用 vs 完全不呼叫,誤差在雜訊內;trace 停用/啟用相對一個真實 phase
大小的 span,開銷同樣落在雜訊內)。

### 2.3 `scheduler.timers` + `procedural.tween`(Phase 17.35,2026-09-28)

計時器落在 layer 3(`scheduler`),補間落在 layer 2(`procedural`,只能引入
`geometry`/`diag`)——兩者是 17.35 同一份設計筆記(`docs/design/wave-a-services.md`)
的兩半,各自長出一個 seam:

| Seam | 檔案 | 範疇論解讀 | 定律測試 | Benchmark |
|---|---|---|---|---|
| `TimerQueue`:陣列二元 min-heap vs 二階環狀 timing wheel | scheduler/timers.mojo | 同一「到期」謂詞的兩個資料結構;`advance()` 回傳的 fired 序列以 `(due_tick, schedule 序號)` 全序比對逐位相同,與實作無關(`_HeapEntry`/`_WheelEntry` 對呼叫者不可見) | `test_timers`(seeded 隨機 schedule/cancel/advance 腳本,12 個種子逐位比對) | `bench_timers`(schedule 吞吐 + 近到期 drain 成本,N=1e2..1e6;heap 對 window 不敏感,wheel 隨散布視窗變寬而變貴,見表 3) |
| 緩動分派:`ease[kind]`(comptime 参數)vs `ease_dyn(kind)`(執行期,`comptime for` 展開的 if 鏈) | procedural/tween.mojo | 同一組 31 條 Penner 曲線的兩個求值路徑;數值逐點相等(`test_tween` 的 `ease_dyn==ease` 檢查),只有分派成本不同 | `test_tween` | `bench_tween`(同一 kind 比兩種分派,見下方數字) |
| 補間插值子:`lerp_real`/`lerp_vec3`(線性)vs `geodesic3`(PGA motor 測地線,`geometry.galie`) | procedural/tween.mojo | §3 表示函子在「補間」這個態射上的作用,呼應 `procedural/anim.mojo` 的 `BLEND_GEODESIC` 列;端點以**作用**比對(`M` 與 `−M` 是同一剛體運動,不比係數),`Tween[Motor3,...]` 的端點與 `geodesic3` 的端點在任意取樣點上的作用一致 | `test_tween`(motor 端點 BY ACTION + `Tween.value_at(0.5)` == 原生 `geodesic3(a,b,0.5)`) | `bench_tween` |

**`schedule()` 單看插入成本,heap 與 wheel 在 N≈1000–10000 之間交叉**(heap
在 N=1000 約 44 ns/op,wheel 約 57 ns/op;到 N=10000 heap 約 71 ns/op,wheel
降到約 55 ns/op)——小 N 時 wheel 的固定環狀陣列配置蓋過它 O(1) 插入的優勢。
**近到期 drain 成本(window=256 tick)則 wheel 在整個 1e2..1e6 測試範圍全勝**,
差距隨 N 擴大——N=1e6 時 heap 約 324 ns/op 對 wheel 約 43 ns/op(≈7.5×,本表
最大差距落在 N=1e5,≈8.2×),正是設計筆記點名的「wheel 優勢區是大 N、且多數計
時器接近到期」。固定 N=200000 改掃散布視窗(表 3)則誠實地展示 wheel 的代價:
視窗從 256 拉到 300000 tick(超出兩階環的 65536 tick 全域,見
`scheduler/timers.mojo` 模組註解的別名重掃代價),wheel 每 op 成本從約 22 ns
(≈9× 領先)漲到約 58 ns(≈3.6×)再到約 135 ns(≈1.6×),heap 全程持平在約
200–211 ns 左右(它本就不在乎到期時間分布)——wheel 仍領先但優勢明顯收斂,與
模組文件承認的取捨一致。

**分派成本(`bench_tween` 表 1,同一 kind 比兩種路徑,N=2e6 次呼叫)**:
comptime 分派(`ease[kind]`)完全內聯、無分支,`EASE_QUAD_IN` 約 1.2 ns/op;
執行期分派(`ease_dyn`)兩個 kind 都多付出約 10–11 ns/op 的分派開銷
(`EASE_QUAD_IN` id=1 約 +11 ns,`EASE_BOUNCE_INOUT` id=30 約 +10 ns)——與
「if 鏈長度應該正比分派成本」的預期相反(鏈尾要多比 29 次卻沒有多付這些成本),
讀作編譯器把 0..30 的稠密等式鏈降成跳轉表而非線性掃描;無論如何,comptime 分
派仍是唯一「真正不用付錢」的路徑。

### 2.4 `scheduler.events`(Phase 17.38,2026-09-28)

事件匯流排落在 layer 3(`scheduler`);seam 是 pull(共用雙緩衝 + 每個 reader
一個 cursor,production 實作)對 push(`send()` 當下就 fan-out 複製進每個訂閱
者自己的 inbox,呼應既有 `scheduler/message.mojo` 的 mailbox 風格,僅作為
seam 的對照組)。`collision.contact_events.ContactEvent` 轉接器**刻意不放進
`scheduler/events.mojo`**——`collision` 與 `scheduler` 同為 layer 3,同層引入
違反 §1 的 reach-through 規則——轉接器改放進
`tests/test_events_contacts.mojo`,在 `gameplay`(layer 5)套件出現前,這個測
試本身就是定律 v3 要求的「接上專案」生產式呼叫端。

| Seam | 檔案 | 範疇論解讀 | 定律測試 | Benchmark |
|---|---|---|---|---|
| `EventChannel`:pull 雙緩衝+cursor(`Channel[E]`)vs push fan-out(`PushChannel[E]`) | scheduler/events.mojo | 同一「遞送」態射的兩個求值策略;送出序號(`send()` 呼叫序)全序決定遞送序,與實作無關——重播同一腳本兩次逐位相同(`test_events.mojo` 的 determinism 檢查),換 seam 三個 reader(先註冊/frame 中途註冊/`update()` 後註冊)的觀察序列逐位相同(parity 檢查) | `test_events`(component:普通/parity/多數極端案例)、`test_events_gameloop`(integration:`scheduler.gameloop.FixedLoop` 真實 tick 驅動,驗證「writer 之前/之後讀」逐位不漏)、`test_events_contacts`(integration:真實 `physics.solver6.ContactScene6` 疊出的 `ContactEvent` 經轉接器送達 reader,began/ended 都收到) | `bench_events`(readers×events/frame 雙表;readers 才是 seam 分歧的軸,見下方數字) |

**未讀丟棄計數走 `diag.counters`**:pull 側的雙緩衝每次 `update()` 回收前一
週期時,任何 cursor 仍落後的 reader 都被計入本地 `dropped_unread`(仿
`diag/log.mojo`﹑`diag/draw.mojo`﹑`diag/trace.mojo` 既有的「容器自帶
`dropped: Int`」慣例),`Channel.sync_counters` 再把這個本地計數併入共用的
`diag.counters.Counters`(新 id `EVENT_DROPPED_UNREAD`)並歸零,避免重複計
數——`test_events.mojo` 的「一個從不讀取的 reader」極端案例直接斷言這條路徑
真的計數,不只是文件宣稱。push 側刻意沒有這個計數器:沒 reader 讀走的
inbox 只會變長,不會丟棄——這正是為什麼 pull 才是 production 選擇,而不是
對稱地補一個 push 並不真的需要的計數器。

**`bench_events` 表 1(1000 events/frame,readers 掃 1..32)找到真正的交叉
點**:readers=1 時 push 略勝(約 3.3 對 pull 約 5.3 ns/op——pull 每週期的固定
開銷,例如 `update()` 逐一檢查每個 cursor,在最小 reader 數時攤不掉);
readers=2 兩者打平(約 4.6 ns/op);readers≥4 起 pull 反超且差距隨 reader 數擴
大——8 個 reader 約 3.75 對 5.15 ns/op(push 慢約 1.4×),16 個約 3.57 對
11.66 ns/op(≈3.3×),32 個約 3.47 對 12.31 ns/op(≈3.5×)。pull 的 ns/op 隨
reader 數增加反而略降(固定開銷被更多次讀取攤薄),push 的 ns/op 卻比「純粹
O(readers) 次複製、單位成本應該打平」的預期漲得更多——讀作 fan-out 進多個
「各自獨立」的 `List` 一旦數量夠多,快取局部性的代價會疊加在複製本身之上,
這是設計筆記「push 成本 ∝ readers 次複製」這句話沒有拆開講的部分。表 2 固定
4 個 reader(交叉帶內)改掃 events/frame(1e2..1e6),兩者全程接近,沒有一方
持續大幅領先——與表 1 的結論一致:這個 seam 的分歧軸是 reader 數,不是事件
數。

### 2.5 `physics.body_set` 動作型別與 `physics.material` 組合模式(Phase 17.0g-2,2026-09-28)

17.0g-1 把 `statics: List[Bool]` 換成 `MotionType`(`MOTION_STATIC`/
`MOTION_DYNAMIC`)時就在文件裡點名「KINEMATIC 之後補上,只能附加不能插入」;
17.0g-2 補了 `MOTION_KINEMATIC`(17.24)與逐 body 摩擦/恢復係數 + 逐對組合模
式(17.23)。兩者都是「同一態射的三/四個實例」形狀的 seam(17.25 的睡眠公開
API 刻意**不算**新 seam——既有的 `_wake_islands`/`_update_sleep` 內部機制只是
介面化,見 ROADMAP 17.25 條目)。

| Seam | 檔案 | 範疇論解讀 | 定律測試 | Benchmark |
|---|---|---|---|---|
| body 動作型別:`MOTION_STATIC`/`MOTION_DYNAMIC`/`MOTION_KINEMATIC` | physics/body_set.mojo、physics/solver6.mojo(`_solve_pair` 等每個接觸/關節求解站台) | 同一「位姿推進」態射的三個實例;`BodySet.moves`(讀速度:dynamic∪kinematic)與`is_dynamic`(質量項/衝量:僅 dynamic)兩個謂詞的交集決定每個站台的行為——kinematic 靜止時兩個謂詞在其 slot 上的取值與 static 完全相同,退化為同一分支,逐位相等 | `test_kinematic.mojo`(KEY PARITY TEST:零速度 kinematic 與 static 在同場景跑 200 步,每個動態 body 逐位相同;整合案例含 island/sleep/broadphase seam 與序列化續跑;極端案例含 kinematic 撞靜態牆零接觸、`move_to` 巨位移仍有限、kinematic 夾擠動態體仍有限) | `bench_kinematic`(N=16..1024 個動態箱疊在 kinematic 對 static 平台上,量測 kinematic 路徑多付出的 `velocity_at` 讀取成本) |
| 材質組合模式:`COMBINE_AVERAGE`/`COMBINE_MIN`/`COMBINE_MULTIPLY`/`COMBINE_MAX`(`physics.material.combine`,PhysX「較高優先模式勝」規則) | physics/material.mojo、physics/body_set.mojo(逐 body `friction`/`friction_combine`/`restitution_combine`)、physics/solver6.mojo(`_solve_pair`、`_restitution_pass`) | 同一「逐對係數」態射的四個求值分支,選哪一支由兩個 body 各自的模式取 `max` 決定(而非某個全域開關);兩個係數相等時四個分支在該點退化為同一個數值(`combine(1,1,·,·) == 1` 對全部四模式成立,是四個分支的共同不動點) | `test_materials.mojo`(普通:`combine` 四種公式的直接算術含優先權規則;整合/極端:兩 body 係數與模式皆為 1.0 時四模式跑出逐位相同的軌跡——parity;冰面對橡膠依組合模式排序的滑行距離,配合 `MULTIPLY<=MIN<=AVERAGE<=MAX`(係數皆在 [0,1] 時恆成立)的解析證明;預設 `restitution_combine=MAX` 重現既有 `max(a,b)` 彈跳行為) | `bench_materials`(N=1024 個同時接觸,四種組合模式各跑一輪 solver step——分派開銷應與選哪個模式無關,只是分支目標不同) |

摩擦係數的「未設定」哨兵值(`BodySet.friction[i] < 0`)是恆等閘門的關鍵:
`eff_friction` 在未呼叫 `set_friction` 時用該步的 `cfg.default_friction` 頂
替,兩個 body 都走這條路徑時 `combine(mu, mu, AVERAGE, AVERAGE) == mu`(IEEE
754 下 `(x+x)*0.5` 對任意有限浮點數精確成立,不是近似),所以 17.0g-2 之前寫
好的每一個場景在沒有呼叫任何新 API 的前提下逐位重現舊行為——這正是
`.campaign/golden_test_stdout_1.1.0.txt` 這條恆等閘門守住的東西,`test_serialize`
的 blob 位元組數變大(新增五個逐 body 欄位:`motion`/`friction`/
`friction_combine`/`restitution_combine`/`can_sleep`)是本次變更唯一允許改動
的 golden 行。

`bench_kinematic` 量化的成本**只**來自 `moves(i)` 在 kinematic 側多讀一次
`velocity_at`——`combine()` 的分派本身對 static/kinematic/dynamic 一視同仁
(每一對接觸都會呼叫,不分 body 動作型別),`bench_materials` 的四列因此預期
彼此接近,證明「選哪個組合模式」不是新的可觀測成本軸,只有「有沒有 kinematic
body 需要讀它的速度」才是。**兩個 bench 都得先把箱子釘醒**
(`set_can_sleep(id, False)`)才量得出這個小差異——箱子一旦睡著,整對接觸直接被
`_impulse_inert` 跳過,睡/醒狀態的落差(整對跳過 vs 全套求解)比 kinematic 多
讀一次速度大得多,會把要量的東西完全蓋掉,`bench_kinematic.mojo` 的檔頭把這
個混淆變數寫在建場景的地方。控制掉睡眠之後,`bench_kinematic` 四個 N 的
kinematic/static 比值落在 **0.97×–1.00×**(N=16 約 0.97×、N=64 約 0.99×、
N=256 約 1.00×、N=1024 約 1.00×,`flock` 鎖下的正式記錄跑)——一次額外的
`velocity_at` 讀取在雜訊範圍內,不是可觀測的成本軸;`bench_materials` 的四個
組合模式在 N=1024 落在 14.1–15.6 M ns/step(約 1.1× 展延,同量級雜訊),印證
「選哪個模式不改變求解成本」。`bench_sleep_wake` 印證 `wake(id)` 的 O(bodies)
宣稱:N 每擴大約 4 倍(16→64→256→1024),單次 `wake` 成本分別約
37/128/440/2308 ns,倍率 3.5×/3.4×/5.2×——與體數大致線性成長一致,不是
O(island size) 或常數(最後一段倍率略高於線性,讀作單次呼叫量測在 ns 級別本
身的雜訊,`bench_sleep_wake.mojo` 每點已是 3000 次重複的總時間平均)。

### 2.6 可微 / 批次接觸求解器(Phase 17.20 / 17.18,2026-09-29)

| Seam | 檔案 | 範疇論解讀 | 定律測試 | Benchmark |
|---|---|---|---|---|
| 接觸求解的係數環:`RealF` / `DualReal` / `DualBatch` / `RevReal` / `BatchReal[W]`(`SolverField`) | geometry/field.mojo、physics/diffsolver.mojo | 同一個「一幀」態射在五個係數環上的像;分支全部改寫為指示函數 `positive`(導數定義為 0 = 接觸開關的次梯度約定),所以批次的各 lane 走不同分支仍是同一條指令流 | `test_diffsolver`(`RealF` 對 `ContactScene6`:落下 / 三球疊 / 滑轉滾;DualReal / DualBatch / RevReal / 中央差分四方梯度一致;批次 lane 對純量世界 ≤1e-4;NaN 世界不外溢;無接觸 = 精確彈道、μ=0 不自轉、重合球心有限、靜止高度對落下高度導數為 0) | `bench_diffsolver`(世界佈局:純量循序 / SIMD 8 lane / lane × 核,N=1..4096;梯度:FD / DualReal / DualBatch / RevReal,NP=1..16) |
| 解算器實作:`ContactScene6`(具體 `Vec3`/`Real`,全功能)vs `SphereWorld[F]`(可微子集:動態球 + 靜態平面) | physics/solver6.mojo + contact6.mojo、physics/diffsolver.mojo | 同一接觸演算法的兩個實作;子集邊界寫在 diffsolver 檔頭 | 同上(parity 容差 1e-4..5e-3,非逐位:運算分組不同) | 同上 |

### 2.7 反射 / 型別註冊表(Phase 17.11,2026-09-29)

| Seam | 檔案 | 範疇論解讀 | 定律測試 | Benchmark |
|---|---|---|---|---|
| 序列化:反射驅動(`ecs.schema`,單筆自描述 / 批次)vs 手寫 | ecs/schema.mojo | 同一「值 → 位元組 → 值」往返態射的兩個實作;反射版的 schema 由編譯器的欄位表生成,手寫版的欄位清單由人維護。往返皆為恆等(逐位) | `test_schema`(round-trip 逐位、反射 == 手寫、ECS backend 互換後逐位相同、V1→V2 按名稱遷移) | `bench_schema`(N=16..65536:單筆 / 批次 / 手寫的 ns 與 B per value) |

### 2.8 接觸求解的裝置實作(Phase 17.17,2026-09-29)

| Seam | 檔案 | 範疇論解讀 | 定律測試 | Benchmark |
|---|---|---|---|---|
| 著色接觸求解:CPU(`ContactScene6.step(cfg.colored)`,串行 / 色內多核)vs GPU(`GpuContactSolver`) | physics/solver6.mojo、physics/contact6.mojo、physics/gpu_contact.mojo | 同一排程(色內 Jacobi、色間 Gauss-Seidel)在兩個裝置上的實作;GPU kernel 呼叫同一個 `QuatBody6` 的方法。parity 非逐位:乘加收縮不同,且箱堆接觸裁剪是離散分支(系統對 1e-7 擾動混沌),故以 CPU 自身擾動發散為界 | `test_gpu_contact`(四場景 GPU−CPU ≤ 2× CPU 自身發散 + 靜止狀態 by action + 接觸數 / island 數相同;單體無接觸;拒絕關節) | `bench_gpu_contact`(N=64..4096:CPU 串行 / 多核 / GPU 整幀,GPU 拆 上傳 / 計算 / 下載 / CPU 簿記) |

### 2.9 動畫圖節點(Phase 17.6,2026-09-29)

| Seam | 檔案 | 範疇論解讀 | 定律測試 | Benchmark |
|---|---|---|---|---|
| 混合節點家族:1-D 空間 / 2-D gradient band / 遮罩層 / 加法(× 混合模式 LINEAR / DLB / GEODESIC) | procedural/anim_graph.mojo、procedural/anim.mojo(`blend_bone`) | 每個節點是姿勢的凸組合;邊界權重為投影(恰回傳某一輸入)——節點家族在頂點上的限制都是恆等 | `test_anim_graph`(樣本點上 = 該 clip 逐位、遮罩 0/1、加法權重 0;2-D 權重非負且和為 1;NaN clip 權重 0 不外溢) | `bench_anim_graph`(骨數 16/64/256 × 節點組合 × DLB/geodesic) |

### 2.10 角色 IK(Phase 17.3,2026-09-29)

| Seam | 檔案 | 範疇論解讀 | 定律測試 | Benchmark |
|---|---|---|---|---|
| 兩段鏈 IK:解析(`two_bone`)vs 迭代(`fabrik`) | procedural/ik.mojo | 同一「末端到目標且保骨長」映射的閉式與不動點迭代兩實作;選哪個膝位置由 pole(解析)或起始姿勢(迭代)決定,末端與骨長相同 | `test_ik`(末端相同、骨長保持;極端:不可達、目標在根、pole 共線、零長骨、NaN) | `bench_ik`(解析 vs FABRIK 同腿;FABRIK 4/16/64 關節) |

### 2.11 主動布娃娃驅動(Phase 17.2,2026-09-29)

| Seam | 檔案 | 範疇論解讀 | 定律測試 | Benchmark |
|---|---|---|---|---|
| 關節驅動:無驅動 vs `AngularDrive`(強度 0..1) | physics/joints6.mojo、physics/solver6.mojo、gameplay/ragdoll.mojo | 驅動器是疊加在關節約束上的軟態射;力矩上限為 0 時為恆等(零衝量),逐骨權重 0/1 在姿態混合上是投影 | `test_ragdoll`(零上限 == 無驅動逐位;混合權重 0 == 動畫、1 == 物理) | `bench_ragdoll`(N 條腿,驅動 vs 僅關節) |

### 2.12 接觸修改與關節斷裂(Phase 17.26 / 17.29,2026-09-29)

| Seam | 檔案 | 範疇論解讀 | 定律測試 | Benchmark |
|---|---|---|---|---|
| 接觸是否生效 / 如何作用:靜態過濾(`set_filter`)vs 動態規則(`ContactRule`) | physics/contact6.mojo、physics/solver6.mojo | 同一「接觸謂詞」的兩層;不匹配任何接觸的規則(與零速輸送帶)是恆等 | `test_contact_rules`(不匹配規則 == 無規則逐位) | `bench_contact_rules`(無規則 / 全匹配 / 8 條不匹配) |
| 關節負載估計:最後子步 vs 逐子步峰值 | physics/joints6.mojo(`sample_loads`、`check_breaks`) | 同一負載量的兩個取樣;穩態一致(m·g),衝擊時只有峰值取樣看得到 | `test_joint_break`(懸掛質量 = m·g;扭轉 hinge 只在峰值取樣下斷) | `bench_contact_rules`(有 / 無閾值) |

### 2.13 力場、浮力、繩索、地形變形(Phase 17.27 / 17.28 / 17.41 / 17.30,2026-09-29)

| Seam | 檔案 | 範疇論解讀 | 定律測試 | Benchmark |
|---|---|---|---|---|
| 風速來源:常數 vs `WindGrid` 取樣 | physics/fields.mojo | 常數場是網格取樣態射的常數截面;三線性插值對常數網格是恆等 | `test_fields`(常數網格 == 常數風逐位) | `bench_fields` |
| 浸沒體積:閉式(軸對齊盒、球)vs 中點積分 | physics/fields.mojo | 同一體積泛函的精確與數值求積 | `test_fields`(11 水位差 < V/16) | `bench_fields`(8³ / 16³ vs 球閉式) |
| 繩索:XPBD 1D 鏈 vs 距離關節剛體鏈 | physics/rope.mojo、physics/joints6.mojo | 同一懸鏈線的兩個離散化 | `test_rope`(兩者與解析下垂 5% 內) | `bench_rope` |
| 高度場邊界:區塊摘要增量 vs 全表重掃 | collision/trimesh.mojo、collision/collider_set.mojo | 同一 min / max 歸約的兩種結合律分組(max 的結合律 ⇒ 結果逐位相同) | `test_terrain_deform`(每次編輯 AABB 逐位相同) | `bench_terrain_deform` |

### 2.14 物理 LOD 與決定論回放(Phase 17.31 / 17.39,2026-09-29)

| Seam | 檔案 | 範疇論解讀 | 定律測試 | Benchmark |
|---|---|---|---|---|
| 求解品質:全品質 vs LOD(凍結 / iters / substeps) | physics/solver6.mojo(`freeze`)、physics/lod.mojo | 同一不動點迭代在不同 iters / substeps 下的實例;凍結 = 動作型別的暫時投影到 STATIC,解凍是其逆 | `test_lod`(全覆蓋 LOD + 天花板預算 == 原解算器逐位;解凍後速度逐位相同) | `bench_lod`(iters 1–8 成本 vs 誤差;凍結一半) |
| 回放:全程重跑 vs 快照 + 短重跑 | gameplay/replay.mojo | `sim_tick` 的 n 次合成;快照是中間狀態的忠實表示,故從任一快照續合成等於從頭合成 | `test_replay`(8 個目標 tick 逐位相同;分歧定位) | `bench_replay`(尋位延遲 vs 快照間隔) |

### 2.15 存檔(Phase 17.40,2026-09-29)

| Seam | 檔案 | 範疇論解讀 | 定律測試 | Benchmark |
|---|---|---|---|---|
| 保存路徑:schema 存檔(選擇性、跨版本)vs 決定論全狀態快照 | gameplay/save.mojo、physics/serialize.mojo | 存檔是快照的投影(只保留選定欄位);在投影涵蓋的欄位上兩條「存 → 讀」路徑相等 | `test_save`(涵蓋欄位逐位相同;V1 → V2 按名稱) | `bench_save`(位元組與時間,64 / 1024 體) |

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
