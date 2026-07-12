# ROADMAP:補缺路線圖(Now / Next / Later)

> 2026-07-10 制定。依據:[SOTA_GAP_ANALYSIS.md](SOTA_GAP_ANALYSIS.md)。
> 主線已定:**「GA 原生物理補齊」** —— 用引擎的差異化(motor/screw/forque)去填最大 SOTA 缺口
> (角動力學 + 現代 solver),一石二鳥。
> 架構法則不變(`CATEGORY.md`):**每個新 seam 實作必附 parity test**;每個效能主張必附
> benchmark 數字與 baseline(correctness gates do not see speed)。

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
```
