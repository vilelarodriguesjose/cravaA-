-- ============================================================
-- CRAVAÍ - REMOVER PLANO DUPLICADO DE PROFILES
-- user_plans passa a ser a única fonte oficial de assinatura.
-- ============================================================


-- ============================================================
-- 1. ATUALIZAR FUNÇÃO DE CRIAÇÃO DE PERFIL
-- ============================================================

create or replace function public.handle_auth_user_created()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  insert into public.profiles (
    id,
    email,
    username,
    fullname,
    cpf,
    phone,
    gender,
    country
  )
  values (
    new.id,
    new.email,
    coalesce(
      new.raw_user_meta_data->>'username',
      'user_' || substr(new.id::text, 1, 8)
    ),
    coalesce(new.raw_user_meta_data->>'fullname', ''),
    new.raw_user_meta_data->>'cpf',
    new.raw_user_meta_data->>'phone',
    new.raw_user_meta_data->>'gender',
    new.raw_user_meta_data->>'country'
  )
  on conflict (id) do nothing;

  return new;
end;
$$;


-- ============================================================
-- 2. REMOVER COLUNA DUPLICADA
-- ============================================================

alter table public.profiles
drop column if exists plan;