-- =========================================================
-- CravaAi - Harden League Place Bet
-- Evita seleções duplicadas e congela as odds validadas
-- CP da liga continua totalmente separado do CP normal
-- =========================================================


-- =========================================================
-- 1. SUBSTITUIR PLACE_LEAGUE_BET
-- =========================================================

drop function if exists public.place_league_bet(uuid, numeric, jsonb);


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

  -- Guarda somente dados já validados pelo servidor
  v_sanitized_items jsonb := '[]'::jsonb;

begin

  -- =======================================================
  -- USUÁRIO AUTENTICADO
  -- =======================================================

  v_user_id := auth.uid();

  if v_user_id is null then
    raise exception 'Usuário não autenticado';
  end if;


  -- =======================================================
  -- VALIDAR STAKE
  -- =======================================================

  if p_stake is null or p_stake <= 0 then
    raise exception 'Stake inválida';
  end if;

  -- CP aceita no máximo 2 casas decimais
  if p_stake <> round(p_stake, 2) then
    raise exception 'Stake deve possuir no máximo 2 casas decimais';
  end if;


  -- =======================================================
  -- VALIDAR ITENS
  -- =======================================================

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


  -- =======================================================
  -- TRAVAR E VALIDAR A LIGA
  -- =======================================================

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


  -- =======================================================
  -- TRAVAR SALDO DA LIGA
  -- =======================================================

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


  -- =======================================================
  -- VALIDAR E CONGELAR AS SELEÇÕES
  -- =======================================================

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

    if v_selection is null or v_selection = '' then
      raise exception 'Seleção inválida';
    end if;


    -- =====================================================
    -- BLOQUEAR SELEÇÃO DUPLICADA
    -- Mesmo jogo + mercado + seleção
    -- =====================================================

    if exists (
      select 1
      from jsonb_array_elements(v_sanitized_items) s
      where (s ->> 'match_id')::uuid = v_match_id
        and lower(s ->> 'market') = v_market
        and (s ->> 'selection') = v_selection
    ) then
      raise exception 'Seleção duplicada na aposta da liga';
    end if;


    -- =====================================================
    -- VALIDAR PARTIDA GLOBAL
    -- =====================================================

    perform 1
    from public.matches m
    where m.id = v_match_id
      and m.league_key = v_league.competition_key
      and m.status = 'NS'
      and m.start_time > now();

    if not found then
      raise exception 'Partida indisponível para esta liga';
    end if;


    -- =====================================================
    -- BUSCAR ODD OFICIAL UMA ÚNICA VEZ
    -- =====================================================

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


    -- =====================================================
    -- GUARDAR ITEM VALIDADO
    -- =====================================================

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


  -- =======================================================
  -- CRIAR BILHETE DA LIGA
  -- =======================================================

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


  -- =======================================================
  -- DEBITAR SOMENTE CP DA LIGA
  -- =======================================================

  update public.league_members
  set balance = balance - p_stake
  where league_id = p_league_id
    and user_id = v_user_id;


  -- IMPORTANTE:
  -- public.wallets NÃO é alterada aqui.
  -- CP normal e CP da liga permanecem separados.


  return v_bet_id;

end;

$function$;


-- =========================================================
-- 2. PERMISSÕES
-- =========================================================

revoke all
on function public.place_league_bet(uuid, numeric, jsonb)
from public;

revoke all
on function public.place_league_bet(uuid, numeric, jsonb)
from anon;

grant execute
on function public.place_league_bet(uuid, numeric, jsonb)
to authenticated;