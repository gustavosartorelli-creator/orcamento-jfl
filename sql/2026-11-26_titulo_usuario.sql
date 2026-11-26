-- Título do usuário no topo do app (ex.: "Graciele Ranzan - Gerente de manutenção").
-- Quando vazio, o app continua mostrando "nome · departamento".
alter table orc_usuarios add column if not exists titulo text;

create or replace function orc_login(p_pin text) returns json
language plpgsql stable security definer set search_path = public as $$
declare u orc_usuarios;
begin
  perform pg_sleep(0.3);
  u := orc__usuario(p_pin);
  return json_build_object('id', u.id, 'nome', u.nome, 'titulo', u.titulo, 'papel', u.papel, 'departamento', u.departamento, 'predio', u.predio_id,
    've_privadas', u.ve_privadas,
    'predios', coalesce((select json_agg(json_build_object('id', id, 'nome', nome) order by ordem) from gov_predios
                         where ativo and (u.predio_id is null or id = u.predio_id)), '[]'::json));
end $$;

update orc_usuarios set nome = 'Graciele Ranzan', titulo = 'Graciele Ranzan - Gerente de manutenção'
where nome in ('Graciele', 'Graciele Ranzan') and papel = 'lider' and departamento = 'manutencao' and predio_id is null;
