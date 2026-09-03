-- =========================================================
-- CravaAi - Secure Leagues Admin
-- Remove autorização por e-mail fixo
-- Administração passa a usar profiles.is_admin
-- =========================================================


-- =========================================================
-- 1. REMOVER POLICIES ANTIGAS
-- =========================================================

drop policy if exists "admin delete leagues"
on public.leagues;

drop policy if exists "admin insert leagues"
on public.leagues;

drop policy if exists "public read leagues"
on public.leagues;


-- =========================================================
-- 2. FECHAR PRIVILÉGIOS EXCESSIVOS
-- =========================================================

revoke all
on table public.leagues
from anon;

revoke all
on table public.leagues
from authenticated;


-- =========================================================
-- 3. PERMITIR SOMENTE LEITURA
-- =========================================================

grant select
on table public.leagues
to anon;

grant select
on table public.leagues
to authenticated;


-- =========================================================
-- 4. LEITURA DAS LIGAS
-- =========================================================

create policy "leagues_select"
on public.leagues
for select
to anon, authenticated
using (true);


-- =========================================================
-- 5. ADMIN PODE INSERIR
-- =========================================================

create policy "leagues_admin_insert"
on public.leagues
for insert
to authenticated
with check (
  exists (
    select 1
    from public.profiles p
    where p.id = auth.uid()
      and p.is_admin = true
  )
);


-- =========================================================
-- 6. ADMIN PODE ATUALIZAR
-- =========================================================

create policy "leagues_admin_update"
on public.leagues
for update
to authenticated
using (
  exists (
    select 1
    from public.profiles p
    where p.id = auth.uid()
      and p.is_admin = true
  )
)
with check (
  exists (
    select 1
    from public.profiles p
    where p.id = auth.uid()
      and p.is_admin = true
  )
);


-- =========================================================
-- 7. ADMIN PODE EXCLUIR
-- =========================================================

create policy "leagues_admin_delete"
on public.leagues
for delete
to authenticated
using (
  exists (
    select 1
    from public.profiles p
    where p.id = auth.uid()
      and p.is_admin = true
  )
);


-- =========================================================
-- 8. GRANTS NECESSÁRIOS PARA AS POLICIES DE ESCRITA
-- =========================================================

grant insert, update, delete
on table public.leagues
