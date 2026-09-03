-- CravaAí Backend V2
-- Migration 04: proteção do saldo das ligas

begin;


-- =========================================================
-- 1. REMOVER POLICIES ANTIGAS
-- =========================================================

drop policy if exists "users insert league_members"
on public.league_members;

drop policy if exists "users read own league members"
on public.league_members;


-- =========================================================
-- 2. REMOVER PERMISSÕES DIRETAS
--
-- O cliente não pode inserir nem alterar saldo de liga.
-- =========================================================

revoke all privileges
on table public.league_members
from anon;

revoke all privileges
on table public.league_members
from authenticated;


-- =========================================================
-- 3. PERMITIR SOMENTE LEITURA DO PRÓPRIO SALDO DE LIGA
-- =========================================================

grant select
on table public.league_members
to authenticated;

create policy "league_members_select_own"
on public.league_members
for select
to authenticated
using (
  user_id = auth.uid()
);


-- =========================================================
-- 4. ENTRADA NA LIGA
--
-- Não existe INSERT direto para anon/authenticated.
--
-- A entrada deve ocorrer exclusivamente por:
--
-- public.join_league(uuid)
--
-- Essa função SECURITY DEFINER é responsável por:
-- - identificar auth.uid()
-- - validar plano
-- - validar vagas
-- - validar limite mensal
-- - impedir duplicidade
-- - definir o saldo inicial da liga
-- =========================================================


-- =========================================================
-- 5. ALTERAÇÃO DO SALDO
--
-- Não concedemos UPDATE ao cliente.
--
-- league_members.balance só poderá ser modificado
-- por funções controladas do backend.
-- =========================================================


commit;