-- Vertical com destino: uma linha SPE pode pegar só "Unidades" ou só "Condomínio" da Descrição Vertical da planilha.
-- regra_vertical: 'OPEX' | 'CAPEX' (como antes, qualquer destino) ou 'OPEX UNIDADES' | 'OPEX CONDOMINIO' | 'CAPEX UNIDADES' | 'CAPEX CONDOMINIO'.
-- Ex.: "JML747-Capex Unidades" casa com CAPEX e CAPEX UNIDADES; "JML747-Capex Condomínio" casa com CAPEX e CAPEX CONDOMINIO.

alter table orc_linhas drop constraint if exists orc_linhas_regra_vertical_check;
alter table orc_linhas add constraint orc_linhas_regra_vertical_check check (regra_vertical in
  ('OPEX', 'CAPEX', 'OPEX UNIDADES', 'OPEX CONDOMINIO', 'CAPEX UNIDADES', 'CAPEX CONDOMINIO'));

-- Destino da Descrição Vertical (UNIDADES / CONDOMINIO / nulo)
create or replace function orc__vert_alvo(p_vertical text) returns text
language sql immutable set search_path = public as $$
  select case when orc__chave(p_vertical) like '%UNIDADE%' then 'UNIDADES'
              when orc__chave(p_vertical) like '%CONDOMINIO%' then 'CONDOMINIO' end
$$;

-- A regra da linha aceita este pagamento?
create or replace function orc__vert_ok(p_regra text, p_tipo text, p_vertical text) returns boolean
language sql immutable set search_path = public as $$
  select p_regra is null
      or (split_part(p_regra, ' ', 1) = p_tipo
          and (split_part(p_regra, ' ', 2) = '' or split_part(p_regra, ' ', 2) = orc__vert_alvo(p_vertical)))
$$;

create or replace function orc__casa(l orc_linhas, p orc_pagamentos) returns boolean
language sql immutable set search_path = public as $$
  select l.fonte = 'pagamentos' and p.predio_id = l.predio_id and p.ano = l.ano
     and p.fin_chave = any(l.regra_finalidades) and orc__vert_ok(l.regra_vertical, p.vert_tipo, p.vertical)
$$;

-- Editor: finalidades agrupadas também pelo destino, para a soma da regra bater.
create or replace function orc_finalidades(p_pin text, p_predio text, p_ano integer) returns json
language plpgsql stable security definer set search_path = public as $$
begin
  perform orc__admin(p_pin, p_predio);
  return coalesce((select json_agg(x order by x.vert_tipo nulls last, x.finalidade) from (
    select g.vert_tipo, g.vert_alvo, g.chave, g.finalidade, g.qtd, g.total,
           (select array_agg(l.id) from orc_linhas l where l.predio_id = p_predio and l.ano = p_ano and l.fonte = 'pagamentos'
              and g.chave = any(l.regra_finalidades)
              and (l.regra_vertical is null or (split_part(l.regra_vertical, ' ', 1) = g.vert_tipo
                   and (split_part(l.regra_vertical, ' ', 2) = '' or split_part(l.regra_vertical, ' ', 2) = g.vert_alvo)))) as linhas
    from (select p.vert_tipo, orc__vert_alvo(p.vertical) as vert_alvo, p.fin_chave as chave, min(p.finalidade) as finalidade,
                 count(*) as qtd, sum(p.valor) as total
          from orc_pagamentos p where p.predio_id = p_predio and p.ano = p_ano and p.fin_chave <> ''
          group by 1, 2, 3) g) x), '[]'::json);
end $$;
