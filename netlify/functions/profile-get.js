import { createClient } from "@supabase/supabase-js";

const supa = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_ROLE_KEY,
  { auth: { persistSession: false } }
);

const json = (statusCode, body) => ({
  statusCode,
  headers: {
    "Content-Type": "application/json",
    "Access-Control-Allow-Origin": "*"
  },
  body: JSON.stringify(body)
});

export async function handler(event) {
  try {
    const email = String(event.queryStringParameters?.email || "").trim().toLowerCase();
    if (!email) return json(400, { error: "email obrigatório" });

    const { data, error } = await supa
      .from("profiles")
      .select("email, username, fullname, plan, cp")
      .eq("email", email)
      .maybeSingle();

    if (error) return json(500, { error: error.message });
    if (!data) return json(404, { error: "perfil não encontrado" });

    return json(200, data);
  } catch (e) {
    return json(500, { error: String(e?.message || e) });
  }
}