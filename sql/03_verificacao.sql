-- Consultas de conferência após a primeira execução do pipeline (rodar no banco, fora do n8n).

-- Última execução ponta a ponta
SELECT id, created_at, status, fontes_aptas, endpoints, cargas_aprovadas, cargas_com_problema, snapshot_id, envios_ok, envios_falha, resumo
FROM auditoria.pipeline_log ORDER BY id DESC LIMIT 5;

-- Situação das chaves
SELECT nome, ativo, status, ultimo_resultado, http_status, motivo, validado_em FROM auditoria.fontes_sistema ORDER BY id;

-- Últimas cargas e watermark por endpoint
SELECT c.created_at, c.entidade, c.status, c.recebidos, c.aprovados, c.rejeitados, c.taxa_rejeicao_pct, c.motivo
FROM auditoria.carga_log c ORDER BY c.id DESC LIMIT 10;
SELECT entidade, ativo, watermark FROM auditoria.endpoints_extracao;

-- Qualidade do mart: registros do staging que a view não consegue tipar (ficam fora dos KPIs)
SELECT count(*) FILTER (WHERE data_inspecao IS NULL)       AS sem_data,
       count(*) FILTER (WHERE pranchas_analisadas IS NULL) AS sem_analisadas,
       count(*) FILTER (WHERE pranchas_avaria IS NULL)     AS sem_avaria,
       count(*)                                            AS total
FROM auditoria.vw_inspecoes;

-- Envios e erros recentes
SELECT id, snapshot_id, qtd_destinatarios, status, detalhe, created_at FROM auditoria.envio_log ORDER BY id DESC LIMIT 10;
SELECT created_at, workflow_nome, no_falhou, mensagem, alertado FROM auditoria.erro_log ORDER BY id DESC LIMIT 10;
