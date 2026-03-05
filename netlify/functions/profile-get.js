const { createClient } = require("@supabase/supabase-js");

const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_ROLE_KEY
);

exports.handler = async (event) => {
  try {
    if (event.httpMethod !== "GET") {
      return { statusCode: 405, body: JSON.stringify({ error: "Use GET" }) };
    }

    const email = (event.queryStringParameters?.email || "").trim().toLowerCase();
    if (!email || !email.includes("@")) {
      return { statusCode: 400, body: JSON.stringify({ error: "Email inválido" }) };
    }

    const { data, error } = await supabase
      .from("profiles")
      .select("email, plan")
      .eq("email", email)
      .maybeSingle();

    if (error) throw error;

    return {
      statusCode: 200,
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ plan: data?.plan || "free" }),
    };
  } catch (e) {
    console.error(e);
    return { statusCode: 500, body: JSON.stringify({ error: e.message || String(e) }) };
  }
};