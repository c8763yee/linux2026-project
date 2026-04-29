# 2026 Linux 核心設計專題：驗證 MGLRU 中 PID Controller 加入微分項對於 Page refault rate 與效能影響

:::info
HackMD 免費版僅可檢視前 10 筆編輯紀錄，完整編輯紀錄請參考 [GitHub](https://github.com/c8763yee/linux2026-project/tree/history)
:::

## 比較一般形式與 MGLRU 中 PID Controller 的差異

### 一般形式的 PID Controller

$$
\begin{aligned}
u(t) &= MV(t) \\
     &= P_{out} + I_{out} + D_{out} \\
     &= K_p e(t) + K_i \int_0^t e(\tau)d\tau + K_d \frac{de(t)}{dt}
\end{aligned}
$$

其中 $e(t) = SP - PV$ 代表目前位置（回授值，PV）與目標位置（設定值，SP）的誤差。
$K_p$、$K_i$、$K_d$ 分別代表比例增益、積分增益與微分增益。

### 各項輸出說明

比例項 $P_{out}$ 的作用是根據目前誤差直接調整輸出，當誤差越大時，比例項的輸出也會越大，幫助系統快速回應。
積分項 $I_{out}$ 的作用是累積過去的誤差，當系統長時間存在誤差時，積分項會逐漸調整輸出，幫助系統達到穩定狀態，消除穩態誤差。
微分項 $D_{out}$ 的作用透過過去的誤差變化來預測未來，當誤差變化率很大時，微分項會產生較大的輸出，幫助系統快速反應，減少過衝和震盪。

### MGLRU 中的 PID Controller

P term($K_d$):

- $\frac{refaulted}{total=(evicted+protected)}$

I term($\sum_{tier} folio[tier] $): $\alpha=\frac{1}{2}$ 的 EWMA 分別對 refaulted/total page/folio 套用

- $I_{n} = \alpha \times folio + (1-\alpha) \times I_{n-1}$

Error term($e(t)$, from `positive_ctrl_err`):

```c
static bool positive_ctrl_err(struct ctrl_pos *sp, struct ctrl_pos *pv)
{
	/*
	 * Return true if the PV has a limited number of refaults or a lower
	 * refaulted/total than the SP. (SP - PV > 0)
	 */
	return pv->refaulted < MIN_LRU_BATCH ||
	       pv->refaulted * (sp->total + MIN_LRU_BATCH) * sp->gain <=
	       (sp->refaulted + 1) * pv->total * pv->gain;
}
```

$$
\begin{aligned}
e(t) &= SP - PV \\
     &= \frac{SP_{refaulted}}{SP_{total}} \times SP_{gain} - \frac{PV_{refaulted}}{PV_{total}} \times PV_{gain}
\end{aligned}
$$

問題點：

1. 如何將 MGLRU 形式的 PID Controller 對應到一般形式（或反過來對應）？
2. 已知微分項會對系統的穩定性和回應速度產生影響，然而 MGLRU 並未使用微分項，其考量為何？
3. 對於積分項，其對應的 $K_i$ 又是什麼？是否為 $\frac{1}{2}$ 的 EWMA 參數 $\alpha$？

效能量測指標：

- Page refault rate
- 整體系統效能（如吞吐量、回應時間等）
