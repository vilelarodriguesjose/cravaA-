-- ============================================================
-- CRAVAÍ - SEGURANÇA DE PARTIDAS E ODDS
-- Cliente pode apenas consultar.
-- Escrita fica restrita ao backend/service_role.
-- ============================================================


-- ============================================================
-- 1. FECHAR PERMISSÕES DIRETAS
-- ============================================================

revoke all on table public.matches from anon, authenticated;
revoke all on table public.odds from anon, authenticated;

-- Jogos e odds precisam ser visíveis no site,
-- inclusive antes do usuário fazer login.
grant select on table public.matches to anon, authenticated;
grant select on table public.odds to anon, authenticated;


-- ============================================================
-- 2. RECRIAR POLÍTICAS DE LEITURA
-- ============================================================

drop policy if exists matches_select on public.matches;
drop policy if exists odds_select on public.odds;

create policy matches_select_public
on public.matches
for select
to anon, authenticated
using (true);

create policy odds_select_public
on public.odds
for select
to anon, authenticated
using (true);