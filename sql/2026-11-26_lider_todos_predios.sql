-- Líder pode ser de todos os prédios (predio_id nulo): vê só o próprio departamento, em qualquer prédio.
-- Ex.: Graciele, gerente de manutenção da JFL. As RPCs já tratavam predio_id nulo (orc__predio) e filtram o departamento do líder.
alter table orc_usuarios drop constraint if exists orc_usuarios_check;
alter table orc_usuarios add constraint orc_usuarios_check check (papel <> 'lider' or departamento is not null);
