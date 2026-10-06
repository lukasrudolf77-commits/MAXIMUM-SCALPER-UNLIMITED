//+------------------------------------------------------------------+
//| MAXIMUM-SCALPER-UNLIMITED H4 STRUCTURE V1.00                    |
//| BTCUSD M5 execution / H4 structure                               |
//| H4: lowest confirmed swing = BUY, highest confirmed swing = SELL |
//| M5: Fibonacci entry 1.70, SL -1.00, TP 3/5/7/9/11/21            |
//| No #property strict                                              |
//+------------------------------------------------------------------+
#property version "1.00"
#property description "BTC H4 structure + M5 Fibonacci 1.70 six-position basket"

#include <Trade/Trade.mqh>
CTrade trade;

input string InpSymbol="";
input long MagicNumber=26100601;
input ENUM_TIMEFRAMES StructureTF=PERIOD_H4;
input ENUM_TIMEFRAMES EntryTF=PERIOD_M5;

input int SwingDepth=3;
input int LookbackBars=240;

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

input int MaxSpreadPoints=2500;
input bool UseBreakEven=true;
input bool UseFibTrailing=true;
input bool RequireHedgingAccount=true;
input bool ShowDashboard=true;

string sym;
int lockedDirection=0;
double activeP0=0.0,activeP1=0.0,activeEntry=0.0,activeSL=0.0;
datetime activeExtremeTime=0;
int activeExtremeShift=-1;
bool setupPlaced=false;
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
int DetermineDirection(double &extreme,double &other,datetime &extremeTime,int &extremeShift)
{
   double low,high; datetime lowT,highT; int lowS,highS;
   if(!FindLowestSwing(low,lowT,lowS) || !FindHighestSwing(high,highT,highS)) return 0;

   if(lockedDirection==1)
   {
      // Reversal BUY -> SELL: highest H4 extreme must be newer than active BUY low.
      if(highT>activeExtremeTime)
      {
         extreme=high; extremeTime=highT; extremeShift=highS;
         other=low; return -1;
      }
      extreme=low; extremeTime=lowT; extremeShift=lowS;
      other=high; return 1;
   }

   if(lockedDirection==-1)
   {
      // Reversal SELL -> BUY: lowest H4 extreme must be newer than active SELL high.
      if(lowT>activeExtremeTime)
      {
         extreme=low; extremeTime=lowT; extremeShift=lowS;
         other=high; return 1;
      }
      extreme=high; extremeTime=highT; extremeShift=highS;
      other=low; return -1;
   }

   // Initial setup: use the more recent important extreme.
   if(lowT>highT)
   {
      extreme=low; other=high; extremeTime=lowT; extremeShift=lowS; return 1;
   }
   extreme=high; other=low; extremeTime=highT; extremeShift=highS; return -1;
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

bool PlaceBasket(int dir,double p0,double p1,datetime extremeTime,int extremeShift)
{
   double range=MathAbs(p1-p0);
   if(range<=0) return false;

   double entry,sl,tp1,tp2,tp3,tp4,tp5,tp6;
   if(dir>0)
   {
      entry=p0+range*EntryLevel;
      sl=p0+range*SLLevel;
      sl-=SLSpreadBufferPoints*Pt();
      tp1=p0+range*TP1Level; tp2=p0+range*TP2Level;
      tp3=p0+range*TP3Level; tp4=p0+range*TP4Level;
      tp5=p0+range*TP5Level; tp6=p0+range*TP6Level;
   }
   else
   {
      entry=p0-range*EntryLevel;
      sl=p0-range*SLLevel;
      sl+=SLSpreadBufferPoints*Pt();
      tp1=p0-range*TP1Level; tp2=p0-range*TP2Level;
      tp3=p0-range*TP3Level; tp4=p0-range*TP4Level;
      tp5=p0-range*TP5Level; tp6=p0-range*TP6Level;
   }

   entry=N(entry); sl=N(sl);
   tp1=N(tp1);tp2=N(tp2);tp3=N(tp3);tp4=N(tp4);tp5=N(tp5);tp6=N(tp6);

   double ask=SymbolInfoDouble(sym,SYMBOL_ASK);
   double bid=SymbolInfoDouble(sym,SYMBOL_BID);
   // A stop order must be beyond current market. If not, this structure is already broken.
   if(dir>0 && entry<=ask) return false;
   if(dir<0 && entry>=bid) return false;
   if(!ValidStopDistance(entry,sl,dir)) return false;

   DeletePending();
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(MaxSpreadPoints);
   trade.SetTypeFillingBySymbol(sym);

   double lot=Lot();
   bool okAll=true;

   for(int i=1;i<=PositionsCount;i++)
   {
      double tp=0.0;
      if(i==1) tp=tp1;
      else if(i==2 || i==3) tp=tp2;

      bool ok=false;
      if(dir>0) ok=trade.BuyStop(lot,entry,sym,sl,tp,ORDER_TIME_GTC,0,"H4FIBO BUY");
      else ok=trade.SellStop(lot,entry,sym,sl,tp,ORDER_TIME_GTC,0,"H4FIBO SELL");

      uint rc=trade.ResultRetcode();
      if(!ok || (rc!=TRADE_RETCODE_DONE && rc!=TRADE_RETCODE_PLACED))
      {
         Print("ORDER ",i," FAILED retcode=",rc," ",trade.ResultRetcodeDescription());
         okAll=false;
      }
   }

   if(okAll)
   {
      lockedDirection=dir;
      activeP0=p0; activeP1=p1; activeEntry=entry; activeSL=sl;
      activeExtremeTime=extremeTime; activeExtremeShift=extremeShift;
      setupPlaced=true;
      Print("H4 STRUCTURE SETUP ",(dir>0?"BUY":"SELL"),
            " extreme=",DoubleToString(activeP0,Dig()),
            " other=",DoubleToString(activeP1,Dig()),
            " ENTRY=",DoubleToString(entry,Dig()),
            " SL=",DoubleToString(sl,Dig()));
   }
   return okAll;
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
         // The basket is finished. Unlock only now, then look for the opposite H4 extreme.
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
   if(spread>MaxSpreadPoints) return;

   double extreme,other; datetime tm; int sh;
   int dir=DetermineDirection(extreme,other,tm,sh);
   if(dir==0) return;

   // BUY: p0 is the H4 low, p1 is the most important high.
   // SELL: p0 is the H4 high, p1 is the most important low.
   double p0=extreme,p1=other;

   // For reversal we require a genuinely new extreme relative to the active setup.
   if(lockedDirection==1 && dir==1 && tm<=activeExtremeTime) return;
   if(lockedDirection==-1 && dir==-1 && tm<=activeExtremeTime) return;

   PlaceBasket(dir,p0,p1,tm,sh);
}

void Dashboard()
{
   if(!ShowDashboard) return;
   string d=lockedDirection>0?"BUY":(lockedDirection<0?"SELL":"WAIT");
   Comment("MAXIMUM-SCALPER-UNLIMITED H4 STRUCTURE V1.00\n",
           sym," | Structure H4 / Entry M5\n",
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
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason){Comment("");}

void OnTick()
{
   ManageBasket();

   datetime h4=iTime(sym,StructureTF,0);
   if(h4!=lastH4Bar)
   {
      lastH4Bar=h4;
      // Structure is evaluated only after a new H4 candle starts,
      // so swing values come from closed/confirmed H4 candles.
      DetectAndPlace();
   }

   // If the basket ended intrabar by SL/TP, allow a new structure on the next tick.
   if(CountPositions()==0 && CountOrders()==0)
      DetectAndPlace();

   Dashboard();
}
//+------------------------------------------------------------------+