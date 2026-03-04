// netlify/functions/stripe-webhook.js
const Stripe = require("stripe");
const { createClient } = require("@supabase/supabase-js");

const stripe = new Stripe(process.env.STRIPE_SECRET_KEY);

const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_ROLE_KEY
);

exports.handler = async (event) => {
  try {
    const sig = event.headers["stripe-signature"] || event.headers["Stripe-Signature"];
    if (!sig) return { statusCode: 400, body: "Missing stripe-signature" };

    const stripeEvent = stripe.webhooks.constructEvent(
      event.body,
      sig,
      process.env.STRIPE_WEBHOOK_SECRET
    );

    if (stripeEvent.type === "checkout.session.completed") {
      const session = stripeEvent.data.object;
      const email = session.customer_email;
      const plan = (session.metadata && session.metadata.plan) || "free";

      if (email) {
        await supabase
          .from("profiles")
          .upsert({ email, plan }, { onConflict: "email" });
      }
    }

    if (stripeEvent.type === "customer.subscription.deleted") {
      const sub = stripeEvent.data.object;
      const customerId = sub.customer;

      if (customerId) {
        const customer = await stripe.customers.retrieve(customerId);
        const email = customer?.email;
        if (email) {
          await supabase.from("profiles").update({ plan: "free" }).eq("email", email);
        }
      }
    }

    return { statusCode: 200, body: "ok" };
  } catch (err) {
    console.error("Webhook error:", err);
    return { statusCode: 400, body: `Webhook Error: ${err.message || String(err)}` };
  }
};