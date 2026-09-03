-- =========================================================
-- CravaAi - Automatic Normal Bet Settlement
-- Liquidação automática e segura das apostas normais
-- =========================================================


-- =========================================================
-- 1. REMOVER SETTLEMENT ANTIGO
-- =========================================================

drop function if exists public.settle_bet(uuid, text);


-- =========================================================
-- 2. NOVO SETTLEMENT AUTOMÁTICO
-- =========================================================

create or replace function public.settle_bet(
  p_bet_id uuid
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $function$

declare

  v_bet public.bets%rowtype;
  v_item record;
  v_match public.matches%rowtype;

  v_item_result public.bet_item_result;

  v_has_lost boolean := false;
  v_has_valid_selection boolean := false;

  v_effective_odds numeric := 1;

  v_payout numeric(14,2) := 0;
  v_balance numeric(14,2);
  v_new_balance numeric(14,2);

begin

  -- =======================================================
  -- TRAVAR E VALIDAR A APOSTA
  -- =======================================================

  select *
  into v_bet
  from public.bets
  where id = p_bet_id
  for update;

  if not found then
    raise exception 'Aposta não encontrada';
  end if;

  if v_bet.status <> 'OPEN' then
    raise exception
      'Aposta já foi liquidada com status %',
      v_bet.status;
  end if;


  -- =======================================================
  -- PRECISA EXISTIR PELO MENOS UM ITEM
  -- =======================================================

  if not exists (
    select 1
    from public.bet_items
    where bet_id = p_bet_id
  ) then
    raise exception 'Aposta não possui seleções';
  end if;


  -- =======================================================
  -- PROCESSAR CADA SELEÇÃO
  -- =======================================================

  for v_item in
    select *
    from public.bet_items
    where bet_id = p_bet_id
    order by id
  loop

    -- Atualmente o settlement automático suporta 1x2.
    if lower(v_item.market) <> '1x2' then
      raise exception
        'Mercado ainda não suportado para liquidação automática: %',
        v_item.market;
    end if;


    if v_item.selection not in ('1', 'X', '2') then
      raise exception
        'Seleção 1x2 inválida: %',
        v_item.selection;
    end if;


    -- Travar partida durante a leitura do resultado.
    select *
    into v_match
    from public.matches
    where id = v_item.match_id
    for share;

    if not found then
      raise exception
        'Partida da seleção não encontrada: %',
        v_item.match_id;
    end if;


    -- =====================================================
    -- CANCELADA / ABANDONADA = VOID
    -- =====================================================

    if v_match.status in ('CAN', 'ABD') then

      v_item_result := 'VOID';

      update public.bet_items
      set
        result = v_item_result,
        settled_at = now()
      where id = v_item.id;

      -- VOID equivale a odd 1.00.
      -- Portanto não multiplica v_effective_odds.
      continue;

    end if;


    -- =====================================================
    -- SOMENTE FT É LIQUIDADO AUTOMATICAMENTE
    -- =====================================================

    if v_match.status <> 'FT' then

      if v_match.status = 'PST' then
        raise exception
          'Partida adiada; aposta ainda não pode ser liquidada';

      elsif v_match.status in ('AET', 'PEN') then
        raise exception
          'Partida terminou após prorrogação/pênaltis; resultado de 90 minutos necessário';

      else
        raise exception
          'Partida ainda não está pronta para liquidação. Status: %',
          v_match.status;
      end if;

    end if;


    -- =====================================================
    -- FT PRECISA POSSUIR PLACAR
    -- =====================================================

    if v_match.home_score is null
       or v_match.away_score is null then
      raise exception 'Placar final da partida não disponível';
    end if;


    -- =====================================================
    -- DESCOBRIR RESULTADO 1X2
    -- =====================================================

    if v_match.home_score > v_match.away_score then

      if v_item.selection = '1' then
        v_item_result := 'WON';
      else
        v_item_result := 'LOST';
      end if;

    elsif v_match.home_score < v_match.away_score then

      if v_item.selection = '2' then
        v_item_result := 'WON';
      else
        v_item_result := 'LOST';
      end if;

    else

      if v_item.selection = 'X' then
        v_item_result := 'WON';
      else
        v_item_result := 'LOST';
      end if;

    end if;


    -- =====================================================
    -- SALVAR RESULTADO DO ITEM
    -- =====================================================

    update public.bet_items
    set
      result = v_item_result,
      settled_at = now()
    where id = v_item.id;


    -- =====================================================
    -- CALCULAR RESULTADO DO BILHETE
    -- =====================================================

    if v_item_result = 'LOST' then

      v_has_lost := true;

    elsif v_item_result = 'WON' then

      v_has_valid_selection := true;

      v_effective_odds :=
        v_effective_odds * v_item.odd;

    end if;

  end loop;


  -- =======================================================
  -- DEFINIR RESULTADO FINAL
  -- =======================================================

  if v_has_lost then

    -- Qualquer seleção perdida perde o bilhete inteiro.
    v_payout := 0.00;

    update public.bets
    set
      status = 'LOST',
      payout = v_payout,
      settled_at = now()
    where id = p_bet_id;


  elsif not v_has_valid_selection then

    -- Todas as seleções foram VOID.
    -- Devolve exatamente a stake.
    v_payout := round(v_bet.stake, 2);

    select balance_cp
    into v_balance
    from public.wallets
    where user_id = v_bet.user_id
    for update;

    if not found then
      raise exception 'Carteira do usuário não encontrada';
    end if;

    v_new_balance :=
      round(v_balance + v_payout, 2);

    update public.wallets
    set balance_cp = v_new_balance
    where user_id = v_bet.user_id;

    insert into public.transactions (
      user_id,
      type,
      amount,
      balance_after,
      reference_id,
      description
    )
    values (
      v_bet.user_id,
      'refund',
      v_payout,
      v_new_balance,
      p_bet_id,
      'Aposta anulada — estorno'
    );

    update public.bets
    set
      status = 'VOID',
      payout = v_payout,
      settled_at = now()
    where id = p_bet_id;


  else

    -- Todas as seleções válidas venceram.
    -- Seleções VOID equivalem a odd 1.00.
    v_effective_odds :=
      round(v_effective_odds, 4);

    v_payout :=
      round(v_bet.stake * v_effective_odds, 2);

    select balance_cp
    into v_balance
    from public.wallets
    where user_id = v_bet.user_id
    for update;

    if not found then
      raise exception 'Carteira do usuário não encontrada';
    end if;

    v_new_balance :=
      round(v_balance + v_payout, 2);

    update public.wallets
    set balance_cp = v_new_balance
    where user_id = v_bet.user_id;

    insert into public.transactions (
      user_id,
      type,
      amount,
      balance_after,
      reference_id,
      description
    )
    values (
      v_bet.user_id,
      'win',
      v_payout,
      v_new_balance,
      p_bet_id,
      'Aposta ganha'
    );

    update public.bets
    set
      status = 'WON',
      payout = v_payout,
      settled_at = now()
    where id = p_bet_id;

  end if;

end;

$function$;


-- =========================================================
-- 3. PERMISSÕES
-- =========================================================

revoke all
on function public.settle_bet(uuid)
from public;

revoke all
on function public.settle_bet(uuid)
from anon;

revoke all
on function public.settle_bet(uuid)
from authenticated;

grant execute
on function public.settle_bet(uuid)
to service_role;