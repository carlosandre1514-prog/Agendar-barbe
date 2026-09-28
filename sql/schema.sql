-- =====================================================================
-- BANCO DE DADOS - Agendamento de barbearias (Supabase / Postgres)
-- Cole tudo no SQL Editor do Supabase e clique em Run.
-- =====================================================================

create extension if not exists btree_gist;

-- ---------------------------------------------------------------------
-- 1. TABELAS
-- ---------------------------------------------------------------------

-- Perfil de cada usuario (cliente, dono ou admin). O login em si fica no
-- Supabase Auth; aqui ficam os dados extras.
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  nome text,
  telefone text,
  role text not null default 'cliente' check (role in ('admin', 'dono', 'cliente')),
  created_at timestamptz not null default now()
);

create table public.barbearias (
  id uuid primary key default gen_random_uuid(),
  nome text not null,
  endereco text not null,
  estado char(2) not null,
  cidade text not null,
  dono_id uuid references public.profiles(id),
  ativa boolean not null default true,   -- false = suspensa pelo admin
  created_at timestamptz not null default now()
);
create index on public.barbearias (estado, cidade);

-- Dias e horarios em que a barbearia trabalha.
-- dia_semana: 0 = domingo ... 6 = sabado. Dia sem linha = fechado.
create table public.horarios_funcionamento (
  id uuid primary key default gen_random_uuid(),
  barbearia_id uuid not null references public.barbearias(id) on delete cascade,
  dia_semana smallint not null check (dia_semana between 0 and 6),
  abre time not null,
  fecha time not null,
  check (fecha > abre),
  unique (barbearia_id, dia_semana)
);

-- Servicos (produtos) de cada barbearia. Duracao sempre em minutos.
create table public.servicos (
  id uuid primary key default gen_random_uuid(),
  barbearia_id uuid not null references public.barbearias(id) on delete cascade,
  nome text not null,
  preco numeric(10, 2) not null check (preco >= 0),
  duracao_min integer not null check (duracao_min between 5 and 480),
  imagem_url text,                       -- link da foto no Cloudinary
  ativo boolean not null default true,
  created_at timestamptz not null default now()
);

-- Agendamentos. A regra "quem agenda primeiro fica com o horario" e
-- garantida pelo proprio banco (constraint sem_conflito): dois agendamentos
-- pendentes/confirmados nao podem se sobrepor na mesma barbearia.
-- Se o dono recusar ou o cliente cancelar, o horario volta a ficar livre.
create table public.agendamentos (
  id uuid primary key default gen_random_uuid(),
  barbearia_id uuid not null references public.barbearias(id) on delete cascade,
  servico_id uuid not null references public.servicos(id),
  cliente_id uuid not null references public.profiles(id),
  inicio timestamptz not null,
  fim timestamptz not null,
  status text not null default 'pendente'
    check (status in ('pendente', 'confirmado', 'recusado', 'cancelado')),
  created_at timestamptz not null default now(),
  constraint sem_conflito exclude using gist (
    barbearia_id with =,
    tstzrange(inicio, fim) with &&
  ) where (status in ('pendente', 'confirmado'))
);
create index on public.agendamentos (barbearia_id, inicio);
create index on public.agendamentos (cliente_id);

create table public.avaliacoes (
  id uuid primary key default gen_random_uuid(),
  barbearia_id uuid not null references public.barbearias(id) on delete cascade,
  cliente_id uuid not null default auth.uid() references public.profiles(id),
  nota smallint not null check (nota between 1 and 5),
  comentario text,
  created_at timestamptz not null default now(),
  unique (barbearia_id, cliente_id)
);

-- ---------------------------------------------------------------------
-- 2. FUNCOES AUXILIARES
-- ---------------------------------------------------------------------

-- Cria o perfil automaticamente quando alguem se cadastra.
-- O papel sempre nasce como 'cliente'; so o admin/servidor muda isso.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, nome, telefone)
  values (
    new.id,
    new.raw_user_meta_data ->> 'nome',
    new.raw_user_meta_data ->> 'telefone'
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

create or replace function public.meu_papel()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select role from public.profiles where id = auth.uid();
$$;

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(public.meu_papel() = 'admin', false);
$$;

create or replace function public.eh_dono_da(bid uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.barbearias where id = bid and dono_id = auth.uid()
  );
$$;

-- Ao criar um agendamento: valida o servico, calcula o horario final pela
-- duracao do servico e forca cliente = usuario logado e status = pendente.
create or replace function public.preparar_agendamento()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  s public.servicos%rowtype;
begin
  select * into s
  from public.servicos
  where id = new.servico_id
    and barbearia_id = new.barbearia_id
    and ativo;
  if not found then
    raise exception 'Serviço inválido';
  end if;

  if not exists (
    select 1 from public.barbearias where id = new.barbearia_id and ativa
  ) then
    raise exception 'Barbearia indisponível';
  end if;

  if new.inicio <= now() then
    raise exception 'Esse horário já passou';
  end if;

  new.fim := new.inicio + make_interval(mins => s.duracao_min);
  new.status := 'pendente';
  new.cliente_id := auth.uid();
  return new;
end;
$$;

create trigger antes_de_agendar
  before insert on public.agendamentos
  for each row execute function public.preparar_agendamento();

-- Depois de criado, so o status do agendamento pode mudar.
create or replace function public.proteger_agendamento()
returns trigger
language plpgsql
as $$
begin
  if new.barbearia_id <> old.barbearia_id
     or new.servico_id <> old.servico_id
     or new.cliente_id <> old.cliente_id
     or new.inicio <> old.inicio
     or new.fim <> old.fim then
    raise exception 'Só o status do agendamento pode ser alterado';
  end if;
  return new;
end;
$$;

create trigger antes_de_atualizar_agendamento
  before update on public.agendamentos
  for each row execute function public.proteger_agendamento();

-- O cliente precisa ver quais horarios estao ocupados, mas sem ver quem
-- agendou. Esta funcao devolve so inicio e fim. O site passa o intervalo
-- do dia ja com o fuso do usuario (ex: 2026-10-05T00:00:00-03:00).
create or replace function public.horarios_ocupados(
  p_barbearia uuid,
  p_de timestamptz,
  p_ate timestamptz
)
returns table (inicio timestamptz, fim timestamptz)
language sql
stable
security definer
set search_path = public
as $$
  select a.inicio, a.fim
  from public.agendamentos a
  where a.barbearia_id = p_barbearia
    and a.status in ('pendente', 'confirmado')
    and a.inicio >= p_de
    and a.inicio < p_ate;
$$;

-- ---------------------------------------------------------------------
-- 3. VIEW PUBLICA (lista de barbearias com nota media)
-- ---------------------------------------------------------------------
create view public.barbearias_publicas
with (security_invoker = true) as
select
  b.id,
  b.nome,
  b.endereco,
  b.estado,
  b.cidade,
  coalesce(round(avg(a.nota)::numeric, 1), 0) as nota_media,
  count(a.id) as total_avaliacoes
from public.barbearias b
left join public.avaliacoes a on a.barbearia_id = b.id
where b.ativa
group by b.id;

-- ---------------------------------------------------------------------
-- 4. SEGURANCA (Row Level Security)
-- Sem estas regras qualquer pessoa poderia alterar o banco pelo site.
-- ---------------------------------------------------------------------
alter table public.profiles enable row level security;
alter table public.barbearias enable row level security;
alter table public.horarios_funcionamento enable row level security;
alter table public.servicos enable row level security;
alter table public.agendamentos enable row level security;
alter table public.avaliacoes enable row level security;

-- PROFILES
create policy "ver o proprio perfil ou admin ve todos"
  on public.profiles for select
  using (id = auth.uid() or public.is_admin());

create policy "dono ve os clientes da sua barbearia"
  on public.profiles for select
  using (
    exists (
      select 1
      from public.agendamentos a
      where a.cliente_id = profiles.id
        and public.eh_dono_da(a.barbearia_id)
    )
  );

-- O usuario edita nome/telefone, mas nao consegue mudar o proprio papel.
create policy "editar o proprio perfil"
  on public.profiles for update
  using (id = auth.uid())
  with check (id = auth.uid() and role = public.meu_papel());

create policy "admin gerencia perfis"
  on public.profiles for all
  using (public.is_admin())
  with check (public.is_admin());

-- BARBEARIAS (so o admin cria, edita e suspende)
create policy "publico ve barbearias ativas"
  on public.barbearias for select
  using (ativa or dono_id = auth.uid() or public.is_admin());

create policy "admin gerencia barbearias"
  on public.barbearias for all
  using (public.is_admin())
  with check (public.is_admin());

-- HORARIOS DE FUNCIONAMENTO
create policy "todos veem horarios de funcionamento"
  on public.horarios_funcionamento for select
  using (true);

create policy "dono ou admin gerencia horarios"
  on public.horarios_funcionamento for all
  using (public.eh_dono_da(barbearia_id) or public.is_admin())
  with check (public.eh_dono_da(barbearia_id) or public.is_admin());

-- SERVICOS
create policy "publico ve servicos ativos"
  on public.servicos for select
  using (
    public.eh_dono_da(barbearia_id)
    or public.is_admin()
    or (
      ativo
      and exists (
        select 1 from public.barbearias b
        where b.id = servicos.barbearia_id and b.ativa
      )
    )
  );

create policy "dono ou admin gerencia servicos"
  on public.servicos for all
  using (public.eh_dono_da(barbearia_id) or public.is_admin())
  with check (public.eh_dono_da(barbearia_id) or public.is_admin());

-- AGENDAMENTOS
create policy "ver agendamentos (cliente, dono ou admin)"
  on public.agendamentos for select
  using (
    cliente_id = auth.uid()
    or public.eh_dono_da(barbearia_id)
    or public.is_admin()
  );

create policy "cliente logado cria agendamento"
  on public.agendamentos for insert
  to authenticated
  with check (cliente_id = auth.uid());

create policy "dono ou admin confirma ou recusa"
  on public.agendamentos for update
  using (public.eh_dono_da(barbearia_id) or public.is_admin());

create policy "cliente cancela o proprio agendamento"
  on public.agendamentos for update
  using (cliente_id = auth.uid() and status in ('pendente', 'confirmado'))
  with check (status = 'cancelado');

-- AVALIACOES (so quem teve um agendamento confirmado pode avaliar)
create policy "todos veem avaliacoes"
  on public.avaliacoes for select
  using (true);

create policy "cliente avalia apos atendimento confirmado"
  on public.avaliacoes for insert
  to authenticated
  with check (
    cliente_id = auth.uid()
    and exists (
      select 1 from public.agendamentos a
      where a.cliente_id = auth.uid()
        and a.barbearia_id = avaliacoes.barbearia_id
        and a.status = 'confirmado'
    )
  );

create policy "cliente edita a propria avaliacao"
  on public.avaliacoes for update
  using (cliente_id = auth.uid())
  with check (cliente_id = auth.uid());

create policy "cliente apaga a propria avaliacao"
  on public.avaliacoes for delete
  using (cliente_id = auth.uid());

-- ---------------------------------------------------------------------
-- 5. SEU ACESSO DE ADMIN
-- 1) Crie sua conta normalmente (Authentication > Users > Add user).
-- 2) Rode a linha abaixo trocando pelo seu e-mail:
--
-- update public.profiles set role = 'admin'
-- where id = (select id from auth.users where email = 'SEU_EMAIL_AQUI');
-- ---------------------------------------------------------------------
