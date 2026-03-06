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
    if (event.httpMethod !== "POST") return json(405, { error: "Use POST" });

    const body = JSON.parse(event.body || "{}");
    const email = String(body.email || "").trim().toLowerCase();
    if (!email) return json(400, { error: "email obrigatório" });

    const patch = {};
    if (body.username != null) patch.username = String(body.username);
    if (body.fullname != null) patch.fullname = String(body.fullname);
    if (body.plan != null) patch.plan = String(body.plan);
    if (body.cp != null) patch.cp = Number(body.cp);

    const { data, error } = await supa
      .from("profiles")
      .upsert({ email, ...patch }, { onConflict: "email" })
      .select("email, username, fullname, plan, cp")
      .single();

    if (error) return json(500, { error: error.message });
    return json(200, { ok: true, profile: data });
  } catch (e) {
    return json(500, { error: String(e?.message || e) });
  }
}