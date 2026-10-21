-- =====================================================================
-- Tequaly · Automação de auditoria — consultas SQL configuradas nos nós Postgres do n8n
-- Versão 1.0 · 21/10/2026 · requer 01_schema_auditoria.sql
-- Todos os nós: operação Execute Query, Options > Query Parameters = expressão em array ($1, $2...),
-- Options > Output Large-Format Numbers As = Numbers. Nada é concatenado na SQL (sem injeção).
-- O WF00 canvas completo usa as mesmas consultas dos nós de mesmo nome.
-- =====================================================================

-- #####################################################################
-- WF10 - Validar chaves das fontes
-- #####################################################################

-- ---- Nó: Ler fontes ativas
-- Fontes ativas (ou só a informada em fonteNome).
-- Query Parameters: ={{ [ ($json.fonteNome || '').trim() ] }}
SELECT id, nome, tipo_auth AS "tipoAuth", base_url AS "baseUrl", endpoint_teste AS "endpointTeste",
       owner_email AS "ownerEmail", status, expira_em::text AS "expiraEm"
FROM auditoria.fontes_sistema
WHERE ativo
  AND ($1::text = '' OR nome ILIKE $1::text)   -- vazio = todas as fontes ativas
ORDER BY id;

-- ---- Nó: Atualizar fonte
-- INDETERMINADA não muda status (statusNovo já vem com o status anterior).
-- Query Parameters: ={{ [ $json.fonteId, $json.statusNovo, $json.resultado, $json.httpStatus, $json.motivo ] }}
UPDATE auditoria.fontes_sistema
SET status = $2, ultimo_resultado = $3, http_status = $4::int, motivo = $5, validado_em = now()
WHERE id = $1::bigint
RETURNING id;

-- ---- Nó: Registrar validação
-- Query Parameters: ={{ [ $('Classificar resultado').item.json.fonteId, $('Classificar resultado').item.json.nome, $('Classificar resultado').item.json.resultado, $('Classificar resultado').item.json.statusAnterior, $('Classificar resultado').item.json.statusNovo, $('Classificar resultado').item.json.httpStatus, $('Classificar resultado').item.json.motivo ] }}
INSERT INTO auditoria.validacao_log (fonte_id, fonte_nome, resultado, status_anterior, status_novo, http_status, motivo)
VALUES ($1::bigint, $2, $3, $4, $5, $6::int, $7)
RETURNING id;

-- ---- Nó: Retornar fontes aptas
-- Fontes aptas para a extração. alwaysOutputData: sem fonte apta o pipeline segue e termina como SEM_FONTES.
-- Configurações: executeOnce, alwaysOutputData
SELECT id, nome, tipo_auth AS "tipoAuth", base_url AS "baseUrl"
FROM auditoria.fontes_sistema
WHERE ativo AND status = 'VALIDA'
ORDER BY id;

-- #####################################################################
-- WF20 - Extrair, carregar e validar endpoint
-- #####################################################################

-- ---- Nó: Ler endpoint
-- alwaysOutputData: endpoint inexistente/inativo segue como item vazio e vira PULADA.
-- Configurações: alwaysOutputData
-- Query Parameters: ={{ [ $json.endpointId ?? '' ] }}
SELECT id, fonte_nome AS "fonteNome", entidade, endpoint, caminho_registros AS "caminhoRegistros",
       campo_id AS "campoId", campo_atualizacao AS "campoAtualizacao", campos_obrigatorios AS "camposObrigatorios",
       param_watermark AS "paramWatermark", to_char(watermark AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') AS watermark,
       param_pagina AS "paramPagina", param_tamanho_pagina AS "paramTamanhoPagina",
       tamanho_pagina AS "tamanhoPagina", limite_rejeicao_pct::float8 AS "limiteRejeicaoPct"
FROM auditoria.endpoints_extracao
WHERE id = NULLIF($1::text, '')::bigint AND ativo
LIMIT 1;

-- ---- Nó: Ler fonte do endpoint
-- Gate do WF10: só extrai de fonte ativa com status VALIDA.
-- Configurações: alwaysOutputData
-- Query Parameters: ={{ [ $('Ler endpoint').first().json.fonteNome || '__sem_endpoint__' ] }}
SELECT id, nome, base_url AS "baseUrl", owner_email AS "ownerEmail"
FROM auditoria.fontes_sistema
WHERE nome = $1 AND ativo AND status = 'VALIDA'   -- gate do WF10
LIMIT 1;

-- ---- Nó: Carregar staging
-- Upsert por entidade + chave_externa, em uma transação: o lote carrega inteiro ou nada.
-- Configurações: Query Batching = transaction
-- Query Parameters: ={{ [ $json.entidade, $json.fonteNome, $json.chaveExterna, $json.atualizadoFonte ?? '', $json.payload_object, $json.cargaId ] }}
INSERT INTO auditoria.staging_registros (entidade, fonte_nome, chave_externa, atualizado_fonte, payload, carga_id)
VALUES ($1, $2, $3, NULLIF($4::text, '')::timestamptz, $5::jsonb, $6)
ON CONFLICT (entidade, chave_externa) DO UPDATE
SET fonte_nome = EXCLUDED.fonte_nome,
    atualizado_fonte = EXCLUDED.atualizado_fonte,
    payload = EXCLUDED.payload,
    carga_id = EXCLUDED.carga_id
RETURNING id, chave_externa AS "chaveExterna";

-- ---- Nó: Avançar watermark
-- Só avança depois da carga aprovada: lote bloqueado ou com erro é re-extraído na próxima execução.
-- Configurações: executeOnce, alwaysOutputData
-- Query Parameters: ={{ [ $('Ler endpoint').first().json.id, $('Normalizar e aplicar DQ').first().json.novoWatermark ?? '' ] }}
UPDATE auditoria.endpoints_extracao
SET watermark = COALESCE(NULLIF($2::text, '')::timestamptz, watermark)
WHERE id = $1::bigint
RETURNING id;

-- ---- Nó: Registrar carga
-- Saída do sub-workflow: a linha gravada em carga_log é o resumo devolvido ao orquestrador.
-- Query Parameters: ={{ [ $json.cargaId, $json.endpointId ?? '', $json.entidade, $json.fonteNome, $json.status, $json.recebidos, $json.aprovados, $json.rejeitados, $json.taxaRejeicaoPct, $json.novoWatermark ?? '', $json.motivo ] }}
INSERT INTO auditoria.carga_log
  (carga_id, endpoint_id, entidade, fonte_nome, status, recebidos, aprovados, rejeitados, taxa_rejeicao_pct, novo_watermark, motivo)
VALUES ($1, NULLIF($2::text, '')::bigint, $3, $4, $5, $6::int, $7::int, $8::int, $9::numeric, NULLIF($10::text, '')::timestamptz, $11)
RETURNING id, carga_id AS "cargaId", endpoint_id AS "endpointId", entidade, fonte_nome AS "fonteNome", status,
          recebidos, aprovados, rejeitados, taxa_rejeicao_pct::float8 AS "taxaRejeicaoPct",
          to_char(novo_watermark AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') AS "novoWatermark", motivo;

-- #####################################################################
-- WF30 - Calcular KPIs e gerar narrativa
-- #####################################################################

-- ---- Nó: Consultar KPIs (SQL)  (substitui "Ler staging de inspeções")
-- Agregação no banco (mart auditoria.vw_inspecoes): período, período anterior, contrato, fornecedor, semana e alertas.
-- Configurações: executeOnce
-- Query Parameters: ={{ [ $('Definir período').first().json.periodoInicio, $('Definir período').first().json.periodoFim ] }}
-- Agregação das inspeções do período ($1 = início, $2 = fim) e do período anterior de mesma duração.
-- Números saem daqui; o nó "Calcular KPIs" só formata em pt-BR e monta a lista de números permitidos para a IA.
WITH p AS (
  SELECT $1::date AS ini, $2::date AS fim, ($2::date - $1::date + 1) AS dias
),
validos AS (
  SELECT * FROM auditoria.vw_inspecoes
  WHERE data_inspecao IS NOT NULL AND pranchas_analisadas IS NOT NULL AND pranchas_avaria IS NOT NULL
),
atual AS (SELECT v.* FROM validos v CROSS JOIN p WHERE v.data_inspecao BETWEEN p.ini AND p.fim),
anterior AS (SELECT v.* FROM validos v CROSS JOIN p WHERE v.data_inspecao BETWEEN p.ini - p.dias AND p.ini - 1),
tot AS (
  SELECT count(*)::int AS inspecoes, COALESCE(sum(pranchas_analisadas), 0) AS analisadas, COALESCE(sum(pranchas_avaria), 0) AS avaria,
         COALESCE(sum(indenizacao_bruta), 0) AS bruta, COALESCE(sum(desconto), 0) AS desconto
  FROM atual
),
tot_ant AS (
  SELECT count(*)::int AS inspecoes, COALESCE(sum(pranchas_analisadas), 0) AS analisadas, COALESCE(sum(pranchas_avaria), 0) AS avaria,
         COALESCE(sum(indenizacao_bruta), 0) AS bruta, COALESCE(sum(desconto), 0) AS desconto
  FROM anterior
),
indice_geral AS (SELECT CASE WHEN analisadas > 0 THEN avaria / analisadas * 100 ELSE 0 END AS v FROM tot),
grupos AS (
  SELECT 'contrato' AS dimensao, contrato AS chave, count(*)::int AS inspecoes, sum(pranchas_analisadas) AS analisadas,
         sum(pranchas_avaria) AS avaria, sum(indenizacao_bruta) AS bruta, sum(desconto) AS desconto
  FROM atual GROUP BY contrato
  UNION ALL
  SELECT 'fornecedor', fornecedor, count(*)::int, sum(pranchas_analisadas), sum(pranchas_avaria), sum(indenizacao_bruta), sum(desconto)
  FROM atual GROUP BY fornecedor
),
grupos_ind AS (
  SELECT g.*, CASE WHEN g.analisadas > 0 THEN g.avaria / g.analisadas * 100 ELSE 0 END AS indice FROM grupos g
),
semanas AS (
  SELECT date_trunc('week', data_inspecao)::date AS semana, count(*)::int AS inspecoes, sum(pranchas_analisadas) AS analisadas,
         sum(pranchas_avaria) AS avaria, sum(indenizacao_bruta) AS bruta, sum(desconto) AS desconto
  FROM atual GROUP BY 1
)
SELECT
  (SELECT dias FROM p) AS dias,
  (SELECT count(*) FROM auditoria.vw_inspecoes) - (SELECT count(*) FROM validos) AS ignorados,
  (SELECT row_to_json(tot) FROM tot) AS totais,
  (SELECT row_to_json(tot_ant) FROM tot_ant) AS anterior,
  (SELECT COALESCE(json_agg(json_build_object('chave', chave, 'inspecoes', inspecoes, 'analisadas', analisadas, 'avaria', avaria,
            'bruta', bruta, 'desconto', desconto,
            -- Alerta: volume relevante (>= 50 pranchas) e índice >= 2x o índice geral do período
            'alerta', analisadas >= 50 AND (SELECT v FROM indice_geral) > 0 AND indice >= 2 * (SELECT v FROM indice_geral))
          ORDER BY indice DESC, chave), '[]'::json)
   FROM grupos_ind WHERE dimensao = 'contrato') AS por_contrato,
  (SELECT COALESCE(json_agg(json_build_object('chave', chave, 'inspecoes', inspecoes, 'analisadas', analisadas, 'avaria', avaria,
            'bruta', bruta, 'desconto', desconto) ORDER BY indice DESC, chave), '[]'::json)
   FROM grupos_ind WHERE dimensao = 'fornecedor') AS por_fornecedor,
  (SELECT COALESCE(json_agg(json_build_object('semana', to_char(semana, 'DD/MM'), 'inspecoes', inspecoes, 'analisadas', analisadas,
            'avaria', avaria, 'bruta', bruta, 'desconto', desconto) ORDER BY semana), '[]'::json)
   FROM semanas) AS serie_semanal;

-- ---- Nó: Salvar snapshot
-- Histórico de cada cálculo: permite auditar o que foi enviado em cada relatório.
-- Query Parameters: ={{ [ $json.entidade, $json.periodoInicio, $json.periodoFim, $json.semDados, JSON.stringify($json.kpis), $json.narrativa ?? '', $json.narrativaValida, $json.motivoNarrativa, $json.modelo ] }}
INSERT INTO auditoria.kpi_snapshots
  (entidade, periodo_inicio, periodo_fim, sem_dados, kpis, narrativa, narrativa_valida, motivo_narrativa, modelo)
VALUES ($1, $2::date, $3::date, $4::boolean, $5::jsonb, $6, $7::boolean, $8, $9)
RETURNING id;

-- #####################################################################
-- WF40 - Gerar e enviar dashboard por e-mail
-- #####################################################################

-- ---- Nó: Ler snapshot
-- snapshotId informado = esse snapshot; vazio = o mais recente.
-- Query Parameters: ={{ [ Number($json.snapshotId) || 0 ] }}
SELECT id, entidade, periodo_inicio::text AS "periodoInicio", periodo_fim::text AS "periodoFim",
       sem_dados AS "semDados", kpis::text AS kpis_object, narrativa,
       narrativa_valida AS "narrativaValida", motivo_narrativa AS "motivoNarrativa"
FROM auditoria.kpi_snapshots
WHERE $1::bigint = 0 OR id = $1::bigint   -- 0 = snapshot mais recente
ORDER BY id DESC
LIMIT 1;

-- ---- Nó: Ler destinatários
-- Configurações: executeOnce
SELECT id, nome, email, perfil, contratos_escopo AS "contratosEscopo", canal_email AS "canalEmail"
FROM auditoria.destinatarios
WHERE ativo AND canal_email AND COALESCE(btrim(email), '') <> ''
ORDER BY id;

-- ---- Nó: Ainda não enviado?
-- Idempotência: 0 linhas (já ENVIADO para este snapshot) encerra o fluxo; FALHA é reenviada.
-- Configurações: executeOnce
-- Query Parameters: ={{ [ $('Ler snapshot').first().json.id ] }}
SELECT 1 AS pendente
WHERE NOT EXISTS (
  SELECT 1 FROM auditoria.envio_log
  WHERE snapshot_id = $1::bigint AND canal = 'email' AND status = 'ENVIADO'
);

-- ---- Nó: Registrar envio
-- Trilha do envio: ENVIADO só com confirmação do provedor; FALHA com o motivo.
-- Query Parameters: ={{ [ $('Ler snapshot').first().json.id, $('Montar dashboard').first().json.qtdDestinatarios, (($json.accepted?.length || $json.messageId || $json.messages?.[0]?.id) && !$json.error ? 'ENVIADO' : 'FALHA'), (() => {
--     // Sucesso exige confirmação do provedor; sem ela é falha (ex.: nó sem credencial devolve o item sem campo error)
--     const e = $json.error
--     const para = 'Para: ' + ($('Montar dashboard').first().json.emails || '(nenhum destinatário)')
--     if (e) return (String(typeof e === 'string' ? e : (e.message ?? JSON.stringify(e))) + ' | ' + para).slice(0, 500)
--     return (($json.messageId ?? 'Sem confirmação do provedor: verificar credencial SMTP e a execução') + ' | ' + para).slice(0, 500)
--   })() ] }}
INSERT INTO auditoria.envio_log (snapshot_id, qtd_destinatarios, canal, status, detalhe)
VALUES ($1::bigint, $2::int, 'email', $3, $4)
RETURNING id, snapshot_id AS "snapshotId", qtd_destinatarios AS "qtdDestinatarios", canal, status, detalhe;

-- #####################################################################
-- WF99 - Tratar erros
-- #####################################################################

-- ---- Nó: Buscar erro igual recente
-- Mesmo workflow + nó + mensagem na última hora = não manda outro e-mail.
-- Configurações: executeOnce, alwaysOutputData
-- Query Parameters: ={{ [ [$('Erro em workflow').first().json.workflow?.id, $('Erro em workflow').first().json.execution?.lastNodeExecuted, String($('Erro em workflow').first().json.execution?.error?.message ?? '').slice(0, 120)].join('|') ] }}
SELECT id
FROM auditoria.erro_log
WHERE assinatura = $1 AND created_at >= now() - interval '60 minutes'
ORDER BY id DESC
LIMIT 1;

-- ---- Nó: Registrar erro
-- Gravado antes do e-mail: se o alerta falhar, o erro continua registrado.
-- Configurações: executeOnce
-- Query Parameters: ={{ [ $('Erro em workflow').first().json.workflow?.id ?? '', $('Erro em workflow').first().json.workflow?.name ?? '', String($('Erro em workflow').first().json.execution?.id ?? ''), $('Erro em workflow').first().json.execution?.url ?? '', $('Erro em workflow').first().json.execution?.lastNodeExecuted ?? '', String($('Erro em workflow').first().json.execution?.error?.message ?? '').slice(0, 500), String($('Erro em workflow').first().json.execution?.error?.description ?? '').slice(0, 500), $('Erro em workflow').first().json.execution?.mode ?? '', [$('Erro em workflow').first().json.workflow?.id, $('Erro em workflow').first().json.execution?.lastNodeExecuted, String($('Erro em workflow').first().json.execution?.error?.message ?? '').slice(0, 120)].join('|'), !$('Buscar erro igual recente').first().json.id ] }}
INSERT INTO auditoria.erro_log
  (workflow_id, workflow_nome, execucao_id, execucao_url, no_falhou, mensagem, descricao, modo, assinatura, alertado)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10::boolean)
RETURNING id, alertado;

-- #####################################################################
-- WF00 - Orquestrador
-- #####################################################################

-- ---- Nó: Listar endpoints ativos
-- Todos os endpoints ativos vão para o WF20; endpoint de fonte não VALIDA vira PULADA com o motivo.
-- Configurações: executeOnce, alwaysOutputData
SELECT id, entidade, fonte_nome AS "fonteNome"
FROM auditoria.endpoints_extracao
WHERE ativo
ORDER BY id;

-- ---- Nó: Registrar execução do pipeline
-- Query Parameters: ={{ [ $json.origem, $json.periodoInicio ?? '', $json.periodoFim ?? '', $json.fontesAptas, $json.endpoints, $json.cargasAprovadas, $json.cargasComProblema, $json.snapshotId ?? '', $json.narrativaValida, $json.enviosOk, $json.enviosFalha, $json.status, $json.resumo ] }}
INSERT INTO auditoria.pipeline_log
  (origem, periodo_inicio, periodo_fim, fontes_aptas, endpoints, cargas_aprovadas, cargas_com_problema,
   snapshot_id, narrativa_valida, envios_ok, envios_falha, status, resumo)
VALUES ($1, NULLIF($2::text, '')::date, NULLIF($3::text, '')::date, $4::int, $5::int, $6::int, $7::int,
        NULLIF($8::text, '')::bigint, $9::boolean, $10::int, $11::int, $12, $13)
RETURNING id;
