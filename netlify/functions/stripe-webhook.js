const Stripe = require("stripe");
const { createClient } = require("@supabase/supabase-js");

const stripe = new Stripe(process.env.STRIPE_SECRET_KEY);

const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_ROLE_KEY
);

exports.handler = async (event) => {

  const sig = event.headers["stripe-signature"];

  const stripeEvent = stripe.webhooks.constructEvent(
    event.body,
    sig,
    process.env.STRIPE_WEBHOOK_SECRET
  );

  if (stripeEvent.type === "checkout.session.completed") {

    const session = stripeEvent.data.object;

    const email = session.customer_email;

    const price = session.line_items?.data?.[0]?.price?.id;

    let plan = "free";

    if (price === process.env.STRIPE_PRICE_PRO) {
      plan = "pro";
    }

    if (price === process.env.STRIPE_PRICE_ELITE) {
      plan = "elite";
    }

    await supabase
      .from("profiles")
      .update({ plan })
      .eq("email", email);

  }

  return {
    statusCode: 200,
    body: "ok"
  };
};