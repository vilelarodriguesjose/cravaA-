-- Migration 23
-- Administração segura da Loja CravaAí

-- =========================================================
-- 1. FUNÇÃO AUXILIAR: VERIFICAR ADMIN
-- =========================================================

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select coalesce(
    (
      select p.is_admin
      from public.profiles p
      where p.id = auth.uid()
    ),
    false
  );
$$;

revoke all on function public.is_admin() from public;
grant execute on function public.is_admin() to authenticated;


-- =========================================================
-- 2. RLS DOS PRODUTOS
-- =========================================================

alter table public.shop_items enable row level security;

revoke all on table public.shop_items from anon, authenticated;

grant select on table public.shop_items to anon, authenticated;

drop policy if exists "shop_items_public_select" on public.shop_items;
drop policy if exists "shop_items_admin_select" on public.shop_items;

create policy "shop_items_public_select"
on public.shop_items
for select
to anon, authenticated
using (active = true);

create policy "shop_items_admin_select"
on public.shop_items
for select
to authenticated
using (public.is_admin());


-- =========================================================
-- 3. RLS DOS PEDIDOS
-- =========================================================

alter table public.shop_orders enable row level security;

revoke all on table public.shop_orders from anon, authenticated;

grant select on table public.shop_orders to authenticated;

drop policy if exists "shop_orders_own_select" on public.shop_orders;
drop policy if exists "shop_orders_admin_select" on public.shop_orders;

create policy "shop_orders_own_select"
on public.shop_orders
for select
to authenticated
using (user_id = auth.uid());

create policy "shop_orders_admin_select"
on public.shop_orders
for select
to authenticated
using (public.is_admin());


-- =========================================================
-- 4. ADMIN: CRIAR PRODUTO
-- =========================================================

create or replace function public.admin_create_shop_item(
  p_name text,
  p_description text,
  p_image_url text,
  p_category text,
  p_price_cp numeric,
  p_stock integer,
  p_active boolean default true
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_id uuid;
  v_name text;
  v_category text;
begin
  if auth.uid() is null then
    raise exception 'Usuário não autenticado';
  end if;

  if not public.is_admin() then
    raise exception 'Acesso restrito ao administrador';
  end if;

  v_name := nullif(trim(p_name), '');
  v_category := lower(trim(coalesce(p_category, 'geral')));

  if v_name is null then
    raise exception 'Nome do produto é obrigatório';
  end if;

  if v_category not in (
    'camiseta',
    'ingresso',
    'acessorio',
    'digital',
    'geral'
  ) then
    raise exception 'Categoria inválida';
  end if;

  if p_price_cp is null or p_price_cp < 0 then
    raise exception 'Preço inválido';
  end if;

  if round(p_price_cp, 2) <> p_price_cp then
    raise exception 'Preço deve ter no máximo 2 casas decimais';
  end if;

  if p_stock is not null and p_stock < 0 then
    raise exception 'Estoque inválido';
  end if;

  insert into public.shop_items (
    name,
    description,
    image_url,
    category,
    price_cp,
    stock,
    active
  )
  values (
    v_name,
    nullif(trim(p_description), ''),
    nullif(trim(p_image_url), ''),
    v_category,
    round(p_price_cp, 2),
    p_stock,
    coalesce(p_active, true)
  )
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.admin_create_shop_item(
  text,
  text,
  text,
  text,
  numeric,
  integer,
  boolean
) from public;

grant execute on function public.admin_create_shop_item(
  text,
  text,
  text,
  text,
  numeric,
  integer,
  boolean
) to authenticated;


-- =========================================================
-- 5. ADMIN: EDITAR PRODUTO
-- =========================================================

create or replace function public.admin_update_shop_item(
  p_item_id uuid,
  p_name text,
  p_description text,
  p_image_url text,
  p_category text,
  p_price_cp numeric,
  p_stock integer,
  p_active boolean
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_name text;
  v_category text;
begin
  if auth.uid() is null then
    raise exception 'Usuário não autenticado';
  end if;

  if not public.is_admin() then
    raise exception 'Acesso restrito ao administrador';
  end if;

  v_name := nullif(trim(p_name), '');
  v_category := lower(trim(coalesce(p_category, 'geral')));

  if v_name is null then
    raise exception 'Nome do produto é obrigatório';
  end if;

  if v_category not in (
    'camiseta',
    'ingresso',
    'acessorio',
    'digital',
    'geral'
  ) then
    raise exception 'Categoria inválida';
  end if;

  if p_price_cp is null or p_price_cp < 0 then
    raise exception 'Preço inválido';
  end if;

  if round(p_price_cp, 2) <> p_price_cp then
    raise exception 'Preço deve ter no máximo 2 casas decimais';
  end if;

  if p_stock is not null and p_stock < 0 then
    raise exception 'Estoque inválido';
  end if;

  update public.shop_items
  set
    name = v_name,
    description = nullif(trim(p_description), ''),
    image_url = nullif(trim(p_image_url), ''),
    category = v_category,
    price_cp = round(p_price_cp, 2),
    stock = p_stock,
    active = coalesce(p_active, false)
  where id = p_item_id;

  if not found then
    raise exception 'Produto não encontrado';
  end if;
end;
$$;

revoke all on function public.admin_update_shop_item(
  uuid,
  text,
  text,
  text,
  text,
  numeric,
  integer,
  boolean
) from public;

grant execute on function public.admin_update_shop_item(
  uuid,
  text,
  text,
  text,
  text,
  numeric,
  integer,
  boolean
) to authenticated;


-- =========================================================
-- 6. ADMIN: ALTERAR STATUS DO PEDIDO
-- =========================================================

create or replace function public.admin_update_shop_order_status(
  p_order_id uuid,
  p_status public.order_status
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_current_status public.order_status;
begin
  if auth.uid() is null then
    raise exception 'Usuário não autenticado';
  end if;

  if not public.is_admin() then
    raise exception 'Acesso restrito ao administrador';
  end if;

  select status
  into v_current_status
  from public.shop_orders
  where id = p_order_id
  for update;

  if not found then
    raise exception 'Pedido não encontrado';
  end if;

  if v_current_status = p_status then
    return;
  end if;

  -- Fluxo permitido:
  -- PENDING -> CONFIRMED ou CANCELLED
  -- CONFIRMED -> SHIPPED ou CANCELLED
  -- SHIPPED -> DELIVERED
  -- DELIVERED e CANCELLED são estados finais

  if not (
    (v_current_status = 'PENDING'   and p_status in ('CONFIRMED', 'CANCELLED'))
    or
    (v_current_status = 'CONFIRMED' and p_status in ('SHIPPED', 'CANCELLED'))
    or
    (v_current_status = 'SHIPPED'   and p_status = 'DELIVERED')
  ) then
    raise exception
      'Transição de status inválida: % -> %',
      v_current_status,
      p_status;
  end if;

  update public.shop_orders
  set status = p_status
  where id = p_order_id;
end;
$$;

revoke all on function public.admin_update_shop_order_status(
  uuid,
  public.order_status
) from public;

grant execute on function public.admin_update_shop_order_status(
  uuid,
  public.order_status
) to authenticated;