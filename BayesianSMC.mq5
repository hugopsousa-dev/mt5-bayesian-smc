//+------------------------------------------------------------------+
//|                                                 BayesianSMC.mq5  |
//|                     Standalone Bayesian Smart Money Concepts     |
//|                              Indicador preditivo autocontido     |
//+------------------------------------------------------------------+
#property copyright   "BayesianSMC v1.0 — Standalone"
#property link        ""
#property version     "1.00"
#property strict
#property description "Bayesian Smart Money Concepts — indicador preditivo standalone."
#property description "Combina Trend, Momentum, Estrutura (BoS/CHoCH), Imbalance (FVG),"
#property description "Liquidity Sweep e Volume via inferência Bayesiana em log-odds."
#property description "Desenha setas, linhas de Entry/Stop/TP e zonas OB/FVG no gráfico."
#property description "Autocontido — sem dependências de includes ou arquivos externos."

#property indicator_chart_window
#property indicator_plots   0
#property indicator_buffers 0

//==================================================================
//  INPUTS — parametrização completa do indicador
//==================================================================

//── Engine ────────────────────────────────────────────────────────
input group                         "═══ Engine ═══"
input int    InpLookbackBars        = 300;    // Barras para análise (>= 100)
input int    InpSwingStrength       = 3;      // Força do fractal p/ swings (>= 2)
input double InpMinConfidence       = 60.0;   // Confiança mínima p/ sinal (%)
input int    InpEMA_Fast            = 20;     // EMA rápida (trend)
input int    InpEMA_Slow            = 50;     // EMA lenta (trend)
input int    InpRSI_Period          = 14;     // Período RSI (momentum)
input int    InpATR_Period          = 14;     // Período ATR (stop/target)
input int    InpVolumeMA            = 20;     // MA do volume (evidência de fluxo)

//── Pesos das evidências (Bayes) ──────────────────────────────────
input group                         "═══ Pesos Bayesianos ═══"
input double InpWTrend              = 1.0;    // Peso: trend (EMA fast vs slow)
input double InpWMomentum           = 1.0;    // Peso: momentum (RSI)
input double InpWStructure          = 1.3;    // Peso: estrutura (BoS/CHoCH)
input double InpWImbalance          = 1.1;    // Peso: imbalance (FVG)
input double InpWLiquidity          = 1.2;    // Peso: liquidity sweep
input double InpWVolume             = 0.8;    // Peso: volume confirmatório

//── Risco ─────────────────────────────────────────────────────────
input group                         "═══ Risco ═══"
input double InpATRMultStop         = 1.5;    // Stop = ATR × fator
input double InpRR_TP1              = 1.5;    // Reward:Risk do TP1
input double InpRR_TP2              = 3.0;    // Reward:Risk do TP2

//── Visual ────────────────────────────────────────────────────────
input group                         "═══ Visual ═══"
input bool   InpShowArrows          = true;   // Setas BUY/SELL
input bool   InpShowEntryLines      = true;   // Linhas Entry/Stop/TP
input bool   InpShowZones           = true;   // Zonas OB e FVG
input bool   InpShowPanel           = true;   // Painel Bayesiano
input int    InpMaxZones            = 8;      // Max zonas desenhadas
input int    InpArrowSize           = 3;      // Tamanho das setas (1..5)
input int    InpLineWidth           = 1;      // Largura das linhas H
input ENUM_LINE_STYLE InpLineStyle  = STYLE_DOT; // Estilo das linhas

//── Cores ─────────────────────────────────────────────────────────
input group                         "═══ Cores ═══"
input color  InpColorBuy            = clrDodgerBlue;
input color  InpColorSell           = clrOrangeRed;
input color  InpColorEntry          = clrWhite;
input color  InpColorStop           = clrCrimson;
input color  InpColorTP1            = clrLimeGreen;
input color  InpColorTP2            = clrSeaGreen;
input color  InpColorOB_Bull        = clrMediumSeaGreen;
input color  InpColorOB_Bear        = clrIndianRed;
input color  InpColorFVG_Bull       = clrGoldenrod;
input color  InpColorFVG_Bear       = clrDarkOrange;
input color  InpColorPanelBG        = clrBlack;
input color  InpColorPanelText      = clrWhite;

//── Painel ────────────────────────────────────────────────────────
input group                         "═══ Painel ═══"
input int    InpPanelX              = 10;     // Offset X (px)
input int    InpPanelY              = 30;     // Offset Y (px)
input int    InpPanelW              = 240;    // Largura
input int    InpPanelH              = 180;    // Altura
input int    InpFontSize            = 9;      // Fonte
input string InpFontName            = "Consolas";

//── Identificação ─────────────────────────────────────────────────
input group                         "═══ Identificação ═══"
input string InpPrefix              = "BSMC_"; // Prefixo objetos (troque se usar várias cópias)

//==================================================================
//  ESTRUTURAS
//==================================================================

// Uma zona (OB ou FVG) com intervalo temporal e preço
struct SMCZone {
   datetime t_from;        // início no eixo tempo
   datetime t_to;          // fim (extensível à direita)
   double   price_low;
   double   price_high;
   bool     is_bull;       // bullish = procura demand; bearish = supply
   uchar    type;          // 0=OB, 1=FVG
   bool     mitigated;     // tocada pelo preço desde a criação
};

// Resultado Bayesiano da última barra fechada
struct BayesResult {
   string   signal;        // "BUY" | "SELL" | "HOLD" | "WARMUP"
   double   confidence;    // 0..100
   double   p_buy;         // probabilidade posterior de alta
   double   p_sell;        // 1 - p_buy
   double   entry;
   double   stop;
   double   tp1;
   double   tp2;
   // componentes (em log-odds) para debug/painel
   double   llr_trend;
   double   llr_momentum;
   double   llr_structure;
   double   llr_imbalance;
   double   llr_liquidity;
   double   llr_volume;
};

//==================================================================
//  GLOBAIS
//==================================================================
int       g_hATR   = INVALID_HANDLE;
int       g_hRSI   = INVALID_HANDLE;
int       g_hEMA_F = INVALID_HANDLE;
int       g_hEMA_S = INVALID_HANDLE;

datetime  g_lastBar   = 0;         // detecta nova barra
int       g_curW      = 0;         // janela válida corrente
double    g_curAtr    = 0.0;       // ATR da última barra fechada (cache p/ visual)
BayesResult g_sig;                 // sinal corrente
SMCZone   g_zones[];               // zonas ativas
int       g_zCount    = 0;

// buffers pré-alocados (evita realloc por tick)
double    g_bufClose[];
double    g_bufHigh[];
double    g_bufLow[];
double    g_bufOpen[];
double    g_bufATR[];
double    g_bufRSI[];
double    g_bufEMAF[];
double    g_bufEMAS[];
long      g_bufVol[];

// Prefixos internos (derivados de InpPrefix)
string    g_pfx_arrow;
string    g_pfx_line;
string    g_pfx_zone;
string    g_pfx_panel;

//==================================================================
//  UTIL
//==================================================================
string NowTag() {
   return TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS);
}

double Sigmoid(const double x) {
   if(x >  40.0) return 1.0;
   if(x < -40.0) return 0.0;
   return 1.0 / (1.0 + MathExp(-x));
}

// Clamp
double Clamp(const double v, const double lo, const double hi) {
   return (v < lo ? lo : (v > hi ? hi : v));
}

//==================================================================
//  ONINIT — validação defensiva + inicialização dos handles
//==================================================================
int OnInit() {
   // Validação de inputs (fail-fast — evita comportamento tosco em runtime)
   if(InpLookbackBars < 100) {
      Print("❌ BayesianSMC: InpLookbackBars deve ser >= 100");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpSwingStrength < 2) {
      Print("❌ BayesianSMC: InpSwingStrength deve ser >= 2");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpEMA_Fast >= InpEMA_Slow) {
      Print("❌ BayesianSMC: InpEMA_Fast deve ser < InpEMA_Slow");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpMinConfidence < 50.0 || InpMinConfidence > 99.0) {
      Print("❌ BayesianSMC: InpMinConfidence fora de [50..99]");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpATRMultStop <= 0.0 || InpRR_TP1 <= 0.0 || InpRR_TP2 <= 0.0) {
      Print("❌ BayesianSMC: fatores de risco devem ser > 0");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(StringLen(InpPrefix) < 3) {
      Print("❌ BayesianSMC: InpPrefix precisa ter >= 3 caracteres (evita colisão com outros indicadores)");
      return INIT_PARAMETERS_INCORRECT;
   }

   // Handles — criar e checar (INVALID_HANDLE = broker não tem série ou parâmetro inválido)
   g_hATR   = iATR(_Symbol, _Period, InpATR_Period);
   g_hRSI   = iRSI(_Symbol, _Period, InpRSI_Period, PRICE_CLOSE);
   g_hEMA_F = iMA (_Symbol, _Period, InpEMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   g_hEMA_S = iMA (_Symbol, _Period, InpEMA_Slow, 0, MODE_EMA, PRICE_CLOSE);

   if(g_hATR == INVALID_HANDLE || g_hRSI == INVALID_HANDLE ||
      g_hEMA_F == INVALID_HANDLE || g_hEMA_S == INVALID_HANDLE) {
      PrintFormat("❌ BayesianSMC: falha criando handles (ATR=%d RSI=%d EMAf=%d EMAs=%d)",
                  g_hATR, g_hRSI, g_hEMA_F, g_hEMA_S);
      return INIT_FAILED;
   }

   // Pre-alocação dos buffers (cresce no primeiro recompute se necessário)
   const int cap = MathMax(200, InpLookbackBars + 50);
   ArrayResize(g_bufClose, cap);
   ArrayResize(g_bufHigh , cap);
   ArrayResize(g_bufLow  , cap);
   ArrayResize(g_bufOpen , cap);
   ArrayResize(g_bufATR  , cap);
   ArrayResize(g_bufRSI  , cap);
   ArrayResize(g_bufEMAF , cap);
   ArrayResize(g_bufEMAS , cap);
   ArrayResize(g_bufVol  , cap);
   ArrayResize(g_zones   , InpMaxZones * 4); // folga para zonas detectadas antes do prune

   // Séries ascendentes (idx 0 = barra mais antiga) para facilitar o fractal
   ArraySetAsSeries(g_bufClose, false);
   ArraySetAsSeries(g_bufHigh , false);
   ArraySetAsSeries(g_bufLow  , false);
   ArraySetAsSeries(g_bufOpen , false);
   ArraySetAsSeries(g_bufATR  , false);
   ArraySetAsSeries(g_bufRSI  , false);
   ArraySetAsSeries(g_bufEMAF , false);
   ArraySetAsSeries(g_bufEMAS , false);
   ArraySetAsSeries(g_bufVol  , false);

   // Prefixos
   g_pfx_arrow = InpPrefix + "arr_";
   g_pfx_line  = InpPrefix + "line_";
   g_pfx_zone  = InpPrefix + "zone_";
   g_pfx_panel = InpPrefix + "panel_";

   // Limpeza de objetos de sessões anteriores (mesmo prefixo)
   ObjectsDeleteAll(0, InpPrefix);

   // Estado inicial
   g_sig.signal      = "WARMUP";
   g_sig.confidence  = 0.0;
   g_sig.p_buy       = 0.5;
   g_sig.p_sell      = 0.5;
   g_lastBar         = 0;
   g_zCount          = 0;

   IndicatorSetString(INDICATOR_SHORTNAME, "BayesianSMC v1.0");

   PrintFormat("✔ BayesianSMC iniciado em %s %s (lookback=%d, minConf=%.1f%%)",
               _Symbol, EnumToString(_Period), InpLookbackBars, InpMinConfidence);
   return INIT_SUCCEEDED;
}

//==================================================================
//  ONDEINIT — libera handles; limpa objetos só em remoção real
//==================================================================
void OnDeinit(const int reason) {
   if(g_hATR   != INVALID_HANDLE) { IndicatorRelease(g_hATR);   g_hATR   = INVALID_HANDLE; }
   if(g_hRSI   != INVALID_HANDLE) { IndicatorRelease(g_hRSI);   g_hRSI   = INVALID_HANDLE; }
   if(g_hEMA_F != INVALID_HANDLE) { IndicatorRelease(g_hEMA_F); g_hEMA_F = INVALID_HANDLE; }
   if(g_hEMA_S != INVALID_HANDLE) { IndicatorRelease(g_hEMA_S); g_hEMA_S = INVALID_HANDLE; }

   // Preserve os desenhos em recompile/mudança de parâmetros/mudança de TF —
   // só limpa em remoção explícita, fechamento do chart/terminal ou troca de conta.
   const bool should_clean =
      (reason == REASON_REMOVE)  ||
      (reason == REASON_CLOSE)   ||
      (reason == REASON_ACCOUNT) ||
      (reason == REASON_INITFAILED);

   if(should_clean) {
      ObjectsDeleteAll(0, InpPrefix);
      ChartRedraw(0);
   }

   PrintFormat("✔ BayesianSMC deinit — reason=%d (clean=%s)",
               reason, should_clean ? "sim" : "não");
}

//==================================================================
//  ONCALCULATE — entrypoint; só recalcula em nova barra fechada
//==================================================================
int OnCalculate(const int        rates_total,
                const int        prev_calculated,
                const datetime  &time[],
                const double    &open[],
                const double    &high[],
                const double    &low[],
                const double    &close[],
                const long      &tick_volume[],
                const long      &volume[],
                const int       &spread[]) {

   // Warmup mínimo
   if(rates_total < InpLookbackBars + MathMax(InpEMA_Slow, 50)) return 0;

   // Gate de nova barra: só recomputa quando fecha uma barra nova
   const datetime curBar = time[rates_total - 1];
   if(curBar == g_lastBar) return rates_total;
   g_lastBar = curBar;

   // --- Copia as séries na ordem ascendente para os buffers pré-alocados ---
   const int window = MathMin(rates_total, InpLookbackBars);
   const int fromIdx = rates_total - window; // índice inicial na série ascendente
   g_curW = window;

   if(!CopySeriesToBuffers(fromIdx, window,
                           time, open, high, low, close, tick_volume))
      return rates_total;

   // Indicadores técnicos (CopyBuffer com tratamento de erro)
   if(!CopyIndicatorBuffers(fromIdx, window)) return rates_total;

   // --- Pipeline Bayesiano ---
   RunPipeline(window, time);

   // --- Visual ---
   if(InpShowZones)      DrawZones();
   if(InpShowArrows && (g_sig.signal == "BUY" || g_sig.signal == "SELL"))
      DrawArrow(time[rates_total - 1]);
   if(InpShowEntryLines && (g_sig.signal == "BUY" || g_sig.signal == "SELL"))
      DrawEntryLines();
   if(InpShowPanel)      DrawPanel();

   ChartRedraw(0);
   return rates_total;
}

//==================================================================
//  COPIA DAS SÉRIES DO MT5 PARA NOSSOS BUFFERS (ascendentes)
//==================================================================
bool CopySeriesToBuffers(const int fromIdx, const int window,
                         const datetime &time[], const double &open[],
                         const double &high[],   const double &low[],
                         const double &close[],  const long   &tvol[]) {
   if(window <= 0) return false;
   // Os arrays de OnCalculate já são ascendentes (idx 0 = antiga).
   for(int i = 0; i < window; ++i) {
      const int src = fromIdx + i;
      if(src < 0 || src >= ArraySize(close)) continue;
      g_bufOpen [i] = open [src];
      g_bufHigh [i] = high [src];
      g_bufLow  [i] = low  [src];
      g_bufClose[i] = close[src];
      g_bufVol  [i] = tvol [src];
   }
   return true;
}

//==================================================================
//  COPIA DOS INDICADORES (com GetLastError)
//==================================================================
bool CopyIndicatorBuffers(const int fromIdx, const int window) {
   // CopyBuffer usa "shift" contado do mais recente (0 = último fechado).
   // Para pegar os 'window' valores alinhados com nossa janela ascendente,
   // copiamos os últimos 'window' valores e depois invertemos se preciso.
   ResetLastError();
   if(CopyBuffer(g_hATR , 0, 0, window, g_bufATR ) <= 0) {
      PrintFormat("⚠ CopyBuffer(ATR) falhou: err=%d", GetLastError()); return false; }
   if(CopyBuffer(g_hRSI , 0, 0, window, g_bufRSI ) <= 0) {
      PrintFormat("⚠ CopyBuffer(RSI) falhou: err=%d", GetLastError()); return false; }
   if(CopyBuffer(g_hEMA_F, 0, 0, window, g_bufEMAF) <= 0) {
      PrintFormat("⚠ CopyBuffer(EMA_F) falhou: err=%d", GetLastError()); return false; }
   if(CopyBuffer(g_hEMA_S, 0, 0, window, g_bufEMAS) <= 0) {
      PrintFormat("⚠ CopyBuffer(EMA_S) falhou: err=%d", GetLastError()); return false; }
   // CopyBuffer devolve ordem ascendente quando series-flag = false — já setamos.
   return true;
}

//==================================================================
//  PIPELINE BAYESIANO
//==================================================================
void RunPipeline(const int W, const datetime &time[]) {
   // ── 1. Detectar swings (fractais) ────────────────────────────
   int swH[], swL[]; // índices (dentro de 0..W-1) dos pivôs
   ArrayResize(swH, 0);
   ArrayResize(swL, 0);
   DetectSwings(W, swH, swL);

   // ── 2. Estrutura: BoS / CHoCH → LLR ──────────────────────────
   double llr_structure = EvidenceStructure(W, swH, swL);

   // ── 3. FVG (3-bar imbalance) ────────────────────────────────
   DetectFVG(W, time);

   // ── 4. Order Blocks (último opposite candle antes do BoS) ───
   DetectOB(W, time, swH, swL);

   // ── 5. Poda + mitigação de zonas ────────────────────────────
   MitigateAndPruneZones(W);

   // ── 6. LLR das evidências restantes ─────────────────────────
   double llr_trend     = EvidenceTrend(W);
   double llr_momentum  = EvidenceMomentum(W);
   double llr_imbalance = EvidenceImbalance(W);
   double llr_liquidity = EvidenceLiquidity(W);
   double llr_volume    = EvidenceVolume(W);

   // ── 7. Combinação bayesiana em log-odds ─────────────────────
   const double logit =
        InpWTrend     * llr_trend
      + InpWMomentum  * llr_momentum
      + InpWStructure * llr_structure
      + InpWImbalance * llr_imbalance
      + InpWLiquidity * llr_liquidity
      + InpWVolume    * llr_volume;

   const double pBuy = Sigmoid(logit);
   const double conf = 100.0 * MathAbs(pBuy - 0.5) * 2.0; // 0..100

   g_sig.p_buy        = pBuy;
   g_sig.p_sell       = 1.0 - pBuy;
   g_sig.confidence   = conf;
   g_sig.llr_trend     = llr_trend;
   g_sig.llr_momentum  = llr_momentum;
   g_sig.llr_structure = llr_structure;
   g_sig.llr_imbalance = llr_imbalance;
   g_sig.llr_liquidity = llr_liquidity;
   g_sig.llr_volume    = llr_volume;

   if(conf < InpMinConfidence) {
      g_sig.signal = "HOLD";
   } else if(pBuy > 0.5) {
      g_sig.signal = "BUY";
   } else {
      g_sig.signal = "SELL";
   }

   // ── 8. Risk: Entry/Stop/TP a partir do ATR ──────────────────
   ComputeRiskLevels(W);
}

//==================================================================
//  DETECÇÃO DE SWINGS (fractal N-bar)
//==================================================================
void DetectSwings(const int W, int &swH[], int &swL[]) {
   const int K = InpSwingStrength;
   for(int i = K; i < W - K; ++i) {
      bool isHigh = true, isLow = true;
      for(int k = 1; k <= K; ++k) {
         if(g_bufHigh[i] <= g_bufHigh[i - k] || g_bufHigh[i] <= g_bufHigh[i + k]) isHigh = false;
         if(g_bufLow [i] >= g_bufLow [i - k] || g_bufLow [i] >= g_bufLow [i + k]) isLow  = false;
         if(!isHigh && !isLow) break;
      }
      if(isHigh) { const int n = ArraySize(swH); ArrayResize(swH, n + 1); swH[n] = i; }
      if(isLow)  { const int n = ArraySize(swL); ArrayResize(swL, n + 1); swL[n] = i; }
   }
}

//==================================================================
//  EVIDÊNCIA: ESTRUTURA (BoS / CHoCH)  → LLR em [-2..+2]
//==================================================================
double EvidenceStructure(const int W, const int &swH[], const int &swL[]) {
   const int nH = ArraySize(swH), nL = ArraySize(swL);
   if(nH < 2 || nL < 2) return 0.0;

   // Últimos 2 highs e 2 lows
   const double h1 = g_bufHigh[swH[nH - 2]], h2 = g_bufHigh[swH[nH - 1]];
   const double l1 = g_bufLow [swL[nL - 2]], l2 = g_bufLow [swL[nL - 1]];
   const double cur = g_bufClose[W - 1];

   double llr = 0.0;
   // HH + HL  → estrutura de alta
   if(h2 > h1 && l2 > l1) llr += 1.0;
   // LL + LH → estrutura de baixa
   if(h2 < h1 && l2 < l1) llr -= 1.0;

   // BoS: preço rompe o último high / low pivotal
   if(cur > h2) llr += 0.8;
   if(cur < l2) llr -= 0.8;

   // CHoCH: rompimento contra a tendência anterior (forte)
   if(h2 < h1 && cur > h1) llr += 1.2; // era baixa, virou alta
   if(l2 > l1 && cur < l1) llr -= 1.2; // era alta, virou baixa

   return Clamp(llr, -2.0, 2.0);
}

//==================================================================
//  DETECÇÃO DE FVG (Fair Value Gap — 3-bar imbalance)
//==================================================================
void DetectFVG(const int W, const datetime &time[]) {
   // Só varre a cauda — zonas antigas já estão no vetor g_zones
   const int from = MathMax(2, W - 80);
   for(int i = from; i < W; ++i) {
      // Bullish FVG: low[i] > high[i-2]  (gap entre candle i e i-2)
      if(g_bufLow[i] > g_bufHigh[i - 2]) {
         AddZone(time[i - 2], time[i], g_bufHigh[i - 2], g_bufLow[i], true, 1);
      }
      // Bearish FVG: high[i] < low[i-2]
      if(g_bufHigh[i] < g_bufLow[i - 2]) {
         AddZone(time[i - 2], time[i], g_bufHigh[i], g_bufLow[i - 2], false, 1);
      }
   }
}

//==================================================================
//  DETECÇÃO DE ORDER BLOCKS (último candle oposto antes de BoS)
//==================================================================
void DetectOB(const int W, const datetime &time[], const int &swH[], const int &swL[]) {
   // Heurística simples: para cada swing high/low recente, o candle
   // *imediatamente antes* do pivô, se for de cor oposta à direção
   // que veio depois, é um OB bullish (antes de high) ou bearish (antes de low).
   const int nH = ArraySize(swH);
   const int nL = ArraySize(swL);

   if(nH > 0) {
      const int i = swH[nH - 1];
      if(i - 1 >= 0) {
         // OB bearish = último candle verde antes do topo
         if(g_bufClose[i - 1] > g_bufOpen[i - 1]) {
            AddZone(time[i - 1], time[i], g_bufOpen[i - 1], g_bufClose[i - 1], false, 0);
         }
      }
   }
   if(nL > 0) {
      const int i = swL[nL - 1];
      if(i - 1 >= 0) {
         // OB bullish = último candle vermelho antes do fundo
         if(g_bufClose[i - 1] < g_bufOpen[i - 1]) {
            AddZone(time[i - 1], time[i], g_bufClose[i - 1], g_bufOpen[i - 1], true, 0);
         }
      }
   }
}

//==================================================================
//  ADICIONA ZONA (evita duplicadas — mesma faixa de preço)
//==================================================================
void AddZone(const datetime t1, const datetime t2,
             const double p_lo, const double p_hi,
             const bool is_bull, const uchar ztype) {
   if(p_hi <= p_lo) return;

   // dedupe: se já existe zona com overlap > 80% e mesmo tipo/direção, ignora
   for(int k = 0; k < g_zCount; ++k) {
      if(g_zones[k].type != ztype || g_zones[k].is_bull != is_bull) continue;
      const double overlap = MathMin(p_hi, g_zones[k].price_high) -
                             MathMax(p_lo, g_zones[k].price_low);
      const double mySize = p_hi - p_lo;
      if(overlap > 0.8 * mySize) return;
   }

   if(g_zCount >= ArraySize(g_zones)) ArrayResize(g_zones, g_zCount + 16);
   g_zones[g_zCount].t_from     = t1;
   g_zones[g_zCount].t_to       = t2;
   g_zones[g_zCount].price_low  = p_lo;
   g_zones[g_zCount].price_high = p_hi;
   g_zones[g_zCount].is_bull    = is_bull;
   g_zones[g_zCount].type       = ztype;
   g_zones[g_zCount].mitigated  = false;
   g_zCount++;
}

//==================================================================
//  MITIGAÇÃO + PODA — mantém as N zonas mais próximas do preço
//==================================================================
void MitigateAndPruneZones(const int W) {
   const double cur = g_bufClose[W - 1];

   // marca mitigadas
   for(int k = 0; k < g_zCount; ++k) {
      if(g_zones[k].mitigated) continue;
      // qualquer touch da mecha dentro da zona = mitigada
      for(int i = W - 30; i < W; ++i) {
         if(i < 0) continue;
         if(g_bufLow[i] <= g_zones[k].price_high && g_bufHigh[i] >= g_zones[k].price_low) {
            g_zones[k].mitigated = true;
            break;
         }
      }
   }

   // ordena por proximidade ao preço atual (mais próxima primeiro) — insertion sort
   for(int i = 1; i < g_zCount; ++i) {
      SMCZone key = g_zones[i];
      double key_d = MathAbs((key.price_high + key.price_low) * 0.5 - cur);
      int j = i - 1;
      while(j >= 0) {
         double j_d = MathAbs((g_zones[j].price_high + g_zones[j].price_low) * 0.5 - cur);
         if(j_d <= key_d) break;
         g_zones[j + 1] = g_zones[j];
         j--;
      }
      g_zones[j + 1] = key;
   }

   // mantém só as InpMaxZones mais próximas
   if(g_zCount > InpMaxZones) g_zCount = InpMaxZones;
}

//==================================================================
//  EVIDÊNCIAS TÉCNICAS → LLR em [-2..+2]
//==================================================================
double EvidenceTrend(const int W) {
   const double ef = g_bufEMAF[W - 1];
   const double es = g_bufEMAS[W - 1];
   if(es <= 0.0) return 0.0;
   const double diff = (ef - es) / es; // espaço unitless
   // escalar com tanh para saturar em ±2
   return Clamp(2.0 * MathTanh(100.0 * diff), -2.0, 2.0);
}

double EvidenceMomentum(const int W) {
   const double r = g_bufRSI[W - 1];
   // 50 = neutro; >60 = alta; <40 = baixa. Castigar extremos (reversal risk).
   double base = (r - 50.0) / 20.0;   // RSI 70 → 1.0
   if(r > 80.0) base -= 0.5;
   if(r < 20.0) base += 0.5;
   return Clamp(base, -2.0, 2.0);
}

double EvidenceImbalance(const int W) {
   // Soma contribuição das zonas não mitigadas: bullish perto abaixo do preço
   // → BUY; bearish perto acima → SELL.
   const double cur = g_bufClose[W - 1];
   const double atr = (g_bufATR[W - 1] > 0 ? g_bufATR[W - 1] : 1.0);
   double llr = 0.0;
   for(int k = 0; k < g_zCount; ++k) {
      if(g_zones[k].mitigated) continue;
      const double mid = 0.5 * (g_zones[k].price_high + g_zones[k].price_low);
      const double dist = MathAbs(mid - cur) / atr; // em ATRs
      if(dist > 5.0) continue; // longe demais
      const double w = MathExp(-dist / 2.0); // peso decai com distância
      llr += (g_zones[k].is_bull ? +0.6 : -0.6) * w;
   }
   return Clamp(llr, -2.0, 2.0);
}

double EvidenceLiquidity(const int W) {
   // Sweep = mecha rompe o último low/high e corpo volta pra dentro
   if(W < 5) return 0.0;
   const double cur_h = g_bufHigh[W - 1], cur_l = g_bufLow[W - 1];
   const double cur_c = g_bufClose[W - 1], cur_o = g_bufOpen[W - 1];

   // últimos 10 highs/lows (exclui barra atual)
   double maxH = -DBL_MAX, minL = DBL_MAX;
   for(int i = W - 11; i < W - 1; ++i) {
      if(i < 0) continue;
      if(g_bufHigh[i] > maxH) maxH = g_bufHigh[i];
      if(g_bufLow [i] < minL) minL = g_bufLow [i];
   }

   double llr = 0.0;
   // varreu o low e fechou bullish → liquidez tomada, reversão p/ cima
   if(cur_l < minL && cur_c > cur_o) llr += 1.2;
   // varreu o high e fechou bearish → reversão p/ baixo
   if(cur_h > maxH && cur_c < cur_o) llr -= 1.2;
   return Clamp(llr, -2.0, 2.0);
}

double EvidenceVolume(const int W) {
   // volume médio últimos N vs volume atual
   const int n = MathMin(InpVolumeMA, W - 1);
   if(n < 5) return 0.0;
   double sum = 0.0;
   for(int i = W - 1 - n; i < W - 1; ++i) {
      if(i < 0) continue;
      sum += (double)g_bufVol[i];
   }
   const double avg = sum / n;
   if(avg <= 0.0) return 0.0;
   const double cur_v = (double)g_bufVol[W - 1];
   const double ratio = cur_v / avg; // 1.0 = normal

   // Volume corrobora a direção do candle atual
   const double body = g_bufClose[W - 1] - g_bufOpen[W - 1];
   double sign = (body > 0.0 ? 1.0 : (body < 0.0 ? -1.0 : 0.0));
   const double magnitude = Clamp((ratio - 1.0) * 1.0, -1.5, 1.5);
   return Clamp(sign * magnitude, -2.0, 2.0);
}

//==================================================================
//  RISCO — Entry/Stop/TPs derivados do ATR
//==================================================================
void ComputeRiskLevels(const int W) {
   const double cur = g_bufClose[W - 1];
   const double atr = g_bufATR[W - 1];
   g_curAtr = atr; // cache para uso do visual
   if(atr <= 0.0) return;

   const double stopDist = atr * InpATRMultStop;
   g_sig.entry = cur;
   if(g_sig.signal == "BUY") {
      g_sig.stop = cur - stopDist;
      g_sig.tp1  = cur + stopDist * InpRR_TP1;
      g_sig.tp2  = cur + stopDist * InpRR_TP2;
   } else if(g_sig.signal == "SELL") {
      g_sig.stop = cur + stopDist;
      g_sig.tp1  = cur - stopDist * InpRR_TP1;
      g_sig.tp2  = cur - stopDist * InpRR_TP2;
   } else {
      g_sig.stop = 0.0; g_sig.tp1 = 0.0; g_sig.tp2 = 0.0;
   }
}

//==================================================================
//  VISUAL — SETAS
//==================================================================
void DrawArrow(const datetime t) {
   const string name = g_pfx_arrow + IntegerToString((long)t);
   // Apaga qualquer seta antiga do mesmo bar (raro, mas seguro)
   if(ObjectFind(0, name) >= 0) ObjectDelete(0, name);

   const bool is_buy = (g_sig.signal == "BUY");
   const double offset = (g_curAtr > 0.0 ? g_curAtr : 0.0) * 0.3;
   const double price = is_buy ? (g_sig.entry - offset) : (g_sig.entry + offset);
   const int code = is_buy ? 233 : 234; // Wingdings: ▲ / ▼

   ObjectCreate(0, name, OBJ_ARROW, 0, t, price);
   ObjectSetInteger(0, name, OBJPROP_ARROWCODE, code);
   ObjectSetInteger(0, name, OBJPROP_COLOR,     is_buy ? InpColorBuy : InpColorSell);
   ObjectSetInteger(0, name, OBJPROP_WIDTH,     InpArrowSize);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR,    is_buy ? ANCHOR_TOP : ANCHOR_BOTTOM);
   ObjectSetInteger(0, name, OBJPROP_BACK,      false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN,    true);
   ObjectSetString (0, name, OBJPROP_TOOLTIP,
      StringFormat("%s %.1f%%  P(BUY)=%.2f", g_sig.signal, g_sig.confidence, g_sig.p_buy));
}

//==================================================================
//  VISUAL — LINHAS HORIZONTAIS (Entry / Stop / TP1 / TP2)
//==================================================================
void UpsertHLine(const string suffix, const double price,
                 const color clr, const string label) {
   const string name = g_pfx_line + suffix;
   if(ObjectFind(0, name) < 0) {
      ObjectCreate(0, name, OBJ_HLINE, 0, 0, price);
   } else {
      ObjectSetDouble(0, name, OBJPROP_PRICE, price);
   }
   ObjectSetInteger(0, name, OBJPROP_COLOR,     clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE,     InpLineStyle);
   ObjectSetInteger(0, name, OBJPROP_WIDTH,     InpLineWidth);
   ObjectSetInteger(0, name, OBJPROP_BACK,      true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN,    true);
   ObjectSetString (0, name, OBJPROP_TEXT,      label);
   ObjectSetString (0, name, OBJPROP_TOOLTIP,
      StringFormat("%s @ %s", label, DoubleToString(price, _Digits)));
}

void DrawEntryLines() {
   UpsertHLine("entry", g_sig.entry, InpColorEntry, "Entry");
   UpsertHLine("stop" , g_sig.stop , InpColorStop , "Stop");
   UpsertHLine("tp1"  , g_sig.tp1  , InpColorTP1  , "TP1");
   UpsertHLine("tp2"  , g_sig.tp2  , InpColorTP2  , "TP2");
}

//==================================================================
//  VISUAL — ZONAS (retângulos)
//==================================================================
void DrawZones() {
   // Apaga as zonas desenhadas antes (prefixo zona) e redesenha as ativas.
   ObjectsDeleteAll(0, g_pfx_zone);

   // Estende o limite direito até a barra atual + margem
   const datetime t_right = TimeCurrent() + PeriodSeconds(_Period) * 20;

   for(int k = 0; k < g_zCount; ++k) {
      const string name = g_pfx_zone + IntegerToString(k);
      const datetime t2 = (datetime)MathMax((long)g_zones[k].t_to, (long)t_right);

      ObjectCreate(0, name, OBJ_RECTANGLE, 0,
                   g_zones[k].t_from, g_zones[k].price_low,
                   t2,                g_zones[k].price_high);

      color clr;
      if(g_zones[k].type == 0)
         clr = g_zones[k].is_bull ? InpColorOB_Bull  : InpColorOB_Bear;
      else
         clr = g_zones[k].is_bull ? InpColorFVG_Bull : InpColorFVG_Bear;

      ObjectSetInteger(0, name, OBJPROP_COLOR,      clr);
      ObjectSetInteger(0, name, OBJPROP_FILL,       true);
      ObjectSetInteger(0, name, OBJPROP_BACK,       true);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN,     true);
      ObjectSetInteger(0, name, OBJPROP_WIDTH,      1);
      ObjectSetInteger(0, name, OBJPROP_STYLE,      g_zones[k].mitigated ? STYLE_DASH : STYLE_SOLID);
      ObjectSetString (0, name, OBJPROP_TOOLTIP,
         StringFormat("%s %s %s  [%s .. %s]",
                      g_zones[k].type == 0 ? "OB" : "FVG",
                      g_zones[k].is_bull ? "Bull" : "Bear",
                      g_zones[k].mitigated ? "(mit)" : "",
                      DoubleToString(g_zones[k].price_low, _Digits),
                      DoubleToString(g_zones[k].price_high, _Digits)));
   }
}

//==================================================================
//  VISUAL — PAINEL BAYESIANO
//==================================================================
void UpsertLabel(const string suffix, const int x, const int y,
                 const string text, const color clr, const int fontSize) {
   const string name = g_pfx_panel + suffix;
   if(ObjectFind(0, name) < 0) {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER,     CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_ANCHOR,     ANCHOR_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN,     true);
      ObjectSetInteger(0, name, OBJPROP_BACK,       false);
   }
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_COLOR,     clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE,  fontSize);
   ObjectSetString (0, name, OBJPROP_FONT,      InpFontName);
   ObjectSetString (0, name, OBJPROP_TEXT,      text);
}

void UpsertRect(const string suffix, const int x, const int y,
                const int w, const int h, const color bg) {
   const string name = g_pfx_panel + suffix;
   if(ObjectFind(0, name) < 0) {
      ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER,     CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN,     true);
      ObjectSetInteger(0, name, OBJPROP_BACK,       false);
      ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   }
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE,     w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE,     h);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR,   bg);
   ObjectSetInteger(0, name, OBJPROP_COLOR,     clrDimGray);
}

void DrawPanel() {
   const int X  = InpPanelX;
   const int Y  = InpPanelY;
   const int W  = InpPanelW;
   const int H  = InpPanelH;
   const int FS = InpFontSize;

   UpsertRect("bg", X, Y, W, H, InpColorPanelBG);

   color sigClr = clrGray;
   if(g_sig.signal == "BUY")  sigClr = InpColorBuy;
   if(g_sig.signal == "SELL") sigClr = InpColorSell;

   int row = 0; const int rowH = FS + 4;
   UpsertLabel("title", X + 8, Y + 6 + row++ * rowH,
               "BayesianSMC v1.0", InpColorPanelText, FS + 1);
   UpsertLabel("sym", X + 8, Y + 6 + row++ * rowH,
               StringFormat("%s %s", _Symbol, EnumToString(_Period)),
               InpColorPanelText, FS);
   UpsertLabel("sig", X + 8, Y + 6 + row++ * rowH,
               StringFormat("Sinal: %-5s  %.1f%%", g_sig.signal, g_sig.confidence),
               sigClr, FS + 1);
   UpsertLabel("prob", X + 8, Y + 6 + row++ * rowH,
               StringFormat("P(BUY)=%.2f  P(SELL)=%.2f", g_sig.p_buy, g_sig.p_sell),
               InpColorPanelText, FS);

   // barras de evidência
   row++;
   UpsertLabel("h_e", X + 8, Y + 6 + row++ * rowH,
               "─── Evidências (LLR) ───", clrSilver, FS);
   UpsertLabel("e_tr", X + 8, Y + 6 + row++ * rowH,
               StringFormat("Trend .... %+.2f", g_sig.llr_trend),
               ColorFromLLR(g_sig.llr_trend), FS);
   UpsertLabel("e_mo", X + 8, Y + 6 + row++ * rowH,
               StringFormat("Momentum . %+.2f", g_sig.llr_momentum),
               ColorFromLLR(g_sig.llr_momentum), FS);
   UpsertLabel("e_st", X + 8, Y + 6 + row++ * rowH,
               StringFormat("Structure  %+.2f", g_sig.llr_structure),
               ColorFromLLR(g_sig.llr_structure), FS);
   UpsertLabel("e_im", X + 8, Y + 6 + row++ * rowH,
               StringFormat("Imbalance  %+.2f", g_sig.llr_imbalance),
               ColorFromLLR(g_sig.llr_imbalance), FS);
   UpsertLabel("e_li", X + 8, Y + 6 + row++ * rowH,
               StringFormat("Liquidity  %+.2f", g_sig.llr_liquidity),
               ColorFromLLR(g_sig.llr_liquidity), FS);
   UpsertLabel("e_vo", X + 8, Y + 6 + row++ * rowH,
               StringFormat("Volume ... %+.2f", g_sig.llr_volume),
               ColorFromLLR(g_sig.llr_volume), FS);

   if(g_sig.signal == "BUY" || g_sig.signal == "SELL") {
      row++;
      UpsertLabel("risk_e", X + 8, Y + 6 + row++ * rowH,
                  StringFormat("Entry %s", DoubleToString(g_sig.entry, _Digits)),
                  InpColorEntry, FS);
      UpsertLabel("risk_s", X + 8, Y + 6 + row++ * rowH,
                  StringFormat("Stop  %s", DoubleToString(g_sig.stop, _Digits)),
                  InpColorStop, FS);
      UpsertLabel("risk_t", X + 8, Y + 6 + row++ * rowH,
                  StringFormat("TP1 %s   TP2 %s",
                               DoubleToString(g_sig.tp1, _Digits),
                               DoubleToString(g_sig.tp2, _Digits)),
                  InpColorTP1, FS);
   } else {
      // limpa labels de risco quando não há sinal
      ObjectDelete(0, g_pfx_panel + "risk_e");
      ObjectDelete(0, g_pfx_panel + "risk_s");
      ObjectDelete(0, g_pfx_panel + "risk_t");
   }
}

color ColorFromLLR(const double llr) {
   if(llr >  0.3) return InpColorBuy;
   if(llr < -0.3) return InpColorSell;
   return clrSilver;
}

//+------------------------------------------------------------------+
//|                              FIM — BayesianSMC.mq5               |
//+------------------------------------------------------------------+