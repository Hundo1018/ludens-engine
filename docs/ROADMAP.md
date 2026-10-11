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

## 目前位置(2026-10-11)

- **物理與數值核心**:角動力學、sub-stepped soft solver、CCD、islands / sleeping / warm-start、軟體與雙向耦合、
  縮座標關節體(ABA / RNEA / 致動器 / 腱 / 感測器)、FEM / MPM / SPH / PBF / 布料、LBM 風洞、可微模擬
  (reverse tape、comptime 伴隨)皆已交付,各附 parity 測試與 benchmark 列。
- **遊戲執行期外殼(Phase 17)**:Wave A / B 全數交付;Wave C 已交付 17.4 載具、17.5 破壞,其餘
  (17.14 導航起)在 2026-10-09 依使用者指示暫停。
- **平台方向已定為 C**:被宿主引擎嵌入的模擬函式庫,RL 平台次要(2026-10-09,`a93c53d`)。
- **2026-10-09 負空間盤點**:對照 SOTA 引擎找出「不在路線上」的能力,RL / 機器人以外全數入路線,
  成為 17.44–17.84,並擴充尚未開工的 17.14 / 17.15 / 17.16。同一次盤點發現 9.1、13.8 標 ✅ 但程式碼
  不符,已改為 🔶。
- **2026-10-11 整理**:本檔改為依子系統分組;已完成條目的原文移到 ROADMAP_HISTORY.md;未完成條目
  逐條改寫為現況與待辦,原文同樣保存在歷史檔。

## 子系統

| 子系統 | 範圍 | ✅ | 🔶 | ⬜ | ⏸ / 不排 |
|---|---|--:|--:|--:|--:|
| [幾何代數與數值基礎](#幾何代數與數值基礎) | geometry、numerics、AD 係數場、exact predicates | 2 | 0 | 0 | 0 |
| [剛體動力學、接觸與關節](#剛體動力學接觸與關節) | physics:solver6、接觸、最大座標關節、islands / sleeping、材質 | 16 | 2 | 5 | 0 |
| [碰撞形狀、寬窄相與世界查詢](#碰撞形狀寬窄相與世界查詢) | collision、spatial | 9 | 1 | 5 | 0 |
| [縮座標關節體與致動](#縮座標關節體與致動) | chain(ABA / RNEA)、致動器、腱、感測器、統一約束 | 9 | 1 | 1 | 0 |
| [軟體、布料、連續體與流體](#軟體布料連續體與流體) | softbody、cloth、FEM / MPM / SPH / PBF、LBM、繩索 | 13 | 0 | 9 | 0 |
| [可微模擬、批次世界與數值深化](#可微模擬批次世界與數值深化) | diffsim、diffsolver、tape、批次、稀疏線代 | 5 | 1 | 1 | 1 |
| [GPU 計算](#gpu-計算) | GPU kernels 與單一 device context | 2 | 1 | 0 | 0 |
| [動畫與程序化](#動畫與程序化) | procedural:anim / IK / tween / spline / noise / FSM / PCG | 7 | 0 | 3 | 0 |
| [角色、載具、破壞與 gameplay 物理](#角色載具破壞與-gameplay-物理) | gameplay:character / ragdoll / vehicle / fracture / interpolation | 7 | 0 | 5 | 0 |
| [gameplay 服務、AI、導航與網路](#gameplay-服務ai導航與網路) | 規則框架、AI、導航、rollback | 0 | 0 | 6 | 0 |
| [ECS、排程、執行期與診斷](#ecs排程執行期與診斷) | ecs、scheduler、diag、runtime、存檔 / 回放 | 15 | 0 | 4 | 2 |
| [嵌入、腳本與平台](#嵌入腳本與平台) | C-ABI、Python 綁定、宿主整合、平台 | 0 | 0 | 6 | 0 |
| [工程、測試、效能與工具鏈](#工程測試效能與工具鏈) | gate、benchmark、CI、Mojo 版本搬遷、範例 | 8 | 0 | 3 | 0 |

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

### 已決定的剩餘順序(2026-10-09)
1. 17.14 導航
2. 17.15 AI(EQS 接 17.13、BT tick 可入 10.2 job graph)
3. 17.16 rollback 核心 + 預測策略 seam + 給宿主傳送的 byte payload API
4. 12.1 C-ABI 嵌入邊界(世界建構 / 系統註冊 / 查詢 / 事件訂閱,v0.x 凍結)
5. 17.21 Python 綁定
6. 17.17 GPU articulation / narrowphase
7. 17.8 大世界座標(先 f32 + rebasing + partition,f64 只參數化)

**不排**:17.12 場景格式、17.43 undo 交易層(編輯器相關)。

### 17.44–17.84 的插入建議(待使用者決定)
- 平台方向 C 的前提,與 12.1 同期:17.75 嵌入契約、17.76 平台可攜、17.81 的 LICENSE 與發佈管道。
- 不依賴其他未做條目、可隨時插入:17.45 / 17.48 / 17.49 / 17.53 / 17.81 / 17.82 / 17.83;其中 17.81 的 CI
  先做,之後每一項都過同一條自動閘門。
- 17.47 / 17.51 / 17.52 承接 9.1 / 13.8 的校正(已標完成條目的剩餘部分),建議排在其他 Wave B 增補之前。
- 17.55 連續體步進契約是 17.56 / 17.58 / 17.59 / 17.62 的前提(四者的「相依」都列了 17.55)。

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
| 17.19 | [生產級 solver 硬化](#1719-生產級-solver-硬化) | 🔶 | B | F22 第一批已把 island 喚醒 / 入睡與 warm-start 快取比對改成線性(N=4096 簿記 82 → 20.6 ms/幀),但高質量比、大 island、接觸密集堆疊等壓力測試尚未做,滾動球減速 / 下沉的錨點缺陷也未修。 |
| 17.23 | [物理材質與逐對組合模式](ROADMAP_HISTORY.md#1723-物理材質與逐對組合模式--wave-a) | ✅ | A | physics/material.mojo 提供四種組合模式(average/min/multiply/max,較高優先模式勝),BodySet 存逐 body 的 friction 與兩種組合模式,solver6 每對接觸算一次 pair_mu 與組合後的 restitution,並有 parity 測試與 bench(四模式成本在雜訊範圍內)。 |
| 17.24 | [Kinematic 剛體型別(通用可移動體)](ROADMAP_HISTORY.md#1724-kinematic-剛體型別通用可移動體--wave-a) | ✅ | A | solver6 支援 static/dynamic/kinematic 三種運動型別:kinematic 由腳本設定速度或用 move_to 指定目標位姿、會推動動態體,也會喚醒已入睡的動態體;零速度時與 static 逐位 parity,序列化格式升到 v2。 |
| 17.25 | [睡眠/喚醒生命週期公開 API](ROADMAP_HISTORY.md#1725-睡眠喚醒生命週期公開-api--wave-a) | ✅ | A | ContactScene6 提供公開的 is_sleeping、wake(整島喚醒)、set_can_sleep 與 teleport(瞬移、喚醒並清掉 warm-start 快取),無效 id 會 raise;本項不是新 seam,所以 CATEGORY 沒有對應列。 |
| 17.26 | [接觸修改 / 單向平台](ROADMAP_HISTORY.md#1726-接觸修改--單向平台--wave-b) | ✅ | B | physics/contact6.mojo 用資料驅動的 ContactRule(不是 callback)提供 RULE_ONE_WAY 單向平台、RULE_CONVEYOR 輸送帶表面速度與 RULE_FRICTION 逐接觸摩擦覆寫,由 ContactScene6.add_contact_rule 註冊,並有 seam parity 測試(規則不匹配時與無規則逐位相同)。 |
| 17.29 | [通用可斷裂關節](ROADMAP_HISTORY.md#1729-通用可斷裂關節--wave-b) | ✅ | B | ContactScene6.set_joint_break(j, force, torque) 對所有 Joint6 種類提供力 / 力矩閾值,有閾值時每子步取峰值負載(joints6.sample_loads)、步末 check_breaks 轉為 JOINT_BROKEN,斷裂事件經 scheduler.events.Channel 送達。 |
| 17.31 | [物理 LOD / 模擬預算調度](ROADMAP_HISTORY.md#1731-物理-lod--模擬預算調度--wave-b) | ✅ | B | ContactScene6.freeze / unfreeze 以暫時切成 STATIC 並保留速度實作凍結,physics/lod.mojo 提供 DistanceLOD(距離 + 遲滯)與 SimBudget(依量測步進時間調 iters 再調 substeps),全場 LOD + 天花板預算與原解算器逐位相同。 |
| 17.44 | [複合形狀、共享形狀實例與質量性質](#1744-複合形狀共享形狀實例與質量性質--wave-b) | ⬜ | B | 2026-10-09 盤點新增:複合形狀 / 子形狀局部位姿、共享形狀實例、非均勻縮放形狀、依密度算質量與完整慣量張量 |
| 17.47 | [最大座標關節庫補完](#1747-最大座標關節庫補完--wave-b) | ⬜ | B | 2026-10-09 盤點新增:最大座標關節庫(滑軌 / 角度限制 / 馬達 / 彈簧)、D6 可設定關節、萬向節、平面關節、螺旋關節、齒輪 / 齒條 / 滑輪約束、目標跟隨(mouse)關節、路徑約束、關節摩擦 / 阻尼 / armature、指定體對不碰撞(collideConnected) |
| 17.48 | [剛體逐體參數與施力 API](#1748-剛體逐體參數與施力-api--wave-a) | ⬜ | A | 2026-10-09 盤點新增:阻尼 / 速度上限、逐軸自由度鎖、力 / 力矩累加器、支配群組、滾動 / 扭轉摩擦、異向摩擦 |
| 17.49 | [接觸 / 關節力回報與衝擊事件](#1749-接觸--關節力回報與衝擊事件--wave-a) | ⬜ | A | 2026-10-09 盤點新增:接觸衝量與關節反力讀回(剛體)、接觸回報內容(碰撞)、帶衝量的衝擊事件與表面型別(gameplay) |
| 17.50 | [接觸模型與求解器變體](#1750-接觸模型與求解器變體--wave-b) | ⬜ | B | 2026-10-09 盤點新增:柔順接觸律、hydroelastic 壓力場接觸、IPC 系保證無穿透(剛體與連續體各記一筆,計為 1 筆)、AVBD 剛體解算器、primal-dual 內點法、質量分割 / 衝擊傳播 |

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
- **17.29**([紀錄](ROADMAP_HISTORY.md#1729-通用可斷裂關節--wave-b)):斷裂閾值寫入快照(17.32 車輛與 17.5 FractureSet 的待辦也以「同 17.29」引用此缺口;physics/serialize.mojo、state_io.mojo 目前無相關欄位)
- **17.29**([紀錄](ROADMAP_HISTORY.md#1729-通用可斷裂關節--wave-b)):島平行路徑內取樣(現在有閾值時島平行路徑退回串行)
- **17.31**([紀錄](ROADMAP_HISTORY.md#1731-物理-lod--模擬預算調度--wave-b)):凍結狀態(BodySet.frozen_motion)寫入快照(physics/serialize.mojo、state_io.mojo 目前無此欄位)
- **17.31**([紀錄](ROADMAP_HISTORY.md#1731-物理-lod--模擬預算調度--wave-b)):逐 island 的品質分級(目前 iters / substeps 是全域)

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

> **狀態**:🔶 部分完成(Wave B 持續工項;F22 第一批 ✅ 2026-09-29;壓力測試案例與滾動球錨點缺陷尚未處理)
> **現況**:穩定堆疊只驗到 6 箱塔(`tests/test_softstep6.mojo`);大 island / 高質量比 / 接觸密集堆疊未系統測試(17.17 的 `tests/test_gpu_contact.mojo` 有 10:1 質量比與 400 箱場,但那是 GPU/CPU parity,不是穩定性壓力測試)。
> **缺口**:高質量比(1:1000)、長鏈受載、單 island 數千體、接觸密集堆疊(碎石 / 骨牌)、warm-start 接觸點 feature-ID 穩定性、contact reduction。
> **對照組**:Jolt(Horizon FW 實戰)、Box2D v3 Soft Step、TGS Soft、AVBD 堆疊 demo。
> **優勢區**:中 —— sub-stepped soft(2.1)+ 著色平行(6.11)+ 變分積分子(4.1b)已是對的地基;缺的是壓力測試 + 調參。
> **規模軸**:body / contact 數 vs 穿透 / 發散;iters vs 殘差(已有量測設計:對齊睡眠)。
> **seam?**:否,不新增 seam —— 對既有 solver6 補極端案例覆蓋(定律 v3 §4)+ 擴大 `bench_solver_scale` / `bench_islands` 的規模軸。
> **交付**:普通(現有)/ 整合(高質量比 + island sleep + CCD 同場景)/ 極端(1:1e4 質量比、1e4 體單 island、瞬移入堆、零質量、退化接觸)。
>
> **發現(2026-09-29,`test_diffsolver`)—— 未修**:球在地面滑行後於 t = 2v0/(7μg) 正確進入 5/7·v0 的滾動,但之後持續減速(v0=3、μ=0.5:1.5 s 時 1.80、4 s 時 1.57),ω·r 高於 vx,並下沉約 7 mm。`ContactScene6` 與可微解算器逐幀一致,所以問題在正式解算器本身:body-frame 接觸錨點隨滾動的球旋轉,摩擦與分離量取在偏離真實接觸點的位置。修法候選:圓形 shape 每子步重新投影錨點到接觸點,或摩擦改在 manifold 點求相對速度。
>
> **進度 F22 第一批 ✅(2026-09-29)**:`islands.refresh_islands` 的整島喚醒與 `update_sleep` 的整島入睡改為兩趟 O(n)(先標 label 再套用);warm-start 比對改為每幀建一次 `(a,b,feat)` → 首位索引的 `Dict`(`contact6.cache_index`,從第一個鍵相符處續掃,保留原本「第一個相符」規則)。身分閘門 148/148 golden 逐節相同。`bench_gpu_contact`(寬相開):N=4096 CPU 簿記 82 → 20.6 ms/幀、GPU 整幀 84.5 → 23 ms、CPU 串行整幀 152 → 82 ms;N=1024 簿記 6.8 → 2.2 ms。
>
> **待辦**:
> - 簿記仍略超線性(N ×4 → ×9),剩餘熱點待量:著色重排 O(色數 × 對數)、每幀重建 BVH、CCD 全對。
> - 修正上述滾動球錨點缺陷。
> - 缺口所列的壓力測試案例,以及整合 / 極端交付。
>
> **歷史**:
> - 量測(2026-09-29,`bench_gpu_contact`,F22 修正前):寬相開啟後,N=4096 箱每幀 CPU 收集 + 簿記(不含求解)達 82 ms,N 每 ×4 成長約 ×12 —— `refresh_islands` 與 `update_sleep` 的 island 喚醒 / 入睡迴圈為 O(n²),warm-start 對快取的線性比對為 O(pairs × cache)(審計 F22)。這是 GPU 與 CPU 路徑共同的瓶頸,因此排為本項第一個工作(已由上面的 F22 第一批處理)。

#### 17.44 複合形狀、共享形狀實例與質量性質 — Wave B

> **緣起**:2026-10-09 負空間盤點,合併 4 筆:複合形狀 / 子形狀局部位姿、共享形狀實例、非均勻縮放形狀、依密度算質量與完整慣量張量。
> **現況**:一個剛體只有一個形狀。`collision/collider_set.mojo:12-13`(collider `i` 就是
> body `i`)、`:37-42`(每格一種 `SHAPE_*`),沒有子形狀與子形狀局部位姿。凹物件目前的
> 唯一做法是 17.5 的「每個凸零件一個 hull 剛體 + `JOINT_WELD`」(`bond_overlapping`,
> `physics/fracture.mojo:305`;焊接兩體互不碰撞,`physics/solver6.mojo:720-730`),
> N 個零件 = N 個 body、N 個 island 節點、至少 N−1 條焊接約束。
> 形狀資料逐體複製:`ColliderSet.add_hull` 每次 `hulls.append`(`collider_set.mojo:214-215`),
> trimesh / heightfield 同(`:233-235`、`:248-250`);快照也逐體寫幾何
> (`physics/solver6.mojo:1465-1493`)。`HullShape.v`(`collision/hull.mojo:78`,body
> 局部座標)與 `TriMesh.v`(`collision/trimesh.mojo:117`,世界座標)直接存頂點,沒有縮放
> 欄位;`ecs/motor_transform.mojo:10` 與 `docs/CATEGORY.md:422-423` 明言 motor 不表達縮放。
> 質量性質:`Inertia3` 只有質量 + 三個主軸慣量(`physics/rigid6.mojo:45-52`),
> `ContactScene6.add_hull` 收呼叫端建好的 body,慣量由呼叫端給(`physics/solver6.mojo:324-335`);
> 唯一的「密度 → 質量」路徑是 `physics/fracture.mojo:177-184`,用的
> `Polytope.inertia_diag` 丟掉慣量積(`geometry/polytope.mojo:168-171`「TODO rotate to
> the principal frame」)。grep `compound|child_shape|sub_shape|shape_count`、
> `ScaledShape|mesh_scale|set_scale`、`refcount|shared_shape|ArcPointer` 於引擎套件無相關
> 命中(`compound` 只命中 `geometry/polytope.mojo:373` 與 `scheduler/gameloop.mojo:57` 的
> 英文動詞),docs 內 `compound|ScaledShape|refcount|shared.?shape|sub.?shape` 零命中;
> `eigen|svd` 於引擎套件零命中,`jacobi` 只命中 Jacobian 與 Jacobi 迭代(沒有 3×3 對稱
> 特徵分解)。
> 已登記未排程:17.5「決定」(碎片慣量只取張量對角,`TODO` 轉主軸)與「待辦」
> (慣量轉主軸);Phase 17 建議順序 2026-10-09 修訂「本輪遺留待辦」(17.5 —— 碎片慣量只取對角)。
> **缺口**:
> - **複合形狀**:一個 body 擁有 K 個子形狀(box / sphere / capsule / hull),各帶局部
>   位姿與材質,共用一份質量 / 慣量、一個 island 節點、一組睡眠狀態;接觸子鍵從三角形
>   索引(`feat`)推廣到子形狀索引,17.13 查詢回報命中的子形狀。例:椅子 = 4 支 box 腳
>   加座面 hull;木箱 + 把手;17.5 凹體分解的零件直接成為同一剛體的子形狀。
> - **共享形狀實例**:不可變的 hull / mesh / heightfield 放進形狀表,多個 body 以 id 引用,
>   不再逐體複製頂點;快照寫一次形狀表 + 每體 id。例:5,000 塊同形 17.5 碎屑共用一個
>   `HullShape`;同一棵樹的碰撞網格擺 300 次。
> - **非均勻縮放實例**:形狀引用帶 (sx, sy, sz),hull 支撐函數 / 面法向、mesh 頂點在
>   查詢時套縮放,不重建幾何。例:同一個岩石資產以 (2, 1, 3) 擺放。
> - **由形狀 + 密度算質量性質**:hull / 閉合網格 / 原生形狀的質量、質心與完整 3×3 慣量
>   張量,以對稱特徵分解轉主軸,主軸旋轉寫進形狀對 body 的局部位姿;複合形狀以平行軸
>   定理合併;`add_*` 提供 by-density 入口。例:不規則岩石或破碎碎片按真實主軸翻滾,
>   呼叫端不必手算 `Inertia3`。
> **對照組**:Jolt `StaticCompoundShape` / `MutableCompoundShape` / `ScaledShape` /
> `RefConst<Shape>` / `MassProperties::DecomposePrincipalMomentsOfInertia`;PhysX 每 actor
> 多個 `PxShape`、`PxMeshScale`、`PxRigidBodyExt::updateMassAndInertia`;Bullet
> `btCompoundShape`;Rapier `SharedShape` + `ColliderBuilder::density`;Box2D v3 每 body
> 多 shape;MuJoCo 每 body 多 geom;Unity / Godot 子 collider。**本庫內部對照**:17.5 的
> N 個 hull 剛體 + 焊接(seam 的另一端)。
> **優勢區**:中 —— 子形狀局部位姿是 PGA motor,子形狀世界位姿是一次 motor 合成(與
> `ecs/motor_transform` 同機件),主軸旋轉也以 motor 存,不另存 3×3;縮放不是剛體變換,
> 所以只放在形狀引用側、不進 body 位姿,維持 motor 路徑不變。慣量合併可重用同套件的
> 緊湊空間慣量 `SpInertia`(`physics/chain.mojo:57-86` 平行軸、`:169-171` 相加)。
> 複合 vs 焊接 N 體:前者至少少 N−1 條約束、少 N−1 個 island 節點,剛度不受迭代數限制;
> 理論優勢區 = 每物件子形狀多 × 場景中凹物件多。共享 / 縮放 / 質量性質屬純工程。
> **規模軸**:每 body 子形狀數 K × 凹物件數(複合 vs 焊接的每步成本、island 數);共享
> 實例數 × 每形狀頂點數(記憶體、快照大小、`add_*` 時間);縮放實例 vs 預先烘焙縮放
> 頂點的窄相 ns/pair。
> **seam?**:是 ——(1)凹物件表示:複合單一剛體 vs 17.5 的 N hull 剛體 + 焊接 → parity:
> 同一凹體落地 / 受撞後質心軌跡與靜置姿態在容差內一致,總質量與換到同一參考點的總慣量
> 逐項在容差內相同;bench row:K = 2…64 的每步成本。(2)形狀儲存:共享 id vs 逐體複製 → 接觸與
> 步進**逐位相同** + 記憶體 / 快照大小 row。(3)縮放:執行期縮放 vs 預先烘焙縮放頂點 →
> 接觸在容差內一致 + ns/pair row。質量性質對 `Inertia3.box` / `sphere` / `capsule` 解析值
> 驗證,不另立 seam。CATEGORY §2 補兩列。
> **交付**:普通(椅子複合體落地靜置、四腳皆有接觸;旋轉 30° 擺放的長盒 hull 依密度算出
> 的主軸慣量等於 `Inertia3.box` 解析值、主軸方向等於擺放旋轉;1,000 塊共享 hull 的碎屑只
> 存一份頂點)/ 整合(17.5 凹體分解改產生複合體,`test_fracture` 的牆與凹板場景照常入睡;
> 複合體走寬相、睡眠、島平行,6.10 快照來回逐位相同;17.13 射線回報子形狀索引;子形狀
> 各自材質(17.23))/ 極端(K = 1 且局部位姿為恆等時與單一形狀逐位相同、子形狀完全重疊、
> 零體積子形狀、縮放含 0 或負值(API 端 raise)、極扁縮放 (100, 1, 0.01)、三主軸相等
> (特徵分解退化)、質心落在所有子形狀之外、共享形狀被一個 body 移除後其他引用者不受影響)。
> **相依**:8.1(hull)、17.0e(`ColliderSet`)、17.5(凹體分解零件、碎片慣量待辦;未斷裂
> 的凹物件可改用複合體,斷裂時拆出子形狀)、17.13(查詢走子形狀)、17.23(其缺口原文已列
> per-shape 摩擦)、6.10 / 17.40(快照與存檔改存形狀表)、17.49(接觸回報帶子形狀索引)、
> 17.52(動態凹網格的另一條路);共享形狀 id 可作 17.12 場景 / prefab 引用碰撞資產的落點
> (17.12 本輪不排)。

#### 17.47 最大座標關節庫補完 — Wave B

> **緣起**:2026-10-09 負空間盤點,合併 10 筆:最大座標關節庫(滑軌 / 角度限制 / 馬達 / 彈簧)、D6 可設定關節、萬向節、平面關節、螺旋關節、齒輪 / 齒條 / 滑輪約束、目標跟隨(mouse)關節、路徑約束、關節摩擦 / 阻尼 / armature、指定體對不碰撞(collideConnected)。
> **現況**:9.1 原標 ✅,但 `Joint6` 的上下限 / 馬達 / 彈簧 / 滑軌 / cone-twist 沒有交付
> (見 9.1 狀態校正:最大座標部分移到本條,縮座標多自由度關節移到 17.51)。
> `physics/joints6.mojo:14-18` 只有 `JOINT_BALL` / `DISTANCE` / `HINGE` /
> `BROKEN` / `WELD`;`Joint6` 欄位(`:27-36`)只有錨點、rest、兩軸與累積衝量,沒有上下限、
> 馬達、彈簧欄位,docstring 明言「no cone clamp」(`:23-25`)。`joint_axis`(`:82-126`)是
> 純等式的純量軸解,沒有單邊夾限。`AngularDrive`(`:279-298`)是姿態驅動 + `max_torque`,
> 不是速度馬達,也沒有線性版;`ContactScene6.move_to` 直接設速度、無力上限
> (`physics/solver6.mojo:529-550`)。上下限與滑軌只在縮座標(`physics/chain.mojo:96-97`、
> `:108-109`、`:130-139`)。乾摩擦列 `CON_FRICTION_LOSS`(`physics/constraints.mojo:40`、
> `:101`)所在的 `ConstraintSet` 只被 `tests/test_constraints.mojo` 與
> `benchmarks/bench_constraints.mojo` import(`add_friction_loss` 只有該測試呼叫),沒有
> 模擬路徑使用;黏滯阻尼只能在縮座標以 `Actuator.gain_qd` 湊(`physics/actuator.mojo:20-21`、
> `:41`)。兩體耦合只有縮座標鏈內的 `FixedTendon`(`physics/tendon.mojo:64-91`)。
> `geometry/spline.mojo` 有 `closest_point`(`:378`)與 `frame_at_distance`(`:485`),但
> physics / gameplay / collision 零 importer。關節兩體互不碰撞只對 weld 成立
> (`physics/solver6.mojo:720-730`);繩索的靜態錨體以 `set_filter(a, 0, 0)` 整體關閉碰撞
> (`physics/rope.mojo:116`);`gameplay/ragdoll.mojo:83-89` 的骨骼球關節不設過濾(該檔無
> `set_filter`),相鄰骨骼只能靠幾何間隙避開。關節快照格式固定
> (`physics/solver6.mojo:1494-1506`)。grep `\bD6\b`(大小寫敏感)、`configurable`、
> `universal|cardan|hooke`、`helical|screw_joint|JOINT_SCREW`、`pulley`、
> `mouse|grab|LinearDrive|position_drive`、`armature`、
> `collide_connected|ignore_pair|disable_collision` 於引擎套件零命中;`six.?dof` 只命中
> `physics/rigid6.mojo:1` 的六自由度剛體說明;`\bplanar` 只命中幾何判定(`geometry/epa.mojo:278`)
> 與 `gameplay/vehicle_wheel.mojo:11-22` 的路面。
> 已登記:17.2「進度」待辦「關節角度限制(膝單向)」、17.3「進度」待辦「關節角度限制(膝只能單向、
> 肩錐)」、17.41「進度」待辦「關節為雙向(無鬆弛)」。
> **缺口**:
> - **9.1 剩餘(在 `Joint6` 上)**:hinge 角度上下限、滑軌(prismatic)+ 上下限、
>   swing-twist / cone 限制、速度馬達(目標速度 + 力 / 力矩上限)、彈簧(hertz / zeta
>   軟化,距離軸與角度軸皆可)、距離關節的單邊上限(繩索鬆弛)。例:膝只能單向彎、門停在
>   90°、活塞與電梯滑軌、ragdoll 肩的錐限制、馬達驅動的吊橋。
> - **D6 可設定關節**:六軸各自 free / limited / locked,外加線性與角度 drive;ball / hinge /
>   slider / weld 與下列 universal / planar 都是它的預設組態。例:武器架只放開 yaw;座椅
>   懸吊只有軟性 Y 向 drive。
> - **universal(萬向節)**:兩條正交 hinge 軸。例:傳動軸 U 型接頭、轉向柱。
> - **planar**:平面內平移 + 繞法向旋轉,作為兩體間的約束(與 17.48 逐體 DOF 鎖的差別:
>   可接在移動的平台上)。例:空氣曲棍球的球餅、桌面上滑動的機關。
> - **helical(螺旋)**:沿一軸的旋轉與平移以 pitch 耦合。例:絲槓、旋開的瓶蓋、螺栓。
> - **gear / rack-and-pinion / pulley**:兩 hinge 間的齒比、hinge 對滑軌的齒條、兩體間繩長
>   守恆的滑輪(可帶比例)。例:時鐘齒輪組、齒條轉向、電梯配重。
> - **目標跟隨(mouse)關節**:把 body 上一點以軟彈簧 + 力上限拉向移動的世界目標點,body
>   照常碰撞(`AngularDrive` 的線性對應)。例:拖曳木箱、重力槍。
> - **路徑約束**:錨點沿樣條滑動,可選方向對齊與沿路徑馬達。例:雲霄飛車車廂、沿彎軌
>   滑動的門。
> - **關節摩擦 / 黏滯阻尼 / armature**:`Joint6` 各軸乾摩擦與黏滯阻尼;把既有
>   `CON_FRICTION_LOSS` 接上模擬路徑;縮座標 `Chain` 加 armature(反射轉子慣量加在 H
>   對角)與隱式被動阻尼。例:門自己擺到靜止;重載絞盤在大 dt 下仍穩定。
> - **關節相連體不碰撞 / 指定體對不碰撞**:每條關節一個 `collide_connected` 旗標(取代
>   只認 weld 的 `weld_keys`),外加顯式忽略體對表,不佔 category bit。例:50 個 ragdoll
>   的相鄰骨骼;門與門框。
> **對照組**:Jolt `HingeConstraint` / `SliderConstraint` / `SwingTwistConstraint` /
> `SixDOFConstraint` / `GearConstraint` / `RackAndPinionConstraint` / `PulleyConstraint` /
> `PathConstraint`(+ `MotorSettings` / `SpringSettings`)與 `GroupFilterTable`;PhysX
> `PxRevoluteJoint` / `PxPrismaticJoint` / `PxSphericalJoint` / `PxD6Joint` / `PxGearJoint` /
> `PxRackAndPinionJoint`;Box2D v3 revolute / prismatic / wheel / mouse / motor joint 與
> `collideConnected`;Bullet `btConeTwistConstraint` / `btUniversalConstraint` /
> `btGearConstraint`;Unity `ConfigurableJoint` / `CharacterJoint` /
> `Physics.IgnoreCollision`;UE `PhysicsHandleComponent`;MuJoCo joint `damping` /
> `frictionloss` / `armature`;Drake `UniversalJoint` / `PlanarJoint` / `ScrewJoint`。本庫
> 內部對照:縮座標 `chain.mojo` 的 revolute / prismatic + 上下限(`docs/CATEGORY.md:124`
> 運動子空間 + 關節極限列)。
> **優勢區**:中 —— 關節軸是 PGA 直線、兩體相對位姿是 motor:相對 motor 取 log 得到 6 個
> bivector 分量,可當 D6 六軸誤差的統一參數化(小角度時與「錨點位移 + 三軸角」一致),
> 各關節型別只是選哪幾軸受約束;swing-twist 分解是 rotor 的因式分解;helical 關節就是
> 固定 pitch 的 screw(`physics/screw.mojo:10-12`:常數速度 bivector 走出精確螺旋線),
> 在本庫是既有的 screw 生成元,不是特例。gear / pulley / 路徑約束都是新增一條純量約束列,與既有
> soft substep 軸解同形,不需新求解器。17.20 可微化後,drive / 彈簧 / 阻尼參數可用梯度調。
> **規模軸**:關節數 × 種類 × 子步 / 迭代;串接馬達數(收斂);跨關節質量比(接 17.19);
> ragdoll 數 × 忽略體對數(過濾查表成本)。
> **seam?**:是 ——(1)D6 預設組態 vs 專用關節型別:ball / hinge / weld(及新增的 slider /
> universal / planar)以 D6 表達時軌跡在容差內一致(列序相同時逐位相同)+ bench row「D6
> 通用性成本」;(2)最大座標 vs 縮座標:hinge 上下限 + 速度馬達在 `Joint6` 與 `Chain`
> (上下限 + `Actuator` 速度伺服)上的擋停角、穩態速度一致(擴充 `docs/CATEGORY.md:120`
> 「關節鏈:縮座標 CRBA+RNEA vs O(n) ABA vs 極大座標 solver6」列);(3)關節相連不
> 碰撞:旗標 vs 以 category 遮罩手動繞過 → 接觸集合逐位相同。馬達力矩上限 0 / 彈簧關閉
> 時與沒有此功能逐位相同(同 17.2 `AngularDrive`「零上限驅動與無驅動逐位相同」)。bench:
> 9.1 原定的「關節種類 × 迭代」列。
> **交付**:新測試 `test_joints_ext`(9.1 原定名稱)。普通(上限擋停於解析角、馬達在力矩
> 上限內達到目標速度、彈簧頻率對上 hertz、螺旋關節轉一圈前進一個 pitch、齒比下
> ω_b = −r·ω_a、滑輪繩長守恆、目標跟隨在力上限內收斂;能量不注入,沿用 9.1 gate)/
> 整合(17.2 ragdoll 加膝單向與肩錐;17.41 繩索改用單邊距離上限而能鬆弛;電梯滑軌 + 配重
> 滑輪與接觸、睡眠、島、17.29 斷裂同場;關節新欄位進 6.10 快照(關節格式升版)後來回
> 逐位相同)/ 極端(lo == hi 鎖死、非法上下限在 API 端 raise、cone 0° 與 180°、力矩上限 ∞、
> 1:1000 質量比的齒輪、universal 90° 奇異、路徑端點與閉合路徑、目標瞬移、50 個 ragdoll 的
> 忽略體對、關節斷裂後兩體恢復碰撞)。
> **相依**:9.1(狀態校正,本條接手最大座標部分)、17.2 / 17.3(角度限制待辦)、17.29
> (斷裂閾值與事件)、17.41(繩索鬆弛待辦)、17.36(路徑約束用其樣條與 `frame_at_distance`)、
> 13.4 / 13.5(縮座標側的耦合與 friction-loss 列)、17.48(逐軸 DOF 鎖,與 planar 關節分工)、
> 17.49(關節反力回報)、17.51(縮座標多自由度關節;armature 共用 H 組裝)、17.53(查詢側
> 忽略清單,與本條的碰撞側忽略體對分開)、6.10(快照格式)、17.20(可微)。
> **邊界**:目標跟隨關節只收世界座標目標點;游標 / 手把輸入與螢幕射線換算屬宿主(輸入
> 裝置不在本 repo)。drive 目標可由任何外部控制器每步寫入;核心不含學習式控制器。

#### 17.48 剛體逐體參數與施力 API — Wave A

> **緣起**:2026-10-09 負空間盤點,合併 6 筆:阻尼 / 速度上限、逐軸自由度鎖、力 / 力矩累加器、支配群組、滾動 / 扭轉摩擦、異向摩擦。
> **現況**:逐 body 參數集中在 `physics/body_set.mojo:93-120`(motion、sleeping、
> restitution、can_sleep、friction 與兩個組合模式、17.27 的 `grav_on` / `grav`、17.31 的
> `frozen_motion`);公開的逐 body 操作(`physics/solver6.mojo:455-616`:`set_filter` /
> `set_sensor` / 四個材質 setter / `set_kinematic` / `set_velocity` / `move_to` /
> `freeze` / `unfreeze` / `wake` / `set_can_sleep` / `teleport`)沒有阻尼、速度上限、
> 軸鎖或施力入口。grep `linear_damp|angular_damp|max_lin|max_ang`、
> `lock_rot|lock_axis|allowed_dof|freeze_rot`、`add_force|add_torque|force_acc|ForceMode`、
> `dominance|inv_mass_scale` 於 `physics/`、`collision/`、`gameplay/` 全部零命中。
> - 外力:子步內已有施力點 —— `ContactScene6.step`(`step_soft` 轉發至此)每子步
>   呼叫 `integrate_force(h, f, Vec3(0, 0, 0, 0))`(`physics/solver6.mojo:1308-1311`;
>   島平行路徑 `physics/solver6.mojo:881-884` 同形式),但只傳重力,力矩恆為零。呼叫端只能在步前直接對
>   `sc.bset.bodies[i]` 施衝量(`physics/fields.mojo:174`、`gameplay/vehicle.mojo:727-728`)。
>   17.27 已量到幀首衝量每幀留下 g·dt²/2 的漂移(1 秒 6 cm),重力區因此改走每子步的
>   `BodySet.grav`(`physics/body_set.mojo:113-115,299-303`);這個掛鉤只表達質心上的
>   常力,不能施力矩或偏心力。
> - 阻尼只有區域型:`FIELD_DRAG`(`physics/fields.mojo:40,168-169`,F = −k·m·v,僅線性,
>   且以幀首衝量施加)與 17.28 水體積;沒有逐 body 阻尼,也沒有速度上限。
> - 軸鎖:`tests/test_softstep6.mojo:31` 以 `Inertia3(2, 1e12, 1e12, 1e12)` 假造「凍結
>   旋轉」,沒有平移鎖;`freeze`(`physics/solver6.mojo:552`,17.31)凍結整個 body。
>   kinematic 角色控制器(17.1)不需要軸鎖,動態剛體角色需要。
> - 支配:17.26 `ContactRule` 只有 ONE_WAY / CONVEYOR / FRICTION
>   (`physics/contact6.mojo:541-543`)。「推得動別人、自己不被推」目前只有 kinematic
>   (17.24)做得到,而 kinematic 不受重力、不受碰撞衝量。
> - 摩擦模型:每接觸點兩個切向列,方向取任意的 `tangent_basis(n)`,上限 `pair_mu·λn`
>   (`physics/contact6.mojo:394-395`);`physics/material.mojo:26-50` 只組合純量 μ。沒有
>   材質方向、滾動阻力或繞法向的扭轉摩擦。唯一的滾動阻力是載具輪胎 Crr
>   (`gameplay/vehicle.mojo:166,657`,作用在輪轉矩,不是接觸模型);
>   `physics/constraints.mojo:22-30,67` 的 "anisotropy" 是金字塔錐方向誤差的量測,
>   不是異向摩擦。
> **缺口**:
> - **逐 body 線性 / 角阻尼 + 線 / 角速度上限**:每子步套用,隱式形式 v/(1+c·h)
>   (17.28 浮體阻尼 `physics/fields.mojo:276-277` 已用同一形式,但以整幀 dt 施加)。
>   例:氣球線性阻尼高、緩慢飄落;爆炸碎片角速度夾在上限內,避免單步轉過頭穿透或發散。
> - **逐軸自由度鎖**(平移 3 軸 × 旋轉 3 軸):等價於該軸的逆質量 / 逆慣量為 0,作用在
>   `Body6` 的 `inv_mass` / `apply_impulse` / `angular_factor` / `apply_angular_impulse`
>   (`physics/rigid6.mojo:120-130`)。例:2.5D 橫向捲軸的箱子只在 XY 平面移動、只繞 Z
>   轉;動態剛體角色鎖兩個旋轉軸保持直立。測試裡的 1e12 慣量 hack 可改用正式 API。
> - **力 / 力矩累加器 + 施力模式**:force / impulse / velocity change / acceleration
>   (PhysX `PxForceMode` 的四種),可施於質心或世界點(換算成力 + 力矩),步內每子步套用、
>   步末清零。例:太空船推進器的持續推力、帆受風的偏心力。17.27 的風 / 徑向場與 17.4 載具
>   輪力改走同一路徑,消掉幀首衝量的離散誤差。
> - **支配群組 / 逐接觸逆質量縮放**:作為 `ContactRule` 的第四種規則(逐對 inverse mass /
>   inertia scale)。例:玩家推箱子但不被箱子推回、Boss 不被碎石推動。
> - **滾動阻力與扭轉(自旋)摩擦**:接觸點加反向力矩列,上限 ∝ λn。例:草地上的球滾一段
>   後停下、地上自轉的硬幣逐漸停轉。
> - **異向摩擦**:材質局部座標中的主摩擦軸取代任意 `tangent_basis`,兩軸各自的 μ。
>   例:滑雪板順向滑、橫向抓地;履帶;拉絲金屬板。
> **對照組**:PhysX `setLinearDamping` / `setMaxAngularVelocity` / `PxRigidDynamicLockFlag` /
> `addForce(PxForceMode)` / dominance groups + `PxContactModifyPair` 逆質量縮放 / torsional
> patch friction;Jolt `mLinearDamping` / `mMaxAngularVelocity` / `EAllowedDOFs` /
> `AddForce`;Unity `drag` / `constraints` / `ForceMode`;Godot `linear_damp` /
> `axis_lock`;Rapier dominance groups / `LockedAxes`;Box2D v3 `rollingResistance`;
> Bullet `rollingFriction` / `spinningFriction` / anisotropic friction;MuJoCo condim 4 / 6。
> **本庫內部對照**:幀首衝量(`fields.mojo` / `vehicle.mojo` 現行做法)。
> **優勢區**:低 —— 多數是 table stakes。兩點差異:(1)17.20 可微子集可對阻尼、滾阻係數
> 求梯度做系統辨識(`examples/22_diffsolver_sysid.mojo` 已由觀測反推 μ,同一手法);
> (2)軸鎖在 `QuatBody6` / `ScrewBody6` 兩個表示函子上同一定義,parity 沿用
> `test_rigid6` 的 by-action 比較。
> **規模軸**:body 數 × 啟用參數的比例(未啟用時固定成本須為零);累加器每子步的額外
> 加法;滾阻 / 扭轉 / 異向列使每接觸點的列數由 3 增為 4–6 的成本。
> **seam?**:是(兩列)——(1)外力施加時機:幀首衝量 vs 子步累加器 → parity(零力時
> 逐位相同;常力自由體對解析拋物線,子步路徑誤差隨 dt → 0 收斂,幀首路徑每幀留
> F·dt²/(2m),與 17.27 量到的偏差同源)+ bench row(累加器開 / 關)。(2)摩擦模型:
> 等向 Coulomb vs 異向 + 滾動 / 扭轉 → parity(兩軸 μ 相等、滾阻與扭轉係數為 0 時與現行
> 逐位相同)+ bench row。阻尼、速度上限、軸鎖、支配是既有路徑的參數,不另立 seam,
> 以「預設值逐位不變」為閘門(同 17.23 / 17.24 的恆等閘門,golden 各段不動)。
> **交付**:普通(阻尼下落的終端速度對解析 g/c;硬幣停轉時間對解析;2.5D 箱只在 XY 平面;
> 推進器加速度 = F/m)/ 整合(新欄位入快照、`_VERSION` 升版後續跑逐位相同;島平行與
> 著色路徑結果一致;17.27 風場改走累加器後 `test_fields` 的解析案例誤差下降;動態角色經
> 支配規則推箱不被推回;GPU 解算器遇未支援參數 raise)/ 極端(阻尼 1e6、速度上限 0、
> 六軸全鎖的動態體受撞不動且有限、支配雙方同群組 == 一般接觸逐位、滾阻係數遠大於 μ 時
> 不反轉角速度、負值或 NaN 參數在 API 邊界 raise)。新測試 test_body_params。
> **相依**:17.19 發現(滾動球錯誤減速)須先修,否則滾阻量測分不出 bug 與模型;17.23
> (材質承載異向方向與滾阻係數)、17.24、17.26(`ContactRule` 擴充)、17.27 / 17.28 /
> 17.4(改走累加器)、17.20(可微參數)、17.67(動態剛體角色:軸鎖 + 支配)、12.1(宿主施力
> API)。

#### 17.49 接觸 / 關節力回報與衝擊事件 — Wave A

> **緣起**:2026-10-09 負空間盤點,合併 3 筆:接觸衝量與關節反力讀回(剛體)、接觸回報內容(碰撞)、帶衝量的衝擊事件與表面型別(gameplay)。
> **現況**:
> - 事件只有集合差分:`collision/contact_events.mojo:19-31` `ContactEvent` =
>   `a, b, feat, kind`,模組 docstring(`collision/contact_events.mojo:1-11`)寫明是純集合邏輯、不含衝量;9.4 以
>   `(a, b, feat)` 為鍵。`gameplay/runtime.mojo:84,196-197` 把它轉進
>   `scheduler.events.Channel`(17.38)。
> - 原始資料存在,但沒有 API:步末 `self.cache = pairs`(`physics/solver6.mojo:1368`)保留每個
>   `ContactConstraint`(`physics/contact6.mojo:31-61`)的 manifold 點與法向、逐點累積衝量
>   `acc` / `acc_t1` / `acc_t2`、接近速度 `vn0`、恢復係數衝量 `racc`。`cache` 是公開欄位
>   (`physics/solver6.mojo:139`;`tests/test_error_wiring.mojo:401-402` 直接讀它),但語意
>   (最後一個子步的累積衝量,不是整步總和)沒有文件化,次序也隨路徑而異(島平行路徑存的
>   是依島重排的 `pairs2`,`physics/solver6.mojo:1281`)。
> - 關節:`Joint6.acc` / `acc_ang`(`physics/joints6.mojo:35-36`)同樣是最後子步的值;逐子步
>   峰值 `peak_force` / `peak_torque`(`physics/solver6.mojo:147-148`)只在設了斷裂閾值時
>   取樣(`physics/solver6.mojo:1353-1354`),且一設閾值島平行路徑就退回串行(`physics/solver6.mojo:1244`)。
>   `tests/test_joint_break.mojo:57` 直接讀 `joints[jh].acc / h` 當負載估計,17.29 已量到
>   這種讀法漏掉衝擊(`docs/CATEGORY.md:344`「關節負載估計」列)。
> - grep `ContactListener|contact_report|surface_id|surface_type` 於 `physics/`、
>   `collision/`、`gameplay/` 零命中;grep `damage|impact|vn0|\.acc\[` 於
>   `gameplay/*.mojo`、`physics/fracture.mojo` 零命中(gameplay 與破碎模組都不讀衝量);
>   `physics/material.mojo:26-50` 只有組合模式,沒有表面型別 id。縮座標側 `read_touch`
>   (`physics/sensors.mojo:125-132`)讀的是穿透深度,不是力。
> **缺口**:
> - **接觸回報**:每個接觸對公開 manifold 點、法向、整步法向 / 切向衝量總和(各子步 +
>   恢復係數 pass)、接近速度、兩側表面型別 id;依 `(a, b, feat)` 排序輸出,與 9.4 事件流
>   同序。型別放 `physics`(第 4 層):`collision` 不得引用 physics,`ContactEvent` 維持純
>   集合。例:箱子 8 m/s 撞地與 0.5 m/s 撞地,宿主拿到不同衝量、播不同音量。
> - **衝擊事件(hit event)**:接近速度或衝量超過閾值才發出(Box2D v3 hit event 的做法),
>   帶最大衝量的接觸點與表面型別對;容量有上限,溢出時丟最新一筆並計入 `diag.counters`
>   (`docs/ARCHITECTURE.md` §2 的 Capacity / budget overflow 列)。例:車撞牆算傷害、
>   木箱落地揚塵。
> - **關節反力讀回**:每個 `Joint6` 每步的反力 / 反力矩,提供整步平均與子步峰值兩種讀數
>   (沿用 17.29 的取樣定義),不需先設斷裂閾值;同時完成 17.29 待辦「島平行路徑內取樣」。
>   例:吊橋鏈節的張力、壓力板讀出上面箱子的重量、拖車掛鉤的負載。
> - **表面型別 id**:逐 body 一個整數 id(與 17.23 材質一起放在 `BodySet`);逐三角形 /
>   高度場格的 id 屬 17.45。例:同一木箱打在混凝土與金屬上,宿主依 id 對查不同音效與貼花。
> **對照組**:Box2D v3 `b2ContactHitEvent`(approachSpeed、point);PhysX
> `PxContactPairPoint` 衝量 + contact report 閾值 + `PxConstraint::getForce`;Jolt
> `ContactListener::OnContactAdded`(manifold)+ `GetTotalLambda*`;Bullet
> `getAppliedImpulse`;Rapier `ContactForceEvent`;Unity `Collision.impulse` /
> `relativeVelocity`;UE `OnComponentHit` 的 `NormalImpulse` + `UPhysicalMaterial`
> SurfaceType;MuJoCo `mj_contactForce`。
> **優勢區**:中 —— 決定論 + 排序正規化。9.4 已證明同場景在不同碰撞 seam 上事件流逐位
> 相同;回報沿用同一排序後,同一段錄製(17.39)重播出的衝擊事件序列逐位相同,可直接當
> QA 回歸資料;對照組中 Jolt 的 `ContactListener` 在多個 job 執行緒上回呼,次序不固定。
> 另:17.20 可微子集裡接觸衝量對參數可導,回報量本身可當 loss(例:以落地衝量峰值反推
> 材質)。
> **規模軸**:每步接觸數 × 回報開 / 關的成本;閾值高低 vs 事件數;事件容量 vs 丟棄數。
> **seam?**:是 —— 負載讀數:最後子步 vs 整步總和 vs 子步峰值(把 `docs/CATEGORY.md:344`
> 的關節列擴到接觸)→ parity(穩態下三者一致:靜置箱的法向衝量總和 = m·g·dt、懸掛質量
> 讀 m·g)+ bench row(回報關 / 開 / 開 + 閾值)。回報關閉時解算路徑逐位不變(身分閘門)。
> **交付**:普通(靜置箱法向力 = m·g;同高度落下的兩箱,質量大者衝量大;閾值以下不發
> hit)/ 整合(經 `gameplay/runtime.mojo` 送進 `Channel`,與 9.4 began 事件同幀對上;17.39
> 回放重現同一 hit 序列;著色 / 島平行 / GPU 解算器回報一致或明確拒絕;吊橋關節張力對
> 解析靜力學)/ 極端(零接觸場景、mesh 上同一 body 對的多三角接觸(feat 不同)、sensor
> 不產生衝量、NaN 隔離的 body 不進回報、容量 1 時溢出計數、被 `ContactRule` 丟掉的接觸
> 不回報、斷裂關節讀數歸零)。新測試 test_contact_report。
> **相依**:9.4(鍵與排序)、17.38(事件匯流排)、17.29(負載取樣定義、島平行待辦)、17.23
> (表面 id 與材質同處)、17.45(逐三角形表面 id)、17.39(回放重現)、12.1(宿主訂閱)、
> 17.70(傷害 / 血量系統是消費端)、17.71(戰鬥物理)、17.80(擷取檔可帶接觸力)。
> **邊界**:音訊播放與粒子 / 貼花屬宿主。核心只提供資料(回報與事件 payload)與訂閱 API
> (17.38 `Channel`,嵌入時經 12.1 的事件訂閱);表面 id 對應哪個聲音或貼花由宿主決定。
> 傷害計算由 17.70 的 gameplay 規則或宿主讀同一事件流。

#### 17.50 接觸模型與求解器變體 — Wave B

> **緣起**:2026-10-09 負空間盤點,合併 6 筆:柔順接觸律、hydroelastic 壓力場接觸、IPC 系保證無穿透(剛體與連續體各記一筆,計為 1 筆)、AVBD 剛體解算器、primal-dual 內點法、質量分割 / 衝擊傳播。
> IPC / AVBD / 內點法原本只列在 `docs/SOTA_GAP_ANALYSIS.md:82-84,87-89,93` 的前沿清單,
> `docs/SOTA_GAP_ANALYSIS.md:106-107` 判「不在射程內」;該判斷的前提是「先補齊角動力學與 sub-stepping」,兩者已在
> Phase 1–2 完成,但沒有編號項接手。AVBD 在 ROADMAP 只出現在 17.17「對照組」與 17.19「對照組」。
> **現況**:
> - 3D 接觸只有一個演算法:Box2D v3 soft step(`physics/contact6.mojo:312` `solve_contact`,
>   投影 Gauss-Seidel + Coulomb 摩擦),軟度是全域 `SolverConfig.hertz` / `zeta`
>   (`physics/solver_config.mojo:54-55`,預設 30 / 10,`physics/solver_config.mojo:71-72`)。既有 seam 都不換演算法:
>   裝置(CPU 著色 vs GPU,`docs/CATEGORY.md` §2.8)與實作(`ContactScene6` vs 可微子集
>   `SphereWorld`,§2.6,同一演算法);舊 2D 的 SI / PBD / XPBD seam 已隨 2D 路徑刪除
>   (17.0「已刪除(2026-09-29,使用者決定)」),17.19「seam?」寫「否新 seam」。
> - `physics/contact6.mojo:381` 的 `mass_scale` 是 soft step 係數 c/(1+c)
>   (`physics/solver6.mojo:1225`),不是質量分割;grep `shock|mass splitting` 於
>   `physics/` 零命中。
> - 柔順接觸只在可微玩具:`physics/diffsim.mojo:9-15`(平滑罰函數地面)與
>   `physics/diffrigid.mojo:82` `rollout_soft`(彈簧-阻尼地面,`docs/CATEGORY.md:157`
>   「可微接觸模型」列)。`ContactScene6` 沒有逐材質剛度,17.26 `ContactRule` 也沒有剛度
>   覆寫;grep `hydroelastic|hunt.?crossley|solref|pressure.?field` 於程式碼與 docs 零命中。
> - VBD 只用在布料(`physics/vbd_cloth.mojo:38` `_vbd_vertex`);grep `AVBD` 於程式碼零命中。
> - 13.5「設計」規劃的 PGS / CG / Newton 解算器 seam 只落地 PGS:
>   `physics/constraints.mojo:124` `solve` 是 projected Gauss-Seidel,grep `newton|\bcg\b`
>   於該檔、`test_constraints`、`bench_constraints` 零命中;grep `primal.?dual` 於
>   `physics/` 零命中。
> - IPC 需要的零件部分在:全域 CG / PCG(15.1;`numerics/sparse.mojo:9-11` 的 docstring 把
>   barrier-based non-penetration 列為用途)、TOI(`collision/toi.mojo:42` `swept_box_toi`,
>   僅盒對盒);grep `barrier|\bipc\b` 於 `physics/` 零命中。
> **缺口**:
> - **(a)逐材質柔順接觸律**:接觸剛度 / 阻尼由全域 hertz / zeta 改為逐材質(MuJoCo
>   solref / solimp 式),另加 Hunt–Crossley 非線性彈簧-阻尼(耗散隨穿透量)。例:橡膠球與
>   鋼球落在同一地板上,彈跳高度與陷入深度不同;泡棉墊讓落下的箱子陷 5 cm 再停住。
> - **(b)hydroelastic 壓力場接觸**:柔順體帶一個由 SDF 導出的壓力場,在兩體重疊區算接觸面
>   與壓力分佈,取代少數接觸點。例:平放在傾斜軟墊上的箱子,接觸由 4 點跳動變成連續壓力
>   面而不抖;車胎壓在軟地面上的接地面積。
> - **(c)AVBD 剛體解算器**:把 VBD 擴到剛體與硬約束(SIGGRAPH 2025),作為 soft step 的
>   替代演算法。例:50 層箱塔、上千塊積木塌落時,在固定迭代預算內維持剛性。
> - **(d)質量分割 / 衝擊傳播**:依接觸層分割質量或由下而上傳播(Tonge mass splitting、
>   Guendelman shock propagation),作為 soft step 的變體。例:1000 kg 巨石壓在 1 kg 木箱堆上,
>   8 次迭代不壓塌。
> - **(e)primal-dual 內點法摩擦接觸**:二次收斂,用於剛性堆疊與高精度參考解。例:工地 / 物流
>   模擬裡的鋼樑堆、變速箱內的零件,PGS 殘差停滯時仍收斂;也當其他變體的 parity oracle。
> - **(f)IPC / ABD 障礙勢接觸**:barrier 能量 + CCD 線搜尋,保證軌跡無穿透;剛體走 ABD
>   (仿射體),布料 / 薄殼 / 硬可變形體走 IPC。例:螺帽轉進螺栓、緊配合的齒輪組;打結的
>   布料、被兩塊板夾住的軟物不穿透。
> **對照組**:Drake hydroelastic + SAP / TAMSI、MuJoCo solref / solimp + convex Newton、
> Simbody Hunt–Crossley、AVBD(Utah,SIGGRAPH 2025)與 VBD(arXiv 2403.06321)、Tonge 等
> mass splitting、Guendelman shock propagation、PhysX / Havok 堆疊啟發式、primal-dual
> interior-point friction(SIGGRAPH 2024)、IPC(Li 2020)/ ABD(arXiv 2201.10022)/ GIPC /
> StiffGIPC(arXiv 2411.06224)、Genesis。**本庫內部對照**:現行 soft step 與 17.19 的
> 壓力場景。
> **優勢區**:中 ——(1)柔順律的接觸力隨穿透連續變化,接觸開關處沒有衝量跳變,接到 17.20
> 時梯度不再只靠 `positive` 的次梯度約定,即把 `docs/CATEGORY.md:157` 的「剛性 vs
> 罰函數」可微接觸列搬到正式解算器;(2)接觸求解已是作用在 `BodySet` 上的自由函式
> (`physics/contact6.mojo:6-13` 自述這是 17.17 / 17.18 / 17.20 換裝用的形狀),新演算法是
> 並列一組函式,不是改寫場景;(3)6.11 著色排程已給出決定論的 Gauss-Seidel,AVBD 需要的
> 逐 body 著色可建在同一基礎上。(e)(f)為低 —— 成本高,價值在精度與無穿透保證。
> **規模軸**:質量比(1:1 → 1:1e4)× 塔高 × 迭代預算 → 穿透 / 殘差 / 是否塌;柔順律剛度跨
> 6 個數量級時的穩定步長;hydroelastic 的場解析度 × 重疊體積;IPC 的接觸數 × 線搜尋次數。
> **seam?**:是(兩個)——(1)**接觸律**:剛性 soft step vs 逐材質柔順律 vs hydroelastic
> → parity(柔順律參數換算回全域 hertz / zeta 時與現行逐位相同;hydroelastic 球壓平面
> 靜止時合力 = 重量、壓力中心在球心正下方,剛度 → ∞ 時靜止高度收斂到 soft step)+
> bench row。(2)**求解演算法**:soft step / 質量分割 / AVBD / 內點法 / IPC 實作同一個
> 「接觸 + 關節子步」trait、編譯期選擇 → parity(17.19 場景集的靜止狀態 by action,判準
> 沿用 17.17 的「≤ 2 × 自身擾動發散」)+ bench row(迭代數 → 殘差、質量比、塔高)。
> 17.19 維持「既有解算器硬化」,本項提供替代者,兩者共用壓力場景;新 seam 列入
> `docs/CATEGORY.md` §2。
> **交付**:普通(單箱靜置:各變體同一靜止高度;橡膠 / 鋼球彈跳高度依材質排序)/ 整合
> (各變體接 island 睡眠、warm start、CCD、17.26 規則、9.4 事件;換變體後既有測試在容差內
> 不變;柔順律接 17.20 可微子集出梯度,對中央差分)/ 極端(1:1e4 質量比、100 層塔、剛度
> 1e9、退化的點對點接觸、IPC 初始即穿透時的拒絕路徑、GPU 解算器遇未支援變體拒絕)。
> 新測試 test_contact_models、test_solver_variants。
> **相依**:17.19(壓力場景、F22 簿記熱點)、17.23(材質承載剛度)、17.20(可微)、17.17
> (GPU 版變體)、15.1(CG / PCG)、17.84(稀疏直接解 / 預條件子,供 IPC 與內點法)、17.52
> (SDF 形狀,hydroelastic 壓力場的來源)、13.5(其 PGS / CG / Newton seam 只落地 PGS;
> (e)是 Newton 系,可順帶給 `ConstraintSet` 補 Newton 變體)、15.2 / 17.56 / 17.58(布料
> 自碰撞與體積軟體是 IPC 的對照與使用端)。內部順序:(a)(d)先(改動小,直接服務
> 17.19)→(c)(e)→(b)(f)(需要 17.52 的 SDF 形狀與 17.84 的稀疏線性解)。

---

## 碰撞形狀、寬窄相與世界查詢

範圍:collision、spatial。

| 編號 | 條目 | 狀態 | Wave | 說明 |
|---|---|:-:|:-:|---|
| 1.1 | [Contact manifold 生成(一切的前置)](ROADMAP_HISTORY.md#11-contact-manifold-生成一切的前置) | ✅ |  | `collision/manifold.mojo` 提供 `ContactManifold[dim]` 與 `ManifoldNarrowPhase` seam(AABB / SAT / OBB / GJK 實作),`geometry/clip.mojo` 做 reference/incident 裁切,3D EPA 回真實深度與 witness points,並與既有 narrowphase 做 normal/depth parity。 |
| 2.3 | [持久化 broadphase + speculative CCD 第一步](ROADMAP_HISTORY.md#23-持久化-broadphase--speculative-ccd-第一步) | ✅ |  | `collision/bp_dbvh.mojo` 提供 Box2D 式 dynamic tree + fat-overlap pair 快取(與 BruteForce pair-set parity,N=4096 相干負載 70µs vs 全重建 18.9ms),solver 的 `_collect_pairs` 以速度比例 speculative margin 攔截高速體(`tests/test_ccd6.mojo`)。 |
| 7.1 | [SAH-BVH(建樹啟發式:median vs SAH seam)](ROADMAP_HISTORY.md#71-sah-bvh建樹啟發式median-vs-sah-seam--2026-07-22) | ✅ |  | 靜態 BVH 加入 binned SAH 建樹(每軸 12 桶,退化回退 median),與 median 樹 region-query/raycast 結果集相等,群聚 raycast 1.62×、樹緊 43%,且因 median 用插入排序,SAH 建樹反而更快。 |
| 7.2 | [solver6 接寬相(生產 solver 脫離 O(n²))](ROADMAP_HISTORY.md#72-solver6-接寬相生產-solver-脫離-on²--2026-07-22) | ✅ |  | solver6 的 pair 收集可改走 fat 世界-AABB 上的寬相(半徑設計使命中集與 brute 相同、依 (i,j) 字典序發出),400 幀混合場景 brute vs bvh bit-identical,N=512 快 1.76×。 |
| 8.1 | [凸包碰撞入 narrowphase](ROADMAP_HISTORY.md#81-凸包碰撞入-narrowphase---完成2026-08-11) | ✅ |  | 任意凸包經 ContactScene6.add_hull 進入生產解算器,以兩包面法向 SAT 求法向/深度、產生多點 patch 接觸,EPA 只留作邊-邊 fallback;test_hull 24 checks、test_quickhull 17 checks,bench_manifold 有兩列量測。 |
| 8.2 | [三角網格 / heightfield 靜態關卡幾何](ROADMAP_HISTORY.md#82-三角網格--heightfield-靜態關卡幾何---完成2026-08-11) | ✅ |  | 靜態 TriMesh(BVH midphase)與 HeightField(格點 midphase)接進 ContactScene6,窄相復用 8.1 hull_manifold,_CPair 以三角形索引 feat 為子鍵支援一對多接觸;test_trimesh 18 checks,bench_trimesh 量測 brute 線性、BVH 對數、heightfield 不隨三角形數成長。 |
| 9.3 | [碰撞過濾(layers / groups / masks)+ sensors / triggers](ROADMAP_HISTORY.md#93-碰撞過濾layers--groups--masks-sensors--triggers---完成2026-08-11) | ✅ |  | ContactScene6 在 _try_pair 開頭做 Box2D 式對稱 category/mask 過濾(brute 與寬相共用),sensor 接觸收在獨立的 sensor_pairs,solve / warm-start / islands 不需認識 sensor;tests/test_filter_events.mojo 21 checks(與 9.4 合測),bench_filter 顯示過濾決定場景能否收斂到靜止。 |
| 13.8 | [SDF / 橢球 / 圓柱 narrowphase](#138-sdf--橢球--圓柱-narrowphase) | 🔶 |  | geometry/sdf3.mojo 有 3D SDF 場與 SDF 對 SDF 接觸,collision/narrowphase.mojo 有 2D 的 SDFNarrowPhase,但兩者都沒有接進 solver6(collider_set 沒有 SDF 形狀種類);橢球與圓柱沒有任何形狀程式碼;交付物 test_sdf_narrowphase 不存在。 |
| 17.13 | [世界查詢完整度](ROADMAP_HISTORY.md#1713-世界查詢完整度--wave-a) | ✅ | A | `collision/world_query.mojo` 對真實 collider 幾何提供有號距離、ray / sphere / capsule cast、overlap、capsule penetration、batched raycast 與 QueryFilter,`test_world_query` 30/30、`bench_world_query` 已量測。 |
| 17.30 | [地形(HeightField)執行期變形](ROADMAP_HISTORY.md#1730-地形heightfield執行期變形--wave-b) | ✅ | B | HeightField 支援 set_height / deform(圓盤挖填)與 16×16 區塊 min/max 摘要增量重算 bounds,ColliderSet / ContactScene6.deform_heightfield 更新 AABB 並喚醒受影響的睡眠體,1024² 地形每次編輯 11.7 µs vs 全表重掃 2.87 ms。 |
| 17.45 | [三角網格 / 高度場碰撞品質與碰撞幾何烘焙](#1745-三角網格--高度場碰撞品質與碰撞幾何烘焙--wave-a) | ⬜ | A | 2026-10-09 盤點新增:內部邊 / 鬼碰撞消除、碰撞網格烘焙、高度場挖洞、逐三角 / 逐格材質與表面類型、對網格 / 高度場的有號距離與穿透深度、雙面三角網格、大面數凸包建構、網格 → SDF 烘焙 |
| 17.46 | [CCD 形狀與旋轉覆蓋、逐體接觸偏移](#1746-ccd-形狀與旋轉覆蓋逐體接觸偏移--wave-b) | ⬜ | B | 2026-10-09 盤點新增:對凸包 / 網格 / 高度場的掃掠 CCD、旋轉(非線性)CCD、逐體接觸偏移 / 靜止偏移 |
| 17.52 | [碰撞形狀種類擴充(動態凹網格 / SDF / 曲面基元 / 半空間 / 體素 / 點雲)](#1752-碰撞形狀種類擴充動態凹網格--sdf--曲面基元--半空間--體素--點雲--wave-b) | ⬜ | B | 2026-10-09 盤點新增:動態凹三角網格(含網格對網格)、圓角凸體 / 凸半徑、圓錐 / 錐形膠囊、無限平面 / 半空間、體素形狀、點雲 / 八叉樹碰撞體、可變形網格 BVH refit;另承接 13.8 的剩餘工作(SDF 作為 solver 形狀、橢球、圓柱) |
| 17.53 | [世界查詢擴充(過濾謂詞 / 多命中 / any-hit / kNN / PVS / GPU 真實幾何射線)](#1753-世界查詢擴充過濾謂詞--多命中--any-hit--knn--pvs--gpu-真實幾何射線--wave-a) | ⬜ | A | 2026-10-09 盤點新增:查詢過濾回呼與多體忽略清單、多命中 / 任意命中射線與掃掠、k 最近鄰查詢、PVS / 預計算可見性集、GPU 批次射線對真實幾何、音訊遮擋查詢 |
| 17.54 | [CPU 多執行緒碰撞管線(寬相更新 / narrowphase / manifold)](#1754-cpu-多執行緒碰撞管線寬相更新--narrowphase--manifold--wave-b) | ⬜ | B | 2026-10-09 盤點新增:多執行緒碰撞管線(平行寬相更新與 narrowphase) |

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

#### 17.45 三角網格 / 高度場碰撞品質與碰撞幾何烘焙 — Wave A

> **緣起**:2026-10-09 負空間盤點,合併 8 筆:內部邊 / 鬼碰撞消除、碰撞網格烘焙、高度場挖洞、逐三角 / 逐格材質與表面類型、對網格 / 高度場的有號距離與穿透深度、雙面三角網格、大面數凸包建構、網格 → SDF 烘焙。
> **現況**:8.2 把三角形當「三頂點單面的凸包」直接走 8.1 的 `hull_manifold`。`TriMesh`
> 只存頂點、索引、每三角一個法向與 BVH(`collision/trimesh.mojo:117-120`),沒有鄰接、
> 沒有材質陣列,單面由繞序決定(`:113-115`)。`HeightField` 欄位是高度、格數、格距、原點
> 與區塊摘要(`:230-242`),沒有洞 / 遮罩。退化三角保留零法向以穩定索引(`:40-45`),
> 到查詢時才略過(`collision/collider_set.mojo:595-596`)。接縫的現行行為有測試:
> `tests/test_filter_events.mojo:308` 斷言箱子壓在接縫上同時與兩個三角形有接觸。
> 網格距離無號:`collision/world_query.mojo:243-244`、`:282-283`(trimesh / heightfield
> 「register only on touch」);`capsule_penetrations`(`:360-371`)只在膠囊軸仍在面上方
> 時給出深度。凸包:`HullShape._build_faces` 三重迴圈 × 全點檢查 = O(V⁴),面數上限 30
> (`collision/hull.mojo:123-165`,`len(self.f) < 90`);float64 增量凸包
> `geometry/polytope.mojo:791` 只被 17.5 的破碎 / 凸分解鏈呼叫(`polytope.mojo:465`、
> `geometry/convex_decomp.mojo:297`)。SDF 只有解析基元(`geometry/sdf3.mojo:25-28`),
> winding number 只有 2D(`geometry/pip.mojo:49`),`voxelize`
> (`geometry/convex_decomp.mojo:101`)給佔據不給距離。
> grep `weld_vert|merge_vert|sanitiz|decimat|cook`、`material_id|surface_type|per_tri`、
> `mesh_sdf|sdf_grid|pseudo.?normal` 於引擎套件零命中;
> `internal.?edge|active.?edge|adjacen|edge_flag` 只命中接觸著色 / ECS 階層的鄰接、
> 英文形容詞 adjacent 與 `collision/hull.mojo:28`(說明 hull 不存鄰接);
> `double.?sided|two.?sided|back.?face` 只命中布料自碰撞註解(`physics/self_collide.mojo:5`);
> `\bholes?\b|cell_mask` 只命中無關用法(`geometry/pip.mojo:11` 的 2D 多邊形洞、ECS 刪列
> 空位、`gameplay/vehicle_wheel.mojo:15` 的路面坑)。docs 內 grep
> `internal.?edge|active.?edge|ghost.?(contact|collision)|double.?sided|back.?face` 零命中。
> 已登記未排程:Phase 17 建議順序 2026-10-09 修訂「本輪遺留待辦」F12 —— mesh / heightfield 接觸只有觸碰
> 無深度(`docs/design/17.0-f12-chain.md:22-24`「true mesh depth is the follow-up for
> 17.2」);17.5 待辦「`HullShape` 面表上限 30 面、O(V⁴) 建構」;8.2 的單面只是範圍陳述,
> 沒有雙面選項;8.2 量測寫明「heightfield 表達不了懸空、牆、洞穴」,但沒有提出挖洞。
> **缺口**:
> - **內部邊 / 鬼碰撞消除**:烘焙時建三角鄰接與 active-edge 旗標(共面或凹的共享邊為
>   inactive),窄相把落在 inactive 邊 / 頂點上的接觸法向換成三角面法向或丟棄;heightfield
>   的鄰接由格點算術直接得出。例:箱子滑過由上萬個共面三角形組成的地板,不在接縫處
>   彈跳、卡住;彈珠滾過起伏地形不被接縫偏轉。
> - **碰撞網格烘焙**:頂點焊接(容差)、重複 / 退化三角清除、鄰接建構、非流形邊回報、
>   quadric 減面成碰撞代理;索引在烘焙時一次重新編號(warm-start 以三角索引為子鍵,
>   執行期不能變)。例:20 萬三角的美術網格烘成 5 千三角的碰撞網格。
> - **heightfield 挖洞**:逐格 no-collision 遮罩,洞內接觸與查詢都不命中。例:在地形上
>   開洞穴入口,洞內另放 trimesh。
> - **逐三角 / 逐格材質與表面類型**:三角 / 格帶 material id,接觸的 `feat`
>   (`physics/contact6.mojo:34-39`)映到材質,摩擦 / 恢復係數走 17.23 組合規則;查詢與
>   接觸事件回傳 surface id。例:同一地形上的冰面低摩擦;腳步查詢回報「碎石」或「木頭」。
> - **對網格 / 高度場的有號距離與穿透深度**:heightfield 以面下為負;trimesh 以單面法向或
>   角度加權 pseudonormal 決定符號;`nearest_surface` 與 `capsule_penetrations` 在軸已沉到
>   面下時仍給深度與推出方向。例:布娃娃 / 關節鏈的腳陷進地形 5 cm;膠囊被瞬移進斜坡。
> - **雙面網格選項**:逐 trimesh 設雙面(背面也產生接觸,射線背面命中可選);代價是失去
>   `trimesh.mojo:113-115` 所述「已穿隧的物體被往外推回」的保護,須搭配 17.46 CCD。
>   例:薄圍籬、繞序不一致的美術網格。
> - **生產級凸包建構**:以增量 / quickhull 建構取代 O(V⁴) 枚舉,取消 30 面上限,加頂點
>   數預算與容差合併(把 `polytope.convex_hull` 接到 `HullShape`)。例:數百點的掃描岩石;
>   17.5 分解出的零件與 Voronoi 碎片不再受「頂點數 ≲ 60」限制。
> - **網格 → SDF 烘焙**:由閉合網格產生密集或稀疏的有號距離格(符號用 3D winding number
>   或 pseudonormal),提供取樣 / 梯度查詢。例:雕刻岩石、齒輪道具的距離場(作為 solver
>   形狀屬 17.52);17.14 navmesh bake 的距離場來源(17.14 優勢區已提 SDF3)。
> **對照組**:Jolt active edges + `mEnhancedInternalEdgeRemoval`、`MeshShapeSettings::Sanitize`、
> `HeightFieldShape` 的 `cNoCollisionValue`、逐三角 `PhysicsMaterial`、`EBackFaceMode`、
> `ConvexHullBuilder`;PhysX cooking(weld / cleanup / active edges / 頂點上限)、
> `PxHeightFieldMaterial::eHOLE`、`PxMeshGeometryFlag::eDOUBLE_SIDED`、PhysX 5 SDF 三角網格;
> Bullet `btAdjustInternalEdgeContacts`;Rapier `TriMeshFlags::FIX_INTERNAL_EDGES`;Box2D v3
> chain shape ghost vertices;meshoptimizer(減面);UE / Unity 地形洞與 surface type。本庫
> 內部對照:`HeightField` vs 其 `to_trimesh()` 明列版(8.2 既有 parity);
> `geometry/polytope.mojo:791` 增量凸包 vs `HullShape` 枚舉。
> **優勢區**:中 —— 鄰接分類(共面 / 凸 / 凹)與 SDF 符號可走 10.1 exact predicates
> (`orient3d`),共面判定不靠 epsilon;heightfield 的鄰接、有號距離、洞遮罩都是格點
> 算術,每次查詢 O(1)(8.2 量測寫 heightfield midphase 109→113 ns、三角數 16.8×;16.3「Benchmark」
> 更正為 124.6→139.6 ns,+12%,來自較大高度陣列的快取行為);
> 凸包建構換成增量版後,17.5 碎片頂點數的上限解除。內部邊、烘焙、材質、雙面屬純工程。
> **規模軸**:三角數 / 格數 × 滑行物體數(接縫命中率);烘焙前後三角數(減面率 vs 接觸
> 誤差);凸包點數 V(O(V⁴) vs 增量的建構時間)與面數;SDF 格解析度(誤差 vs 記憶體)。
> **seam?**:是 ——(1)內部邊處理 on / off:每條共享邊都是凸邊的網格(如四面體)全為
> active 邊,兩者**逐位相同**;平鋪地板上 off 側在接縫處有垂直速度尖峰、on 側低於容差
> (差異當行為斷言);`bench_trimesh` 加 on / off 列。(2)凸包建構:現行三重枚舉 vs 增量
> 建構 → 面數 ≤ 30 的點雲上(共面三角合併後)面法向集合一致;`bench_manifold` 既有的
> 「3d hull face enumeration」列加增量列。(3)有號距離:heightfield 與其 `to_trimesh()`
> 走 pseudonormal 的結果一致;mesh → SDF:winding number vs pseudonormal 符號 parity,與
> `sdf3` 解析盒對照誤差 ≤ 格距。烘焙、材質、洞、雙面不另立 seam(烘焙對已乾淨的網格須為恆等)。
> 擴充「靜態關卡中相」列(`docs/CATEGORY.md:149`)。
> **交付**:普通(箱子以 5 m/s 滑過 1 萬三角共面地板,無垂直跳動;冰格摩擦較低;洞內的
> 箱子落下;雙面圍籬兩側皆擋;300 點雲建出 > 30 面的 hull)/ 整合(17.1 角色走過三角接縫
> 地形、17.4 載具過 heightfield 接縫無抖動;`Chain.resolve_contacts` 的腳陷入地形後被推出;
> 17.30 挖坑後鄰接 / 材質 / 洞保持一致;烘焙後的網格與 hull 進 6.10 快照來回逐位相同;
> 17.49 衝擊事件帶 surface id)/ 極端(全退化網格、T 形接合與非流形邊、單三角、零面積格、
> 整張地形全是洞、material id 越界(API 端 raise)、共面點雲 → 空 hull、1e5 點雲、從背面
> 高速進入單面網格、非閉合網格的 SDF 烘焙回報錯誤而非產生錯號)。
> **相依**:8.1、8.2(單面、退化三角以空面表略過)、10.1(predicates)、17.0 F12(網格
> 深度)、17.5(凸包上限待辦)、17.13(查詢)、17.23(材質組合)、17.30(地形編輯須維持
> 鄰接 / 遮罩)、17.46(雙面網格的穿隧保護)、17.49(衝擊事件 surface id)、13.8 / 17.52
> (SDF 作 solver 形狀、動態網格);可供 17.14 navmesh bake 當距離場來源。
> **邊界**:網格與地形資產匯入(glTF / USD)跟宿主走(17.12、平台方向 C),烘焙只收扁平
> 頂點 / 索引陣列;surface id 的意義(腳步音效、貼花)由宿主解讀,核心只回傳 id。

#### 17.46 CCD 形狀與旋轉覆蓋、逐體接觸偏移 — Wave B

> **緣起**:2026-10-09 負空間盤點,合併 3 筆:對凸包 / 網格 / 高度場的掃掠 CCD、旋轉(非線性)CCD、逐體接觸偏移 / 靜止偏移。
> **現況**:swept / TOI 只有盒對盒線性掃掠:`collision/toi.mojo` 只有 `swept_box_toi`,
> 檔頭明言「Rotation during the step is ignored (linear cast)」(`:18-20`)。`ccd_advance`
> (`physics/ccd6.mojo:18-47`)把 sphere / capsule 當保守 `half` 盒掃(`:33-35`),
> hull / trimesh / heightfield 整對跳過(`:56-57`、`:76-77`),docstring 自承這三種對快速
> 物體留有「residual tunnelling risk」(`:43-45`);候選是全對 O(n²) 迴圈(`:52-61`)。
> 接觸裕度是全域的:`SPEC_BASE = 0.02`(`collision/collider_set.mojo:49`)+ 速度項
> (`collision/contact_gen.mojo:72-77`),容許穿透 `_SLOP = 0.005`
> (`physics/contact6.mojo:27`);`SolverConfig.margin_base` 尚未接到呼叫點
> (`physics/solver_config.mojo:33-40`)。grep `contact.?offset|rest.?offset|skin` 於
> collision / physics 只命中查詢用的 `_SKIN`(`collision/world_query.mojo:54`)與
> `collision/hull.mojo:62` 註解裡的 `SkinVert`;docs 內 `contact.?offset|rest.?offset` 零命中。
> 已登記未排程:6.3 限制「swept TOI 仍 box-only(ccd=True 場景勿混形狀)」;
> `docs/design/17.0f-shape-bugs.md:31-39`(F4c:逐形狀保守掃掠或跳過,選了跳過);6.6
> 限制「盒旋轉忽略(一階)」與 6.7 膠囊 ccd「一階近似」(軟-剛);4.1 只交付線性 cast。
> 17.19 進度把「CCD 全對」列為剩餘熱點(效能面,非形狀覆蓋)。
> **缺口**:
> - **全形狀 swept TOI**:sphere / capsule 精確掃掠(不再以盒代替);hull 對任意凸體以
>   GJK 距離做保守推進(conservative advancement);對 trimesh / heightfield 以掃掠盒取
>   三角候選再逐三角推進。例:300 m/s 彈丸打 5 cm 厚的 trimesh 牆;高速 hull 碎片撞地形。
> - **旋轉 CCD**:TOI 計入子步內的旋轉(以 |v| + |ω|·r_max 為推進界),盒 / hull / capsule
>   共用;軟-剛粒子掃掠的旋轉盒走同一套。例:以 50 rad/s 旋轉、質心幾乎不動的細長木板或
>   螺旋槳葉片不穿牆。
> - **逐體接觸偏移 / 靜止偏移**:每個 collider 的 contact offset(加寬投機裕度)與 rest
>   offset(靜止間隙,可為 0 或負),並維持 fat-AABB 半徑和 == 逐對裕度
>   (`collision/collider_set.mojo:494-499`,寬相 parity 的前提)。例:高速薄板加厚 contact
>   offset;精細道具 rest offset 取 0,視覺上不浮空。
> **對照組**:Jolt `LinearCast` motion quality(任意凸體對 mesh)、Box2D v3 `b2TimeOfImpact`
> (含旋轉)、Bullet conservative advancement、PhysX CCD(含 mesh)與 `contactOffset` /
> `restOffset`、Rapier nonlinear CCD、MuJoCo geom `margin` / `gap`、Unity
> `Collider.contactOffset`。**本庫內部對照**:`swept_box_toi`(盒對盒精確解)。
> **優勢區**:中 —— `ContactScene6` 對 `B: Body6` 泛型。`ScrewBody6` 的子步位姿更新本身
> 就是常數 twist 的閉式 motor exp(`physics/rigid6.mojo:347-349`;`physics/screw.mojo:10-12`:
> 常數速度 bivector 走出精確螺旋線),旋轉 CCD 的路徑插值與積分器同式,不必另做「四元數
> slerp + 線性平移」近似;`QuatBody6` 是質心線性平移 + 繞質心旋轉(`rigid6.mojo:212-222`),
> 與 screw 路徑只在子步端點一致,所以路徑插值放在 `Body6` 上、各表示用自己的路徑。保守
> 推進直接重用 17.13 查詢「每個距離都是真距離的下界」的性質
> (`collision/world_query.mojo:10-18`)。逐體偏移屬純工程。
> **規模軸**:相對線速度 / 角速度 × 特徵厚度(穿隧門檻);快速物體數 × 場景 collider 數
> (含 mesh 三角數);每對 TOI 的推進迭代數 vs 盒對盒精確解。
> **seam?**:是 —— 擴充既有「CCD 階段 speculative vs swept/TOI」列(`docs/CATEGORY.md:56`):
> (1)線性 vs 旋轉掃掠:ω = 0 時與現行線性 cast **逐位相同**,慢速路徑維持 4.1 的逐位
> 不變保證;(2)盒對盒 `swept_box_toi` vs 保守推進 → TOI 在容差內一致;`bench_ccd` 加
> 逐形狀與旋轉 on / off 的 ns/pair 列;(3)旋轉掃掠路徑走既有 `Body6` seam:`QuatBody6`
> 與 `ScrewBody6` 對同一初態的 TOI 在容差內一致。逐體偏移全取預設值時與現行全域裕度
> 逐位相同。
> **交付**:普通(球 / 膠囊 / hull 各以 300 m/s 打薄牆零過衝;旋轉木板不穿牆;加厚 contact
> offset 的薄板不穿)/ 整合(`step_soft(ccd=True)` 的混合全形狀場景與 trimesh 關卡,解除
> 6.3 限制;寬相開關逐位相同;與 17.24 kinematic、9.3 過濾 / sensor 規則一致;17.4 載具高速
> 撞牆、17.5 碎片高速飛散)/ 極端(起點已穿透、擦邊、零面積三角、heightfield 格邊、每子步
> 轉多圈的 ω、rest offset 為 0 與負值、contact offset 為 0、兩快速體對撞、撞上移動中的
> kinematic 平台)。
> **相依**:4.1(swept TOI)、6.3 / 6.6 / 6.7(限制來源)、17.0f(F4c)、17.13(保守推進的
> 距離查詢)、17.45(mesh 有號距離 —— 從面下開始推進需要符號;雙面網格靠本條補穿隧保護)、
> 17.19(「CCD 全對」熱點;新的逐形狀掃掠從寬相取候選)、17.24(kinematic 對)、17.52(新形狀
> 須宣告 CCD 支援)。

#### 17.52 碰撞形狀種類擴充(動態凹網格 / SDF / 曲面基元 / 半空間 / 體素 / 點雲) — Wave B

> **緣起**:2026-10-09 負空間盤點,合併 7 筆:動態凹三角網格(含網格對網格)、圓角凸體 / 凸半徑、圓錐 / 錐形膠囊、無限平面 / 半空間、體素形狀、點雲 / 八叉樹碰撞體、可變形網格 BVH refit;另承接 13.8 的剩餘工作(SDF 作為 solver 形狀、橢球、圓柱)。
> **現況**:13.8「狀態校正」把剩餘工作(SDF 作為 solver 形狀、橢球、圓柱)移入本條;
> 動態三角網格只以限制的形式出現、從未編號 —— `README.md:102-103`「static-only」、
> 8.2「成果」寫明 `add_trimesh` / `add_heightfield`「恆為靜態」。
> 正式解算器的形狀種類只有 box / sphere / capsule / hull / trimesh / heightfield
> (`collision/collider_set.mojo:34-42`,註明 4 / 5 只能靜態)。`ContactScene6.add_trimesh`
> 強制靜態(`physics/solver6.mojo:337-353`);mesh 頂點存世界座標、body 姿態被忽略
> (`collision/collider_set.mojo:82-85`),所以 17.24 的 `set_kinematic`
> (`physics/solver6.mojo:501`)套在 mesh 上也帶不動幾何;`collision/contact_gen.mojo:98-99`
> 對 mesh 對 mesh 直接 return。3D SDF(`geometry/sdf3.mojo:25-28`,含 `KIND_PLANE`)只被
> `tests/test_sdf3.mojo` 與 `benchmarks/bench_sdf3.mojo` 使用。作為剛體碰撞形狀的半空間
> 只在可微子集(`physics/diffsolver.mojo:193-195` `DiffPlane`)與 CGA narrowphase
> (`collision/narrowphase.mojo:217-223`);連續體的地面是逐點高度夾鉗(例:
> `physics/fem.mojo:315-316`),不是 collider;正式路徑的地面是有厚度的盒
> (`collision/collider_set.mojo:161-173` `add_ground_slab`,沉過 `thickness` 就查不到接觸)。
> GJK 只吃頂點雲(`geometry/gjk.mojo:19-45`,`support` 逐點掃描)、只回傳相交布林 +
> simplex(`geometry/gjk.mojo:109-125`),EPA 只給穿透(`geometry/epa.mojo:131-142`),
> 沒有分離時的最近點距離;曲面形狀沒有隱式 support 函式,「核 + 半徑」也缺距離模式;
> hull 的八分域膨脹只用於投機邊距(`collision/collider_set.mojo:352-366` `as_hull`)。
> `TriMesh` 的 BVH 在建構子建一次(`collision/trimesh.mojo:122-164`);`spatial/bvh.mojo`
> 的 `BVH` 只有建樹(`build` / `build_lbvh_presorted` / `build_boxes`)與查詢(`raycast` /
> `query_region`),沒有 refit;refit 只在寬相(`collision/bp_dbvh.mojo:89` `_refit_up`);
> 執行期編輯只有 HeightField(`collision/trimesh.mojo:288,295`,17.30)。體素只是凸分解輸入
> (`geometry/convex_decomp.mojo:42` `VoxelGrid`、`geometry/convex_decomp.mojo:101` `voxelize`),
> 點雲只是凸包輸入(`collision/hull.mojo:190`)。`Inertia3` 只有 box / sphere / capsule 公式
> (`physics/rigid6.mojo:55,66,71`)。grep `convex.?radius|round.?box|圓角|倒角`、
> `half.?space|半空間|無限平面`、`dynamic.?(tri)?mesh|mesh.?vs.?mesh|網格對網格`、
> `voxel.?(shape|collider|world)|minecraft` 於 docs / README 零命中;
> `tapered|錐形|圓錐` 只命中 13.5「設計」的摩擦錐(金字塔錐 / 橢圓錐)。
> **缺口**:
> - **SDF / 橢球 / 圓柱作為 solver 形狀(13.8 剩餘工作)**:`collision/collider_set.mojo`
>   新增 SDF、橢球、圓柱三種 shape kind;SDF 種類接 `sdf_contact`(`geometry/sdf3.mojo:156`),
>   處理 SDF 對既有各形狀的接觸,網格烘焙 SDF 由 17.45 提供;橢球與圓柱走隱式 support
>   函式(見「曲面基元」),`Inertia3` 補兩者公式(例:`Sdf3` 減法咬掉一角的岩石以動態體
>   落在 trimesh 地形上;木桶沿斜坡直線滾下,不在 hull 稜面上顛簸)。
> - **動態 / kinematic 凹三角網格(含 mesh 對 mesh)**:頂點改存局部座標、隨 body 姿態
>   變換;封閉網格的質量性質由 17.44 算;接觸走三角 BVH 對 BVH 或 SDF 取樣(例:浴缸從
>   卡車上掉到 trimesh 地面;旋轉中的凹形風車葉片把箱子推開)。
> - **曲面基元**:圓錐、錐形膠囊 / 錐形圓柱;GJK 改吃隱式 support 函式(圓柱、橢球共用),
>   `Inertia3` 補對應公式(例:交通錐被車撞倒;布娃娃上臂用錐形膠囊)。
> - **圓角凸體 / 凸半徑**:盒與 hull 存成「縮小的核 + 半徑」,GJK 距離模式在核上求解再
>   扣半徑,半徑 0 退化為現有盒 / hull(例:圓角骰子滾動後穩定停在一面,稜邊不抖)。
> - **無限平面 / 半空間**:取代有厚度的 ground slab(例:沙盒場景 1 萬塊碎片高速落地,
>   沒有任何一塊從 slab 底面穿出)。
> - **體素 / 稀疏體素形狀**:磚塊格存佔據位元,逐格編輯只更新受影響磚塊的摘要、
>   不重建三角網格,沿用 17.30 的區塊摘要(例:挖礦遊戲每幀挖掉數十格,落石立即穿過
>   新挖的洞)。
> - **點雲 / 八叉樹碰撞體**:點帶半徑、以八叉樹索引,直接當靜態碰撞面(例:攝影測量
>   點雲建的洞穴關卡,不先重建網格就讓碎石滾落)。
> - **可變形 / 動畫三角網格 + BVH refit**:每幀更新頂點並 refit 三角 BVH,退化超過門檻
>   才重建(例:放下中的吊橋網格把橋上的箱子帶下來;動畫驅動的巨型 boss 體表供角色攀爬)。
> **對照組**:動態網格 / SDF —— PhysX 5 SDF triangle mesh、Bullet `btGImpactMeshShape`、
> parry TriMesh 對 TriMesh、MuJoCo 3 SDF plugin;曲面與圓角 —— Jolt `CylinderShape` /
> `TaperedCapsuleShape` / `TaperedCylinderShape` 與 convex radius、Bullet `btConeShape` 與
> collision margin、parry `RoundShape` / `Cone`、Box2D v3 `b2MakeRoundedBox`;半空間 ——
> MuJoCo plane geom、PhysX `PxPlaneGeometry`、Jolt `PlaneShape`、Bullet
> `btStaticPlaneShape`;體素 —— parry `Voxels`、Teardown;點雲 —— FCL `OcTree`;refit ——
> PhysX `PxTriangleMesh::refitBVH`、Bullet `btBvhTriangleMeshShape::refitTree`、Warp
> `wp.Mesh.refit`。**本庫內部對照**:17.5 凸分解 + 焊接 hull(凹體的現行替代路線)、
> `add_ground_slab`、以 hull 近似曲面、HeightField 的區塊編輯。
> **優勢區**:中 ——(a)CGA / DCGA:`CgaShapeNarrowPhase` 以 grade-1 內積處理球與無限
> 平面(`collision/narrowphase.mojo:217-223`),DCGA 的 15 單項式基底以同一內積涵蓋平面、
> 球、橢球(`geometry/dcga.mojo:24`,目前只支援軸對齊 `geometry/dcga.mojo:31`);依「明確
> 不做」節的定位,CGA 只當曲面基元的查詢與交叉驗證,不當效能主線。(b)SDF 的接觸數與
> 網格細分無關(`geometry/sdf3.mojo:7-12`);正式解算器有了半空間,就能與可微子集的
> `DiffPlane` 逐幀對照(17.20)。(c)體素編輯是整數位元運算,回放(17.39)逐位可重現。
> 圓錐、圓角、refit、點雲:低 —— 純工程。
> **規模軸**:動態網格三角數 × 動態網格對數;SDF 格解析度 vs 接觸品質;曲面基元的解析
> 形狀 vs hull 近似面數(誤差 / 成本);體素數 × 每幀編輯數;點數 × 點半徑;refit 的每幀
> 頂點位移量 × 三角數(refit 品質退化到需重建的交叉點)。
> **seam?**:是 ——(1)動態凹體接觸生成:三角 BVH 對 BVH vs SDF 取樣 → parity(同一網格
> 兩法的靜置高度 / 接觸法向在容差內一致;凸網格時與 `add_hull` 一致)+ bench row(三角數
> 掃描);(2)`TriMesh` BVH 更新:refit vs rebuild → parity(任一頂點更新後對同一 AABB
> 查詢的候選集合相等)+ bench row。新種類各對一個既有表示做 parity:半徑 0 的圓角盒 ≡ 盒
> (逐位)、穿透小於 slab 厚度時半空間與 `add_ground_slab` 在容差內一致、SDF 球 ≡ 解析球、
> 圓柱的 hull 近似隨面數收斂到解析圓柱、體素格 ≡ 同佔據的盒複合(17.44);各附 bench row,
> `docs/CATEGORY.md` 補兩列 seam。
> **交付**:普通(SDF 岩石落到 trimesh 地形上入睡;浴缸網格落到 trimesh 地面並入睡;圓角
> 骰子停在一面;木桶沿斜坡直線滾下;交通錐倒地;半空間承載千箱;體素牆挖一格後球滾過;
> 點雲地面上箱子靜置;refit 中的吊橋把箱子放下)/ 整合(新種類都走 `ContactScene6` 正式
> 路徑:島 / 睡眠 / 6.10 快照往返 / 17.13 `ray_cast` 與 `point_distance`;17.1 角色站上旋轉
> 的凹網格平台;17.4 的 `WheelCast` 加圓柱輪變體(現有 ray / sphere / capsule,
> `gameplay/vehicle_wheel.mojo:5-18`);17.2 布娃娃改用錐形膠囊肢段(現為盒,
> `gameplay/ragdoll.mojo:68-70`);17.17 GPU 路徑(收集留在 CPU、裝置只解接觸)對含新種類的
> 場景與 CPU 一致)/ 極端(半徑 0 圓角盒逐位等於盒;錐頂半徑 0、兩端半徑相等的退化;沉到
> slab 厚度以下仍被半空間推出;兩個動態網格初始互穿;非封閉網格當動態體加入時 raise;
> 空體素格、單點點雲;refit 位移過大觸發重建;1e6 體素世界每幀 1e3 次編輯)。
> **相依**:13.8(SDF / 橢球 / 圓柱的剩餘工作移入本條)、8.1 / 8.2(凸包與靜態網格路徑)、
> 6.3、17.5(凸分解是凹體的現行替代路線;17.5「待辦」記載只切凸實體、凹體先分解)、
> 17.24(kinematic 網格)、17.30(區塊摘要供體素 / refit 的增量 AABB)、17.44(複合形狀與
> 依形狀算質量性質)、17.45(網格烘焙 SDF、網格清理)、17.46(新種類的 CCD)、17.65(morph /
> 蒙皮頂點來源)、17.13、17.17、17.20;解鎖 17.1 / 17.2 / 17.4 的形狀選項,17.14 的 navmesh
> bake 可直接讀體素世界。
> **邊界**:網格頂點動畫的來源(蒙皮 / morph)由 11.3 動畫執行期、17.65 或宿主提供頂點
> 陣列;點雲的擷取裝置與繪製用網格屬宿主,核心只收碰撞用的點 / 頂點資料。

#### 17.53 世界查詢擴充(過濾謂詞 / 多命中 / any-hit / kNN / PVS / GPU 真實幾何射線) — Wave A

> **緣起**:2026-10-09 負空間盤點,合併 6 筆:查詢過濾回呼與多體忽略清單、多命中 / 任意命中射線與掃掠、k 最近鄰查詢、PVS / 預計算可見性集、GPU 批次射線對真實幾何、音訊遮擋查詢。
> **現況**:17.13 交付的 `collision/world_query.mojo` 只回傳最近一筆:`ray_cast`
> (`collision/world_query.mojo:568-584`)、`capsule_cast` / `sphere_cast`
> (`collision/world_query.mojo:377-427`,第一個接觸)、`ray_cast_batch`
> (`collision/world_query.mojo:587-598`,每條射線一筆、逐條串行);只有 overlap 與
> `capsule_penetrations` 回傳全部(`collision/world_query.mojo:344-371`)。hull 射線已算出
> 出口距離 `t1`(`collision/world_query.mojo:519-537`)但丟棄;網格射線對三角形雙面求交
> (`collision/world_query.mojo:552-553` 翻轉背面法向);`Hit`(`collision/world_query.mojo:76-91`)
> 只有 body,沒有三角形 / feature 索引,接不上逐三角形材質。`QueryFilter`
> (`collision/world_query.mojo:59-74`)= 類別遮罩 + **單一** `ignore` + sensor 開關,沒有
> 謂詞;例:載具懸吊射線只忽略車體一個 body(`gameplay/vehicle.mojo:518`)。AI 視線目前用
> 最近命中的 `ray_cast`(`collision/world_query.mojo:5` 點名 AI line-of-sight)。
> `nearest_surface`(`collision/world_query.mojo:266-294`)是對所有 collider 的 1-NN 線性
> 掃描;`spatial/` 各索引只有 AABB `query_region`(`spatial/bvh.mojo:409`、
> `spatial/hash_grid.mojo:93`、`spatial/tree_core.mojo:117`;`BVH` 另有回傳單一命中的
> `raycast`,`spatial/bvh.mojo:382`)。GPU 射線只測 broadphase 盒
> (`collision/gpu_raycast.mojo:1-8`;`docs/CATEGORY.md:109` 為逐 proxy-id parity)。grep
> `all.?hits|multi.?hit|any.?hit|pierc|多命中`、`knn|k.?nearest|nearest.?neighbo|最近鄰`、
> `\bPVS\b|occlu|potentially.?visible`、`acoustic|聲學|音訊遮擋` 於 docs / README 與引擎
> 程式碼皆零命中;`PreFilter|PostFilter|filter.?(fn|predicate|callback)|ignore.?(list|set)`
> 於 docs 零命中,程式碼只命中 AABB 預篩的註解(`collision/world_query.mojo:32-35`)。
> **缺口**:
> - **查詢過濾謂詞與多體忽略集**:pre-filter(逐 collider,窄相前)與 post-filter(逐命中,
>   拒絕後射線繼續找下一筆),以 comptime trait 參數傳入(內層迴圈不 raise),另附小型
>   忽略集(例:車體、拖車與四個輪子 body 都不擋自己的懸吊射線;AI 視線穿過標為玻璃
>   的 collider)。
> - **多命中(全部 / 穿透)射線與掃掠**:依 t 排序回傳每個表面的進入點與出口點(厚度),
>   命中帶 body 與三角形索引(例:穿甲子彈依序打穿兩面牆與一個木箱,傷害按每段厚度
>   遞減)。
> - **任意命中(any-hit)**:找到任一命中即停,只回布林(例:200 個哨兵每幀測「看得到
>   玩家嗎」,不需要最近點)。
> - **k 最近鄰**:對 collider 與對無 collider 的點(agent 位置)以 BVH / 格網最佳優先
>   搜尋,距離相同時以索引定序(例:每個 crowd agent 取最近 8 個鄰居給 17.14 的 ORCA;
>   塔防砲塔選最近 5 個敵人)。
> - **PVS / 預計算可見性集**:靜態關卡切成格,離線以批次射線取樣算格對格可見位元集,
>   執行期先查位元再決定是否發視線射線;門 / 可破壞牆以 portal 旗標開關(例:1000 個
>   AI 只對潛在可見的目標發 LOS 射線)。
> - **GPU 批次射線對真實幾何**:把 `_ray_one`(`collision/world_query.mojo:483-565`)的各形狀
>   分支(盒 slab、球二次式、hull 平面裁切、三角 Möller–Trumbore、膠囊保守推進)搬進
>   kernel,trimesh 走裝置端 BVH 走訪(`spatial/gpu_lbvh.mojo` 目前只做 Morton 碼與排序)
>   (例:一幀 10 萬條射線更新 RTS 戰爭迷霧的可見性格,接 17.15)。
> - **音訊遮擋的查詢資料**:多命中射線回傳的 (body, 三角形 / 材質, 厚度) 序列即宿主音訊
>   遮擋的輸入(例:聲源隔著兩道牆,宿主依材質與總厚度決定悶音量)。
> **對照組**:PhysX `PxQueryFilterCallback`(preFilter / postFilter)與 `PxRaycastBuffer`
> touches、Jolt `BodyFilter` / `ShapeFilter` 與 `AllHitCollisionCollector` /
> `AnyHitCollisionCollector`、Unity `RaycastAll` / `RaycastNonAlloc`、UE `LineTraceMulti` 與
> `FCollisionQueryParams` 忽略清單、Rapier `QueryFilter` 謂詞;kNN —— nanoflann、Recast /
> Detour crowd proximity grid;PVS —— Source engine PVS、Umbra、UE precomputed visibility
> volumes;GPU 射線 —— NVIDIA Warp `mesh_query_ray`;音訊 —— Steam Audio、Wwise Spatial
> Audio、UE5 audio occlusion trace。**本庫內部對照**:現有最近命中 `ray_cast`、
> `QueryFilter`、`nearest_surface`(1-NN)、`gpu_raycast`(proxy 層級)。
> **優勢區**:低-中 —— 主要是工程。加值在決定論:多命中依 (t, body, 三角形) 全序排序、
> kNN 以 (距離, 索引) 破平手、any-hit 只回布林(與走訪順序無關),結果在各索引後端與
> CPU / GPU 之間可逐位比對(沿用 `gpu_raycast` 的「最低索引勝」規則,
> `collision/gpu_raycast.mojo:10-15`),17.39 回放與 17.16 rollback 不受影響。GPU 真實幾何
> 射線:中 —— 各形狀分支都是閉式解,適合一條射線一個 thread。
> **規模軸**:查詢數 × 場景 collider 數(接 17.13 待辦的持久寬相預篩);每條射線命中數
> (穿透牆數);k × agent 數 × 鄰居半徑;PVS 格數 × agent 數(省下的射線比例 vs 位元集
> 記憶體);GPU 射線批量 × collider 數的 CPU / GPU 交叉點。
> **seam?**:是 —— 擴充既有 `SceneQuery` / world_query seam:(1)命中收集器(closest /
> any / all)→ parity:all-hits 排序後第一筆 ≡ `ray_cast`、any-hit ≡「all-hits 非空」;
> (2)過濾:以謂詞實作的遮罩 + 單一忽略 ≡ 現有 `QueryFilter`(逐位);(3)kNN 在 brute /
> BVH / grid / tree 四索引結果集相等(與 17.13 待辦的四索引 parity 同表);(4)PVS 剔除後
> 的 LOS 結果 ≡ 全量射線結果(PVS 只能多報可見、不能漏報);(5)GPU vs CPU:每條射線的
> body 與 t 相等(`docs/CATEGORY.md:109` 一列擴到真實幾何)。各附 `bench_world_query` 擴充列。
> **交付**:普通(穿甲射線打穿三個箱子得三筆排序命中與厚度;any-hit 視線;最近 5 個敵人;
> 忽略整台載具的懸吊射線)/ 整合(`gameplay/vehicle.mojo:518` 改用忽略集;17.1 角色控制器以
> post-filter 實作單向平台 —— 17.26「進度」的待辦記載角色控制器尚未套用單向平台;17.14
> crowd 取 kNN 鄰居;17.15 perception 先查 PVS 再發射線;GPU 射線餵 17.15 戰爭迷霧格)/
> 極端(起點在物體內的 all-hits、射線沿面掠過、同 t 多筆命中的次序固定、k 大於 collider
> 數、k = 0、空場景、PVS 格外的點、謂詞全拒、無加速器時 GPU 測試自動跳過)。GPU 子項接
> 17.17 的裝置端狀態,可晚於其他子項。
> **相依**:17.13(基底;其待辦的持久寬相預篩與四索引 parity)、9.3(類別遮罩)、17.23 /
> 17.45(逐 body / 逐三角形材質,命中要帶材質)、17.26、17.1、17.4、17.14、17.15(消費者)、
> 3.2 / 17.17(GPU 裝置端 collider 狀態)、17.54(`ray_cast_batch` 的多執行緒)、12.1
> (謂詞跨 C-ABI 的函式指標形式)、17.39 / 17.16(查詢決定論)。
> **邊界**:音訊播放、DSP 與聲學傳播(繞射 / 殘響)屬宿主的音訊層(「明確不做」節的
> 2026-08-02 註記:多媒體不在核心 repo);核心只提供多命中射線與 (body, 材質, 厚度) 資料。
> 繪製用的遮擋剔除屬宿主渲染器;PVS 位元集是資料,宿主可自行重用。LiDAR / 深度相機等
> 機器人感測器模型不排(2026-10-09 排除 RL 與機器人);13.6 測距儀只對平面
> (`physics/sensors.mojo:19-21`),本條不接感測器,宿主自行以批次射線組出取樣樣式。

#### 17.54 CPU 多執行緒碰撞管線(寬相更新 / narrowphase / manifold) — Wave B

> **緣起**:2026-10-09 負空間盤點,合併 1 筆:多執行緒碰撞管線(平行寬相更新與 narrowphase)。
> **現況**:`ContactScene6._collect_pairs`(`physics/solver6.mojo:696-824`)整段串行:逐體組
> fat AABB(`physics/solver6.mojo:737-745`)→ `collect_bp_pairs` 重建寬相、取對、排成 (a, b)
> 字典序(`collision/contact_gen.mojo:43-69`)→ 逐對 `try_pair` 把接觸 append 到共用的
> `raws` / `sraws`(`physics/solver6.mojo:775-794`,brute 路徑 `physics/solver6.mojo:796-815`)
> → 逐筆 `make_contact` 做 warm-start 比對、`apply_rules`(`physics/solver6.mojo:816-823`)。
> 平行只在求解:physics 內 `max.algorithm.parallelize` 只用在 `physics/solver6.mojo:1405-1407`
> (島)、`physics/contact6.mojo:534-536`(同色接觸對)、`physics/diffsolver.mojo:464-466`
> (多世界);其餘呼叫在 scheduler 的通用原語(`scheduler/policy.mojo:41`、
> `scheduler/jobgraph.mojo:175-177`、`scheduler/workstealing.mojo:93`);`collision/*.mojo`
> 沒有 `parallelize`。7.2「進度」記載「收集在前、分島在後」,之後沒有條目平行化收集。
> 17.19「進度」(F22 第一批)量到 N=4096 時 CPU 簿記仍 20.6 ms/幀(`bench_gpu_contact` 的
> 「GPU path: CPU collection + bookkeeping」列,現行 `BENCHMARK_REPORT.md:2343` 為 25.3 ms),
> 17.17 的 GPU 解算因此被 CPU 端拖住;17.17 規劃的是 GPU narrowphase(17.17「缺口」與
> 「進度」的待辦),沒有提到 CPU 多執行緒版本。grep
> `parallel.{0,20}(narrow|collect)|多執行緒.{0,10}(碰撞|收集)` 於 docs 與引擎程式碼零命中。
> **缺口**:
> - **逐對 narrowphase / manifold 的 fan-out**:每個候選對寫入自己的輸出槽(接觸數 +
>   `RawContact`),再依 (a, b) 次序以前綴和串接,得到與串行完全相同的 `raws` 序列(例:
>   17.5 爆炸後 4096 塊碎片同時壓在 trimesh 地形上)。
> - **負載不均的排程**:每對成本差異大 —— mesh 對要逐三角呼叫 `hull_manifold`
>   (`collision/contact_gen.mojo:80-138` `try_mesh_pair`),盒對是固定成本的
>   `box_box_manifold`;靜態切分會讓抽到 mesh 對的 worker 拖住整輪。fan-out 放在 physics
>   (第 4 層)才能選用 `scheduler/workstealing.mojo`(collision 與 scheduler 同在第 3 層,
>   `scripts/arch_layers.toml:12-13`,不能互引)(例:城市 trimesh 上 2000 輛殘骸車)。
> - **逐體 fat AABB 與寬相重建的平行**:逐體 AABB 是獨立 map;BVH 建樹可接既有 Morton
>   排序(`spatial/bvh.mojo:452` `morton_order`)(例:每幀 16384 個 AABB)。
> - **接觸後處理的平行 map**:`make_contact` 對唯讀 `cache_index`
>   (`physics/contact6.mojo:104`)查 warm-start、`make_sensor_contact`
>   (`physics/contact6.mojo:86`)逐筆獨立;`_emit_events`(`physics/solver6.mojo:905-926`)的
>   key 打包與排序可平行,其後的 `diff_events`(`collision/contact_events.mojo:44`)是兩個
>   有序串列的合併,保持串行或改為分段合併(例:佈滿觸發區的關卡,每幀上千筆 began /
>   ended 事件)。
> - **批次查詢共用同一 fan-out**:`ray_cast_batch` 逐條串行
>   (`collision/world_query.mojo:587-598`),每條射線獨立(例:每幀 500 條 AI 視線)。
> **對照組**:Jolt job system(broadphase 更新與 narrowphase 皆為 job)、PhysX 5 CPU
> dispatcher 上的多執行緒 narrowphase、Box2D v3 以使用者 task 平行化接觸更新、Rapier
> `parallel` feature、Avian(Bevy)平行 narrow phase。**本庫內部對照**:串行
> `_collect_pairs`(逐位參考)、6.5 島平行與 6.11 著色平行(同一「寫入不相交 → 逐位相同」
> 論證,`docs/CATEGORY.md:111-112`)、17.17 GPU 路徑。
> **優勢區**:中 —— 主體是工程。差異在決定論:`collect_bp_pairs` 已把候選對正規化為
> (a, b) 字典序(`collision/contact_gen.mojo:46-53`),逐對寫槽再依序串接即與串行逐位
> 相同,所以 Gauss–Seidel 求解、17.39 回放雜湊與 17.16 rollback 都不隨 worker 數改變,
> 與 6.5 / 6.11 的 parity 標準一致。
> **規模軸**:N(64 → 16384)× worker 數(核心擴展曲線);場景組成(全盒 vs 混 trimesh /
> hull 的每對成本變異 → 靜態切分 vs work-stealing);小 N 誠實列(6.5「進度」的誠實行:
> 單大島平行反慢 1.37×;收集同樣有 fan-out 開銷)。
> **seam?**:是 —— 收集求值策略(串行 / 靜態 `parallelize` / work-stealing)→ parity:任一
> worker 數下 `raws` / `sraws` 序列、接觸事件與 K 幀後世界逐位相同(與 `test_islands_par`
> 同構)+ bench row(收集 ms/幀 vs N × workers;mesh 偏重場景的兩種排程各一列);
> `docs/CATEGORY.md` 在島平行列旁補一列。
> **交付**:普通(N=4096 箱場,多執行緒收集與串行逐位相同並量 ms/幀)/ 整合(接
> `ContactScene6.step(cfg)` 既有的 `cfg.parallel` / `cfg.workers`
> (`physics/solver_config.mojo:58-61`)與 17.17 GPU 路徑的 CPU 收集;求解端的島平行在
> colored / 軟體 / CCD / drive / 可斷關節時不啟用(`physics/solver6.mojo:1244-1249`,colored
> 改走逐色平行),收集段不受此限;混合場景含 trimesh 地形、hull 碎片、焊接、sensor、接觸
> 規則(17.26)與事件;17.39 回放在不同 worker 數下每 tick 雜湊相同)/ 極端(workers = 1
> ≡ 串行;零候選對;單體;所有候選對壓在同一個 mesh;刪除體與焊接過濾;收集時遇 NaN
> 體仍走步末隔離;N = 16384)。
> **相依**:7.2(寬相收集)、6.5 / 6.11(求解段平行,本條補收集段)、17.19(演算法熱點
> 先行:每幀重建 BVH、著色重排、CCD 全對;本條只平行化、不改複雜度)、17.17(GPU
> narrowphase 是另一條路;本條是無加速器主機的路徑與其 parity 基準)、17.10(分段計時)、
> 9.4(接觸事件)、17.75(宿主 job system 注入時,收集 fan-out 要能改走宿主排程)、17.79
> (執行緒拓撲)、17.53(批次查詢)、17.39 / 17.16(跨 worker 數決定論)。

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
| 17.51 | [縮座標關節體完整化(球關節・雙向接觸・閉環・可微)](#1751-縮座標關節體完整化球關節雙向接觸閉環可微--wave-b) | ⬜ | B | 2026-10-09 盤點新增:縮座標球 / free 關節、摩擦 + 雙向接觸、閉環機構、可微 ABA / RNEA |

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

> **狀態**:✅ 已完成 — 原屬 Wave C
> **已交付(依程式碼核對補記,原 ROADMAP 本節無進度註)**:`physics/constraints.mojo` 的 `ConstraintSet`:equality(不設上下限)、joint limit(f ≥ 0)、friction loss(|f| ≤ f_max)、contact normal(f ≥ 0)、contact friction(|f_t| ≤ μ f_n)全部放進同一個 projected Gauss-Seidel 迴圈,每列各有自己的 projection;`H⁻¹Jᵀ` 每列只算一次。摩擦錐用旗標 `CONE_PYRAMIDAL` / `CONE_ELLIPTIC` 選擇;橢圓錐把兩條切向列當成一對處理,做徑向投影。`tests/test_constraints.mojo`:equality 殘差歸零、stop 只推不拉、乾摩擦在上限以下保持靜止、橢圓錐等向而金字塔錐沿對角線多出 sqrt(2) 倍摩擦(最多偏 35°)、equality + limit + contact 同時成立。`benchmarks/bench_constraints.mojo`(報告範本有 `@bench` 行)。
> **量測結論(bench_constraints 檔頭)**:同等工作量下,單一系統與交替 pass 的違反量相同;交替 pass 能降到機器零,單一系統則停在約 3e-8(warm-start 累積衝量後重算殘差產生的抵消誤差)。所以統一求解的理由不是迭代數,而是摩擦錐把各列耦合在一起:不知道 f_n 的 pass 根本算不出 |f_t| ≤ μ f_n。
> **與設計 / 交付物的差距(依程式碼核對,原 ROADMAP 未記錄;狀態仍維持原標 ✅)**:
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

#### 17.51 縮座標關節體完整化(球關節・雙向接觸・閉環・可微) — Wave B

> **緣起**:2026-10-09 負空間盤點,合併 4 筆:縮座標球 / free 關節、摩擦 + 雙向接觸、閉環機構、可微 ABA / RNEA。
> 9.1「狀態校正(2026-10-09)」已把「縮座標球關節 / 多自由度關節」移到本項;Phase 13 開頭「現況校正」
> 所列「缺的是關節型別只有 revolute」在球關節部分仍成立。可微部分原只在 17.20「進度」的待辦「子集外擴
> (盒 / 膠囊、關節、恢復係數 pass)」與 17.2「優勢區」「drive gain 可用梯度調」被提到,前者指接觸
> 解算子集而非 `Chain`,後者沒有實作(17.2 建在最大座標上)。
> **現況**:
> - 關節型別:`physics/chain.mojo:96-97` 只有 `JOINT_REVOLUTE` / `JOINT_PRISMATIC`,每個
>   link 1 自由度(`ChainLink`,`physics/chain.mojo:101-109`);只有根可以 6 自由度(`physics/floating.mojo:40`
>   `FloatingChain`)。grep `ball|spherical|cone|twist|friction|tangent` 於 `chain.mojo`、
>   `floating.mojo` 零命中。
> - 接觸:`Chain.resolve_contacts`(`physics/chain.mojo:694-783`)只對材質點施法向衝量
>   (速度 pass + 位置修正 pass),docstring 寫明 "the colliders are static as far as this call
>   is concerned";沒有摩擦,也不把反作用衝量施給 `ContactScene6` 的動態體。13.2「設計」寫「先做
>   單一鏈接地,再推廣」,F12 把地面推廣到任意靜態 `ColliderSet`
>   (`docs/design/17.0-f12-chain.md:17-27`),摩擦與動態體耦合不在任何條目裡。
> - 閉環:`Chain.parent`(`physics/chain.mojo:182`)只能表達樹 / 森林(6.12)。13.5 的
>   `ConstraintSet.add_equality`(`physics/constraints.mojo:94`)能表達閉環方程,但 docstring
>   寫明 "Deliberately not tied to `Chain`"(`physics/constraints.mojo:63`),且只被 `test_constraints` /
>   `bench_constraints` 使用。docs grep `closed.?loop|loop closure|four.?bar|閉環|四連桿`
>   只命中樣條閉曲線與控制閉環。最大座標的 `ContactScene6` 關節圖本來就允許有環。
> - 可微:`Field` 泛型只在 `physics/diffsim.mojo`、`diffrigid.mojo`、`diffsolver.mojo`;
>   `chain.mojo` 是具體的 `Real` / `Vec3`(`physics/chain.mojo:23-29` imports)。grep
>   `d_rnea|rnea_deriv|dqdd_dq` 零命中。縮座標關節力只有 `read_joint_torque`
>   (`physics/sensors.mojo:84-88`,經逆動力學)。
> **缺口**:
> - **多自由度關節**:球關節(四元數座標、3 維速度,積分走 exp map)、樹中的 free joint、
>   universal(2 自由度)。例:縮座標人形 ragdoll 的肩 / 髖;吊車吊鉤的球鉸;掛在手臂上、
>   被拋出的盾(樹中途的浮動子樹)。
> - **摩擦 + 雙向接觸**:Chain 的接觸列改走 13.5 統一 `ConstraintSet`(法向 + 兩切向 +
>   摩擦錐),反作用衝量在同一子步施給 `ContactScene6` 的動態體。例:挖土機手臂(縮座標鏈)
>   推開散落的木箱;機甲的腳踩在會翹起的動態木板上不打滑。
> - **閉環機構**:在樹上加閉環等式列(點重合 / 軸對齊),Jacobian 由 `point_jacobian`
>   (`physics/chain.mojo:610`)組出。例:挖土機鏟斗的四連桿、車輛雙 A 臂懸吊、吊橋的平行
>   連桿。
> - **可微關節體動力學**:`Chain` 穿 `SolverField` 係數環走過 CRBA / RNEA / ABA,或 Pinocchio
>   式解析 ∂RNEA / ∂ABA。例:以梯度調主動 ragdoll 的驅動增益;調吊車連桿質量,使擺動
>   週期對上目標。
> **對照組**:MuJoCo ball / free joints + equality connect + 所有約束同一解;Drake
> `BallRpyJoint` / `QuaternionFloatingJoint` + loop constraints + AutoDiffXd;PhysX 5
> articulations(spherical joint、loop joints、與剛體同一解算器);Pinocchio
> (`JointModelSpherical`、RNEA / ABA 解析導數,Carpentier 2018);Simbody;Nimble;Warp /
> Newton articulations。**本庫內部對照**:最大座標 ragdoll(17.2,`Joint6` ball +
> `AngularDrive`)、`bench_chain`(同一鏈的縮 vs 最大座標,6.4)與 `bench_chain_contact`
> (縮座標接觸成本對連桿數)。
> **優勢區**:中 —— FK 已走 motor 合成(Phase 13 現況校正),球關節的四元數座標與 `Motor3`
> 同一表示,沒有 Euler 角奇異;縮座標關節在高剛度下不抖(13.2 規模軸的論點),閉環只多
> 幾條等式列;可微部分接 17.18 / 17.20 的 `SolverField` 環(`RealF` / `DualReal` /
> `RevReal`),對照組中 MJWarp 目前不可微(17.18 優勢區)。
> **規模軸**:連桿數 × 球關節比例(ABA 仍 O(n));接觸數 × 動態體數;閉環數(約束列)×
> 迭代;可微:參數數 NP 對有限差分的交叉點。
> **seam?**:是(三列)——(1)關節座標表示:縮座標球關節 vs 最大座標 `Joint6` ball →
> parity(同初值擺動,末端軌跡 by action 在容差內)+ bench row(連桿數掃描)。(2)Chain
> 接觸解:現行分通道 `resolve_contacts` vs 統一 `ConstraintSet` 列 → parity(無摩擦、
> 靜態碰撞體時靜止狀態一致)+ bench row。(3)Chain 係數環:`RealF` vs `DualReal` /
> `RevReal` → parity(`RealF` 與現行逐位相同、梯度對中央差分)+ bench row(接
> `bench_diffsolver` 的 NP 掃描)。閉環沿用 (2) 的 `ConstraintSet` 列,以最大座標 hinge
> 四連桿為對照,不另立 seam。
> **交付**:普通(小角度球擺週期對解析;四連桿輸出角對 Freudenstein 方程;球關節 ragdoll
> 自由落體質心拋物線)/ 整合(縮座標手臂推動 `ContactScene6` 木箱:鏈與箱收到的接觸衝量
> 大小相等、方向相反,箱子受摩擦被帶動;閉環 + 接觸 + 關節極限在同一 `ConstraintSet`;
> `FloatingChain` 帶球關節;梯度對有限差分;選現行分通道變體時 `test_chain_contact` /
> `test_chain_ground` 不變)/ 極端(球關節轉過 π 的四元數雙覆蓋、冗餘閉環列(過約束)、
> 奇異姿態、動態體質量 1e-3 與 1e3 對鏈、摩擦係數 0 時與只有法向列逐位相同、NP 大)。
> 新測試 test_chain_ball、test_chain_loop、test_chain_friction。
> **相依**:6.4 / 6.8 / 6.12 / 9.2(Chain 本體)、9.1(校正來源)、13.2(接觸耦合)、13.5
> (統一約束)、13.3(致動器 seam)、17.2(最大座標對照)、17.47(最大座標關節庫,parity
> 對照)、17.17(GPU articulation 依本項的關節型別)、17.18 / 17.20(可微環)、17.66(物理
> 角色控制的使用端)。
> **邊界**:RL 與機器人用途已由使用者排除(2026-10-09):本項不做 Gym 介面、策略訓練、
> 機器人感測器與抓取。學習式控制器(17.66)只能經 13.3 致動器 seam 由外部提供 τ。

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
| 17.55 | [連續體共用步進契約(審計 F25)](#1755-連續體共用步進契約審計-f25--wave-b) | ⬜ | B | 2026-10-09 盤點新增:連續體解算器接入世界步進、布料與剛體 / 碰撞體雙向碰撞、軟體睡眠 |
| 17.56 | [布料完整化(綁骨架、彎曲、任意網格、空氣動力、CCD、撕裂)](#1756-布料完整化綁骨架彎曲任意網格空氣動力ccd撕裂--wave-b) | ⬜ | B | 2026-10-09 盤點新增:布料綁骨架、布料彎曲剛度、任意三角網格布料與膜材料、布料空氣動力、布料連續碰撞、布料撕裂與軟體切割 |
| 17.57 | [毛髮、彈簧骨與肌肉次級動力學](#1757-毛髮彈簧骨與肌肉次級動力學--wave-c) | ⬜ | C | 2026-10-09 盤點新增:毛髮與髮束模擬、骨架彈簧骨(次級運動,continuum 與 anim 兩域重複記錄)、體積肌肉與肉體次級動力學、Hill 肌肉力-長度 / 力-速度曲線與肌腱柔度 |
| 17.58 | [體積軟體完整化](#1758-體積軟體完整化--wave-c) | ⬜ | C | 2026-10-09 盤點新增:任意網格體積軟體(四面體化 + 嵌入網格)、超彈性與各向異性材料、形狀匹配軟體、壓力(充氣)軟體、軟體互撞與體積自碰撞、可變形體彈塑性斷裂、薄殼與塑性彎曲 |
| 17.59 | [流體-固體雙向耦合](#1759-流體-固體雙向耦合--wave-c) | ⬜ | C | 2026-10-09 盤點新增:SPH / PBF 與剛體雙向耦合、LBM 與運動剛體雙向耦合、MPM / FEM 與剛體雙向耦合、流體-布料耦合、剛體流體力模型、統一粒子物理 |
| 17.60 | [水面與網格流體(淺水・海浪・煙火・FLIP・多相・黏塑・爆炸波)](#1760-水面與網格流體淺水海浪煙火flip多相黏塑爆炸波--wave-c) | ⬜ | C | 2026-10-09 盤點新增:高度場水面 / 淺水方程、海浪與水流浮力水面、歐拉網格煙火、FLIP / APIC 液體、多相流與表面張力、非牛頓 / 黏塑流體、爆炸壓力波傳播 |
| 17.61 | [多物理材料(顆粒 / 熱傳與相變 / 電磁 / 植被)](#1761-多物理材料顆粒--熱傳與相變--電磁--植被--wave-c) | ⬜ | C | 2026-10-09 盤點新增:顆粒材料(砂)、熱傳導與相變、電磁與磁力、植被風擺與互動 |
| 17.62 | [GPU 連續體與可微連續體(含可微盒 / 膠囊 / 凸包接觸)](#1762-gpu-連續體與可微連續體含可微盒--膠囊--凸包接觸--wave-c) | ⬜ | C | 2026-10-09 盤點新增:GPU 連續體解算器、可微可變形體與流體、盒 / 膠囊 / 凸包的可微碰撞 |
| 17.63 | [模擬輸出、烘焙快取與稀疏體積](#1763-模擬輸出烘焙快取與稀疏體積--wave-c) | ⬜ | C | 2026-10-09 盤點新增:流體表面重建輸出、模擬烘焙與快取回放、OpenVDB / NanoVDB式稀疏體積 |

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

#### 17.55 連續體共用步進契約(審計 F25) — Wave B

> **緣起**:2026-10-09 負空間盤點,合併 3 筆:連續體解算器接入世界步進、布料與剛體 / 碰撞體雙向碰撞、軟體睡眠。
> 審計 F25(`docs/audits/2026-09-27-architecture.md:96`)記下:可變形體求解器各帶自己的
> 地板與重力、API 是整段 rollout 形狀,沒有共用的 world / step 契約,力場與浮力無處可接;
> 建議 17.27 開工時定一個最小 `step(dt, gravity, colliders)` 契約。grep `F25` 於
> `docs/ROADMAP.md` 零命中,17.27 / 17.28 落地時只接了 `ContactScene6` 的剛體。
> 17.5「決定」記「軟體不睡,壓在其上的碎片也保持清醒」,同樣沒有條目接手。
> **現況**:接進世界的只有兩種。XPBD 晶格軟體走 `physics/soft_couple.mojo:46`
> `softbody_pass`(粒子對 `ColliderSet` 推出,hull / trimesh / heightfield 經
> `collision/collider_set.mojo:530` `soft_particle_contact`,等大反向衝量回饋剛體,
> `soft_couple.mojo:152-154` 喚醒睡眠體),由 `physics/solver6.mojo:1341` 在子步內呼叫,
> 並由 `write_state`(`:1410`,軟體段 `:1507-1525`)進 6.10 快照;繩索
> `physics/rope.mojo:134-136` `step(sc, dt, gravity, ...)` 以 `sc.overlap_sphere`(`:188`)
> 推出粒子。其餘六個求解器各自封閉:`physics/fem.mojo:321` `step(dt, gravity, floor_y)`
> (地板夾回 `:349-350`);`physics/mpm.mojo:107` `step(dt, gravity)`,邊界是格網 3 格
> 黏壁(`:221`);`physics/pbf.mojo:211` `_clamp_to_box`;`physics/sph.mojo:42` 靜態
> `BoundaryParticles`(`:76` 只建地板);`physics/gpu_cloth.mojo:213-216`
> `cpu_cloth_run[W, H](steps, ...)` 與 `physics/vbd_cloth.mojo:254` `cpu_vbd_run` 是
> 整段 rollout,回傳只含位置的 `ClothState`(`gpu_cloth.mojo:192-197`),地板寫死在
> kernel(`gpu_cloth.mojo:158`、`vbd_cloth.mojo:109`)。這六者不 import `collision`
> 套件或 `BodySet`。力場與浮力只作用於剛體:`physics/fields.mojo:3` 對 `ContactScene6`
> 施加,`apply_fields` 與 `apply_buoyancy` 只迴圈 `sc.bset.bodies`(`:146`、`:244`),
> 已接上世界的晶格軟體也收不到風。`gameplay/runtime.mojo:48` 只步進 `ContactScene6`;
> `write_state` 不含那六者。數值失敗隔離只有剛體:`solver6.mojo:929`
> `_quarantine_nonfinite` 是引擎內唯一遞增 `NAN_QUARANTINED`(`diag/counters.mojo:27`)
> 的地方,FEM 只有 `CG_NOT_CONVERGED`(`physics/fem.mojo:111-115`)。軟體沒有睡眠狀態
> (grep `sleep` 於 `physics/softbody.mojo` 只命中 `:15`「喚醒剛體」的說明),但
> `:136` `max_speed()` 可當入睡判據。`docs/SOTA_GAP_ANALYSIS.md:151` 第 9 列
> 「deformables 雙向耦合 ❌」只被 6.1 回答;「編輯器邊界分類」(I) 表的「軟體 / 布料 / 繩」列
> 標 ✅,指的是求解器本身,不是接進世界。
> **缺口**:
> - **共用步進契約**:`Deformable` trait —— `step(dt, gravity, scene view)`(view =
>   `ColliderSet` + `BodySet` + 力場 / 水體積)、`aabb()`、粒子 / 節點位置匯出、
>   `write_state` / `read_state`;FEM / MPM / PBF / SPH / 兩種布料以轉接層實作,原本的
>   `floor_y` / 夾盒 / rollout API 保留為特例。場景以型別參數持有各型別清單,編譯期選擇,
>   不做執行期多型。例:PBF 水窪繞過場景裡的 hull 石頭流走,而不是撞上看不見的盒壁。
> - **對碰撞器的接觸(單向)**:粒子 / 節點對 box / sphere / capsule / hull / trimesh /
>   heightfield 推出 + 摩擦,共用 `soft_couple` 的逐形狀尾端與 `soft_particle_contact`;
>   MPM 走格網節點對碰撞器的速度投影。例:FEM 輪胎落在 trimesh 坡道上停住。
> - **布料與剛體雙向碰撞**:布料粒子推出時以等大反向衝量回饋動態剛體並喚醒(與 6.1
>   晶格同式)。例:披風搭在角色膠囊上、旗幟纏住旗桿、床單蓋住的箱子被壓住。
> - **力場 / 浮力接上**:17.27 `ForceField`(風、阻尼、重力區)與 17.28 `WaterVolume`
>   逐粒子作用於可變形體(含已在場景裡的 6.1 晶格軟體)。例:同一個風區把布、PBF 噴濺
>   與剛體一起吹偏。
> - **世界整合**:`gameplay/runtime.mojo` 步進可變形體;6.10 快照涵蓋它們;步末偵測
>   NaN / 發散 → 隔離該物體 + `NAN_QUARANTINED` 計數(`docs/ARCHITECTURE.md:64`)。
>   例:一塊 FEM 爆掉不讓整個關卡停住。
> - **軟體睡眠**:依最大粒子速度 + 計時器入睡,納入島級喚醒與 17.25 `wake` /
>   `set_can_sleep`。例:一堆靜止的果凍方塊不再耗 CPU,壓在上面的碎片(17.5)也能睡。
> **對照組**:PhysX 5(FEM 軟體 + PBD 粒子 + 剛體同一 `PxScene`)、Jolt(`SoftBody` 在同一
> `PhysicsSystem`,可睡)、UE5 Chaos、MuJoCo 3 flex、Genesis;本庫內部對照:6.1 晶格軟體
> 與 17.41 繩索是已接上世界的兩個樣板。
> **優勢區**:低-中 —— 主要是接線工程。可量的加值:6.10 決定論快照擴到所有可變形體後,
> 17.39 回放與 17.40 存檔對混合場景成立。17.41「進度」記:把剛體當無限質量錨點回饋反作用
> 衝量時張力被高估到 160 N(應為 19.6 N),所以雙向耦合要用動量守恆測試把關。
> **規模軸**:各求解器粒子 / 節點數 × 場景碰撞器數(每粒子窄相查詢成本);靜止可變形體數
> × 睡眠比例。
> **seam?**:是 —— 新 seam「邊界來源」:舊的自帶邊界(`floor_y`、`_clamp_to_box`、kernel
> 內地板)vs 契約路徑 + 等價的靜態碰撞器(一塊地板盒或六面牆盒)→ parity:同場景粒子軌跡
> 逐位相同或在 ε 內(夾回與推出的差異照實記錄);軟體睡眠開 / 關 → parity:入睡前逐位相同。
> bench row:契約路徑每步額外成本(碰撞器查詢);靜止果凍堆入睡前後每步成本。
> CATEGORY.md §2 補一列。
> **交付**:普通(FEM 方塊落在 hull 上靜置;PBF 水在六面碰撞器盒中,對照舊
> `_clamp_to_box`;布蓋在膠囊上)/ 整合(`gameplay/runtime` 步進「剛體 + 晶格軟體 + FEM +
> 布 + PBF」混合場景;17.27 風區同時吹布與剛體;快照存讀後逐位續跑;碎片壓在睡著的軟體上
> 一起入睡;零重力下布-剛體碰撞的總動量守恆)/ 極端(零粒子;dt = 0;碰撞器生成在粒子群
> 內部;注入 NaN → 該物體隔離、其餘照常步進、計數器有變動;布粒子單子步位移大於厚度;
> 睡著的軟體被瞬移剛體撞醒)。新測試 `test_deformable_contract`、`test_soft_sleep`。
> **相依**:17.27、17.28(力場與浮力的掛點)、6.1 / 6.7 / 6.9(`soft_couple` 推出與摩擦
> 尾端)、6.10(快照)、17.41(`Rope.step` 是契約形狀的先例)、17.25(睡眠 API)、
> 17.31(凍結可套到可變形體)、17.0h(NaN 隔離政策)、17.13(場景查詢);
> 解鎖 17.56、17.58、17.59、17.62。

#### 17.56 布料完整化(綁骨架、彎曲、任意網格、空氣動力、CCD、撕裂) — Wave B

> **緣起**:2026-10-09 負空間盤點,合併 6 筆:布料綁骨架、布料彎曲剛度、任意三角網格布料與膜材料、布料空氣動力、布料連續碰撞、布料撕裂與軟體切割。
> 其中兩項已在文件中點名但未編號:連續碰撞是 15.2「明說的缺口」(`physics/self_collide.mojo:14-16`:
> 擋不住高速邊在一步內穿過兩頂點之間,需要 `collision/toi.mojo` 的掃掠);風作用於布是審計
> F25 的一部分(`docs/audits/2026-09-27-architecture.md:96`,力場與浮力無處可接)。其餘四項零文件。
> **現況**:兩個布料解算器都是 W×H 格點:`physics/gpu_cloth.mojo:3-6`(結構距離約束、
> 每粒子 ≤ 4 鄰居、地板、釘住頂行);`physics/vbd_cloth.mojo:29` 沿用同一個 `init_grid`,
> `:34` 只有單一彈簧常數 `_K`,`:7-9` 的平行度來自格點專用的棋盤 2 著色。唯一的附著是頂行
> 逆質量 0(`gpu_cloth.mojo:240`、`vbd_cloth.mojo:281`)。grep `bend|dihedral` 於兩檔零命中;
> grep `tether|long.?range|backstop|skinned.?constr`、`garment|membrane`、`aerodynamic`
> 於 docs / README 皆零命中。自碰撞(15.2)是頂點-頂點排斥;`collision/toi.mojo:42` 只有
> OBB 的 `swept_box_toi`,沒有頂點-三角形 / 邊-邊掃掠。斷裂只存在於繩段
> (`physics/rope.mojo:13-14` `break_tension`)與剛體關節 / 焊接(17.29 / 17.5);grep
> `\btear(s|ing)?\b|撕` 於 docs 只命中 17.29「缺口」的「撕裂 ragdoll」(關節斷裂)。力場只作用於
> 剛體(`physics/fields.mojo:3`、`:146`),布料只有重力(`gpu_cloth.mojo:29` `_G`)。
> **缺口**:
> - **綁骨架**:逐頂點的動畫目標由蒙皮網格給出(`geometry/skinning.mojo:57` `skin_motor`),
>   加 max-distance 球、backstop 球(把布保持在身體外側)、long-range attachment 拴繩
>   (每頂點到最近釘點的最大距離,少迭代也不伸長)。例:角色奔跑時裙擺與披風跟隨且不被拉長。
> - **彎曲剛度**:相鄰三角形的二面角約束或 isometric bending(Bergou 2006),XPBD 與 VBD
>   各一份。例:皮革與帆布維持外形、絲綢垂墜。
> - **任意三角網格 + 膜材料**:由三角索引緩衝建布(VBD 改用一般圖著色,沿用 6.11 的貪婪
>   著色),三角形 FEM 膜(StVK)含經 / 緯向各向異性拉伸與剪切(Baraff-Witkin 1998)。
>   例:剪裁好的襯衫網格取代 W×H 格點。
> - **空氣動力**:逐三角形依相對風速計算法向拖曳、切向拖曳與升力;風取自 17.27
>   `ForceField` WIND 或 `WindGrid`(`physics/fields.mojo:75`,可由 LBM 填)。
>   例:旗幟飄動、披風被風鼓起。
> - **連續碰撞**:頂點-三角形與邊-邊 CCD(Bridson 2002,三次共面方程求根),用於自碰撞
>   與薄碰撞器,符號判斷走 `geometry/predicates.mojo:229` `orient3d`。
>   例:甩動的披風邊不穿過自己,也不穿過薄劍刃。
> - **撕裂 / 切割**:約束超過應變門檻或被射線 / 平面切到時斷開,沿斷邊分裂頂點、更新
>   拓撲,斷裂事件送 17.38;同一機制用於 6.1 晶格軟體的邊切割。例:帆被子彈打穿後撕開、
>   果凍被刀切成兩半。帶損傷模型的連續體斷裂屬 17.58。
> **對照組**:UE5 Chaos Cloth(MaxDistance、Backstop、Long Range Attachment、aerodynamics
> drag / lift)、Jolt soft body(SkinnedConstraint、LRA、dihedral bend)、PhysX 5 cloth、
> Unity Cloth、Houdini Vellum(可斷約束)、Obi Cloth(tearable);論文 Baraff-Witkin 1998、
> Bridson 2002、Bergou 2006、Kim 2012(LRA)。本庫對照:XPBD vs VBD seam
> (`docs/CATEGORY.md:52`)、自碰撞跨兩解算器(`:142`)。
> **優勢區**:中 —— 每種新約束在 XPBD 與 VBD 兩個下降子上各實作一次,既有 seam 直接給出
> parity 與成本對照(15.2 已立此慣例);附著目標由 motor DLB 蒙皮給出,關節扭轉時目標不塌
> 陷(範例 07 的 candy-wrapper 對照);CCD 走 10.1 精確謂詞,共面與退化輸入的符號穩健;
> 風可取 LBM 填的 `WindGrid`,不是手調噪聲。撕裂本身低 —— 純工程。
> **規模軸**:頂點數(10³ → 10⁵)× 迭代數;彎曲剛度掃描(絲 → 皮革)下的下垂與摺痕;
> 三角形數 × 風速;甩動速度掃描下 CCD 開關的穿透數與成本;每幀撕裂事件數。
> **seam?**:是 ——(a)長度保持:純迭代 vs LRA 拴繩 → parity:迭代數足夠時伸長量收斂到
> 同值;bench:同伸長上限下的迭代成本。(b)彎曲模型:二面角 vs isometric → parity:小角度
> 下同一下垂形狀,彎曲剛度 0 時與現行逐位相同。(c)網格來源:W×H 格點 vs 三角網格建構器
> → parity:以三角網格餵入同一格點拓撲時逐位相同。(d)自碰撞:頂點-頂點(15.2)vs 連續
> VT / EE → parity:慢速場景結果集一致;bench:甩動場景成本。各入 CATEGORY.md 與
> BENCHMARK_REPORT 一列。
> **交付**:普通(披風掛在動畫角色肩上行走;皮革與絲綢掛在同一根桿上;襯衫網格靜置;旗幟
> 在定風中飄;布被射穿後撕開)/ 整合(角色跑跳動畫 + 17.55 膠囊碰撞 + backstop 驅動裙擺,
> 伸長 < 10%;LBM `WindGrid` 吹旗;撕裂事件經 17.38 到 gameplay;撕裂後的拓撲進快照並
> 逐位續跑)/ 極端(骨架瞬移、單影格大位移 —— LRA 限住伸長且不爆;彎曲剛度近無限的板;
> 零面積三角形、非流形網格;CCD 的共面與平行邊;一步內撕成大量碎片;風速 0 與極大)。
> 新測試 `test_cloth_skinned`、`test_cloth_bend`、`test_cloth_ccd`、`test_cloth_tear`。
> **相依**:17.55(碰撞器接觸、雙向衝量、力場掛點)、15.2(自碰撞)、4.3(VBD)、3.2
> (GPU 布)、17.27(風)、11.3 / 17.6 / 17.3(動畫姿勢與蒙皮)、10.1(精確謂詞)、6.11
> (著色)、17.29 / 17.41(斷裂門檻慣例)、17.38(斷裂事件);解鎖 17.58 薄殼、
> 17.59 流體-布耦合、17.62 GPU / 可微布料。
> **邊界**:核心輸出頂點位置,撕裂後輸出新的三角索引與「新頂點 ← 原頂點」對應表;法線 /
> 切線重建、UV 接縫處理與繪製在宿主。

#### 17.57 毛髮、彈簧骨與肌肉次級動力學 — Wave C

> **緣起**:2026-10-09 負空間盤點,合併 4 筆:毛髮與髮束模擬、骨架彈簧骨(次級運動,continuum 與 anim 兩域重複記錄)、體積肌肉與肉體次級動力學、Hill 肌肉力-長度 / 力-速度曲線與肌腱柔度。
> **現況**:grep `hair|strand|毛髮|頭髮` 於 docs / README 零命中,程式碼只有「a hair of
> back-off」這類用語(`physics/ccd6.mojo:25`);grep
> `spring.?bone|jiggle|dynamic.?bone|AnimDynamics|彈簧骨|次級運動` 於 docs 零命中,grep
> `spring.?bone|jiggle|dynamic.?bone|secondary` 於 `procedural/` `gameplay/` `physics/`
> 零命中。最接近的零件:`physics/rope.mojo:30` `Rope` 是 XPBD 1D 鏈,無彎曲 / 扭轉
> (Cosserat 桿列在 17.41「進度」所附「待辦」);`procedural/anim_graph.mojo:45`
> `Pose` 與 `:313` `Skeleton`(父索引 + 靜止偏移)是彈簧骨可以吃的資料。今天唯一把動畫
> 姿勢接到物理的是 17.2 `Ragdoll.follow`(`gameplay/ragdoll.mojo:98`):每骨一個剛體盒
> (`:4-5`),動畫骨以 `move_to` 運動學跟隨,模擬骨由 `AngularDrive`
> (`physics/joints6.mojo:279`,建於 `ragdoll.mojo:93`)拉向動畫姿勢,走完整剛體求解器,
> 不是便宜的次級運動層。肌肉:`physics/actuator.mojo:70-80` `muscle()` 只有不對稱啟動
> 延遲 × `f_peak`,無長度 / 速度項;13.3「設計」的範圍明寫只做「Hill 型肌肉的啟動動力學」,
> grep `force.?length|force.?velocity` 於 docs 零命中。肉體:Ziva 只出現在 Phase 15 起因的
> 對照家族名單;FEM 節點只能 `pin`(`physics/fem.mojo:148`,逆質量設 0),沒有讓節點跟隨
> 骨骼的運動學驅動。
> **缺口**:
> - **彈簧骨 / 次級運動**:動畫姿勢之上的逐骨彈簧-阻尼(或 verlet 粒子)鏈 —— 骨長保持、
>   角度限制、重力與根運動帶來的慣性、骨骼空間的球 / 膠囊碰撞體。放在 `procedural`
>   (層 2,只依賴 `geometry`,吃 `Pose` / `Skeleton`);要對場景碰撞器時由 `gameplay` 轉接。
>   例:角色急轉時馬尾、尾巴、耳環、天線甩動,不必跑布料、軟體或布娃娃。
> - **毛髮 / 髮束**:導引髮束為離散彈性桿(DER / Cosserat,彎曲 + 扭轉),根部綁頭部骨骼,
>   對頭 / 身體碰撞體推出;髮束間摩擦與體積排斥(段-段配對,或格網密度 / 速度平滑)。
>   例:由數千根導引髮組成的馬尾與動物毛。
> - **體積肉體次級動力學**:以 FEM 四面體網格包覆骨架,骨骼附近節點運動學跟隨骨骼,肌肉
>   沿纖維方向的主動應力使其收縮時膨起,受衝擊時晃動。例:手臂出力時二頭肌鼓起、落地時
>   腹部晃動。
> - **Hill 肌肉力-長度 / 力-速度曲線 + 肌腱柔度**:`DYN_MUSCLE` 的力乘上 f_L(纖維長度)×
>   f_V(收縮速度),加被動彈性 f_PE;肌腱可剛性或柔性(Millard 2013 平衡式)。長度與速度
>   取自關節座標或腱長(`physics/tendon.mojo:78,84` `FixedTendon.length` / `velocity`、
>   `:211` `SpatialTendon.length`)。例:手臂伸直與彎曲時能舉的重量不同,快速揮動時出力下降。
> **對照組**:彈簧骨 —— VRM SpringBone、Godot 4.4 `SpringBoneSimulator3D`、UE AnimDynamics /
> Kawaii Physics、Unity Dynamic Bone / Magica Cloth;毛髮 —— UE5 Groom(Niagara strands)、
> AMD TressFX、Frostbite strand hair、Houdini Vellum hair、Bergou 2008(DER);肉體 —— Ziva
> Real-Time、UE5 Chaos Flesh;肌肉 —— MuJoCo muscle(FLV 曲線)、OpenSim(Millard 2013)。
> 本庫對照:17.41 XPBD 繩、17.2 主動布娃娃。
> **優勢區**:中 —— 彈簧骨的旋轉在 rotor / motor 上積分(`geometry/galie.mojo:116`
> `geodesic3`,與 4.1b 變分積分子同路線),大角度甩動沒有 gimbal 與正規化漂移;髮束的材料
> 框架(Cosserat director)以 rotor 表示,扭轉沿桿傳遞由代數直接表達;彈簧骨的剛度 / 阻尼可用
> 既有 AD(3.1 / 4.2)對錄製軌跡擬合。髮束間互動與大規模肉體 FEM 是純工程與算力,低。
> **規模軸**:彈簧骨 —— 角色數 × 每角色骨數(10² → 10⁴ 角色);毛髮 —— 導引髮束數 ×
> 每束節點數 × 互動開關;肉體 —— 四面體數 × 子步;肌肉 —— 致動器數(每步 ns,同 13.3 bench)。
> **seam?**:是 ——(a)次級運動實作:彈簧骨(角度空間)vs XPBD 粒子鏈(17.41 `Rope` 改掛
> 動畫骨)vs 主動布娃娃骨(17.2)→ parity:單骨小振幅下三者的自然頻率與阻尼比都對上阻尼
> 振子解析解,無彎曲剛度的多骨鏈靜止形狀一致;bench:每骨每步成本。(b)髮束模型:XPBD
> 1D 鏈 vs DER / Cosserat → parity:彎曲 / 扭轉剛度 0 時兩者都對上懸鏈線(沿用 `test_rope`
> 場景);互動強度 0 時與無互動逐位相同。(c)肌腱:剛性 vs 柔性 → parity:肌腱剛度 → ∞ 時
> 柔性解收斂到剛性解;f_L = f_V = 1 且無 f_PE 時與現行 `DYN_MUSCLE` 逐位相同。肉體不另開
> seam,是 17.58 本構 seam 的消費者。
> **交付**:普通(馬尾隨轉頭甩動後回到靜止;單根髮束在重力下垂;二頭肌收縮鼓起;等長收縮
> 的力隨長度變化對上 f_L 曲線)/ 整合(17.6 動畫圖驅動的奔跑 + 急停,彈簧骨尾巴不穿入身體
> 膠囊;髮束對頭部膠囊碰撞 + 17.27 風;肉體 FEM 隨 17.3 IK 姿勢變形;Hill 肌肉驅動關節鏈
> 屈肘,與 13.3 的啟動延遲共存)/ 極端(骨架瞬移、根部一幀翻轉 180°;零長骨;剛度 0 與
> 極大;髮束全部重疊;肉體四面體反轉;收縮速度超過最大值、纖維長度超出曲線範圍 → 夾限
> 且保持有限)。新測試 `test_spring_bone`、`test_hair_strand`、`test_muscle_flv`。
> **相依**:17.41(繩與 Cosserat 待辦,髮束的基礎)、17.2(布娃娃為對照)、11.3 / 17.6 /
> 17.3(姿勢來源)、17.55(碰撞器接觸與契約)、17.58(四面體化與超彈性 / 纖維材料,肉體
> 的前提)、13.3 / 13.4(致動器、腱長)、17.31(遠處角色關掉次級運動);與 17.64(骨骼
> 插槽)、17.65(姿勢空間修正與學習式變形器掛點)互補。
> **邊界**:髮絲渲染、由導引髮插值出的渲染髮與其 LOD、蒙皮網格繪製在宿主;核心輸出導引
> 髮束節點位置與材料框架、彈簧骨調整後的 `Pose`、肉體節點位置(資料)。學習式變形器
> (ML Deformer 類)需要神經網路推論,核心不含推論執行期(與 2026-10-09 排除 RL /
> 機器人同一界線);其外部掛接點歸 17.65,FEM 肉體可作為該變形器的離線參考資料。

#### 17.58 體積軟體完整化 — Wave C

> **緣起**:2026-10-09 負空間盤點,合併 7 筆:任意網格體積軟體(四面體化 + 嵌入網格)、超彈性與各向異性材料、形狀匹配軟體、壓力(充氣)軟體、軟體互撞與體積自碰撞、可變形體彈塑性斷裂、薄殼與塑性彎曲。
> **現況**:`physics/softbody.mojo:67` `box_lattice`(n³ 晶格)是 `SoftBody` 唯一的形狀
> 建構子(`:58` `__init__` 為空體);FEM 的 `add_node` / `add_tet`(`physics/fem.mojo:136,151`)
> 接受任意手建四面體網格,但唯一的網格產生器是 `make_beam`(`:491`);沒有把表面網格
> 四面體化,也沒有把渲染網格嵌入模擬網格(grep `tetrahedrali|tetgen|tetwild|四面體化`
> 於 docs 零命中)。17.5 的 `geometry/convex_decomp.mojo:101` `voxelize` 能把封閉網格
> 體素化,但沒有軟體使用它。本構:`fem.mojo:1` 是 co-rotational 線性,MPM 是
> fixed-corotated(`physics/mpm.mojo:147`);grep `neo.?hook|stvk|hyperelastic|anisotrop`
> 於 docs 零命中。grep `shape.?match|形狀匹配` 於 docs 與程式碼零命中;grep
> `balloon|inflat|氣球` 只命中 6.7「進度」(CCD 的「充氣球」,無關);
> `softbody.mojo` / `soft_couple.mojo` 無 `pressure`。軟體粒子只對 `ColliderSet` 測試
> (`physics/soft_couple.mojo:105-107`;`:64` 的逐軟體迴圈沒有軟-軟 pass),15.2 自碰撞
> 只給布。斷裂:`physics/fracture.mojo:1-7` 的碎片是剛體 hull;MPM 的暫時格網允許材料
> 分離(`mpm.mojo:7-9`)但沒有損傷狀態;grep `damage|ductile|crack` 於 docs 零命中。
> 薄殼:grep `thin.?shell|薄殼|crumple` 零命中;17.4 的車是一個剛體盒(17.4「進度」)。
> **缺口**:
> - **任意網格體積軟體**:表面網格 → 四面體網格(穩健四面體化,fTetWild 類;或以 `voxelize`
>   產生晶格),渲染 / 碰撞網格以重心座標嵌入模擬網格。例:輪胎、生物、座墊直接由美術網格
>   變成軟體,不必是 n³ 方塊。
> - **超彈性與各向異性材料**:StVK、Stable Neo-Hookean(Smith 2018,反轉四面體仍有恢復力)、
>   纖維強化(肌肉、木材方向)。例:被壓到很扁的果凍保持體積並彈回;木條沿紋理方向較硬。
> - **形狀匹配軟體**:無網格的區域形狀匹配(Müller 2005),無條件穩定、便宜,同一機制給出
>   粒子系統裡的剛體團簇。例:遊戲裡的果凍道具、可擠壓的靠墊。
> - **壓力 / 充氣軟體**:封閉表面的體積-壓力約束(理想氣體 PV = 常數,或目標體積)。
>   例:氣球、海灘球、氣墊、受撞擊凹陷後回彈的軟輪胎。
> - **軟-軟碰撞與體積自碰撞**:粒子對另一軟體的表面三角形 / 四面體,同一軟體折疊時不互穿。
>   例:兩塊果凍疊起來互相壓扁、長條軟體打結。
> - **可變形體彈塑性斷裂**:FEM / MPM 的損傷累積與裂紋(CD-MPM、O'Brien-Hodgins 1999 的
>   FEM 斷裂),超出 17.5 預切的剛體碎片。例:被彎折的鈑金撕開、MPM 麵包被拉斷。
> - **薄殼與塑性彎曲**:殼元素彎曲能(Grinspun 2003 discrete shells)+ 塑性屈服(超限彎曲時
>   更新靜止二面角)。例:車門被撞凹後保持凹陷、金屬板皺折;這是軟體車損的核心。
> **對照組**:PhysX 5 FEM 軟體(tet cooking、嵌入碰撞網格、Neo-Hookean)、Jolt soft body
> (四面體體積約束、壓力)、UE5 Chaos Flesh、Godot `SoftBody3D`、TetGen / fTetWild、
> NVIDIA FleX 與 Obi Softbody(形狀匹配)、Houdini Vellum(氣球、塑性)、Pixelux DMM、
> BeamNG.drive(node-beam 車損);論文 Müller 2005、Smith 2018、Wolper 2019(CD-MPM)、
> Grinspun 2003。本庫對照:6.1 XPBD 晶格、FEM 線性 vs co-rotational(`docs/CATEGORY.md:139`)、
> MPM 彈性 vs 塑性(`:140`)。
> **優勢區**:中 —— FEM 已有隱式步(`step_implicit`,`fem.mojo:227`,15.1 CG)與線性 /
> co-rotational 兩個變體,新本構是同一 seam 多一個變體,不是新求解器;四面體化與裂面可走
> 10.1 精確謂詞(`geometry/predicates.mojo:229` `orient3d`、`:356` `insphere`),17.5 的
> `polytope` 以邊鍵共用索引保持 watertight,但符號判斷仍是 epsilon 帶(改走 `orient3d`
> 列在 17.5「待辦」);形狀匹配的最佳旋轉可直接用 FEM / MPM 共用的
> `polar_rotation`(`fem.mojo:64`)。充氣與薄殼低 —— 純工程。
> **規模軸**:四面體數或晶格解析度 × 子步;壓縮比(J 從 1 掃到 0.1 再到反轉)下的體積誤差
> 與成本;軟體數 × 接觸對數;裂紋 / 碎片數;殼三角形數 × 每幀凹陷事件。
> **seam?**:是 ——(a)本構:線性 / co-rotational / StVK / Stable Neo-Hookean / 纖維 →
> parity:小應變下懸臂梁尖端撓度對同一 Young / Poisson 一致(沿用 `test_fem` 場景);
> bench:每四面體每步成本。(b)體積軟體離散:XPBD 晶格(6.1)vs FEM 四面體 vs 形狀匹配 →
> parity:同一方塊落地靜置的質心高度在容差內、零重力動量守恆;bench:同精度下成本。
> (c)模擬網格來源:體素晶格 vs 四面體化 → parity:體積對 `mesh_volume`
> (`geometry/convex_decomp.mojo:183`)誤差在數 % 內。壓力 0、軟-軟碰撞關、損傷關、屈服
> 無限大時各自與現行逐位相同(開關式 parity,同 15.2 慣例)。各入 CATEGORY.md 一列。
> **交付**:普通(美術網格四面體化後落地;Neo-Hookean 方塊壓到 10% 後彈回;氣球受壓凹陷
> 後回復;兩塊果凍堆疊;鈑金彎折後保持彎角)/ 整合(四面體化軟體經 17.55 契約與剛體雙向
> 碰撞並進快照;充氣輪胎裝在 17.4 車上;MPM 撕裂與 FEM 斷裂的碎片進 17.5 碎片預算與睡眠;
> 車體薄殼面板被剛體撞凹)/ 極端(非流形或有洞的輸入網格 → 拒絕或修補並回報;全反轉
> 四面體;零體積氣球;初始時兩軟體完全互相嵌入;一步內大量裂紋;屈服應力 0)。
> 新測試 `test_tetmesh`、`test_hyperelastic`、`test_soft_pressure`、`test_soft_soft`。
> **相依**:17.55(契約、碰撞器、快照、睡眠)、6.1、15.1(CG,隱式 FEM)、10.1(精確
> 謂詞)、17.5(`voxelize`、`polytope`、碎片管理)、17.29(斷裂事件慣例)、17.56(彎曲約束
> → 薄殼;布撕裂 → 晶格切割)、17.4(充氣輪胎、車損)、17.84(稀疏直接解與多重網格可加速
> 隱式 FEM);17.57 的肉體以此為前提。
> **邊界**:核心輸出嵌入網格的頂點位置與斷裂後的新索引;法線重建與繪製在宿主。

#### 17.59 流體-固體雙向耦合 — Wave C

> **緣起**:2026-10-09 負空間盤點,合併 6 筆:SPH / PBF 與剛體雙向耦合、LBM 與運動剛體雙向耦合、MPM / FEM 與剛體雙向耦合、流體-布料耦合、剛體流體力模型、統一粒子物理。
> Phase 14 起因查證 `physics/pbf.mojo` / `physics/sph.mojo`「零固體耦合」;17.42「進度」(d)
> 只補了靜態地板邊界粒子,17.42「進度」所附「待辦」只列牆面取樣與格網鄰居搜尋,沒有運動或
> 動態物體。17.28「進度」所附「待辦」的「LBM 阻力耦合」,依 17.28「優勢區」是把 14.4 的
> 阻力係數餵給浮體,屬單向。
> **現況**:PBF / SPH 只 import `std.math`、`geometry.vec` 與彼此(`pbf.mojo:34-35`、
> `sph.mojo:27-29`),邊界是 `_clamp_to_box`(`pbf.mojo:211`)與靜態 `BoundaryParticles`
> (`sph.mojo:42`,Akinci 2012)。LBM 固體是靜態旗標(`fluid/lbm.mojo:185` `set_solid_box`、
> `:197` `set_solid_sphere`),動量交換累積成所有固體共用的一個總力(`:76-78` `fx` /
> `fy` / `fz`),沒有逐物體的力與力矩;引擎套件中 LBM 在 `fluid/` 外唯一的使用者是
> `gameplay/vehicle_tunnel.mojo:21`,預先算 Cd 再單向交給車(17.4)。MPM
> `step(dt, gravity)`(`physics/mpm.mojo:107`)與 FEM `step(dt, gravity, floor_y)`
> (`physics/fem.mojo:321`)不 import 任何剛體或碰撞模組;布與 PBF 不共享狀態
> (`physics/gpu_cloth.mojo:18-26` 的 import)。剛體端的流體力只有 17.27 線性 `WIND` /
> `DRAG`(`physics/fields.mojo:14-18`)、17.28 依浸沒比例的線性 / 角阻尼(`:20-23`),與
> 車輛專用的二次阻力 + 下壓力(`gameplay/vehicle.mojo:126-136` `Aero`)。grep
> `moving.?bound|運動邊界|fluid.?structure|流固`、`added.?mass|magnus|kutta`、
> `unified particle|統一粒子` 於 docs 皆零命中;FleX 只出現在 17.41「對照組」;
> `docs/SOTA_GAP_ANALYSIS.md:85-89` 的 AVBD 統一的是剛體與可變形體,不含流體。
> **缺口**:
> - **SPH / PBF ↔ 剛體雙向**:動態剛體表面取樣為移動邊界粒子(Akinci 2012),流體對邊界
>   粒子的壓力與摩擦累加成剛體的力與力矩,剛體排開流體。例:箱子浮在 PBF 池中上下起伏、
>   石頭落水濺起水花。
> - **LBM ↔ 運動剛體**:帶壁速項的移動壁 bounce-back(Ladd 1994)、固體移開後新流體格的
>   重填、逐物體的動量交換力與力矩,每步回饋剛體。例:落葉被自己擾動的氣流推著走、球在
>   通道中下沉到終端速度。
> - **MPM / FEM ↔ 剛體雙向**:MPM 格網節點對剛體做速度投影,衝量回饋剛體(Hu 2018 CPIC
>   類);FEM 節點與剛體的接觸衝量雙向。例:車輪陷進 MPM 泥地壓出車轍,泥同時拖住車輪。
> - **流體-布耦合**:流體粒子對布三角形碰撞與拖曳,布能盛水。例:防水布接住雨水、旗幟在
>   水流中擺動。
> - **剛體流體力模型**:不跑 CFD 的逐物體流體力 —— 二次阻力、附加質量、Magnus 與 Kutta 升力
>   (MuJoCo 流體力的 inertia / ellipsoid 兩種模型)。例:飛盤滑翔、旋轉的球劃出弧線、水下
>   物體加速時多出的附加質量。
> - **統一粒子求解器**:FleX 式單一粒子求解器,流體、布、繩、形狀匹配剛體同屬一套粒子並
>   雙向互動。例:布袋裝水、繩子綁住箱子。作為「分立求解器 + 耦合 pass」的對照端,不取代
>   既有求解器。
> **對照組**:Akinci 2012、PhysX 5 PBD 粒子 ↔ 剛體、NVIDIA FleX(Macklin 2014 Unified
> Particle Physics)、Genesis(SPH / MPM ↔ 剛體)、Hu 2018 MLS-MPM、Newton / Warp、
> waLBerla / Palabos 移動邊界 LBM(含 Noble-Torczynski PSM)、XLB、Houdini FLIP + Vellum、
> MuJoCo 流體力模型。本庫對照:17.28 `WaterVolume` 解析浮力、14.6 LBM 文獻驗證、6.1 晶格
> 軟體的雙向衝量(6.1「進度」:零重力動量守恆 0.03%)。
> **優勢區**:中高 —— LBM 這一支是本庫少數能對上文獻數值的方向(Phase 14 起因):運動邊界
> 接上後,Stokes 區落球的終端速度 v_t = 2(ρs − ρf) g r² / (9μ)、旋轉圓柱的 Magnus 升力都能
> 解析驗證,也能直接對照剛體流體力模型;GPU LBM(17.42a)與 Bouzidi 插值邊界(17.42b,
> `fluid/lbm.mojo:216` `link_q` 已能對真實球幾何求 q)是現成的。PBF 浮箱可對 17.28 的
> Archimedes 解析值做 parity,對照組多半沒有這類解析對照。統一粒子求解器本身低 —— 純工程。
> **規模軸**:流體粒子數或格數 × 耦合剛體數;剛體速度(每步移動幾格)對 LBM 重填誤差;MPM
> 格解析度 × 輪數;布三角形數 × 流體粒子數;剛體流體力模型每物體 ns。
> **seam?**:是 ——(a)剛體流體力來源:解析力模型 vs LBM 動量交換實測 → parity:低 Re 球
> 的阻力兩者都對上 Stokes 解析值且彼此在容差內;bench:每物體每步成本 vs MLUPS。(b)PBF /
> SPH 剛體邊界:移動邊界粒子 vs 既有 `sph_step_boundary`(`sph.mojo:95`)→ parity:剛體
> 不動時逐位相同;浮箱平衡吃水對 17.28 解析浮力在容差內。(c)耦合架構:分立求解器 + 耦合
> pass vs 統一粒子求解器 → parity:同一浮箱 / 布兜水場景的平衡態在容差內、零重力總動量
> 守恆;bench:同場景每步成本。各入 CATEGORY.md 與 BENCHMARK_REPORT 一列。
> **交付**:普通(箱子浮在 PBF 池中、吃水對上解析值;Stokes 區落球終端速度;輪子壓進 MPM
> 泥;布兜住 PBF 水;旋轉球的 Magnus 側偏)/ 整合(經 17.55 契約進 `ContactScene6` 與
> `gameplay/runtime`;17.4 的車開過 MPM 泥地;移動剛體擾動的 LBM 流經 `WindGrid`
> 吹動旁邊 17.56 的旗;快照存讀後續跑)/ 極端(比流體重很多 / 輕很多的物體;剛體每步
> 移動超過一格 → 子步或拒絕並計數;剛體佔滿整個流域;零質量剛體;流體粒子生成在剛體
> 內部;零重力下流體 + 剛體總動量守恆)。新測試 `test_pbf_rigid`、`test_lbm_moving`、
> `test_mpm_rigid`、`test_fluid_force`。
> **相依**:17.55(契約)、17.42(GPU LBM、插值邊界、SPH 邊界粒子)、14.4 / 14.6(動量交換
> 與驗證)、17.27 / 17.28(風場與浮力;本項把 17.28 的單向 LBM 待辦升級為雙向)、17.4
> (車)、17.56(布)、17.58(形狀匹配,統一粒子求解器的剛體團簇);與 17.60(水面與網格
> 流體)、17.61(顆粒)、17.74(地面力學)互補,與 17.71(彈道阻力)共用剛體流體力模型。

#### 17.60 水面與網格流體(淺水・海浪・煙火・FLIP・多相・黏塑・爆炸波) — Wave C

> **緣起**:2026-10-09 負空間盤點,合併 7 筆:高度場水面 / 淺水方程、海浪與水流浮力水面、歐拉網格煙火、
> FLIP / APIC 液體、多相流與表面張力、非牛頓 / 黏塑流體、爆炸壓力波傳播。其中只有投影法
> Navier-Stokes 出現過,而且是假設語氣:「若日後要做投影法 Navier-Stokes 或隱式 FEM,15.1 是前提」
> (Phase 15 建議順序「與 Phase 14 的關係」);`numerics/sparse.mojo:9-11` 也把「pressure projection
> for Eulerian fluids」列為全域線性解的未來使用者;兩處都沒有編號。其餘子項在 docs / README
> 沒有規劃命中。
> **現況**:流體求解器有三個:`fluid/` D3Q19 LBM(二階截斷,`fluid/d3q19.mojo:91-92`
> 寫「incompressible Navier-Stokes to O(Ma^2)」)、`physics/pbf.mojo` PBF、
> `physics/sph.mojo` WCSPH;後兩者共用 `PbfFluid`,只有一個 `rho0`(`physics/pbf.mojo:92`)。
> 水面是 17.28 的 `WaterVolume`:「an AABB whose top face is the surface」
> (`physics/fields.mojo:20`),`apply_buoyancy` 以 `wv.hi[1]` 當常數水位(`:259`、`:262`),
> 沒有波浪也沒有流速(欄位只有 lo / hi / density / 兩個阻尼,`:181-186`)。爆炸是 17.27 的
> `RADIAL`:對 body 中心即時施力、線性衰減到 `radius`(`physics/fields.mojo:12-13`、
> `:154-158`,測試 `tests/test_fields.mojo:66-78`),沒有傳播時間、沒有遮擋,也與受力面積無關。
> SPH 把負壓夾掉(`physics/sph.mojo:21-24`)、黏度是常數 `_VISC`(`:32`);PBF 的
> `s_corr` 是防結團項、XSPH 是速度平滑(`physics/pbf.mojo:20-26`、`:46`),兩者都不是表面
> 張力或黏性本構。APIC 只在 MLS-MPM 固體裡(`physics/mpm.mojo:12-13`),沒有壓力投影。
> `numerics/cg.mojo` 的 `cg` / `pcg`(`:61`、`:73`)可當泊松後端,但 `numerics` 與 `fluid`
> 同為層 2(`scripts/arch_layers.toml:7,10`),`fluid` 不能 import 它;`numerics` 也沒有 FFT。
> grep `shallow|ripple|wave.?eq`(程式碼只有無關字面,如 `collision/hull.mojo:476`)、
> `gerstner|fft|tessendorf|ocean|swell|flow.?map`、`smoke|vorticity|semi.?lagrang|pyro|
> combust`、`surface.?tension|cohesion|adhesion|multiphase`、`non.?newton|viscoplast|
> yield.?stress|bingham|herschel`、`shock|衝擊波|blast wave|壓力波` 於 docs / README /
> 引擎套件,除上列外零命中(`cohesion` 只命中 17.15「增補」的 boids)。
> **缺口**:
> - **高度場水面 / 淺水方程**:2.5D 高度場上解 SWE(或 Müller 2008 的高度場波動方程),
>   含乾濕前緣、地形河床(讀 8.2 / 17.30 的 `HeightField`)、浮體排水造成的波與尾跡。
>   例:石頭落進池塘激起環狀漣漪、船尾拖出 V 形尾跡、潰壩水沿河谷流下。
> - **海浪與水流當浮力水面**:Gerstner 波組與 FFT 頻譜海面(Tessendorf 2001)、2D 流速圖,
>   提供任意點的水面高度 / 法向 / 流速查詢;`apply_buoyancy` 改由查詢取水位,流速進拖曳。
>   需新增 FFT 例程。例:小船隨湧浪俯仰、漂流物順河道漂走。
> - **歐拉網格煙與火**:stable fluids(Stam 1999)半拉格朗日平流 + 壓力投影 + 浮力 / 溫度 +
>   渦度約束(Fedkiw 2001)+ 燃料 / 燃燒的簡化反應。例:爆炸火球升起成蕈狀雲、車輛駛過
>   把煙霧推開。
> - **FLIP / APIC 液體**:粒子-格網混合 + 不可壓投影(Zhu & Bridson 2005、Jiang 2015),
>   時步比 WCSPH / PBF 大、耗散較低。例:大型潰壩、水桶傾倒濺出的水花。
> - **多相流與表面張力 / 內聚 / 附著**:Akinci 2013 式表面張力與壁面附著、不同密度比的
>   多相粒子(Ren 2014)。例:水滴在桌面凝成水珠、雨水沿牆面流下、油水分層。
> - **非牛頓 / 黏塑流體**:隱式高黏度(Takahashi 2015)與降伏應力(Bingham /
>   Herschel–Bulkley)本構。例:蜂蜜落下捲繞、熔岩緩慢流動、泥流停在斜坡上。
> - **爆炸壓力波**:以有限波速向外推進的壓力前緣(超壓 Friedlander 波形),經 17.13 射線
>   判遮擋、依迎風受力面積對物體加載;高保真對照端是可壓縮 Euler 格網解(震波捕捉)。
>   LBM 只到 O(Ma²)、不涵蓋震波,所以另立模型。例:掩體後的箱子不被吹動、走廊盡頭的門
>   晚一拍才被炸開。
> **對照組**:UE5 Water plugin(Gerstner + BuoyancyComponent)與 Niagara Fluids(Shallow
> Water、Grid 2D / 3D gas、3D FLIP)、Unity 6 HDRP Water System(FFT + CPU 水位查詢 + 流速圖)、
> Crest Ocean、Houdini Pyro / FLIP、EmberGen、FleX 與 PhysX 5 PBD 粒子(cohesion /
> surfaceTension / adhesion 參數);論文 Müller 2008、Tessendorf 2001、Stam 1999、
> Fedkiw 2001、Zhu & Bridson 2005、Jiang 2015、Akinci 2013、Ren 2014、Takahashi 2015、
> Yue 2015、Feldman 2003。本庫對照:17.28 平面水位、17.27 `RADIAL`、PBF 潰壩(`test_pbf`)、
> SPH / PBF 時步掃描(`bench_sph`)、14.6 LBM 驗證(剪切波衰減、音速)。
> **優勢區**:中 ——(a)決定論:海浪頻譜與 SWE 以固定 seed 逐位可重現,浮體在湧浪上的
> 軌跡可進 17.39 回放與 17.16 rollback,宿主渲染與物理查的是同一個函數;(b)可驗證:SWE
> 波速對 √(gh),煙的數值黏度可用 14.6 的剪切波衰減量出,爆炸波到達時間的線性極限可對
> LBM 音速脈衝(`tests/test_lbm_validation.mojo:18-19`);(c)求解器若寫成 `Field` 泛型,
> 煙的關鍵影格控制、波浪參數擬合可交給 17.62 微分。表面張力與黏塑本構本身低 —— 純工程。
> **規模軸**:高度場格數(128² → 2048²);海面查詢點數 × FFT 解析度;煙格數 × 投影迭代數;
> FLIP 粒子數 × 每格粒子數 × 時步;黏度 / 降伏應力對最大穩定時步;爆炸源數 × 受影響體數 ×
> 每體取樣點數。
> **seam?**:是 ——(a)水面來源:平面(現行)/ Gerstner / FFT / SWE → parity:振幅與流速
> 為 0 時 `apply_buoyancy` 結果與現行平面水位逐位相同;bench:每查詢點 ns。(b)液體求解器:
> PBF / WCSPH / FLIP 跑同一潰壩 → parity:質量守恆、前緣位置對 Martin & Moyce 1952 實驗
> 曲線在容差內、靜止水位一致;表面張力 / 附著係數 0 時退化為現行 PBF / SPH、降伏應力 0 時
> 退化為牛頓黏性,皆逐位相同;bench:每模擬秒成本對時步(沿用 `bench_sph` 的時步掃描)。
> (c)壓力投影後端:CG / PCG / 17.84 多重網格 → parity:散度殘差同容差、速度場在容差內;
> bench:格數掃描。(d)爆炸模型:`RADIAL` 即時 / 傳播前緣 + 遮擋 / 可壓縮 Euler → parity:
> 波速 → ∞、無遮擋、線性衰減時與 `RADIAL` 逐位相同,前緣到達時間與可壓縮解在容差內;
> bench:射線數與格數對成本。各入 CATEGORY.md 與 BENCHMARK_REPORT 一列。
> **交付**:先寫設計筆記(`docs/design/`,以 17.60 命名)定煙 / FLIP 放 `physics`(層 4,
> 可用 CG)或在 `fluid` 內自帶 matrix-free 解法。普通(池塘環狀漣漪波速對 √(gh);Gerstner
> 海面上的箱子隨波俯仰;煙柱受浮力上升;FLIP 潰壩前緣對實驗曲線;水滴靜置成珠、振盪頻率
> 對 Rayleigh 解;Bingham 通道流的塞流剖面對解析解;爆炸波到達時間 = r / c、牆後物體不受力)/
> 整合(浮體經 17.28 `apply_buoyancy` 查 FFT 海面並受流速拖曳;SWE 河床讀 17.30 變形後的
> `HeightField`;移動剛體推開煙,煙的速度場填成 17.27 `WindGrid`;爆炸波經 17.13
> `ray_cast_batch`(`collision/world_query.mojo:587`)判遮擋,驅動 17.5 破碎與 17.29 關節
> 斷裂;全部經 17.55 契約進 `ContactScene6` 與 6.10 快照,存讀後續跑逐位相同)/ 極端(SWE
> 水深 → 0 不出現負水深;CFL 超限 → 子步或夾限並計入 `diag.counters`;Gerstner 陡度過大
> 自交 → 夾限;全固體 / 全空流域;單一 FLIP 粒子;黏度 → ∞ 趨近剛體;爆炸源在固體內、
> 密閉箱內多次反射;NaN 注入 → 步末隔離並計數)。新測試 `test_shallow_water`、
> `test_ocean_surface`、`test_smoke_grid`、`test_flip`、`test_surface_tension`、
> `test_viscoplastic`、`test_blast_wave`。
> **相依**:15.1(CG / PCG)、17.84(多重網格預條件)、17.27 / 17.28(本項把平面水位與即時
> `RADIAL` 升級)、17.13(遮擋射線)、8.2 / 17.30(高度場河床)、17.55(步進契約)、17.59
> (流固雙向耦合與剛體流體力模型;本項是它的流體端)、17.42(GPU LBM、SPH 邊界粒子)、
> 17.5 / 17.29(爆炸載荷的消費者)、17.61(溫度場)、17.62(GPU 與可微)、17.63(表面輸出、
> 稀疏格網、烘焙)、17.69(SWE 可供水力侵蝕重用)、17.74(船舶推進)。
> **邊界**:水面 / 泡沫 / 焦散著色、體積煙火渲染、濺水與爆炸音效在宿主。核心提供水面高度 /
> 法向 / 流速查詢 API、海浪頻譜參數與 seed(宿主渲染可算同一函數)、煙 / 溫度 / 速度格網
> 與液體粒子(資料)、濺水與爆炸波到達事件(17.38 `EventChannel`)。表面網格輸出在 17.63。

#### 17.61 多物理材料(顆粒 / 熱傳與相變 / 電磁 / 植被) — Wave C

> **緣起**:2026-10-09 負空間盤點,合併 4 筆:顆粒材料(砂)、熱傳導與相變、電磁與磁力、植被風擺與互動。
> **現況**:MLS-MPM 的塑性只有行列式夾限 ——「Plasticity is a determinant clamp on F」
> (`physics/mpm.mojo:21-22`,實作 `:308-319`),docstring 只列「snow, mud and plastic flow」
> (`:10`);Lamé 參數 `mu` / `lam` 全域一組(`:49-50`),粒子欄位只有 x / v / F / C / vol /
> mass(`:35-41`),沒有溫度、相別或材料編號。Drucker–Prager 回映要 3×3 SVD,但 grep
> `svd|singular value` 於 `geometry` / `numerics` / `physics` 零命中(`physics/fem.mojo:64`
> 只有 `polar_rotation`)。CATEGORY 已有「MPM 彈性 vs 塑性」seam(`docs/CATEGORY.md:140`)。
> DEM 對照端可用 `ContactScene6` 的球堆,但沒有滾動阻力(列在 17.48)。熱只有實驗
> `experiments/exp_dec.mojo:12-13`(圖拉普拉斯熱擴散 probe,無引擎套件使用);PBF 單一
> `rho0`(`physics/pbf.mojo:92`),LBM 沒有溫度純量。力場只對中心施線性衝量
> (`physics/fields.mojo:174`),不施力矩,雖然 `Body6.apply_angular_impulse` 已存在
> (`physics/rigid6.mojo:130`);八叉樹節點只存 (proxy, box),不彙總質量或偶極矩
> (`spatial/tree_core.mojo:4-7`),用途是寬相(`collision/bp_tree.mojo:61`)。植被可用的
> 零件:6.12 樹狀 `Chain`(`add_link_to`,`physics/chain.mojo:227`;關節只有單自由度的
> revolute / prismatic,`:96-97`,沒有球關節,9.1 狀態校正已把這部分移到 17.51),
> `Chain.step` 吃關節力矩 `tau`(`:868`),檔內沒有關節彈簧(grep `stiff|spring|damp` 零命中);
> 風來自 17.27 `WindGrid`(`physics/fields.mojo:75`)與 `procedural/noise.mojo` 的 `fbm3`
> (`:181`);角色 / 載具的壓痕可用 17.13 的 `overlap_capsule` / `capsule_penetrations`
> (`collision/world_query.mojo:344,360`)。grep `granular|\bsand\b|drucker|顆粒|休止角`、
> `magnet|dipole|lorentz|磁`、`vegetation|foliage|grass|植被|草|樹木` 於 docs / README 零命中,
> `heat|thermal|temperature|溫度|melt|相變|熔` 只命中 17.4「待辦」的輪胎溫度;引擎套件只有無關
> 字面(`physics/pbf.mojo:25-26` 的「looks like sand」、`collision/toi.mojo:5` 的「granularity」)。
> **缺口**:
> - **顆粒材料(砂)**:MPM 的 Drucker–Prager 摩擦角塑性回映(Klár 2016,含 SVD),並以 DEM
>   (球 + 滾動阻力)作對照。例:砂堆停在休止角、沙漏穩定流出、輪子壓出車轍(耦合在
>   17.59 / 17.74)。
> - **熱傳導與相變**:剛體的集總溫度 + 接觸導熱;MPM / PBF 粒子攜帶溫度並擴散,依溫度改變
>   材料(Stomakhin 2014 augmented MPM:潛熱、溫度相依的 Lamé 參數),MPM 與 PBF 粒子
>   依相別互轉;LBM 加溫度純量(雙分佈函數)。例:冰塊融成 PBF 水、熔岩冷卻變硬、蠟受熱
>   變軟、燒紅的鐵球熔穿冰面。
> - **電磁與磁力**:body 帶磁偶極矩或電荷,偶極-偶極力與力矩、Coulomb 力、外加均勻場中的
>   Lorentz 力;多體時用 Barnes–Hut(八叉樹節點彙總偶極矩)。範圍只到剛體上的力與力矩,
>   不做電路與電磁波傳播。例:磁鐵吊車吸起鐵箱、磁浮列車懸浮、磁吸工具把剛體吸成一串、
>   帶電粒子在磁場中偏轉。
> - **植被風擺與互動**:降階樹木(6.12 樹狀鏈 + 關節彈簧,或 Habel 2009 模態)、草葉(每葉
>   1–2 自由度彈簧),由 `WindGrid` + 雜訊陣風驅動,被角色 / 載具的膠囊壓彎後緩慢回復,
>   倒伏狀態可保留。例:坦克輾過草地留下倒伏痕跡、陣風掃過樹林。
> **對照組**:顆粒 —— Klár 2016、Newton / Warp implicit MPM、Genesis MPM 砂、Houdini MPM /
> Vellum grains、Taichi Elements;熱 —— Stomakhin 2014、Houdini Pyro / MPM;電磁 ——
> Thomaszewski 2008「Magnets in Motion」;植被 —— SpeedTree wind、UE5 interactive foliage、
> Habel 2009。本庫對照:MPM 行列式夾限(`test_mpm`、`bench_mpm`)、`ContactScene6` 球堆
> (DEM 端)、`experiments/exp_dec.mojo` 的熱擴散、17.41 `Rope` 與 6.12 `Chain`(樹枝)。
> **優勢區**:中 ——(a)電磁:`Multivector[p,q,r]` 是 signature 泛型
> (`geometry/multivector.mojo:1-5`),B 場可表為雙向量、偶極力矩是交換子,直接進 `Body6`
> 的角衝量介面;(b)植被:樹枝 FK 已在 PGA motor 上(`physics/chain.mojo:13-14`);`Chain`
> 目前不是 `Field` 泛型,待 17.51 把關節體可微化後,枝條剛度 / 阻尼可對錄製的擺動擬合;
> (c)顆粒:DP 回映與現行夾限同屬一個本構回映 seam,休止角與柱崩塌跑距(Lajeunesse 2004)
> 有實驗值可對。熱傳本身低 —— 純工程。
> **規模軸**:MPM 粒子數 × 格解析度;導熱粒子 / 物體數 × 時步(顯式穩定上限 dt ∝ h²);
> 磁性物體數(直接加總 O(n²) vs Barnes–Hut 的 θ);植被實例數(10³ 棵樹 / 10⁵–10⁶ 草葉)×
> 每實例自由度。
> **seam?**:是 ——(a)MPM 本構回映:行列式夾限 / Drucker–Prager(擴充 `docs/CATEGORY.md:140`
> 那一列)→ parity:同一彈性本構下,內聚力 → ∞(永不降伏)時與純彈性 `set_plastic(1, 1)`
> (`physics/mpm.mojo:88`,`j_max > j_min` 才夾限,`:308`)逐位相同;DP 砂堆與 DEM 球堆的
> 休止角在容差內;bench:每粒子每步成本。(b)熱擴散:顯式 / 隱式(15.1 CG)→
> parity:總熱量守恆、穩態溫度在容差內;bench:最大穩定時步 × 成本。(c)電磁加總:直接
> O(n²) / Barnes–Hut → parity:θ = 0 時與直接加總在容差內,θ 掃描畫精度-成本曲線;bench:
> n 掃描。(d)植被模型:單葉解析彈簧 / 樹狀 `Chain` + 關節彈簧 / 模態 → parity:小振幅自然
> 頻率對阻尼扭簧擺解析值、定風速下的靜態彎曲一致;bench:每實例每步成本。各入
> CATEGORY.md 與 BENCHMARK_REPORT 一列。
> **交付**:普通(砂堆休止角、沙漏流量;兩端定溫細棒的線性穩態剖面;冰塊在室溫下融化、
> 總質量守恆;兩磁鐵相吸並對齊、力隨 1/r⁴ 衰減;單株樹在定風下彎曲、風停後衰減振盪)/
> 整合(17.4 的車開過 MPM 砂地留下車轍(經 17.59 耦合);17.60 煙火與本項共用溫度場;磁鐵
> 吊車以 `ContactScene6` 關節吊起鐵箱、超載經 17.29 斷開;載具壓過草地,倒伏狀態經 6.10
> 快照存讀後一致;全部經 17.55 契約)/ 極端(摩擦角 0° 與 89°;顆粒全部重疊出生;溫度在
> 相變點附近來回、潛熱耗盡;兩磁偶極重合(r → 0 夾限並計入 `diag.counters`)、偶極矩 0;
> 10⁶ 草葉;風速 0 與颶風級;NaN 注入 → 步末隔離並計數)。新測試 `test_mpm_granular`、
> `test_heat`、`test_phase_change`、`test_magnetics`、`test_vegetation`。
> **相依**:17.59(MPM ↔ 剛體耦合,車轍)、17.74(輪-土壤地面力學)、17.48(滾動阻力,DEM
> 端前提)、17.58(超彈性本構與可變形體斷裂,共用本構 seam)、17.55(步進契約)、17.60
> (煙火溫度場)、17.62(GPU MPM)、15.1(隱式熱擴散)、17.27(`WindGrid` 與施力骨架)、
> 6.12 / 17.41(樹枝)、17.47(關節彈簧與縮座標被動阻尼)、17.51(縮座標球關節、關節體
> 可微)、17.56(布料空氣動力的逐元素拖曳,葉片可共用)、17.69(L-system 植物骨架生成 →
> 本項的動力學輸入)、17.31(大量植被的 LOD)。
> **邊界**:植被繪製(頂點著色風擺、草葉實例化)與冰融、熔岩的著色在宿主;核心輸出每實例
> 的彎曲向量 / 骨骼旋轉與倒伏狀態、粒子溫度與相別(資料)。

#### 17.62 GPU 連續體與可微連續體(含可微盒 / 膠囊 / 凸包接觸) — Wave C

> **緣起**:2026-10-09 負空間盤點,合併 3 筆:GPU 連續體解算器、可微可變形體與流體、盒 / 膠囊 / 凸包的
> 可微碰撞。三者先前只以限制、待辦或對照組出現,沒有編號:6.1「已知限制」寫「無 GPU 版
> (gpu_cloth 機制可移植)」;17.17「交付」寫「GPU 剛體 + CPU 軟體同幀」,軟體留在 CPU;
> `docs/SOTA_GAP_ANALYSIS.md:90-91,96` 把 PB-MPM 列為 GPU-first 前沿,`:106-107` 判「VBD/AVBD、
> PB-MPM、IPC 系全部不在射程內」。DiffXPBD 只出現在 SOTA_GAP(`:97-98`)與 17.20「對照組」。
> 17.20「進度」的待辦「子集外擴(盒 / 膠囊、關節、恢復係數 pass)」不在 Phase 17 建議順序
> 2026-10-09 修訂的「剩餘順序」內,13.7 標頭仍是 🔶。
> **現況**:GPU 物理只有 `physics/gpu_cloth.mojo`、`physics/vbd_cloth.mojo`、
> `physics/gpu_contact.mojo`、`fluid/lbm_gpu.mojo`(另有寬相 / LBVH / raycast);
> `physics/mpm.mojo`、`pbf.mojo`、`sph.mojo`、`fem.mojo`、`softbody.mojo` 不 import 任何 GPU
> 模組。可移植的慣例已在:`gpu_cloth` 是 gather 式 Jacobi,「no atomics, deterministic」
> (`physics/gpu_cloth.mojo:4-5`);`PbfFluid` 已是 SoA(`physics/pbf.mojo:69-71`);
> `DeviceContext` 由呼叫端傳入、每 process 一個(`gpu_cloth_run_ctx`,
> `physics/gpu_cloth.mojo:342`)。MPM 的格是稠密 n³(`physics/mpm.mojo:73-78`),P2G 是逐粒子
> 的散射迴圈(`:117-118`),照搬上 GPU 要浮點 atomics,加總順序不定。可微:
> `physics/diffsolver.mojo` 的子集只有動態球 + 靜態平面(`:19-22` 寫「no joints, no
> restitution pass ... no soft bodies」;`DiffPlane` `:193`、`add_plane` `:259`),
> `physics/diffsim.mojo` 是玩具拋體;`SolverField` 係數環(`geometry/field.mojo:39`,實作
> `RealF` / `DualReal` / `DualBatch` / `BatchReal[W]` / `RevReal`)可重用。grep「可微 / diff」
> 搭配布 / 軟體 / MPM / SPH / 流體 於 docs 沒有規劃命中。
> **缺口**:
> - **GPU 連續體解算器**:MPM(含 PB-MPM,EA SEED 2024 的位置式 MPM,大時步穩定)、
>   SPH / PBF(格網鄰居搜尋上 GPU)、隱式 FEM(matrix-free 算子 + GPU CG,歸約順序固定)、
>   XPBD 晶格軟體(著色或 gather Jacobi)。P2G 採 gather 式(粒子按格排序、格點收集)或
>   定點整數 atomics,維持同 seed 逐位重現(17.39 回放、17.16 rollback 的前提)。例:
>   10⁵–10⁶ 粒子的雪崩或水池即時跑。
> - **可微可變形體與流體**:照 17.20 的做法(`Field` 泛型重述 + 對具體解算器的 parity),
>   做出 XPBD 布 / 晶格軟體、MPM、PBF / SPH 的可微子集;長 rollout 以 checkpointing 控記憶體。
>   例:由一段參考垂墜擬合布料剛度、由回彈高度反推果凍柔度、調整煙源讓煙形接近目標
>   (17.60)。
> - **可微碰撞擴到盒 / 膠囊 / 凸包**:`SphereWorld` 擴成含盒 / 膠囊 / hull 的可微子集,
>   接觸特徵切換(角 ↔ 邊 ↔ 面)沿用 `positive` 的次梯度約定,另提供隨機平滑
>   (Montaut 2023)作對照;17.20 同一行待辦的關節與恢復係數 pass 一併收入。例:由滑行距離
>   反推箱子的摩擦係數、由落地翻滾反推膠囊的恢復係數。
> **對照組**:GPU —— EA SEED PB-MPM(SIGGRAPH 2024)、PhysX 5 GPU FEM / PBD 粒子、Genesis、
> Newton / Warp、Taichi;可微 —— DiffXPBD(2023)、DiffTaichi / ChainQueen(可微 MPM)、
> Warp / Newton、Genesis、MJX 可微凸體碰撞、Montaut 2023 隨機平滑、Dojo。本庫對照:各 CPU
> 解算器(parity 基準)、`test_gpu_cloth` / `test_vbd_cloth` / `test_lbm_gpu` 的 CPU↔GPU
> 方法、`test_diffsolver` 的四方梯度一致與 `examples/22_diffsolver_sysid.mojo` 的 μ 反推。
> **優勢區**:GPU 中 —— SoA 與 gather 式慣例已就緒;本庫要求同 seed 逐位重現,浮點
> atomics 的 P2G 做不到,gather / 定點歸約的成本差要量出來;kernel 與 CPU 參考逐行對應
> (17.42 `LbmGpu` 的做法)。可微 高 —— 與 17.20 / 17.18 合流:`BatchReal[W]` 一次跑 W 組
> 材料參數、`DualBatch` 一次帶 4 個方向。子集現行的姿態是一階四元數 + 正規化,與
> `QuatBody6` 的精確指數每子步差 O(h²),球只經旋轉的接觸錨點受影響
> (`physics/diffsolver.mojo:23-26`);盒的接觸點直接依姿態,可改用 `ScrewBody6`
> (`physics/rigid6.mojo:271`)的閉式 motor 指數(`:347-349`),與
> `ContactScene6[ScrewBody6]`(`tests/test_solver6.mojo` 已用)走同一積分子。
> **規模軸**:粒子數 10⁴ → 10⁶(GPU vs CPU 交叉點,傳輸成本獨立成列,同 `bench_gpu_contact`);
> 可微:參數數 NP × rollout 步數 × checkpoint 間隔;形狀種類 × 接觸數。
> **seam?**:是 ——(a)裝置:CPU / GPU(MPM、PBF / SPH、FEM、晶格軟體)→ parity:與 CPU
> 逐位,或差距 ≤ CPU 對 1e-6 擾動自身發散的 2 倍(沿用 `test_gpu_contact` 判準);bench:
> N 掃描 + 傳輸列。(b)P2G 歸約:浮點 atomics / gather / 定點 atomics → parity:後兩者跑兩次
> 逐位相同,三者質量與動量守恆同容差;bench:每粒子 ns。(c)MPM 時步法:顯式 MLS-MPM /
> PB-MPM → parity:同彈性方塊的靜止態、同塑性流在容差內;bench:最大穩定時步 × 每模擬秒
> 成本(沿用 `bench_sph` 的時步掃描)。(d)可微係數環擴到可變形體與新形狀 → parity:`RealF`
> 路徑對具體解算器在容差內(`test_diffsolver` 的判準),DualReal / DualBatch / RevReal /
> 中央差分四方一致;bench 接 `bench_diffsolver` 的 NP 掃描。各入 CATEGORY.md(擴 §2.6 /
> §2.8)與 BENCHMARK_REPORT。
> **交付**:普通(GPU MPM 雪塊落地堆積與 CPU 在判準內;GPU PBF 潰壩;GPU 晶格軟體落地
> 靜置;可微布由參考垂墜擬合剛度;可微 MPM 由回彈高度反推楊氏模數;可微盒由滑行距離
> 反推 μ)/ 整合(GPU 連續體與 `GpuContactSolver`、`LbmGpu` 共用同一個 `DeviceContext`;
> GPU MPM 經 17.55 契約碰 `ContactScene6` 的碰撞器;`examples/22` 擴到盒與膠囊(8 lane
> `BatchReal` 掃描 + DualReal Newton);可微盒進 17.18 批次多世界)/ 極端(10⁶ 粒子;粒子
> 離開格網(現行 CPU P2G 直接略過,`physics/mpm.mojo:126-129`)→ 夾回並計入
> `diag.counters`;所有粒子擠在同一格(歸約熱點);無加速器自動跳過(`has_accelerator`);
> 盒以稜或角著地時特徵切換處的梯度行為明確記錄;零接觸 rollout = 解析彈道;NP 大、長
> rollout 的 checkpoint 記憶體上限)。新測試 `test_gpu_mpm`、`test_gpu_pbf`、
> `test_gpu_softbody`、`test_diff_cloth`、`test_diff_mpm`、`test_diffsolver_shapes`。
> **相依**:3.2 / 4.3(GPU 布料與 VBD 慣例)、17.17(GPU 接觸、單一 context)、17.42(GPU LBM
> 做法)、17.55(步進契約)、13.7 / 17.20(可微子集;本項收掉其待辦)、17.18(批次多世界)、
> 4.2 / 15.3(reverse tape 與 comptime 伴隨)、17.84(接觸解的隱式微分、多重網格)、17.51
> (縮座標關節體可微)、17.52(新碰撞形狀)、17.56 / 17.58 / 17.60 / 17.61(GPU 與可微的
> 消費者)、17.76(GPU 跨廠商與宿主 GPU context 互通)。
> **邊界**:本項交付梯度 API(參數擬合、軌跡最佳化、逆向設計)。以梯度訓練策略或神經網路
> 屬 2026-10-09 排除的 RL 範圍,不在本項;外部控制器只經控制器 seam 接入。

#### 17.63 模擬輸出、烘焙快取與稀疏體積 — Wave C

> **緣起**:2026-10-09 負空間盤點,合併 3 筆:流體表面重建輸出、模擬烘焙與快取回放、OpenVDB / NanoVDB
> 式稀疏體積。
> **現況**:本庫沒有渲染層,流體交給宿主的只有原始資料:`PbfFluid` 的 SoA 座標與速度
> (`physics/pbf.mojo:69-81`),LBM 與 MPM 是稠密格(`fluid/lbm.mojo:141-142` 的
> `self.f[i * self.cells() + c]`、`physics/mpm.mojo:73-78`)。grep `marching|isosurface|
> level.?set|surface.?reconstruct|等值面|表面重建` 於 docs / 引擎套件零命中。回放是「輸入 +
> 定期快照 + 重跑」(`gameplay/replay.mojo:1-19`),不是幾何回放;6.10 快照自註「a full
> state snapshot, not an asset reference」(`physics/solver6.mojo:1469-1470`);17.39「進度」的
> 待辦有「錄製檔案化(目前在記憶體)」,17.40「進度」的待辦有「檔案 I/O(目前給 bytes)」。
> 補幀插值已有 `PoseInterpolator` seam,含 `MotorGeodesic`(`gameplay/interpolation.mojo:14-17`)。
> SDF 只有解析基元 + CSG min / max(`geometry/sdf3.mojo:14-15`),沒有取樣網格;所有體素 /
> 速度格都是稠密的:`geometry/convex_decomp.mojo:42` `VoxelGrid`、`physics/fields.mojo:75`
> `WindGrid`、LBM、MPM。grep `vdb|alembic|point.?cache|sim.?cache` 於 docs / 引擎套件零命中
> (程式碼的 `bake` 只是無關字面,如 `procedural/anim.mojo:52`;docs 的 bake 只指 17.14
> navmesh);`narrow.?band|窄帶|sdf.?grid|nanovdb|稀疏網格` 於 docs 零命中,「稀疏體素」只出現
> 在 17.14「增補」的 3D 體積導航。
> **缺口**:
> - **流體表面重建輸出**:粒子 → 密度 / 水平集場的 splat、平滑位置(Laplacian 平滑)、
>   各向異性核(Yu & Turk 2013,每粒子協方差 → 橢球參數),再交 17.69 的等值面擷取出網格;
>   LBM 與煙格直接給場。例:PBF 潰壩交給宿主的是一張連續水面網格或一組橢球,而不是點雲。
> - **模擬烘焙與快取回放**:把昂貴模擬的逐幀輸出(剛體姿態、碎片、布頂點、粒子)錄成時間
>   取樣快取,回放時不重跑;樣本之間用 17.7 的 `PoseInterpolator` 補幀;量化與幀間差分壓縮;
>   快取 → 即時模擬交接(樣本存姿態 + 速度;另每 N 幀存一份 6.10 快照,交接時從最近快照
>   短重跑到當幀,同 17.39 `seek`)。例:1000 片破碎離線烘焙後在過場重播,子彈打中時從當幀
>   交回即時模擬;布料垂墜烘焙後在低階平台播放。
> - **稀疏體積(VDB 式)**:階層稀疏體素格(根 / 內部節點 / 葉 brick,層級大小 comptime
>   參數化)+ 背景值 + 活躍體素;用作窄帶 SDF 的儲存(網格 → SDF 烘焙列在 17.45,SDF 與
>   體素碰撞形狀列在 17.52)、煙 / 密度 / 溫度格(17.60)、MPM 稀疏格;與稠密格互轉;
>   可選單一連續緩衝的線性化佈局(NanoVDB 式,可整塊上 GPU)。放 `geometry`(層 1),
>   `fluid` 與 `physics` 才都能用(`scripts/arch_layers.toml:6,10,14`)。
>   例:整座城市的窄帶 SDF 只存表面附近幾格,記憶體隨表面積而非體積成長。
> **對照組**:表面 —— PhysX 5 `PxIsosurfaceExtractor` / `PxAnisotropyGenerator` / smoothed
> positions、FleX anisotropy、Yu & Turk 2013、OpenVDB particle-to-level-set;烘焙 —— UE Chaos
> Cache Manager、Houdini(Vellum / RBD 快取到 Alembic / bgeo)、Unity Alembic、Blender point
> cache、USD time samples;稀疏體積 —— OpenVDB / NanoVDB、NVIDIA Warp `wp.Volume`、PhysX 5
> SDF 碰撞體、UE Heterogeneous Volumes、Houdini、EmberGen。本庫對照:17.39 回放(重跑式)、
> 6.10 快照、各稠密格(`WindGrid`、`VoxelGrid`、LBM、MPM)。
> **優勢區**:烘焙 中高 ——(a)決定論:未量化的樣本在取樣 tick 與即時模擬逐位相同(可驗);
> 交接走「快照 + 短重跑」,接手後的狀態與從未烘焙的即時模擬逐位相同,不只是近似姿態;
> (b)GA:樣本間以 `MotorGeodesic` 螺旋插值,旋轉碎片在較低取樣率下仍走正確軌跡,取樣率
> 對誤差可量。稀疏體積 中 —— 層級設定 comptime 參數化,走訪展開成直線碼。表面重建 低 ——
> 純工程。
> **規模軸**:粒子數 × 輸出格解析度;烘焙幀數 × 物體 / 頂點數(每幀位元組,量化前後)、
> 取樣率;體素數 × 活躍比例(1% → 100%)。
> **seam?**:是 ——(a)表面核:等向 splat / 各向異性 → parity:協方差等向時與等向 splat
> 逐位相同,靜止水池兩者給出同一水面高度;bench:粒子數 × 解析度。(b)回放來源:即時模擬 /
> 烘焙快取 → parity:未量化時取樣 tick 的狀態逐位相同、補幀等於 17.7 插值的輸出;bench:
> 每幀回放 ns vs 模擬 ns、每幀位元組。(c)格網儲存:稠密 / 稀疏階層 → parity:活躍區的值
> 與三線性取樣逐位相同、區外回背景值;bench:記憶體與每次取樣 ns 對活躍比例。各入
> CATEGORY.md 與 BENCHMARK_REPORT 一列。
> **交付**:普通(PBF 靜止水池重建出的水面高度對粒子靜止高度;烘焙 300 幀疊箱倒塌後回放
> 逐位相同;球的窄帶 SDF 取樣對解析距離在半格內)/ 整合(17.60 的煙存在稀疏格;17.52 的
> SDF 形狀讀窄帶 SDF 參與 `ContactScene6` 接觸;17.5 破碎烘焙後回放,中途射擊 → 交回即時
> 模擬並繼續步進;快取依 17.40 的 bytes 慣例交給宿主)/ 極端(零粒子、單粒子、粒子全重合;
> 空快取、只有一幀;超過容量上限 → 丟最新一筆並計入 `diag.counters`;快取版本不符 →
> raise;全空與全滿的稀疏格、背景值查詢、超出邊界的取樣)。新測試 `test_fluid_surface`、
> `test_sim_cache`、`test_sparse_grid`。
> **相依**:17.69(等值面擷取)、17.39(回放;其「快照差分壓縮」待辦與本項共用)、17.40(bytes
> 慣例、檔案 I/O 待辦)、6.10(交接用快照)、17.7(補幀插值)、17.5 / 17.56(烘焙的主要來源)、
> 17.45(網格 → SDF 烘焙)、13.8 / 17.52(SDF 與體素碰撞形狀,可共用本項的稀疏格儲存)、
> 17.60(煙與液體格)、17.62(GPU 線性化佈局)、17.14(3D 體積導航可共用稀疏格)、17.75
> (零拷貝匯出)、17.80(除錯擷取檔記的是除錯串流,不是回放幾何)、17.78(宿主轉接層)。
> **邊界**:流體表面著色、螢幕空間流體渲染、體積渲染在宿主;Alembic / USD / OpenVDB 檔案編碼
> 交宿主或 17.78 的轉接層(17.12「決定(2026-10-09)」:場景格式跟宿主走)。核心提供網格頂點 /
> 索引、每粒子橢球、時間取樣陣列與版本化 bytes、稀疏格走訪與互轉 API(資料)。

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
| 17.84 | [數值與可微深化:接觸隱式微分、因數分解、預條件子、學習式殘差](#1784-數值與可微深化接觸隱式微分因數分解預條件子學習式殘差--wave-c) | ⬜ | C | 2026-10-09 盤點新增:接觸解的隱式微分、稀疏直接解法、多重網格與強預條件子、學習式物理代理 |

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

#### 17.84 數值與可微深化:接觸隱式微分、因數分解、預條件子、學習式殘差 — Wave C

> **緣起**:2026-10-09 負空間盤點,合併 4 筆:接觸解的隱式微分、稀疏直接解法、多重網格與強預條件子、學習式物理代理。
> **現況**:四項都在文件中被點名、未編號。(a)可微:17.20 交付的是**展開式**梯度 ——
> `physics/diffsolver.mojo:1-17` 在球 / 平面子集上以 `SolverField` 重述每幀演算法,
> `physics/diffsolver.mojo:32-38` 以 `positive` 的零導數當接觸開關的次梯度約定;
> `physics/diffsolver.mojo:4-7` 說明不把係數環穿過 `ContactScene6` 的原因(要重寫 body 表示、
> collider set 與每個 narrowphase)。Nimble(LCP 可微)只出現在 17.20「對照組」;grep
> `KKT|implicit diff|隱式微分|sensitivity` 於 `docs/` 與引擎套件零相關命中。
> (b)直接解法:`numerics/` 只有 `cg.mojo`、`dense.mojo`、`sparse.mojo`、`vecops.mojo`;
> `solve_dense`(`numerics/dense.mojo:84`)是部分樞軸高斯消去,每次呼叫重新消去。
> `Chain.resolve_contacts` 已把 H 提出迴圈(`physics/chain.mojo:744,762`),但速度與位置
> 兩個 pass 各 8 次迭代 × 每個接觸仍各做一次 O(n³) 消去(`physics/chain.mojo:746-757`、
> `physics/chain.mojo:765-779` → `apply_impulse_with` 的 `physics/chain.mojo:661`);
> `ConstraintSet.solve` 每一列約束一次完整消去(`physics/constraints.mojo:136-146`),而同函式
> docstring(`physics/constraints.mojo:129-132`)說 "the expensive part is the factorisation",
> 分解並未重用。審計建議 Cholesky(`docs/audits/2026-09-27-architecture.md:52`),
> `docs/design/17.0-f12-chain.md:11-13` 記 "not done … A Cholesky variant is a separate,
> parity-tested seam row if wanted"。
> (c)預條件:`pcg` 只有 Jacobi(`numerics/cg.mojo:73-88`);隱式 FEM 呼叫的是無預條件
> `cg`(`physics/fem.mojo:287`),剛性材料每步 31 次迭代(15.1「量測」);
> `LinearOperator` 只暴露 `size` / `apply` / `diagonal`(`numerics/sparse.mojo:35-51`),FEM
> 刻意不組裝全域剛度矩陣(15.1「接線」);多重網格只以前沿文獻出現
> (`docs/SOTA_GAP_ANALYSIS.md:81` MGPBD)。(d)學習式物理:「stretch 項(learned physics、
> GPU rigid)明確留待後續」(開頭「狀態(2026-07-13)」),另見 3.1「進度」與 learned-physics
> 原型條、4.2「進度」與 Stretch 條,以及 `docs/SOTA_GAP_ANALYSIS.md:52-54`;GPU rigid 後來成為
> 17.17,learned physics 沒有編號。程式只有 `experiments/exp_clifford_nn.mojo`(40 參數 PGA2
> 兩層網路、SPSA 訓練,`experiments/exp_clifford_nn.mojo:1-12,25`),未接任何引擎套件。
> **缺口**:
> - **(a)接觸解的隱式微分**:在收斂解的 KKT / 互補條件上用隱函數定理取梯度,一次線性解取代
>   逐迭代展開;先在 `SphereWorld` 子集上與展開式對照,再推到 `ContactScene6` 與 `Chain` 的
>   接觸列,不需把 solver6 改成 `Field` 泛型。例:由一段錄下的箱子滑行反求摩擦係數(模擬
>   校準),或調彈跳板角度讓物體落在目標點。限制:solver6 每子步只掃固定迭代數(17.31
>   `SimBudget` 調的正是迭代數與子步數),隱式梯度微分的是收斂解而非截斷迭代映射,差異要量。
> - **(b)因數分解 seam**:先做 dense Cholesky / LDLᵀ(分解一次、多次 O(n²) 回代),再做
>   樹狀稀疏 LDLᵀ(關節鏈質量矩陣,O(n·樹深))與 CSR 上的稀疏 Cholesky(隱式 FEM 的直接解
>   對照組)。例:20 連桿角色鏈 4 個地面接觸,一次接觸解析最多 64 次 O(n³) 消去 → 2 次
>   分解 + 回代。(a)的伴隨解與正向解共用同一個分解。
> - **(c)預條件子 seam**:新 `Preconditioner` trait —— Jacobi(現況)/ 3×3 block-Jacobi /
>   IC0 / AMG V-cycle;IC0 與 AMG 需要組裝好的 `CsrMatrix`,FEM 算子補一條可選的組裝路徑。
>   例:1e6 自由度的可破壞牆體隱式 FEM,剛性材料下 CG 迭代數不隨網格細化線性上升。
> - **(d)學習式殘差 seam**:solver 步末呼叫的新 `ResidualModel` trait(狀態 → 速度修正),
>   預設 `NoResidual` 在編譯期消去;殘差參數的梯度經既有 `Field` 型別(`DualBatch` /
>   `RevReal`)取得,供外部訓練器擬合。例:碎石堆在 `SimBudget` 降級(少子步)時以殘差補回
>   與細子步參考解的差距。`exp_clifford_nn` 的 GA 層留在 `experiments/` 當參考實作。
> **對照組**:(a)Nimble Physics(LCP 敏感度)、Dojo(隱式積分微分)、de Avila
> Belbute-Peres et al. 2018、cvxpylayers、DiffMJX;本庫內部對照:17.20 展開式
> `SolverField` 梯度與有限差分。(b)MuJoCo(M 的稀疏 LDLᵀ)、Eigen `SimplicialLDLT`
> (Drake)、CHOLMOD、Pinocchio、cuDSS;內部對照:`solve_dense`。(c)AMGX、AmgCL、
> PETSc / hypre、MGPBD(arXiv:2505.13390)、Houdini Vellum;內部對照:Jacobi `pcg`。
> (d)GATr(arXiv:2305.18415)、CGENN(arXiv:2305.11141)、Graph Network Simulators
> (DeepMind)、NVIDIA PhysicsNeMo。
> **優勢區**:(a)高 —— 17.18 + 17.20 是本專案主打(17.20「優勢區」),隱式微分讓梯度觸及
> 完整 solver6 而不必改型別,記憶體也不隨迭代數成長(展開式的 tape 隨迭代線性成長)。
> (b)中 —— 分解重用是確定的漸近改善;螺旋 / PGA 鏈已有 O(n) ABA,樹狀 LDLᵀ 補的是約束 /
> 接觸那一側。(c)中低 —— 數值工程,規模大時才顯現。(d)中 —— multivector 層對剛體運動
> 等變(`experiments/exp_clifford_nn.mojo:6-7`),引擎原生 AD 直接給殘差參數梯度;是否
> 勝過純解析模型未知,要量。
> **規模軸**:(a)迭代數 × 接觸數 × 參數數 NP;(b)自由度 n × 約束列 m × 樹深;(c)自由度
> 1e3→1e6 × 剛度對比 1→1e6;(d)殘差參數數 vs 每步額外成本與誤差下降幅度。
> **seam?**:是 —— 四條:(a)梯度路徑(展開 vs 隱式)→ parity:solver 跑到收斂時兩者與
> 有限差分在容差內一致(同一接觸排程)+ bench(記憶體 / 時間 vs 迭代數);(b)`solve_dense`
> vs Cholesky / LDLᵀ → parity 為容差而非逐位(換分解會改捨入、破身分閘門,故預設不換,
> `docs/design/17.0-f12-chain.md:11-13`)+ bench(n × m 掃描);(c)預條件子 → 同一系統的解在
> CG 容差內一致、既有 FEM 測試不變 + bench(迭代數與牆鐘 vs 自由度);(d)`NoResidual` 路徑
> 與現況逐位相同(golden 不變)+ bench(殘差開 / 關的每步成本)。
> **交付**:普通(單一接觸的隱式梯度 vs FD;10 連桿鏈 Cholesky vs 消去;block-Jacobi 在 FEM
> 上迭代數少於 Jacobi;零殘差逐位相同)/ 整合(`ContactScene6` rollout 的隱式梯度在
> `SphereWorld` 子集上與 17.20 一致,並接 4.2 reverse tape 串多步、與 17.18 批次相容;LDLᵀ
> 接進 `chain.mojo` 與 `constraints.mojo` 後既有測試在容差內不變;AMG 接
> `FemBody.step_implicit`;殘差接 `SimBudget` 降級路徑)/ 極端(接觸開關不連續點;秩虧的
> KKT 系統;未收斂時回報而非給假梯度;審計 E18 的無質量連桿使質量矩陣奇異 → 分解回報;
> 剛度對比 1e6;殘差輸出 NaN → 步末隔離並計數)。
> **相依**:13.7 / 17.20(展開式可微子集)、17.18(批次梯度)、4.2 / 15.3(tape 與 emitted
> adjoint)、13.5(統一約束求解器)、6.4 / 6.12(關節鏈)、15.1(Krylov 層)、17.0 F12
> (`numerics/dense.mojo`)、3.1 / 4.2 stretch(learned physics)、17.31(`SimBudget`)、
> 17.62(可微連續體共用 (b)(c))。
> **邊界**:核心不內建 NN 推論 runtime、模型檔格式或訓練迴圈(RL / 機器人依 2026-10-09
> 使用者指示排除);學習式元件只經 (d) 的 seam 由外部提供,核心負責步進與梯度。

---

## GPU 計算

範圍:GPU kernels 與單一 device context。

| 編號 | 條目 | 狀態 | Wave | 說明 |
|---|---|:-:|:-:|---|
| 3.2 | [GPU 物理(Mojo kernels)](ROADMAP_HISTORY.md#32-gpu-物理mojo-kernels) | ✅ |  | 引擎首個 GPU 常駐物理:gather 式 Jacobi XPBD 布料 4 kernels、`has_accelerator` 守衛,CPU/GPU parity 2.4e-6,RTX 3060 上 16k 粒子 8.3×、65k 粒子 1.08 ms/step。 |
| 4.3 | [GPU 物理擴張:VBD 原型](ROADMAP_HISTORY.md#43-gpu-物理擴張vbd-原型) | ✅ |  | VBD 布料原型(每頂點 3×3 局部 Newton、棋盤 2 著色 Gauss-Seidel、4 個 kernel)與 XPBD 同場景比較:在簡單布料上 XPBD 收斂較快較省;另修好多 DeviceContext 掛死問題(共享單 context,128² XPBD GPU 28×)。 |
| 17.17 | [GPU 剛體 / articulation solver](#1717-gpu-剛體--articulation-solver) | 🔶 | B | `GpuContactSolver` 把 `ContactScene6` 著色模式的接觸子步迴圈搬到 GPU(CPU 保留收集、island、著色與簿記),以量測出的擾動界通過 parity 測試 22/22,但 GPU articulation 與 GPU narrowphase 尚未做。 |

### 已完成條目的遺留待辦

這些條目已完成並移到歷史檔,但各自記下了尚未做的部分:

- **3.2**([紀錄](ROADMAP_HISTORY.md#32-gpu-物理mojo-kernels)):GPU rigid(6-DOF 剛體 solver 上 GPU)— 4.3 stretch 未做,後續歸入 17.17 GPU articulation / 剛體
- **3.2**([紀錄](ROADMAP_HISTORY.md#32-gpu-物理mojo-kernels)):Gate 所寫粒子數 scaling 10⁴→10⁶ 只量到 65k 粒子(bench_gpu_cloth 記錄 16k、65k),10⁶ 端未見數字
- **4.3**([紀錄](ROADMAP_HISTORY.md#43-gpu-物理擴張vbd-原型)):Stretch:GPU rigid(6-DOF 剛體 solver 上 GPU)— 本節未做;已轉到 17.17,剛體接觸部分於 2026-09-29 完成,GPU articulation(Featherstone)、GPU narrowphase、kernel 融合、持久裝置狀態仍是 17.17 的待辦

### 待辦與部分完成條目

#### 17.17 GPU 剛體 / articulation solver

> **狀態**:🔶 部分完成(Wave B;GPU 剛體接觸 ✅ 2026-09-29;GPU articulation / narrowphase 未做,排在 Phase 17 建議順序 2026-10-09 修訂剩餘順序第 (6) 項)
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
> **待辦**:
> - GPU articulation(Featherstone on device)
> - GPU narrowphase / manifold
> - kernel 融合(每子步一次啟動)
> - 持久裝置狀態,免每幀上下傳
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
| 17.64 | [動畫執行期補完](#1764-動畫執行期補完--wave-b) | ⬜ | B | 2026-10-09 盤點新增:慣性化過渡、motion matching 軌跡特徵、motion matching 加速結構、跨拓撲重定向、動畫壓縮、動畫事件與同步標記、動畫扭曲、方向性 2-D 混合空間、動畫 LOD / 更新率預算、動畫資料匯入、骨骼插槽 |
| 17.65 | [蒙皮形變資料(morph target / 臉部 / 姿勢空間修正)](#1765-蒙皮形變資料morph-target--臉部--姿勢空間修正--wave-c) | ⬜ | C | 2026-10-09 盤點新增:morph target / blend shape、臉部動畫(FACS / viseme / lip-sync)、姿勢空間修正與 ML deformer |
| 17.69 | [程序化內容生成](#1769-程序化內容生成--wave-c) | ⬜ | C | 2026-10-09 盤點新增:OpenSimplex2 與 SIMD 批次取樣、地形生成與侵蝕、Poisson-disk 散布、WFC、地城 / 關卡生成、L-system / 植物生成、程序化網格建構、等值面擷取、三角網格布林運算、瓦片 / 六角格 |

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

#### 17.64 動畫執行期補完 — Wave B

> **緣起**:2026-10-09 負空間盤點,合併 11 筆:慣性化過渡、motion matching 軌跡特徵、motion matching 加速結構、跨拓撲重定向、動畫壓縮、動畫事件與同步標記、動畫扭曲、方向性 2-D 混合空間、動畫 LOD / 更新率預算、動畫資料匯入、骨骼插槽。
> 其中「motion matching 加速結構」與「方向性(polar)2-D 空間」已列在 17.6「進度」的待辦但未編號;
> polar 也是 17.6「缺口」原文「blend tree(1D / 2D 方向性)」的一半;同一待辦的「骨架階層
> 世界矩陣組合」併入 (k)。其餘各項沒有任何條目或待辦提及(零命中的 grep 列於現況末)。
> **現況**:
> - 過渡只有 cross-fade:`procedural/anim.mojo:294-322` `AnimPlayer.evaluate` 取樣兩個
>   clip 再混;11.3「量測」記錄 cross-fade 期間 170 ns,是單一 clip 的 3.4×。
> - `procedural/anim.mojo:46-60` `AnimClip` 每(幀, 骨)存原始 pos 3 + rot 4 個 `Real`;
>   `:52` 把非均勻關鍵幀列為「bake-time concern」,但沒有 baker,也沒有任何匯入器。
> - `procedural/anim_graph.mojo:346-402` `MotionDB`:特徵 = 根速度 (x, z) + 選定骨位置
>   (`:363-376`),`query` 是無權重平方距離的 O(N·dim) 線性掃(`:389-402`),docstring
>   (`:347-349`)寫明它是加速搜尋的對照基準;`bench_anim_graph` 沒有 MotionDB 列。
> - 同檔 `BlendSpace2D`(`:174-237`)只有 freeform cartesian;`BlendSpace1D` 以同一正規化
>   相位同步步伐(`:13-16`),沒有 marker;`retarget`(`:326-340`)以相同骨索引照抄旋轉、
>   依骨長比縮放平移,`Skeleton.rest`(`:315`)只用來算骨長(零長源骨時改取 `dst.rest`
>   平移,`:337-338`);`root_motion` / `strip_root`(`:284-307`)只擷取或剝除位移,從不縮放。
> - 物體跟骨:`to_world`(`:405-414`,FK)+ `gameplay/ragdoll.mojo:98-106`
>   `Ragdoll.follow` 以 `move_to` 帶動 kinematic 骨箱,只存在於 `Ragdoll` 內部;
>   `ecs/transform.mojo:86-88` `Parent` 只存 entity id,沒有骨索引。`physics/lod.mojo:1-18`
>   只凍結剛體、調 iters / substeps,不含動畫。
> - grep 於 docs 與程式碼皆零命中:`inertiali`、`dead.?blend`、`慣性化`、`notif(y|ies)`、
>   `footstep`、`sync.?marker`、`compress.*(anim|clip|key)`、`keyframe.?reduc`、`quantiz`、
>   `motion.?warp`、`distance.?match`、`kd.?tree`、`nearest.?neighbo`、`socket`、
>   `bone_world`、`update.?rate`、`mocap`、`Biovision`、`FBX`。glTF 在 docs 只出現於場景匯入
>   (「Wave 分組與相依」的 2026-10-09 平台方向 C 決定、(II) 表「資產匯入」列、17.12「決定」與
>   「對照組」)與 `docs/SOTA_GAP_ANALYSIS.md:42` 的渲染器描述,沒提骨架或動畫通道。
> **缺口**:
> - (a)**慣性化過渡**(inertialization / dead blending):切換當幀只取樣目標 clip,新舊
>   姿態的逐骨偏移(位置 + 速度)以臨界阻尼衰減到 0(例:motion matching 每 0.1 s 跳幀、
>   ragdoll 起身接回動畫,都不 pop,也不必同時取樣兩個 clip)。
> - (b)**motion matching 生產特徵**:未來根軌跡(由搖桿輸入預測 +0.2 / 0.4 / 0.6 s 的
>   位置與朝向)+ 腳位置 / 速度,逐特徵正規化與權重(例:strafe 轉衝刺時挑到朝向正確的
>   起步幀,而不是根速度最近的幀)。
> - (c)**motion matching 加速結構**:KD-tree / AABB 剪枝 / 量化特徵(例:10 萬幀 mocap
>   庫每幀查詢在 µs 級)。k 維索引若要與 17.53 的 kNN 共用,須放第 1 層 `geometry`
>   (`procedural` 與 `spatial` 同為第 2 層,不得互引)。
> - (d)**跨拓撲重定向**:骨名 / 鏈映射、骨數不同、bind pose 旋轉差補償、腳與手的 IK 修正
>   (例:A-pose 的 mocap 演員多兩節脊椎,重定向到 T-pose 遊戲骨架後腳不穿地)。
> - (e)**動畫壓縮**:誤差有界的關鍵幀精簡、量化四元數(smallest-three)、逐軌值域
>   (例:30 分鐘 mocap 庫壓到數 MB,而非每骨每幀 7 個浮點)。
> - (f)**動畫事件與同步標記**:clip 上帶時間戳的 marker,在播放、混合、跨 loop 時決定論
>   地各觸發一次;以腳步 marker 對齊不同步伐(sync group),取代只靠正規化相位(例:walk /
>   run 混合中 `LeftFootDown` 每週期恰觸發一次,接腳步聲與 foot-lock)。`procedural` 在
>   第 2 層不得 import `scheduler`:取樣回傳本步跨過的 marker,由 `gameplay` 轉進 17.38
>   `Channel`。
> - (g)**動畫扭曲**:stride warping(步幅依膠囊速度縮放)、orientation warping(下半身
>   轉向 strafe 方向)、slope warping、motion warping(翻越的 root motion 扭曲到 1.3 m 外
>   的牆緣)、distance matching(依剩餘煞停距離選 clip 時間);消除 17.1 控制器速度與 clip
>   速度不同時的滑步。
> - (h)**方向性(polar)2-D 混合空間**:以(速度, 方向角)參數化、±180° 接縫環繞(例:
>   8 向 strafe 從 170° 轉到 −170° 時不經過 0° 的前進 clip)。
> - (i)**動畫 LOD / 更新率預算**:遠處骨架降頻、減骨、更新之間插值,在每幀 ms 預算下
>   排程(例:1000 個群眾角色的動畫成本固定);是 17.31 物理 LOD 的動畫對應。
> - (j)**動畫資料匯入**:非均勻關鍵幀通道重取樣成均勻 `AnimClip`;glTF skin / animation
>   channel 與 BVH mocap → `Skeleton` + `AnimClip`(例:真 mocap 餵 `MotionDB` 與重定向,
>   取代測試裡用程式碼生成的 clip)。
> - (k)**骨骼插槽**:具名 socket(骨索引 + 局部偏移),實體 / collider / kinematic 剛體每幀
>   跟隨動畫骨的世界姿態(例:劍的 collider 掛在右手骨);含 17.6 待辦「骨架階層世界矩陣
>   組合」:`to_world` 已有 FK,缺的是世界姿態 × 逆 bind pose 進蒙皮(範例 24 仍以局部
>   motor 直接 `skin_motor`,`examples/24_locomotion_graph.mojo:121-124`)。需要 `ecs` 與
>   `physics`,落在 `gameplay`(第 5 層)。
> **對照組**:UE5 Inertialization 節點(Bollo, GDC 2018)、Holden「Dead Blending」(2023);
> UE5 Pose Search / Game Animation Sample、Clavet「Motion Matching」(GDC 2016)、Learned
> Motion Matching(2020)的 AABB 剪枝;UE5 IK Retargeter、Godot 4 `SkeletonProfile` /
> `BoneMap`;ACL(UE5 與 Godot 外掛)、ozz-animation keyframe optimizer;UE AnimNotify +
> Sync Markers、Unity AnimationEvent、Bevy AnimationEvent;UE5 Animation Warping / Motion
> Warping / Distance Matching;Unity Mecanim 2D Freeform Directional;UE Animation Budget
> Allocator + URO;glTF 2.0 匯入器(Godot、Bevy);UE Sockets、Godot `BoneAttachment3D`。
> **本庫內部對照**:`AnimPlayer` cross-fade(11.3)、暴力 `MotionDB.query`、同拓撲
> `retarget`、`physics/lod.mojo`(17.31)。
> **優勢區**:
> - (a)中 —— 姿態偏移取 motor 商(`make_additive` 已有,`procedural/anim_graph.mojo:258-264`)
>   再沿 motor 測地衰減,旋轉與平移一起走螺旋;對照組多半位置與四元數分開衰減。成本可直接
>   對 11.3 的 3.4× 量:慣性化只取樣一個 clip。
> - (d)(g)中 —— bind pose 差補償是 motor 商、warping 的根位移修正沿 motor 測地分配,與
>   17.6 加法動畫同一套運算。
> - (e)(f)中 —— 量化後解壓逐位可重現、marker 依固定 tick 決定論觸發,兩者都能直接進
>   17.39 回放與 17.16 rollback。
> - (b)(c)(h)(i)(j)(k)低 —— 純工程。
> **規模軸**:骨數 × 同時活躍角色數;MotionDB 幀數(10³–10⁶)× 特徵維度;壓縮率 vs 最大
> 骨端誤差;LOD 預算(ms)vs 角色數;每秒過渡次數。
> **seam?**:是 —— 四處,皆補進 CATEGORY §2.9(動畫圖節點):
> - 過渡策略:cross-fade(現況)vs 慣性化 → parity(過渡長度 0 時兩者逐位等於目標 clip;
>   同姿態切換時偏移為 0,慣性化與單一 clip 逐位相同)+ bench(每過渡每骨成本,對 11.3 的
>   170 ns)。
> - 最近幀搜尋:暴力 `MotionDB.query` vs 加速結構 → parity(精確搜尋時回傳同一幀索引)+
>   bench(幀數掃描)。
> - clip 儲存:原始 vs 壓縮 → parity(取樣誤差 ≤ 宣告界;誤差界 0 時逐位相同)+ bench
>   (記憶體、每骨取樣 ns)。
> - 動畫更新率:全頻 vs LOD → parity(LOD 關閉時與現況逐位相同)+ bench(角色數掃描)。
> - 非 seam:(b)(d)(f)(g)(h)(j)(k),功能測試即交付;(h)沿用 2-D 空間的 parity(樣本點
>   上權重恰為 one-hot)。
> **交付**:普通(idle→walk 慣性化過渡相鄰幀骨端速度連續;軌跡特徵挑到朝向正確的起步幀;
> polar 空間 8 向;footstep marker 每週期恰一次;劍跟手)/ 整合(接
> `examples/24_locomotion_graph.mojo` 的 FSM → 混合空間 → root motion → 17.1 控制器路徑:
> 控制器速度 ≠ clip 速度時 stride warping 使著地腳的水平滑移下降(以 17.3 `foot_plant`
> 落點逐幀量;foot-lock 在程式碼零命中);marker 經 `gameplay` 進 17.38 `Channel`,動畫
> 播放狀態進 17.39 快照後回放逐位重現(現 `SimState` 只含場景 + 控制器 + RNG,
> `gameplay/replay.mojo:38-42`);socket 上的 collider 被 17.13 `ray_cast` 命中;匯入的
> glTF clip 經壓縮、重定向後驅動 `Ragdoll.follow`)/ 極端(零長度過渡、過渡中再過渡、NaN
> 特徵、空 MotionDB、10⁶ 幀查詢、骨數不同且骨名缺漏的映射、誤差界 0、恰在 loop 邊界的
> marker 不重複不漏、方向角恰為 ±180°、預算 0 ms、只有一個 key 的通道、socket 所掛的骨或
> 實體被刪除)。
> **相依**:17.6(母項;其待辦的 polar、加速結構、世界矩陣組合由此編號)、11.3、17.1、17.3
> (`foot_plant` / `two_bone`,重定向的 IK 修正;17.3 缺口所列 foot-lock 尚未實作)、17.13、
> 17.31、17.38、17.39、17.12(glTF 來源)、17.53(kNN 索引);17.66(起身接慣性化)與
> 17.67(上攀 / 翻越用 motion warping)建在本條上;解鎖 17.71(逐骨命中框、近戰揮擊掃掠
> 建在 socket 與 notify 視窗上)。17.72 的通用系統降頻與 (i) 分工:本條只做動畫專屬的
> 減骨與更新間插值。
> **邊界**:核心提供 marker 事件、socket 世界姿態、通道重取樣與 BVH 文字(bytes)解析;
> 腳步聲 / 特效播放、glTF 容器解碼(二進位 buffer / accessor,隨 17.12 走宿主或其匯入器)、
> FBX 與檔案 I/O 屬宿主。

#### 17.65 蒙皮形變資料(morph target / 臉部 / 姿勢空間修正) — Wave C

> **緣起**:2026-10-09 負空間盤點,合併 3 筆:morph target / blend shape、臉部動畫(FACS / viseme / lip-sync)、姿勢空間修正與 ML deformer。
> 三項在 docs 與程式碼皆零命中。
> **現況**:`geometry/skinning.mojo:57-68` `skin_motor` 與 `:71-89` `skin_lbs` 每頂點只混
> 兩骨(`idx_a` / `idx_b` / `w_a`,`w_b = 1 − w_a`),輸入是固定的 rest 位置,蒙皮前沒有
> 逐頂點位移通道;candy-wrapper 只靠 motor DLB 處理(`:1-9`、範例 07、3.4「Gate」)。
> `procedural/anim.mojo:46-60` `AnimClip` 只有骨骼 pos / rot 軌,沒有純量曲線軌。
> `procedural/ik.mojo:174-191` `look_at`(錐角限制)可轉眼骨,但沒有視線控制器。grep 於
> docs 與程式碼皆零命中:`morph.?target`、`blend.?shape`、`shape.?key`、`vertex.?anim`、
> `facial`、`viseme`、`phoneme`、`lip.?sync`、`FACS`、`ARKit`、`表情`、`臉部`、`口型`、
> `pose.?space`、`corrective`、`pose.?driver`、`RBF`、`radial.?basis`、`ML.?deformer`、
> `delta.?mush`、`twist.?bone`(`視線` 只命中 17.15 的 AI 視線查詢)。
> **缺口**:
> - (a)**morph target / blend shape**:稀疏逐頂點位移(位置,可選法線)集合,依權重加總
>   後再蒙皮;CPU 參考實作 + 給宿主 GPU 的扁平 SoA 佈局(同 `skin_motor` 的扁平欄)。臉與
>   肩的權重常需兩骨以上,每頂點影響數一併擴到 4 / 8(例:20k 頂點頭部 `smile` = 0.7、
>   `blink_L` = 1.0)。
> - (b)**純量曲線軌**:`AnimClip` 之外的逐通道 float 曲線,與骨軌走同一套混合 / 加法 / 層
>   (例:walk / run 混合中 `breath` 權重隨 1-D 空間平滑變化)。
> - (c)**臉部動畫**:FACS / ARKit-52 通道集;viseme 序列 → 權重曲線,輸入是宿主給的音素
>   時間軸;眼睛視線控制器(`look_at` + 眼跳時序 + 眨眼)(例:NPC 說一句對白時口型對上
>   音素時間軸,視線鎖定玩家頭部)。
> - (d)**姿勢空間修正(PSD)**:RBF pose driver 由關節旋轉插值出修正 morph 權重或 twist 骨
>   值,修肘部與肩部塌陷(例:手肘彎到 130° 時自動疊加 `elbow_corrective`)。
> - (e)**學習式修正變形的接點**:核心只提供「逐頂點修正位移」的 deformer seam,由外部提供
>   的模型填值(對應 UE ML Deformer 的角色);核心不內建 NN 推論 runtime,與 2026-10-09
>   使用者排除 RL 與機器人時的邊界相同。
> **對照組**:UE Morph Targets + Pose Driver(RBF)+ ML Deformer、Unity
> `SkinnedMeshRenderer` BlendShapes、glTF 2.0 morph targets、Godot blend shapes;UE5
> MetaHuman + Live Link Face、NVIDIA Audio2Face、Unity Face Capture、Oculus Lipsync;Maya
> PSD、Ziva、delta mush。**本庫內部對照**:`skin_motor`(motor DLB)vs `skin_lbs`。
> **優勢區**:
> - (d)低-中 —— RBF 的姿態距離可取相對 motor 的 log(`log_motor3`,
>   `geometry/galie.mojo:88`),旋轉與平移在同一度量下;仍需先做 `blend_bone` 那樣的半球
>   對齊(`procedural/anim.mojo:191-194`)。
> - (a)中 —— 權重 → 頂點是線性映射,對權重的導數是常數矩陣,可用既有 `Field` 前向 AD
>   (`DualReal`,`geometry/field.mojo:97`)從目標網格反推權重,並以有限差分對照。
> - (b)(c)(e)低 —— 純工程。
> **規模軸**:頂點數 × 活躍 target 數(稀疏度);RBF 樣本姿態數 × 驅動關節數;每頂點骨
> 影響數(2 / 4 / 8)。
> **seam?**:是 ——
> - morph 求值:稠密(每 target 全頂點)vs 稀疏(只存非零位移)→ parity(固定加總順序下
>   輸出頂點逐位相同)+ bench(稀疏度掃描)。
> - 修正變形:無修正 vs PSD vs 外部 deformer → parity(修正量為 0 時三者與 `skin_motor`
>   逐位相同;RBF 在樣本姿態上恰回傳樣本權重)+ bench(每頂點成本)。
> - 每頂點影響數:2 骨(`skin_motor`)vs N 骨 → parity(只有兩個非零權重時逐位相同)+
>   bench。
> **交付**:普通(單一 target 權重 0 / 0.5 / 1;viseme 序列產生權重曲線;RBF 樣本點恰還原)
> / 整合(動畫圖輸出骨姿 + 曲線軌 → morph → `skin_motor`,接
> `examples/24_locomotion_graph.mojo` 的蒙皮段;PSD 由 17.3 IK 解出的手肘角驅動(需 17.3
> 待辦的 IK → 逐骨旋轉);權重曲線在 17.39 回放中逐位重現)/ 極端(全部權重 0 時與無 morph
> 逐位相同、負權重與權重 > 1、空 target、10⁵ 頂點 × 200 target、RBF 樣本重合(奇異矩陣 →
> 正則化並記 `diag` 計數)、驅動關節在 q 與 −q 間跳)。
> **相依**:11.3 / 17.6(曲線軌沿用同一套混合)、17.3(`look_at` 與 IK 角)、17.64(glTF
> morph target 與權重通道走同一條匯入路徑,壓縮也適用曲線軌)、17.12(資產來源)、17.52
> (變形後的網格要碰撞時走可變形 mesh collider)、17.57(彈簧骨 / 肌肉次級動態疊在本條
> 之上)。
> **邊界**:核心產出權重與逐頂點位置 / 法線陣列;GPU 上的 morph / 蒙皮著色、從音訊抽音素、
> 臉部擷取裝置、ML 模型的訓練與推論屬宿主。

#### 17.69 程序化內容生成 — Wave C

> **緣起**:2026-10-09 負空間盤點,合併 10 筆:OpenSimplex2 與 SIMD 批次取樣、地形生成與侵蝕、Poisson-disk 散布、WFC、地城 / 關卡生成、L-system / 植物生成、程序化網格建構、等值面擷取、三角網格布林運算、瓦片 / 六角格。
> 11.1「進度」與「用途」留下兩項未編號的「留後續」:「OpenSimplex2 留後續」與「SIMD 批次採樣
> 留後續優化」;11.1「用途」的「地形 / heightfield(接 8.2)」與 13.8「優勢」的「程序化地形」
> 只是可能用途,沒有條目建它;(I) 表的「程序化」列只有 11.1 noise。
> **現況**:
> - `procedural/__init__.mojo:1` 自述「seedable noise family」;`procedural/noise.mojo:72-212`
>   只有 `value3` / `perlin3` / `perlin2` / `worley3` / `fbm3` / `fbm2`,逐點純量;noise 只被
>   `tests/test_noise.mojo` 與 `benchmarks/bench_noise.mojo` import,沒有生成器呼叫它。
> - `geometry/sdf3.mojo:30-33`、`:37` `Sdf3` 是兩層的隱式 CSG(`OP_UNION` / `OP_INTERSECT`
>   / `OP_SUBTRACT`);`geometry/convex_decomp.mojo:42`、`:101` `VoxelGrid` / `voxelize`
>   只做網格 → 體素,沒有反方向;`geometry/fracture_cut.mojo:189` `cut_by_planes` 只切凸
>   多面體(17.5「待辦」:只切**凸**實體);`geometry/fracture_cut.mojo:61-87`
>   `scatter_seeds` 是均勻 / 聚焦亂數(Voronoi 破碎用),沒有最小間距。
> - 網格建構只有測試夾具 `harness/meshes.mojo:25-76`(`prism` / `l_prism` / `u_prism` /
>   `box_mesh`),引擎套件不得 import(`scripts/arch_layers.toml:18-22`)。
>   `collision/trimesh.mojo:122`、`:244` 的 `TriMesh` / `HeightField` 建構子吃扁平陣列;17.30
>   `HeightField.deform`(`:295`)是執行期編輯,不是生成。
> - grep 於 docs 與程式碼皆零命中:`marching`、`dual.?contour`、`iso.?surface`、
>   `surface.?nets`、`procedural.?mesh`、`loft`、`icosphere`、`erosion`、`侵蝕`、
>   `diamond.?square`、`terrain.?gen`、`blue.?noise`、`bridson`、`halton`、`wave.?function`、
>   `WFC`、`constraint.?propag`、`L-system`、`lindenmayer`、`turtle`、`space.?colon`、
>   `dungeon`、`roguelike`、`graph.?grammar`、`cellular.?automat`、`tilemap`、`tile.?map`、
>   `六角`、`瓦片`、`auto.?til`;docs 的 `CSG` 只指 SDF(`docs/CATEGORY.md:150`)。
> **缺口**:
> - (a)**雜訊補完**:OpenSimplex2(2D / 3D,沒有 Perlin 的軸向紋理)、ridged / billow 變體、
>   SIMD 批次取樣(一次 W 個點,同 `BatchReal[W]` 慣例)(例:512 × 512 heightfield 一次
>   填滿);11.1 的兩項「留後續」由此編號。
> - (b)**地形生成 + 侵蝕**:fBm / ridged → `HeightField` 高度陣列,水力侵蝕(液滴法或淺水
>   法)+ 熱侵蝕(安息角)(例:產生帶河谷的 1 km² 地形,直接當 8.2 collider);局部重算可接
>   17.30 的區塊摘要。
> - (c)**Poisson-disk / 藍噪聲散布**:Bridson O(n) 取樣 + 坡度 / 密度 / 排除區過濾(例:在
>   heightfield 上以 3 m 最小間距放 5 萬棵樹,坡度 > 35° 與道路樣條兩側 4 m 內不放)。
> - (d)**WFC 拼塊生成**:鄰接規則或範例點陣 → 約束傳播 + 決定論回溯,2D / 3D(例:
>   Townscaper 式城鎮、帶入口約束的房間)。
> - (e)**地城 / 關卡佈局**:BSP 分房、細胞自動機洞穴、任務圖文法(鎖鑰順序)(例:40 房
>   roguelike 樓層,保證鑰匙在門之前可達)。
> - (f)**L-system / space colonization**:文法改寫 + turtle 解譯,或 space colonization
>   分枝,輸出樹 / 植物骨架(節點 + 半徑)(例:產生 200 棵各異的樹,枝幹交給 17.61 植被
>   風擺或 17.41 繩索鏈)。
> - (g)**網格建構器**:基本體(box / icosphere / capsule)、多邊形擠出、沿 17.36 樣條掃掠
>   (RMF 標架,不扭轉)、放樣,輸出頂點 / 索引陣列可直接建 `TriMesh` collider(例:沿樣條
>   產生賽道路面與護欄 collider)。
> - (h)**等值面擷取**:marching cubes / surface nets / dual contouring,輸入 `Sdf3`、
>   `VoxelGrid`、密度格或粒子場(例:可挖掘體素地形改動後局部重新網格化並重建 collider;
>   17.63 的流體表面輸出重用同一擷取器)。
> - (i)**三角網格布林運算**:聯集 / 差集 / 交集,含共面與退化處理(例:執行期在牆網格挖出
>   門洞並重建其 collider;17.5 只切凸體、SDF CSG 只在隱式場)。
> - (j)**格子 / 六角格資料模型**:方格、等角、六角(axial / cube 座標:鄰居、距離、直線、
>   環)、分塊 tile 儲存、auto-tiling 規則(例:策略遊戲的六角地圖、2D 平台遊戲的 tile
>   碰撞);回合制、行動點等規則在 17.70。
> - 分層:`procedural`(第 2 層)不得 import `collision`(第 3 層),生成器輸出扁平陣列,
>   collider 由呼叫端或 `gameplay` 建;(g)(h)(i)的網格演算法放第 1 層 `geometry`,與
>   `polytope` / `convex_decomp` 同層。
> **對照組**:OpenSimplex2 / FastNoiseLite(Godot 4 內建)、Houdini HeightField Erode、Gaea /
> World Machine、UE5 Landscape 侵蝕工具;Bridson(SIGGRAPH 2007)、UE5 PCG Framework
> (Surface Sampler、Self Pruning)、Houdini Scatter;mxgmn/WaveFunctionCollapse、Townscaper、
> Bad North;Dormans 圖文法(Unexplored)、Spelunky 房間模板、Brogue 細胞自動機;Prusinkiewicz
> 《The Algorithmic Beauty of Plants》、SpeedTree、Runions space colonization(2007);UE5
> Geometry Script / Dynamic Mesh、`SplineMeshComponent`、Unity ProBuilder、Godot `SurfaceTool` /
> CSG;OpenVDB VDB-to-polygons、NVIDIA Warp `MarchingCubes`;Manifold、CGAL / libigl 布林;
> Godot 4 `TileMapLayer` / `GridMap`、Unity Tilemap、bevy_ecs_tilemap、Red Blob Games 六角
> 參考。**本庫內部對照**:`Sdf3` 隱式 CSG((i)的隱式對照)、`scatter_seeds`((c)的均勻
> 對照)、`cut_by_planes`(凸切)。
> **優勢區**:
> - 決定論(全部)中 —— 生成器以 seed 為唯一輸入;11.1「進度」已用整數格點雜湊而非 RNG
>   狀態做到跨機器決定性,所以網路遊戲只需傳 seed,存檔只需存 seed + 編輯差分。
> - (i)中 —— 10.1 exact predicates(`geometry/predicates.mojo`)讓共面 / 退化處的布林結果
>   watertight,這是網格布林最常出錯的地方。
> - (h)中 —— 擷取出的網格可回頭以 `Sdf3.distance` 驗誤差,距離場就是 oracle。
> - (g)低-中 —— 樣條掃掠用 17.36 的 RMF motor 標架,天生不扭轉。
> - (a)(b)(c)(d)(e)(f)(j)低 —— 純工程。
> **規模軸**:取樣點數(10⁴–10⁷)× SIMD 寬度;地形解析度 × 侵蝕迭代;WFC 格數 × 拼塊數
> (回溯次數);體素解析度 vs 擷取三角數;布林輸入三角數。
> **seam?**:是 ——
> - 等值面擷取:marching cubes vs surface nets(vs dual contouring)→ parity(對球 / 盒
>   SDF,頂點到零面的距離 ≤ 半格、網格封閉、體積隨解析度收斂到解析值)+ bench(解析度
>   掃描)。
> - 雜訊取樣:純量 vs SIMD 批次 → parity(逐點相同;若乘加收縮使 SIMD 與純量不逐位,記錄
>   量到的界,同 17.18 `BatchReal` 的先例)+ bench(點 / s,對 11.1 的 perlin3
>   26.7 ns / sample)。
> - 布林:網格布林 vs SDF CSG 再擷取 → parity(體積與點包含測試一致,容差隨解析度)+ bench。
> - 散布:均勻亂數 vs Poisson-disk → 差異當行為斷言(最小間距只有後者成立)+ bench。
> - 非 seam:(b)(d)(e)(f)(g)(j),功能與決定論測試即交付(侵蝕另驗質量守恆:侵蝕量 =
>   沉積量 + 流出邊界量)。
> **交付**:普通(同 seed 逐位相同、異 seed 不同;球 SDF 擷取出封閉網格;Poisson 最小間距
> 成立;WFC 小規則集收斂;六角距離 / 鄰居對 Red Blob 參考值)/ 整合(生成地形 →
> `HeightField` collider → 散布的樹成為靜態 collider → 17.1 角色走上去、17.14 navmesh
> 烘焙;樣條掃掠的路面 → `TriMesh` → 17.4 載具行駛;體素挖洞 → 擷取 → collider 重建 →
> 睡眠體喚醒(17.25);門洞布林後的牆能被 17.13 查詢正確穿過)/ 極端(空輸入 / 零格、seed
> 極值、WFC 無解(回報矛盾,不無限迴圈)、地城只有 1 房或鑰匙不可達、等值面恰經過格點、
> 布林共面 / 相切 / 完全包含 / 空交集、10⁷ 點散布、六角座標極大值)。
> **相依**:11.1(母項)、8.2、13.8(`Sdf3`)、17.5(凸切與 `VoxelGrid`;(i)補上凹體)、
> 17.30、17.36、10.1、17.14(在生成的關卡上烘焙 navmesh)、17.25、17.12(生成結果的資產化
> 隨宿主格式);與 17.52(體素碰撞形狀可共用體素資料)、17.61(植被風擺吃 (f) 的骨架)、
> 17.63(流體表面輸出重用 (h))、17.70(回合制 / 網格規則建在 (j) 上)相接。
> **邊界**:核心產出資料(高度陣列、點集、拼塊索引、頂點 / 索引陣列、植物骨架);著色、
> 材質、渲染用 LOD 網格與資產匯出屬宿主;PCG 節點圖 UI 屬(III)編輯器本體。

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
| 17.66 | [物理角色控制與學習式動畫接點](#1766-物理角色控制與學習式動畫接點--wave-c) | ⬜ | C | 2026-10-09 盤點新增:IK 關節限制與全身平衡、倒地起身、平衡控制 / MPC / 軌跡最佳化、程序化多足步態、學習式物理角色控制、學習式運動學動畫 |
| 17.67 | [角色移動模式與控制器變體](#1767-角色移動模式與控制器變體--wave-b) | ⬜ | B | 2026-10-09 盤點新增:角色移動模式(游泳 / 攀爬 / 抓緣 / 上攀 / 翻越)、動態剛體角色控制器、移動參考系 / 局部空間模擬 |
| 17.68 | [遊戲攝影機、序列器與協程](#1768-遊戲攝影機序列器與協程--wave-b) | ⬜ | B | 2026-10-09 盤點新增:遊戲攝影機(彈簧臂、跟隨 / 環繞阻尼、震動、混合)、過場序列器 / 時間軸、協程 / latent action |
| 17.71 | [戰鬥與互動物理(彈道 / 物理抓取 / 逐骨命中框 / 近戰掃掠)](#1771-戰鬥與互動物理彈道--物理抓取--逐骨命中框--近戰掃掠--wave-b) | ⬜ | B | 2026-10-09 盤點新增:彈道(下墜 / 阻力 / 穿透 / 跳彈)、物理抓取、近戰揮擊掃掠、逐骨命中框 |
| 17.74 | [載具家族擴充與地面力學(履帶 / 機車 / 飛行器 / 多旋翼 / 船舶推進 / 輪-土壤)](#1774-載具家族擴充與地面力學履帶--機車--飛行器--多旋翼--船舶推進--輪-土壤--wave-c) | ⬜ | C | 2026-10-09 盤點新增:4 輪 raycast 車以外的載具家族(履帶車 / 機車 / 飛行器 / 多旋翼 / 船舶推進)、可變形地形上的輪-土壤地面力學 |

### 已完成條目的遺留待辦

這些條目已完成並移到歷史檔,但各自記下了尚未做的部分:

- **17.1**([紀錄](ROADMAP_HISTORY.md#171-kinematic-角色控制器--wave-a)):seam 對照:掃掠底層 raycast 近似 vs 真 shape-sweep 的 parity 測試(同場景落點一致)+ bench 尚未做
- **17.1**([紀錄](ROADMAP_HISTORY.md#171-kinematic-角色控制器--wave-a)):接 `gameplay.runtime`:目前由呼叫端每步呼叫 `update`(examples/21_runtime_character.mojo:54 仍是手動呼叫 `c.update(rt.scene, ...)`)
- **17.2**([紀錄](ROADMAP_HISTORY.md#172-主動布娃娃--物理動畫--wave-b)):驅動器序列化(AngularDrive 未入快照)
- **17.2**([紀錄](ROADMAP_HISTORY.md#172-主動布娃娃--物理動畫--wave-b)):關節角度限制(膝單向)
- **17.2**([紀錄](ROADMAP_HISTORY.md#172-主動布娃娃--物理動畫--wave-b)):起身時的姿態匹配與地面對齊
- **17.2**([紀錄](ROADMAP_HISTORY.md#172-主動布娃娃--物理動畫--wave-b)):以 PD 積分項消除穩態下垂(可選;目前 8 Hz 下垂 3.8°、20 Hz 0.7°)
- **17.4**([紀錄](ROADMAP_HISTORY.md#174-載具動力學--wave-c)):開放差速目前是平分扭矩;真開放差速應被抓地較差的輪限制(分裂 μ 路面抓地輪應一併削弱)
- **17.4**([紀錄](ROADMAP_HISTORY.md#174-載具動力學--wave-c)):Ackermann 轉向、前束 / 外傾
- **17.4**([紀錄](ROADMAP_HISTORY.md#174-載具動力學--wave-c)):輪的非懸吊質量(輪目前是運動學的)
- **17.4**([紀錄](ROADMAP_HISTORY.md#174-載具動力學--wave-c)):車輛狀態(輪速、檔位、轉向角)未入快照(同 17.29)
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
- **17.5**([紀錄](ROADMAP_HISTORY.md#175-破壞--破碎--wave-c)):`FractureSet` 與斷裂閾值未入快照(同 17.29)
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

#### 17.66 物理角色控制與學習式動畫接點 — Wave C

> **緣起**:2026-10-09 負空間盤點,合併 6 筆:IK 關節限制與全身平衡、倒地起身、平衡控制 / MPC / 軌跡最佳化、程序化多足步態、學習式物理角色控制、學習式運動學動畫。
> 其中兩項已被提過但未編號:17.2「進度」的待辦「關節角度限制(膝單向)、起身時的姿態匹配
> 與地面對齊、以 PD 積分項消除穩態下垂(可選)」,17.3「進度」的待辦「關節角度限制(膝只能
> 單向、肩錐)…全身 IK 的質心 / 平衡約束」;兩者都不在 Phase 17 建議順序 2026-10-09 修訂的
> 「剩餘順序」與「本輪遺留待辦」。學習式控制與學習式動畫只排接點:使用者 2026-10-09 排除
> RL 與機器人。
> **現況**:
> - `gameplay/ragdoll.mojo:98-106` `follow` 把動畫姿態設為驅動目標;
>   `physics/joints6.mojo:279-298` `AngularDrive` 是純 PD 軟馬達(hertz / zeta /
>   `max_torque`),無積分項、無平衡回饋;`gameplay/ragdoll.mojo:127-130` `blend_world`
>   只做權重混合,沒有正 / 反面判定、起身 clip 選擇或地面對齊。
> - `procedural/ik.mojo:53,103,134` 的 `two_bone` / `fabrik` / `fabrik_multi` 無角度限制
>   參數,只有 `look_at`(`:174-191`)夾錐角;IK 只輸出關節位置,轉回逐骨旋轉仍是 17.3
>   待辦。
> - 步態:`foot_plant`(`:209-221`)+ `two_bone` 只做雙足貼地
>   (`examples/24_locomotion_graph.mojo`);`physics/floating.mojo:5` 的 docstring 是
>   程式碼中唯一提到 quadruped 之處。
> - 控制:13.7「優勢」只寫可微 solver 讓「系統辨識、軌跡優化、可微控制全部解鎖」。可微子集
>   `physics/diffsolver.mojo:19-22` 只含動態球 + 靜態平面、無關節,17.18 的 `BatchReal[W]`
>   批次也只在這個子集上,所以梯度 MPC 目前穿不過 ragdoll;`ContactScene6` 只實作
>   `Movable, Deinitable`、不可複製(`physics/solver6.mojo:133`),展開候選只能經 6.10
>   `scene_to_string`(`physics/serialize.mojo:118`)存回,而序列化不含驅動器(該檔 grep
>   `drive` 零命中,即 17.2 待辦「驅動器序列化」)。
> - 學習式:`experiments/exp_clifford_nn.mojo` 是 learned-physics 探針,不是動畫或控制。
> - grep 於 docs 與程式碼皆零命中:`gait`、`步態`、`multi.?leg`、`hexapod`、`spider`、
>   `多足`、`四足`、`SIMBICON`、`capture.?point`、`ZMP`、`MPC`、`model predictive`、
>   `iLQR`、`DDP`、`LQR`、`DeepMimic`、`PFNN`、`phase.?funct`、`learned.?motion`、
>   `DeepPhase`、`motion.?diffusion`。
> **缺口**:
> - (a)**IK 關節限制 + 全身平衡**:鉸鏈單向、球窩錐角、扭轉範圍;多末端 IK 加「質心投影
>   落在支撐多邊形內」約束(例:角色伸手拿遠處物件時髖部後移,而不是膝蓋反折或傾倒)。
>   ragdoll 物理關節本身的角度限制屬 17.47,不在此。
> - (b)**倒地起身**:ragdoll 靜止判定(速度門檻 + 持續時間)、以骨盆朝向判正 / 反面、選
>   對應起身 clip、根位置與朝向對齊地面(17.13 `ray_cast` 取法向),再以 17.64 慣性化接回
>   動畫(例:被炸飛的 NPC 臉朝下落在 15° 坡上,起身不瞬移、不穿地)。
> - (c)**主動平衡 / 恢復步**:`AngularDrive` 之上的 PD 積分項與重力補償(13.1 RNEA 前饋)、
>   SIMBICON 式擺動腿回饋、capture point 決定踏步落點(例:active ragdoll 被橫向推一下時
>   跨一步站穩,推力超過上限才倒下)。
> - (d)**取樣式 MPC / 軌跡最佳化**:對 N 條候選控制序列展開、取最低成本(MPPI / CEM 類),
>   用在 active ragdoll 恢復與特技動作(例:預演 8 條踏步序列,挑一條不跌倒的);梯度式
>   (iLQR)等 17.20 可微子集擴到關節後再做。
> - (e)**程序化多足步態**:N 足步態排程(交替組 / 相位、依身體速度定步長與時機)、以
>   17.13 查詢找落腳點、每腳 `two_bone` / `fabrik`、身體高度與傾角由支撐腳擬合平面(例:
>   6 足蜘蛛走過 17.30 炸出坑的 heightfield,沒有任何 authored clip)。
> - (f)**外部控制器接點**(學習式物理角色,DeepMimic / AMP / PHC 類的落點):一個 trait,
>   每 tick 讀角色狀態(關節角 / 角速度、根姿態、接觸旗標)並回傳各驅動器目標;核心只定義
>   接點與狀態讀出,外部提供的控制器在此插入。不規劃 Gym API、獎勵、訓練或 NN 推論 runtime。
> - (g)**外部姿態生成器接點**(學習式運動學動畫,PFNN / Learned Motion Matching / motion
>   diffusion 類的落點):與 `MotionDB` 同形的 pose source seam,外部模型每幀回傳根位移 +
>   姿態;核心內建的實作只有資料庫式一種。
> **對照組**:UE5 Full Body IK / Control Rig、FinalIK FullBodyBipedIK、Unity Animation
> Rigging;UE5 Physical Animation 與起身範例、Unity PuppetMaster、NaturalMotion Euphoria;
> SIMBICON(Yin 2007)、capture point(Pratt 2006)、MuJoCo MPC(MJPC)、Drake;Rain World
> 與 Spore(Hecker 2008)的程序化步行;(f)(g)的外部使用者:DeepMimic / AMP / PHC、PFNN /
> Learned Motion Matching / MDM。**本庫內部對照**:17.2 純 PD `AngularDrive`、17.3
> `two_bone` / `fabrik`、`MotionDB`。
> **優勢區**:
> - (a)低-中 —— 限制可在 motor log(`log_motor3`,`geometry/galie.mojo:88`)座標上夾;
>   17.3 優勢區所寫的可微 IK(`experiments/exp_autodiff.mojo` 的 AD-IK 探針)加上限制即是
>   帶界最佳化,可與閉式 / FABRIK 交叉驗證。
> - (c)(d)中 —— 決定論快照讓每條候選展開可精確重現(快照須先含驅動器);可微子集擴到關節
>   後,梯度 MPC 是 17.20 的直接用途,取樣式與梯度式可在同一問題上對照。
> - (b)(e)低 —— 純工程。
> - (f)(g)接點本身無優勢;決定論的狀態讀出讓外部控制器的行為能在 17.39 回放。
> **規模軸**:IK 鏈長 × 限制數 × 迭代;推力大小 vs 恢復率;MPC 候選數 × 展望步數 vs 每幀
> ms;足數 × 地形起伏;同時活躍的 active ragdoll 數。
> **seam?**:是 ——
> - IK 限制:無限制 vs 限制 → parity(目標落在限制內時與現 `two_bone` / `fabrik` 逐位
>   相同)+ bench(每解 ns),擴充 CATEGORY §2.10。
> - 姿態控制器:純 PD 跟隨(`Ragdoll.follow`)vs 平衡回饋 → parity(回饋增益 0 時逐位相同)
>   + bench(每骨每步成本、推力恢復率),擴充 CATEGORY §2.11。
> - 控制器 / 姿態來源接點:內建實作 vs 外部實作 → parity(外部回傳與內建相同的目標 /
>   姿態時逐位相同)。
> - MPC:取樣 vs 梯度(之後)→ parity(一維可解析問題上最佳控制一致,容差內)+ bench。
> - 非 seam:(b)(e),功能測試即交付。
> **交付**:普通(膝 IK 不反折;正 / 反面各選對起身 clip;6 足在平地直走)/ 整合(接 17.2
> `Ragdoll` + `ContactScene6`:受擊 → 軟癱 → 靜止 → 起身(17.64 慣性化)→ 交回 17.1 控制器,
> 全程在 17.39 回放逐位重現(需先補 17.2 待辦的驅動器序列化);多足步態在 17.30 變形
> heightfield 上以 17.13 查詢落腳;被 17.27 徑向力推動後踏步恢復)/ 極端(目標在限制外、
> 限制區間為空、側躺(非正非反)、起身處被牆擋、懸空時請求起身、推力超過可恢復上限(倒下
> 而非 NaN)、MPC 展望 0 步或候選 1 條、0 足 / 1 足、外部控制器回傳 NaN(隔離並記 `diag`
> 計數))。
> **相依**:17.2(母項待辦:起身、PD 積分項、驅動器序列化)、17.3(母項待辦:關節限制、
> 質心平衡、IK → 逐骨旋轉)、17.47(物理關節限制)、17.64(慣性化、motion warping)、17.13、
> 17.27、17.30、13.1(RNEA 前饋)、17.18 / 17.20(MPC 的批次與梯度;`ContactScene6` 本體
> 批次與關節可微是兩者的待辦)、6.10(展開用快照)、17.39。
> **邊界**:訓練、獎勵、觀測封裝與 NN 推論都在核心之外;核心提供狀態讀出、控制器 / 姿態
> 來源 trait 與決定論步進。

#### 17.67 角色移動模式與控制器變體 — Wave B

> **緣起**:2026-10-09 負空間盤點,合併 3 筆:角色移動模式(游泳 / 攀爬 / 抓緣 / 上攀 / 翻越)、動態剛體角色控制器、移動參考系 / 局部空間模擬。
> 三類在 docs 與程式碼皆無規劃。
> **現況**:
> - `gameplay/character.mojo:61-69` `CharacterController` 的狀態只有 position / velocity /
>   on_ground / ground_normal / ground_body / hit_ceiling / pushed,沒有移動模式;`:1-9`
>   自述是 kinematic、「never enters the contact solver itself」;膠囊恆為垂直(`:30`),
>   上方向寫死 `_UP`(`:40`),`update` 只取 `gravity[1]`(`:278`),所以 17.27 的逐體
>   重力覆寫(`physics/body_set.mojo:109-115`)不影響角色;陡坡「只滑不爬」(`:172-175`)。
>   17.1「缺口」範圍止於蹲伏、移動平台、推擠,Jolt `CharacterVirtual` 只在 17.1「對照組」。
> - 17.28 `WaterVolume`(`physics/fields.mojo:181-186`)只對剛體施浮力,控制器不讀。
> - 移動參考系的唯一先例是 `physics/chain.mojo:203-219` `Chain.set_base_motion`:縮座標鏈在
>   給定的移動根座標系下計算,`FloatingChain` 每次掃描前呼叫(`physics/floating.mojo:91`、
>   `:150`);`ContactScene6` 剛體、最大座標 ragdoll、布料都只在世界系模擬。17.8 rebasing
>   處理遠離原點的精度,不是移動座標系。
> - grep `swim`、`mantl`、`vault`、`parkour`、`wall.?run`、`movement.?mode`、`攀`、`翻越`、
>   `移動模式`、`dynamic character`、`動態角色`、`non-?inertial`、`reference.?frame`、
>   `local.?space`、`參考系`、`fictitious` 於 docs 與程式碼皆零命中;`moving.?frame` 只命中
>   `BENCHMARK_REPORT.md:1206` 的 SAP 測試描述(指模擬幀);`游泳` 只命中 17.14 增補
>   「3D 體積導航(飛行 / 游泳 agent)」;程式碼的 `climb` 都是上坡、台階、載具爬坡或曲線
>   上升(如 `gameplay/character.mojo:173`、`tests/test_character.mojo:74`、
>   `examples/21_runtime_character.mojo:72`),`ledge` 只是 `tests/test_fracture.mojo:14`
>   的靜態台座夾具;Coriolis 只出現在 6.4「進度」的除錯記錄,離心項只出現在 13.6「設計」的
>   IMU。
> **缺口**:
> - (a)**移動模式狀態機**:walking / falling / swimming / flying / climbing / custom,各模式
>   有自己的重力、摩擦、可走判定與 move-and-slide 規則,切換由查詢與體積觸發;上方向改為
>   可設定並讀逐體重力(例:走進 17.27 的反向重力區後角色翻轉、站上天花板)。
> - (b)**游泳**:依 17.28 `WaterVolume`(之後 17.60 水面)的浸沒深度切換,浮力與阻力作用
>   在控制器速度上,水面漂浮與下潛(例:跳進 1.8 m 深水池後浮在水面,按下潛鍵潛入)。
> - (c)**攀爬 / 抓緣 / 上攀 / 翻越**:以 17.13 `sphere_cast` / `capsule_cast` 偵測牆緣高度與
>   頂面可站空間、懸掛、上攀(mantle)與翻越(vault)路徑,動畫端以 17.64 motion warping
>   對準牆緣;沿表面法向的牆面攀爬與梯子(例:抓住 1.8 m 高的牆緣拉上去,翻過 1 m 矮牆
>   不卡腳)。
> - (d)**動態剛體角色控制器**:角色是真的動態膠囊(鎖旋轉軸或以驅動保持直立),推擠、爆炸
>   衝量、站在動態物上都經解算器(例:被 17.27 徑向力炸飛、被重箱推下平台);與 kinematic
>   版並列為變體。
> - (e)**移動參考系 / 局部空間模擬**:剛體、ragdoll、布料、角色相對一個移動座標系(列車、
>   船、太空船艙)模擬,顯式加入虛擬力(座標系線加速度、離心、Coriolis、Euler 項)(例:
>   300 km/h 列車等速時車廂內的箱子靜止不抖,煞車時依虛擬力前滑)。
> **對照組**:UE `CharacterMovementComponent` movement modes(Walking / Falling / Swimming /
> Flying / Custom)、UE5 Mover 2.0、UE5 Game Animation Sample traversal、Unity Kinematic
> Character Controller、Godot `CharacterBody3D` 自訂狀態;Jolt `Character`(剛體)vs
> `CharacterVirtual`、PhysX / Unity Rigidbody 角色;UE Chaos 布料 local-space simulation、
> RigidBody AnimNode 的 simulation space、Unity Cloth `worldVelocityScale`、Star Citizen
> physics grids。**本庫內部對照**:17.1 kinematic 控制器((d)的另一端)、
> `Chain.set_base_motion`((e)在縮座標側的先例)。
> **優勢區**:
> - (e)中 —— 移動座標系的虛擬力在 screw 表述下由座標系 twist 的伴隨作用給出,
>   `Chain.set_base_motion` 已在縮座標掃描中帶這組項,推廣到 `ContactScene6` 是同一數學。
>   可量:世界系 vs 局部系在高速車廂內的接觸抖動與 f32 位置誤差。
> - (d)低-中 —— 動態角色走既有解算器,可與 kinematic 變體在同一場景直接對照。
> - (a)(b)(c)低 —— 純工程。
> **規模軸**:控制器數 × 每模式每步查詢數;牆緣偵測投射數 vs 誤判率;參考系速度 / 角速度
> vs 局部系與世界系的位置抖動;動態角色數 × 子步。
> **seam?**:是 ——
> - 控制器實作:kinematic(`CharacterController`)vs 動態剛體 → parity(平地等速行走、
>   台階、斜坡上限的位移與 `on_ground` 在容差內一致;被重箱推動只有動態版會位移,當行為
>   斷言)+ bench(N 控制器 × 步)。
> - 模擬座標系:世界系 vs 移動參考系 → parity(參考系靜止時逐位相同;等速直線參考系時兩者
>   軌跡在容差內一致,即伽利略不變,f32 下不要求逐位)+ bench(虛擬力額外成本、速度掃描下
>   的抖動曲線)。
> - 非 seam:(a)(b)(c),各模式功能測試即交付。
> **交付**:普通(走進水 → 游泳 → 出水回 walking;抓緣懸掛再上攀;動態控制器平地走與跳;
> 等速參考系內箱子靜止)/ 整合(控制器接 `gameplay.runtime`(17.1 待辦,現由呼叫端每步
> 呼叫 `update`)並進 17.39 回放:游泳讀 17.28 水體積、攀爬用 17.13 查詢、上攀動畫經 17.64
> warping 對準牆緣;動態控制器被 17.27 徑向力炸飛後落地恢復;17.24 kinematic 車廂內的
> ragdoll 與箱子在局部系模擬,煞車時前衝)/ 極端(水面恰在膠囊中心、牆緣恰為上限高度、
> 牆厚小於膠囊半徑、在移動平台邊緣抓緣、動態控制器被兩體夾擠、參考系角速度 10 rad/s、
> 實體進出車廂的當幀切換座標系)。
> **相依**:17.1(母項)、17.13、17.24(車廂 / 移動平台)、17.27(重力區、徑向力)、17.28 /
> 17.60(水體積與水面)、17.48(逐軸自由度鎖定,給動態角色)、17.64(motion warping、
> 慣性化)、17.66(動態角色的直立驅動可共用平衡控制)、17.8(rebasing,互補)、17.14(飛行
> / 游泳 agent 的 3D 導航)、17.0 F12(`Chain.set_base_motion`)。
> **邊界**:按鍵 → 意圖屬宿主;核心收移動意圖向量與模式請求,輸出姿態、模式與模式切換
> 事件。相機跟隨見 17.68。

#### 17.68 遊戲攝影機、序列器與協程 — Wave B

> **緣起**:2026-10-09 負空間盤點,合併 3 筆:遊戲攝影機(彈簧臂、跟隨 / 環繞阻尼、震動、混合)、過場序列器 / 時間軸、協程 / latent action。
> 遊戲攝影機邏輯不在多媒體排除範圍:Phase 17 緣起排除的是渲染主體 / 音訊 / 輸入;(III)
> 編輯器本體的「相機導覽」是編輯器視窗,不是遊戲相機。
> **現況**:
> - grep `camera`、`攝影機`、`相機`、`鏡頭`、`spring.?arm`、`cinemachine`、`screen.?shake`、
>   `trauma`、`第三人稱` 於程式碼零命中;docs 除了指向本條的 Phase 17 索引列,只有
>   `docs/design/wave-a-services.md:22`(樣條 RMF 標架讓「vehicle/camera following the
>   path」不扭轉)與 (III) 編輯器本體的視窗 / 相機導覽。
> - 零件已在:17.13 `sphere_cast`(`collision/world_query.mojo:418`)可做彈簧臂防穿牆;
>   17.36 `build_rmf_frames` / `frame_at_distance`(`geometry/spline.mojo:454`、`:485`)
>   可做軌道相機;17.35 `Tween`(`procedural/tween.mojo:220`)只有 Penner 緩動,沒有有狀態
>   的臨界阻尼彈簧(`critically.?damp` 只命中 `tests/test_diffrigid.mojo:152` 與
>   `BENCHMARK_REPORT.md:2262`,兩處都在說軟接觸的恢復係數)。
> - 序列:`sequencer`、`cutscene`、`timeline`、`過場`、`cinematic` 零命中;`時間軸` 只命中
>   (II) 表「時間軸拖動 / 回看模擬」列(→ 17.39 `seek`),那是回放拖動,不是編排序列。
> - 協程:17.35 `TimerQueue`(`scheduler/timers.mojo:90-100`)只排程「N tick 後以 id 觸發」
>   (`TimerFire`,`:79-87`),表達不了「等 2 秒 → 等門開完 → 再做」;`coroutine`、`協程`、
>   `await`、`latent`、`wait.?until` 零命中,`async` 只命中 `libAsyncRT` 執行期名稱與 GPU
>   非同步佇列註解。17.39 `SimState`(`gameplay/replay.mojo:38-42`)只含場景 + 角色控制器
>   + RNG。
> **缺口**:
> - (a)**遊戲攝影機邏輯**(headless,輸出相機姿態與參數):第三人稱彈簧臂以 `sphere_cast`
>   防穿牆並平滑回彈、臨界阻尼跟隨 / 環繞 / look-at、trauma 式震動(震幅 ∝ trauma²,以 11.1
>   noise 取樣)、多相機優先權與混合、沿 17.36 RMF 的軌道相機(例:玩家背靠牆時相機拉近
>   而不穿牆;爆炸後震動 0.4 s 內衰減完)。
> - (b)**臨界阻尼彈簧 / SmoothDamp**:有狀態、對任意 dt 穩定的一 / 二階彈簧,補 17.35 tween
>   沒有的部分,也給 17.64 慣性化與一般數值平滑用(例:同一跟隨以 30 Hz 與 144 Hz 步進,
>   軌跡差在容差內)。
> - (c)**序列器 / 時間軸**:多軌(transform、動畫 clip、事件、相機切換、屬性)、關鍵幀 +
>   緩動,以 sim tick 決定論播放、可 seek(例:門開 → NPC 走到標記點 → t = 3.2 s 觸發
>   ragdoll 與對白事件,回放逐位相同)。
> - (d)**協程 / latent action**:多幀 gameplay 邏輯寫成「等 N tick / 等條件 / 等事件」的
>   步驟,由固定 tick 決定論地恢復;步驟狀態要能進 6.10 快照與 17.40 存檔,所以以資料驅動
>   的步驟表實作(例:「等 2 秒 → 等門開完 → 生成三波敵人」,讀檔後從中斷處續跑)。
> **對照組**:UE5 `SpringArmComponent` + `PlayerCameraManager` + CameraShake + Gameplay
> Cameras plugin、Unity Cinemachine 3、Godot 4 `SpringArm3D` / `Camera3D`、Unity
> `Mathf.SmoothDamp`;UE5 Sequencer、Unity Timeline、Godot AnimationPlayer 多軌;UE latent
> actions / UE5Coro、Unity coroutines + Awaitable、Godot `await`、Bevy async tasks。
> **本庫內部對照**:17.35 `TimerQueue`(只做延遲觸發)、11.2 FSM(`procedural/fsm.mojo`)、
> 17.15 BT(另一種多幀邏輯,⬜)。
> **優勢區**:
> - (a)中 —— 相機混合與跟隨在 motor 測地上做,位置與朝向一起插值;17.7「進度」量到偏心
>   螺旋下 lerp + nlerp 偏離 0.29、測地 1e-7、dq-nlerp 6e-8,所以優勢是對 lerp + nlerp 類
>   對照組,不是對 DQ;軌道相機直接用 RMF motor 標架。
> - (c)(d)中 —— 以固定 tick 推進並進快照,序列與協程在 17.39 回放 / 17.16 rollback 中
>   逐位重現;依牆鐘時間恢復的協程做不到。
> - (b)低 —— 純工程。
> **規模軸**:活躍相機數 × 每相機每幀投射數;序列軌數 × 關鍵幀數 × 同時播放序列數;活躍
> 協程數 × 每 tick 恢復成本。
> **seam?**:是 ——
> - 協程等待佇列建在既有 `TimerQueue` seam 上(`TimerHeap` / `TimerWheel`)→ parity(同一
>   腳本兩後端的恢復序列逐位相同,同 `test_timers` 方格)+ bench(活躍協程數掃描)。
> - 相機混合重用 17.7 `PoseInterpolator`(`LerpNlerp` / `DqNlerp` / `MotorGeodesic`,
>   `gameplay/interpolation.mojo:58-93`)→ parity(權重 0 / 1 時逐位等於單一相機)+ bench。
> - 序列 seek:從頭播放 vs 直接求值於 t → parity(兩者結果逐位相同,同 17.39 方格)+
>   bench(seek 延遲)。
> - 防穿牆投射:射線 vs 球掃(同 17.4 `WheelCast` 慣例)→ 差異當行為斷言(射線會從窄縫
>   看穿,球掃不會)+ bench。
> **交付**:普通(空曠處維持臂長、跟隨無超調;三軌序列依時觸發;「等 2 秒再發事件」恰在
> 第 120 tick)/ 整合(接 `gameplay.runtime`:相機跟隨 17.1 控制器經 17.7 插值後的繪製
> 姿態(控制器進 `Runtime` 仍是 17.1 待辦);序列驅動 ECS transform、17.64 動畫軌、17.2
> ragdoll 觸發與 17.38 事件,`seek` 與從頭回放逐位相同;協程狀態存進 17.40 存檔後讀回
> 續跑)/ 極端(目標在牆內、臂長 0、dt = 0 與極大、兩相機同優先權、空序列、seek 超出結尾
> 或負時間、序列中途取消、協程等待的實體被刪除、同 tick 喚醒 10⁴ 個協程、條件永不成立
> (逾時回報,不空轉))。
> **相依**:17.7、17.13、17.35、17.36、17.38、17.39、17.40、11.2、11.1(震動取樣)、17.15
> (BT 與協程並存,不互相取代)、17.64(動畫軌與事件軌,共用 (b) 的彈簧)、17.67(移動模式
> 切換驅動相機)、17.12;解鎖 17.72(對話 / 任務狀態由序列與協程推進)。
> **邊界**:核心輸出相機姿態、FOV 等數值與切換 / 震動事件;投影、渲染、後製、音訊、滑鼠
> 視角輸入屬宿主;時間軸編輯面板屬(III)編輯器本體;序列資產格式隨 17.12。

#### 17.71 戰鬥與互動物理(彈道 / 物理抓取 / 逐骨命中框 / 近戰掃掠) — Wave B

> **緣起**:2026-10-09 負空間盤點,合併 4 筆:彈道(下墜 / 阻力 / 穿透 / 跳彈)、物理抓取、近戰揮擊掃掠、逐骨命中框。
> **現況**:查詢、關節、動畫零件已有,彈道 / 抓取 / 命中框 / 近戰服務都沒有。查詢:
> `collision/world_query.mojo:568` `ray_cast` 只回最近一個 `Hit`(`:77`,單一 `body` / `t` /
> `point`,沒有出口點),`:377` `capsule_cast` 是固定線段的平移掃掠;查詢只吃 `ColliderSet` +
> 每個 collider 一個 `Pose3`,不碰 `Body6`(`:6-8`)。彈道:
> `physics/diffsim.mojo:3`、`physics/diffrigid.mojo:54` 是可微拋體 toy;
> `examples/16_entity_pool.mojo:86` 的池化子彈只做等速位移;CCD 的「子彈 vs 薄牆」
> (2.3「進度」、4.1 swept/TOI Gate)是剛體穿隧,不是彈道服務。抓取:`physics/joints6.mojo:14-18` 只有
> ball / distance / hinge / broken / weld,`:279` `AngularDrive` 只拉姿態;
> `physics/solver6.mojo:529` `move_to` 能驅動 kinematic 錨點,但與剛性 ball 關節組合時沒有
> 力上限;9.1 狀態校正把剩餘的最大座標關節工作移到 17.47,滑鼠 / 目標跟隨線性軟驅動
> 列在 17.47。命中框:`gameplay/ragdoll.mojo:4` 是每骨一個**求解器**箱體(參與接觸與衝量),
> 不是 query-only;`gameplay/interpolation.mojo:96` `PoseHistory` 只存 prev / curr。近戰:
> `procedural/anim.mojo:117` `AnimClip.sample(t)` 能取任意時刻的姿勢,但沒有東西在兩幀之間
> 掃武器。引擎套件 grep `ricochet|grab|mouse.?joint|melee|weapon|sword|hit.?box|hurt.?box`
> 零命中,`projectile` 只命中 `ecs/pool.mojo:6` 的池化動機與 `physics/diffsim.mojo:3` 的可微
> toy;docs grep `grab|gravity gun|抓取`、`melee|近戰|武器|hitbox` 零命中,`lag.?comp` 只命中
> 17.16「增補」的對照組補行(延遲補償條目是 17.16「增補」第一項)。
> **缺口**:
> - **批次彈道**:SoA 彈丸集(不是每顆一個 `Body6`),每 tick 對 17.13 做線段掃掠(粗彈用
>   `sphere_cast`);重力下墜 + 二次阻力(可讀 17.27 `WindGrid` 風場);依材質厚度 × 密度穿透、
>   依入射角與材質跳彈;命中動態體時施 `apply_impulse` 並發命中事件;生命週期走 17.37 池。
>   例:狙擊彈飛 600 m 的下墜、穿過 2 cm 木板、以 15° 掠角擦過鋼板跳彈。
> - **物理抓取 handle**:`ray_cast` 選取 → 在命中點掛 17.47 的線性目標驅動(軟彈簧 + 力上限),
>   另以 `AngularDrive` 保持姿態;目標位姿每 tick 由呼叫端給(例如準星前方 1.5 m);過載或卡住
>   時放開(17.29 閾值機制),拋出 = 放開 + 衝量。這是 gameplay 的物理把手,不是機器人抓取。
>   例:重力槍搬箱子,箱子卡在門框時拉力到上限、脫手。
> - **逐骨命中框集**:每骨一個 query-only 膠囊 / 盒,放在獨立的 `ColliderSet`,姿態每 tick 由
>   `procedural/anim_graph.mojo:405` `to_world` 或布娃娃 `physics_pose`
>   (`gameplay/ragdoll.mojo:118`)寫入;不進求解器、不佔 `ContactScene6` 寬相;`Hit.body` →
>   骨骼 id → 部位(頭 / 軀幹 / 四肢)。掛點與 17.64 骨骼插槽共用;回溯用的位姿環在 17.16
>   增補,本條提供被回溯的對象。例:射線回報「命中第 12 骨(頭)」。
> - **近戰揮擊掃掠**:在動畫事件窗(17.64)內,於兩幀之間取 K 個子取樣時刻的武器骨位姿,相鄰
>   取樣之間做 `capsule_cast`;一次揮擊對每個目標只命中一次;命中送 17.70 傷害與 `Ragdoll.hit`
>   (`gameplay/ragdoll.mojo:113`)。例:60 Hz 下 2 幀掃過 180° 的劍,只在幀姿勢檢查時會直接
>   穿過目標。
> **對照組**:UE `UProjectileMovementComponent`、Arma / Tarkov 的穿透系統;Box2D v3
> `b2MouseJoint` / `b2MotorJoint`、UE `UPhysicsHandleComponent`、PhysX D6 drive、Bullet picking;
> UE Physics Asset 逐骨 body、CS2 lag-compensated hitboxes;UE anim-notify-state weapon trace。
> 本庫內部對照:剛體子彈(`Body6` + CCD,`tests/test_ccd6.mojo`)在同一發射條件下。
> **優勢區**:中 ——(1)彈道可走既有 `Field` 泛型可微 rollout(`physics/diffsim.mojo:3`),有
> 阻力時射角沒有閉式解,可直接以梯度求;(2)近戰子取樣以 motor geodesic
> (`geometry/galie.mojo:116` `geodesic3`)在兩幀位姿之間插值:繞固定軸的揮擊走的是弧,
> lerp + slerp 讓骨原點走弦,外緣路徑誤差較大。抓取與命中框為低 —— 純工程。
> **規模軸**:同時飛行的彈丸數 × 每 tick 掃掠;穿透層數;抓取體數;命中框骨數 × 角色數;
> 近戰子取樣數 K(漏判率 vs 成本)。
> **seam?**:是 ——(1)彈丸表示:SoA 彈道集 vs `Body6` + CCD → 無阻力時兩者落點都對上解析
> 拋物線、命中點一致(parity)+ 每 tick 彈丸吞吐 row;(2)近戰子取樣插值:lerp + slerp vs
> motor geodesic → K 增大時命中集合收斂到同一組(parity)+ 固定 K 的漏判率 row。抓取與命中框
> 沒有互換變體。
> **交付**:普通(無阻力落點 = 解析;穿過木板後減速;15° 跳彈、60° 嵌入;搬起箱子;射線打頭得
> 頭骨)/ 整合(彈丸接 17.37 池與 17.38 事件、命中扣 17.70 血量;抓取物在 `ContactScene6` 中推開
> 其他箱子並喚醒睡眠體;命中框跟著 17.6 動畫圖與 17.2 布娃娃切換;近戰窗接 17.64 動畫事件)/
> 極端(零速、貼著表面平行入射、穿透到能量歸零、同 tick 命中多目標、抓取目標點在牆內、被抓的
> 物體被刪除、0 骨角色、K = 1、揮擊窗跨過動畫循環點)。
> **相依**:17.13(查詢)、17.53(多命中 / 穿透查詢)、17.46(旋轉 CCD,可替代 K 子取樣)、
> 17.47(線性目標驅動關節)、17.29(斷裂閾值)、17.37(池)、17.38(事件)、17.64(動畫事件窗、
> 骨骼插槽)、17.16(回溯命中)、17.70(傷害規則)、17.27(風場)、17.59(逐體二次阻力 / Magnus
> 升力模型,彈道可共用力律)、17.23 / 17.45(穿透 / 跳彈要材質 id:17.23 只有摩擦與恢復係數及
> 組合模式,逐三角形 / 逐格材質 id 在 17.45)。

#### 17.74 載具家族擴充與地面力學(履帶 / 機車 / 飛行器 / 多旋翼 / 船舶推進 / 輪-土壤) — Wave C

> **緣起**:2026-10-09 負空間盤點,合併 2 筆:4 輪 raycast 車以外的載具家族(履帶車 / 機車 / 飛行器 / 多旋翼 / 船舶推進)、可變形地形上的輪-土壤地面力學。
> **現況**:17.4 交付的是 raycast 懸吊車:`gameplay/vehicle.mojo:1-5`(底盤是 `ContactScene6`
> 動力學體,輪不是剛體);`VehicleConfig.validate` 限 2..8 輪、軸號 0..3(`:220-221`、
> `:234-235`);輪接觸走 `WheelCast` seam(`gameplay/vehicle_wheel.mojo:62`);滾阻是常數 Crr
> (`gameplay/vehicle.mojo:166`,預設 0.012 於 `:202`);`Aero`(`:126-149`)只在質心施阻力與
> 下壓力,沒有攻角、升力面或失速。17.4「待辦」已列「拖車 / 多軸 > 2 輪每軸」。
> 17.28 `WaterVolume` / `apply_buoyancy`(`physics/fields.mojo:181`、`:235`)只有浮力與阻尼,
> 浸沒比例只在函式內部算(`:268`),沒有推進;公開的 `sphere_submerged` / `box_submerged_sampled`
> (`:189`、`:209`)回傳浸沒體積與形心。地面:`collision/trimesh.mojo:295` `HeightField.deform`
> 與 `physics/solver6.mojo:372` `deform_heightfield` 只做呼叫端指定的編輯,17.30「進度」的待辦列有
> 「連續變形(履帶壓痕)的批次 API」;`physics/mpm.mojo:10` 的 MPM 可模擬泥與雪,但沒接到
> 載具。LBM 有總力 `fx` / `fy` / `fz`(`fluid/lbm.mojo:76-78`),只包了 `drag_coefficient`
> (`:524`)。引擎套件 grep `tank|tread|motorcycle|aircraft|airfoil|drone|quadrotor|propel|thruster`、
> `bekker|terramech|soil|sinkage` 只命中 `_TextReader` / `EventReader` 的子字串;docs grep
> `坦克|機車|飛機|翼型|螺旋槳|motorcycle|aircraft|airfoil|propeller`、
> `terramech|Bekker|土壤|車轍` 零命中,「無人機」只出現在 17.14「增補」3D 體積導航的例子。
> **缺口**:
> - **履帶車**:每側一條履帶耦合多個負重輪(超過現行 8 輪上限)、主動輪轉速帶動整側、左右速差
>   轉向(skid steer,含原地樞轉)、以接地長度分布法向力並允許側滑。例:坦克原地樞轉;單側
>   履帶在冰面打滑時車身偏航。
> - **機車 / 雙輪**:傾角動力學與平衡(反向轉向)、前後輪載荷轉移(翹孤輪 / 前翻)。例:以
>   20 m/s 過半徑 40 m 的彎,穩態傾角 = atan(v² / (g r)) ≈ 45.6°。
> - **固定翼與多旋翼飛行器**:每個升力面的 Cl(α) / Cd(α) 曲線、失速、控制面偏轉、推力;多旋翼
>   每個旋翼推力 T = k ω² 與反扭矩。姿態穩定以 controller seam 接入,核心附一個 PD 參考實作當
>   測試基準。例:滑翔機攻角超過失速角後升力驟降;四旋翼以對角旋翼轉速差偏航。
> - **船舶推進**:螺旋槳推力只在槳位低於水面時生效(靜水讀 17.28 `WaterVolume` 水面高度,有浪
>   時讀 17.60 水面)、舵力隨流速平方、船體水阻。例:船尾抬出浪頭時推力降為零。
> - **輪-土壤地面力學**:Bekker-Wong 壓力-沉陷(kc、kφ、n)、壓實造成的滾阻、Janosi-Hanamoto
>   剪切限制牽引力;沉陷寫回 17.30 高度場形成車轍,第二次通過時土已壓實;逐格土壤參數掛在
>   17.45 的逐格材質 id 上。例:卡車在泥地下陷數公分、牽引力下降,並留下車轍。
> **對照組**:Jolt `TrackedVehicleController` / `MotorcycleController`、PhysX Vehicle SDK
> tank drive、UE Chaos Vehicles;飛行模型:JSBSim、X-Plane 葉素法;多旋翼:Gazebo multicopter
> motor 外掛;地面力學:Project Chrono SCM、Vortex Studio、AGX Dynamics terrain。本庫內部對照:
> 17.4 常數 Crr 路面、`physics/mpm.mojo` 顆粒 / 塑性材料(高保真端)。
> **優勢區**:中 ——(1)與 17.4「LBM Cd 餵回車體」同模式:用 LBM 的 `fy` / `fx` 對攻角掃出翼型
> Cl / Cd 表,餵給飛行模型;(2)土壤參數(kc、kφ、n)可用 17.20 的可微 rollout 從量到的沉陷
> 反推,做法同 `examples/22_diffsolver_sysid.mojo:1-13` 由滑行後位置反推摩擦係數;(3)MPM 可當
> 地面力學的高保真對照(同一個輪壓進泥地)。履帶、機車、船舶為低 —— 純工程。
> **規模軸**:履帶負重輪數 × 車數;升力面數;旋翼數;土壤格解析度 × 輪數;車轍寫回頻率(每 tick
> vs 批次)。
> **seam?**:是 ——(1)地面模型 seam(新 trait):剛性路面(現行常數 Crr,逐位不變)vs
> Bekker-Wong → 土壤剛度遠大於載重時沉陷趨近 0、軌跡與剛性路面在容差內一致(parity)+ 每輪
> 成本 row;(2)履帶 vs 每側輪速鎖定的多輪滑移轉向車 → 履帶無彈性時兩者軌跡一致(parity)+
> bench row;(3)升力 / 阻力來源:解析曲線 vs LBM 量測表 → 表取自同一曲線時逐位相同(同 17.27
> 常數場 vs 網格的 parity 形式)。
> **交付**:普通(坦克直線行駛;原地樞轉角速度對無滑移運動學值(履帶速差 / 軌距)在容差內;
> 機車穩態傾角;滑翔機失速;四旋翼懸停推力 = mg;船在靜水加速到推力 = 阻力;卡車沉陷對 Bekker
> 解析值)/ 整合(全部走 `ContactScene6` + 17.13 查詢 + 17.28 水體 + 17.30 高度場寫回;前車的
> 車轍被後車讀到;LBM 量出的 Cl 表餵給飛行器)/ 極端(一側履帶懸空、機車零速、飛行器倒飛與
> 90° 攻角、旋翼全停時自由落體、螺旋槳離水、土壤剛度 0 與極大、沉陷超過輪半徑、瞬移)。
> **相依**:17.4(載具骨架、`WheelCast` seam、傳動)、17.28(浮力與浸沒體積)、17.60(海浪 /
> 水流水面)、17.59(逐體氣動 / 水動力模型)、17.27(風場)、17.30(高度場寫回,並完成其連續
> 變形批次 API 待辦)、17.45(逐格材質 id)、17.61(Drucker-Prager 顆粒 MPM,地面力學的高保真
> 對照)、14.4 / 17.42(LBM 測力)、17.20(可微參數反推)、17.47(若履帶張緊或懸吊用關節)、
> 17.29(零件斷裂)、17.14(飛行 agent 的 3D 導航)。
> **邊界**:自動駕駛、狀態估計、感測器與學習式控制器不在本條(使用者 2026-10-09 排除 RL 與
> 機器人);核心只提供力模型與控制輸入介面,外部控制器經 controller seam 接入。

---

## gameplay 服務、AI、導航與網路

範圍:規則框架、AI、導航、rollback。

| 編號 | 條目 | 狀態 | Wave | 說明 |
|---|---|:-:|:-:|---|
| 17.14 | [導航](#1714-導航) | ⬜ | C | 規劃 navmesh bake、A* / funnel、動態障礙、crowd 避讓(RVO / ORCA)、off-mesh link,以及 2026-10-09 增補的流場尋路、3D 體積導航與階層式長程尋路;尚無程式碼。 |
| 17.15 | [AI 框架](#1715-ai-框架) | ⬜ | C | 規劃 behavior tree、utility AI、blackboard、perception、EQS,以及 2026-10-09 增補的轉向 / 群聚 / 隊形、GOAP / HTN、smart objects、影響力圖 / 戰爭迷霧;目前只有 FSM / HSM。 |
| 17.16 | [網路 / rollback](#1716-網路--rollback) | ⬜ | C | 規劃 rollback 核心、預測策略 seam(lockstep / predict-rollback / snapshot-interp)與給宿主傳送的 byte payload API,另含延遲補償與輸入驗證 / 失步偵測;傳輸層與線路格式交給宿主,尚未開工。 |
| 17.70 | [gameplay 規則框架(屬性與效果 / 標籤 / 傷害 / 背包 / 抽選 RNG / 回合規則)](#1770-gameplay-規則框架屬性與效果--標籤--傷害--背包--抽選-rng--回合規則--wave-c) | ⬜ | C | 2026-10-09 盤點新增:屬性 / 效果 / 能力系統、傷害 / 血量 / 陣營、背包 / 物品、階層式 gameplay 標籤、抽選與計數器式 RNG、回合制 / 網格規則 |
| 17.72 | [gameplay 流程服務(遊戲狀態 / 重要度降頻 / 生成與波次 / 逐實體時間縮放 / 對話任務)](#1772-gameplay-流程服務遊戲狀態--重要度降頻--生成與波次--逐實體時間縮放--對話任務--wave-c) | ⬜ | C | 2026-10-09 盤點新增:遊戲流程與依狀態啟停系統、重要度管理 / 系統降頻、生成點 / 波次、逐實體時間縮放、對話 / 任務 / 敘事狀態 |
| 17.73 | [營運與宿主側服務邊界(成就與遙測 / 線上服務 / 模組 / 本地化 / 無障礙)](#1773-營運與宿主側服務邊界成就與遙測--線上服務--模組--本地化--無障礙--wave-c) | ⬜ | C | 2026-10-09 盤點新增:成就 / 遙測 / 數據分析、配對 / 大廳 / 線上服務、模組 / 玩家自製內容、本地化、無障礙服務 |

### 待辦與部分完成條目

#### 17.14 導航

> **狀態**:⬜ 未開始(Wave C;2026-10-09 修訂後為剩餘順序第 (1) 項)
> **現況**:無(舊「明確不做」,已被 [[no-tech-exclusion-principle]] 推翻)。
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

> **狀態**:⬜ 未開始(Wave C;2026-10-09 修訂後為剩餘順序第 (2) 項:EQS 接 17.13、BT tick 可入 10.2)
> **現況**:僅 FSM / HSM(`procedural/fsm.mojo`)。
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

> **狀態**:⬜ 未開始(Wave C;2026-10-09 平台方向 C 拍板解開 gating,為剩餘順序第 (3) 項:rollback 核心 + 預測策略 seam + 給宿主的 byte payload API)
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

#### 17.70 gameplay 規則框架(屬性與效果 / 標籤 / 傷害 / 背包 / 抽選 RNG / 回合規則) — Wave C

> **緣起**:2026-10-09 負空間盤點,合併 6 筆:屬性 / 效果 / 能力系統、傷害 / 血量 / 陣營、背包 / 物品、階層式 gameplay 標籤、抽選與計數器式 RNG、回合制 / 網格規則。
> **現況**:規則層不存在,只有時間與事件零件:`scheduler/timers.mojo:90` `TimerQueue`(17.35;
> 17.35「缺口」把 cooldown、buff 持續時間列為計時器用途,但沒有效果模型)、
> `scheduler/events.mojo:127` `Channel[E]`(17.38)。`Health` / `Damage` / `DamageSystem` 只是
> 排程 parity 的測試夾具(`tests/test_scheduler_parity.mojo:49,55,87`;`scheduler/scheduler.mojo:9,11`
> 的 docstring 拿它們當用法示例);`physics/solver6.mojo:593` 的 "explosion's damage query" 只是
> `wake` docstring 的呼叫例;`gameplay/ragdoll.mojo:113` `hit` 是受擊衝量,不扣血。物品只出現在
> 存檔測試資料(`tests/test_save.mojo:47` `Item`、`:70-81` 往返;17.40「進度」的物品清單往返)。標籤:
> `ecs/relations.mojo:1-14` 是型別化 pair 關係,`ecs/pool.mojo:102` `Disabled` 是唯一的標記
> 元件,沒有可做階層比對的標籤表;引擎裡唯一的 `has_tag` 是 `geometry/polytope.mojo:329`
> 的多面體三角面標籤。RNG:`scheduler/rng.mojo:16-20` `Rng` 只有循序 `next_u64` / `next_f32`,
> 輔助只有 `range_i` / `range_f` / `unit_vec2` / `unit_vec3`(`:116-155`);
> `gameplay/replay.mojo:41` 一個 `SplitMix64` 依呼叫順序取數(`:77-78`),走訪順序一變結果
> 就變;`procedural/noise.mojo:19` `_hash(ix, iy, iz, seed)` 是無狀態鍵控雜湊,但屬 noise
> 私有。網格:`spatial/hash_grid.mojo:20` 是 proxy 空間索引,不是佔用格地圖;17.14 只把 JPS
> 列為 pathfinder 變體(17.14「seam?」)。
> grep `\babilit(y|ies)\b|attribute set|debuff|status effect|modifier stack`、
> `hit.?box|faction|血量|陣營`、`inventory|loot|背包|道具`、`gameplay.?tag|hierarchical tag`、
> `weighted|alias table|shuffle bag|philox|counter.?based`、
> `turn.?based|initiative|action point|hex grid|tile ?map|回合|六角` 於 docs / README 零命中
> (不加字界的 `ability` 會命中 observability / swappability 等字);引擎套件只命中無關字串
> (`weighted` 是 `geometry/skinning.mojo` 的蒙皮權重,`ability` 是 `numerics/sparse.mojo:20`
> 的英文句子)。
> **缺口**:
> - **屬性 / 修飾器 / 效果 / 能力**:屬性集(base + 修飾器堆疊 add / mul / override,固定求值序:
>   優先級 → 套用序號);一次性 / 持續 / 週期效果與疊層規則(刷新 / 疊加上限 / 各自獨立);
>   能力的消耗、冷卻、啟用 / 封鎖標籤條件;週期與到期都走 `TimerQueue` tick。例:5 秒中毒
>   每秒 3 點,疊到 3 層為每秒 9 點,第 4 層依規則被拒。
> - **階層式 gameplay 標籤**:字串 intern 成整數 id + 父節點表(`Status.Debuff.Poison`),容器
>   支援 HasTag / HasAny / HasAll / 父層匹配與計數。例:帶 `State.Stunned.*` 任一子標籤時
>   不能衝刺。
> - **傷害 / 血量 / 陣營**:傷害事件(數值、類型、施加者、目標、命中部位)走 17.38 通道;
>   陣營態度表(隊伍 × 隊伍 → 友 / 中立 / 敵)決定友軍傷害;i-frame 是帶時長的標籤;部位倍率
>   取自 17.71 逐骨命中框。例:爆頭 ×2,友軍手榴彈 0 傷害。
> - **物品 / 背包 / 裝備**:物品定義是 17.11 schema 資料;可堆疊格位與容量規則;裝備槽把修飾器
>   掛到屬性上;存讀走 17.40。例:撿起 30 支箭併入上限 99 的堆疊,裝上劍攻擊 +5。
> - **抽選與鍵控 RNG**:alias table 加權抽選、巢狀掉落表、shuffle bag、PRD(暴擊偽隨機分布);
>   計數器式鍵控串流 `(seed, entity, tick)`,抽到的值與走訪順序、執行緒數無關。例:1 萬個 agent
>   的漫遊方向在系統順序或 10.2 job graph 平行度改變後逐位不變。
> - **回合與格上規則**:格地圖上的佔用與移動成本、格上視線(用 17.69 的格線繪製)、行動點
>   內的移動範圍(Dijkstra 淹沒)、先攻序佇列(同值以固定鍵決勝)。方格 / 六角(axial / cube)
>   座標與分塊瓦片儲存屬 17.69;隊伍層級的可見性格與戰爭迷霧屬 17.15 增補。本條只做回合與
>   行動規則。例:六角戰棋以 6 AP 算出可達格,回合依先攻序結算。
> **對照組**:UE Gameplay Ability System + GameplayEffects + GameplayTags、Lyra inventory /
> equipment fragments、UE `ApplyDamage` / `UDamageType` + `IGenericTeamAgentInterface`;
> NVIDIA Warp `rand_init(seed, tid)`(Philox)、JAX `PRNGKey` split / `fold_in`、Dota PRD;
> Godot `TileMap` / `GridMap`、Unity Tilemap。本庫內部對照:循序 `Pcg32` / `SplitMix64`。
> **優勢區**:多數為低 —— 純工程。鍵控 RNG 為中:17.39 回放、17.16 rollback、17.18 批次多世界
> 與 10.2 平行 job graph 都要求抽選結果不依執行順序,循序串流做不到;效果在固定 tick 上結算,
> 回放逐位相同不需額外工作。
> **規模軸**:實體數 × 每實體活躍效果數;標籤階層深度 × 容器大小;背包格數;抽選次數 / 秒
> (鍵控 vs 循序);格地圖大小 × AP 範圍。
> **seam?**:是 ——(1)`Rng` seam(`docs/CATEGORY.md:47`)加鍵控計數器式變體:同一
> `(seed, entity, tick)` 在打亂走訪順序、串行 vs 平行 job graph 下逐位相同(循序產生器在同一
> 測試結果會變,作為對照)+ 抽選吞吐 vs `Pcg32` 的 bench row;(2)標籤容器:bitset vs 排序
> id 清單 → 同查詢同答案 + 查詢成本 row。屬性 / 傷害 / 背包 / 回合是規則本身,無互換變體。
> **交付**:普通(中毒疊層與到期、箭矢併堆、爆頭倍率、1e6 次加權抽選頻率對權重比在 3σ 內)/
> 整合(接 `gameplay.runtime`:效果由 `Runtime` 的計時器結算、17.71 命中事件經 17.38 扣血、
> 屬性與背包經 17.40 存讀後逐位還原、整段經 17.39 回放逐位相同)/ 極端(零時長效果、疊層到
> 上限被拒並回報、override 與 mul 同優先級、週期 tick 中死亡、背包滿、未註冊的標籤字串與全零
> 權重表在 API 邊界 raise、1e5 實體打亂順序抽選)。落點:規則層在 `gameplay`(第 5 層),鍵控
> RNG 與抽選在 `scheduler/rng.mojo` 旁(第 3 層)。
> **相依**:17.35(計時器)、17.38(事件)、17.11 / 17.40(物品 schema 與存檔)、17.71(命中部位)、
> 17.49(衝擊衝量 → 摔落 / 撞擊傷害)、17.69(方格 / 六角座標與瓦片儲存)、17.14(格上尋路共用
> pathfinder seam)、17.15(AI 讀標籤與屬性;增補的可見性格 / 戰爭迷霧與 smart object 標籤)、
> 17.39 / 17.16 / 17.18(鍵控 RNG 的消費者)、17.72(生成與任務使用同一套規則)。

#### 17.72 gameplay 流程服務(遊戲狀態 / 重要度降頻 / 生成與波次 / 逐實體時間縮放 / 對話任務) — Wave C

> **緣起**:2026-10-09 負空間盤點,合併 5 筆:遊戲流程與依狀態啟停系統、重要度管理 / 系統降頻、生成點 / 波次、逐實體時間縮放、對話 / 任務 / 敘事狀態。
> **現況**:`gameplay/runtime.mojo:70` `Runtime` 的欄位(`:79-86`:world / scene / loop / cfg /
> gravity / events / timers / history)沒有遊戲模式、對局狀態或操控權;
> `scheduler/scheduler.mojo:13-19` 的系統清單是編譯期 type pack,排程器只暴露 `tick`,沒有依
> 狀態啟停的執行條件。`procedural/fsm.mojo:18` `StateMachine`(11.2)會記錄 entered / exited
> (`:11-14`),但沒接到排程。降頻只在物理:`physics/lod.mojo:27` `DistanceLOD`、`:58`
> `SimBudget`(17.31)。生成:`ecs/pool.mojo:128` `Pool`(17.37)與
> `collision/world_query.mojo:344,354,360` 的 `overlap_capsule` / `overlap_sphere` /
> `capsule_penetrations` 是零件,17.37「現況」只把「AI 波次」當池化動機。時間:
> 17.41「拒絕(5)」拒絕的是**全域**時間縮放(`frame_dt` 由呼叫端縮放);逐實體沒有 ——
> `procedural/anim.mojo:285` `AnimPlayer.advance(dt)` 可由呼叫端縮放,但 `ContactScene6` 只有
> 一個全域步長,`TimerQueue.advance` 以整數 tick 前進(`scheduler/timers.mojo:100`)。docs grep
> `game ?mode|game ?state|possess|run.?condition|OnEnter`、`遊戲模式|操控權|對局`、
> `significance|tick ?interval|降頻`、`spawner|spawn ?point|director|刷怪`、
> `time dilation|slow.?mo|hit.?stop`、`dialog|quest|objective|對話|劇情|敘事` 零命中
> (`quest` 的命中都是 question,已排除);引擎套件 grep `run_?if|on_enter|time_?scale`、
> `dilation|slow_?mo|hit_?stop` 零命中。
> **缺口**:
> - **遊戲流程與依狀態啟停系統**:以 11.2 HSM 表示模式 / 對局狀態(暖身 → 進行 → 回合結束),
>   OnEnter / OnExit 讀 FSM 的 entered / exited;狀態經 17.77 的執行條件決定哪些系統跑;操控權
>   表(玩家槽 → 被控實體:角色控制器 / 載具 / 布娃娃),切換時交接控制輸入的目標。例:
>   `Paused` 時物理與 AI 系統整段不跑;上車時操控權從 `CharacterController` 移到 `Vehicle`。
> - **重要度管理(significance)**:依距離、宿主給的可見性提示與 gameplay 優先級打分 → 分桶 →
>   每個子系統的更新率(AI 每 N tick、動畫每 M tick、物理走 17.31 `DistanceLOD`),帶遲滯與相位
>   錯開,總量受 17.10 量到的預算約束。多速率執行機制在 17.77、動畫 LOD 在 17.64,本條是跨子系統
>   的打分與配額策略。例:遠處 NPC 的行為樹 2 Hz、近處 30 Hz。
> - **生成點 / 波次 / director**:生成點有效性檢查(`overlap_capsule` 無重疊、對玩家 `ray_cast`
>   不可見或在宿主給的視錐外)、波次腳本(數量 / 組成 / 間隔走計時器)、依強度調整生成率的
>   director;實體取自 17.37 池,抽選用 17.70 鍵控 RNG。例:第 3 波 12 隻敵人分 4 個點、間隔
>   2 秒,只在玩家看不到的點出生。
> - **逐實體 / 群組時間縮放**:逐體時間尺度(沿用 `physics/body_set.mojo:109-115` 逐體重力覆寫的
>   旗標 + 快路徑做法)、群組計時器以分數 tick 累加、動畫 dt 由同一尺度驅動;hit-stop = 兩體短暫
>   尺度 0。尺度量化成有理數,讓回放逐位相同;不同尺度的兩體接觸時的規則(以慢者為準,或暫時
>   視為 kinematic)先寫設計筆記。例:一個敵人 0.2× 慢動作,世界其餘部分 1×。
> - **對話 / 任務 / 敘事狀態**:對話圖(節點帶說話者與文字 key;選項帶條件:旗標 / 17.70 標籤 /
>   屬性)、任務目標追蹤器訂閱 17.38 事件推進、敘事旗標表;全部經 17.40 存讀,17.39 回放逐位
>   相同。例:「收集 5 個」任務在第 5 個 `ItemPicked` 事件完成,NPC 的對話分支依任務階段切換。
> **對照組**:UE `GameMode` / `GameState` / `PlayerController` possession、Bevy `States` + run
> conditions、flecs pipeline phases;UE Significance Manager + Animation Budget Allocator、Unity
> DOTS `RateManager`;Left 4 Dead AI Director、Lyra player spawning manager;UE
> `CustomTimeDilation`;Yarn Spinner、Ink、Godot Dialogic。本庫內部對照:全域 `frame_dt` 縮放
> (17.41「拒絕(5)」)、17.31 物理 LOD。
> **優勢區**:低 —— 純工程。可驗證的加值:狀態轉移、生成、任務推進都在固定 tick 上決定論執行,
> 17.39 回放可直接當這些流程的 QA 回歸。
> **規模軸**:實體數 × 重要度分桶數;生成點數 × 每次有效性查詢;同時活躍的縮放群組數;對話圖
> 節點數 × 條件數。
> **seam?**:是 ——(1)時間縮放:全域 dt·s vs 逐體尺度 s(全體同尺度)→ 世界在容差內一致
> (parity)+ 逐體尺度開啟時的每步成本 row;(2)重要度降頻:預算放到天花板時與全速路徑逐位
> 相同(同 17.31 LOD = max 的 parity)+ 預算 vs 成本曲線 row。遊戲狀態、生成、對話是規則與
> 資料,沒有互換變體。
> **交付**:普通(暫停時物理 / AI 不跑、恢復後接續;遠近 NPC 的 tick 率;第 3 波生成;單體 0.2×;
> 收集任務完成)/ 整合(狀態機驅動 `Runtime` 的真實系統表;上車換操控權後控制輸入驅動
> `Vehicle`;生成體從 17.37 池取出且不重疊;慢動作敵人與正常速度的箱子碰撞;任務狀態經 17.40
> 存讀、17.39 回放逐位相同)/ 極端(同 tick 連續切兩次狀態、所有生成點被佔或可見、波次進行中
> 存檔、尺度 0 與極小尺度、縮放群組中途加入 / 離開、對話條件引用不存在的旗標在載入邊界
> raise、同一 tick 湧入大量任務事件)。
> **相依**:11.2(FSM)、17.77(執行條件 / 多速率)、17.64(動畫 LOD、動畫事件)、17.31 / 17.10
> (物理 LOD 與預算量測)、17.37 / 17.12(池與 prefab)、17.13(有效性查詢)、17.70(標籤 / 屬性 /
> 鍵控 RNG)、17.38 / 17.40 / 17.39(事件、存檔、回放)、17.35(計時器)、17.68(協程 / 序列器,
> 對話與任務腳本可共用)、17.15(blackboard)、17.27(逐體覆寫的先例)。
> **邊界**:選單與暫停畫面、對話框與字幕的繪製、配音、過場鏡頭剪接屬宿主;核心提供狀態、事件
> (帶文字 key)與系統啟停。字串表與在地化見 17.73。

#### 17.73 營運與宿主側服務邊界(成就與遙測 / 線上服務 / 模組 / 本地化 / 無障礙) — Wave C

> **緣起**:2026-10-09 負空間盤點,合併 5 筆:成就 / 遙測 / 數據分析、配對 / 大廳 / 線上服務、模組 / 玩家自製內容、本地化、無障礙服務。
> **現況**:`diag/counters.mojo:27-79` 是編譯期固定 id 的引擎診斷計數器(`COUNT` = 15),
> 不是 gameplay 可在執行期註冊的統計;`diag/trace.mojo:1` 是 profiling 匯出。17.16 已決定
> 傳輸層交宿主(17.16「決定(2026-10-09)」)。可被宿主搬運的零件:`gameplay/replay.mojo:86` `checksum`、
> `:141` `first_divergence`,`gameplay/save.mojo:70` `SaveWriter`(輸出 bytes)。模組:
> `README.md:104-105` 寫明目前沒有腳本 / 插件層、宿主層將放在架構邊界之後(此句早於
> 2026-10-09 解除 17.21 gating 的決定,見 17.21「決定(2026-10-09)」);12.1 C-ABI 宣告 v0.x 凍結
> (Phase 12「決定(2026-10-09,使用者)」);`ecs/schema.mojo:16-21` 已能按欄位名讀 schema blob 並以 `ReadReport`
> 回報差異,`:271` `TypeRegistry` 可按名稱讀寫欄位。本地化:引擎套件不 `print`
> (`CLAUDE.md:73`),不產生面向玩家的文字。無障礙:輸入屬多媒體層,不在核心(「明確不做」節
> 2026-08-02 推翻註、Phase 17 緣起)。docs / README grep `achiev|telemetry|analytics|leaderboard|成就|遙測`、
> `matchmak|lobby|cloud save|MMR|大廳`、`\bmod(s|ding)\b|UGC|user.?generated|玩家自製`、
> `locali[sz]|i18n|locale|string table|本地化|多語|翻譯`、
> `accessib|aim.?assist|subtitle|colou?r.?blind|無障礙|字幕` 零命中;程式碼只命中 `achieved`
> 等無關字串(`tests/test_chain_contact.mojo`、`benchmarks/bench_sph.mojo`)。
> **缺口**(每項分核心 / 宿主):
> - **統計 / 成就 / 遙測**:核心 —— 執行期註冊的具名 gameplay 統計(由 17.38 事件累加)、成就
>   規則(統計門檻,解鎖事件只發一次)、經 17.40 存讀;遙測環形緩衝(session id、tick、事件 id、
>   payload bytes,取樣率與批次),由宿主拉取,滿了丟最新筆並記 `diag.counters`。例:每個 17.5
>   破碎事件讓 `boxes_broken` +1,到 100 解鎖一次。宿主 —— 上傳、平台成就 API、隱私同意。
> - **線上服務**:核心 —— session 描述(seed、tick 率、玩家數、build / 工具鏈指紋;17.16 只保證
>   同工具鏈、同架構,指紋供相容檢查);以 17.39 回放離線驗證提交的成績(輸入紀錄 → 重跑 →
>   比對 `checksum`)。即時的伺服器端輸入驗證與失步偵測已在 17.16「增補」第二項,
>   本項只做離線成績驗證。例:排行榜收到一筆計時賽成績,伺服器重跑輸入,在第 412 tick 雜湊
>   分歧而拒收。宿主 —— 配對 / 大廳 / MMR、排行榜儲存、帳號、雲端存檔的傳輸(核心只給 17.40
>   bytes)。
> - **模組 / UGC**:核心 —— schema 資料的分層覆寫(base → mod A → mod B,依載入序按欄位名套用,
>   衝突寫進報告)、mod 宣告所需的 12.1 ABI 版本、載入邊界驗證(如 `VehicleConfig.validate`,
>   `gameplay/vehicle.mojo:215`,不合法即 raise)。例:一個 mod 只改載具質量與輪胎 μ,其餘欄位
>   沿用基底。宿主 —— 檔案掛載、mod 瀏覽 / workshop、腳本沙箱(17.21 Python 綁定不含沙箱)、
>   原生插件動態載入(見 17.78)。
> - **本地化**:核心 —— gameplay 資料(17.72 對話 / 任務、17.70 物品)只存穩定的文字 key 與參數,
>   事件帶 key 不帶字串,存檔也存 key。例:任務目標事件帶 `quest.find_key.title` 與數量參數。
>   宿主 —— 字串表、語系 fallback、複數與數字格式、字型。
> - **無障礙**:核心 —— 輔助瞄準查詢(錐角 + 距離內的候選、`ray_cast` 視線、排序、強度參數把
>   瞄準方向往目標混合)、慢速模式(全域 `frame_dt` 或 17.72 群組時間縮放)、字幕提示事件(文字
>   key、說話者、起訖 tick、聲源方向,來自 17.72 對話與 17.64 動畫事件)。例:強度 0.5 時,準星
>   往 3° 內的目標偏移一半角度。宿主 —— 輸入重映射與按住 / 切換轉換、色盲濾鏡、字幕繪製、
>   讀屏。
> **對照組**:Steamworks Stats / Achievements、UE Analytics、Unity Gaming Services;Epic Online
> Services、Photon、Nakama;UE Game Features / ModKit、Godot PCK 載入;UE `FText` / Localization
> Dashboard、Unity Localization、Godot `TranslationServer`;Xbox Accessibility Guidelines、Lyra
> 的 aim assist input modifier。本庫內部對照:`diag.counters`(引擎診斷)、17.39
> `first_divergence`。
> **優勢區**:多數為低 —— 純工程或宿主側。成績驗證為中:6.10 / 17.39 的逐位決定論讓伺服器能
> 重跑輸入驗證成績,非決定論引擎只能做合理性檢查;限制同 17.16(同工具鏈、同架構)。
> **規模軸**:統計數 × 每幀事件量;遙測事件 / 秒 vs 環容量(丟棄率);覆寫層數 × 欄位數;
> 驗證一筆成績的重跑時間 vs 錄製長度;輔助瞄準候選數 × 視線射線數。
> **seam?**:否 —— 服務與資料層,沒有可互換的演算法變體。但統計 / 成就 / 遙測開與關必須讓
> 模擬逐位相同(同 17.10 on / off 規則),輔助瞄準強度 0 必須與無輔助逐位相同。
> **交付**:普通(打破 100 箱解鎖一次;mod 覆寫一個欄位;key 原樣進事件;強度 0.5 的偏移角)/
> 整合(統計吃 `Runtime` 上真實的 17.5 破碎事件並經 17.40 存讀;17.39 錄製的計時賽通過驗證,
> 竄改一個輸入在分歧 tick 被拒;字幕事件由 17.72 對話節點發出)/ 極端(遙測環溢出丟最新筆並
> 計數、取樣率 0 與 1、兩個 mod 改同一欄位由載入序決定、mod 欄位不存在 / 改型 / ABI 版本不符、
> 空輸入紀錄、所有目標被遮擋、目標正在準星中心)。
> **相依**:17.38、17.40、17.39、17.16(含增補的伺服器端驗證)、17.11、12.1、17.21、17.78(插件
> 與多語言綁定)、17.72(對話與時間縮放)、17.64(動畫事件)、17.13 / 17.53(視線與最近鄰查詢)、
> 17.5(破碎事件)。
> **邊界**:這五類大多屬宿主或線上服務;編號是為了寫明核心該提供的資料 / API / 事件(判準同
> 「編輯器邊界分類」)。各項的宿主側工作已在「缺口」逐項列出,核心只提供其中「核心」部分的資料、
> API 與事件。

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
| 17.8 | [大世界座標](#178-大世界座標) | ⬜ | C | 計畫以 f32 + origin rebasing + world partition / cell streaming 支援大世界,f64 只做到 `WorldType` 參數化與小世界 parity,並以座標策略 seam 量測遠離原點的精度退化。 |
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
| 17.77 | [ECS 表達力補完](#1777-ecs-表達力補完--wave-b) | ⬜ | B | 2026-10-09 盤點新增:執行期定義元件、ECS 查詢表達力、多速率系統群組與執行條件、變更 tick 偵測、型別化全域資源、延遲 spawn 與平行指令緩衝、世界整批存讀、元件生命週期鉤子 |
| 17.79 | [執行期資源治理與排程拓撲](#1779-執行期資源治理與排程拓撲--wave-b) | ⬜ | B | 2026-10-09 盤點新增:記憶體預算與分子系統用量追蹤(含 soak 測試)、纖程工作系統與任務優先序、執行緒拓撲與 CPU 親和性 |
| 17.80 | [觀測:物理擷取、執行期追蹤開關與飛行記錄器](#1780-觀測物理擷取執行期追蹤開關與飛行記錄器--wave-b) | ⬜ | B | 2026-10-09 盤點新增:視覺除錯擷取檔與遠端除錯串流、執行期可切換追蹤、當機診斷 / 飛行記錄器 |

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

> **狀態**:⬜ 未開始(Wave C,架構;2026-10-09 修訂排在 Wave C 剩餘順序第 (7) 項,即最末;程式碼中尚無 rebasing / partition 實作)
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
> - `ecs/commands.mojo` `CommandBuffer`(4.4)只記**正向**結構變更(spawn / despawn / add / remove),`apply` 後不留反向資訊。
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

#### 17.77 ECS 表達力補完 — Wave B

> **緣起**:2026-10-09 負空間盤點,合併 8 筆:執行期定義元件、ECS 查詢表達力、多速率系統群組與執行條件、變更 tick 偵測、型別化全域資源、延遲 spawn 與平行指令緩衝、世界整批存讀、元件生命週期鉤子。
> **現況**:
> - 元件型別是編譯期集合:`ComponentType` 只有 `comptime ID`(`ecs/component.mojo:15-16`),
>   後端是 `Archetype[*CTs]` / `SparseSetBackend[*CTs]`(`ecs/archetype.mojo:121`、
>   `ecs/sparse_backend.mojo:23`),archetype 遮罩是一個 `Int`(`ecs/archetype.mojo:123`),
>   job graph 遮罩上限 64 型別(`scheduler/jobgraph.mojo:39-41`)。17.11
>   `TypeRegistry.register[T]`(`ecs/schema.mojo:281`)仍要一個 Mojo 型別。
> - 查詢只有 `matching1/2/3` + `for_each2`(`ecs/storage.mojo:41-54`),`ecs/query.mojo:1-9`
>   註明刻意留空。archetype 後端每次查詢掃過全部 archetype(`ecs/archetype.mojo:330-335`),
>   只有 reactive 後端有快取群組(`ecs/reactive_backend.mojo:3-9`);唯一的排除條件是
>   `Pool.active_query1-3` 逐實體回查 `Disabled`(`ecs/pool.mojo:265-291`)。
> - 系統更新率:`FixedLoop` 只有一個 `dt`(`scheduler/gameloop.mojo:18-19`),
>   `Runtime.advance` 每 tick 跑同一組工作(`gameplay/runtime.mojo:169-211`)。17.31「缺口」
>   提過「每 N 幀 step 一次」,17.31「進度」交付的是凍結與 `SimBudget`,沒有降頻步進。
> - 變更偵測只有 4.4 push observers,限 reactive 後端(`ecs/reactive_backend.mojo:16-24`;
>   `docs/CATEGORY.md:57`),且 `for_each2` 原地寫入不經 `_emit`
>   (`ecs/reactive_backend.mojo:281-303`);`Transform` 的 dirty 旗標只服務階層
>   (`ecs/transform.mojo:30-32`)。
> - 全域資源:審計 F15 記「ecs/world.mojo (no resources)」
>   (`docs/audits/2026-09-27-architecture.md:86`),以固定欄位的 `Runtime` 解決
>   (`gameplay/runtime.mojo:79-86`,`cfg`、`gravity` 等於寫死的單例);job graph 讀寫集
>   只涵蓋元件。
> - 指令緩衝:`ecs/commands.mojo:9-14` 只涵蓋 despawn、關係增刪與延遲 set,方法只有
>   `despawn` / `relate` / `unrelate`(`:43-49`)與 `SetBuffer.set`(`:109`)。**校正**:
>   17.43「現況」寫 `CommandBuffer` 記「spawn / despawn / add / remove」,實際沒有 spawn、
>   add、remove。
> - 整批存讀:17.40「進度」的待辦「ECS 世界整批存讀的便利層」;`gameplay/save.mojo` 只有
>   逐區段 `SaveWriter.add[T]`(`:78`)/ `SaveReader`(`:104`)與 `save_bodies` /
>   `load_bodies`(`:162`、`:172`)。
> - 生命週期:`Runtime.despawn` 手動先移除 body 再移除實體(`gameplay/runtime.mojo:153-165`)。
> grep `change_tick|is_changed|run_if|ComponentDescriptor` 於引擎套件 0 命中;`singleton`
> 只命中 island 註解(`physics/solver6.mojo:878`、`physics/islands.mojo:53`);`on_add` /
> `on_remove` 只命中 `_transition_add` / `_transition_remove` 與 `MOTION_REMOVED` 一類子字串。
> **缺口**:
> - **執行期定義元件**:以描述子(大小、對齊、17.11 欄位 schema)在執行期註冊元件,
>   可查詢、可存讀;遮罩擴到 64 型別以上。例:經 12.1 嵌入的宿主註冊自訂的 Health
>   元件,再查出同時帶 Health 與 `Transform` 的實體。
> - **查詢表達力**:`With` / `Without` / `Optional` / `Or` 條件、三項以上元件、可重用的
>   快取查詢狀態(記住符合的 archetype,新 archetype 出現時才更新)。例:「有 `Transform` 與
>   速度元件、排除睡眠標記、材質元件可有可無」一次查出,不必像 `active_query*` 逐實體回查。
> - **多速率系統群組與執行條件**:系統分組,各組有自己的 tick 率(物理 60 Hz、AI 10 Hz、
>   每繪製幀)、執行條件與順序標籤,組內仍由 10.2 推導層級。例:感知系統每 6 個固定
>   tick 跑一次,且只在有 AI 醒著時跑。
> - **變更 tick**:每個元件欄存 added / changed tick,任一後端都能問「自上次執行以來
>   `Changed<Transform>`」,包含 `for_each2` 的原地寫入。例:只對這一幀移動過的實體更新
>   空間索引。
> - **型別化全域資源**:世界層級的單例(重力、`SolverConfig`、時間),系統讀寫時在
>   job graph 讀寫集宣告,與元件一樣推導衝突。例:風場系統寫自訂的 Wind 資源,
>   布料與粒子系統讀它,job graph 自動把寫者排在前面。
> - **延遲 spawn 與平行指令寫入**:`CommandBuffer` 支援 spawn(預留 ID 可立即引用)、
>   add / remove,並接受多個 worker 同時寫入,以排序鍵決定性合併。例:平行跑的爆炸系統
>   在各 worker 生成碎片實體,套用順序與 worker 數無關。
> - **世界整批存讀**:一次呼叫經 17.11 schema 序列化 / 還原整個 `World` 的實體與元件。
>   例:存 1 萬個 gameplay 實體,不必為每個型別手寫 `SaveWriter` 區段。
> - **元件生命週期鉤子**:每型別的同步 on_add / on_remove,在變更當下於所有後端執行。
>   例:移除 `RigidBodyRef` 時自動移除對應 body,取代 `Runtime.despawn` 的手動兩步。
> **對照組**:Bevy(`ComponentDescriptor`、`Query<…, (With, Without)>` + `QueryState`、
> schedules + `SystemSet` + `run_if`、`Added` / `Changed`、`Res` / `ResMut`、`Commands`
> 預留 `Entity`、`DynamicScene`、component hooks)、flecs(runtime components + meta、查詢
> DSL 與快取查詢、pipeline / tick source、`changed()`、singleton、deferred stage、
> `ecs_world_to_json`、on_add / on_remove hooks)、Unity Entities(`TypeManager`、`EntityQuery`
> WithAll / WithNone / WithAny、`ComponentSystemGroup` + `RateManager`、chunk change version、
> singleton、`EntityCommandBuffer.ParallelWriter`、`SerializeUtility`)、EnTT(runtime pools、
> exclude view、`registry.ctx()`、snapshot、`on_construct` / `on_destroy`)。
> **優勢區**:中 —— 多數是 table stakes。可槓桿處:10.2 job graph 以讀寫遮罩推導層級,
> 同層順序不影響結果,所以與串行逐位相同(10.2「成果」);把資源、`Changed` 過濾與多速率
> 群組放進同一套遮罩後,這個性質仍在。平行指令以排序鍵合併,維持 3.3 / 4.4 的決定論。
> 靜態元件路徑仍是 comptime 特化,執行期型別只在用到的地方付成本。
> **規模軸**:元件型別數(64 → 256)× archetype 數 × 查詢數;實體數 × 變更比例(changed
> 過濾 vs 全掃);系統數 × 速率組數;寫入 worker 數 × 每幀指令數;整批存讀的實體數。
> **seam?**:是 —— (a)元件定義:編譯期集合 / 執行期描述子 → 同一組資料的查詢結果與
> 位元組逐位相同 + 存取成本 bench row;(b)查詢:每次重掃 / 快取查詢狀態 → 相同實體
> 序列 + archetype 數掃描 bench row;(c)變更偵測:`docs/CATEGORY.md:57` 既有列(push
> observers vs 輪詢)加第三個實作「tick 比較」→ reactive 後端上 `Changed<T>` 集合等於
> 收到 EV_SET 的實體集合;(d)指令寫入:單執行緒錄製 / 多 worker 排序鍵合併 → 套用後
> 世界逐位相同 + 吞吐 bench row。資源、多速率群組、整批存讀與鉤子不新增 seam,以 parity
> 對到現行路徑:速率 1 的群組 == 現行 `Runtime.advance`;整批存讀 == 逐區段 `SaveWriter`;
> 鉤子移除 body == 手動 `Runtime.despawn`。
> **交付**:普通(每個子項一個最小案例,六個 `StorageBackend` 都跑)/ 整合(`Runtime` 上
> 物理 60 Hz + AI 群組 10 Hz,AI 以 `Changed<Transform>` 只處理移動過的實體;Wind 資源
> 由 job graph 排序;以鉤子移除 `RigidBodyRef` 後 `ContactScene6` 不再有該 body;整個
> `World` 存讀後繼續步進,與未存讀版逐位相同)/ 極端(第 65 個元件型別;全被 `Without`
> 排除的查詢;change tick 環繞;同一緩衝內 spawn 後立即 despawn;預留 ID 在 `apply` 前被
> 引用、緩衝隨後被丟棄;鉤子內再 despawn 其他實體的重入;換後端後載入存檔)。新測試
> `test_query_filters`、`test_change_ticks`、`test_system_groups`、`test_ecs_resources`、
> `test_commands_spawn`、`test_world_save`、`test_component_hooks`。
> **相依**:3.3 / 4.4(command buffer 與 observers)、10.2(讀寫遮罩)、17.11(執行期元件
> 與整批存讀的 schema)、17.37(`Disabled` 改成 `Without` 條件)、17.40(整批存讀便利層)、
> 17.43(undo 需要 spawn / add / remove 指令;其現況描述需同步更正)、17.31(降頻步進可落在
> 多速率群組)、17.15(AI tick 率,見 17.15「規模軸」)。解鎖 12.1 的系統註冊 / 查詢、
> 17.21 的 Python 端元件與 17.78 的模組註冊。

#### 17.79 執行期資源治理與排程拓撲 — Wave B

> **緣起**:2026-10-09 負空間盤點,合併 3 筆:記憶體預算與分子系統用量追蹤(含 soak 測試)、纖程工作系統與任務優先序、執行緒拓撲與 CPU 親和性。
> **現況**:
> - 記憶體:`diag/counters.mojo:27-79` 的 15 個計數器全是事件次數,沒有位元組;唯一的
>   位元組存取子是 `FrameArena.used()`(`diag/arena.mojo:85`)。容量上限只存在個別容器:
>   `Pool` 的 `cap`(`ecs/pool.mojo:145-150`)、`ContactScene6` 的 `TraceBuffer(capacity=512)` /
>   `LogRing[256]` / `DrawQueue(capacity=1024)`(`physics/solver6.mojo:200-202`)、17.5 碎片
>   淘汰(`FRAGMENT_EVICTED`,`diag/counters.mojo:70`)、17.43「缺口」規劃中的 undo 深度 /
>   記憶體上限。大小只在 bench 裡臨時量(17.40「進度」:`bench_save` 快照 932 KB),
>   沒有長時間 soak 測試。
> - 排程:`scheduler/` 有區段竊取(`workstealing.mojo`)、Serial / Parallel(`policy.mojo`)
>   與分層(`jobgraph.mojo`),grep `fiber|priority` 於 `scheduler/` 0 命中。`workers` 是
>   一個 `Int`(`physics/solver_config.mojo:61`、`:78` 預設 0;`scheduler/jobgraph.mojo:74`)。
>   `benchmarks/bench_islands.mojo:15-18` 記錄 i7-1280P 為 6 P-core + 8 E-core;
>   `scripts/benchmark_report.md.in:1435-1439` 把寬度 8 的掉速推測為拓撲問題並註明
>   「untested here」,沒有程式處理。
> grep `memory budget|記憶體預算|記憶體追蹤|high.?water|soak|leak|洩漏|fiber|纖程|affinity|
> 親和` 於 `docs/`:只命中 `docs/audits/2026-09-27-architecture.md:109` 的「no leak」(指分層,
> 與記憶體無關)。
> **缺口**:
> - **分子系統位元組帳本**:依子系統標記配置(broadphase、接觸快取、`BodySet`、布料、
>   LBM 格網、快照、事件通道),記目前值與高水位,宿主可查詢,經 `diag` 匯出。
>   例:宿主的除錯面板顯示 LBM 格網 80 MB、warm-start 快取 4 MB。
> - **預算上限**:每子系統可設上限;建構時超出由公開 API `raise`,步進中成長超出依容量
>   政策丟最新並計數(`docs/ARCHITECTURE.md:65`)。例:拒絕建立超過 512 MB 的 LBM 格網,
>   並記一次拒絕。
> - **長時間 soak**:1e5 步的高周轉場景(spawn / despawn、睡眠 / 喚醒、破碎、事件)斷言
>   暖機後位元組不再成長。例:開放世界跑一小時後物理記憶體持平。工具層的洩漏與越界
>   偵測屬 17.82。
> - **任務優先序**:派送時帶優先序(高:角色控制、查詢;低:背景 LBM、破碎預切、導航
>   烘焙)。會讓出的 fiber 先做可行性 spike;方向 C 下執行緒歸宿主,優先序經 17.75 的
>   派送器交給宿主。例:LBM 背景步進時,角色控制器的工作仍先跑、延遲不變。
> - **拓撲感知**:偵測 P / E 核心決定預設 worker 寬度、選配綁核、總執行緒數依宿主預算
>   設上限。例:在 i7-1280P 上讓求解 worker 留在 6 個 P-core。
> **對照組**:UE Low-Level Memory Tracker + `memreport`、Unity Memory Profiler /
> `ProfilerRecorder`、Box2D v3 `b2GetByteCount`、Jolt 固定 `MaxBodies` / `MaxBodyPairs` +
> `TempAllocator`、PhysX `PxgDynamicsMemoryConfig`;Naughty Dog fiber job system(GDC 2015)、
> UE5 Tasks 優先序、Havok 任務優先序;UE5 混合核心親和性、oneTBB `task_arena` 限制、
> Unity `JobWorkerCount`。**本庫內部對照**:`FrameArena` 溢位計數與 `Pool` 耗盡計數
> (容量政策的現有實例)。
> **優勢區**:低-中 —— 純工程。可槓桿的一點:worker 數只改排程,結果與串行逐位相同
> (`physics/solver6.mojo:1191-1194`),所以優先序與拓撲變更能用逐位相同驗證;預算上限
> 沿用既有的容量政策,不新增錯誤類別。
> **規模軸**:子系統 × 1e5 步的位元組曲線;帳本每次配置的額外成本(ns);高優先工作在
> 低優先負載下的延遲;worker 1–20 在 P / E 混合上綁核 vs 不綁核(延伸 `bench_islands`)。
> **seam?**:是 —— (a)帳本開關(編譯期,同 `LUDENS_TRACE` 模式)→ 模擬結果逐位相同 +
> 每次配置成本 bench row,並併入 `docs/CATEGORY.md:170` 那組 compile-time on/off;(b)排程
> 策略(FIFO / 優先序)→ 逐位相同 + 高優先延遲 bench row;(c)worker 寬度(固定 / 拓撲
> 決定)→ 逐位相同 + `bench_islands` 的一列。預算上限不是 seam,行為由錯誤政策定義。
> **交付**:普通(查各子系統位元組;上限拒絕並計數;高水位可重設)/ 整合(`Runtime` 跑
> 1e5 步,含 spawn / despawn、破碎與 LBM,暖機後位元組持平;宿主經 12.1 讀高水位;LBM
> 背景負載下角色控制器的延遲)/ 極端(上限 0;上限恰等於需求;workers 大於核心數;單核;
> 全 E-core 寬度;優先序反轉:高優先工作等待低優先工作的輸出)。新測試
> `test_mem_accounting`、`test_stress_soak`(stress tier)、`test_task_priority`。
> **相依**:17.75(帳本建在配置掛鉤上,優先序經派送器傳出)、17.34、17.31(時間預算;本項
> 是記憶體預算)、17.10(計數器與 trace)、6.5 / 6.11 / 10.2(受拓撲影響的平行區段)、17.5
> (碎片預算)、17.43(undo 上限);與 17.82(sanitizer、洩漏偵測)、17.83(效能回歸門檻可加
> 記憶體列)、17.68(gameplay 協程,不是排程器 fiber)分工。
> **邊界**:方向 C 下建立執行緒與 OS 層綁核屬宿主;核心提供位元組帳本、預算 API、優先序
> 與寬度提示,只有內建的預設 worker 池自己綁核。

#### 17.80 觀測:物理擷取、執行期追蹤開關與飛行記錄器 — Wave B

> **緣起**:2026-10-09 負空間盤點,合併 3 筆:視覺除錯擷取檔與遠端除錯串流、執行期可切換追蹤、當機診斷 / 飛行記錄器。
> **現況**:
> - 擷取:17.9 `DrawQueue`(`diag/draw.mojo:57`)只在記憶體,由宿主每幀取走;
>   `ContactScene6` 自帶 `counters` / `trace` / `log` / `draw`(`physics/solver6.mojo:153`、
>   `:166-168`)。17.39 `Recorder` 在記憶體存輸入、間隔快照與每 tick 雜湊
>   (`gameplay/replay.mojo:101-105`),17.39「進度」的待辦「錄製檔案化」指的是輸入錄製。
>   快照編碼已有 `StateWriter` seam(`physics/state_io.mojo:25`)。Chaos Visual Debugger
>   只在 17.9「對照組」出現。沒有接觸 / island / 繪圖指令的檔案或串流格式。
> - 追蹤開關:trace 由 `-D LUDENS_TRACE`(`diag/level.mojo:45`;`diag/trace.mojo:83`、`:90`)、
>   debug-draw 由 `-D LUDENS_DEBUG_DRAW`(`diag/level.mojo:48`)在編譯期開關。17.10「進度」
>   的待辦「同一行程交錯量測 trace on/off(需 runtime 開關)」;編輯器邊界分類表「Profiler
>   面板」列標「✅(runtime 開關與擷取檔 → 17.80 ⬜)」。
> - 當機診斷:`debug_assert` 失敗即印訊息並終止(`docs/design/diag.md:7-8`;
>   `docs/ARCHITECTURE.md:61`)。`LogRing.dump()`(`diag/log.mojo:85`)與 `Counters.dump()`
>   (`diag/counters.mojo:135`)在引擎內沒有呼叫者,失敗時不留紀錄。
> grep `pvd|flight.?recorder|minidump|post.?mortem` 於引擎套件與 `docs/`:0 命中。
> **缺口**:
> - **擷取格式**:每幀 body 狀態(經 `StateWriter`)、接觸 manifold、island 標籤、
>   `DrawQueue` 指令、計數器與 trace span,寫成有版本的 byte 串流;核心給 bytes(同 17.40),
>   寫檔由宿主做,外部 viewer 可來回拖動。例:QA 回報穿隧 bug 時附上最後 600 幀的擷取,
>   開發者在 viewer 裡逐幀看接觸點。
> - **環形擷取與即時串流**:記憶體內保留最近 N 幀(有界、覆寫最舊並計數),另有每幀
>   一段的增量 chunk 供宿主轉送到 socket。例:客戶現場只開環形擷取,出事時才把最後
>   10 秒存下。
> - **執行期追蹤開關**:trace 與 debug-draw 在編譯期「編入」後,還能在執行期開關;
>   編譯期移除仍是零成本。例:宿主的 profiler 面板勾選「物理 trace」,不必重建;17.10 的
>   同一行程交錯量測因此可做。
> - **飛行記錄器**:致命路徑(斷言失敗、單步 NaN 隔離數超過門檻、邊界 `raise`)發生時,
>   把 log ring、計數器、最後一個快照與最近的輸入尾段打包成 bytes 交給宿主。std
>   `debug_assert` 直接終止,先查工具鏈有無終止前掛鉤;沒有的話,由引擎自己的檢查路徑
>   先 dump 再中止。例:玩家機器上的當機附帶可用 17.39 `seek` 重播的資料。
> **對照組**:PhysX OmniPVD(`.ovd`)、UE Chaos Visual Debugger 錄製、Jolt
> `DebugRendererRecorder` + JoltViewer、Rerun SDK;Tracy on-demand 模式、UE Insights 執行期
> trace channel、Unity `Profiler.enabled`;UE CrashReportClient + minidump、Crashpad / Sentry。
> **本庫內部對照**:17.39 回放(記輸入、重新模擬)對上本項的擷取(記觀測值)。
> **優勢區**:中 —— 決定論讓擷取可以很小:同工具鏈同架構下只存輸入 + 間隔快照 + 每 tick
> 雜湊,接觸與繪圖指令靠重新模擬產生(17.39 已證明 `seek` 與全程重跑逐位相同)。對照組的
> 擷取檔都存完整觀測值;本庫只在跨建置、跨架構(決定論不承諾,見 17.16「決定」)或外部
> viewer 需要時才用完整觀測串流。
> **規模軸**:幀數 × body 數 × 接觸數 → 每幀位元組與擷取開銷(佔步進 %);環長度;
> 執行期關閉 vs 編譯期移除的 trace 開銷;dump 時間與大小。
> **seam?**:是 —— (a)擷取策略:完整觀測串流 / 輸入 + 快照 + 重新模擬 → 任一幀重建後
> 逐位相同(同工具鏈)+ 每幀位元組與尋位延遲 bench row;(b)trace 開關:在
> `docs/CATEGORY.md:170` 那列加第三態「編入但執行期關閉」→ 模擬結果與編譯期移除逐位相同 +
> `bench_diag` 開銷列。飛行記錄器是單一設施,不是 seam。
> **交付**:普通(擷取 100 幀再讀回,body 狀態與接觸逐位相同;trace 執行期開 / 關各跑一次)/
> 整合(`Runtime` 開環形擷取跑破碎 + 載具場景,擷取的幀與 17.39 重新模擬重建的同一幀逐位
> 相同;同一行程交錯量測 trace on / off 開銷,補完 17.10 待辦;注入 NaN 讓隔離數超過門檻,
> 觸發飛行記錄器,dump 可餵 `seek` 重現)/ 極端(0 幀擷取;環滿覆寫並計數;擷取格式版本
> 不符 → 拒絕;步進中途切換 trace;dump 時 log ring 已滿;擷取當幀有族群變動與瞬移)。
> 新測試 `test_capture`、`test_trace_runtime`、`test_flight_recorder`。
> **相依**:17.9(繪圖指令來源)、17.10(trace;補完其 runtime 開關待辦)、17.32 / 17.33
> (log ring 與斷言路徑)、17.39(錄製檔案化與 `seek`)、17.40(bytes 輸出慣例)、6.10 與
> `StateWriter`(快照編碼)、17.0h(NaN 隔離計數);與 17.63(模擬烘焙快取,給繪製用)分工。
> **邊界**:viewer UI、檔案與 socket I/O、當機回報上傳都在宿主;核心提供擷取 byte 串流、
> 環形緩衝、執行期開關與 dump API。

---

## 嵌入、腳本與平台

範圍:C-ABI、Python 綁定、宿主整合、平台。

| 編號 | 條目 | 狀態 | Wave | 說明 |
|---|---|:-:|:-:|---|
| 12.1 | [Core embedding 邊界(C-ABI)](#121-core-embedding-邊界c-abi) | ⬜ | C | 以 C-ABI 共享庫提供世界建構 / 系統註冊 / 查詢 / 事件訂閱的穩定介面,v0.x 凍結。 |
| 12.2 | [Mojo / Python 雙腳本](#122-mojo--python-雙腳本) | ⬜ | C | Python(PythonModuleBuilder 擴充模組)與 Mojo 原生系統雙腳本;先做 Python 綁定,落地為 17.21。 |
| 17.21 | [腳本層(Phase 12 落地)](#1721-腳本層phase-12-落地) | ⬜ | C | 計畫在核心 repo 最上層新增 Python 綁定套件(測試以客戶端方式安裝進乾淨環境),之後再接 hot reload、CVar / 設定系統與 live 參數調校;目前尚無實作。 |
| 17.75 | [嵌入契約:宿主注入、非同步步進、併發存取與單位慣例](#1775-嵌入契約宿主注入非同步步進併發存取與單位慣例--wave-b) | ⬜ | B | 2026-10-09 盤點新增:宿主工作系統注入、宿主記憶體配置器、非同步步進、執行緒安全 API、零拷貝狀態匯出、即時性保證、宿主座標與尺度慣例、公開 API 物理單位型別 |
| 17.76 | [平台與硬體可攜性](#1776-平台與硬體可攜性--wave-b) | ⬜ | B | 2026-10-09 盤點新增:Linux x86-64 以外的平台建置、WebAssembly、主機與行動平台、ISA 基線與 SIMD 分派、GPU 跨廠商、宿主 GPU 互通、浮點環境控制、多 GPU / 多節點擴展 |
| 17.78 | [宿主引擎參考整合、多語言綁定與功能模組](#1778-宿主引擎參考整合多語言綁定與功能模組--wave-c) | ⬜ | C | 2026-10-09 盤點新增:宿主引擎參考整合 adapter、C-ABI 與 Python 以外的語言綁定、插件與模組系統 |

### 待辦與部分完成條目

#### 12.1 Core embedding 邊界(C-ABI)

> **狀態**:⬜ 未開始(2026-10-09 已決定的剩餘順序第 4 項)。
> **內容**:定義穩定介面(世界建構、系統註冊、查詢、事件訂閱)的 C-ABI / 值語意契約,核心零腳本依賴;
> 以 C-ABI 共享庫提供給宿主,邊界宣告 **v0.x 凍結**。前面各項(17.14 / 17.15 / 17.16)的資料導向 API 由此包出。
> **交付(實作時)**:腳本層 vs 原生系統同場景 **parity**(腳本不改變模擬結果)。
> **相依**:17.75 嵌入契約(宿主注入 job system / allocator、非同步步進、單位慣例)、17.76 平台可攜、
> 17.81 授權與發佈管道。
> **歷史**:原為 Phase 12「架構分離定律」下 gated on 核心 API 凍結 + 使用者確認;2026-10-09 平台方向拍板 C
> 後解除 gating。原文見 ROADMAP_HISTORY.md「Phase 12」。

#### 12.2 Mojo / Python 雙腳本

> **狀態**:⬜ 未開始;落地條目為 **17.21**(先做 Python 綁定,hot reload 之後再接)。
> **內容**:Python(PythonModuleBuilder 擴充模組,快速迭代)+ Mojo(原生系統,零開銷);使用者可選其一或混用。
> **決定(2026-10-09)**:Python 綁定是腳本層,放核心 repo 的最上層獨立套件(修正原「不入核心 repo」);
> 其測試須**環境隔離** —— 建出的擴充模組以客戶端方式安裝進乾淨環境(不用 repo 的 `-I build` / repo 路徑)再測。
> hot reload 參考 experiment 分支 H1–H6、R1/R2。
> **歷史**:此為 2026-07 撤銷的「引擎-UI / 腳本」方向的重生形態 —— 分離、可選、核心先穩。原文見
> ROADMAP_HISTORY.md「Phase 12」。

#### 17.21 腳本層(Phase 12 落地)

> **狀態**:⬜ 未開始(Wave C;gating 已於 2026-10-09 解除,排在 Phase 17 建議順序 2026-10-09 修訂剩餘順序第 (5) 項,接在 12.1 C-ABI 之後)
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

#### 17.75 嵌入契約:宿主注入、非同步步進、併發存取與單位慣例 — Wave B

> **緣起**:2026-10-09 負空間盤點,合併 8 筆:宿主工作系統注入、宿主記憶體配置器、非同步步進、執行緒安全 API、零拷貝狀態匯出、即時性保證、宿主座標與尺度慣例、公開 API 物理單位型別。
> **現況**:Phase 12「12.1 Core embedding 邊界」的 C-ABI 契約只列世界建構 / 系統註冊 / 查詢 /
> 事件訂閱,宿主嵌入時需要的其餘約定都沒有條目。
> - 執行緒:平行區段直接呼叫 `max.algorithm.parallelize`(`physics/solver6.mojo:1405`、
>   `physics/contact6.mojo:534`、`physics/diffsolver.mojo:464`、`scheduler/jobgraph.mojo:175`、
>   `scheduler/workstealing.mojo:93`)。唯一的派送抽象 `DispatchPolicy`
>   (`scheduler/policy.mojo:20-41`,Serial / Parallel)在編譯期選定,只有 actor 排程器使用
>   (`scheduler/entity_actor.mojo:95`、`scheduler/system_actor.mojo:67`)。
> - 記憶體:引擎直接 `alloc`(`ecs/archetype.mojo:137`、`ecs/sparse_backend.mojo:40`、
>   `ecs/reactive_backend.mojo:91`、`ecs/commands.mojo:90`)或用 `List`(`physics/solver6.mojo`
>   有 78 行出現 `List[`)。17.34 `FrameArena` 只被 `diag/`、`tests/test_diag_arena.mojo`、
>   `benchmarks/bench_diag.mojo` 使用;17.34「缺口」原定給 `_collect_pairs` 的暫存沒有接上。
>   `docs/CATEGORY.md:172-173` 記錄的是被放棄的引擎內部配置器 trait,不是宿主掛鉤。
> - 步進時序:`ContactScene6.step` 同步執行(`physics/solver6.mojo:1173`),
>   `Runtime.advance` 在同一呼叫內跑計時器 → 步進 → 事件 → transform 同步
>   (`gameplay/runtime.mojo:169-211`)。GPU 路徑已拆成 `begin_external_solve` /
>   `end_external_solve`(`physics/solver6.mojo:1108`、`:1125`),但
>   `GpuContactSolver.step` 在兩者之間呼叫 `ctx.synchronize()`(`physics/gpu_contact.mojo:456`)。
> - 併發存取:Mojo 端 `step(mut self, …)` 由借用規則擋住同時讀寫;經 C-ABI 出去後
>   沒有這層保證。grep `mutex|spinlock|thread.?safe|reentran` 於引擎套件 0 命中;
>   `Atomic` 只在 `collision/bp_gpu.mojo:78` 與 `scheduler/workstealing.mojo:73`、`:85`。
> - 資料交換:零拷貝只在內部(`ecs/archetype.mojo:53-54` `ArchView2`);對外只有逐欄位
>   複製的 `StateWriter`(`physics/state_io.mojo:25`)。`BodySet` 是 body struct 的 `List`
>   加逐屬性 `List`(`physics/body_set.mojo:93-120`),`Lbm.f` 是連續的 `[dir][cell]`
>   (`fluid/lbm.mojo:55`)。
> - 時間上限:17.31「進度」的 `SimBudget` 依量測步進時間調整 iters / substeps,是軟預算;
>   沒有「每步 0 次配置」或最壞步進時間的保證。
> - 單位:`Real` 是 f32 純量別名(`geometry/vec.mojo:14-15`)。容差以公尺調校:
>   `SPEC_BASE = 0.02`(`collision/collider_set.mojo:49`)、`lin_sleep_tol = 0.01`、
>   `ang_sleep_tol = 0.05`、`restitution_threshold = 1.0`
>   (`physics/solver_config.mojo:64-68`,`:47` 註明 m/s)。唯一的 newtype 先例
>   `BodyId`(`physics/body_set.mojo:57`)管身分,不管單位。
> `grep -iw` 查 `job system|thread pool|allocator|fetchResults|thread-safe|mutex|dlpack|
> zero-copy|worst-case|wcet|allocation-free|y-up|z-up|centimeter|dimensional` 於 `docs/`、
> `README.md`:只命中 17.34 節(現況 / 對照組 / 進度)、`docs/design/diag.md:38`、
> `docs/SOTA_GAP_ANALYSIS.md:146`(內部 job graph),以及 Phase 17 建議順序「2026-10-09 增補
> (17.44–17.84)的排序」中指向本項的一句。
> **缺口**:
> - **宿主工作系統注入**:`TaskDispatcher` 介面(送出一批 index 區段、等待完成、回報
>   worker 數),上列五個平行區段都改經它;內建 `parallelize` 是預設實作。
>   例:嵌進 UE5 時 island 求解跑在 TaskGraph 上,不再另開一個與遊戲執行緒搶核心的池。
> - **宿主記憶體配置器**:建立世界前設定一次的配置掛鉤(持久 / 對齊 / 每步暫存三類),
>   引擎內的 `alloc` 與熱路徑暫存改經它;暫存類以 17.34 `FrameArena` 為預設。
>   例:主機遊戲把物理記憶體放進自己有上限的 arena,並計入自己的記憶體追蹤。
> - **非同步步進**:`step_begin` 立即返回、`step_end` 取結果,外加可讀的上一步狀態
>   雙緩衝(延伸 17.7 `PoseHistory`)。例:物理在 worker 或 GPU 跑第 N+1 步時,
>   宿主用第 N 步的姿態繪製並跑 gameplay。
> - **併發存取規則**:寫明哪些 API 可在步進中由其他執行緒呼叫;查詢讀上一個已提交的
>   快照,或以讀寫鎖保護;違規在 debug 建置以 `debug_assert` 抓。
>   例:遊戲執行緒在物理執行緒步進中途做 raycast。
> - **零拷貝狀態匯出**:對 `BodySet` 逐屬性陣列、`Lbm.f`、GPU buffer 提供
>   (指標, 形狀, stride, dtype)視圖,C-ABI 直接給,17.21 Python 端包成 buffer
>   protocol / DLPack。例:Python 筆記本對 1.77M 格風洞的速度場畫剖面,不複製格網。
>   RL 觀測管線不在範圍(使用者 2026-10-09 排除)。
> - **有界步進**:暖機後每步 0 次堆配置(預配暫存;容量溢出依
>   `docs/ARCHITECTURE.md:65` 丟最新並計數)、迭代數有上限,並量出最壞步進時間的包絡。
>   例:主機遊戲給物理每幀 2 ms,接觸數突增的那一幀也不超過。機器人控制迴圈不在範圍。
> - **座標與尺度慣例**:邊界設定上軸(Y-up / Z-up)、手性與長度單位,並依長度單位換算
>   margin / 睡眠 / 恢復係數門檻等容差。例:UE 宿主(Z-up、公分)直接傳值時,
>   `SPEC_BASE = 0.02` 變成 0.2 mm、`lin_sleep_tol = 0.01` 變成 0.1 mm/s,物體幾乎不入睡。
> - **公開 API 的物理單位型別**:`Meters` / `Kilograms` / `Seconds` 等以 comptime 參數
>   表示量綱的零成本型別,只放在公開邊界,內部仍用 `Real`。
>   例:把公分值傳給 `add_sphere` 的半徑(`physics/solver6.mojo:302`)、或把密度傳進
>   質量欄位,編譯期報錯。
> **對照組**:Jolt `JobSystem` 介面、`Allocate` / `Free` 掛鉤 + `TempAllocator`、
> `BodyLockRead` / `BodyLockWrite`、`PhysicsSettings`;PhysX 5 `PxCpuDispatcher`、
> `PxAllocatorCallback`、`simulate()` / `fetchResults()`、`PxSceneReadLock`、
> `PxTolerancesScale`;Box2D v3 `b2WorldDef.enqueueTask` / `finishTask`、`b2SetAllocator`;
> UE5 Chaos async physics tick;MuJoCo `mj_step`(`mj_makeData` 之後不配置);
> Warp / Genesis 的 DLPack 匯出;mp-units(C++)、uom(Rust)。**本庫內部對照**:
> `DispatchPolicy` 的 Serial / Parallel;`bench_diag` 的 `FrameArena` vs 逐幀 `List`。
> **優勢區**:中 —— 多數子項是純工程。差異在決定論:`cfg.workers` 只改排程,任何
> worker 數都與串行逐位相同(`physics/solver6.mojo:1191-1194`),所以宿主派送器、宿主
> 配置器與管線化步進都能以逐位相同作 parity,不必用容差比。單位型別靠 comptime
> 參數,執行期零成本。座標換算為低 —— 純工程。
> **規模軸**:worker 數 × 宿主池負載(單池 vs 雙池超額訂閱的步進時間);每步堆配置
> 次數(目標 0)與 1e4 幀的 p99 / 最大步進時間;管線化下「步進 + 宿主工作」的牆鐘
> 時間對串行;匯出位元組數(複製 vs 視圖);長度單位倍率 0.01–100 下的穩定性。
> **seam?**:是 —— 三個 seam。(a)派送:內建 `parallelize` / 宿主 callback / 串行 →
> 同場景逐位相同 + bench row(超額訂閱下的步進時間);(b)配置:系統配置 / 宿主 arena →
> 逐位相同 + bench row(每步配置成本);(c)步進模式:同步 `step` / `step_begin` +
> `step_end` → 取回結果逐位相同 + bench row(重疊率)。三列補進 `docs/CATEGORY.md`。
> 座標 / 單位不是 seam,是邊界換算:同一場景以 Z-up 公分與 Y-up 公尺建立,換算回來的
> 軌跡在 f32 ε 內一致(容差經換算,不逐位)。
> **交付**:普通(計數用的宿主派送器跑 16 島場景與內建逐位相同;宿主配置器記到三類
> 位元組;`step_begin` / `step_end` 與 `step` 結果相同;匯出視圖讀到的位置等於 `BodySet`)/
> 整合(`Runtime.advance` 改走管線化步進並接 17.7 插值;12.1 的 C 範例宿主帶自己的
> thread pool 與配置器跑 1000 幀;另一執行緒在步進中 raycast,拿到與上一步一致的結果;
> Z-up 公分版箱塔與 Y-up 公尺版一樣站穩並入睡)/ 極端(倒序或亂序執行任務的派送器仍
> 逐位相同;1 個 worker;配置器回報失敗 → 邊界 raise、步進中丟棄並計數;未 `step_end`
> 又 `step_begin`、沒有 `step_begin` 就 `step_end`;接觸數突增幀的最壞時間;長度單位
> 0.01 與 100;左右手翻轉的鏡像場景;量綱誤用以 spike 證明編譯期拒絕)。新測試
> `test_host_dispatch`、`test_host_alloc`、`test_step_pipelined`、`test_units_convention`。
> **相依**:12.1(本項補足其契約,宜在 v0.x 凍結前併入)、17.21(Python 端視圖包裝)、
> 17.34(暫存配置的預設實作)、17.31(軟預算;本項給硬上限)、17.7(管線化下的繪製姿態)、
> 17.17(`begin_external_solve` / `end_external_solve` 是拆步的現成切點)、6.5 / 6.11 /
> 10.2(派送器要接的平行區段)、17.13(併發查詢)、17.8(長度單位與 f32 精度互相影響)。
> 解鎖 17.79(記憶體帳本建在配置掛鉤上)、17.78(宿主整合需要座標 / 單位約定)、
> 17.54(多執行緒碰撞管線走同一派送器)。
> **邊界**:執行緒池、記憶體系統、繪製執行緒與 Python / 張量框架都在宿主;核心只提供
> 派送與配置介面、分段步進 API、併發存取規則、資料視圖與座標 / 單位設定。

#### 17.76 平台與硬體可攜性 — Wave B

> **緣起**:2026-10-09 負空間盤點,合併 8 筆:Linux x86-64 以外的平台建置、WebAssembly、主機與行動平台、ISA 基線與 SIMD 分派、GPU 跨廠商、宿主 GPU 互通、浮點環境控制、多 GPU / 多節點擴展。
> **現況**:
> - 平台:只有 Linux x86-64。`pixi.toml:5` 為 `platforms = ["linux-64"]`,`README.md:42`
>   與 `CLAUDE.md:8` 寫「Linux x86-64 + pixi」。決定論只承諾同工具鏈、同架構
>   (17.16「決定」)。wasm 只在審計中順帶提到:`gpu_lbvh` 把 `max.gpu` 拉進根
>   套件「matters for the wasm-retarget path」(`docs/audits/2026-09-27-architecture.md:113`),
>   沒有條目。
> - 指令集:`scripts/build_engine.sh:16` 以 `mojo precompile` 編譯,不帶目標 CPU 旗標;
>   `ecs/system.mojo:42` 以 `simd_width_of` 取編譯主機的寬度。
> - GPU:只在一張 NVIDIA RTX 3060 上量過(`README.md:34`)。七個 GPU 模組
>   (`spatial/gpu_lbvh.mojo`、`fluid/lbm_gpu.mojo`、`collision/bp_gpu.mojo`、
>   `collision/gpu_raycast.mojo`、`physics/gpu_cloth.mojo`、`physics/vbd_cloth.mojo`、
>   `physics/gpu_contact.mojo`)沒有廠商矩陣,無加速器時只靠 `has_accelerator` 跳過測試;
>   block 大小寫死 `_BLOCK = 128`(`physics/gpu_contact.mojo:48`、`fluid/lbm_gpu.mojo:27`)。
> - 宿主 GPU 互通:`DeviceContext` 已由呼叫端持有(`fluid/lbm_gpu.mojo:15`;單一擁有者
>   見 17.0「Wave B 入口前置」),但資料每次經過 CPU:`LbmGpu` 由 CPU `Lbm` 上傳、
>   `download` 回 CPU(`fluid/lbm_gpu.mojo:161`、`:222`),`GpuContactSolver` 每幀
>   `synchronize` 後映射回主機(`physics/gpu_contact.mojo:456-480`)。17.17「進度」的待辦
>   「持久裝置狀態免每幀上下傳」只談駐留,沒談匯入 / 匯出宿主 buffer。
>   「每個 process 一個 `DeviceContext`」(`CLAUDE.md:75`)排除了多裝置。
> - 浮點環境:`benchmarks/bench_diffrigid.mojo:6-10` 把長 rollout 的效能斷崖歸因於 f32
>   denormal(梯度降到 3e-45),沒有處置;NaN 只在步末隔離(17.0h)。
> `grep -iw` 查 `macos|darwin|windows|wsl|arm64|aarch64|avx|avx2|neon|denormal|subnormal|ftz|
> daz|rocm|metal|multi-gpu|nccl|ps5|xbox|android|wasm|webassembly` 於 `docs/`、`README.md`:
> 只命中上述審計行。
> **缺口**:
> - **桌面平台矩陣**:`pixi.toml` 加 `osx-arm64`、`linux-aarch64`,在各平台跑全部 tier
>   與 golden;Windows 在 Mojo 工具鏈原生支援前經 WSL 並寫明。
>   例:跑在 Apple silicon Mac 上的 Godot 宿主載入 12.1 的共享庫。
> - **ISA 基線與 SIMD 分派**:發行建置指定基線目標(x86-64-v3 / armv8)而非主機原生,
>   `simd_width_of` 取目標寬度;AVX-512 / SVE 等寬向量以多版本選配。
>   例:同一個 `.so` 在只有 AVX2 的筆電與有 AVX-512 的伺服器上都正確執行。
> - **WebAssembly**:CPU 路徑編到 wasm32,GPU 模組排除,無執行緒時平行區段退回串行並
>   計數。例:瀏覽器內的 6 箱塔 demo。工具鏈支援前只做 spike 並記錄阻擋點。
> - **主機與行動平台**:PS5 / Xbox / Switch / iOS / Android。Mojo 工具鏈目前沒有這些
>   目標,屬上游阻擋;核心先守住可移植前提:引擎套件不 `print`、不做檔案 I/O(17.40
>   「進度」的待辦註明目前只給 bytes)。例:日後移植時引擎套件內沒有 OS 呼叫要改。
> - **GPU 跨廠商**:七個 GPU 模組在 AMD(ROCm)與 Apple GPU 上跑同一套 parity 測試,
>   處理 warp / wavefront 寬度差異(NVIDIA 32、AMD CDNA 64)對 `_BLOCK` 與著色求解的假設。
>   例:XPBD 布料在 AMD GPU 上維持與 CPU 約 1e-6 的 parity。
> - **宿主 GPU 互通**:接受宿主的 device / stream,匯入與匯出外部 buffer,狀態常駐裝置。
>   例:布料頂點或 LBM 速度場直接寫進宿主的頂點 / 3D 紋理 buffer,不經 CPU,也不開
>   第二個 `DeviceContext`。
> - **浮點環境**:步進期間以 scope 設 FTZ / DAZ,離開時還原宿主設定;debug 建置的 FP
>   例外攔截接進閘門屬 17.82。例:`bench_diffrigid` 的軟接觸長 rollout 不再掉進 denormal
>   斷崖。
> - **多 GPU / 多節點**:17.18 的批次世界依裝置分片,LBM 依 slab 分域並交換邊界層;
>   context 規則改為每裝置一個。例:四張 GPU 各跑四分之一的 4096 組參數掃描(設計
>   最佳化),或把風洞格網切成四塊。RL 訓練分片不在範圍(使用者 2026-10-09 排除)。
> **對照組**:Jolt(Win / Linux / macOS / iOS / Android / WASM / 主機;`USE_AVX2` /
> `USE_AVX512` / NEON 建置選項;`FPFlushDenormals` scope)、PhysX 5(x64 與 aarch64;
> `PxCudaContextManager` 建在既有 CUDA context 上)、Box2D v3(`BOX2D_AVX2`、emscripten)、
> Rapier(rapier.js)、MuJoCo(Linux / macOS / Windows)、Genesis / Taichi(CUDA + Metal +
> Vulkan)、Warp(外部 buffer 互通、多裝置)、MJX / MJWarp(分片)。反例:PhysX GPU 與
> Warp 只支援 CUDA。**本庫內部對照**:CPU 路徑是每個 GPU 廠商的 parity 基準。
> **優勢區**:低-中 —— 平台與主機是純工程且受上游限制;GPU 跨廠商來自 Mojo / MAX
> (同一份 kernel 原始碼),本庫的工作是證明 parity。FTZ 對可微路徑有實際收益,因為
> 梯度衰減時正好落進 denormal。批次世界彼此獨立,分片後每個世界仍可逐位對上單裝置。
> **規模軸**:平台 × tier 通過數;ISA 基線 vs 原生的 bench 差距(%);GPU 廠商 × kernel
> 的 parity 誤差與吞吐;互通 vs 每幀上下傳的傳輸時間(基準:17.17「進度」記錄的
> `bench_gpu_contact` 傳輸 0.15–1.6 ms);FTZ 開 / 關下 rollout 長度 × 每步時間;GPU 數 ×
> 世界數 / 格點數的強、弱擴展。
> **seam?**:是 —— (a)浮點環境(預設 / FTZ+DAZ)→ 不產生 denormal 的場景逐位相同,
> 產生時差異限於 denormal 量級 + bench row(`bench_diffrigid` 長 rollout);(b)GPU 資料
> 駐留(每幀經 CPU / 宿主 buffer 常駐)→ 同 kernel 逐位相同 + 傳輸時間 bench row;
> (c)裝置數(1 / N)→ 每個批次世界逐位相同、LBM 分域後格點值逐位相同(動量交換的
> 總和順序另以容差比)+ 擴展 bench row。平台與 ISA 是建置矩陣,不是 compile-time seam:
> 跨架構只做容差 parity,並把決定論承諾寫明為「同工具鏈 × 同架構 × 同 ISA 目標」
> (延伸 17.16「決定」)。
> **交付**:普通(osx-arm64 / linux-aarch64 上 `pixi run test` 全過、golden 比對;FTZ scope
> 進出後宿主的 MXCSR / FPCR 原樣)/ 整合(12.1 共享庫在各平台被 C 範例宿主載入並跑同一
> 場景;布料頂點匯出到宿主 buffer,由另一個 kernel 讀回驗證,全程沒有 CPU 複製;
> `bench_diffrigid` 長 rollout 在 FTZ 下沒有斷崖;AMD 上 `test_gpu_contact` 的發散判準照常
> 通過)/ 極端(全 denormal 輸入;無 GPU 時互通 API 在邊界 raise,由選 backend 的那層退回
> CPU;世界數不能被裝置數整除;單一裝置失敗時的隔離;wasm 無執行緒時串行退回的計數)。
> 新測試 `test_fp_env`、`test_gpu_interop`、`test_multi_device`。
> **相依**:12.1(要在各平台出貨的共享庫)、17.17(持久裝置狀態待辦)、17.18(批次世界是
> 多 GPU 分片的單位)、17.42(`LbmGpu` 分域)、3.2 / 4.3(GPU 布料)、17.16(決定論承諾的
> 範圍)、17.75(GPU 視圖與 CPU 零拷貝共用描述格式);與 17.81(CI 平台矩陣)、17.82(FP
> 例外攔截、GPU runner 驗證)分工。
> **邊界**:主機 / 行動 SDK、圖形 API(Vulkan / D3D12 / Metal)的資源 handle 與繪製都在
> 宿主;核心提供 device buffer 的匯入 / 匯出 API 與可攜的建置。CI runner 與發佈管道屬 17.81。

#### 17.78 宿主引擎參考整合、多語言綁定與功能模組 — Wave C

> **緣起**:2026-10-09 負空間盤點,合併 3 筆:宿主引擎參考整合 adapter、C-ABI 與 Python 以外的語言綁定、插件與模組系統。
> **現況**:平台方向 C(頁首「狀態(2026-10-09)」、Phase 12「決定(2026-10-09,使用者)」)
> 只排了 12.1 C-ABI 與 17.21 Python 綁定(Phase 17 建議順序 2026-10-09 修訂「剩餘順序」
> (4)(5)),沒有任何宿主端消費者。`README.md:104-105` 寫「No scripting or plugin layer —
> deliberate … host layers will live behind a strict architectural boundary when they come」,
> 是邊界宣告,不是排程。Godot / Unity / Bevy 在程式碼裡只出現在對照註解(例:
> `gameplay/character.mojo:8-9`、`ecs/commands.mojo:1`、`ecs/schema.mojo:20`),C# 在文件裡
> 只當對照組(17.21「對照組」、17.38「對照組」)。`gameplay/runtime.mojo:79-86` 是固定欄位
> 的容器,沒有註冊功能模組的 API。repo 沒有 adapter 或 bindings 目錄。
> grep `GDExtension|PhysicsServer|bevy_rapier|csharp|plugin|插件|外掛|模組系統` 於 `docs/`:
> 只命中 17.14 增補對照組的「UE Mass 的 3D 導航插件」,與本項無關。
> **缺口**:
> - **參考整合 adapter**:先做 Godot 4 `PhysicsServer3D`(經 GDExtension;Godot 有正式的
>   物理後端替換 API),之後依需求做 Bevy plugin、UE / Unity native plugin。adapter 把宿主
>   的 space / body / shape / joint / query 呼叫對到 12.1。例:一個 Godot 專案把物理引擎
>   切到本庫,既有 `RigidBody3D` 場景不改就能跑(Godot Jolt 的做法)。
> - **多語言綁定**:在 C-ABI 上做慣用包裝 —— C++ RAII 標頭、C#(P/Invoke)套件、Rust
>   (`-sys` + safe crate),由同一份介面描述產生,避免各自漂移。例:Unity 專案匯入 C#
>   套件後直接建立世界與剛體,不手寫 FFI。
> - **功能模組**:把載具、LBM、破壞、角色等打包成模組,模組向 `Runtime` 註冊自己的
>   元件、系統與資源;預設編譯期選擇,動態載入原生擴充列為選配並先做 spike。
>   例:宿主只啟用「載具 + LBM」,其餘不進二進位。
> **對照組**:Godot Jolt(Godot 4.4 起內建為模組)、bevy_rapier、PhysX 的 UE / Unity 整合、
> Box2D v3(C API 與眾多社群綁定);JoltPhysicsSharp、jolt-rust、physx-rs;Bevy `Plugin` /
> `PluginGroup`、UE5 modules / plugins、Godot GDExtension、flecs modules(`ECS_IMPORT`)。
> **本庫內部對照**:17.21 Python 綁定(另一條綁定路徑,環境隔離測試規則可沿用)。
> **優勢區**:低 —— 純整合工程。價值在驗證:在 Godot 跑既有場景,是 12.1 契約夠不夠用
> 的第一個真實系統測試;多語言驅動同一場景逐位相同,證明包裝層沒有改動數值。
> **規模軸**:每幀每 body 的跨 ABI 呼叫成本(adapter vs Mojo 原生);adapter 覆蓋的宿主
> API 比例;各語言每次呼叫的 FFI 開銷;啟用模組數 × 二進位大小 / 步進時間。
> **seam?**:是 —— (a)Godot 物理後端(GodotPhysics / Godot Jolt / 本庫)是宿主自己的
> seam:同一 Godot 場景比可觀察行為(靜止位置、接觸訊號次數、raycast 命中),不比位元,
> 另列 bench row(同場景步進時間);(b)功能模組集合(全開 / 子集)→ 不使用被關模組的
> 場景逐位相同 + 二進位大小與步進時間 bench row。綁定本身不是 seam:C、C++、C#、Rust
> 驅動同一場景必須逐位相同。
> **交付**:普通(C++ 包裝建立世界並讓一個箱子落地;Godot adapter 下一個 `RigidBody3D`
> 落在 `StaticBody3D` 上)/ 整合(Godot 範例場景的關節、raycast 與接觸訊號全經 adapter;
> C# 與 Rust 測試依 17.21 規則安裝進乾淨環境再跑,不靠 repo 路徑)/ 極端(宿主以不支援
> 的順序呼叫,例如 body 先於 space 建立 → 邊界拒絕;不支援的形狀在 adapter 端拒絕並計數;
> ABI 版本不符拒絕載入;存檔裡有已關閉模組的元件 → 依 17.40 的規則略過並回報)。
> **相依**:12.1(全部建在上面)、17.21(安裝與隔離測試規則)、17.75(宿主的座標 / 單位、
> 執行緒與配置器約定)、17.76(宿主所在平台)、17.77(模組註冊需要執行期元件與資源)、
> 17.13 / 9.4(查詢與接觸事件對到宿主 API)、17.81(套件發佈)。
> **邊界**:宿主引擎、其編輯器與繪製都在宿主。adapter 與語言綁定不放進引擎套件,依 17.21
> 先例放在核心 repo 最上層的獨立套件或另一個 repo;核心只提供 12.1 C-ABI 與模組註冊 API。

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
| 17.81 | [工程基礎建設與發行(CI / 授權 / 版本 / 文件 / 發佈)](#1781-工程基礎建設與發行ci--授權--版本--文件--發佈--wave-a) | ⬜ | A | 2026-10-09 盤點新增:CI(含 PR 檢查與託管測試矩陣)、LICENSE、CITATION、貢獻指南、英文文件、API 參考、版本與 CHANGELOG、棄用政策、套件發佈管道、格式 / lint 強制 |
| 17.82 | [品質工具:記憶體 / 競爭 / 覆蓋率 / fuzz / 性質測試 / 組態矩陣](#1782-品質工具記憶體--競爭--覆蓋率--fuzz--性質測試--組態矩陣--wave-a) | ⬜ | A | 2026-10-09 盤點新增:記憶體錯誤與洩漏偵測、資料競爭偵測、程式碼覆蓋率、fuzz、性質測試與縮小、不可信輸入硬化、GPU 核心驗證、發行組態測試、浮點例外攔截 |
| 17.83 | [效能治理:回歸門檻、外部引擎同場對打、編譯成本預算](#1783-效能治理回歸門檻外部引擎同場對打編譯成本預算--wave-a) | ⬜ | A | 2026-10-09 盤點新增:效能回歸追蹤與門檻、與外部引擎同場景對打、編譯時間與二進位大小預算 |

### 已完成條目的遺留待辦

這些條目已完成並移到歷史檔,但各自記下了尚未做的部分:

- **16.3**([紀錄](ROADMAP_HISTORY.md#163-vec3-重構width-3-simd-被禁--完成2026-08-12分支-mojo-stable)):f64 化(17.8 大世界座標)會讓這次的 Vec3 / SIMD 寬度重構重做一遍,所以 17.8 排在 Wave C 末(出自 Phase 17 相依骨牌與 17.8 優勢區)

### 待辦與部分完成條目

#### 17.81 工程基礎建設與發行(CI / 授權 / 版本 / 文件 / 發佈) — Wave A

> **緣起**:2026-10-09 負空間盤點,合併 10 筆:CI(含 PR 檢查與託管測試矩陣)、LICENSE、CITATION、貢獻指南、英文文件、API 參考、版本與 CHANGELOG、棄用政策、套件發佈管道、格式 / lint 強制。
> **現況**:唯一的閘門是本機指令。`scripts/agent_gate.sh:2` 自述 "The one gate
> command for agents and humans",`scripts/agent_gate.sh:22` 以 `timeout 1800 pixi run test`
> 跑全套再比 golden(`docs/ARCHITECTURE.md:174-192`),但沒有東西自動觸發它:repo 無 `.github/`、
> `git log --all` 對 `.github/*`、`*.yml`、`*.yaml` 零筆,`.git/hooks` 只有 `*.sample`,
> PR #1 / #2 / #8–#13 合併時無 workflow 可跑。`pixi.toml:5` 只宣告 `linux-64`;
> `pixi.toml:6` `version = "0.1.0"` 從未變動,`git tag` 零個;`pixi.toml:7` 開了
> `preview = ["pixi-build"]` 但無 `[package]` 配方。根目錄無 `LICENSE*` / `NOTICE*` / `CITATION*` /
> `CONTRIBUTING*` / `CHANGELOG*`(歷史中也沒有)。格式:grep `mojo format` /
> `pre-commit` 於 `pixi.toml`、`scripts/`、`docs/` 零命中;閘門只擋編譯警告與錯誤
> (`tools/golden.mojo:212-213,238-240`)。文件:`docs/ROADMAP.md` 約 4.2 萬 CJK 字、
> `docs/CATEGORY.md` 約 7 千、`docs/SOTA_GAP_ANALYSIS.md` 約 1.3 千,只有 `README.md`
> 與 `docs/ARCHITECTURE.md` 是英文;`mojo doc` 只被 `tools/archindex.mojo` 用來產
> `build/archdoc/<pkg>.json` 供分層閘門(`docs/design/archindex.md:10`),沒有 API 參考頁。
> 版本承諾只有兩處:12.1「v0.x 凍結」(Phase 12「決定(2026-10-09)」、Phase 17 建議順序
> 2026-10-09 修訂「剩餘順序」(4))與 stress tier "run before a release"
> (`docs/ARCHITECTURE.md:149`),沒有發行流程。格式相容:6.10 快照 `_VERSION = 2` 遇不同版本
> 直接拒絕(`physics/serialize.mojo:38-44,127-128`),17.40 存檔按欄位名相容;兩種承諾都沒寫成
> 政策。grep `deprecat|棄用` 於 `docs/` 只命中工具鏈棄用(「工具鏈 2026-07-19」節、
> 16.3「做了什麼」),全樹 `@deprecated` 零命中。
> **缺口**:
> - **CI**:每次 push / PR 自動跑 `pixi run gate`,設為合併必要檢查;例:某 PR 改壞
>   17.40 的欄位名相容,`test_save` 在合併前紅燈,而不是等下次有人在本機跑。
>   託管 runner 無 GPU,但 golden 記的是真 GPU 輸出(`tests/golden/test_stdout.txt:482-487`
>   的 `test_gpu_contact` 22 checks;無加速器時只印 skip 與 1 check,
>   `tests/test_gpu_contact.mojo:143-147`)→ 需要依主機能力分的 golden profile,或自架
>   GPU runner(`README.md:34` 的 RTX 3060 開發機)。另設決定論 job:同 commit 跑兩次、
>   golden 逐節相同,承諾範圍同 Phase 17 建議順序 2026-10-09 修訂「剩餘順序」(3)的「同工具鏈同架構」。
> - **格式 / lint**:`mojo format --check` 進 gate 與 pre-commit hook;例:縮排漂移的 PR
>   在 CI 失敗,與 17.0a 的架構違規同等處理。全樹首次格式化單獨一個 commit,golden 不變。
> - **授權與引用**:`LICENSE`(授權種類由使用者決定)、第三方 `NOTICE`、`pixi.toml`
>   license 欄位;`CITATION.cff` 指向 PGA 螺旋剛體、LGVCI、emitted adjoint 等研究成果;
>   例:宿主引擎審查要嵌入的 12.1 `.so` 時,授權條款有檔可查。
> - **貢獻指南**:英文 `CONTRIBUTING.md` + PR 範本 + 行為準則,把 `CLAUDE.md`(中文、
>   寫給 agent)與 `docs/CATEGORY.md:63-87` 定律 v1–v3 轉成人類貢獻流程;例:新增 seam 的
>   PR 範本逐項勾 parity 測試、bench row、CATEGORY 列、普通 / 整合 / 極端三類案例。
> - **英文文件**:CATEGORY 定律與 seam 表、ROADMAP 狀態摘要的英文版;例:宿主整合者不讀
>   中文也查得到 17.39 回放的決定論範圍。摘要的條目清單由腳本對 ROADMAP 的 `###`
>   標題機械比對,譯本落後即失敗。
> - **API 參考**:由 archindex 已產的 `mojo doc` JSON 產生每版 API 頁(`ContactScene6`、
>   `World`、`SaveReader` 等公開型別);例:宿主查 `ContactScene6.set_velocity` 何時
>   `raise`,不必讀原始碼。
> - **版本 / CHANGELOG / 棄用政策**:semver tag;與 ROADMAP 分開、含 Breaking 段的
>   CHANGELOG;公開 API 棄用至少保留一個 minor 版並附遷移說明;各格式(6.10 快照 /
>   17.40 存檔 / 17.39 回放)的相容承諾表。例:12.1 C-ABI 改一個函式簽章時,舊名以
>   `@deprecated` 保留到下一個 minor。
> - **發佈管道**:pixi-build 配方產 conda 套件、17.21 的 Python wheel、12.1 的 C header +
>   `.so`,掛在 release;例:宿主以 `ludens-engine==0.2.*` 宣告相依,而不是 clone 後
>   `-I build`。
> **對照組**:Jolt(GitHub Actions 多平台 × Debug / Release / Distribution + 決定論 job、
> tagged release + `Docs/ReleaseNotes.md`、Doxygen 站)、MuJoCo(每版 changelog 含
> Breaking changes、PyPI wheel、readthedocs API 參考、引用說明)、Bevy(每版遷移指南、
> CI 跑 `cargo fmt --check`)、Godot(clang-format pre-commit、CONTRIBUTING)、Rapier
> (crates.io / npm);授權:Jolt / Box2D / Godot MIT、Rapier / MuJoCo Apache-2.0、
> Bullet zlib。
> **優勢區**:低 —— 純工程。閘門已是一條指令 + golden + selftest,CI 只是薄包裝;
> `mojo doc` JSON 已由 archindex 產出,API 頁不必另寫抽取器。
> **規模軸**:CI 牆鐘時間 × 矩陣格數(OS / 架構 / GPU 有無 / ASSERT 組態,後兩者接
> 17.82);現行 gate 上限 1800 s(`scripts/agent_gate.sh:22`)。
> **seam?**:否 —— 工程流程,不是可替換子系統;要求是 CI 與本機跑同一條 gate 指令、
> 同一份 golden。
> **交付**:普通(PR 觸發 gate 綠燈;tag `v0.2.0` 產出 CHANGELOG 段落與 release 附件)/
> 整合(故意弄壞一個測試的 PR 被擋下;release 產物裝進乾淨環境跑 examples,與 17.21 的
> 環境隔離測試同一套;API 頁與 archindex 吃同一份 JSON)/ 極端(無 GPU runner 上 GPU
> 段落走主機 profile、不誤判;gate 逾時被回報為失敗;repo 內呼叫已棄用 API → 編譯警告 →
> gate 失敗;英文摘要漏一個 ROADMAP 條目 → 同步檢查失敗)。
> **相依**:17.0a / 17.0b(gate 與 tier 本體)、12.1 與 17.21(發佈物)、6.10 / 17.39 /
> 17.40(格式相容承諾)、17.22(範例即文件)、17.76(平台矩陣)、17.82 / 17.83(CI 承載的
> 品質與效能檢查)。
> **邊界**:CI 服務、套件頻道、文件託管是外部線上服務;repo 只提供 workflow 檔、建置
> 配方、文件產生腳本與政策文件。

#### 17.82 品質工具:記憶體 / 競爭 / 覆蓋率 / fuzz / 性質測試 / 組態矩陣 — Wave A

> **緣起**:2026-10-09 負空間盤點,合併 9 筆:記憶體錯誤與洩漏偵測、資料競爭偵測、程式碼覆蓋率、fuzz、性質測試與縮小、不可信輸入硬化、GPU 核心驗證、發行組態測試、浮點例外攔截。
> **現況**:整套測試只有一種組態 —— `scripts/run_tests.sh:68` 固定
> `mojo run -D ASSERT=all`;bench 與 example 不開斷言(`scripts/run_benchmarks.sh:32`)
> 但不驗證任何東西。`pixi.toml:52` 已裝 valgrind,只用在 cachegrind 計 cache miss
> (`ECS_VS_OOP_INVESTIGATION.md:20,211-213`);grep `memcheck|helgrind|sanitiz|asan|tsan`
> 於 `scripts/`、`tools/`、`docs/` 零命中。引擎套件有約 130 行 `UnsafePointer` /
> `unsafe_*`(14 檔),含靠手寫 `__deinit__` 的型別抹除堆積槽(`ecs/reactive_backend.mojo:33`、
> `ecs/commands.mojo:24`、`geometry/field.mojo:295`)。越界類 bug 靠審計逐條改成 `raise`
> (E12 "UB in release"、E20,`docs/audits/2026-09-27-architecture.md:159,167`),
> `List[Vec3]` teardown 損毀靠手動逐段配對稽核定位(4.5「進度」)。平行路徑 —— 島平行
> (`physics/solver6.mojo:1405`)、著色配對(`physics/contact6.mojo:534`)、job graph
> (`scheduler/jobgraph.mojo:175`)—— 只靠串行 vs 平行 parity;審計 E7 記過一次真實資料
> 競爭(`docs/audits/2026-09-27-architecture.md:154`),10.2「誠實弱點」自承「沒有任何機制
> 驗證宣告與 `apply` 實際碰的東西一致」。`harness/runner.mojo:29-71` 只有 `check` / `eqi` /
> `almost` / `finish`,無產生器與縮小器;隨機輸入是手寫種子迴圈(23 個測試檔 import
> `scheduler.rng`,如 `tests/test_timers.mojo:121`;`scripts/arch_layers.toml:44` 稱之為
> "fuzzing input source"),grep `fuzz|proptest|shrink` 於 `docs/` 零命中。壞輸入測試是
> 固定幾例(`tests/test_save.mojo:129-149` 壞 magic / 截斷 / 較新格式;
> `tests/test_serialize.mojo:125-142` 截斷)。載入端驗 magic、版本、負數與截斷
> (`gameplay/save.mojo:115-127`),不設數量上限、不驗浮點有限性:`ecs/schema.mojo:250-256`
> 以 `pos + count * rec > len(data)` 防截斷,但零欄位批次(`rec = 0`)時 `count` 不受資料
> 長度約束,`count * rec` 也未防溢位;`load_bodies` 直接套用位姿(`gameplay/save.mojo:185`),
> NaN 要到步末掃描(`physics/solver6.mojo:962-964`)才被隔離;grep
> `security|threat|untrusted|惡意` 於 `docs/` 零命中。覆蓋率:grep
> `llvm-cov|gcov|kcov|覆蓋率` 零個程式碼覆蓋命中。GPU:7 個 GPU 測試檔在無加速器時自跳過
> (如 `tests/test_gpu_contact.mojo:143-147`),grep `compute-sanitizer|racecheck` 零命中。
> 浮點例外:grep `feenableexcept|fenv|SIGFPE` 零命中;`diag/invariant.mojo:59` 的
> `invariant_finite` 在引擎套件無呼叫點,NaN 只在事後處理
> (`docs/design/17.0h-error-wiring.md:21-26`)。stress tier 定義為 "adversarial inputs"
> (`docs/ARCHITECTURE.md:149`),目前 0 個檔案。
> **缺口**:
> - **記憶體錯誤 / 洩漏**:測試先 `mojo build` 成執行檔,再以既有 valgrind 的 memcheck 跑
>   unit + component tier(工具鏈若提供 ASan / LSan 則並列),附 Mojo runtime 的
>   suppression 檔;例:reactive backend 的 per-type `Slot` 在 `__deinit__` 漏釋放,或
>   `List[Vec3]` 類 teardown 越界,第一次就被報出。
> - **資料競爭**:helgrind / DRD(同一 valgrind 套件)或 TSan 跑平行路徑;另加 10.2 的
>   宣告稽核模式(除錯組態下記錄 `apply` 實際存取的 component,與宣告的讀寫遮罩比對)。
>   例:E7 類「兩個同色配對共用一個 body」在 parity 碰巧逐位相同時仍被報出。
> - **覆蓋率**:先做 spike,確認 Mojo 產出的 DWARF 行表能被 kcov 類工具使用,再出每套件
>   行 / 分支覆蓋;例:審計 E11 標為 "untested" 的 CCD × mesh / sensor 分支、存檔載入的
>   錯誤分支,哪些沒有測試走到一目了然。
> - **fuzz**:對位元組入口做變異式 fuzz(位元翻轉、截斷、長度欄位改寫):
>   `SaveReader(bytes)`、`scene_from_string`、`read_values`、`TriMesh` / 凸分解輸入;語料與
>   重現檔入 repo,每個 crash 轉成一條回歸測試;有覆蓋率工具後升級為覆蓋導向。例:上述
>   `rec = 0` 批次即第一個種子案例。
> - **性質測試 + 縮小**:`harness` 加產生器與縮小器(harness 在 `scripts/build_engine.sh:21`
>   緊接 diag 編譯,不能 import `scheduler.rng`,需自帶 PRNG 或調整建置序);例:「任兩個
>   隨機凸包,GJK 距離 ≥ 0 且 EPA 深度 > 0 ⇔ 重疊」失敗時縮到頂點最少的反例。
> - **不可信輸入硬化**:威脅模型文件 + `SECURITY.md` 回報管道;載入時的數量上限(段數、
>   欄位數、記錄數、body 數)與 NaN / Inf 拒絕(公開 API 非法輸入 → `raise`,
>   `docs/ARCHITECTURE.md:62`);例:玩家分享的 mod 存檔不能靠改一個 8 位元組長度欄位
>   讓遊戲配置數 GB 記憶體。
> - **GPU 核心驗證**:有 GPU 的 runner(或開發機排程)跑 7 個 GPU 測試檔,並以 NVIDIA
>   compute-sanitizer(memcheck / racecheck)跑一輪;例:LBM GPU kernel 改 32 位元索引
>   (17.42「進度」(a))若有越界,由工具報出,而不是靠數值偏差碰巧露出。
> - **發行組態**:以斷言關閉(宿主實際出貨的組態)再跑一次整套,golden 須逐節相同,允許的
>   差異在測試檔頭宣告;例:只在斷言關閉時才出現的 E12 類越界寫入。
> - **浮點例外攔截**:測試組態可開 invalid / div-by-zero / overflow trap(Linux 經 glibc
>   `feenableexcept`),第一個產生 NaN 的運算即中止並給出位置;例:FEM 元素反轉產生的
>   NaN 停在出事的那一行,而不是步末被隔離後只剩計數器 +1。執行期的 FP 環境 API(FTZ /
>   DAZ、宿主可設定)屬 17.76,本項只做測試組態。
> **對照組**:Jolt(CI 的 ReleaseASAN / ReleaseUBSAN / ReleaseTSAN / ReleaseCoverage 組態、
> `JPH_FLOATING_POINT_EXCEPTIONS_ENABLED`)、Godot(`use_asan` / `use_tsan`、`SECURITY.md`)、
> PhysX(debug / checked / profile / release 四組態)、MuJoCo(模型載入的 libFuzzer target)、
> Bullet3(OSS-Fuzz)、Drake(kcov)、Rust 生態的 proptest / cargo-fuzz;GPU:NVIDIA
> compute-sanitizer、Warp 的 debug 邊界檢查模式。
> **優勢區**:中 —— 決定論讓每個 fuzz / 性質測試失敗都能由(種子, 輸入)逐位重現,縮小器
> 不受不穩定重現干擾;既有串行 vs 平行 parity 測試已是 oracle,競爭偵測只補「碰巧相同」的
> 盲點。memcheck、覆蓋率本身為低 —— 純工程。
> **規模軸**:工具減速倍率(memcheck 約數十倍)決定哪些 tier 能在 CI 時限內跑;fuzz 每秒
> 執行數 × 語料大小;各套件行覆蓋率。
> **seam?**:否新 seam;但「斷言開 / 關」「FP trap 開 / 關」兩組態須 golden 逐節相同,比照
> `docs/CATEGORY.md:170` 既有的 `LUDENS_LOG_LEVEL` / `LUDENS_TRACE` compile-time on/off 列。
> **交付**:普通(memcheck 跑 unit tier 零錯誤;`SaveReader` fuzz 1e5 次無 crash;新測試
> test_prop_gjk 的性質在 1e3 組隨機凸包成立)/ 整合(新 `pixi run` 任務接進 17.81 的 CI;
> fuzz 找到的重現檔成為 `tests/` 回歸案例並進 golden;helgrind 跑 `test_scheduler_parity`、
> `test_islands_par`、`test_colored`)/ 極端(刻意植入的越界寫入、洩漏、無鎖共寫各被對應
> 工具報出,作為工具的負對照;`rec = 0` 批次、`count` 溢位、NaN 位姿各被拒絕;刻意注入 NaN
> 的 17.0h 測試在 trap 組態下列為預期中止;無加速器主機上 GPU 檢查回報「未執行」而非綠燈)。
> **相依**:17.33 / 17.0h(斷言與 NaN 隔離)、6.10 / 17.39 / 17.40(fuzz 目標)、10.2 /
> 6.5 / 6.11(平行路徑)、17.17 / 17.42(GPU kernel)、17.76(執行期 FP 環境)、17.81(CI 承載)。

#### 17.83 效能治理:回歸門檻、外部引擎同場對打、編譯成本預算 — Wave A

> **緣起**:2026-10-09 負空間盤點,合併 3 筆:效能回歸追蹤與門檻、與外部引擎同場景對打、編譯時間與二進位大小預算。
> **現況**:`docs/ARCHITECTURE.md:141` 寫 "Performance lives in `benchmarks/` (the report
> is the gate)",但沒有任何門檻:golden 刻意剝掉計時行(`tools/golden.mojo:5-6`,單位表
> 在 `tools/golden.mojo:92`),速度從不受閘門檢查;`scripts/run_benchmarks.sh:44-54` 只把範本
> 渲染後覆寫 `BENCHMARK_REPORT.md`,無歷史、無比較;報告標頭(`scripts/benchmark_report.md.in:1-9`)
> 沒有 commit / CPU / 工具鏈戳記;`harness/bench.mojo:22-37` 只回傳 20 次中的最小值,
> 不報離散度。雜訊量到了但沒控制:跨行程 ±15%(17.10「進度」的待辦)、
> 執行間漂移達 ~1.4×(`docs/design/wave-a-services.md:12-14`);報告最後一次重產在
> `9bff80f`(2026-09-29),之後未重產(Phase 17 建議順序 2026-10-09 修訂「本輪遺留待辦」)。grep
> `perf.*regress|效能.*(回歸|退化)|bench.*門檻` 於 `docs/` 零命中。對外比較:ROADMAP 自評
> 「已達競爭級」(開頭「重整(2026-07-22)」、「前瞻路線總覽」)、「已達或超過前沿」(Phase 17 緣起),
> 但 bench 只比內部 seam 變體與 `oop/` 基準;外部引擎只以對照組出現(如 17.19「對照組」),
> grep `large_pyramid|PerformanceTest|head-to-head|對打` 於 `docs/`、`README.md` 零命中;
> 唯一的外部數值驗證是 14.6 對文獻。編譯成本只以風險被提及 ——
> 「大範圍簽章掃描可能撞上編譯成本懸崖」(17.24「進度」引 17.0g 系列文件),commit `07450bf`
> 訊息手寫 "build 0 errors/0 warnings (~25s, no compile-cost-cliff)";
> `scripts/build_engine.sh:14-18` 的 `pc` 不計時,grep `binary size|monomorphi|bloat` 於
> `docs/` 零命中。
> **缺口**:
> - **(a)回歸門檻**:每次 bench 附戳記(commit、CPU 型號、核心數、工具鏈版本)追加到歷史檔;
>   比較工具(比照 `tools/golden.mojo` 附 selftest)對同機器基線標出變慢超過門檻的追蹤列;
>   門檻依該列量到的離散度訂,受門檻管的列改為同行程交錯 A/B,或多次取中位數 + 離散度。
>   例:`bench_solver_scale` N=4096 的 ns/step 因 warm-start 快取改動變慢 30%,合併前被標出。
> - **(b)外部引擎同場對打**:同機器、同場景跑 Jolt(C++)與 MuJoCo(conda-forge / PyPI),
>   回報 ns/step 與準確度(穿透深度、能量漂移、堆疊靜止時間;比照 `bench_rigid6` 的 1e5 步
>   漂移欄,4.1「進度」);場景:箱子金字塔、多布娃娃堆、凸體對三角網格。外部
>   引擎放獨立 pixi environment,不成為引擎相依。Box2D v3 是 2D,而本庫 2D 路徑已刪除
>   (17.0「已刪除(2026-09-29)」)→ 只引用其公開數字,不同場跑。例:「已達競爭級」改寫成
>   「N 層金字塔 ns/step 為 Jolt 的 x 倍、穿透為 y 倍」。
> - **(c)編譯成本 / 二進位大小預算**:`build_engine.sh` 逐套件計時與 `.mojoc` 大小、代表性
>   example 以 `mojo build` 產出的執行檔大小,入同一歷史檔並設預算;例:把 `Field` 泛型推進
>   新模組(17.20 類工作)讓 physics 預編譯時間翻倍時在 PR 上被標出,不再靠 commit 訊息手寫。
> **對照組**:Godot godot-benchmarks(逐 commit 結果儀表板)、Bevy CI benchmark 追蹤、
> perf.rust-lang.org(含編譯時間)、CodSpeed;Box2D v3 benchmark 套件(逐 CPU 公開結果)、
> Jolt PerformanceTest、Erez et al. 2015(Bullet / Havok / MuJoCo / ODE / PhysX 同場比較);
> `cargo build --timings`、LLVM `-ftime-trace`。
> **優勢區**:低 —— 純工程。輸出已由 golden 逐位鎖住,效能比較只需比時間,不必
> 另驗結果是否相同。對打表可多兩欄外部引擎沒有的:可微(17.20 子集)與逐位決定論;預期
> raw ns/step 會有輸的列,照實入報告。
> **規模軸**:(a)追蹤列數 × 歷史長度;門檻 vs 雜訊的誤報率。(b)金字塔層數 / 布娃娃數 /
> 接觸數。(c)套件 × 單態化數量;冷 / 熱建置。
> **seam?**:否 —— 量測基礎設施。對打場景以同一份場景描述餵兩邊,兩邊的質量、尺寸、摩擦、
> 步長一致由測試檢查,這是對打數字可比的前提。
> **交付**:普通(歷史檔帶戳記;人為放慢一列被標出)/ 整合(gate 摘要多一行效能差異;對打
> 表經 `@bench` 進 `BENCHMARK_REPORT.md`;編譯時間列進同一歷史檔)/ 極端(未改碼連跑兩次
> 不得被標出,作為誤報負對照;換機器或升工具鏈時重設基線而非比較,呼應 `CLAUDE.md:9` 升版須
> 重跑整套 bench;外部引擎未安裝時該列標「未執行」;冷建置與熱建置分開計)。
> **相依**:17.10(trace 與 ±15% 雜訊待辦)、17.19(`bench_solver_scale` / `bench_islands`
> 規模軸)、4.0(bench 覆蓋矩陣)、14.6(對外驗證前例)、17.0g(編譯成本懸崖風險)、
> 17.81(CI 承載)。

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
| 12.1 | [Core embedding 邊界(C-ABI)](#121-core-embedding-邊界c-abi) | 嵌入、腳本與平台 | ⬜ |
| 12.2 | [Mojo / Python 雙腳本](#122-mojo--python-雙腳本) | 嵌入、腳本與平台 | ⬜ |
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
| 17.8 | [大世界座標](#178-大世界座標) | ECS、排程、執行期與診斷 | ⬜ |
| 17.9 | [Debug-draw 指令佇列](ROADMAP_HISTORY.md#179-debug-draw-指令佇列--wave-a工具) | ECS、排程、執行期與診斷 | ✅ |
| 17.10 | [Profiling / tracing hooks](ROADMAP_HISTORY.md#1710-profiling--tracing-hooks--wave-a工具) | ECS、排程、執行期與診斷 | ✅ |
| 17.11 | [反射 / 型別註冊表](ROADMAP_HISTORY.md#1711-反射--型別註冊表--wave-b架構解鎖多項) | ECS、排程、執行期與診斷 | ✅ |
| 17.12 | [可編輯場景 / prefab / 實例化](#1712-可編輯場景--prefab--實例化) | ECS、排程、執行期與診斷 | 不排 |
| 17.13 | [世界查詢完整度](ROADMAP_HISTORY.md#1713-世界查詢完整度--wave-a) | 碰撞形狀、寬窄相與世界查詢 | ✅ |
| 17.14 | [導航](#1714-導航) | gameplay 服務、AI、導航與網路 | ⬜ |
| 17.15 | [AI 框架](#1715-ai-框架) | gameplay 服務、AI、導航與網路 | ⬜ |
| 17.16 | [網路 / rollback](#1716-網路--rollback) | gameplay 服務、AI、導航與網路 | ⬜ |
| 17.17 | [GPU 剛體 / articulation solver](#1717-gpu-剛體--articulation-solver) | GPU 計算 | 🔶 |
| 17.18 | [批次多世界步進(13.9 落地)](ROADMAP_HISTORY.md#1718-批次多世界步進139-落地--wave-b) | 可微模擬、批次世界與數值深化 | ✅ |
| 17.19 | [生產級 solver 硬化](#1719-生產級-solver-硬化) | 剛體動力學、接觸與關節 | 🔶 |
| 17.20 | [剛體 solver 可微化收尾(13.7)](ROADMAP_HISTORY.md#1720-剛體-solver-可微化收尾137--wave-b) | 可微模擬、批次世界與數值深化 | ✅ |
| 17.21 | [腳本層(Phase 12 落地)](#1721-腳本層phase-12-落地) | 嵌入、腳本與平台 | ⬜ |
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
| 17.44 | [複合形狀、共享形狀實例與質量性質](#1744-複合形狀共享形狀實例與質量性質--wave-b) | 剛體動力學、接觸與關節 | ⬜ |
| 17.45 | [三角網格 / 高度場碰撞品質與碰撞幾何烘焙](#1745-三角網格--高度場碰撞品質與碰撞幾何烘焙--wave-a) | 碰撞形狀、寬窄相與世界查詢 | ⬜ |
| 17.46 | [CCD 形狀與旋轉覆蓋、逐體接觸偏移](#1746-ccd-形狀與旋轉覆蓋逐體接觸偏移--wave-b) | 碰撞形狀、寬窄相與世界查詢 | ⬜ |
| 17.47 | [最大座標關節庫補完](#1747-最大座標關節庫補完--wave-b) | 剛體動力學、接觸與關節 | ⬜ |
| 17.48 | [剛體逐體參數與施力 API](#1748-剛體逐體參數與施力-api--wave-a) | 剛體動力學、接觸與關節 | ⬜ |
| 17.49 | [接觸 / 關節力回報與衝擊事件](#1749-接觸--關節力回報與衝擊事件--wave-a) | 剛體動力學、接觸與關節 | ⬜ |
| 17.50 | [接觸模型與求解器變體](#1750-接觸模型與求解器變體--wave-b) | 剛體動力學、接觸與關節 | ⬜ |
| 17.51 | [縮座標關節體完整化(球關節・雙向接觸・閉環・可微)](#1751-縮座標關節體完整化球關節雙向接觸閉環可微--wave-b) | 縮座標關節體與致動 | ⬜ |
| 17.52 | [碰撞形狀種類擴充(動態凹網格 / SDF / 曲面基元 / 半空間 / 體素 / 點雲)](#1752-碰撞形狀種類擴充動態凹網格--sdf--曲面基元--半空間--體素--點雲--wave-b) | 碰撞形狀、寬窄相與世界查詢 | ⬜ |
| 17.53 | [世界查詢擴充(過濾謂詞 / 多命中 / any-hit / kNN / PVS / GPU 真實幾何射線)](#1753-世界查詢擴充過濾謂詞--多命中--any-hit--knn--pvs--gpu-真實幾何射線--wave-a) | 碰撞形狀、寬窄相與世界查詢 | ⬜ |
| 17.54 | [CPU 多執行緒碰撞管線(寬相更新 / narrowphase / manifold)](#1754-cpu-多執行緒碰撞管線寬相更新--narrowphase--manifold--wave-b) | 碰撞形狀、寬窄相與世界查詢 | ⬜ |
| 17.55 | [連續體共用步進契約(審計 F25)](#1755-連續體共用步進契約審計-f25--wave-b) | 軟體、布料、連續體與流體 | ⬜ |
| 17.56 | [布料完整化(綁骨架、彎曲、任意網格、空氣動力、CCD、撕裂)](#1756-布料完整化綁骨架彎曲任意網格空氣動力ccd撕裂--wave-b) | 軟體、布料、連續體與流體 | ⬜ |
| 17.57 | [毛髮、彈簧骨與肌肉次級動力學](#1757-毛髮彈簧骨與肌肉次級動力學--wave-c) | 軟體、布料、連續體與流體 | ⬜ |
| 17.58 | [體積軟體完整化](#1758-體積軟體完整化--wave-c) | 軟體、布料、連續體與流體 | ⬜ |
| 17.59 | [流體-固體雙向耦合](#1759-流體-固體雙向耦合--wave-c) | 軟體、布料、連續體與流體 | ⬜ |
| 17.60 | [水面與網格流體(淺水・海浪・煙火・FLIP・多相・黏塑・爆炸波)](#1760-水面與網格流體淺水海浪煙火flip多相黏塑爆炸波--wave-c) | 軟體、布料、連續體與流體 | ⬜ |
| 17.61 | [多物理材料(顆粒 / 熱傳與相變 / 電磁 / 植被)](#1761-多物理材料顆粒--熱傳與相變--電磁--植被--wave-c) | 軟體、布料、連續體與流體 | ⬜ |
| 17.62 | [GPU 連續體與可微連續體(含可微盒 / 膠囊 / 凸包接觸)](#1762-gpu-連續體與可微連續體含可微盒--膠囊--凸包接觸--wave-c) | 軟體、布料、連續體與流體 | ⬜ |
| 17.63 | [模擬輸出、烘焙快取與稀疏體積](#1763-模擬輸出烘焙快取與稀疏體積--wave-c) | 軟體、布料、連續體與流體 | ⬜ |
| 17.64 | [動畫執行期補完](#1764-動畫執行期補完--wave-b) | 動畫與程序化 | ⬜ |
| 17.65 | [蒙皮形變資料(morph target / 臉部 / 姿勢空間修正)](#1765-蒙皮形變資料morph-target--臉部--姿勢空間修正--wave-c) | 動畫與程序化 | ⬜ |
| 17.66 | [物理角色控制與學習式動畫接點](#1766-物理角色控制與學習式動畫接點--wave-c) | 角色、載具、破壞與 gameplay 物理 | ⬜ |
| 17.67 | [角色移動模式與控制器變體](#1767-角色移動模式與控制器變體--wave-b) | 角色、載具、破壞與 gameplay 物理 | ⬜ |
| 17.68 | [遊戲攝影機、序列器與協程](#1768-遊戲攝影機序列器與協程--wave-b) | 角色、載具、破壞與 gameplay 物理 | ⬜ |
| 17.69 | [程序化內容生成](#1769-程序化內容生成--wave-c) | 動畫與程序化 | ⬜ |
| 17.70 | [gameplay 規則框架(屬性與效果 / 標籤 / 傷害 / 背包 / 抽選 RNG / 回合規則)](#1770-gameplay-規則框架屬性與效果--標籤--傷害--背包--抽選-rng--回合規則--wave-c) | gameplay 服務、AI、導航與網路 | ⬜ |
| 17.71 | [戰鬥與互動物理(彈道 / 物理抓取 / 逐骨命中框 / 近戰掃掠)](#1771-戰鬥與互動物理彈道--物理抓取--逐骨命中框--近戰掃掠--wave-b) | 角色、載具、破壞與 gameplay 物理 | ⬜ |
| 17.72 | [gameplay 流程服務(遊戲狀態 / 重要度降頻 / 生成與波次 / 逐實體時間縮放 / 對話任務)](#1772-gameplay-流程服務遊戲狀態--重要度降頻--生成與波次--逐實體時間縮放--對話任務--wave-c) | gameplay 服務、AI、導航與網路 | ⬜ |
| 17.73 | [營運與宿主側服務邊界(成就與遙測 / 線上服務 / 模組 / 本地化 / 無障礙)](#1773-營運與宿主側服務邊界成就與遙測--線上服務--模組--本地化--無障礙--wave-c) | gameplay 服務、AI、導航與網路 | ⬜ |
| 17.74 | [載具家族擴充與地面力學(履帶 / 機車 / 飛行器 / 多旋翼 / 船舶推進 / 輪-土壤)](#1774-載具家族擴充與地面力學履帶--機車--飛行器--多旋翼--船舶推進--輪-土壤--wave-c) | 角色、載具、破壞與 gameplay 物理 | ⬜ |
| 17.75 | [嵌入契約:宿主注入、非同步步進、併發存取與單位慣例](#1775-嵌入契約宿主注入非同步步進併發存取與單位慣例--wave-b) | 嵌入、腳本與平台 | ⬜ |
| 17.76 | [平台與硬體可攜性](#1776-平台與硬體可攜性--wave-b) | 嵌入、腳本與平台 | ⬜ |
| 17.77 | [ECS 表達力補完](#1777-ecs-表達力補完--wave-b) | ECS、排程、執行期與診斷 | ⬜ |
| 17.78 | [宿主引擎參考整合、多語言綁定與功能模組](#1778-宿主引擎參考整合多語言綁定與功能模組--wave-c) | 嵌入、腳本與平台 | ⬜ |
| 17.79 | [執行期資源治理與排程拓撲](#1779-執行期資源治理與排程拓撲--wave-b) | ECS、排程、執行期與診斷 | ⬜ |
| 17.80 | [觀測:物理擷取、執行期追蹤開關與飛行記錄器](#1780-觀測物理擷取執行期追蹤開關與飛行記錄器--wave-b) | ECS、排程、執行期與診斷 | ⬜ |
| 17.81 | [工程基礎建設與發行(CI / 授權 / 版本 / 文件 / 發佈)](#1781-工程基礎建設與發行ci--授權--版本--文件--發佈--wave-a) | 工程、測試、效能與工具鏈 | ⬜ |
| 17.82 | [品質工具:記憶體 / 競爭 / 覆蓋率 / fuzz / 性質測試 / 組態矩陣](#1782-品質工具記憶體--競爭--覆蓋率--fuzz--性質測試--組態矩陣--wave-a) | 工程、測試、效能與工具鏈 | ⬜ |
| 17.83 | [效能治理:回歸門檻、外部引擎同場對打、編譯成本預算](#1783-效能治理回歸門檻外部引擎同場對打編譯成本預算--wave-a) | 工程、測試、效能與工具鏈 | ⬜ |
| 17.84 | [數值與可微深化:接觸隱式微分、因數分解、預條件子、學習式殘差](#1784-數值與可微深化接觸隱式微分因數分解預條件子學習式殘差--wave-c) | 可微模擬、批次世界與數值深化 | ⬜ |
