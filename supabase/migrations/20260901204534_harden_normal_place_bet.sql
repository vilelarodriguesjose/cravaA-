-- =========================================================
-- CravaAi - Harden Normal Place Bet
-- Evita seleções duplicadas e elimina re-leitura de odds
-- =========================================================


-- =========================================================
-- 1. SUBSTITUIR PLACE_BET
-- =========================================================

drop function if exists public.place_bet(numeric, text, jsonb);


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

  -- Guarda exatamente as seleções já validadas
  v_sanitized_items jsonb := '[]'::jsonb;

begin

  -- =======================================================
  -- USUÁRIO
  -- =======================================================

  v_user_id := auth.uid();

  if v_user_id is null then
    raise exception 'Usuário não autenticado';
  end if;


  -- =======================================================
  -- STAKE
  -- =======================================================

  if p_stake is null or p_stake <= 0 then
    raise exception 'Stake inválida';
  end if;

  if p_stake <> round(p_stake, 2) then
    raise exception 'Stake deve possuir no máximo 2 casas decimais';
  end if;


  -- =======================================================
  -- ITENS
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
  -- TIPO
  -- =======================================================

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


  -- =======================================================
  -- TRAVAR CARTEIRA NORMAL
  -- =======================================================

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


  -- =======================================================
  -- VALIDAR E CONGELAR SELEÇÕES
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


    -- -----------------------------------------------------
    -- BLOQUEAR SELEÇÃO DUPLICADA
    -- Mesmo jogo + mercado + seleção
    -- -----------------------------------------------------

    if exists (
      select 1
      from jsonb_array_elements(v_sanitized_items) s
      where (s ->> 'match_id')::uuid = v_match_id
        and lower(s ->> 'market') = v_market
        and (s ->> 'selection') = v_selection
    ) then
      raise exception 'Seleção duplicada na aposta';
    end if;


    -- -----------------------------------------------------
    -- VALIDAR PARTIDA
    -- -----------------------------------------------------

    perform 1
    from public.matches m
    where m.id = v_match_id
      and m.status = 'NS'
      and m.start_time > now();

    if not found then
      raise exception 'Partida indisponível para apostas';
    end if;


    -- -----------------------------------------------------
    -- BUSCAR ODD OFICIAL UMA ÚNICA VEZ
    -- -----------------------------------------------------

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


    -- -----------------------------------------------------
    -- GUARDAR ITEM VALIDADO
    -- -----------------------------------------------------

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
  -- CRIAR BILHETE
  -- =======================================================

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


  -- =======================================================
  -- GRAVAR EXATAMENTE AS ODDS VALIDADAS
  -- =======================================================

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


  -- =======================================================
  -- DEBITAR CP NORMAL
  -- =======================================================

  update public.wallets
  set balance_cp = balance_cp - p_stake
  where user_id = v_user_id;


  -- =======================================================
  -- TRANSAÇÃO
  -- =======================================================

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
-- 2. PERMISSÕES
-- =========================================================

revoke all
on function public.place_bet(numeric, text, jsonb)
from public;

revoke all
on function public.place_bet(numeric, text, jsonb)
from anon;

grant execute
on function public.place_bet(numeric, text, jsonb)
to authenticated;