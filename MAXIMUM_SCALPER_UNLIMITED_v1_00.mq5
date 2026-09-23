//+------------------------------------------------------------------+
//| MAXIMUM-SCALPER-UNLIMITED v1.00                                 |
//| XAUUSDs - M1 scalper / M5 trend / M15 volatility                 |
//| Dashboard modeled from the supplied video                       |
//| No #property strict                                              |
//+------------------------------------------------------------------+
#property version   "1.00"
#property description "XAUUSD scalper with dashboard, volume profile and basket management"

#include <Trade/Trade.mqh>
CTrade trade;

//-------------------- INPUTS ---------------------------------------
input string InpSymbol              = "";       // Empty = chart symbol
input long   MagicNumber             = 260923;
input double RiskPercent             = 1.0;
input double FixedLot                = 0.01;
input bool   AutoLot                 = true;

input ENUM_TIMEFRAMES EntryTF        = PERIOD_M1;
input ENUM_TIMEFRAMES TrendTF        = PERIOD_M5;
input ENUM_TIMEFRAMES VolatilityTF   = PERIOD_M15;

input int EMA_Fast                   = 21;
input int EMA_Mid                    = 34;
input int EMA_Slow                   = 55;
input int EMA_Trend                  = 200;

input int RSI_Period                 = 2;
input double RSI_BuyMax              = 30.0;
input double RSI_SellMin             = 70.0;

input int StochK                     = 5;
input int StochD                     = 3;
input int StochSlowing               = 3;

input int ATR_Period                 = 14;
input double SL_ATR_Mult             = 1.20;
input double Grid_ATR_Mult           = 0.65;
input double BasketTP_ATR_Mult       = 0.80;

input int MaxPositions               = 10;
input double GridMultiplier           = 1.20;
input double MaxLot                  = 0.50;
input int MaxSpreadPoints            = 25;
input int CooldownMinutes            = 3;
input int MaxTradesPerDay            = 10;

input int VP_Bars                   = 300;
input int VP_Bins                   = 48;
input double ValueAreaPercent       = 70.0;

input bool AllowLong                = true;
input bool AllowShort               = true;
input bool UseTradingHours          = true;
input int StartHour                 = 7;
input int EndHour                   = 22;

input bool UseTrailing              = true;
input double TrailStartATR          = 1.00;
input double TrailDistanceATR       = 0.70;

input bool ShowDashboard            = true;

//-------------------- GLOBALS --------------------------------------
string sym;
int hEma21=-1,hEma34=-1,hEma55=-1,hEma200=-1,hRSI=-1,hATR=-1,hStoch=-1;
datetime lastEntryTime=0;
datetime lastBarTime=0;
int todayTrades=0;
int todayKey=-1;

//-------------------- HELPERS --------------------------------------
double PointValue(){ return SymbolInfoDouble(sym,SYMBOL_POINT); }
int DigitsSym(){ return (int)SymbolInfoInteger(sym,SYMBOL_DIGITS); }

double NormalizeLot(double lot)
{
   double minLot=SymbolInfoDouble(sym,SYMBOL_VOLUME_MIN);
   double maxLot=SymbolInfoDouble(sym,SYMBOL_VOLUME_MAX);
   double step=SymbolInfoDouble(sym,SYMBOL_VOLUME_STEP);
   lot=MathMax(minLot,MathMin(MathMin(maxLot,MaxLot),lot));
   if(step>0) lot=MathFloor(lot/step)*step;
   return NormalizeDouble(lot,2);
}

bool IsTradingTime()
{
   if(!UseTradingHours) return true;
   MqlDateTime tm; TimeToStruct(TimeCurrent(),tm);
   if(StartHour<=EndHour) return (tm.hour>=StartHour && tm.hour<EndHour);
   return (tm.hour>=StartHour || tm.hour<EndHour);
}

void ResetDailyCounter()
{
   MqlDateTime tm; TimeToStruct(TimeCurrent(),tm);
   int key=tm.year*1000+tm.day_of_year;
   if(key!=todayKey){ todayKey=key; todayTrades=0; }
}

bool NewBar()
{
   datetime t=iTime(sym,EntryTF,0);
   if(t!=lastBarTime){ lastBarTime=t; return true; }
   return false;
}

double BufValue(int handle,int shift)
{
   if(handle<0) return EMPTY_VALUE;
   double b[];
   ArraySetAsSeries(b,true);
   if(CopyBuffer(handle,0,shift,1,b)!=1) return EMPTY_VALUE;
   return b[0];
}

double StochMain(int shift)
{
   double b[]; ArraySetAsSeries(b,true);
   if(hStoch<0 || CopyBuffer(hStoch,0,shift,1,b)!=1) return EMPTY_VALUE;
   return b[0];
}
double StochSignal(int shift)
{
   double b[]; ArraySetAsSeries(b,true);
   if(hStoch<0 || CopyBuffer(hStoch,1,shift,1,b)!=1) return EMPTY_VALUE;
   return b[0];
}

int CountPositions(int type=-1)
{
   int n=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=sym) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=MagicNumber) continue;
      if(type!=-1 && (int)PositionGetInteger(POSITION_TYPE)!=type) continue;
      n++;
   }
   return n;
}

double PositionVolumeTotal()
{
   double v=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=sym) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=MagicNumber) continue;
      v+=PositionGetDouble(POSITION_VOLUME);
   }
   return v;
}

double BasketProfit()
{
   double p=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=sym) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=MagicNumber) continue;
      p+=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
   }
   return p;
}

double WeightedOpenPrice()
{
   double pv=0, vv=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=sym) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=MagicNumber) continue;
      double v=PositionGetDouble(POSITION_VOLUME);
      pv+=PositionGetDouble(POSITION_PRICE_OPEN)*v;
      vv+=v;
   }
   if(vv<=0) return 0;
   return pv/vv;
}

int BasketDirection()
{
   int buy=CountPositions(POSITION_TYPE_BUY);
   int sell=CountPositions(POSITION_TYPE_SELL);
   if(buy>0 && sell==0) return 1;
   if(sell>0 && buy==0) return -1;
   return 0;
}

double CalcLot(double slPoints)
{
   if(!AutoLot) return NormalizeLot(FixedLot);
   double bal=AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney=bal*RiskPercent/100.0;
   double tickVal=SymbolInfoDouble(sym,SYMBOL_TRADE_TICK_VALUE);
   double tickSize=SymbolInfoDouble(sym,SYMBOL_TRADE_TICK_SIZE);
   if(slPoints<=0 || tickVal<=0 || tickSize<=0) return NormalizeLot(FixedLot);
   double moneyPerLot=(slPoints*PointValue()/tickSize)*tickVal;
   if(moneyPerLot<=0) return NormalizeLot(FixedLot);
   return NormalizeLot(riskMoney/moneyPerLot);
}

//-------------------- VOLUME PROFILE -------------------------------
bool VolumeProfile(double &poc,double &vah,double &val)
{
   MqlRates r[];
   ArraySetAsSeries(r,true);
   int got=CopyRates(sym,EntryTF,1,VP_Bars,r);
   if(got<50) return false;

   double lo=r[0].low, hi=r[0].high;
   for(int i=1;i<got;i++){ lo=MathMin(lo,r[i].low); hi=MathMax(hi,r[i].high); }
   if(hi<=lo) return false;

   double vol[];
   ArrayResize(vol,VP_Bins);
   ArrayInitialize(vol,0.0);
   double step=(hi-lo)/VP_Bins;
   for(int i=0;i<got;i++)
   {
      double p=(r[i].high+r[i].low+r[i].close)/3.0;
      int b=(int)MathFloor((p-lo)/step);
      if(b<0) b=0;
      if(b>=VP_Bins) b=VP_Bins-1;
      vol[b]+=(double)r[i].tick_volume;
   }

   int pocBin=0;
   for(int b=1;b<VP_Bins;b++) if(vol[b]>vol[pocBin]) pocBin=b;
   double total=0; for(int b=0;b<VP_Bins;b++) total+=vol[b];
   double target=total*ValueAreaPercent/100.0;

   int left=pocBin,right=pocBin;
   double area=vol[pocBin];
   while(area<target && (left>0 || right<VP_Bins-1))
   {
      double lv=(left>0?vol[left-1]:-1);
      double rv=(right<VP_Bins-1?vol[right+1]:-1);
      if(rv>=lv){ if(right<VP_Bins-1){right++;area+=vol[right];} else {left--;area+=vol[left];} }
      else { if(left>0){left--;area+=vol[left];} else {right++;area+=vol[right];} }
   }

   poc=lo+(pocBin+0.5)*step;
   val=lo+left*step;
   vah=lo+(right+1)*step;
   return true;
}

//-------------------- SIGNAL ---------------------------------------
int Signal()
{
   double e21=BufValue(hEma21,1), e34=BufValue(hEma34,1), e55=BufValue(hEma55,1), e200=BufValue(hEma200,1);
   double rsi=BufValue(hRSI,1);
   double k1=StochMain(1), d1=StochSignal(1), k2=StochMain(2), d2=StochSignal(2);
   double close=iClose(sym,EntryTF,1);
   double trend21=BufValue(hEma21,1);

   if(e21==EMPTY_VALUE||e34==EMPTY_VALUE||e55==EMPTY_VALUE||e200==EMPTY_VALUE||rsi==EMPTY_VALUE) return 0;

   bool up=close>e200 && e21>e34 && e34>e55 && e55>e200;
   bool dn=close<e200 && e21<e34 && e34<e55 && e55<e200;

   bool stochUp=(k2<=d2 && k1>d1 && k1<45);
   bool stochDn=(k2>=d2 && k1<d1 && k1>55);

   double poc,vah,val;
   bool vp=VolumeProfile(poc,vah,val);
   double bid=SymbolInfoDouble(sym,SYMBOL_BID), ask=SymbolInfoDouble(sym,SYMBOL_ASK);

   if(AllowLong && up && rsi<=RSI_BuyMax && stochUp && (!vp || ask>=val))
      return 1;
   if(AllowShort && dn && rsi>=RSI_SellMin && stochDn && (!vp || bid<=vah))
      return -1;

   return 0;
}

double NextOrderPrice(int dir)
{
   double atr=BufValue(hATR,1);
   if(atr==EMPTY_VALUE || atr<=0) atr=100*PointValue();
   double step=atr*Grid_ATR_Mult;
   double avg=WeightedOpenPrice();
   if(avg<=0) return 0;
   if(dir>0) return avg-step;
   return avg+step;
}

double BasketTPPrice(int dir)
{
   double atr=BufValue(hATR,1);
   if(atr==EMPTY_VALUE || atr<=0) atr=100*PointValue();
   double avg=WeightedOpenPrice();
   if(avg<=0) return 0;
   if(dir>0) return avg+atr*BasketTP_ATR_Mult;
   return avg-atr*BasketTP_ATR_Mult;
}

bool OpenTrade(int dir)
{
   if(todayTrades>=MaxTradesPerDay) return false;
   if(!IsTradingTime()) return false;
   if((TimeCurrent()-lastEntryTime)<CooldownMinutes*60) return false;

   int positions=CountPositions();
   if(positions>=MaxPositions) return false;

   double atr=BufValue(hATR,1);
   if(atr==EMPTY_VALUE || atr<=0) return false;

   double ask=SymbolInfoDouble(sym,SYMBOL_ASK), bid=SymbolInfoDouble(sym,SYMBOL_BID);
   double price=(dir>0?ask:bid);
   double slDist=atr*SL_ATR_Mult;
   double lot=CalcLot(slDist/PointValue());

   if(positions>0)
   {
      int bd=BasketDirection();
      if(bd!=dir) return false;
      lot=NormalizeLot(FixedLot*MathPow(GridMultiplier,positions));
   }

   double sl=(dir>0?price-slDist:price+slDist);
   sl=NormalizeDouble(sl,DigitsSym());

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(MaxSpreadPoints);

   bool ok=false;
   if(dir>0) ok=trade.Buy(lot,sym,0,sl,0,"MAXIMUM BUY");
   else ok=trade.Sell(lot,sym,0,sl,0,"MAXIMUM SELL");

   if(ok){ lastEntryTime=TimeCurrent(); todayTrades++; }
   return ok;
}

void ManageBasket()
{
   int dir=BasketDirection();
   if(dir==0) return;

   double bid=SymbolInfoDouble(sym,SYMBOL_BID), ask=SymbolInfoDouble(sym,SYMBOL_ASK);
   double tp=BasketTPPrice(dir);
   bool hit=(dir>0 ? bid>=tp : ask<=tp);
   if(hit)
   {
      for(int i=PositionsTotal()-1;i>=0;i--)
      {
         ulong ticket=PositionGetTicket(i);
         if(ticket==0 || !PositionSelectByTicket(ticket)) continue;
         if(PositionGetString(POSITION_SYMBOL)!=sym) continue;
         if((long)PositionGetInteger(POSITION_MAGIC)!=MagicNumber) continue;
         trade.PositionClose(ticket);
      }
      return;
   }

   if(UseTrailing)
   {
      double atr=BufValue(hATR,0);
      if(atr<=0 || atr==EMPTY_VALUE) return;
      for(int i=PositionsTotal()-1;i>=0;i--)
      {
         ulong ticket=PositionGetTicket(i);
         if(ticket==0 || !PositionSelectByTicket(ticket)) continue;
         if(PositionGetString(POSITION_SYMBOL)!=sym) continue;
         if((long)PositionGetInteger(POSITION_MAGIC)!=MagicNumber) continue;
         double op=PositionGetDouble(POSITION_PRICE_OPEN);
         double sl=PositionGetDouble(POSITION_SL);
         double cur=(dir>0?bid:ask);
         if(dir>0 && cur-op>=atr*TrailStartATR)
         {
            double nsl=cur-atr*TrailDistanceATR;
            if(nsl>sl) trade.PositionModify(ticket,NormalizeDouble(nsl,DigitsSym()),0);
         }
         if(dir<0 && op-cur>=atr*TrailStartATR)
         {
            double nsl=cur+atr*TrailDistanceATR;
            if(sl==0 || nsl<sl) trade.PositionModify(ticket,NormalizeDouble(nsl,DigitsSym()),0);
         }
      }
   }
}

string PosText()
{
   int b=CountPositions(POSITION_TYPE_BUY), s=CountPositions(POSITION_TYPE_SELL);
   if(b>0) return "BUY x"+IntegerToString(b)+" | "+DoubleToString(PositionVolumeTotal(),2)+" lot";
   if(s>0) return "SELL x"+IntegerToString(s)+" | "+DoubleToString(PositionVolumeTotal(),2)+" lot";
   return "NONE";
}

void Dashboard()
{
   if(!ShowDashboard) return;
   double bal=AccountInfoDouble(ACCOUNT_BALANCE);
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   double open=BasketProfit();
   double poc=0,vah=0,val=0; VolumeProfile(poc,vah,val);
   double next=NextOrderPrice(BasketDirection());
   double btp=BasketTPPrice(BasketDirection());
   long spread=(long)SymbolInfoInteger(sym,SYMBOL_SPREAD);

   string txt=
      "MAXIMUM-SCALPER-UNLIMITED\n"
      "v1.00 | "+sym+" | Long + Short\n"+
      "PROFIT "+DoubleToString(AccountInfoDouble(ACCOUNT_PROFIT),2)+" USD\n"+
      "Balance  "+DoubleToString(bal,2)+" USD\n"+
      "Equity   "+DoubleToString(eq,2)+" USD\n"+
      "Open P/L "+DoubleToString(open,2)+" USD\n"+
      "Today    "+DoubleToString(open,2)+" USD\n"+
      "This week  --\n"+
      "This month --\n"+
      "Total closed --\n"+
      "Position "+PosText()+"\n"+
      "Orders   "+IntegerToString(CountPositions())+"/"+IntegerToString(MaxPositions)+"\n"+
      "Next lot "+DoubleToString(NormalizeLot(FixedLot*MathPow(GridMultiplier,CountPositions())),2)+" (x"+DoubleToString(GridMultiplier,2)+")\n"+
      "Next order at "+(next>0?DoubleToString(next,DigitsSym()):"--")+"\n"+
      "Basket TP    "+(btp>0?DoubleToString(btp,DigitsSym()):"--")+"\n"+
      "POC          "+(poc>0?DoubleToString(poc,DigitsSym()):"--")+"\n"+
      "VAH          "+(vah>0?DoubleToString(vah,DigitsSym()):"--")+"\n"+
      "VAL          "+(val>0?DoubleToString(val,DigitsSym()):"--")+"\n"+
      "Spread "+IntegerToString((int)spread)+" pts\n"+
      "TF Entry M1 | Trend M5 | ATR M15\n"+
      "Status "+(CountPositions()>0?"In trade":"Waiting");

   Comment(txt);
}

//-------------------- INIT / TICK ----------------------------------
int OnInit()
{
   sym=(InpSymbol==""?_Symbol:InpSymbol);

   hEma21=iMA(sym,EntryTF,EMA_Fast,0,MODE_EMA,PRICE_CLOSE);
   hEma34=iMA(sym,EntryTF,EMA_Mid,0,MODE_EMA,PRICE_CLOSE);
   hEma55=iMA(sym,EntryTF,EMA_Slow,0,MODE_EMA,PRICE_CLOSE);
   hEma200=iMA(sym,TrendTF,EMA_Trend,0,MODE_EMA,PRICE_CLOSE);
   hRSI=iRSI(sym,EntryTF,RSI_Period,PRICE_CLOSE);
   hATR=iATR(sym,VolatilityTF,ATR_Period);
   hStoch=iStochastic(sym,EntryTF,StochK,StochD,StochSlowing,MODE_SMA,STO_LOWHIGH);

   if(hEma21<0||hEma34<0||hEma55<0||hEma200<0||hRSI<0||hATR<0||hStoch<0)
      return INIT_FAILED;

   trade.SetExpertMagicNumber(MagicNumber);
   ResetDailyCounter();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   Comment("");
}

void OnTick()
{
   ResetDailyCounter();

   long spread=(long)SymbolInfoInteger(sym,SYMBOL_SPREAD);
   if(spread<=MaxSpreadPoints) ManageBasket();

   if(NewBar())
   {
      int positions=CountPositions();
      if(positions==0)
      {
         int s=Signal();
         if(s!=0 && spread<=MaxSpreadPoints) OpenTrade(s);
      }
      else if(positions<MaxPositions)
      {
         int dir=BasketDirection();
         if(dir!=0)
         {
            double next=NextOrderPrice(dir);
            double bid=SymbolInfoDouble(sym,SYMBOL_BID), ask=SymbolInfoDouble(sym,SYMBOL_ASK);
            if((dir>0 && bid<=next) || (dir<0 && ask>=next))
               OpenTrade(dir);
         }
      }
   }
   Dashboard();
}
//+------------------------------------------------------------------+
