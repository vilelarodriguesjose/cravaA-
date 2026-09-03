-- CravaAí Backend V2
-- Migration 03: proteção de perfis e dados pessoais

begin;


-- =========================================================
-- 1. REMOVER POLICIES ANTIGAS E PERMISSIVAS
-- =========================================================

drop policy if exists "profiles_insert"
on public.profiles;

drop policy if exists "profiles_select"
on public.profiles;

drop policy if exists "profiles_update"
on public.profiles;


-- =========================================================
-- 2. REMOVER PERMISSÕES DIRETAS ANTIGAS
-- =========================================================

revoke all privileges
on table public.profiles
from anon;

revoke all privileges
on table public.profiles
from authenticated;


-- =========================================================
-- 3. LEITURA DO PERFIL
--
-- Usuário autenticado pode consultar somente
-- o próprio perfil completo.
-- =========================================================

grant select
on table public.profiles
to authenticated;

create policy "profiles_select_own"
on public.profiles
for select
to authenticated
using (
  id = auth.uid()
);


-- =========================================================
-- 4. CRIAÇÃO DO PERFIL
--
-- Não permitimos INSERT direto pelo navegador.
--
-- O perfil continua sendo criado automaticamente pelo
-- trigger handle_auth_user_created() após o cadastro
-- no Supabase Auth.
-- =========================================================

-- Nenhum GRANT INSERT para anon/authenticated.
-- Nenhuma policy INSERT para anon/authenticated.


-- =========================================================
-- 5. EDIÇÃO DO PERFIL
--
-- O usuário pode alterar SOMENTE:
--
-- username
-- fullname
-- avatar_url
-- phone
--
-- Todo o restante fica protegido pelo backend.
-- =========================================================

grant update (
  username,
  fullname,
  avatar_url,
  phone
)
on public.profiles
to authenticated;


create policy "profiles_update_own"
on public.profiles
for update
to authenticated
using (
  id = auth.uid()
)
with check (
  id = auth.uid()
);


-- =========================================================
-- CAMPOS PROTEGIDOS
--
-- O usuário NÃO consegue alterar diretamente:
--
-- id
-- email
-- cpf
-- country
-- gender
-- birth_date
-- plan
-- is_admin
-- created_at
-- updated_at
-- =========================================================


commit;