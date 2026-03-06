import { createClient } from "@supabase/supabase-js";
import crypto from "crypto";

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

function verifyPass(pass, stored) {
  try {
    const [kind, salt, hash] = String(stored || "").split("$");
    if (kind !== "pbkdf2") return false;
    const test = crypto.pbkdf2Sync(pass, salt, 120000, 32, "sha256").toString("hex");
    return crypto.timingSafeEqual(Buffer.from(test, "hex"), Buffer.from(hash, "hex"));
  } catch {
    return false;
  }
}

export async function handler(event) {
  try {
    if (event.httpMethod !== "POST") return json(405, { error: "Use POST" });

    const body = JSON.parse(event.body || "{}");
    const email = String(body.email || "").trim().toLowerCase();
    const pass = String(body.pass || "");

    if (!email.includes("@") || pass.length < 4) {
      return json(400, { error: "Email/senha inválidos" });
    }

    const supa = sb();

    const { data: authRow, error: e1 } = await supa
      .from("auth_local")
      .select("email, pass_hash")
      .eq("email", email)
      .maybeSingle();

    if (e1) return json(500, { error: e1.message });
    if (!authRow) return json(401, { error: "Dados incorretos" });

    if (!verifyPass(pass, authRow.pass_hash)) {
      return json(401, { error: "Dados incorretos" });
    }

    const { data: profile, error: e2 } = await supa
      .from("profiles")
      .select("email, username, fullname, plan, cp")
      .eq("email", email)
      .single();

    if (e2) return json(500, { error: e2.message });

    return json(200, { ok: true, profile });
  } catch (e) {
    return json(500, { error: String(e?.message || e) });
  }
}