// Expressão do campo 'dashboard' do nó "Montar dashboard" (WF40 e WF00 completo).
// Gera { html, email }: html = PDF com gráficos SVG; email = versão compatível com Gmail/Outlook.
// Entrada: $('Ler snapshot').first().json (kpis_object, narrativa, narrativaValida, semDados, id).
(() => {
  // Dashboard único do snapshot: html = PDF completo (gráficos SVG); email = versão compatível com clientes de e-mail (tabelas)
  const snap = $('Ler snapshot').first().json
  const k = JSON.parse(snap.kpis_object || '{}')
  const esc = s => String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;')
  // Valores do WF30 chegam formatados em pt-BR ("1.234", "4,2%", "R$ 1.234,56", "+0,5 p.p."); n() devolve o número para os gráficos
  const n = s => { const v = parseFloat(String(s ?? '').replace(/[^\d,.-]/g, '').replace(/\./g, '').replace(',', '.')); return Number.isFinite(v) ? v : 0 }
  const dec1 = v => v.toLocaleString('pt-BR', { minimumFractionDigits: 1, maximumFractionDigits: 1 })
  const corte = (s, max) => { const x = String(s ?? ''); return x.length > max ? x.slice(0, max - 1) + '…' : x }
  const C = { navy: '#12263F', azul: '#2E6FD8', azulClaro: '#CFDDF7', verde: '#1E8E5A', vermelho: '#C62828', ambar: '#D98E04', cinza: '#5B6675', cinzaClaro: '#EEF1F5', borda: '#DDE2EA', fundo: '#F6F8FB', texto: '#1C2430' }

  const t = k.totais || {}
  const ant = k.periodoAnterior || {}
  const contratos = k.porContrato || []
  const fornecedores = k.porFornecedor || []
  const alertas = k.contratosEmAlerta || []
  const emAlerta = new Set(alertas.map(a => a.nome))
  const serie = k.serieSemanal || []
  const geral = n(t.indicePerdas)
  const temAnterior = n(ant.inspecoes) > 0
  const periodo = (k.periodo?.inicio ?? '-') + ' a ' + (k.periodo?.fim ?? '-')
  const geradoEm = $now.setZone('America/Sao_Paulo').toFormat('dd/MM/yyyy HH:mm')

  // Variação vs. período anterior: vermelho quando piora, verde quando melhora, cinza quando neutro
  const chip = (texto, cor) => `<span class="chip" style="color:${cor};background:${cor}1F">${esc(texto)}</span>`
  const variacao = (a, b, sufixo, piorSobe, pontos) => {
    if (!temAnterior) return chip('sem base de comparação', C.cinza)
    // Índice: usa a variação já calculada no WF30 (sem arredondamento intermediário)
    const d = pontos ? n(k.variacao?.indicePerdas) : (n(b) ? (n(a) - n(b)) / Math.abs(n(b)) * 100 : null)
    if (d === null) return chip('sem base de comparação', C.cinza)
    const cor = Math.abs(d) < 0.05 || piorSobe === null ? C.cinza : (d > 0) === piorSobe ? C.vermelho : C.verde
    const txt = pontos ? String(k.variacao?.indicePerdas ?? '').replace(/^\+/, '') : dec1(Math.abs(d)) + sufixo
    return chip((d > 0 ? '▲ +' : d < 0 ? '▼ ' : '■ ') + txt.replace(/^-/, '') + ' vs. anterior', cor)
  }
  const situacao = g => emAlerta.has(g.nome) ? chip('Em alerta', C.vermelho) : n(g.indicePerdas) > geral ? chip('Acima do geral', C.ambar) : chip('Normal', C.verde)
  const corIndice = g => emAlerta.has(g.nome) ? C.vermelho : n(g.indicePerdas) > geral ? C.ambar : C.azul

  // Narrativa (## título, - marcador) -> HTML
  const narrativaHtml = (cor) => snap.narrativaValida && snap.narrativa
    ? snap.narrativa.split('\n').map(l => l.startsWith('## ') ? `<div style="font-weight:700;color:${cor};margin:10px 0 4px;font-size:13px">${esc(l.slice(3))}</div>`
        : l.startsWith('- ') ? `<div style="margin:2px 0 2px 10px">• ${esc(l.slice(2))}</div>` : (l.trim() ? `<p style="margin:4px 0">${esc(l)}</p>` : '')).join('')
    : `<p style="color:${C.cinza};font-style:italic;margin:0">Resumo automático indisponível neste envio. Os indicadores são calculados diretamente dos dados.</p>`

  // ---------- Gráficos (SVG, para o PDF) ----------
  const donut = (() => {
    const total = n(t.pranchasAnalisadas), av = n(t.pranchasComAvaria), r = 62, c = 2 * Math.PI * r
    const frac = total ? Math.min(1, av / total) : 0
    return `<svg width="180" height="180" viewBox="0 0 180 180">
      <circle cx="90" cy="90" r="${r}" fill="none" stroke="${C.verde}" stroke-opacity="0.25" stroke-width="24"/>
      <circle cx="90" cy="90" r="${r}" fill="none" stroke="${C.vermelho}" stroke-width="24" stroke-dasharray="${(frac * c).toFixed(1)} ${c.toFixed(1)}" transform="rotate(-90 90 90)"/>
      <text x="90" y="88" text-anchor="middle" font-size="26" font-weight="700" fill="${C.navy}">${esc(t.indicePerdas ?? '-')}</text>
      <text x="90" y="110" text-anchor="middle" font-size="11" fill="${C.cinza}">das pranchas com avaria</text></svg>`
  })()

  const comparativo = [['Inspeções', t.inspecoes, ant.inspecoes], ['Pranchas analisadas', t.pranchasAnalisadas, ant.pranchasAnalisadas], ['Pranchas com avaria', t.pranchasComAvaria, ant.pranchasComAvaria], ['Indenização final', t.indenizacaoFinal, ant.indenizacaoFinal]]
    .map(([rot, a, b]) => {
      const m = Math.max(n(a), n(b)) || 1
      const barra = (val, cor, txt) => `<div class="cmp-linha"><div class="trilho"><div class="barra" style="width:${Math.max(1.5, n(val) / m * 100).toFixed(1)}%;background:${cor}"></div></div><span class="cmp-val">${esc(txt ?? '-')}</span></div>`
      return `<div class="cmp"><div class="cmp-rot">${rot}</div>${barra(a, C.azul, a)}${barra(b, '#A9B4C4', b)}</div>`
    }).join('')

  const tendencia = (() => {
    if (serie.length < 2) return `<div class="vazio">A tendência semanal aparece quando o período tem inspeções em pelo menos 2 semanas.</div>`
    const W = 720, H = 230, pl = 48, pr = 20, pt = 26, pb = 34, w = W - pl - pr, h = H - pt - pb
    const maxA = Math.max(...serie.map(s => n(s.pranchasAnalisadas)), 1)
    const maxI = Math.max(...serie.map(s => n(s.indicePerdas)), geral, 1) * 1.25
    const passo = w / serie.length, bw = Math.min(48, passo * 0.55)
    const x = i => pl + passo * i + passo / 2
    const yA = v => pt + h - v / maxA * h
    const yI = v => pt + h - v / maxI * h
    const grade = [0.25, 0.5, 0.75, 1].map(f => `<line x1="${pl}" y1="${(pt + h - f * h).toFixed(1)}" x2="${W - pr}" y2="${(pt + h - f * h).toFixed(1)}" stroke="${C.cinzaClaro}"/><text x="${pl - 6}" y="${(pt + h - f * h + 3).toFixed(1)}" text-anchor="end" font-size="9" fill="${C.cinza}">${Math.round(maxA * f).toLocaleString('pt-BR')}</text>`).join('')
    const barras = serie.map((s, i) => `<rect x="${(x(i) - bw / 2).toFixed(1)}" y="${yA(n(s.pranchasAnalisadas)).toFixed(1)}" width="${bw.toFixed(1)}" height="${(pt + h - yA(n(s.pranchasAnalisadas))).toFixed(1)}" rx="3" fill="${C.azulClaro}"/><text x="${x(i).toFixed(1)}" y="${H - 18}" text-anchor="middle" font-size="10" fill="${C.cinza}">sem. ${esc(s.semana)}</text>`).join('')
    const linha = serie.map((s, i) => x(i).toFixed(1) + ',' + yI(n(s.indicePerdas)).toFixed(1)).join(' ')
    const pontos = serie.map((s, i) => `<circle cx="${x(i).toFixed(1)}" cy="${yI(n(s.indicePerdas)).toFixed(1)}" r="4.5" fill="#fff" stroke="${C.vermelho}" stroke-width="2.5"/><text x="${x(i).toFixed(1)}" y="${(yI(n(s.indicePerdas)) - 10).toFixed(1)}" text-anchor="middle" font-size="10.5" font-weight="700" fill="${C.vermelho}">${esc(s.indicePerdas)}</text>`).join('')
    const yG = yI(geral).toFixed(1)
    return `<svg width="100%" viewBox="0 0 ${W} ${H}">${grade}
      <line x1="${pl}" y1="${pt + h}" x2="${W - pr}" y2="${pt + h}" stroke="${C.borda}"/>${barras}
      <line x1="${pl}" y1="${yG}" x2="${W - pr}" y2="${yG}" stroke="${C.cinza}" stroke-dasharray="5 4"/>
      <polyline points="${linha}" fill="none" stroke="${C.vermelho}" stroke-width="2.5" stroke-linejoin="round"/>${pontos}</svg>
      <div class="legenda"><i style="background:${C.azulClaro}"></i>Pranchas analisadas na semana<i style="background:${C.vermelho}"></i>Índice de perdas da semana<i style="background:none;border-top:2px dashed ${C.cinza};height:0;border-radius:0"></i>Índice do período (${esc(t.indicePerdas)})</div>`
  })()

  // Barras horizontais com linhas de referência opcionais
  const barrasH = (linhas, valor, rotulo, cor, refs) => {
    if (!linhas.length) return `<div class="vazio">Sem dados no período.</div>`
    const W = 720, lw = 190, vw = 150, rowH = 28, topo = 22, H = linhas.length * rowH + topo + 6, w = W - lw - vw
    const max = Math.max(...linhas.map(valor), ...refs.map(r => r.valor), 0.0001) * 1.05
    const xv = v => lw + Math.max(0, v) / max * w
    const fundoLinha = linhas.map((g, i) => i % 2 ? '' : `<rect x="0" y="${topo + i * rowH}" width="${W}" height="${rowH}" fill="${C.fundo}"/>`).join('')
    const barras = linhas.map((g, i) => {
      const y = topo + i * rowH, v = valor(g)
      return `<text x="${lw - 10}" y="${y + 18}" text-anchor="end" font-size="11.5" fill="${C.texto}">${esc(corte(g.nome, 28))}</text>
        <rect x="${lw}" y="${y + 6}" width="${Math.max(2, xv(v) - lw).toFixed(1)}" height="16" rx="3" fill="${cor(g)}"/>
        <text x="${(xv(v) + 7).toFixed(1)}" y="${y + 18}" font-size="11.5" font-weight="700" fill="${C.texto}">${esc(rotulo(g))}</text>`
    }).join('')
    const linhasRef = refs.map((r, j) => `<line x1="${xv(r.valor).toFixed(1)}" y1="${topo - 4}" x2="${xv(r.valor).toFixed(1)}" y2="${H - 4}" stroke="${r.cor}" stroke-width="1.5" stroke-dasharray="5 3"/><text x="${xv(r.valor).toFixed(1)}" y="${topo - 8 - j * 0}" text-anchor="${j ? 'start' : 'end'}" dx="${j ? 4 : -4}" font-size="9.5" font-weight="700" fill="${r.cor}">${esc(r.rotulo)}</text>`).join('')
    return `<svg width="100%" viewBox="0 0 ${W} ${H}">${fundoLinha}${barras}${linhasRef}</svg>`
  }
  const refsIndice = geral > 0 ? [{ valor: geral, rotulo: 'geral ' + t.indicePerdas, cor: C.cinza }, { valor: geral * 2, rotulo: 'alerta ≥ ' + dec1(geral * 2) + '%', cor: C.vermelho }] : []
  const graficoContratos = barrasH(contratos, g => n(g.indicePerdas), g => g.indicePerdas + ' · ' + g.pranchasComAvaria + '/' + g.pranchasAnalisadas, corIndice, refsIndice)
  const graficoFornecedores = barrasH(fornecedores, g => n(g.indenizacaoFinal), g => g.indenizacaoFinal, corIndice, [])

  // ---------- Tabelas ----------
  const tabela = (titulo, linhas, comSituacao) => !linhas.length ? '' : `
    <table class="tab"><thead><tr><th style="text-align:left">${titulo}</th><th>Inspeções</th><th>Analisadas</th><th>Com avaria</th><th>Índice</th><th>Indeniz. bruta</th><th>Descontos</th><th>Indeniz. final</th>${comSituacao ? '<th>Situação</th>' : ''}</tr></thead><tbody>
    ${linhas.map(g => `<tr><td style="text-align:left;font-weight:600">${esc(g.nome)}</td><td>${esc(g.inspecoes)}</td><td>${esc(g.pranchasAnalisadas)}</td><td>${esc(g.pranchasComAvaria)}</td><td style="font-weight:700;color:${corIndice(g)}">${esc(g.indicePerdas)}</td><td>${esc(g.indenizacaoBruta)}</td><td>${esc(g.descontos)}</td><td style="font-weight:700">${esc(g.indenizacaoFinal)}</td>${comSituacao ? `<td>${situacao(g)}</td>` : ''}</tr>`).join('')}
    </tbody></table>`

  const card = (rotulo, valor, detalhe, destaque) => `<td class="card${destaque ? ' destaque' : ''}"><div class="rotulo">${rotulo}</div><div class="valor">${esc(valor ?? '-')}</div><div class="det">${detalhe}</div></td>`
  const statusGeral = snap.semDados ? chip('Sem inspeções no período', '#FFFFFF')
    : alertas.length ? chip(alertas.length + ' contrato(s) em alerta', '#FFB4A9') : chip('Nenhum contrato em alerta', '#9BE3BF')

  const css = `
    *{box-sizing:border-box} body{margin:0;font-family:'Segoe UI',Roboto,'Helvetica Neue',Arial,'Liberation Sans',sans-serif;color:${C.texto};font-size:12px;-webkit-print-color-adjust:exact;print-color-adjust:exact}
    .pag{max-width:760px;margin:0 auto}
    .topo{background:${C.navy};color:#fff;border-radius:10px;padding:18px 22px;display:flex;justify-content:space-between;align-items:flex-end}
    .topo .marca{font-size:11px;letter-spacing:1.5px;text-transform:uppercase;opacity:.75}
    .topo h1{margin:4px 0 2px;font-size:22px} .topo .sub{font-size:12px;opacity:.85}
    .topo .dir{text-align:right;font-size:10.5px;opacity:.9;line-height:1.7}
    .chip{display:inline-block;padding:2px 9px;border-radius:999px;font-size:10.5px;font-weight:700;white-space:nowrap}
    table.cards{width:100%;border-spacing:8px;margin:10px -8px 0;table-layout:fixed}
    .card{background:#fff;border:1px solid ${C.borda};border-radius:10px;padding:11px 10px 9px;vertical-align:top}
    .card.destaque{border:2px solid ${C.vermelho};}
    .card .rotulo{font-size:10px;color:${C.cinza};text-transform:uppercase;letter-spacing:.6px;font-weight:600}
    .card .valor{font-size:18px;font-weight:800;color:${C.navy};margin:6px 0 6px;white-space:nowrap;letter-spacing:-.3px}
    .card .chip{white-space:normal;font-size:9.5px;padding:2px 7px}
    .card .det{font-size:10px;color:${C.cinza};line-height:1.6}
    .sec{border:1px solid ${C.borda};border-radius:10px;padding:14px 16px;margin-top:12px;break-inside:avoid;page-break-inside:avoid;background:#fff}
    .sec h2{margin:0 0 2px;font-size:14px;color:${C.navy};} .sec .nota{font-size:10.5px;color:${C.cinza};margin-bottom:10px}
    .duas{display:flex;gap:12px} .duas>.sec{flex:1;margin-top:12px}
    .donut{display:flex;align-items:center;gap:14px} .leg-linha{font-size:11.5px;margin:6px 0} .leg-linha b{font-size:14px}
    .quad{display:inline-block;width:10px;height:10px;border-radius:2px;margin-right:6px;vertical-align:middle}
    .cmp{margin-bottom:9px} .cmp-rot{font-size:10.5px;font-weight:700;color:${C.cinza};margin-bottom:3px}
    .cmp-linha{display:flex;align-items:center;gap:8px;margin:2px 0} .trilho{flex:1;height:11px;background:${C.cinzaClaro};border-radius:6px;overflow:hidden}
    .barra{height:11px;border-radius:6px} .cmp-val{width:96px;text-align:right;font-size:10.5px;font-weight:600}
    .legenda{font-size:10.5px;color:${C.cinza};margin-top:4px} .legenda i{display:inline-block;width:10px;height:10px;border-radius:2px;margin:0 6px 0 14px;vertical-align:middle} .legenda i:first-child{margin-left:0}
    .narr{background:${C.fundo};border-left:4px solid ${C.azul};border-radius:6px;padding:10px 14px;line-height:1.55}
    .alerta{background:#FDECEA;border:1px solid #F5C6C1;color:#8A1F17;border-radius:8px;padding:10px 14px;margin-top:10px;font-size:12px}
    .vazio{color:${C.cinza};font-style:italic;padding:16px;text-align:center;background:${C.fundo};border-radius:8px}
    table.tab{width:100%;border-collapse:collapse;font-size:10.5px;margin-top:4px} .tab th{background:${C.navy};color:#fff;padding:7px 6px;font-weight:600;text-align:right}
    .tab td{padding:6px;border-bottom:1px solid ${C.cinzaClaro};text-align:right;} .tab tbody tr:nth-child(even){background:${C.fundo};}
    .quebra{break-before:page;page-break-before:always}
    .rodape{margin-top:14px;font-size:9.5px;color:#8A94A3;border-top:1px solid ${C.borda};padding-top:8px;line-height:1.6}`

  const total = n(t.pranchasAnalisadas), av = n(t.pranchasComAvaria)
  const corpo = snap.semDados
    ? `<div class="sec"><div class="vazio" style="font-size:14px">Nenhuma inspeção registrada entre ${esc(periodo)}.<br>O dashboard será preenchido assim que houver inspeções carregadas no período.</div></div>`
    : `<table class="cards"><tr>
        ${card('Índice de perdas', t.indicePerdas, variacao(t.indicePerdas, ant.indicePerdas, ' p.p.', true, true) + '<br>anterior: ' + esc(ant.indicePerdas ?? '-'), true)}
        ${card('Inspeções', t.inspecoes, variacao(t.inspecoes, ant.inspecoes, '%', null, false) + '<br>' + esc(k.contagens?.contratos ?? '0') + ' contrato(s) · ' + esc(k.contagens?.fornecedores ?? '0') + ' fornecedor(es)')}
        ${card('Pranchas analisadas', t.pranchasAnalisadas, variacao(t.pranchasAnalisadas, ant.pranchasAnalisadas, '%', null, false) + '<br>anterior: ' + esc(ant.pranchasAnalisadas ?? '-'))}
        ${card('Pranchas com avaria', t.pranchasComAvaria, variacao(t.pranchasComAvaria, ant.pranchasComAvaria, '%', true, false) + '<br>anterior: ' + esc(ant.pranchasComAvaria ?? '-'))}
        ${card('Indenização final', t.indenizacaoFinal, variacao(t.indenizacaoFinal, ant.indenizacaoFinal, '%', null, false) + '<br>bruta ' + esc(t.indenizacaoBruta ?? '-') + ' · desc. ' + esc(t.descontos ?? '-'))}
      </tr></table>

      <div class="sec"><h2>Resumo executivo</h2><div class="nota">Texto gerado por IA a partir dos indicadores e conferido número a número.</div>
        <div class="narr">${narrativaHtml(C.navy)}</div>
        ${alertas.length ? `<div class="alerta"><b>⚠ ${alertas.length} contrato(s) em alerta</b> (índice ≥ 2× o geral com ≥ 50 pranchas): ${alertas.map(a => '<b>' + esc(a.nome) + '</b> ' + esc(a.indicePerdas)).join(' · ')}</div>` : ''}
      </div>

      <div class="duas">
        <div class="sec"><h2>Composição das pranchas</h2><div class="nota">Pranchas analisadas no período</div>
          <div class="donut">${donut}<div>
            <div class="leg-linha"><span class="quad" style="background:${C.vermelho}"></span>Com avaria<br><b>${esc(t.pranchasComAvaria)}</b></div>
            <div class="leg-linha"><span class="quad" style="background:${C.verde};opacity:.35"></span>Sem avaria<br><b>${Math.max(0, total - av).toLocaleString('pt-BR')}</b></div>
            <div class="leg-linha" style="color:${C.cinza}">Total: <b style="color:${C.texto}">${esc(t.pranchasAnalisadas)}</b></div>
          </div></div></div>
        <div class="sec"><h2>Período atual × anterior</h2><div class="nota"><span class="quad" style="background:${C.azul}"></span>${esc(periodo)} &nbsp; <span class="quad" style="background:#A9B4C4"></span>${esc((ant.inicio ?? '-') + ' a ' + (ant.fim ?? '-'))}</div>${comparativo}</div>
      </div>

      <div class="sec"><h2>Tendência semanal</h2><div class="nota">Volume inspecionado (barras) e índice de perdas (linha) por semana; tracejado = índice do período.</div>${tendencia}</div>

      <div class="sec"><h2>Índice de perdas por contrato</h2><div class="nota">10 maiores índices · rótulo: índice · com avaria/analisadas</div>${graficoContratos}
        <div class="legenda"><i style="background:${C.vermelho}"></i>Em alerta<i style="background:${C.ambar}"></i>Acima do índice geral<i style="background:${C.azul}"></i>Até o índice geral</div></div>

      <div class="sec"><h2>Indenização final por fornecedor</h2><div class="nota">10 fornecedores com maior índice de perdas · cor pela situação do índice</div>${graficoFornecedores}</div>

      <div class="sec"><h2>Detalhamento por contrato</h2>${tabela('Contrato', contratos, true)}</div>
      <div class="sec"><h2>Detalhamento por fornecedor</h2>${tabela('Fornecedor', fornecedores, false)}</div>`

  const html = `<!doctype html><html><head><meta charset="utf-8"><style>${css}</style></head><body><div class="pag">
    <div class="topo"><div><div class="marca">Tequaly · Auditoria de andaimes</div><h1>Dashboard de inspeções</h1><div class="sub">Período ${esc(periodo)}</div></div>
      <div class="dir">${statusGeral}<br>Gerado em ${esc(geradoEm)}<br>Snapshot #${esc(snap.id)}</div></div>
    ${corpo}
    <div class="rodape"><b>Metodologia.</b> Índice de perdas = pranchas com avaria ÷ pranchas analisadas. Indenização final = bruta − descontos. Comparação com o período anterior de mesma duração (${esc((ant.inicio ?? '-') + ' a ' + (ant.fim ?? '-'))}). Critério de alerta: ${esc(k.criterioAlerta ?? '-')}. Registros ignorados por dados inválidos: ${esc(k.contagens?.registrosIgnorados ?? '0')}. Números calculados a partir do sistema interno; o resumo é produzido por IA e conferido contra os indicadores.</div>
  </div></body></html>`

  // ---------- Versão para o corpo do e-mail (tabelas e estilos inline) ----------
  const kpiMail = (rotulo, valor, sub, cor) => `<td width="50%" style="padding:6px"><table width="100%" cellpadding="0" cellspacing="0" style="border:1px solid ${C.borda};border-radius:8px"><tr><td style="padding:12px">
    <div style="font-size:10px;color:${C.cinza};text-transform:uppercase;letter-spacing:.6px;font-weight:bold">${rotulo}</div>
    <div style="font-size:22px;font-weight:bold;color:${cor || C.navy};margin:4px 0">${esc(valor ?? '-')}</div>
    <div style="font-size:11px;color:${C.cinza}">${sub}</div></td></tr></table></td>`
  const top5 = contratos.slice(0, 5)
  const maxTop = Math.max(...top5.map(g => n(g.indicePerdas)), 0.0001)
  const linhasTop = top5.map(g => `<tr><td style="padding:5px 8px 5px 0;font-size:12px;white-space:nowrap">${esc(corte(g.nome, 26))}</td>
    <td width="60%" style="padding:5px 0"><table width="100%" cellpadding="0" cellspacing="0"><tr><td width="${Math.max(2, Math.round(n(g.indicePerdas) / maxTop * 100))}%" bgcolor="${corIndice(g)}" style="height:10px;font-size:0;line-height:0;border-radius:3px">&nbsp;</td><td style="font-size:0;line-height:0">&nbsp;</td></tr></table></td>
    <td style="padding:5px 0 5px 8px;font-size:12px;font-weight:bold;color:${corIndice(g)};text-align:right;white-space:nowrap">${esc(g.indicePerdas)}</td></tr>`).join('')
  const email = `<!doctype html><html><head><meta charset="utf-8"></head><body style="margin:0;padding:0;background:${C.fundo}">
  <table width="100%" cellpadding="0" cellspacing="0" bgcolor="${C.fundo}"><tr><td align="center" style="padding:20px 10px">
  <table width="640" cellpadding="0" cellspacing="0" style="max-width:640px;width:100%;background:#fff;border-radius:10px;font-family:Arial,Helvetica,sans-serif;color:${C.texto}">
    <tr><td bgcolor="${C.navy}" style="padding:18px 22px;border-radius:10px 10px 0 0;color:#fff">
      <div style="font-size:11px;letter-spacing:1.5px;text-transform:uppercase;opacity:.8">Tequaly · Auditoria de andaimes</div>
      <div style="font-size:21px;font-weight:bold;margin-top:4px">Dashboard de inspeções</div>
      <div style="font-size:13px;opacity:.9">Período ${esc(periodo)}</div></td></tr>
    <tr><td style="padding:16px 16px 4px;font-size:13px">O dashboard completo, com gráficos e tabelas de detalhamento, está no <b>PDF anexo</b>. Destaques do período:</td></tr>
    ${snap.semDados ? `<tr><td style="padding:16px;font-size:13px;color:${C.cinza}">Nenhuma inspeção registrada no período.</td></tr>` : `
    <tr><td style="padding:4px 10px"><table width="100%" cellpadding="0" cellspacing="0">
      <tr>${kpiMail('Índice de perdas', t.indicePerdas, 'anterior: ' + esc(ant.indicePerdas ?? '-') + ' · ' + esc(k.variacao?.indicePerdas ?? '-'), C.vermelho)}${kpiMail('Indenização final', t.indenizacaoFinal, 'variação: ' + esc(k.variacao?.indenizacaoFinal ?? '-'))}</tr>
      <tr>${kpiMail('Pranchas analisadas', t.pranchasAnalisadas, esc(t.inspecoes ?? '0') + ' inspeção(ões)')}${kpiMail('Pranchas com avaria', t.pranchasComAvaria, 'anterior: ' + esc(ant.pranchasComAvaria ?? '-'))}</tr>
    </table></td></tr>
    ${alertas.length ? `<tr><td style="padding:8px 16px"><div style="background:#FDECEA;border:1px solid #F5C6C1;color:#8A1F17;border-radius:8px;padding:10px 14px;font-size:13px"><b>⚠ ${alertas.length} contrato(s) em alerta:</b> ${alertas.map(a => esc(a.nome) + ' (' + esc(a.indicePerdas) + ')').join(', ')}</div></td></tr>` : ''}
    <tr><td style="padding:10px 16px"><div style="font-size:14px;font-weight:bold;color:${C.navy};margin-bottom:6px">Resumo executivo</div>
      <div style="background:${C.fundo};border-left:4px solid ${C.azul};padding:10px 14px;font-size:13px;line-height:1.5">${narrativaHtml(C.navy)}</div></td></tr>
    ${top5.length ? `<tr><td style="padding:10px 16px"><div style="font-size:14px;font-weight:bold;color:${C.navy};margin-bottom:6px">Contratos com maior índice de perdas</div>
      <table width="100%" cellpadding="0" cellspacing="0">${linhasTop}</table></td></tr>` : ''}`}
    <tr><td style="padding:14px 16px 18px;font-size:10px;color:#8A94A3;border-top:1px solid ${C.borda}">Snapshot #${esc(snap.id)} · gerado em ${esc(geradoEm)} pelo n8n. Números calculados a partir do sistema interno; o resumo é produzido por IA e conferido contra os indicadores.</td></tr>
  </table></td></tr></table></body></html>`

  return { html, email }
})()
