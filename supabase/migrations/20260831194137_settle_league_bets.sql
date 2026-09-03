-- Migration 07
-- Secure automatic settlement for league bets.
-- Initial supported market: 1x2.
-- Winnings are credited ONLY to league_members.balance.

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
as $$
declare
    v_bet public.league_bets%rowtype;

    v_item jsonb;
    v_match public.matches%rowtype;

    v_match_id uuid;
    v_market text;
    v_selection text;
    v_odd numeric;

    v_winning_selection text;

    v_has_lost boolean := false;
    v_total_odds numeric := 1;

    v_final_status text;
    v_payout numeric := 0;
    v_profit numeric := 0;

    v_items_count integer;
begin

    -- =====================================================
    -- 1. LOCK THE BET
    -- Prevents two settlement processes paying the same bet.
    -- =====================================================

    select *
    into v_bet
    from public.league_bets
    where id = p_bet_id
    for update;

    if not found then
        raise exception 'League bet not found';
    end if;


    -- =====================================================
    -- 2. IDEMPOTENCY
    -- Only OPEN bets may be settled.
    -- =====================================================

    if v_bet.status <> 'OPEN' then
        raise exception
            'League bet has already been settled with status %',
            v_bet.status;
    end if;


    -- =====================================================
    -- 3. VALIDATE BET DATA
    -- =====================================================

    if v_bet.selections is null
       or jsonb_typeof(v_bet.selections) <> 'array' then
        raise exception 'League bet has invalid selections';
    end if;

    v_items_count := jsonb_array_length(v_bet.selections);

    if v_items_count < 1 then
        raise exception 'League bet has no selections';
    end if;


    -- =====================================================
    -- 4. PROCESS EVERY SELECTION
    -- Initial settlement engine supports 1x2 only.
    -- =====================================================

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
        v_selection := upper(trim(v_item ->> 'selection'));


        if v_match_id is null
           or v_market is null
           or v_selection is null
           or v_odd is null then
            raise exception 'Incomplete selection data';
        end if;


        -- -------------------------------------------------
        -- For now, only 1x2 can be settled automatically.
        -- -------------------------------------------------

        if v_market <> '1x2' then
            raise exception
                'Unsupported market for automatic settlement: %',
                v_market;
        end if;

        if v_selection not in ('1', 'X', '2') then
            raise exception
                'Invalid 1x2 selection: %',
                v_selection;
        end if;


        -- -------------------------------------------------
        -- Load official match result.
        -- -------------------------------------------------

        select *
        into v_match
        from public.matches
        where id = v_match_id;

        if not found then
            raise exception
                'Match % not found',
                v_match_id;
        end if;


        -- -------------------------------------------------
        -- Only completed matches are accepted.
        --
        -- PEN is intentionally not settled automatically
        -- because 1x2 rules should not use penalty-shootout
        -- winner as the 90-minute result.
        -- -------------------------------------------------

        if v_match.status not in ('FT', 'AET') then
            raise exception
                'Match % is not ready for settlement. Status: %',
                v_match_id,
                v_match.status;
        end if;

        if v_match.home_score is null
           or v_match.away_score is null then
            raise exception
                'Match % has no final score',
                v_match_id;
        end if;


        -- -------------------------------------------------
        -- Determine winning 1x2 selection.
        -- -------------------------------------------------

        if v_match.home_score > v_match.away_score then
            v_winning_selection := '1';

        elsif v_match.home_score < v_match.away_score then
            v_winning_selection := '2';

        else
            v_winning_selection := 'X';

        end if;


        -- -------------------------------------------------
        -- If one leg loses, the entire ticket loses.
        -- -------------------------------------------------

        if v_selection <> v_winning_selection then
            v_has_lost := true;
        end if;


        -- Recalculate total odds from the sanitized odds
        -- stored by place_league_bet().
        v_total_odds := v_total_odds * v_odd;

    end loop;


    -- =====================================================
    -- 5. CALCULATE FINAL RESULT
    -- =====================================================

    if v_has_lost then

        v_final_status := 'LOST';
        v_payout := 0;
        v_profit := -v_bet.stake;

    else

        v_final_status := 'WON';

        v_payout := round(
            v_bet.stake * v_total_odds,
            2
        );

        v_profit := v_payout - v_bet.stake;

    end if;


    -- =====================================================
    -- 6. UPDATE BET FIRST
    -- =====================================================

    update public.league_bets
    set
        status = v_final_status,
        payout = v_payout,
        profit = v_profit,
        total_odds = v_total_odds
    where id = v_bet.id;


    -- =====================================================
    -- 7. CREDIT LEAGUE CP ONLY IF WON
    -- NEVER TOUCH public.wallets
    -- =====================================================

    if v_final_status = 'WON' then

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


    -- =====================================================
    -- 8. RETURN RESULT
    -- =====================================================

    return query
    select
        v_bet.id,
        v_final_status,
        v_payout,
        v_profit;

end;
$$;


-- =========================================================
-- 9. SECURITY
--
-- Users must NEVER be able to settle their own bets.
-- Settlement will be called only by trusted backend/service.
-- =========================================================

revoke all
on function public.settle_league_bet(uuid)
from public, anon, authenticated;

grant execute
on function public.settle_league_bet(uuid)
to service_role;