-- Migration 24
-- Administração segura de partidas e odds do CravaAí

-- =========================================================
-- 1. ADMIN: CRIAR PARTIDA
-- =========================================================

create or replace function public.admin_create_match(
  p_external_id text,
  p_league_key text,
  p_league_name text,
  p_home_team text,
  p_away_team text,
  p_start_time timestamptz,
  p_venue text default null,
  p_status public.match_status default 'NS'
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_id uuid;
  v_external_id text;
  v_league_key text;
  v_league_name text;
  v_home_team text;
  v_away_team text;
begin
  if auth.uid() is null then
    raise exception 'Usuário não autenticado';
  end if;

  if not public.is_admin() then
    raise exception 'Acesso restrito ao administrador';
  end if;

  v_external_id := nullif(trim(p_external_id), '');
  v_league_key := lower(nullif(trim(p_league_key), ''));
  v_league_name := nullif(trim(p_league_name), '');
  v_home_team := nullif(trim(p_home_team), '');
  v_away_team := nullif(trim(p_away_team), '');

  if v_external_id is null then
    raise exception 'external_id é obrigatório';
  end if;

  if v_league_key is null or v_league_name is null then
    raise exception 'Liga é obrigatória';
  end if;

  if v_home_team is null or v_away_team is null then
    raise exception 'Times são obrigatórios';
  end if;

  if lower(v_home_team) = lower(v_away_team) then
    raise exception 'Mandante e visitante não podem ser iguais';
  end if;

  if p_start_time is null then
    raise exception 'Data da partida é obrigatória';
  end if;

  insert into public.matches (
    external_id,
    league_key,
    league_name,
    home_team,
    away_team,
    status,
    start_time,
    venue
  )
  values (
    v_external_id,
    v_league_key,
    v_league_name,
    v_home_team,
    v_away_team,
    p_status,
    p_start_time,
    nullif(trim(p_venue), '')
  )
  returning id into v_id;

  return v_id;

exception
  when unique_violation then
    raise exception 'Já existe uma partida com esse external_id';
end;
$$;

revoke all on function public.admin_create_match(
  text,
  text,
  text,
  text,
  text,
  timestamptz,
  text,
  public.match_status
) from public;

grant execute on function public.admin_create_match(
  text,
  text,
  text,
  text,
  text,
  timestamptz,
  text,
  public.match_status
) to authenticated;


-- =========================================================
-- 2. ADMIN: EDITAR PARTIDA
-- =========================================================

create or replace function public.admin_update_match(
  p_match_id uuid,
  p_league_key text,
  p_league_name text,
  p_home_team text,
  p_away_team text,
  p_start_time timestamptz,
  p_venue text,
  p_status public.match_status
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_league_key text;
  v_league_name text;
  v_home_team text;
  v_away_team text;
begin
  if auth.uid() is null then
    raise exception 'Usuário não autenticado';
  end if;

  if not public.is_admin() then
    raise exception 'Acesso restrito ao administrador';
  end if;

  v_league_key := lower(nullif(trim(p_league_key), ''));
  v_league_name := nullif(trim(p_league_name), '');
  v_home_team := nullif(trim(p_home_team), '');
  v_away_team := nullif(trim(p_away_team), '');

  if v_league_key is null or v_league_name is null then
    raise exception 'Liga é obrigatória';
  end if;

  if v_home_team is null or v_away_team is null then
    raise exception 'Times são obrigatórios';
  end if;

  if lower(v_home_team) = lower(v_away_team) then
    raise exception 'Mandante e visitante não podem ser iguais';
  end if;

  if p_start_time is null then
    raise exception 'Data da partida é obrigatória';
  end if;

  update public.matches
  set
    league_key = v_league_key,
    league_name = v_league_name,
    home_team = v_home_team,
    away_team = v_away_team,
    start_time = p_start_time,
    venue = nullif(trim(p_venue), ''),
    status = p_status
  where id = p_match_id;

  if not found then
    raise exception 'Partida não encontrada';
  end if;
end;
$$;

revoke all on function public.admin_update_match(
  uuid,
  text,
  text,
  text,
  text,
  timestamptz,
  text,
  public.match_status
) from public;

grant execute on function public.admin_update_match(
  uuid,
  text,
  text,
  text,
  text,
  timestamptz,
  text,
  public.match_status
) to authenticated;


-- =========================================================
-- 3. ADMIN: REGISTRAR PLACAR / STATUS
-- =========================================================

create or replace function public.admin_set_match_result(
  p_match_id uuid,
  p_home_score integer,
  p_away_score integer,
  p_status public.match_status default 'FT'
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if auth.uid() is null then
    raise exception 'Usuário não autenticado';
  end if;

  if not public.is_admin() then
    raise exception 'Acesso restrito ao administrador';
  end if;

  if p_home_score is null or p_away_score is null then
    raise exception 'Placar é obrigatório';
  end if;

  if p_home_score < 0 or p_away_score < 0 then
    raise exception 'Placar inválido';
  end if;

  if p_status not in ('FT', 'HT', 'LIVE', 'AET', 'PEN') then
    raise exception 'Status incompatível com placar';
  end if;

  update public.matches
  set
    home_score = p_home_score,
    away_score = p_away_score,
    status = p_status
  where id = p_match_id;

  if not found then
    raise exception 'Partida não encontrada';
  end if;
end;
$$;

revoke all on function public.admin_set_match_result(
  uuid,
  integer,
  integer,
  public.match_status
) from public;

grant execute on function public.admin_set_match_result(
  uuid,
  integer,
  integer,
  public.match_status
) to authenticated;


-- =========================================================
-- 4. ADMIN: CRIAR OU ATUALIZAR ODDS
-- =========================================================

create or replace function public.admin_upsert_odds(
  p_match_id uuid,
  p_market text,
  p_outcomes jsonb
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_id uuid;
  v_market text;
  v_key text;
  v_value text;
  v_odd numeric;
  v_expected_keys text[];
  v_actual_keys text[];
begin
  if auth.uid() is null then
    raise exception 'Usuário não autenticado';
  end if;

  if not public.is_admin() then
    raise exception 'Acesso restrito ao administrador';
  end if;

  if not exists (
    select 1
    from public.matches
    where id = p_match_id
  ) then
    raise exception 'Partida não encontrada';
  end if;

  v_market := lower(trim(coalesce(p_market, '')));

  if v_market not in (
    '1x2',
    'double_chance',
    'btts',
    'over_under_25'
  ) then
    raise exception 'Mercado ainda não suportado: %', v_market;
  end if;

  if p_outcomes is null or jsonb_typeof(p_outcomes) <> 'object' then
    raise exception 'Outcomes deve ser um objeto JSON';
  end if;

  case v_market
    when '1x2' then
      v_expected_keys := array['1', '2', 'X'];
    when 'double_chance' then
      v_expected_keys := array['12', '1X', 'X2'];
    when 'btts' then
      v_expected_keys := array['no', 'yes'];
    when 'over_under_25' then
      v_expected_keys := array['over', 'under'];
  end case;

  select array_agg(k order by k)
  into v_actual_keys
  from jsonb_object_keys(p_outcomes) as k;

  select array_agg(k order by k)
  into v_expected_keys
  from unnest(v_expected_keys) as k;

  if v_actual_keys is distinct from v_expected_keys then
    raise exception 'Seleções inválidas para o mercado %', v_market;
  end if;

  for v_key, v_value in
    select key, value
    from jsonb_each_text(p_outcomes)
  loop
    begin
      v_odd := v_value::numeric;
    exception
      when invalid_text_representation then
        raise exception 'Odd inválida para seleção %', v_key;
    end;

    if v_odd <= 1 or v_odd > 1000 then
      raise exception 'Odd inválida para seleção %', v_key;
    end if;
  end loop;

  insert into public.odds (
    match_id,
    market,
    outcomes,
    source
  )
  values (
    p_match_id,
    v_market,
    p_outcomes,
    'admin'
  )
  on conflict (match_id, market)
  do update set
    outcomes = excluded.outcomes,
    source = 'admin'
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.admin_upsert_odds(
  uuid,
  text,
  jsonb
) from public;

grant execute on function public.admin_upsert_odds(
  uuid,
  text,
  jsonb
) to authenticated;