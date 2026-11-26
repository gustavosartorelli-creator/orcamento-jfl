-- Itens orçados de uma linha (o que compõe o orçado), mostrados no detalhe da linha abaixo do gráfico.
-- Fonte: planilha "ORÇAMENTO 2026 PARA CONSULTA.xlsx" (abas "Capex JFL 2026 - JML747", "Investimento (M&O)" e "Orç CONSOLIDADO").
-- Por enquanto carregados pelo Claude; não há tela de edição.

create table if not exists orc_itens (
  id bigserial primary key,
  linha_id bigint not null references orc_linhas(id) on delete cascade,
  ordem int not null default 0,
  grupo text,          -- ex.: "Geral", "Residencial"
  descricao text not null,
  fornecedor text,
  valor numeric not null default 0,
  obs text             -- ex.: "Estimado", "Orçado", prioridade
);
create index if not exists orc_itens_linha on orc_itens(linha_id, ordem);
alter table orc_itens enable row level security;   -- sem acesso direto; só pela RPC abaixo

-- Mesmas permissões de orc_detalhe.
create or replace function orc_itens_linha(p_pin text, p_linha bigint) returns json
language plpgsql stable security definer set search_path = public as $$
declare u orc_usuarios; l orc_linhas;
begin
  u := orc__usuario(p_pin);
  select * into l from orc_linhas where id = p_linha;
  if l.id is null or (l.privada and not u.ve_privadas) then raise exception 'Linha não encontrada' using errcode = 'P0001'; end if;
  perform orc__predio(u, l.predio_id);
  if u.papel = 'lider' and l.departamento <> u.departamento then raise exception 'Sem permissão' using errcode = 'P0001'; end if;
  return coalesce((select json_agg(json_build_object('grupo', i.grupo, 'descricao', i.descricao, 'fornecedor', i.fornecedor, 'valor', i.valor, 'obs', i.obs)
                   order by i.ordem, i.id) from orc_itens i where i.linha_id = p_linha), '[]'::json);
end $$;
