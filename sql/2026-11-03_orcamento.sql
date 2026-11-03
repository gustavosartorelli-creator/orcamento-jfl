-- Orçamento por área: cada líder (manutenção, governança, recepção) acompanha o orçamento do próprio departamento.
-- Usa os prédios do app de governança (gov_predios). Tudo com prefixo orc_.
-- Linhas de SPE: o realizado é a soma dos pagamentos importados da planilha
--   "2026-Controle de pagamentos-OPR00291_OPEX-CAPEX.xlsx" (SharePoint OPR_MonthlyReports), por Vertical (OPEX/CAPEX) + Finalidade.
-- Linhas de condomínio: realizado digitado pela administração (até integrar com a Umuarama).
-- Segurança: RLS ligado e sem acesso direto; o app só usa as RPCs abaixo, que validam o PIN.

-- ---------- Tabelas ----------
create table if not exists orc_usuarios (
  id uuid primary key default gen_random_uuid(),
  nome text not null,
  pin text not null unique check (pin ~ '^\d{4}$'),
  papel text not null check (papel in ('admin', 'gestor', 'lider')), -- admin edita; gestor vê todos os departamentos; líder vê só o dele
  departamento text,                                                -- obrigatório para líder
  predio_id text references gov_predios(id),                        -- nulo = todos os prédios
  ativo boolean not null default true,
  check (papel <> 'lider' or (departamento is not null and predio_id is not null))
);

create table if not exists orc_linhas (
  id bigserial primary key,
  predio_id text not null references gov_predios(id),
  ano int not null,
  departamento text not null,
  secao text not null,
  ordem int not null default 0,
  origem text not null default 'condominio' check (origem in ('condominio', 'spe')),
  codigo text,
  complemento text not null,
  finalidade text,
  orcado_mes numeric(14,2) not null default 0,
  orcado_ano numeric(14,2) not null default 0,
  fonte text not null default 'manual' check (fonte in ('manual', 'pagamentos')),
  realizado_manual numeric(14,2) not null default 0,
  regra_vertical text check (regra_vertical in ('OPEX', 'CAPEX')),
  regra_finalidades text[] not null default '{}',
  atualizado_em timestamptz not null default now(),
  atualizado_por text
);
create index if not exists orc_linhas_predio on orc_linhas (predio_id, ano, departamento);

-- Chave de comparação da finalidade: maiúsculas, sem acento e só letras/números ("Limpeza-Insumos" = "LIMPEZA INSUMOS")
create or replace function orc__chave(t text) returns text
language sql immutable as $$
  select regexp_replace(translate(upper(coalesce(t, '')), 'ÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇ', 'AAAAAEEEEIIIIOOOOOUUUUC'), '[^A-Z0-9]', '', 'g')
$$;

create table if not exists orc_pagamentos (
  id bigserial primary key,
  predio_id text not null references gov_predios(id),
  ano int not null,
  mes date,
  data_lanc date,
  cod_item text,
  descricao text,
  fornecedor text,
  nf text,
  finalidade text,
  vertical text,
  valor numeric(14,2) not null,
  vencimento date,
  pagamento date,
  fin_chave text generated always as (orc__chave(finalidade)) stored,
  vert_tipo text generated always as (case when vertical ilike '%capex%' then 'CAPEX' when vertical ilike '%opex%' then 'OPEX' end) stored
);
create index if not exists orc_pagamentos_busca on orc_pagamentos (predio_id, ano, fin_chave);

create table if not exists orc_importacoes (
  id bigserial primary key,
  predio_id text not null references gov_predios(id),
  ano int not null,
  arquivo text,
  linhas int not null,
  total numeric(14,2) not null,
  por text,
  em timestamptz not null default now()
);

alter table orc_usuarios enable row level security;
alter table orc_linhas enable row level security;
alter table orc_pagamentos enable row level security;
alter table orc_importacoes enable row level security;

-- ---------- Auxiliares ----------
create or replace function orc__usuario(p_pin text) returns orc_usuarios
language plpgsql stable security definer set search_path = public as $$
declare u orc_usuarios;
begin
  select * into u from orc_usuarios where pin = p_pin and ativo;
  if u.id is null then raise exception 'PIN inválido' using errcode = 'P0001'; end if;
  return u;
end $$;

create or replace function orc__predio(u orc_usuarios, p_predio text) returns void
language plpgsql stable as $$
begin
  if p_predio is null or not (u.predio_id is null or u.predio_id = p_predio) then
    raise exception 'Sem acesso a este prédio' using errcode = 'P0001';
  end if;
end $$;

create or replace function orc__admin(p_pin text, p_predio text) returns orc_usuarios
language plpgsql stable security definer set search_path = public as $$
declare u orc_usuarios;
begin
  u := orc__usuario(p_pin);
  if u.papel <> 'admin' then raise exception 'Sem permissão' using errcode = 'P0001'; end if;
  perform orc__predio(u, p_predio);
  return u;
end $$;

-- Pagamentos que compõem uma linha
create or replace function orc__casa(l orc_linhas, p orc_pagamentos) returns boolean
language sql immutable as $$
  select l.fonte = 'pagamentos' and p.predio_id = l.predio_id and p.ano = l.ano
     and p.fin_chave = any(l.regra_finalidades) and (l.regra_vertical is null or p.vert_tipo = l.regra_vertical)
$$;

-- ---------- RPCs ----------
create or replace function orc_login(p_pin text) returns json
language plpgsql stable security definer set search_path = public as $$
declare u orc_usuarios;
begin
  perform pg_sleep(0.3);
  u := orc__usuario(p_pin);
  return json_build_object('id', u.id, 'nome', u.nome, 'papel', u.papel, 'departamento', u.departamento, 'predio', u.predio_id,
    'predios', coalesce((select json_agg(json_build_object('id', id, 'nome', nome) order by ordem) from gov_predios
                         where ativo and (u.predio_id is null or id = u.predio_id)), '[]'::json));
end $$;

create or replace function orc_painel(p_pin text, p_predio text, p_ano int) returns json
language plpgsql stable security definer set search_path = public as $$
declare u orc_usuarios;
begin
  u := orc__usuario(p_pin);
  perform orc__predio(u, p_predio);
  return json_build_object(
    'linhas', coalesce((
      select json_agg(x order by x.departamento, x.ordem, x.id) from (
        select l.id, l.departamento, l.secao, l.ordem, l.origem, l.codigo, l.complemento, l.finalidade,
               l.orcado_mes, l.orcado_ano, l.fonte, l.realizado_manual, l.regra_vertical, l.regra_finalidades,
               case when l.fonte = 'manual' then l.realizado_manual else coalesce(m.total, 0) end as realizado,
               coalesce(m.qtd, 0) as qtd, m.meses
        from orc_linhas l
        left join lateral (
          select sum(t.v) as total, sum(t.n)::int as qtd, json_object_agg(t.mes, t.v) as meses
          from (select to_char(p.mes, 'YYYY-MM') as mes, sum(p.valor) as v, count(*) as n
                from orc_pagamentos p where orc__casa(l, p) group by 1) t
        ) m on true
        where l.predio_id = p_predio and l.ano = p_ano and (u.papel <> 'lider' or l.departamento = u.departamento)
      ) x), '[]'::json),
    'importacao', (select json_build_object('em', em, 'arquivo', arquivo, 'linhas', linhas, 'por', por)
                   from orc_importacoes where predio_id = p_predio and ano = p_ano order by em desc limit 1));
end $$;

create or replace function orc_detalhe(p_pin text, p_linha bigint) returns json
language plpgsql stable security definer set search_path = public as $$
declare u orc_usuarios; l orc_linhas;
begin
  u := orc__usuario(p_pin);
  select * into l from orc_linhas where id = p_linha;
  if l.id is null then raise exception 'Linha não encontrada' using errcode = 'P0001'; end if;
  perform orc__predio(u, l.predio_id);
  if u.papel = 'lider' and l.departamento <> u.departamento then raise exception 'Sem permissão' using errcode = 'P0001'; end if;
  return coalesce((select json_agg(json_build_object('mes', p.mes, 'data', p.data_lanc, 'descricao', p.descricao, 'fornecedor', p.fornecedor,
           'nf', p.nf, 'finalidade', p.finalidade, 'vertical', p.vertical, 'valor', p.valor, 'pagamento', p.pagamento)
           order by p.data_lanc desc nulls last, p.id desc)
         from orc_pagamentos p where orc__casa(l, p)), '[]'::json);
end $$;

-- Importação: substitui todos os pagamentos do prédio/ano pelos da planilha
create or replace function orc_importar(p_pin text, p_predio text, p_ano int, p_arquivo text, p_linhas jsonb) returns json
language plpgsql security definer set search_path = public as $$
declare u orc_usuarios; n int; t numeric;
begin
  u := orc__admin(p_pin, p_predio);
  delete from orc_pagamentos where predio_id = p_predio and ano = p_ano;
  insert into orc_pagamentos (predio_id, ano, mes, data_lanc, cod_item, descricao, fornecedor, nf, finalidade, vertical, valor, vencimento, pagamento)
  select p_predio, p_ano, (r->>'mes')::date, (r->>'data')::date, nullif(r->>'cod', ''), nullif(r->>'descricao', ''), nullif(r->>'fornecedor', ''),
         nullif(r->>'nf', ''), nullif(r->>'finalidade', ''), nullif(r->>'vertical', ''), (r->>'valor')::numeric, (r->>'venc')::date, (r->>'pgto')::date
  from jsonb_array_elements(p_linhas) r
  where (r->>'valor') is not null;
  get diagnostics n = row_count;
  select coalesce(sum(valor), 0) into t from orc_pagamentos where predio_id = p_predio and ano = p_ano;
  insert into orc_importacoes (predio_id, ano, arquivo, linhas, total, por) values (p_predio, p_ano, p_arquivo, n, t, u.nome);
  return json_build_object('linhas', n, 'total', t);
end $$;

-- Finalidades encontradas nos pagamentos (para montar as regras das linhas e ver o que não caiu em nenhuma)
create or replace function orc_finalidades(p_pin text, p_predio text, p_ano int) returns json
language plpgsql stable security definer set search_path = public as $$
begin
  perform orc__admin(p_pin, p_predio);
  return coalesce((select json_agg(x order by x.vert_tipo nulls last, x.finalidade) from (
    select p.vert_tipo, p.fin_chave as chave, min(p.finalidade) as finalidade, count(*) as qtd, sum(p.valor) as total,
           (select array_agg(l.id) from orc_linhas l where l.predio_id = p_predio and l.ano = p_ano and l.fonte = 'pagamentos'
              and p.fin_chave = any(l.regra_finalidades) and (l.regra_vertical is null or l.regra_vertical = p.vert_tipo)) as linhas
    from orc_pagamentos p where p.predio_id = p_predio and p.ano = p_ano and p.fin_chave <> ''
    group by p.vert_tipo, p.fin_chave) x), '[]'::json);
end $$;

create or replace function orc_salvar_linha(p_pin text, p_predio text, p_ano int, p_linha jsonb) returns bigint
language plpgsql security definer set search_path = public as $$
declare u orc_usuarios; v_id bigint := (p_linha->>'id')::bigint;
begin
  u := orc__admin(p_pin, p_predio);
  if v_id is null then
    insert into orc_linhas (predio_id, ano, departamento, secao, complemento) values (p_predio, p_ano, p_linha->>'departamento', p_linha->>'secao', p_linha->>'complemento')
    returning id into v_id;
  elsif not exists (select 1 from orc_linhas where id = v_id and predio_id = p_predio) then
    raise exception 'Linha não encontrada' using errcode = 'P0001';
  end if;
  update orc_linhas set
    departamento = p_linha->>'departamento', secao = p_linha->>'secao', ordem = coalesce((p_linha->>'ordem')::int, ordem),
    origem = p_linha->>'origem', codigo = nullif(p_linha->>'codigo', ''), complemento = p_linha->>'complemento',
    finalidade = nullif(p_linha->>'finalidade', ''), orcado_mes = coalesce((p_linha->>'orcado_mes')::numeric, 0),
    orcado_ano = coalesce((p_linha->>'orcado_ano')::numeric, 0), fonte = p_linha->>'fonte',
    realizado_manual = coalesce((p_linha->>'realizado_manual')::numeric, 0), regra_vertical = nullif(p_linha->>'regra_vertical', ''),
    regra_finalidades = coalesce((select array_agg(distinct orc__chave(f)) from jsonb_array_elements_text(p_linha->'regra_finalidades') f where orc__chave(f) <> ''), '{}'),
    atualizado_em = now(), atualizado_por = u.nome
  where id = v_id;
  return v_id;
end $$;

create or replace function orc_excluir_linha(p_pin text, p_predio text, p_linha bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform orc__admin(p_pin, p_predio);
  delete from orc_linhas where id = p_linha and predio_id = p_predio;
end $$;

-- Equipe: o admin vê e cadastra os usuários dos prédios dele
create or replace function orc_usuarios_listar(p_pin text, p_predio text) returns json
language plpgsql stable security definer set search_path = public as $$
begin
  perform orc__admin(p_pin, p_predio);
  return coalesce((select json_agg(json_build_object('id', id, 'nome', nome, 'pin', pin, 'papel', papel, 'departamento', departamento,
                   'predio', predio_id, 'ativo', ativo) order by ativo desc, papel, nome)
         from orc_usuarios where predio_id = p_predio or predio_id is null), '[]'::json);
end $$;

create or replace function orc_salvar_usuario(p_pin text, p_predio text, p_usuario jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare u orc_usuarios; alvo orc_usuarios; v_id uuid := (p_usuario->>'id')::uuid; v_papel text := p_usuario->>'papel';
begin
  u := orc__admin(p_pin, p_predio);
  if v_papel not in ('admin', 'gestor', 'lider') then raise exception 'Papel inválido' using errcode = 'P0001'; end if;
  if exists (select 1 from orc_usuarios where pin = p_usuario->>'pin' and id is distinct from v_id) then
    raise exception 'Este PIN já está em uso' using errcode = 'P0001';
  end if;
  if v_id is not null then
    select * into alvo from orc_usuarios where id = v_id;
    if alvo.id is null or alvo.predio_id is null then raise exception 'Usuário não pode ser editado aqui' using errcode = 'P0001'; end if;
    perform orc__predio(u, alvo.predio_id);
    update orc_usuarios set nome = p_usuario->>'nome', pin = p_usuario->>'pin', papel = v_papel,
      departamento = case when v_papel = 'lider' then p_usuario->>'departamento' end, ativo = coalesce((p_usuario->>'ativo')::boolean, true)
    where id = v_id;
  else
    insert into orc_usuarios (nome, pin, papel, departamento, predio_id)
    values (p_usuario->>'nome', p_usuario->>'pin', v_papel, case when v_papel = 'lider' then p_usuario->>'departamento' end, p_predio)
    returning id into v_id;
  end if;
  return v_id;
end $$;

-- Só as RPCs públicas ficam expostas
revoke all on function orc__usuario(text), orc__predio(orc_usuarios, text), orc__admin(text, text) from public, anon, authenticated;
alter function orc__chave(text) set search_path = public;
alter function orc__predio(orc_usuarios, text) set search_path = public;
alter function orc__casa(orc_linhas, orc_pagamentos) set search_path = public;

-- Carga inicial (03/11/2026): linhas do JML copiadas de "ORÇAMENTO POR ÁREA.xlsx" (Sara) e acessos da Sara (admin JML)
-- e do Gustavo (admin de todos os prédios). Os PINs foram sorteados no banco e não ficam neste arquivo.
-- "Eletros / Equipamentos OPEX" e "Mobiliário" ficaram com realizado digitado: a soma dos pagamentos diverge da planilha da Sara.
