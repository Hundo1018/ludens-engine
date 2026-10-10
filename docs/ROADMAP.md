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
>
> **狀態(2026-10-09):Wave A / B 全數交付;Wave C 進行到一半後暫停(使用者指示)。**
> 本輪完成 17.0 F12(`f308a05`,架構前置全數收尾)、17.5 破壞 / 破碎(`422589c`..`28e4ca3`)、
> 17.4 載具(`b9bd0fd`、`988a11a`)。**平台整合方向拍板 = C(被宿主引擎嵌入的模擬函式庫,
> RL 平台次要)**(`a93c53d`),解開 17.16 / 17.21 的 gating。剩餘依序:17.14 導航 → 17.15 AI →
> **17.85 分級模擬(2026-10-10 新增)** → 17.16 rollback → 12.1 C-ABI → 17.21 Python 綁定 →
> 17.17 GPU articulation → 17.8 大世界座標;
> 編輯器相關的 17.12 / 17.43 不排。見 [Phase 17 建議順序](#phase-17-建議順序) 的 2026-10-09 / 10-10 修訂。
>
> **增補(2026-10-09,負空間盤點)**:對照 SOTA 引擎盤點「不在路線上」的能力,RL / 機器人以外
> 全數入路線:新條目 **17.44–17.84**(見 [17.44–17.84 增補](#17441784-增補負空間盤點2026-10-09));
> 尚未開工的 17.14 / 17.15 / 17.16 直接擴充範圍;9.1 / 13.8 原標 ✅ 與程式碼不符,改為 🔶。
> 增補項尚未插入上述剩餘順序。

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

> ⚠️ **本清單的排除邏輯已於 2026-08-02 被 [[no-tech-exclusion-principle]] 推翻**:
> 有優勢區 / 有對照組 / 可規模化比較者一律該做,成本高只排後面 wave,不設「不做」欄。
> 網路、導航、GPU-driven 以外的 GPU 剛體、載具、破壞等已於 **Phase 17** 以
> 【優勢區 / 對照組 / 規模軸】重新列入。多媒體(渲染主體 / 音訊 / 輸入)仍走架構分離
> 的獨立層,不是「不做」而是「不在核心 repo」。

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
| **9** | 物理完整度 | 9.1 關節庫(limits/motor/spring/prismatic/weld) · 9.2 浮動基座 · 9.3 過濾層+sensor ✅ · 9.4 接觸事件 ✅ | ★★ | ✅ |
| **10** | 穩健與排程 | 10.1 exact predicates/interval · 10.2 自動依賴 job graph · 10.3 Actor Model 硬化 ✅ | ★★ | ✅ |
| **11** | 程序化與 gameplay | **11.1 Noise ✅** · **11.2 狀態機 ✅** · 11.3 動畫 runtime | ★★ | 🔨 11.1,11.2✅ |
| **12** | 腳本層(架構分離,獨立) | 12.1 core embedding 邊界 · 12.2 Mojo/Python 雙腳本 | ★(gated) | ⏸ 等核心 API 穩定 |

**相依骨牌**:7 是地基(SAH 品質在 solver 用寬相後才計入幀時);8.2 trimesh 依 8.1 的
凸包/narrowphase 泛化(三角 = 退化凸包)、依 7.1(三角 BVH 用 SAH);9 各項大致獨立可並行;
11.3 動畫依 11.2 狀態機;**12 gated on 核心 API 凍結**(架構分離定律,使用者確認後才實作)。

**架構定律 v2 貫穿**:seam 變體(7.1、7.2、10.1)附 parity 方格 + benchmark;新能力
(8.x、9.x、11.x)附功能測試 + 有效能主張處的 benchmark;每項的交付物列於各節。

> **2026-07-22 之後追加(不在上表)**:**Phase 13** 機器人 / 控制(對照 MuJoCo)· **14** LBM
> 風洞 · **15** 數值與可微基礎 · **16** 切換到正式版 Mojo · **[17](#phase-17--遊戲執行期外殼與前沿引擎的能力差距2026-09-03使用者指示盤點)**
> 遊戲執行期外殼(2026-09-03 盤點 + 2026-09-04 覆核;22 條 × Wave A/B/C,涵蓋角色 / 動畫 /
> 查詢 / 工具化 / 導航 / AI / 網路 / GPU 規模 —— 目前所有未完成工項的落點)。

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

### 9.1 關節庫深度(limits / motors / springs / prismatic / weld / cone-twist)— 🔶 部分完成(2026-10-09 校正)
> **狀態校正(2026-10-09,負空間盤點)**:原標 ✅,但程式碼只交付了一部分。
> 已有:縮座標 `physics/chain.mojo:96-97`(`JOINT_REVOLUTE` / `JOINT_PRISMATIC`)、
> `:108-109,130-139`(`lo` / `hi` 與 `limited()`)、`:785` `resolve_limits`
> (`tests/test_joints_lib.mojo`);最大座標 weld 來自 17.5(`physics/joints6.mojo:18`
> `JOINT_WELD`);17.2 的 `AngularDrive`(`joints6.mojo:279`)是姿態驅動 + `max_torque`,
> 不是速度馬達。
> 未做:`Joint6`(`joints6.mojo:14-18` 只有 BALL / DISTANCE / HINGE / BROKEN / WELD)
> 無上下限、速度馬達、彈簧、滑軌、cone-twist;`joints6.mojo` 與 `chain.mojo` grep
> `cone|twist|swing|spring` 只命中註解(`joints6.mojo:24` 寫明「no cone clamp」),
> 沒有對應的欄位或關節型別;縮座標也沒有球關節 / 多自由度關節(Phase 13 開頭
> 「關節型別只有 revolute」的缺口,在球關節這部分仍在)。
> 剩餘工作移至 **17.47**(最大座標)與 **17.51**(縮座標多自由度關節)。
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

### 9.3 碰撞過濾(layers / groups / masks)+ sensors / triggers — ✅ 完成(2026-08-11)
> **成果**:`ContactScene6.set_filter(i, category, mask)` / `set_sensor(i, on)`。
> Box2D 式對稱測試 `(catA&maskB) && (catB&maskA)`,擺在 `_try_pair` 開頭 ——
> **brute 與寬相兩條列舉路徑唯一的匯流點**,所以兩者不可能對「濾掉了什麼」有分歧。
> sensor 的接觸對收在獨立的 `sensor_pairs`,而不是在 `pairs` 裡加旗標,
> 這樣 solve / warm-start / islands / restitution **沒有任何一個迴圈需要認識 sensor**。
> **量測(`bench_filter`)**:兩個佔據同一空間的族群(這才是過濾的優勢區)。
> 過濾後 4.30 ms/step → 0.575 ms/step。**但驅動因素不是接觸數**(254 vs 192 只差 32%):
> `asleep=` 欄顯示過濾場景 192 個全部入睡,未過濾場景只有 88 個 ——
> 生成時互相穿透的箱子被推開、飄回、再被推開,永遠靜不下來。
> 誠實結論:**過濾不是讓接觸解算變快,而是決定場景會不會收斂到靜止**。
> **量測缺陷(自己踩到並修正)**:第一版拿同一堆箱子加/不加分層對比,得出「過濾慢 45%」——
> 那是在比**兩個不同場景**(被過濾的箱子互相穿透,堆疊塌成別的形狀)。
> **定律 v3 三類**(`tests/test_filter_events.mojo` 21 checks,與 9.4 合測)。

### 9.4 接觸事件(began / stay / ended)— ✅ 完成(2026-08-11)
> **成果**:`events_on` 開啟後,每步以 `_emit_events` 對「本步接觸集」與「上步接觸集」
> 做排序合併差分。接觸集是**推導出來的,不是維護出來的**:solver 剛建好本步的接觸,
> warm-start cache 就是上步的同一份答案,所以不需要增量維護、也沒有「刪 body 要失效什麼」。
> 鍵是 `(a, b, feat)` 打包成一個 Int,`feat` 即三角形索引 —— 木箱沿地板滑過時
> **確實是逐三角形地開始與結束接觸**,只用 body pair 當鍵會報成一次不中斷的接觸。
> 事件順序經排序正規化,所以**同一場景在不同碰撞 seam 上事件流逐位相同**(已測)。
> sensor 重疊也進事件流 —— 觸發區不施力,事件是觀察到它的唯一管道。
> **量測**:預設關閉;開啟成本在測試場景 <3%(0.575→0.583 ms、4.30→4.41 ms)。
> **定律 v3 三類**(`tests/test_filter_events.mojo` 21 checks):
> - **普通** = 層矩陣三種組合(全通/同層互斥/單邊拒絕即足夠);
>   sensor 不施力(**穿過它的木箱位置與完全沒有 sensor 的自由落體逐位相同**);
>   首次接觸步 began=1 且 stay=0,下一步 began=0 且 stay=1,瞬移後 ended。
> - **整合** = 過濾/sensor/事件在 brute 與寬相兩 seam 上逐位相同(含事件總數);
>   過濾與 sensor 旗標經序列化來回後行為不變;**靜態網格接觸的事件**
>   (一對 body 攜帶多個以三角形索引區分的獨立接觸)。
> - **極端** = 全零 mask(連地板都穿過)、同層自我排除、兩個 sensor 互相重疊、
>   瞬移使接觸集整批換掉、完全沒有 body 的空場景。

## Phase 10 — 穩健與排程(2026-07-22)

### 10.1 Exact predicates / interval 穩健層(SOTA_GAP M3)— ✅ 完成(2026-08-11)
> **成果**:`geometry/predicates.mojo` —— `orient2d` / `orient3d` / `incircle` /
> `insphere`,三階段自適應:float32 + 誤差界 → float64 + 誤差界 → **精確展開**
> (Dekker/Knuth two-product、two-sum,非重疊展開的首個非零分量即符號)。
> **「精確」是字面意思**:輸入是 float32,加寬到 float64 無損,所以回傳的符號
> 就是實數行列式的符號 —— 不是「更準」,是「對」。
> **接線**:`convex_hull_2d` 的側判斷改走此層(`exact=False` 保留舊路徑當 seam 變體)。
> **量測(`bench_predicates`)**:一般輸入下濾波階段即決定,orient2d 6.76→7.07 ns
> (+4.6%)、orient3d 24.9→32.1 ns(+29%)。刻意構造的退化輸入下 fallback 每次都跑:
> orient2d 164 ns(naive 的 12×)、orient3d 7386 ns(**370×**)—— 後者用的是教科書
> Leibniz 全排列展開,選它是為了能對著定義讀,因為它只在極小比例的呼叫上跑。
> incircle 11.6 µs / insphere 124 µs(這兩列只在精確路徑上計時,沒有便宜的情況可平均)。
> **抓到的真 bug(靠恆等式,不是靠讀碼)**:濾波階段寫成 `Float64(a[0] - c[0])` ——
> **差值在 float32 裡先捨入了**,而 Shewchuk 的 double 誤差界假設沒有。
> 症狀是 `orient2d(a,b,c)` 與 `orient2d(b,c,a)` 給出相反符號。
> 改成 `Float64(a[0]) - Float64(c[0])` 後恆等式成立。
> **誠實邊界**:naive 路徑對**反對稱**是免費正確的(同樣兩個乘積,順序無關),
> 真正會壞的是**循環不變性** —— 換順序會減不同的座標對。實測 naive 在近退化三元組上
> 違反 558/2000(~28%),精確路徑 0。benchmark 那份 cloud 上 naive 的凸包**也是凸的**,
> 這點照實報,沒有挑一個對自己有利的輸入。
> **定律 v3 三類**(`tests/test_predicates.mojo` 31 checks):
> - **普通** = 四個謂詞對可手算的構型正確;與 naive 在**良好分離**的隨機輸入上
>   6000 次零分歧(若有分歧,錯的會是精確那個)。
> - **整合** = quickhull 接上此層;良好分離輸入下 exact 與 naive 的凸包逐點相同;
>   凸包仍能餵進消費它的窄相。
> - **極端** = 恰好共線/共面/共圓/共球(**構造出來的,不是湊出來的**)、差一個 ulp、
>   座標橫跨 1e8、全部點相同、以及任何正確定向謂詞都必須滿足的反對稱與循環不變性。
> **註**:incircle/insphere 依行列式對「提升列」的線性拆成 2/3 個單項式行列式,
> 所以不需要比檔案其餘部分更寬的算術。

### 10.2 自動依賴 job graph(DOTS 式讀寫衝突)— ✅ 完成(2026-08-11)
> **成果**:`scheduler/jobgraph.mojo` —— `DeclaredSystem` trait 讓系統宣告
> component 讀/寫位元遮罩(`1 << ComponentType.ID`),`JobGraphScheduler` 由此推導層級。
> 衝突律:`W_i & (R_j | W_j)`(RAW/WAW)或 `W_j & R_i`(WAR);**讀-讀不是衝突**。
> 最長路徑分層,同層系統彼此不衝突 → **同層順序不影響結果**,
> 所以與 `SequentialScheduler` 是**逐位相同**而不只是等價。
> **量測(`bench_jobgraph`)**:推導 228 ns(**建構一次,不是每 tick**,分開計時,
> 否則會被 tick 數美化)。串列執行推導出的排程 1.169 vs 註冊順序 1.155 ms/tick(+1.2%,
> 這是把順序決定推遲到執行期的代價)。同層並行 0.826 ms/tick(1.40×)。
> **加速上限由工作形狀決定,不是核心數**:6 個系統只有 4 個能重疊,Amdahl 上限 2×,
> 實測低於它是因為 fan-out 四個短系統拿不到四倍吞吐。
> 這就是**系統級平行的真實天花板**,也是為什麼還要在系統**內部**平行(solver 那邊)。
> **誠實弱點(寫在檔頭)**:沒有任何機制驗證宣告與 `apply` 實際碰的東西一致;
> 宣告錯就排程錯。這是所有 DOTS 式排程器共同的取捨,買到的是「相依關係寫在系統旁邊一次」
> 而不是「隱含在別處的清單順序裡」。
> **定律 v3 三類**(`tests/test_jobgraph.mojo` 30 checks):
> - **普通** = 衝突律四種組合(RAW/WAW/WAR 要排序、讀-讀不用);推導出的層級與人工畫的一致。
> - **整合** = 與 `SequentialScheduler` 的世界摘要逐位相同 —— 在 **sparse 與 archetype
>   兩個 backend 上**、串列與 fan-out(1 與 4 workers)都成立;兩 backend 彼此也一致。
> - **極端** = 零系統(tick 是 no-op)、單系統、全部互相衝突(完全串列化)、
>   全部互不衝突(單一寬層)、宣告空集合的系統、宣告全集的系統,
>   以及「空集合系統註冊在全集系統之後也不該繼承相依」。

### 10.3 Actor Model 硬化(既有雛形 → 生產)— ✅ 完成(2026-08-11)
> **修正舊敘述**:原文寫「零測試」已不成立 —— `test_scheduler_parity` 與
> `bench_scheduler` 早已涵蓋 actor 排程器與 sequential 的世界狀態 parity。
> 真正缺的是**投遞語意**:訊息順序、同 tick 可見性、信箱滿了會怎樣、以及兩次執行是否真的一致。
> **成果**:`EntityActorScheduler` 加上**可觀測的背壓**——
> `max_rounds`(每 tick 級聯深度上限)、`mailbox_cap`(單一信箱上限)、
> 以及回報用的 `rounds_used` / `truncated` / `dropped` / `delivered`。
> **設計決定**:溢位丟**最新**的而不是最舊的。因為送信端是按 id 遞增走訪的,
> 「按 sender id 排序的前 cap 則」是訊息集合本身的性質,而「最後 cap 則」會取決於
> 信箱滿之前哪些送達 —— 一個在高負載下悄悄重排的上限比沒有上限更糟,那會毀掉 replay。
> **一個會靜默截斷的訊息系統,是那種只會以「模擬在某台機器上發散了」現形的 bug**,
> 所以每個上限都回報,不只是執行。
> **定律 v3 三類**(`tests/test_actor.mojo` 24 checks):
> - **普通** = wake 階段送出的訊息在**同一個 tick** 內就被收到並處理(16/16);
>   payload 一則不漏;收件匣第一則來自最小的 sender id。
> - **整合** = serial 與 parallel dispatch 的世界摘要、**投遞則數、級聯輪數**三者都相同;
>   獨立重跑一次結果完全一致(replay/rollback 的地基)。
> - **極端** = 空 actor 族群、單一 actor 對自己送信(4 段級聯一個 tick 收斂)、
>   級聯深過上限(**回報 `truncated=True`,不是靜默截斷**)、
>   信箱溢位(cap=4 時保留 sender id 最小的四則、`dropped=12`,且 parallel 下逐位相同)、
>   送給不存在的 entity(丟棄、不計入背壓、也不會讓 drain 迴圈空轉)。
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

### 11.3 動畫 runtime(clip / blend / 狀態機驅動)— ✅ 完成(2026-08-11)
> **成果**:`procedural/anim.mojo` —— `AnimClip`(等間隔取樣關鍵幀)、
> `blend_poses`(三種混合模式)、`AnimPlayer`(cross-fade 狀態)、`pose_to_motors`
> (接上既有 `geometry/skinning.mojo`)。狀態機驅動由 `scheduler/fsm.mojo` 提供,
> 已在測試中實際接起來(`fire` → `is_in` → `play`)。
> **三種混合都保留並比較**(不是挑一個):linear(正規化 lerp)、
> dlb(`skinning.blend2` 的對偶四元數線性混合)、geodesic(`galie.geodesic3` 的 exp/log 測地)。
> **量測(`bench_anim`)**:每骨每幀 —— 取樣 53 ns、linear 43 ns、dlb 61 ns、
> geodesic 157 ns(linear 的 3.7×)、pose→motors 11 ns。
> 骨數 32 與 256 的每骨成本**持平**(該如此:工作量本來就是每骨線性)。
> player 單一 clip 51–60 ns,cross-fade 中 170 ns(3.4×,因為要取樣兩個 clip 再混)。
> **一個讓測試差點變空洞的細節**:**w = 0.5 時正規化 lerp 與 slerp 完全相同**
> (弦的正規化中點就落在大圓中點),所以在中點做比較會看到兩種模式一致到 7 位數、
> 什麼也證明不了。第一版測試正是如此。改在 w = 0.25 量:linear 0.28285、
> geodesic 0.31931(= 等速的精確值),linear **落後 11%**。
> 中點的巧合本身也寫成一條斷言留著。
> **定律 v3 三類**(`tests/test_anim.mojo` 34 checks):
> - **普通** = 恰好在關鍵幀取樣即得該幀、中點內插正確、循環 clip 一個週期後重現;
>   **三種混合在 w=0 與 w=1 都精確退回輸入**(端點會 pop 的混合是不能用的)。
> - **整合** = 混合後的姿態餵進 `skin_motor` 產生有限結果;`StateMachine` 轉移驅動
>   `AnimPlayer.play`;linear 與 geodesic 在能區分的地方確實不同。
> - **極端** = 單幀 clip、零幀 clip、負時間與一千個循環之外的時間、
>   非循環 clip 兩端夾住、零長度 cross-fade(立即切換)、
>   重播正在播的 clip(不倒帶)、以及 **q 與 −q 混合**(同一個旋轉,
>   天真做法會轉一整圈;三種模式的偏差都是 0.0)。

## Phase 12 — 腳本層(架構分離,獨立層)⏸ gated
> **決定(2026-10-09,使用者)**:平台方向 = **C(被宿主引擎嵌入的模擬函式庫)**。12.1 core embedding
> 邊界宣告 **v0.x 凍結**,以 C-ABI 共享庫提供給宿主;12.2 先做 **Python 綁定**,hot reload
> (experiment 分支 H1–H6、R1/R2)之後再接。**修正本節「不入核心 repo」**:Python 綁定是腳本層,
> 放核心 repo 的最上層獨立套件;其測試須**環境隔離** —— 建出的擴充模組以客戶端方式安裝進乾淨環境
> (不用 repo 的 `-I build` / repo 路徑)再測,確保客戶端實際可用。落地見 17.21。

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

### 13.8 SDF / 橢球 / 圓柱 narrowphase — 🔶 部分完成(2026-10-09 校正)
> **狀態校正(2026-10-09,負空間盤點)**:原標 ✅,本節沒有進度註,程式碼對不上:
> 3D SDF 場與 SDF 對 SDF 接觸在 `geometry/sdf3.mojo`,只被 `tests/test_sdf3.mojo` 與
> `benchmarks/bench_sdf3.mojo` 使用;`collision/collider_set.mojo:37-42` 的形狀種類只有
> box / sphere / capsule / hull / trimesh / heightfield,沒有 SDF,所以 **SDF 未接進
> solver6**;橢球與圓柱沒有任何形狀程式碼;本節交付物 `test_sdf_narrowphase` 不存在。
> 剩餘工作(SDF 作為 solver 形狀、橢球、圓柱)移至 **17.52**。
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
> **決定(2026-10-09)**:平台方向 C 為主、RL 平台(B)為次要;批次能力以 17.18(可微子集上的
> `BatchReal[W]`)為現行落點,完整 solver6 批次隨 B 的需求再擴。
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

### 14.1 LBM 核心(D3Q19 碰撞-傳播)— ✅ 完成(2026-08-12,CPU)
> **成果**:`fluid/d3q19.mojo`(速度集、權重、平衡態、tau↔黏度)與 `fluid/lbm.mojo`
> (BGK 碰撞 + pull 串流 + 雙緩衝交換)。SoA 佈局,每個方向一個連續區段。
> **pull 而非 push**:每格向鄰格**收集**而不是散播,只寫自己那一格,
> 所以掃描天生無競態,CPU 參考與未來的 GPU kernel 可以共用同一套索引而不需要 atomics。
> **量測(`bench_lbm`)**:**3.7 MLUPS**(每 op 一格一步,ns/op 即 1000/MLUPS)。
> 16³→64³ 大致持平(3.69→3.49),隨工作集超出快取而略降 —— 這正是「沒有算術強度可躲」
> 的方法變成頻寬受限的樣子。
> **誠實定位**:3.7 MLUPS 對一個直白的純量實作是站得住的,但**遠不及**最好的公開 CPU
> 數字(數十 MLUPS,用跨格 SIMD、融合 collide-stream、以及省掉第二緩衝的 in-place pattern)。
> 那三項都沒做。**做了的兩件事值 20×**:速度集**具現化一次存進 solver**,
> 而不是每格每步呼叫函式重建 19 次(第一版 benchmark 讀到 **0.18 MLUPS**,
> 差距**全部**是配置);串流改成**交換**兩個緩衝而非把一個複製進另一個。
> **未做**:GPU kernel。原規劃是 GPU-first,但本專案 GPU 是單車道且有多 `DeviceContext`
> 掛死的既知地雷,CPU 參考必須先存在才能做逐位 parity ——
> 現在它存在了,GPU 版是乾淨的後續工作。

### 14.2 障礙物:bounce-back / 浸沒邊界 — ✅ 完成(2026-08-12,半程 bounce-back)
> **成果**:半程 bounce-back 直接內建在 `stream()` 裡 —— 若來源格是固體,
> 收到的不是鄰格的分布,而是**本格自己的反向分布**。這一個替換就是半程 bounce-back 的全部,
> 也是為什麼固體除了旗標之外**不需要任何資料**。
> 障礙物體素化:`set_solid_box` / `set_solid_sphere`。
> **量測**:質量守恆到 4e-6 相對誤差(4032.000 → 4032.017,200 步含障礙物)。
> 對稱球在對稱風洞中的尾流 y 方向不對稱度 **5.8e-8**。
> 一格厚的薄板仍能擋住流(板後 −0.0021 = 回流,板側 0.080)。
> **誠實限制**:半程 bounce-back 在**不與格線對齊**的壁面上是一階並有階梯誤差;
> 插值 bounce-back 未做,那是後續的 seam 變體。
> **未做的對照**:SPH 邊界粒子(既有機制沒有,要一併建),暫記為未做而非「不做」。

### 14.3 進出口邊界(開放流域)— ✅ 完成(2026-08-12)
> **成果**:`BC_TUNNEL` —— x=0 固定速度進口(以**當地密度**建平衡態,
> 密度取自流場而非固定,這樣進口才不會變成質量源)、x=nx-1 零梯度出口(複製上游鄰格)、
> 其餘方向週期。**這就是「盒子裡的水」與「風洞」的分界**。
> **量測**:風洞達到穩態(再跑 100 步尾流漂移 8.1e-5,即自由流的 0.13%);
> 尾流速度 0.0205 明顯低於自由流 0.0634。
> **極端**:障礙物**緊貼進口**時質量既不枯竭也不暴漲(992.0 → 983.5)。
> **定律 v3 三類**(`tests/test_lbm.mojo` 28 checks,三項合測 —— 邊界條件與它所修改的
> 串流步驟不可分割):
> - **普通** = 速度集的**矩條件**(∑w=1、一階矩為 0、二階矩 = cs²=1/3、非對角為 0 ——
>   這些正是平衡態所依賴、而非想當然的東西);`opposite(i)` 對每個 i 都真的是 −c_i;
>   平衡態還原其密度與動量;均勻流**恆等保持**(它就是平衡態);
>   受力通道對上**解析 Poiseuille 拋物線,相對誤差 0.28%**。
> - **整合** = 含障礙物時質量守恆;對稱場景給對稱解;風洞達穩態並維持。
> - **極端** = 單格(自己是自己的鄰居)、一格厚的域、τ 逼近 0.5 穩定邊界
>   (ν=5e-4 → τ=0.5015,仍保持有限)、零速初始場**精確維持零**、
>   障礙物填滿整個域(此後沒有流體可守恆)、一格厚薄板、障礙物貼齊進口。

### 14.4 表面力積分(動量交換)→ Cd / Cl — ✅ 完成(2026-08-12)
> **成果**:動量交換法直接內建在 `stream()` 的 bounce-back 連結上 ——
> 流體沿 −c_i 送出 `back`、沿 +c_i 收回,動量變化 2·back·c_i,固體取其反。
> 對所有邊界連結求和就是總力,**不需要表面法向、不需要面積元、不需要重建壓力**,
> 精度與 bounce-back 本身同階。`drag_coefficient()` 換算成無因次係數。
> **這一步把模擬變成量測** —— 沒有它,風洞只是漂亮的動畫。
> **量測(`bench_lbm` 第二張表)**:對上 **Schiller-Naumann 關聯式**
> (對**實驗**的經驗擬合,不是對另一個模擬)。單一解析度吻合什麼也證明不了,
> 所以主張是**趨勢**:球半徑 3→4→5 格時偏差 **41.5% → 32.6% → 26.7%,單調下降**,
> 代價 4.6×。剩餘差距是階梯體素球與數個百分比阻塞比造成的,**兩者都會抬高 Cd** ——
> 這也是為什麼數字是**從上方**逼近關聯式。
> **定律 v3 三類**(`tests/test_lbm_force.mojo` 11 checks):
> - **普通** = 靜止流體中受力 2e-8;對稱球在對稱流中升力 9e-8(對照阻力 0.17);
>   加倍流速時力的成長介於線性與平方之間(**要求恰好 4 倍是要求錯的物理** ——
>   Cd 本身隨 Re 下降)。
> - **整合** = Cd 對上 Schiller-Naumann,且**偏差隨解析度縮小**。
> - **極端** = 完全埋在牆內的固體(沒有連結,力恰為 0)、零進口速度
>   (力 0,且係數回報 0 而不是除以零)、阻塞比 ~55%(Cd = 42.4,是無阻塞的十倍 ——
>   **這正是真實風洞必須修正的量**)。
> **未做**:壓力+黏性應力積分作為第二條路徑(原規劃的兩法互為對照)。
> 目前的對照組是**實驗關聯式**,比第二個數值方法更硬的標準;第二條路徑仍是後續工作。

### 14.5 湍流模型(LES Smagorinsky)— ✅ 完成(2026-08-12)
> **成果**:Smagorinsky 次網格模型內建在 `collide()`。**應變率不需要用有限差分重建** ——
> 在 LBM 裡非平衡分布本身就正比於它,所以整個模型**只在格內**,
> 代價是多掃一次 19 個方向。這份局部性正是 LES 在這裡如此自然、
> 而在投影法解算器裡如此彆扭的原因。
> **優勢區(這條沒有的話模型就是純成本)**:ν=8e-4、u=0.16 的風洞
> (Re~1600,此格數撐不住)——**純 BGK 發散,開 LES 不發散**。
> **量測**:渦黏度近壁 7.9e-5、通道中央 3.4e-6(剪切大的地方大 23 倍);
> **均勻流中恰為 0.0** —— 它是**次網格**模型,不是全域阻尼。
> τ_eff 恆 ≥ τ,所以模型只能**加阻尼**:一個可能降低有效黏度的湍流模型
> 會是穩定性風險而不是穩定器。
> **定律 v3 三類**(`tests/test_lbm_les.mojo` 15 checks):
> - **普通** = 常數為 0 時與純 BGK **逐位相同**;渦黏度不為負;剪切處最大;
>   均勻流中為零且均勻流仍被保持。
> - **整合** = 與障礙物、風洞邊界、力量測同時開啟仍守恆且阻力為正;
>   **高 Re 的存活對比**(上述優勢區)。
> - **極端** = 荒謬的常數 Cs=5(過度阻尼但保持有限,且確實比合理值阻尼更多)、
>   完全靜止的場(精確維持靜止)、單格(沒有東西可剪切)。

### 14.6 驗證套件:對上文獻數值 — ✅ 完成(2026-08-12)
> **成果**:`tests/test_lbm_validation.mojo` —— 其他 LBM 測試檢查「程式做了它被寫來做的事」,
> 這一份檢查「它做的事**是物理**」,方法是拿**與本引擎無關的數字**來對:
> 閉式解、由速度集固定的格子常數、以及擬合**實驗**的經驗關聯式。
> 每個案例都寫明它的**參考來源與容差**,容差由方法在該解析度能給的精度決定,
> 不是由「剛好會過」決定。
> 1. **剪切波衰減 —— 最鋒利的一條**。正弦速度剖面按 exp(−ν k² t) 衰減,
>    擬合這個速率量出解算器**實際擁有**的黏度。實測 **ν = 0.030296 對輸入 0.03,
>    誤差 0.99%** —— Chapman-Enskog 的 ν=(τ−0.5)/3 在真正的解算器裡成立,
>    而不只是在推導裡。
> 2. **音速** cs = 1/√3 = 0.5774,由權重的二階矩固定。壓力脈衝波峰實測 **0.6**
>    (量測解析度是 ±0.05 格/步)。
>    **一個我自己的量測錯誤**:第一版找「最遠有擾動的格」,得到 0.95 ——
>    單格擾動含所有波長,而最快的格子速度是 1 格/步,總有微量訊號彈道超前。
>    那量到的是**彈道極限**,不是音速。改量波峰才對。
> 3. **Poiseuille** 閉式拋物線,兩個解析度:ny=11 誤差 1.17%、ny=31 誤差 0.17%,收斂。
> 4. **Stokes 極限**:Re→0 時 Cd → 24/Re(精確)。實測 Re=0.20、Cd=190 對 24/Re=120,
>    比值 1.58 —— 在因子內,超出的部分是階梯體素球與阻塞比,兩者都抬高 Cd。
> **相依**:14.1–14.5。

## Phase 15 — 數值與可微基礎(2026-08-11,對照前沿模擬軟體的差距分析)

> **起因**:對照 MuJoCo/Drake/Isaac、Houdini Vellum/Ziva、OpenFOAM/Abaqus、
> Warp/Taichi/Brax 四個家族做的差距盤點。結論不是「少做幾個功能」,而是**幾條
> 結構性的線**。本階段收其中槓桿最大的三條;第四條(凸包接線)已是 **8.1**,
> 不重複列 —— 但**提升優先序**,它是成本最低的能力躍升(碼已在,只差接線,
> 正是定律 v3 點名的孤島反例)。
>
> **本階段全部項目遵架構定律 v3**:接上專案 + 普通 / 整合 / 極端三類案例。

### 15.1 稀疏線性代數層(CG / PCG + 稀疏矩陣)— ✅ 完成(2026-08-11)
> **成果**:`numerics/` 套件 —— `CsrMatrix`、matrix-free 的 `LinearOperator` trait、
> `cg` / `pcg`(Jacobi 預條件)、以及對照組 `jacobi_solve`。
> **接線**:`physics/fem.mojo` 新增 `step_implicit`(Baraff-Witkin backward Euler,
> `(M − dt²·df/dx) dv = dt(f₀ + dt·(df/dx)v₀)`),**全程不組裝全域剛度矩陣**。
> **關鍵設計**:`FemImplicitOp` 在建構時把每元素的旋轉 **snapshot 下來**。這不是快取,
> 是把 warped-stiffness 假設寫進資料佈局:固定 R 才使算子**對稱**,
> 而在 CG 迭代中重算 R 會讓算子在迭代之間悄悄改變 —— 那是 Krylov 法唯一無法容忍的事。
> 順帶也更快(極分解每步一次而非每迭代一次)。
> **混合精度(量出來的必要性)**:算子用 float32(引擎狀態就是),但 Krylov 遞迴用 float64。
> 實測 1D Poisson:float32 遞迴在 n=64 收到 1.6e-7,**n=256 直接發散**(殘差 8.4、解偏 4560)。
> 條件數約 2.6e4 吃掉 float32 七位數的大半,剩下的不足以維持搜尋方向共軛。
> **量測(`bench_numerics`)**:同迭代預算下 Jacobi 每迭代便宜約 1.5×,但殘差停在
> 0.90(n=64)/ 0.98(n=1024),CG 是 5e-17 —— 便宜的那個**根本沒收斂**。
> 條件數軸:等對角線時 pcg 與 cg **完全一樣**(64 次、同時間),對角線跨 1e6 時
> 195 → 84 次。**只報後者會讓預條件看起來到處都好,那是量測錯誤而不是好預條件。**
> FEM:軟材料隱式貴 3.7× 且兩者都穩(顯式勝);剛性材料同 dt 下顯式**發散**
> (那一列是「有成本、沒結果」),隱式每步 31 次 CG 迭代但穩定。
> **抓到的自身錯誤**:(1) 停滯偵測用「殘差 32 次沒進步」——錯,CG 最小化的是誤差的
> A-範數而非殘差範數,‖r‖ 本來就非單調;它把正常收斂中的 n=256 系統在第 33 次誤判為停滯。
> 現在 `stalled` 只保留數學上真實的破裂(搜尋方向上 pᵀAp ≤ 0)。
> (2) 測試用的「對角線拉伸」矩陣**不是正定的**(遞增處列和為負),CG 第 1 次迭代就正確回報破裂
> —— **錯的是測試不是解算器**,改成嚴格對角優勢後才成立。
> (3) 套件原名 `linalg` 被 stdlib 同名模組遮蔽(`.mojoc` 建得出來但子模組找不到),改名 `numerics`。
> **定律 v3 三類**(`tests/test_numerics.mojo` 36 checks):
> - **普通** = 三個尺寸對上 1D Poisson 閉式解(worst error 全 0.0)、矩陣確實對稱、
>   迭代次數 ≤ n(理論保證)。
> - **整合** = 顯式在 E=2e5、dt=1/60 炸掉(tip y −2.4e7),隱式同參數穩定、
>   **體積守恆**(0.37494 vs 靜止 0.37500)、**pin 住的節點完全沒動**;
>   軟材料上兩個積分器的差距隨 dt 縮小而收斂(0.209 → 0.0285),
>   證明隱式解的是同一個問題、只是更耗散。
> - **極端** = 零右手側(覆蓋掉錯誤初始猜測)、單自由度、奇異(半正定)系統
>   **回報破裂且回傳有限值**(殘差本身無意義 —— 右手側有零空間分量時根本沒有解,
>   要求小殘差是要求不可能)、迭代預算用盡(`converged=False` 但 `stalled=False`,
>   兩個旗標的區別就是重點)、對角線跨 1e6(**預條件的存在證明**)。

### 15.2 布料自碰撞 — ✅ 完成(2026-08-11)
> **成果**:`physics/self_collide.mojo` —— 厚度下的頂點-頂點排斥,以對稱位置修正
> 施加(與既有 XPBD 約束同一種寫法)。**兩個布料解算器都接上**
> (`cpu_cloth_run` 的 XPBD 與 `cpu_vbd_run` 的 VBD)——
> 它們是同一個 seam 的兩個變體,只接一邊就讓它們不再可比。
> **量測(`bench_self_collide`)**:堆在地板上的長布,`gap=`(最近的**非彈簧相連**對距離)
> XPBD **0.00034 → 0.05999**(厚度 0.06),VBD 0.0060 → 0.0498。
> 0.00034 不是「摺疊」,是**布穿過自己**。
> 成本 XPBD 12.6×、VBD 7.0×。VBD 達不到完整厚度是因為排斥跑在著色掃描**之後**
> 而非每頂點 Newton 之內,下一輪掃描會拉回一部分 —— 照實報,不調參掩蓋。
> **一列專門分離「看的成本」與「解的成本」**:較大的布跑較少步數(尚未堆疊),
> `gap=` 開關兩者**完全相同**(什麼都沒碰到),但仍付 14× —— 那是雜湊重建與 27 格查詢
> 找不到東西的純開銷,也是「布料很少摺疊的場景」實際會付的數字。
> **拓撲鄰居必須排除**,這一點決定了此功能是幫忙還是破壞:粒子的結構/剪切彈簧
> 已經把它固定在與網格鄰居的靜止長度上,若排斥也推開它們就是直接對抗彈簧,
> 布會膨脹或抖動。已用「布高度跨距」把這件事測起來(2.0 → 2.00006)。
> **明說的缺口**:這擋不住高速邊在一步內穿過兩個頂點之間 ——
> 那要 `collision/toi.mojo` 的掃掠,寫在檔頭而不是留給日後發現。
> **廣相選均勻雜湊而非 BVH**:布料粒子大小一致、間距均勻,正是均勻網格最擅長、
> 樹最不擅長的情況;引擎的 BVH 變體留在剛體寬相那個它們真正有優勢的地方。
> **定律 v3 三類**(`tests/test_self_collide.mojo` 12 checks):
> - **普通** = 堆疊布的非鄰居粒子維持約一個厚度;布不膨脹。
> - **整合** = **XPBD 與 VBD 兩個解算器都有效**;厚度 0 時解算器**逐位不變**
>   (既有測試因此完全不用改)。
> - **極端** = 完全重合的粒子(沒有方向可分離 —— 沿固定軸推開,決定性;
>   什麼都不做會讓它們永遠焊在一起)、單一粒子、全部 pin 住、厚度 0、
>   厚度大於整塊布(必須收斂且保持有限)。

### 15.3 comptime 自動伴隨式生成 — ✅ 完成(2026-08-11)
> **成果**:`physics/adjoint.mojo` —— 一個步驟以小型直線程式描述一次,
> `eval_program` 與 `adjoint_program` 都是對該描述的 `comptime for` 走訪,
> 前向與其轉置在**編譯期**展開成直線碼。Warp / Taichi 在 **JIT 期**做同樣的變換;
> 在 comptime 做的差別是**沒有執行期生成成本**,且伴隨式與 primal 一起被最佳化。
> **量測(`bench_diffsim` 新增一列)**:生成版 **8.48 ns**,對照 runtime tape 49.9 ns
> (**快 5.9×**)、手寫伴隨式 5.27 ns(**仍慢 1.61×**)。這個剩餘差距照實報,不抹掉。
> 兩件事把它從 3.4× 縮到 1.6×,值得記下:暫存器檔與常數從堆積 `List` 改成堆疊
> `InlineArray`;opcode 派送改成 `comptime if`,每條指令只展開自己那條規則。
> 兩者之前是 19.7 ns —— **結構本來就對了,差的全是間接層**。
> **受限子語言的理由**:所有運算都對暫存器線性,所以線性映射的轉置**與求值點無關**,
> 反向掃描**完全不需要中間值** —— 每步 1 bit,對照 tape 的每運算 1 節點。
> `program_is_linear` 在**編譯期**判定這件事;含變數×變數乘法的程式會被回報為非線性,
> 而不是被默默地錯誤微分(OP_MUL 刻意**不給規則**:寫一條看似合理的錯規則,
> 會讓梯度靜默錯誤,而測試機制本身抓不到)。
> **抓到的兩個自身錯誤,都同一個原因**:x 完全看不到 vy。
> (1) 常數用錯(G/K/C 與 diffsim 不同)卻仍與手寫版逐位相同;
> (2) drag 折疊順序寫反(`(vy-gdt)*(1-drag)` 而非 `vy*(1-drag)-gdt`)也一樣全對。
> 因為控制只加到 vx、重力/彈簧/阻尼只碰 vy、而 x 積分 vx、y 積分 vy ——
> **兩半永不相遇**,所以任何對 u 的梯度都看不到重力。
> 唯一能看到的觀測量是 **primal y**;第二個 bug 正是靠它抓到的(差 3.5e-4)。
> d(y)/du **恆為 0** 也是結構事實而非巧合,已寫成斷言(伴隨式不得憑空造出耦合),
> 但明確標注它**不是**在測重力。
> **定律 v3 三類**(`tests/test_adjoint.mojo` 27 checks):
> - **普通** = 生成的 primal 與梯度對手寫伴隨式**逐位相同**;對中央差分吻合;
>   對前向 dual 吻合(四方對照)。
> - **整合** = 生成的 primal 對上 `diffsim.rollout_ctrl` 的 **x 與 y 兩者**。
> - **極端** = 零控制、單控制、burst=1、800 步(球停在地上,分支在多數步被觸發)、
>   全零控制,以及**編譯期內省本身**(含非線性乘法的程式必須被判為非線性;
>   兩個 MARK 的程式其 `marks_before` 必須給出固定的位元索引,
>   而不是「最近記錄的那個」)。

### Phase 15 建議順序
> **先做 8.1 凸包接線**(碼已在,成本最低,且是定律 v3 的孤島反例 —— 補掉它同時
> 示範新標準)→ **15.1 稀疏線代**(解鎖最多後續)→ **15.2 自碰撞**(單項但決定
> 布料可用性)→ **15.3 自動伴隨式**(最高天花板,但最貴)。
> **與 Phase 14 的關係**:14 的 LBM 刻意**不需要** 15.1(格子波茲曼沒有壓力泊松),
> 所以兩階段可並行;但若日後要做投影法 Navier-Stokes 或隱式 FEM,15.1 是前提。

## Phase 16 — 切換到正式版 Mojo(2026-08-12,使用者指示)

> **指示**:讓專案跟隨正式版 Mojo 而非 nightly。
> 正式版是 **Mojo 1.0.0 / modular 26.5.0**(2026-08-05),其實**比**專案原本跑的
> nightly beta `1.0.0b3.dev2026071805` **還新**。

### 16.1 API 搬遷 — ✅ 完成(分支 `mojo-stable`)
> - `std.gpu.host` → **`max.gpu.host`**(`DeviceContext`、`DeviceBuffer`)
> - `std.algorithm.parallelize` → **`max.algorithm.parallelize`**
> - `std.gpu` 仍有 `global_idx` 等 device 端 intrinsics;`barrier` 移到 `max.gpu.sync`
> **一個我下錯的結論**:先前只探了 `std.*` 與 `_hal` 就判定「正式版缺 GPU host API
> 與 parallelize」。**兩者都在 `max` 底下**,是使用者指出來的。教訓:Modular 的
> Mojo 標準庫(`std`)與 MAX 提供的套件(`max`、`layout`、`algorithm`)是**兩個
> import root**,缺一個符號要兩邊都探完才能下結論。

### 16.2 `InlineArray` 不再 `ImplicitlyCopyable` — ✅ 完成
> Mojo 1.0 起 `InlineArray`(型別顯示為 `Array`)不再隱式可複製。
> - 8 個持有它的結構補**顯式複製建構子** `__init__(out self, *, copy: Self)`,
>   內容是 `self.f = copy.f.copy()`:`Mat`、`GMV`、`Multivector`、`DcgaEntity`、
>   `ContactManifold`、`SpInertia`、`_ABI`、`_CPair`、`FatObject`。
> - 26 處回傳/傳參補 `^` 所有權轉移。
> **兩處我補過頭**(已修正,值得記):不能從**不可變參考**的欄位轉移
> (`Self(ii.io^, ...)` → `.copy()`);轉移後仍要再用的區域變數也不能轉移
> (`_ABI(a2^, b2^, d2^)` 之後還讀 a2/b2/d2)。
> 這兩種都是編譯器擋下來的,不是靜默錯誤。

### 16.3 Vec3 重構(width-3 SIMD 被禁)— ✅ 完成(2026-08-12,分支 `mojo-stable`)

> **完成判準達成**:`rm -rf build && pixi run test` → **116 [PASS]、all tests passed、exit 0**,
> 在正式版 **Mojo 1.0.0 / modular 26.5.0** 上。

#### 做了什麼
> - `Vec3` = `SIMD[WorldType, 4]`,**lane 3 恆 0**;1509 處三引數建構補 `, 0`。
> - 維度泛型容器用 `comptime PadW[d: Int] = 4 if d == 3 else d`。
>   **必須是條件式**:型別位置呼叫 `def` 不會摺疊,算術式保持符號式
>   (`SIMDLength(((Int(4) // Int(2)) * Int(2)))` 無法與 `SIMDLength(4)` 統一)。
> - `dot` / `lane_min` / `lane_max` 由手寫 `comptime for i in range(Int(w))`
>   改為 `reduce_add()` / `min()` / `max()`。原理由(width-3 的 `reduce_add` 壞掉)已失效,
>   而手寫形式在維度泛型中會拿到未摺疊的 `PadW[D]` 當迴圈上界。
> - API 搬遷:`std.gpu.host` → `max.gpu.host`、`std.algorithm` → `max.algorithm`。
>   **`std` 與 `max` 是兩個 import root**,缺符號要兩邊都探完才能下結論。
> - `InlineArray` 不再 `ImplicitlyCopyable`:9 個結構補顯式複製建構子、28 處補 `^`。
> - 棄用清理:`bitcast` → 指標方法 `unsafe_bitcast`(39 處)、`ptr[i]` → `ptr[unsafe_offset=i]`。
>   `bitcast` 的自由函式形式**沒有**對應替代,scalar 位元重解要走
>   `UnsafePointer(to=x).unsafe_bitcast[T]()[]`。
> - **`SkinVert` 包裝拆除**,兩個理由各自否證(見下)。

#### 一個我自己製造的假象,值得記
> 中途我報告過三個失敗族群(gjk 無限迴圈、solver6/actuator 崩潰、aba 耗盡 comptime 堆積),
> 還為它們寫了根因分析與修復順序。**那些失敗不存在** —— 是我讓背景 sweep 在跑建置的同時
> 前景指令也在建置,又中途 `pkill`,把 `build/` 弄髒了。乾淨重建後四個測試原封不動全過。
> **教訓:本專案的建置寫共用產物到 `build/`,sweep 執行期間不得有任何其他建置;
> 在那種條件下蒐集到的失敗清單不是證據。**

#### Benchmark
> 已重新產生。width 4 的對齊與記憶體流量與 width 3 不同,**散文裡引用的具體數字逐條核對過**,
> 三條已修正:heightfield 的「109→113 ns、完全不成長」實測是 124.6→139.6 ns(+12%,
> 是較大高度陣列的快取行為而非更多工作);orient2d 一般輸入原稱 robust 慢 5%,
> 實測 robust 反而更快(7.75 vs 8.64),兩者已改述為「等價,勝負會在不同執行間換邊」;
> orient3d 退化路徑 370× 實測為 339×。改述一律用比例/量級而非硬數字,避免再漂移。

#### 包裝已全數退場(2026-09-03,commit f3aff20)
> `_Pt`(gjk)、`_LV`(chain)、`_Half`(solver6)**已拆除**。照 `SkinVert` 的規格逐條否證:
> 三者的唯一理由都是「裸 `List[SIMD[_, 3]]` 在 realloc 時損毀」,重測(capacity 0 → 100 /
> 1,000 / 10,000)讀回**零筆錯誤** —— width 3 本來就不是受支援的 SIMD 寬度,改四 lane 已移除病因。
>
> 同一輪順帶關掉一個**陷阱**(非 bug):`collision/queries.mojo` 用 splat 建 root/empty AABB,
> 連 pad lane 一起填 ±1。目前**惰性無害**(`surface_area` 只索引 0..dim-1,且現存每個 box 的
> pad 區間都跨過 0,lane-wise overlap 恆真);但 pad 區間不含 0 的 AABB 會與所有真實 box 判為
> 不重疊,在 broadphase 靜默剔除真對且無跡可循。`AABB.symmetric()` 改為把 pad lane 設為 0,
> `test_aabb` 立閘,陷阱不會再悄悄打開。

---

## Phase 17 — 遊戲執行期外殼:與前沿引擎的能力差距(2026-09-03,使用者指示盤點)

> **緣起**:使用者問「撇開多媒體,與前沿遊戲引擎相比 ludens-engine 還缺什麼」,並要求
> 把答案全數寫進路線圖。**定調**:純模擬 / 數值這一軸(可微物理、PGA 螺旋剛體與關節
> 動力學、LGVCI 變分積分子、MuJoCo 級 reduced-coord + 致動器 / 腱 / 肌肉、FEM / MPM /
> SPH / PBF / cloth 全家桶、LBM 風洞)已達或超過前沿「遊戲」引擎。差距集中在**把這套
> 模擬接上角色、關卡、工具、網路的那一層**,外加物理本身少數幾個工程洞。
>
> **本 Phase 的三條法則(承 [[no-tech-exclusion-principle]] / [[advantage-regime-rule]] /
> [[testing-standard]])**:
> 1. **不設「不做」欄** —— 每項標【現況 / 缺口 / 對照組 / 優勢區 / 規模軸 / seam?】,
>    成本高只排後面 wave。
> 2. **負面結論前先測優勢區** —— 任何「不值得做」的判定,先跑該法在其理論優勢區的量測。
> 3. **定律 v2 + v3** —— 引入 swap 變體者附 parity 方格 + benchmark row(CATEGORY.md §2);
>    每項交付**接上真正會跑到的路徑** + 普通 / 整合 / 極端案例。
>
> 多媒體(渲染主體 / 音訊 / 輸入)不在此列 —— 走架構分離的獨立層(同 Phase 12)。

### 來源盤點對照(使用者 A–H 清單 → 本 Phase 條目)

> 使用者 2026-09-04 再次交付的缺口清單(A 角色 / gameplay 物理層、B 動畫系統組裝、
> C 執行期架構 / 工具化、D 世界查詢完整度、E AI 與導航、F 網路、G GPU 與規模、
> H 半成品 / gated)**逐項落在下表**;任何一格空白即代表漏收。

| 來源分類 | 缺口條目 | 本 Phase |
|---|---|:--:|
| **A** 角色 / gameplay 物理 | 膠囊 kinematic 角色控制器(斜坡 / 台階 / 天花板 / 移動平台 / 蹲伏;SOTA_GAP §4 表第 8 列 ❌) | 17.1 |
| | 主動布娃娃 / 物理動畫(動畫姿勢當 drive target、部分布娃娃、倒地→爬起過渡) | 17.2 |
| | gameplay IK(two-bone / FABRIK / full-body / look-at / foot planting) | 17.3 |
| | 載具動力學(raycast 懸吊 / 輪胎摩擦 / 傳動變速;同為表第 8 列) | 17.4 |
| | 破壞 / 破碎(凸分解 V-HACD、Voronoi、執行期切網格、碎片預算) | 17.5 |
| **B** 動畫系統組裝 | blend tree(1D / 2D)、動畫層 + 遮罩、加法動畫、root motion、retarget、motion matching | 17.6 |
| **C** 執行期架構 / 工具化 | 固定步 ↔ 繪製率解耦的狀態插值(prev↔curr 雙緩衝) | 17.7 |
| | 大世界座標(64-bit / origin rebasing / world partition) | 17.8 |
| | debug-draw 指令佇列(線 / 球 / 文字 / 接觸點,帶生命期) | 17.9 |
| | profiling / tracing hooks(scoped timer、trace event、每系統 frame 預算) | 17.10 |
| | 反射 / 型別註冊表(runtime metadata → 序列化 / 工具 / replication / 腳本綁定) | 17.11 |
| | 可編輯場景 / prefab / 實例化(schema 化、版本化、可 diff) | 17.12 |
| **D** 世界查詢完整度 | shapecast / sweep、closest-point / distance、penetration / depenetration、batched;打真實幾何而非 `BoxProxy` | 17.13 |
| **E** AI 與導航 | navmesh bake、A* / funnel、動態障礙挖洞、crowd 避讓(RVO / ORCA)、off-mesh link | 17.14 |
| | behavior tree、utility AI、blackboard、perception、EQS 式空間查詢 | 17.15 |
| **F** 網路 | snapshot ring buffer、input prediction / reconciliation、delta replication、authority、lockstep 傳輸;**跨平台決定論** | 17.16 |
| **G** GPU 與規模 | GPU 剛體 / articulation solver(領域已 GPU-first) | 17.17 |
| | 13.9 批次多世界步進落地(對標 Brax / Newton 的 RL 吞吐) | 17.18 |
| | 大 island / 高質量比 / 接觸密集堆疊壓力測試(現僅驗到 6 箱塔) | 17.19 |
| **H** 半成品 / gated | 13.7 剛體 solver 可微化收尾(`solver6.mojo` 未穿 `Field`) | 17.20 |
| | Phase 12 腳本層(gated on 核心 API 凍結) | 17.21 |
| **I** 2026-09-27 增補盤點 | 物理材質、kinematic 型別、睡眠 API、日誌、斷言、frame arena、計時器 / 補間、樣條、實體池、事件匯流排 | 17.23–17.25 · 17.32–17.38 |
| | 接觸修改、力場、浮力、可斷裂關節、地形變形、物理 LOD、輸入回放、存檔、繩索 | 17.26–17.31 · 17.39–17.41 |
| **J** Phase 14 遺留 | LBM GPU kernel、插值 bounce-back、壓力 / 黏性應力測力、SPH 邊界粒子對照 | 17.42 |
| **K** 2026-09-30 編輯器邊界分類 | undo / redo 交易層(編輯器依賴的核心能力中唯一未編號者) | 17.43 |
| **L** 2026-10-09 負空間盤點(RL / 機器人除外) | 剛體:複合形狀、網格品質、CCD 形狀覆蓋、關節庫補完、剛體參數 API、力回報、接觸模型、縮座標完整化 | 17.44–17.51 |
| | 碰撞:形狀種類、查詢擴充、CPU 多執行緒碰撞管線 | 17.52–17.54 |
| | 連續體:共用步進契約、布料、毛髮 / 肌肉、體積軟體、流固耦合、水面 / 網格流體、多物理、GPU / 可微、輸出 / 快取 | 17.55–17.63 |
| | 動畫 / 角色 / 程序化:動畫執行期、形變資料、物理角色、移動模式、攝影機 / 序列、PCG | 17.64–17.69 |
| | gameplay:規則框架、戰鬥物理、流程服務、營運邊界、載具家族 | 17.70–17.74 |
| | 執行期:嵌入契約、平台可攜、ECS 表達力、宿主整合 / 綁定、資源治理、觀測 | 17.75–17.80 |
| | 工程與數值:CI / 授權 / 發行、品質工具、效能治理、數值與可微深化 | 17.81–17.84 |
| | 導航 / AI / 網路的增補(尚未開工,直接擴充範圍) | 17.14 · 17.15 · 17.16 |
| | ✅ 與程式碼不符的狀態校正 | 9.1 · 13.8 |
| **M** 2026-10-10 規模盤點 | 實體數 ≫ 玩家可因果交互數時的時間 / 空間解析度分級(tick 分頻、active set、逐 island 品質、可替換分級策略) | 17.85 |

### 現況校正(避免重複高估 / 低估)

> - **已有、不要重列**:9.1 關節庫含 cone-twist / limits / motor / spring / prismatic /
>   weld;9.2 浮動基座 = ragdoll 本體;9.3 layers/masks + sensors/triggers;9.4 接觸事件
>   (began/stay/ended);11.3 動畫 runtime(clip / blend linear·DLB·geodesic / crossfade);
>   11.2 FSM/HSM;`scheduler/gameloop.mojo` 的 `FixedLoop.advance` **已回傳 leftover 分數**
>   (插值用,但無雙緩衝);6.10 全狀態決定論序列化;10.2 讀寫集 job graph;10.3 actor model。
> - **半成品**:13.7 剛體 solver 可微化 🔶(見 17.20);13.9 批次多世界 ⏸(見 17.18);
>   Phase 12 腳本層 ⏸(見 17.21)。
> - **已接掉、不要重列**:`geometry/quickhull.mojo` 曾是定律 v3 的孤島反例,已於
>   2026-08-11(`947a37f`)接上 `SATNarrowPhase.add_cloud`(見 10.1「順帶接掉的孤島」),
>   3D 側對應能力為 `collision/hull.mojo`;17.5 只剩破壞 / 破碎本體。

### Wave 分組與相依

| Wave | 主題 | 項目 |
|---|---|---|
| **A** — 接線 + 工程 table stakes(低風險、槓桿高) | 讓引擎「能被當遊戲引擎用」 | 17.1 角色控制器 · 17.7 狀態插值 · 17.9 debug-draw · 17.10 profiling hooks · 17.13 查詢完整度 · 17.22 範例覆蓋 · **增補** 17.23 材質 · 17.24 kinematic · 17.25 睡眠 API · 17.32 日誌 · 17.33 斷言 · 17.34 frame arena · 17.35 計時器 / 補間 · 17.36 樣條 · 17.37 實體池 · 17.38 事件匯流排 · **增補(2026-10-09)** 17.45 網格碰撞品質 · 17.48 剛體參數 API · 17.49 力回報 / 衝擊事件 · 17.53 查詢擴充 · 17.81 CI / 授權 / 發行 · 17.82 品質工具 · 17.83 效能治理 |
| **B** — 差異化 / 解鎖多項(中風險) | 用 GA / 可微 / 決定論 spine 做別家沒有的 | 17.2 主動布娃娃 · 17.3 角色 IK · 17.6 動畫圖 · 17.11 反射 · 17.17 GPU 剛體 solver · 17.18 批次多世界 · 17.19 solver 硬化 · 17.20 13.7 收尾 · **增補** 17.26 接觸修改 · 17.27 力場 · 17.28 浮力 · 17.29 可斷裂關節 · 17.30 地形變形 · 17.31 物理 LOD · 17.39 輸入回放 · 17.40 存檔 · 17.41 繩索 · 17.42 LBM 收尾 · 17.43 undo 交易層 · **增補(2026-10-09)** 17.44 複合形狀 · 17.46 CCD 形狀覆蓋 · 17.47 關節庫補完 · 17.50 接觸模型變體 · 17.51 縮座標完整化 · 17.52 形狀種類 · 17.54 CPU 碰撞管線 · 17.55 連續體步進契約 · 17.56 布料 · 17.64 動畫執行期 · 17.67 移動模式 · 17.68 攝影機 / 序列 · 17.71 戰鬥物理 · 17.75 嵌入契約 · 17.76 平台可攜 · 17.77 ECS 表達力 · 17.79 資源治理 · 17.80 觀測 |
| **C** — 大工程 / 綁平台決策(排後) | 成本高或先於技術的架構決策 | 17.4 載具 · 17.5 破壞 · 17.8 大世界座標 · 17.12 場景格式(gated) · 17.14 導航 · 17.15 AI · 17.16 網路(部分 gated) · 17.21 腳本(gated) · **增補(2026-10-09)** 17.57 毛髮 / 肌肉 · 17.58 體積軟體 · 17.59 流固耦合 · 17.60 水面 / 網格流體 · 17.61 多物理 · 17.62 GPU / 可微連續體 · 17.63 輸出 / 快取 · 17.65 形變資料 · 17.66 物理角色 · 17.69 PCG · 17.70 規則框架 · 17.72 流程服務 · 17.73 營運邊界 · 17.74 載具家族 · 17.78 宿主整合 · 17.84 數值 / 可微 · **增補(2026-10-10)** 17.85 分級模擬(架構,橫切 scheduler / ecs / physics) |

> **相依骨牌**:17.13 查詢 → 17.1 / 17.4 / 17.15(EQS)的前提;17.11 反射 → 17.12 場景
> 格式 / 17.16 replication 的前提;17.6 動畫圖 → 17.3 IK 的接點;17.18 批次 + 17.20 可微
> 收尾 → 合流為「可微批次模擬」主打(都接 4.2 reverse tape);17.17 GPU 剛體的 parity
> 基準用 6.11 colored CPU 版;17.8 f64 會重觸 16.3 的 Vec3 重構 → 排 Wave C 末;
> **17.12 / 17.16 的傳輸層與檔案格式 gated on 平台整合方向**(同 13.9、同 Phase 13 排除
> MJCF/URDF 之因:格式綁定先於技術)。**2026-10-09 已拍板 = C**:傳輸層交宿主、場景格式跟宿主走
> (glTF / USD),不自訂格式。

### 編輯器邊界分類(2026-09-30,使用者指示)

> **前提**:引擎 UI 已於 2026-07 撤銷(架構分離定律),本 repo **不做圖形化編輯器**。
> 本節把路線圖分成兩類:**(I)引擎核心 —— 只靠程式碼 API 就能完整使用、完整測試**;
> **(II)圖形化編輯器依賴的核心功能 —— 編輯器(若日後以獨立層 / repo 出現)要建在它們上面**。
> (II)的項目本身仍是 headless 的核心 API,但它們的主要消費者是編輯器;缺了它們,
> 外部編輯器無從建起。第三類「編輯器本體」(視窗、面板、gizmo 操作)不在本 repo,列在最後
> 只為把邊界寫明。判準:**把編輯器拿掉,這項功能的價值還剩多少?** 全部還在 → (I)。

#### (I) 引擎核心:不需要編輯器

| 領域 | 條目 | 狀態 |
|---|---|---|
| GA 數學 / 數值 | Phase 1(manifold、screw、Lie 積分器)· 15.1 稀疏線代 · 15.3 comptime 伴隨 · 10.1 exact predicates | ✅ |
| 剛體 solver | Phase 2 · 6.2 恢復係數 · 6.3 形狀 · 6.5 / 6.11 島平行 · 7.2 寬相 · 9.1(🔶,見 9.1 狀態校正)· 9.2–9.4 · 17.0 · 17.23–17.25 · 17.26 · 17.29 | ✅(9.1 除外) |
| 碰撞 / 幾何 | 2.3 · 4.1 CCD · 7.1 SAH · 8.1 凸包 · 8.2 mesh / heightfield · 13.8 SDF(🔶,見 13.8 狀態校正)· 17.13 查詢 · 17.30 地形變形 | ✅(13.8 除外) |
| 關節體 / 機器人 | 6.4 / 6.8 / 6.12 · 13.1–13.6 | ✅ |
| 軟體 / 布料 / 繩 | 6.1 · 6.6–6.9 · 15.2 · 4.3 VBD · 17.41 | ✅ |
| 流體 | Phase 14 LBM · 17.42 | ✅(17.42 有待辦) |
| 力場 / 浮力 / LOD | 17.27 · 17.28 · 17.31 | ✅ |
| 可微 / 批次 | 3.1 · 4.2 · 13.7 → 17.20 · 13.9 → 17.18 | ✅(有待辦) |
| GPU | 3.2 · 17.17 | ✅(articulation 未做) |
| ECS / 排程 | 3.3 · 4.4 · 10.2 job graph · 10.3 actor · 17.34 frame arena · 17.35 計時器 / 補間 · 17.37 實體池 · 17.38 事件匯流排 · 17.7 狀態插值 | ✅ |
| 角色 / 動畫執行期 | 17.1 角色控制器 · 17.2 主動布娃娃 · 17.3 IK · 11.3 動畫 runtime · 11.2 FSM | ✅ |
| 程序化 | 11.1 noise | ✅ |
| 診斷(headless) | 17.33 斷言 / 不變量 · 17.0h NaN 隔離 + 計數器 | ✅ |
| 決定論 | 6.10 快照 · 17.39 回放 · 17.40 存檔 | ✅ |
| 破壞 / 破碎 | 17.5 凸分解 · Voronoi 預切 · 執行期切割 · 鍵結斷裂 | ✅ |
| 載具 | 17.4 raycast 懸吊 · 輪胎 slip 曲線 · 引擎 / 變速 / 差速 · LBM Cd 餵回車體 | ✅ |
| **未做** | 17.8 大世界座標 · 17.16 網路 / rollback(rollback 核心 + 預測 seam + 給宿主的 byte payload;傳輸交宿主)· 12.1 C-ABI 嵌入邊界 | ⬜ |
| **未做,但資產面偏重** | 17.14 導航(bake 可由幾何自動完成,off-mesh link / 區域標記以 API 指定)· 17.15 AI(BT / utility 以程式碼組樹) | ⬜ |
| **未做(2026-10-09 增補)** | 17.44–17.84 全部(其中 17.45 碰撞網格烘焙、17.63 模擬快取、17.80 擷取與追蹤開關也是 (II) 的提供者)· 17.14–17.16 的範圍擴充 · 9.1 / 13.8 的剩餘部分(移至 17.47 / 17.51 / 17.52) | ⬜ |

> 後兩列在無編輯器時**仍可完整使用**(自動烘焙、程式碼建樹),只是手工 authoring 不便;
> 它們的「可存檔資產」形態落在 (II) 的 17.12。

#### (II) 圖形化編輯器依賴的核心功能

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

#### (III) 編輯器本體(不在本 repo,僅為劃界)
視窗 / 相機導覽、gizmo 拖曳、inspector 與 outliner 面板、節點圖編輯器 UI、資產瀏覽器、
undo 歷史 UI、play-in-editor 的外殼。依架構分離定律,若要做,以獨立層 / repo 建在 (II) 之上。

> **結論(2026-10-09 更新)**:(I) 除 17.8 / 17.14 / 17.15 / 17.16 與 12.1 外都已交付;(II) 的 15 項中 10 項已在核心就緒,
> 真正擋住外部編輯器的是 **17.12 場景 / prefab 格式** 與 **17.43 undo 交易層**,
> 其次是 17.21 的 live 調校。
> **2026-10-09 負空間盤點之後**:(I) 新增 17.44–17.84 共 41 項未做,9.1 / 13.8 由 ✅ 改為 🔶;
> 上句「(I) 除 … 外都已交付」只對盤點前的條目成立。(II) 的判斷不變,17.45 / 17.63 / 17.80
> 補上 Profiler 面板與資產匯入兩列的部分提供者。

---

### 17.0 架構前置(Wave A 之前必做;2026-09-27 架構審計)
> **緣起**:使用者要求全程顧及 (1) 模組職責 / 依賴方向 / 循環 / 上層摸底層實作、(2) 責任
> 分離、(3) 錯誤處理分層、(4) 測試分層、(5) 自動化架構索引。對全樹做了一次唯讀審計
> (25 項發現、24 個錯誤處理熱點,每項附 `path:line`),其中 10 項會讓 Wave A 直接蓋在錯的
> 地基上,先修。契約本身見 `docs/ARCHITECTURE.md`。
>
> | 子項 | 內容 | 審計編號 |
> |---|---|---|
> | 17.0a | 架構閘門:`tools/archindex.mojo`(Mojo 寫;`mojo doc` 宣告 + import 圖)與 `check`(層級 / 循環 / 跨套件 `_` 私名),接進 `pixi run test`;修 `bp_bvh` 對 `geometry.bvh._Leaf` 的越界 | F9 |
> | 17.0b | 測試分層:每個測試檔標 `# tier:`,runner 依層執行;以索引機械推導(受測模組橫跨的套件數)而非人工判讀;補 system 層(目前實質為空) | F9 |
> | 17.0c | 契約修正:`diag` 在第 0 層且零引擎依賴(繪圖點用 `SIMD[dtype, 4]` 參數化型別),`geometry` 移到第 1 層;`bvh` / `gpu_lbvh` 移入 `spatial`(GPU 離開數學根套件);`WorldType` 寫死 f32 的 6 處改引用單一來源 | F6 · F17 |
> | 17.0d | `geometry` 補公開 `cross` / `tangent_basis` / 線性 `Mat3x3`,收掉 11 份私有叉積副本 | F8 |
> | 17.0e | **`collision/collider_set.mojo` + `contact_gen.mojo`**:把 collider 註冊與形狀配對分派從 solver6(physics,第 4 層)移回 collision,並讓 3D solver 走 `BroadPhase` seam(目前每步自建自丟 BVH,seam benchmark 量的是引擎不跑的路徑) | F1 · F2 |
> | 17.0f | 讀碼可見的 4 個形狀處理 bug 先寫紅燈測試再修:偏心 mesh / heightfield 在 broadphase 下被剔除、sensor 對 mesh 落入 capsule 萬用分支、軟體把 hull / mesh 當球、CCD 無視過濾與 sensor;分派改為窮舉 + 未支援組合在 API 端拒絕 | F3 · F4 |
> | 17.0g | `BodySet` + `BodyId` + 運動型別(static / kinematic / dynamic,即 17.24 落點)+ solver 自有的 snapshot / restore(serialize 不再直接改 13 條平行 List) | F5 · F20 |
> | 17.0h | 錯誤政策落地到 Wave A 會碰的 API:邊界 `raise`(`add*` / `add_joint` / `step_soft` 參數 / `TriMesh` / `HeightField`)、步末 NaN 隔離 + `diag` 計數器 + 注入 NaN 的測試 | F10 |
> | 17.0i | 執行期容器 `gameplay/runtime.mojo`(擁有 `World + ContactScene6 + FixedLoop` 與位姿→transform 同步):17.1 / 17.7 需要的「有狀態執行期」目前無處可放 | F15 |
>
> **Wave B 入口前置**(不擋 Wave A;**solver6 拆分 ✅ 2026-09-29 `01cd3d0`**:`contact6` / `joints6` / `islands` / `ccd6` / `soft_couple` 為作用在 `BodySet` 上的自由函式,solver6 2787→~1570 行,身分閘門 golden 逐節相同;**單一 device context 擁有者 ✅ 2026-09-29(17.17)**:引擎內不再有 `DeviceContext()`,`gpu_cloth_run` / `gpu_vbd_run` 包裝移除,測試自持 context;FSM 移動已於 17.0c 完成;**F12 `chain` 稠密解移 `numerics`(`numerics/dense.mojo`: `solve_dense` / `solve_dense_checked`)+ 地面接觸走 `ColliderSet`(`Chain.resolve_contacts` 經 `collision.world_query.nearest_surface`)+ `FloatingChain` 改走公開 `Chain.set_base_motion` ✅ 2026-10-08 `f308a05`**,身分閘門 golden 既有各段逐位相同,設計筆記 `docs/design/17.0-f12-chain.md`;17.0 架構前置至此全數完成):solver6 依 13 個職責群拆分為作用在 body view 上的自由函式(17.17 / 17.18 / 17.20 的第一個 commit)、`chain` 的稠密解移 `numerics` 與地面接觸改走 `ColliderSet`(17.2 前)、單一 device context 擁有者(17.17 前)、FSM 移到 `procedural` 之下可被動畫圖使用(17.6 前)。
> **已刪除(2026-09-29,使用者決定)**:舊 2D 物理路徑(`physics/{solver,step,rigidbody,forces,body,integrator}.mojo`)連同只為它存在的 `test_physics_dynamics`、`test_physis`、`bench_physics`、`examples/20_contact_solver_2d.mojo` 一併移除(範例編號 20 留空)。`CollisionPipeline`(collision 層)保留,現在只由其測試使用;`ContactSolver` 2D seam 列自 CATEGORY §2 移除。`BENCHMARK_REPORT.md` 是產生物,其中的 2D 接觸求解器段落要到下次重新產生才會消失。
> **驗收閘門(重構類)**:行為不變的重構以「全套測試 stdout 逐位相同(去除計時行)」為身分閘門,不是只看綠燈。

### 17.1 Kinematic 角色控制器 — Wave A
> **現況**:無 —— SOTA_GAP §4「10 能力」表第 8 列(character controller / vehicle)❌,
> 自 2026-07-10 盤點後從未排程,本節是它第一次進路線圖。`physics/solver6.mojo` 只有動態剛體;`SceneQuery`(`collision/queries.mojo:28`)
> 只有 raycast + overlap(且打在 broadphase 的 `BoxProxy` 上,非真實幾何 → 見 17.13)。
> **缺口**:膠囊 kinematic controller、地面偵測 / 斜坡上限 / 台階上下、天花板、移動平台
> 速度繼承、擠出解算(depenetration)、蹲伏 / 尺寸切換、與動態剛體的雙向推擠。
> **對照組**:UE `CharacterMovementComponent`、Unity `CharacterController`、Godot
> `CharacterBody3D`、Jolt `CharacterVirtual`。
> **優勢區**:低 —— 純工程 table stakes。邊際差異化:controller pose 用 motor 表示,與
> GA 變換層一致(免 quat↔mat 來回)。
> **規模軸**:N 個 controller × M 次 move-and-slide 迭代 / 幀;與靜態關卡三角數。
> **seam?**:是 —— 掃掠底層(raycast 近似 vs 真 shape-sweep)→ parity(同場景落點一致)+ bench。
> **交付**:接 trimesh/heightfield 關卡;普通(平地行走)/ 整合(移動平台 + 動態剛體雙向)/
> 極端(卡縫、零長度法向、瞬移、極陡坡、天花板夾擠)。

> **進度:✅ 2026-09-29** `gameplay/character.mojo`:`CharacterController` 以 capsule sweep(17.13)做 move-and-slide;台階以「支撐面高度 − 腳底」判定(圓底卡在高箱邊角時抬升看似 < step_height,實際箱高才算數);斜坡上限;邊角支撐面以短射線取真實表面法向;天花板截斷上升;起跳期間不判地面;移動平台(kinematic/dynamic)速度繼承;對動態剛體以速度差施加推擠衝量並喚醒;擠出;蹲伏(站起受阻則拒絕);`teleport`。`tests/test_character.mojo` 21/21(平地、20° 可爬 / 60° 不可爬、0.2 台階可上 / 0.6 擋住、跳撞天花板、1 m/s 平台載運 ~1 m、推箱、生成於牆內擠出、靜止 60 步不漂移、雙牆夾擠有限值、低天花板拒絕站起、20 m 落地)。`bench_character`:空地 ~3.5 µs / update,N=256 障礙 ~33 µs(隨查詢前置線性成長)。**待辦**:seam(raycast 近似 vs shape-sweep)對照、接 `gameplay.runtime`(目前由呼叫端每步呼叫 `update`)。

### 17.2 主動布娃娃 / 物理動畫 — Wave B
> **現況**:9.2 浮動基座 + 9.1 關節庫給了 ragdoll 本體;`procedural/anim.mojo` 給姿勢。**兩者未接**。
> **缺口**:以動畫姿勢為 drive target 的關節馬達(PD / articulation drive,前饋可用 13.1 RNEA)、
> 部分布娃娃(骨骼遮罩混合 physics vs animation)、受擊反應脈衝、倒地→起身過渡、blend in/out 權重。
> **對照組**:UE `PhysicalAnimationComponent` / Physics Control、PhysX articulation drives、Unity active ragdoll。
> **優勢區**:中 —— screw/motor 關節動力學天生可微 → drive gain 與 blend 權重可用梯度調
> (對照組多為手調);變分積分子(4.1b)使長時間 ragdoll 更穩。
> **規模軸**:骨骼數 × 子步數;blend 權重掃描下的姿勢追蹤誤差 vs 成本。
> **seam?**:是 —— 「動畫姿勢→關節目標」實作:純 PD vs 逆動力學前饋 → parity(同軌跡追蹤)+ bench。
> **交付**:接 `chain`/`floating` + `anim`;普通(全 ragdoll 自由落)/ 整合(上半身 ragdoll +
> 下半身動畫驅動同一骨架)/ 極端(gain→∞、目標跳變、零質量 link、單影格切換)。

> **進度:✅ 2026-09-29** 建在 `ContactScene6` 的最大座標關節上(Unity / UE ragdoll 同路線),故 `chain` 的前置重構對此路線非必要(仍列在 17.0)。`physics/joints6.mojo` 新增 `AngularDrive`:以驅動器**自己的** hertz / zeta 算 Box2D v3 軟係數,沿世界三軸把 b 相對 a 的姿態拉向目標,累積衝量夾在 `max_torque·h`;`ContactScene6.add_drive`,串行子步中 warm start + 求解(不進 relax),驅動器邊併入 island,島平行 / GPU 路徑遇驅動器退回串行 / 拒絕,`remove_body` 檢查引用。`gameplay/ragdoll.mojo`:`Ragdoll`(每骨一箱 + 父子球關節 + 驅動;逐骨遮罩決定模擬或以 kinematic `move_to` 跟隨動畫 = 部分布娃娃)、`follow` / `set_strength`(0 = 軟癱)/ `hit` / `physics_pose`、`blend_world`(起身過渡,權重 0 即動畫本身);`procedural/anim_graph.to_world`(FK)。`tests/test_ragdoll.mojo` 13/13:直腿被驅動成動畫姿態(8 Hz 穩態下垂 3.8°、20 Hz 0.7° —— 軟驅動無積分項,下垂隨剛性下降)、軟癱時垂 30°;**零上限驅動與無驅動逐位相同**(seam parity);動畫骨盆行走時 kinematic 追蹤誤差 1.2e-7、髖關節間隙 1.1 mm;受擊峰值 17.6° 後 1.5 s 回到受擊前穩態;1000 Hz 驅動有限且誤差 0。`bench_ragdoll`:驅動器使每幀成本增加約 13–40%(N=1..128 條腿)。**待辦**:驅動器序列化、關節角度限制(膝單向)、起身時的姿態匹配與地面對齊、以 PD 積分項消除穩態下垂(可選)。

### 17.3 角色 IK — Wave B
> **現況**:`experiments/exp_autodiff.mojo` 的 AD-IK probe(未接線);`physics/chain.mojo`
> 的 `point_jacobian`(robotics 用,非 gameplay)。
> **缺口**:two-bone IK(閉式)、FABRIK、full-body IK、look-at、foot planting / foot-lock、
> hand IK,接進 `anim` 的 pose pipeline。
> **對照組**:UE Control Rig / IK Rig、Unity Animation Rigging、FinalIK。
> **優勢區**:中高 —— motor/bivector 表述 + 既有前向 / 反向 AD → **可微 IK**(梯度對骨長 /
> 目標 / pole);閉式 two-bone 與 AD-IK 互為交叉驗證。
> **規模軸**:鏈長(DOF)× 迭代數;閉式 vs 迭代 vs AD 的交叉點。
> **seam?**:是 —— IK solver 家族(analytic two-bone / FABRIK / Jacobian-AD)對同一目標的
> 末端誤差 parity + 各自成本 row。
> **交付**:接 `anim` + skinning;普通(伸手碰點)/ 整合(移動中 foot-lock 不滑步)/
> 極端(不可達目標、奇異姿態、目標落在關節上、pole flip)。

> **進度:✅ 2026-09-29** `procedural/ik.mojo`(只吃關節位置,不依賴 collision 層):`two_bone`(餘弦定理 + pole 向量,骨長依構造保持;不可達則沿目標伸直;pole 落在目標線上退回目前膝側;零長骨 / NaN 目標回傳輸入)、`fabrik`(固定根)、`fabrik_multi`(多末端:胸腔掛兩臂,中繼點取各鏈後向提議的質心並拉回其繞骨盆的球面)、`look_at`(錐角限制)、`foot_plant`(地面高度 / 法向由呼叫端的世界查詢提供)。`tests/test_ik.mojo` 27/27(解析 vs FABRIK 同一腿末端相同 = seam parity;坡面靜態箱上以 `ray_cast` 找地面後貼腳、傾角 = 坡角、腿 IK 到位;雙手多末端到位)。`bench_ik`:解析 two-bone 18.7 ns vs 同腿 FABRIK 324 ns(約 17×;FABRIK 含 List 配置);FABRIK 64 關節 70 µs / 38 次迭代。接線:`examples/24_locomotion_graph.mojo` 每幀以世界查詢貼腳 + two-bone 解腿。**待辦**:關節角度限制(膝只能單向、肩錐)、IK 結果轉回逐骨旋轉寫入 `Pose`、全身 IK 的質心 / 平衡約束。

### 17.4 載具動力學 — Wave C
> **現況**:無(與 17.1 同屬 SOTA_GAP §4 表第 8 列 ❌)。
> **缺口**:raycast 懸吊車體(彈簧-阻尼 + 輪胎 slip / friction 曲線 + 引擎扭矩 / 變速 / 差速)
> 或約束式車輪;空氣阻力可接 14.4 的動量交換 Cd。
> **對照組**:PhysX Vehicle SDK、Jolt `VehicleConstraint`、UE Chaos Vehicles、Rapier。
> **優勢區**:低-中 —— 車輛動力學本身是 table stakes;差異化在「用 LBM 風洞(14.4)的 Cd
> 餵回車體阻力」形成 LBM↔剛體耦合示範,別家沒有。
> **規模軸**:車輛數 × 子步;輪胎模型保真 vs 成本。
> **seam?**:是 —— 車輪接觸:raycast 近似 vs 真 shape-cast → parity(同路面同落點)+ bench。
> **交付**:接 solver6 + queries;普通(平地加速煞車)/ 整合(斜坡、跳台落地、多車)/
> 極端(翻車、車輪懸空、極低 / 極高摩擦、瞬移)。

> **進度:✅ 2026-10-09** 車是真的 `ContactScene6` 動力學體(一個會碰撞、翻車、睡眠的盒),輪子不是剛體——每步在 `scene.step` 前由 `gameplay/vehicle.mojo` 的 `Vehicle.update` 以 impulse 施力(經 `Body6.apply_impulse`,不繞過 solver6),查詢走 `collision.world_query`(射線 / 球掃 / 膠囊掃)。**檔案**:`vehicle.mojo`(`Vehicle[W]` / `VehicleSet` / `VehicleConfig` / `Aero`)、`vehicle_wheel.mojo`(seam)、`vehicle_tire.mojo`(輪胎)、`vehicle_drive.mojo`(引擎 / 變速 / 差速)、`vehicle_tunnel.mojo`(LBM 風洞);`diag` 新計數器 `VEHICLE_FORCE_DROPPED`。**懸吊**:彈簧 + 壓縮 / 回彈雙速阻尼 + bump stop + 防傾桿;阻尼力以隱式上限截斷(不能在一步內反轉相對速度)。**輪胎**:正規化 Pacejka「magic formula」(B,C,E 三個數,峰值位置數值定位後除掉,峰在 slip 比 0.125、鎖死剩 69 %),縱向 / 側向各以自己的峰值 slip 正規化後取向量模長,等於**摩擦橢圓**(煞車中轉向會損失側向抓地,任何方向的力都不超過 μFz);μ 以地面 body 的 `friction`(17.23)相對 solver 預設 0.5 縮放,地面 μ = 0 就完全沒有抓地。**輪胎力是隱式解的**:`F = Grip(a − bF)`(a = 無輪胎力時步末的滑移速度,b = 一牛頓使其減少多少,縱向含輪的轉動慣量),`solve_axis` 在曲線上升支上二分求不動點,所以停在斜坡上不需要先蠕動、剎死的輪不會被路面轉動(顯式模型在低速需要 `dt·μFz·R²/(I·κp·v) < 2`,低速時差 100 倍)。滑移以「重力作用這一步後」的速度計算,因此 15° 斜坡上煞車保持 4 秒移動 < 0.15 m。**所有輪讀同一個步初底盤狀態、impulse 加總後一次施加**(逐輪施加會讓第一個輪改變下一個輪看到的 slip——量到左右輪側向力正負交替)。**傳動**:分段線性扭矩曲線、離合在起步轉速打滑、紅線斷油、收油門引擎煞車、自動變速(遲滯 + 換檔時間扭矩歸零)、倒檔由「往後油門 + 低速」選取、FWD / RWD / AWD(中央扭矩比),軸差速 **開放 / 限滑(預載 + 速差鎖定,封頂)/ 鎖死**(皆守恆軸扭矩)。**輔助**:ABS(煞車扭矩上限 0.95·μFzR,輪不鎖)與循跡控制(驅動扭矩上限 0.9·μFzR)可關。**空氣動力**:`Aero`(ρ、Cd、迎風面積、Cl、風)阻力 `½ρCdA|v|v` 與下壓力,阻力一步最多把相對風速減到 0。
> **LBM 耦合(差異化)**:`vehicle_tunnel.car_cd(CarShape)` 在 `fluid.lbm` 風洞(動量交換測力,14.4)跑一個體素車,回傳時間平均 Cd;`scaled_cd` 對已知參考車校準後交給 `Aero.from_cd`。實測(48×24×24,Re≈35,800 步取後 200 步平均):磚形 Cd(格子)**6.20**、斜引擎蓋 + 船尾 **5.63**(−9.2 %,迎風面積同為 66 格),校準磚 = 0.45 → 流線 0.409;帶入同推力(1800 N)的車,模擬極速 **51.8 → 54.2 m/s**(預測 52.3 → 54.9;比例 √(Cd 比) 在 2.5 % 內)。**誠實的限制**:格子 Re 與路上車差 4 個數量級、階梯體素、無地面,所以**絕對 Cd 是格子數,可信的是形狀排序與接線**;高解析度 / GPU 風洞(`lbm_gpu`)的 Cd 可原樣接入。
> **seam**:`WheelCast` trait(`RayWheel` / `SphereWheel` / `CapsuleWheel`,編譯期選擇 `Vehicle[W]`)。`tests/test_vehicle_wheel.mojo` 133/133:平地、20° 斜坡(對解析的輪心高度 `h = 安裝高 − 坡高 − R/cos` 在 3 mm 內)、heightfield 三變體輪心距離 / 接觸點 / 法向相同(< 2–6 mm);**差異被當成行為斷言**:12 cm 路緣前 0.1 m 處射線仍看見低路面而球掃騎上邊緣(輪心較高),窄 10 cm 坑射線落入(在行程內找不到路面 = 懸空)而掃描橋過;牆貼著輪胎時掃描回退成射線,不會讓牆擋住下方路面。整車層級:同一段 330 步的加速 + 轉向,球掃 / 膠囊掃終點與射線差 < 1 %。`bench_vehicle`(N 車 × 步,`VehicleSet` 共用一份 pose 列表):**射線 13.6 µs / 球掃 13.7 µs / 膠囊掃 23.0 µs 每車步**(N = 1),N = 128 時 19.5 / 24.2 / 28.1 µs——**投射不是主要成本**(平面上的球掃兩步就收斂),輪胎隱式解與線性的碰撞體前置過濾才是;每車成本隨車隊上升是因為每個輪查詢都掃全部碰撞體(同 world_query)。
> **測試**(新增 4 檔,全過):`test_vehicle_drive` 62(輪胎曲線歸一化 / 奇函數 / 單峰 / 摩擦橢圓上界;`solve_axis` 不動點殘差 < 12 N、奇對稱、剛接觸會黏、旋轉輪取滑動值;扭矩曲線內插與截止、檔位比、轉速 / 紅線 / 引擎煞車;三種差速守恆軸扭矩、限滑封頂、不反轉較快輪的扭矩)、`test_vehicle_wheel` 133、`test_vehicle` 88(**普通**:停車胎載和 = 車重 ±120 N、停車 5 秒不爬行;全油門 6 秒 > 22 m/s、直行 z < 0.3 m、換檔、不傾斜;**煞車距離 21.0 m(理想 v²/(2μg) = 20.4 m)**,ABS 勝鎖死,峰值減速 1.12 g;煞車距離隨 v² 縮放;穩態轉向半徑對自行車模型(容許不足轉向);倒車 / 倒檔切換;手煞。**整合**:15° 斜坡煞車保持、無煞車滾下、20° 爬坡、2 m 落下(底盤從未碰路,最低 y > 0.42,回到同一車高 ±2 cm)、坡道跳台(滯空 > 15 幀、落地四輪直立)、追撞(動量共享 50–120 %)、推木箱、開上動態木板(輪回報板為地面、板不被壓穿)、四車 `VehicleSet`、起伏 heightfield 穿越 25 m+、分裂 μ 路面限滑勝開放。**極端**:μ_eff = 10 高速急轉**翻車**(最小 up = −0.98;之後靜止)、車頂朝下(0 接地、輪胎力恰為 0、不穿路)、四輪懸空(自由落體 −14.7 m/s、水平速度不變、轉速受紅線限制、未驅動輪經軸承摩擦減速)、μ = 0(油門空轉、煞車轉向無效、TC 在 μ=0 時削扭矩不空轉)、μ = 100(停車 11.2 m、減速 2.2 g 由煞車扭矩決定)、瞬移(無速度尖峰、無被丟棄的力;瞬移進路面內被推出後在 0.7 m 車高穩住)、底盤速度非有限(計數、不施力、不 crash)、底盤被移除(計數)、錯誤設定 raise)、`test_vehicle_aero` 25(力律;滑行對解析律 0.35 m/s 內;下壓力;三個 Cd 的極速對 `推力 = ½ρCdAv² + 滾阻` 在 6 % 內且單調;LBM 磚 vs 流線 Cd;Cd = 0、Cd = 1000 只停不倒車)。
> **決定**:forward = +X、up = +Y、right = +Z;輪胎力作用在路面往輪心 70 % 高度處(`tire_force_lift`,減少每牛頓側向力造成的車身側傾);底盤用 `Never sleep`;打滑保護以重力預測(`VehicleConfig.gravity` 須與場景重力一致);開放差速的近似(見待辦);不實作約束式車輪。
> **待辦**:開放差速目前是「平分扭矩」,真開放差速兩輪扭矩被抓地較差的輪限制(分裂 μ 路面上抓地輪應被一併削弱,現在只有限滑勝過開放這一個比較);Ackermann 轉向、前束 / 外傾;輪的非懸吊質量(輪是運動學的);車輛狀態(輪速、檔位、轉向角)未入快照(同 17.29);拖車 / 多軸 > 2 輪每軸;進階輪胎(鬆弛長度、溫度、載重敏感度);`CapsuleWheel` 的接觸點固定在輪中央平面下(側緣接觸只影響法向);引擎轉動慣量(換檔時 rpm 瞬變)。

### 17.5 破壞 / 破碎 — Wave C
> **現況**:無破壞 / 破碎能力。凸包這一塊的前置已備妥:2D `geometry/quickhull.mojo`
> 與 3D `collision/hull.mojo`(`HullShape` + `_prune_interior`)都已接進 narrowphase
> 與 solver6(2026-08-11 `947a37f`),破碎產生的新凸包有現成入口。
> **缺口**:凸分解(V-HACD 類)、預切(Voronoi / 圖樣)破碎、執行期網格切割 + 新凸包生成、
> 碎片島管理 + 預算 / 睡眠、接縫鍵結斷裂(9.1 有 weld,缺斷裂閾值 + 事件)。
> **對照組**:UE Chaos Destruction、Havok Destruction、NVIDIA Blast。
> **優勢區**:低 —— 純工程。小加值:exact predicates(10.1)使切割 watertight;破碎後
> island 平行(6.11)現成。
> **規模軸**:碎片數 × 接觸密度;切割前處理成本 vs 執行期。
> **seam?**:是 —— 凸分解演算法變體對同一網格的體積覆蓋率 + narrowphase 結果一致。
> **交付**:凸分解 → 預切破碎 → 執行期切割;
> 普通(牆被打穿)/ 整合(碎片與既有剛體 / 軟體碰撞、落進 island sleep)/
> 極端(退化三角、共面、單一碎片、一次切上千片)。

> **進度:✅ 2026-10-08** 全鏈接進真路徑(碎片是 `ContactScene6` 的 hull 剛體,不是旁路)。**幾何**(`geometry/`):`polytope.mojo`(float64 閉合三角網的凸多面體:增量凸包、平面切分、體積 / 質心 / 慣量、接縫面積 / 中心;切分按邊鍵建新頂點,兩側共用同一索引故 watertight;`simplified` 只留真角點,否則 Voronoi 胞切十幾刀後可達數千個共線點)、`convex_decomp.mojo`(體素化 + **`ConvexDecomposer` seam 兩個變體**:`SplitDecomposer` 階層軸平面切分、`ClusterDecomposer` 體素 k-means)、`fracture_cut.mojo`(Voronoi 預切——精確鄰居剪枝:切面距離 `|sj-si|/2` 小於胞半徑才可能有影響,所以先切最近 12 個再只切 2R 內的;`cut_by_planes` 多平面執行期切;胞的切面帽帶鄰居 seed 為標籤)。**物理**(`physics/`):`JOINT_WELD`(ball + 三軸角鎖,參考相對旋轉寄存在 `axis_a` / `rest`,結構與快照格式不變;3D 場景原本只有 ball / distance / hinge)、焊接中的兩體不互相碰撞(斷開後下一步恢復);`fracture.mojo` 的 `FractureSet`:`spawn`(碎片 → `add_hull`,質量 / 慣量取自多面體)、`bond_neighbors`(共享 Voronoi 面 → 焊接,斷裂力 = `stress × 接縫面積`,下限 `floor_g` 倍較輕塊的重量,否則碎屑面一受重力就剪斷)、`bond_overlapping`(凹體分解零件間以 AABB + GJK 找重疊)、`anchor`(腳底焊到地面)、`poll`(掃描鍵結狀態,每個斷裂恰好回報一次,`FractureEvent`,可轉送 `scheduler.events.Channel`)、`enforce_budget`(游離碎片超額時先移睡眠的、再小的,記入新計數器 `FRAGMENT_EVICTED`)、`cut_fragment` / `cut_fragment_planes` / `replace_fragment`(執行期切:碎片換成切片,繼承父體速度場 `v + w × r`,父體每個關節重新錨到含該錨點的切片)。島 / 睡眠無需專碼:鍵結結構是一個島,整塊睡、整塊醒;碎裂後是許多小島。
> **順帶修掉的引擎缺陷(前置,量到才發現)**:任意形狀的 hull 落地會沉進地板——基準 72 塊 Voronoi 碎片從 2 cm / 1 m 落下,48–49 塊沉超過 2 cm、20–22 塊超過 10 cm、只有 18 塊入睡。根因是投機邊距:`ColliderSet.as_hull` 把 hull 每個頂點沿所在八分域外推,盒子的面仍平,**其他 hull 的斜面被彎曲**(頂點離面可達 `infl·(|nx|+|ny|+|nz|)`),`_face_by_normal` 的 1 mm 面容差只剩一個頂點合格,接觸片退成每幀跳動的單點,hull 搖晃、沉陷(三角柱尖端朝下落地:最低頂點 −0.21 m)。修法:hull 不再膨脹,`hull_manifold(…, margin)` 自己產生投機接觸(沿面軸間隙 < margin → 負深度),呼叫端把 margin 加回深度以維持 `try_pair` 的慣例;`margin = 0` 與舊行為逐位相同(既有 hull / 求解器 / trimesh / 軟體耦合測試全過);置中的盒狀 hull(`HullShape.box_like`)仍走舊的八分域膨脹——對它面保持平且與盒路徑逐位相同,所以 golden 的盒 hull 各行不變,**唯一變動的 golden 行是四面體 rest y `0.1996508 → 0.19966601`**(1.5e-5 m,不規則 hull 改用新慣例)。修後同一批 72 塊:沉超過 2 cm 的 18–19 塊、超過 10 cm 的 1–2 塊、入睡 45–47 塊;抖動立方體(沒有任何面完全平)3/8 → 8/8 靜止,尖端朝下三角柱 −0.21 → −0.0003 m。`tests/test_hull_irregular.mojo` 13/13。
> **量測**(`bench_fracture`):L 板 res 24 分解:split 2 零件 / excess 0 / 0.94 s,cluster 3 零件 / 0 / 0.09 s;U 板 res 30:split 3 零件 / **2.0 %** / 2.04 s,cluster 4 零件 / 4.5 % / 0.17 s——品質換建構時間(離線選 split、快速選 cluster)。Voronoi 預切 100 seed 41 ms、**1000 seed 0.77 s**(體積 8.000000000000004 / 8);一次 27 個平面切出 **1000 片** 105 ms(體積誤差 3e-14);1000 片加入場景成 hull 剛體 5.9 ms;40 碎片 / 155 焊接的牆清醒時 4.6 ms / 步。
> **測試**(新增 5 檔,全過):`test_polytope` 44(盒的體積 / 質心 / 慣量解析值;切分守恆與帽標籤;60 個隨機平面連切得 1576 片,體積誤差 1e-14、每片閉合且凸;共面 / 共線 / 重合 / 不足四點 → 空凸包而非垃圾)、`test_convex_decomp` 44(seam parity:兩變體覆蓋 ≥ 0.999、excess ≤ 35 %、L 板 81 + U 板 41 個非擦邊探針的 GJK 命中 / 未命中逐一相同且不與實體矛盾,`hull_manifold` 同;凸網格 → 1 零件;退化三角被略過;共面網格 → 0 零件;錯誤索引 / res 0 / 長度不是 3 的倍數 raise)、`test_weld` 15(離心錨點的焊接盒保持姿態,同錨點的 ball 關節擺動 1.28 m;帶扭轉的焊接保持扭轉;焊接雙盒落地同睡一島;超載焊接斷開、只回報一次;焊接兩體互不碰撞、未焊的被推開)、`test_fracture` 75(**普通**:40 碎片的牆 135 + 8 焊接站穩 90 幀零斷裂;100 kg 球 50 m/s 打擊,121 / 143 鍵結斷、37 塊被打穿牆面、射線上 0 塊殘留、22 鍵結仍站著;閾值 3× 載重保持、0.3× 斷且只回報一次、Channel 亦收到一次;**整合**:2 × 27 塊磚(及 2 × 24 塊 Voronoi 碎片)落在剛性箱子 / 靜態台座上、另一批輕質的落在軟體上,剛性側磚 54/54、碎片 47/48 入睡,箱子承重,軟體被撞後仍健全;L 板 → 體素 → 分解 → 各零件 Voronoi → 生成 → 零件內 104 + 跨零件 23 焊接 → 全部入睡成一島;執行期切割保體積、鍵結全數重新錨定;預算上限 12,淘汰數 = 超額數且記數、最小者先走;**極端**:單 seed = 單碎片無鍵結、重合 seed、共面胞不生成剛體、零 stress / 零法向 / 未知碎片 raise;**1000 胞** Voronoi 與 **一刀 1000 片**——皆保體積並步進無 NaN)。
> **決定**:焊接用既有的 `set_joint_break`(17.29)當斷裂閾值與事件來源,不另造斷裂機制;碎片慣量只取張量對角(`TODO` 轉主軸);`debris_config()` 把睡眠容差放寬 10 倍給碎屑場景(不規則碎片在接觸片上以數 cm/s 緩慢搖擺,預設 1 cm/s 永遠睡不著);軟體不睡,壓在其上的碎片也保持清醒,所以測試把軟體隔在別處。
> **待辦**:慣量轉主軸;`polytope_split` 的符號判斷改走 `geometry/predicates.orient3d`(目前是 epsilon 帶);`bond_overlapping` 為 O(n²)、跨零件接縫面積以 `min(V)^(2/3)` 估;`HullShape` 面表上限 30 面、O(V⁴) 建構,所以單碎片頂點數宜 ≲ 60;只切**凸**實體(凹體先分解);`FractureSet` 與斷裂閾值未入快照(同 17.29);單塊不規則碎片孤立落地 6 秒內約 6 成入睡(搖擺緩慢,尚非靜止),其接觸片品質值得單獨處理;「一次切上千片」的 O(pieces × planes) 分類尚未加空間索引。

### 17.6 動畫圖深度 — Wave B
> **現況**:`procedural/anim.mojo` = clip / blend(linear·DLB·geodesic)/ crossfade +
> `scheduler/fsm.mojo` 驅動。
> **缺口**:blend tree(1D / 2D 方向性)、動畫層 + 骨骼遮罩、加法動畫、root motion 擷取與
> 套用、骨架間 retarget、(選)motion matching。
> **對照組**:UE AnimGraph / Motion Matching、Unity Mecanim / Playables、Godot AnimationTree。
> **優勢區**:中 —— blend 已走 motor geodesic(candy-wrapper-free,範例 07 已示);retarget
> 在 motor 空間做可免 gimbal;加法動畫 = motor 除法,GA 自然。
> **規模軸**:骨骼數 × 混合節點數;方向混合取樣密度 vs 品質。
> **seam?**:是 —— blend node 家族已是 CATEGORY §2 既有 row;新節點型別附 parity(邊界權重
> 退化為單一 clip)+ bench。
> **交付**:接 skinning + fsm;普通(idle↔walk↔run 1D)/ 整合(上半身瞄準層疊加、root
> motion 位移與碰撞一致)/ 極端(權重全 0、NaN clip、單影格 clip、retarget 到骨長差 10×)。

> **進度:✅ 2026-09-29** `procedural/anim_graph.mojo`(`procedural/anim.mojo` 的逐骨混合抽為 `blend_bone`,行為不變):`Pose`;`BlendSpace1D`(分段線性、所有 clip 取**同一正規化相位**,walk 1.0 s 與 run 0.6 s 混合時步伐同步);`BlendSpace2D`(freeform cartesian gradient band,樣本點上權重恰為 one-hot);`layer`(逐骨遮罩 × alpha);`make_additive` / `apply_additive`(PGA motor 商 D = M·M_ref⁻¹,沿 motor geodesic 縮放:90° 的一半恰 45°);`root_motion`(跨 loop 累積)/ `strip_root`;`Skeleton` / `retarget`(旋轉照抄、平移依骨長比縮放);`MotionDB`(暴力最近幀)。混合節點跳過零權重輸入、權重 1 回傳輸入副本 → 邊界權重**恰**退化為單一 clip(seam parity),且被權重排除的 NaN clip 不外溢。`tests/test_anim_graph.mojo` 29/29(含 root motion 驅動 17.1 角色控制器:空曠處走出擷取距離、撞牆停下;10× 骨長 retarget;motion matching 找回自身幀)。`bench_anim_graph`:成本線性於骨數(DLB 1-D 約 240 ns/骨),geodesic 約 DLB 的 1.5×。接線範例 `examples/24_locomotion_graph.mojo`(FSM → 1-D 空間 → 瞄準層 → root motion 進控制器 → 蒙皮)。**待辦**:姿勢改用預配置緩衝(現每節點配置 `List`);方向性(polar)2-D 空間;骨架階層世界矩陣組合(範例以局部 motor 直接蒙皮);motion matching 加速結構。

### 17.7 固定步 ↔ 繪製率解耦的狀態插值 — Wave A
> **現況**:`scheduler/gameloop.mojo` `FixedLoop.advance` 已回傳 leftover 分數;但**無 prev↔curr
> 變換雙緩衝與插值輸出**。
> **缺口**:每個可視 transform 的上一 / 當前快照環、alpha 插值(motor geodesic / DQ nlerp)、
> 外推選項、teleport 時抑制插值的旗標。
> **對照組**:所有引擎(Unity fixed timestep、Godot `_physics_process` vs `_process`、UE)。
> **優勢區**:低-中 —— 插值走 motor geodesic 與變換層一致(對照組多用 pos-lerp + quat-nlerp,
> 螺旋運動下略差)。
> **規模軸**:可視實體數 × 每幀插值成本;插值 vs 外推的視覺誤差。
> **seam?**:是 —— 插值子(pos+quat lerp / DQ nlerp / motor geodesic)→ parity(alpha=0,1
> 端點完全一致)+ bench。
> **交付**:接 gameloop + ECS transform;普通(sim 60 / render 144 平滑)/ 整合(父子階層
> 插值不脫節、與 CCD 命中影格一致)/ 極端(alpha 超界、teleport、族群變動當幀、dt 抖動)。

> **進度:✅ 2026-09-29** `gameplay/interpolation.mojo`:`PoseHistory`(每 body 前一 / 當前 tick 姿態,新 slot prev==curr,`mark_teleport` 抑制插值)+ 插值子 seam `PoseInterpolator`:`LerpNlerp` / `DqNlerp` / `MotorGeodesic`;`Runtime` 每 tick 擷取、`render_pose[I = DqNlerp](e)` 依 `loop.alpha` 取繪製姿態、`teleport(e, p)`。`test_interpolation` 21/21(三變體端點與純平移 parity;偏心軸 90° 螺旋:geodesic 1e-7、dq-nlerp 6e-8、lerp+nlerp 偏離 0.29;clamp / 外推 / 反向四元數 / 瞬移);`test_system_render` 5/5(sim 60 Hz、render 144 Hz:繪製值恆在兩 tick 之間、單調、多數幀為中間值;瞬移無拖影)。`bench_interpolation`:lerp+nlerp ~4 ns、dq-nlerp ~12 ns、motor geodesic ~200 ns / 姿態 → runtime 預設 dq-nlerp。

### 17.8 大世界座標 — Wave C(架構)
> **決定(2026-10-09)**:先做 f32 + origin rebasing + world partition;f64 只做到 `WorldType`
> 參數化與小世界 parity,完整精度曲線視代價再補。
> **現況**:全 `f32`(`WorldType`),為 bit-identical 決定論。世界尺度上限 ~單一關卡。
> **缺口**:64-bit 世界座標 **或** origin rebasing(世界原點位移)、world partition /
> cell streaming、與決定論相容的方案(rebasing 事件也要進序列化)。
> **對照組**:UE5 Large World Coordinates + World Partition、Unity origin shifting、
> 64-bit 位置的自研引擎。
> **優勢區**:低 —— 純架構。**f64 化會使 16.3 的 Vec3 / SIMD 寬度重構重來一遍** → 排 Wave C 末。
> **規模軸**:世界跨度(m)vs 位置誤差;streaming cell 進出的幀成本。
> **seam?**:是 —— 座標策略(f32 / f32+rebasing / f64)→ parity(小世界下三者 ε 一致)+
> bench(遠離原點的精度退化曲線 = 優勢區量測)。
> **交付**:普通(遠原點物件不抖)/ 整合(rebasing 後 warm-start cache、序列化續跑一致)/
> 極端(1e7 m 外、cell 邊界瞬移、rebasing 當幀有 CCD)。

### 17.9 Debug-draw 指令佇列 — Wave A(工具)
> **現況**:無。SOTA_GAP 標「編輯器 / debug-draw ❌」。
> **缺口**:引擎側 immediate-mode 佇列(line / sphere / box / arrow / text / contact-point,
> 帶顏色與生命期),host 端消費;可被測試斷言(畫了幾條、座標)。
> **對照組**:UE `DrawDebug*` / Chaos Visual Debugger、Unity `Debug.DrawLine` / Gizmos、Godot。
> **優勢區**:不適用 —— 基礎設施(但這個 API 本身是核心觀測設施,不算多媒體)。
> **規模軸**:每幀指令數的緩衝 / 清空成本。
> **seam?**:否(單一設施);但**須符合定律 v3「接上專案」** —— solver6 接觸點、broadphase
> pair、island 顏色、CCD 命中都要發指令。
> **交付**:普通(畫 100 條線一幀清掉)/ 整合(solver 每個 contact 一點、可視 island)/
> 極端(0 指令、溢位上限、生命期跨多幀、多執行緒 island 併發寫)。

> **進度:✅ 2026-09-27** `diag/draw.mojo`:`DrawQueue[dtype]` 固定容量指令佇列(line / sphere / box / arrow / text / contact-point 六種指令共用一個扁平 tagged struct,`tick()` 老化生命期,溢位 drop + 計數);點為 `SIMD[dtype, 4]`、`dtype` 為 struct 參數,故 `diag` 零引擎依賴而 `DrawQueue[WorldType]` 直接吃 `Vec3`。`tests/test_diag_draw.mojo`(普通 / 整合 / 極端);`bench_diag` 表 (c) push+tick 吞吐。(commit `7978b69`,merge `10a935f`)

### 17.10 Profiling / tracing hooks — Wave A(工具)
> **現況**:僅離線 `benchmarks/` + `harness/bench.mojo`;無 in-loop instrumentation。
> **缺口**:scoped timer、trace event 輸出(Chrome trace / Perfetto / Tracy 相容)、每系統 /
> 每 phase frame 預算與統計、計數器(contacts / pairs / island / iters)。
> **對照組**:UE Insights / `stat` 指令、Unity Profiler、Tracy。
> **優勢區**:不適用。小加值:10.2 job graph 已有讀寫集 → 可自動標註 span 邊界。
> **規模軸**:instrumentation 開 vs 關的 overhead(須 < few %)。
> **seam?**:否;但 on/off 兩路徑須 parity(結果不受量測影響)+ overhead bench。
> **交付**:普通(單幀 trace dump)/ 整合(標註 job graph、GPU 段)/ 極端(百萬 span、
> 遞迴 span、執行緒池)。

> **進度:✅ 2026-09-29** `diag/trace.mojo`(`begin`/`end` + `with`-scoped span,`-D LUDENS_TRACE` 關閉時編譯為無)、計數器、Chrome trace 匯出;接入 `ContactScene6`:每步一個 span / 階段(collect_pairs、solve 涵蓋整個子步迴圈、sleep、nan_scan)。17.0h 首版每步 ~23 組 span 量到 ~20% 開銷 → 粗化為每步 5 組;粗化後以兩個獨立行程比較 N=512 的 solve 列差 ~14%,但同表 octree 列方向相反(−15%),且 5 次 `perf_counter` 不可能佔 1 ms → 判定落在本機跨行程雜訊(±15%)內。**待辦**:同一行程交錯量測 trace on/off(需 runtime 開關)以取得乾淨數字。

### 17.11 反射 / 型別註冊表 — Wave B(架構,解鎖多項)
> **現況**:`ComponentType` 只有 `comptime ID: Int`;無 runtime metadata。
> **缺口**:欄位名 / 型別 / offset 的 runtime 表(comptime 生成)、版本標記、(de)serialize
> 由 schema 驅動、供工具 / 網路 replication codegen / 腳本綁定查詢。
> **對照組**:UE `UPROPERTY` reflection、Unity serialization、Bevy Reflect、flecs meta。
> **優勢區**:中 —— Mojo comptime 可近零成本生成反射表(對照組多靠 codegen 前處理或執行期
> 字典);與 17.12 / 17.16 共用。
> **規模軸**:型別數 × 生成成本(comptime)/ 查詢成本(runtime);對編譯期的影響。
> **seam?**:是 —— 反射驅動序列化 vs 手寫序列化(6.10)→ parity(round-trip 逐位相同)+ bench。
> **交付**:普通(一個 component round-trip)/ 整合(接 6.10、換 backend 後仍一致)/
> 極端(空型別、巢狀、遞迴參照、版本不符)。

> **進度:✅ 2026-09-29** `ecs/schema.mojo`:以 Mojo 1.1 prelude 的 `reflect[T]`(欄位名 / 型別 / byte offset / `field_ref`)在**編譯期**產生 `TypeSchema`,遞迴展開巢狀 struct 為點號路徑(`rotation.w`),無任何手寫欄位清單。`write_value` / `read_value`(自描述單筆)與 `write_values` / `read_values`(批次:描述一次、名稱比對一次);讀取按**欄位名**對應目前 schema:已刪欄位略過、新欄位保留呼叫端預設、改型欄位不重解釋,結果記在 `ReadReport`(dropped / mismatched / defaulted)。`TypeRegistry`:依型別名註冊,對型別擦除位址按欄位名讀寫純量(工具 / 腳本綁定形狀)。`tests/test_schema.mojo` 22/22(Transform 逐位 round-trip、反射 vs 手寫 parity、50 個 Transform 由 sparse-set world 搬到 archetype world 逐位相同、`SolverConfig` round-trip 後步進場景逐位相同;極端:空型別、巢狀、V1→V2 版本不符、截斷、錯型別名、registry 未知型別 / 欄位 / 非純量)。`bench_schema`(N=65536):單筆自描述 989 ns / 634 B、批次 115 ns / 114 B、手寫 17 ns / 48 B(手寫不存快取世界矩陣)。接線範例 `examples/23_reflection_inspector.mojo`(檢視器:列出並按名稱修改 Transform / SolverConfig 欄位)。**待辦**:批次讀寫仍逐 byte `append`,改整段複製;非純資料型別(`List` / `String`)目前靠契約排除,未在編譯期擋;17.12 場景格式 / 17.16 replication / 17.40 存檔改用此 schema。

### 17.12 可編輯場景 / prefab / 實例化 — Wave C(gated)
> **決定(2026-10-09)**:平台方向 C → 場景格式**跟宿主走**(glTF / USD 匯入),不自訂檔案格式;
> 場景(作者資料)與決定論快照分開,以 parity 連結。屬編輯器相關,本輪不做。
> **現況**:`physics/serialize.mojo` = 全狀態 f32 bit-pattern 決定論快照(自註「非 asset reference」)。
> **缺口**:schema 化、可 diff、版本化的場景格式、prefab / blueprint、nested scene 組合、
> 實例覆寫(override)、entity template。
> **對照組**:UE `.umap` + Blueprint、Unity prefab + YAML scene、Godot `.tscn` + PackedScene、
> glTF / USD 匯入。
> **優勢區**:低 —— 工程;差異化在依賴 17.11 反射 → 格式免手寫。
> **⚠️ gated**:檔案格式綁定是「先於技術的架構決策」(同 Phase 13 排除 MJCF/URDF、同 13.9),
> 待平台整合方向確定。
> **規模軸**:場景實體數的載入時間;prefab 覆寫深度。
> **seam?**:是 —— 場景格式讀寫 vs 決定論快照 → parity(同場景兩路徑載入後逐位相同)。
> **交付**:普通(存讀一個場景)/ 整合(prefab 實例 + 覆寫、warm-start cache 保留)/
> 極端(空場景、循環 prefab 參照、缺資源、格式版本升級)。

### 17.13 世界查詢完整度 — Wave A
> **現況**:`SceneQuery` trait 僅 `raycast` + `overlap(AABB)`,打在 broadphase `BoxProxy` 上、
> 非真實碰撞幾何(`collision/queries.mojo:28`)。
> **缺口**:任意 convex 的 shapecast / sweep、closest-point / distance、penetration(MTV)/
> depenetration 查詢、對真實 shape(hull / trimesh / capsule)而非 AABB proxy、batched query、
> 查詢過濾(接 9.3)。
> **對照組**:UE Chaos scene queries、PhysX `sweep`/`overlap`/`raycast`、Jolt `NarrowPhaseQuery`、
> Rapier `QueryPipeline`。
> **優勢區**:中 —— shape-sweep 可重用既有 15 軸 SAT / GJK-EPA / TOI(4.1)機件;CGA 對曲面
> 基元的 meet 給閉式最近點(對照組要迭代)。
> **規模軸**:查詢數 × 場景大小;shape-sweep vs raycast 近似的準確度 / 成本。
> **seam?**:是 —— 既有 `SceneQuery` seam 的擴充:每個新查詢對 brute / bvh / grid / tree
> 四索引結果集相等 + 各自 bench row(CATEGORY §2 既有列擴充)。
> **交付**:普通(對 hull 掃一個 capsule)/ 整合(接 17.1 控制器、17.4 載具)/
> 極端(零長度掃、起點已穿透、相切、退化 shape、命中 static trimesh 接縫)。

> **進度:✅ 2026-09-29** `collision/world_query.mojo`:點對任一 collider 的有號距離(box / sphere / capsule 精確,hull 面平面、mesh 三角候選為下界)為核心;`ray_cast`(各形狀閉式,capsule 保守推進)、`sphere_cast` / `capsule_cast`(保守推進,線段距離以黃金分割搜尋)、`overlap_sphere` / `overlap_capsule`、`capsule_penetrations`(擠出法向 + 深度)、`ray_cast_batch`;`QueryFilter`(類別遮罩 / 忽略自身 / sensor 可選)。`ContactScene6` 提供包裝(姿態由 physics 端組出)。`tests/test_world_query.mojo` 30/30(含舊 `SceneQuery` 會誤判的「穿過球體 AABB 角落」案例、settle 後的疊塔、start_solid / 忽略自身 / sensor / 空場景等極端)。`bench_world_query`:N=16 時 ray/sphere/penetration ~0.6 µs、capsule sweep ~4 µs;N≥256 起每次查詢被線性前置工作主導(逐次組全部姿態 + AABB 線性預篩)。**待辦**:改用持久 broadphase 預篩並每步快取姿態;四索引 seam parity(brute / BVH / grid / tree)。

### 17.14 導航 — Wave C
> **現況**:無(舊「明確不做」,已被 [[no-tech-exclusion-principle]] 推翻)。
> **缺口**:navmesh bake(voxel → region → contour → 三角化)、A* / funnel(string-pulling)、
> 動態障礙挖洞、crowd + 區域避讓(RVO / ORCA)、off-mesh link、tile 重烘。
> **對照組**:Recast / Detour、DotRecast、UE Navigation System、Unity NavMesh;避讓:ORCA(van den Berg)。
> **優勢區**:中 ——(a)navmesh bake 是體素 / 幾何運算,可用既有 SDF3(13.8)/ predicates
> (10.1)/ BVH;(b)ORCA 的線性規劃可微 → 學習式避讓權重(對照 hand-tuned);(c)island
> 平行(6.11)可平行 agent 更新。
> **規模軸**:agent 數(crowd 鄰居前的規模軸)、navmesh 多邊形數、動態重烘的 tile 成本。
> **seam?**:是 —— 避讓演算法(RVO / ORCA / 力場)對同場景的無碰撞率 + 到達時間 parity;
> pathfinder(A* / JPS / funnel)路徑等價類。
> **交付**:普通(單 agent 繞牆)/ 整合(crowd 對衝不卡死、動態障礙即時挖洞、與物理地面一致)/
> 極端(無路徑、瓶頸門、agent 重疊出生、navmesh 破洞)。
> **增補(2026-10-09 負空間盤點,本節尚未開工故直接擴充範圍)**:
> - **流場尋路**:每個目標算一次 integration field + 方向場,同目標的大量單位 O(1) 讀方向
>   (例:5000 個 RTS 單位走向同一集結點,不跑 5000 次 A*)。grep `flow.?field|流場尋路`
>   於 docs / 程式碼只命中 LBM 的「流場」。pathfinder seam 加一個變體。
> - **3D 體積導航**(飛行 / 游泳 agent):稀疏體素八叉樹 + 3D A*(例:無人機敵人穿過建築
>   內部空間)。navmesh 只處理可行走表面;既有 `spatial/` 八叉樹是寬相索引,不是導航圖。
> - **階層式長程尋路**(HPA* / 每個 partition cell 一份 navmesh):公里級分區世界先在抽象
>   cluster graph 上粗規劃,只有已載入的 cell 持有細 navmesh;接 17.8 world partition。
> 對照組補:Unity DOTS 流場範例 / Supreme Commander 2 flow field、UE Mass 的 3D 導航插件、
> HPA*(Botea 2004)。**相依**補:17.8(partition 與串流)。

### 17.15 AI 框架 — Wave C
> **現況**:僅 `scheduler/fsm.mojo`(FSM / HSM)。
> **缺口**:behavior tree(decorator / service / 平行節點)、utility AI、blackboard、
> perception(視錐 / 聽覺 / 記憶)、EQS 式空間查詢(接 17.13)。
> **對照組**:UE Behavior Trees + EQS、Unity Behavior、通用 BT 函式庫。
> **優勢區**:低 —— 純 gameplay。小加值:BT tick 可入 10.2 job graph 依讀寫集自動平行;
> EQS 打分可微。
> **規模軸**:agent 數 × 樹節點數 × tick 率;EQS 查詢取樣密度。
> **seam?**:是 —— BT vs FSM vs utility 對同一決策問題的行為等價(可定義的情境集)+ tick 成本 row。
> **交付**:普通(巡邏→追擊→搜索)/ 整合(perception 接 17.13、多 agent 共享 blackboard)/
> 極端(空樹、深遞迴、每 tick 目標消失、1e4 agent)。
> **增補(2026-10-09 負空間盤點,本節尚未開工故直接擴充範圍)**:
> - **轉向行為 / 群聚 / 隊形**:Reynolds seek / flee / arrive / pursue / evade / wander /
>   path-follow、boids(separation / cohesion / alignment)、隊形槽位與跟隨隊長(例:1 萬條
>   魚群用 hash grid 鄰居查詢、8 人小隊沿 navmesh 路徑保持楔形)。17.14 只規劃了避讓
>   (RVO / ORCA / 力場),seek / arrive / 群聚 / 隊形不在其中。
> - **GOAP / HTN 規劃器**:以前置條件 / 效果搜尋動作序列(例:冷了 → 拿斧 → 砍樹 → 生火);
>   作為決策 seam 的第四個變體(BT / FSM / utility / planner)。grep `GOAP|HTN|planner` 零命中。
> - **Smart objects / 互動點**:物件公告可佔用的互動槽(坐、使用、開門),含預約與標籤
>   (例:三個 NPC 各佔一個長椅座位,第四個找不到空位)。
> - **影響力圖 / 戰爭迷霧 / 可見性格**:戰術用純量格(威脅、控制)與以視線計算的每隊可見性
>   (例:RTS 只顯示各單位視野半徑內、被地形遮擋後的區域)。本節 perception 是單 agent 感知,
>   不是隊伍層級的格;視線查詢用 17.13 `ray_cast`(`collision/world_query.mojo:5` 已點名
>   AI line-of-sight 為用途)。
> 對照組補:Craig Reynolds steering、F.E.A.R. 的 GOAP、Horizon / Killzone 的 HTN、UE Smart
> Objects、RTS 迷霧實作。**規模軸**補:boids 數 × 鄰居半徑;planner 動作數 × 搜尋深度;格解析度。

### 17.16 網路 / rollback — Wave C(部分 gated)
> **決定(2026-10-09)**:平台方向 C → **傳輸層與線路格式交給宿主**;引擎提供 rollback 核心、
> 預測策略 seam(lockstep / predict-rollback / snapshot-interp)與給宿主傳送的 byte payload API。
> 權威模型以 lockstep + rollback 為主;決定論只承諾**同工具鏈、同架構**(不做跨平台定點 / 軟浮點)。
> **現況**:刻意未做。**地基已在**:決定論 RNG(`scheduler/rng.mojo`)、actor model(10.3)、
> 全狀態快照(6.10)。
> **缺口**:snapshot ring buffer + 重模擬(rollback)、input prediction / server reconciliation、
> delta 壓縮 state replication、authority / ownership、interest management、lockstep 傳輸層;
> **跨平台決定論**(不同編譯器 / 架構 —— 目前只保證同工具鏈,16 章鎖版本是半個答案)。
> **對照組**:GGPO / rollback netcode、UE Iris / Replication Graph、Unity Netcode for Entities、
> Photon Quantum(決定論 lockstep)。
> **優勢區**:中高 —— **差異化方向**:(a)既有 bit-identical 決定論 + 快照 → rollback 最難
> 前提已滿足;(b)actor model 訊息重放天生對 lockstep 友善;(c)可微 + 決定論 → 學習式預測補償。
> **⚠️ gated**:傳輸層 / 線路格式綁定平台整合(同 13.9 / 17.12)。
> **規模軸**:rollback 幀深 × 每幀重模擬成本、封包大小 vs 實體數、玩家數。
> **seam?**:是 —— 預測策略(pure lockstep / predict-rollback / snapshot-interp)對同輸入
> 序列的最終世界 parity;各自頻寬 / CPU row。
> **交付**:普通(2 端同輸入 → 逐位相同世界)/ 整合(丟包重排下重模擬收斂、與 CCD / island
> sleep 相容)/ 極端(rollback 深度上限、當幀族群變動、時鐘漂移、跨平台 f32)。
> **增補(2026-10-09 負空間盤點,本節尚未開工故直接擴充範圍)**:
> - **延遲補償 / 伺服器回溯命中**:保留短期 collider 位姿環形緩衝,讓伺服器對「射擊者 N ms
>   前看到的世界」做 raycast / overlap,不必整個世界 rollback(例:120 ms 延遲的爆頭,對目標
>   7 tick 前的位姿判定)。零件:`collision/world_query.mojo:566-573` `ray_cast` 已接受外部
>   `poses: List[Pose3]`;缺的是位姿歷史環(`gameplay/interpolation.mojo:96` `PoseHistory`
>   只存 prev / curr)與回溯查詢服務。
> - **伺服器端輸入驗證與失步偵測**:拒絕不可能的輸入 / 位移(速度上限、瞬移偵測),各端交換
>   每 tick 狀態雜湊偵測 desync(例:回報速度超過衝刺上限 3 倍的客戶端被拉回)。零件:17.39
>   的逐 tick FNV-1a 雜湊(`gameplay/replay.mojo:86` `checksum`)與 `first_divergence`,
>   目前只用於 replay QA。**邊界**:反作弊的帳號 / 封禁 / 用戶端防護屬宿主與線上服務。
> 對照組補:Valve Source 的 lag compensation、Overwatch 的 hit registration、GGPO desync
> 檢查。**規模軸**補:回溯深度(tick)× collider 數的記憶體;每 tick 雜湊成本。

### 17.17 GPU 剛體 / articulation solver — Wave B
> **現況**:GPU 僅覆蓋布料(4.3 / 6)、broadphase(3.2)、LBVH、raycast。剛體 solver 全 CPU
> (islands 多執行緒 6.11)。
> **缺口**:GPU 端 contact solver(著色 / Jacobi PGS)、GPU narrowphase / manifold、GPU
> articulation(Featherstone on device),CPU↔GPU parity。
> **對照組**:PhysX 5 GPU rigid bodies、Newton(Warp)、Genesis、AVBD(SIGGRAPH 2025 擴到剛體)。
> SOTA_GAP 自述「領域已決定性轉向 GPU-first」。
> **優勢區**:中 ——(a)Mojo GPU kernels 在 memory-bound 負載與 CUDA 相當(ORNL);
> (b)著色平行(6.11)的 CPU 版可作 parity 基準;(c)motor / screw 狀態緊湊(8 float)利於頻寬。
> **規模軸**:剛體數 / 接觸數的 GPU vs CPU 交叉點;每幀 readback 隔離(Wave 1 教訓:傳輸成本情境相依)。
> **seam?**:是 —— contact solver 裝置實作(CPU islands / GPU colored)→ parity(同場景 rest
> 態 by action,對齊睡眠)+ bench(N 掃描 + 傳輸隔離列)。
> **交付**:普通(箱堆 GPU / CPU 同 rest)/ 整合(GPU 剛體 + CPU 軟體同幀、island 邊界)/
> 極端(單體、百萬接觸、高質量比、accelerator 缺席自跳過)。

> **進度:✅(剛體接觸;articulation 未做)2026-09-29** `physics/gpu_contact.mojo`:`GpuContactSolver` 把 `ContactScene6.step(cfg.colored=True)` 的子步迴圈(重力 / 各色 warm start / 各色 iters 次軟求解 / 位姿積分 / 各色兩次 relax)搬到裝置上,一個 thread 一個接觸(同色不共用動態體)。kernel 內把 body 載入成真正的 `QuatBody6` 並呼叫它自己的 `velocity_at` / `angular_factor` / `apply_impulse` / `integrate_*`,跑的是正式的 body 算術。CPU 保留收集、island、著色(`ContactScene6.begin_external_solve`)與恢復係數 / 睡眠 / NaN 隔離 / 事件 / 快取(`end_external_solve`;`_color_pairs` 自 `step` 機械抽出)。**判準是量出來的**:箱堆接觸裁剪是離散分支,CPU 自己對 1e-7 的擾動 20 幀內放大到 ~3e-3,故 `tests/test_gpu_contact.mojo`(22/22)以「GPU−CPU ≤ 2 × CPU 對每個動態體 1e-6 擾動的自身發散」+ 靜止狀態 by action 判定:五箱塔、雙 island + 材質 + 滾球(事件開)、10:1 質量比、400 箱場(差 7.6e-6);單體無接觸 == CPU;關節 / 軟體 / CCD 拒絕。`bench_gpu_contact`(RTX 3060,寬相開,箱全醒):GPU 子步迴圈 0.7–1.0 ms/幀於 N=64..4096 幾乎持平(受 kernel 啟動數主導),傳輸 0.15–1.6 ms;N=4096 時 CPU 串行求解約 70 ms → 單看求解 GPU 約 28×(含傳輸)。**但整幀被 CPU 端收集與簿記主導**(N=256/1024/4096:0.6 / 6.8 / 82 ms,近平方),即審計 F22 的 O(n²) 熱點 → 17.19 首要。**待辦**:GPU articulation(Featherstone)、GPU narrowphase、kernel 融合(每子步一次啟動)、持久裝置狀態免每幀上下傳。

### 17.18 批次多世界步進(13.9 落地) — Wave B
> **現況**:13.9 標 ⏸ 決策點(綁平台整合)。
> **缺口**:同構世界的 SoA 批次步進(env 維在最內 / 最外)、批次 GPU、與 diffsim(3.1 / 4.2)
> 串接成 batched gradient。
> **對照組**:Brax、MJX、Newton(humanoid ~70×)、Genesis(宣稱 43M FPS)、Isaac Gym。
> **優勢區**:**高** —— [[roadmap-2026-07]] D 縱深已標:MJWarp 目前不可微、可微只在 MJX-JAX;
> **批次 × 可微 × Mojo 原生是本專案唯一可能領先的方向**。
> **規模軸**:env 數的吞吐(steps/s)、批次梯度 vs 逐一的加速比。
> **seam?**:是 —— 世界佈局(逐世界迴圈 / 批次 SoA)→ parity(單 env 下逐位相同)+ bench
> (env 掃描吞吐曲線)。
> **交付**:普通(1024 env 自由落同步)/ 整合(接 4.2 reverse tape 出批次梯度、與 13.7 串)/
> 極端(env=1 控制組須略慢、族群不齊、NaN env 隔離)。

> **進度:✅(可微子集上的批次)2026-09-29** `BatchReal[W]`(`SolverField`,每 SIMD lane 一個世界,env 維在最內)讓 17.20 的 `SphereWorld` 不改一行即成批次步進;`step_worlds_parallel[W]` 再把批次分到各核(env 維在最外)。`test_diffsolver`:lane k 對純量世界 k 最大差 2.4e-6(接觸後 SIMD 與純量路徑的乘加收縮不同,非逐位——量到的,故以 1e-4 為界);NaN 世界只留在自己的 lane。`bench_diffsolver`(20 核):N=1 控制組批次略慢(符合預期);N ≥ 64 時 8 lane 約 7.4×、lane × 核約 22× 於純量循序。**待辦**:批次 × 反向梯度(batched tape)、`ContactScene6` 本體的 SoA 批次(目前只在可微子集上)、GPU 批次。

### 17.19 生產級 solver 硬化 — Wave B(持續)
> **現況**:穩定堆疊只驗到 6 箱塔(`tests/test_softstep6.mojo`);大 island / 高質量比 /
> 接觸密集堆疊未系統測。
> **缺口**:高質量比(1:1000)、長鏈受載、單 island 數千體、接觸密集堆(碎石 / 骨牌)、
> warm-start 接觸點 feature-ID 穩定性、contact reduction。
> **對照組**:Jolt(Horizon FW 實戰)、Box2D v3 Soft Step、TGS Soft、AVBD 堆疊 demo。
> **優勢區**:中 —— sub-stepped soft(2.1)+ 著色平行(6.11)+ 變分積分子(4.1b)已是對的
> 地基;缺的是壓力測試 + 調參。
> **規模軸**:body / contact 數 vs 穿透 / 發散;iters vs 殘差(已有量測設計:對齊睡眠)。
> **seam?**:否新 seam —— 既有 solver6 的極端案例覆蓋(定律 v3 §4)+ `bench_solver_scale` /
> `bench_islands` 擴大規模軸。
> **交付**:普通(現有)/ 整合(高質量比 + island sleep + CCD 同場景)/ 極端(1:1e4 質量比、
> 1e4 體單 island、瞬移入堆、零質量、退化接觸)。

> **發現(2026-09-29,`test_diffsolver`)**:球在地面滑行後於 t = 2v0/(7μg) 正確進入 5/7·v0 的滾動,但之後持續減速(v0=3、μ=0.5:1.5 s 時 1.80、4 s 時 1.57),ω·r 高於 vx、並下沉約 7 mm。`ContactScene6` 與可微解算器逐幀一致,故屬正式解算器本身:body-frame 接觸錨點隨滾動的球旋轉,摩擦與分離量取在偏離真實接觸點的位置。修法候選:圓形 shape 每子步重新投影錨點到接觸點,或摩擦改在 manifold 點求相對速度。

> **量測(2026-09-29,`bench_gpu_contact`)**:寬相開啟後,N=4096 箱每幀的 CPU 收集 + 簿記(不含求解)達 82 ms,且 N 每 ×4 成長約 ×12 —— `refresh_islands` 與 `update_sleep` 的 island 喚醒 / 入睡迴圈為 O(n²),warm-start 對快取的線性比對為 O(pairs × cache)(審計 F22)。這是 GPU 與 CPU 路徑共同的瓶頸,排本項第一個工作。
> **進度 ✅ F22 第一批(2026-09-29)**:`islands.refresh_islands` 的整島喚醒與 `update_sleep` 的整島入睡改為兩趟 O(n)(先標 label 再套用),warm-start 比對改為每幀建一次 `(a,b,feat)` → 首位索引的 `Dict`(`contact6.cache_index`,自首個鍵相符處續掃,保留原「第一個相符」規則)。身分閘門 148/148 golden 逐節相同。`bench_gpu_contact`(寬相開):N=4096 CPU 簿記 82 → 20.6 ms/幀、GPU 整幀 84.5 → 23 ms、CPU 串行整幀 152 → 82 ms;N=1024 簿記 6.8 → 2.2 ms。仍略超線性(N ×4 → ×9),剩餘熱點待量(著色重排 O(色數 × 對數)、每幀重建 BVH、CCD 全對)。

### 17.20 剛體 solver 可微化收尾(13.7) — Wave B
> **現況**:13.7 🔶 —— `Field` 泛型在 `physics/diffrigid.mojo` 完成,但未推進 1555 行的
> `physics/solver6.mojo`。
> **缺口**:把 `Field` 係數環穿過 solver6 的接觸 / 摩擦 / warm-start / island 路徑;或明確
> 定義「可微子集」邊界並記在檔頭(定律 v3 §1)。
> **對照組**:DiffXPBD、Warp、Brax、Nimble(LCP 可微)。
> **優勢區**:高 —— 與 17.18 合為主打;screw 動力學可微天生免 gimbal / renorm。
> **規模軸**:參數數(NP)平坦性(4.2 已測 tape 平坦)、可微 solver vs 有限差分交叉點。
> **seam?**:是 —— solver6 係數環(RealF / DualReal / RevReal)→ parity(RealF 路徑與現況
> 逐位相同)+ bench(NP 掃描,接 `bench_diffsim` / `bench_diffrigid`)。
> **交付**:普通(穿一參數梯度 vs FD)/ 整合(與 island / CCD / warm-start 相容、換環後既有
> 測試不變)/ 極端(接觸開關不連續點、NP 大、零梯度路徑)。

> **進度:✅(可微子集)2026-09-29** 取 ROADMAP 允許的第二條路:明確定義「可微子集」並寫在檔頭,而非把 `Field` 穿過具體 `Vec3`/`Body6` 的 solver6。`geometry/field.mojo` 新增 `SolverField(Field)`(`recip` / `root` / `positive`;`positive` 導數定義為 0 = 接觸開關的次梯度約定),`RealF` / `DualReal` / `DualBatch` / `RevReal` 皆實作。`physics/diffsolver.mojo`:`SphereWorld[F]` 以同一套 per-frame 演算法(投機收集 + warm-start 快取規則、每子步 重力 / warm start / Box2D v3 軟法向 + Coulomb 摩擦 / 積分 / relax)處理動態球 + 靜態平面,全部分支改為指示函數。`tests/test_diffsolver.mojo` 26/26:`RealF` 對 `ContactScene6`(落下 1e-4、三球疊 1e-3、滑轉滾 5e-3);四方梯度一致(DualReal == 中央差分、DualBatch 兩 lane == DualReal、RevReal 一次掃出兩個參數);靜止高度對落下高度導數 = 0。`bench_diffsolver`:DualBatch 在 NP ≤ 16 全程最便宜;RevReal tape 前置成本對 FD 的比值由 NP=1 約 6× 降到 NP=16 約 2×,交叉點在掃描範圍外。接線範例 `examples/22_diffsolver_sysid.mojo`:由 `ContactScene6` 的單一觀測值反推 μ(8 lane 批次掃描 + DualReal Newton,真值 0.37 → 0.370002)。**待辦**:子集外擴(盒 / 膠囊、關節、恢復係數 pass);全部球對每幀都攜帶是 O(n²),大 n 需寬相;RevReal tape 每運算一次 `List.append` + `Optional` 指標,是反向模式偏慢的主因。

### 17.21 腳本層(Phase 12 落地) — Wave C(gated)
> **決定(2026-10-09)**:gating 解除 —— 見 Phase 12 決定註:12.1 邊界凍結(C-ABI)、先做 Python
> 綁定(核心 repo 最上層套件,測試環境隔離),hot reload 後接。
> **現況**:Phase 12 ⏸ gated on 核心 API 凍結。
> **保持 gated**,但列出前提:core embedding 邊界定義、Mojo / Python 雙腳本(技術偵察已在
> [[roadmap-2026-07]]:`PythonModuleBuilder` 擴充模組驗證過 rest y=0.2497、跨語言 bit-identical)、
> hot-reload、CVar / 設定系統、live 參數調校。
> **對照組**:UE Blueprint + Verse、Unity C# domain reload、Godot GDScript hot-reload。
> **優勢區**:不適用(架構分離決策)。
> **交付**:gated —— 使用者確認架構後才動。

### 17.22 範例覆蓋補完 — Wave A(文件)
> **現況**:`examples/` 有 01–14(2026-09-04 補齊 08 solver6 / 09 軟體耦合 / 10 關節鏈 /
> 11 排程 swap / 12 可微 / 13 LBM / 14 可變形體),`pixi run examples` 全綠。
> **缺口**:README 有列、CATEGORY §2 有 seam 列、但無可跑範例的四個 swap:
> ① rigid6 quat/screw + `SpinIntegrator` 四種積分子;② GPU cloth XPBD vs VBD;
> ③ reactive backend + observers + command buffers;④ 2D `ContactSolver`
> (SequentialImpulse / PBD / XPBD)。四者的 parity 測試與 benchmark 都已存在,
> 缺的只是「讀者能自己跑一次看到 swap」的那一份。
> **對照組**:既有 01–14 的房規 —— 模組 docstring 以 `Run:` 收尾、`def main()` 自足、
> 印出結果並與另一條路徑互相對照。
> **優勢區**:不適用(文件)。**規模軸**:不適用。**seam?**:否 —— 展示既有 seam,不新增。
> **交付**:15–18 四支;驗收即 `pixi run examples` 全綠且每支印出兩條路徑的對照數字。

> **進度:✅ 2026-09-29** 新增範例 17–21:`17_spin_integrators`(四種自旋積分子的 Dzhanibekov 漂移)、`18_cloth_xpbd_vbd`(XPBD vs VBD,CPU 與共用單一 context 的 GPU,CPU/GPU 一致)、`19_reactive_commands`(push observer vs 輪詢 + `SetBuffer` 同步點,每 tick 名單一致)、`20_contact_solver_2d`(SequentialImpulse / Pbd / Xpbd 疊塔;如實印出 PBD 系頂端殘餘速度)、`21_runtime_character`(runtime + 角色控制器 + 事件 + 插值端到端)。先前 15 樣條、16 實體池。

### 17.23–17.41 增補:同量級、先前未入路線圖的缺口(2026-09-27 盤點)

> **緣起**:使用者 2026-09-27 指示「探索是否有其他介於 A/B 之間的類似功能尚未排入
> Roadmap,若有則將之排入」。方法:24 個候選逐一 grep 全部引擎套件與 `docs/`,只保留
> 「程式碼中確實缺席或明顯不完整」且「不是任何既有條目子項」者 —— **保留 19、拒絕 5**
> (拒絕理由見本節末)。每項的「現況」都附真實 `path:line` 或註明 grep 零命中的詞彙;
> 格式同 17.1–17.22。**17.32 / 17.33 是 `docs/ARCHITECTURE.md` §2 錯誤處理政策的
> 「記錄」與「終止」兩層的落地**,與 17.9 / 17.10 同住 `diag` 套件。

### 17.23 物理材質與逐對組合模式 — Wave A

> **現況**:`physics/rigidbody.mojo:20-22`(`inv_mass`/`restitution`/`friction` 是
> per-body 純量),但 6-DOF solver 的 `Body6` trait(`physics/rigid6.mojo:88-107`)
> **完全不含材質存取器**;`physics/solver6.mojo:244`(`restitution: List[Real] # per-body
> coefficient (pair uses max)`——組合模式寫死 max);friction 在 solver6 走全域單一參數
> `physics/solver6.mojo:1823`(`mu: Real = 0.5`),不是 per-body。舊版
> `physics/solver.mojo:85`(`min(ba.restitution, bb.restitution)`)與
> `physics/solver.mojo:101`(`sqrt(ba.friction * bb.friction)`)兩條路徑的組合規則
> 互相不一致,且都不可配置。
> **缺口**:solver6 側 per-body/per-shape 摩擦係數、可配置逐對組合模式(min / max /
> average / multiply)、跨 solver 一致的材質規則。
> **對照組**:Unity `PhysicMaterial.combine`、PhysX `PxCombineMode`、Jolt
> `PhysicsMaterial`、UE `UPhysicalMaterial` + `FrictionCombineMode`。
> **優勢區**:低 —— 純工程 table stakes;若疊加 17.20 可微化,組合權重理論上可學習,
> 但目前無此串接。
> **規模軸**:材質數 × 組合模式數(4)查表成本;body 數對 per-body friction 查詢的
> 快取局部性。
> **seam?**:是 —— 四種組合模式對同一 (a,b) 係數輸入 → 各自數學定義的 parity +
> 查表 vs 計算的 bench。
> **相依**:17.19(極端質量比常伴隨極端摩擦組合)、17.12(場景格式需序列化材質)。

> 進度:✅ 2026-09-28 `physics/material.mojo`(新檔)——`COMBINE_AVERAGE`/`MIN`/
> `MULTIPLY`/`MAX` comptime 常數 + `combine(a,b,mode_a,mode_b)`(PhysX「較高優先
> 模式勝」規則,`mode = max(mode_a, mode_b)`)。`physics/body_set.mojo` 增逐 body
> `friction`(< 0 為「未設定」哨兵)、`friction_combine`、`restitution_combine`
> 三個 List,`BodySet.push` 一併初始化(預設 `friction=-1`、
> `friction_combine=COMBINE_AVERAGE`、`restitution_combine=COMBINE_MAX`)、新增
> `eff_friction(i, default_mu)` 讀取輔助。`ContactScene6` 增
> `set_friction`/`set_friction_combine`/`set_restitution_combine`(逐 index,呼
> 應既有 `set_restitution`)。`solver6._solve_pair` 在每對接觸的點迴圈**之前**算一
> 次 `pair_mu = combine(...)`(非逐點,符合「per contact 需廉價」要求),取代原本
> 直接用的全域 `mu`;`_restitution_pass` 的 `max(a,b)` 換成
> `combine(restitution[a], restitution[b], restitution_combine[a],
> restitution_combine[b])`。恆等閘門:兩 body 都未設定 friction 時
> `eff_friction` 回退到該步的 `cfg.default_friction`,預設組合模式
> `COMBINE_AVERAGE` 下 `(mu+mu)*0.5 == mu`(IEEE 754 精確,非近似)——`test_serialize`
> 的 golden blob 位元組數變大是本次變更**唯一**允許改動的 golden 行,其餘全部逐位
> 不變。測試:`tests/test_materials.mojo`(15/15)——普通:`combine` 四公式直接算
> 術 + 優先權規則;整合/極端:兩 body 係數與組合模式皆為 1.0(四公式共同不動點)時
> 四模式模擬軌跡逐位相同(parity)、冰面對橡膠的滑行距離依 `combine` 算出的組合
> mu 排序(`MULTIPLY<=MIN<=AVERAGE<=MAX`,係數 ∈[0,1] 時的解析恆真式)、預設
> `restitution_combine=MAX` 重現既有彈跳行為。`benchmarks/bench_materials.mojo`
> (N=1024 同時接觸,四模式各跑一輪 step,`flock` 鎖下正式記錄跑):14.1–15.6 M
> ns/step,四模式落在同一帶內(≈1.1× 展延,雜訊等級)——「選模式」不是新的可
> 觀測成本軸。seam row 入
> `docs/CATEGORY.md` §2.5。**17.23 完成。**

### 17.24 Kinematic 剛體型別(通用可移動體) — Wave A

> **現況**:`physics/solver6.mojo:403`(`add(mut self, var b: Self.B, half: Vec3,
> is_static: Bool)`)只有二元 `is_static` 旗標;`physics/forces.mojo:14-22`
> (`apply_gravity`/`integrate_positions` 皆以 `not b.is_static()` 判斷是否推進);
> `physics/solver6.mojo:888-892` prep 階段 `if not self.statics[i]: va0 = ...`——
> static 一律視為零速度。動態/靜態两態,沒有第三態。
> **缺口**:無限質量但由腳本設定速度、每步依速度積分位置(不受重力/衝量影響)、撞擊時
> 仍把速度傳給動態剛體的「kinematic」型別(電梯、旋轉風扇、平台、活塞門)。與 17.1
> 不同:17.1 是角色控制器**站上**移動平台時繼承其速度,這裡缺的是「平台本身」作為
> 可移動物理實體存在於 solver 中的方式。
> **對照組**:Unity `Rigidbody.isKinematic`、Jolt `EMotionType::Kinematic`、PhysX
> `PxRigidBodyFlag::eKINEMATIC`、UE `Simulate Physics=false` + `Movable`。
> **優勢區**:低-中 —— 與 17.1「移動平台速度繼承」共用驗收案例;motor 表示下的位姿
> 插值可重用 17.7 的 geodesic。
> **規模軸**:kinematic 體數 × 受影響動態體數;移動速度對穿隧風險(接 17.13/CCD)。
> **seam?**:是 —— body 動作類型(static/dynamic/kinematic)是同一「位姿推進」態射的
> 三個實例;kinematic 靜止時應與 static parity 一致 + bench(移動平台推擠成本)。
> **相依**:17.1(第一個使用者)、17.13(移動 kinematic 需真實 shape 查詢而非
> `BoxProxy`)。

> 進度:✅ 2026-09-28 `physics/body_set.mojo` 增 `MOTION_KINEMATIC = 3`(附加在
> `MOTION_REMOVED` 之後,舊快照的 0/1/2 不受影響)+ `is_dynamic`/`is_kinematic`/
> `moves`(dynamic∪kinematic)三個新謂詞——`is_dynamic` 管「這個 body 這步會不會
> 拿到質量項/衝量」,`moves` 管「這個 body 的速度/位姿這步要不要被讀/推進」,兩者
> 交集就是 17.24 全部的求解端行為:kinematic 靜止時兩個謂詞在其 slot 上的取值與
> static 完全相同,退化為同一分支。`physics/rigid6.mojo` 增 `Pose6`(表示無關的
> `pos+Quat` 目標位姿)+ `Body6` trait 三個新方法 `rotation`/`set_pose`/
> `set_velocity`(`QuatBody6`/`ScrewBody6` 各自實作,`ScrewBody6.set_velocity` 走
> 既有 `screw_velocity` 的 body-frame twist 轉換)。`physics/solver6.mojo`:
> `_collect_pairs`(brute + broadphase 兩路)的 static-static 跳過規則改成「雙方
> 都非 dynamic 才跳過」,連帶跳過 static-kinematic/kinematic-kinematic;
> `_solve_point`/`_joint_axis`/`_solve_pair`/`_restitution_pass` 等每個求解站台
> 把原本單一 `if not is_static(x):` 拆成「`moves(x)` 讀速度」+「`is_dynamic(x)`
> 讀質量項/施加衝量」兩層;`_refresh_islands` 只讓 dynamic-dynamic 併島,
> kinematic 拿自己的獨立單體 island(`_find` 自環,從未被併入任何聯集)——這正是
> `cfg.parallel=True` 路徑下 `_solve_island` 只碰 `island==label` 的 body 仍能推進
> kinematic 位姿的原因,否則平行路徑下 kinematic 永遠推進不到。**踩到的坑**:
> `_inactive`(`is_static or sleeping`)原本兼職「這對接觸要不要整對跳過」與「這個
> body 的位姿要不要繼續推進」兩種語意,kinematic 出現後這兩種語意分岔——新增
> `_impulse_inert`(`not is_dynamic or sleeping`)專職前者,`_inactive` 維持舊語意
> 專職後者;沒分開之前,靜止 kinematic 平台旁一個已入睡的動態箱每步仍被 warm-start
> 漏灌極小殘餘衝量(`_inactive(kinematic)=False` 讓「雙方 inactive 才跳過」的判斷
> 失效),KEY PARITY TEST 開發時當場抓到(見下方測試)。另新增
> `_wake_if_kinematic_moving`:**移動中**的 kinematic body 必須喚醒它接觸到的已
> 睡動態 body(電梯開始動時不能把箱子凍結在原地),但**靜止**的 kinematic
> (速度恰為零)絕不能觸發喚醒,否則破壞與 static 的逐位 parity——閘門就是
> kinematic 自己的速度是否恰好為零,不是「有沒有接觸」。`set_kinematic(id)`
> 刻意不是新的 `add_kinematic` 建構子:所有既有 `add*`(7 個方法、~100 個呼叫點)
> 簽章不變,只在既有 body 上後續呼叫 `set_kinematic` 轉型——避免 17.0g 系列文件
> 點名的「大範圍簽章掃描可能撞上編譯成本懸崖」風險。公開 API:
> `set_kinematic(id) raises`、`set_velocity(id,v,w) raises`、
> `move_to(id,pose,dt) raises`(由目標位姿反推速度,轉角走四元數導數的小角近似
> `w=2·Im(q_delta)/dt`,與既有 hinge 關節角誤差項同一手法,任意有限位移/dt 恆
> 有限不會 NaN)。序列化:`write_state`/`read_state` 逐 body 新增五個欄位
> (`motion`/`friction`/`friction_combine`/`restitution_combine`/`can_sleep`),
> 附加在既有欄位**之後**(舊 `is_static` bit 保留原樣、原封不動,只是不再是唯一
> 依據),`_VERSION` 由 1 升到 2。測試:`tests/test_kinematic.mojo`(18/18)——普通:
> 水平移動平台靠摩擦帶動箱子、電梯帶動箱子(需要上面「移動喚醒已睡箱子」那個修
> 正才會過);整合:kinematic 旁靜置箱子仍可入睡且 kinematic 自己絕不入睡、
> broadphase 路徑與 brute 路徑一致、序列化續跑逐位相同;極端:**KEY PARITY
> TEST**(零速度 kinematic 與 static 在同場景跑 200 步,3 個動態箱逐位相同——
> 開發過程中連續抓到兩個真 bug,見上);kinematic 撞靜態牆零接觸不穿隧也不
> NaN;`move_to` 巨位移仍有限;kinematic 夾擠動態體撞靜態牆全程有限。
> `benchmarks/bench_kinematic.mojo`(N=16..1024,兩欄都 pin 住不准睡眠以隔離睡眠
> 狀態這個更大的混淆變數,`flock` 鎖下正式記錄跑):kinematic/static 比值
> 0.97×–1.00×,雜訊等級,一次多讀
> `velocity_at` 不是可觀測成本。seam row 入 `docs/CATEGORY.md` §2.5。
> **17.24 完成。**

### 17.25 睡眠/喚醒生命週期公開 API — Wave A

> **現況**:睡眠機制完整但全為內部管理:`physics/solver6.mojo:240-241`
> (`sleeping`/`sleep_timer` 欄位)、`:357-400`(`_wake_islands`/`_update_sleep`,
> 島級自動喚醒/入睡)、`:594-596`(`_inactive` 為**私有**方法,無公開
> `is_sleeping`/`wake`)。喚醒目前只由接觸衝擊觸發(`docs/ROADMAP.md:90`)。
> **缺口**:公開 `wake(i)`(如遠處爆炸判定後手動喚醒)、`is_sleeping(i)` 查詢(供
> 17.2 判斷是否該讓動畫接手)、`set_can_sleep(i, bool)`(玩家載具永不睡)、瞬移後
> 自動喚醒旗標。
> **對照組**:Unity `Rigidbody.WakeUp()`/`IsSleeping()`、PhysX
> `PxRigidDynamic::wakeUp()`、Jolt `BodyInterface::ActivateBody`、UE
> `WakeRigidBody()`。
> **優勢區**:低 —— table stakes,但直接解鎖 17.2 與 17.16。
> **規模軸**:每幀外部喚醒呼叫數 vs 島重算成本;強制不睡體數對整體睡眠比例的影響。
> **seam?**:否新 seam(既有機制介面化);普通(手動喚醒單體)/整合(觸發整島喚醒)/
> 極端(喚醒 static 體、重複喚醒)。
> **相依**:17.2、17.16。

> 進度:✅ 2026-09-28 `physics/body_set.mojo` 增 `can_sleep: List[Bool]`(預設
> `True`,`push` 一併初始化)。`physics/solver6.mojo` 增 `_wake_island(i)`(私有
> 輔助:喚醒 `i` 所在整島,對 static/kinematic 是 no-op——`_refresh_islands` 既有
> 的島級喚醒邏輯的可重用版本,供下面公開 API 呼叫,不重複實作)。公開 API(皆
> `raises`,無效/已移除 id → 依 `docs/ARCHITECTURE.md` §2「呼叫端輸入錯誤 →
> raise」拋錯;static/kinematic id 是合法 id,只是沒有意義的睡眠狀態可動,視為
> no-op 而非錯誤):`is_sleeping(id)`、`wake(id)`、`set_can_sleep(id, bool)`
> (`False` 時讓 `_update_sleep` 的 still-timer 對該 body 永遠停在 0,連帶讓整島
> 的 `all_still` 檢查永遠不過,不需要第二個閘門;重新打開時立刻喚醒,不留「早該醒
> 卻還在睡」的殘留狀態)、`teleport(id, pose)`(用 17.24 新增的 `Body6.set_pose`
> 瞬間改位姿、喚醒、並清掉 `cache` 裡引用該 body 的 warm-start 項——舊位置的殘餘
> 衝量不能在新位置重放)。`docs/ROADMAP.md` 原文已註記本項**不算新 seam**(既有
> `_wake_islands`/`_update_sleep` 機制介面化),`docs/CATEGORY.md` §2.5 因此不列
> 本項的表格列。測試:`tests/test_sleep_api.mojo`(20/20)——普通:手動喚醒睡眠中
> 的塔,`wake` 喚醒整島(兩箱一起醒);整合:`can_sleep=False` 撐過 1000 步不睡、
> 重新開放後恢復正常入睡、`teleport` 喚醒 + 清 warm-start 快取(先驗證確實有殘留
> 快取項、瞬移後確認清空);極端:喚醒 static id 是 no-op 不拋錯、喚醒/瞬移/
> `is_sleeping`/`set_can_sleep` 對從未發出的 id 拋錯、喚醒/瞬移已 `remove()` 的 id
> 拋錯、連續三次 `wake` 冪等不出錯。**17.25 完成。**

### 17.26 接觸修改 / 單向平台 — Wave B

> **現況**:過濾機制只有靜態對稱位元遮罩:`physics/solver6.mojo:488-495`
> (`set_filter(i, category, mask)` + `_should_collide`,docstring 明言
> "Symmetric by construction")、`:498-501`(`set_sensor` 只能整體開關,無法依接觸
> 法向/相對速度動態決定是否生效)。grep `ContactModify`/`PreSolve`/`contact_callback`/
> `filter_contact` 於 `collision/`、`physics/` 全零命中。
> **缺口**:逐接觸的執行期回呼/規則(依法向、相對速度、穿透深度決定接觸是否生效或被
> 修改)。單向平台(由下往上穿越、由上落地才碰撞)是最小驗證案例;可延伸傳送帶
> (修改切向速度)、逐接觸覆寫 restitution/friction。
> **對照組**:Unity `PlatformEffector2D`、PhysX `PxContactModifyCallback`、Jolt
> `ContactListener::OnContactValidate`、Godot `one_way_collision`。
> **優勢區**:中 —— 回呼規則可設計為對相對速度的次梯度可微(供 17.20 學習式規則),
> 對照組多為手寫硬規則。
> **規模軸**:每幀受回呼影響的接觸數 vs 全量接觸的額外分支成本。
> **seam?**:是 —— 靜態過濾 vs 動態接觸修改是同一「接觸是否生效」謂詞的兩層實作;
> parity(回呼恆真時退化為現況)+ bench(callback overhead)。
> **相依**:17.1(單向平台是角色控制器關卡常見元件)、17.13。

> **進度:✅ 2026-09-29** `physics/contact6.mojo`:`ContactRule`(資料驅動,非回呼)+ `apply_rules`,在每幀收集後套用:`RULE_ONE_WAY`(平台→對方法向與 `dir` 夾角 < 60°、對方沿 `dir` 速度 ≤ 0.1 m/s、最深穿透 ≤ `value` 才保留 → 由下穿過、由上落地)、`RULE_CONVEYOR`(接觸新增表面速度 `vsurf`,僅在非零時進入摩擦列)、`RULE_FRICTION`(逐接觸摩擦覆寫 `mu_override`)。`ContactScene6.add_contact_rule`;GPU 解算器支援摩擦覆寫、拒絕輸送帶。`tests/test_contact_rules.mojo` 9/9(箱子由下穿過單向平台升到 3.55 m 後停在頂上 2.2997;無規則時被擋在 1.9 以下;**不匹配的規則 + 零速輸送帶與無規則逐位相同** = seam parity;輸送帶把靜止箱帶到 2.0000 m/s;摩擦覆寫 0 / 預設 / 1 → 3.0 / 0.55 / 0)。`bench_contact_rules`:規則掃描成本低於量測雜訊。**待辦**:角色控制器(走世界查詢,不經接觸)尚未套用單向平台;可微規則(對相對速度的次梯度,供 17.20)。

### 17.27 力場 / 區域效果 — Wave B

> **現況**:grep `ForceField`/`GravityZone`/`WindVolume`/`AreaEffect` 於
> `physics/*.mojo`、`docs/*.md` 全零命中;`physics/forces.mojo:1-22` 只有全域重力
> `apply_gravity`(對所有非 static 體施加同一向量);唯一衝量入口是
> `physics/chain.mojo:676-702`(`apply_impulse`/`apply_impulse_with`),但那是縮座標
> 鏈的單點 API,不是「對範圍內所有體施力」的工具。
> **缺口**:可疊加、依查詢限定範圍的力產生器 —— 重力區(方向覆寫)、徑向力
> (爆炸/吸引,依距離衰減)、風力區(定向+紊流)、拖曳區。
> **對照組**:Unity `Rigidbody.AddExplosionForce`、UE `URadialForceComponent`/
> Wind Directional Source、Godot `Area3D` 的 `gravity_point`/`linear_damp`。
> **優勢區**:中 —— 風力區可重用 14.4 LBM 的動量交換係數(同 17.4「LBM Cd 餵回車體」
> 模式),比對照組手調風場更有理論依據。
> **規模軸**:區域數 × 受影響體數;查詢範圍大小 vs 每步重算力的成本。
> **seam?**:是 —— 風力來源(常數向量 vs LBM 場採樣)→ parity(常數場退化一致)+
> bench(採樣額外成本)。
> **相依**:17.13(範圍查詢)、9.3(sensor 判定進出區域)、14.4(可選 LBM 耦合)。

> **進度:✅ 2026-09-29** `physics/fields.mojo`:`ForceField`(重力區 / 徑向 / 風 / 阻尼)+ `apply_fields`(每幀步進前以衝量施加,並喚醒被推動的睡眠體)。**重力區不是衝量**:幀首抵消重力的衝量會留下每幀 g·dt²/2 的漂移(量到 1 秒 6 cm),改為逐 body 重力覆寫 `BodySet.grav`,解算器每子步使用(無覆寫時走原分支逐位不變;GPU 解算器拒絕)。風速可取自 `WindGrid`(三線性,可由 LBM 速度場填入)。`tests/test_fields.mojo` 16/16:零重力房內靜止 / 房外自由落體、爆炸近強遠弱且半徑外逐位不動、風中 v = w(1−e^{−kt/m})、阻尼 v0·e^{−kt};**常數網格 == 常數風逐位**(seam parity);重疊力場相加。`bench_fields`:網格取樣使風場成本約 ×2.8。**待辦**:LBM 速度場直接接成 `WindGrid` 的範例;力場的空間索引(現為 bodies × fields 全掃)。

### 17.28 浮力 / 水體積 — Wave B

> **現況**:grep `buoyan`/`Water` 於 `physics/`、`fluid/` 全零命中(唯一命中是不相關
> 的 "watertight" 字面重疊,`docs/ROADMAP.md:1397`);唯一流體是 `fluid/lbm.mojo` 全網格
> LBM 風洞,量級遠大於「水體積 trigger + Archimedes 力」的輕量 gameplay 機制。
> **缺口**:體積化區域(復用 9.3 sensor)偵測浸沒體積比例、施加浮力(∝ 排開體積 ×
> 流體密度 × g)+ 線性/角阻尼,不需完整 CFD。
> **對照組**:常見 Unity `Buoyancy.cs` 樣式套件、UE `PhysicsVolume`(`bWaterVolume` +
> `FluidFriction`)、Godot `Area3D` 自訂浮力腳本。
> **優勢區**:中 —— 浸沒體積若走 `geometry/sdf3.mojo` 隱式場或既有 hull 交集,可比
> 對照組常見的盒體近似更精確;長遠可與 14.4 LBM 阻力係數耦合成「輕量浮力 + 重量級
> 尾流」雙軌案例。
> **規模軸**:浸沒體積計算複雜度(box/sphere 解析 vs hull 數值積分)× 受影響體數。
> **seam?**:是 —— 浸沒體積估計(AABB 近似 vs 解析 vs hull 數值積分)→ parity(規則
> 形狀下解析與數值積分一致)+ bench。
> **相依**:17.27(共用「範圍內施力」骨架)、17.13(shape overlap 查詢)。

> **進度:✅ 2026-09-29** 與 17.27 同模組:`WaterVolume` + `apply_buoyancy`(浮力 = ρ g V_sub 施於浮心、隱式線性 / 角阻尼 v/(1+c·frac·dt) —— 顯式阻尼下浮體會長時間擺盪)。浸沒體積:球解析(球冠)、盒 `samples`³ 中點積分(任意旋轉);軸對齊盒另有閉式 `box_submerged_exact`。`test_fields`:取樣 vs 閉式在 11 個水位皆差 < 體積 / 16(seam parity);半密度箱中心停在水面、四分之一密度球浸沒 0.2585(理論 0.25)、重球沉底。`bench_fields`:球解析約 25 ns / 體,盒 8³ 約 2.3 µs、16³ 約 18 µs。**待辦**:hull / 膠囊浸沒、以平面切割凸體求精確體積取代取樣、LBM 阻力耦合。

### 17.29 通用可斷裂關節 — Wave B

> **現況**:`physics/solver6.mojo:194-229`(`struct Joint6` —— ball/distance/hinge,
> 欄位只有 `kind/a/b/la/lb/rest/axis_a/axis_b/acc/acc_ang`,無斷裂閾值或事件)。
> `docs/ROADMAP.md:1394`(17.5)已提及「接縫鍵結斷裂(9.1 有 weld,缺斷裂閾值+事件)」,
> 但那是**破壞/破碎語境**下的結構性斷裂(`physics/self_collide.mojo:163` 的
> "welded" 只是布料自碰撞註解,非關節);9.1 的 cone-twist/limits/motor/spring/
> prismatic 關節庫(`physics/chain.mojo`)同樣沒有斷裂欄位。
> **缺口**:對**所有**關節種類統一的斷裂力/力矩閾值 + 斷裂事件,供 17.2(撕裂 ragdoll
> 肢體)、車輛零件飛脫、鏈條崩斷等**非破壞語境**使用 —— 與 17.5 的觸發路徑不同
> (17.5 針對接縫/焊接的結構性破壞,這裡是任意關節超載時的通用行為),需在文件釐清
> 邊界避免重工。
> **對照組**:Unity `Joint.breakForce`/`breakTorque`、UE
> `FConstraintInstance::LinearBreakThreshold`、PhysX `PxJoint::setBreakForce`。
> **優勢區**:中 —— `acc`/`acc_ang`(累積衝量)已在 `Joint6` 內,斷裂判定只需除以
> dt 換算力/力矩比閾值;接 17.20 可讓閾值本身可學習(對照組是常數)。
> **規模軸**:關節數 × 每步斷裂檢查成本;斷裂事件密度對事件佇列(17.38)的壓力。
> **seam?**:是 —— 斷裂判定(累積衝量/dt 估計 vs 逐步瞬時力採樣)→ parity(穩態一致)
> + bench。
> **相依**:17.2、17.5(需文件釐清邊界)、17.38(斷裂事件走事件匯流排)。

> **進度:✅ 2026-09-29** `JOINT_BROKEN` 種類(sweep / warm start / island 邊皆跳過,既有種類不變)+ `ContactScene6.set_joint_break(j, force, torque)` / `broken_joints`。**seam 的量測結論**:只看最後一個子步的「累積衝量 / h」在穩態下正確(懸掛 2 kg 讀 19.6 = m·g),但**漏掉衝擊**——扭轉的 hinge 在第一個子步吸收了衝擊,最後子步只剩 4.6 N·m;改為有閾值時每子步取峰值(`joints6.sample_loads`),步末以峰值判斷(`check_breaks`)。`tests/test_joint_break.mojo` 11/11(閾值高於重量則保持、低於則斷且只回報一次;無限閾值與未設定逐位相同;布娃娃髖關節受重擊斷開、腿分離,斷裂事件經 `scheduler.events.Channel` 送達;僅力矩閾值也會斷)。`bench_contact_rules`:取樣使有閾值場景每幀 +4–8%;有閾值時島平行路徑退回串行。與 17.5 的邊界:這裡是任意關節超載的通用行為,17.5 是結構破碎。**待辦**:閾值寫入快照;島平行路徑內取樣。

### 17.30 地形(HeightField)執行期變形 — Wave B

> **現況**:`collision/trimesh.mojo:157-186`(`struct HeightField`,docstring 明言
> "The triangles are never stored" / "O(1) in the size of the terrain",只有建構子
> 讀入 `h: List[Real]`,無 `set_height`/`deform` 方法);`physics/solver6.mojo:474-486`
> (`add_heightfield` 在加入當下算一次 `f.bounds()` 存為該 static body 的 `half`,
> 之後若直接改 `.h[i]` 不會重算 bounds/broadphase fattening)。grep
> `set_height`/`deform`/`modify_height` 全零命中。
> **缺口**:執行期高度編輯 API(單點/區域下壓或抬升,如彈坑、挖掘、履帶壓痕)+
> 邊界/broadphase AABB 的重算或增量更新,以及編輯波及既有休眠剛體時的喚醒規則
> (接 17.25)。與 17.5 不同賽道:17.5 把凸體切成新凸體,這裡是編輯已存在的高度網格,
> 不需重新三角化或產生新 hull,範疇小得多。
> **對照組**:Unity `TerrainData.SetHeights` + collider 重建、常見「可挖掘地形」遊戲。
> **優勢區**:低 —— 純工程。
> **規模軸**:每次編輯影響的子區塊大小 vs 全地形重算成本;編輯頻率(單次彈坑 vs
> 每幀連續變形)。
> **seam?**:是 —— bounds 更新策略(整張重算 vs 受影響子區塊增量 AABB)→ parity
> (結果 AABB 一致)+ bench。
> **相依**:17.25(變形波及睡眠體時的喚醒)、17.13(變形後查詢需讀新高度)。

> **進度:✅ 2026-09-29** `collision/trimesh.mojo` `HeightField`:`set_height` / `deform`(圓盤下挖 / 抬升,Δ·(1−(d/r)²))與 16×16 區塊 min / max 摘要,`bounds_blocks()` 只重算受影響區塊再合併;`ColliderSet.deform_heightfield(i, …, incremental)` 更新 `world_aabb` / `half`;`ContactScene6.deform_heightfield` 並喚醒觸及編輯圓盤的睡眠體(17.25)。`tests/test_terrain_deform.mojo` 11/11:在睡著的箱子下挖坑 → 喚醒、落到坑底;射線讀到新高度;**區塊摘要 AABB == 全表重掃 AABB**(含把山峰挖回平地時最大值縮小)= seam parity;格外 / 零半徑無效果;非高度場拒絕。`bench_terrain_deform`:1024² 地形每次編輯 11.7 µs vs 全表重掃 2.87 ms。**待辦**:編輯後讓持久寬相增量更新(現每幀由 fat AABB 重建);連續變形(履帶壓痕)的批次 API。

### 17.31 物理 LOD / 模擬預算調度 — Wave B

> **現況**:grep `\bLOD\b`/`simulation_budget`/`sim_budget` 於 `physics/*.mojo`、
> `docs/ROADMAP.md` 全零命中;17.10(profiling hooks)只提案量測「每系統/每 phase
> frame 預算」,17.19(solver 硬化)只提案在固定品質下驗證大規模穩定性,兩者都不涉及
> 「量測後主動降級」。
> **缺口**:依重要度/距離/預算動態調整 —— 降低 island 子步數/迭代次數、降低更新頻率
> (每 N 幀 step 一次)、或凍結(非睡眠語意),恢復時無縫接回不產生可見穿透跳變。
> **對照組**:Havok 自適應求解、多數開放世界遊戲的自建物理預算管理器(無統一業界標準
> API,多為引擎整合層自建)。
> **優勢區**:中 —— 6.11 island 著色平行 + 4.1b 變分積分子已是「品質可控」地基,
> 調整子步/迭代數不需換演算法,只需把既有旋鈕按重要度分組驅動。
> **規模軸**:island/body 數 vs 可用 frame 預算;降級程度(iters 1↔8)對品質(穿透/
> 抖動)的曲線。
> **seam?**:是 —— 全品質 solve vs LOD 降級 solve 是同一不動點迭代在不同
> iters/substeps 下的實例;parity(LOD=max 與現況逐位相同)+ bench(品質 vs 成本
> 曲線,呼應 17.19 的 iters-vs-殘差量測設計)。
> **相依**:17.10(預算量測是降級輸入)、17.19(旋鈕共用)、17.18(批次多世界的每 env
> 預算是同一問題的另一形式)。

> **進度:✅ 2026-09-29** `ContactScene6.freeze` / `unfreeze` / `is_frozen`:凍結 = 暫時切成 STATIC 並記住原動作型別(`BodySet.frozen_motion`),速度欄位原封不動 → 解凍後以原速度無縫接續,凍結期間是其他物體的靜止障礙;解算器謂詞完全不用改。`physics/lod.mojo`:`DistanceLOD`(依觀察點距離凍結 / 解凍,含遲滯帶)、`SimBudget`(依量測步進時間在 [min, max] 間調 iters 再調 substeps,超過目標 110% 降級、低於 70% 回升、之間持平)。`tests/test_lod.mojo` 18/18:凍結中不動、解凍後速度逐位相同;落在凍結箱上的箱子停在其上;**覆蓋全場的 LOD + 天花板預算與原解算器逐位相同**(seam parity);觀察者移動時的凍結 / 解凍與遲滯;預算降級 / 回升 / 持平。`bench_lod`:10 層箱塔穩態頂誤差在 iters 1–8 皆約 30 mm(軟接觸柔度主導),成本隨 iters 線性 → 此區間降級幾乎不損品質;凍結一半物體每幀成本減半(1.9×)。**待辦**:凍結狀態寫入快照;逐 island 的品質分級(目前 iters / substeps 是全域)。

### 17.32 執行期分級日誌設施 — Wave A(工具;錯誤政策的「記錄」層)

> **現況**:grep `Logger`/`LOG_`/`log\b` 於 `ecs/`、`physics/`、`scheduler/` 僅命中
> `harness/bench.mojo`、`harness/runner.mojo`(離線 benchmark 的 print,非分級/分類
> 日誌)與 `ecs/commands.mojo`(命中字串是 "recording"/"replay",與日誌無關)。全引擎
> 無 warn/error/info 分級或按子系統(solver/broadphase/scheduler)分類的日誌設施。
> **缺口**:分級(trace/debug/info/warn/error)+ 分類(per-subsystem tag)+ 可配置
> 輸出目的地(可與 17.10 trace 匯出共用環狀緩衝)的最小日誌 API。
> **對照組**:UE `UE_LOG`(category+verbosity)、Unity `Debug.Log`/`ILogger`、Godot
> `print_verbose`。
> **優勢區**:不適用 —— 基礎設施。
> **規模軸**:每幀日誌呼叫的 overhead(關閉分級時應趨近零成本);緩衝滿載丟棄策略。
> **seam?**:否(單一設施);定律 v3——至少 solver6 的 NaN/退化偵測、broadphase 容量
> 溢位須實際發出日誌,不能只是 API 存在。
> **相依**:17.10(共用緩衝/時間戳)、17.33(斷言失敗走同一輸出)。

> **進度:✅ 2026-09-27** `diag/log.mojo` + `diag/level.mojo`:`LogRing` 分級 + 分類環形緩衝,comptime `LUDENS_LOG_LEVEL` 閘門,溢位 drop-newest 並計數;引擎套件不 `print`(ARCHITECTURE §2 規則 1),由測試 / 範例讀 `dump()`。`tests/test_diag_log.mojo`;`bench_diag` 表 (a):關閉層級與「不呼叫」落在雜訊內,證實編譯期閘門零成本。(`7978b69`)

### 17.33 執行期斷言 / 不變量檢查層 — Wave A(工具;錯誤政策的「立即終止」層)

> **現況**:grep `debug_assert`/`Contract`/`precondition` 於 `ecs/`、`physics/`、
> `scheduler/` 全零命中;現有測試用 `harness/runner.mojo` 的 `Suite`,僅存在於
> `tests/`,不是可留在生產路徑、依 build 設定開關的執行期不變量檢查。
> **缺口**:可在 debug/release 建置間開關的執行期不變量斷言(如「island label 必須
> 在 [-1, n)」、「NaN 不得進入 solver」),失敗時可選擇 log(接 17.32)或中止,供
> **執行期**捕捉定律 v3 提到的退化案例類型,而非只靠離線測試。
> **對照組**:UE `check()`/`ensure()`、Unity `Debug.Assert`、Godot
> `ERR_FAIL_COND_V`。
> **優勢區**:低 —— table stakes,純工程紀律工具。
> **規模軸**:斷言密度 vs release build 下的零成本編譯期剔除(Mojo comptime 強項)。
> **seam?**:否;落地方式 = debug 建置下把既有 parity/測試已知的極端案例(零長度法向、
> NaN、負質量)複用為執行期斷言。
> **相依**:17.32(共用輸出)、17.19(硬化測試發現的不變量直接變成斷言)。

> **進度:✅ 2026-09-27** `diag/invariant.mojo`:文件化引擎的 `debug_assert` 慣例(不重造),加熱路徑用 `invariant_finite`(NaN / Inf);建置以 `-D ASSERT=all` 跑測試(`15a0eb8`)。錯誤政策的「立即終止」層,與 17.0h 的邊界 `raise` / 步末 NaN 隔離分工。`tests/test_diag_invariant.mojo`。(`7978b69`)

### 17.34 每幀 / 暫存集區配置器 — Wave A

> **現況**:grep `Allocator`/`Arena`/`PoolAllocator`/`FrameAllocator` 於全樹(排除
> `build/`)只命中 `tests/_spikes/spike_dispatch_policy.mojo`(未接線的實驗性 spike)。
> 所有暫存資料(接觸對列表、debug-draw 指令、查詢結果)都用 `List[...]` 逐幀重新配置/
> 成長,沒有可重置的競技場(arena)供這些「活不過一幀」的資料共用記憶體。
> **缺口**:逐幀重置(reset,不逐一釋放)的 bump/arena 配置器,供 17.9(debug-draw
> 佇列)、17.13(batched query 暫存)、solver6 的 `_collect_pairs` 暫存列表使用。
> **對照組**:UE `FMemStack`、Unity DOTS `Allocator.TempJob`/`Allocator.Temp`。
> **優勢區**:低-中 —— Mojo 無 GC、手動所有權模型下,frame arena 比對照組(語言有
> GC 兜底)更直接影響效能上限。
> **規模軸**:每幀暫存位元組數 vs `List` 逐次成長重配的攤銷成本對照。
> **seam?**:是 —— 暫存容器實作(`List` 逐幀重配 vs arena reset)→ parity(相同資料
> 內容)+ bench(配置/釋放開銷)。
> **相依**:17.9(第一個天然使用者)、17.13(batched query 暫存)。

> **進度:✅ 2026-09-27** `diag/arena.mojo`:`FrameArena` 單次配置上的 bump allocator,型別化 `alloc[T]`、`reset()` 重用、溢位 raise + 計數。`tests/test_diag_arena.mojo`(含與 List 的 parity);`bench_diag` 表 (b):N=64..65536 筆 / 幀,arena 持平約 1.9 ns/筆,List-per-frame 慢 1.5–4×(依 N)。seam 列在 CATEGORY §2.2。(`7978b69`、`8f5f29c`)

### 17.35 計時器 / 補間 / 緩動曲線 — Wave A

> **現況**:grep `Timer`/`Tween`/`Easing`/`ease_` 於全樹只命中
> `tests/test_backend_parity.mojo`(不相關字串)。沒有「N 秒後觸發回呼」的計時器,也
> 沒有緩動函式庫或對現有型別(`Real`、`Vec3`、`geometry/motor.mojo` 的 Motor)的補間。
> **缺口**:遊戲邏輯計時器(cooldown、buff 持續時間、延遲觸發)+ 標準緩動曲線集合 +
> 補間函式,和 17.7(狀態插值)共用 alpha 概念但服務對象不同(17.7 是渲染插值,這裡是
> 時間驅動的遊戲邏輯數值變化)。
> **對照組**:Unity 生態系標準 `DOTween`/`iTween`、UE `FTimerManager` +
> `UCurveFloat`、Godot `Tween` 節點(核心引擎一級功能)。
> **優勢區**:中 —— motor/bivector 補間可直接復用既有 `geometry/galie.mojo` 的
> `geodesic`(等速螺旋)而非 lerp+renormalize,天生比對照組「位置 lerp + 四元數 slerp
> 各自處理」更一致。
> **規模軸**:同時活躍計時器/tween 數 × 每幀更新成本。
> **seam?**:是 —— 補間對象的差值方式(scalar lerp / Vec lerp / motor geodesic)是
> 既有 §3 表示函子在「時間驅動」情境下的重用;parity 與 `test_motor_transform` 的
> geodesic 端點一致性共用。
> **相依**:17.7(共用 alpha/插值子概念)、17.6(動畫圖過渡曲線可能重用同一套緩動)。

> **進度:✅ 2026-09-28** `scheduler/timers.mojo`:`TimerQueue` seam —— `TimerHeap`(陣列二元堆)vs `TimerWheel`(兩層環 + 遠環 cascade),皆以 (due_tick, 排程序號) 觸發,供 17.39 / 17.16 回放決定論。`procedural/tween.mojo`:31 條 Penner 緩動(comptime `kind` 零成本分派 + runtime `ease_dyn` 對照),`Tween` 對 Real / Vec3 用 lerp、對 Motor2 / Motor3 用 `galie` geodesic(螺旋插值,以作用於點比較)。測試 `test_timers`(heap↔wheel 種子 parity)/ `test_tween` / `test_timers_integration`(接 `FixedLoop`);`bench_timers`、`bench_tween`;CATEGORY §2.3。(`9b33cc7`,merge `5429fda`)

### 17.36 樣條 / 曲線(路徑) — Wave A

> **現況**:grep `Spline`/`Bezier`/`CatmullRom` 於全樹零命中;`geometry/` 目錄有
> motor/dualquat/mat/quat 等變換表示,但沒有任何參數化曲線型別。
> **缺口**:至少 Catmull-Rom 與三次 Bezier 樣條(供載具賽道中線、AI 巡邏路徑等非渲染
> 用途),含弧長參數化(等速取樣)與最近點查詢。
> **對照組**:Unity Splines 套件、UE `USplineComponent`、Godot `Curve3D`/`Path3D`。
> **優勢區**:中 —— 樣條切線可直接餵給 motor 的 look-at/朝向建構(重用
> `geometry/motor.mojo`),比對照組「曲線位置 + 另算朝向四元數」少一次表示轉換。
> **規模軸**:控制點數 × 取樣密度;弧長表建構的預處理成本 vs 執行期查詢頻率。
> **seam?**:是 —— 曲線族(Catmull-Rom vs Bezier)對同一控制點集合在端點/切點的行為
> → parity(次數退化情形一致)+ bench(取樣成本)。
> **相依**:17.4(賽道中線)、17.14(導航路徑平滑)、17.3(IK look-at 沿路徑瞄準)。

> **進度:✅ 2026-09-28** `geometry/spline.mojo`:Catmull-Rom(comptime alpha:uniform / centripetal / chordal)與分段三次 Bezier,維度泛型;CR 段以 Barry-Goldman → Hermite 精確轉為 `CubicBezier`,故弧長表、`closest_point`、RMF(平行移動)motor 標架全只寫一次。`tests/test_spline{,_parity,_frames}.mojo` 共 577 檢查(極端:2 控制點、重合點零長段無 NaN、閉環、查詢點在曲線上 / 無窮遠);`bench_spline`;接線範例 `examples/15_spline_rmf.mojo`。(`06f24e3`,merge `74ae0fb`)

### 17.37 實體池化 — Wave A

> **現況**:`ecs/entity.mojo:1-19`(`Entity.gen` 只保證同 id 回收後舊 handle 可偵測
> 為 dead,不等於物件池)、`ecs/world.mojo:27,30,53,58`(`spawn`/`despawn`/`spawn1`/
> `spawn2` 是唯一生命週期入口)。grep `Pool`/`ObjectPool`/`object_pool` 於 `ecs/*.mojo`
> 零命中。高頻 spawn/despawn(子彈、特效代理、AI 波次)每次都走完整 archetype 遷移
> 路徑。
> **缺口**:預先配置 N 個帶模板元件集的實體、以啟用/停用取代「despawn 再 spawn」,
> 避免重複的元件插入/archetype 遷移成本。
> **對照組**:Unity `ObjectPool<T>`、UE 社群常見物件池樣式、Bevy 的 disabled-entity
> marker 慣例。
> **優勢區**:低 —— 純工程效能優化。
> **規模軸**:池大小 × 啟用/停用頻率;與直接 spawn/despawn 的攤銷成本比較(N=1 控制
> 組須略慢方為可信,呼應既有量測設計慣例,如 `sensors.mojo` 的攤銷 batch 量測)。
> **seam?**:是 —— 生命週期策略(直接 spawn/despawn vs 池化啟用/停用)→ parity(啟用
> 後元件值與新 spawn 一致)+ bench(高頻收發吞吐)。
> **相依**:17.12(prefab 格式若落地,池化模板定義可共用)。

> **進度:✅ 2026-09-28** `ecs/pool.mojo`:`Pool` / `PooledEntity` / `Disabled`,六個 `StorageBackend` 全支援;`acquire` 每次重套 template;順帶修 `World` 存取子的 stale-handle 檢查(審計 F14);容量計數接 `diag`。`tests/test_pool.mojo`(六後端 parity、`active_query2` 排除停用實體、固定容量耗盡拒絕 + 計數、無界成長、外來實體、跨釋放的舊 handle);`bench_pool`:N=1 時 pool 慢 1.19–1.74×(含一次 `prime`),N≥1000 起快 1.08–1.51×;接線範例 `examples/16`(子彈池)。(merge `c069054`)

### 17.38 遊戲事件匯流排 / 訊息系統 — Wave A

> **現況**:`ecs/reactive_backend.mojo:15-23`(push observers `observe1`/`observe2`
> 只針對**元件層級**的 add/set/remove 事件,docstring 明言 "event-kind mask ×
> component set");`scheduler/message.mojo:1-29`(`Envelope[M]`/`MessageType` 是
> actor 排程器內部的**定址**信箱,`target` 是 entity id 或 system index,是排程執行
> 序機制而非跨系統廣播)。兩者都不是「任意具名事件(如 OnPlayerDied)可被任意數量、
> 彼此不知情的監聽者訂閱」的 gameplay pub/sub。
> **缺口**:解耦的多對多事件匯流排 —— 具名/型別化事件、動態訂閱/取消訂閱、發布順序
> 決定性(供 replay/rollback 相容)。
> **對照組**:Godot `Signal`(一級引擎功能)、UE `Multicast Delegate`/`Event
> Dispatcher`、Unity C# event 生態慣例。
> **優勢區**:低-中 —— 可直接複用 `scheduler/message.mojo` 的 envelope/mailbox
> 決定性投遞模式(已解決「同 tick 送達」與「重播位元相同」,見
> `docs/ROADMAP.md:729`「wake 階段送出的訊息在同一個 tick 內就被收到並處理」),把
> 定址方式從「entity id / system index」泛化成「訂閱者清單」即可,實作風險因此屬
> Wave A 而非從零設計。
> **規模軸**:事件型別數 × 訂閱者數;每幀事件量對決定性重播(排序穩定性)的要求。
> **seam?**:是 —— 投遞策略(push 廣播 vs 訂閱者輪詢)是 CATEGORY.md §2 既有「push
> observers vs 輪詢」列(`ecs/reactive_backend.mojo`)在 gameplay 事件語境的重用;
> parity = 重播 ≡ 輪詢結果(與 `test_observers` 同構)。
> **相依**:17.29(斷裂事件)、17.9(debug-draw 可訂閱同一匯流排)、17.16(rollback
> 需要事件重播決定性,這裡先做基礎機制)。

> **進度:✅ 2026-09-28** `scheduler/events.mojo`:`EventChannel` seam —— `Channel[E]`(pull,正式路徑)vs `PushChannel[E]`(fan-out 對照組);呼叫序決定論投遞、保留兩次 `update()` 的雙緩衝、每讀者游標、未讀丟棄計入 `diag.counters`。`ContactEvent` 轉接放在測試端(collision 與 scheduler 同層)。測試 `test_events`(parity / 決定論 / 極端)、`test_events_gameloop`、`test_events_contacts`(真 `ContactScene6` 疊塔);`bench_events` 掃 讀者 × 事件 / 幀。(`02d14c5`,merge `422ab38`)

### 17.39 輸入錄製 / 決定論回放(QA・ghost,非網路) — Wave B

> **現況**:地基已在但未組裝:`scheduler/rng.mojo`(決定論 RNG)、
> `physics/serialize.mojo:99`(全狀態快照,自註 "not an asset reference",
> `docs/ROADMAP.md:388-395` 已驗證 save→load→save byte-identical)。但 grep
> `Replay`/`InputRecord`/`input_record` 於全樹只命中 `ecs/commands.mojo`(命中字串是
> command buffer 的 "recording order",與輸入錄製無關)。沒有「錄製輸入序列 + 定期
> 快照,之後可從任一快照點決定性重放」的組裝層。
> **缺口**:帶 tick 編號的輸入流錄製格式、快照間隔管理、重放驅動(餵錄製輸入 + 從
> 快照恢復而非從 t=0 重跑)。與 17.16 的差異:不含網路傳輸/預測/reconciliation,純
> 單機 QA 自動化回歸測試、ghost 賽道錄影、killcam,因此不受 17.16「傳輸層格式綁定
> 平台整合」的 gating 限制,現在就能做。
> **對照組**:賽車遊戲 ghost 錄影(如 Trackmania)、格鬥遊戲 replay 系統、UE
> Demo Net Driver(概念相通)。
> **優勢區**:中高 —— 決定論快照(6.10)+ 決定論 RNG 已是這件事最難的前提,對照組
> (非 lockstep 引擎)通常要另外驗證決定性,這裡幾乎是組裝既有零件;做完後直接降低
> 17.16 的實作風險。
> **規模軸**:快照間隔(記憶體 vs 回放尋位精度)× 錄製長度;回放時重跑幀數 vs 直接
> 跳快照的成本。
> **seam?**:是 —— 回放實作(全程重跑 vs 快照+短重跑)→ parity(同輸入下最終世界
> 逐位相同)+ bench(回放尋位延遲)。
> **相依**:6.10(快照)、`scheduler/rng.mojo`、17.16(此項是其地基驗證的前置練習,
> 非其子項)。

> **進度:✅ 2026-09-29** `gameplay/replay.mojo`:`SimState`(場景 + 角色控制器 + RNG)以 `sim_tick` 逐 tick 推進;`Recorder` 錄輸入、每 `interval` tick 存快照(6.10 的 `scene_to_string` + 控制器副本 + RNG 狀態值)、每 tick 存 FNV-1a 狀態雜湊;`replay_from_start` / `seek`(最近快照 + 短重跑)/ `first_divergence`(重跑比對雜湊,回傳第一個分歧 tick)/ `ghost`。`tests/test_replay.mojo` 8/8:角色走、跳、以 RNG 隨機方向踢箱子 300 tick → 從頭回放與實況逐位相同、每 tick 雜湊重現;**seek 與全程重跑在 8 個目標 tick 逐位相同**(seam parity);ghost 軌跡 == 實況軌跡;竄改第 137 tick 的輸入 → 分歧恰在 137;間隔 1。`bench_replay`:600 tick 錄製中尋位到 590,快照間隔 10 → 0.10 ms、120 → 4.2 ms、全程重跑 32.6 ms。**待辦**:錄製檔案化(目前在記憶體);快照差分壓縮;接 17.16 的網路 rollback。

### 17.40 存檔系統(相對於決定論快照) — Wave B

> **現況**:`physics/serialize.mojo:99` 自我定位「this format is a full state
> snapshot, not an asset reference」;`docs/ROADMAP.md:388-395` 的 6.10 是
> bit-identical 完整世界 blob(約 20KB),任何程式碼變更都可能讓舊存檔失效,不設計
> 給跨版本相容。這與玩家導向「存檔」(需 schema 版本升級、只存部分進度、可能跨 build
> 相容)是不同問題。
> **缺口**:基於 schema/版本標記的選擇性序列化(存哪些欄位、缺欄位/新欄位如何處理),
> 依賴 17.11(反射)取得欄位 metadata 而非手寫序列化每個型別。
> **對照組**:UE `USaveGame` 版本相容、Unity 自訂存檔系統慣例、Godot
> `ResourceSaver`。
> **優勢區**:低 —— 工程;差異化同 17.12,依賴 17.11 comptime 反射可省手寫版本遷移
> 程式碼。
> **規模軸**:存檔資料量 × schema 版本跨度(遷移路徑數)。
> **seam?**:是 —— 存檔路徑(schema 驅動 vs 決定論全狀態快照)→ parity(同場景兩
> 路徑載入後,schema 存檔覆蓋到的欄位與快照一致)。
> **相依**:17.11(前提)、17.12(姊妹問題,常共用 schema 基礎設施但服務不同資料)。

> **進度:✅ 2026-09-29** `gameplay/save.mojo`(建在 17.11 schema 上):`SaveWriter.add[T](section, values, version, type_name)` / `bytes()`、`SaveReader(bytes).read[T](section, template, out)`——具名區段、描述每段一次、**按欄位名**載入目前型別(新欄位保留預設、舊欄位略過、改型不重解釋,`ReadReport` 回報),缺區段讀為空;`BodyRecord` + `save_bodies` / `load_bodies`(只存動態體姿態與速度,套回關卡腳本重建的場景;快取只在最後剪一次——逐體 `teleport` 會每次重掃快取,1024 體時 16.4 ms → 1.69 ms)。`tests/test_save.mojo` 11/11:物品清單往返;「build 1」的 PlayerV1 存檔載入「build 2」的 PlayerV2;**同一關卡模擬 1 秒後的存檔與 6.10 快照,載入後存檔涵蓋的每個欄位逐位相同**(seam parity),再步進 1 秒兩者差 2.3e-5(差異來自存檔刻意不存的 warm-start 快取);壞 magic / 截斷 / 較新格式拒絕,空存檔可載入。`bench_save`(1024 箱):快照 932 KB、寫 3.9 ms / 讀 8.6 ms;存檔 74 KB、寫 0.17 ms / 讀 + 套用 1.7 ms。**待辦**:ECS 世界整批存讀的便利層;檔案 I/O(目前給 bytes);壓縮。

### 17.41 繩索 / 纜線約束 — Wave B

> **現況**:grep `Rope`/`Cable` 於 `physics/*.mojo` 只命中 `properties`/`property`
> 的子字串重疊(`physics/adjoint.mojo:25`、`physics/fem.mojo:10,18`、
> `physics/pbf.mojo:29`、`physics/sensors.mojo:4`),真實的繩索/纜線約束不存在;
> `physics/solver6.mojo:194-229` 的 `Joint6`(ball/distance/hinge)與
> `physics/chain.mojo` 的縮座標鏈都是「剛性連桿」語意,沒有多節點、可彎曲、可自我碰撞
> 的柔性線。
> **缺口**:由多個距離約束(或 Cosserat 桿模型)串接、可選自我碰撞(重用
> `physics/self_collide.mojo`)、兩端固定於剛體局部點的柔性纜線。
> **對照組**:UE `UCableComponent`(引擎內建一級元件)、PhysX FleX 繩索範例、
> Houdini/Blender 的 Cosserat rod 求解器。
> **優勢區**:中 —— 既有 PBD/XPBD 距離約束(`physics/pbf.mojo`、
> `physics/vbd_cloth.mojo` 的著色 Gauss-Seidel)可直接降維重用成 1D 鏈;變分積分子
> (4.1b)的穩定性優勢在長鏈上比顯式彈簧-阻尼更不易爆炸。
> **規模軸**:節點數(鏈長)× 子步數;自我碰撞開關的成本影響(同 `test_self_collide`
> 量測設計)。
> **seam?**:是 —— 繩索求解器變體(distance-joint 鏈 vs PBD 1D 鏈 vs Cosserat 桿)
> 對同一「兩端固定、重力下垂」場景的靜止形狀 → parity(無彎曲剛度極限下懸鏈線解析解
> 三者一致)+ bench。
> **相依**:9.1(距離關節)、17.5、17.29(纜線斷裂可共用斷裂閾值機制)。

> **拒絕(5)**:時間縮放 / 暫停(`scheduler/gameloop.mojo:27` 的 `frame_dt` 由呼叫端
> 縮放或跳過即可,非缺失能力);transform 階層傳播(已在 `ecs/hierarchy.mojo` +
> `ecs/transform_systems.mojo`,CATEGORY §2 有列);gameplay 粒子(solver6 / SPH / PBF /
> MPM 已可承載,重做屬冗餘);查詢結果快取(持久化 DBVH 已在,且與 17.13 batched 重疊);
> hot config / CVar(已併入 17.21)。

> **進度:✅ 2026-09-29** `physics/rope.mojo`:`Rope` = XPBD 1D 鏈(柔度 α、自身子步、兩端可釘住世界點或掛在剛體局部點、粒子對場景碰撞器推出、段張力超限即斷)。**載重路徑走解算器**:`tie()` 在兩端間加一條繩長的距離關節(釘住端建不碰撞的靜態錨體),吊物重量由關節承擔、斷裂走 17.29 閾值,XPBD 粒子只負責形狀與披掛(單向;與引擎的 cable component + physics constraint 配對同理)——先試過把剛體當繩端無限質量錨點並回饋反作用衝量,張力被高估到 160 N(應為 19.6)。`tests/test_rope.mojo` 12/12:下垂 1.0073 vs 懸鏈線解析 1.0053;距離關節剛體鏈 1.0417(seam:兩者皆近似懸鏈線,5% 內);吊 2 kg 箱於 2.9997、載重恰 19.6 N;斷裂後箱落下;披掛在箱頂;柔性繩伸長更多;單段即擺。`bench_rope`:XPBD 繩比同長剛體鏈快約 5–6×。**待辦**:關節為雙向(無鬆弛);繩自碰撞;Cosserat 桿(彎曲 / 扭轉剛度)。

### 17.42 LBM 風洞收尾(Phase 14 遺留併入) — Wave B
> **緣起**:Phase 14 各節明列但未入 Phase 17 的四項(2026-09-29 盤點補收)。
> **現況**:`fluid/` D3Q19 LBM 為純 CPU;壁面為半程 bounce-back(14.2);受力僅動量交換一條路徑(14.4)。
> **缺口**:
> - (a)**GPU kernel**(14.1):CPU 參考已存在可做逐位 / 容差 parity;走單一 device context 擁有者(Wave B 前置)。
> - (b)**插值 bounce-back**(14.2):非格線對齊壁面的二階邊界,作為半程 bounce-back 的 seam 變體。
> - (c)**壓力 + 黏性應力積分**(14.4):第二條測力路徑,與動量交換互為對照。
> - (d)**SPH 邊界粒子對照組**(14.2):既有 SPH 無此機制,需一併建立。
> **對照組**:Palabos / waLBerla(GPU LBM)、Bouzidi 插值 bounce-back、文獻 Cd 關聯式(14.6 既有)。
> **優勢區**:(a)格數 ≥ 10⁶ 的 GPU 吞吐(MLUPS);(b)彎曲壁面在低解析度下的 Cd 誤差收斂階;(c)兩法差異隨解析度縮小。
> **規模軸**:格數、壁面曲率 / 解析度。
> **seam?**:是 —— (a) CPU/GPU、(b) 半程 / 插值邊界、(c) 兩條測力路徑,各附 parity + bench row。
> **交付**:普通(球繞流 Cd)/ 整合(接 14.6 驗證套件)/ 極端(全埋固體、零進口速度、單格厚板)。

> **進度:✅ 2026-09-29**(四項全做)
> (b)**插值 bounce-back**:`Lbm.interp` + `link_q`(球的真實幾何以射線求交得 q),Bouzidi 線性公式;q = ½ 時兩分支恰退化為半程。`tests/test_lbm_bounce.mojo`:只有盒狀固體(所有連結 q = ½)時與半程**逐位相同**(seam parity);球心平移半格,阻力變動 半程 6.9% vs 插值 1.8%;周期盒質量漂移 1.1e-4。
> (c)**第二條測力路徑**:`Lbm.momentum_flux_force`(控制面上 Π = Π_eq + (1−1/2τ)Π_neq 的通量)與動量交換在四個組態中最大相差 1.5%。
> (a)**GPU kernel**:`fluid/lbm_gpu.mojo` `LbmGpu`(BGK + 均勻體力、拉取式串流 + 半程 bounce-back、風洞進出口,三個 kernel 逐行對應 CPU;以 CPU `Lbm` 建場後上傳、下載回 CPU;拒絕 LES / 插值格網;context 由呼叫端傳入)。`tests/test_lbm_gpu.mojo`:風洞 + 球 200 步 |Δf| ≤ 3.6e-7、體力通道速度剖面逐位相同。`bench_lbm_gpu`:1.77M 格 GPU 55.6 MLUPS vs CPU 3.2(約 17×)——**仍遠低於記憶體頻寬上限(約 20× 空間)**,kernel 改 32 位元索引只從 43 升到 55,瓶頸未定位(待 profiler)。
> (d)**SPH 邊界粒子對照組**:`physics/sph.mojo` `BoundaryParticles`(Akinci 2012,ψ = ρ0 / 自身核和)+ `box_floor_boundary` + `sph_step_boundary`(`sph_step` 即無邊界粒子的特例)。`tests/test_sph_boundary.mojo` 6/6:無邊界粒子、以及邊界粒子在核半徑外時與原 `sph_step` 逐位相同;流體在地板攤平 1 秒後,夾回式牆面的質心塌到 3 mm(底層缺鄰居而低估密度),邊界粒子維持 25 mm。
> **待辦**:GPU kernel 效能定位、GPU 上的動量交換歸約 / LES / 插值 bounce-back;邊界粒子的鄰居搜尋走格網(現為暴力)、牆面(非僅地板)取樣。

### 17.43 Undo / redo 交易層 — Wave B(編輯器前置)
> **緣起**:2026-09-30 編輯器邊界分類找出的缺口 —— 外部編輯器依賴的 15 項核心能力中,
> 除 17.12(gated)外唯一未編號者。
> **現況**:零件已在但未組合:`ecs/commands.mojo` `CommandBuffer` 只記**正向**結構變更
> (spawn / despawn / add / remove),`apply` 後不留反向資訊;17.11 `TypeSchema` 能按欄位名
> 讀寫值,但沒有「前值 / 後值」記錄;`ContactScene6` 的變更(`add*` / 關節 / 材質 / 規則 /
> `deform_heightfield`)只能靠 6.10 全快照回復。
> **缺口**:
> - **交易**(`begin` / `commit` / `abort`):一組變更成為一個 undo 步;可巢狀、可合併
>   (連續拖曳同一欄位合為一步)。
> - **反向操作記錄**:結構變更記下被刪實體的全部 component(經 17.11 schema 序列化)以便
>   復原;欄位變更記 (entity, type, path, 前值, 後值) 位元組。
> - **物理場景變更**:body / collider / 關節 / 規則 / 地形編輯的 inverse op(地形記受影響
>   區塊的舊高度,接 17.30 的區塊摘要)。
> - undo / redo 堆疊、深度 / 記憶體上限、redo 在新變更時截斷。
> - 與 4.4 observers 相容:undo 觸發的變更照常推播(編輯器視圖同步)。
> **對照組**:UE `FTransaction` / `FScopedTransaction`(物件快照差分)、Unity `Undo.RecordObject`、
> Godot `UndoRedo`(do / undo 方法對);**本庫內部對照**:6.10 全快照回復(seam 的另一端)。
> **優勢區**:差分記錄 vs 全快照 —— 場景越大、每步變更越小,差分的記憶體 / 時間優勢越大;
> 理論優勢區 = 大場景 × 單欄位編輯。反向:整批變更(全場景變形)時快照可能較省,需一併量。
> **規模軸**:場景實體數 × 每交易變更數;undo 深度。
> **seam?**:是 —— `UndoLog`(inverse op 差分)vs `SnapshotUndo`(每交易一次 6.10 快照):
> 同一編輯序列 undo 到任一步後**世界逐位相同**(parity)+ 記憶體 / 延遲 bench row。
> **交付**:普通(改一欄位 → undo → redo)/ 整合(刪一個帶關節的剛體 → undo 後關節、材質、
> 睡眠狀態、warm-start 以外的欄位逐位還原,並能繼續步進;經 observers 推播)/ 極端(空交易、
> 巢狀 abort、undo 超過深度上限、redo 被新變更截斷、復原已被其他交易刪除的實體參照、
> 1e5 實體場景單欄位編輯的差分 vs 快照成本)。
> **邊界**:本條只做 headless 核心 API;undo 歷史的 UI 屬編輯器本體(不在本 repo)。

### 17.85 分級模擬:依因果可達性分配時間 / 空間解析度 — Wave C(架構)
> **緣起**:2026-10-10 使用者提問 —— 世界中實體數遠大於玩家能產生因果交互的實體數時,
> 引擎能否以適當的時間 / 空間解析度維護 simulation state,且分級(LOD)模組本身可替換。
> 設計筆記:`docs/design/17.85-tiered-simulation.md`。
> **現況**(已核對原始碼):**做不到**。執行模型是「每個 fixed step × 所有系統 × 所有實體 ×
> 全精度」。`System.apply` 無狀態、`Scheduler.tick` 跑整個 pack、`FixedLoop` 單一 dt、job graph
> 的 level 只給並行度(`scheduler/scheduler.mojo:26-46`、`gameloop.mojo:93-96`);ECS 查詢只有
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
> 17.39 / 17.40(plan 必須是快照狀態的函數);餵 17.16 rollback(relevance 集合就是 `CausalReach`
> 走的同一張圖)、17.8 大世界(分區 cell 是天然的 tier 邊界)、17.14 / 17.15(導航 / AI 依 tier tick)。
> **邊界**:軟體 / LBM / 粒子第一刀只拿同一 plan 的 per-object period,不改內部;`Aggregate` 替身排後。

### Phase 17 建議順序
> **Wave A 先**(17.13 查詢 → 17.1 控制器 → 17.7 插值 → 17.9 debug-draw → 17.10 profiling):
> 全是接線 / table stakes,做完引擎「可被當遊戲引擎用」,且 17.13 解鎖 17.1 / 17.4 / 17.15。
> **Wave B 主攻差異化**:先 17.20 + 17.18(可微批次模擬 —— 本專案唯一可能領先處,兩者互為
> 前提),並行 17.11 反射(解鎖 C 的多項)、17.17 GPU 剛體、17.6→17.3→17.2(動畫→IK→
> 主動布娃娃,依序相接);17.19 solver 硬化貫穿整個 Wave 當持續工項。
> **Wave C 排後**:17.5 破壞、17.4 載具、17.14 導航、17.15 AI 為
> 純工程可隨時插入;17.8 大世界座標排最末(重觸 Vec3 重構);**17.12 場景格式 / 17.16 網路
> 傳輸 / 17.21 腳本 gated on 平台整合方向** —— 與 [[roadmap-2026-07]] Phase 13 排除 MJCF/URDF
> 同因,需先與使用者定架構。


> **2026-09-27 修訂(納入增補 + 架構閘門)**:執行順序改為
> **(0)閘門先行** —— 工具鏈升 Mojo 1.1.0;`docs/ARCHITECTURE.md`(套件職責 / 分層 /
> 錯誤處理政策 / 測試分層)+ 自動化架構索引與 `check` 閘門(層級違規、循環、跨套件摸
> `_` 私名)先落地,之後每一項都過同一閘門。
> **(1)`diag` 地基**:17.33 斷言 → 17.32 日誌 → 17.34 frame arena → 17.9 debug-draw →
> 17.10 profiling(錯誤政策的偵測 / 記錄 / 終止三層一次到位,後續各項直接使用)。
> **(2)查詢與物理 table stakes**:17.13 查詢 → 17.25 睡眠 API → 17.24 kinematic →
> 17.23 材質 → 17.1 角色控制器。
> **(3)時間與 gameplay 服務**:17.7 插值 → 17.35 計時器 / 補間 → 17.36 樣條 →
> 17.38 事件匯流排 → 17.37 實體池 → 17.22 範例。
> **(4)Wave B**:17.20 + 17.18 → 17.11 反射 → 17.17 GPU 剛體 → 17.6 → 17.3 → 17.2;
> 增補的 B 項依相依插入(17.26 / 17.29 接 17.1 / 17.2 之後、17.27 → 17.28、
> 17.39 接 17.38、17.40 接 17.11、17.31 接 17.10 + 17.19、17.42 接單一 device context 擁有者);17.19 貫穿。

> **2026-10-09 修訂(Wave C 暫停點)**:平台方向拍板 = **C(嵌入式模擬函式庫)**,原 gated 項重排為:
> **已交付**:17.0 F12 · 17.5 破壞 / 破碎 · 17.4 載具。
> **剩餘順序**:(1)17.14 導航 → (2)17.15 AI(EQS 接 17.13、BT tick 可入 10.2)→
> (3)17.16 rollback 核心 + 預測策略 seam + 給宿主傳送的 byte payload API(傳輸層交宿主;
> 決定論只承諾同工具鏈同架構)→ (4)**12.1 C-ABI 嵌入邊界**(世界建構 / 系統註冊 / 查詢 /
> 事件訂閱,v0.x 凍結;前面各項的資料導向 API 由此包出)→ (5)**17.21 Python 綁定**(核心 repo
> 最上層套件;測試以客戶端方式安裝進乾淨環境、不靠 `-I build`)→ (6)17.17 GPU articulation /
> narrowphase → (7)17.8 大世界座標(先 f32 + rebasing + partition,f64 只參數化)。
> **不排**:17.12 場景格式、17.43 undo 層(編輯器相關)。

> **2026-10-10 修訂(新增 17.85)**:使用者提問「實體數 ≫ 可因果交互數時能否分級維護 state」,
> 盤點結論為目前做不到(見 17.85 現況);新增 **17.85 分級模擬** 插在 **17.15 AI 之後、17.16
> rollback 之前** —— rollback 的 relevance 集合與 `CausalReach` 是同一張圖,先有 tier plan 再做
> rollback 可避免兩套興趣管理。剩餘順序改為:17.14 → 17.15 → **17.85** → 17.16 → 12.1 → 17.21 →
> 17.17 → 17.8。
> **本輪遺留待辦**(詳見各節進度註):F12 —— mesh / heightfield 接觸只有觸碰無深度、base motion
> 未參數化;17.5 —— 碎片慣量只取對角、`FractureSet` 不在快照、單片碎片入睡率 ~60%;17.4 ——
> 開放式差速只均分、無 Ackermann / 簧下質量、載具狀態不在快照。`BENCHMARK_REPORT.md` 尚未
> 以 `pixi run benchmark` 重產(17.5 / 17.4 的 bench 列已在範本)。

> **2026-10-09 增補(17.44–17.84)的排序**:未插入上面的剩餘順序,待使用者決定。
> 依相依關係的建議:
> - 平台方向 C 的前提,與 12.1 同期:17.75 嵌入契約(宿主注入 job system / allocator、
>   非同步步進、單位慣例)、17.76 平台可攜、17.81 的 LICENSE 與發佈管道。
> - Wave A 增補(17.45 / 17.48 / 17.49 / 17.53 / 17.81–17.83)不依賴其他未做條目,
>   可隨時插入;其中 17.81 的 CI 先做,之後每一項都過同一條自動閘門。
> - 17.47 / 17.51 / 17.52 承接 9.1 / 13.8 的校正,是已標完成的條目的剩餘部分,
>   建議排在其他 Wave B 增補之前。
> - 17.55 連續體步進契約是 17.56 / 17.58 / 17.59 / 17.62 的前提。
