export async function handler(event) {
  const apiKey = process.env.ODDS_API_KEY;

  const url = `https://api.the-odds-api.com/v4/sports/soccer_epl/odds/?apiKey=${apiKey}&regions=eu&markets=h2h&oddsFormat=decimal`;

  const response = await fetch(url);
  const data = await response.text();

  return {
    statusCode: 200,
    body: data,
  };
}