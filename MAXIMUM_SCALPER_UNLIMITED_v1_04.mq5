//+------------------------------------------------------------------+
//| MAXIMUM-SCALPER-UNLIMITED v1.04                                 |
//| XAUUSDs - M1 scalper / M5 trend                                 |
//| Reworked entries, controlled entries, tighter SL/TP       |
//| No #property strict                                              |
//+------------------------------------------------------------------+
#property version "1.04"
#property description "XAUUSD M1 scalper with M5 trend, tighter exits and controlled risk"

#include <Trade/Trade.mqh>
CTrade trade;

input string InpSymbol="";
input long MagicNumber=260923;
input double RiskPercent=1.0;
input double FixedLot=0.01;
input bool AutoLot=true;

input ENUM_TIMEFRAMES EntryTF=PERIOD_M1;
input ENUM_TIMEFRAMES TrendTF=PERIOD_M5;
input int EMA_Fast=21;
input int EMA_Mid=34;
input int EMA_Slow=55;
input int EMA_Trend=200;

input int RSI_Period=2;
input double RSI_BuyLevel=30.0;
input double RSI_SellLevel=70.0;
input int StochK=5;
input int StochD=3;
input int StochSlowing=3;

input int ATR_Period=14;
input double SL_ATR_Mult=0.95;
input double TP_ATR_Mult=1.14;

input int MaxPositions=1;
input bool UseAddOnEntries=false;
input double AddOnTriggerATR=0.60;
input double AddOnMinSpacingATR=0.50;
input bool AddOnSameLot=true;

input double MaxLot=0.10;
input int MaxSpreadPoints=25;
input int CooldownMinutes=3;
input int MaxTradesPerDay=10;
input bool UseDailyLossLimit=true;
input double DailyLossLimitPercent=3.0;
input bool UseSuddenMoveFilter=true;
input double SuddenMoveATRMult=2.50;

input bool AllowLong=true;
input bool AllowShort=true;
input bool UseTradingHours=true;
input int StartHour=7;
input int EndHour=22;

input bool UseTrailing=true;
input double TrailStartATR=1.00;
input double TrailDistanceATR=0.45;
input bool UseBreakEven=true;
input double BreakEvenATR=0.70;
input bool ShowDashboard=true;

string sym;
int hEma21=-1,hEma34=-1,hEma55=-1,hEma200=-1,hRSI=-1,hATR=-1,hStoch=-1;
datetime lastEntryTime=0;
int todayTrades=0,todayKey=-1;

double PointValue(){return SymbolInfoDouble(sym,SYMBOL_POINT);}
int DigitsSym(){return (int)SymbolInfoInteger(sym,SYMBOL_DIGITS);}

double NormalizeLot(double lot)
{
 double mn=SymbolInfoDouble(sym,SYMBOL_VOLUME_MIN),mx=SymbolInfoDouble(sym,SYMBOL_VOLUME_MAX),st=SymbolInfoDouble(sym,SYMBOL_VOLUME_STEP);
 lot=MathMax(mn,MathMin(MathMin(mx,MaxLot),lot));
 if(st>0) lot=MathFloor(lot/st)*st;
 return NormalizeDouble(lot,2);
}

bool IsTradingTime()
{
 if(!UseTradingHours)return true;
 MqlDateTime tm;TimeToStruct(TimeCurrent(),tm);
 if(StartHour<=EndHour)return tm.hour>=StartHour&&tm.hour<EndHour;
 return tm.hour>=StartHour||tm.hour<EndHour;
}

void ResetDailyCounter()
{
 MqlDateTime tm;TimeToStruct(TimeCurrent(),tm);
 int k=tm.year*1000+tm.day_of_year;
 if(k!=todayKey){todayKey=k;todayTrades=0;}
}

double BufValue(int h,int shift)
{
 if(h<0)return EMPTY_VALUE;
 double b[];ArraySetAsSeries(b,true);
 if(CopyBuffer(h,0,shift,1,b)!=1)return EMPTY_VALUE;
 return b[0];
}
double StochMain(int shift)
{
 double b[];ArraySetAsSeries(b,true);
 if(hStoch<0||CopyBuffer(hStoch,0,shift,1,b)!=1)return EMPTY_VALUE;
 return b[0];
}
double StochSignal(int shift)
{
 double b[];ArraySetAsSeries(b,true);
 if(hStoch<0||CopyBuffer(hStoch,1,shift,1,b)!=1)return EMPTY_VALUE;
 return b[0];
}

int CountPositions(int type=-1)
{
 int n=0;
 for(int i=PositionsTotal()-1;i>=0;i--)
 {
  ulong t=PositionGetTicket(i);if(t==0||!PositionSelectByTicket(t))continue;
  if(PositionGetString(POSITION_SYMBOL)!=sym||(long)PositionGetInteger(POSITION_MAGIC)!=MagicNumber)continue;
  if(type!=-1&&(int)PositionGetInteger(POSITION_TYPE)!=type)continue;
  n++;
 }
 return n;
}

int BasketDirection()
{
 int b=CountPositions(POSITION_TYPE_BUY),s=CountPositions(POSITION_TYPE_SELL);
 if(b>0&&s==0)return 1;if(s>0&&b==0)return -1;return 0;
}

double CalcLot(double slPoints)
{
 if(!AutoLot)return NormalizeLot(FixedLot);
 double bal=AccountInfoDouble(ACCOUNT_BALANCE),risk=bal*RiskPercent/100.0;
 double tv=SymbolInfoDouble(sym,SYMBOL_TRADE_TICK_VALUE),ts=SymbolInfoDouble(sym,SYMBOL_TRADE_TICK_SIZE);
 if(slPoints<=0||tv<=0||ts<=0)return NormalizeLot(FixedLot);
 double mpl=(slPoints*PointValue()/ts)*tv;
 if(mpl<=0)return NormalizeLot(FixedLot);
 return NormalizeLot(risk/mpl);
}

datetime StartOfDay()
{
 MqlDateTime tm;TimeToStruct(TimeCurrent(),tm);tm.hour=0;tm.min=0;tm.sec=0;return StructToTime(tm);
}

double ClosedPLSince(datetime from)
{
 if(!HistorySelect(from,TimeCurrent()))return 0;
 double total=0;
 for(int i=0;i<HistoryDealsTotal();i++)
 {
  ulong t=HistoryDealGetTicket(i);if(t==0)continue;
  if(HistoryDealGetString(t,DEAL_SYMBOL)!=sym||(long)HistoryDealGetInteger(t,DEAL_MAGIC)!=MagicNumber)continue;
  long e=HistoryDealGetInteger(t,DEAL_ENTRY);
  if(e!=DEAL_ENTRY_OUT&&e!=DEAL_ENTRY_OUT_BY)continue;
  total+=HistoryDealGetDouble(t,DEAL_PROFIT)+HistoryDealGetDouble(t,DEAL_SWAP)+HistoryDealGetDouble(t,DEAL_COMMISSION);
 }
 return total;
}

double GrossProfitSince(datetime from)
{
 if(!HistorySelect(from,TimeCurrent()))return 0;
 double total=0;
 for(int i=0;i<HistoryDealsTotal();i++)
 {
  ulong t=HistoryDealGetTicket(i);if(t==0)continue;
  if(HistoryDealGetString(t,DEAL_SYMBOL)!=sym||(long)HistoryDealGetInteger(t,DEAL_MAGIC)!=MagicNumber)continue;
  long e=HistoryDealGetInteger(t,DEAL_ENTRY);
  if(e!=DEAL_ENTRY_OUT&&e!=DEAL_ENTRY_OUT_BY)continue;
  double p=HistoryDealGetDouble(t,DEAL_PROFIT)+HistoryDealGetDouble(t,DEAL_SWAP)+HistoryDealGetDouble(t,DEAL_COMMISSION);
  if(p>0)total+=p;
 }
 return total;
}
double GrossLossSince(datetime from)
{
 if(!HistorySelect(from,TimeCurrent()))return 0;
 double total=0;
 for(int i=0;i<HistoryDealsTotal();i++)
 {
  ulong t=HistoryDealGetTicket(i);if(t==0)continue;
  if(HistoryDealGetString(t,DEAL_SYMBOL)!=sym||(long)HistoryDealGetInteger(t,DEAL_MAGIC)!=MagicNumber)continue;
  long e=HistoryDealGetInteger(t,DEAL_ENTRY);
  if(e!=DEAL_ENTRY_OUT&&e!=DEAL_ENTRY_OUT_BY)continue;
  double p=HistoryDealGetDouble(t,DEAL_PROFIT)+HistoryDealGetDouble(t,DEAL_SWAP)+HistoryDealGetDouble(t,DEAL_COMMISSION);
  if(p<0)total-=p;
 }
 return total;
}
int ClosedCountSince(datetime from)
{
 if(!HistorySelect(from,TimeCurrent()))return 0;
 int n=0;
 for(int i=0;i<HistoryDealsTotal();i++)
 {
  ulong t=HistoryDealGetTicket(i);if(t==0)continue;
  if(HistoryDealGetString(t,DEAL_SYMBOL)!=sym||(long)HistoryDealGetInteger(t,DEAL_MAGIC)!=MagicNumber)continue;
  long e=HistoryDealGetInteger(t,DEAL_ENTRY);
  if(e==DEAL_ENTRY_OUT||e==DEAL_ENTRY_OUT_BY)n++;
 }
 return n;
}
int WinsSince(datetime from)
{
 if(!HistorySelect(from,TimeCurrent()))return 0;
 int n=0;
 for(int i=0;i<HistoryDealsTotal();i++)
 {
  ulong t=HistoryDealGetTicket(i);if(t==0)continue;
  if(HistoryDealGetString(t,DEAL_SYMBOL)!=sym||(long)HistoryDealGetInteger(t,DEAL_MAGIC)!=MagicNumber)continue;
  long e=HistoryDealGetInteger(t,DEAL_ENTRY);
  if(e!=DEAL_ENTRY_OUT&&e!=DEAL_ENTRY_OUT_BY)continue;
  double p=HistoryDealGetDouble(t,DEAL_PROFIT)+HistoryDealGetDouble(t,DEAL_SWAP)+HistoryDealGetDouble(t,DEAL_COMMISSION);
  if(p>0)n++;
 }
 return n;
}

bool DailyLossBlocked()
{
 if(!UseDailyLossLimit||DailyLossLimitPercent<=0)return false;
 double closed=ClosedPLSince(StartOfDay());
 double start=AccountInfoDouble(ACCOUNT_BALANCE)-closed;
 if(start<=0)return false;
 double floating=0;
 for(int i=PositionsTotal()-1;i>=0;i--)
 {
  ulong t=PositionGetTicket(i);if(t==0||!PositionSelectByTicket(t))continue;
  if(PositionGetString(POSITION_SYMBOL)!=sym||(long)PositionGetInteger(POSITION_MAGIC)!=MagicNumber)continue;
  floating+=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
 }
 return closed+floating<=-(start*DailyLossLimitPercent/100.0);
}

bool SuddenMoveBlocked()
{
 if(!UseSuddenMoveFilter)return false;
 double atr=BufValue(hATR,1);if(atr==EMPTY_VALUE||atr<=0)return false;
 return iHigh(sym,EntryTF,1)-iLow(sym,EntryTF,1)>atr*SuddenMoveATRMult;
}

int Signal()
{
 double e21=BufValue(hEma21,1),e34=BufValue(hEma34,1),e55=BufValue(hEma55,1),e200=BufValue(hEma200,1);
 double e21p=BufValue(hEma21,2),e34p=BufValue(hEma34,2);
 double r1=BufValue(hRSI,1),r2=BufValue(hRSI,2);
 double k1=StochMain(1),d1=StochSignal(1),k2=StochMain(2),d2=StochSignal(2);
 double c1=iClose(sym,EntryTF,1),o1=iOpen(sym,EntryTF,1),c2=iClose(sym,EntryTF,2);
 double tc=iClose(sym,TrendTF,1);
 if(e21==EMPTY_VALUE||e34==EMPTY_VALUE||e55==EMPTY_VALUE||e200==EMPTY_VALUE||r1==EMPTY_VALUE||r2==EMPTY_VALUE||k1==EMPTY_VALUE||d1==EMPTY_VALUE||k2==EMPTY_VALUE||d2==EMPTY_VALUE)return 0;

 bool up=tc>e200&&e21>e34&&e34>e55&&e21>e21p&&e34>e34p;
 bool dn=tc<e200&&e21<e34&&e34<e55&&e21<e21p&&e34<e34p;

 bool pullBuy=iLow(sym,EntryTF,1)<=e21&&c1>e21&&c1>o1&&c2<=e21p;
 bool pullSell=iHigh(sym,EntryTF,1)>=e21&&c1<e21&&c1<o1&&c2>=e21p;

 bool rb=r2<=35.0&&r1>r2;
 bool rs=r2>=65.0&&r1<r2;
 bool sb=k2<=d2&&k1>d1&&k1<60;
 bool ss=k2>=d2&&k1<d1&&k1>40;

 if(AllowLong&&up&&pullBuy&&rb&&sb)return 1;
 if(AllowShort&&dn&&pullSell&&rs&&ss)return -1;
 return 0;
}

double LastEntryPrice(int dir)
{
 double p=0;datetime latest=0;int typ=(dir>0?POSITION_TYPE_BUY:POSITION_TYPE_SELL);
 for(int i=PositionsTotal()-1;i>=0;i--)
 {
  ulong t=PositionGetTicket(i);if(t==0||!PositionSelectByTicket(t))continue;
  if(PositionGetString(POSITION_SYMBOL)!=sym||(long)PositionGetInteger(POSITION_MAGIC)!=MagicNumber)continue;
  if((int)PositionGetInteger(POSITION_TYPE)!=typ)continue;
  datetime ot=(datetime)PositionGetInteger(POSITION_TIME);
  if(ot>=latest){latest=ot;p=PositionGetDouble(POSITION_PRICE_OPEN);}
 }
 return p;
}

bool AddOnMoveOK(int dir)
{
 double atr=BufValue(hATR,1);if(atr==EMPTY_VALUE||atr<=0)return false;
 double last=LastEntryPrice(dir);if(last<=0)return false;
 double bid=SymbolInfoDouble(sym,SYMBOL_BID),ask=SymbolInfoDouble(sym,SYMBOL_ASK);
 if(dir>0)return bid-last>=atr*AddOnTriggerATR;
 return last-ask>=atr*AddOnTriggerATR;
}

bool AddOnSpacingOK(int dir)
{
 double atr=BufValue(hATR,1);if(atr==EMPTY_VALUE||atr<=0)return false;
 double last=LastEntryPrice(dir);
 double bid=SymbolInfoDouble(sym,SYMBOL_BID),ask=SymbolInfoDouble(sym,SYMBOL_ASK);
 if(dir>0)return bid-last>=atr*AddOnMinSpacingATR;
 return last-ask>=atr*AddOnMinSpacingATR;
}

bool OpenTrade(int dir,bool addon)
{
 if(CountPositions()>0||todayTrades>=MaxTradesPerDay||!IsTradingTime())return false;
 if((TimeCurrent()-lastEntryTime)<CooldownMinutes*60||DailyLossBlocked())return false;
 double atr=BufValue(hATR,1);if(atr==EMPTY_VALUE||atr<=0)return false;
 double ask=SymbolInfoDouble(sym,SYMBOL_ASK),bid=SymbolInfoDouble(sym,SYMBOL_BID),price=dir>0?ask:bid;
 double swing=dir>0?iLow(sym,EntryTF,1):iHigh(sym,EntryTF,1);
 for(int i=2;i<=6;i++){if(dir>0)swing=MathMin(swing,iLow(sym,EntryTF,i));else swing=MathMax(swing,iHigh(sym,EntryTF,i));}
 double sl=dir>0?swing-atr*0.15:swing+atr*0.15;
 double dist=MathAbs(price-sl);
 double minDist=atr*0.80,maxDist=atr*1.40;
 if(dist<minDist)sl=dir>0?price-minDist:price+minDist;
 if(dist>maxDist)sl=dir>0?price-maxDist:price+maxDist;
 dist=MathAbs(price-sl);
 double tp=dir>0?price+dist*1.20:price-dist*1.20;
 sl=NormalizeDouble(sl,DigitsSym());tp=NormalizeDouble(tp,DigitsSym());
 double lot=CalcLot(dist/PointValue());
 trade.SetExpertMagicNumber(MagicNumber);trade.SetDeviationInPoints(MaxSpreadPoints);
 bool ok=dir>0?trade.Buy(lot,sym,0,sl,tp,"MAX v1.04 BUY"):trade.Sell(lot,sym,0,sl,tp,"MAX v1.04 SELL");
 if(ok){lastEntryTime=TimeCurrent();todayTrades++;}
 return ok;
}

void ManagePositions()
{
 double atr=BufValue(hATR,0);if(atr==EMPTY_VALUE||atr<=0)return;
 double bid=SymbolInfoDouble(sym,SYMBOL_BID),ask=SymbolInfoDouble(sym,SYMBOL_ASK);
 for(int i=PositionsTotal()-1;i>=0;i--)
 {
  ulong t=PositionGetTicket(i);if(t==0||!PositionSelectByTicket(t))continue;
  if(PositionGetString(POSITION_SYMBOL)!=sym||(long)PositionGetInteger(POSITION_MAGIC)!=MagicNumber)continue;
  long typ=PositionGetInteger(POSITION_TYPE);
  double op=PositionGetDouble(POSITION_PRICE_OPEN),sl=PositionGetDouble(POSITION_SL),cur=(typ==POSITION_TYPE_BUY?bid:ask);
  double move=(typ==POSITION_TYPE_BUY?cur-op:op-cur);
  if(UseBreakEven&&move>=atr*BreakEvenATR)
  {
   double be=typ==POSITION_TYPE_BUY?op+2*PointValue():op-2*PointValue();
   be=NormalizeDouble(be,DigitsSym());
   if(typ==POSITION_TYPE_BUY&&(sl==0||be>sl))trade.PositionModify(t,be,PositionGetDouble(POSITION_TP));
   if(typ==POSITION_TYPE_SELL&&(sl==0||be<sl))trade.PositionModify(t,be,PositionGetDouble(POSITION_TP));
  }
  if(UseTrailing&&move>=atr*TrailStartATR)
  {
   double ns=typ==POSITION_TYPE_BUY?cur-atr*TrailDistanceATR:cur+atr*TrailDistanceATR;
   ns=NormalizeDouble(ns,DigitsSym());
   if(typ==POSITION_TYPE_BUY&&ns>sl)trade.PositionModify(t,ns,PositionGetDouble(POSITION_TP));
   if(typ==POSITION_TYPE_SELL&&(sl==0||ns<sl))trade.PositionModify(t,ns,PositionGetDouble(POSITION_TP));
  }
 }
}

void Dashboard()
{
 if(!ShowDashboard)return;
 double bal=AccountInfoDouble(ACCOUNT_BALANCE),eq=AccountInfoDouble(ACCOUNT_EQUITY);
 double gp=GrossProfitSince(0),gl=GrossLossSince(0),pf=gl>0?gp/gl:0;
 int closed=ClosedCountSince(0),wins=WinsSince(0);double wr=closed>0?100.0*wins/closed:0;
 long spread=(long)SymbolInfoInteger(sym,SYMBOL_SPREAD);
 string status=DailyLossBlocked()?"DAILY LOSS BLOCK":(CountPositions()>0?"IN TRADE":"WAITING");
 Comment("MAXIMUM-SCALPER-UNLIMITED v1.04\n",sym," | M1 / M5\n",
 "Balance ",DoubleToString(bal,2)," | Equity ",DoubleToString(eq,2),"\n",
 "Open P/L ",DoubleToString(eq-bal,2)," | Today ",DoubleToString(ClosedPLSince(StartOfDay()),2),"\n",
 "Closed ",closed," | Win ",DoubleToString(wr,1),"% | PF ",DoubleToString(pf,2),"\n",
 "BUY ",CountPositions(POSITION_TYPE_BUY)," | SELL ",CountPositions(POSITION_TYPE_SELL),
 " | Max ",MaxPositions,"\n","Trades today ",todayTrades,"/",MaxTradesPerDay,
 " | Spread ",spread," pts\n","Status ",status);
}

int OnInit()
{
 sym=(InpSymbol==""?_Symbol:InpSymbol);
 hEma21=iMA(sym,EntryTF,EMA_Fast,0,MODE_EMA,PRICE_CLOSE);
 hEma34=iMA(sym,EntryTF,EMA_Mid,0,MODE_EMA,PRICE_CLOSE);
 hEma55=iMA(sym,EntryTF,EMA_Slow,0,MODE_EMA,PRICE_CLOSE);
 hEma200=iMA(sym,TrendTF,EMA_Trend,0,MODE_EMA,PRICE_CLOSE);
 hRSI=iRSI(sym,EntryTF,RSI_Period,PRICE_CLOSE);
 hATR=iATR(sym,EntryTF,ATR_Period);
 hStoch=iStochastic(sym,EntryTF,StochK,StochD,StochSlowing,MODE_SMA,STO_LOWHIGH);
 if(hEma21<0||hEma34<0||hEma55<0||hEma200<0||hRSI<0||hATR<0||hStoch<0)return INIT_FAILED;
 trade.SetExpertMagicNumber(MagicNumber);ResetDailyCounter();return INIT_SUCCEEDED;
}

void OnDeinit(const int reason){Comment("");}

void OnTick()
{
 ResetDailyCounter();
 ManagePositions();
 long spread=(long)SymbolInfoInteger(sym,SYMBOL_SPREAD);
 if(spread>MaxSpreadPoints||DailyLossBlocked()||!IsTradingTime()){Dashboard();return;}
 if(CountPositions()==0&&!SuddenMoveBlocked())
 {
  int sig=Signal();
  if(sig!=0)OpenTrade(sig,false);
 }
 Dashboard();
}
//+------------------------------------------------------------------+