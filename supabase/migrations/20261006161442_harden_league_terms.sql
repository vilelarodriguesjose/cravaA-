-- Migration 26
-- Impede alteração de regras estruturais/financeiras
-- depois que uma liga já possui participantes.

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
  v_current public.leagues%rowtype;
  v_member_count integer;
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

  if p_league_id is null then
    raise exception 'Liga inválida';
  end if;

  select *
  into v_current
  from public.leagues
  where id = p_league_id
  for update;

  if not found then
    raise exception 'Liga não encontrada';
  end if;

  v_name := nullif(btrim(p_name), '');
  v_competition_key := lower(nullif(btrim(p_competition_key), ''));
  v_competition_name := nullif(btrim(p_competition_name), '');
  v_status := lower(nullif(btrim(p_status), ''));
  v_code := upper(nullif(btrim(p_code), ''));

  if v_name is null then
    raise exception 'Nome da liga é obrigatório';
  end if;

  if v_competition_key is null then
    raise exception 'Competition key é obrigatória';
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

  if p_max_players is null
     or p_max_players < p_min_players
     or p_max_players > 1000 then
    raise exception 'Máximo de jogadores inválido';
  end if;

  if p_initial_stack is null
     or p_initial_stack <= 0
     or round(p_initial_stack, 2) <> p_initial_stack then
    raise exception 'Saldo inicial da liga inválido';
  end if;

  if p_reward_1 is null or p_reward_1 < 0
     or round(p_reward_1, 2) <> p_reward_1
     or p_reward_2 is null or p_reward_2 < 0
     or round(p_reward_2, 2) <> p_reward_2
     or p_reward_3 is null or p_reward_3 < 0
     or round(p_reward_3, 2) <> p_reward_3 then
    raise exception 'Premiação inválida';
  end if;

  if p_starts_at is not null
     and p_ends_at is not null
     and p_ends_at <= p_starts_at then
    raise exception 'Data final deve ser posterior à data inicial';
  end if;

  select count(*)
  into v_member_count
  from public.league_members
  where league_id = p_league_id;

  if p_max_players < v_member_count then
    raise exception
      'Máximo de jogadores não pode ser menor que o número atual de participantes';
  end if;

  /*
   * Assim que o primeiro participante entra,
   * as regras fundamentais da competição ficam congeladas.
   *
   * Isso evita que jogadores participem da mesma liga
   * sob condições diferentes.
   */
  if v_member_count > 0 then

    if v_competition_key is distinct from v_current.competition_key
       or v_competition_name is distinct from v_current.competition_name then
      raise exception
        'A competição não pode ser alterada após a entrada de participantes';
    end if;

    if p_initial_stack is distinct from v_current.initial_stack then
      raise exception
        'O saldo inicial não pode ser alterado após a entrada de participantes';
    end if;

    if p_min_players is distinct from v_current.min_players
       or p_max_players is distinct from v_current.max_players then
      raise exception
        'Os limites de participantes não podem ser alterados após a entrada de participantes';
    end if;

    if p_starts_at is distinct from v_current.starts_at
       or p_ends_at is distinct from v_current.ends_at then
      raise exception
        'As datas da liga não podem ser alteradas após a entrada de participantes';
    end if;

    if p_reward_1 is distinct from v_current.reward_1
       or p_reward_2 is distinct from v_current.reward_2
       or p_reward_3 is distinct from v_current.reward_3 then
      raise exception
        'A premiação não pode ser alterada após a entrada de participantes';
    end if;

    if v_code is distinct from v_current.code then
      raise exception
        'O código da liga não pode ser alterado após a entrada de participantes';
    end if;

  end if;

  /*
   * Mudanças de status devem passar exclusivamente
   * por admin_set_league_status(), que valida o ciclo
   * waiting -> active -> finished/cancelled.
   */
  if v_status is distinct from v_current.status then
    raise exception
      'Use admin_set_league_status para alterar o status da liga';
  end if;

  update public.leagues
  set
    name = v_name,
    competition_key = v_competition_key,
    competition_name = v_competition_name,
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