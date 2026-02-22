//+------------------------------------------------------------------+
//| GodBotScalper.mq5                                                |
//| GodBot Scalper v2.1 — Session + Break-Even + Daily Limit +      |
//|                        Spread Filter                             |
//|                                                                  |
//| Direction  : H1 Technical Summary (26 indicators — replicates   |
//|              investing.com methodology)                          |
//|              Score >= +InpTSThresh  → BUY                       |
//|              Score <= -InpTSThresh  → SELL                       |
//| Frequency  : M1 execution, InpCooldownBars between entries      |
//| Sizing     : Martingale — doubles lot on loss (same direction)   |
//|              0.2→0.4→0.8→1.6→3.2 lots (5 levels)               |
//| Hedge      : If InpHedgeMode=true, open counter-position when   |
//|              H1 score flips to Strong Sell/Buy (|score|>=15)    |
//|              while primary trade is still open                   |
//| Exit       : Fixed ATR R:R  TP=InpTP_ATR×ATR | SL=InpSL_ATR×ATR|
//| v2.1 adds : Session filter, break-even stop, daily loss limit,  |
//|              spread filter                                       |
//+------------------------------------------------------------------+
#property copyright "GodBot"
#property version   "2.10"
#property description "GodBot Scalper v2.1 — Session + BE + Daily Limit + Spread Filter"

#include <Trade\Trade.mqh>

//──────────────────────────────────────────────────────────────────
// Inputs
//──────────────────────────────────────────────────────────────────

input group "=== Technical Summary (H1 Direction Filter) ==="
input int    InpTSThresh     = 7;    // TS score threshold: 7=Buy/Sell, 15=Strong only
// Score is computed from 13 MAs + 11 Oscillators on H1 chart

input group "=== Exit: ATR R:R ==="
input int    InpATRPeriod    = 21;   // ATR period (M1)
input double InpTP_ATR       = 3.0;  // TP = N × ATR
input double InpSL_ATR       = 0.75; // SL = N × ATR

input group "=== Martingale ==="
input double InpBaseLot      = 0.2;  // Base lot (level 0)
input int    InpMaxMartLevel = 4;    // Max levels: 0.2→0.4→0.8→1.6→3.2

input group "=== Frequency (M1 Execution) ==="
input int    InpCooldownBars = 12;   // Min M1 bars between entries (~53/day)

input group "=== Hedge Mode ==="
input bool   InpHedgeMode    = false; // Open counter-position on Strong reversal

input group "=== Session Filter ==="
input bool   InpUseSession   = true;  // Only trade within session hours (UTC)
input int    InpSessionStart = 7;     // Session open hour UTC (0-23)
input int    InpSessionEnd   = 20;    // Session close hour UTC (0-23)

input group "=== Break-Even Stop ==="
input bool   InpUseBE        = true;  // Move SL to entry once in profit >= N×ATR
input double InpBE_ATR       = 1.0;   // Profit threshold to trigger break-even (×ATR)

input group "=== Daily Loss Limit ==="
input bool   InpUseDDLimit   = true;    // Stop trading today if loss exceeds limit
input double InpMaxDailyLoss = 500.0;   // Max allowed daily loss in account currency

input group "=== Spread Filter ==="
input bool   InpUseSpread    = true;   // Skip entry if spread is too wide
input double InpMaxSpreadATR = 0.15;   // Max spread as fraction of ATR

input group "=== Trade Settings ==="
input ulong  InpMagic        = 20250301; // EA magic number
input bool   InpHedgeMagic   = true;     // Hedge trades use Magic+1

//──────────────────────────────────────────────────────────────────
// Globals
//──────────────────────────────────────────────────────────────────

CTrade   trade;

// H1 indicator handles
int hSMA5_H1, hSMA10_H1, hSMA20_H1, hSMA50_H1, hSMA100_H1, hSMA200_H1;
int hEMA5_H1, hEMA10_H1, hEMA20_H1, hEMA50_H1, hEMA100_H1, hEMA200_H1;
int hVWMA_H1;                // VWMA(20) — using WMA as proxy

// H1 Oscillator handles
int hRSI_H1, hStoch_H1, hCCI_H1, hADX_H1;
int hAO_H1, hMom_H1, hMACD_H1, hWPR_H1, hUO_H1;

// M1 ATR handle
int hATR_M1;

// State
datetime lastBar        = 0;
datetime lastEntryBar   = 0;
int      martLevel      = 0;   // current martingale level
int      lastDir        = 0;   // +1 buy / -1 sell
bool     paused         = false;

// Daily loss tracking
datetime todayDate    = 0;
double   dailyPnL     = 0.0;
bool     dailyStopped = false;


//──────────────────────────────────────────────────────────────────
// Break-Even: called every tick — moves SL to open price once
//             trade profit reaches InpBE_ATR × ATR
//──────────────────────────────────────────────────────────────────

void CheckBreakEven()
{
    if(!InpUseBE) return;
    double atrV[1]; ArraySetAsSeries(atrV, true);
    if(CopyBuffer(hATR_M1, 0, 1, 1, atrV) < 1 || atrV[0] <= 0) return;
    double atr = atrV[0];

    for(int i = 0; i < PositionsTotal(); i++)
    {
        if(PositionGetSymbol(i) != _Symbol) continue;
        if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagic) continue;

        ulong  ticket    = PositionGetInteger(POSITION_TICKET);
        double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
        double curSL     = PositionGetDouble(POSITION_SL);
        double curTP     = PositionGetDouble(POSITION_TP);
        int    posType   = (int)PositionGetInteger(POSITION_TYPE);
        double curPrice  = (posType == POSITION_TYPE_BUY)
                           ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                           : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

        double profit_pts = (posType == POSITION_TYPE_BUY)
                            ? (curPrice - openPrice)
                            : (openPrice - curPrice);

        if(profit_pts >= InpBE_ATR * atr)
        {
            double newSL     = openPrice;
            bool   needsMove = (posType == POSITION_TYPE_BUY)
                               ? (curSL < newSL - _Point)
                               : (curSL > newSL + _Point);
            if(needsMove)
            {
                trade.PositionModify(ticket, newSL, curTP);
                PrintFormat("BE | ticket=%llu | SL moved to open %.5f (profit=%.1f pts, ATR=%.5f)",
                            ticket, newSL, profit_pts, atr);
            }
        }
    }
}

//──────────────────────────────────────────────────────────────────
// Helper: compute H1 Tech Summary score  (-24 to +24)
//──────────────────────────────────────────────────────────────────

int ComputeH1TechSummary()
{
    double close_h1[1], high_h1[1], low_h1[1];
    ArraySetAsSeries(close_h1, true);
    ArraySetAsSeries(high_h1,  true);
    ArraySetAsSeries(low_h1,   true);

    if(CopyClose(_Symbol, PERIOD_H1, 1, 1, close_h1) < 1) return 0;
    if(CopyHigh (_Symbol, PERIOD_H1, 1, 1, high_h1)  < 1) return 0;
    if(CopyLow  (_Symbol, PERIOD_H1, 1, 1, low_h1)   < 1) return 0;

    double price = close_h1[0];
    int    score = 0;
    double buf[1];
    ArraySetAsSeries(buf, true);

    // ── Moving Average signals (13 total) ──────────────────────────────────
    int smaHandles[] = {hSMA5_H1, hSMA10_H1, hSMA20_H1,
                        hSMA50_H1, hSMA100_H1, hSMA200_H1};
    for(int i = 0; i < 6; i++)
    {
        if(CopyBuffer(smaHandles[i], 0, 1, 1, buf) < 1) continue;
        score += (price > buf[0]) ? 1 : (price < buf[0]) ? -1 : 0;
    }
    int emaHandles[] = {hEMA5_H1, hEMA10_H1, hEMA20_H1,
                        hEMA50_H1, hEMA100_H1, hEMA200_H1};
    for(int i = 0; i < 6; i++)
    {
        if(CopyBuffer(emaHandles[i], 0, 1, 1, buf) < 1) continue;
        score += (price > buf[0]) ? 1 : (price < buf[0]) ? -1 : 0;
    }
    if(CopyBuffer(hVWMA_H1, 0, 1, 1, buf) >= 1)
        score += (price > buf[0]) ? 1 : (price < buf[0]) ? -1 : 0;

    // ── Oscillator signals (11 total) ───────────────────────────────────────

    // 1. RSI(14)
    if(CopyBuffer(hRSI_H1, 0, 1, 1, buf) >= 1)
    {
        double rsi = buf[0];
        score += (rsi < 30) ? 1 : (rsi > 70) ? -1 : 0;
    }

    // 2. Stochastic(14,3,3)
    if(CopyBuffer(hStoch_H1, 0, 1, 1, buf) >= 1)
    {
        double k = buf[0];
        score += (k < 20) ? 1 : (k > 80) ? -1 : 0;
    }

    // 3. CCI(20)
    if(CopyBuffer(hCCI_H1, 0, 1, 1, buf) >= 1)
    {
        double cci = buf[0];
        score += (cci < -100) ? 1 : (cci > 100) ? -1 : 0;
    }

    // 4. ADX(14)
    {
        double adxBuf[1], pDiBuf[1], mDiBuf[1];
        ArraySetAsSeries(adxBuf, true);
        ArraySetAsSeries(pDiBuf, true);
        ArraySetAsSeries(mDiBuf, true);
        if(CopyBuffer(hADX_H1, 0, 1, 1, adxBuf) >= 1 &&
           CopyBuffer(hADX_H1, 1, 1, 1, pDiBuf) >= 1 &&
           CopyBuffer(hADX_H1, 2, 1, 1, mDiBuf) >= 1)
        {
            if(adxBuf[0] > 25)
                score += (pDiBuf[0] > mDiBuf[0]) ? 1 : -1;
        }
    }

    // 5. Awesome Oscillator
    if(CopyBuffer(hAO_H1, 0, 1, 1, buf) >= 1)
        score += (buf[0] > 0) ? 1 : (buf[0] < 0) ? -1 : 0;

    // 6. Momentum(10)
    if(CopyBuffer(hMom_H1, 0, 1, 1, buf) >= 1)
        score += (buf[0] > 0) ? 1 : (buf[0] < 0) ? -1 : 0;

    // 7. MACD(12,26,9)
    {
        double macdBuf[1], sigBuf[1];
        ArraySetAsSeries(macdBuf, true);
        ArraySetAsSeries(sigBuf,  true);
        if(CopyBuffer(hMACD_H1, 0, 1, 1, macdBuf) >= 1 &&
           CopyBuffer(hMACD_H1, 1, 1, 1, sigBuf)  >= 1)
            score += (macdBuf[0] > sigBuf[0]) ? 1 : (macdBuf[0] < sigBuf[0]) ? -1 : 0;
    }

    // 8. Williams %R(14)
    if(CopyBuffer(hWPR_H1, 0, 1, 1, buf) >= 1)
    {
        double wr = buf[0];
        score += (wr < -80) ? 1 : (wr > -20) ? -1 : 0;
    }

    // 9. Ultimate Oscillator — skip (not standard in MT5)
    if(hUO_H1 != INVALID_HANDLE)
    {
        if(CopyBuffer(hUO_H1, 0, 1, 1, buf) >= 1)
            score += (buf[0] < 30) ? 1 : (buf[0] > 70) ? -1 : 0;
    }

    // 10. Bull/Bear Power: midpoint vs EMA(13)
    {
        double ema13[1];
        ArraySetAsSeries(ema13, true);
        int hEMA13 = iMA(_Symbol, PERIOD_H1, 13, 0, MODE_EMA, PRICE_CLOSE);
        if(hEMA13 != INVALID_HANDLE && CopyBuffer(hEMA13, 0, 1, 1, ema13) >= 1)
        {
            double midpoint = (high_h1[0] + low_h1[0]) / 2.0;
            score += (midpoint > ema13[0]) ? 1 : (midpoint < ema13[0]) ? -1 : 0;
            IndicatorRelease(hEMA13);
        }
    }

    // 11. RSI momentum: >55 bullish, <45 bearish
    if(CopyBuffer(hRSI_H1, 0, 1, 1, buf) >= 1)
        score += (buf[0] > 55) ? 1 : (buf[0] < 45) ? -1 : 0;

    return score;
}

//──────────────────────────────────────────────────────────────────
// OnInit
//──────────────────────────────────────────────────────────────────

int OnInit()
{
    trade.SetExpertMagicNumber(InpMagic);

    hSMA5_H1   = iMA(_Symbol, PERIOD_H1, 5,   0, MODE_SMA, PRICE_CLOSE);
    hSMA10_H1  = iMA(_Symbol, PERIOD_H1, 10,  0, MODE_SMA, PRICE_CLOSE);
    hSMA20_H1  = iMA(_Symbol, PERIOD_H1, 20,  0, MODE_SMA, PRICE_CLOSE);
    hSMA50_H1  = iMA(_Symbol, PERIOD_H1, 50,  0, MODE_SMA, PRICE_CLOSE);
    hSMA100_H1 = iMA(_Symbol, PERIOD_H1, 100, 0, MODE_SMA, PRICE_CLOSE);
    hSMA200_H1 = iMA(_Symbol, PERIOD_H1, 200, 0, MODE_SMA, PRICE_CLOSE);
    hEMA5_H1   = iMA(_Symbol, PERIOD_H1, 5,   0, MODE_EMA, PRICE_CLOSE);
    hEMA10_H1  = iMA(_Symbol, PERIOD_H1, 10,  0, MODE_EMA, PRICE_CLOSE);
    hEMA20_H1  = iMA(_Symbol, PERIOD_H1, 20,  0, MODE_EMA, PRICE_CLOSE);
    hEMA50_H1  = iMA(_Symbol, PERIOD_H1, 50,  0, MODE_EMA, PRICE_CLOSE);
    hEMA100_H1 = iMA(_Symbol, PERIOD_H1, 100, 0, MODE_EMA, PRICE_CLOSE);
    hEMA200_H1 = iMA(_Symbol, PERIOD_H1, 200, 0, MODE_EMA, PRICE_CLOSE);
    hVWMA_H1   = iMA(_Symbol, PERIOD_H1, 20,  0, MODE_LWMA, PRICE_CLOSE);

    hRSI_H1   = iRSI      (_Symbol, PERIOD_H1, 14, PRICE_CLOSE);
    hStoch_H1 = iStochastic(_Symbol, PERIOD_H1, 14, 3, 3, MODE_SMA, STO_LOWHIGH);
    hCCI_H1   = iCCI      (_Symbol, PERIOD_H1, 20, PRICE_TYPICAL);
    hADX_H1   = iADX      (_Symbol, PERIOD_H1, 14);
    hAO_H1    = iAO       (_Symbol, PERIOD_H1);
    hMom_H1   = iMomentum (_Symbol, PERIOD_H1, 10, PRICE_CLOSE);
    hMACD_H1  = iMACD     (_Symbol, PERIOD_H1, 12, 26, 9, PRICE_CLOSE);
    hWPR_H1   = iWPR      (_Symbol, PERIOD_H1, 14);
    hUO_H1    = INVALID_HANDLE;

    hATR_M1   = iATR(_Symbol, PERIOD_M1, InpATRPeriod);

    int handles[] = {hSMA5_H1, hSMA10_H1, hSMA20_H1, hSMA50_H1, hSMA100_H1, hSMA200_H1,
                     hEMA5_H1, hEMA10_H1, hEMA20_H1, hEMA50_H1, hEMA100_H1, hEMA200_H1,
                     hVWMA_H1, hRSI_H1, hStoch_H1, hCCI_H1, hADX_H1, hAO_H1,
                     hMom_H1, hMACD_H1, hWPR_H1, hATR_M1};
    for(int i = 0; i < ArraySize(handles); i++)
    {
        if(handles[i] == INVALID_HANDLE)
        {
            PrintFormat("GodBot Scalper v2.1: FAILED to create handle index %d", i);
            return INIT_FAILED;
        }
    }

    PrintFormat("GodBot Scalper v2.1 | %s M1 (H1 TS thresh=+/-%d) | "
                "BaseLot=%.2f | MaxMart=%d | CD=%d bars | "
                "TP=%.1fx ATR | SL=%.1fx ATR | Hedge=%s | "
                "Session=%s(%d-%d UTC) | BE=%s(%.1fx ATR) | "
                "DailyLimit=%s($%.0f) | SpreadFilter=%s(%.2fx ATR)",
                _Symbol, InpTSThresh, InpBaseLot, InpMaxMartLevel,
                InpCooldownBars, InpTP_ATR, InpSL_ATR,
                InpHedgeMode ? "ON" : "OFF",
                InpUseSession ? "ON" : "OFF", InpSessionStart, InpSessionEnd,
                InpUseBE ? "ON" : "OFF", InpBE_ATR,
                InpUseDDLimit ? "ON" : "OFF", InpMaxDailyLoss,
                InpUseSpread ? "ON" : "OFF", InpMaxSpreadATR);
    return INIT_SUCCEEDED;
}

//──────────────────────────────────────────────────────────────────
// OnDeinit
//──────────────────────────────────────────────────────────────────

void OnDeinit(const int reason)
{
    int handles[] = {hSMA5_H1, hSMA10_H1, hSMA20_H1, hSMA50_H1, hSMA100_H1, hSMA200_H1,
                     hEMA5_H1, hEMA10_H1, hEMA20_H1, hEMA50_H1, hEMA100_H1, hEMA200_H1,
                     hVWMA_H1, hRSI_H1, hStoch_H1, hCCI_H1, hADX_H1, hAO_H1,
                     hMom_H1, hMACD_H1, hWPR_H1, hATR_M1};
    for(int i = 0; i < ArraySize(handles); i++)
        if(handles[i] != INVALID_HANDLE)
            IndicatorRelease(handles[i]);
}

//──────────────────────────────────────────────────────────────────
// OnTradeTransaction — update martingale on trade close
//──────────────────────────────────────────────────────────────────

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &req,
                        const MqlTradeResult      &res)
{
    if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;

    ulong ticket = trans.deal;
    if(!HistoryDealSelect(ticket)) return;
    if(HistoryDealGetString (ticket, DEAL_SYMBOL) != _Symbol)          return;
    if(HistoryDealGetInteger(ticket, DEAL_MAGIC)  != (long)InpMagic)   return;
    if(HistoryDealGetInteger(ticket, DEAL_ENTRY)  != DEAL_ENTRY_OUT)   return;

    double profit    = HistoryDealGetDouble (ticket, DEAL_PROFIT)
                     + HistoryDealGetDouble (ticket, DEAL_SWAP)
                     + HistoryDealGetDouble (ticket, DEAL_COMMISSION);

    // Daily P&L tracking
    MqlDateTime ddt; TimeToStruct(TimeCurrent(), ddt);
    datetime today = StringToTime(StringFormat("%04d.%02d.%02d", ddt.year, ddt.mon, ddt.day));
    if(today != todayDate) { todayDate = today; dailyPnL = 0.0; dailyStopped = false; }
    dailyPnL += profit;
    if(InpUseDDLimit && dailyPnL < -InpMaxDailyLoss && !dailyStopped)
    {
        dailyStopped = true;
        PrintFormat("DAILY LOSS LIMIT hit: daily P&L=%.2f < -%.2f. No new trades today.",
                    dailyPnL, InpMaxDailyLoss);
    }

    long   deal_type = HistoryDealGetInteger(ticket, DEAL_TYPE);
    int    closedDir = (deal_type == DEAL_TYPE_SELL) ? 1 : -1;

    if(profit < 0.0 && closedDir == lastDir)
    {
        martLevel = MathMin(martLevel + 1, InpMaxMartLevel);
        if(martLevel >= InpMaxMartLevel)
        {
            paused = true;
            PrintFormat("MART MAX reached (level %d). Pausing.", martLevel);
        }
        PrintFormat("LOSS | dir=%s | new martLevel=%d | nextLot=%.2f",
                    closedDir == 1 ? "BUY" : "SELL",
                    martLevel, InpBaseLot * MathPow(2, martLevel));
    }
    else
    {
        if(martLevel > 0 || paused)
            PrintFormat("WIN/RESET | was level %d | resetting to base lot %.2f",
                        martLevel, InpBaseLot);
        martLevel = 0;
        paused    = false;
    }
}

//──────────────────────────────────────────────────────────────────
// Helpers
//──────────────────────────────────────────────────────────────────

bool HasOpenPosition(ulong magic)
{
    for(int i = 0; i < PositionsTotal(); i++)
        if(PositionGetSymbol(i) == _Symbol &&
           PositionGetInteger(POSITION_MAGIC) == (long)magic)
            return true;
    return false;
}

int GetOpenPositionType(ulong magic)
{
    for(int i = 0; i < PositionsTotal(); i++)
        if(PositionGetSymbol(i) == _Symbol &&
           PositionGetInteger(POSITION_MAGIC) == (long)magic)
            return (int)PositionGetInteger(POSITION_TYPE);
    return -1;
}

//──────────────────────────────────────────────────────────────────
// OnTick
//──────────────────────────────────────────────────────────────────

void OnTick()
{
    CheckBreakEven();   // runs every tick — manages BE stop for open positions

    datetime curBar = iTime(_Symbol, PERIOD_M1, 0);
    if(curBar == lastBar) return;
    lastBar = curBar;

    if(paused) return;

    // Reset daily tracker on new day; stop if limit hit
    MqlDateTime ndt; TimeToStruct(TimeCurrent(), ndt);
    datetime today = StringToTime(StringFormat("%04d.%02d.%02d", ndt.year, ndt.mon, ndt.day));
    if(today != todayDate) { todayDate = today; dailyPnL = 0.0; dailyStopped = false; }
    if(dailyStopped) return;

    // Session time filter
    if(InpUseSession)
    {
        MqlDateTime utc; TimeToStruct(TimeGMT(), utc);
        if(utc.hour < InpSessionStart || utc.hour >= InpSessionEnd) return;
    }

    int  tsScore = ComputeH1TechSummary();
    bool bull    = tsScore >= InpTSThresh;
    bool bear    = tsScore <= -InpTSThresh;

    // Hedge mode check
    if(InpHedgeMode && HasOpenPosition(InpMagic))
    {
        int posType = GetOpenPositionType(InpMagic);
        double atrV[1]; ArraySetAsSeries(atrV, true);
        if(CopyBuffer(hATR_M1, 0, 1, 1, atrV) < 1 || atrV[0] <= 0) return;

        if(posType == 0 && tsScore <= -15 && !HasOpenPosition(InpMagic + 1))
        {
            double price    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            double hedgeLot = MathMax(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN),
                                      InpBaseLot / 2.0);
            CTrade hedgeTrade;
            hedgeTrade.SetExpertMagicNumber(InpMagic + 1);
            if(hedgeTrade.Sell(hedgeLot, _Symbol, price,
                               price + InpSL_ATR * atrV[0],
                               price - InpTP_ATR * atrV[0],
                               "GodBot Scalper HEDGE SELL"))
                PrintFormat("HEDGE SELL | lot=%.2f | H1 TS=%d", hedgeLot, tsScore);
        }
        else if(posType == 1 && tsScore >= 15 && !HasOpenPosition(InpMagic + 1))
        {
            double price    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            double hedgeLot = MathMax(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN),
                                      InpBaseLot / 2.0);
            CTrade hedgeTrade;
            hedgeTrade.SetExpertMagicNumber(InpMagic + 1);
            if(hedgeTrade.Buy(hedgeLot, _Symbol, price,
                              price - InpSL_ATR * atrV[0],
                              price + InpTP_ATR * atrV[0],
                              "GodBot Scalper HEDGE BUY"))
                PrintFormat("HEDGE BUY | lot=%.2f | H1 TS=%d", hedgeLot, tsScore);
        }
        return;
    }

    if(HasOpenPosition(InpMagic)) return;

    if(lastEntryBar > 0 &&
       (curBar - lastEntryBar) < (InpCooldownBars * PeriodSeconds(PERIOD_M1)))
        return;

    if(!bull && !bear) return;

    double atrV[1]; ArraySetAsSeries(atrV, true);
    if(CopyBuffer(hATR_M1, 0, 1, 1, atrV) < 1 || atrV[0] <= 0) return;
    double atr = atrV[0];

    // Spread filter — skip entry if spread is too wide vs ATR
    if(InpUseSpread)
    {
        double spread = SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                      - SymbolInfoDouble(_Symbol, SYMBOL_BID);
        if(spread > InpMaxSpreadATR * atr) return;
    }

    double lot     = InpBaseLot * MathPow(2.0, martLevel);
    double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    double lotMin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double lotMax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    lot = MathMax(lotMin, MathMin(lotMax, MathRound(lot / lotStep) * lotStep));

    if(bull)
    {
        double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        double sl    = price - InpSL_ATR * atr;
        double tp    = price + InpTP_ATR * atr;
        if(trade.Buy(lot, _Symbol, price, sl, tp, "GodBot Scalper BUY"))
        {
            lastDir      = 1;
            lastEntryBar = curBar;
            PrintFormat("BUY  | lot=%.2f (lvl %d) | %.5f | SL=%.5f TP=%.5f | H1 TS=%d",
                        lot, martLevel, price, sl, tp, tsScore);
        }
    }
    else
    {
        double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        double sl    = price + InpSL_ATR * atr;
        double tp    = price - InpTP_ATR * atr;
        if(trade.Sell(lot, _Symbol, price, sl, tp, "GodBot Scalper SELL"))
        {
            lastDir      = -1;
            lastEntryBar = curBar;
            PrintFormat("SELL | lot=%.2f (lvl %d) | %.5f | SL=%.5f TP=%.5f | H1 TS=%d",
                        lot, martLevel, price, sl, tp, tsScore);
        }
    }
}
