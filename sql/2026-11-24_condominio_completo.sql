-- "Condomínio completo": uma linha por conta do relatório Orçado e Gasto da Umuarama (todo o plano de contas),
-- no departamento 'condominio', visível só para quem tem orc_usuarios.ve_privadas (hoje, só o Gustavo).
-- As linhas privadas são criadas e têm o orçado atualizado a cada importação da Umuarama (orc__sync_privadas):
--   orçado mês = orçado do último mês importado; orçado ano = soma dos meses importados + último orçado x meses que faltam.
-- Contas já ligadas a alguma linha (as dos líderes) não ganham linha privada.

alter table orc_usuarios add column if not exists ve_privadas boolean not null default false;
alter table orc_linhas add column if not exists privada boolean not null default false;
update orc_usuarios set ve_privadas = true where nome = 'Gustavo' and papel = 'admin' and predio_id is null;

-- Nome da seção: "<bloco> · <grupo>" (blocos do JML: 1 Geral, 2 Residencial, 3 Comercial)
create or replace function orc__secao(p_bloco int, p_grupo text, p_conta text) returns text
language sql immutable set search_path = public as $$
  select (case p_bloco when 1 then 'Geral' when 2 then 'Residencial' when 3 then 'Comercial' else 'Bloco ' || p_bloco end) || ' · ' ||
    case when orc__chave(p_conta) in ('DESPESAS', 'BENFEITORIAS') or p_grupo is null then 'Outras contas'
         when orc__chave(p_grupo) = 'DESPESAS' then 'Melhorias e Obras'
         else replace(replace(replace(replace(initcap(lower(regexp_replace(p_grupo, '\s*-\s*', ' - ', 'g'))),
                ' E ', ' e '), ' De ', ' de '), ' Do ', ' do '), ' Da ', ' da ') end
$$;

create or replace function orc__sync_privadas(p_predio text, p_ano int) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not exists (select 1 from orc_usuarios where ve_privadas and ativo and (predio_id is null or predio_id = p_predio)) then return 0; end if;
  create temp table if not exists orc_tmp_contas (bloco int, conta_chave text, conta text, grupo text, orc_ult numeric, orc_soma numeric, ult_mes int) on commit drop;
  delete from orc_tmp_contas;
  insert into orc_tmp_contas
  select c.bloco, c.conta_chave, min(c.conta), mode() within group (order by c.grupo),
         (array_agg(c.orcado order by c.mes desc))[1], sum(c.orcado), max(c.mes)
  from orc_condominio c where c.predio_id = p_predio and c.ano = p_ano group by c.bloco, c.conta_chave;

  insert into orc_linhas (predio_id, ano, departamento, secao, ordem, origem, complemento, orcado_mes, orcado_ano, fonte, regra_bloco, regra_conta, privada, atualizado_por)
  select p_predio, p_ano, 'condominio', orc__secao(k.bloco, k.grupo, k.conta), 0, 'condominio', k.conta, k.orc_ult, k.orc_soma + k.orc_ult * (12 - k.ult_mes),
         'umuarama', k.bloco, k.conta_chave, true, 'importação Umuarama'
  from orc_tmp_contas k
  where not exists (select 1 from orc_linhas l where l.predio_id = p_predio and l.ano = p_ano and l.fonte = 'umuarama'
                      and l.regra_bloco = k.bloco and l.regra_conta = k.conta_chave);
  get diagnostics n = row_count;

  update orc_linhas l set orcado_mes = k.orc_ult, orcado_ano = k.orc_soma + k.orc_ult * (12 - k.ult_mes)
  from orc_tmp_contas k
  where l.predio_id = p_predio and l.ano = p_ano and l.privada and l.fonte = 'umuarama' and l.regra_bloco = k.bloco and l.regra_conta = k.conta_chave;

  -- ordem: por seção (bloco, grupo) e conta
  update orc_linhas l set ordem = o.rn * 10
  from (select id, row_number() over (order by regra_bloco, secao, complemento) rn
        from orc_linhas where predio_id = p_predio and ano = p_ano and privada and departamento = 'condominio') o
  where l.id = o.id;
  return n;
end $$;
revoke all on function orc__sync_privadas(text, int) from public, anon, authenticated;

create or replace function orc_login(p_pin text) returns json
language plpgsql stable security definer set search_path = public as $$
declare u orc_usuarios;
begin
  perform pg_sleep(0.3);
  u := orc__usuario(p_pin);
  return json_build_object('id', u.id, 'nome', u.nome, 'papel', u.papel, 'departamento', u.departamento, 'predio', u.predio_id, 've_privadas', u.ve_privadas,
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
               l.orcado_mes, l.orcado_ano, l.fonte, l.realizado_manual, l.regra_vertical, l.regra_finalidades, l.regra_bloco, l.regra_conta, l.privada,
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
          and (not l.privada or u.ve_privadas)
      ) x), '[]'::json),
    'importacao', (select json_build_object('em', em, 'arquivo', arquivo, 'linhas', linhas, 'por', por)
                   from orc_importacoes where predio_id = p_predio and ano = p_ano and tipo = 'pagamentos' order by em desc limit 1),
    'condominio', (select json_build_object('em', i.em, 'por', i.por,
                     'meses', (select json_agg(distinct c.mes) from orc_condominio c where c.predio_id = p_predio and c.ano = p_ano))
                   from orc_importacoes i where i.predio_id = p_predio and i.ano = p_ano and i.tipo = 'umuarama' order by i.em desc limit 1));
end $$;

create or replace function orc_detalhe(p_pin text, p_linha bigint) returns json
language plpgsql stable security definer set search_path = public as $$
declare u orc_usuarios; l orc_linhas;
begin
  u := orc__usuario(p_pin);
  select * into l from orc_linhas where id = p_linha;
  if l.id is null or (l.privada and not u.ve_privadas) then raise exception 'Linha não encontrada' using errcode = 'P0001'; end if;
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
  perform orc__sync_privadas(p_predio, p_ano);
  return json_build_object('linhas', n, 'total', t);
end $$;

create or replace function orc_contas(p_pin text, p_predio text, p_ano int) returns json
language plpgsql stable security definer set search_path = public as $$
declare u orc_usuarios;
begin
  u := orc__admin(p_pin, p_predio);
  return coalesce((select json_agg(x order by x.bloco, x.grupo, x.conta) from (
    select c.bloco, c.conta_chave as chave, min(c.conta) as conta, min(c.grupo) as grupo, sum(c.gasto) as total,
           max(c.orcado) as orcado_mes, count(distinct c.mes) as meses,
           (select array_agg(l.id) from orc_linhas l where l.predio_id = p_predio and l.ano = p_ano and l.fonte = 'umuarama'
              and l.regra_bloco = c.bloco and l.regra_conta = c.conta_chave and (not l.privada or u.ve_privadas)) as linhas
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
  elsif not exists (select 1 from orc_linhas where id = v_id and predio_id = p_predio and (not privada or u.ve_privadas)) then
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
    privada = case when u.ve_privadas then coalesce((p_linha->>'privada')::boolean, privada) else privada end,
    atualizado_em = now(), atualizado_por = u.nome
  where id = v_id;
  return v_id;
end $$;

create or replace function orc_excluir_linha(p_pin text, p_predio text, p_linha bigint) returns void
language plpgsql security definer set search_path = public as $$
declare u orc_usuarios;
begin
  u := orc__admin(p_pin, p_predio);
  delete from orc_linhas where id = p_linha and predio_id = p_predio and (not privada or u.ve_privadas);
end $$;

-- Carga inicial (24/11/2026): linhas privadas do JML/2026 criadas a partir de jan–nov já importados.
select orc__sync_privadas('jml', 2026);
