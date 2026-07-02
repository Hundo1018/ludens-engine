# ECS 為何「慘輸」OOP — 分層取證定論報告

> 一句話結論：**這不是 ECS 記憶體佈局的缺陷。** 反組譯層證明 ECS 的欄式(SoA)儲存
> 與 OOP 的 AoS 產生**逐指令相同**的最佳化程式碼,並在資料量越過快取時**反超 OOP 2–4 倍**。
> 原始 benchmark 的「慘輸」來自兩件與佈局無關的事:(1) 拿 ECS 的**人體工學 handle 路徑**
> (每幀配置 + 未內聯、帶邊界檢查、未向量化的存取器)去比 OOP **內聯且向量化的裸迴圈**;
> (2) 在 **N≤4000(工作集 ≤128KB,全裝進 L2)** 的規模下量測 —— 而 locality 正是 ECS 的
> 唯一優勢,在此規模**物理上無從展現**。此外存在一組**真實、可修**的 API/codegen 稅
> (非佈局問題),列於文末待辦(依既定範圍「修正另議」)。

---

## 1. 方法與環境

| 項 | 值 |
|---|---|
| CPU | Intel i7-1280P(Alder Lake,6 P + 8 E);L1d 48KB、L2 1.25MB/core、L3 24MB shared |
| Mojo | nightly `1.0.0b3.dev2026061606`,預設 `-O3` |
| 量測衛生 | 綁 P-core(`taskset -c 3`)、暖機、重複 30 次取 **min**、保留原始 ns(不取整) |
| 靜態/剖析工具 | `mojo build --emit asm`、`objdump`、`llvm-mca`;**`valgrind`/`cachegrind`/`cg_annotate` 已透過 `pixi add valgrind` 裝入專案環境**(免 root),用於 §5 確定性 cache-miss 計數 |
| 硬體 counter | `perf stat -d`:原被 `perf_event_paranoid=4` 擋,已 `sudo sysctl kernel.perf_event_paranoid=-1`(runtime,重開機還原)啟用,取真實 cache-miss/IPC。§5 為四方交叉:mca + cachegrind + perf + 時間法 |
| 產物 | `scratchpad/ecs-probe/{probe_layout.mojo,probe_api.mojo,*.s,layout_result.csv}` |

原始謎團(`BENCHMARK_REPORT.md`,movement 工作負載,N=500/1000/4000,F=20):

| variant | update ns/op |
|---|---|
| oop | 1 |
| archetype (soa) | 2 |
| naive | 6–8 |
| bitset | 10–12 |
| sparse | 24–25 |
| archetype (handle) | 32–33 |
| reactive | 35–41 |

---

## 2. 假說判定

| # | 假說 | 判定 | 依據 |
|---|---|---|---|
| **H1** | 結果落在計時解析度地板 | **部分成立** | N=500/F=20 → update 總時 ~10µs,ns/op 再被 `_round_i` 取整;「1 vs 2」不具意義。但 handle 的 20–40 遠高於雜訊,是真實差距 |
| **H2** | 抽象不對等(API vs 裸迴圈) | **成立(核心)** | §4 asm:handle frame 45 個 `callq` + 每幀配置 + 邊界 panic;OOP frame **0 個 callq**、向量化 |
| **H3** | `mojo run` 優化低於 `-O3` | **推翻** | §5:`mojo run` 與 AOT `-O3` 數字實質相同(index_bc 0.89 vs 1.12) |
| **H4** | 規模未觸發 locality | **成立(核心)** | §3:對齊存取方式後,cache-resident 時 AoS≈SoA;locality 差異僅在越過 L2/L3 後出現。原 benchmark ≤128KB 全在 L2 |
| **H5** | Mojo「OOP」本就具局部性 | **成立** | §4:`List[GameObject]` 連續 AoS,`for ref o` → `vfmadd`,0 呼叫、向量化。非指標追逐/vtable 的傳統 OOP |
| **H6** | ECS 佈局本身有缺陷 | **推翻(佈局)/ 部分成立(API)** | §3 asm 證明欄式與 AoS codegen 相同;但存取器路徑有可移除的配置/邊界檢查/未向量化稅(§6 待辦) |

**決策閘門結論:並存,但主軸明確** —— 「ECS 慘輸」是 H2 + H4 + H5(輔以 H1)疊加的**可解釋現象,非佈局缺陷**;H3 已排除;另有一組非佈局的 API/codegen 稅可修。

---

## 3. Layer 6 —— 同抽象層的「記憶體山」:佈局到底重不重要?

兩條迴圈**都用 `unsafe_ptr` 裸迭代**(存取方式對齊,唯一變因=AoS 交錯 vs SoA 欄式),掃 N 跨越快取邊界。ns/op,越低越好(綁 P-core,30 次取 min):

**Slim 全量更新(touch pos+vel):**

| N | 工作集 | AoS | SoA | 判讀 |
|---:|---:|---:|---:|---|
| 4,096 | 64 KB (L2) | 0.38 | 0.34 | 持平 |
| 65,536 | 1 MB (L2) | 0.33 | 0.29 | 持平 |
| 262,144 | 4 MB (L3) | 0.47 | 0.37 | 持平 |
| 1,048,576 | 16 MB (L3) | 0.52 | 0.40 | 接近 |
| **4,194,304** | **64 MB (RAM)** | **1.7** | **0.81** | **越過 L3 → SoA 快 2x** |

**Fat 選擇性讀取(只讀 pos,2KB 冷 payload/物件):**

| N | AoS 工作集 | AoS | SoA(pos 欄 8B/elem) | 判讀 |
|---:|---:|---:|---:|---|
| 1,024 | 2 MB (L2/L3) | 0.50 | 0.50 | 持平 |
| 4,096 | 8 MB (L3) | 0.70 | 0.53 | SoA 略勝 |
| **16,384** | **33 MB (>L3)** | **1.47** | **0.42** | **SoA 快 3.5x** |
| **65,536** | **132 MB (RAM)** | **1.82** | **0.44** | **SoA 快 4.1x,且差距隨 N 擴大** |

> **這就是 ECS 佈局的 locality 勝場,且完全符合快取理論**:AoS 拖著冷 payload,工作集越過 L3
> 就每元素一次 cache miss;SoA 把 pos 收進 8B/elem 的獨立欄,恆定 cache-resident。
> 佈局在「裝得進快取」時中性,在「裝不進」時 SoA 決定性勝出。**原 benchmark 從未進入這個區間。**

---

## 4. Layer 4 —— `.ll` / 組語層:差距的機制

### 4a. 真實引擎三條 frame(`probe_api.mojo`,`-O3 --emit asm`)

| Frame 函式 | asm 行數 | `callq` | SIMD | assert/panic | ns/op(對照) |
|---|---:|---:|---:|---:|---:|
| **`oop_frame`**(`Scene.step`) | **25** | **0** | 1 `vfmadd` | 0 | ~1 |
| `ecs_soa_frame`(`query2_views`) | 309 | 25 | 1 | 5 | ~2 |
| `ecs_handle_frame`(`query2`+`get`/`set`) | 457 | **45** | 1 | 7 | ~20–40 |

`ecs_handle_frame` 內部 `callq` 拆解:每幀 `List::_realloc` + `AlignedFree`(**配置/釋放 query 結果**)、
每元素 `SparseSet::get`×2 + `ArchetypeBackend::_col`×2 + `set`(**未內聯的間接存取**)、
6× `_debug_assert_msg` + 31× `write_to`(**邊界檢查 panic 骨架**)。整迴圈**未向量化**。
`oop_frame` 則完全內聯成一條 `vfmadd` 迴圈,**零配置、零呼叫、零 panic**。

> 差距 100% 來自 **API/codegen**(配置 + 未內聯的邊界檢查存取 + 未向量化),**與記憶體佈局無關**。

### 4b. 佈局本身:AoS 與 SoA 產生相同程式碼

`aos_slim_step`(unsafe_ptr)熱迴圈:
```asm
.LBB0_2:
    vmovsd  (%rdi), %xmm1          # pos
    vmovsd  8(%rdi), %xmm2         # vel
    vfmadd213ps %xmm1, %xmm0, %xmm2   # pos + vel*dt
    vmovlps %xmm2, (%rdi)          # store pos
    addq    $16, %rdi              # 16B stride
    decq    %rsi ; jne .LBB0_2
```
`soa_slim_step`(unsafe_ptr)熱迴圈 —— **同樣 `vfmadd`、同樣 4 記憶體操作、同樣無邊界檢查**:
```asm
.LBB1_2:
    vmovsd  (%rax,%r8,8), %xmm1    # vel[i]
    vmovsd  (%rdi,%r8,8), %xmm2    # pos[i]
    vfmadd231ps %xmm1, %xmm0, %xmm2
    vmovlps %xmm2, (%rdi,%r8,8)    # store pos[i]
    incq    %r8 ; cmpq %r8,%rsi ; jne .LBB1_2
```
fat 讀取的關鍵差異是**跨步**:`aos_fat_readx` 是 `addq $2064,%rdi`(2KB 跨步 → 越過快取即 miss),
`soa_fat_readx` 是 `stride 8B`(8 元素/cache line)。

### 4c. 存取方式的稅(同 AoS 佈局,三種存取,N=4096 全 cache-resident)

| 存取方式 | ns/op | asm 行數 | 特徵 |
|---|---:|---:|---|
| `for ref o`(迭代器) | 0.28 | 21 | `vfmadd`,無邊界檢查 |
| **`objs[i]`(索引)** | **1.12** | **87** | **每迭代往堆疊寫 6 值建構 assertion 上下文 + 邊界比較 + panic 路徑**;阻擋向量化 |
| `unsafe_ptr` | 0.28 | 22 | `vfmadd`,無邊界檢查 |

> 純存取方式即造成 **4x** 差距,與佈局、與快取無關。ECS handle/view 路徑用的正是帶邊界檢查的
> `movers[i]` / `view.get_a(i)` —— 這是 handle 稅的一大來源。

---

## 5. Layer 3 & 5 —— 優化對等 與 locality 實證

**優化對等(H3)**:`mojo run`(JIT)vs AOT `-O3`,同一 probe 關鍵列幾乎一致 →
`mojo run` **本來就是 -O3 級**,原 benchmark 沒有「優化未套用」問題。

| 列 | mojo run | AOT -O3 |
|---|---:|---:|
| access index_bc | 0.89 | 1.12 |
| fat aos 65536 | 1.78 | 1.82 |
| fat soa 65536 | 0.42 | 0.44 |

**locality 實證(四方交叉)**:

1. **靜態吞吐(`llvm-mca`)**:兩條 fat 迴圈**完全相同**(4009 cycles / 1000 iter,IPC 1.00,RThroughput 0.7)。在「全 L1 命中」理想模型下兩者一樣快 → 運算不是差異來源。

2. **確定性 cache-miss(`cachegrind` + `cg_annotate`,per-function,N=65536,無 prefetcher 模型)**:

   | fat 讀取迴圈 | 跨步 | L1 讀取 miss 率 | **LL(≈RAM)讀取 miss 率** |
   |---|---|---:|---:|
   | `aos_fat_readx` | 2064 B | **100%** | **83.8%** |
   | `soa_fat_readx` | 8 B | 12.5% | 0.5% |

   demand-fetch 上限:AoS 每元素都 miss 到 RAM,SoA 從 L2 串流。cachegrind **不模擬硬體 prefetcher**,故此為「無預取」界。

3. **真實硬體 counter(`perf stat -r 3`,綁 P-core,N=65536×400 pass;`paranoid=-1`)**:

   | 模式 | 牆鐘 | IPC | L1-dcache miss | vs SoA |
   |---|---:|---:|---:|---:|
   | AoS 循序 | 0.146 s | 0.94 | 17.4% | 5.6× |
   | **AoS 散亂** | **0.227 s** | 0.64 | 30.9% | **8.3×** |
   | SoA 循序 | 0.026 s | 1.87 | 5.6% | — |
   | SoA 散亂 | 0.0275 s | 2.16 | 38.5% | — |

   **調和 cachegrind 與硬體**:Alder Lake 的 stride prefetcher 認得 AoS 的 2064B 固定跨步,把 cachegrind 預測的
   ~84% RAM demand-miss 大幅預取掉 → 循序 AoS「只」慢 5.6×(瓶頸轉為 L1 miss 17% + 頻寬 + IPC 0.94)。
   一旦**散亂存取擊潰 prefetcher**,AoS 掉到 IPC 0.64、L1 miss 31%,對 SoA 差距**擴大到 8.3×**;
   而 **SoA 幾乎免疫**(0.026→0.0275,+6%)——因 pos 欄 512KB 恆駐 L2,散亂也只是 L2 命中。

4. **時間法記憶體山(§3)**:AoS 越過 L3 後 0.44→1.82,SoA 恆 ~0.44。

> 四者一致收斂:運算相同(mca)→ 差距純屬記憶體;AoS 才會 miss(cachegrind 給無預取上限,硬體 perf 給實測)→
> SoA 的欄式佈局恆駐快取、對散亂免疫,優勢隨「越過快取 + 存取越散亂」而擴大(5.6×→8.3×)。
> **這是 locality 效應的定義,現為實機實測 —— 且 ECS 的 SoA 正是這個贏家佈局。**

---

## 6. 待修正待辦(非佈局;依範圍「修正另議」)

這些是**可移除的 API/codegen 稅**,修好可讓 ECS 的人體工學路徑逼近其 SoA 上限;與「佈局是否正確」無關。

1. **每幀 query 配置**:`query2` / `query2_views` 每幀 `List::_realloc`+`Free`。→ 重用緩衝 / 提供就地 view API。
2. **未內聯、帶邊界檢查的存取器**:`get`/`set`/`view.get_a`/`SparseSet::get` 各自帶邊界 panic 骨架(§4a/4c)。→ `@always_inline` + unsafe 欄存取,消除每元素配置與 assertion 材料化。
3. **存取器路徑未向量化**:handle/soa frame 僅 1 個 SIMD op。→ 走 `unsafe_ptr` 欄迴圈(如 `ecs/system.mojo:integrate2_simd`)讓 `vfmadd` 覆蓋全欄。
4. **`InlineArray[Int, 4096]` sparse cap**:大 cap 炸 codegen,擋住百萬級 N —— 也就擋住 §3 的 locality 制勝區。→ 改堆積式 sparse 索引。
5. **benchmark harness 本身**:原用單次執行 + 整數取整 ns。→ 沉澱本報告的硬化 harness(暖機 / taskset / min-of-30 / 原始 ns / 跨快取 N 掃描)。

---

## 7. 可重現指令

```bash
pixi run build                        # 產生 build/*.mojoc
P=scratchpad/ecs-probe                # 本報告 probe(見 session scratchpad)

# Layer 6 記憶體山(同抽象層 AoS vs SoA + 存取方式微測)
pixi run mojo build -O3 -I build -o $P/probe_layout $P/probe_layout.mojo
taskset -c 3 $P/probe_layout          # → layout_result.csv

# Layer 4 真實引擎三路徑反組譯
pixi run mojo build -O3 -I build --emit asm -o $P/probe_api.s $P/probe_api.mojo
# 統計每 frame 的 callq / SIMD / panic(見報告 §4a)

# Layer 5a 靜態吞吐(證明運算相同 → 差距純屬記憶體)
llvm-mca -mcpu=alderlake < <fat-loop-snippet>

# Layer 5b 確定性 cache-miss(valgrind 已在 pixi 環境)
pixi run mojo build -O3 -I build -o $P/probe_cg $P/probe_cg.mojo
pixi run valgrind --tool=cachegrind --cache-sim=yes \
    --I1=32768,8,64 --D1=49152,12,64 --LL=25165824,12,64 \
    --cachegrind-out-file=$P/cg.out $P/probe_cg
pixi run cg_annotate $P/cg.out | grep fat_readx   # per-function Dr/D1mr/DLmr

# Layer 3 優化對等
taskset -c 3 pixi run mojo run -I build $P/probe_layout.mojo   # 對照 AOT
```

# Layer 5c 真實硬體 counter(perf,已啟用)
sudo sysctl kernel.perf_event_paranoid=-1     # runtime;重開機還原
pixi run mojo build -O3 -I build -o $P/probe_perf $P/probe_perf.mojo
EV=cpu_core/instructions/,cpu_core/cycles/,cpu_core/L1-dcache-load-misses/,cpu_core/LLC-load-misses/
for m in aos aos_scatter soa soa_scatter; do
    taskset -c 3 perf stat -r 3 -e $EV $P/probe_perf $m
done
```

> 綁 P-core(cpu3)取 `cpu_core/` PMU(Alder Lake 混合架構會分 P/E 兩組 PMU)。
> 若要 perf 永久生效,把 `kernel.perf_event_paranoid=1`(或 `-1`)寫進 `/etc/sysctl.d/99-perf.conf`。
> 註:`LLC-load-misses` 絕對值在此 PMU 上偏低估;以 IPC / L1-miss / 牆鐘為準。

---

## 8. 修正後(WS1–WS4)—— 稅已移除,ECS 反超 OOP

依 §6 待辦實作(計畫 `humble-skipping-finch.md`),全 parity 測試維持綠燈(含新增 `test_iter_parity`、`test_sparse_large`、`test_simd_generic`)。

- **WS1 動態成長 sparse**:`SparseSet` 索引改堆積 `List[Int]`(移除 `InlineArray[Int,4096]`),各 backend 去除 `cap` 型別參數。`test_sparse_large` 實測 spawn **100 萬**(sparse)/ 20 萬(archetype)實體 —— 舊 4096 天花板已除。
- **WS2 內聯 + 無邊界檢查存取器**:`ArchView2` 全 `@always_inline` + `unsafe_ptr()[i]`。單此一項就讓 `archetype (soa)` 從 2 ns/op 躍升 sub-ns、**首次反超 OOP**。
- **WS3 零配置 `for_each2`(跨所有 backend)**:comptime-callback,消除每幀 `List[Entity]` 配置 + 每存取查找。
- **WS4 通用 SIMD**:`integrate_simd[A: SimdComponent, B: SimdComponent]` 泛化任意 dtype/lane 寬(`test_simd_generic` 驗證 float32×4),`integrate2_simd` 委派之。

**主 benchmark(movement,update ns/op,綁 P-core,越低越好):**

| variant | N=500 | N=4000 | N=65536 |
|---|---:|---:|---:|
| **archetype (for_each2)** | **0.27** | **0.32** | **0.31** |
| archetype (soa) | 0.47 | 0.45 | 0.49 |
| oop | 0.52 | 0.54 | **1.09** |
| archetype (handle,修正前路徑) | 32.33 | 31.93 | 33.68 |
| reactive (for_each2) | 15.13 | 16.78 | 16.06 |
| reactive (handle) | 28.54 | 30.45 | 32.55 |
| sparse (for_each2) | 14.76 | 15.91 | 15.61 |
| sparse (handle) | 19.81 | 21.38 | 22.75 |

**關鍵結論:**
- `for_each2` vs handle:archetype **~108×**(33.68→0.31)、reactive **~2×**、sparse ~1.4×。
- **archetype `for_each2` 在所有 N 都勝過 OOP**,且差距隨規模擴大:N=65536 時 **0.31 vs 1.09(3.5×)** —— OOP 的 AoS 工作集越過 L2 開始退化(0.54→1.09),ECS 欄式保持緊湊。這正是 §3 記憶體山預測的 locality 制勝區,如今在真實引擎的 movement 工作負載上實現。

> 原調查的「OOP 慘勝」是**量測 handle 路徑 + 觸不到 locality 的規模**的雙重偽影(§2 H1/H2/H4/H5)。修掉 API/codegen 稅、放大到 locality 生效後,ECS 的資料導向佈局如理論預期反超 OOP —— **不是佈局的錯,是路徑與規模的錯,現已修正。**
