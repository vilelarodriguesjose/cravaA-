// netlify/functions/create-checkout.js
const Stripe = require("stripe");
const { createClient } = require("@supabase/supabase-js");

const stripe = new Stripe(process.env.STRIPE_SECRET_KEY);

const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_ROLE_KEY
);

exports.handler = async (event) => {
  // só POST
  if (event.httpMethod !== "POST") {
    return {
      statusCode: 405,
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ error: "Method Not Allowed. Use POST." }),
    };
  }

  try {
    if (!event.body) {
      return {
        statusCode: 400,
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ error: "Body vazio. Envie {email, plan}." }),
      };
    }

    const { email, plan } = JSON.parse(event.body || "{}");

    if (!email || !String(email).includes("@")) {
      return {
        statusCode: 400,
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ error: "Email inválido" }),
      };
    }

    const priceId =
      plan === "pro"
        ? process.env.STRIPE_PRICE_PRO
        : plan === "elite"
        ? process.env.STRIPE_PRICE_ELITE
        : null;

    if (!priceId) {
      return {
        statusCode: 400,
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ error: "Plano inválido. Use pro ou elite." }),
      };
    }

    const siteUrl = process.env.SITE_URL;
    if (!siteUrl) {
      return {
        statusCode: 500,
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ error: "SITE_URL não configurada no Netlify." }),
      };
    }

    // garante perfil
    await supabase
      .from("profiles")
      .upsert({ email, plan: "free" }, { onConflict: "email" });

    const session = await stripe.checkout.sessions.create({
      mode: "subscription",
      customer_email: email,
      metadata: { plan }, // ✅ isso que o webhook vai ler
      line_items: [{ price: priceId, quantity: 1 }],
      success_url: `${siteUrl}/?pay=success&session_id={CHECKOUT_SESSION_ID}`,
      cancel_url: `${siteUrl}/?pay=cancel`,
    });

    return {
      statusCode: 200,
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ url: session.url }),
    };
  } catch (error) {
    console.error("create-checkout error:", error);
    return {
      statusCode: 500,
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ error: error.message || String(error) }),
    };
  }
};