//+------------------------------------------------------------------+
//|                                              GodBotReaper.mq5    |
//|                         GodBot Reaper v1.0                       |
//|                                                                  |
//|  Strategy:                                                        |
//|    Entry  : MA(100) mean-reversion — enter when price is        |
//|             stretched >= MADistance points from MA               |
//|             BUY  when price far BELOW MA  (expect revert up)    |
//|             SELL when price far ABOVE MA  (expect revert down)  |
//|    Filter : RSI(14) SMA(10) on M5 confirms direction            |
//|    Grid   : ATR(21,M30) × GAF adaptive step, flat lots          |
//|    Smart  : Stops adding grid levels when RSI flips against grid |
//|    Exit   : Ratchet basket TP (default: $50→$60→$70→$80)       |
//|    BE     : Break-even + 2pts applied at 3rd grid trade         |
//|    Risk   : 2% floating DD / 10% balance drop kill-switch       |
//|                                                                  |
//|  ► No magic number filtering (manages all positions on symbol)  |
//|  ► No news filter                                                |
//|  ► No session filter                                             |
//+------------------------------------------------------------------+
#property copyright "GodBot Reaper v1.0"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//===========================================================================
// INPUTS
//===========================================================================

input group "=== Risk & Safety ==="
input double InpStopTradePct   = 10.0;  // Kill-switch: stop if balance drops X% from start
input double InpMaxDDPct       =  2.0;  // Close grid if floating loss >= X% of balance
input double InpMaxSpread      = 50.0;  // Max allowed spread in points before skipping

input group "=== Entry Signal (MA Mean-Reversion) ==="
input int    InpMAPeriod       = 100;   // Simple MA period
input double InpMADistance     = 15.0;  // Points from MA required before entry fires
//  BUY  entry: close is >= MADistance points BELOW MA  → expect reversion upward
//  SELL entry: close is >= MADistance points ABOVE MA  → expect reversion downward

input group "=== RSI Direction Filter ==="
input ENUM_TIMEFRAMES InpRSITF = PERIOD_M5;  // Timeframe for RSI (M5)
input int    InpRSIPeriod      = 14;          // RSI period
input int    InpRSIMALen       = 10;          // SMA length applied to RSI values

input group "=== Lot Size ==="
input double InpLot            = 0.2;   // Fixed lot for every grid order (no multiplier)

input group "=== Grid ==="
input bool             InpAutoCal    = true;       // Use ATR for dynamic grid step
input ENUM_TIMEFRAMES  InpATRTF      = PERIOD_M30; // ATR timeframe (M30 = index 4 in setfile)
input int              InpATRPeriods = 21;          // ATR period
input double           InpGAF        = 1.5;         // ATR multiplier (Grid Adjustment Factor)
input double           InpMinStep    = 25.0;        // Min grid step (points) when ATR is small
input int              InpMaxTrades  = 5;           // Max simultaneous grid orders

input group "=== Break-Even ==="
input int    InpBEAtCount      = 3;     // Apply BE when this many trades are open
input double InpBEOffset       = 2.0;   // BE level = entry + X points (BUY) / entry - X (SELL)

input group "=== Force Close Oldest ==="
input bool   InpForceCloseOld  = true;  // Enable force-close of oldest trade
input int    InpCloseOldAt     = 4;     // Trigger when this many trades are open
input double InpCloseOldMinPts = 10.0;  // Only close if oldest trade is >= X points in profit

input group "=== Basket Exit (Ratchet TP) ==="
input double InpProfitTarget   = 50.0;  // Initial basket profit target ($)
input bool   InpRatchetTP      = true;  // Raise target each time it is hit
input double InpRatchetStep    = 10.0;  // Raise basket target by this $ each time
input int    InpRatchetMax     = 3;     // Max raises: $50→$60→$70→$80 then close
//  Once armed (first target hit), basket closes if PL drops back to the previous floor

//===========================================================================
// GLOBAL STATE
//===========================================================================

CTrade g_trade;

// ── Grid state
int    g_dir       = 0;      // 1 = long grid  |  -1 = short grid  |  0 = flat
int    g_cnt       = 0;      // Open positions (synced each tick)
double g_last_px   = 0.0;    // Price where last grid order was placed
bool   g_be_done   = false;  // Break-even has been logged as applied this grid

// ── Ratchet state
double g_tp        = 0.0;    // Current basket close threshold ($)
int    g_tp_moves  = 0;      // How many ratchet raises have fired
double g_tp_floor  = 0.0;    // Basket must stay above this once armed ($)
bool   g_tp_armed  = false;  // True after basket first hit InpProfitTarget

// ── Risk
double g_start_bal = 0.0;    // Balance at EA start (for kill-switch reference)
bool   g_killed    = false;  // Trading permanently halted this session

// ── Indicator handles
int    g_hMA  = INVALID_HANDLE;
int    g_hATR = INVALID_HANDLE;
int    g_hRSI = INVALID_HANDLE;

//===========================================================================
// OnInit
//===========================================================================
int OnInit()
{
    // No magic number — manages all positions on the chart symbol
    g_trade.SetDeviationInPoints(10);
    g_trade.SetTypeFilling(ORDER_FILLING_IOC);
    g_trade.LogLevel(LOG_LEVEL_ERRORS);

    g_hMA  = iMA (Symbol(), PERIOD_CURRENT, InpMAPeriod, 0, MODE_SMA, PRICE_CLOSE);
    g_hATR = iATR(Symbol(), InpATRTF, InpATRPeriods);
    g_hRSI = iRSI(Symbol(), InpRSITF, InpRSIPeriod, PRICE_CLOSE);

    if(g_hMA == INVALID_HANDLE || g_hATR == INVALID_HANDLE || g_hRSI == INVALID_HANDLE)
    {
        Print("GodBotReaper: Indicator init failed — check symbol/timeframe");
        return INIT_FAILED;
    }

    g_start_bal = AccountInfoDouble(ACCOUNT_BALANCE);
    g_tp        = InpProfitTarget;

    PrintFormat(
        "GodBotReaper v1.0 started | %s | Lot=%.2f | MaxTrades=%d"
        " | Grid=%s | ATRTF=%s | GAF=%.1f",
        Symbol(), InpLot, InpMaxTrades,
        InpAutoCal ? "ATR auto" : "fixed",
        EnumToString(InpATRTF), InpGAF);

    return INIT_SUCCEEDED;
}

//===========================================================================
// OnDeinit
//===========================================================================
void OnDeinit(const int reason)
{
    if(g_hMA  != INVALID_HANDLE) IndicatorRelease(g_hMA);
    if(g_hATR != INVALID_HANDLE) IndicatorRelease(g_hATR);
    if(g_hRSI != INVALID_HANDLE) IndicatorRelease(g_hRSI);
    Comment("");
}

//===========================================================================
// OnTick
//===========================================================================
void OnTick()
{
    string sym = Symbol();

    //──────────────────────────────────────────────────────────────────────
    // 1. Kill-switch: balance has fallen too far from session start
    //──────────────────────────────────────────────────────────────────────
    if(g_killed)
    {
        Comment("GodBotReaper | HALTED — balance kill-switch active");
        return;
    }

    double cur_bal = AccountInfoDouble(ACCOUNT_BALANCE);
    if(cur_bal < g_start_bal * (1.0 - InpStopTradePct / 100.0))
    {
        _CloseAll(sym);
        _ResetGrid();
        g_killed = true;
        PrintFormat("GodBotReaper: KILL-SWITCH | Balance %.2f dropped %.1f%% from start %.2f",
                    cur_bal, (g_start_bal - cur_bal) / g_start_bal * 100.0, g_start_bal);
        return;
    }

    //──────────────────────────────────────────────────────────────────────
    // 2. Spread guard
    //──────────────────────────────────────────────────────────────────────
    double spread = (double)SymbolInfoInteger(sym, SYMBOL_SPREAD);
    if(spread > InpMaxSpread)
    {
        _Comment(sym);
        return;
    }

    //──────────────────────────────────────────────────────────────────────
    // 3. Sync grid count / direction from live positions
    //──────────────────────────────────────────────────────────────────────
    _SyncGrid(sym);

    //──────────────────────────────────────────────────────────────────────
    // 4. Max floating drawdown on open grid
    //──────────────────────────────────────────────────────────────────────
    if(g_cnt > 0)
    {
        double pl  = _BasketPL(sym);
        double bal = AccountInfoDouble(ACCOUNT_BALANCE);
        if(pl < 0.0 && (-pl / bal * 100.0) >= InpMaxDDPct)
        {
            PrintFormat("GodBotReaper: MaxDD hit | Grid PL=%.2f (%.2f%%) | Closing all",
                        pl, -pl / bal * 100.0);
            _CloseAll(sym);
            _ResetGrid();
            return;
        }
    }

    //──────────────────────────────────────────────────────────────────────
    // 5. Basket TP — ratchet exit
    //──────────────────────────────────────────────────────────────────────
    if(g_cnt > 0)
    {
        double pl = _BasketPL(sym);

        // Once armed: close if basket retreats back to the previous floor
        if(g_tp_armed && pl <= g_tp_floor)
        {
            PrintFormat("GodBotReaper: Ratchet floor hit | PL=$%.2f <= Floor=$%.2f | Closing",
                        pl, g_tp_floor);
            _CloseAll(sym);
            _ResetGrid();
            return;
        }

        // Basket has hit the current target
        if(pl >= g_tp)
        {
            if(InpRatchetTP && g_tp_moves < InpRatchetMax)
            {
                // Raise the target and lock in the floor
                g_tp_floor = g_tp;
                g_tp      += InpRatchetStep;
                g_tp_moves++;
                g_tp_armed = true;
                PrintFormat(
                    "GodBotReaper: Ratchet %d/%d | Floor=$%.0f | New target=$%.0f",
                    g_tp_moves, InpRatchetMax, g_tp_floor, g_tp);
            }
            else
            {
                // Max moves done (or ratchet disabled) → close all
                PrintFormat("GodBotReaper: Basket TP hit | PL=$%.2f | Closing all", pl);
                _CloseAll(sym);
                _ResetGrid();
                return;
            }
        }
    }

    //──────────────────────────────────────────────────────────────────────
    // 6. Break-even management
    //──────────────────────────────────────────────────────────────────────
    if(g_cnt >= InpBEAtCount)
        _ApplyBreakEven(sym);

    //──────────────────────────────────────────────────────────────────────
    // 7. Force close oldest (harvests oldest profitable position)
    //──────────────────────────────────────────────────────────────────────
    if(InpForceCloseOld && g_cnt >= InpCloseOldAt)
        _ForceCloseOldest(sym);

    //──────────────────────────────────────────────────────────────────────
    // 8. Add next grid level if price has moved far enough against us
    //──────────────────────────────────────────────────────────────────────
    if(g_cnt > 0 && g_cnt < InpMaxTrades && g_dir != 0)
    {
        double step = _GridStep();
        double ref  = (g_dir == 1) ? SymbolInfoDouble(sym, SYMBOL_BID)
                                   : SymbolInfoDouble(sym, SYMBOL_ASK);

        bool trigger = (g_dir ==  1 && ref <= g_last_px - step) ||
                       (g_dir == -1 && ref >= g_last_px + step);

        if(trigger)
        {
            if(_SmartGridAllowed(sym, g_dir))
            {
                _OpenOrder(sym, g_dir);
                g_last_px = ref;
                g_cnt++;
                PrintFormat(
                    "GodBotReaper: Grid L%d | %s | Price=%.5f | Step=%.1f pts",
                    g_cnt, (g_dir == 1 ? "BUY" : "SELL"),
                    ref, step / _Point);
            }
            else
            {
                Print("GodBotReaper: Smart Grid blocked — RSI flipped against grid direction");
            }
        }
    }

    //──────────────────────────────────────────────────────────────────────
    // 9. New bar — check entry signal (only when flat)
    //──────────────────────────────────────────────────────────────────────
    static datetime s_bar = 0;
    datetime cur_bar = iTime(sym, PERIOD_CURRENT, 0);
    if(cur_bar == s_bar) { _Comment(sym); return; }
    s_bar = cur_bar;

    if(g_cnt > 0) { _Comment(sym); return; }  // Already in a grid

    // MA value on last closed bar
    double ma_buf[1];
    if(CopyBuffer(g_hMA, 0, 1, 1, ma_buf) < 1) { _Comment(sym); return; }
    double ma = ma_buf[0];

    // Closed bar close price
    double close_buf[1];
    if(CopyClose(sym, PERIOD_CURRENT, 1, 1, close_buf) < 1) { _Comment(sym); return; }
    double close = close_buf[0];

    double dist = InpMADistance * _Point;

    bool want_buy  = (close < ma - dist);   // Price stretched far below MA → revert up
    bool want_sell = (close > ma + dist);   // Price stretched far above MA → revert down

    if(!want_buy && !want_sell) { _Comment(sym); return; }

    // RSI confirmation for mean-reversion direction:
    //   BUY  entry: RSI bias must be BEARISH  (-1) — confirms oversold extension
    //   SELL entry: RSI bias must be BULLISH  (+1) — confirms overbought extension
    int rsi_bias = _GetRSIBias(sym);

    if(want_buy  && rsi_bias != -1) { _Comment(sym); return; }
    if(want_sell && rsi_bias !=  1) { _Comment(sym); return; }

    int    dir         = want_buy ? 1 : -1;
    double entry_price = (dir == 1) ? SymbolInfoDouble(sym, SYMBOL_ASK)
                                    : SymbolInfoDouble(sym, SYMBOL_BID);

    _OpenOrder(sym, dir);

    g_dir      = dir;
    g_last_px  = entry_price;
    g_cnt      = 1;
    g_be_done  = false;
    g_tp       = InpProfitTarget;
    g_tp_moves = 0;
    g_tp_floor = 0.0;
    g_tp_armed = false;

    PrintFormat(
        "GodBotReaper: ENTRY %s | Price=%.5f | MA=%.5f | Dist=%.1f pts | RSI bias=%d",
        (dir == 1 ? "BUY" : "SELL"),
        entry_price, ma,
        MathAbs(close - ma) / _Point,
        rsi_bias);

    _Comment(sym);
}

//===========================================================================
// HELPERS
//===========================================================================

//── Sync g_cnt and g_dir from live positions (no magic filter)
void _SyncGrid(const string sym)
{
    int cnt = 0;
    int dir = 0;

    for(int i = 0; i < PositionsTotal(); i++)
    {
        ulong t = PositionGetTicket(i);
        if(t == 0) continue;
        if(PositionGetString(POSITION_SYMBOL) != sym) continue;
        cnt++;
        if(dir == 0)
            dir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
    }

    if(cnt == 0 && g_cnt > 0)
    {
        Print("GodBotReaper: All positions gone — resetting grid state");
        _ResetGrid();
    }

    g_cnt = cnt;
    if(cnt > 0) g_dir = dir;
}

//── Total floating P&L for all positions on this symbol
double _BasketPL(const string sym)
{
    double total = 0.0;
    for(int i = 0; i < PositionsTotal(); i++)
    {
        ulong t = PositionGetTicket(i);
        if(t == 0) continue;
        if(PositionGetString(POSITION_SYMBOL) != sym) continue;
        total += PositionGetDouble(POSITION_PROFIT)
               + PositionGetDouble(POSITION_SWAP);
    }
    return total;
}

//── ATR-based grid step; returns raw price distance (not points)
double _GridStep()
{
    double step = InpMinStep * _Point;
    if(InpAutoCal)
    {
        double atr[1];
        if(CopyBuffer(g_hATR, 0, 1, 1, atr) >= 1)
            step = MathMax(step, atr[0] * InpGAF);
    }
    return step;
}

//── Open a market order with no SL / TP (basket-managed exit)
void _OpenOrder(const string sym, const int dir)
{
    if(dir == 1)
        g_trade.Buy (InpLot, sym, SymbolInfoDouble(sym, SYMBOL_ASK), 0.0, 0.0, "Reaper BUY");
    else
        g_trade.Sell(InpLot, sym, SymbolInfoDouble(sym, SYMBOL_BID), 0.0, 0.0, "Reaper SELL");
}

//── Close every open position on this symbol
void _CloseAll(const string sym)
{
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong t = PositionGetTicket(i);
        if(t == 0) continue;
        if(PositionGetString(POSITION_SYMBOL) != sym) continue;
        g_trade.PositionClose(t);
    }
}

//── Move all open positions to break-even + InpBEOffset points
//   Never moves SL in the wrong direction (safe to call every tick)
void _ApplyBreakEven(const string sym)
{
    int    digits    = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
    double offset    = InpBEOffset * _Point;
    bool   any_moved = false;

    for(int i = 0; i < PositionsTotal(); i++)
    {
        ulong t = PositionGetTicket(i);
        if(t == 0) continue;
        if(PositionGetString(POSITION_SYMBOL) != sym) continue;

        double entry  = PositionGetDouble(POSITION_PRICE_OPEN);
        double cur_sl = PositionGetDouble(POSITION_SL);
        int    ptype  = (int)PositionGetInteger(POSITION_TYPE);

        double new_sl = (ptype == POSITION_TYPE_BUY)
                      ? NormalizeDouble(entry + offset, digits)
                      : NormalizeDouble(entry - offset, digits);

        bool needs_update =
            (ptype == POSITION_TYPE_BUY  && (cur_sl == 0.0 || cur_sl < new_sl)) ||
            (ptype == POSITION_TYPE_SELL && (cur_sl == 0.0 || cur_sl > new_sl));

        if(needs_update)
        {
            g_trade.PositionModify(t, new_sl, PositionGetDouble(POSITION_TP));
            any_moved = true;
        }
    }

    if(any_moved && !g_be_done)
    {
        PrintFormat("GodBotReaper: Break-even applied to all positions (offset=%.1f pts)",
                    InpBEOffset);
        g_be_done = true;
    }
}

//── Close the oldest open position if it is >= InpCloseOldMinPts in profit
void _ForceCloseOldest(const string sym)
{
    ulong    oldest_ticket = 0;
    datetime oldest_time   = D'3000.01.01';

    for(int i = 0; i < PositionsTotal(); i++)
    {
        ulong t = PositionGetTicket(i);
        if(t == 0) continue;
        if(PositionGetString(POSITION_SYMBOL) != sym) continue;
        datetime ot = (datetime)PositionGetInteger(POSITION_TIME);
        if(ot < oldest_time)
        {
            oldest_time   = ot;
            oldest_ticket = t;
        }
    }

    if(oldest_ticket == 0) return;
    if(!PositionSelectByTicket(oldest_ticket)) return;

    int    ptype      = (int)PositionGetInteger(POSITION_TYPE);
    double entry      = PositionGetDouble(POSITION_PRICE_OPEN);
    double cur_price  = (ptype == POSITION_TYPE_BUY)
                      ? SymbolInfoDouble(sym, SYMBOL_BID)
                      : SymbolInfoDouble(sym, SYMBOL_ASK);
    double profit_pts = (ptype == POSITION_TYPE_BUY)
                      ? (cur_price - entry) / _Point
                      : (entry - cur_price) / _Point;

    if(profit_pts >= InpCloseOldMinPts)
    {
        g_trade.PositionClose(oldest_ticket);
        PrintFormat("GodBotReaper: Force-closed oldest #%I64u | Profit=%.1f pts",
                    oldest_ticket, profit_pts);
    }
}

//── RSI bias: RSI(14) vs its own SMA(10) on InpRSITF
//   Returns: +1 = bullish (RSI > SMA)   -1 = bearish (RSI < SMA)   0 = neutral
int _GetRSIBias(const string sym)
{
    int     bars_needed = InpRSIMALen + 1;
    double  rsi[];
    ArraySetAsSeries(rsi, true);

    if(CopyBuffer(g_hRSI, 0, 1, bars_needed, rsi) < bars_needed) return 0;

    // SMA of last InpRSIMALen RSI values
    double sum = 0.0;
    for(int i = 0; i < InpRSIMALen; i++) sum += rsi[i];
    double rsi_sma = sum / InpRSIMALen;
    double cur_rsi = rsi[0];  // Most recent closed bar RSI

    if(cur_rsi > rsi_sma) return  1;
    if(cur_rsi < rsi_sma) return -1;
    return 0;
}

//── Smart Grid gate: stop adding grid levels when RSI momentum flips
//   For a LONG  (mean-reversion buy) grid: keep adding while RSI is still bearish (-1)
//   For a SHORT (mean-reversion sell) grid: keep adding while RSI is still bullish (+1)
//   Once RSI flips (suggests reversal is underway), stop adding more same-side levels.
bool _SmartGridAllowed(const string sym, const int grid_dir)
{
    int bias = _GetRSIBias(sym);
    if(bias == 0) return true;                             // No clear bias — allow
    if(grid_dir ==  1 && bias == -1) return true;         // Long grid, still bearish RSI ✓
    if(grid_dir == -1 && bias ==  1) return true;         // Short grid, still bullish RSI ✓
    return false;                                          // RSI turned — block new levels
}

//── Reset all grid and ratchet state
void _ResetGrid()
{
    g_dir      = 0;
    g_cnt      = 0;
    g_last_px  = 0.0;
    g_be_done  = false;
    g_tp       = InpProfitTarget;
    g_tp_moves = 0;
    g_tp_floor = 0.0;
    g_tp_armed = false;
}

//── Chart dashboard
void _Comment(const string sym)
{
    double pl     = (g_cnt > 0) ? _BasketPL(sym) : 0.0;
    double bal    = AccountInfoDouble(ACCOUNT_BALANCE);
    double spread = (double)SymbolInfoInteger(sym, SYMBOL_SPREAD);
    double dd_pct = (g_cnt > 0 && pl < 0.0 && bal > 0.0)
                  ? (-pl / bal * 100.0) : 0.0;

    string ratchet_str;
    if(g_tp_armed)
        ratchet_str = StringFormat("Ratchet: floor=$%.0f | target=$%.0f | moves=%d/%d",
                                   g_tp_floor, g_tp, g_tp_moves, InpRatchetMax);
    else
        ratchet_str = StringFormat("Target: $%.0f (unarmed)", g_tp);

    Comment(StringFormat(
        "GodBotReaper v1.0 | %s\n"
        "Grid: %-5s | Orders: %d/%d | Basket PL: $%.2f\n"
        "%s\n"
        "BE: %-8s | Float DD: %.2f%% / %.1f%%\n"
        "Spread: %.0f / %.0f pts\n"
        "%s",
        sym,
        (g_dir ==  1 ? "LONG" : g_dir == -1 ? "SHORT" : "FLAT"),
        g_cnt, InpMaxTrades, pl,
        ratchet_str,
        (g_be_done ? "ACTIVE" : (g_cnt >= InpBEAtCount ? "PENDING" : "---")),
        dd_pct, InpMaxDDPct,
        spread, InpMaxSpread,
        TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES | TIME_SECONDS)
    ));
}
