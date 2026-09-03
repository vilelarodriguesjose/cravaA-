-- ============================================================
-- CRAVAÍ - SEGURANÇA DE CARTEIRAS E TRANSAÇÕES
-- Usuário só pode LER os próprios dados.
-- Alterações ficam restritas às funções seguras/backend.
-- ============================================================


-- ============================================================
-- 1. FECHAR PERMISSÕES DIRETAS
-- ============================================================

revoke all on table public.wallets from anon, authenticated;
revoke all on table public.transactions from anon, authenticated;

-- Usuário autenticado pode apenas consultar.
grant select on table public.wallets to authenticated;
grant select on table public.transactions to authenticated;


-- ============================================================
-- 2. RECRIAR POLÍTICAS RLS DE LEITURA
-- ============================================================

drop policy if exists wallets_select on public.wallets;
drop policy if exists tx_select on public.transactions;

create policy wallets_select_own
on public.wallets
for select
to authenticated
using (auth.uid() = user_id);

create policy transactions_select_own
on public.transactions
for select
to authenticated
using (auth.uid() = user_id);