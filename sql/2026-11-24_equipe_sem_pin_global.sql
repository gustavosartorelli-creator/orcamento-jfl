-- Equipe: o PIN de usuários de todos os prédios (predio_id nulo, ex.: Gustavo) não é mostrado a admins de um prédio só.
-- Antes, a Sara (admin do JML) via o PIN do Gustavo na tela Equipe e poderia entrar como ele (e ver as linhas privadas).
create or replace function orc_usuarios_listar(p_pin text, p_predio text) returns json
language plpgsql stable security definer set search_path = public as $$
declare u orc_usuarios;
begin
  u := orc__admin(p_pin, p_predio);
  return coalesce((select json_agg(json_build_object('id', id, 'nome', nome,
                   'pin', case when predio_id is null and u.predio_id is not null then null else pin end,
                   'papel', papel, 'departamento', departamento, 'predio', predio_id, 'ativo', ativo) order by ativo desc, papel, nome)
         from orc_usuarios where predio_id = p_predio or predio_id is null), '[]'::json);
end $$;
