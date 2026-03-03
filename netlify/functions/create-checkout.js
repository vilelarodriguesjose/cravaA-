const Stripe = require("stripe");
const { createClient } = require("@supabase/supabase-js");

const stripe = new Stripe(process.env.STRIPE_SECRET_KEY);

const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_ROLE_KEY
);

exports.handler = async (event) => {
  try {

    const { email, plan } = JSON.parse(event.body);

    const priceId =
      plan === "pro"
        ? process.env.STRIPE_PRICE_PRO
        : process.env.STRIPE_PRICE_ELITE;

    const session = await stripe.checkout.sessions.create({
      mode: "subscription",
      customer_email: email,
      line_items: [
        {
          price: priceId,
          quantity: 1
        }
      ],
      success_url: `${process.env.SITE_URL}/?success=true`,
      cancel_url: `${process.env.SITE_URL}/?cancel=true`
    });

    return {
      statusCode: 200,
      body: JSON.stringify({
        url: session.url
      })
    };

  } catch (error) {

    return {
      statusCode: 500,
      body: JSON.stringify({
        error: error.message
      })
    };

  }
};