import { createClient } from "npm:@supabase/supabase-js@2";

const supabaseUrl = Deno.env.get("PROJECT_URL");
const serviceRoleKey = Deno.env.get("SERVICE_ROLE_KEY");
const apiFootballKey = Deno.env.get("API_FOOTBALL_KEY");

if (!supabaseUrl) throw new Error("PROJECT_URL não definida no .env");
if (!serviceRoleKey) throw new Error("SERVICE_ROLE_KEY não definida no .env");
if (!apiFootballKey) throw new Error("API_FOOTBALL_KEY não definida no .env");

const sb = createClient(supabaseUrl, serviceRoleKey);

const API_BASE = "https://v3.football.api-sports.io";

const LEAGUES: Record<string, { league: number; name: string }> = {
  "br-seriea": { league: 71, name: "Brasileirão Série A" },
  "eng-pl": { league: 39, name: "Premier League" },
  "esp-ll": { league: 140, name: "LaLiga" },
  "ita-sa": { league: 135, name: "Serie A" },
  "ger-bl": { league: 78, name: "Bundesliga" },
  "fra-l1": { league: 61, name: "Ligue 1" },
};

function mapFixtureStatus(
  short: string
): "NS" | "LIVE" | "HT" | "FT" | "AET" | "PEN" | "PST" | "CAN" | "ABD" {
  if (["NS", "TBD"].includes(short)) return "NS";
  if (["1H", "2H", "ET", "BT", "INT", "LIVE"].includes(short)) return "LIVE";
  if (short === "HT") return "HT";
  if (short === "FT") return "FT";
  if (short === "AET") return "AET";
  if (short === "PEN") return "PEN";
  if (short === "PST") return "PST";
  if (short === "CANC") return "CAN";
  if (["ABD", "AWD", "WO"].includes(short)) return "ABD";
  return "NS";
}

async function apiFetch(path: string) {
  const res = await fetch(`${API_BASE}${path}`, {
    headers: {
      "x-apisports-key": apiFootballKey,
    },
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`API-Football error ${res.status}: ${text}`);
  }

  return await res.json();
}

async function getLeagueMeta(leagueId: number) {
  const json = await apiFetch(`/leagues?id=${leagueId}&current=true`);
  const row = json.response?.[0];

  if (!row) {
    return {
      season: null as number | null,
      hasOdds: false,
    };
  }

  const currentSeason = row.seasons?.find((s: any) => s.current === true);

  return {
    season: currentSeason?.year ?? null,
    hasOdds: Boolean(currentSeason?.coverage?.odds),
  };
}

function normalizeOutcomeMap(marketName: string, values: any[]) {
  const out: Record<string, number> = {};

  if (marketName === "Match Winner") {
    for (const v of values) {
      if (v.value === "Home") out["1"] = Number(v.odd);
      if (v.value === "Draw") out["X"] = Number(v.odd);
      if (v.value === "Away") out["2"] = Number(v.odd);
    }
    return { market: "1x2", outcomes: out };
  }

  if (marketName === "Double Chance") {
    for (const v of values) {
      if (["Home/Draw", "1X"].includes(v.value)) out["1X"] = Number(v.odd);
      if (["Home/Away", "12"].includes(v.value)) out["12"] = Number(v.odd);
      if (["Draw/Away", "X2"].includes(v.value)) out["X2"] = Number(v.odd);
    }
    return { market: "double_chance", outcomes: out };
  }

  if (marketName === "Both Teams Score") {
    for (const v of values) {
      if (v.value === "Yes") out["yes"] = Number(v.odd);
      if (v.value === "No") out["no"] = Number(v.odd);
    }
    return { market: "btts", outcomes: out };
  }

  if (marketName === "Goals Over/Under" || marketName === "Over/Under") {
    let has25 = false;

    for (const v of values) {
      const label = String(v.value || "");

      if (label.includes("Over 2.5")) {
        out["over"] = Number(v.odd);
        has25 = true;
      }

      if (label.includes("Under 2.5")) {
        out["under"] = Number(v.odd);
        has25 = true;
      }
    }

    if (has25) return { market: "over_under_25", outcomes: out };
  }

  return null;
}

function formatDateUTC(date: Date) {
  return date.toISOString().slice(0, 10);
}

Deno.serve(async () => {
  try {
    const allMatches: any[] = [];
    const oddsRows: any[] = [];
    const debug: any[] = [];

    const now = new Date();
    const from = new Date(now);
    const to = new Date(now);
    to.setDate(to.getDate() + 10);

    const fromDate = formatDateUTC(from);
    const toDate = formatDateUTC(to);

    const leagueRuntimeData: Record<
      string,
      { league: number; name: string; season: number | null; hasOdds: boolean }
    > = {};

    for (const [leagueKey, cfg] of Object.entries(LEAGUES)) {
      const meta = await getLeagueMeta(cfg.league);

      leagueRuntimeData[leagueKey] = {
        league: cfg.league,
        name: cfg.name,
        season: meta.season,
        hasOdds: meta.hasOdds,
      };

      debug.push({
        type: "league-meta",
        leagueKey,
        league: cfg.league,
        season: meta.season,
        hasOdds: meta.hasOdds,
      });
    }

    for (const [leagueKey, cfg] of Object.entries(leagueRuntimeData)) {
      if (!cfg.season) continue;

      const fixturesJson = await apiFetch(
        `/fixtures?league=${cfg.league}&season=${cfg.season}&from=${fromDate}&to=${toDate}`
      );

      const fixtureCount = (fixturesJson.response || []).length;

      console.log(
        `[fixtures] ${leagueKey} season=${cfg.season} from=${fromDate} to=${toDate} count=${fixtureCount}`
      );

      debug.push({
        type: "fixtures",
        leagueKey,
        season: cfg.season,
        fromDate,
        toDate,
        count: fixtureCount,
      });

      for (const item of fixturesJson.response || []) {
        const fixtureId = String(item.fixture.id);

        allMatches.push({
          external_id: fixtureId,
          league_key: leagueKey,
          league_name: cfg.name,
          home_team: item.teams.home.name,
          away_team: item.teams.away.name,
          home_score: item.goals.home,
          away_score: item.goals.away,
          status: mapFixtureStatus(item.fixture.status.short),
          start_time: item.fixture.date,
          venue: item.fixture.venue?.name || null,
        });
      }
    }

    if (allMatches.length > 0) {
      const { error } = await sb
        .from("matches")
        .upsert(allMatches, { onConflict: "external_id" });

      if (error) throw error;
    }

    const { data: savedMatches, error: savedMatchesError } = await sb
      .from("matches")
      .select("id, external_id, start_time");

    if (savedMatchesError) throw savedMatchesError;

    const byExternalId = new Map(
      (savedMatches || []).map((m) => [String(m.external_id), m.id])
    );

    for (const [leagueKey, cfg] of Object.entries(leagueRuntimeData)) {
      if (!cfg.season || !cfg.hasOdds) continue;

      const leagueMatches = allMatches.filter((m) => m.league_key === leagueKey);

      for (const match of leagueMatches) {
        const oddsJson = await apiFetch(`/odds?fixture=${match.external_id}`);
        const oddsCount = (oddsJson.response || []).length;

        console.log(
          `[odds] ${leagueKey} fixture=${match.external_id} count=${oddsCount}`
        );

        debug.push({
          type: "odds",
          leagueKey,
          fixture: match.external_id,
          count: oddsCount,
        });

        for (const item of oddsJson.response || []) {
          const fixtureId = String(item.fixture?.id || "");
          const matchId = byExternalId.get(fixtureId);
          if (!matchId) continue;

          for (const bookmaker of item.bookmakers || []) {
            for (const bet of bookmaker.bets || []) {
              const normalized = normalizeOutcomeMap(bet.name, bet.values || []);
              if (!normalized) continue;

              oddsRows.push({
                match_id: matchId,
                market: normalized.market,
                outcomes: normalized.outcomes,
                source: "api-football",
              });
            }
            break;
          }
        }
      }
    }

    const dedup = new Map<string, any>();
    for (const row of oddsRows) {
      dedup.set(`${row.match_id}:${row.market}`, row);
    }

    const finalOddsRows = [...dedup.values()];

    if (finalOddsRows.length > 0) {
      const { error } = await sb
        .from("odds")
        .upsert(finalOddsRows, { onConflict: "match_id,market" });

      if (error) throw error;
    }

    return new Response(
      JSON.stringify({
        ok: true,
        matches_upserted: allMatches.length,
        odds_upserted: finalOddsRows.length,
        debug,
      }),
      {
        headers: { "Content-Type": "application/json" },
      }
    );
  } catch (err) {
    return new Response(
      JSON.stringify({
        ok: false,
        error: err instanceof Error ? err.message : String(err),
      }),
      {
        status: 500,
        headers: { "Content-Type": "application/json" },
      }
    );
  }
});