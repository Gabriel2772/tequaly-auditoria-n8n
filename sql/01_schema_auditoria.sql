-- =====================================================================
-- Tequaly · Automação de auditoria (n8n) — esquema PostgreSQL
-- Versão 1.0 · 21/10/2026
-- Executar uma vez no banco que o n8n vai usar (credencial "Postgres Auditoria").
-- Idempotente: pode rodar de novo sem perder dados.
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS auditoria;

-- ---------- Funções utilitárias ----------
-- Conversões que não derrubam a consulta quando o dado da API vem sujo
CREATE OR REPLACE FUNCTION auditoria.try_numeric(v text) RETURNS numeric
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  IF v IS NULL OR btrim(v) = '' THEN RETURN NULL; END IF;
  RETURN replace(btrim(v), ',', '.')::numeric;
EXCEPTION WHEN others THEN RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION auditoria.try_date(v text) RETURNS date
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  IF v IS NULL OR btrim(v) = '' THEN RETURN NULL; END IF;
  -- Data pura = data local; data-hora com fuso = convertida para o horário de Brasília
  IF btrim(v) ~ '^\d{4}-\d{2}-\d{2}$' THEN RETURN btrim(v)::date; END IF;
  RETURN (v::timestamptz AT TIME ZONE 'America/Sao_Paulo')::date;
EXCEPTION WHEN others THEN
  BEGIN RETURN v::date; EXCEPTION WHEN others THEN RETURN NULL; END;
END $$;

CREATE OR REPLACE FUNCTION auditoria.set_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at := now(); RETURN NEW; END $$;

-- ---------- Configuração ----------
CREATE TABLE IF NOT EXISTS auditoria.fontes_sistema (
  id               bigserial PRIMARY KEY,
  nome             text NOT NULL UNIQUE,
  tipo_auth        text NOT NULL,                       -- anthropic | headerAuth (outros caem em "não suportado")
  base_url         text NOT NULL,
  endpoint_teste   text NOT NULL DEFAULT '',
  owner_email      text,
  ativo            boolean NOT NULL DEFAULT true,
  status           text NOT NULL DEFAULT 'PENDENTE' CHECK (status IN ('PENDENTE','VALIDA','INVALIDA')),
  ultimo_resultado text CHECK (ultimo_resultado IN ('VALIDA','INVALIDA','INDETERMINADA')),
  http_status      integer,
  motivo           text,
  validado_em      timestamptz,
  expira_em        date,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS auditoria.endpoints_extracao (
  id                   bigserial PRIMARY KEY,
  fonte_nome           text NOT NULL REFERENCES auditoria.fontes_sistema(nome) ON UPDATE CASCADE,
  entidade             text NOT NULL UNIQUE,
  endpoint             text NOT NULL,
  caminho_registros    text,                            -- chave do array na resposta (vazio = array na raiz)
  campo_id             text NOT NULL,
  campo_atualizacao    text,
  campos_obrigatorios  text NOT NULL DEFAULT '',        -- lista separada por vírgula
  param_watermark      text,
  watermark            timestamptz,
  param_pagina         text,
  param_tamanho_pagina text,
  tamanho_pagina       integer NOT NULL DEFAULT 100 CHECK (tamanho_pagina > 0),
  limite_rejeicao_pct  numeric(5,2) NOT NULL DEFAULT 5 CHECK (limite_rejeicao_pct BETWEEN 0 AND 100),
  ativo                boolean NOT NULL DEFAULT true,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS auditoria.destinatarios (
  id               bigserial PRIMARY KEY,
  nome             text NOT NULL,
  email            text,
  whatsapp         text,
  perfil           text NOT NULL DEFAULT 'gestor' CHECK (perfil IN ('auditor','gestor','diretoria')),
  contratos_escopo text NOT NULL DEFAULT '*',
  canal_email      boolean NOT NULL DEFAULT true,
  canal_whatsapp   boolean NOT NULL DEFAULT false,
  opt_in_whatsapp  boolean NOT NULL DEFAULT false,
  ativo            boolean NOT NULL DEFAULT true,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);

-- ---------- Staging (dado bruto aprovado no DQ) ----------
CREATE TABLE IF NOT EXISTS auditoria.staging_registros (
  id               bigserial PRIMARY KEY,
  entidade         text NOT NULL,
  fonte_nome       text NOT NULL,
  chave_externa    text NOT NULL,
  atualizado_fonte timestamptz,
  payload          jsonb NOT NULL,
  carga_id         text NOT NULL,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_staging_entidade_chave UNIQUE (entidade, chave_externa)   -- base do upsert idempotente
);
CREATE INDEX IF NOT EXISTS ix_staging_entidade ON auditoria.staging_registros (entidade);

-- ---------- Logs e histórico ----------
CREATE TABLE IF NOT EXISTS auditoria.validacao_log (
  id              bigserial PRIMARY KEY,
  fonte_id        bigint REFERENCES auditoria.fontes_sistema(id),
  fonte_nome      text,
  resultado       text,
  status_anterior text,
  status_novo     text,
  http_status     integer,
  motivo          text,
  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS auditoria.carga_log (
  id                bigserial PRIMARY KEY,
  carga_id          text NOT NULL,
  endpoint_id       bigint,
  entidade          text,
  fonte_nome        text,
  status            text NOT NULL CHECK (status IN ('APROVADA','BLOQUEADA','SEM_NOVOS','ERRO','PULADA')),
  recebidos         integer NOT NULL DEFAULT 0,
  aprovados         integer NOT NULL DEFAULT 0,
  rejeitados        integer NOT NULL DEFAULT 0,
  taxa_rejeicao_pct numeric(5,1) NOT NULL DEFAULT 0,
  novo_watermark    timestamptz,
  motivo            text,
  created_at        timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS auditoria.kpi_snapshots (
  id               bigserial PRIMARY KEY,
  entidade         text NOT NULL,
  periodo_inicio   date NOT NULL,
  periodo_fim      date NOT NULL,
  sem_dados        boolean NOT NULL,
  kpis             jsonb NOT NULL,
  narrativa        text NOT NULL DEFAULT '',
  narrativa_valida boolean NOT NULL DEFAULT false,
  motivo_narrativa text,
  modelo           text,
  created_at       timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS auditoria.envio_log (
  id                bigserial PRIMARY KEY,
  snapshot_id       bigint NOT NULL REFERENCES auditoria.kpi_snapshots(id),
  qtd_destinatarios integer NOT NULL DEFAULT 0,
  canal             text NOT NULL DEFAULT 'email',
  status            text NOT NULL CHECK (status IN ('ENVIADO','FALHA')),
  detalhe           text,
  created_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_envio_snapshot ON auditoria.envio_log (snapshot_id, canal, status);

CREATE TABLE IF NOT EXISTS auditoria.erro_log (
  id            bigserial PRIMARY KEY,
  workflow_id   text,
  workflow_nome text,
  execucao_id   text,
  execucao_url  text,
  no_falhou     text,
  mensagem      text,
  descricao     text,
  modo          text,
  assinatura    text,
  alertado      boolean NOT NULL DEFAULT false,
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_erro_assinatura ON auditoria.erro_log (assinatura, created_at DESC);

CREATE TABLE IF NOT EXISTS auditoria.pipeline_log (
  id                  bigserial PRIMARY KEY,
  origem              text,
  periodo_inicio      date,
  periodo_fim         date,
  fontes_aptas        integer,
  endpoints           integer,
  cargas_aprovadas    integer,
  cargas_com_problema integer,
  snapshot_id         bigint,
  narrativa_valida    boolean,
  envios_ok           integer,
  envios_falha        integer,
  status              text CHECK (status IN ('OK','PARCIAL','SEM_FONTES')),
  resumo              text,
  created_at          timestamptz NOT NULL DEFAULT now()
);

-- updated_at automático
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['fontes_sistema','endpoints_extracao','destinatarios','staging_registros'] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_%1$s_updated ON auditoria.%1$s', t);
    EXECUTE format('CREATE TRIGGER trg_%1$s_updated BEFORE UPDATE ON auditoria.%1$s FOR EACH ROW EXECUTE FUNCTION auditoria.set_updated_at()', t);
  END LOOP;
END $$;

-- ---------- Mart: inspeções tipadas ----------
-- ÚNICO lugar para ajustar o nome dos campos quando a TI documentar a API (payload->>'...').
CREATE OR REPLACE VIEW auditoria.vw_inspecoes AS
SELECT
  s.id,
  s.chave_externa,
  COALESCE(NULLIF(s.payload->>'contrato_id', ''), 'sem contrato')   AS contrato,
  COALESCE(NULLIF(s.payload->>'fornecedor', ''), 'não informado')   AS fornecedor,
  auditoria.try_date(s.payload->>'data_inspecao')                   AS data_inspecao,
  auditoria.try_numeric(s.payload->>'pranchas_analisadas')          AS pranchas_analisadas,
  auditoria.try_numeric(s.payload->>'pranchas_avaria')              AS pranchas_avaria,
  COALESCE(auditoria.try_numeric(s.payload->>'indenizacao_bruta'), 0) AS indenizacao_bruta,
  COALESCE(auditoria.try_numeric(s.payload->>'desconto'), 0)          AS desconto
FROM auditoria.staging_registros s
WHERE s.entidade = 'inspecoes';

-- ---------- Carga inicial de configuração (mesmos valores das Data Tables) ----------
INSERT INTO auditoria.fontes_sistema (nome, tipo_auth, base_url, endpoint_teste, owner_email, ativo)
VALUES
  ('Claude API', 'anthropic', 'https://api.anthropic.com', '/v1/models', 'auditoria@suaempresa.com.br', true),
  ('Sistema Tequaly', 'headerAuth', 'https://SUBSTITUIR-URL-DA-API-TEQUALY', '/health', 'auditoria@suaempresa.com.br', false)
ON CONFLICT (nome) DO NOTHING;

INSERT INTO auditoria.endpoints_extracao
  (fonte_nome, entidade, endpoint, caminho_registros, campo_id, campo_atualizacao, campos_obrigatorios,
   param_watermark, param_pagina, param_tamanho_pagina, tamanho_pagina, limite_rejeicao_pct, ativo)
VALUES
  ('Sistema Tequaly', 'inspecoes', '/inspecoes', 'data', 'id', 'updated_at', 'id,contrato_id,data_inspecao',
   'updated_since', 'page', 'per_page', 100, 5, true)
ON CONFLICT (entidade) DO NOTHING;

INSERT INTO auditoria.destinatarios (nome, email, perfil, contratos_escopo, canal_email, ativo)
SELECT 'Auditoria', 'auditoria@suaempresa.com.br', 'gestor', '*', true, true
WHERE NOT EXISTS (SELECT 1 FROM auditoria.destinatarios WHERE email = 'auditoria@suaempresa.com.br');
