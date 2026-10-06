//+------------------------------------------------------------------+
//| MAXIMUM-SCALPER-UNLIMITED H4 STRUCTURE V1.07                    |
//| BTCUSD M5 execution / H4 structure                               |
//| H4: lowest confirmed swing = BUY, highest confirmed swing = SELL |
//| M5: Fibonacci entry 1.70, SL -1.00, TP 3/5/7/9/11/21            |
//| No #property strict                                              |
//+------------------------------------------------------------------+
#property version "1.10"
#property description "BTC H4 structure + M5 Fibonacci 1.70 six-position basket"

#include <Trade/Trade.mqh>
CTrade trade;

input string InpSymbol="";
input long MagicNumber=26100601;
input ENUM_TIMEFRAMES StructureTF=PERIOD_H1;
input ENUM_TIMEFRAMES EntryTF=PERIOD_M5;

input int SwingDepth=2;
input int LookbackBars=120;

input double LotsPerPosition=0.01;
input int PositionsCount=6;
input double EntryLevel=1.70;
input double SLLevel=-1.00;
input double TP1Level=3.00;
input double TP2Level=5.00;
input double TP3Level=7.00;
input double TP4Level=9.00;
input double TP5Level=11.00;
input double TP6Level=21.00;
input double SLSpreadBufferPoints=5.0;

input int MaxSpreadPoints=0; // 0 = no spread filter
input bool UseBreakEven=true;
input bool UseFibTrailing=true;
input bool RequireHedgingAccount=false;
input bool ShowDashboard=true;
input bool MarketIfFibAlreadyPassed=true;
input bool EnterOnH4ExtremeRetest=true;
input double RetestTolerancePoints=300.0;
input double MinRetraceFromExtremePercent=10.0;
input bool DrawStructureLevels=true;
input int StructureLookback=120;

string sym;
int lockedDirection=0;
double activeP0=0.0,activeP1=0.0,activeEntry=0.0,activeSL=0.0;
datetime activeExtremeTime=0;
int activeExtremeShift=-1;
bool setupPlaced=false;
bool retestArmed=false;
datetime lastH4Bar=0;

double Pt(){return SymbolInfoDouble(sym,SYMBOL_POINT);}
int Dig(){return (int)SymbolInfoInteger(sym,SYMBOL_DIGITS);}
double N(double p){return NormalizeDouble(p,Dig());}

int CountPositions(int type=-1)
{
   int n=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i);
      if(t==0 || !PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=sym) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=MagicNumber) continue;
      if(type!=-1 && (int)PositionGetInteger(POSITION_TYPE)!=type) continue;
      n++;
   }
   return n;
}

int CountOrders()
{
   int n=0;
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      ulong t=OrderGetTicket(i);
      if(t==0) continue;
      if(OrderGetString(ORDER_SYMBOL)!=sym) continue;
      if((long)OrderGetInteger(ORDER_MAGIC)!=MagicNumber) continue;
      n++;
   }
   return n;
}

bool IsSwingHigh(int shift)
{
   double h=iHigh(sym,StructureTF,shift);
   if(h<=0) return false;
   for(int k=1;k<=SwingDepth;k++)
   {
      if(h<=iHigh(sym,StructureTF,shift-k)) return false;
      if(h<=iHigh(sym,StructureTF,shift+k)) return false;
   }
   return true;
}

bool IsSwingLow(int shift)
{
   double l=iLow(sym,StructureTF,shift);
   if(l<=0) return false;
   for(int k=1;k<=SwingDepth;k++)
   {
      if(l>=iLow(sym,StructureTF,shift-k)) return false;
      if(l>=iLow(sym,StructureTF,shift+k)) return false;
   }
   return true;
}

bool FindLowestSwing(double &price,datetime &tm,int &shift)
{
   price=DBL_MAX; tm=0; shift=-1;
   int bars=Bars(sym,StructureTF);
   int maxShift=MathMin(LookbackBars,bars-SwingDepth-2);
   for(int s=SwingDepth+1;s<=maxShift;s++)
   {
      if(!IsSwingLow(s)) continue;
      double p=iLow(sym,StructureTF,s);
      if(p<price){price=p;tm=iTime(sym,StructureTF,s);shift=s;}
   }
   return shift>0;
}

bool FindHighestSwing(double &price,datetime &tm,int &shift)
{
   price=-DBL_MAX; tm=0; shift=-1;
   int bars=Bars(sym,StructureTF);
   int maxShift=MathMin(LookbackBars,bars-SwingDepth-2);
   for(int s=SwingDepth+1;s<=maxShift;s++)
   {
      if(!IsSwingHigh(s)) continue;
      double p=iHigh(sym,StructureTF,s);
      if(p>price){price=p;tm=iTime(sym,StructureTF,s);shift=s;}
   }
   return shift>0;
}

// After BUY finishes, search for the highest H4 swing formed after the active low.
// After SELL finishes, search for the lowest H4 swing formed after the active high.
// This prevents the EA from getting stuck on the previous side.

// V1.01: last confirmed H4 swing helpers.
bool FindLatestSwingLow(double &price,datetime &tm,int &shift)
{
   price=0.0; tm=0; shift=-1;
   int bars=Bars(sym,StructureTF);
   int maxShift=MathMin(LookbackBars,bars-SwingDepth-2);
   for(int s=SwingDepth+1;s<=maxShift;s++)
   {
      if(IsSwingLow(s))
      {
         price=iLow(sym,StructureTF,s);
         tm=iTime(sym,StructureTF,s);
         shift=s;
         return true;
      }
   }
   return false;
}

bool FindLatestSwingHigh(double &price,datetime &tm,int &shift)
{
   price=0.0; tm=0; shift=-1;
   int bars=Bars(sym,StructureTF);
   int maxShift=MathMin(LookbackBars,bars-SwingDepth-2);
   for(int s=SwingDepth+1;s<=maxShift;s++)
   {
      if(IsSwingHigh(s))
      {
         price=iHigh(sym,StructureTF,s);
         tm=iTime(sym,StructureTF,s);
         shift=s;
         return true;
      }
   }
   return false;
}

int DetermineDirection(double &p0,double &p1,datetime &tm,int &sh)
{
   MqlRates r[]; ArraySetAsSeries(r,true);
   int n=CopyRates(sym,StructureTF,0,LookbackBars+5,r);
   if(n<10) return 0;
   double low=DBL_MAX,high=-DBL_MAX; datetime lowT=0,highT=0; int lowS=-1,highS=-1;
   // Most recent local H4 turning points.
   for(int s=2;s<n-1;s++)
   {
      if(highT==0 && r[s].high>r[s-1].high && r[s].high>r[s+1].high){high=r[s].high;highT=r[s].time;highS=s;}
      if(lowT==0 && r[s].low<r[s-1].low && r[s].low<r[s+1].low){low=r[s].low;lowT=r[s].time;lowS=s;}
   }
   // Fallback to latest closed H4 bar extremes.
   if(highT==0){high=r[1].high;highT=r[1].time;highS=1;}
   if(lowT==0){low=r[1].low;lowT=r[1].time;lowS=1;}

   if(lockedDirection==1)
   {
      if(highT>activeExtremeTime){p0=high;p1=low;tm=highT;sh=highS;return -1;}
      p0=activeP0;p1=activeP1;tm=activeExtremeTime;sh=activeExtremeShift;return 1;
   }
   if(lockedDirection==-1)
   {
      if(lowT>activeExtremeTime){p0=low;p1=high;tm=lowT;sh=lowS;return 1;}
      p0=activeP0;p1=activeP1;tm=activeExtremeTime;sh=activeExtremeShift;return -1;
   }
   if(lowT>highT){p0=low;p1=high;tm=lowT;sh=lowS;return 1;}
   p0=high;p1=low;tm=highT;sh=highS;return -1;
}

void DeletePending()
{
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      ulong t=OrderGetTicket(i);
      if(t==0) continue;
      if(OrderGetString(ORDER_SYMBOL)!=sym) continue;
      if((long)OrderGetInteger(ORDER_MAGIC)!=MagicNumber) continue;
      trade.OrderDelete(t);
   }
}

void CloseBasket()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i);
      if(t==0 || !PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=sym) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=MagicNumber) continue;
      trade.PositionClose(t);
   }
   DeletePending();
}

bool ValidStopDistance(double price,double sl,int dir)
{
   long stops=(long)SymbolInfoInteger(sym,SYMBOL_TRADE_STOPS_LEVEL);
   double minDist=stops*Pt();
   if(dir>0) return price-sl>=minDist;
   return sl-price>=minDist;
}

double Lot()
{
   double mn=SymbolInfoDouble(sym,SYMBOL_VOLUME_MIN);
   double mx=SymbolInfoDouble(sym,SYMBOL_VOLUME_MAX);
   double st=SymbolInfoDouble(sym,SYMBOL_VOLUME_STEP);
   double v=MathMax(mn,MathMin(mx,LotsPerPosition));
   if(st>0) v=MathFloor(v/st)*st;
   return NormalizeDouble(v,2);
}

bool PlaceBasket(int dir,double p0,double p1,datetime dirExtremeTime,int dirExtremeShift)
{
   double range=MathAbs(p1-p0);
   if(range<=0) return false;
   double entry,sl,tp1,tp2,tp3,tp4,tp5,tp6;
   if(dir>0)
   {
      entry=EnterOnH4ExtremeRetest ? p0 : p0+range*EntryLevel;
      sl=p0+range*SLLevel-SLSpreadBufferPoints*Pt();
      tp1=p0+range*TP1Level; tp2=p0+range*TP2Level; tp3=p0+range*TP3Level;
      tp4=p0+range*TP4Level; tp5=p0+range*TP5Level; tp6=p0+range*TP6Level;
   }
   else
   {
      entry=EnterOnH4ExtremeRetest ? p0 : p0-range*EntryLevel;
      sl=p0-range*SLLevel+SLSpreadBufferPoints*Pt();
      tp1=p0-range*TP1Level; tp2=p0-range*TP2Level; tp3=p0-range*TP3Level;
      tp4=p0-range*TP4Level; tp5=p0-range*TP5Level; tp6=p0-range*TP6Level;
   }
   entry=N(entry); sl=N(sl); tp1=N(tp1); tp2=N(tp2); tp3=N(tp3); tp4=N(tp4); tp5=N(tp5); tp6=N(tp6);

   DeletePending();
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(MaxSpreadPoints);
   trade.SetTypeFillingBySymbol(sym);

   double lot=Lot();
   bool okAll=true;

   // For the H4 retest model we do NOT use a limit order. We arm the setup,
   // wait for price to move away from the extreme, then enter at market when
   // price returns within RetestTolerancePoints of that H4 extreme.
   lockedDirection=dir;
   activeP0=p0; activeP1=p1; activeEntry=entry; activeSL=sl;
   activeExtremeTime=dirExtremeTime; activeExtremeShift=dirExtremeShift;
   setupPlaced=true;
   retestArmed=false;

   Print("H1 RETEST ARMED ",(dir>0?"BUY LOW":"SELL HIGH"),
         " P0=",DoubleToString(p0,Dig()),
         " P1=",DoubleToString(p1,Dig()),
         " tolerance=",DoubleToString(RetestTolerancePoints,0),
         " points");
   return true;
}

bool ExecuteRetestIfReady()
{
   if(!EnterOnH4ExtremeRetest || !setupPlaced || retestArmed==false) return false;
   if(CountPositions()>0) return false;

   double ask=SymbolInfoDouble(sym,SYMBOL_ASK);
   double bid=SymbolInfoDouble(sym,SYMBOL_BID);
   double tol=RetestTolerancePoints*Pt();
   double range=MathAbs(activeP1-activeP0);
   if(range<=0) return false;

   bool hit=(lockedDirection>0 ? bid<=activeP0+tol : ask>=activeP0-tol);
   if(!hit) return false;

   double sl,tp1,tp2;
   if(lockedDirection>0)
   {
      sl=activeP0+range*SLLevel-SLSpreadBufferPoints*Pt();
      tp1=activeP0+range*TP1Level; tp2=activeP0+range*TP2Level;
   }
   else
   {
      sl=activeP0-range*SLLevel+SLSpreadBufferPoints*Pt();
      tp1=activeP0-range*TP1Level; tp2=activeP0-range*TP2Level;
   }
   sl=N(sl); tp1=N(tp1); tp2=N(tp2);

   double lot=Lot();
   bool all=true;
   for(int i=1;i<=PositionsCount;i++)
   {
      double tp=(i==1?tp1:((i==2||i==3)?tp2:0.0));
      bool ok=(lockedDirection>0 ? trade.Buy(lot,sym,0.0,sl,tp,"H4 LOW RETEST BUY")
                                 : trade.Sell(lot,sym,0.0,sl,tp,"H4 HIGH RETEST SELL"));
      uint rc=trade.ResultRetcode();
      if(!ok || (rc!=TRADE_RETCODE_DONE && rc!=TRADE_RETCODE_PLACED))
      {
         Print("RETEST MARKET ",i," FAILED ",rc," ",trade.ResultRetcodeDescription());
         all=false;
      }
   }
   if(all)
   {
      activeEntry=(lockedDirection>0?ask:bid);
      retestArmed=false;
      Print("H4 RETEST EXECUTED ",(lockedDirection>0?"BUY":"SELL"),
            " at ",DoubleToString(activeEntry,Dig()));
   }
   return all;
}

void ModifyAllStops(double newSL)
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i);
      if(t==0 || !PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=sym) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=MagicNumber) continue;

      long typ=PositionGetInteger(POSITION_TYPE);
      double oldSL=PositionGetDouble(POSITION_SL);
      double tp=PositionGetDouble(POSITION_TP);
      bool improve=(typ==POSITION_TYPE_BUY ? (oldSL==0 || newSL>oldSL)
                                          : (oldSL==0 || newSL<oldSL));
      if(improve) trade.PositionModify(t,N(newSL),tp);
   }
}

double CurrentExtremePrice()
{
   return lockedDirection>0 ? SymbolInfoDouble(sym,SYMBOL_BID)
                             : SymbolInfoDouble(sym,SYMBOL_ASK);
}

void ManageBasket()
{
   int pos=CountPositions();
   int ord=CountOrders();

   if(pos==0 && ord==0)
   {
      if(setupPlaced)
      {
         // The basket is finished. Unlock only now, then look for the opposite H4 dirP0.
         setupPlaced=false;
      }
      return;
   }

   if(pos==0 && ord>0) return;

   if(lockedDirection==0 || activeP0==0 || activeP1==0) return;

   double range=MathAbs(activeP1-activeP0);
   if(range<=0) return;

   double p3,p4,p5,p6;
   if(lockedDirection>0)
   {
      p3=activeP0+range*TP3Level;
      p4=activeP0+range*TP4Level;
      p5=activeP0+range*TP5Level;
      p6=activeP0+range*TP6Level;
   }
   else
   {
      p3=activeP0-range*TP3Level;
      p4=activeP0-range*TP4Level;
      p5=activeP0-range*TP5Level;
      p6=activeP0-range*TP6Level;
   }

   double cur=CurrentExtremePrice();

   // TP2 has already closed positions #2 and #3. Move remaining positions to BE.
   double tp2=lockedDirection>0 ? activeP0+range*TP2Level : activeP0-range*TP2Level;
   if(UseBreakEven)
   {
      bool hit2=(lockedDirection>0 ? cur>=tp2 : cur<=tp2);
      if(hit2) ModifyAllStops(activeEntry);
   }

   // TP3 -> SL at TP2; TP4 -> SL at TP3; TP5 -> SL at TP4; TP6 -> SL at TP5.
   if(UseFibTrailing)
   {
      if((lockedDirection>0 && cur>=p3) || (lockedDirection<0 && cur<=p3))
         ModifyAllStops(tp2);

      double tp3=p3;
      if((lockedDirection>0 && cur>=p4) || (lockedDirection<0 && cur<=p4))
         ModifyAllStops(tp3);

      double tp4=p4;
      if((lockedDirection>0 && cur>=p5) || (lockedDirection<0 && cur<=p5))
         ModifyAllStops(tp4);

      double tp5=p5;
      if((lockedDirection>0 && cur>=p6) || (lockedDirection<0 && cur<=p6))
         ModifyAllStops(tp5);
   }
}

void DetectAndPlace()
{
   if(CountPositions()>0 || CountOrders()>0) return;

   long spread=(long)SymbolInfoInteger(sym,SYMBOL_SPREAD);
   if(MaxSpreadPoints>0 && spread>MaxSpreadPoints) return;

   double dirP0,dirP1; datetime tm; int sh;
   int dir=DetermineDirection(dirP0,dirP1,tm,sh);
   if(dir==0) return;

   // BUY: p0 is the H4 low, p1 is the most important high.
   // SELL: p0 is the H4 high, p1 is the most important low.
   double p0=dirP0,p1=dirP1;

   // For reversal we require a genuinely new dirP0 relative to the active setup.
   if(lockedDirection==1 && dir==1 && tm<=activeExtremeTime) return;
   if(lockedDirection==-1 && dir==-1 && tm<=activeExtremeTime) return;

   PlaceBasket(dir,p0,p1,tm,sh);
}

void DrawH1Structure()
{
   if(!DrawStructureLevels) return;
   ObjectsDeleteAll(0,"H1STRUCT_");
   MqlRates r[]; ArraySetAsSeries(r,true);
   int n=CopyRates(sym,StructureTF,0,StructureLookback+5,r);
   if(n<10) return;

   double hi=-DBL_MAX,lo=DBL_MAX; datetime ht=0,lt=0;
   for(int s=1;s<n;s++)
   {
      if(r[s].high>hi){hi=r[s].high;ht=r[s].time;}
      if(r[s].low<lo){lo=r[s].low;lt=r[s].time;}
   }

   string hn="H1STRUCT_HIGH";
   ObjectCreate(0,hn,OBJ_HLINE,0,0,hi);
   ObjectSetInteger(0,hn,OBJPROP_COLOR,clrRed);
   ObjectSetInteger(0,hn,OBJPROP_STYLE,STYLE_DASH);
   ObjectSetString(0,hn,OBJPROP_TEXT,"H1 HIGH "+DoubleToString(hi,Dig()));

   string ln="H1STRUCT_LOW";
   ObjectCreate(0,ln,OBJ_HLINE,0,0,lo);
   ObjectSetInteger(0,ln,OBJPROP_COLOR,clrLime);
   ObjectSetInteger(0,ln,OBJPROP_STYLE,STYLE_DASH);
   ObjectSetString(0,ln,OBJPROP_TEXT,"H1 LOW "+DoubleToString(lo,Dig()));

   // Mark every local H1 turning point so we can visually verify what EA catches.
   int mark=0;
   for(int s=2;s<n-1;s++)
   {
      bool sh=(r[s].high>r[s-1].high && r[s].high>r[s+1].high);
      bool sl=(r[s].low<r[s-1].low && r[s].low<r[s+1].low);
      if(sh || sl)
      {
         string nm="H1STRUCT_"+IntegerToString(mark++);
         ObjectCreate(0,nm,OBJ_ARROW,0,r[s].time,sh?r[s].high:r[s].low);
         ObjectSetInteger(0,nm,OBJPROP_ARROWCODE,sh?234:233);
         ObjectSetInteger(0,nm,OBJPROP_COLOR,sh?clrRed:clrLime);
      }
   }
}

void Dashboard()
{
   if(!ShowDashboard) return;
   string d=lockedDirection>0?"BUY":(lockedDirection<0?"SELL":"WAIT");
   Comment("MAXIMUM-SCALPER-UNLIMITED H4 STRUCTURE V1.10\n",
           sym," | Structure H4 / Entry M5 (DIRECT H4 EXTREMES)\n",
           "Direction: ",d," | Positions: ",CountPositions(),
           " | Pending: ",CountOrders(),"\n",
           "H4 P0: ",DoubleToString(activeP0,Dig()),
           " | P1: ",DoubleToString(activeP1,Dig()),"\n",
           "Entry 1.70 | SL -1 | TP 3/5/7/9/11/21\n",
           "Extreme time: ",(activeExtremeTime>0?TimeToString(activeExtremeTime,TIME_DATE|TIME_MINUTES):"-"));
}

int OnInit()
{
   sym=(InpSymbol==""?_Symbol:InpSymbol);
   if(RequireHedgingAccount)
   {
      ENUM_ACCOUNT_MARGIN_MODE mode=(ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);
      if(mode!=ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
      {
         Print("ERROR: six separate positions require a HEDGING account.");
         return INIT_FAILED;
      }
   }
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFillingBySymbol(sym);
   SymbolSelect(sym,true);
   MqlRates preload[];
   ArraySetAsSeries(preload,true);
   CopyRates(sym,StructureTF,0,LookbackBars+5,preload);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason){Comment("");}

void OnTick()
{
   ManageBasket();

   if(setupPlaced && CountPositions()==0 && CountOrders()==0)
   {
      double ask=SymbolInfoDouble(sym,SYMBOL_ASK);
      double bid=SymbolInfoDouble(sym,SYMBOL_BID);
      double range=MathAbs(activeP1-activeP0);
      if(range>0)
      {
         double away=range*(MinRetraceFromExtremePercent/100.0);
         if(lockedDirection>0 && bid>=activeP0+away) retestArmed=true;
         if(lockedDirection<0 && ask<=activeP0-away) retestArmed=true;
      }
      ExecuteRetestIfReady();
   }

   datetime h4=iTime(sym,StructureTF,0);
   if(h4!=lastH4Bar)
   {
      lastH4Bar=h4;
      DetectAndPlace();
   }

   if(CountPositions()==0 && CountOrders()==0 && !setupPlaced)
      DetectAndPlace();

   DrawH1Structure();
   Dashboard();
}//+------------------------------------------------------------------+