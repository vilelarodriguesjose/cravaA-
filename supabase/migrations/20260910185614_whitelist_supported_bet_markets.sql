-- Migration 21
-- Restringe novas apostas aos mercados que o backend
-- já consegue liquidar automaticamente.

-- =========================================================
-- 1. NORMAL BET
-- =========================================================

create or replace function public.place_bet(
  p_stake numeric,
  p_bet_type text,
  p_items jsonb
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $function$
declare
  v_user_id uuid;
  v_balance numeric(14,2);
  v_bet_id uuid;
  v_item jsonb;
  v_match_id uuid;
  v_market text;
  v_selection text;
  v_odd numeric;
  v_total_odds numeric := 1;
  v_item_count integer;
  v_sanitized_items jsonb := '[]'::jsonb;
begin
  v_user_id := auth.uid();

  if v_user_id is null then
    raise exception 'Usuário não autenticado';
  end if;

  if p_stake is null or p_stake <= 0 then
    raise exception 'Stake inválida';
  end if;

  if p_stake <> round(p_stake, 2) then
    raise exception 'Stake deve possuir no máximo 2 casas decimais';
  end if;

  if p_items is null
     or jsonb_typeof(p_items) <> 'array' then
    raise exception 'Itens da aposta inválidos';
  end if;

  v_item_count := jsonb_array_length(p_items);

  if v_item_count = 0 then
    raise exception 'A aposta precisa possuir pelo menos uma seleção';
  end if;

  if v_item_count > 20 then
    raise exception 'Número máximo de seleções excedido';
  end if;

  p_bet_type := lower(trim(p_bet_type));

  if p_bet_type not in ('single', 'multiple') then
    raise exception 'Tipo de aposta inválido';
  end if;

  if p_bet_type = 'single'
     and v_item_count <> 1 then
    raise exception 'Aposta simples deve possuir exatamente uma seleção';
  end if;

  if p_bet_type = 'multiple'
     and v_item_count < 2 then
    raise exception 'Aposta múltipla precisa possuir pelo menos duas seleções';
  end if;

  select balance_cp
  into v_balance
  from public.wallets
  where user_id = v_user_id
  for update;

  if not found then
    raise exception 'Carteira não encontrada';
  end if;

  if v_balance < p_stake then
    raise exception 'Saldo insuficiente';
  end if;

  for v_item in
    select value
    from jsonb_array_elements(p_items)
  loop
    begin
      v_match_id := (v_item ->> 'match_id')::uuid;
    exception
      when others then
        raise exception 'match_id inválido';
    end;

    v_market := lower(trim(v_item ->> 'market'));
    v_selection := trim(v_item ->> 'selection');

    if v_market is null or v_market = '' then
      raise exception 'Mercado inválido';
    end if;

    if v_market not in (
      '1x2',
      'double_chance',
      'btts',
      'over_under_25'
    ) then
      raise exception
        'Mercado ainda não suportado: %',
        v_market;
    end if;

    if v_selection is null or v_selection = '' then
      raise exception 'Seleção inválida';
    end if;

    if exists (
      select 1
      from jsonb_array_elements(v_sanitized_items) s
      where (s ->> 'match_id')::uuid = v_match_id
        and lower(s ->> 'market') = v_market
        and (s ->> 'selection') = v_selection
    ) then
      raise exception 'Seleção duplicada na aposta';
    end if;

    perform 1
    from public.matches m
    where m.id = v_match_id
      and m.status = 'NS'
      and m.start_time > now();

    if not found then
      raise exception 'Partida indisponível para apostas';
    end if;

    select (o.outcomes ->> v_selection)::numeric
    into v_odd
    from public.odds o
    where o.match_id = v_match_id
      and lower(o.market) = v_market;

    if v_odd is null then
      raise exception 'Odd não encontrada para a seleção informada';
    end if;

    if v_odd <= 1 then
      raise exception 'Odd inválida';
    end if;

    v_sanitized_items :=
      v_sanitized_items ||
      jsonb_build_array(
        jsonb_build_object(
          'match_id', v_match_id,
          'market', v_market,
          'selection', v_selection,
          'odd', v_odd
        )
      );

    v_total_odds :=
      v_total_odds * v_odd;
  end loop;

  v_total_odds := round(v_total_odds, 4);

  insert into public.bets (
    user_id,
    stake,
    total_odds,
    payout,
    status,
    bet_type
  )
  values (
    v_user_id,
    p_stake,
    v_total_odds,
    null,
    'OPEN',
    p_bet_type
  )
  returning id into v_bet_id;

  for v_item in
    select value
    from jsonb_array_elements(v_sanitized_items)
  loop
    insert into public.bet_items (
      bet_id,
      match_id,
      market,
      selection,
      odd,
      result
    )
    values (
      v_bet_id,
      (v_item ->> 'match_id')::uuid,
      v_item ->> 'market',
      v_item ->> 'selection',
      (v_item ->> 'odd')::numeric,
      'PENDING'
    );
  end loop;

  update public.wallets
  set balance_cp = balance_cp - p_stake
  where user_id = v_user_id;

  insert into public.transactions (
    user_id,
    type,
    amount,
    balance_after,
    reference_id,
    description
  )
  values (
    v_user_id,
    'bet',
    -p_stake,
    v_balance - p_stake,
    v_bet_id,
    'Aposta realizada'
  );

  return v_bet_id;
end;
$function$;


-- =========================================================
-- 2. LEAGUE BET
-- =========================================================

create or replace function public.place_league_bet(
  p_league_id uuid,
  p_stake numeric,
  p_items jsonb
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $function$
declare
  v_user_id uuid;
  v_league public.leagues%rowtype;
  v_balance numeric;
  v_bet_id uuid;
  v_item jsonb;
  v_match_id uuid;
  v_market text;
  v_selection text;
  v_odd numeric;
  v_total_odds numeric := 1;
  v_item_count integer;
  v_sanitized_items jsonb := '[]'::jsonb;
begin
  v_user_id := auth.uid();

  if v_user_id is null then
    raise exception 'Usuário não autenticado';
  end if;

  if p_stake is null or p_stake <= 0 then
    raise exception 'Stake inválida';
  end if;

  if p_stake <> round(p_stake, 2) then
    raise exception 'Stake deve possuir no máximo 2 casas decimais';
  end if;

  if p_items is null
     or jsonb_typeof(p_items) <> 'array' then
    raise exception 'Itens da aposta inválidos';
  end if;

  v_item_count := jsonb_array_length(p_items);

  if v_item_count = 0 then
    raise exception 'A aposta precisa possuir pelo menos uma seleção';
  end if;

  if v_item_count > 20 then
    raise exception 'Número máximo de seleções excedido';
  end if;

  select *
  into v_league
  from public.leagues
  where id = p_league_id
  for update;

  if not found then
    raise exception 'Liga não encontrada';
  end if;

  if v_league.status not in ('waiting', 'active') then
    raise exception 'Liga não está disponível para apostas';
  end if;

  if v_league.starts_at is not null
     and v_league.starts_at > now() then
    raise exception 'A liga ainda não começou';
  end if;

  if v_league.ends_at is not null
     and v_league.ends_at <= now() then
    raise exception 'A liga já terminou';
  end if;

  select lm.balance
  into v_balance
  from public.league_members lm
  where lm.league_id = p_league_id
    and lm.user_id = v_user_id
  for update;

  if not found then
    raise exception 'Usuário não participa desta liga';
  end if;

  if v_balance < p_stake then
    raise exception 'Saldo insuficiente na liga';
  end if;

  for v_item in
    select value
    from jsonb_array_elements(p_items)
  loop
    begin
      v_match_id := (v_item ->> 'match_id')::uuid;
    exception
      when others then
        raise exception 'match_id inválido';
    end;

    v_market := lower(trim(v_item ->> 'market'));
    v_selection := trim(v_item ->> 'selection');

    if v_market is null or v_market = '' then
      raise exception 'Mercado inválido';
    end if;

    if v_market not in (
      '1x2',
      'double_chance',
      'btts',
      'over_under_25'
    ) then
      raise exception
        'Mercado ainda não suportado: %',
        v_market;
    end if;

    if v_selection is null or v_selection = '' then
      raise exception 'Seleção inválida';
    end if;

    if exists (
      select 1
      from jsonb_array_elements(v_sanitized_items) s
      where (s ->> 'match_id')::uuid = v_match_id
        and lower(s ->> 'market') = v_market
        and (s ->> 'selection') = v_selection
    ) then
      raise exception 'Seleção duplicada na aposta da liga';
    end if;

    perform 1
    from public.matches m
    where m.id = v_match_id
      and m.league_key = v_league.competition_key
      and m.status = 'NS'
      and m.start_time > now();

    if not found then
      raise exception 'Partida indisponível para esta liga';
    end if;

    select (o.outcomes ->> v_selection)::numeric
    into v_odd
    from public.odds o
    where o.match_id = v_match_id
      and lower(o.market) = v_market;

    if v_odd is null then
      raise exception 'Odd não encontrada para a seleção informada';
    end if;

    if v_odd <= 1 then
      raise exception 'Odd inválida';
    end if;

    v_sanitized_items :=
      v_sanitized_items ||
      jsonb_build_array(
        jsonb_build_object(
          'match_id', v_match_id,
          'market', v_market,
          'selection', v_selection,
          'odd', v_odd
        )
      );

    v_total_odds :=
      v_total_odds * v_odd;
  end loop;

  v_total_odds := round(v_total_odds, 4);

  insert into public.league_bets (
    league_id,
    match_id,
    user_id,
    market,
    selection,
    odd,
    stake,
    status,
    profit,
    payout,
    selections,
    total_odds
  )
  values (
    p_league_id,
    null,
    v_user_id,
    null,
    null,
    null,
    p_stake,
    'OPEN',
    null,
    null,
    v_sanitized_items,
    v_total_odds
  )
  returning id into v_bet_id;

  update public.league_members
  set balance = balance - p_stake
  where league_id = p_league_id
    and user_id = v_user_id;

  return v_bet_id;
end;
$function$;


-- =========================================================
-- 3. SECURITY
-- =========================================================

revoke all
on function public.place_bet(numeric, text, jsonb)
from public, anon;

grant execute
on function public.place_bet(numeric, text, jsonb)
to authenticated;

revoke all
on function public.place_league_bet(uuid, numeric, jsonb)
from public, anon;

grant execute
on function public.place_league_bet(uuid, numeric, jsonb)
to authenticated;