const { createClient } = require("@supabase/supabase-js");

const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_ROLE_KEY
);

exports.handler = async (event) => {
  try {
    if (event.httpMethod !== "POST") {
      return { statusCode: 405, body: JSON.stringify({ error: "Use POST" }) };
    }

    const { email, username, fullname } = JSON.parse(event.body || "{}");
    if (!email || !String(email).includes("@")) {
      return { statusCode: 400, body: JSON.stringify({ error: "Email inválido" }) };
    }

    // garante que existe (free por padrão)
    const { error } = await supabase
      .from("profiles")
      .upsert(
        { email, plan: "free", username: username || null, fullname: fullname || null },
        { onConflict: "email" }
      );

    if (error) throw error;

    return { statusCode: 200, body: JSON.stringify({ ok: true }) };
  } catch (e) {
    console.error(e);
    return { statusCode: 500, body: JSON.stringify({ error: e.message || String(e) }) };
  }
};