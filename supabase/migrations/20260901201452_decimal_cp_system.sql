-- =========================================================
-- CravaAi - Decimal CP System
-- Padroniza o CP normal para aceitar 2 casas decimais
-- Ex.: 10 CP -> 10.00 CP
--      28.05 CP -> 28.05 CP
-- =========================================================


-- =========================================================
-- 1. CARTEIRA NORMAL
-- =========================================================

alter table public.wallets
  alter column balance_cp type numeric(14,2)
  using balance_cp::numeric(14,2);


-- =========================================================
-- 2. APOSTAS NORMAIS
-- =========================================================

alter table public.bets
  alter column stake type numeric(14,2)
  using stake::numeric(14,2);

alter table public.bets
  alter column payout type numeric(14,2)
  using payout::numeric(14,2);


-- =========================================================
-- 3. HISTÓRICO FINANCEIRO
-- =========================================================

alter table public.transactions
  alter column amount type numeric(14,2)
  using amount::numeric(14,2);

alter table public.transactions
  alter column balance_after type numeric(14,2)
  using balance_after::numeric(14,2);


-- =========================================================
-- 4. LOJA
-- =========================================================

alter table public.shop_items
  alter column price_cp type numeric(14,2)
  using price_cp::numeric(14,2);

alter table public.shop_orders
  alter column total_cp type numeric(14,2)
  using total_cp::numeric(14,2);


-- =========================================================
-- 5. PLACE_BET COM CP DECIMAL
-- =========================================================

-- Remove a assinatura antiga que recebia stake como bigint.
drop function if exists public.place_bet(bigint, text, jsonb);


create or replace function public.place_bet(
  p_stake numeric,
  p_bet_type text,
  p_items jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public
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

  -- CP normal aceita no máximo 2 casas decimais.
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
  -- VALIDAR TIPO DA APOSTA
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
  -- VALIDAR SELEÇÕES E CALCULAR ODD NO SERVIDOR
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


    -- Partida precisa existir, não ter começado
    -- e estar disponível para apostas.

    perform 1
    from public.matches m
    where m.id = v_match_id
      and m.status = 'NS'
      and m.start_time > now();

    if not found then
      raise exception 'Partida indisponível para apostas';
    end if;


    -- Busca a odd oficial diretamente do banco.
    -- Nunca confia na odd enviada pelo navegador.

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


    -- Calcula a odd total no servidor.

    v_total_odds := v_total_odds * v_odd;

  end loop;


  v_total_odds := round(v_total_odds, 4);


  -- =======================================================
  -- CRIAR APOSTA
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
  -- CRIAR ITENS DA APOSTA
  -- =======================================================

  for v_item in
    select value
    from jsonb_array_elements(p_items)
  loop

    v_match_id := (v_item ->> 'match_id')::uuid;

    v_market := lower(trim(v_item ->> 'market'));

    v_selection := trim(v_item ->> 'selection');


    -- Busca novamente a odd oficial.

    select (o.outcomes ->> v_selection)::numeric
    into v_odd
    from public.odds o
    where o.match_id = v_match_id
      and lower(o.market) = v_market;


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
      v_match_id,
      v_market,
      v_selection,
      v_odd,
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
  -- REGISTRAR TRANSAÇÃO
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
-- 6. PERMISSÕES DA FUNÇÃO
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