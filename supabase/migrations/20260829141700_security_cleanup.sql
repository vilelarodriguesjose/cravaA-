-- CravaAí Backend V2
-- Migration 01: limpeza inicial de segurança

begin;

-- 1) Remover carteira duplicada e vazia
drop table if exists public.user_wallets;

-- 2) Remover policy perigosa:
-- usuário não pode alterar diretamente o próprio saldo da liga
drop policy if exists "users can update own league member balance"
on public.league_members;

-- 3) Restringir execução das funções sensíveis

-- SETTLE BET: somente backend/service_role
revoke execute on function public.settle_bet(uuid, text) from public;
revoke execute on function public.settle_bet(uuid, text) from anon;
revoke execute on function public.settle_bet(uuid, text) from authenticated;

grant execute on function public.settle_bet(uuid, text) to service_role;

-- PLACE BET:
-- temporariamente disponível apenas para usuários autenticados.
-- Na próxima migration vamos substituir essa função por uma versão segura.
revoke execute on function public.place_bet(uuid, bigint, numeric, text, jsonb) from public;
revoke execute on function public.place_bet(uuid, bigint, numeric, text, jsonb) from anon;

grant execute on function public.place_bet(uuid, bigint, numeric, text, jsonb)
to authenticated;

-- JOIN LEAGUE: somente usuário autenticado
revoke execute on function public.join_league(uuid) from public;
revoke execute on function public.join_league(uuid) from anon;

grant execute on function public.join_league(uuid) to authenticated;

-- STANDINGS: somente usuário autenticado
revoke execute on function public.get_league_standings(uuid) from public;
revoke execute on function public.get_league_standings(uuid) from anon;

grant execute on function public.get_league_standings(uuid) to authenticated;

-- 4) Funções internas de trigger não podem ser chamadas
-- diretamente pelo navegador/cliente.

revoke execute on function public.handle_auth_user_created() from public;
revoke execute on function public.handle_auth_user_created() from anon;
revoke execute on function public.handle_auth_user_created() from authenticated;

revoke execute on function public.handle_new_user() from public;
revoke execute on function public.handle_new_user() from anon;
revoke execute on function public.handle_new_user() from authenticated;

revoke execute on function public.handle_updated_at() from public;
revoke execute on function public.handle_updated_at() from anon;
revoke execute on function public.handle_updated_at() from authenticated;

commit;