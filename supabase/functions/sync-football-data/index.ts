import { createClient } from "npm:@supabase/supabase-js@2";

const supabaseUrl = Deno.env.get("PROJECT_URL");
const serviceRoleKey = Deno.env.get("SERVICE_ROLE_KEY");
const apiFootballKey = Deno.env.get("API_FOOTBALL_KEY");

if (!supabaseUrl) {
  throw new Error("PROJECT_URL não definida no ambiente");
}

if (!serviceRoleKey) {
  throw new Error("SERVICE_ROLE_KEY não definida no ambiente");
}

if (!apiFootballKey) {
  throw new Error("API_FOOTBALL_KEY não definida no ambiente");
}

/*
 * Cliente administrativo.
 *
 * A SERVICE_ROLE_KEY nunca é enviada ao navegador.
 * Ela existe somente dentro desta Edge Function.
 */
const sb = createClient(supabaseUrl, serviceRoleKey, {
  auth: {
    persistSession: false,
    autoRefreshToken: false,
  },
});

const API_BASE = "https://v3.football.api-sports.io";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};

/*
 * Competições oficiais que o CravaAí importa.
 */
const LEAGUES: Record<
  string,
  {
    league: number;
    name: string;
  }
> = {
  "br-seriea": {
    league: 71,
    name: "Brasileirão Série A",
  },

  "eng-pl": {
    league: 39,
    name: "Premier League",
  },

  "esp-ll": {
    league: 140,
    name: "LaLiga",
  },

  "ita-sa": {
    league: 135,
    name: "Serie A",
  },

  "ger-bl": {
    league: 78,
    name: "Bundesliga",
  },

  "fra-l1": {
    league: 61,
    name: "Ligue 1",
  },
};

/*
 * Converte os status da API-Football
 * para o enum utilizado pelo CravaAí.
 */
function mapFixtureStatus(
  short: string
):
  | "NS"
  | "LIVE"
  | "HT"
  | "FT"
  | "AET"
  | "PEN"
  | "PST"
  | "CAN"
  | "ABD" {
  if (["NS", "TBD"].includes(short)) {
    return "NS";
  }

  if (
    ["1H", "2H", "ET", "BT", "INT", "LIVE"].includes(short)
  ) {
    return "LIVE";
  }

  if (short === "HT") {
    return "HT";
  }

  if (short === "FT") {
    return "FT";
  }

  if (short === "AET") {
    return "AET";
  }

  if (short === "PEN") {
    return "PEN";
  }

  if (short === "PST") {
    return "PST";
  }

  if (short === "CANC") {
    return "CAN";
  }

  if (["ABD", "AWD", "WO"].includes(short)) {
    return "ABD";
  }

  return "NS";
}

/*
 * Faz chamadas para a API-Football.
 */
async function apiFetch(path: string) {
  const res = await fetch(`${API_BASE}${path}`, {
    headers: {
      "x-apisports-key": apiFootballKey!,
    },
  });

  if (!res.ok) {
    const text = await res.text();

    throw new Error(
      `API-Football error ${res.status}: ${text}`,
    );
  }

  return await res.json();
}

/*
 * Descobre a temporada atual de uma competição
 * e se a API informa cobertura de odds.
 */
async function getLeagueMeta(leagueId: number) {
  const json = await apiFetch(
    `/leagues?id=${leagueId}&current=true`,
  );

  const row = json.response?.[0];

  if (!row) {
    return {
      season: null as number | null,
      hasOdds: false,
    };
  }

  const currentSeason = row.seasons?.find(
    (season: any) => season.current === true,
  );

  return {
    season: currentSeason?.year ?? null,
    hasOdds: Boolean(currentSeason?.coverage?.odds),
  };
}

/*
 * Normaliza os mercados da API-Football
 * para o padrão interno do CravaAí.
 */
function normalizeOutcomeMap(
  marketName: string,
  values: any[],
) {
  const out: Record<string, number> = {};

  /*
   * Vencedor da partida - 1X2
   */
  if (marketName === "Match Winner") {
    for (const value of values) {
      if (value.value === "Home") {
        out["1"] = Number(value.odd);
      }

      if (value.value === "Draw") {
        out["X"] = Number(value.odd);
      }

      if (value.value === "Away") {
        out["2"] = Number(value.odd);
      }
    }

    return {
      market: "1x2",
      outcomes: out,
    };
  }

  /*
   * Dupla chance
   */
  if (marketName === "Double Chance") {
    for (const value of values) {
      if (
        ["Home/Draw", "1X"].includes(value.value)
      ) {
        out["1X"] = Number(value.odd);
      }

      if (
        ["Home/Away", "12"].includes(value.value)
      ) {
        out["12"] = Number(value.odd);
      }

      if (
        ["Draw/Away", "X2"].includes(value.value)
      ) {
        out["X2"] = Number(value.odd);
      }
    }

    return {
      market: "double_chance",
      outcomes: out,
    };
  }

  /*
   * Ambas marcam
   */
  if (marketName === "Both Teams Score") {
    for (const value of values) {
      if (value.value === "Yes") {
        out["yes"] = Number(value.odd);
      }

      if (value.value === "No") {
        out["no"] = Number(value.odd);
      }
    }

    return {
      market: "btts",
      outcomes: out,
    };
  }

  /*
   * Mais/Menos 2.5 gols
   */
  if (
    marketName === "Goals Over/Under" ||
    marketName === "Over/Under"
  ) {
    let has25 = false;

    for (const value of values) {
      const label = String(value.value || "");

      if (label.includes("Over 2.5")) {
        out["over"] = Number(value.odd);
        has25 = true;
      }

      if (label.includes("Under 2.5")) {
        out["under"] = Number(value.odd);
        has25 = true;
      }
    }

    if (has25) {
      return {
        market: "over_under_25",
        outcomes: out,
      };
    }
  }

  return null;
}

function formatDateUTC(date: Date) {
  return date.toISOString().slice(0, 10);
}

/*
 * Confirma:
 *
 * 1. existência do Bearer Token;
 * 2. validade do usuário;
 * 3. profiles.is_admin = true.
 */
async function requireAdmin(req: Request) {
  const authorization =
    req.headers.get("Authorization");

  if (
    !authorization ||
    !authorization.startsWith("Bearer ")
  ) {
    return {
      ok: false as const,
      status: 401,
      message: "Token de autenticação ausente",
    };
  }

  const token = authorization
    .replace("Bearer ", "")
    .trim();

  if (!token) {
    return {
      ok: false as const,
      status: 401,
      message: "Token de autenticação inválido",
    };
  }

  /*
   * Valida o JWT diretamente com o Supabase Auth.
   *
   * Não confiamos simplesmente no ID enviado
   * pelo navegador.
   */
  const {
    data: userData,
    error: userError,
  } = await sb.auth.getUser(token);

  if (userError || !userData.user) {
    return {
      ok: false as const,
      status: 401,
      message: "Usuário não autenticado",
    };
  }

  /*
   * Consulta o perfil pelo ID obtido do JWT.
   */
  const {
    data: profile,
    error: profileError,
  } = await sb
    .from("profiles")
    .select("is_admin")
    .eq("id", userData.user.id)
    .maybeSingle();

  if (profileError) {
    console.error(
      "[admin-check]",
      profileError.message,
    );

    return {
      ok: false as const,
      status: 500,
      message:
        "Erro ao validar permissão administrativa",
    };
  }

  if (!profile?.is_admin) {
    return {
      ok: false as const,
      status: 403,
      message:
        "Apenas administradores podem executar a sincronização",
    };
  }

  return {
    ok: true as const,
    userId: userData.user.id,
  };
}

Deno.serve(async (req: Request) => {
  /*
   * Preflight do navegador.
   */
  if (req.method === "OPTIONS") {
    return new Response(null, {
      status: 204,
      headers: CORS_HEADERS,
    });
  }

  /*
   * Sync só pode ser executado via POST.
   */
  if (req.method !== "POST") {
    return new Response(
      JSON.stringify({
        ok: false,
        error: "Método não permitido",
      }),
      {
        status: 405,
        headers: CORS_HEADERS,
      },
    );
  }

  try {
    /*
     * Segurança:
     * valida o usuário antes de sequer consultar
     * a API-Football.
     */
    const admin = await requireAdmin(req);

    if (!admin.ok) {
      return new Response(
        JSON.stringify({
          ok: false,
          error: admin.message,
        }),
        {
          status: admin.status,
          headers: CORS_HEADERS,
        },
      );
    }

    console.log(
      `[sync] iniciado por admin ${admin.userId}`,
    );

    const allMatches: any[] = [];
    const oddsRows: any[] = [];
    const debug: any[] = [];

    const now = new Date();

    const from = new Date(now);
    const to = new Date(now);

    /*
     * Importa jogos dos próximos 10 dias.
     */
    to.setDate(to.getDate() + 10);

    const fromDate = formatDateUTC(from);
    const toDate = formatDateUTC(to);

    const leagueRuntimeData: Record<
      string,
      {
        league: number;
        name: string;
        season: number | null;
        hasOdds: boolean;
      }
    > = {};

    /*
     * Descobrir temporada atual de cada competição.
     */
    for (
      const [leagueKey, cfg]
      of Object.entries(LEAGUES)
    ) {
      const meta = await getLeagueMeta(
        cfg.league,
      );

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

    /*
     * Importar partidas.
     */
    for (
      const [leagueKey, cfg]
      of Object.entries(leagueRuntimeData)
    ) {
      if (!cfg.season) {
        continue;
      }

      const fixturesJson = await apiFetch(
        `/fixtures?league=${cfg.league}&season=${cfg.season}&from=${fromDate}&to=${toDate}`,
      );

      const fixtureCount =
        (fixturesJson.response || []).length;

      console.log(
        `[fixtures] ${leagueKey} season=${cfg.season} from=${fromDate} to=${toDate} count=${fixtureCount}`,
      );

      debug.push({
        type: "fixtures",
        leagueKey,
        season: cfg.season,
        fromDate,
        toDate,
        count: fixtureCount,
      });

      for (
        const item of fixturesJson.response || []
      ) {
        const fixtureId =
          String(item.fixture.id);

        allMatches.push({
          external_id: fixtureId,
          league_key: leagueKey,
          league_name: cfg.name,
          home_team: item.teams.home.name,
          away_team: item.teams.away.name,
          home_score: item.goals.home,
          away_score: item.goals.away,
          status: mapFixtureStatus(
            item.fixture.status.short,
          ),
          start_time: item.fixture.date,
          venue:
            item.fixture.venue?.name || null,
        });
      }
    }

    /*
     * Salvar/atualizar partidas.
     */
    if (allMatches.length > 0) {
      const { error } = await sb
        .from("matches")
        .upsert(allMatches, {
          onConflict: "external_id",
        });

      if (error) {
        throw error;
      }
    }

    /*
     * Buscar IDs internos das partidas.
     */
    const externalIds = allMatches.map(
      (match) => match.external_id,
    );

    let savedMatches: any[] = [];

    if (externalIds.length > 0) {
      const {
        data,
        error: savedMatchesError,
      } = await sb
        .from("matches")
        .select("id, external_id, start_time")
        .in("external_id", externalIds);

      if (savedMatchesError) {
        throw savedMatchesError;
      }

      savedMatches = data || [];
    }

    const byExternalId = new Map(
      savedMatches.map((match) => [
        String(match.external_id),
        match.id,
      ]),
    );

    /*
     * Importar odds.
     */
    for (
      const [leagueKey, cfg]
      of Object.entries(leagueRuntimeData)
    ) {
      if (!cfg.season || !cfg.hasOdds) {
        continue;
      }

      const leagueMatches = allMatches.filter(
        (match) =>
          match.league_key === leagueKey,
      );

      for (const match of leagueMatches) {
        const oddsJson = await apiFetch(
          `/odds?fixture=${match.external_id}`,
        );

        const oddsCount =
          (oddsJson.response || []).length;

        console.log(
          `[odds] ${leagueKey} fixture=${match.external_id} count=${oddsCount}`,
        );

        debug.push({
          type: "odds",
          leagueKey,
          fixture: match.external_id,
          count: oddsCount,
        });

        for (
          const item of oddsJson.response || []
        ) {
          const fixtureId = String(
            item.fixture?.id || "",
          );

          const matchId =
            byExternalId.get(fixtureId);

          if (!matchId) {
            continue;
          }

          /*
           * Atualmente usamos somente o primeiro bookmaker
           * disponível para cada partida.
           */
          for (
            const bookmaker
            of item.bookmakers || []
          ) {
            for (
              const bet
              of bookmaker.bets || []
            ) {
              const normalized =
                normalizeOutcomeMap(
                  bet.name,
                  bet.values || [],
                );

              if (!normalized) {
                continue;
              }

              /*
               * Ignora mercado vazio ou com odds inválidas.
               */
              const validOutcomes =
                Object.fromEntries(
                  Object.entries(
                    normalized.outcomes,
                  ).filter(
                    ([, odd]) =>
                      Number.isFinite(odd) &&
                      odd > 1,
                  ),
                );

              if (
                Object.keys(validOutcomes)
                  .length === 0
              ) {
                continue;
              }

              oddsRows.push({
                match_id: matchId,
                market:
                  normalized.market,
                outcomes:
                  validOutcomes,
                source: "api-football",
              });
            }

            /*
             * Para depois do primeiro bookmaker.
             */
            break;
          }
        }
      }
    }

    /*
     * Remove mercados duplicados.
     *
     * A chave oficial da tabela odds é:
     * match_id + market
     */
    const dedup = new Map<string, any>();

    for (const row of oddsRows) {
      dedup.set(
        `${row.match_id}:${row.market}`,
        row,
      );
    }

    const finalOddsRows = [
      ...dedup.values(),
    ];

    /*
     * Salvar/atualizar odds.
     */
    if (finalOddsRows.length > 0) {
      const { error } = await sb
        .from("odds")
        .upsert(finalOddsRows, {
          onConflict: "match_id,market",
        });

      if (error) {
        throw error;
      }
    }

    console.log(
      `[sync] concluído matches=${allMatches.length} odds=${finalOddsRows.length}`,
    );

    return new Response(
      JSON.stringify({
        ok: true,
        matches_upserted:
          allMatches.length,
        odds_upserted:
          finalOddsRows.length,
        debug,
      }),
      {
        status: 200,
        headers: CORS_HEADERS,
      },
    );
  } catch (err) {
    console.error("[sync-error]", err);

    return new Response(
      JSON.stringify({
        ok: false,
        error:
          err instanceof Error
            ? err.message
            : String(err),
      }),
      {
        status: 500,
        headers: CORS_HEADERS,
      },
    );
  }
});