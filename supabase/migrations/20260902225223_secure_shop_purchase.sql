-- ============================================================
-- CRAVAÍ - LOJA SEGURA
-- Compra atômica usando SOMENTE CP normal (public.wallets)
-- ============================================================


-- ============================================================
-- 1. FECHAR PERMISSÕES DIRETAS
-- ============================================================

revoke all on table public.shop_items from anon, authenticated;
revoke all on table public.shop_orders from anon, authenticated;

-- Vitrine: todos podem consultar os produtos permitidos pela RLS.
grant select on table public.shop_items to anon, authenticated;

-- Pedidos: somente usuários autenticados podem consultar.
-- A RLS limita a consulta aos próprios pedidos.
grant select on table public.shop_orders to authenticated;


-- ============================================================
-- 2. POLÍTICAS RLS
-- ============================================================

drop policy if exists shop_select on public.shop_items;
drop policy if exists orders_select on public.shop_orders;

create policy shop_items_select_active
on public.shop_items
for select
to anon, authenticated
using (active = true);

create policy shop_orders_select_own
on public.shop_orders
for select
to authenticated
using (user_id = auth.uid());


-- ============================================================
-- 3. FUNÇÃO SEGURA DE COMPRA
-- ============================================================

create or replace function public.purchase_shop_item(
  p_item_id uuid,
  p_quantity integer,
  p_shipping_info jsonb default null
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_user_id uuid;
  v_item public.shop_items%rowtype;
  v_balance numeric(14,2);
  v_total numeric(14,2);
  v_order_id uuid;
begin
  v_user_id := auth.uid();

  if v_user_id is null then
    raise exception 'Usuário não autenticado';
  end if;

  if p_item_id is null then
    raise exception 'Produto inválido';
  end if;

  if p_quantity is null or p_quantity <= 0 then
    raise exception 'Quantidade inválida';
  end if;

  -- Limite defensivo contra quantidades absurdas.
  if p_quantity > 100 then
    raise exception 'Quantidade máxima por compra é 100';
  end if;

  -- Trava o produto para evitar duas compras consumirem
  -- o mesmo estoque simultaneamente.
  select *
    into v_item
  from public.shop_items
  where id = p_item_id
  for update;

  if not found then
    raise exception 'Produto não encontrado';
  end if;

  if v_item.active is not true then
    raise exception 'Produto indisponível';
  end if;

  if v_item.price_cp is null or v_item.price_cp < 0 then
    raise exception 'Preço do produto inválido';
  end if;

  -- stock NULL significa estoque não limitado.
  if v_item.stock is not null and v_item.stock < p_quantity then
    raise exception 'Estoque insuficiente';
  end if;

  -- O preço é calculado exclusivamente no servidor.
  v_total := round(v_item.price_cp * p_quantity, 2);

  -- Trava somente a carteira NORMAL do usuário.
  select balance_cp
    into v_balance
  from public.wallets
  where user_id = v_user_id
  for update;

  if not found then
    raise exception 'Carteira não encontrada';
  end if;

  if v_balance < v_total then
    raise exception 'Saldo de CP insuficiente';
  end if;

  -- Debita SOMENTE CP normal.
  update public.wallets
  set balance_cp = balance_cp - v_total
  where user_id = v_user_id
  returning balance_cp into v_balance;

  -- Desconta estoque somente quando ele é controlado.
  if v_item.stock is not null then
    update public.shop_items
    set stock = stock - p_quantity
    where id = v_item.id;
  end if;

  -- Cria o pedido.
  insert into public.shop_orders (
    user_id,
    item_id,
    quantity,
    total_cp,
    status,
    shipping_info
  )
  values (
    v_user_id,
    v_item.id,
    p_quantity,
    v_total,
    'PENDING'::public.order_status,
    p_shipping_info
  )
  returning id into v_order_id;

  -- Registra o movimento da carteira normal.
  insert into public.transactions (
    user_id,
    type,
    amount,
    balance_after,
    reference_id,
    description
  )
  values (
    v_user_id,
    'purchase'::public.transaction_type,
    -v_total,
    v_balance,
    v_order_id,
    'Compra na Loja CravaAí'
  );

  return v_order_id;
end;
$$;


-- ============================================================
-- 4. PERMISSÕES DA FUNÇÃO
-- ============================================================

revoke all on function public.purchase_shop_item(uuid, integer, jsonb)
from public, anon, authenticated;

grant execute on function public.purchase_shop_item(uuid, integer, jsonb)
to authenticated;