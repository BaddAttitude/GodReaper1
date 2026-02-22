# GodBotScalper v2.0 — Full Installation Guide

## What This Bot Does

GodBotScalper v2.0 is an automated trading EA (Expert Advisor) for MetaTrader 5.

- **Direction**: Reads the H1 Technical Summary (26 indicators — same as investing.com)
  - Score ≥ +7 → opens a BUY
  - Score ≤ −7 → opens a SELL
- **Execution**: Fires trades on the M1 chart every ~4 minutes when direction qualifies
- **Exit**: Auto-calculated TP and SL based on live ATR (no manual price levels needed)
- **Lot size**: Fixed (no martingale in the recommended set files)

---

## Recommended Set Files

| Set File | Symbol | Lots | Daily Profit | Max DD |
|----------|--------|------|-------------|--------|
| `GodBotScalper_XAUUSD_M1_3pct.set` | XAUUSD | 0.14 fixed | ~$413/day | ~$3,247 |
| `GodBotScalper_US30_M1_3contracts.set` | US30 | 3.0 fixed | ~$603/day | ~$3,000 |
| **Both together** | — | — | **~$1,016/day** | **~$6,247** |

> Backtest period: Feb 2025 – Feb 2026 on a $100K account. PF ~1.31, Sharpe ~12.

---

## Requirements

- MetaTrader 5 (MT5) installed and logged into your broker account
- Account balance: minimum $100,000 (recommended)
- Symbols available: XAUUSD (Gold) and US30 (Dow Jones)
- Algorithmic trading enabled on your account
- Stable internet connection (VPS recommended for 24/5 operation)

---

## Step 1 — Copy the EA File into MT5

1. Open MT5
2. Click **File → Open Data Folder**
3. Navigate to: `MQL5 → Experts`
4. Copy **`GodBotScalper.mq5`** from the `GodBotReaper` folder into this `Experts` folder
5. Copy **all `.set` files** from the `GodBotReaper` folder into: `MQL5 → Profiles → Tester` (for the strategy tester) and also keep a copy somewhere accessible

---

## Step 2 — Compile the EA

1. In MT5, press **F4** to open MetaEditor (or click Tools → MetaEditor)
2. In MetaEditor, press **F4** again or go to **File → Open**
3. Navigate to and open **`GodBotScalper.mq5`**
4. Press **F7** to compile
5. Check the bottom panel — it should say:
   `0 error(s), 0 warning(s)`
6. Close MetaEditor

---

## Step 3 — Enable Algorithmic Trading in MT5

1. In MT5, go to **Tools → Options → Expert Advisors**
2. Check these boxes:
   - ✅ Allow algorithmic trading
   - ✅ Allow DLL imports (if prompted)
3. Click OK
4. Make sure the **AutoTrading** button in the toolbar is **green/active**

---

## Step 4 — Set Up XAUUSD Chart (Gold)

1. Open a **new chart**: File → New Chart → XAUUSD
2. Set the timeframe to **M1** (1 Minute)
3. In the Navigator panel (Ctrl+N), expand **Expert Advisors**
4. Double-click **GodBotScalper** to attach it to the chart
5. The EA settings window will open — go to the **Inputs** tab
6. Click **Load** at the bottom of the Inputs tab
7. Navigate to and select: **`GodBotScalper_XAUUSD_M1_3pct.set`**
8. Click **Open** — all parameters load automatically
9. Go to the **Common** tab and ensure:
   - ✅ Allow live trading
   - ✅ Allow importing DLL
10. Click **OK**
11. You should see a smiley face (🙂) in the top-right corner of the chart — EA is running

---

## Step 5 — Set Up US30 Chart (Dow Jones)

1. Open a **new chart**: File → New Chart → US30
2. Set the timeframe to **M1** (1 Minute)
3. Attach **GodBotScalper** to this chart (same as Step 4)
4. In the Inputs tab, click **Load**
5. Select: **`GodBotScalper_US30_M1_3contracts.set`**
6. Click **OK**
7. Confirm 🙂 in the top-right corner

> **Important**: Each chart uses a different Magic Number (20250301 for XAUUSD, 20250302 for US30) so the two bots don't interfere with each other.

---

## Step 6 — Verify the EA is Working

After attaching the EA, check the following in MT5:

### Check 1 — Journal Tab
Click the **Journal** tab at the bottom of MT5. You should see a log line like:
```
GodBot Scalper v2.0 | XAUUSD M1 (H1 TS thresh=+/-7) | BaseLot=0.14 | ...
```

### Check 2 — Experts Tab
Click the **Experts** tab. When the first trade fires you'll see:
```
BUY  | lot=0.14 (lvl 0) | 3312.50 | SL=3309.88 TP=3323.50 | H1 TS=11
```

### Check 3 — Trade Tab
Go to **View → Terminal → Trade** (or press Ctrl+T). Once a trade opens you'll see it listed with the correct SL and TP prices already set.

### Check 4 — Smiley Face
The chart should show 🙂 (not 😟). A sad face means:
- AutoTrading is disabled → click the AutoTrading button
- EA failed to initialise → check the Experts tab for error messages

---

## Step 7 — What to Expect

| Timeframe | What Happens |
|-----------|-------------|
| First few minutes | EA checks H1 TS score every M1 bar |
| When score ≥ +7 or ≤ −7 | Trade opens with auto-calculated TP and SL |
| Trade duration | Avg ~8–9 minutes |
| Per day | ~91–94 trades per symbol |
| Per week | ~450–470 trades per symbol |

Trades only fire during **active market hours** for each symbol:
- XAUUSD: Sunday 23:00 – Friday 22:00 UTC (almost 24/5)
- US30: Monday–Friday, US session hours (09:30–16:00 EST)

---

## EA Parameters Reference

| Parameter | Default | Description |
|-----------|---------|-------------|
| `InpTSThresh` | 7 | H1 TS score needed to trade (±7 = Buy/Sell) |
| `InpATRPeriod` | 21 | ATR lookback period on M1 |
| `InpTP_ATR` | 3.0 | Take Profit = 3× current ATR (auto-calculated) |
| `InpSL_ATR` | 0.75 | Stop Loss = 0.75× current ATR (auto-calculated) |
| `InpBaseLot` | 0.14 / 3.0 | Fixed lot size (set by your chosen .set file) |
| `InpMaxMartLevel` | 0 | 0 = fixed lot, no martingale |
| `InpCooldownBars` | 4 | Min M1 bars between entries (~4 minutes) |
| `InpHedgeMode` | false | Hedge mode (off by default) |
| `InpMagic` | 20250301 | Unique ID for this EA instance |

---

## Available Set Files Summary

| File | Symbol | Strategy | Daily | Annual | MaxDD |
|------|--------|----------|-------|--------|-------|
| `GodBotScalper_XAUUSD_M1_3pct.set` | XAUUSD | Fixed 0.14 lot | $413 | $150K | $3.2K |
| `GodBotScalper_US30_M1_3contracts.set` | US30 | Fixed 3.0 lot | $603 | $219K | $3.0K |
| `GodBotScalper_XAUUSD_M1.set` | XAUUSD | 0.2 lot martingale | $2,784 | $1.0M | $35K |
| `GodBotScalper_XAUUSD_M1_2lot.set` | XAUUSD | 2.0 lot martingale | $27,940 | $10.2M | $261K |
| `GodBotScalper_XAUUSD_M1_5lot.set` | XAUUSD | 5.0 lot martingale | $69,450 | $25.3M | $555K |

> ⚠️ Martingale set files (2lot, 5lot) are high-risk and can exceed $100K account balance on a bad streak. Only use with sufficient capital.

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| Sad face 😟 on chart | Enable AutoTrading button in toolbar |
| No trades opening | Check Journal tab for errors; confirm symbol is available on your broker |
| "Trade context is busy" | Normal — MT5 retries automatically |
| EA disappears after restart | Re-attach and reload set file; or save chart as template |
| Wrong lot sizes | Reload the correct .set file via Inputs → Load |
| US30 not available | Check your broker — may be listed as DJ30, DJIA, or WallSt30 |

---

## VPS Recommendation

For 24/5 uninterrupted trading, run MT5 on a VPS (Virtual Private Server):

1. Any Windows VPS with 2GB RAM and 50GB storage works
2. Install MT5 on the VPS
3. Log into your broker account
4. Set up both charts and attach EAs as per this guide
5. The VPS keeps the bot running even when your PC is off

Recommended VPS providers: Beeks FX, ForexVPS, Vultr (Windows), AWS.

---

## Quick Start Checklist

- [ ] Copy `GodBotScalper.mq5` to MT5 Experts folder
- [ ] Compile in MetaEditor (F7) — 0 errors
- [ ] Enable AutoTrading in MT5
- [ ] Open XAUUSD M1 chart → attach EA → load `_XAUUSD_M1_3pct.set`
- [ ] Open US30 M1 chart → attach EA → load `_US30_M1_3contracts.set`
- [ ] Confirm 🙂 on both charts
- [ ] Check Journal tab for startup messages
- [ ] Wait for first trades to appear in Trade tab
