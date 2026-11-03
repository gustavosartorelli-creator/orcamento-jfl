-- Realizado de condomínio vindo da Umuarama (portal CondoPro/webware).
-- A administração exporta, mês a mês, o relatório Finanças → Prestação de Contas Desm. Online → "Orçado e Gasto" (botão Exportar Excel)
-- e importa no app. O relatório traz orçado e gasto por conta, em blocos sem título (no JML: 1 = Geral, 2 = Residencial, 3 = Comercial).
-- Cada linha de condomínio com fonte 'umuarama' aponta para um bloco + conta; o realizado é a soma do gasto dessa conta no ano.

create table if not exists orc_condominio (
  id bigserial primary key,
  predio_id text not null references gov_predios(id),
  ano int not null,
  mes int not null check (mes between 1 and 12),
  bloco int not null,
  grupo text,
  conta text not null,
  conta_chave text generated always as (orc__chave(conta)) stored,
  orcado numeric(14,2) not null default 0,
  gasto numeric(14,2) not null default 0
);
create index if not exists orc_condominio_busca on orc_condominio (predio_id, ano, bloco, conta_chave);
alter table orc_condominio enable row level security;

alter table orc_linhas drop constraint if exists orc_linhas_fonte_check;
alter table orc_linhas add constraint orc_linhas_fonte_check check (fonte in ('manual', 'pagamentos', 'umuarama'));
alter table orc_linhas add column if not exists regra_bloco int;
alter table orc_linhas add column if not exists regra_conta text; -- orc__chave da conta da Umuarama

alter table orc_importacoes add column if not exists tipo text not null default 'pagamentos' check (tipo in ('pagamentos', 'umuarama'));
alter table orc_importacoes add column if not exists mes int;

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
               l.orcado_mes, l.orcado_ano, l.fonte, l.realizado_manual, l.regra_vertical, l.regra_finalidades, l.regra_bloco, l.regra_conta,
               case l.fonte when 'manual' then l.realizado_manual when 'umuarama' then coalesce(c.total, 0) else coalesce(m.total, 0) end as realizado,
               coalesce(m.qtd, 0) as qtd,
               case when l.fonte = 'umuarama' then c.meses else m.meses end as meses
        from orc_linhas l
        left join lateral (
          select sum(t.v) as total, sum(t.n)::int as qtd, json_object_agg(t.mes, t.v) as meses
          from (select to_char(p.mes, 'YYYY-MM') as mes, sum(p.valor) as v, count(*) as n
                from orc_pagamentos p where orc__casa(l, p) group by 1) t
        ) m on true
        left join lateral (
          select sum(t.v) as total, json_object_agg(t.mes, t.v) as meses
          from (select to_char(make_date(c.ano, c.mes, 1), 'YYYY-MM') as mes, sum(c.gasto) as v
                from orc_condominio c
                where l.fonte = 'umuarama' and c.predio_id = l.predio_id and c.ano = l.ano and c.bloco = l.regra_bloco and c.conta_chave = l.regra_conta
                group by 1) t
        ) c on true
        where l.predio_id = p_predio and l.ano = p_ano and (u.papel <> 'lider' or l.departamento = u.departamento)
      ) x), '[]'::json),
    'importacao', (select json_build_object('em', em, 'arquivo', arquivo, 'linhas', linhas, 'por', por)
                   from orc_importacoes where predio_id = p_predio and ano = p_ano and tipo = 'pagamentos' order by em desc limit 1),
    'condominio', (select json_build_object('em', i.em, 'por', i.por,
                     'meses', (select json_agg(distinct c.mes) from orc_condominio c where c.predio_id = p_predio and c.ano = p_ano))
                   from orc_importacoes i where i.predio_id = p_predio and i.ano = p_ano and i.tipo = 'umuarama' order by i.em desc limit 1));
end $$;

-- Detalhe: pagamentos (linhas SPE) ou orçado x gasto mês a mês (linhas da Umuarama)
create or replace function orc_detalhe(p_pin text, p_linha bigint) returns json
language plpgsql stable security definer set search_path = public as $$
declare u orc_usuarios; l orc_linhas;
begin
  u := orc__usuario(p_pin);
  select * into l from orc_linhas where id = p_linha;
  if l.id is null then raise exception 'Linha não encontrada' using errcode = 'P0001'; end if;
  perform orc__predio(u, l.predio_id);
  if u.papel = 'lider' and l.departamento <> u.departamento then raise exception 'Sem permissão' using errcode = 'P0001'; end if;
  if l.fonte = 'umuarama' then
    return coalesce((select json_agg(json_build_object('mes', c.mes, 'conta', c.conta, 'orcado', c.orcado, 'gasto', c.gasto) order by c.mes)
           from orc_condominio c
           where c.predio_id = l.predio_id and c.ano = l.ano and c.bloco = l.regra_bloco and c.conta_chave = l.regra_conta), '[]'::json);
  end if;
  return coalesce((select json_agg(json_build_object('mes', p.mes, 'data', p.data_lanc, 'descricao', p.descricao, 'fornecedor', p.fornecedor,
           'nf', p.nf, 'finalidade', p.finalidade, 'vertical', p.vertical, 'valor', p.valor, 'pagamento', p.pagamento)
           order by p.data_lanc desc nulls last, p.id desc)
         from orc_pagamentos p where orc__casa(l, p)), '[]'::json);
end $$;

-- Importação de um mês do relatório "Orçado e Gasto": substitui o que havia daquele prédio/mês
create or replace function orc_importar_condominio(p_pin text, p_predio text, p_ano int, p_mes int, p_arquivo text, p_linhas jsonb) returns json
language plpgsql security definer set search_path = public as $$
declare u orc_usuarios; n int; t numeric;
begin
  u := orc__admin(p_pin, p_predio);
  if p_mes not between 1 and 12 then raise exception 'Mês inválido' using errcode = 'P0001'; end if;
  delete from orc_condominio where predio_id = p_predio and ano = p_ano and mes = p_mes;
  insert into orc_condominio (predio_id, ano, mes, bloco, grupo, conta, orcado, gasto)
  select p_predio, p_ano, p_mes, (r->>'bloco')::int, nullif(r->>'grupo', ''), r->>'conta',
         coalesce((r->>'orcado')::numeric, 0), coalesce((r->>'gasto')::numeric, 0)
  from jsonb_array_elements(p_linhas) r
  where coalesce(r->>'conta', '') <> '';
  get diagnostics n = row_count;
  select coalesce(sum(gasto), 0) into t from orc_condominio where predio_id = p_predio and ano = p_ano and mes = p_mes;
  insert into orc_importacoes (predio_id, ano, mes, tipo, arquivo, linhas, total, por) values (p_predio, p_ano, p_mes, 'umuarama', p_arquivo, n, t, u.nome);
  return json_build_object('linhas', n, 'total', t);
end $$;

-- Contas da Umuarama importadas no ano (para ligar as linhas e ver o que não caiu em nenhuma)
create or replace function orc_contas(p_pin text, p_predio text, p_ano int) returns json
language plpgsql stable security definer set search_path = public as $$
begin
  perform orc__admin(p_pin, p_predio);
  return coalesce((select json_agg(x order by x.bloco, x.grupo, x.conta) from (
    select c.bloco, c.conta_chave as chave, min(c.conta) as conta, min(c.grupo) as grupo, sum(c.gasto) as total,
           max(c.orcado) as orcado_mes, count(distinct c.mes) as meses,
           (select array_agg(l.id) from orc_linhas l where l.predio_id = p_predio and l.ano = p_ano and l.fonte = 'umuarama'
              and l.regra_bloco = c.bloco and l.regra_conta = c.conta_chave) as linhas
    from orc_condominio c where c.predio_id = p_predio and c.ano = p_ano
    group by c.bloco, c.conta_chave) x), '[]'::json);
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
    regra_bloco = (p_linha->>'regra_bloco')::int, regra_conta = nullif(orc__chave(p_linha->>'regra_conta'), ''),
    atualizado_em = now(), atualizado_por = u.nome
  where id = v_id;
  return v_id;
end $$;

-- Carga inicial (03/11/2026): jan a nov/2026 do JML lidos do portal; as 13 linhas de condomínio do JML passaram para fonte 'umuarama'.
