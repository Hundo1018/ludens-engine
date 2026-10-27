# 階段分流(2026-10-27):🔶 列的未做子句

目的:把 ROADMAP 🔶 列的未做子句逐條標為 doable / GPU / UI-editor / env-blocked / stale-done / deferred,
讓「階段目標是否完成」可由表格判定,而不是由條目數判定。本文件不改程式碼。

標籤定義與驗證規則同 ROADMAP 17.60 的分流標準:stale-done 與 doable 需要實際執行過的 grep 證據;
無法驗證者標 unverified。

## 本文件的驗證狀態(誠實標註)

- 17.70 / 17.74 / 17.76 / 17.78 / 17.83 / 17.86:下表每列由唯讀子代理回報;作者抽查了下列證據,
  全部成立:`tests/test_strand_torsion.mojo`、`gameplay/rules_ecs.mojo`、`tests/test_rules_ecs.mojo`、
  `gameplay/watercraft.mojo`、`tests/test_vehicle_slope.mojo`、`scripts/perf.py`(`compare_runs` 172、
  `fit_slope` 202、`check_budgets` 249)、`diag/counters.mojo` 171(`narrowphase_pairs`)、
  `scripts/orphans_allow.txt`。其餘 file:line 引用未逐一重跑。
- 17.19 / 17.58 / 17.61 / 17.63:表格取自子代理的 SubagentHandback 紀錄(同一 transcript 的 tool_use 區塊),
  並於下方收入本文件。作者抽查成立:`physics/contact6.mojo:492`、`physics/mpm_melt.mojo:24`(docstring)、
  `geometry/vdb_file.mojo:427` 與 `:458`(raise 訊息)、`geometry/abc_file.mojo` 內 read / parse / decode / load 0 命中、
  `physics/mac_fluid.mojo` 內 solid / obstacle / mask 0 命中、`physics/strand_air.mojo` 與 `cloth_air.mojo` 內
  Smoke2 / MacFluid2 0 命中、`physics/mac_fluid.mojo:183` 與 `mac_fluid3.mojo:480` 的 add_impulse、
  `tests/test_stress_solver.mojo:74` 將 `lin_sleep_tol` 設為 0(即測試以關閉睡眠來迴避睡眠接觸衝量問題)。
  其餘列未逐一重跑。

## 17.86 扭轉股線整合

| 子句 | 標籤 | 證據 | 下一步 |
|---|---|---|---|
| StrandSet 逐粒子扭轉、扭轉整合 | stale-done | `physics/strand.mojo` 49-56、89、94、148;`tests/test_strand_torsion.mojo` 6/6 | — |
| 螺旋 / plectoneme 量測、Greenhill 長度掃描 | stale-done | `tests/test_rod_plectoneme.mojo` 3/3;`tests/test_rod_greenhill.mojo` 2/2 | — |
| 球 / 盒 / 空氣耦合 | stale-done | `tests/test_strand_contact_twist.mojo` 4/4;`tests/test_strand_scene_twist.mojo` 4/4;`tests/test_strand_air_twist.mojo` 5/5 | — |
| Rope 扭轉整合 | deferred | `physics/rope.mojo` 內 twist 0 命中 | 17.41 繩索消費者需要扭轉 |
| frame-reading 接觸 / 空氣模型 | deferred | 設計已寫、檢查未執行 | 17.57 毛髮需要各向異性阻力 |
| Greenhill 離散校正 B、C | deferred | ROADMAP 條目標為「未經驗證」 | 需要絕對 φ_c 的消費者 |
| `rod_from_strand` 鏈條 parity | deferred | 量測為不等價 | 目前無法依原文達成 |

## 17.74 載具家族

| 子句 | 標籤 | 證據 | 下一步 |
|---|---|---|---|
| 陡坡爬升 | stale-done | `tests/test_vehicle_slope.mojo` 3/3 | — |
| 履帶車(滑移轉向、坡道、停車錨) | stale-done | `gameplay/vehicle_kinds.mojo:141` TrackDrive;`tests/test_vehicle_kinds.mojo` 12/12 | — |
| 水上浮力、推進器、飛行翼面 CL/CD | stale-done | `gameplay/watercraft.mojo:26`;`gameplay/force_element.mojo:26`;`gameplay/aircraft.mojo:25`;`tests/test_force_elements.mojo` 13/13;`tests/test_wing_polar.mojo` 9/9 | — |
| 機車、直升機、座位、轎車元件包裝 | stale-done | `gameplay/bike.mojo`、`helicopter.mojo`、`vehicle_seat.mojo`、`vehicle_element.mojo` 各有測試 | — |
| 轎車管線拆成元件(懸吊 / 輪胎 / 傳動) | deferred | `vehicle_element.mojo:22` 包住整個 `Vehicle.update`,ROADMAP 標為技術債 | 第二種載具需要可替換元件 |
| Runtime 擁有 Vehicle | deferred | `gameplay/runtime.mojo` 內 Vehicle 0 命中 | 宿主要求經 Runtime 步進載具 |
| 地形壓痕 | deferred | `gameplay/` 內壓痕 / deform 0 命中 | 17.30 地形變形消費者 |
| 解析 Gerstner 波面 | stale-done | `physics/water.mojo:57` `GerstnerWave`、`:66` `GerstnerWater(WaterSurface)`;`tests/test_force_elements.mojo:27` 匯入 `GerstnerWater` | — |
| 水上舵升力 | doable | `watercraft.mojo:26` `HullBuoyancy[W: WaterSurface]` 只含浮力;`gameplay/watercraft.mojo`、`physics/water.mojo` 內 rudder / 舵 0 命中 | 以 `Thruster` 同形的力元件加舵升力 CL(α),測試:舵角 0 無側力、舵角 ±10° 側力符號正確 |
| 懸浮 / RCS 陣列、操縱面、噴射推力、地面效應 | deferred | `hover` 僅見註解,無 RCS 配置器 | 規劃中的氣墊船或太空消費者 |
| 狀態入快照、VehicleInput 軸陣列、多軸卡車、軌道車、零件脫落、17.85 分級 | deferred | ROADMAP:2838 列為未做;**子代理未重新 grep** | 各自的消費者 |

## 17.70 規則框架

| 子句 | 標籤 | 證據 | 下一步 |
|---|---|---|---|
| (a) 元件化子集(ECS 變體) | stale-done | `gameplay/rules_ecs.mojo:26-47`(Life/Stat/Buff/Dot);`tests/test_rules_ecs.mojo` 12/12 | — |
| 計時比較 oop vs rules | stale-done | `benchmarks/bench_rules_oop.mojo`;`tests/test_rules_oop.mojo` 4/4 | — |
| 完整框架元件化(tags、疊加、免疫、抗性管線、序列化) | deferred | rules_ecs 只涵蓋 buff + DoT;ROADMAP 量測 ECS 約 6 倍指令成本 | 宿主實際需要完整規則集於 ECS |
| Runtime 擁有 Rules | deferred | `gameplay/runtime.mojo` 0 命中 | 宿主要求經 Runtime 步進規則 |

## 17.76 平台可攜

| 子句 | 標籤 | 證據 | 下一步 |
|---|---|---|---|
| linux-aarch64 / osx-arm64 實測、ARM/macOS golden、跨架構 dump 比對 | env-blocked | `.github/workflows/ci.yml:59-67` 已有 ubuntu-24.04-arm 與 macos-14 矩陣;`tests/golden/` 僅有 `test_stdout.txt`,無分平台 golden | 需要 ARM / macOS 執行環境;若 CI 已跑,記錄其結果(未查) |
| 跨目標容差表、降級矩陣 | stale-done | ROADMAP:3801-3805(2026-10-17) | — |
| wasm 核心 / 殼切分的機器檢查 | doable | `scripts/wasm_probe.py:1-10` 只涵蓋葉核心;ROADMAP:3751-3752 說明無切分檢查 | 在 `wasm_probe --selftest` 加入「純核心 import 掃描」規則 |
| wasm64 / 含指標模組 | env-blocked | 需要外部 llc;Modular LLVM 無 wasm 後端 | — |
| AMD / Apple GPU 路徑 | GPU | ROADMAP:3744-3745 | 需要 AMD / Apple 加速器 |

## 17.78 宿主整合 / 綁定

| 子句 | 標籤 | 證據 | 下一步 |
|---|---|---|---|
| Godot / Unity 實機適配層 | env-blocked | 無適配層程式碼;Godot / Unity 只出現在文件 | 在裝有 Godot / Unity 的機器上執行 |
| 批量 SoA 交換、POD 事件緩衝 | stale-done | `embed/ludens.h:89` ld_world_get_bodies、`:100` ld_world_get_events、`:114` ld_world_set_poses | — |
| 宿主定義元件 / 查詢、綁定產生、多實例與執行緒 | stale-done | `ecs/host_components.mojo:35`;`tests/test_host_bulk.mojo` 9/9;`tests/test_capi.mojo` 66/66;`scripts/gen_bindings.py` | — |

## 17.83 效能治理

| 子句 | 標籤 | 證據 | 下一步 |
|---|---|---|---|
| 比較工具(依雜訊判定、指紋不符拒絕) | stale-done | `scripts/perf.py:172` compare_runs;selftest 於 perf.py:335 | — |
| 漸近斜率閘門、影格預算表、報告治理、bisect、交錯 A/B | stale-done | `perf.py:202` fit_slope、`:249` check_budgets;`scripts/perf_slopes.toml`;`scripts/perf_budgets.json`;`scripts/bench_fresh.py` | — |
| (a) 工作量計數器精確斷言 | stale-done | `diag/counters.mojo:171-175` 計數器;`tests/test_work_counters.mojo`(integration):`sc.counters.get(NARROWPHASE_PAIRS / CONTACT_MANIFOLDS / CONTACT_POINTS)` 精確斷言,N=1、N=4^k、無動態體 | — |
| 注入 +5 / +10 / +25 % 偵測率 | stale-done(2026-10-27 本輪完成) | `scripts/perf.py` selftest 20 / 20;+10 %、+25 % 被判回歸,+5 % 不被判(3 % 雜訊下的量測邊界,以斷言固定) | 無(後續:CI 未執行 perf selftest) |
| (b) cachegrind 指令數代理 | unverified | `scripts/icount.py` 存在;未執行 | — |
| (c) 每步配置次數 | deferred | tests/、scripts/、diag/ 內 AllocStats / dhat 0 命中 | 宿主或 CI 需要配置次數閘門 |
| 基準線檔入 repo | env-blocked | repo 內無基準線;4 核容器無法產生固定主機基準 | 固定主機 |
| 夜間牆鐘閘門、真實機器偵測率 | env-blocked | ROADMAP:4048 需要釘核與穩定時脈 | 固定主機 |

## 17.19 / 17.58 / 17.61 / 17.63(子代理回報,作者抽查如上)

### 17.19 剛體堆疊與接觸

| 子句 | 標籤 | 證據 | 下一步 |
|---|---|---|---|
| `step_soft` 暴露 `max_mass_ratio` | stale-done | `physics/solver6.mojo:2614`;`tests/test_stress_solver.mojo:59` | — |
| 開啟縮放時的力報告失真(A2) | stale-done | `physics/solver6.mojo:2636` `_own_excess`;`physics/contact6.mojo:107`;`tests/test_stress_solver.mojo:67` | — |
| 「穩定堆疊只驗證到 6 箱」(現況) | stale-done | `tests/test_stress_solver.mojo:126` tower、`:219` 十箱斷言、`:23` 64 箱堆 | — |
| 睡眠堆疊回報零接觸衝量(d) | doable | `physics/contact6.mojo:492` `accumulate_step_impulse`;測試以 `lin_sleep_tol = 0` 迴避(`test_stress_solver.mojo:74`) | 新增兩箱堆疊地板讀數約 9820 N 的測試(睡眠開啟),修前應失敗 |
| 負載相依接觸剛度與質量分配 | doable | `physics/body_set.mojo:152` 只有逐物體 hertz,無負載項 | 以 `tests/test_stress_solver.mojo` 的 0.5 m 重箱穿透案例作為閘門 |
| 會計熱點(coloring、逐幀 BVH、CCD 全配對) | doable | ROADMAP:375;BVH 移動後重建 `physics/solver6.mojo:1833` | 以既有 bench 於 N=4096 做剖析,一次只改一個熱點 |
| 凸殼振盪(body 14,解除睡眠後) | unverified | 只有 ROADMAP:316 的重現描述,未找到測試 | — |
| `_emit_events` 讀原始衝量(a);關節力矩(b) | unverified | `physics/solver6.mojo:2328` docstring 說事件來自接觸集;原始衝量與力矩路徑未讀 | — |
| 網格窄相 逐三角 SAT 成本 | unverified | 僅 ROADMAP:376 | — |
| `max_mass_ratio` 預設開啟、heightfield active-edge | deferred | ROADMAP:314、375 | 需要改變既有場景決策;目前無需要 |
| 非堆疊支撐圖分割近似(c) | deferred | ROADMAP:335 | 環形支撐場景的負載誤差超出容差時 |
| GPU 拒絕 `max_mass_ratio`;GPU anchor / substep | GPU | `physics/gpu_contact.mojo:351-352` | — |

### 17.58 軟體與 MPM 沙

| 子句 | 標籤 | 證據 | 下一步 |
|---|---|---|---|
| Projective dynamics(VBD 段) | stale-done | `physics/fem_pd.mojo:45` `FemPd`;`tests/test_fem_pd.mojo:50` | — |
| 無 neo-Hookean / 無四面體網格生成(現況) | stale-done | `physics/fem_material.mojo:87` `StableNeoHookean`;`geometry/tetmesh.mojo:24` `TetMesh`;`tests/test_tetmesh.mojo` | — |
| 沙子攤平、原因未知 | doable | `physics/mpm.mojo:151` `set_sand`;`tests/test_mpm_sand.mojo` | 30° 砂柱測試,記錄 G2P 耗散以切分成因 |
| Tampubolon 體積修正未重測 | doable | ROADMAP:1633;`tests/test_mpm_sand.mojo` | 開啟修正後重跑 30 / 60 / 85° 掃描 |
| 黏彈(塑性 / 黏彈範圍) | deferred | `physics/ fluid/ numerics/` 內 viscoelas / 黏彈 0 命中 | 需要速率相依固體響應的場景 |
| XPBD-FEM 變體 | deferred | `physics/fem*` 內 xpbd 0 命中 | 約束求解器比較需求 |
| 域壁 μ;skin 固定 dx/4 | deferred | ROADMAP:1642-1643;`tests/test_mpm_domain.mojo` | ROADMAP 標為「留待需要時」;0.3 dx 的接觸間隙量測 |

### 17.61 流體

| 子句 | 標籤 | 證據 | 下一步 |
|---|---|---|---|
| 3-D 點源(未做) | stale-done | `physics/mac_fluid3.mojo:480` `add_impulse`;`tests/test_fluid3_point.mojo:60` | — |
| 固體不阻擋 MacFluid2 面 | doable | `physics/mac_fluid.mojo` 內 solid / obstacle / mask 0 命中 | 面更新加入固體格遮罩;32² 網格中放一個方塊的測試 |
| 股線 / 布料 ↔ Smoke2 雙向 | doable | `physics/strand_air.mojo`、`cloth_air.mojo` 內 Smoke2 / MacFluid2 0 命中(兩者皆用 `Lbm`) | 以 `MacFluid2.add_impulse`(`physics/mac_fluid.mojo:183`)為 −J,做 1 股線探針 |
| 糊狀顆粒保持固體;剪應力未按 φ 縮放 | doable | `physics/mpm_melt.mojo:24` docstring「Mushy particles stay solid」 | 逐顆粒剪應力乘以 (1 − φ);於 `tests/test_mpm_melt.mojo` 測試 |
| 氣體容器壁;布料+空氣 2.8 % 動量缺口;多相假流 | unverified | ROADMAP:2014、2021、2025;`physics/multiphase.mojo:23-27` 有壁 | — |
| 火 / 燃燒(浮力驅動) | deferred | `physics/thermal.mojo:32` 僅註解 | 火場景(17.61 邊界:化學不在範圍) |

### 17.63 快取與檔案格式

| 子句 | 標籤 | 證據 | 下一步 |
|---|---|---|---|
| sim cache、`CachePlayer`、格式治理 | stale-done | `physics/sim_cache.mojo:206` `PointCacheReader`、`:339` `CachePlayer`;`tests/test_sim_cache.mojo` | — |
| Alembic 寫入;OpenVDB 寫入 / 稀疏體積 | stale-done | `geometry/abc_file.mojo:147` `_Ogawa`;`geometry/vdb_file.mojo:125` `vdb_bytes`;`geometry/sparse_volume.mojo`;`tests/test_abc_file.mojo`、`test_vdb_file.mojo`、`test_sparse_volume.mojo` | — |
| 大小 vs 重算取捨 | unverified | ROADMAP:2136 僅量測描述;bench 未查 | — |
| NanoVDB | env-blocked | 無程式碼(`geometry/sparse_volume.mojo:18` 僅註解);需要參考 `.nvdb` 與規格 | 取得參考檔與規格 |
| 讀回自寫 `.vdb`(blosc / zip);讀外部 VDB SDF | doable | `geometry/vdb_file.mojo:458` raise「zip / blosc not supported」 | 實作一個 grid 的 zlib inflate;`tests/test_vdb_file.mojo` 往返測試 |
| 主動 tile 讀取 | doable | `geometry/vdb_file.mojo:427` raise | 於 `vdb_grid` 把 tile 展開為體素;以含 tile 的檔案測試 |
| Alembic 讀回 | doable | `geometry/abc_file.mojo` 只有寫入 `_Ogawa`;read / parse / decode / load 0 命中 | 加入讀取器;`tests/test_abc_file.mojo` 往返自身輸出 |
| 點數變化時的強制 keyframe | deferred | `physics/sim_cache.mojo:206`;ROADMAP:2164 | 點快取場景的點數會變(拓撲已改走 Alembic) |

子代理回報的列數:stale-done 8、doable 11、unverified 5、deferred 7、GPU 1、env-blocked 1(共 33 列,部分列合併多個子句)。

## 計數(上方 42 列,不含 17.19 / 17.58 / 17.61 / 17.63)

- stale-done 14、deferred 13、doable 4、env-blocked 5、GPU 1、unverified 1。
- 本輪勘誤(2026-10-27,作者複核後):17.74 Gerstner 波面與 17.83 精確計數斷言原被標 doable,實際已存在(分別為 `physics/water.mojo:66` 與 `tests/test_work_counters.mojo`);改為 stale-done。17.83 合成注入等級與 17.76 wasm 切分檢查已於本輪完成。
- 17.74 的「軸陣列 / 快照 / 17.85 分級」以 ROADMAP 文字標為 deferred,未重新 grep。

## 結論

- 階段目標未完成:doable 項目存在(上列 4 項,加上 17.19 / 17.58 / 17.61 / 17.63 中子代理回報的 11 項待複核)。
- GPU / UI / env-blocked 項目不計入階段目標。
- stale-done 項目應在 ROADMAP 對應子句註明已完成,以免重複列為未做。
