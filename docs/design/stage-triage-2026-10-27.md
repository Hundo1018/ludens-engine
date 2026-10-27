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
- 17.19 / 17.58 / 17.61 / 17.63:子代理回報為 stale-done 8、doable 11、unverified 5、deferred 7、GPU 1、
  env-blocked 1。逐列表格未在本文件中重現,**尚未由作者複核**;在複核前不得據此關閉任何條目。

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
| 水上舵升力、解析 Gerstner 波面 | doable | `watercraft.mojo:26` `HullBuoyancy[W: WaterSurface]` 接受任何 WaterSurface | 補 Gerstner WaterSurface 實作與起伏 / 俯仰測試;**Gerstner 實作是否存在未驗證** |
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
| (a) 工作量計數器精確斷言 | doable | `diag/counters.mojo:171-175` 已有計數器;精確斷言只見於 `tests/probes/trace_on_probe.mojo:59`(probe,非閘門) | 對 ContactScene6 fixture 加精確計數斷言測試 |
| 注入 +5 / +10 / +25 % 偵測率 | doable | `perf.py` selftest 只注入 +20 %(perf.py:335) | selftest 加入三個注入等級(合成資料,不需牆鐘) |
| (b) cachegrind 指令數代理 | unverified | `scripts/icount.py` 存在;未執行 | — |
| (c) 每步配置次數 | deferred | tests/、scripts/、diag/ 內 AllocStats / dhat 0 命中 | 宿主或 CI 需要配置次數閘門 |
| 基準線檔入 repo | env-blocked | repo 內無基準線;4 核容器無法產生固定主機基準 | 固定主機 |
| 夜間牆鐘閘門、真實機器偵測率 | env-blocked | ROADMAP:4048 需要釘核與穩定時脈 | 固定主機 |

## 計數(僅本文件所列 42 列,不含 17.19 / 17.58 / 17.61 / 17.63)

- stale-done 14、deferred 13、doable 4、env-blocked 5、GPU 1、unverified 1。
- doable 四項:17.74 Gerstner 波面(實作存在性待查)、17.76 wasm 切分檢查、17.83 精確計數斷言、17.83 合成注入等級。
- 17.74 的「軸陣列 / 快照 / 17.85 分級」以 ROADMAP 文字標為 deferred,未重新 grep。

## 結論

- 階段目標未完成:doable 項目存在(上列 4 項,加上 17.19 / 17.58 / 17.61 / 17.63 中子代理回報的 11 項待複核)。
- GPU / UI / env-blocked 項目不計入階段目標。
- stale-done 項目應在 ROADMAP 對應子句註明已完成,以免重複列為未做。
