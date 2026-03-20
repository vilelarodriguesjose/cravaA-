import { createClient } from "@supabase/supabase-js";
import crypto from "crypto";
import { Resend } from "resend";

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

function make6DigitCode(){
  return String(Math.floor(100000 + Math.random()*900000));
}

function hashPass(pass){
  const salt = crypto.randomBytes(16).toString("hex");
  const hash = crypto.pbkdf2Sync(pass, salt, 120000, 32, "sha256").toString("hex");
  return `pbkdf2$${salt}$${hash}`;
}

export async function handler(event){
  try{
    if(event.httpMethod !== "POST") return json(405, { error:"Use POST" });

    const body = JSON.parse(event.body || "{}");
    const email = String(body.email || "").trim().toLowerCase();
    const pass  = String(body.pass || "");
    const username = String(body.username || "").trim();

    if(!email.includes("@")) return json(400, { error:"Email inválido" });
    if(pass.length < 4) return json(400, { error:"Senha muito curta" });
    if(username.length < 3) return json(400, { error:"Usuário muito curto" });

    if(!process.env.RESEND_API_KEY || !process.env.EMAIL_FROM){
      return json(500, { error:"Configure RESEND_API_KEY e EMAIL_FROM no Netlify" });
    }

    const { data: exists, error: e1 } = await supa
      .from("profiles")
      .select("email")
      .eq("email", email)
      .maybeSingle();

    if(e1) return json(500, { error: e1.message });
    if(exists?.email) return json(409, { error:"Esse e-mail já está cadastrado" });

    const code = make6DigitCode();
    const expiresAt = new Date(Date.now() + 15*60*1000).toISOString();

    const payload = {
      email,
      username,
      fullname: String(body.fullname || "").trim(),
      country: String(body.country || ""),
      phone: String(body.phone || ""),
      gender: String(body.gender || ""),
      firstName: String(body.firstName || ""),
      lastName: String(body.lastName || ""),
      birthDay: String(body.birthDay || ""),
      birthMonth: String(body.birthMonth || ""),
      birthYear: String(body.birthYear || ""),
      cpf: String(body.cpf || ""),
      pass_hash: hashPass(pass),
      cp: 500,
      plan: "free"
    };

    const { error: upErr } = await supa
      .from("email_verifications")
      .upsert({
        email,
        code,
        payload,
        expires_at: expiresAt
      }, { onConflict: "email" });

    if(upErr) return json(500, { error: upErr.message });

    const resend = new Resend(process.env.RESEND_API_KEY);

    const { error: mailError } = await resend.emails.send({
      from: process.env.EMAIL_FROM,
      to: email,
      subject: "CravaAí • Seu código de confirmação",
      html: `
        <div style="font-family:Arial,sans-serif;line-height:1.5">
          <h2>Confirme seu e-mail</h2>
          <p>Seu código é:</p>
          
          <div style="
            font-size:32px;
            font-weight:900;
            letter-spacing:6px;
            background:#0E8A3B;
            color:#fff;
            display:inline-block;
            padding:10px 20px;
            border-radius:8px;
          ">
            ${code}
          </div>

          <p style="margin-top:20px;color:#666">
            Esse código expira em 15 minutos.
          </p>
        </div>
      `
    });

    if (mailError) {
      return json(500, { error: "Erro ao enviar email" });
    }

    return json(200, { ok:true });

  }catch(e){
    return json(500, { error: String(e?.message || e) });
  }
}