param(
    [string]$CsvPath = (Join-Path $PSScriptRoot 'dados_hidrometros_slz.csv'),
    [string]$OutputPath = (Join-Path $PSScriptRoot 'dashboard_hidrometros.html')
)

$ErrorActionPreference = 'Stop'

function Clean-Value([object]$Value) {
    if ($null -eq $Value) { return '(Não informado)' }
    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return '(Não informado)' }
    return $text
}

if (-not (Test-Path -LiteralPath $CsvPath)) {
    throw "CSV não encontrado: $CsvPath"
}

$rows = Import-Csv -LiteralPath $CsvPath -Delimiter ';'
$seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$cube = @{}
$neighborhoods = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$duplicateRows = 0
$missingConsumption = 0
$invalidDates = 0
$futureDates = 0
$suspiciousOldDates = 0
$today = [datetime]::Today
$periodStart = [datetime]'2016-01-01'
$includedCount = 0
$excludedBeforePeriod = 0

foreach ($row in $rows) {
    $rawKey = @(
        $row.MATRICULA,
        $row.LOCALIDADE,
        $row.BAIRRO,
        $row.'NR HID.',
        $row.'DATA INSTALACAO',
        $row.'TIPO CONSUMO AGUA',
        $row.'TIPO CONSUMO ESGOTO',
        $row.'SITUACAO AGUA'
    ) -join [char]31

    if (-not $seen.Add($rawKey)) {
        $duplicateRows++
        continue
    }

    $dateText = Clean-Value $row.'DATA INSTALACAO'
    $parsedDate = [datetime]::MinValue
    if ($dateText -eq '(Não informado)' -or -not [datetime]::TryParseExact(
        $dateText,
        'yyyy-MM-dd',
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::None,
        [ref]$parsedDate
    )) {
        $invalidDates++
        continue
    }
    if ($parsedDate.Date -lt $periodStart) {
        $excludedBeforePeriod++
        if ($parsedDate.Year -lt 1980) { $suspiciousOldDates++ }
        continue
    }
    if ($parsedDate.Date -gt $today) {
        $futureDates++
        continue
    }

    $ano = [string]$parsedDate.Year
    $bairro = Clean-Value $row.BAIRRO
    $situacao = Clean-Value $row.'SITUACAO AGUA'
    $consumo = Clean-Value $row.'TIPO CONSUMO AGUA'
    if ($consumo -eq '(Não informado)') { $missingConsumption++ }
    [void]$neighborhoods.Add($bairro)
    $includedCount++

    $key = @($ano, $bairro, $situacao, $consumo) -join [char]30
    if ($cube.ContainsKey($key)) {
        $cube[$key].n++
    }
    else {
        $cube[$key] = [pscustomobject]@{
            y = $ano
            b = $bairro
            s = $situacao
            c = $consumo
            n = 1
        }
    }
}

$cubeRows = @($cube.Values | Sort-Object y, b, s, c)
$payload = [ordered]@{
    generatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm')
    source = [IO.Path]::GetFileName($CsvPath)
    totalRaw = $rows.Count
    totalUnique = $seen.Count
    total = $includedCount
    duplicates = $duplicateRows
    neighborhoods = $neighborhoods.Count
    missingConsumption = $missingConsumption
    invalidDates = $invalidDates
    futureDates = $futureDates
    suspiciousOldDates = $suspiciousOldDates
    excludedBeforePeriod = $excludedBeforePeriod
    periodStart = $periodStart.ToString('yyyy-MM-dd')
    periodEnd = $today.ToString('yyyy-MM-dd')
    currentYear = $today.Year
    data = $cubeRows
}

$json = $payload | ConvertTo-Json -Depth 5 -Compress
$json = $json.Replace('</', '<\/')

$html = @'
<!doctype html>
<html lang="pt-BR">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>BI Gerencial — Hidrômetros de São Luís</title>
  <script>document.documentElement.dataset.theme=localStorage.getItem('tema')==='escuro'?'dark':'light';</script>
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800;900&family=Plus+Jakarta+Sans:wght@700;800&display=swap" rel="stylesheet">
  <style>
    /* Tokens do Portal CAEMA (portal/auth-assets/auth.css) */
    :root{
      --brand:#0ea5e9;--brand-dark:#0284c7;--brand-soft:rgba(14,165,233,.12);
      --bg:#07111f;--surface:#0f1c2d;--surface-2:#132338;--border:rgba(125,211,252,.16);
      --text:#e8f1f8;--muted:#91a4b7;--success:#34d399;--warning:#fbbf24;--danger:#fb7185;
      --shadow:0 24px 70px rgba(0,0,0,.42);
      --body-glow-1:rgba(14,165,233,.18);--body-glow-2:rgba(2,132,199,.14);
      --input-bg:rgba(5,13,24,.56);--label:#c8d7e5;--placeholder:#52677b;
      --accent:#7dd3fc;--footer:#60758a;
      --table-head:#0b1626;--row-border:rgba(125,211,252,.09);
      --track:rgba(125,211,252,.13);--grid:rgba(125,211,252,.14);--violet:#a78bfa;
    }
    html[data-theme="light"]{
      color-scheme:light;
      --brand:#0284c7;--brand-dark:#0369a1;--brand-soft:rgba(2,132,199,.1);
      --bg:#eef6fb;--surface:#ffffff;--surface-2:#f4f9fc;--border:rgba(2,132,199,.18);
      --text:#122235;--muted:#60758a;--success:#15803d;--warning:#b45309;--danger:#be123c;
      --shadow:0 24px 70px rgba(15,53,82,.14);
      --body-glow-1:rgba(14,165,233,.16);--body-glow-2:rgba(56,189,248,.12);
      --input-bg:rgba(241,247,251,.9);--label:#31475b;--placeholder:#8ba0b3;
      --accent:#0369a1;--footer:#7b8fa2;
      --table-head:#e9f2f9;--row-border:rgba(2,132,199,.09);
      --track:rgba(2,132,199,.11);--grid:rgba(2,132,199,.14);--violet:#7856d8;
    }
    *,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
    html{font-family:Inter,system-ui,-apple-system,"Segoe UI",sans-serif;color-scheme:dark}
    body{min-height:100vh;color:var(--text);transition:background .2s ease,color .2s ease;background:
      radial-gradient(circle at 10% 10%,var(--body-glow-1),transparent 34rem),
      radial-gradient(circle at 90% 90%,var(--body-glow-2),transparent 30rem),
      var(--bg)}
    h1,h2{font-family:"Plus Jakarta Sans",Inter,sans-serif}
    button,input,select{font:inherit}button{cursor:pointer}

    header{width:min(1540px,94vw);margin:0 auto;padding:clamp(2rem,4vw,3.4rem) 0 1.5rem;position:relative;overflow:hidden}
    .hero{display:flex;align-items:flex-end;justify-content:space-between;gap:1.5rem;flex-wrap:wrap}
    header::after{content:"";position:absolute;width:420px;height:420px;border:1px solid var(--border);border-radius:50%;right:-210px;top:-160px;box-shadow:0 0 0 70px var(--brand-soft);pointer-events:none;opacity:.5}
    header .eyebrow{font-size:.72rem;text-transform:uppercase;letter-spacing:.18em;color:var(--accent);font-weight:800;margin-bottom:.85rem}
    header h1{font-size:clamp(2rem,3.6vw,3.3rem);line-height:1.04;letter-spacing:-.055em;font-weight:800}
    header h1 span{color:#38bdf8}
    header p{margin-top:.85rem;color:var(--muted);font-size:.95rem;line-height:1.7;max-width:700px}

    main{width:min(1540px,94vw);margin:0 auto 3rem;position:relative;z-index:2}
    .card{background:var(--surface);border:1px solid var(--border);border-radius:22px;box-shadow:var(--shadow)}
    .filters{padding:1.05rem 1.15rem;display:grid;grid-template-columns:repeat(4,minmax(150px,1fr)) auto;gap:14px;align-items:end}
    label{display:block;color:var(--label);font-size:.68rem;font-weight:800;text-transform:uppercase;letter-spacing:.09em;margin:0 0 .5rem}
    select,input{width:100%;height:46px;border:1px solid var(--border);border-radius:14px;background:var(--input-bg);color:var(--text);padding:0 14px;outline:none;transition:.18s ease}
    select:focus,input:focus{border-color:var(--brand);box-shadow:0 0 0 4px var(--brand-soft)}
    input::placeholder{color:var(--placeholder)}
    button{height:46px;padding:0 1.1rem;border-radius:14px;border:1px solid var(--border);background:var(--surface-2);color:var(--text);font-weight:800;white-space:nowrap;transition:.18s ease}
    button:hover{border-color:var(--brand)}
    .btn-primary{border:0;background:linear-gradient(135deg,var(--brand),var(--brand-dark));color:#fff;box-shadow:0 14px 28px rgba(14,165,233,.2)}
    .btn-primary:hover{transform:translateY(-1px);box-shadow:0 18px 34px rgba(14,165,233,.28)}
    .theme-toggle{height:40px;font-size:.72rem;letter-spacing:.02em}

    .kpis{display:grid;grid-template-columns:repeat(4,1fr);gap:14px;margin:14px 0}
    .kpi{padding:1.15rem 1.25rem;border-radius:18px;position:relative;overflow:hidden}
    .kpi:after{content:"";position:absolute;width:96px;height:96px;border-radius:50%;right:-30px;top:-34px;background:var(--accent-color);opacity:.14}
    .kpi .name{font-size:.65rem;color:var(--muted);font-weight:800;text-transform:uppercase;letter-spacing:.09em}
    .kpi .value{font-size:clamp(1.6rem,2.4vw,2.15rem);font-weight:900;margin-top:.3rem;line-height:1.1;letter-spacing:-.02em}
    .kpi .sub{font-size:.72rem;color:var(--muted);margin-top:.3rem}

    .grid{display:grid;grid-template-columns:1.35fr .85fr;gap:14px;margin-bottom:14px}.grid.equal{grid-template-columns:1fr 1fr}
    .chart-card{padding:1.35rem 1.4rem;min-width:0}
    .chart-head{display:flex;align-items:start;justify-content:space-between;gap:12px;margin-bottom:1.1rem}
    .chart-head h2{font-size:1.02rem;letter-spacing:-.03em;font-weight:800}
    .chart-head p{font-size:.76rem;color:var(--muted);margin-top:.35rem}
    .chart-head select{height:36px;font-size:.75rem;width:auto;border-radius:11px;padding:0 10px}
    .canvas-scroll{overflow:auto;max-width:100%;position:relative}.canvas-scroll.vertical{max-height:560px}canvas{display:block}

    .quality{padding:1rem 1.15rem;margin-bottom:14px;display:flex;gap:1rem;align-items:flex-start;border-radius:16px;box-shadow:none;
      background:rgba(251,191,36,.07);border:1px solid rgba(251,191,36,.26)}
    .quality strong{font-size:.82rem;color:var(--text)}
    .quality p{font-size:.76rem;color:var(--muted);margin-top:.3rem;line-height:1.6}

    .donut-wrap{display:grid;grid-template-columns:minmax(180px,1fr) minmax(180px,1fr);align-items:center;gap:8px}
    .legend{font-size:.78rem}
    .legend-row{display:grid;grid-template-columns:10px 1fr auto;gap:10px;align-items:center;padding:.55rem 0;border-bottom:1px solid var(--row-border)}
    .dot{width:10px;height:10px;border-radius:999px}
    .legend-row b{font-variant-numeric:tabular-nums;font-weight:800}
    .legend-row small{color:var(--muted)}

    .table-card{padding:1.35rem 1.4rem}
    .table-tools{display:flex;gap:10px;align-items:end}.table-tools input{width:min(300px,42vw);height:40px;border-radius:11px}
    .table-tools button{height:40px}
    .table-wrap{overflow:auto;max-height:520px;border:1px solid var(--border);border-radius:16px;margin-top:1rem}
    table{width:100%;border-collapse:collapse;font-size:.8rem}
    th{position:sticky;top:0;background:var(--table-head);text-align:left;color:var(--muted);font-size:.62rem;font-weight:800;text-transform:uppercase;letter-spacing:.08em;z-index:1}
    th,td{padding:.8rem 1rem;border-bottom:1px solid var(--row-border)}
    td:nth-child(1),td:nth-child(3){font-variant-numeric:tabular-nums}
    td:nth-child(2){font-weight:700}
    td:nth-child(3),th:nth-child(3){text-align:right}
    .mini-bar{height:7px;background:var(--track);border-radius:999px;overflow:hidden;min-width:100px}
    .mini-bar i{display:block;height:100%;background:linear-gradient(90deg,var(--brand),#2dd4bf);border-radius:999px}

    footer{text-align:center;color:var(--footer);font-size:.68rem;margin-top:1.4rem}
    @media(max-width:950px){.filters{grid-template-columns:repeat(2,1fr)}.grid,.grid.equal{grid-template-columns:1fr}.kpis{grid-template-columns:repeat(2,1fr)}}
    @media(max-width:560px){main,header{width:96vw}.filters,.kpis{grid-template-columns:1fr}.filters button{width:100%}.donut-wrap{grid-template-columns:1fr}.chart-card,.table-card{padding:1.1rem}.table-tools{align-items:stretch;flex-direction:column}.table-tools input,.table-tools button{width:100%}}
  </style>
</head>
<body>
  <header>
    <div class="hero">
      <div>
        <div class="eyebrow">Portal de Gestão · Visão gerencial</div>
        <h1>Hidrômetros de <span>São Luís</span></h1>
        <p>Instalações de 2016 até hoje, distribuição territorial, situação da água e perfil de consumo</p>
      </div>
      <button class="theme-toggle" id="themeToggle" type="button">Tema escuro</button>
    </div>
  </header>
  <main>
    <section class="card filters" aria-label="Filtros do painel">
      <div><label for="fYear">Ano de instalação</label><select id="fYear"></select></div>
      <div><label for="fBairro">Bairro</label><select id="fBairro"></select></div>
      <div><label for="fSituacao">Situação da água</label><select id="fSituacao"></select></div>
      <div><label for="fConsumo">Tipo de consumo</label><select id="fConsumo"></select></div>
      <button id="reset">Limpar filtros</button>
    </section>

    <section class="kpis">
      <article class="card kpi" style="--accent-color:var(--brand)"><div class="name">Instalações</div><div class="value" id="kTotal">0</div><div class="sub" id="kTotalSub">registros sem duplicidade exata</div></article>
      <article class="card kpi" style="--accent-color:var(--success)"><div class="name">Bairros</div><div class="value" id="kBairros">0</div><div class="sub">com instalação no recorte</div></article>
      <article class="card kpi" style="--accent-color:var(--warning)"><div class="name">Água ligada</div><div class="value" id="kLigado">0%</div><div class="sub" id="kLigadoSub">0 ligações</div></article>
      <article class="card kpi" style="--accent-color:var(--violet)"><div class="name">Consumo real</div><div class="value" id="kReal">0%</div><div class="sub" id="kRealSub">0 instalações</div></article>
    </section>

    <aside class="card quality"><div>⚠️</div><div><strong>Leitura e qualidade dos dados</strong><p id="qualityText"></p></div></aside>

    <section class="grid">
      <article class="card chart-card">
        <div class="chart-head"><div><h2>Instalações por ano</h2><p>Evolução anual conforme o recorte selecionado</p></div></div>
        <div class="canvas-scroll" id="yearScroll"><canvas id="yearChart" height="340"></canvas></div>
      </article>
      <article class="card chart-card">
        <div class="chart-head"><div><h2>Situação da água</h2><p>Participação de cada situação</p></div></div>
        <div class="donut-wrap"><canvas id="situationChart" width="300" height="300"></canvas><div class="legend" id="situationLegend"></div></div>
      </article>
    </section>

    <section class="grid equal">
      <article class="card chart-card">
        <div class="chart-head"><div><h2>Instalações por bairro</h2><p>Ranking territorial no recorte selecionado</p></div><select id="bairroLimit" aria-label="Quantidade de bairros no gráfico"><option value="10">Top 10</option><option value="20" selected>Top 20</option><option value="50">Top 50</option><option value="0">Todos</option></select></div>
        <div class="canvas-scroll vertical" id="bairroScroll"><canvas id="bairroChart"></canvas></div>
      </article>
      <article class="card chart-card">
        <div class="chart-head"><div><h2>Tipo de consumo de água</h2><p>Classificação do consumo dos hidrômetros</p></div></div>
        <div class="canvas-scroll" id="consumoScroll"><canvas id="consumoChart"></canvas></div>
      </article>
    </section>

    <section class="card table-card">
      <div class="chart-head"><div><h2>Ranking completo de bairros</h2><p id="tableSummary">Todos os bairros do recorte</p></div><div class="table-tools"><input id="bairroSearch" type="search" placeholder="Pesquisar bairro..." aria-label="Pesquisar bairro"><button class="btn-primary" id="exportCsv">Exportar ranking CSV</button></div></div>
      <div class="table-wrap"><table><thead><tr><th>#</th><th>Bairro</th><th>Instalações</th><th>Participação</th></tr></thead><tbody id="bairroTable"></tbody></table></div>
    </section>
    <footer id="footer"></footer>
  </main>

  <script>
    const BI = __BI_DATA__;
    const colors=['#0ea5e9','#34d399','#fbbf24','#fb7185','#a78bfa','#38bdf8','#2dd4bf','#f472b6','#94a3b8'];
    const FONT='Inter,"Segoe UI",Arial';
    const cssv=n=>getComputedStyle(document.documentElement).getPropertyValue(n).trim();
    const T=()=>({text:cssv('--text'),muted:cssv('--muted'),grid:cssv('--grid'),track:cssv('--track'),brand:cssv('--brand'),accent:cssv('--accent')});
    const nf=new Intl.NumberFormat('pt-BR');
    const pf=new Intl.NumberFormat('pt-BR',{style:'percent',minimumFractionDigits:1,maximumFractionDigits:1});
    const $=id=>document.getElementById(id);
    const filters={year:$('fYear'),bairro:$('fBairro'),situacao:$('fSituacao'),consumo:$('fConsumo')};
    let currentRows=[],bairroRanking=[];

    function uniq(field){return [...new Set(BI.data.map(d=>d[field]))].sort((a,b)=>field==='y'?(Number(a)||9999)-(Number(b)||9999):a.localeCompare(b,'pt-BR'));}
    function fillSelect(el,values,label){el.innerHTML=`<option value="">${label}</option>`+values.map(v=>`<option value="${esc(v)}">${esc(v)}</option>`).join('');}
    function esc(s){return String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));}
    function init(){
      fillSelect(filters.year,uniq('y'),'Todos os anos');fillSelect(filters.bairro,uniq('b'),'Todos os bairros');
      fillSelect(filters.situacao,uniq('s'),'Todas as situações');fillSelect(filters.consumo,uniq('c'),'Todos os tipos');
      Object.values(filters).forEach(el=>el.addEventListener('change',render));
      $('bairroLimit').addEventListener('change',()=>drawBairros(bairroRanking));
      $('bairroSearch').addEventListener('input',renderTable);
      $('reset').addEventListener('click',()=>{Object.values(filters).forEach(x=>x.value='');$('bairroSearch').value='';render();});
      $('exportCsv').addEventListener('click',exportRanking);
      $('themeToggle').addEventListener('click',()=>{const dark=document.documentElement.dataset.theme==='dark';document.documentElement.dataset.theme=dark?'light':'dark';localStorage.setItem('tema',dark?'claro':'escuro');syncTheme();renderCharts();});
      syncTheme();
      window.addEventListener('resize',debounce(renderCharts,140));
      const startDate=new Date(BI.periodStart+'T00:00:00').toLocaleDateString('pt-BR');
      const endDate=new Date(BI.periodEnd+'T00:00:00').toLocaleDateString('pt-BR');
      $('qualityText').textContent=`Período de instalações: ${startDate} a ${endDate}. O parque de hidrômetro possui ${nf.format(BI.totalRaw)} registros; ${nf.format(BI.excludedBeforePeriod)} registros anteriores a 2016.`;
      $('footer').textContent=`Fonte: ${BI.source} • Período: ${startDate} a ${endDate} • BI gerado em ${BI.generatedAt} • Dados processados localmente.`;
      render();
    }
    function debounce(fn,ms){let t;return()=>{clearTimeout(t);t=setTimeout(fn,ms)}}
    function syncTheme(){$('themeToggle').textContent=document.documentElement.dataset.theme==='dark'?'Tema claro':'Tema escuro';}
    function filtered(){return BI.data.filter(d=>(!filters.year.value||d.y===filters.year.value)&&(!filters.bairro.value||d.b===filters.bairro.value)&&(!filters.situacao.value||d.s===filters.situacao.value)&&(!filters.consumo.value||d.c===filters.consumo.value));}
    function group(rows,field){const m=new Map();rows.forEach(d=>m.set(d[field],(m.get(d[field])||0)+d.n));return [...m].map(([label,value])=>({label,value}));}
    function total(rows){return rows.reduce((s,d)=>s+d.n,0)}
    function render(){currentRows=filtered();const t=total(currentRows);bairroRanking=group(currentRows,'b').sort((a,b)=>b.value-a.value||a.label.localeCompare(b.label,'pt-BR'));
      const sit=group(currentRows,'s'),cons=group(currentRows,'c');const ligados=sit.filter(x=>x.label.toLocaleUpperCase('pt-BR')==='LIGADO').reduce((s,x)=>s+x.value,0);const reais=cons.filter(x=>x.label.toLocaleUpperCase('pt-BR')==='REAL').reduce((s,x)=>s+x.value,0);
      $('kTotal').textContent=nf.format(t);$('kBairros').textContent=nf.format(bairroRanking.length);$('kLigado').textContent=t?pf.format(ligados/t):'0%';$('kLigadoSub').textContent=`${nf.format(ligados)} ligações`;$('kReal').textContent=t?pf.format(reais/t):'0%';$('kRealSub').textContent=`${nf.format(reais)} instalações`;
      $('kTotalSub').textContent=t===BI.total?'instalações desde 2016':'no recorte selecionado';renderCharts();renderTable();
    }
    function renderCharts(){drawYears(group(currentRows,'y'));drawDonut(group(currentRows,'s').sort((a,b)=>b.value-a.value));drawBairros(bairroRanking);drawConsumption(group(currentRows,'c').sort((a,b)=>b.value-a.value));}
    function setupCanvas(canvas,w,h){const dpr=Math.min(window.devicePixelRatio||1,2);canvas.style.width=w+'px';canvas.style.height=h+'px';canvas.width=Math.round(w*dpr);canvas.height=Math.round(h*dpr);const ctx=canvas.getContext('2d');ctx.setTransform(dpr,0,0,dpr,0,0);ctx.font='12px '+FONT;return ctx;}
    function roundedRect(ctx,x,y,w,h,r){r=Math.min(r,Math.abs(w)/2,Math.abs(h)/2);ctx.beginPath();ctx.roundRect(x,y,w,h,r);ctx.fill()}
    function noData(container,id){const c=$(id);const ctx=setupCanvas(c,Math.max(container.clientWidth,300),250);ctx.fillStyle=T().muted;ctx.textAlign='center';ctx.fillText('Nenhum dado para os filtros selecionados',c.clientWidth/2,125)}
    function drawYears(items){const wrap=$('yearScroll');const numeric=items.filter(x=>/^\d{4}$/.test(x.label)).sort((a,b)=>+a.label-+b.label);if(!numeric.length)return noData(wrap,'yearChart');const th=T(),w=Math.max(wrap.clientWidth||500,numeric.length*64+74),h=340,ctx=setupCanvas($('yearChart'),w,h),left=58,right=20,top=38,bottom=62,plotW=w-left-right,plotH=h-top-bottom,max=Math.max(...numeric.map(x=>x.value),1);ctx.strokeStyle=th.grid;ctx.fillStyle=th.muted;ctx.textAlign='right';ctx.textBaseline='middle';for(let i=0;i<=4;i++){const y=top+plotH*i/4,val=max*(1-i/4);ctx.beginPath();ctx.moveTo(left,y);ctx.lineTo(w-right,y);ctx.stroke();ctx.fillText(compact(val),left-8,y)}const step=plotW/numeric.length,bw=Math.max(10,step*.66);numeric.forEach((d,i)=>{const bh=d.value/max*plotH,x=left+i*step+(step-bw)/2,y=top+plotH-bh;const grad=ctx.createLinearGradient(0,y,0,top+plotH);grad.addColorStop(0,'#38bdf8');grad.addColorStop(1,th.brand);ctx.fillStyle=grad;roundedRect(ctx,x,y,bw,bh,6);ctx.fillStyle=th.text;ctx.font='800 11px '+FONT;ctx.textAlign='center';ctx.textBaseline='bottom';ctx.fillText(nf.format(d.value),x+bw/2,Math.max(15,y-5));ctx.font='12px '+FONT;ctx.save();ctx.translate(x+bw/2,h-bottom+10);ctx.rotate(-Math.PI/4);ctx.fillStyle=th.muted;ctx.textAlign='right';ctx.textBaseline='middle';ctx.fillText(d.label,0,0);ctx.restore()});}
    function drawBairros(items){const limit=+$('bairroLimit').value,shown=limit?items.slice(0,limit):items;const wrap=$('bairroScroll');if(!shown.length)return noData(wrap,'bairroChart');const th=T(),w=Math.max(wrap.clientWidth||500,520),rowH=31,h=Math.max(180,shown.length*rowH+30),ctx=setupCanvas($('bairroChart'),w,h),left=Math.min(205,w*.39),right=65,max=Math.max(...shown.map(x=>x.value),1);shown.forEach((d,i)=>{const y=16+i*rowH,bw=(w-left-right)*d.value/max;ctx.fillStyle=th.muted;ctx.textAlign='right';ctx.textBaseline='middle';ctx.fillText(shorten(d.label,left<170?19:28),left-10,y+8);ctx.fillStyle=th.track;roundedRect(ctx,left,y,w-left-right,16,999);const g=ctx.createLinearGradient(left,0,w-right,0);g.addColorStop(0,th.brand);g.addColorStop(1,'#2dd4bf');ctx.fillStyle=g;roundedRect(ctx,left,y,bw,16,999);ctx.fillStyle=th.text;ctx.font='800 12px '+FONT;ctx.textAlign='left';ctx.fillText(nf.format(d.value),left+bw+7,y+8);ctx.font='12px '+FONT});}
    function drawConsumption(items){const wrap=$('consumoScroll');if(!items.length)return noData(wrap,'consumoChart');const th=T(),w=Math.max(wrap.clientWidth||500,440),rowH=37,h=Math.max(300,items.length*rowH+30),ctx=setupCanvas($('consumoChart'),w,h),left=Math.min(190,w*.38),right=74,max=Math.max(...items.map(x=>x.value),1);items.forEach((d,i)=>{const y=16+i*rowH,bw=(w-left-right)*d.value/max;ctx.fillStyle=th.muted;ctx.textAlign='right';ctx.textBaseline='middle';ctx.fillText(shorten(d.label,left<165?18:26),left-10,y+9);ctx.fillStyle=th.track;roundedRect(ctx,left,y,w-left-right,18,999);ctx.fillStyle=colors[i%colors.length];roundedRect(ctx,left,y,bw,18,999);ctx.fillStyle=th.text;ctx.font='800 12px '+FONT;ctx.textAlign='left';ctx.fillText(nf.format(d.value),left+bw+7,y+9);ctx.font='12px '+FONT});}
    function drawDonut(items){const th=T(),canvas=$('situationChart'),wrap=canvas.parentElement,w=Math.min(Math.max(wrap.clientWidth*.5,190),300),h=w,ctx=setupCanvas(canvas,w,h),t=items.reduce((s,x)=>s+x.value,0),cx=w/2,cy=h/2,r=w*.36,inner=r*.66;if(!t){ctx.fillStyle=th.muted;ctx.textAlign='center';ctx.fillText('Sem dados',cx,cy);$('situationLegend').innerHTML='';return}let a=-Math.PI/2;items.forEach((d,i)=>{const next=a+d.value/t*Math.PI*2;ctx.beginPath();ctx.arc(cx,cy,r,a,next);ctx.arc(cx,cy,inner,next,a,true);ctx.closePath();ctx.fillStyle=colors[i%colors.length];ctx.fill();a=next});ctx.fillStyle=th.text;ctx.textAlign='center';ctx.textBaseline='middle';ctx.font='900 22px '+FONT;ctx.fillText(compact(t),cx,cy-6);ctx.fillStyle=th.muted;ctx.font='11px '+FONT;ctx.fillText('instalações',cx,cy+15);$('situationLegend').innerHTML=items.map((d,i)=>`<div class="legend-row"><i class="dot" style="background:${colors[i%colors.length]}"></i><span>${esc(d.label)} <small>(${pf.format(d.value/t)})</small></span><b>${nf.format(d.value)}</b></div>`).join('');}
    function compact(n){return Intl.NumberFormat('pt-BR',{notation:'compact',maximumFractionDigits:1}).format(Math.round(n))}
    function shorten(s,n){return s.length>n?s.slice(0,n-1)+'…':s}
    function renderTable(){const q=$('bairroSearch').value.trim().toLocaleUpperCase('pt-BR'),rows=bairroRanking.filter(x=>!q||x.label.toLocaleUpperCase('pt-BR').includes(q)),t=bairroRanking.reduce((s,x)=>s+x.value,0),max=bairroRanking[0]?.value||1;$('bairroTable').innerHTML=rows.map((d,i)=>`<tr><td>${i+1}</td><td>${esc(d.label)}</td><td>${nf.format(d.value)}</td><td><div class="mini-bar" title="${t?pf.format(d.value/t):'0%'}"><i style="width:${d.value/max*100}%"></i></div></td></tr>`).join('');$('tableSummary').textContent=`${nf.format(rows.length)} bairro(s) exibido(s) • ${nf.format(t)} instalações no recorte`;}
    function exportRanking(){const t=bairroRanking.reduce((s,x)=>s+x.value,0);const lines=['Posição;Bairro;Instalações;Participação'];bairroRanking.forEach((d,i)=>lines.push(`${i+1};"${d.label.replaceAll('"','""')}";${d.value};${t?(d.value/t*100).toFixed(2).replace('.',','):0}%`));const blob=new Blob(['\ufeff'+lines.join('\r\n')],{type:'text/csv;charset=utf-8'}),a=document.createElement('a');a.href=URL.createObjectURL(blob);a.download='ranking_bairros_hidrometros.csv';a.click();URL.revokeObjectURL(a.href);}
    init();
  </script>
</body>
</html>
'@

$html = $html.Replace('__BI_DATA__', $json)
$outputDirectory = Split-Path -Parent $OutputPath
if ($outputDirectory -and -not (Test-Path -LiteralPath $outputDirectory)) {
    [void](New-Item -ItemType Directory -Path $outputDirectory)
}
[IO.File]::WriteAllText($OutputPath, $html, [Text.UTF8Encoding]::new($false))

Write-Host "Dashboard gerado: $OutputPath"
Write-Host "Registros no período: $includedCount | Bairros: $($neighborhoods.Count) | Duplicidades removidas: $duplicateRows"
