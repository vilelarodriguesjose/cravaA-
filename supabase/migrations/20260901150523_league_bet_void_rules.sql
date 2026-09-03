-- Migration 08
-- League bet VOID rules and safer automatic settlement.
--
-- Rules:
-- FT  -> settle 1x2 normally
-- CAN -> selection becomes VOID
-- ABD -> selection becomes VOID
-- PST -> wait, do not settle
-- AET -> wait, because current score may include extra time
-- PEN -> wait, because current score may include penalties
--
-- In multiple bets:
-- VOID selection has effective odd 1.00.
-- If any selection loses -> entire ticket LOST.
-- If all selections are VOID -> ticket VOID and stake refunded.
-- If remaining valid selections win -> ticket WON.

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
    v_has_valid_selection boolean := false;

    v_total_odds numeric := 1;

    v_final_status text;
    v_payout numeric := 0;
    v_profit numeric := 0;

    v_items_count integer;
begin

    -- =====================================================
    -- 1. LOCK BET
    -- Prevent duplicate settlement/payment.
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
    -- =====================================================

    if v_bet.status <> 'OPEN' then
        raise exception
            'League bet has already been settled with status %',
            v_bet.status;
    end if;


    -- =====================================================
    -- 3. VALIDATE STORED SELECTIONS
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
    -- 4. PROCESS EACH SELECTION
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
           or v_market = ''
           or v_selection is null
           or v_selection = ''
           or v_odd is null
           or v_odd <= 1 then
            raise exception 'Incomplete or invalid selection data';
        end if;


        -- =================================================
        -- Initial automatic engine supports 1x2 only.
        -- =================================================

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


        -- =================================================
        -- LOAD OFFICIAL GLOBAL MATCH
        -- =================================================

        select *
        into v_match
        from public.matches
        where id = v_match_id;

        if not found then
            raise exception
                'Match % not found',
                v_match_id;
        end if;


        -- =================================================
        -- CANCELLED / ABANDONED
        --
        -- This selection becomes VOID.
        -- Effective odd = 1.00.
        -- =================================================

        if v_match.status in ('CAN', 'ABD') then
            continue;
        end if;


        -- =================================================
        -- NOT SAFE TO SETTLE YET
        -- =================================================

        if v_match.status in ('NS', 'LIVE', 'HT', 'PST', 'AET', 'PEN') then
            raise exception
                'Match % is not ready for automatic settlement. Status: %',
                v_match_id,
                v_match.status;
        end if;


        -- =================================================
        -- ONLY FT REACHES NORMAL 1X2 SETTLEMENT
        -- =================================================

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


        -- This is a real/non-void selection.
        v_has_valid_selection := true;


        -- =================================================
        -- WINNING 1X2 SELECTION
        -- =================================================

        if v_match.home_score > v_match.away_score then
            v_winning_selection := '1';

        elsif v_match.home_score < v_match.away_score then
            v_winning_selection := '2';

        else
            v_winning_selection := 'X';

        end if;


        if v_selection <> v_winning_selection then
            v_has_lost := true;
        end if;


        -- VOID selections never reach this point,
        -- therefore their effective odd remains 1.00.
        v_total_odds := v_total_odds * v_odd;

    end loop;


    -- =====================================================
    -- 5. FINAL TICKET RESULT
    -- =====================================================

    if v_has_lost then

        v_final_status := 'LOST';
        v_payout := 0;
        v_profit := -v_bet.stake;


    elsif not v_has_valid_selection then

        -- Every selection was VOID.
        v_final_status := 'VOID';
        v_total_odds := 1;
        v_payout := v_bet.stake;
        v_profit := 0;


    else

        -- All non-void selections won.
        v_final_status := 'WON';

        v_payout := round(
            v_bet.stake * v_total_odds,
            2
        );

        v_profit := v_payout - v_bet.stake;

    end if;


    -- =====================================================
    -- 6. UPDATE BET
    -- =====================================================

    update public.league_bets
    set
        status = v_final_status,
        payout = v_payout,
        profit = v_profit,
        total_odds = v_total_odds
    where id = v_bet.id;


    -- =====================================================
    -- 7. CREDIT LEAGUE WALLET
    --
    -- WON  -> payout
    -- VOID -> stake refund
    -- LOST -> nothing
    --
    -- NEVER TOUCH public.wallets.
    -- =====================================================

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
-- Only trusted backend/service can settle bets.
-- =========================================================

revoke all
on function public.settle_league_bet(uuid)
from public, anon, authenticated;

grant execute
on function public.settle_league_bet(uuid)
to service_role;