-- CravaAí Backend V2
-- Migration 02: sistema seguro de apostas normais

begin;

-- =========================================================
-- 1. Remover a função antiga e insegura
-- =========================================================

drop function if exists public.place_bet(
  uuid,
  bigint,
  numeric,
  text,
  jsonb
);


-- =========================================================
-- 2. Criar a nova função segura
-- =========================================================

create or replace function public.place_bet(
  p_stake bigint,
  p_bet_type text,
  p_items jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
  v_balance bigint;
  v_bet_id uuid;

  v_item jsonb;
  v_match_id uuid;
  v_market text;
  v_selection text;

  v_odd numeric;
  v_total_odds numeric := 1;
  v_item_count integer;
begin

  -- -------------------------------------------------------
  -- Usuário vem da sessão autenticada.
  -- O navegador NÃO informa mais user_id.
  -- -------------------------------------------------------

  v_user_id := auth.uid();

  if v_user_id is null then
    raise exception 'Usuário não autenticado';
  end if;


  -- -------------------------------------------------------
  -- Validar stake
  -- -------------------------------------------------------

  if p_stake is null or p_stake <= 0 then
    raise exception 'Stake inválida';
  end if;


  -- -------------------------------------------------------
  -- Validar itens
  -- -------------------------------------------------------

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


  -- -------------------------------------------------------
  -- Validar tipo da aposta
  -- -------------------------------------------------------

  p_bet_type := lower(trim(p_bet_type));

  if p_bet_type not in ('single', 'multiple') then
    raise exception 'Tipo de aposta inválido';
  end if;

  if p_bet_type = 'single' and v_item_count <> 1 then
    raise exception 'Aposta simples deve possuir exatamente uma seleção';
  end if;

  if p_bet_type = 'multiple' and v_item_count < 2 then
    raise exception 'Aposta múltipla precisa possuir pelo menos duas seleções';
  end if;


  -- -------------------------------------------------------
  -- Travar carteira do usuário
  -- Isso evita duas apostas simultâneas gastarem o mesmo CP.
  -- -------------------------------------------------------

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


  -- -------------------------------------------------------
  -- Validar cada seleção e buscar a odd REAL no banco
  -- -------------------------------------------------------

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


    -- Busca a odd diretamente em public.odds.
    -- Exemplo outcomes:
    -- {"1": 1.88, "X": 3.4, "2": 4.2}

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


    -- Total é calculado pelo servidor.

    v_total_odds := v_total_odds * v_odd;

  end loop;


  v_total_odds := round(v_total_odds, 4);


  -- -------------------------------------------------------
  -- Criar aposta
  -- -------------------------------------------------------

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


  -- -------------------------------------------------------
  -- Criar os itens usando novamente as odds do banco
  -- -------------------------------------------------------

  for v_item in
    select value
    from jsonb_array_elements(p_items)
  loop

    v_match_id := (v_item ->> 'match_id')::uuid;
    v_market := lower(trim(v_item ->> 'market'));
    v_selection := trim(v_item ->> 'selection');

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


  -- -------------------------------------------------------
  -- Debitar CP NORMAL
  -- -------------------------------------------------------

  update public.wallets
  set balance_cp = balance_cp - p_stake
  where user_id = v_user_id;


  -- -------------------------------------------------------
  -- Registrar no histórico financeiro
  -- -------------------------------------------------------

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
$$;


-- =========================================================
-- 3. Permissões
-- =========================================================

revoke all on function public.place_bet(bigint, text, jsonb)
from public;

revoke all on function public.place_bet(bigint, text, jsonb)
from anon;

grant execute on function public.place_bet(bigint, text, jsonb)
to authenticated;


commit;