# Workflows n8n — detalhamento por nó

Todos os JSON são exportações do n8n (importar em **Workflows → Import from File**). Os nós Postgres usam *Execute Query* com parâmetros; a SQL completa de cada um está em [`../sql/02_consultas_n8n.sql`](../sql/02_consultas_n8n.sql).

## WF00 — Pipeline de auditoria (canvas completo) · `WF00_pipeline_auditoria_completo.json`

Mesma lógica dos blocos abaixo, em um único canvas organizado em caixas:

| Caixa | Nós principais |
|---|---|
| Entrada | Agendamento diário 06:00 · Rodar pipeline manualmente (formulário) → Normalizar entrada |
| ① Validação de chaves | Ler fontes ativas → Rotear por tipo de auth → Testar Claude API / Testar API (Header Auth) → Classificar resultado → Atualizar fonte → Registrar validação → Precisa notificar? → Avisar dono da chave · Retornar fontes aptas |
| ② Extração, carga e DQ | Listar endpoints ativos → Extrair, DQ e carregar (por endpoint) — chama o WF20 uma vez por endpoint |
| ③ KPIs + narrativa | Definir período → Consultar KPIs (SQL) → Calcular KPIs → Há dados no período? → Gerar narrativa (Claude) → Validar narrativa → Montar pacote → Salvar snapshot → Retornar pacote |
| ④ Dashboard e e-mail | Ler snapshot → Ler destinatários → Montar dashboard → Ainda não enviado? → Gerar PDF → Baixar PDF → Enviar e-mail → Registrar envio |
| ⑤ Consolidação | Consolidar execução → Registrar execução do pipeline (`pipeline_log`) |
| Erro global | Erro em workflow → Buscar erro igual recente → Registrar erro → Alertar agora? → Alertar por e-mail |

"Retornar pacote" tem duas saídas: a de cima (etapa ④) roda primeiro; a de baixo (⑤) só depois que a etapa ④ termina (modo de execução v1).

## WF00 — Orquestrador · `blocos/WF00_orquestrador.json`

Normalizar entrada → Validar chaves (WF10) → Listar endpoints ativos → Extrair e carregar (WF20, 1x por endpoint) → Calcular KPIs (WF30) → Distribuir relatório (WF40) → Consolidar execução → Registrar execução do pipeline. Cada chamada tem *always output data*, então uma etapa vazia não interrompe o registro final.

## WF10 — Validar chaves · `blocos/WF10_validar_chaves.json`

- **Gatilhos:** agenda 05:30, formulário (revalidar uma fonte) ou chamada do WF00 (`fonteNome`, vazio = todas).
- **Teste por tipo de auth:** um nó HTTP por credencial (`anthropic`, `headerAuth`); tipo não suportado vai direto para a classificação com o motivo.
- **Classificação:** 2xx = VALIDA, 401/403 = INVALIDA, demais = INDETERMINADA (mantém o status anterior).
- **Notificação:** só quando o status muda ou a chave está a ≤ 15 dias de expirar.
- **Saída:** fontes ativas com status VALIDA.

## WF20 — Extrair, carregar e DQ · `blocos/WF20_extrair_carregar_dq.json`

- **Entrada:** `endpointId` (linha de `endpoints_extracao`).
- **Gate:** só extrai de fonte VALIDA; caso contrário registra PULADA.
- **Extração:** incremental (`paramWatermark`) com paginação; retentativas e saída de erro → ERRO.
- **DQ por registro:** chave presente e única, campos obrigatórios, data de atualização válida.
- **DQ por lote:** rejeição acima de `limite_rejeicao_pct` → BLOQUEADA + e-mail ao dono, sem carga.
- **Carga:** upsert em `staging_registros` (`entidade` + `chave_externa`), em transação; o watermark avança só em APROVADA.
- **Saída:** linha de `carga_log`.

## WF30 — KPIs e narrativa · `blocos/WF30_kpis_narrativa.json`

- **Definir período:** vazio = últimos 30 dias.
- **Consultar KPIs (SQL):** a partir de `auditoria.vw_inspecoes` (único lugar com os nomes dos campos da API), calcula totais do período e do período anterior de mesma duração, agrupamentos por contrato, fornecedor e semana e o alerta (≥ 50 pranchas e índice ≥ 2× o geral).
- **Calcular KPIs:** índices, formatação pt-BR e lista de números permitidos.
- **Gerar narrativa:** Claude (`claude-sonnet-5-5`), com instruções para só citar números do JSON; falha de API não derruba o fluxo.
- **Validar narrativa:** descarta o texto se houver número fora dos KPIs.
- **Salvar snapshot:** grava em `kpi_snapshots`; a saída vai para o WF40.

## WF40 — Dashboard por e-mail · `blocos/WF40_dashboard_email.json`

- **Entrada:** `snapshotId` (vazio = último); formulário "Reenviar relatório".
- **Montar dashboard:** um único dashboard; gera `dashboard.html` (PDF, gráficos SVG) e `dashboard.email` (tabelas, compatível com Gmail/Outlook). Modelo em [`../dashboards/modelo/montar_dashboard.js`](../dashboards/modelo/montar_dashboard.js).
- **Ainda não enviado?:** encerra se o snapshot já tem envio ENVIADO.
- **Gerar PDF / Baixar PDF:** PDF.co (A4, 12 mm), arquivo `dashboard-auditoria-<snapshot>.pdf`.
- **Enviar e-mail:** um e-mail para todos os destinatários ativos, com o PDF anexo.
- **Registrar envio:** ENVIADO só com confirmação do provedor; caso contrário FALHA com o motivo.

## WF99 — Tratar erros · `blocos/WF99_tratar_erros.json`

Error workflow global de WF00, WF10, WF20, WF30 e WF40: assinatura do erro = workflow + nó + mensagem. Grava em `erro_log` sempre e alerta por e-mail no máximo 1 vez por hora por assinatura. O nó de e-mail vem desativado até existir credencial SMTP.
