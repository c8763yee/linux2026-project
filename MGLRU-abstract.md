# MGLRU

## TODO
搞懂 lruvec 與其 attribute用途
查詢 Page 與 Cache 關聯性
PTE Scan

---

```
            ----------------------------------------------------------------------------------
Page flags: |  SECTION  |  NODE  |  ZONE  |  LAST_CPUPID  |  LRU_GEN  |  LRU_REFS  |  OTHER FLAGS  |
            ----------------------------------------------------------------------------------
```

## Overview

原本的 Active/Inactive List 僅

LRU Vector(lruvec) 存放 多個 Generation 的 Evicable Pages
```
youngest: lruvec->maxseq
oldest: lruvec->minseq[type]  # 不同類別(anon,file)分開管理
```
> clean file pages can be evicted regardless of swap constraints. These three variables are monotonically increasing.

各Generation 以 sliding window ( gen % `MAX_NR_GENS` ) 方式存取/追蹤 
## Tier

`sort_folio`: 真正將Folio移動(protected, promote, evict)
### refs: Page 被訪問(open,read,write,...)的次數
- `folio_lru_refs`: return refs
- `folio_mark_accessed(lru_gen_inc_refs)`: 
```c
static void lru_gen_inc_refs(struct folio *folio)
{
	unsigned long new_flags, old_flags = READ_ONCE(folio->flags.f);

	if (folio_test_unevictable(folio))
		return;

	/* see the comment on LRU_REFS_FLAGS */
	if (!folio_test_referenced(folio)) { // 第一次: 設定PG_referenced
		set_mask_bits(&folio->flags.f, LRU_REFS_MASK, BIT(PG_referenced));
		return;
	}

	// 使用 do-while 避免Race Condition (flags 可能在其他 Task 變更過一次)
	do { 
		if ((old_flags & LRU_REFS_MASK) == LRU_REFS_MASK) {
			// 設定 workingset flags
			if (!folio_test_workingset(folio))
				folio_set_workingset(folio);
			return;
		}
		
		// refs += 1
		new_flags = old_flags + BIT(LRU_REFS_PGOFF);
	} while (!try_cmpxchg(&folio->flags.f, &old_flags, new_flags));
}

```

- 基於fd操作取 order_base_2計數: $\lceil log2(refs) \rceil (\text{n } \gt 1); 0 (\text{n} \le 1 )$
```c
static inline int lru_tier_from_refs(int refs, bool workingset)
{
	VM_WARN_ON_ONCE(refs > BIT(LRU_REFS_WIDTH));

	/* see the comment on MAX_NR_TIERS */
	
	// max tier when PG_workingset is set
	return workingset ? MAX_NR_TIERS - 1 : order_base_2(refs);
}
```


## Flags
- PG_workingset: 曾經被 Refault 回 LRU List 中
- PG_active: 處於活躍狀態(頻繁被存取)
- PG_referenced: 最近被Reference
- PG_writeback: 正在寫回Disk（被Lock）
- PG_dirty: Page 曾經被修改過，準備寫回Disk
## gen
- lrugen(seq)
->max_seq: 最新generation
->min_seq: ANON與file分別的Generation(清空後才遞增)
- memcg
- folio
新 Folio Fault-in 後透過 `lru_gen_add_folio -> lru_gen_folio_seq`處理初始位置(gen)
- lru_gen_add_folio: 更新Folio所屬Gen
```c=
static inline bool lru_gen_add_folio(struct lruvec *lruvec, struct folio *folio, bool reclaiming)
{
	unsigned long seq;
	unsigned long flags;
	int gen = folio_lru_gen(folio);
	int type = folio_is_file_lru(folio);
	int zone = folio_zonenum(folio);
	struct lru_gen_folio *lrugen = &lruvec->lrugen;

	VM_WARN_ON_ONCE_FOLIO(gen != -1, folio);

	if (folio_test_unevictable(folio) || !lrugen->enabled)
		return false;

	seq = lru_gen_folio_seq(lruvec, folio, reclaiming);
	gen = lru_gen_from_seq(seq);
	flags = (gen + 1UL) << LRU_GEN_PGOFF;
	/* see the comment on MIN_NR_GENS about PG_active */
	set_mask_bits(&folio->flags.f, LRU_GEN_MASK | BIT(PG_active), flags);

	lru_gen_update_size(lruvec, folio, -1, gen);
	/* for folio_rotate_reclaimable() */
	if (reclaiming)
		list_add_tail(&folio->lru, &lrugen->folios[gen][type][zone]);
	else
		list_add(&folio->lru, &lrugen->folios[gen][type][zone]);

	return true;
}


static inline unsigned long lru_gen_folio_seq(const struct lruvec *lruvec,
					      const struct folio *folio,
					      bool reclaiming)
{
	int gen;
	int type = folio_is_file_lru(folio);
	const struct lru_gen_folio *lrugen = &lruvec->lrugen;

	/*
	 * +-----------------------------------+-----------------------------------+
	 * | Accessed through page tables and  | Accessed through file descriptors |
	 * | promoted by folio_update_gen()    | and protected by folio_inc_gen()  |
	 * +-----------------------------------+-----------------------------------+
	 * | PG_active (set while isolated)    |                                   |
	 * +-----------------+-----------------+-----------------+-----------------+
	 * |  PG_workingset  |  PG_referenced  |  PG_workingset  |  LRU_REFS_FLAGS |
	 * +-----------------------------------+-----------------------------------+
	 * |<---------- MIN_NR_GENS ---------->|                                   |
	 * |<---------------------------- MAX_NR_GENS ---------------------------->|
	 * 位置
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

	return max(READ_ONCE(lrugen->max_seq) - gen + 1, READ_ONCE(lrugen->min_seq[type]));
}

```

sort_folio: 實際進行移動Folio動作
```clike=
	/* promoted */
	if (gen != lru_gen_from_seq(lrugen->min_seq[type])) {
		list_move(&folio->lru, &lrugen->folios[gen][type][zone]);
		return true;
	}

```
- folios list 結構
```
folios[gen][type][zones]
  |
  v
Folio -> Folio->...(nr_pages[gen][type][zone])
```



--------------------------------

- /sys/kernel/debug/lru_gen
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

working set 定義: 指一個應用程式在一段時間內正常執行所需要的時常存取的 page，也就是 hot page 所構成的集合

## Eviction
![image](https://hackmd.io/_uploads/SJWgv71v-g.png)
![image](https://hackmd.io/_uploads/B1VddQkD-g.png)
```
kswapd()
  └─ balance_pgdat()
      └─ shrink_node()
          └─ shrink_one()
              └─ try_to_shrink_lruvec()
                  └─ evict_folios()
                      ├─ isolate_folios()
                      │    └─ scan_folios()
                      │         ├─ sort_folio()     // Promote 熱頁到次老世代
                      │         └─ isolate_folio()  // 選出 page
                      ├─ shrink_folio_list()         // 對選出的 page 進行實際回收
                      │    ├─ folio_check_references()
                      │    │    └─ folio_referenced()
                      │    │         └─ lru_gen_look_around() // 局部性優化，尋找附近的 hot PTE
                      │    ├─ lru_gen_set_refs()    // 決定是否 Protect（移動到 min_seq+1）
                      │    └─ try_to_free_swap() / folio_free() // swap out 或釋放
                      └─ try_to_inc_min_seq()       // 若 oldest gen 已清空則淘汰並 min_seq++
```

`isolate_folio -> sort_folio(return false)`: 隔離並回收Folio
`isolate_folios`: 獲取要回收的FOlio Type(anon/file)以及需要回收（掃描到）的數量
`scan_folios`: 


## Aging
kswapd: -> shrink_node -> shrink_lruvec


                 lru_gen_age_node()  <─── Aging: Page table walk
                            │
                 folio_update_gen() / lru_gen_set_refs()
                 (清 accessed bit → 設 PG_referenced / 升代)

──────────────────────────────────────────────────────────
Page: fault -> handle_mm_fault -> lru_gen_look_around()
                 
                            │
                            ▼
                 folio_update_gen()  <─── Aging
                 (附近頁的 accessed bit → 更新 gen)

## Refault
## Protected
`evict_folios -> isolate_folios -> scan_folios-> sort_folio -> folio_inc_gen`
PID Controller 決定 Protected tier
- 連續形式
${\displaystyle \mathrm {u} (t)=\mathrm {MV} (t)=K_{p}{e(t)}+K_{i}\int _{0}^{t}{e(\tau )}\,{d\tau }+K_{d}{\frac {d}{dt}}e(t)}$
- MGLRU 中將比例項 $K_p$ 定義為 $\frac{refaulted}{protected+evicted}$，積分項 $K_i$ 使用 EWMA $\alpha=\frac12$ 統計 
$Total_{new}= (1-\alpha) Total_{old} + \alpha (total=protected+evicted)$
此 EWMA 項來自連續形式 PID 積分取衰減因子

## Promotion
- folio_mark_accessed
refs 清零 after promotion
`folio_update_gen`與`folio_inc_gen`只更新 Generation 與 tier, `sort_folio` 才真正移動

- `folio_update_gen`: Promote 到 max_seq
- `folio_inc_gen`: Promote 到 min_seq + 1

## Patch Set
[v1](https://lore.kernel.org/lkml/20210313075747.3781593-1-yuzhao@google.com/)

