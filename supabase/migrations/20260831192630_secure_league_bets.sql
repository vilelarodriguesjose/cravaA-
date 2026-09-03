-- Migration 06
-- Secure league betting.
-- Global matches/odds are the single source of truth.
-- League bets use ONLY league_members.balance.

-- =========================================================
-- 1. REMOVE DIRECT CLIENT INSERT ACCESS TO LEAGUE BETS
-- =========================================================

drop policy if exists "users can insert own league bets"
on public.league_bets;

revoke insert, update, delete
on table public.league_bets
from anon, authenticated;

revoke all
on table public.league_bets
from anon;

grant select
on table public.league_bets
to authenticated;


-- =========================================================
-- 2. KEEP READ ACCESS LIMITED TO USER'S OWN LEAGUE BETS
-- =========================================================

drop policy if exists "users can read own league bets"
on public.league_bets;

drop policy if exists league_bets_select_own
on public.league_bets;

create policy league_bets_select_own
on public.league_bets
for select
to authenticated
using (user_id = auth.uid());


-- =========================================================
-- 3. SECURE FUNCTION FOR PLACING A LEAGUE BET
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
as $$
declare
    v_user_id uuid;
    v_league public.leagues%rowtype;
    v_member_balance numeric;

    v_item jsonb;
    v_match_id uuid;
    v_market text;
    v_selection text;
    v_odd numeric;

    v_total_odds numeric := 1;
    v_items_count integer;

    v_bet_id uuid;
    v_safe_items jsonb := '[]'::jsonb;
begin

    -- -----------------------------------------------------
    -- AUTHENTICATED USER ONLY
    -- -----------------------------------------------------

    v_user_id := auth.uid();

    if v_user_id is null then
        raise exception 'Not authenticated';
    end if;


    -- -----------------------------------------------------
    -- BASIC BET VALIDATION
    -- -----------------------------------------------------

    if p_stake is null or p_stake <= 0 then
        raise exception 'Stake must be greater than zero';
    end if;

    if p_items is null
       or jsonb_typeof(p_items) <> 'array' then
        raise exception 'Items must be a JSON array';
    end if;

    v_items_count := jsonb_array_length(p_items);

    if v_items_count < 1 or v_items_count > 20 then
        raise exception 'Bet must contain between 1 and 20 selections';
    end if;


    -- -----------------------------------------------------
    -- LOAD AND LOCK LEAGUE
    -- -----------------------------------------------------

    select *
    into v_league
    from public.leagues
    where id = p_league_id
    for update;

    if not found then
        raise exception 'League not found';
    end if;

    if v_league.status not in ('waiting', 'active') then
        raise exception 'League is not available for betting';
    end if;

    if v_league.starts_at is not null
       and now() < v_league.starts_at then
        raise exception 'League has not started yet';
    end if;

    if v_league.ends_at is not null
       and now() >= v_league.ends_at then
        raise exception 'League has already ended';
    end if;


    -- -----------------------------------------------------
    -- LOCK MEMBER BALANCE
    -- THIS IS LEAGUE CP, NEVER NORMAL CP
    -- -----------------------------------------------------

    select balance
    into v_member_balance
    from public.league_members
    where league_id = p_league_id
      and user_id = v_user_id
    for update;

    if not found then
        raise exception 'User is not a member of this league';
    end if;

    if v_member_balance < p_stake then
        raise exception 'Insufficient league balance';
    end if;


    -- -----------------------------------------------------
    -- VALIDATE EVERY SELECTION AGAINST GLOBAL MATCHES + ODDS
    -- CLIENT-SUPPLIED ODDS ARE NEVER TRUSTED
    -- -----------------------------------------------------

    for v_item in
        select value
        from jsonb_array_elements(p_items)
    loop

        begin
            v_match_id := (v_item ->> 'match_id')::uuid;
        exception
            when others then
                raise exception 'Invalid match_id';
        end;

        v_market := lower(trim(v_item ->> 'market'));
        v_selection := trim(v_item ->> 'selection');

        if v_match_id is null
           or v_market is null
           or v_market = ''
           or v_selection is null
           or v_selection = '' then
            raise exception 'Invalid bet selection';
        end if;


        -- Match must:
        -- 1. exist
        -- 2. belong to the league competition
        -- 3. not have started
        -- 4. have NS status

        if not exists (
            select 1
            from public.matches m
            where m.id = v_match_id
              and m.league_key = v_league.competition_key
              and m.status = 'NS'
              and m.start_time > now()
        ) then
            raise exception
                'Match % is not available for this league',
                v_match_id;
        end if;


        -- Get authoritative odd from GLOBAL odds table.

        select (o.outcomes ->> v_selection)::numeric
        into v_odd
        from public.odds o
        where o.match_id = v_match_id
          and lower(o.market) = v_market
        limit 1;

        if v_odd is null or v_odd <= 1 then
            raise exception
                'Odd not available for match %, market %, selection %',
                v_match_id,
                v_market,
                v_selection;
        end if;


        -- Calculate total odds on server.

        v_total_odds := v_total_odds * v_odd;


        -- Build sanitized selection.
        -- Only server-confirmed odd is stored.

        v_safe_items :=
            v_safe_items ||
            jsonb_build_array(
                jsonb_build_object(
                    'match_id', v_match_id,
                    'market', v_market,
                    'selection', v_selection,
                    'odd', v_odd
                )
            );

    end loop;


    -- -----------------------------------------------------
    -- CREATE LEAGUE BET
    -- -----------------------------------------------------

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
        0,
        0,
        v_safe_items,
        v_total_odds
    )
    returning id into v_bet_id;


    -- -----------------------------------------------------
    -- DEBIT ONLY THE USER'S BALANCE INSIDE THIS LEAGUE
    -- NEVER TOUCH public.wallets
    -- -----------------------------------------------------

    update public.league_members
    set balance = balance - p_stake
    where league_id = p_league_id
      and user_id = v_user_id;


    return v_bet_id;

end;
$$;


-- =========================================================
-- 4. FUNCTION PERMISSIONS
-- =========================================================

revoke all
on function public.place_league_bet(uuid, numeric, jsonb)
from public, anon;

grant execute
on function public.place_league_bet(uuid, numeric, jsonb)
to authenticated;


-- =========================================================
-- 5. USEFUL INDEXES
-- =========================================================

create index if not exists idx_league_bets_user_created
on public.league_bets (user_id, created_at desc);

create index if not exists idx_league_bets_league_created
on public.league_bets (league_id, created_at desc);

create index if not exists idx_league_bets_status
on public.league_bets (status);