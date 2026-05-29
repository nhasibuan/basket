//+------------------------------------------------------------------+
//|                          DDR Custom Assistant (Refactored 3.0)   |
//|                                       Copyright © 2024           |
//|                                  https://wa.me/+628811230359     |
//+------------------------------------------------------------------+
//
//  PURPOSE
//  ----------------------------------------------------------------
//  This EA does NOT open trades. It manages orders that already
//  exist on the current chart symbol:
//    - locks profit on selected legs with an ATR-based stop, and
//    - closes groups of orders (pair / triple) once their COMBINED
//      net profit reaches a per-lot money target.
//
//  ARCHITECTURE (single-file, modular)
//  ----------------------------------------------------------------
//   1. Inputs            - user-tunable parameters (grouped)
//   2. Globals/Constants - module-wide state and named constants
//   3. Logger            - Print() helper with prefix
//   4. Errors / Trade    - retry-safe close & modify wrappers
//   5. OrderState        - data struct + reset/validate helpers
//   6. Scanner           - finds extreme orders (No.1 / No.2)
//   7. Pricing           - spread helpers (price delta + money cost)
//   8. ATR Stop Loss     - profit-zone SL, spread- & StopLevel-aware
//   9. Closer            - basket close (atomic-ish, retry, verified)
//  10. License           - account / expiry validation
//  11. GUI               - dashboard build & update
//  12. Lifecycle         - OnInit / OnDeinit / OnTick
//
//  STRATEGIES (legs are chosen from the Scanner result)
//   1) BUY-BUY    PAIR   : buyHigh + buyLow(No.2)
//   2) SELL-SELL  PAIR   : sellLow + sellHigh(No.2)
//   3) SELL-BUY   TRIPLE : buyHigh + sellHigh(No.2) + sellHighAbs(No.1)
//   4) BUY-SELL   TRIPLE : buyLow(No.2) + buyLowAbs(No.1) + sellLow
//
//  ATR SL applied to: buyHigh, buyLow(No.2), sellLow, sellHigh(No.2).
//  NOT applied to:    buyLowAbs(No.1), sellHighAbs(No.1)  (anchors).
//
//  CORRECTNESS NOTES (fixes vs. 2.0)
//  ----------------------------------------------------------------
//  * Strategies share legs (e.g. buyHigh is used by S1 and S3). To
//    avoid acting on a stale snapshot, AT MOST ONE basket is closed
//    per tick; after a close we return and re-scan on the next tick.
//  * Basket close verifies every leg and retries transient errors;
//    partial closes are logged and re-evaluated next tick.
//  * Stop-loss prices are normalized with NormalizeDouble().
//  * ATR stop is optional (it can desync baskets if a single leg is
//    stopped out independently); see InpEnableATRStop.
//  * The spread "safety buffer" added to the target is optional and
//    documented; see InpAddSpreadBuffer.
//+------------------------------------------------------------------+
#property copyright  "Copyright © 2024"
#property link       "https://wa.me/+628811230359"
#property version    "3.00"
#property strict
#property description "Manages existing orders. Pair/triple closes on combined profit."

//==================================================================
// 1. INPUTS
//==================================================================
input group "=== General ==="
input int    InpMagicNumber   = 0;          // Magic filter (0 = all symbol orders)
input int    InpSlippagePts    = 30;        // OrderClose slippage (points)
input int    InpGuiUpdateSecs  = 1;         // GUI refresh interval (seconds)
input int    InpRetryCount     = 3;         // Trade retry attempts on transient errors
input int    InpRetryDelayMs   = 200;       // Delay between retries (ms, live only)
input bool   InpAddSpreadBuffer= true;      // Add spread cost as a safety buffer to target

input group "=== Strategy 1: BUY-BUY (PAIR) ==="
input bool   InpEnable_BB     = true;       // Enable BUY-BUY
input double InpProfit_BB     = 1.5;        // Target $ per lot

input group "=== Strategy 2: SELL-SELL (PAIR) ==="
input bool   InpEnable_SS     = true;       // Enable SELL-SELL
input double InpProfit_SS     = 1.5;        // Target $ per lot

input group "=== Strategy 3: SELL-BUY (TRIPLE) ==="
input bool   InpEnable_SB     = true;       // Enable SELL-BUY
input double InpProfit_SB     = 0.5;        // Target $ per lot

input group "=== Strategy 4: BUY-SELL (TRIPLE) ==="
input bool   InpEnable_BS     = true;       // Enable BUY-SELL
input double InpProfit_BS     = 0.5;        // Target $ per lot

input group "=== ATR Stop Loss ==="
input bool            InpEnableATRStop  = true;     // Enable ATR profit-lock SL
input int             InpATR_Period     = 14;       // ATR period
input ENUM_TIMEFRAMES InpATR_Timeframe  = PERIOD_H1;// ATR timeframe
input double          InpATR_Multiplier = 1.0;      // ATR multiplier

//==================================================================
// 2. GLOBALS & CONSTANTS
//==================================================================
//--- License (hard-coded; intentionally NOT input) ----------------
const int    LIC_ACCOUNT_ID  = 0;            // 0 = any account
const string LIC_EXPIRE_DATE = "2026.12.01"; // YYYY.MM.DD

//--- GUI styling --------------------------------------------------
//   GUI_FONT_SZ is a macro because MQL4 default-args accept only
//   literals/macros (a const int is not allowed there).
#define GUI_FONT_SZ 11

const string GUI_PREFIX  = "DDR_";
const int    GUI_X_LEFT  = 20;
const int    GUI_X_RIGHT = 280;
const int    GUI_LINE_H  = 20;
const int    GUI_GROUP_H = 30;
const string GUI_FONT    = "Consolas";

//--- Logger -------------------------------------------------------
const string LOG_PREFIX  = "[DDR] ";

//--- Runtime state ------------------------------------------------
double   g_PointAdj   = 0;   // point normalized for 3/5-digit brokers
datetime g_ExpireTs   = 0;
datetime g_LastGuiTs  = 0;

//==================================================================
// 3. LOGGER
//==================================================================
void Log(const string msg) { Print(LOG_PREFIX, msg); }

//==================================================================
// 4. ERRORS / TRADE WRAPPERS
//==================================================================
// Transient errors worth retrying within the same tick.
bool Trade_IsRetryableError(const int err)
  {
   switch(err)
     {
      case 4:    // server busy
      case 128:  // trade timeout
      case 129:  // invalid price
      case 135:  // price changed
      case 136:  // off quotes
      case 137:  // broker busy
      case 138:  // requote
      case 146:  // trade context busy
         return true;
     }
   return false;
  }

void Trade_Pause()
  {
   if(!IsTesting() && InpRetryDelayMs > 0)
      Sleep(InpRetryDelayMs);
  }

//+------------------------------------------------------------------+
//| Close one ticket with verification + retry on transient errors.  |
//| Returns true if the order is closed (or was already closed).     |
//+------------------------------------------------------------------+
bool Trade_CloseTicket(const int ticket)
  {
   if(ticket < 0)
      return false;

   for(int attempt = 1; attempt <= InpRetryCount; attempt++)
     {
      if(!OrderSelect(ticket, SELECT_BY_TICKET))
        {
         Log(StringFormat("Close: ticket %d not found (err=%d)", ticket, GetLastError()));
         return false;
        }
      if(OrderCloseTime() != 0)
         return true; // already closed elsewhere

      if(!IsTradeAllowed())
        {
         Log("Close: trading not allowed; will retry next tick");
         return false;
        }

      RefreshRates();
      const double cp = (OrderType() == OP_BUY) ? Bid : Ask;
      if(OrderClose(ticket, OrderLots(), cp, InpSlippagePts, clrNONE))
         return true;

      const int err = GetLastError();
      if(!Trade_IsRetryableError(err))
        {
         Log(StringFormat("Close FAILED ticket=%d err=%d (non-retryable)", ticket, err));
         return false;
        }
      Log(StringFormat("Close retry %d/%d ticket=%d err=%d", attempt, InpRetryCount, ticket, err));
      Trade_Pause();
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Modify only the stop-loss, with retry. err==1 (no changes) = OK. |
//+------------------------------------------------------------------+
bool Trade_ModifyStopLoss(const int ticket, const double openPrice,
                          const double newSL, const bool isBuy)
  {
   for(int attempt = 1; attempt <= InpRetryCount; attempt++)
     {
      if(!OrderSelect(ticket, SELECT_BY_TICKET))
         return false;
      if(OrderCloseTime() != 0)
         return false;
      if(!IsTradeAllowed())
         return false;

      RefreshRates();
      const color clr = isBuy ? clrGreen : clrRed;
      if(OrderModify(ticket, NormalizeDouble(openPrice, _Digits), newSL,
                     OrderTakeProfit(), 0, clr))
        {
         Log(StringFormat("ATR SL set %s ticket=%d sl=%s",
                          (isBuy ? "BUY" : "SELL"), ticket,
                          DoubleToString(newSL, _Digits)));
         return true;
        }

      const int err = GetLastError();
      if(err == 1) // ERR_NO_RESULT: nothing changed
         return true;
      if(!Trade_IsRetryableError(err))
        {
         Log(StringFormat("ATR SL FAILED ticket=%d err=%d", ticket, err));
         return false;
        }
      Trade_Pause();
     }
   return false;
  }

//==================================================================
// 5. ORDERSTATE STRUCT
//==================================================================
struct OrderState
  {
   int               ticket;
   double            price;
   double            lots;
   double            profit;   // net: profit + commission + swap
   int               type;     // OP_BUY / OP_SELL

   bool              IsValid() const { return ticket != -1; }
  };

void OrderState_Reset(OrderState &s, const double initPrice)
  {
   s.ticket = -1;
   s.price  = initPrice;
   s.lots   = 0;
   s.profit = 0;
   s.type   = -1;
  }

// Copies the CURRENTLY selected order into the struct.
void OrderState_FillFromCurrent(OrderState &s)
  {
   s.ticket = OrderTicket();
   s.price  = OrderOpenPrice();
   s.lots   = OrderLots();
   s.profit = OrderProfit() + OrderCommission() + OrderSwap();
   s.type   = OrderType();
  }

//==================================================================
// 6. SCANNER
//==================================================================
struct ScanResult
  {
   OrderState        buyHigh;       // highest Buy
   OrderState        buyLow;        // 2nd-lowest Buy (No.2, runner-up)
   OrderState        buyLowAbs;     // lowest Buy (No.1, most extreme)
   OrderState        sellLow;       // lowest Sell
   OrderState        sellHigh;      // 2nd-highest Sell (No.2, runner-up)
   OrderState        sellHighAbs;   // highest Sell (No.1, most extreme)
  };

void Scanner_Init(ScanResult &r)
  {
   OrderState_Reset(r.buyHigh,     0);
   OrderState_Reset(r.buyLow,      DBL_MAX);
   OrderState_Reset(r.buyLowAbs,   DBL_MAX);
   OrderState_Reset(r.sellLow,     DBL_MAX);
   OrderState_Reset(r.sellHigh,    0);
   OrderState_Reset(r.sellHighAbs, 0);
  }

bool Scanner_PassesFilter()
  {
   if(OrderSymbol() != _Symbol)
      return false;
   if(InpMagicNumber != 0 && OrderMagicNumber() != InpMagicNumber)
      return false;
   if(OrderType() != OP_BUY && OrderType() != OP_SELL)
      return false;
   return true;
  }

void Scanner_HandleBuy(ScanResult &r, const double price)
  {
   // Highest Buy
   if(price > r.buyHigh.price)
      OrderState_FillFromCurrent(r.buyHigh);

   // Two lowest Buys (rolling No.1 / No.2)
   if(price < r.buyLowAbs.price)
     {
      r.buyLow = r.buyLowAbs;             // demote old champion to runner-up
      OrderState_FillFromCurrent(r.buyLowAbs);
     }
   else
      if(price < r.buyLow.price)
         OrderState_FillFromCurrent(r.buyLow);
  }

void Scanner_HandleSell(ScanResult &r, const double price)
  {
   // Lowest Sell
   if(price < r.sellLow.price)
      OrderState_FillFromCurrent(r.sellLow);

   // Two highest Sells (rolling No.1 / No.2)
   if(price > r.sellHighAbs.price)
     {
      r.sellHigh = r.sellHighAbs;         // demote old champion to runner-up
      OrderState_FillFromCurrent(r.sellHighAbs);
     }
   else
      if(price > r.sellHigh.price)
         OrderState_FillFromCurrent(r.sellHigh);
  }

void Scanner_Run(ScanResult &r)
  {
   Scanner_Init(r);
   const int total = OrdersTotal();
   for(int i = 0; i < total; i++)
     {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(!Scanner_PassesFilter())
         continue;

      const double price = OrderOpenPrice();
      if(OrderType() == OP_BUY)
         Scanner_HandleBuy(r, price);
      else
         Scanner_HandleSell(r, price);
     }
  }

//==================================================================
// 7. PRICING (spread helpers)
//==================================================================
double Spread_PriceDelta()
  {
   return Ask - Bid;
  }

// Spread cost in account currency for a given total lots.
double Spread_CostMoney(const double lots)
  {
   const double spreadPts = MarketInfo(_Symbol, MODE_SPREAD);
   const double tickValue = MarketInfo(_Symbol, MODE_TICKVALUE);
   return spreadPts * tickValue * lots;
  }

//==================================================================
// 8. ATR STOP LOSS
//==================================================================
double Atr_Value()
  {
   return iATR(_Symbol, InpATR_Timeframe, InpATR_Period, 1);
  }

double Atr_StopLevelDist()
  {
   return MarketInfo(_Symbol, MODE_STOPLEVEL) * _Point;
  }

bool Atr_NeedsModifyBuy(const double newSL, const double currentSL,
                        const double bid, const double stopLvl)
  {
   if(bid - newSL < stopLvl)
      return false; // broker rejects: SL too close / above Bid
   if(currentSL >= newSL)
      return false; // ratchet: SL already tighter
   return true;
  }

bool Atr_NeedsModifySell(const double newSL, const double currentSL,
                         const double ask, const double stopLvl)
  {
   if(newSL - ask < stopLvl)
      return false;
   if(currentSL > 0 && currentSL <= newSL)
      return false;
   return true;
  }

void Atr_ApplyTo(OrderState &order)
  {
   if(!InpEnableATRStop)
      return;
   if(!order.IsValid())
      return;
   if(!OrderSelect(order.ticket, SELECT_BY_TICKET))
      return;
   if(OrderCloseTime() != 0)
      return;

   const double atr = Atr_Value();
   if(atr <= 0)
     {
      Log("ATR warning: atr<=0 (skip ticket=" + IntegerToString(order.ticket) + ")");
      return;
     }

   const bool   isBuy       = (order.type == OP_BUY);
   const double openPrice   = order.price;
   const double spreadPrice = Spread_PriceDelta();
   // SL placed in the profit zone, ATR + spread away from entry.
   const double slDist      = InpATR_Multiplier * atr + spreadPrice;
   const double newSL       = NormalizeDouble(isBuy ? openPrice + slDist
                                              : openPrice - slDist, _Digits);
   const double currentSL   = OrderStopLoss();
   const double stopLvl     = Atr_StopLevelDist();

   const bool ok = isBuy
                   ? Atr_NeedsModifyBuy(newSL, currentSL, Bid, stopLvl)
                   : Atr_NeedsModifySell(newSL, currentSL, Ask, stopLvl);
   if(!ok)
      return;

   Trade_ModifyStopLoss(order.ticket, openPrice, newSL, isBuy);
  }

void Atr_ApplyAll(ScanResult &r)
  {
   Atr_ApplyTo(r.buyHigh);
   Atr_ApplyTo(r.buyLow);
   Atr_ApplyTo(r.sellLow);
   Atr_ApplyTo(r.sellHigh);
  }

//==================================================================
// 9. CLOSER
//==================================================================
bool Closer_DistinctValid2(OrderState &a, OrderState &b)
  {
   return a.IsValid() && b.IsValid() && a.ticket != b.ticket;
  }

bool Closer_DistinctValid3(OrderState &a, OrderState &b, OrderState &c)
  {
   if(!Closer_DistinctValid2(a, b))
      return false;
   if(!c.IsValid())
      return false;
   return c.ticket != a.ticket && c.ticket != b.ticket;
  }

// Closes every leg in the basket, verifying each. Logs the result.
// Returns true because the basket was eligible and an attempt was made
// (the caller stops evaluating further strategies this tick).
bool Closer_CloseBasket(const int &tickets[], const string name,
                        const double totalProfit, const double targetMoney,
                        const double spreadCost, const double totalLots)
  {
   RefreshRates();
   const int n = ArraySize(tickets);
   int closed = 0;
   for(int i = 0; i < n; i++)
      if(Trade_CloseTicket(tickets[i]))
         closed++;

   Log(StringFormat("Basket %s | closed %d/%d | profit=%s target=%s spread=%s lots=%s",
                    name, closed, n,
                    DoubleToString(totalProfit, 2),
                    DoubleToString(targetMoney, 2),
                    DoubleToString(spreadCost,  2),
                    DoubleToString(totalLots,   2)));

   if(closed < n)
      Log(StringFormat("WARNING: basket %s partially closed (%d/%d); "
                       "remaining legs re-evaluated next tick.", name, closed, n));
   return true;
  }

bool Closer_TryPair(OrderState &o1, OrderState &o2,
                    const double targetPerLot, const string name)
  {
   if(!Closer_DistinctValid2(o1, o2))
      return false;

   const double totalLots   = o1.lots   + o2.lots;
   const double totalProfit = o1.profit + o2.profit;
   const double spreadCost  = InpAddSpreadBuffer ? Spread_CostMoney(totalLots) : 0.0;
   const double targetMoney = targetPerLot * totalLots + spreadCost;
   if(totalProfit < targetMoney)
      return false;

   int tickets[2];
   tickets[0] = o1.ticket;
   tickets[1] = o2.ticket;
   return Closer_CloseBasket(tickets, name, totalProfit, targetMoney, spreadCost, totalLots);
  }

bool Closer_TryTriple(OrderState &o1, OrderState &o2, OrderState &o3,
                      const double targetPerLot, const string name)
  {
   if(!Closer_DistinctValid3(o1, o2, o3))
      return false;

   const double totalLots   = o1.lots   + o2.lots   + o3.lots;
   const double totalProfit = o1.profit + o2.profit + o3.profit;
   const double spreadCost  = InpAddSpreadBuffer ? Spread_CostMoney(totalLots) : 0.0;
   const double targetMoney = targetPerLot * totalLots + spreadCost;
   if(totalProfit < targetMoney)
      return false;

   int tickets[3];
   tickets[0] = o1.ticket;
   tickets[1] = o2.ticket;
   tickets[2] = o3.ticket;
   return Closer_CloseBasket(tickets, name, totalProfit, targetMoney, spreadCost, totalLots);
  }

// At most ONE basket per tick: after a close we return so the next
// tick re-scans fresh state (legs are shared across strategies).
void Strategies_Run(ScanResult &r)
  {
   if(InpEnable_BB && Closer_TryPair(r.buyHigh, r.buyLow,   InpProfit_BB, "BUY-BUY"))
      return;
   if(InpEnable_SS && Closer_TryPair(r.sellLow, r.sellHigh, InpProfit_SS, "SELL-SELL"))
      return;
   if(InpEnable_SB && Closer_TryTriple(r.buyHigh, r.sellHigh, r.sellHighAbs, InpProfit_SB, "SELL-BUY"))
      return;
   if(InpEnable_BS && Closer_TryTriple(r.buyLow,  r.buyLowAbs, r.sellLow,    InpProfit_BS, "BUY-SELL"))
      return;
  }

//==================================================================
// 10. LICENSE
//==================================================================
bool License_Check()
  {
   if(g_ExpireTs > 0 && TimeCurrent() >= g_ExpireTs)
     {
      Comment("EA EXPIRED! Contact Admin.");
      return false;
     }
   if(LIC_ACCOUNT_ID > 0 && AccountNumber() != LIC_ACCOUNT_ID)
     {
      Comment("ACCOUNT NOT REGISTERED! Contact Admin.");
      return false;
     }
   return true;
  }

//==================================================================
// 11. GUI
//==================================================================
void Gui_CreateLabel(const string id, const int x, const int y, const string text,
                     const color clr = clrWhite, const int fsz = GUI_FONT_SZ)
  {
   const string full = GUI_PREFIX + id;
   if(ObjectFind(0, full) == -1)
     {
      ObjectCreate(0, full, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, full, OBJPROP_CORNER,    CORNER_LEFT_UPPER);
      ObjectSetInteger(0, full, OBJPROP_XDISTANCE, x);
      ObjectSetInteger(0, full, OBJPROP_YDISTANCE, y);
      ObjectSetString(0, full, OBJPROP_FONT,       GUI_FONT);
      ObjectSetInteger(0, full, OBJPROP_FONTSIZE,  fsz);
      ObjectSetInteger(0, full, OBJPROP_COLOR,     clr);
     }
   ObjectSetString(0, full, OBJPROP_TEXT, text);
  }

void Gui_SetText(const string id, const string text)
  {
   ObjectSetString(0, GUI_PREFIX + id, OBJPROP_TEXT, text);
  }

void Gui_SetColor(const string id, const color clr)
  {
   ObjectSetInteger(0, GUI_PREFIX + id, OBJPROP_COLOR, clr);
  }

void Gui_Build()
  {
   int x = GUI_X_LEFT;
   int y = GUI_LINE_H;

   // Header
   Gui_CreateLabel("Spread", x, y, "Spread: ");
   y += GUI_LINE_H;
   Gui_CreateLabel("ATR",    x, y, "ATR: ", clrYellow);
   y += GUI_GROUP_H;

   const int yStrategiesStart = y;

   // Left column
   Gui_CreateLabel("S1_Title", x, y, "STRATEGY 1: BUY-BUY",   clrAqua);
   y += GUI_LINE_H;
   Gui_CreateLabel("S1_BH",    x, y, "Buy  High  : ");
   y += GUI_LINE_H;
   Gui_CreateLabel("S1_BL",    x, y, "Buy  Lo(2) : ");
   y += GUI_LINE_H;
   Gui_CreateLabel("S1_P",     x, y, "Profit     : $0.00");
   y += GUI_GROUP_H;

   Gui_CreateLabel("S2_Title", x, y, "STRATEGY 2: SELL-SELL", clrAqua);
   y += GUI_LINE_H;
   Gui_CreateLabel("S2_SL",    x, y, "Sell Low   : ");
   y += GUI_LINE_H;
   Gui_CreateLabel("S2_SH",    x, y, "Sell Hi(2) : ");
   y += GUI_LINE_H;
   Gui_CreateLabel("S2_P",     x, y, "Profit     : $0.00");

   // Right column
   x = GUI_X_RIGHT;
   y = yStrategiesStart;

   Gui_CreateLabel("S3_Title", x, y, "STRATEGY 3: SELL-BUY",  clrAqua);
   y += GUI_LINE_H;
   Gui_CreateLabel("S3_BH",    x, y, "Buy  High  : ");
   y += GUI_LINE_H;
   Gui_CreateLabel("S3_SH2",   x, y, "Sell Hi(2) : ");
   y += GUI_LINE_H;
   Gui_CreateLabel("S3_SH1",   x, y, "Sell Hi(1) : ");
   y += GUI_LINE_H;
   Gui_CreateLabel("S3_P",     x, y, "Profit     : $0.00");
   y += GUI_GROUP_H;

   Gui_CreateLabel("S4_Title", x, y, "STRATEGY 4: BUY-SELL",  clrAqua);
   y += GUI_LINE_H;
   Gui_CreateLabel("S4_BL2",   x, y, "Buy  Lo(2) : ");
   y += GUI_LINE_H;
   Gui_CreateLabel("S4_BL1",   x, y, "Buy  Lo(1) : ");
   y += GUI_LINE_H;
   Gui_CreateLabel("S4_SL",    x, y, "Sell Low   : ");
   y += GUI_LINE_H;
   Gui_CreateLabel("S4_P",     x, y, "Profit     : $0.00");
  }

string Gui_PriceText(const string label, OrderState &o)
  {
   return label + (o.IsValid() ? DoubleToString(o.price, _Digits) : "N/A");
  }

void Gui_SetProfit(const string id, const double p, const bool valid)
  {
   Gui_SetText(id, "Profit     : $" + DoubleToString(valid ? p : 0, 2));
   Gui_SetColor(id, p >= 0 ? clrLime : clrRed);
  }

void Gui_Update(ScanResult &r)
  {
   const double spread = (Ask - Bid) / g_PointAdj;
   const double atr    = Atr_Value();

   Gui_SetText("Spread", "Spread: " + DoubleToString(spread, 1) + " pips");
   Gui_SetText("ATR",    StringFormat("ATR x%s: %s",
                                      DoubleToString(InpATR_Multiplier, 2),
                                      DoubleToString(atr * InpATR_Multiplier, _Digits)));

   // Strategy 1: BUY-BUY (pair)
   Gui_SetText("S1_BH", Gui_PriceText("Buy  High  : ", r.buyHigh));
   Gui_SetText("S1_BL", Gui_PriceText("Buy  Lo(2) : ", r.buyLow));
   const bool s1ok = r.buyHigh.IsValid() && r.buyLow.IsValid();
   Gui_SetProfit("S1_P", s1ok ? r.buyHigh.profit + r.buyLow.profit : 0, s1ok);

   // Strategy 2: SELL-SELL (pair)
   Gui_SetText("S2_SL", Gui_PriceText("Sell Low   : ", r.sellLow));
   Gui_SetText("S2_SH", Gui_PriceText("Sell Hi(2) : ", r.sellHigh));
   const bool s2ok = r.sellLow.IsValid() && r.sellHigh.IsValid();
   Gui_SetProfit("S2_P", s2ok ? r.sellLow.profit + r.sellHigh.profit : 0, s2ok);

   // Strategy 3: SELL-BUY (triple)
   Gui_SetText("S3_BH",  Gui_PriceText("Buy  High  : ", r.buyHigh));
   Gui_SetText("S3_SH2", Gui_PriceText("Sell Hi(2) : ", r.sellHigh));
   Gui_SetText("S3_SH1", Gui_PriceText("Sell Hi(1) : ", r.sellHighAbs));
   const bool s3ok = r.buyHigh.IsValid() && r.sellHigh.IsValid() && r.sellHighAbs.IsValid();
   Gui_SetProfit("S3_P", s3ok ? r.buyHigh.profit + r.sellHigh.profit + r.sellHighAbs.profit : 0, s3ok);

   // Strategy 4: BUY-SELL (triple)
   Gui_SetText("S4_BL2", Gui_PriceText("Buy  Lo(2) : ", r.buyLow));
   Gui_SetText("S4_BL1", Gui_PriceText("Buy  Lo(1) : ", r.buyLowAbs));
   Gui_SetText("S4_SL",  Gui_PriceText("Sell Low   : ", r.sellLow));
   const bool s4ok = r.buyLow.IsValid() && r.buyLowAbs.IsValid() && r.sellLow.IsValid();
   Gui_SetProfit("S4_P", s4ok ? r.buyLow.profit + r.buyLowAbs.profit + r.sellLow.profit : 0, s4ok);

   ChartRedraw(0);
  }

void Gui_MaybeUpdate(ScanResult &r)
  {
   if(TimeCurrent() - g_LastGuiTs < InpGuiUpdateSecs)
      return;
   Gui_Update(r);
   g_LastGuiTs = TimeCurrent();
  }

void Gui_Destroy() { ObjectsDeleteAll(0, GUI_PREFIX); }

//==================================================================
// 12. LIFECYCLE
//==================================================================
int OnInit()
  {
   if(InpATR_Period <= 0 || InpATR_Multiplier <= 0)
     {
      Log("Invalid ATR parameters.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpRetryCount < 1)
     {
      Log("InpRetryCount must be >= 1.");
      return INIT_PARAMETERS_INCORRECT;
     }

   g_PointAdj = _Point;
   if(_Digits == 3 || _Digits == 5)
      g_PointAdj *= 10;

   g_ExpireTs  = StringToTime(LIC_EXPIRE_DATE);
   g_LastGuiTs = 0;

   Gui_Build();
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   Gui_Destroy();
   Comment("");
  }

void OnTick()
  {
   if(!License_Check())
      return;

   RefreshRates();

   ScanResult r;
   Scanner_Run(r);

   // ATR profit-lock SL (No.1 anchors are intentionally excluded).
   Atr_ApplyAll(r);

   // Dashboard (throttled).
   Gui_MaybeUpdate(r);

   // Close at most one basket per tick (shared legs -> fresh re-scan next tick).
   Strategies_Run(r);
  }
//+------------------------------------------------------------------+
