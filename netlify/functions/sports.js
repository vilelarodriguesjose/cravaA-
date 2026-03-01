export async function handler() {
  const apiKey = process.env.ODDS_API_KEY;
  const url = `https://api.the-odds-api.com/v4/sports/?apiKey=${encodeURIComponent(apiKey)}`;

  const res = await fetch(url);
  const body = await res.text();

  return {
    statusCode: res.status,
    headers: { "Content-Type": "application/json" },
    body,
  };
}