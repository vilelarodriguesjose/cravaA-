-- Migration 22
-- Centraliza os benefícios dos planos e protege a administração
-- das assinaturas do CravaAí.

-- ============================================================
-- 1. TABELA CENTRAL DE BENEFÍCIOS DOS PLANOS
-- ============================================================

create table if not exists public.plan_entitlements (
  plan text primary key,
  display_name text not null,
  price_brl numeric(10,2) not null default 0,
  league_entries_per_month integer not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint plan_entitlements_price_nonnegative
    check (price_brl >= 0),

  constraint plan_entitlements_entries_nonnegative
    check (league_entries_per_month >= 0)
);

insert into public.plan_entitlements (
  plan,
  display_name,
  price_brl,
  league_entries_per_month,
  active
)
values
  ('free', 'Free', 0.00, 0, true),
  ('pro', 'Pro', 29.90, 3, true)
on conflict (plan)
do update set
  display_name = excluded.display_name,
  price_brl = excluded.price_brl,
  league_entries_per_month = excluded.league_entries_per_month,
  active = excluded.active;


-- ============================================================
-- 2. UPDATED_AT
-- ============================================================

drop trigger if exists trg_plan_entitlements_updated_at
on public.plan_entitlements;

create trigger trg_plan_entitlements_updated_at
before update on public.plan_entitlements
for each row
execute function public.handle_updated_at();


-- ============================================================
-- 3. SEGURANÇA DA TABELA DE BENEFÍCIOS
-- ============================================================

alter table public.plan_entitlements enable row level security;

revoke all on table public.plan_entitlements from public;
revoke all on table public.plan_entitlements from anon;
revoke all on table public.plan_entitlements from authenticated;

grant select on table public.plan_entitlements to anon;
grant select on table public.plan_entitlements to authenticated;

drop policy if exists plan_entitlements_public_select
on public.plan_entitlements;

create policy plan_entitlements_public_select
on public.plan_entitlements
for select
to anon, authenticated
using (active = true);


-- ============================================================
-- 4. REFORÇA SEGURANÇA DE USER_PLANS
-- ============================================================

alter table public.user_plans enable row level security;

revoke all on table public.user_plans from public;
revoke all on table public.user_plans from anon;
revoke all on table public.user_plans from authenticated;

grant select on table public.user_plans to authenticated;

drop policy if exists user_plans_select_own
on public.user_plans;

drop policy if exists user_plans_own_select
on public.user_plans;

create policy user_plans_select_own
on public.user_plans
for select
to authenticated
using (auth.uid() = user_id);


-- ============================================================
-- 5. VALIDAÇÃO DOS VALORES DE USER_PLANS
-- ============================================================

-- Corrige eventual status antigo fora do padrão antes de criar
-- a constraint.
update public.user_plans
set status = lower(trim(status))
where status is not null;

alter table public.user_plans
drop constraint if exists user_plans_status_check;

alter table public.user_plans
add constraint user_plans_status_check
check (status in ('active', 'cancelled', 'expired'));

alter table public.user_plans
drop constraint if exists user_plans_period_check;

alter table public.user_plans
add constraint user_plans_period_check
check (
  current_period_start is null
  or current_period_end is null
  or current_period_end > current_period_start
);


-- ============================================================
-- 6. FUNÇÃO PARA O USUÁRIO CONSULTAR SEU PLANO EFETIVO
-- ============================================================

create or replace function public.get_my_plan()
returns table (
  plan text,
  display_name text,
  price_brl numeric,
  league_entries_per_month integer,
  subscription_status text,
  current_period_start timestamptz,
  current_period_end timestamptz
)
language sql
security definer
stable
set search_path = public
as $$
  with effective_plan as (
    select
      case
        when up.status = 'active'
         and (up.current_period_start is null or up.current_period_start <= now())
         and (up.current_period_end is null or up.current_period_end > now())
         and pe.active = true
        then up.plan
        else 'free'
      end as effective_plan,

      case
        when up.status = 'active'
         and (up.current_period_start is null or up.current_period_start <= now())
         and (up.current_period_end is null or up.current_period_end > now())
         and pe.active = true
        then up.status
        else 'inactive'
      end as effective_status,

      up.current_period_start,
      up.current_period_end

    from (select auth.uid() as user_id) u

    left join public.user_plans up
      on up.user_id = u.user_id

    left join public.plan_entitlements pe
      on pe.plan = up.plan
  )

  select
    pe.plan,
    pe.display_name,
    pe.price_brl,
    pe.league_entries_per_month,
    ep.effective_status,
    ep.current_period_start,
    ep.current_period_end

  from effective_plan ep
  join public.plan_entitlements pe
    on pe.plan = ep.effective_plan
  where auth.uid() is not null;
$$;

revoke all on function public.get_my_plan() from public;
revoke all on function public.get_my_plan() from anon;
revoke all on function public.get_my_plan() from authenticated;

grant execute on function public.get_my_plan() to authenticated;


-- ============================================================
-- 7. FUNÇÃO ADMINISTRATIVA PARA DEFINIR ASSINATURA
-- ============================================================

create or replace function public.admin_set_user_plan(
  p_user_id uuid,
  p_plan text,
  p_status text,
  p_current_period_start timestamptz,
  p_current_period_end timestamptz
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin boolean;
  v_plan text;
  v_status text;
begin
  if auth.uid() is null then
    raise exception 'Autenticação obrigatória';
  end if;

  select p.is_admin
  into v_admin
  from public.profiles p
  where p.id = auth.uid();

  if coalesce(v_admin, false) = false then
    raise exception 'Acesso restrito ao administrador';
  end if;

  if not exists (
    select 1
    from public.profiles
    where id = p_user_id
  ) then
    raise exception 'Usuário não encontrado';
  end if;

  v_plan := lower(trim(p_plan));
  v_status := lower(trim(p_status));

  if not exists (
    select 1
    from public.plan_entitlements
    where plan = v_plan
      and active = true
  ) then
    raise exception 'Plano inválido ou inativo: %', v_plan;
  end if;

  if v_status not in ('active', 'cancelled', 'expired') then
    raise exception 'Status de assinatura inválido: %', v_status;
  end if;

  if p_current_period_start is not null
     and p_current_period_end is not null
     and p_current_period_end <= p_current_period_start then
    raise exception 'Período da assinatura inválido';
  end if;

  insert into public.user_plans (
    user_id,
    plan,
    status,
    current_period_start,
    current_period_end
  )
  values (
    p_user_id,
    v_plan,
    v_status,
    p_current_period_start,
    p_current_period_end
  )
  on conflict (user_id)
  do update set
    plan = excluded.plan,
    status = excluded.status,
    current_period_start = excluded.current_period_start,
    current_period_end = excluded.current_period_end,
    updated_at = now();
end;
$$;

revoke all on function public.admin_set_user_plan(
  uuid,
  text,
  text,
  timestamptz,
  timestamptz
) from public;

revoke all on function public.admin_set_user_plan(
  uuid,
  text,
  text,
  timestamptz,
  timestamptz
) from anon;

revoke all on function public.admin_set_user_plan(
  uuid,
  text,
  text,
  timestamptz,
  timestamptz
) from authenticated;

grant execute on function public.admin_set_user_plan(
  uuid,
  text,
  text,
  timestamptz,
  timestamptz
) to authenticated;


-- ============================================================
-- 8. JOIN_LEAGUE PASSA A USAR A CONFIGURAÇÃO CENTRAL
-- ============================================================

create or replace function public.join_league(
  p_league_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_user uuid;

  v_plan text;
  v_month text;

  v_league public.leagues%rowtype;
  v_entries public.monthly_league_entries%rowtype;

  v_count integer;
  v_entries_allowed integer;
begin

  -- =======================================================
  -- USUÁRIO AUTENTICADO
  -- =======================================================

  v_user := auth.uid();

  if v_user is null then
    return jsonb_build_object(
      'ok', false,
      'message', 'Você precisa estar logado.'
    );
  end if;


  -- =======================================================
  -- VALIDAR ASSINATURA E BUSCAR BENEFÍCIOS
  -- =======================================================

  select
    up.plan,
    pe.league_entries_per_month
  into
    v_plan,
    v_entries_allowed
  from public.user_plans up
  join public.plan_entitlements pe
    on pe.plan = lower(up.plan)
  where up.user_id = v_user
    and up.status = 'active'
    and up.current_period_start is not null
    and up.current_period_end is not null
    and up.current_period_start <= now()
    and up.current_period_end > now()
    and pe.active = true;

  if not found then
    return jsonb_build_object(
      'ok', false,
      'message', 'Você precisa ter um plano ativo e dentro do período de validade para entrar em ligas.'
    );
  end if;


  -- =======================================================
  -- VALIDAR BENEFÍCIO DO PLANO
  -- =======================================================

  if coalesce(v_entries_allowed, 0) <= 0 then
    return jsonb_build_object(
      'ok', false,
      'message', 'Seu plano não possui acesso às ligas.'
    );
  end if;


  -- =======================================================
  -- TRAVAR A LIGA
  -- =======================================================

  select *
  into v_league
  from public.leagues
  where id = p_league_id
  for update;

  if not found then
    return jsonb_build_object(
      'ok', false,
      'message', 'Liga não encontrada.'
    );
  end if;


  -- =======================================================
  -- VALIDAR STATUS
  -- =======================================================

  if v_league.status <> 'waiting' then
    return jsonb_build_object(
      'ok', false,
      'message', 'Essa liga não está aberta para entrada.'
    );
  end if;


  -- =======================================================
  -- VALIDAR DATAS
  -- =======================================================

  if v_league.starts_at is not null
     and v_league.starts_at <= now() then
    return jsonb_build_object(
      'ok', false,
      'message', 'Essa liga já começou.'
    );
  end if;

  if v_league.ends_at is not null
     and v_league.ends_at <= now() then
    return jsonb_build_object(
      'ok', false,
      'message', 'Essa liga já terminou.'
    );
  end if;


  -- =======================================================
  -- IMPEDIR ENTRADA DUPLICADA
  -- =======================================================

  if exists (
    select 1
    from public.league_members lm
    where lm.league_id = p_league_id
      and lm.user_id = v_user
  ) then
    return jsonb_build_object(
      'ok', false,
      'message', 'Você já está nessa liga.'
    );
  end if;


  -- =======================================================
  -- VALIDAR CAPACIDADE
  -- =======================================================

  select count(*)
  into v_count
  from public.league_members lm
  where lm.league_id = p_league_id;

  if v_count >= v_league.max_players then
    return jsonb_build_object(
      'ok', false,
      'message', 'Essa liga já está cheia.'
    );
  end if;


  -- =======================================================
  -- CONTROLE MENSAL DE ENTRADAS
  -- =======================================================

  v_month := to_char(now() at time zone 'UTC', 'YYYY-MM');

  insert into public.monthly_league_entries (
    user_id,
    month_key,
    entries_total,
    entries_used
  )
  values (
    v_user,
    v_month,
    v_entries_allowed,
    0
  )
  on conflict (user_id, month_key)
  do nothing;


  -- Trava o contador mensal.
  select *
  into v_entries
  from public.monthly_league_entries
  where user_id = v_user
    and month_key = v_month
  for update;


  -- Se o benefício do plano mudar, atualiza o limite.
  update public.monthly_league_entries
  set entries_total = v_entries_allowed
  where user_id = v_user
    and month_key = v_month;

  v_entries.entries_total := v_entries_allowed;


  if v_entries.entries_used >= v_entries.entries_total then
    return jsonb_build_object(
      'ok', false,
      'message', 'Você já usou todas as entradas de liga disponíveis neste mês.'
    );
  end if;


  -- =======================================================
  -- ENTRAR NA LIGA
  --
  -- balance = CP exclusivo da liga.
  -- Nenhuma alteração é feita em public.wallets.
  -- =======================================================

  insert into public.league_members (
    league_id,
    user_id,
    balance
  )
  values (
    p_league_id,
    v_user,
    v_league.initial_stack
  );


  -- =======================================================
  -- CONSUMIR UMA ENTRADA
  -- =======================================================

  update public.monthly_league_entries
  set entries_used = entries_used + 1
  where user_id = v_user
    and month_key = v_month;


  -- =======================================================
  -- SUCESSO
  -- =======================================================

  return jsonb_build_object(
    'ok', true,
    'message', 'Você entrou na liga com sucesso.',
    'league_id', p_league_id,
    'league_balance', v_league.initial_stack,
    'plan', v_plan,
    'monthly_entries_total', v_entries_allowed
  );

end;
$$;

revoke all on function public.join_league(uuid) from public;
revoke all on function public.join_league(uuid) from anon;
revoke all on function public.join_league(uuid) from authenticated;

grant execute on function public.join_league(uuid) to authenticated;