# ROADMAP:補缺路線圖(Now / Next / Later)

> 2026-07-10 制定。依據:[SOTA_GAP_ANALYSIS.md](SOTA_GAP_ANALYSIS.md)。
> 主線已定:**「GA 原生物理補齊」** —— 用引擎的差異化(motor/screw/forque)去填最大 SOTA 缺口
> (角動力學 + 現代 solver),一石二鳥。
> 架構法則不變(`CATEGORY.md`):**每個新 seam 實作必附 parity test**;每個效能主張必附
> benchmark 數字與 baseline(correctness gates do not see speed)。
>
> **狀態(2026-07-13):Phase 1–4 全部完成。** Phase 4 六節(4.0 benchmark 覆蓋、
> 4.1a swept/TOI CCD、4.1b LGVCI、4.2 reverse-mode AD tape、4.3 VBD、4.4 ECS
> observers + 延遲 set、4.5 bench_ga flake 根因)各節進度註見下;新增 6 個 seam
> 變體皆附 parity test + benchmark row(CATEGORY.md §2 覆蓋矩陣)。stretch 項
> (learned physics、GPU rigid)明確留待後續。
>
> **狀態(2026-07-19):Phase 6(soft body,6.1–6.12)全部完成** —— restitution、
> 球/膠囊形狀、Featherstone 縮座標鏈、islands 平行、軟-剛 CCD、軟接觸摩擦、O(n) ABA、
> 場景序列化、島內著色平行、樹狀關節,皆附自驗 gate + 誠實行。wgpu-mojo 依賴解除、
> `pixi run` 復活。
>
> **重整(2026-07-22):物理演算法核心已達競爭級 —— 焦點轉向「接線 + 表現力 +
> gameplay/程序化基礎 + 分離的外殼」。** 前瞻路線見下方 [前瞻路線總覽](#前瞻路線總覽2026-07-22-重整)
> (Phase 7–12)。

---

## Phase 1 — Now:角動力學的 GA 原生實作

最大缺口 × 最強差異化。`rigidbody.mojo` docstring 明言 angular 被 deferred 的原因是
「缺接觸點」,所以順序固定:manifold 先行。

### 1.1 Contact manifold 生成(一切的前置)

> 進度:✅ 2026-07-10 `collision/manifold.mojo` — `ContactManifold[dim]` + `ManifoldNarrowPhase` seam + `AABBManifoldNarrowPhase`(2D 2 點 / 3D 4 點),`tests/test_manifold.mojo` 34/34(含與 `AABBNarrowPhase` 的 normal/depth parity)。
> 進度:✅ 2026-07-10 `geometry/clip.mojo`(reference/incident edge + Sutherland–Hodgman)+ `SATManifoldNarrowPhase`/`OBBManifoldNarrowPhase`(面-面 2 點、角-面 1 點,各點深度),test_manifold 53/53,與 `sat_collide`/`obb_collide` normal/depth parity。
> 進度:✅ 2026-07-10 3D EPA(三角面 polytope + horizon 擴張)+ witness points(barycentric 還原 A/B 最深點)+ `GjkManifoldNarrowPhase`,`gjk_collide` 3D 不再回 zero depth。test_manifold 71/71(立方體對穿 depth=0.5/1.75 與軸路徑 parity、`point_a−point_b == normal·depth`)。**1.1 全部完成。**
- **改動**:`collision/narrowphase.mojo` 的 `Contact[dim]` 升級為含接觸點
  (points + per-point depth);box-box clipping(Sutherland–Hodgman 式 reference/incident face)、
  GJK witness points;順帶補 3D EPA 真實深度(現況 `epa.mojo` 3D boolean-only)。
- **Seam**:`NarrowPhase` trait 擴充或並行新 trait(`ManifoldNarrowPhase`),舊 narrowphase
  照舊可用 —— 不破壞既有 parity tests。
- **驗收 gate**:
  - parity:manifold 的 normal/depth 與既有各 narrowphase 一致(誤差 ε 內)。
  - 幾何正確性:box-on-box 靜置產生 4 點(2D 為 2 點)接觸;斜面接觸點位於重疊區內。
  - 3D EPA:立方體對穿測例回非零深度,與 SAT 路徑 parity。

### 1.2 Screw dynamics 接進 contact solver

> 進度:✅ 2026-07-10(第一半)`physics/rigid6.mojo` — `Inertia3`(box/sphere 主軸慣性)+ 兩套 parity 表示:`QuatBody6`(世界系 Newton-Euler + 四元數指數)vs `ScrewBody6`(Motor3 pose + 體座標 twist bivector,Lie-Poisson Euler 方程 + 閉式 motor 指數步進);forque 以 world force/torque 進 seam、衝量→twist 經 `I⁻¹[r×j]`。`tests/test_rigid6.mojo` 15/15:彈道/球慣性自旋/非對稱箱穩定自旋/點衝量/恆定扭矩,全部**比 action** parity + |L|、能量守恆 gate。> 進度:✅ 2026-07-10(第二半)`physics/solver6.mojo` — `Body6` trait(表示無關的求解介面:`velocity_at`/`apply_impulse`/`angular_factor`)+ `ContactScene6[B]`:重力 → `AABBManifoldNarrowPhase` 接觸點 → accumulated-impulse Gauss-Seidel(Baumgarte bias)→ pose 步進。`tests/test_solver6.mojo` 13/13:雙箱堆疊在兩種表示下同高度靜置(parity < 5e-3)、effective-mass 項跨表示 parity。**1.2 完成。**
> 除錯記錄:(a) 裸 `List[Vec3]` realloc 毀資料(gjk.mojo 已記載的 nightly 陷阱)導致箱子穿地 — 一律 struct 包裝;(b) 逐點衝量注入微小 rocking ω(≈4e-3 rad/s,靜置後為 solver null mode 不衰減)— 已知限制,gate 改驗有界性;Phase 2 的 block solve / warm-starting / sleeping 是正解。
> 未解懸案:`bench_ga.mojo` 有 ~50-70% 機率在程式收尾時死於 runtime teardown(libAsyncRT 棧,無符號;`--debug-level` 建置在此 nightly 連結失敗)。先於本輪改動存在、不影響任何測試;容量預留無效 → 疑似更深的 SIMD3 列表損毀或 nightly runtime bug。已開背景任務全面稽核裸 `List[SIMD3]`;`pixi run benchmark` 遇當機重跑即可(報告為原子性覆寫)。
- **改動**:`physics/screw.mojo` 的 `ScrewBody`(Motor3 pose + Screw3 velocity)補上:
  - inertia(bivector 空間的慣性映射,PGAdyn §momentum 公式)
  - forque(force+torque 合一的 bivector,[PGAdyn](https://bivector.net/PGAdyn.pdf))
  - 接觸衝量的 motor 形式(衝量 → Screw3 velocity 增量,經 inertia inverse)
- **Parity gate(公平比較準則)**:與傳統 quat + inertia-tensor 參考實作**比 action 不比係數**
  (M 與 −M 是同一剛體運動):同初始條件、同接觸序列,末態 pose 作用於測試點集的誤差 < ε。
  新增傳統路徑作為 baseline 也是一個 seam 實作,雙向受益。
- **Benchmark gate**:ns/body/step 對 baseline 路徑,數字進 `BENCHMARK_REPORT.md`;
  注意 `@always_inline`(歷史教訓:缺 inline 曾造成 25× 慢)。

### 1.3 Lie-group / variational integrator seam

> 進度:✅ 2026-07-10 `physics/integrator6.mojo` — `SpinIntegrator` seam(pose 一律走閉式 motor exp,ω 更新可換):`EulerSpin` / `Rk2Spin` / `MidpointSpin`(隱式中點,定點迭代)。`tests/test_integrator6.mojo` 9/9(球慣性三者全等、小步長交叉 parity、Dzhanibekov 20k 步:中點 E 漂移 3.6e-5 vs Euler 1.3e-2)。`benchmarks/bench_rigid6.mojo` 入 report:QuatBody6 65.8 vs ScrewBody6 89.3 ns/step(GA 1.36×);1e5 步漂移 Euler 6.4e-2、RK2 2.1e-5、隱式中點 3.0e-5。真正的 LGVCI 變分積分器留待後續(現為隱式中點,已誠實標注)。**Phase 1 全部完成。**
- **改動**:`physics/integrator.mojo` 增加 integrator seam:semi-implicit Euler(現有)、
  Lie-group screw step(現有 `step_screw`)、variational(RATTLE 式或 LGVCI 方向)。
- **驗收 gate**:
  - 能量長時穩定性 benchmark:自由旋轉剛體(Dzhanibekov 測例)10⁶ 步的能量漂移曲線,
    三種 integrator 同圖比較。
  - 動量守恆:無外力系統動量誤差 < ε。

---

## Phase 2 — Next:現代 solver 公式 + 碰撞管線升級

### 2.1 Sub-stepped soft-constraint solver(Box2D v3 "Soft Step" / TGS 系)

> 進度:✅ 2026-07-10(核心)`ContactScene6.step_soft` — 完整 Box2D v3 子步結構:每幀碰撞一次 → n 子步 {重力 → **warm start**(跨幀+每子步,`−impulseScale·acc` 為配對衰減項)→ soft 掃(Solver2D 係數 ω/biasRate/massScale/impulseScale)→ pose → **relax**(去 bias 能量)};**Coulomb 摩擦**(雙切向、摩擦錐 μ·λₙ);**body-frame local anchors**(逐點分離量隨當前姿態重算)。`tests/test_softstep6.mojo` 11/11。
> 量化:單箱靜置 |v|<1e-4、自旋 4e-7(比 plain step 的 4e-3 好 4 個數量級);凍結旋轉的 6 箱塔 1000 步站到機器精度(x 漂移 ~1e-11);100:1 質量比不壓爆。
> 進度:✅ 2026-07-11 `collision/manifold.mojo` 增 `box_box_manifold` — **3D 旋轉箱 manifold**(15 軸 SAT、面軸 5% 偏好防抖、reference/incident 面四邊形裁切取最深 4 點、edge-edge 單點);`ContactScene6._collect_pairs` 改用之(經 `Body6.act` 取世界軸,表示無關)。`test_manifold` 91/91(軸對齊 parity、傾斜箱接觸面偏向下沉邊 = 回復幾何)。
> **2.1 完整 gate 達成**:活旋轉 6 箱塔 1000 步站穩(高度 ±0.02、頂箱 lean < 0.01、自旋收斂 ~1e-6)+ 100:1 質量比 600 步不壓爆不滑落(`test_softstep6` 13/13)。**2.1 完成。**
- **改動**:`physics/solver.mojo` 的 `ContactSolver` seam 加第四個實作(sub-stepping +
  soft constraints),依據 [Solver2D 方法論](https://box2d.org/posts/2024/02/solver2d/) 與
  [Small Steps](https://mmacklin.com/smallsteps.pdf)。
- **驗收 gate**:stacking(10 箱塔 1000 步不倒)、mass-ratio(100:1 不爆)、long-chain
  場景 benchmark,四個 solver 同表對照(對齊 Solver2D 的比較法)。

### 2.2 Joints 最小集 + islands + sleeping + warm-starting

> 進度:✅ 2026-07-11(joints)`Joint6`(ball / distance / hinge)進 `solver6.mojo` 的 soft substep 迴圈(等式約束無 clamp、與接觸共用 warm start / soft 係數 / relax);`Body6` trait 增 `omega_world`/`apply_angular_impulse`/`angular_only_factor`。`tests/test_joints6.mojo` 8/8:ball 擺週期 123.0 幀 vs 物理擺解析 122.2(0.65%)、distance 擺 120.0 vs 120.4(0.35%)、quat/screw 週期 parity 完全一致、hinge 面外運動穩態抑制到 2e-7、漂移 1.6mm。warm-starting 已於 2.1 完成。
> 進度:✅ 2026-07-11(islands + sleeping)union-find 連通分量(contacts + joints,static 不併島)、島級喚醒(任一成員醒 → 全島醒)、能量閾值休眠(|v|<0.01、|ω|<0.05 持續 0.5s,全島同眠、`halt()` 歸零)。`tests/test_sleep6.mojo` 13/13:雙塔 2 島、35 幀入睡、睡姿 bit-frozen 100 幀、落箱撞擊喚醒後全塔再眠、雙次執行 bit-identical。**2.2 完成。**
- **改動**:新 `physics/joints.mojo`(distance、revolute/hinge 起步,GA 形式:joint 即
  motor 空間的約束);`step.mojo` 加 island 分割(broadphase pair graph 的連通分量)、
  sleeping(能量閾值)、warm-starting(manifold 持久化的衝量快取)。
- **驗收 gate**:單擺/雙擺週期 vs 解析解;island 數與喚醒行為的確定性測試;
  warm-start 前後收斂迭代數 benchmark。

### 2.3 持久化 broadphase + speculative CCD 第一步

> 進度:✅ 2026-07-11(speculative CCD)`_collect_pairs` 速度比例 margin 膨脹偵測(`SPEC_BASE + (|va|+|vb|)·dt`)、深度回扣為負值接觸,交由 solver 既有 `d<0 → bias=−d/h` speculative 分支。`tests/test_ccd6.mojo` 8/8:20 m/s 快落精準攔在表面(min_y 0.2495)、50 m/s 子彈 vs 0.05 薄牆**不穿透中平面**(暫態過衝 8.5cm 後排出、末速 50→4.3)、靜置高度零回歸(0.2497)。真子彈級保證(swept/TOI, Jolt LinearCast)列為後續強化。
> 進度:✅ 2026-07-11(持久化 broadphase)`collision/bp_dbvh.mojo` — Box2D 式 dynamic tree(fat AABB ±0.1、逃逸才 remove+reinsert、surface heuristic 選 sibling)+ **fat-overlap pair 快取**(移動者局部修復、tight 過濾發射 → 與 BruteForce 完全 parity)。`tests/test_dbvh.mojo` 3/3(30 幀抖動逐幀 pair-set parity、teleport、region query);`benchmarks/bench_dbvh.mojo`:相干工作負載 N=4096 **70µs vs 全重建 18.9ms/frame(269×)**。**2.3 完成、Phase 2 全部完成。**
- **改動**:`collision/broadphase.mojo` 加 incremental BVH(refit + rotation)與 pair cache,
  取代 `step.mojo` 每步重建;narrowphase 加 speculative margin(CCD 的第一階段,Jolt/Box2D 做法)。
- **驗收 gate**:parity(pair 集合與 BruteForce 一致);benchmark:N=10⁴ 動態物體
  ns/step vs 重建路徑;子彈穿薄牆測例(speculative margin 攔住)。

---

## Phase 3 — Later:四縱深(已確認全保留;建議依此序)

### 3.1 可微模擬(與 GA 核心契合度最高)

> 進度:✅ 2026-07-11 `Field` trait 擴充(`const`/`value`,tape 前置)+ **`DualBatch`**(SIMD 4 lane = 4 個導數方向一次算)+ `physics/diffsim.mojo`(Field-generic 拋體 rollout:重力+阻力+smooth 地面 penalty)。`tests/test_diffsim.mojo` 9/9:對偶 vs 中央差分 **穿過彈跳** parity(1.8123 vs 1.8124)、batch lanes ≡ 逐一 dual(1e-5)、梯度下降控制任務收斂(loss 9e-7,一次 rollout 得全梯度)、**GA 原生 AD**(`GMV[3,0,1,DualReal]` motor sandwich 導數精確 1.0)。實地重現並記錄接觸梯度高原(settled 軌跡 dy/dv≈0,同 Brax 病態梯度)。reverse-mode tape 與 learned physics(Clifford NN 升級)留後續。
- `GMV[…,DualReal]` forward-mode 擴到 **batch forward**(SIMD lane = 多方向導數)或
  reverse-mode;目標:對標 [Warp](https://developer.nvidia.com/blog/announcing-newton-an-open-source-physics-engine-for-robotics-simulation/)/MJX
  的 differentiable rollout(gradient through contact 是已知難點,先做 smooth contact)。
- `experiments/exp_clifford_nn.mojo` 升級為 learned-physics 原型(GATr/CGENN 方向,
  [arXiv:2305.18415](https://arxiv.org/abs/2305.18415))。
- **Gate**:d(末態)/d(初速) 與有限差分 parity;一個梯度下降收斂的 toy 控制任務。

### 3.2 GPU 物理(Mojo kernels)

> 進度:✅ 2026-07-11 `physics/gpu_cloth.mojo` — **引擎首個 GPU 常駐物理**:XPBD 布料(gather 式 Jacobi = 無 atomics、決定性;SoA 分量緩衝;釘頂行 + 地板)4 kernels(predict/jacobi/apply/finalize),`has_accelerator` 守衛(無 GPU 主機照常編譯、測試空過)。`tests/test_gpu_cloth.mojo` 5/5:**CPU/GPU parity 2.4e-6**(60 步×8 迭代×1024 粒子)、下垂/地板/約束長度物性 gate。`benchmarks/bench_gpu_cloth.mojo`(RTX 3060):16k 粒子 GPU 0.41 vs CPU 3.39 ms/step(**8.3×**),65k 粒子 GPU 1.08 ms/step(≈CPU 4k 的價格)。後續:VBD 原型、GPU rigid。
- 先做粒子/XPBD cloth 或 [VBD](https://arxiv.org/pdf/2403.06321) 原型(mojo-gpu-fundamentals);
  領域已 GPU-first,且這是 Mojo 的原生賣點(無任何已知 Mojo 物理引擎 = first-mover)。
- **Gate**:CPU/GPU 同 seed parity(ε 內);粒子數 scaling benchmark(10⁴→10⁶)。

### 3.3 ECS table stakes

> 進度:✅ 2026-07-11(relationships + command buffer)`ecs/relations.mojo` — 一級公民實體關係(flecs pair 式):正/反向索引、wildcard `(rel,*,*)` 枚舉、per-entity touch 索引使 despawn 清理為局部操作、插入序決定性;`ecs/commands.mojo` — 結構變更延遲緩衝(despawn+關係編輯,sync point 依記錄序執行)。`tests/test_relations.mojo` 19/19(方向性、雙向清理、generation 保留、迭代中延遲 despawn、雙次執行枚舉一致)。待補:push-based observers(reactive backend 正式化)、延遲 component set(需型別抹除)。
- Relationships 一級公民(flecs v4 級,wildcard query)、observers 正式化
  (`reactive_backend` 升級為 push-based)、structural-change command buffer。
- **Gate**:relationship query parity vs 手寫 join;observer 觸發順序決定性測試。

### 3.4 最低限渲染 demo

> 進度:✅ 2026-07-12 wgpu-mojo 已接入(`pixi add --git`;nightly 升至 2026071006 以匹配其 mojopkg,**全套測試零回歸**;`setup-native.sh` 安裝 libwgpu_native v29 + callback 橋 + glfw)。`examples/08_wgpu_motor_skinning.mojo` — **糖果紙效應上屏**:雙 ribbon(綠 = motor DLB、紅 = LBS)實時顯示鏈上各站的蒙皮寬度,CPU 用引擎 `skin_motor`/`skin_lbs` 蒙皮、uniform 陣列直傳(無矩陣上線,LookMaNoMatrices 方向);240 幀自動關閉、headless 優雅跳過。機器可驗證證據:θ=2.19 時 DLB 寬 0.300 vs LBS 0.138;θ=−2.74 時 LBS 塌至 0.063(1/5)而 DLB 恆持 0.300。**3.4 完成 —— 路線圖三階段全部完成。**
> 附帶:`run_benchmarks.sh` 加 `run_bench` 重試(bench_ga teardown flake 在新 nightly 仍在,稽核 chip 已開)。
- 用 **wgpu-mojo**(`pixi add --git https://github.com/Hundo1018/wgpu-mojo`)建薄渲染層,
  跑 `examples/07_motor_skinning` 視覺化;可順著
  [LookMaNoMatrices](https://enkimute.github.io/LookMaNoMatrices/) 的無矩陣管線做
  (motor 直達 shader,不經 mat4)。取代 `systems/renders` 的廢棄 Python pygfx 實驗。
- **Gate**:render gate —— 截圖並人眼確認 candy-wrapper 修正可見(LBS vs DLB 並排)。
- 明確不追 GPU-driven rendering(Nanite 級)。

---

## Phase 4 — 下一階段:未竟事項收攏(2026-07-13 制定)

> 前提:Phase 1–3 全部完成(見上)。本階段把各節「留後續/待補」正式排程。
> 同時新增**架構定律 v2**(詳 [CATEGORY.md](CATEGORY.md) §2):任何 seam 的所有變體
> 必須**同時**具有 parity 測試與 `BENCHMARK_REPORT.md` 對應 row —— 缺一不收。
> 4.0 為不變式基線、先行;4.1–4.5 僅依賴已完成 seam,可並行;
> 建議序 4.1 → 4.2 → 4.3 → 4.4(SOTA 價值 × GA 差異化排序),4.5 背景進行。

### 4.0 Benchmark 覆蓋補齊(不變式基線)

2026-07-13 盤點:18 個相對方法 seam 中 5 個有 parity 測試而無 benchmark:

1. `SceneQuery`(brute/bvh/grid/tree):`bench_queries.mojo` 已寫好未接線 → 接進 `run_benchmarks.sh`。
2. `ManifoldNarrowPhase` 4 變體:新 `bench_manifold.mojo` — ns/pair 完整接觸面生成(solver 實際付的成本),對照 boolean narrowphase 基線。
3. CGA narrowphase(`CgaSphereNarrowPhase`/`CgaShapeNarrowPhase`):入 `bench_collision.mojo` narrowphase 表 — 代數 vs 解析路徑,量化 GA 抽象成本。
4. motor vs matrix 階層傳播:`bench_transform.mojo` 加 `propagate_motor` vs `propagate_full` 同 N 節點階層(`bench_ga` 只測單次 apply/compose)。
5. AD:新 `bench_diffsim.mojo` — (a) 1 次 `DualBatch` rollout(4 導數方向)vs 5 次 `RealF` 有限差分 rollout;(b) motor sandwich `GMV` vs 特化 `Multivector` 吞吐。

- **驗收 gate**:CATEGORY.md 覆蓋矩陣 benchmark 欄無空格;新章節入 report。

> 進度:✅ 2026-07-13 五缺口全補(上輪 session):bench_queries 接線、`bench_manifold.mojo`(接觸面 vs boolean 同 pair 對照)、CGA rows 入 narrowphase 表、`bench_transform` 加 motor vs matrix 階層傳播(motor 勝)、`bench_diffsim.mojo`(DualBatch/GMV 表)。矩陣 benchmark 欄無空格。**4.0 完成。**

### 4.1 物理保真度:swept/TOI CCD + LGVCI

> 進度:✅ 2026-07-13(swept/TOI)`collision/toi.mojo` — `swept_box_toi`:OBB 對 OBB **精確** 15 軸 swept SAT 線性掃掠(entry/exit 區間交集,免正規化、免迭代);`ContactScene6._ccd_advance` — substep pose 推進前對「相對位移 > pair 最薄半厚一半」的高速對做 linear cast,夾限至 TOI(−0.01 回退),慢速路徑逐位不變。`step_soft(..., ccd=True)` 開關。`test_ccd6` 20/20:TOI 解析解(正面 t=0.25 精確、45° 旋轉目標、角色對稱)、**50 m/s 子彈零過衝**(max x = −0.1514,表面 −0.15;speculative-only 過衝至 −0.065)、rest height 與 speculative 路徑 parity 1e-6 內逐位一致。`bench_ccd`:speculative 膨脹 manifold 443 vs swept TOI cast **114 ns/pair**(掃掠免裁切,3.9× 便宜)。矩陣入 CATEGORY.md §2。
- **swept/TOI 真子彈 CCD**(Jolt LinearCast / conservative advancement 方向):
  在 speculative margin(2.3)之上加 swept 路徑,窄相對高速 pair 求 TOI、子步推進。
  - **Gate**:50 m/s 子彈 vs 0.05 薄牆**零過衝**(speculative 現況暫態過衝 8.5cm);
    靜置高度與堆疊測例零回歸(`test_ccd6` 擴充)。
  - **Benchmark gate**:TOI vs speculative ns/pair 同表(高速場景),入 report。
> 進度:✅ 2026-07-13(LGVCI)`physics/integrator6.mojo` — `LgvciSpin`:Moser–Veselov DMV(`F·J_d − J_d·Fᵀ = h·skew(Π)`,J_d 由主軸慣性、F 以旋轉向量不動點解出 `f ← f + I⁻¹(hΠ − ax(F·J_d − J_d·Fᵀ))`、5 次收斂率 O(h|ω|);`Π' = FᵀΠ` 精確旋轉傳輸、pose 走閉式 motor exp)。`test_integrator6` 16/16(球慣性 ω 精確保持、短程與中點 parity、Dzhanibekov 20k 步 E 3.1e-5 / L 1.2e-5,勝 Euler 400×+)。`bench_rigid6` 四 integrator 同表:LGVCI 183 ns/step(中點 2.6×)、1e5 步 E 1.3e-4 / L 4.3e-5(RK2/中點同屬 roundoff 積累帶、Euler 6.4e-2)。**4.1 完成。**
- **LGVCI 變分積分器**:`SpinIntegrator` seam(`physics/integrator6.mojo`)第四實作
  (現隱式中點已誠實標注非變分)。
  - **Gate**:Dzhanibekov 10⁶ 步能量漂移曲線四 integrator 同圖;動量守恆 < ε。
  - **Benchmark gate**:入 `bench_rigid6` 積分器表(ns/step + 1e5 步漂移)。

### 4.2 可微模擬深化:reverse-mode AD tape

> 進度:✅ 2026-07-13 `geometry/field.mojo` — `Tape`(append-only 運算記錄 + `grad()` 反向掃,一次掃出全部輸入的 adjoint)+ `RevReal`(Field 第四成員;**off-tape 常數方案**:`const`/`zero` 無 tape 可談 → idx=−1 + `Optional[TapePtr]`(本 nightly UnsafePointer 不可 null),混合運算向帶 tape 運算元借指標)+ `rev_seed` helper。`physics/diffsim.mojo` 加 `rollout_ctrl`(N 參數推力脈衝 rollout,與 rollout2 共用 `_step2`)。`test_diffsim` 20/20:穿彈跳三方 parity(reverse 1.8122891 vs dual 1.812278 vs FD 1.81236)、同 tape 二次掃(d(y)/d(vy0))、GMV[3,0,1,RevReal] motor sandwich 導數精確 1.0、**8 參數**(>4 lanes)reverse ≡ 分塊 DualBatch(1.1e-5)≡ FD。`bench_diffsim` 新 8 參數表:tape 記錄開銷 ~19×/step 但成本對 N 平坦(2→8 參數 reverse 持平、DualBatch ×2.9、FD 線性),交叉點外推 ~N=76;數字誠實入 report。**4.2 完成**(learned physics stretch 未做)。
- `Field` trait(`geometry/field.mojo`,`const`/`value` 已為 tape 前置)加 reverse-mode
  實作:tape 記錄 + 反向掃;梯度方向數不再受 SIMD lane 限制。
- **Gate**:reverse vs forward(`DualBatch`)vs 中央差分三方 parity(穿彈跳);
  既有 `test_diffsim` 全綠。
- **Benchmark gate**:N 參數梯度成本 —— reverse(1 rollout + tape)vs DualBatch
  (⌈N/4⌉ rollouts)vs 差分(N+1 rollouts),入 `bench_diffsim`。
- Stretch:`exp_clifford_nn.mojo` 升級 learned physics(GATr/CGENN 方向)。

### 4.3 GPU 物理擴張:VBD 原型

> 進度:✅ 2026-07-13 `physics/vbd_cloth.mojo` — VBD(vertex block descent)原型:每頂點 3×3 局部 Newton(彈簧能量 gradient/Hessian,橫向項 SPD clamp,Cramer 解),棋盤 2-著色 Gauss-Seidel(邊皆異色 → 同色平行、無 atomics、決定性),隱式 Euler target y=x+hv+h²g。復用 `gpu_cloth` 的 `ClothState`/`_init_grid`/SoA。4 kernels(predict/solve×2 color/finalize)、`has_accelerator` 守衛。`test_vbd_cloth` 6/6:物性(下垂/地板/約束)、與同預算 XPBD 約束品質同級、**CPU/GPU parity 4.9e-5**(RTX 3060 實機)。`bench_vbd_cloth`:XPBD vs VBD 同場景同表、每 row 附最差邊拉伸誤差(公平準則 = 同品質水準比成本)。誠實發現:此簡單結構布料上 XPBD 直接投影收斂更快更省(it=2 誤差 0%,VBD 需 it≥10 才降到 0.1%);VBD 的優勢(高剛度無條件穩定、體積/FEM 材質)不在距離約束布料顯現。
> 附帶根因:多個 `DeviceContext`/process 在此 nightly 掛死(2026-07-13 定位:掃 32→64→128 逐一驗證,單 context 過、三 context 掛)→ `gpu_cloth_run_ctx`/`gpu_vbd_run_ctx` 共享單 context,一併修好先前 `bench_gpu_cloth` GPU rows 空白的問題(128² XPBD:GPU 90µs vs CPU 2507µs,28×)。**4.3 完成**(GPU rigid stretch 未做)。
- [VBD](https://arxiv.org/pdf/2403.06321)(vertex block descent)原型,復用 `gpu_cloth`
  基建(SoA 分量緩衝、gather 式無 atomics、`has_accelerator` 守衛)。
- **Gate**:CPU/GPU 同 seed parity(ε 內);布料物性 gate(下垂/地板/約束長度)。
- **Benchmark gate**:同布料場景 XPBD vs VBD —— ns/step 與收斂迭代數同表
  (公平準則:同精度目標下比總成本),入 report。
- Stretch:GPU rigid(6-DOF 剛體 solver 上 GPU)。

### 4.4 ECS 完備:push-based observers + 延遲 component set

> 進度:✅ 2026-07-13(observers)`ecs/reactive_backend.mojo` — `observe1/observe2`(事件種類遮罩 × 組件集過濾)+ `ObsEvent` inbox + `drain`;mutation 現場派送(flecs 語意:EV_ADD 首次、EV_SET 每寫、EV_REMOVE 含 despawn 依 slot 序)。`test_observers` 8/8:精確事件流(12 事件逐欄比對)、過濾、雙次執行逐位一致、ADD/REMOVE 重播 ≡ 輪詢成員。`bench_ecs_events`:push 56.9 vs 輪詢 73.2 ns/event(同 20k 事件)。
> 進度:✅ 2026-07-13(延遲 set)`ecs/commands.mojo` — `SetBuffer[*CTs]`:型別抹除 per-type 佇列(backends 的 Slot 慣例)+ 全域錄製序 log,`apply` 依錄製序跨型別重播、亡者寫入丟棄(Bevy 語意)。`test_deferred_set` 13/13:逐值 parity、跨型別保序、迭代中錄製世界不動、無復活。benchmark:37.1 vs 直接 15.0 ns/write(迭代安全價格 2.5×)。**4.4 完成。**
- **push-based observers**:`reactive_backend` 正式化為事件驅動(add/remove/set 觸發)。
  - **Gate**:觸發順序決定性(雙次執行一致);與手動輪詢語意 parity。
  - **Benchmark gate**:observer dispatch vs 手動輪詢 ns/event,入 report。
- **延遲 component set**(command buffer 補完;需型別抹除,風險最高、排最後):
  - **Gate**:與立即 set 逐值 parity;迭代中延遲寫入決定性。
  - **Benchmark gate**:command buffer 吞吐(records/s)vs 直接結構變更。

### 4.5 工程債:bench_ga teardown flake 根因(背景)

> 進度:✅ 2026-07-13 **根因定位**:bench_ga 四段(build/apply/compose/skin)配對稽核 —— `apply`+`skin` 組合 12/12 掛、其餘任一段單獨 0/12。共同點:多個裸 `List[Vec3]`(width-3 SIMD)被不同閉包捕獲,teardown 時毀(libAsyncRT 棧;容量預留無效,佐證非 realloc 而是 teardown)。修法:`geometry/skinning.mojo` 加 `SkinVert` 結構包裝,`skin_motor`/`skin_lbs` 及 bench_ga 的 trans/rest/out 全部改用之(連帶更新 test_skinning、examples 07/08)。驗證:**bench_ga 100/100 乾淨**(修前 ~10/15 掛)。`run_bench` 重試已從 8 次降為單次安全網並記錄根因。另發現並修復 GPU 多 `DeviceContext` 掛死(見 4.3)。**4.5 完成。**
- 裸 `List[SIMD3]` 稽核(chip 已開)or nightly runtime bug 定位(libAsyncRT 棧)。
- **Gate**:連續 100 次乾淨執行 → 移除 `run_benchmarks.sh` 的 `run_bench` 重試 hack
  (或降為安全網並記錄原因)。

---

## 明確不做(本輪)

- GPU-driven rendering、資產管線、音訊、網路、導航、編輯器 —— 成本最高、差異化最低。
- CGA 作為效能主線(自家數據 ~4× 已否定;保留為 curved-primitive 查詢與交叉驗證)。

## 依賴圖(骨牌序)

```
1.1 manifold ──► 1.2 screw+forque ──► 2.1 soft solver ──► 2.2 joints/islands
      │                 │                                        │
      │                 └──► 1.3 integrators                     │
      └──► 2.3 persistent broadphase + speculative CCD ◄─────────┘
                        (Phase 3 各縱深可在 Phase 2 後並行)

Phase 4(4.0 先行、其餘可並行):
4.0 benchmark 覆蓋補齊(獨立)
2.3 speculative CCD ──► 4.1a swept/TOI      1.3 integrators ──► 4.1b LGVCI
3.1 diffsim ──► 4.2 reverse tape            3.2 gpu_cloth  ──► 4.3 VBD
3.3 relations/commands ──► 4.4 observers + 延遲 set          4.5 flake 根因(背景)
```


---

## Phase 6 — Soft body(2026-07-13 使用者定向:技術續推)

### 6.1 CPU XPBD 體積軟體 + 剛體雙向耦合
> 進度:✅ 2026-07-13 `physics/softbody.mojo` — `SoftBody.box_lattice`(n³ 粒子、13 方向鄰接
> 距離約束 = 結構+面對角+體對角提供剪切剛度)、真 XPBD(每子步 λ 累積、compliance α 時步無關、
> `damp` 為材質屬性);`ContactScene6._softbody_pass` 接進 soft-step 子步(剛體 pose 積分後):
> predict → Gauss-Seidel 邊約束 → 粒子對每個 box 的當前姿態局部座標推出(最小穿透軸)→
> **雙向耦合**(推出量 × m_p/h 等效衝量回饋動態剛體 + 喚醒睡眠體)→ 位置導速度。
> `tests/test_softbody.mojo` **11/11**:落地靜置(粒子不穿地、settles)、雙次執行 bit-identical、
> 剛度排序(α 1e-6 高 0.599 vs 3e-2 高 0.576)、**零重力動量守恆 0.03%**(damp=1 隔離耦合本身:
> 4.0 → 0.471+3.530)、剛體騎乘軟墊(縫隙=粒子半徑、載重路徑下沉 4.1mm、未壓扁)。
> 校準記錄:XPBD 尺度 α̃=α/h² 需與 Σw⁻¹≈64 同階才進「軟」區(α≥1e-2 = 果凍;1e-3 = 承重海綿);
> `top_y()` 量的是未受載角柱,壓縮 gate 須量載重路徑(rider 下沉)。
> 已知限制(誠實):軟-剛無 CCD(rider 每幀位移 > 粒子半徑會鑽晶格);單一實作無 seam 變體
> (benchmark 法則不適用,成本 row 留待有第二實作時);無 GPU 版(gpu_cloth 機制可移植)。
> ⚠ 環境懸案:`pixi run` 目前因 wgpu-mojo git 依賴的 build backend 解析失敗
> (pixi-build-api-version 無候選)而不可用;workaround = 直接 activate env
> (`PATH=.pixi/envs/default/bin` + source `activate.d/10-activate-max.sh`),引擎建置測試不受影響。

### 6.2 Restitution(彈性碰撞 — README「Honest status」第一洞)
> 進度:✅ 2026-07-19 Box2D v3 式:`_collect_pairs` 於 prep 擷取逐點逼近速度 vn0(不隨 warm-start
> 繼承,每幀新鮮);子步迴圈後專屬 `_restitution_pass`(門檻 1 m/s、目標 vn=−e·vn0、獨立
> clamp≥0 累積器);`set_restitution(i,e)` 逐體設定、pair 取 max。`tests/test_restitution.mojo`
> **7/7**:e=0.8 首彈頂點 0.582(解析 e²=0.64,離散衝擊損耗 9%)、e=0.4 → 0.144/0.16、
> e=0 死落(回歸守衛)、連續頂點衰減比 0.599、bit-identical。全套無回歸(預設 e=0 行為不變)。

### 6.3 Sphere / Capsule 形狀入 solver(脫離 box-only)
> 進度:✅ 2026-07-19 `collision/manifold.mojo` 增形狀對 manifold:sphere-sphere/sphere-box
> (中心在內時最小軸推出)/capsule-box(段-OBB 最近點 = 凸距離**三分搜尋** 40 迭代,決定性;
> 端點探針最多 2 接觸點)/capsule-capsule(段-段最近點閉式)/capsule-sphere;
> `ContactScene6` 增 `shape` kind 清單 + `add_sphere`/`add_capsule` + `_pair_manifold` 派發
> (kind 正規化 + normal 翻轉);`Inertia3.capsule`(圓柱+半球標準公式)。錨點/warm-start/
> 摩擦/restitution/睡眠機制全形狀通用、零改動。`tests/test_shapes6.mojo` **10/10**:
> 球靜置 y=0.2997(r=0.3)且入睡、球彈跳 apex 0.582(與 box restitution 同值)、
> **球-球對撞動量均分 1.49999/1.50001**、capsule 翻倒躺平 y=0.1996 軸水平 6e-6、
> 球站 box 頂不滑(x=1.3e-5)、bit-identical。全套無回歸。
> 限制:soft-vs-sphere/capsule 耦合未做(softbody pass 跳過非 box);swept TOI 仍 box-only
> (ccd=True 場景勿混形狀)。

### 6.4 縮座標關節鏈(Featherstone 方向,CRBA+RNEA 切片)
> 進度:✅ 2026-07-19 `physics/chain.mojo` — 串聯 revolute 鏈的縮座標動力學:CRBA 質量矩陣 +
> RNEA 偏置力,全程用**緊湊空間慣性 {m, h, I₀}**(串鏈的剛體與複合慣性都封閉於此形式,
> 全程免 6×6);FK 走純 motor 合成(GA 命題「Featherstone 空間向量即 motor」字面兌現);
> 部分主元高斯求解。`tests/test_chain.mojo` **8/8**:單擺週期 1.6400 vs 解析 1.6392(0.05%)、
> 大擺幅能量漂移 0.26%、**混沌雙擺 5 秒能量漂移 1.4e-4**、bob 擺 2.0383 vs 解析 2.0367 vs
> maximal-coordinate 實測 2.050(**兩形式經共享解析互驗**)、bit-identical。
> `benchmarks/bench_chain.mojo`(法則 row):**reduced n=8 3.1µs vs maximal 140µs/step(45×)**、
> n=16 34×。
> 除錯記錄(三個解析檢查點的教科書式定位):H 精確、重力偏置精確、Coriolis 錯 → 鎖定
> `_rot_rows` **轉置反了**(basis 影像即 R 的行 = Rᵀ 的列,毋須再轉置;單擺 z 旋轉下 w 不變
> 故隱形,先前的「重力符號修正」實為遮掩)— 修正後雙擺漂移 159% → 1.4e-4。
> 另:`dynamics()` 內六個裸 `List[Vec3]` 觸發 teardown 當機(已知陷阱再現)→ `_LV` 包裝,
> bench 3/3 乾淨。O(n) ABA 與樹狀拓撲留後續。

### 6.5 Islands 平行化(多執行緒 solver)
> 進度:✅ 2026-07-19 `step_soft(parallel=True)` — pairs 依島重排為連續區段、joints 依島過濾、
> `_solve_island` 把整個子步迴圈限定在單島(重力/warm start/joint/soft/pose/relax/restitution),
> `parallelize` fan-out(自由函式包裝 + `@parameter` 隱式捕獲 — 顯式 `{}` 捕獲清單此 nightly
> 不可解析,記入陷阱)。島互不共享 → **平行 vs 串行 bit-identical**(`test_islands_par` 5/5:
> 位置/旋轉/睡眠逐位相同、6 島場景、四塔全穩)。
> `benchmarks/bench_islands.mojo`(法則 row):16 島 **1.52×**(177 vs 270µs/step);
> 誠實行:單大島平行反慢 1.37×(執行緒開銷,無可攤提 — 與 scheduler bench 既有結論一致)。
> 限制:soft bodies 或 ccd=True 時退回串行;島內仍為順序 Gauss-Seidel(單島平行需著色,留後續)。

### 6.6 軟-剛 CCD(粒子掃掠 vs 盒)
> 進度:✅ 2026-07-19 `_softbody_pass(ccd=True)` — 粒子 prev→x 線段在盒**當前**局部座標系做
> slab 掃掠;相對運動 = 粒子起點先平移盒自身子步位移 **+v·h**(對 integrate_pose 精確;
> 旋轉忽略,一階掃掠)。兩個非顯然的坑:(1) 兩端都用當前姿態變換會**抵消盒自身位移**
> (快盒撞慢粒子完全掃不到 — 主案例!);(2) 單子步穿越中平面的粒子會被離散 min-pen 從
> **遠面**彈出 → 掃掠必須**優先於**離散分支且入口側符號取自 **lp0**(穿越後 lp 已在出口側)。
> 閘門 `|dv| > r` 保慢速路徑逐位不變;t_in≥0(非 >0)允許貼面粒子重入。
> `tests/test_softccd.mojo` **6/6**:子彈方塊 120 m/s vs 薄牆(每子步 0.5m > 充氣厚 0.12m,
> 對照組 64 粒全穿 x=9.2;ccd 全數擋下 x=−0.86)、**40 m/s 薄板**(4cm 厚,每子步行程 16.7cm
> > 充氣厚 14cm:對照組無感切穿到地板 min_bot=−0.094,ccd 被方塊接住 0.308 且方塊存活)、
> 慢場景 ccd on/off **bit-identical**(零回歸)。
> 發現:厚盒(40cm)在 ≤60 m/s 相對速度下掃掠與離散**可證明同值**(同面同符號同夾值)——
> slam 實測逐位相同;軟-剛 ccd 的判別域是薄特徵與極端速度。
> 限制:sphere/capsule 剛體不掃(同耦合缺口);盒旋轉忽略(一階)。

### 工具鏈 2026-07-19:Mojo nightly 升級 + pixi 修復
> ✅ Mojo **1.0.0b3.dev2026071006 → 1.0.0b3.dev2026071805**、wgpu-mojo 推至最新 rev、全依賴
> 更新;69 測試檔全綠。使用者政策:**專案不鎖版本,每次都升級**。
> API 更名批次處理:`destroy_pointee`→`unsafe_deinit_pointee`、`init_pointee_move`→`unsafe_write`;
> 未處理 deprecation:參數慣例 `read`→`imm`(仍為警告)。
> 新編譯器行為:precompile 會**先建立輸出檔再解析 import** → 套件內絕對自我匯入經 -I 撞到
> 半寫/過期 .mojoc(magic bytes 錯)→ `build_engine.sh` 改 staging 目錄 + 完成後搬移。
> pixi run 壞因根治:isolated backend solve 對 `pixi-build-mojo 0.1.*` 的 `pixi-build-api-version`
> 無候選(0.1.x 舊建置的依賴鏈斷);**上游一行修復已實證**(wgpu-mojo pixi.toml:backend
> version `"0.1.*"` → `"0.2.*"`,path-dep 實驗免 override 全綠)。上游修復前的過渡:
> `pixi global install pixi-build-mojo -c https://repo.prefix.dev/pixi-build-backends -c conda-forge`
> 後以 `PIXI_BUILD_BACKEND_OVERRIDE="pixi-build-mojo=$HOME/.pixi/bin/pixi-build-mojo"` 前綴
> pixi 指令。

### 6.7 Soft-vs-sphere/capsule 耦合(補 softbody pass 的形狀缺口)
> 進度:✅ 2026-07-19 `_softbody_pass` 不再跳過 shape≠0:球=最近內點徑向推出、膠囊=世界軸段
> 最近點作球處理,衝量回饋與 box 路徑同式。ccd 掃掠=線段 vs 充氣球二次式(最早根 ∈[0,1]、
> 起點須在外),**掃掠優先於徑向推出**(單子步穿中平面會被徑向彈出遠側 — box 的中平面陷阱
> 在球形狀的鏡像,實測 200 m/s 下先離散後掃掠會漏);膠囊 ccd 用當前位置最近點球一階近似。
> `tests/test_softcouple.mojo` **13/13**:球/膠囊圓丘 drape 逐幀 min gap −3e-8(全程零穿透)、
> 零重力動量守恆 **1.9996/2.0(0.02%)**、相位精算 200 m/s 彈丸(子步行程 0.83m > 充氣弦 0.7m,
> 起點調至離散取樣全跳)— 對照組穿越 x=14.5,ccd 兩形狀皆擋(−0.17/−0.66)。全套無回歸。
> 誠實記錄:粒子-形狀接觸**無摩擦**(純法向推出)→ 圓丘為不穩定平衡,方塊滑至丘緣停住
> (兩場景決定性同軌跡)— 對目前模型是正確物理;軟接觸摩擦留後續。

### 6.8 O(n) ABA(關節化剛體演算法)
> 進度:✅ 2026-07-19 `Chain.dynamics_aba`/`step_aba` — Featherstone RBDA 7.3 三趟掃描:
> 外掃(速度+關節偏置 c+速度積偏置力 p)、內掃(關節化慣量 + U Uᵀ/d 投影 + 偏置力回推)、
> 外掃(加速度+qdd)。U Uᵀ/d 破壞緊湊 {m,h,I₀} 形式 → 新 `_ABI`(對稱 6×6 分塊 [[A,B],[Bᵀ,D]]),
> 平移共軛 shift 手推:A′=A₁−B₁P+PB₁ᵀ−PD₁P、B′=B₁+PD₁、D′=D₁(P=[pivot]×,先旋後移,
> 與 dynamics() 力回推同構)。
> `tests/test_aba.mojo` **3/3**:vs dense CRBA+RNEA 逐點 parity(混軸混質量鏈 n=1–6,
> 最壞相對誤差 **4.3e-6**,f32 舍入級;軌跡逐步比對 200 步同階)、垂懸靜止鏈 qdd **精確 0**、
> test_chain 同款雙擺 step_aba 能量漂移 0.29%(同 2e-2 gate,且用更粗步長)。
> `bench_chain` 法則 rows:n=4 dense 贏(1.66 vs 1.80µs)、n=8 dense 贏(2.98 vs 3.82µs,
> 誠實行:ABA 常數大)、n≈16 交叉(7.61 vs 7.90µs)、**n=64 ABA 3.5×**(103.5 vs 29.8µs/step,
> 三次方 vs 線性肉眼可見)。
> 測試校準教訓:能量 gate 場景必須與 test_chain 同構 —— q0=2.0 過頂甩鞭(qd±17 rad/s)在
> dt=1/240 下 dense 與 ABA **同樣**漂移 113%(積分器解析度問題,非演算法錯;兩者末能量
> −10.186 vs −10.192 幾乎同軌跡)。樹狀拓撲與浮動基座留後續。

### 6.9 軟接觸摩擦(位置級 Coulomb 錐)
> 進度:✅ 2026-07-19 `SoftBody.mu`(預設 0.5)+ `_soft_fric` — 切向滑移(粒子子步位移 −
> 接觸點體速×h)夾制於 μ×法向修正:錐內全抓(靜摩擦)、錐上滑動;修正折入目標點,
> 耦合衝量自動帶切向反作用(等大反向 → 動量守恆由構造保證)。三個接觸尾端全接:box
> (面法向 = 單位局部偏移的 act 差分)、球/膠囊(徑向)。位置級錐比例與力級同縮放(皆 h²)
> → 解析斜坡 gate 成立。
> `tests/test_softfriction.mojo` **6/6**:15° 坡(tan=0.27<μ)drift **6.6e-7**(對照 μ=0:88.98,
> 滑落墜出)、35° 坡(tan=0.70>μ)超錐滑動 103.8、6.7 的圓丘蠕滑 0.397 → **0.050**(釘住)、
> 斜掠零重力撞自由球動量 px 2.0003 / py −9e-5。
> 回歸調整:softcouple 彈丸 gate 由「停在接近側」改為「停在形狀近域 + 不穿入表面」——
> 摩擦讓 200 m/s 彈丸抓面後**繞球擺到遠側表面**(x=0.339≈rr,min dist 0.330>0.315,合法
> 物理,非穿隧;對照組仍 14.46)。全套綠。

### 6.10 場景序列化(精確存檔/載入)
> 進度:✅ 2026-07-19 `physics/serialize.mojo` — `scene_to_string`/`scene_from_string`
> (ContactScene6[QuatBody6]):版本標記 + 純整數 token 流,**浮點以 f32 位元模式存**
> (`to_bits`/指標 bitcast 還原,無十進位往返損失)。逐位續跑的必要條件是把**所有動力學
> 狀態**入格式:跨幀 warm-start cache(_CPair 衝量累積器 + manifold + body-frame anchors +
> vn0/racc)、joint 累積器、sleep timer、軟體粒子/邊/材質;islands 每步重算免存。
> `tests/test_serialize.mojo` **5/5**(混合場景:塔+球關節擺+彈球+靜態膠囊+軟方塊,300 幀後
> 存檔):save→load→save **byte-identical**(blob 20KB)、載入後續跑 100 幀剛體 pos/q/vel/omega
> **bit-identical**、睡眠狀態相同、軟粒子相同、塔穿越存讀仍站立。全套綠。
> nightly 陷阱補記:`len(String)` 被禁(UTF-8 歧義)→ `byte_length()`;`bitcast` 無頂層函式 →
> `f.to_bits()` + `UnsafePointer(to=u).bitcast[Float32]()[]`;`atol` 是 builtin(std.strings 不存在)。
> 限制:綁定 QuatBody6(ScrewBody6 場景需對應變體);格式 v1 無向後相容承諾。

### 6.11 島內著色平行(單大島的約束圖著色)
> 進度:✅ 2026-07-19 `step_soft(colored=True[, parallel=True])` — 貪婪最小空色著色
> (位遮罩;**靜態體不入鄰接** — 否則一塊地板把全場串成一色鏈),pairs 重排為連續色段;
> `_soft_sweep` 的 pair 本體抽出為 `_solve_pair`(平凡路徑逐位不變),`_sweep_colored` 色內
> `parallelize`、色間順序。同色 pair 不共享動態體 → 寫入不相交 → **排程決定性**:兩次執行
> 逐位相同、colored 串行==平行逐位相同(`test_colored` 6/6);地面-only 場景單色且與平凡 GS
> 逐位相同(解析 gate)。金字塔(單島)colored vs 平凡 GS 位置差 1.4mm、塔頂沉降高度精確。
> **關鍵發現(除錯記錄)**:colored 排程打斷平凡序的「波前」傳播(由下而上逐排),iters=4 時
> 殘餘抖動 ~1cm/s 騎在睡眠門檻上 → **島永不入睡**(bench 首輪 3× 假性劣化全是睡眠差);
> iters=8 品質恢復(比平凡更早入睡,f=60 vs f=120)。relax 排程無關(實測)。
> `bench_colored`(法則 rows,STEPS=60 活躍沉降段):120 盒單島 — 排程本身 0 成本
> (4.65 vs 4.63ms)、同工作量平行 **1.66×**(2.79ms)、品質對齊行 it8 **1.21×** 淨賺(3.83ms,
> 可入睡);誠實行:21 盒 fan-out 反慢 1.78×。
> 使用指引:colored 適用「大且持續活躍」的單島(destruction 堆、料堆);會靜置的場景用
> 平凡 GS(睡眠紅利 ≫ 平行紅利)或 colored+iters≥8。

### 6.12 樹狀拓撲(分支關節樹/森林)
> 進度:✅ 2026-07-19 `Chain.parent`(-1=根;append 序保證父先於子)+ `add_link_to(p, link)` —
> fk/dynamics(CRBA+RNEA)/dynamics_aba/energy 全面改父索引:前向掃描按父索引讀、後向
> 掃描推入 `parent[i]`、H 矩陣沿父鏈上行;串鏈=parent i-1 特例。
> `tests/test_tree.mojo` **5/5**:顯式父鏈 vs add_link **bit-identical**(dense 與 ABA 皆是)、
> 森林雙根 == 兩條獨立鏈(逐位)、**Y 樹(軀幹+雙臂,混軸)ABA vs dense parity 2.1e-7**、
> 垂懸 Y 樹 qdd 精確 0、擺動 Y 樹能量漂移 1.19%(dt 減半漂移減半 → 一階積分器歸因,
> 非動力學誤差)。既有 chain 8/8 / aba 3/3 逐位不變(能量數字與樹化前完全相同)。
> 限制:浮動基座(6-DOF 根關節,完整 ragdoll)留後續;僅 revolute 關節。

### 工具鏈:解除 wgpu-mojo 依賴(2026-07-19,使用者指示)
> ✅ 移除 pixi.toml git dep、刪 `examples/08_wgpu_motor_skinning.mojo`(糖果紙效應的 CPU 版
> 演示與機器可驗證證據完整保留於 examples/07 與 ROADMAP 3.4 記錄)。lock 重解成功,
> **`pixi run` 復活**(build/test/examples 全綠,不再需要環境 override workaround)。
> 核心零觸點確認:physics/collision/ecs/geometry/tests/benchmarks 無任何 wgpu 引用 ——
> 渲染屬外部分層(架構分離定律)。遺留:`systems/renders/renderer.mojo`(1 行 import stub,
> 不在建置內)、`systems/renders/legacy_renderer.*` + `systems/input/input.py`(Python wgpu-py
> interop 舊碼,與 wgpu-mojo 無關,不在建置內)—— 待使用者決定去留。

## 前瞻路線總覽(2026-07-22 重整)

物理**演算法**核心已達競爭級:角動力學、sub-stepped soft solver、CCD、islands/sleeping/
warm-start、soft body + 雙向耦合、可微模擬(reverse tape)、GPU 布料、持久化寬相 DBVH、
EPA 3D(witness points)、樹狀關節 —— 全部 ✅ 且有 parity + benchmark。**當下瓶頸不再是
演算法,而是四件事**:

- **(A) 接線** —— 既有寬相(DBVH/hashgrid/BVH)未接進生產 6-DOF solver(仍 O(n²))。
- **(B) 表現力** —— 只能碰 box/sphere/capsule;無任意凸包、無三角網格/heightfield 靜態關卡。
- **(C) gameplay/程序化基礎** —— 無狀態機、無 Noise、無動畫 runtime、Actor Model 未硬化。
- **(D) 外殼** —— 腳本等需按架構分離另立,核心 API 穩定後才動。

優先序 = **槓桿**(接線既有零件 ＞ 新能力 ＞ 外殼)。六階段:

| Phase | 主題 | 項目 | 優先 | 狀態 |
|---|---|---|:--:|:--:|
| **7** | 可擴展性:接線既有寬相 | **7.1 SAH-BVH ✅** · **7.2 solver6 接寬相 ✅** | ★★★ | ✅ |
| **8** | 幾何表現力:跳出盒子 | 8.1 凸包入 narrowphase ✅ · 8.2 trimesh/heightfield 靜態關卡 ✅ | ★★★ | ✅ |
| **9** | 物理完整度 | 9.1 關節庫(limits/motor/spring/prismatic/weld) · 9.2 浮動基座 · 9.3 過濾層+sensor · 9.4 接觸事件 | ★★ | 📋 |
| **10** | 穩健與排程 | 10.1 exact predicates/interval · 10.2 自動依賴 job graph · 10.3 Actor Model 硬化 | ★★ | 📋(10.3 有雛形) |
| **11** | 程序化與 gameplay | **11.1 Noise ✅** · **11.2 狀態機 ✅** · 11.3 動畫 runtime | ★★ | 🔨 11.1,11.2✅ |
| **12** | 腳本層(架構分離,獨立) | 12.1 core embedding 邊界 · 12.2 Mojo/Python 雙腳本 | ★(gated) | ⏸ 等核心 API 穩定 |

**相依骨牌**:7 是地基(SAH 品質在 solver 用寬相後才計入幀時);8.2 trimesh 依 8.1 的
凸包/narrowphase 泛化(三角 = 退化凸包)、依 7.1(三角 BVH 用 SAH);9 各項大致獨立可並行;
11.3 動畫依 11.2 狀態機;**12 gated on 核心 API 凍結**(架構分離定律,使用者確認後才實作)。

**架構定律 v2 貫穿**:seam 變體(7.1、7.2、10.1)附 parity 方格 + benchmark;新能力
(8.x、9.x、11.x)附功能測試 + 有效能主張處的 benchmark;每項的交付物列於各節。

---

## Phase 7 — 可擴展性:接線既有寬相(2026-07-22)

### 7.1 SAH-BVH(建樹啟發式:median vs SAH seam)— ✅ 2026-07-22
> **進度**:✅ `geometry.bvh.BVH.build(sah=True)` — binned SAH(每軸 12 桶,前綴/後綴
> area×count 掃最小 `SA(L)·|L|+SA(R)·|R|`,就地分割;退化 → median 回退)。median 為預設,
> 遍歷碼(raycast/query_region)一行不動。新增 `cost()`(Σ 節點面積)與 `avg_leaf_depth()`。
> `tests/test_sah.mojo` **5/5**:200 體群聚場景,SAH vs median **region-query 結果集相等**
> (300 隨機盒)、**raycast 最近命中 proxy+t 相等**(300 隨機射線)、兩樹皆覆蓋全 200 proxy;
> **SAH 樹緊 43%**(Σ 面積比 0.572)。
> `bench_sah`:群聚 raycast **1.62×**(354 vs 573 ns/ray,緊樹多剪枝)、均勻 raycast **打平**
> (615 vs 635 = **誠實行**:無空隙可利用,SAH 品質優勢消失)。
> **意外發現(推翻計畫假設)**:SAH 建樹**反而更快**(群聚 2.13 vs 3.33ms、均勻 1.86 vs 3.64ms)——
> 現有 median build 用**插入排序**(每節點 O(n²)),binned SAH 是 O(n) 分箱+分割 → SAH 在此
> codebase 既更緊又更快建。計畫原寫「SAH 建樹較貴、有交叉點」不成立(median 的排序才是瓶頸;
> 若 median 改 quickselect 會更快,但 SAH 的群聚查詢優勢不受影響)。
> **誠實細節**:SAH 平均葉深略高(8.90 vs 7.72)—— median 完美平衡給最小深度,SAH 犧牲平衡
> 換更緊包圍盒(沿空隙切),這正是遍歷成本的正確取捨,Σ 面積(非深度)才是真指標。
> **後續**:solver6 broadphase(7.2)的每幀重建可改 `sah=True`(候選集相等 + solver 依 (i,j) 排序
> → 仍逐位一致,且更快更緊);此處保守留 median,標為一行後續。
> **動機/現況盤點**:靜態 BVH(`geometry/bvh.mojo`)目前以 **median-split along widest
> centroid axis** 建樹(`_widest_axis`+`_sort_range`+取中位),**未用 SAH**。持久化
> DBVH(`collision/bp_dbvh.mojo:37`)的**增量插入**已用 surface-area best-sibling 成本
> (SAH 近親,Box2D dynamic-tree 式),但那是逐次插入、非整樹最佳化。`AABB.surface_area()`
> (`geometry/aabb.mojo:51`,docstring 已標「the SAH cost metric」)成本度量現成、只用在測試。
> 缺口 = **靜態整樹 SAH 建構**。
>
> **設計**:BVH 建樹加 `median`(現況)vs `sah` 變體。SAH 用 **binned SAH**(每軸 12–16 桶,
> 累積前綴/後綴 area×count,掃最小 `SA(L)·|L| + SA(R)·|R|` 切面;免每軸全排序 → O(n) per level)。
> 介面選項:`build(..., heuristic: BuildHeuristic = Median)` 執行期參數(對齊 backend 慣例,
> 不新增型別)。葉節點閾值(leaf ≤ K prim)與遍歷碼(raycast/query_region/self-pairs)完全不動。
>
> **架構定律 v2 交付物**:
> 1. **Parity(自然性方格)**:SAH 樹與 median 樹對同一謂詞**結果集相等** —— region query
>    命中集合、raycast 最近命中、self-pair 集合三者逐一相等(兩者皆為同一 overlap/ray 謂詞的
>    精確加速結構,只有樹品質/遍歷成本不同)。「先 SAH 建再查 = 先 median 建再查」。
>    測試:擴充 `test_bvh` —— 隨機場景(均勻/群聚/尺寸混合)下 SAH vs median 結果集斷言相等 +
>    SAH 樹的葉節點覆蓋 == 輸入 proxy 集合。
> 2. **Benchmark**(兩軸,`bench_queries` 現有 harness):
>    - **建樹成本**:median 插入排序 vs binned SAH,ns/build vs n。
>    - **樹品質 + 查詢成本**:總 SAH 成本 Σarea(node)、平均葉深、實測**每查詢訪問節點數**與
>      ns/raycast、ns/overlap;median vs SAH,**掃描場景分布** —— 均勻分布(median 有競爭力 →
>      誠實行)vs 群聚/非均勻/尺寸差異大(SAH 應勝)。
> 3. **CATEGORY.md §2 新列**:`BVH 建樹啟發式 median vs SAH | geometry/bvh.mojo | 同一謂詞加速
>    結構的建構品質變體;結果集相等 | test_bvh(SAH parity) | bench_queries(建樹+查詢兩軸)`。
>
> **誠實準則(預先聲明)**:(a) SAH 的贏面**依場景分布與每幀查詢數**;每幀重建下建樹成本會被
> 計入,SAH 建樹較貴 → 存在**交叉點**(每幀查詢少 → median 整體更省;查詢多 → SAH 攤提回本),
> benchmark 必須報這條交叉曲線而非只報樹品質。(b) 公平比較 = **比 action(查詢一次的攤提總成本
> = 建樹/查詢次數 + 每查詢成本)**,同 leaf 閾值、同場景;不在均勻分布上宣稱 SAH 勝。
>
> **範圍界線**:只動靜態 BVH 建樹;DBVH 增量插入既有 surface heuristic 不變(正交)。不做
> spatial split(SBVH)、不做 GPU 建樹 —— 若 binned SAH 已足,留為後續。
>
> **相依**:無(純 `geometry/bvh.mojo` 內部 + test/bench)。可獨立於 Phase 6 後續(浮動基座等)推進。

### 7.2 solver6 接寬相(生產 solver 脫離 O(n²))— ✅ 2026-07-22
> **進度**:✅ `_collect_pairs(use_bp=True)` — 每幀重建 `geometry.bvh.BVH[3]` over 各體
> **fat 世界-AABB**(`_fat_aabb`),取代 O(n²) 雙迴圈;逐對邏輯抽為 `_try_pair`,brute 與
> broadphase **共用同一函式** → parity 白送。`step_soft(broadphase=True)` 開關(預設關 = 零回歸)。
> **parity 論證(關鍵)**:fat 半徑 `r_i = SPEC_BASE/2 + |v_i|·spec_dt`,使 **r_i + r_j ≡ pair
> speculative margin**(逐軸精確);AABB 重疊只看兩者膨脹量之**和** → fat-AABB 重疊 ⟺ 膨脹
> tight-AABB 重疊 ⊇ 膨脹 OBB 重疊 → 命中集**不變**;候選以相同 (i,j) 字典序發出 → Gauss-Seidel
> 逐位相同。
> `tests/test_solver_broadphase.mojo` **4/4**:混合場景(5 塔 + 球關節擺 + 彈球 + 靜態膠囊,
> 全形狀)400 幀 brute vs bvh **bit-identical**(pos/q/vel/omega/sleep 逐體零差)、接觸對數相同、
> 塔站立、**30 m/s 快落體(speculative margin)亦逐位相同**(fat 半徑隨 |v| 放大有捕捉)。全套零回歸。
> `bench_solver_scale`(分離小塔格,多數對為非鄰居):N=8 打平(**誠實行**:BVH 建樹開銷在小
> 場景可忽略)→ N=128 **1.27×**(1.16 vs 1.47ms/step)→ N=288 **1.47×** → N=512 **1.76×**
> (6.25 vs 10.96ms);gap 隨 N 單調擴大 = O(n²)→O(n log n) 漸近。
> **誠實記錄**:幅度溫和因 pair 收集每幀一次、而 solve 是 16 sweeps/幀 —— broadphase 消掉
> O(n²) **項**,常數因子的 solve 在 N 大前仍主導,故小 N 打平、大 N 才顯著。
> **限制/後續**:每幀**重建** BVH(非增量);持久化 DBVH(`bp_dbvh`,增量 refit)接入是下一步
> 優化;warm-start 的 by-(a,b) 匹配仍 O(pairs×cache),大 N 需改雜湊查找。7.1 SAH 建樹品質
> 現在才真正計入幀時(協同成立)。broadphase 與 parallel/colored 正交(收集在前、分島在後)。

## Phase 8 — 幾何表現力:跳出盒子(2026-07-22)

### 8.1 凸包碰撞入 narrowphase — ✅ 完成(2026-08-11)
> **成果**:`collision/hull.mojo` + `ContactScene6.add_hull`(shape kind 3)。任意凸體
> 進得了生產解算器,接觸是**多點 patch** 而非單點。
> **關鍵設計決定(與原計畫不同)**:法向/深度**不用 EPA**,改用**兩包面法向上的 SAT**。
> 原因是量到的:EPA 的法向只有其多胞形的解析度,靜置(淺穿透)時最差 —— 實測歪 1.4°,
> 在 60 單位地板上把最遠頂點推離極值 0.74,支撐面塌成 1 點,盒子就沉下去並翻倒。
> 兩包都帶精確面法向時,面接觸的最小穿透軸**就是答案**,沒有容差要調。
> 邊-邊接觸的軸不在任一面集合中,EPA 因此保留為 fallback。
> **量測**:hull 靜置高度 0.24971156 vs 同尺寸原生 box 0.24971099(差 5.7e-7);
> 4 點接觸;靜止速度 0.0;寬相開/關逐位相同。
> **定律 v3 三類**(`tests/test_hull.mojo` 24 checks、`tests/test_quickhull.mojo` 17 checks):
> - **普通** = 盒子表示為凸包後,法向/深度/點數對上專用 box-box SAT manifold(兩條路徑零共用碼)。
> - **整合** = 凸包/盒/球同場靜置正確、與真盒同高、寬相 seam 逐位相同、既有 8 組剛體測試不變;
>   點雲經 `SATNarrowPhase.add_cloud` 註冊與直接給 `Polygon` 的接觸逐點相同。
> - **極端** = 單點、共線、共面近扁(1e-4 厚)、頂點全重複、兩包完全重合、遠距退化點雲。
> **順帶接掉的孤島**:`geometry/quickhull.mojo`(2D)先前只有自己的測試在呼叫。
> 現有生產入口 `SATNarrowPhase.add_cloud` / `SATManifoldNarrowPhase.add_cloud`;
> 3D 側對應能力是 `HullShape._prune_interior`(35 點雲 → 8 頂點)。
> **Benchmark**:`bench_manifold` 新增兩列。GJK+EPA `pts=2201`(每次命中 1 點)
> vs hull `pts=8804`(4 點/命中,與專用 AABB 裁剪器相同點數,但適用任意凸體),
> 代價 ~2.5×。面枚舉 O(V³) 單獨列(V=8 約 3.1 µs/shape),因為它**每形狀建構一次**、
> 而 manifold **每對每步一次**,合併會掩蓋昂貴的那半是載入期付的。
> **踩到的 nightly 地雷(已寫進檔頭探針)**:`List[Vec3]` **跨函式邊界即損毀**
> —— 回傳後傳進另一個函式再讀出,末兩個元素會變成前面元素的複本;`for ref` 與
> 索引皆然、borrow 與 owned 皆然、預留 capacity 也沒用;只有在建構它的同一函式內讀、
> 或以未綁定 rvalue 傳遞才正確。症狀是盒子回報 5 個面法向而非 6。
> 因此此路徑**不傳、不回、不存任何 `List[Vec3]`**,一律扁平 `List[Real]`(stride 3)。
> **相依**:8.2 的三角形即退化凸包,復用此路徑。

### 8.2 三角網格 / heightfield 靜態關卡幾何 — ✅ 完成(2026-08-11)
> **成果**:`collision/trimesh.mojo` 的 `TriMesh`(BVH midphase)與 `HeightField`
> (格點算術 midphase),各接進 `ContactScene6` 為 shape kind 4 / 5(`add_trimesh` /
> `add_heightfield`,恆為靜態)。**任意靜態關卡現在表示得出來**。
> **窄相沒有新東西**:三角形就是三頂點單面的凸包,直接走 8.1 的 `hull_manifold`。
> 新的是 **midphase**,以及**一對多接觸**:一個木箱靠在山谷裡同時壓到數個三角形,
> `_CPair` 因此新增 `feat`(三角形索引)當子鍵,否則每個接觸都會繼承同一筆 warm-start
> 而互相打架。
> **量測(`bench_trimesh`)**:三角形數 1922→32258(16.8×)時,brute 162.8→2709.6 µs
> (**16.6× ,線性**)、BVH 379→886 ns(**2.3×,對數**)、heightfield 109→113 ns
> (**完全不成長**)。三者**候選數相同**(3278 vs 3278),所以沒有人是靠多丟工作給窄相
> 才變快的。代價寫明:heightfield 表達不了懸空、牆、洞穴。
> 全步整合:7938 三角形 + 64 木箱時 midphase 佔比小到兩者無法區分(400 vs 408 µs)。
> **定律 v3 三類**(`tests/test_trimesh.mojo` 18 checks):
> - **普通** = 平面網格靜置高度 0.2498787 對上實心盒地板 0.24971099;20° 斜坡上
>   木箱維持 0.266 離面高度 —— **這條就是在測三角形的法向有沒有進到 SAT**,
>   盒子自己的面法向全是軸對齊的,少了三角形的法向木箱會被沿 +y 推而陷進斜面。
> - **整合** = heightfield 與其 `to_trimesh()` 明列版對同一曲面靜置差 5e-6;
>   盒/球/凸包同場靜置於網格;寬相開關逐位相同;**序列化來回後逐位相同**。
> - **極端** = 空網格、零面積三角形、遠離網格的查詢、完全在格外的 heightfield 查詢、
>   V 型谷多三角形接觸。
> **抓到的真 bug**:
> 1. 投機邊距只膨脹動態體一半卻扣掉整個 margin → 靜置低了 **0.0102**(= margin/2)。
>    三角形沒有厚度可膨脹,動態體必須吃下整個 margin。
> 2. 零面積三角形仍是**合法凸物**(退化成線段),GJK 照樣回報命中,木箱會停在一條
>    數學線上。改由 `tri_faces` 對退化三角形回傳空清單來表達「沒有面就沒有接觸」。
> 3. **8.1 留下的序列化洞被這個測試抓到**:`scene_from_string` 沒有還原 `hull_id`,
>    凸包場景來回後會索引空側表。已補齊 —— hull / trimesh / heightfield 的幾何
>    現在隨 body 一起序列化(此格式是完整狀態快照,不是資產參照)。
> **相依**:8.1(三角=退化凸包)、7.1(三角 BVH 用 SAH)。

## Phase 9 — 物理完整度(2026-07-22)

### 9.1 關節庫深度(limits / motors / springs / prismatic / weld / cone-twist)— ✅ 已完成
> **現況**:`Joint6` 僅 ball / distance / hinge **等式約束**;無限制/馬達/彈簧/滑軌/焊接。
> **設計**:hinge/prismatic 加下上限(單邊不等式,錐外投影)、馬達(目標速度 + 力矩上限)、
> 軟約束彈簧(復用 soft coefficient)、weld(6-DOF 剛接)、cone-twist(ragdoll 肩髖);
> 全走既有 soft substep sweep,warm-start 累積器擴充。
> **交付物**:`test_joints_ext`(限制擋停解析角、馬達達速、彈簧頻率、weld 剛度、**能量不注入**)
> + bench row(關節種類 × 迭代)。**相依**:9.2 浮動基座 ragdoll 需 cone-twist。

### 9.2 浮動基座關節(完整 ragdoll)— ✅ 已完成
> **現況**:`chain.mojo` 固定基座;完整 ragdoll 需 6-DOF 自由根(已於 6.8/6.12 記為後續)。
> **設計**:根連桿 6-DOF(3 平移 + 3 旋轉廣義座標,或 motor 根);CRBA/RNEA/ABA 三路徑的
> 根項推廣(Featherstone floating-base,H 左上 6×6 塊、根空間慣量)。
> **交付物**:`test_floatingbase`(自由落體質心拋物線 = 解析、無外力**角動量守恆**、鎖根時
> 與固定基座 parity)+ 與 solver6 maximal-coord ragdoll 交叉驗證。**相依**:9.1(關節)。

### 9.3 碰撞過濾(layers / groups / masks)+ sensors / triggers — 📋 規劃中
> **現況**:無 —— 無法表達「玩家不撞玩家」「觸發區」。
> **設計**:per-body category bits + mask(Box2D 式 `(catA&maskB)&&(catB&maskA)`),**寬相
> 候選即過濾**(零額外解算);sensor 旗標(產接觸事件但不解衝量)。
> **交付物**:`test_filter`(層矩陣命中/略過、sensor 不施力但報重疊)+ 寬相過濾零額外配置。
> **相依**:9.4(sensor 產事件)、7.2(過濾掛在 DBVH 候選出口最省)。

### 9.4 接觸事件(began / stay / ended)— 📋 規劃中
> **現況**:無接觸回呼;gameplay 無法知「誰碰到誰」。
> **設計**:跨幀 pair cache 差分(warm-start cache 已有 pair 集)→ began(本幀新)/ stay /
> ended(上幀有本幀無);事件佇列復用 ECS observer inbox 慣例,**決定性順序**。
> **交付物**:`test_contact_events`(逐事件流比對、sensor 觸發、雙次執行一致)。**相依**:9.3。

## Phase 10 — 穩健與排程(2026-07-22)

### 10.1 Exact predicates / interval 穩健層(SOTA_GAP M3)— 📋 規劃中
> **現況**:無;退化構型(共面/共線/近平行)下健全性未保證。
> **設計**:Shewchuk 式自適應精度 orient2d/3d + incircle/insphere(浮點快篩 → 必要時展開);
> GJK/EPA/clip/quickhull 的關鍵符號判斷改用之。
> **交付物**:`test_predicates`(共線/共面退化 vs 任意精度參考、符號正確)+ bench(快篩路徑
> 額外成本 ~0)。**seam 變體**:naive float vs exact,幾何謂詞結果集相等。

### 10.2 自動依賴 job graph(DOTS 式讀寫衝突)— 📋 規劃中
> **現況**:排程器 serial/parallel/actor 但**手動**;無讀寫衝突自動偵測。
> **設計**:系統宣告 component 讀寫集 → 建 DAG(寫寫/讀寫衝突加邊)→ 拓撲分層平行;
> **結果與 serial 逐位一致(決定性)**。
> **交付物**:`test_jobgraph`(自動排程 == serial 結果 parity、衝突正確串行化、無衝突真並行)
> + bench(vs 手動 serial/parallel scheduler)。**相依**:與 Phase 4.4 observers / commands 協同。

### 10.3 Actor Model 硬化(既有雛形 → 生產)— 📋 規劃中(有雛形)
> **現況**:`scheduler/{entity_actor,system_actor,message}.mojo`(336 行,EntityActor /
> SystemActor 兩排程器 + envelope/inbox)**已存在但零測試、未整合、未證明**。
> **設計**:補決定性投遞語意(inbox 排序、同 tick 訊息可見性規則)、與 `gameloop` 整合、
> 背壓/mailbox 溢位策略。
> **交付物**:`test_actor`(訊息投遞順序、**雙次執行逐位一致 = rollback 地基**、entity vs
> system actor 同場景 parity)+ bench(actor 排程 vs 直接系統)。
> **註**:網路 rollback 的地基(決定性 RNG + actor + 序列化)在此收口;網路本體仍為外殼、不做。

## Phase 11 — 程序化與 gameplay 基礎建設(2026-07-22)

### 11.1 Noise 家族 — ✅ 2026-07-22
> **進度**:✅ 新 `procedural/` 套件 + `procedural/noise.mojo` —— `value3`、`perlin3`/`perlin2`
> (gradient,Ken Perlin improved-noise 選擇子 + quintic fade)、`worley3`(cellular F1)、
> `fbm3`/`fbm2`(分形疊加)。**純函式**:整數格點雜湊(xxhash 風味,無置換表/無 RNG 狀態)→
> 跨執行/跨機器決定性。Simplex 跳過(專利+複雜,OpenSimplex2 留後續)。
> `tests/test_noise.mojo` **11/11**:seed 決定性(同 seed 逐位相同、異 seed 去相關)、
> 值域(perlin3 ∈[−0.78,0.75]、value3/fbm3 皆 ⊂[−1,1]、worley≥0)、**連續性**(跨格界最大
> 一階差 0.012)、**梯度連續**(二階差 0.0006,quintic fade 給 C¹)、2D 路徑。
> `bench_noise`:perlin2 11.3 / perlin3 26.7 / value3 12.6 / worley3 94.4(27 格搜尋)/
> fbm 5-octave 68/134 ns/sample(scalar,~37M perlin3/s)。
> **踩雷**:純函式 benchmark 被 DCE 消成 0 ns → 用 `std.benchmark.keep(acc)` 擋(bench_queries
> 慣例);此 nightly `fn` 已移除,一律 `def`。
> **用途**:地形/heightfield(接 8.2)、程序紋理、動畫擾動。SIMD 批次採樣留後續優化。
> **相依**:無。**註**:noise 非 seam 變體(無 parity 方格),故不入 CATEGORY §2,功能測試即交付。

### 11.2 狀態機(FSM / HSM)— ✅ 2026-07-22
> **進度**:✅ `scheduler/fsm.mojo` — 資料驅動階層狀態機(UML statechart 風味)。狀態成樹
> (leaf/composite),轉移為 (from, event, to) 三元組;`fire(event)` 從當前 leaf **向上冒泡**
> 找匹配轉移,再做 **LCA exit/enter**(退到最近共同祖先、進到目標、descend 進 initial/歷史子態)。
> `is_in(s)` 對當前 leaf 及其所有祖先為真(`is_in(grounded)` 在 idle/walk/run 皆成立)。
> **免 callback**:每次 `fire`/`start` 把退出/進入的狀態記入 `exited`/`entered`(caller 讀取)——
> 觀察 enter/exit 動作而不需函式指標(Mojo 友善)。淺歷史(composite 記住 last-active 子態)。
> `tests/test_fsm.mojo` **17/17**:平坦 FSM 轉移 + 未知事件 no-op、HSM 進 composite→initial 子態、
> **JUMP 從 leaf 冒泡到 parent 轉移**、exit/enter 記錄序正確、**淺歷史恢復 last child**(非 initial)、
> **同事件序列雙機同路徑**(決定性)。
> **用途**:AI、gameplay 邏輯、動畫狀態(驅動 11.3)。**相依**:無。非 seam,功能測試即交付。

### 11.3 動畫 runtime(clip / blend / 狀態機驅動)— 📋 規劃中
> **現況**:skinning 數學已有(motor DLB / LBS,修過 candy-wrapper),**缺 runtime**。
> **設計**:動畫 clip(關鍵幀取樣)、blend tree(線性 / **motor 測地混合**,復用 GA)、
> 由 11.2 狀態機驅動狀態轉移。
> **交付物**:`test_anim`(clip 取樣、blend 端點 == 純 clip、**motor blend 無 candy-wrapper**)
> + bench(每骨每幀 ns)。**相依**:11.2(狀態機驅動)。

## Phase 12 — 腳本層(架構分離,獨立層)⏸ gated

> **架構分離定律(使用者明令)**:核心 API 仍在演進 → 腳本層**不入核心 repo**,以獨立
> 層/repo 綁定;本階段**先定邊界**,實作 gated on **核心 API 凍結 + 使用者確認**。
> - **12.1 Core embedding 邊界**:定義穩定介面(世界建構、系統註冊、查詢、事件訂閱)的
>   C-ABI / 值語意契約,核心零腳本依賴。
> - **12.2 Mojo / Python 雙腳本**:Python(PythonModuleBuilder 擴充模組,快速迭代)+
>   Mojo(原生系統,零開銷);使用者可選其一或混用。
> **交付物(實作時)**:腳本層 vs 原生系統同場景 **parity**(腳本不改變模擬結果)。
> **註**:此為 2026-07 撤銷的「引擎-UI / 腳本」方向的**正確重生形態** —— 分離、可選、
> 核心先穩;與當時「混入核心」的做法本質不同。

## Phase 13 — 機器人／控制能力(2026-08-04,對照 MuJoCo 能力盤點)

> **來源**:與 MuJoCo 的能力差異盤點。**使用者明令排除**三項,不入本階段:
> **場景描述格式(MJCF/URDF)**、**MJX**、**MJWarp** —— 因為與其他 RL / Game Engine 平台
> 的整合方式尚在評估,格式綁定是先於技術的架構決策。其餘缺口全數規劃入路線。
>
> **已被既有階段涵蓋、不重複列**:凸包入 narrowphase(**8.1**)、trimesh / heightfield
> 靜態幾何(**8.2**)、關節型別擴充 limits / prismatic / weld / cone-twist(**9.1**)、
> 浮動基座 6-DOF 根(**9.2**)。本階段只列那些**尚未出現在任何階段**的能力。
>
> **現況校正(避免高估缺口)**:縮座標側比預期完整 —— `physics/chain.mojo` 已有
> **樹 / 森林拓撲**(`parent` / `add_link_to`)、CRBA + RNEA + O(n) ABA、FK 走 motor 合成。
> 缺的是**關節型別只有 revolute**、**無浮動基座**、以及**與接觸求解器完全不耦合**。

### 13.1 反向動力學(精確 τ = ID(q, q̇, q̈))— ✅ 已完成
> **現況**:`Chain.dynamics` 內部**已用 RNEA 算 bias 項** —— 精確反向動力學的機件已在,
> 只差把它以 `inverse_dynamics(qdd) -> tau` 的形式暴露出來。是本階段**成本最低的一項**。
> **優勢**:控制、力矩前饋、系統辨識、接觸力估計的共同基礎;MuJoCo 以此做 warm-start。
> **對照組**:有限差分反解(數值)、以及 `dynamics()` 正解的**往返一致性**(ID∘FD = 恆等)。
> **規模軸**:連桿數 n(RNEA 是 O(n),對照的稠密反解是 O(n³))。
> **交付物**:`test_inverse_dynamics`(**往返 τ→q̈→τ 逐位一致**、對照有限差分、
> 分支樹與森林皆測)+ bench row(n 掃描,ID vs 稠密反解)。**相依**:無。

### 13.2 縮座標 ↔ 接觸耦合(關節體能碰到世界)— ✅ 已完成
> **現況**:`Chain`(縮座標)與 `ContactScene6`(最大座標接觸)是**兩個互不相通的世界**。
> 關節機器人目前碰不到任何東西 —— 這是本階段**最關鍵的結構缺口**,幾乎所有機器人用途
> 都卡在這裡。
> **設計**:接觸雅可比 J 把接觸點速度映到關節空間;在關節空間解約束(MuJoCo 路線),
> 或以 Featherstone 的鏈約束把接觸衝量投影回 τ。**先做單一鏈接地**,再推廣。
> **優勢**:關節體不再是離線玩具;與最大座標 ragdoll 形成可比較的兩條路線。
> **對照組**:同場景的**最大座標 ragdoll**(既有 joints6 路線)—— 兩者穩定性與成本對比,
> 這正是「縮 vs 最大座標」的經典權衡,引擎兩邊都有,可以真的量。
> **規模軸**:連桿數 × 接觸點數;以及**關節剛度**(縮座標在高剛度下不會抖,最大座標會)。
> **交付物**:`test_chain_contact`(落地不穿透、靜止殘餘漂移、能量不增)+ bench
> (縮 vs 最大座標,同場景同精度)。**相依**:9.2 浮動基座(自由基座才有一般性)。

### 13.3 致動器模型(傳動 + 力生成 + 內部動力學)— ✅ 已完成
> **現況**:**零**。`Chain.step` 直接吃 τ,沒有任何致動器抽象。
> **設計**:MuJoCo 式三段分解 —— **傳動**(關節 / 腱 / 位置)、**力生成**(仿射 gain/bias:
> 一組參數即涵蓋 motor / position servo / velocity servo)、**內部動力學**(一階濾波、
> 氣壓/液壓遲滯、**Hill 型肌肉**的啟動動力學)。
> **優勢**:控制迴路可在引擎內閉環,而非由外部每步寫死 τ;肌肉模型是生物力學/角色動畫路線。
> **對照組**:直接寫 τ 的裸控制(現況)—— 對比追蹤誤差與穩定性;PD servo vs 內建 position 致動器。
> **規模軸**:致動器數;以及**增益**(高增益下裸 PD 會震盪,帶內部動力學的不會 —— 這是優勢區)。
> **交付物**:`test_actuator`(位置伺服到達設定點、速度伺服穩態誤差、
> **肌肉啟動遲滯的階躍響應**、零增益 == 純 τ 逐位一致)+ bench(每致動器每步 ns)。
> **相依**:13.1(前饋 τ 用 ID 算)。

### 13.4 腱(fixed / spatial,含繞行)— ✅ 已完成
> **現況**:**零**。
> **設計**:**fixed tendon** = 關節座標的線性組合(耦合、差動);**spatial tendon** = 過路徑點的
> 最短路徑,可繞球/圓柱(wrapping)。腱長 → 腱速 → 力,經傳動回關節。
> **優勢**:一根腱驅動多關節(手指、肌腱驅動手)、關節耦合(差速器)—— 用純關節無法表達。
> **對照組**:等效的多關節 equality 約束(13.5)—— 同樣行為,兩種表達,比成本與穩定性。
> **規模軸**:腱數 × 每腱路徑點數 × 繞行幾何數。
> **交付物**:`test_tendon`(fixed 腱線性耦合精確、**spatial 腱長 == 幾何最短路徑**、
> 繞行切點連續、腱力功率守恆)+ bench row。**相依**:13.3(腱是一種傳動)。

### 13.5 統一約束求解器(equality / limit / friction-loss / contact 一體)— ✅ 已完成
> **現況**:只有接觸 + ball/hinge 兩種關節,**無關節極限、無乾摩擦、無 equality 約束**,
> 且各自以不同機制處理。
> **設計**:把四類約束收進**同一個凸優化**(MuJoCo 路線),並提供**摩擦錐 seam**:
> 金字塔錐(快、robust)vs **橢圓錐**(物理正確)。求解器本身也做成 seam:
> PGS(現況 `_solve_point`)vs CG vs Newton。
> **優勢**:一套機制涵蓋四類約束 → 新約束種類是**加資料不是加程式路徑**;
> 橢圓錐消除金字塔錐的方向性偏差(斜坡上滑動方向會被錐面稜線吸引)。
> **對照組**:現況的分頭處理;金字塔 vs 橢圓錐的**斜坡滑動方向偏差**是可量的物理量。
> **規模軸**:約束數 × 迭代數;錐型 × 摩擦係數。
> **交付物**:`test_constraints`(關節極限不越界、乾摩擦靜止不漂、equality weld 剛性、
> **橢圓錐斜坡滑動方向無稜線偏差**而金字塔錐有)+ bench(PGS / CG / Newton × 兩種錐,
> 同精度比成本)。**相依**:9.1(關節極限的表達)。

### 13.6 機器人感測器組 — ✅ 已完成
> **現況**:**零**。9.3 的 "sensors / triggers" 是 **gameplay 觸發器**,與此不同,不重複。
> **設計**:觸覺(接觸法向力積分)、IMU(加速度計 + 陀螺,含重力與離心項)、力矩感測器
> (關節/腱)、關節/腱位置速度、測距儀(復用既有 raycast)。統一為「從模擬狀態導出的
> 唯讀量」,每步一次批次求值。
> **優勢**:RL / 控制的觀測空間直接由引擎產生,且與模擬狀態嚴格一致(而非外部近似)。
> **對照組**:有限差分導出的等效量(如數值微分速度 vs 解析速度感測)—— 比精度與成本。
> **規模軸**:感測器數;以及**取樣率**(高頻 IMU 是壓力點)。
> **交付物**:`test_sensors`(**IMU 在自由落體讀數為零**、靜止時讀重力、
> 力矩感測 == ID 算出的 τ、測距儀 == raycast)+ bench row。**相依**:13.1(力矩感測)。

### 13.7 剛體求解器可微(把 `Field` 推進 solver6)— 🔶 部分完成
> **現況**:AD 只覆蓋 `physics/diffsim.mojo` 的**玩具拋體**;`ContactScene6` 完全不可微。
> 4.1 的 emitted-adjoint 快 tape 9× 的結果,目前只在玩具上成立。
> **設計**:`ContactScene6[B, F: Field]` 係數泛型化,讓 DualBatch / RevReal / emitted adjoint
> 都能穿過真實求解器。**接觸的不可微性是核心難點**:接觸開關是分支,梯度在切換處不存在 ——
> 需要平滑接觸(既有 softbody 已是平滑懲罰)或次梯度約定,兩者都要明確標示。
> **優勢**:這是**最大的差異化** —— 讓 4.1 的 9× 從玩具搬到真實求解器;系統辨識、
> 軌跡優化、可微控制全部解鎖。
> **對照組**:有限差分(必然的正確性 oracle)、runtime tape、DualBatch —— 三方 parity,
> 與 `bench_diffsim` 同一套方法論。
> **規模軸**:剛體數 × 接觸數 × 參數數(reverse 的優勢區在參數多時)。
> **交付物**:`test_diffsolver`(**三方梯度 parity**、接觸切換處的梯度行為明確記錄、
> 平滑接觸極限下收斂到解析解)+ bench(參數掃描,對照 4.1 的玩具交叉點是否搬移)。
> **相依**:無硬相依,但成本最高;建議在 13.1/13.2 之後,屆時有真實場景可微。

**實作狀態(2026-08-11)**:已完成 `physics/diffrigid.mojo` —— Field 泛型的
**衝量式**剛體接觸 rollout(鏡射反射 + 恢復係數),含 `tests/test_diffrigid.mojo`
與 `benchmarks/bench_diffrigid.mojo`。**尚未完成**:把 `Field` 推進 1555 行的
`solver6.mojo`(極大量具體化的 Vec3/Real,泛型化風險高,需獨立 wave)。

先做衝量接觸是因為那才是可微剛體模擬真正困難的部分,而量測結果證實了這點:
接觸排程的身分是**觸發步索引**而非反彈次數,y0∈[0.5,1.0] 的 499 個取樣點中
有 366 次排程改變,可用的有限差分探針隨 dt 縮小(dt=1/120 時 2.5e-3 → 1.6e-4)。
solver6 泛型化在這些性質確立之前做,只會得到一個更大的、同樣有這些陷阱的東西。

### 13.8 SDF / 橢球 / 圓柱 narrowphase — ✅ 已完成
> **現況**:`SDFNarrowPhase` **已存在但未接進 solver6**(與 8.1 凸包同樣是「有碼未接線」);
> 橢球與圓柱**完全沒有**。
> **設計**:先接線 SDF(接觸點 = 兩 SDF 最大值的梯度下降極小點,MuJoCo 路線),
> 再補橢球/圓柱解析對。SDF 的賣點是**接觸點數與網格解析度脫鉤**。
> **優勢**:任意隱式形狀(程序化地形、雕刻幾何)不需先轉網格;接觸數可預測。
> **對照組**:同形狀的解析對(球/膠囊已有)—— SDF 的通用性 vs 解析的速度,正是既有
> narrowphase 表的軸;以及網格近似同一形狀的接觸數對比。
> **規模軸**:形狀複雜度 × 接觸點數;SDF 求值成本 × 梯度下降迭代數。
> **交付物**:`test_sdf_narrowphase`(SDF 球 vs 解析球 parity、SDF 對 SDF 收斂、
> 接觸數與解析度無關)+ bench row。**相依**:8.1(narrowphase 接線的既有路徑)。

### 13.9 批次多世界步進 — ⏸ 決策點(與平台整合綁定)
> **狀態**:**不排入實作,先標記** —— 這是 MJX / MJWarp 提供的能力,而使用者明令
> MuJoCo 特定實作不入路線;但「多個獨立世界一起步進」是**通用 RL 需求**而非 MuJoCo 專屬。
> **與被排除項的關係**:實作方式(SoA 批次 vs 多執行緒多世界 vs GPU 批次)取決於
> **要與哪個 RL 平台整合** —— 與場景格式是同一個待決策。
> **若日後開做**:優勢 = 取樣吞吐;對照組 = 單世界 × N 的序列步進與既有 islands 平行;
> 規模軸 = 世界數 × 每世界剛體數。**相依**:平台整合方向拍板。

### Phase 13 建議順序
> **Wave A(低成本、解鎖後續)**:13.1 反向動力學(機件已在)→ 13.8 SDF 接線(碼已在)。
> **Wave B(結構性)**:9.2 浮動基座 → **13.2 縮座標↔接觸耦合**(本階段最關鍵)→ 9.1 關節庫。
> **Wave C(控制能力)**:13.3 致動器 → 13.4 腱 → 13.6 感測器 → 13.5 統一約束求解器。
> **Wave D(差異化)**:13.7 剛體可微 —— 成本最高,但把既有的 emitted-adjoint 優勢
> 從玩具搬到真實求解器,是本專案相對 MuJoCo **唯一可能領先**的方向(MJWarp 目前不可微,
> 可微只在 MJX-JAX)。

---

## Phase 14 — 空氣動力學:LBM 風洞(2026-08-11)

> **起因**:「這個庫做得到風洞實驗嗎?」答案是**做不到**,而且缺的不只是功能。
> 查證結果:`physics/pbf.mojo` / `physics/sph.mojo` **零固體耦合**(grep obstacle /
> solid / rigid / body / coupl 全無命中)、**無進出口邊界**(只有封閉盒 + `_clamp_to_box`)、
> **無表面力積分**、**無湍流模型**。
>
> **但真正的理由是方法選擇,不是待辦清單**:WCSPH 是拉格朗日自由表面法,調給不可壓縮
> **液體**用;風洞是**氣體、高雷諾數**,物理幾乎全在**邊界層**(極薄、近壁、高梯度)與尾流。
> SPH 要解析邊界層需要粒子間距 ≪ 邊界層厚度,在航空 Re 下是天文數字。**就算把上述四項
> 全補上,SPH 的 Cd/Cl 在風洞在意的 Re 下仍會定性錯誤。**
>
> **選 LBM 的理由**:格子波茲曼是網格法、天生極度平行、GPU 友善 —— 而引擎已有 GPU kernel
> 基礎設施(`collision/bp_gpu.mojo`、`geometry/gpu_lbvh.mojo`、`physics/gpu_cloth.mojo`)
> 與均勻網格(`physics/pbf.mojo` 的 counting-sort grid)。**且它是目前引擎裡唯一一個
> 能對上真實文獻數值驗證的物理方向** —— 不像遊戲流體只能「看起來對」。
>
> **SPH/PBF 不被取代**:它們留在自己的優勢區(自由表面、潰壩、晃盪、低 Re 黏性主導流),
> 並作為 LBM 繞流的**對照組** —— 量出它為什麼不適合,本身就是符合 [[優勢區規則]] 的結果。

### 14.1 LBM 核心(D3Q19 碰撞-傳播,GPU)— 📋 規劃中
> **設計**:D3Q19 速度集,BGK 或 TRT 碰撞算子,push/pull 傳播。SoA 佈局(每個速度方向
> 一個 buffer),與 `gpu_cloth` 同紀律 —— 避開 width-3 SIMD、對齊 coalesced 存取。
> **優勢**:每格只與鄰格通訊,是**比布料 Jacobi 更純的平行結構**;無全域求解、無壓力泊松。
> **對照組**:CPU 版同核心(逐位 parity,如 `test_gpu_cloth` 的作法);以及 SPH 繞流。
> **規模軸**:格數(64³ → 256³)、CPU vs GPU。
> **交付物(定律 v3)**:**普通** = 質量守恆、Poiseuille 流對上解析拋物線剖面;
> **整合** = CPU/GPU 逐位 parity、與既有 `DeviceContext` 共享(單車道紀律)、
> 序列化後續跑一致;**極端** = 單格 / 一格厚的域、τ 逼近 0.5(穩定性邊界)、
> 零速初始場、全域週期邊界。**接線** = `pixi run benchmark` 收錄 + `run_tests.sh`。
> bench row:格數掃描、MLUPS(每秒百萬格更新)。**相依**:無。

### 14.2 障礙物:bounce-back / 浸沒邊界 — 📋 規劃中
> **設計**:半程 bounce-back(壁面落在格心與格心之間)先做;再考慮插值 bounce-back
> 以支援非對齊曲面。障礙物由既有的 `SdfShape` 或 AABB/球/膠囊直接體素化。
> **優勢**:**這是「流體看得見固體」的那一步** —— 目前 SPH/PBF 完全沒有。
> **對照組**:同幾何在 SPH 中以邊界粒子表示(既有機制沒有,需一併建,或標記為不做對照)。
> **規模軸**:障礙物表面積 / 格數比;以及壁面對齊 vs 傾斜(半程 bounce-back 在傾斜面上
> 有階梯誤差,插值版沒有 —— 這是一組乾淨的 seam 變體)。
> **交付物(定律 v3)**:**普通** = 無穿透、無質量洩漏、對稱場景給對稱解;
> **整合** = 障礙物來自既有 `SdfShape` / `AABB` / 球 / 膠囊(共用 narrowphase 幾何,
> 不另立一套)、與 14.3 邊界同時開啟仍守恆;**極端** = 障礙物填滿整個域、
> 厚度僅一格的薄板、恰好落在格心上的壁面、障礙物貼齊進口。
> bench:bounce-back vs 插值(誤差 vs 成本)。**相依**:14.1。

### 14.3 進出口邊界(開放流域)— 📋 規劃中
> **設計**:進口固定速度(Zou/He 或平衡態外推),出口零梯度 / convective outflow,
> 側壁自由滑移或週期。**這是「風洞」與「盒子裡的水」的分界。**
> **優勢**:解鎖一切外流問題;也是穩態量測的前提。
> **對照組**:封閉盒(既有 SPH/PBF 的唯一模式)—— 對照能顯示阻塞比(blockage)如何污染 Cd。
> **規模軸**:阻塞比(物體截面 / 風洞截面),這正是真實風洞要修正的量。
> **交付物(定律 v3)**:**普通** = 充分發展流剖面、質量進出平衡;
> **整合** = 與 14.2 障礙物同場景、長時間跑不漂移;**極端** = 零進口速度、
> 反向流、阻塞比 →1(物體幾乎塞滿風洞)、出口緊貼物體(尾流未發展)。
> bench:阻塞比掃描。**相依**:14.1、14.2。

### 14.4 表面力積分(動量交換)→ Cd / Cl — 📋 規劃中
> **設計**:動量交換法(momentum exchange)在 bounce-back 連結上累加力;可選壓力+黏性
> 應力積分作為第二條路徑。時間平均以取穩態係數。
> **優勢**:**把模擬變成量測** —— 沒有這一步,風洞只是漂亮的動畫。
> **對照組**:兩種積分法互為對照(動量交換 vs 應力積分),應在解析度足夠時收斂到同值。
> **規模軸**:解析度(Cd 對格數的收斂);時間平均窗長。
> **交付物(定律 v3)**:**普通** = 靜止流中受力≈0、對稱物體升力≈0、兩種積分法收斂到同值;
> **整合** = 力可回饋給 `ContactScene6` 剛體(流固單向耦合的最小接線),與既有
> 剛體積分器同步;**極端** = 物體完全在牆內、極低 Re(黏性主導)與極高 Re、
> 時間平均窗長短於一個渦脫落週期(必須偵測未收斂而非給出假數字)。
> bench:解析度 vs Cd 誤差。**相依**:14.2、14.3。

### 14.5 湍流模型(LES Smagorinsky)— 📋 規劃中
> **設計**:在碰撞算子的鬆弛時間上加渦黏性 τ_eff = τ + τ_turb,由局部應變率張量算出
> (LBM 的優勢:應變率可從非平衡矩**局部**取得,不需有限差分鄰格)。
> **優勢**:讓可用 Re 從 ~10³ 推到 ~10⁵,即真實風洞區間。
> **對照組**:無模型(DNS-ish)在低 Re 下必須與有模型結果一致 —— 這是模型不污染低 Re 的門檻。
> **規模軸**:雷諾數(這是本階段真正的規模軸)。
> **交付物(定律 v3)**:**普通** = Smagorinsky 常數敏感度在合理範圍;
> **整合** = 低 Re 下有/無模型必須一致(模型不得污染層流區);**極端** = C_s=0
> 退化回無模型、極大應變率下 τ_eff 不得越過穩定界、與 14.2 壁面相接處
> (壁面阻尼缺失會過度耗散)。bench:Re 掃描下的穩定性與成本。**相依**:14.1。

### 14.6 驗證套件:對上文獻數值 — 📋 規劃中
> **這一項是本階段存在的理由。** 引擎現有的物理 gate 幾乎都是「內部一致性」
> (parity、守恆、逐位相同);風洞是**第一個能對上外部標準答案**的方向。
> **驗證目標(皆為文獻標準值)**:
> - 圓柱繞流 **Strouhal 數 ≈ 0.2**(Re 100–10⁵),卡門渦街週期
> - 球 **Cd ≈ 0.47**(Re 10⁴–10⁵);**阻力危機**在 Re ≈ 3×10⁵ 的躍降至 ~0.1
> - 立方體 **Cd ≈ 1.05**;平板垂直來流 **Cd ≈ 1.17**
> - 圓柱 Re=40 的**再循環泡長度**(有標準表格值)
> **優勢**:把「看起來對」換成「數字對」;也是唯一能證明 LBM 路線值得的證據。
> **對照組**:文獻值本身;以及 SPH 在同場景的 Cd(預期定性錯誤 —— **量出來**,不假設)。
> **規模軸**:雷諾數 × 解析度。
> **交付物(定律 v3)**:**普通** = 每個文獻標準值一條 gate(附容差與出處);
> **整合** = 同一場景跑完整管線(14.1→14.5 全開)、CPU/GPU 給同樣的 Cd、
> 序列化中斷續跑不改變時間平均;**極端** = 解析度不足時**必須報告未收斂**而非給出
> 落在容差內的巧合數字(這是驗證套件最容易自欺的地方)、Re 落在阻力危機兩側的
> 躍變、時間平均窗長不足。**接線** = `run_tests.sh` + BENCHMARK_REPORT 專節
> (Cd/St vs 文獻,含收斂表)。**相依**:14.4、14.5。

### Phase 14 建議順序
> **Wave A(骨幹)**:14.1 核心 → 14.2 障礙物 → 14.3 進出口。到此有「會動的風洞」。
> **Wave B(變成量測)**:14.4 力積分 → 14.6 低 Re 驗證(圓柱 Strouhal、Re=40 泡長)。
> **Wave C(推到真實 Re)**:14.5 LES → 14.6 高 Re 驗證(球 Cd、阻力危機)。
> **成本**:XL,約等同一個 Wave 4 項目;但 14.1+14.2 落地後就有可展示與可驗證的東西。

---

## Phase 15 — 數值與可微基礎(2026-08-11,對照前沿模擬軟體的差距分析)

> **起因**:對照 MuJoCo/Drake/Isaac、Houdini Vellum/Ziva、OpenFOAM/Abaqus、
> Warp/Taichi/Brax 四個家族做的差距盤點。結論不是「少做幾個功能」,而是**幾條
> 結構性的線**。本階段收其中槓桿最大的三條;第四條(凸包接線)已是 **8.1**,
> 不重複列 —— 但**提升優先序**,它是成本最低的能力躍升(碼已在,只差接線,
> 正是定律 v3 點名的孤島反例)。
>
> **本階段全部項目遵架構定律 v3**:接上專案 + 普通 / 整合 / 極端三類案例。

### 15.1 稀疏線性代數層(CG / PCG + 稀疏矩陣)— 📋 規劃中
> **現況**:全庫 grep `conjugate.gradient` / `gmres` / `precondition` /
> `sparse.matrix` / `cholesky` / `newton.raphson` —— **零命中**。所有求解器都是
> **迭代式局部法**(PBD 投影、PGS、Jacobi、逐頂點 Newton)。
> **這一條擋住四件事**:隱式 FEM(Abaqus 的 Newton-Raphson + line search)、
> 歐拉流體的壓力投影(∇²p = ∇·u 是全域泊松)、IPC / 保證無穿透(barrier + Newton)、
> MuJoCo 式的 Newton 約束求解器(比 PGS 收斂快得多)。**是槓桿最大的一項。**
> **設計**:CSR 稀疏矩陣 + matrix-free 運算子介面(讓 FEM/流體不必真的組裝矩陣),
> CG 與 PCG(Jacobi / IC(0) 預條件)。先做對稱正定,非對稱(GMRES)留後。
> **優勢**:一項解鎖四條路線;且 CG 本身是可比較、可規模化的乾淨對象。
> **對照組**:同問題用既有的 Gauss-Seidel / Jacobi 迭代解(**引擎兩邊都有,可以真的量**)
> —— 這正是「局部迭代 vs 全域解」的經典權衡。
> **規模軸**:自由度數 × 條件數(condition number)—— 後者才是 CG 真正的規模軸,
> 也是預條件有沒有用的判準。
> **交付物(定律 v3)**:**普通** = 對上解析解(1D Poisson、彈簧鏈)、殘差單調下降;
> **整合** = 接進 FEM 做**隱式積分**(與既有顯式共旋 FEM 同場景對比穩定時步)、
> 既有測試不變;**極端** = 奇異 / 半正定系統(必須偵測而非發散)、零右手側、
> 單自由度、極高條件數(無預條件時 CG 停滯,有預條件時不停滯 —— 這是預條件的存在證明)、
> 迭代上限用盡時回報未收斂。**接線** = `physics/fem.mojo` 隱式路徑 +
> `bench_linalg` 新節。**相依**:無(是其他項的前提)。

### 15.2 布料自碰撞 — 📋 規劃中
> **現況**:grep `self.colli` —— **零命中**。布料只與世界碰,不與自己碰。
> **沒有自碰撞的布料只能做旗幟,不能做衣服** —— 這是能否用於角色的分水嶺。
> **設計**:三角形-三角形 / 頂點-三角形 + 邊-邊 近距離查詢,走既有 BVH(可直接用
> `geometry/bvh.mojo` 的 refit 路徑);排斥用 XPBD 不穿透約束,高速用既有
> `collision/toi.mojo` 的掃掠。**自碰撞是 CCD 最需要的地方**(布料摺疊速度極高)。
> **優勢**:解鎖角色服裝;也讓既有的 DBVH / SAH / LBVH 建樹變體有了**第二個消費者**
> (目前只有寬相在用),它們的優勢區可以在新工作負載上重測。
> **對照組**:無自碰撞(既有行為)—— 量出成本與它換到的東西;以及排斥 vs 掃掠兩條路線。
> **規模軸**:布料解析度 × 摺疊程度(接觸密度)。
> **交付物(定律 v3)**:**普通** = 布料落在自己上不穿透、能量不增;
> **整合** = 與 XPBD 和 VBD **兩個** solver 都要能跑(它們是既有 seam 的兩個變體,
> 只接一邊就是破壞 seam)、與世界碰撞同時開啟、CPU/GPU parity;
> **極端** = 布料完全對摺(接觸點與頂點重合)、單三角形、退化零面積三角形、
> 極高速摺疊(掃掠 vs 離散的判別域)、全部頂點重合。
> **接線** = `physics/gpu_cloth.mojo` + `physics/vbd_cloth.mojo` 的 solver 迴圈。
> **相依**:無(BVH 機件已在)。

### 15.3 comptime 自動伴隨式生成 — 📋 規劃中
> **現況**:`physics/diffsim.mojo` 的 `rollout_ctrl_adjoint` 是**手寫**的伴隨式,
> 已實測比 runtime tape **快 9×**、對 primal 僅 **4.5×**(tape 是 40×)。
> 概念已證明;缺的是**自動生成**。
> **這是本專案相對前沿唯一有結構性優勢的方向**:Warp / Taichi 必須在 **JIT 期**
> 生成伴隨式,Mojo 的 comptime 元編程可以在**編譯期**做 —— 沒有執行期生成成本,
> 且伴隨式與 primal 一起被最佳化。
> **設計**:先做**受限子語言**(算術 + 已知原語的直線程式碼 + 可標記的分支),
> 由 comptime 走訪產生反向掃描。不追求全語言 —— 追求覆蓋物理核心的那個子集。
> **優勢**:把已量到的 9× 從一個手寫函式推廣到整個求解器;且**checkpoint 只需
> 每步一個 bit**(分支決策)而非每運算一節點,記憶體差兩個數量級。
> **對照組**:手寫伴隨式(**正確性的黃金標準** —— 自動生成必須逐位對上)、
> runtime tape、DualBatch 前向、有限差分。**四方對照,全部現成。**
> **規模軸**:參數數 × 每步 flops(既有掃描的兩軸)。
> **交付物(定律 v3)**:**普通** = 生成的伴隨式對上手寫版與有限差分;
> **整合** = 套到 `diffrigid`(可微剛體接觸)與 `rollout_ctrl` **兩個**既有可微路徑、
> 既有 `test_diffsim` / `test_adjoint` 不變;**極端** = 零參數、常數函式(梯度恆零)、
> 分支在每一步都翻轉、不可微點(|x| 在 0)、極長 rollout(checkpoint 記憶體上界)。
> **接線** = `geometry/field.mojo` 新增一個 `Field` 變體,走既有 seam。
> **相依**:無,但 13.7(剛體可微)完成度越高,可套用面越大。

### Phase 15 建議順序
> **先做 8.1 凸包接線**(碼已在,成本最低,且是定律 v3 的孤島反例 —— 補掉它同時
> 示範新標準)→ **15.1 稀疏線代**(解鎖最多後續)→ **15.2 自碰撞**(單項但決定
> 布料可用性)→ **15.3 自動伴隨式**(最高天花板,但最貴)。
> **與 Phase 14 的關係**:14 的 LBM 刻意**不需要** 15.1(格子波茲曼沒有壓力泊松),
> 所以兩階段可並行;但若日後要做投影法 Navier-Stokes 或隱式 FEM,15.1 是前提。
