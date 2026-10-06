-- Migration 25
-- Administração segura das Ligas CravaAí

create or replace function public.admin_create_league(
  p_name text,
  p_competition_key text,
  p_competition_name text,
  p_status text default 'waiting',
  p_min_players integer default 2,
  p_max_players integer default 20,
  p_initial_stack numeric default 1000,
  p_starts_at timestamptz default null,
  p_ends_at timestamptz default null,
  p_reward_1 numeric default 0,
  p_reward_2 numeric default 0,
  p_reward_3 numeric default 0,
  p_code text default null
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_id uuid;
  v_name text;
  v_competition_key text;
  v_competition_name text;
  v_status text;
  v_code text;
begin
  if auth.uid() is null then
    raise exception 'Usuário não autenticado';
  end if;

  if not public.is_admin() then
    raise exception 'Acesso restrito ao administrador';
  end if;

  v_name := nullif(btrim(p_name), '');
  v_competition_key := lower(nullif(btrim(p_competition_key), ''));
  v_competition_name := nullif(btrim(p_competition_name), '');
  v_status := lower(nullif(btrim(p_status), ''));
  v_code := nullif(upper(btrim(p_code)), '');

  if v_name is null then
    raise exception 'Nome da liga é obrigatório';
  end if;

  if v_competition_key is null then
    raise exception 'competition_key é obrigatório';
  end if;

  if v_competition_name is null then
    raise exception 'Nome da competição é obrigatório';
  end if;

  if v_status not in ('waiting', 'active', 'finished', 'cancelled') then
    raise exception 'Status de liga inválido: %', v_status;
  end if;

  if p_min_players is null or p_min_players < 2 then
    raise exception 'Mínimo de jogadores deve ser pelo menos 2';
  end if;

  if p_max_players is null or p_max_players < p_min_players then
    raise exception 'Máximo de jogadores deve ser maior ou igual ao mínimo';
  end if;

  if p_max_players > 1000 then
    raise exception 'Máximo de jogadores acima do limite permitido';
  end if;

  if p_initial_stack is null or p_initial_stack <= 0 then
    raise exception 'Stack inicial da liga deve ser maior que zero';
  end if;

  if scale(p_initial_stack) > 2 then
    raise exception 'Stack inicial aceita no máximo 2 casas decimais';
  end if;

  if p_reward_1 is null or p_reward_1 < 0
     or p_reward_2 is null or p_reward_2 < 0
     or p_reward_3 is null or p_reward_3 < 0 then
    raise exception 'Premiações não podem ser negativas';
  end if;

  if scale(p_reward_1) > 2
     or scale(p_reward_2) > 2
     or scale(p_reward_3) > 2 then
    raise exception 'Premiações aceitam no máximo 2 casas decimais';
  end if;

  if p_starts_at is not null
     and p_ends_at is not null
     and p_ends_at <= p_starts_at then
    raise exception 'Data final deve ser posterior à data inicial';
  end if;

  insert into public.leagues (
    name,
    competition_key,
    competition_name,
    status,
    min_players,
    max_players,
    initial_stack,
    starts_at,
    ends_at,
    reward_1,
    reward_2,
    reward_3,
    code
  )
  values (
    v_name,
    v_competition_key,
    v_competition_name,
    v_status,
    p_min_players,
    p_max_players,
    round(p_initial_stack, 2),
    p_starts_at,
    p_ends_at,
    round(p_reward_1, 2),
    round(p_reward_2, 2),
    round(p_reward_3, 2),
    v_code
  )
  returning id into v_id;

  return v_id;

exception
  when unique_violation then
    raise exception 'Já existe uma liga com esse código';
end;
$$;


create or replace function public.admin_update_league(
  p_league_id uuid,
  p_name text,
  p_competition_key text,
  p_competition_name text,
  p_status text,
  p_min_players integer,
  p_max_players integer,
  p_initial_stack numeric,
  p_starts_at timestamptz,
  p_ends_at timestamptz,
  p_reward_1 numeric,
  p_reward_2 numeric,
  p_reward_3 numeric,
  p_code text
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_name text;
  v_competition_key text;
  v_competition_name text;
  v_status text;
  v_code text;
  v_member_count integer;
begin
  if auth.uid() is null then
    raise exception 'Usuário não autenticado';
  end if;

  if not public.is_admin() then
    raise exception 'Acesso restrito ao administrador';
  end if;

  v_name := nullif(btrim(p_name), '');
  v_competition_key := lower(nullif(btrim(p_competition_key), ''));
  v_competition_name := nullif(btrim(p_competition_name), '');
  v_status := lower(nullif(btrim(p_status), ''));
  v_code := nullif(upper(btrim(p_code)), '');

  if not exists (
    select 1
    from public.leagues
    where id = p_league_id
  ) then
    raise exception 'Liga não encontrada';
  end if;

  if v_name is null then
    raise exception 'Nome da liga é obrigatório';
  end if;

  if v_competition_key is null then
    raise exception 'competition_key é obrigatório';
  end if;

  if v_competition_name is null then
    raise exception 'Nome da competição é obrigatório';
  end if;

  if v_status not in ('waiting', 'active', 'finished', 'cancelled') then
    raise exception 'Status de liga inválido: %', v_status;
  end if;

  if p_min_players is null or p_min_players < 2 then
    raise exception 'Mínimo de jogadores deve ser pelo menos 2';
  end if;

  if p_max_players is null or p_max_players < p_min_players then
    raise exception 'Máximo de jogadores deve ser maior ou igual ao mínimo';
  end if;

  if p_max_players > 1000 then
    raise exception 'Máximo de jogadores acima do limite permitido';
  end if;

  select count(*)
  into v_member_count
  from public.league_members
  where league_id = p_league_id;

  if p_max_players < v_member_count then
    raise exception
      'Máximo de jogadores não pode ser menor que o número atual de membros (%)',
      v_member_count;
  end if;

  if p_initial_stack is null or p_initial_stack <= 0 then
    raise exception 'Stack inicial da liga deve ser maior que zero';
  end if;

  if scale(p_initial_stack) > 2 then
    raise exception 'Stack inicial aceita no máximo 2 casas decimais';
  end if;

  if p_reward_1 is null or p_reward_1 < 0
     or p_reward_2 is null or p_reward_2 < 0
     or p_reward_3 is null or p_reward_3 < 0 then
    raise exception 'Premiações não podem ser negativas';
  end if;

  if scale(p_reward_1) > 2
     or scale(p_reward_2) > 2
     or scale(p_reward_3) > 2 then
    raise exception 'Premiações aceitam no máximo 2 casas decimais';
  end if;

  if p_starts_at is not null
     and p_ends_at is not null
     and p_ends_at <= p_starts_at then
    raise exception 'Data final deve ser posterior à data inicial';
  end if;

  update public.leagues
  set
    name = v_name,
    competition_key = v_competition_key,
    competition_name = v_competition_name,
    status = v_status,
    min_players = p_min_players,
    max_players = p_max_players,
    initial_stack = round(p_initial_stack, 2),
    starts_at = p_starts_at,
    ends_at = p_ends_at,
    reward_1 = round(p_reward_1, 2),
    reward_2 = round(p_reward_2, 2),
    reward_3 = round(p_reward_3, 2),
    code = v_code
  where id = p_league_id;

exception
  when unique_violation then
    raise exception 'Já existe uma liga com esse código';
end;
$$;


create or replace function public.admin_set_league_status(
  p_league_id uuid,
  p_status text
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_current_status text;
  v_new_status text;
  v_member_count integer;
begin
  if auth.uid() is null then
    raise exception 'Usuário não autenticado';
  end if;

  if not public.is_admin() then
    raise exception 'Acesso restrito ao administrador';
  end if;

  v_new_status := lower(nullif(btrim(p_status), ''));

  if v_new_status not in ('waiting', 'active', 'finished', 'cancelled') then
    raise exception 'Status de liga inválido: %', v_new_status;
  end if;

  select status
  into v_current_status
  from public.leagues
  where id = p_league_id
  for update;

  if not found then
    raise exception 'Liga não encontrada';
  end if;

  if v_current_status = v_new_status then
    return;
  end if;

  if v_current_status = 'waiting'
     and v_new_status not in ('active', 'cancelled') then
    raise exception
      'Transição de status inválida: % -> %',
      v_current_status,
      v_new_status;
  end if;

  if v_current_status = 'active'
     and v_new_status not in ('finished', 'cancelled') then
    raise exception
      'Transição de status inválida: % -> %',
      v_current_status,
      v_new_status;
  end if;

  if v_current_status in ('finished', 'cancelled') then
    raise exception
      'Liga com status % não pode ser reaberta',
      v_current_status;
  end if;

  if v_new_status = 'active' then
    select count(*)
    into v_member_count
    from public.league_members
    where league_id = p_league_id;

    if v_member_count < (
      select min_players
      from public.leagues
      where id = p_league_id
    ) then
      raise exception
        'Liga ainda não possui o número mínimo de jogadores';
    end if;
  end if;

  update public.leagues
  set status = v_new_status
  where id = p_league_id;
end;
$$;


revoke all on function public.admin_create_league(
  text,
  text,
  text,
  text,
  integer,
  integer,
  numeric,
  timestamptz,
  timestamptz,
  numeric,
  numeric,
  numeric,
  text
) from public, anon;

grant execute on function public.admin_create_league(
  text,
  text,
  text,
  text,
  integer,
  integer,
  numeric,
  timestamptz,
  timestamptz,
  numeric,
  numeric,
  numeric,
  text
) to authenticated;


revoke all on function public.admin_update_league(
  uuid,
  text,
  text,
  text,
  text,
  integer,
  integer,
  numeric,
  timestamptz,
  timestamptz,
  numeric,
  numeric,
  numeric,
  text
) from public, anon;

grant execute on function public.admin_update_league(
  uuid,
  text,
  text,
  text,
  text,
  integer,
  integer,
  numeric,
  timestamptz,
  timestamptz,
  numeric,
  numeric,
  numeric,
  text
) to authenticated;


revoke all on function public.admin_set_league_status(
  uuid,
  text
) from public, anon;

grant execute on function public.admin_set_league_status(
  uuid,
  text
) to authenticated;