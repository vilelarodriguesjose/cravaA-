-- CravaAí Backend V2
-- Migration 05: proteção dos planos e entrada segura nas ligas

begin;


-- =========================================================
-- 1. PROTEGER USER_PLANS
--
-- Plano, status e validade da assinatura são dados
-- controlados exclusivamente pelo backend.
-- =========================================================

revoke all privileges
on table public.user_plans
from anon;

revoke all privileges
on table public.user_plans
from authenticated;


-- =========================================================
-- 2. RECRIAR JOIN_LEAGUE DE FORMA SEGURA
-- =========================================================

create or replace function public.join_league(
  p_league_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $function$
declare
  v_user uuid;

  v_plan text;
  v_month text;

  v_league public.leagues%rowtype;
  v_entries public.monthly_league_entries%rowtype;

  v_count integer;
  v_entries_allowed integer;
begin

  -- =======================================================
  -- USUÁRIO AUTENTICADO
  -- =======================================================

  v_user := auth.uid();

  if v_user is null then
    return jsonb_build_object(
      'ok', false,
      'message', 'Você precisa estar logado.'
    );
  end if;


  -- =======================================================
  -- VALIDAR ASSINATURA
  --
  -- Não basta status = active.
  -- O período também precisa estar válido AGORA.
  -- =======================================================

  select up.plan
  into v_plan
  from public.user_plans up
  where up.user_id = v_user
    and up.status = 'active'
    and up.current_period_start is not null
    and up.current_period_end is not null
    and up.current_period_start <= now()
    and up.current_period_end > now();

  if not found then
    return jsonb_build_object(
      'ok', false,
      'message', 'Você precisa ter um plano ativo e dentro do período de validade para entrar em ligas.'
    );
  end if;


  -- =======================================================
  -- DEFINIR LIMITE MENSAL PELO PLANO
  --
  -- Regra atual do CravaAí:
  -- PRO = 3 entradas por mês
  --
  -- Isso fica centralizado aqui para não depender
  -- de informação enviada pelo navegador.
  -- =======================================================

  case lower(v_plan)
    when 'pro' then
      v_entries_allowed := 3;

    else
      return jsonb_build_object(
        'ok', false,
        'message', 'Seu plano não possui acesso às ligas.'
      );
  end case;


  -- =======================================================
  -- TRAVAR A LIGA
  --
  -- FOR UPDATE impede que duas chamadas simultâneas
  -- ultrapassem o limite máximo de jogadores.
  -- =======================================================

  select *
  into v_league
  from public.leagues
  where id = p_league_id
  for update;

  if not found then
    return jsonb_build_object(
      'ok', false,
      'message', 'Liga não encontrada.'
    );
  end if;


  -- =======================================================
  -- VALIDAR STATUS DA LIGA
  -- =======================================================

  if v_league.status <> 'waiting' then
    return jsonb_build_object(
      'ok', false,
      'message', 'Essa liga não está aberta para entrada.'
    );
  end if;


  -- =======================================================
  -- VALIDAR DATAS DA LIGA
  -- =======================================================

  if v_league.starts_at is not null
     and v_league.starts_at <= now() then
    return jsonb_build_object(
      'ok', false,
      'message', 'Essa liga já começou.'
    );
  end if;

  if v_league.ends_at is not null
     and v_league.ends_at <= now() then
    return jsonb_build_object(
      'ok', false,
      'message', 'Essa liga já terminou.'
    );
  end if;


  -- =======================================================
  -- IMPEDIR ENTRADA DUPLICADA
  -- =======================================================

  if exists (
    select 1
    from public.league_members lm
    where lm.league_id = p_league_id
      and lm.user_id = v_user
  ) then
    return jsonb_build_object(
      'ok', false,
      'message', 'Você já está nessa liga.'
    );
  end if;


  -- =======================================================
  -- VALIDAR CAPACIDADE
  -- =======================================================

  select count(*)
  into v_count
  from public.league_members lm
  where lm.league_id = p_league_id;

  if v_count >= v_league.max_players then
    return jsonb_build_object(
      'ok', false,
      'message', 'Essa liga já está cheia.'
    );
  end if;


  -- =======================================================
  -- CONTROLE MENSAL DE ENTRADAS
  -- =======================================================

  v_month := to_char(now(), 'YYYY-MM');


  -- Cria o controle do mês se ainda não existir.

  insert into public.monthly_league_entries (
    user_id,
    month_key,
    entries_total,
    entries_used
  )
  values (
    v_user,
    v_month,
    v_entries_allowed,
    0
  )
  on conflict (user_id, month_key)
  do nothing;


  -- Trava o registro mensal para impedir duas entradas
  -- simultâneas usando a mesma última vaga disponível.

  select *
  into v_entries
  from public.monthly_league_entries
  where user_id = v_user
    and month_key = v_month
  for update;


  -- Mantém o limite sincronizado com a regra atual do plano.

  update public.monthly_league_entries
  set entries_total = v_entries_allowed
  where user_id = v_user
    and month_key = v_month;

  v_entries.entries_total := v_entries_allowed;


  if v_entries.entries_used >= v_entries.entries_total then
    return jsonb_build_object(
      'ok', false,
      'message', 'Você já usou todas as entradas de liga disponíveis neste mês.'
    );
  end if;


  -- =======================================================
  -- CRIAR PARTICIPAÇÃO NA LIGA
  --
  -- IMPORTANTE:
  -- balance = CP DA LIGA.
  --
  -- Não existe nenhuma leitura ou alteração em wallets.
  -- Portanto CP normal e CP da liga permanecem separados.
  -- =======================================================

  insert into public.league_members (
    league_id,
    user_id,
    balance
  )
  values (
    p_league_id,
    v_user,
    v_league.initial_stack
  );


  -- =======================================================
  -- CONSUMIR UMA ENTRADA MENSAL
  -- =======================================================

  update public.monthly_league_entries
  set entries_used = entries_used + 1
  where user_id = v_user
    and month_key = v_month;


  -- =======================================================
  -- SUCESSO
  -- =======================================================

  return jsonb_build_object(
    'ok', true,
    'message', 'Você entrou na liga com sucesso.',
    'league_id', p_league_id,
    'league_balance', v_league.initial_stack
  );

end;
$function$;


-- =========================================================
-- 3. PERMISSÕES DA FUNÇÃO
-- =========================================================

revoke all
on function public.join_league(uuid)
from public;

revoke all
on function public.join_league(uuid)
from anon;

grant execute
on function public.join_league(uuid)
to authenticated;


commit;