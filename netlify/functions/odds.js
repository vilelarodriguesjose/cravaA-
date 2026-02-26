export async function handler(event) {
  try {
    const apiKey = process.env.ODDS_API_KEY;
    if (!apiKey) {
      return { statusCode: 500, body: "Missing ODDS_API_KEY" };
    }

    const sport = event.queryStringParameters?.sport || "soccer_epl";
    const regions = event.queryStringParameters?.regions || "eu";
    const markets = event.queryStringParameters?.markets || "h2h";

    const url =
      `https://api.the-odds-api.com/v4/sports/${encodeURIComponent(sport)}/odds/` +
      `?apiKey=${encodeURIComponent(apiKey)}&regions=${encodeURIComponent(regions)}` +
      `&markets=${encodeURIComponent(markets)}&oddsFormat=decimal`;

    const res = await fetch(url);
    const body = await res.text();

    return {
      statusCode: res.status,
      headers: { "Content-Type": "application/json" },
      body,
    };
  } catch (e) {
    return { statusCode: 500, body: JSON.stringify({ error: e.message }) };
  }
}