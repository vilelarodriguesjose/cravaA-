import { createClient } from "@supabase/supabase-js";

const sb = () => createClient(
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
  body: JSON.stringify(body),
});

export async function handler(event) {
  try {
    if (event.httpMethod !== "POST") return json(405, { error: "Use POST" });

    const body = JSON.parse(event.body || "{}");
    const email = String(body.email || "").trim().toLowerCase();
    const code = String(body.code || "").trim();

    if (!email.includes("@")) return json(400, { error: "Email inválido" });
    if (code.length !== 6) return json(400, { error: "Código deve ter 6 dígitos" });

    const supa = sb();

    const { data: row, error: e1 } = await supa
      .from("email_verifications")
      .select("email, code, payload, expires_at")
      .eq("email", email)
      .maybeSingle();

    if (e1) return json(500, { error: e1.message });
    if (!row) return json(404, { error: "Sem código pendente para esse e-mail" });

    const exp = new Date(row.expires_at).getTime();
    if (Date.now() > exp) return json(400, { error: "Código expirado. Reenvie." });
    if (String(row.code) !== code) return json(401, { error: "Código inválido" });

    const payload = row.payload || {};
    const username = payload.username || "Usuário";

    const { data: prof, error: e2 } = await supa
      .from("profiles")
      .upsert(
        {
          email,
          username,
          fullname: payload.fullname || "",
          plan: payload.plan || "free",
          cp: Number(payload.cp || 500)
        },
        { onConflict: "email" }
      )
      .select("email, username, fullname, plan, cp")
      .single();

    if (e2) return json(500, { error: e2.message });

    const { error: e3 } = await supa
      .from("auth_local")
      .upsert(
        {
          email,
          pass_hash: payload.pass_hash
        },
        { onConflict: "email" }
      );

    if (e3) return json(500, { error: e3.message });

    await supa.from("email_verifications").delete().eq("email", email);

    return json(200, { ok: true, profile: prof });
  } catch (e) {
    return json(500, { error: String(e?.message || e) });
  }
}