-- Migration 20
-- Expande a liquidação automática para mercados baseados apenas no placar final:
-- 1x2, dupla chance, ambas marcam e over/under 2.5.
--
-- Mantém CP normal e CP de liga completamente separados.

-- =========================================================
-- 1. NORMAL BET SETTLEMENT
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
  v_market text;
  v_selection text;
  v_total_goals integer;
  v_has_lost boolean := false;
  v_has_valid_selection boolean := false;
  v_effective_odds numeric := 1;
  v_payout numeric(14,2) := 0;
  v_balance numeric(14,2);
  v_new_balance numeric(14,2);
begin
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

  if not exists (
    select 1
    from public.bet_items
    where bet_id = p_bet_id
  ) then
    raise exception 'Aposta não possui seleções';
  end if;

  for v_item in
    select *
    from public.bet_items
    where bet_id = p_bet_id
    order by id
  loop
    v_market := lower(trim(v_item.market));
    v_selection := trim(v_item.selection);

    if v_market not in (
      '1x2',
      'double_chance',
      'btts',
      'over_under_25'
    ) then
      raise exception
        'Mercado ainda não suportado para liquidação automática: %',
        v_item.market;
    end if;

    if v_market = '1x2'
       and v_selection not in ('1', 'X', '2') then
      raise exception 'Seleção 1x2 inválida: %', v_selection;
    end if;

    if v_market = 'double_chance'
       and v_selection not in ('1X', '12', 'X2') then
      raise exception
        'Seleção dupla chance inválida: %',
        v_selection;
    end if;

    if v_market = 'btts'
       and lower(v_selection) not in ('yes', 'no') then
      raise exception
        'Seleção ambas marcam inválida: %',
        v_selection;
    end if;

    if v_market = 'over_under_25'
       and lower(v_selection) not in ('over', 'under') then
      raise exception
        'Seleção over/under 2.5 inválida: %',
        v_selection;
    end if;

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

    if v_match.status in ('CAN', 'ABD') then
      v_item_result := 'VOID';

      update public.bet_items
      set
        result = v_item_result,
        settled_at = now()
      where id = v_item.id;

      continue;
    end if;

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

    if v_match.home_score is null
       or v_match.away_score is null then
      raise exception 'Placar final da partida não disponível';
    end if;

    v_total_goals :=
      v_match.home_score + v_match.away_score;

    if v_market = '1x2' then
      if v_match.home_score > v_match.away_score then
        v_item_result :=
          case when v_selection = '1' then 'WON' else 'LOST' end;
      elsif v_match.home_score < v_match.away_score then
        v_item_result :=
          case when v_selection = '2' then 'WON' else 'LOST' end;
      else
        v_item_result :=
          case when v_selection = 'X' then 'WON' else 'LOST' end;
      end if;

    elsif v_market = 'double_chance' then
      if v_selection = '1X' then
        v_item_result :=
          case
            when v_match.home_score >= v_match.away_score
            then 'WON'
            else 'LOST'
          end;

      elsif v_selection = '12' then
        v_item_result :=
          case
            when v_match.home_score <> v_match.away_score
            then 'WON'
            else 'LOST'
          end;

      else
        v_item_result :=
          case
            when v_match.home_score <= v_match.away_score
            then 'WON'
            else 'LOST'
          end;
      end if;

    elsif v_market = 'btts' then
      if lower(v_selection) = 'yes' then
        v_item_result :=
          case
            when v_match.home_score > 0
             and v_match.away_score > 0
            then 'WON'
            else 'LOST'
          end;
      else
        v_item_result :=
          case
            when v_match.home_score = 0
              or v_match.away_score = 0
            then 'WON'
            else 'LOST'
          end;
      end if;

    else
      if lower(v_selection) = 'over' then
        v_item_result :=
          case
            when v_total_goals > 2
            then 'WON'
            else 'LOST'
          end;
      else
        v_item_result :=
          case
            when v_total_goals < 3
            then 'WON'
            else 'LOST'
          end;
      end if;
    end if;

    update public.bet_items
    set
      result = v_item_result,
      settled_at = now()
    where id = v_item.id;

    if v_item_result = 'LOST' then
      v_has_lost := true;
    elsif v_item_result = 'WON' then
      v_has_valid_selection := true;
      v_effective_odds :=
        v_effective_odds * v_item.odd;
    end if;
  end loop;

  if v_has_lost then
    v_payout := 0.00;

    update public.bets
    set
      status = 'LOST',
      payout = v_payout,
      settled_at = now()
    where id = p_bet_id;

  elsif not v_has_valid_selection then
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
-- 2. LEAGUE BET SETTLEMENT
-- =========================================================

create or replace function public.settle_league_bet(
  p_bet_id uuid
)
returns table (
  bet_id uuid,
  final_status text,
  payout numeric,
  profit numeric
)
language plpgsql
security definer
set search_path = pg_catalog, public
as $function$
declare
  v_bet public.league_bets%rowtype;
  v_item jsonb;
  v_match public.matches%rowtype;
  v_match_id uuid;
  v_market text;
  v_selection text;
  v_odd numeric;
  v_total_goals integer;
  v_has_lost boolean := false;
  v_has_valid_selection boolean := false;
  v_total_odds numeric := 1;
  v_final_status text;
  v_payout numeric := 0;
  v_profit numeric := 0;
  v_items_count integer;
begin
  select *
  into v_bet
  from public.league_bets
  where id = p_bet_id
  for update;

  if not found then
    raise exception 'League bet not found';
  end if;

  if v_bet.status <> 'OPEN' then
    raise exception
      'League bet has already been settled with status %',
      v_bet.status;
  end if;

  if v_bet.selections is null
     or jsonb_typeof(v_bet.selections) <> 'array' then
    raise exception 'League bet has invalid selections';
  end if;

  v_items_count := jsonb_array_length(v_bet.selections);

  if v_items_count < 1 then
    raise exception 'League bet has no selections';
  end if;

  for v_item in
    select value
    from jsonb_array_elements(v_bet.selections)
  loop
    begin
      v_match_id := (v_item ->> 'match_id')::uuid;
      v_odd := (v_item ->> 'odd')::numeric;
    exception
      when others then
        raise exception 'Invalid selection data in league bet';
    end;

    v_market := lower(trim(v_item ->> 'market'));
    v_selection := trim(v_item ->> 'selection');

    if v_match_id is null
       or v_market is null
       or v_market = ''
       or v_selection is null
       or v_selection = ''
       or v_odd is null
       or v_odd <= 1 then
      raise exception 'Incomplete or invalid selection data';
    end if;

    if v_market not in (
      '1x2',
      'double_chance',
      'btts',
      'over_under_25'
    ) then
      raise exception
        'Unsupported market for automatic settlement: %',
        v_market;
    end if;

    if v_market = '1x2'
       and v_selection not in ('1', 'X', '2') then
      raise exception 'Invalid 1x2 selection: %', v_selection;
    end if;

    if v_market = 'double_chance'
       and v_selection not in ('1X', '12', 'X2') then
      raise exception
        'Invalid double chance selection: %',
        v_selection;
    end if;

    if v_market = 'btts'
       and lower(v_selection) not in ('yes', 'no') then
      raise exception
        'Invalid BTTS selection: %',
        v_selection;
    end if;

    if v_market = 'over_under_25'
       and lower(v_selection) not in ('over', 'under') then
      raise exception
        'Invalid over/under 2.5 selection: %',
        v_selection;
    end if;

    select *
    into v_match
    from public.matches
    where id = v_match_id;

    if not found then
      raise exception 'Match % not found', v_match_id;
    end if;

    if v_match.status in ('CAN', 'ABD') then
      continue;
    end if;

    if v_match.status in (
      'NS',
      'LIVE',
      'HT',
      'PST',
      'AET',
      'PEN'
    ) then
      raise exception
        'Match % is not ready for automatic settlement. Status: %',
        v_match_id,
        v_match.status;
    end if;

    if v_match.status <> 'FT' then
      raise exception
        'Unsupported match status for settlement: %',
        v_match.status;
    end if;

    if v_match.home_score is null
       or v_match.away_score is null then
      raise exception
        'Match % has no final score',
        v_match_id;
    end if;

    v_has_valid_selection := true;

    v_total_goals :=
      v_match.home_score + v_match.away_score;

    if v_market = '1x2' then
      if v_match.home_score > v_match.away_score then
        if v_selection <> '1' then
          v_has_lost := true;
        end if;
      elsif v_match.home_score < v_match.away_score then
        if v_selection <> '2' then
          v_has_lost := true;
        end if;
      else
        if v_selection <> 'X' then
          v_has_lost := true;
        end if;
      end if;

    elsif v_market = 'double_chance' then
      if v_selection = '1X'
         and v_match.home_score < v_match.away_score then
        v_has_lost := true;

      elsif v_selection = '12'
         and v_match.home_score = v_match.away_score then
        v_has_lost := true;

      elsif v_selection = 'X2'
         and v_match.home_score > v_match.away_score then
        v_has_lost := true;
      end if;

    elsif v_market = 'btts' then
      if lower(v_selection) = 'yes'
         and not (
           v_match.home_score > 0
           and v_match.away_score > 0
         ) then
        v_has_lost := true;

      elsif lower(v_selection) = 'no'
         and not (
           v_match.home_score = 0
           or v_match.away_score = 0
         ) then
        v_has_lost := true;
      end if;

    else
      if lower(v_selection) = 'over'
         and v_total_goals <= 2 then
        v_has_lost := true;

      elsif lower(v_selection) = 'under'
         and v_total_goals >= 3 then
        v_has_lost := true;
      end if;
    end if;

    v_total_odds :=
      v_total_odds * v_odd;
  end loop;

  if v_has_lost then
    v_final_status := 'LOST';
    v_payout := 0;
    v_profit := -v_bet.stake;

  elsif not v_has_valid_selection then
    v_final_status := 'VOID';
    v_total_odds := 1;
    v_payout := v_bet.stake;
    v_profit := 0;

  else
    v_final_status := 'WON';
    v_payout :=
      round(v_bet.stake * v_total_odds, 2);
    v_profit :=
      v_payout - v_bet.stake;
  end if;

  update public.league_bets
  set
    status = v_final_status,
    payout = v_payout,
    profit = v_profit,
    total_odds = v_total_odds
  where id = v_bet.id;

  if v_final_status in ('WON', 'VOID') then
    perform 1
    from public.league_members
    where league_id = v_bet.league_id
      and user_id = v_bet.user_id
    for update;

    if not found then
      raise exception
        'League member not found for settlement';
    end if;

    update public.league_members
    set balance = balance + v_payout
    where league_id = v_bet.league_id
      and user_id = v_bet.user_id;
  end if;

  return query
  select
    v_bet.id,
    v_final_status,
    v_payout,
    v_profit;
end;
$function$;


-- =========================================================
-- 3. SECURITY
-- =========================================================

revoke all
on function public.settle_bet(uuid)
from public, anon, authenticated;

grant execute
on function public.settle_bet(uuid)
to service_role;

revoke all
on function public.settle_league_bet(uuid)
from public, anon, authenticated;

grant execute
on function public.settle_league_bet(uuid)
to service_role;