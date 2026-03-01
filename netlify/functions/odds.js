export async function handler(event) {
  // CORS básico
  const corsHeaders = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "Content-Type",
    "Access-Control-Allow-Methods": "GET, OPTIONS",
    "Content-Type": "application/json",
  };

  // Preflight
  if (event.httpMethod === "OPTIONS") {
    return { statusCode: 204, headers: corsHeaders, body: "" };
  }

  try {
    const apiKey = process.env.ODDS_API_KEY;
    if (!apiKey) {
      return { statusCode: 500, headers: corsHeaders, body: JSON.stringify({ error: "Missing ODDS_API_KEY" }) };
    }

    const qs = event.queryStringParameters || {};

    // ✅ Você pode usar sportKey (recomendado) OU sport
    const sportKey = (qs.sportKey || qs.sport || "soccer_brazil_campeonato").trim();

    // Defaults bons pro futebol
    const regions = (qs.regions || "sa").trim();              // sa, eu, uk, us, au (ou combinado: "sa,eu")
    const markets = (qs.markets || qs.market || "h2h").trim(); // h2h, totals, spreads, etc.
    const oddsFormat = (qs.oddsFormat || "decimal").trim();    // decimal ou american
    const dateFormat = (qs.dateFormat || "iso").trim();        // iso ou unix

    // Opcional: filtrar bookmakers (se sua conta suportar)
    const bookmakers = (qs.bookmakers || "").trim(); // ex: "bet365,pinnacle"

    // Monta URL
    const url = new URL(`https://api.the-odds-api.com/v4/sports/${encodeURIComponent(sportKey)}/odds/`);
    url.searchParams.set("apiKey", apiKey);
    url.searchParams.set("regions", regions);
    url.searchParams.set("markets", markets);
    url.searchParams.set("oddsFormat", oddsFormat);
    url.searchParams.set("dateFormat", dateFormat);

    if (bookmakers) url.searchParams.set("bookmakers", bookmakers);

    // Chama Odds API
    const res = await fetch(url.toString(), { headers: { "accept": "application/json" } });
    const text = await res.text();

    // Repassa também headers úteis de rate limit (se existirem)
    const remaining = res.headers.get("x-requests-remaining");
    const used = res.headers.get("x-requests-used");
    const limitHeaders = {};
    if (remaining) limitHeaders["x-requests-remaining"] = remaining;
    if (used) limitHeaders["x-requests-used"] = used;

    return {
      statusCode: res.status,
      headers: { ...corsHeaders, ...limitHeaders },
      body: text,
    };
  } catch (e) {
    return {
      statusCode: 500,
      headers: corsHeaders,
      body: JSON.stringify({ error: e?.message || "Unknown error" }),
    };
  }
}