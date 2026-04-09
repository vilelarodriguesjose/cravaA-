const { createClient } = require("@supabase/supabase-js");

exports.handler = async (event) => {
  if(event.httpMethod !== "POST"){
    return {
      statusCode: 405,
      body: JSON.stringify({ error: "Método não permitido" })
    };
  }

  try{
    const body = JSON.parse(event.body || "{}");

    const supabase = createClient(
      process.env.SUPABASE_URL,
      process.env.SUPABASE_SERVICE_ROLE_KEY
    );

    const { data, error } = await supabase.rpc("place_bet", {
      p_user_id: body.user_id,
      p_stake: body.stake,
      p_total_odds: body.total_odds,
      p_bet_type: body.bet_type,
      p_items: body.items
    });

    if(error){
      return {
        statusCode: 400,
        body: JSON.stringify({ error: error.message })
      };
    }

    return {
      statusCode: 200,
      body: JSON.stringify({ bet_id: data })
    };
  }catch(err){
    return {
      statusCode: 500,
      body: JSON.stringify({ error: "Erro interno ao criar aposta" })
    };
  }
};