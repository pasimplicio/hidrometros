param(
    [string]$CsvPath = (Join-Path $PSScriptRoot 'dados_hidrometros_slz.csv'),
    [string]$OutputPath = (Join-Path $PSScriptRoot 'index.html')
)

$ErrorActionPreference = 'Stop'

function Clean-Value([object]$Value) {
    if ($null -eq $Value) { return '(Não informado)' }
    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return '(Não informado)' }
    return $text
}

# A execução própria da CAEMA passou a se chamar 'EQUIPE CAEMA'. A query já
# emite o nome novo, mas CSVs gerados antes ainda trazem 'FORA DOS CONTRATOS':
# normaliza as duas cargas.
function Rename-Empresa([string]$Empresa) {
    if ($Empresa -eq 'FORA DOS CONTRATOS') { return 'EQUIPE CAEMA' }
    return $Empresa
}

if (-not (Test-Path -LiteralPath $CsvPath)) {
    throw "CSV não encontrado: $CsvPath"
}

# --- Parametros da meta do acordo -------------------------------------------
$metaTotal = 130000        # hidrometros a instalar desde 2016
$metaAnoBase = 2026        # primeiro ano com meta pactuada
$metaAnoBaseQtd = 7700     # meta do ano base
$metaCrescimento = 0.10    # crescimento anual da meta

$rows = Import-Csv -LiteralPath $CsvPath -Delimiter ';' -Encoding UTF8
$today = [datetime]::Today
$periodStart = [datetime]'2016-01-01'

# --- Passe 1: reduzir os eventos a HIDROMETROS DISTINTOS ---------------------
# A base traz um registro por evento de instalacao, entao o mesmo hidrometro
# (NR HID.) reaparece a cada reinstalacao. A meta conta hidrometro fisico, nao
# evento: cada NR HID. entra uma vez so, no ano da PRIMEIRA instalacao.
$meters = @{}
$invalidDates = 0
$missingSerial = 0
$reinstalls = 0

foreach ($row in $rows) {
    $serial = Clean-Value $row.'NR HID.'
    if ($serial -eq '(Não informado)') { $missingSerial++; continue }

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

    if ($meters.ContainsKey($serial)) {
        $reinstalls++
        # so troca se esta instalacao for anterior a que ja temos
        if ($parsedDate.Date -ge $meters[$serial].Dt) { continue }
    }

    $meters[$serial] = [pscustomobject]@{
        Dt      = $parsedDate.Date
        Bairro  = Clean-Value $row.BAIRRO
        Empresa = Rename-Empresa (Clean-Value $row.'EMPRESA CONTRATADA')
        Situacao = Clean-Value $row.'SITUACAO AGUA'
        Consumo = Clean-Value $row.'TIPO CONSUMO AGUA'
        Status  = Clean-Value $row.'STATUS HIDROMETRO'
    }
}

# --- Passe 2: montar o cubo com os hidrometros do periodo -------------------
$cube = @{}
$neighborhoods = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$missingConsumption = 0
$futureDates = 0
$includedCount = 0
$excludedBeforePeriod = 0
$activeCount = 0
$perYear = @{}

foreach ($m in $meters.Values) {
    if ($m.Dt -lt $periodStart) { $excludedBeforePeriod++; continue }
    if ($m.Dt -gt $today) { $futureDates++; continue }

    $ano = [string]$m.Dt.Year
    if ($m.Consumo -eq '(Não informado)') { $missingConsumption++ }
    if ($m.Status -eq 'ATIVO') { $activeCount++ }
    [void]$neighborhoods.Add($m.Bairro)
    $includedCount++

    if (-not $perYear.ContainsKey($ano)) { $perYear[$ano] = 0 }
    $perYear[$ano]++

    $key = @($ano, $m.Bairro, $m.Empresa, $m.Situacao, $m.Consumo, $m.Status) -join [char]30
    if ($cube.ContainsKey($key)) {
        $cube[$key].n++
    }
    else {
        $cube[$key] = [pscustomobject]@{
            y = $ano
            b = $m.Bairro
            e = $m.Empresa
            s = $m.Situacao
            c = $m.Consumo
            t = $m.Status
            n = 1
        }
    }
}

# Serie realizada acumulada, ano a ano
$realized = @()
$acc = 0
foreach ($ano in ($perYear.Keys | Sort-Object { [int]$_ })) {
    $acc += $perYear[$ano]
    $realized += [pscustomobject]@{ y = [int]$ano; n = $perYear[$ano]; acc = $acc }
}

$cubeRows = @($cube.Values | Sort-Object y, b, e, s, c, t)
$payload = [ordered]@{
    generatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm')
    source = [IO.Path]::GetFileName($CsvPath)
    totalRaw = $rows.Count
    totalMeters = $meters.Count
    reinstalls = $reinstalls
    total = $includedCount
    active = $activeCount
    neighborhoods = $neighborhoods.Count
    missingConsumption = $missingConsumption
    missingSerial = $missingSerial
    invalidDates = $invalidDates
    futureDates = $futureDates
    excludedBeforePeriod = $excludedBeforePeriod
    periodStart = $periodStart.ToString('yyyy-MM-dd')
    periodEnd = $today.ToString('yyyy-MM-dd')
    currentYear = $today.Year
    meta = [ordered]@{
        total = $metaTotal
        baseYear = $metaAnoBase
        baseQty = $metaAnoBaseQtd
        growth = $metaCrescimento
    }
    realized = $realized
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
    .filters{padding:1.05rem 1.15rem;display:grid;grid-template-columns:repeat(5,minmax(140px,1fr)) auto;gap:14px;align-items:end}
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
    .share{display:grid;grid-template-columns:1fr auto;gap:.7rem;align-items:center}
    .share b{font-variant-numeric:tabular-nums;font-size:.72rem;font-weight:800;color:var(--muted);min-width:3.4rem;text-align:right}
    .mini-bar{height:7px;background:var(--track);border-radius:999px;overflow:hidden;min-width:100px}
    .mini-bar i{display:block;height:100%;background:linear-gradient(90deg,var(--brand),#2dd4bf);border-radius:999px}

    /* Meta 130 mil */
    .meta-verdict{padding:.5rem .9rem;border-radius:999px;font-size:.72rem;font-weight:800;white-space:nowrap;border:1px solid}
    .meta-verdict.ok{color:var(--success);background:rgba(52,211,153,.09);border-color:rgba(52,211,153,.28)}
    .meta-verdict.warn{color:var(--warning);background:rgba(251,191,36,.09);border-color:rgba(251,191,36,.28)}
    .meta-stats{display:grid;grid-template-columns:repeat(4,1fr);gap:14px;margin-bottom:1.2rem}
    .meta-stat{background:var(--surface-2);border:1px solid var(--border);border-radius:14px;padding:.85rem 1rem}
    .meta-stat .n{font-size:.64rem;text-transform:uppercase;letter-spacing:.09em;color:var(--muted);font-weight:800}
    .meta-stat .v{font-size:1.45rem;font-weight:900;margin-top:.25rem;letter-spacing:-.02em}
    .meta-stat .s{font-size:.7rem;color:var(--muted);margin-top:.2rem}
    .meta-bar{position:relative;height:12px;border-radius:999px;background:var(--track);overflow:hidden;margin-bottom:1.6rem}
    .meta-bar-fill{height:100%;border-radius:999px;background:linear-gradient(90deg,var(--brand),#2dd4bf);transition:width .4s ease}
    .meta-note{font-size:.7rem;color:var(--muted);margin-top:1rem;line-height:1.6}
    table.matrix td.ano{font-weight:800}
    table.matrix tr.futuro td{color:var(--muted)}
    table.matrix tr.cruza td{background:rgba(52,211,153,.08)}
    table.matrix tr.cruza td.ano{color:var(--success)}
    @media(max-width:950px){.meta-stats{grid-template-columns:repeat(2,1fr)}}

    /* Matriz empresa x ano: 1a coluna fixa, numeros alinhados a direita */
    .matrix-wrap{max-height:none;margin-top:1.2rem}
    table.matrix{min-width:900px}
    table.matrix th,table.matrix td{padding:.65rem .85rem;white-space:nowrap}
    table.matrix thead th{background:var(--table-head)}
    table.matrix th.emp,table.matrix td.emp{position:sticky;left:0;z-index:2;background:var(--surface);text-align:left;white-space:normal;min-width:230px}
    table.matrix thead th.emp{background:var(--table-head);z-index:3}
    table.matrix td.emp{font-weight:700;font-size:.74rem}
    table.matrix td.emp .dot{display:inline-block;margin-right:.5rem;vertical-align:middle}
    table.matrix th.num,table.matrix td.num{text-align:right;font-variant-numeric:tabular-nums}
    table.matrix td.num{color:var(--muted)}
    table.matrix td.num.on{color:var(--text);font-weight:700}
    table.matrix .per{color:var(--muted);font-size:.68rem;font-weight:700}
    table.matrix .tot{font-weight:800;color:var(--text);border-left:1px solid var(--border)}
    table.matrix th.tot{color:var(--muted)}
    table.matrix tfoot td{background:var(--table-head);font-weight:800;color:var(--text);border-top:1px solid var(--border);border-bottom:0}
    table.matrix tfoot td.emp{background:var(--table-head)}

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
      <div><label for="fEmpresa">Empresa contratada</label><select id="fEmpresa"></select></div>
      <button id="reset">Limpar filtros</button>
    </section>

    <section class="kpis">
      <article class="card kpi" style="--accent-color:var(--brand)"><div class="name">Hidrômetros instalados</div><div class="value" id="kTotal">0</div><div class="sub" id="kTotalSub">números de hidrômetro distintos</div></article>
      <article class="card kpi" style="--accent-color:var(--success)"><div class="name">Bairros</div><div class="value" id="kBairros">0</div><div class="sub">com instalação no recorte</div></article>
      <article class="card kpi" style="--accent-color:var(--warning)"><div class="name">Água ligada</div><div class="value" id="kLigado">0%</div><div class="sub" id="kLigadoSub">0 ligações</div></article>
      <article class="card kpi" style="--accent-color:var(--violet)"><div class="name">Consumo real</div><div class="value" id="kReal">0%</div><div class="sub" id="kRealSub">0 instalações</div></article>
    </section>

    <aside class="card quality"><div>⚠️</div><div><strong>Leitura e qualidade dos dados</strong><p id="qualityText"></p></div></aside>

    <section class="card chart-card meta-card" style="margin-bottom:14px">
      <div class="chart-head">
        <div><h2>Acompanhamento da meta de 130 mil hidrômetros</h2><p id="metaSub">Acumulado desde 2016 e projeção pela meta pactuada</p></div>
        <div class="meta-verdict" id="metaVerdict"></div>
      </div>
      <div class="meta-stats" id="metaStats"></div>
      <div class="meta-bar"><div class="meta-bar-fill" id="metaBarFill"></div><div class="meta-bar-mark" id="metaBarMark"></div></div>
      <div class="canvas-scroll" id="metaScroll"><canvas id="metaChart"></canvas></div>
      <div class="table-wrap matrix-wrap"><table class="matrix"><thead id="metaHead"></thead><tbody id="metaBody"></tbody></table></div>
      <p class="meta-note">A meta não é afetada pelos filtros do topo: ela mede o total pactuado no acordo, sempre sobre todos os hidrômetros distintos instalados desde 2016.</p>
    </section>

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

    <section class="card chart-card" style="margin-bottom:14px">
      <div class="chart-head"><div><h2>Instalações por ano e empresa contratada</h2><p>Sucessão dos contratos: cada empresa ocupa um período distinto. "EQUIPE CAEMA" reúne a execução própria, fora das janelas de contrato.</p></div></div>
      <div class="canvas-scroll" id="empresaScroll"><canvas id="empresaChart"></canvas></div>
      <div class="table-wrap matrix-wrap"><table class="matrix"><thead id="empresaMatrixHead"></thead><tbody id="empresaMatrixBody"></tbody><tfoot id="empresaMatrixFoot"></tfoot></table></div>
    </section>

    <section class="card table-card">
      <div class="chart-head"><div><h2>Ranking completo de bairros</h2><p id="tableSummary">Todos os bairros do recorte</p></div><div class="table-tools"><input id="bairroSearch" type="search" placeholder="Pesquisar bairro..." aria-label="Pesquisar bairro"><button class="btn-primary" id="exportCsv">Exportar ranking CSV</button></div></div>
      <div class="table-wrap"><table><thead><tr><th>#</th><th>Bairro</th><th>Empresa Cadastrada</th><th>Instalações</th><th>Participação</th></tr></thead><tbody id="bairroTable"></tbody></table></div>
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
    const filters={year:$('fYear'),bairro:$('fBairro'),situacao:$('fSituacao'),consumo:$('fConsumo'),empresa:$('fEmpresa')};
    let currentRows=[],bairroRanking=[];
    // Ordem estavel das empresas: pelo primeiro ano de atuacao, para a sucessao
    // de contratos ser lida da esquerda para a direita no empilhamento.
    const empresaOrder=(()=>{const first=new Map();BI.data.forEach(d=>{const y=Number(d.y);if(!Number.isFinite(y))return;if(!first.has(d.e)||y<first.get(d.e))first.set(d.e,y)});return [...first].sort((a,b)=>a[1]-b[1]||a[0].localeCompare(b[0],'pt-BR')).map(x=>x[0]);})();
    // "EQUIPE CAEMA" e execucao propria, nao uma contratada: fica em cinza
    // neutro, e as cores vivas ficam so para as empresas contratadas.
    const SEM_CONTRATO='EQUIPE CAEMA';
    const contratadas=empresaOrder.filter(e=>e!==SEM_CONTRATO);
    // Matizes bem separados: empresas que se empilham no mesmo ano nao colidem.
    const CORES_EMPRESA=['#0ea5e9','#fbbf24','#34d399','#fb7185','#a78bfa','#2dd4bf','#f472b6'];
    const empresaColor=e=>e===SEM_CONTRATO?'#94a3b8':CORES_EMPRESA[Math.max(0,contratadas.indexOf(e))%CORES_EMPRESA.length];

    function uniq(field){return [...new Set(BI.data.map(d=>d[field]))].sort((a,b)=>field==='y'?(Number(a)||9999)-(Number(b)||9999):a.localeCompare(b,'pt-BR'));}
    function fillSelect(el,values,label){el.innerHTML=`<option value="">${label}</option>`+values.map(v=>`<option value="${esc(v)}">${esc(v)}</option>`).join('');}
    function esc(s){return String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));}
    function init(){
      fillSelect(filters.year,uniq('y'),'Todos os anos');fillSelect(filters.bairro,uniq('b'),'Todos os bairros');
      fillSelect(filters.situacao,uniq('s'),'Todas as situações');fillSelect(filters.consumo,uniq('c'),'Todos os tipos');
      fillSelect(filters.empresa,empresaOrder,'Todas as empresas');
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
      $('qualityText').textContent=`A base traz ${nf.format(BI.totalRaw)} eventos de instalação, que correspondem a ${nf.format(BI.totalMeters)} hidrômetros distintos (${nf.format(BI.reinstalls)} reinstalações do mesmo hidrômetro contam uma vez só, no ano da primeira instalação). Destes, ${nf.format(BI.excludedBeforePeriod)} foram instalados antes de 2016 e ficam fora do recorte, restando ${nf.format(BI.total)} entre ${startDate} e ${endDate}. Números iguais de hidrômetro são o critério de contagem — não eventos, não imóveis.`;
      $('footer').textContent=`Fonte: ${BI.source} • Período: ${startDate} a ${endDate} • BI gerado em ${BI.generatedAt} • Dados processados localmente.`;
      renderMeta();
      render();
    }
    function debounce(fn,ms){let t;return()=>{clearTimeout(t);t=setTimeout(fn,ms)}}
    function syncTheme(){$('themeToggle').textContent=document.documentElement.dataset.theme==='dark'?'Tema claro':'Tema escuro';}
    function filtered(){return BI.data.filter(d=>(!filters.year.value||d.y===filters.year.value)&&(!filters.bairro.value||d.b===filters.bairro.value)&&(!filters.situacao.value||d.s===filters.situacao.value)&&(!filters.consumo.value||d.c===filters.consumo.value)&&(!filters.empresa.value||d.e===filters.empresa.value));}
    function group(rows,field){const m=new Map();rows.forEach(d=>m.set(d[field],(m.get(d[field])||0)+d.n));return [...m].map(([label,value])=>({label,value}));}
    function total(rows){return rows.reduce((s,d)=>s+d.n,0)}
    function render(){currentRows=filtered();const t=total(currentRows);
      const bMap = new Map();
      currentRows.forEach(d => {
        if(!bMap.has(d.b)) bMap.set(d.b, {value: 0, emp: new Map()});
        const o = bMap.get(d.b);
        o.value += d.n;
        if(d.e) o.emp.set(d.e, (o.emp.get(d.e)||0) + d.n);
      });
      bairroRanking = [...bMap].map(([label, o]) => {
        let empresa = ''; let maxE = -1;
        for(let [eName, eCount] of o.emp.entries()){ if(eCount > maxE){ maxE = eCount; empresa = eName; } }
        return {label, value: o.value, empresa};
      }).sort((a,b)=>b.value-a.value||a.label.localeCompare(b.label,'pt-BR'));
      const sit=group(currentRows,'s'),cons=group(currentRows,'c');const ligados=sit.filter(x=>x.label.toLocaleUpperCase('pt-BR')==='LIGADO').reduce((s,x)=>s+x.value,0);const reais=cons.filter(x=>x.label.toLocaleUpperCase('pt-BR')==='REAL').reduce((s,x)=>s+x.value,0);
      $('kTotal').textContent=nf.format(t);$('kBairros').textContent=nf.format(bairroRanking.length);$('kLigado').textContent=t?pf.format(ligados/t):'0%';$('kLigadoSub').textContent=`${nf.format(ligados)} ligações`;$('kReal').textContent=t?pf.format(reais/t):'0%';$('kRealSub').textContent=`${nf.format(reais)} instalações`;
      $('kTotalSub').textContent=t===BI.total?'instalações desde 2016':'no recorte selecionado';renderCharts();renderTable();renderEmpresaMatrix(currentRows);
    }
    function renderCharts(){drawYears(group(currentRows,'y'));drawDonut(group(currentRows,'s').sort((a,b)=>b.value-a.value));drawBairros(bairroRanking);drawConsumption(group(currentRows,'c').sort((a,b)=>b.value-a.value));drawEmpresaAno(currentRows);drawMeta(metaPlano());}
    /* ---------------------------------------------------------------------
       META DE 130 MIL HIDROMETROS
       Nao depende dos filtros: mede o pactuado no acordo, sempre sobre todos
       os hidrometros distintos instalados desde 2016.
       --------------------------------------------------------------------- */
    function metaPlano(){
      const M=BI.meta,realized=BI.realized;
      const accAte=y=>{const r=realized.filter(x=>x.y<=y);return r.length?r[r.length-1].acc:0;};
      const base=accAte(M.baseYear-1);            // acumulado ao fim do ano anterior a meta
      const linhas=[];
      let acc=base,ano=M.baseYear,k=0;
      // projeta ate cruzar a meta (teto de seguranca para nao girar infinito)
      while(acc<M.total&&k<40){
        const alvo=Math.round(M.baseQty*Math.pow(1+M.growth,k));
        acc+=alvo;
        linhas.push({y:ano,alvo,accProj:acc});
        ano++;k++;
      }
      const cruza=linhas.find(l=>l.accProj>=M.total);
      const feito=accAte(BI.currentYear);          // realizado ate hoje
      const noAno=(realized.find(x=>x.y===BI.currentYear)||{n:0}).n;
      const alvoAno=(linhas.find(l=>l.y===BI.currentYear)||{alvo:0}).alvo;
      return {M,realized,base,linhas,cruza,feito,noAno,alvoAno,falta:Math.max(0,M.total-feito)};
    }
    function renderMeta(){
      const p=metaPlano(),M=p.M,pct=p.feito/M.total;
      $('metaVerdict').className='meta-verdict '+(p.cruza?'ok':'warn');
      $('metaVerdict').textContent=p.cruza?`Meta alcançada em ${p.cruza.y}`:'Meta não alcançada no horizonte projetado';
      $('metaSub').textContent=`Acumulado desde 2016 e projeção pela meta de ${nf.format(M.baseQty)} em ${M.baseYear}, crescendo ${pf.format(M.growth)} ao ano`;
      $('metaStats').innerHTML=`
        <div class="meta-stat"><div class="n">Realizado desde 2016</div><div class="v">${nf.format(p.feito)}</div><div class="s">${pf.format(pct)} da meta de ${compact(M.total)}</div></div>
        <div class="meta-stat"><div class="n">Falta para os 130 mil</div><div class="v">${nf.format(p.falta)}</div><div class="s">${pf.format(1-pct)} restantes</div></div>
        <div class="meta-stat"><div class="n">Meta de ${BI.currentYear}</div><div class="v">${nf.format(p.noAno)}<span style="font-size:.9rem;color:var(--muted);font-weight:700"> / ${nf.format(p.alvoAno)}</span></div><div class="s">${p.alvoAno?pf.format(p.noAno/p.alvoAno):'—'} da meta do ano</div></div>
        <div class="meta-stat"><div class="n">Previsão de alcance</div><div class="v">${p.cruza?p.cruza.y:'—'}</div><div class="s">${p.cruza?'mantendo o ritmo pactuado':'fora do horizonte'}</div></div>`;
      $('metaBarFill').style.width=Math.min(100,pct*100)+'%';
      // tabela
      const anos=[...p.realized.map(r=>r.y),...p.linhas.map(l=>l.y)].filter((v,i,a)=>a.indexOf(v)===i).sort((a,b)=>a-b);
      $('metaHead').innerHTML='<tr><th class="emp">Ano</th><th class="num">Instalado no ano</th><th class="num">Acumulado realizado</th><th class="num">Meta do ano</th><th class="num tot">Acumulado projetado</th></tr>';
      $('metaBody').innerHTML=anos.map(y=>{
        const r=p.realized.find(x=>x.y===y),l=p.linhas.find(x=>x.y===y);
        const futuro=y>BI.currentYear,cruza=p.cruza&&y===p.cruza.y;
        const cls=[futuro?'futuro':'',cruza?'cruza':''].filter(Boolean).join(' ');
        return `<tr class="${cls}"><td class="emp ano">${y}${y===BI.currentYear?' <small style="color:var(--muted);font-weight:700">(em curso)</small>':''}</td>`+
          `<td class="num${r?' on':''}">${r?nf.format(r.n):'—'}</td>`+
          `<td class="num${r?' on':''}">${r?nf.format(r.acc):'—'}</td>`+
          `<td class="num${l?' on':''}">${l?nf.format(l.alvo):'—'}</td>`+
          `<td class="num tot">${l?nf.format(l.accProj):'—'}</td></tr>`;
      }).join('');
      drawMeta(p);
    }
    function drawMeta(p){
      const wrap=$('metaScroll'),M=p.M,th=T();
      const anos=[...p.realized.map(r=>r.y),...p.linhas.map(l=>l.y)].filter((v,i,a)=>a.indexOf(v)===i).sort((a,b)=>a-b);
      if(!anos.length)return noData(wrap,'metaChart');
      const teto=Math.max(M.total,...p.linhas.map(l=>l.accProj),...p.realized.map(r=>r.acc))*1.08;
      const w=Math.max(wrap.clientWidth||700,anos.length*66+90),h=360;
      const ctx=setupCanvas($('metaChart'),w,h),left=64,right=22,top=26,bottom=48;
      const plotW=w-left-right,plotH=h-top-bottom;
      const X=y=>left+(anos.indexOf(y))*(plotW/Math.max(1,anos.length-1));
      const Y=v=>top+plotH-(v/teto)*plotH;
      // grade
      ctx.strokeStyle=th.grid;ctx.fillStyle=th.muted;ctx.textAlign='right';ctx.textBaseline='middle';ctx.font='12px '+FONT;
      for(let i=0;i<=4;i++){const y=top+plotH*i/4;ctx.beginPath();ctx.moveTo(left,y);ctx.lineTo(w-right,y);ctx.stroke();ctx.fillText(compact(teto*(1-i/4)),left-8,y);}
      // linha da meta 130k
      const ym=Y(M.total);
      ctx.save();ctx.setLineDash([6,5]);ctx.strokeStyle='#fb7185';ctx.lineWidth=1.5;
      ctx.beginPath();ctx.moveTo(left,ym);ctx.lineTo(w-right,ym);ctx.stroke();ctx.restore();
      ctx.fillStyle='#fb7185';ctx.font='800 11px '+FONT;ctx.textAlign='left';ctx.textBaseline='bottom';
      ctx.fillText('META '+compact(M.total),left+4,ym-5);
      // area + linha do realizado
      const rp=p.realized.map(r=>({x:X(r.y),y:Y(r.acc)}));
      if(rp.length){
        const g=ctx.createLinearGradient(0,top,0,top+plotH);
        g.addColorStop(0,'rgba(14,165,233,.30)');g.addColorStop(1,'rgba(14,165,233,0)');
        ctx.fillStyle=g;ctx.beginPath();ctx.moveTo(rp[0].x,top+plotH);
        rp.forEach(pt=>ctx.lineTo(pt.x,pt.y));
        ctx.lineTo(rp[rp.length-1].x,top+plotH);ctx.closePath();ctx.fill();
        ctx.strokeStyle=th.brand;ctx.lineWidth=2.5;ctx.beginPath();
        rp.forEach((pt,i)=>i?ctx.lineTo(pt.x,pt.y):ctx.moveTo(pt.x,pt.y));ctx.stroke();
        ctx.fillStyle=th.brand;rp.forEach(pt=>{ctx.beginPath();ctx.arc(pt.x,pt.y,3.5,0,Math.PI*2);ctx.fill();});
      }
      // linha projetada (tracejada), partindo do ultimo realizado fechado
      const pp=[{x:X(M.baseYear-1),y:Y(p.base)},...p.linhas.map(l=>({x:X(l.y),y:Y(l.accProj)}))];
      ctx.save();ctx.setLineDash([7,5]);ctx.strokeStyle='#2dd4bf';ctx.lineWidth=2.5;ctx.beginPath();
      pp.forEach((pt,i)=>i?ctx.lineTo(pt.x,pt.y):ctx.moveTo(pt.x,pt.y));ctx.stroke();ctx.restore();
      ctx.fillStyle='#2dd4bf';pp.slice(1).forEach(pt=>{ctx.beginPath();ctx.arc(pt.x,pt.y,3.5,0,Math.PI*2);ctx.fill();});
      /* Rotulos do acumulado. Em 2026 as duas series quase se tocam (realizado
         88.925 x projetado 91.649): o realizado vai ABAIXO do ponto e a projecao
         ACIMA, senao os rotulos se sobrepoem. */
      ctx.font='800 10px '+FONT;ctx.textAlign='center';
      ctx.fillStyle=th.brand;ctx.textBaseline='top';
      p.realized.forEach(r=>ctx.fillText(nf.format(r.acc),X(r.y),Y(r.acc)+8));
      ctx.fillStyle='#2dd4bf';ctx.textBaseline='bottom';
      p.linhas.forEach(l=>ctx.fillText(nf.format(l.accProj),X(l.y),Y(l.accProj)-9));
      // marcador do cruzamento
      if(p.cruza){
        const cx=X(p.cruza.y),cy=Y(p.cruza.accProj);
        ctx.strokeStyle='#34d399';ctx.lineWidth=2;ctx.beginPath();ctx.arc(cx,cy,7,0,Math.PI*2);ctx.stroke();
        ctx.fillStyle='#34d399';ctx.font='900 12px '+FONT;ctx.textAlign='center';ctx.textBaseline='bottom';
        ctx.fillText(p.cruza.y,cx,cy-24);   // acima do rotulo do valor
      }
      // eixo x
      ctx.fillStyle=th.muted;ctx.font='12px '+FONT;ctx.textAlign='center';ctx.textBaseline='top';
      anos.forEach(y=>ctx.fillText(y,X(y),top+plotH+12));
    }

    // Matriz empresa x ano, compartilhada pelo grafico e pela tabela.
    function empresaMatrix(rows){
      const anos=[...new Set(rows.map(d=>d.y))].filter(y=>/^\d{4}$/.test(y)).sort((a,b)=>+a-+b);
      const ativas=empresaOrder.filter(e=>rows.some(d=>d.e===e));
      const cel=new Map();rows.forEach(d=>{if(!/^\d{4}$/.test(d.y))return;const k=d.y+'|'+d.e;cel.set(k,(cel.get(k)||0)+d.n);});
      const val=(a,e)=>cel.get(a+'|'+e)||0;
      const totAno=a=>ativas.reduce((s,e)=>s+val(a,e),0);
      const totEmp=e=>anos.reduce((s,a)=>s+val(a,e),0);
      const geral=anos.reduce((s,a)=>s+totAno(a),0);
      return {anos,ativas,val,totAno,totEmp,geral};
    }
    function renderEmpresaMatrix(rows){
      const {anos,ativas,val,totAno,totEmp,geral}=empresaMatrix(rows);
      const head=$('empresaMatrixHead'),body=$('empresaMatrixBody'),foot=$('empresaMatrixFoot');
      if(!anos.length||!ativas.length){head.innerHTML='';body.innerHTML='<tr><td class="emp">Nenhum dado para os filtros selecionados</td></tr>';foot.innerHTML='';return;}
      head.innerHTML=`<tr><th class="emp">Empresa contratada</th><th class="num">Período</th>${anos.map(a=>`<th class="num">${a}</th>`).join('')}<th class="num tot">Total</th><th class="num tot">Part.</th></tr>`;
      body.innerHTML=ativas.map(e=>{
        const ys=anos.filter(a=>val(a,e)),tot=totEmp(e);
        const per=ys.length?(ys[0]===ys[ys.length-1]?ys[0]:ys[0]+'–'+ys[ys.length-1]):'—';
        const cels=anos.map(a=>{const v=val(a,e);return `<td class="num${v?' on':''}">${v?nf.format(v):'—'}</td>`;}).join('');
        return `<tr><td class="emp"><i class="dot" style="background:${empresaColor(e)}"></i>${esc(e)}</td><td class="num per">${per}</td>${cels}<td class="num tot">${nf.format(tot)}</td><td class="num tot">${geral?pf.format(tot/geral):'0,0%'}</td></tr>`;
      }).join('');
      foot.innerHTML=`<tr><td class="emp">Total do ano</td><td class="num"></td>${anos.map(a=>`<td class="num">${nf.format(totAno(a))}</td>`).join('')}<td class="num tot">${nf.format(geral)}</td><td class="num tot">100,0%</td></tr>`;
    }
    function drawEmpresaAno(rows){
      const wrap=$('empresaScroll');
      const {anos,ativas,val,totAno}=empresaMatrix(rows);
      if(!anos.length||!ativas.length)return noData(wrap,'empresaChart');
      const th=T(),max=Math.max(...anos.map(totAno),1);
      const w=Math.max(wrap.clientWidth||600,anos.length*78+80),h=380;
      const ctx=setupCanvas($('empresaChart'),w,h),left=62,right=18,top=34,bottom=54;
      const plotW=w-left-right,plotH=h-top-bottom;
      ctx.strokeStyle=th.grid;ctx.fillStyle=th.muted;ctx.textAlign='right';ctx.textBaseline='middle';
      for(let i=0;i<=4;i++){const y=top+plotH*i/4;ctx.beginPath();ctx.moveTo(left,y);ctx.lineTo(w-right,y);ctx.stroke();ctx.fillText(compact(max*(1-i/4)),left-8,y);}
      const step=plotW/anos.length,bw=Math.max(14,Math.min(56,step*.62));
      anos.forEach((a,i)=>{
        const tot=totAno(a);if(!tot)return;
        const x=left+i*step+(step-bw)/2;let acc=0;
        ativas.forEach(e=>{
          const v=val(a,e);if(!v)return;
          const segH=v/max*plotH,y=top+plotH-(acc+v)/max*plotH;
          ctx.fillStyle=empresaColor(e);ctx.fillRect(x,y,bw,segH);acc+=v;
        });
        ctx.fillStyle=th.text;ctx.font='800 11px '+FONT;ctx.textAlign='center';ctx.textBaseline='bottom';
        ctx.fillText(nf.format(tot),x+bw/2,Math.max(14,top+plotH-tot/max*plotH-5));
        ctx.font='12px '+FONT;ctx.fillStyle=th.muted;ctx.textBaseline='top';ctx.fillText(a,x+bw/2,top+plotH+10);
      });
    }
    function setupCanvas(canvas,w,h){const dpr=Math.min(window.devicePixelRatio||1,2);canvas.style.width=w+'px';canvas.style.height=h+'px';canvas.width=Math.round(w*dpr);canvas.height=Math.round(h*dpr);const ctx=canvas.getContext('2d');ctx.setTransform(dpr,0,0,dpr,0,0);ctx.font='12px '+FONT;return ctx;}
    function roundedRect(ctx,x,y,w,h,r){r=Math.min(r,Math.abs(w)/2,Math.abs(h)/2);ctx.beginPath();ctx.roundRect(x,y,w,h,r);ctx.fill()}
    function noData(container,id){const c=$(id);const ctx=setupCanvas(c,Math.max(container.clientWidth,300),250);ctx.fillStyle=T().muted;ctx.textAlign='center';ctx.fillText('Nenhum dado para os filtros selecionados',c.clientWidth/2,125)}
    function drawYears(items){const wrap=$('yearScroll');const numeric=items.filter(x=>/^\d{4}$/.test(x.label)).sort((a,b)=>+a.label-+b.label);if(!numeric.length)return noData(wrap,'yearChart');const th=T(),w=Math.max(wrap.clientWidth||500,numeric.length*64+74),h=340,ctx=setupCanvas($('yearChart'),w,h),left=58,right=20,top=38,bottom=62,plotW=w-left-right,plotH=h-top-bottom,max=Math.max(...numeric.map(x=>x.value),1);ctx.strokeStyle=th.grid;ctx.fillStyle=th.muted;ctx.textAlign='right';ctx.textBaseline='middle';for(let i=0;i<=4;i++){const y=top+plotH*i/4,val=max*(1-i/4);ctx.beginPath();ctx.moveTo(left,y);ctx.lineTo(w-right,y);ctx.stroke();ctx.fillText(compact(val),left-8,y)}const step=plotW/numeric.length,bw=Math.max(10,step*.66);numeric.forEach((d,i)=>{const bh=d.value/max*plotH,x=left+i*step+(step-bw)/2,y=top+plotH-bh;const grad=ctx.createLinearGradient(0,y,0,top+plotH);grad.addColorStop(0,'#38bdf8');grad.addColorStop(1,th.brand);ctx.fillStyle=grad;roundedRect(ctx,x,y,bw,bh,6);ctx.fillStyle=th.text;ctx.font='800 11px '+FONT;ctx.textAlign='center';ctx.textBaseline='bottom';ctx.fillText(nf.format(d.value),x+bw/2,Math.max(15,y-5));ctx.font='12px '+FONT;ctx.save();ctx.translate(x+bw/2,h-bottom+10);ctx.rotate(-Math.PI/4);ctx.fillStyle=th.muted;ctx.textAlign='right';ctx.textBaseline='middle';ctx.fillText(d.label,0,0);ctx.restore()});}
    function drawBairros(items){const limit=+$('bairroLimit').value,shown=limit?items.slice(0,limit):items;const wrap=$('bairroScroll');if(!shown.length)return noData(wrap,'bairroChart');const th=T(),w=Math.max(wrap.clientWidth||500,520),rowH=31,h=Math.max(180,shown.length*rowH+30),ctx=setupCanvas($('bairroChart'),w,h),left=Math.min(205,w*.39),right=65,max=Math.max(...shown.map(x=>x.value),1);shown.forEach((d,i)=>{const y=16+i*rowH,bw=(w-left-right)*d.value/max;ctx.fillStyle=th.muted;ctx.textAlign='right';ctx.textBaseline='middle';ctx.fillText(shorten(d.label,left<170?19:28),left-10,y+8);ctx.fillStyle=th.track;roundedRect(ctx,left,y,w-left-right,16,999);const g=ctx.createLinearGradient(left,0,w-right,0);g.addColorStop(0,th.brand);g.addColorStop(1,'#2dd4bf');ctx.fillStyle=g;roundedRect(ctx,left,y,bw,16,999);ctx.fillStyle=th.text;ctx.font='800 12px '+FONT;ctx.textAlign='left';ctx.fillText(nf.format(d.value),left+bw+7,y+8);ctx.font='12px '+FONT});}
    function drawConsumption(items){const wrap=$('consumoScroll');if(!items.length)return noData(wrap,'consumoChart');const th=T(),w=Math.max(wrap.clientWidth||500,440),rowH=37,h=Math.max(300,items.length*rowH+30),ctx=setupCanvas($('consumoChart'),w,h),left=Math.min(190,w*.38),right=74,max=Math.max(...items.map(x=>x.value),1);items.forEach((d,i)=>{const y=16+i*rowH,bw=(w-left-right)*d.value/max;ctx.fillStyle=th.muted;ctx.textAlign='right';ctx.textBaseline='middle';ctx.fillText(shorten(d.label,left<165?18:26),left-10,y+9);ctx.fillStyle=th.track;roundedRect(ctx,left,y,w-left-right,18,999);ctx.fillStyle=colors[i%colors.length];roundedRect(ctx,left,y,bw,18,999);ctx.fillStyle=th.text;ctx.font='800 12px '+FONT;ctx.textAlign='left';ctx.fillText(nf.format(d.value),left+bw+7,y+9);ctx.font='12px '+FONT});}
    function drawDonut(items){const th=T(),canvas=$('situationChart'),wrap=canvas.parentElement,w=Math.min(Math.max(wrap.clientWidth*.5,190),300),h=w,ctx=setupCanvas(canvas,w,h),t=items.reduce((s,x)=>s+x.value,0),cx=w/2,cy=h/2,r=w*.36,inner=r*.66;if(!t){ctx.fillStyle=th.muted;ctx.textAlign='center';ctx.fillText('Sem dados',cx,cy);$('situationLegend').innerHTML='';return}let a=-Math.PI/2;items.forEach((d,i)=>{const next=a+d.value/t*Math.PI*2;ctx.beginPath();ctx.arc(cx,cy,r,a,next);ctx.arc(cx,cy,inner,next,a,true);ctx.closePath();ctx.fillStyle=colors[i%colors.length];ctx.fill();a=next});ctx.fillStyle=th.text;ctx.textAlign='center';ctx.textBaseline='middle';ctx.font='900 22px '+FONT;ctx.fillText(compact(t),cx,cy-6);ctx.fillStyle=th.muted;ctx.font='11px '+FONT;ctx.fillText('instalações',cx,cy+15);$('situationLegend').innerHTML=items.map((d,i)=>`<div class="legend-row"><i class="dot" style="background:${colors[i%colors.length]}"></i><span>${esc(d.label)} <small>(${pf.format(d.value/t)})</small></span><b>${nf.format(d.value)}</b></div>`).join('');}
    function compact(n){return Intl.NumberFormat('pt-BR',{notation:'compact',maximumFractionDigits:1}).format(Math.round(n))}
    function shorten(s,n){return s.length>n?s.slice(0,n-1)+'…':s}
    function renderTable(){const q=$('bairroSearch').value.trim().toLocaleUpperCase('pt-BR'),rows=bairroRanking.filter(x=>!q||x.label.toLocaleUpperCase('pt-BR').includes(q)),t=bairroRanking.reduce((s,x)=>s+x.value,0),max=bairroRanking[0]?.value||1;$('bairroTable').innerHTML=rows.map((d,i)=>`<tr><td>${i+1}</td><td>${esc(d.label)}</td><td style="font-size:0.7rem; color:var(--muted)">${esc(d.empresa)}</td><td>${nf.format(d.value)}</td><td><div class="share"><div class="mini-bar"><i style="width:${d.value/max*100}%"></i></div><b>${t?pf.format(d.value/t):'0,0%'}</b></div></td></tr>`).join('');$('tableSummary').textContent=`${nf.format(rows.length)} bairro(s) exibido(s) • ${nf.format(t)} instalações no recorte`;}
    function exportRanking(){const t=bairroRanking.reduce((s,x)=>s+x.value,0);const lines=['Posição;Bairro;Empresa Cadastrada;Instalações;Participação'];bairroRanking.forEach((d,i)=>lines.push(`${i+1};"${d.label.replaceAll('"','""')}";"${(d.empresa||'').replaceAll('"','""')}";${d.value};${t?(d.value/t*100).toFixed(2).replace('.',','):0}%`));const blob=new Blob(['\ufeff'+lines.join('\r\n')],{type:'text/csv;charset=utf-8'}),a=document.createElement('a');a.href=URL.createObjectURL(blob);a.download='ranking_bairros_hidrometros.csv';a.click();URL.revokeObjectURL(a.href);}
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
Write-Host "Eventos no CSV: $($rows.Count) | Hidrômetros distintos: $($meters.Count) | Reinstalações: $reinstalls"
Write-Host "Hidrômetros distintos desde 2016: $includedCount (ativos: $activeCount) | Bairros: $($neighborhoods.Count)"
Write-Host "Anteriores a 2016: $excludedBeforePeriod | Datas futuras: $futureDates | Datas inválidas: $invalidDates"
