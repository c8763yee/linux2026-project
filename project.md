# 2026 Linux 核心設計專題：驗證 MGLRU 中 PID Controller 加入微分項對於 Page refault rate 與效能影響

:::info
HackMD 免費版僅可檢視前 10 筆編輯紀錄，完整編輯紀錄請參考 [GitHub](https://github.com/c8763yee/linux2026-project/tree/history)
:::

## 比較一般形式與 MGLRU 中 PID Controller 的差異

在一般形式的 PID Controller 表示方式為：

$$
\begin{aligned}
u(t) &= MV(t) \\
     &= P_{out} + I_{out} + D_{out} \\
     &= K_p e(t) + K_i \int_0^t e(\tau)d\tau + K_d \frac{de(t)}{dt}
\end{aligned}
$$

其中 $e(t) = SP - PV$ 代表目前位置（回授值，PV）與目標位置（設定值，SP）的誤差。
$K_p$、$K_i$、$K_d$ 分別代表比例增益、積分增益與微分增益。

在 MGLRU 中的 PID Controller
P term($K_d$): $\frac{refaulted}{total=(evicted+protected)}$
I term: $\alpha=\frac{1}{2}$ 的 EWMA 分別對 refaulted 與 total 套用（$I_{n} = \alpha \cdot folio + (1-\alpha) \cdot I_{n-1}$）
