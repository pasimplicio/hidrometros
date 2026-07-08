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
  <style>
    :root {
      --bg:#f4f7fb; --card:#fff; --ink:#172033; --muted:#64748b;
      --line:#dfe7f1; --blue:#1667d9; --blue2:#65a5f5; --teal:#0f9f8f;
      --amber:#e99a16; --red:#dc4c64; --violet:#7856d8; --shadow:0 7px 24px rgba(26,43,72,.08);
    }
    *{box-sizing:border-box} body{margin:0;background:var(--bg);color:var(--ink);font-family:Inter,Segoe UI,Arial,sans-serif}
    header{background:linear-gradient(120deg,#102a56,#135fa8 62%,#078a8d);color:#fff;padding:28px 4vw 52px}
    header .eyebrow{text-transform:uppercase;letter-spacing:.12em;font-size:11px;font-weight:700;opacity:.76}
    header h1{font-size:clamp(24px,3.2vw,40px);margin:7px 0 6px;line-height:1.1}
    header p{margin:0;opacity:.82;font-size:14px}
    main{width:min(1540px,94vw);margin:-29px auto 44px}
    .card{background:var(--card);border:1px solid rgba(221,230,241,.85);border-radius:15px;box-shadow:var(--shadow)}
    .filters{padding:16px;display:grid;grid-template-columns:repeat(4,minmax(150px,1fr)) auto;gap:12px;align-items:end}
    label{display:block;color:var(--muted);font-size:11px;font-weight:700;text-transform:uppercase;letter-spacing:.05em;margin:0 0 6px}
    select,input,button{font:inherit;border:1px solid #ced9e7;border-radius:9px;background:#fff;color:var(--ink);height:40px;padding:0 11px;width:100%}
    select:focus,input:focus{outline:2px solid rgba(22,103,217,.2);border-color:var(--blue)}
    button{width:auto;cursor:pointer;background:#edf4ff;color:#165daf;border-color:#c7daf5;font-weight:700;white-space:nowrap}
    button:hover{background:#e2edfc}.btn-primary{background:var(--blue);color:#fff;border-color:var(--blue)}.btn-primary:hover{background:#0d57bd}
    .kpis{display:grid;grid-template-columns:repeat(4,1fr);gap:14px;margin:14px 0}
    .kpi{padding:18px 20px;position:relative;overflow:hidden}.kpi:after{content:"";position:absolute;width:80px;height:80px;border-radius:50%;right:-32px;top:-36px;background:var(--accent);opacity:.12}
    .kpi .name{font-size:12px;color:var(--muted);font-weight:700;text-transform:uppercase;letter-spacing:.04em}.kpi .value{font-size:clamp(24px,2.5vw,34px);font-weight:800;margin-top:5px}.kpi .sub{font-size:12px;color:var(--muted);margin-top:3px}
    .grid{display:grid;grid-template-columns:1.35fr .85fr;gap:14px;margin-bottom:14px}.grid.equal{grid-template-columns:1fr 1fr}
    .chart-card{padding:18px;min-width:0}.chart-head{display:flex;align-items:start;justify-content:space-between;gap:12px;margin-bottom:12px}.chart-head h2{font-size:16px;margin:0}.chart-head p{font-size:12px;color:var(--muted);margin:4px 0 0}.chart-head select{height:32px;font-size:12px;width:auto}
    .canvas-scroll{overflow:auto;max-width:100%;position:relative}.canvas-scroll.vertical{max-height:560px}canvas{display:block}
    .quality{padding:15px 18px;margin-bottom:14px;display:flex;gap:18px;align-items:flex-start;border-left:4px solid var(--amber)}.quality strong{font-size:13px}.quality p{font-size:12px;color:var(--muted);margin:4px 0 0;line-height:1.55}
    .donut-wrap{display:grid;grid-template-columns:minmax(180px,1fr) minmax(180px,1fr);align-items:center;gap:8px}.legend{font-size:12px}.legend-row{display:grid;grid-template-columns:11px 1fr auto;gap:8px;align-items:center;padding:6px 0;border-bottom:1px solid #edf1f6}.dot{width:10px;height:10px;border-radius:3px}.legend-row b{font-variant-numeric:tabular-nums}
    .table-card{padding:18px}.table-tools{display:flex;gap:10px;align-items:end}.table-tools input{width:min(290px,42vw)}
    .table-wrap{overflow:auto;max-height:520px;border:1px solid var(--line);border-radius:10px;margin-top:12px}table{width:100%;border-collapse:collapse;font-size:13px}th{position:sticky;top:0;background:#edf3fa;text-align:left;color:#526277;font-size:11px;text-transform:uppercase;letter-spacing:.04em;z-index:1}th,td{padding:10px 12px;border-bottom:1px solid #e9eff6}td:nth-child(1),td:nth-child(3){font-variant-numeric:tabular-nums}td:nth-child(3),th:nth-child(3){text-align:right}.mini-bar{height:6px;background:#dbe9fa;border-radius:9px;overflow:hidden;min-width:100px}.mini-bar i{display:block;height:100%;background:linear-gradient(90deg,var(--blue),var(--teal));border-radius:9px}
    footer{text-align:center;color:var(--muted);font-size:11px;margin-top:16px}
    .empty{height:250px;display:grid;place-items:center;color:var(--muted);font-size:13px}
    @media(max-width:950px){.filters{grid-template-columns:repeat(2,1fr)}.grid,.grid.equal{grid-template-columns:1fr}.kpis{grid-template-columns:repeat(2,1fr)}}
    @media(max-width:560px){main{width:96vw}.filters,.kpis{grid-template-columns:1fr}.filters button{width:100%}.donut-wrap{grid-template-columns:1fr}.chart-card,.table-card{padding:14px}.table-tools{align-items:stretch;flex-direction:column}.table-tools input,.table-tools button{width:100%}}
  </style>
</head>
<body>
  <header>
    <div class="eyebrow">Visão gerencial</div>
    <h1>Hidrômetros de São Luís</h1>
    <p>Instalações de 2016 até hoje, distribuição territorial, situação da água e perfil de consumo</p>
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
      <article class="card kpi" style="--accent:var(--blue)"><div class="name">Instalações</div><div class="value" id="kTotal">0</div><div class="sub" id="kTotalSub">registros sem duplicidade exata</div></article>
      <article class="card kpi" style="--accent:var(--teal)"><div class="name">Bairros</div><div class="value" id="kBairros">0</div><div class="sub">com instalação no recorte</div></article>
      <article class="card kpi" style="--accent:var(--amber)"><div class="name">Água ligada</div><div class="value" id="kLigado">0%</div><div class="sub" id="kLigadoSub">0 ligações</div></article>
      <article class="card kpi" style="--accent:var(--violet)"><div class="name">Consumo real</div><div class="value" id="kReal">0%</div><div class="sub" id="kRealSub">0 instalações</div></article>
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
    const colors=['#1667d9','#0f9f8f','#e99a16','#dc4c64','#7856d8','#38a6d8','#7dab46','#a96cad','#8b98a9'];
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
      window.addEventListener('resize',debounce(renderCharts,140));
      const startDate=new Date(BI.periodStart+'T00:00:00').toLocaleDateString('pt-BR');
      const endDate=new Date(BI.periodEnd+'T00:00:00').toLocaleDateString('pt-BR');
      $('qualityText').textContent=`Período de instalações: ${startDate} a ${endDate}. O parque de hidrômetro possui ${nf.format(BI.totalRaw)} registros; ${nf.format(BI.excludedBeforePeriod)} registros anteriores a 2016.`;
      $('footer').textContent=`Fonte: ${BI.source} • Período: ${startDate} a ${endDate} • BI gerado em ${BI.generatedAt} • Dados processados localmente.`;
      render();
    }
    function debounce(fn,ms){let t;return()=>{clearTimeout(t);t=setTimeout(fn,ms)}}
    function filtered(){return BI.data.filter(d=>(!filters.year.value||d.y===filters.year.value)&&(!filters.bairro.value||d.b===filters.bairro.value)&&(!filters.situacao.value||d.s===filters.situacao.value)&&(!filters.consumo.value||d.c===filters.consumo.value));}
    function group(rows,field){const m=new Map();rows.forEach(d=>m.set(d[field],(m.get(d[field])||0)+d.n));return [...m].map(([label,value])=>({label,value}));}
    function total(rows){return rows.reduce((s,d)=>s+d.n,0)}
    function render(){currentRows=filtered();const t=total(currentRows);bairroRanking=group(currentRows,'b').sort((a,b)=>b.value-a.value||a.label.localeCompare(b.label,'pt-BR'));
      const sit=group(currentRows,'s'),cons=group(currentRows,'c');const ligados=sit.filter(x=>x.label.toLocaleUpperCase('pt-BR')==='LIGADO').reduce((s,x)=>s+x.value,0);const reais=cons.filter(x=>x.label.toLocaleUpperCase('pt-BR')==='REAL').reduce((s,x)=>s+x.value,0);
      $('kTotal').textContent=nf.format(t);$('kBairros').textContent=nf.format(bairroRanking.length);$('kLigado').textContent=t?pf.format(ligados/t):'0%';$('kLigadoSub').textContent=`${nf.format(ligados)} ligações`;$('kReal').textContent=t?pf.format(reais/t):'0%';$('kRealSub').textContent=`${nf.format(reais)} instalações`;
      $('kTotalSub').textContent=t===BI.total?'instalações desde 2016':'no recorte selecionado';renderCharts();renderTable();
    }
    function renderCharts(){drawYears(group(currentRows,'y'));drawDonut(group(currentRows,'s').sort((a,b)=>b.value-a.value));drawBairros(bairroRanking);drawConsumption(group(currentRows,'c').sort((a,b)=>b.value-a.value));}
    function setupCanvas(canvas,w,h){const dpr=Math.min(window.devicePixelRatio||1,2);canvas.style.width=w+'px';canvas.style.height=h+'px';canvas.width=Math.round(w*dpr);canvas.height=Math.round(h*dpr);const ctx=canvas.getContext('2d');ctx.setTransform(dpr,0,0,dpr,0,0);ctx.font='12px Segoe UI,Arial';return ctx;}
    function roundedRect(ctx,x,y,w,h,r){r=Math.min(r,Math.abs(w)/2,Math.abs(h)/2);ctx.beginPath();ctx.roundRect(x,y,w,h,r);ctx.fill()}
    function noData(container,id){const c=$(id);const ctx=setupCanvas(c,Math.max(container.clientWidth,300),250);ctx.fillStyle='#64748b';ctx.textAlign='center';ctx.fillText('Nenhum dado para os filtros selecionados',c.clientWidth/2,125)}
    function drawYears(items){const wrap=$('yearScroll');const numeric=items.filter(x=>/^\d{4}$/.test(x.label)).sort((a,b)=>+a.label-+b.label);if(!numeric.length)return noData(wrap,'yearChart');const w=Math.max(wrap.clientWidth||500,numeric.length*64+74),h=340,ctx=setupCanvas($('yearChart'),w,h),left=58,right=20,top=38,bottom=62,plotW=w-left-right,plotH=h-top-bottom,max=Math.max(...numeric.map(x=>x.value),1);ctx.strokeStyle='#e4ebf3';ctx.fillStyle='#6b7b90';ctx.textAlign='right';ctx.textBaseline='middle';for(let i=0;i<=4;i++){const y=top+plotH*i/4,val=max*(1-i/4);ctx.beginPath();ctx.moveTo(left,y);ctx.lineTo(w-right,y);ctx.stroke();ctx.fillText(compact(val),left-8,y)}const step=plotW/numeric.length,bw=Math.max(10,step*.66);numeric.forEach((d,i)=>{const bh=d.value/max*plotH,x=left+i*step+(step-bw)/2,y=top+plotH-bh;const grad=ctx.createLinearGradient(0,y,0,top+plotH);grad.addColorStop(0,'#1667d9');grad.addColorStop(1,'#65a5f5');ctx.fillStyle=grad;roundedRect(ctx,x,y,bw,bh,4);ctx.fillStyle='#33445a';ctx.font='600 11px Segoe UI,Arial';ctx.textAlign='center';ctx.textBaseline='bottom';ctx.fillText(nf.format(d.value),x+bw/2,Math.max(15,y-5));ctx.font='12px Segoe UI,Arial';ctx.save();ctx.translate(x+bw/2,h-bottom+10);ctx.rotate(-Math.PI/4);ctx.fillStyle='#526277';ctx.textAlign='right';ctx.textBaseline='middle';ctx.fillText(d.label,0,0);ctx.restore()});}
    function drawBairros(items){const limit=+$('bairroLimit').value,shown=limit?items.slice(0,limit):items;const wrap=$('bairroScroll');if(!shown.length)return noData(wrap,'bairroChart');const w=Math.max(wrap.clientWidth||500,520),rowH=31,h=Math.max(180,shown.length*rowH+30),ctx=setupCanvas($('bairroChart'),w,h),left=Math.min(205,w*.39),right=65,max=Math.max(...shown.map(x=>x.value),1);shown.forEach((d,i)=>{const y=16+i*rowH,bw=(w-left-right)*d.value/max;ctx.fillStyle='#526277';ctx.textAlign='right';ctx.textBaseline='middle';ctx.fillText(shorten(d.label,left<170?19:28),left-10,y+8);ctx.fillStyle='#e6eef8';roundedRect(ctx,left,y,w-left-right,16,5);const g=ctx.createLinearGradient(left,0,w-right,0);g.addColorStop(0,'#1667d9');g.addColorStop(1,'#0f9f8f');ctx.fillStyle=g;roundedRect(ctx,left,y,bw,16,5);ctx.fillStyle='#33445a';ctx.textAlign='left';ctx.fillText(nf.format(d.value),left+bw+7,y+8)});}
    function drawConsumption(items){const wrap=$('consumoScroll');if(!items.length)return noData(wrap,'consumoChart');const w=Math.max(wrap.clientWidth||500,440),rowH=37,h=Math.max(300,items.length*rowH+30),ctx=setupCanvas($('consumoChart'),w,h),left=Math.min(190,w*.38),right=74,max=Math.max(...items.map(x=>x.value),1);items.forEach((d,i)=>{const y=16+i*rowH,bw=(w-left-right)*d.value/max;ctx.fillStyle='#526277';ctx.textAlign='right';ctx.textBaseline='middle';ctx.fillText(shorten(d.label,left<165?18:26),left-10,y+9);ctx.fillStyle='#edf1f6';roundedRect(ctx,left,y,w-left-right,18,5);ctx.fillStyle=colors[i%colors.length];roundedRect(ctx,left,y,bw,18,5);ctx.fillStyle='#33445a';ctx.textAlign='left';ctx.fillText(nf.format(d.value),left+bw+7,y+9)});}
    function drawDonut(items){const canvas=$('situationChart'),wrap=canvas.parentElement,w=Math.min(Math.max(wrap.clientWidth*.5,190),300),h=w,ctx=setupCanvas(canvas,w,h),t=items.reduce((s,x)=>s+x.value,0),cx=w/2,cy=h/2,r=w*.36,inner=r*.61;if(!t){ctx.fillStyle='#64748b';ctx.textAlign='center';ctx.fillText('Sem dados',cx,cy);$('situationLegend').innerHTML='';return}let a=-Math.PI/2;items.forEach((d,i)=>{const next=a+d.value/t*Math.PI*2;ctx.beginPath();ctx.arc(cx,cy,r,a,next);ctx.arc(cx,cy,inner,next,a,true);ctx.closePath();ctx.fillStyle=colors[i%colors.length];ctx.fill();a=next});ctx.fillStyle='#172033';ctx.textAlign='center';ctx.textBaseline='middle';ctx.font='700 22px Segoe UI,Arial';ctx.fillText(compact(t),cx,cy-6);ctx.fillStyle='#64748b';ctx.font='11px Segoe UI,Arial';ctx.fillText('instalações',cx,cy+15);$('situationLegend').innerHTML=items.map((d,i)=>`<div class="legend-row"><i class="dot" style="background:${colors[i%colors.length]}"></i><span>${esc(d.label)} <small>(${pf.format(d.value/t)})</small></span><b>${nf.format(d.value)}</b></div>`).join('');}
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
