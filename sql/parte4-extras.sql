-- Estados liberados no filtro da tela inicial
create table public.estados_ativos (uf text primary key);
alter table public.estados_ativos enable row level security;
create policy "publico ve estados ativos" on public.estados_ativos for select using (true);
create policy "admin gerencia estados ativos" on public.estados_ativos for all using (public.is_admin()) with check (public.is_admin());

-- Dono pode ver nome e telefone de quem agendou na barbearia dele
create policy "dono ve clientes" on public.profiles for select using (
  exists (select 1 from public.agendamentos a
  where a.cliente_id = profiles.id and public.eh_dono_da(a.barbearia_id))
);
