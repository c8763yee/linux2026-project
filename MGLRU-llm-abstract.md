# MGLRU（Multi-Gen LRU）

使用 LLM 修改與補充原稿內容。
Assisted-by: claude-opus-4.7

## 前言：為什麼需要 MGLRU

傳統的 Active/Inactive 雙 list 設計有三個根本問題：

1. **粒度過粗**。只有 active 與 inactive 兩種狀態，無法區分「剛被存取」與「很久以前被存取」的 page。
2. **Refault 判斷是二元的**。傳統 LRU 的 refault 只能把 page 放回 active 或 inactive，無法還原它原本的熱度。
3. **Page table walk 成本高**。傳統 LRU 依賴 rmap 反向掃描，在 page 量大時會退化。

MGLRU 的切入點：**把 active/inactive 二分法換成多世代（generation）結構，並對每個 generation 分別統計 evicted、refaulted，用這些統計量作為回饋訊號**，驅動保護與驅逐決策。。

程式碼版本以 Linux v7.0 mainline 為準，`mm/vmscan.c`、`mm/workingset.c`、`include/linux/mmzone.h`。

## 1. 核心資料結構

### 1.1 Folio flags 版面配置

```
----------------------------------------------------------------------------------
Page flags: | SECTION | NODE | ZONE | LAST_CPUPID | LRU_GEN | LRU_REFS | OTHER FLAGS |
----------------------------------------------------------------------------------
```

其中：

- `LRU_GEN`：2 bits，編碼 folio 所屬的 generation（4 個 gen 用 0 表示「不在任何 gen」，1-4 表示 gen 0-3）
- `LRU_REFS`：存取次數（refs）計數器，範圍 0 至 `BIT(LRU_REFS_WIDTH)`

### 1.2 `lru_gen_folio`

定義在 `include/linux/mmzone.h`，每個 `lruvec` 一個，用來表示：

```c
struct lru_gen_folio {
    unsigned long max_seq;                 // 最新世代
    unsigned long min_seq[ANON_AND_FILE];  // anon、file 分別的最老世代
    unsigned long timestamps[MAX_NR_GENS];

    /* 多世代 LRU lists：[gen][type][zone] */
    struct list_head folios[MAX_NR_GENS][ANON_AND_FILE][MAX_NR_ZONES];
    long nr_pages[MAX_NR_GENS][ANON_AND_FILE][MAX_NR_ZONES];

    /* PID controller 的歷史項（EWMA） */
    unsigned long avg_refaulted[ANON_AND_FILE][MAX_NR_TIERS];
    unsigned long avg_total[ANON_AND_FILE][MAX_NR_TIERS];

    /* 當前世代累積量（P 項原始資料） */
    unsigned long protected[NR_HIST_GENS][ANON_AND_FILE][MAX_NR_TIERS];
    atomic_long_t evicted[NR_HIST_GENS][ANON_AND_FILE][MAX_NR_TIERS];
    atomic_long_t refaulted[NR_HIST_GENS][ANON_AND_FILE][MAX_NR_TIERS];

    bool enabled;
    u8 gen;
    u8 seg;
    struct hlist_nulls_node list;
};
```

關鍵常數：

| 常數             | 值 | 用途                                       |
| :--------------- | :- | :----------------------------------------- |
| `MIN_NR_GENS`  | 2  | 最少世代數（active + inactive 的直接對應） |
| `MAX_NR_GENS`  | 4  | 最大世代數                                 |
| `MAX_NR_TIERS` | 4  | Tier 層數                                  |

Sliding window 透過 `gen % MAX_NR_GENS` 對 folios 陣列定址，所以 seq 可以單調遞增而不溢位。

### 1.3 Generation 與 Tier 的差別

兩者是正交維度：

- **Generation**：folio 被放入 LRU 時的「時間」，由 aging 推動。
- **Tier**：「這個 folio 累積被存取了多少次」，由 refs（根據存取頻率）推動。

```c
static inline int lru_tier_from_refs(int refs, bool workingset)
{
    return workingset ? MAX_NR_TIERS - 1 : order_base_2(refs);
}
```

也就是 `tier = ⌈log2(refs)⌉`，當 `workingset` flag 設定時直接跳到最高 tier。

### 1.4 相關 page flags 含義

| Flag              | 含義                                    |
| :---------------- | :-------------------------------------- |
| `PG_active`     | 處於活躍狀態（頻繁被存取）              |
| `PG_referenced` | 最近被 reference                        |
| `PG_workingset` | 曾經 refault 後被判定為屬於 working set |
| `PG_dirty`      | Page 被修改過，準備寫回 disk            |
| `PG_writeback`  | 正在寫回 disk（被 lock）                |

### 1.5 Working set 的定義

一個應用程式在一段時間內正常執行所需要經常存取的 page 集合，也就是 hot page 所構成的集合。MGLRU 不假設 working set 大小固定，而是透過 refault 統計動態識別。

## 2. 生命週期：六個階段

以下是一張 folio 從進入記憶體到被回收的完整路徑。資料結構對了，六個階段的邏輯就很清楚。

```
Fault-in → [駐留記憶體] → Aging → Promotion/Protection → Eviction → Refault
                             ↑                                         │
                             └──────────────（形成回饋迴路）───────────┘
```

### 2.1 Fault-in：新 folio 進入 LRU

新 folio 透過 `lru_gen_add_folio()` 加入，由 `lru_gen_folio_seq()` 決定初始 generation：

```c
static inline unsigned long lru_gen_folio_seq(const struct lruvec *lruvec,
                                              const struct folio *folio,
                                              bool reclaiming)
{
    int gen;
    int type = folio_is_file_lru(folio);
    const struct lru_gen_folio *lrugen = &lruvec->lrugen;

    /*
     * 位置安排（max_seq 最新，min_seq 最舊）：
     *
     * +-----------------------------------+-----------------------------------+
     * | 透過 page table 存取             | 透過 file descriptor 存取         |
     * | 由 folio_update_gen() 促進       | 由 folio_inc_gen() 保護           |
     * +-----------------------------------+-----------------------------------+
     * | PG_active (set while isolated)   |                                   |
     * +-----------------+-----------------+-----------------+-----------------+
     * | PG_workingset   | PG_referenced   | PG_workingset   | LRU_REFS_FLAGS  |
     * +-----------------------------------+-----------------------------------+
     * |<---------- MIN_NR_GENS ---------->|                                   |
     * |<---------------------------- MAX_NR_GENS ---------------------------->|
     *
     * max_seq ----------------------------------------------------- min_seq
     */
    if (folio_test_active(folio))
        gen = MIN_NR_GENS - folio_test_workingset(folio);
    else if (reclaiming)
        gen = MAX_NR_GENS;
    else if ((!folio_is_file_lru(folio) && !folio_test_swapcache(folio)) ||
             (folio_test_reclaim(folio) &&
              (folio_test_dirty(folio) || folio_test_writeback(folio))))
        gen = MIN_NR_GENS;
    else
        gen = MAX_NR_GENS - folio_test_workingset(folio);

    return max(READ_ONCE(lrugen->max_seq) - gen + 1,
               READ_ONCE(lrugen->min_seq[type]));
}
```

簡化版的行為：

- 乾淨的新 file page → `max_seq`（最年輕）
- Reclaiming 路徑上遇到的 folio → 丟到 `min_seq` 附近
- 帶 `PG_active` 的 folio → 根據是否有 `PG_workingset` 決定是 `max_seq-1` 還是 `max_seq`

### 2.2 Promotion：refs 計數與升代

Folio 被存取時，`folio_mark_accessed()` 會呼叫 `lru_gen_inc_refs()`：

```c
static void lru_gen_inc_refs(struct folio *folio)
{
    unsigned long new_flags, old_flags = READ_ONCE(folio->flags.f);

    if (folio_test_unevictable(folio))
        return;

    // 第一次存取：只設定 PG_referenced，不加 refs
    if (!folio_test_referenced(folio)) {
        set_mask_bits(&folio->flags.f, LRU_REFS_MASK, BIT(PG_referenced));
        return;
    }

    // 後續存取：原子遞增 refs，避免 race
    do {
        if ((old_flags & LRU_REFS_MASK) == LRU_REFS_MASK) {
            // refs 已滿：設定 workingset flag 並停止計數
            if (!folio_test_workingset(folio))
                folio_set_workingset(folio);
            return;
        }
        new_flags = old_flags + BIT(LRU_REFS_PGOFF);
    } while (!try_cmpxchg(&folio->flags.f, &old_flags, new_flags));
}
```

Refs 採指數退火策略，到了上限就把 `PG_workingset` 點起來，不再細分。這避免了高頻存取的 folio 在 refs 計數上無限膨脹，同時保留了「這個 folio 熱到需要特殊待遇」的訊號。

實際移動 folio 到新的 `folios[gen][type][zone]` list 由 `sort_folio()` 做，`folio_update_gen()` 與 `folio_inc_gen()` 只更新世代標記，不做 list 操作：

- `folio_update_gen()`：把 folio 升到 `max_seq`
- `folio_inc_gen()`：把 folio 升到 `min_seq + 1`（Protection 用）

### 2.3 Aging：掃描與世代遞進

Aging 的目標是「不掃描所有 page 就能知道誰該被淘汰」。核心流程：

```
kswapd → balance_pgdat → shrink_node → lru_gen_age_node →
    try_to_inc_max_seq →
        iterate_mm_list →
            walk_mm →
                walk_pmd_range →      (Bloom filter 過濾 PMD)
                    walk_pte_range →  (掃描 PTE、清 accessed bit)
                        folio_update_gen()  (把 young folio 升代)
```

每次完成一輪掃描，`max_seq++`，產生新世代。最老世代（`min_seq`）上若無 folio 殘留，`min_seq++`，對應的 list 被回收重用。

Aging 的入口還有一個：**eviction 路徑發現的熱點**。`lru_gen_look_around()` 在驅逐階段走 rmap 時，會順便掃描被驅逐頁面周圍的 PTE，把發現的 hot PMD 回報給 Bloom filter。這讓 eviction 路徑的觀察能回饋給 aging，形成適應性的掃描策略。

### 2.4 Protection：避免「踢錯」

某些 folio 在 eviction 時需要保護：

- Refault 時被判定為 recent 的 folio（`lru_gen_test_recent()` 回傳 true）
- 帶有 `PG_workingset` 的 folio

Protection 的機制是 `folio_inc_gen()` 把 folio 升到 `min_seq + 1`——比最老世代多一級，等於多存活一個 aging 週期。

### 2.5 Eviction：從最老世代開始踢

Call chain（由 `evict_folios()` 出發）：

```
evict_folios()
├── isolate_folios()
│   └── scan_folios()
│       ├── sort_folio()       // Promote 熱頁到次老世代（return true）
│       └── isolate_folio()    // 選出 cold page 隔離（return false）
├── shrink_folio_list()         // 對選出的 page 進行實際回收
│   ├── folio_check_references()
│   │   └── folio_referenced()
│   │       └── lru_gen_look_around()  // 局部性優化：掃描鄰近 PTE
│   ├── lru_gen_set_refs()              // 決定是否 Protect
│   └── try_to_free_swap() / folio_free()
└── try_to_inc_min_seq()        // 若最老世代清空，min_seq++
```

關鍵函數職責：

- `isolate_folios()`：決定要驅逐哪個 type（anon/file），以及要掃描多少 folio
- `scan_folios()`：走訪當前 gen 的 list，對每個 folio 呼叫 `sort_folio()`
- `sort_folio()`：回傳 true 表示這個 folio 被 promote 了（不驅逐）；回傳 false 表示要隔離

Eviction 時對 file-backed folio 會建立 shadow entry（下面 2.6 節詳述），anonymous folio 若是 clean 則直接丟棄，dirty 則 swap out。

### 2.6 Refault：帶著記憶回來

File-backed folio 被驅逐時，`lru_gen_eviction()` 把 **token** 打包塞進 shadow entry：

```c
static void *lru_gen_eviction(struct folio *folio)
{
    int hist;
    unsigned long token;
    unsigned long min_seq;
    struct lruvec *lruvec;
    struct lru_gen_folio *lrugen;
    int type = folio_is_file_lru(folio);
    int delta = folio_nr_pages(folio);
    int refs = folio_lru_refs(folio);
    bool workingset = folio_test_workingset(folio);
    int tier = lru_tier_from_refs(refs, workingset);

    /* ... 取 lruvec ... */

    min_seq = READ_ONCE(lrugen->min_seq[type]);
    token = (min_seq << LRU_REFS_WIDTH) | max(refs - 1, 0);

    hist = lru_hist_from_seq(min_seq);
    atomic_long_add(delta, &lrugen->evicted[hist][type][tier]);

    return pack_shadow(mem_cgroup_id(memcg), pgdat, token, workingset);
}
```

Token 的編碼：

```
+------------------+------------------+
| min_seq (高位)   | refs-1 (低位)    |
+------------------+------------------+
     (gen 資訊)         (熱度資訊)
```

Refault 發生時，`lru_gen_refault()` 解包 token：

```c
static void lru_gen_refault(struct folio *folio, void *shadow)
{
    bool recent;
    int hist, tier, refs;
    bool workingset;
    unsigned long token;
    /* ... */

    rcu_read_lock();
    recent = lru_gen_test_recent(shadow, &lruvec, &token, &workingset);
    if (lruvec != folio_lruvec(folio))
        goto unlock;

    mod_lruvec_state(lruvec, WORKINGSET_REFAULT_BASE + type, delta);

    if (!recent)
        goto unlock;   // 太舊就走一般 fault-in

    lrugen = &lruvec->lrugen;
    hist = lru_hist_from_seq(READ_ONCE(lrugen->min_seq[type]));
    refs = (token & (BIT(LRU_REFS_WIDTH) - 1)) + 1;
    tier = lru_tier_from_refs(refs, workingset);

    atomic_long_add(delta, &lrugen->refaulted[hist][type][tier]);

    if (lru_gen_in_fault())
        mod_lruvec_state(lruvec, WORKINGSET_ACTIVATE_BASE + type, delta);

    if (workingset) {
        folio_set_workingset(folio);
        mod_lruvec_state(lruvec, WORKINGSET_RESTORE_BASE + type, delta);
    } else {
        // 恢復 refs 計數，讓 folio 進入對應的 tier
        set_mask_bits(&folio->flags.f, LRU_REFS_MASK,
                      (refs - 1UL) << LRU_REFS_PGOFF);
    }
unlock:
    rcu_read_unlock();
}
```

`lru_gen_test_recent()` 的判斷邏輯：

```c
return abs_diff(max_seq, *token >> LRU_REFS_WIDTH) < MAX_NR_GENS;
```

也就是「驅逐時的 min_seq 與當前 max_seq 差距小於 4 代」才算 recent。超過 4 代的 shadow entry 被視為過時，不會觸發 activation。

### 2.7 對比：傳統 LRU 與 MGLRU 的 refault 處理

| 項目        | 傳統 LRU                                                                           | MGLRU                                                     |
| :---------- | :--------------------------------------------------------------------------------- | :-------------------------------------------------------- |
| Token 內容  | 只有 eviction timestamp（`nonresident_age` 快照）                                | `(min_seq << LRU_REFS_WIDTH) \| (refs-1)`                |
| Recent 判斷 | `refault_distance ≤ workingset_size`，需讀多個 `lruvec_page_state()` 並 flush | `abs_diff(max_seq, token_gen) < MAX_NR_GENS`，O(1) 比較 |
| 插入後狀態  | 二元：active 或 inactive                                                           | 多元：根據 refs 恢復到對應 tier                           |
| 統計粒度    | 全域 `nonresident_age`                                                           | 按 `[hist][type][tier]` 分桶                            |

關鍵差異是：**傳統 LRU 是「放回 active 或 inactive」的二元決策，MGLRU 是「還原成被驅逐前的狀態」**。這讓工作集被誤踢時能夠以正確的熱度重回 LRU。

## 3. 關鍵機制

### 3.1 Bloom filter：aging 的效率加速器

Aging 需要走訪 page table。問題在於：**不是每個 PMD 底下的 PTE 表都值得掃描**。如果一個 PMD 底下大部分 PTE 是冷的，走進去就是浪費 CPU。

MGLRU 用 Bloom filter 篩選「底下有足夠多 young PTE」的 PMD。

參數選擇（定義在 `mm/vmscan.c`）：

- $m = 2^{15} = 32768$ 個位元（4 KB bitmap）
- $k = 2$（兩個 hash function）
- 偽陽性率：插入 10000 條目時約 1/5，20000 條目時約 1/2

雜湊函數利用 Kirsch-Mitzenmacher 的經典技巧，單次 hash 劈成兩半當成兩個獨立 hash：

```c
static void get_item_key(void *item, int *key)
{
    u32 hash = hash_ptr(item, BLOOM_FILTER_SHIFT * 2);
    key[0] = hash & (BIT(BLOOM_FILTER_SHIFT) - 1);
    key[1] = hash >> BLOOM_FILTER_SHIFT;
}
```

雙緩衝（`NR_BLOOM_FILTERS = 2`）：

```c
unsigned long *filters[NR_BLOOM_FILTERS];
```

用 `seq % NR_BLOOM_FILTERS` 選 filter。當前世代讀、下一世代寫，讀寫永不衝突，所以 **filter 內容不需要鎖**。

熱度判定：

```c
static bool suitable_to_scan(int total, int young)
{
    int n = clamp_t(int, cache_line_size() / sizeof(pte_t), 2, 8);
    return young * n >= total;
}
```

問的是：**這張 PTE 表裡，平均每條 cache line 是否至少有一個 young PTE？** 若 young 密度太低，掃描不划算。

形成的回饋迴路：

```
aging (walk_pmd_range)
    │
    ├─ test_bloom_filter(seq) ──→ 決定是否進入 PTE 表
    ├─ walk_pte_range() ──→ 掃描 PTE、清 accessed bit
    └─ update_bloom_filter(seq+1) ──→ 熱 PMD 帶入下一世代
                                        ↑
eviction (lru_gen_look_around)          │
    └─ 掃描鄰近 PTE，發現熱點 ─────────┘
       update_bloom_filter(max_seq)
```

退化行為：若 filter 分配失敗（`NULL`），`test_bloom_filter()` 回傳 true，意思是「不確定就掃」。不搞 fallback 邏輯，不搞錯誤碼傳播，直接退回全量掃描。

### 3.2 PID controller：保護與驅逐比例的決策

MGLRU 在兩個問題上需要做量化決策：

1. 同一個 generation 裡，該驅逐 anon 還是 file？
2. 某個 tier 的頁面該保護還是驅逐？

兩個問題共用同一個回饋訊號：**refault 比率**。若某類 page 被驅逐後 refault 太頻繁，表示驅逐錯了。

程式碼實作是一個帶 EWMA 的 PI controller，不是完整 PID。原始程式碼註解直白寫著「D term 不支援」。P 項是當前世代的 `refaulted / (evicted + protected)`，I 項是 P 項在歷史世代上的指數移動平均，平滑因子 $\alpha = 1/2$。

三個處理器核函數：

**`read_ctrl_pos()`——讀取 P + I**

```c
static void read_ctrl_pos(struct lruvec *lruvec, int type, int tier,
                          int gain, struct ctrl_pos *pos)
```

把 I 項（`avg_refaulted`、`avg_total`）與 P 項（`refaulted[hist]`、`evicted[hist] + protected[hist]`）相加，產生 `pos->refaulted` 與 `pos->total`。

**`reset_ctrl_pos()`——EWMA 更新**

```c
sum = lrugen->avg_refaulted[type][tier] +
      atomic_long_read(&lrugen->refaulted[hist][type][tier]);
WRITE_ONCE(lrugen->avg_refaulted[type][tier], sum / 2);
```

當一個 generation 被消費（`min_seq++`）或新世代產生（`max_seq++`）時，把當前世代的統計融合進歷史平均值，然後清空當前計數。這是離散時間域的「積分」操作——時間軸是 seq 的遞進，不是牆上時鐘。

**`positive_ctrl_err()`——比較 SP 與 PV**

```c
return pv->refaulted < MIN_LRU_BATCH ||
       pv->refaulted * (sp->total + MIN_LRU_BATCH) * sp->gain <=
       (sp->refaulted + 1) * pv->total * pv->gain;
```

本質是比較 `pv->refaulted / pv->total` 與 `sp->refaulted / sp->total`，但用交叉相乘避免浮點除法——kernel 裡不做浮點除法。`MIN_LRU_BATCH` 與 `+1` 是防止分母為零的防呆。

兩個決策入口：

**`get_tier_idx()`——決定保護到第幾 tier**

```c
read_ctrl_pos(lruvec, type, 0, 1, &sp);
for (tier = 1; tier < MAX_NR_TIERS; tier++) {
    read_ctrl_pos(lruvec, type, tier, 2, &pv);
    if (!positive_ctrl_err(&sp, &pv))
        break;
}
return tier - 1;
```

Tier 0 當 SP（`gain=1`），逐層比較更高 tier（`gain=2`）。Gain 比 1:2 是刻意留的 dead zone，防止微小波動觸發保護決策切換。

**`get_type_to_scan()`——決定驅逐 anon 或 file**

```c
int gain[ANON_AND_FILE] = { swappiness, 200 - swappiness };
read_ctrl_pos(lruvec, LRU_GEN_ANON, 0, gain[LRU_GEN_ANON], &sp);
read_ctrl_pos(lruvec, LRU_GEN_FILE, 0, gain[LRU_GEN_FILE], &pv);
type = positive_ctrl_err(&sp, &pv);
```

Swappiness 範圍 0-200，兩邊 gain 互補。Swappiness 越高，anon 的 gain 越大，anon 看起來「壞」的門檻越低，越容易被選為驅逐對象。這把使用者可調的單一旋鈕塞進了控制律的加權裡。

### 3.3 為什麼不是完整 PID

- **D 項在 kernel 裡會放大雜訊**。Workload 的瞬間抖動會直接轉成錯誤的保護決策。
- **純 I 項會 windup**。長時間壓住一側時，累積誤差無限膨脹，workload 翻轉後要很久才能回應。
- **EWMA 是這兩個問題的正確解答**。帶遺忘的 I 項自動防 windup，不需要 D 的微分。

另外，離散微分 $(e_k - e_{k-1})/T$ 對 $T$ 很敏感，MGLRU 的 $T$ 是 seq 遞增——非均勻取樣。對非均勻時間取微分，結果就是一團雜訊。D 項不存在不是沒人想到，是擋掉了而且擋得有道理。

## 4. 觀測介面

### 4.1 debugfs

```
/sys/kernel/debug/lru_gen
/sys/kernel/debug/lru_gen_full
```

輸出格式：

```
memcg  memcg_id  memcg_path
 node  node_id
         min_gen_nr  age_in_ms  nr_anon_pages  nr_file_pages
         0
         1
         2
         3
         ...
         max_gen_nr  age_in_ms  nr_anon_pages  nr_file_pages
```

### 4.2 Tracepoints 與動態追蹤

常用 tracepoint：

```
vmscan:mm_vmscan_lru_gen_scan
vmscan:mm_vmscan_lru_gen_evict
vmscan:mm_vmscan_direct_reclaim_begin
vmscan:mm_vmscan_direct_reclaim_end
```

注意有些函數被 inline 或標為 `notrace`，無法直接 kprobe。以下是實測不能 attach 的常見函數：

- `lru_gen_add_folio`（inline）→ 用 `filemap:mm_filemap_add_to_page_cache` 或 `filemap_add_folio`
- `walk_pte_range`（可能 inline）→ 用 `walk_pmd_range` 或 `try_to_inc_max_seq`
- `workingset_activate_folio`（inline）→ 用 `workingset_refault`

驗證可追蹤性：

```sh
bpftrace -l 'kprobe:*lru_gen*'
bpftrace -l 'kprobe:*workingset*'
cat /proc/kallsyms | grep -E "(lru_gen|workingset)"
```

## 5. Patch 與延伸閱讀

- [MGLRU v1 patchset (2021-03-13)](https://lore.kernel.org/lkml/20210313075747.3781593-1-yuzhao@google.com/)
- Yu Zhao 的 LWN 系列文章（2021-2022）
- 合入主線：v6.1
- 主要實作檔案：`mm/vmscan.c`、`mm/workingset.c`、`include/linux/mmzone.h`

## 6. 原稿 TODO 收斂

原稿開頭的 TODO 在本整理中對應：

- 搞懂 lruvec 與其 attribute 用途 → 第 1 節
- 查詢 Page 與 Cache 關聯性 → 第 2.6 節（shadow entry、refault）、第 3.2 節（PID controller 決定 file/anon 平衡）
- PTE Scan → 第 2.3 節（Aging）、第 3.1 節（Bloom filter）
