create extension if not exists pgcrypto;

create or replace function public.lavida_is_marketplace_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.user_roles ur
    where lower(ur.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
      and ur.active = true
      and lower(ur.role) in ('owner','admin','executive','manager')
  );
$$;

alter table if exists public.marketplace_orders
  add column if not exists order_type text not null default 'standard',
  add column if not exists service_fee numeric(14,2) not null default 0,
  add column if not exists service_fee_label text;

create table if not exists public.crypto_assets (
  id uuid primary key default gen_random_uuid(),
  marketplace_product_id uuid references public.marketplace_products(id) on delete set null,
  asset_name text not null,
  asset_symbol text not null,
  supplier_base_rate_mwk numeric(14,2) not null default 0,
  lavida_selling_rate_mwk numeric(14,2) not null default 0,
  rate_currency text not null default 'MWK',
  minimum_purchase numeric(18,8) not null default 1,
  maximum_purchase numeric(18,8),
  availability_status text not null default 'available',
  is_active boolean not null default true,
  created_by uuid,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint crypto_assets_symbol_not_blank check (length(trim(asset_symbol)) > 0),
  constraint crypto_assets_rate_currency_mwk check (rate_currency = 'MWK'),
  constraint crypto_assets_rates_non_negative check (supplier_base_rate_mwk >= 0 and lavida_selling_rate_mwk >= 0),
  constraint crypto_assets_purchase_bounds check (minimum_purchase > 0 and (maximum_purchase is null or maximum_purchase >= minimum_purchase))
);

create unique index if not exists crypto_assets_product_unique_idx
  on public.crypto_assets(marketplace_product_id)
  where marketplace_product_id is not null;

create index if not exists crypto_assets_symbol_idx
  on public.crypto_assets(lower(asset_symbol));

create unique index if not exists crypto_assets_default_symbol_unique_idx
  on public.crypto_assets(lower(asset_symbol))
  where marketplace_product_id is null;

create table if not exists public.crypto_asset_networks (
  id uuid primary key default gen_random_uuid(),
  asset_id uuid not null references public.crypto_assets(id) on delete cascade,
  network_name text not null,
  network_code text not null,
  is_enabled boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint crypto_asset_networks_name_not_blank check (length(trim(network_name)) > 0),
  constraint crypto_asset_networks_code_not_blank check (length(trim(network_code)) > 0),
  unique(asset_id, network_code)
);

create table if not exists public.crypto_fee_ranges (
  id uuid primary key default gen_random_uuid(),
  marketplace_product_id uuid references public.marketplace_products(id) on delete cascade,
  amount_min numeric(18,8) not null,
  amount_max numeric(18,8),
  fee_usdt_equivalent numeric(18,8),
  requires_admin_review boolean not null default false,
  is_enabled boolean not null default true,
  sort_order integer not null default 0,
  created_by uuid,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint crypto_fee_ranges_bounds check (amount_min >= 0 and (amount_max is null or amount_max >= amount_min)),
  constraint crypto_fee_ranges_fee check (requires_admin_review = true or coalesce(fee_usdt_equivalent, 0) >= 0)
);

create index if not exists crypto_fee_ranges_product_idx
  on public.crypto_fee_ranges(marketplace_product_id, is_enabled, amount_min);

create unique index if not exists crypto_fee_ranges_default_unique_idx
  on public.crypto_fee_ranges(amount_min, coalesce(amount_max, -1))
  where marketplace_product_id is null;

create table if not exists public.crypto_order_details (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.marketplace_orders(id) on delete cascade,
  marketplace_product_id uuid references public.marketplace_products(id),
  asset_id uuid references public.crypto_assets(id),
  network_id uuid references public.crypto_asset_networks(id),
  asset_name text not null,
  asset_symbol text not null,
  network_name text not null,
  network_code text not null,
  wallet_address text not null,
  receive_amount numeric(18,8) not null,
  supplier_base_rate_mwk numeric(14,2) not null,
  lavida_selling_rate_mwk numeric(14,2) not null,
  crypto_value_mwk numeric(14,2) not null,
  service_fee_usdt_equivalent numeric(18,8),
  service_fee_mwk numeric(14,2),
  total_payable_mwk numeric(14,2) not null,
  requires_admin_review boolean not null default false,
  crypto_status text not null default 'pending_payment',
  tx_hash text,
  amount_sent numeric(18,8),
  sent_network text,
  sent_at timestamptz,
  admin_notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint crypto_order_details_receive_amount_positive check (receive_amount > 0)
);

create unique index if not exists crypto_order_details_order_unique_idx
  on public.crypto_order_details(order_id);

alter table public.crypto_assets enable row level security;
alter table public.crypto_asset_networks enable row level security;
alter table public.crypto_fee_ranges enable row level security;
alter table public.crypto_order_details enable row level security;

drop policy if exists "Public can read active crypto assets" on public.crypto_assets;
create policy "Public can read active crypto assets"
  on public.crypto_assets for select
  using (is_active = true);

drop policy if exists "Admins manage crypto assets" on public.crypto_assets;
create policy "Admins manage crypto assets"
  on public.crypto_assets for all
  using (public.lavida_is_marketplace_admin())
  with check (public.lavida_is_marketplace_admin());

drop policy if exists "Public can read enabled crypto networks" on public.crypto_asset_networks;
create policy "Public can read enabled crypto networks"
  on public.crypto_asset_networks for select
  using (is_enabled = true);

drop policy if exists "Admins manage crypto networks" on public.crypto_asset_networks;
create policy "Admins manage crypto networks"
  on public.crypto_asset_networks for all
  using (public.lavida_is_marketplace_admin())
  with check (public.lavida_is_marketplace_admin());

drop policy if exists "Public can read enabled crypto fee ranges" on public.crypto_fee_ranges;
create policy "Public can read enabled crypto fee ranges"
  on public.crypto_fee_ranges for select
  using (is_enabled = true);

drop policy if exists "Admins manage crypto fee ranges" on public.crypto_fee_ranges;
create policy "Admins manage crypto fee ranges"
  on public.crypto_fee_ranges for all
  using (public.lavida_is_marketplace_admin())
  with check (public.lavida_is_marketplace_admin());

drop policy if exists "Admins read crypto order details" on public.crypto_order_details;
create policy "Admins read crypto order details"
  on public.crypto_order_details for select
  using (public.lavida_is_marketplace_admin());

grant select on public.crypto_assets, public.crypto_asset_networks, public.crypto_fee_ranges to anon, authenticated;
grant select, insert, update, delete on public.crypto_assets, public.crypto_asset_networks, public.crypto_fee_ranges to authenticated;
grant select on public.crypto_order_details to authenticated;

insert into public.crypto_assets (asset_name, asset_symbol, rate_currency, minimum_purchase, maximum_purchase, availability_status, is_active)
values
  ('Tether USD', 'USDT', 'MWK', 1, null, 'available', true),
  ('USD Coin', 'USDC', 'MWK', 1, null, 'available', true),
  ('Bitcoin', 'BTC', 'MWK', 0.00000001, null, 'available', true),
  ('Ethereum', 'ETH', 'MWK', 0.00000001, null, 'available', true),
  ('BNB', 'BNB', 'MWK', 0.00000001, null, 'available', true),
  ('Solana', 'SOL', 'MWK', 0.00000001, null, 'available', true),
  ('TRON', 'TRX', 'MWK', 0.00000001, null, 'available', true),
  ('Polygon', 'POL', 'MWK', 0.00000001, null, 'available', true),
  ('KERNEL', 'KERNEL', 'MWK', 1, null, 'available', true)
on conflict do nothing;

insert into public.crypto_fee_ranges (marketplace_product_id, amount_min, amount_max, fee_usdt_equivalent, requires_admin_review, is_enabled, sort_order)
values
  (null, 1, 50, 1, false, true, 10),
  (null, 51, 100, 2, false, true, 20),
  (null, 101, 250, 3, false, true, 30),
  (null, 251, 500, 5, false, true, 40),
  (null, 501, 1000, 8, false, true, 50),
  (null, 1000.00000001, null, null, true, true, 60)
on conflict do nothing;

insert into public.marketplace_categories (name, sort_order, is_active)
values ('Crypto', 35, true)
on conflict do nothing;

create or replace function public.calculate_crypto_service_fee(
  p_marketplace_product_id uuid,
  p_receive_amount numeric,
  p_rate_mwk numeric
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_range public.crypto_fee_ranges%rowtype;
  v_has_product_ranges boolean := false;
  v_fee_usdt numeric := 0;
  v_fee_mwk numeric := 0;
begin
  if p_receive_amount is null or p_receive_amount <= 0 then
    raise exception 'Crypto receive amount must be greater than zero.';
  end if;

  select exists (
    select 1
    from public.crypto_fee_ranges
    where marketplace_product_id = p_marketplace_product_id
      and is_enabled = true
  ) into v_has_product_ranges;

  select *
  into v_range
  from public.crypto_fee_ranges
  where is_enabled = true
    and (
      (v_has_product_ranges = true and marketplace_product_id = p_marketplace_product_id)
      or (v_has_product_ranges = false and marketplace_product_id is null)
    )
    and p_receive_amount >= amount_min
    and (amount_max is null or p_receive_amount <= amount_max)
  order by amount_min desc, sort_order asc
  limit 1;

  if not found then
    return jsonb_build_object(
      'range_id', null,
      'requires_admin_review', true,
      'fee_usdt_equivalent', null,
      'fee_mwk', null,
      'label', 'Manual/Admin review'
    );
  end if;

  if v_range.requires_admin_review then
    return jsonb_build_object(
      'range_id', v_range.id,
      'requires_admin_review', true,
      'fee_usdt_equivalent', null,
      'fee_mwk', null,
      'label', 'Manual/Admin review'
    );
  end if;

  v_fee_usdt := coalesce(v_range.fee_usdt_equivalent, 0);
  v_fee_mwk := round(v_fee_usdt * coalesce(p_rate_mwk, 0), 2);

  return jsonb_build_object(
    'range_id', v_range.id,
    'requires_admin_review', false,
    'fee_usdt_equivalent', v_fee_usdt,
    'fee_mwk', v_fee_mwk,
    'label', trim(to_char(v_fee_usdt, 'FM999999999990.########')) || ' USDT'
  );
end;
$$;

create or replace function public.submit_crypto_marketplace_order(p_order jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_product public.marketplace_products%rowtype;
  v_asset public.crypto_assets%rowtype;
  v_network public.crypto_asset_networks%rowtype;
  v_fee jsonb;
  v_order public.marketplace_orders%rowtype;
  v_item public.marketplace_order_items%rowtype;
  v_product_id uuid := (p_order ->> 'product_id')::uuid;
  v_network_id uuid := (p_order ->> 'network_id')::uuid;
  v_receive_amount numeric := (p_order ->> 'receive_amount')::numeric;
  v_wallet_address text := trim(p_order ->> 'wallet_address');
  v_rate numeric;
  v_crypto_value numeric;
  v_service_fee_mwk numeric;
  v_service_fee_usdt numeric;
  v_total numeric;
  v_reference text := 'LC-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10));
  v_order_payload jsonb;
  v_item_payload jsonb;
begin
  if v_product_id is null then
    raise exception 'Crypto product is required.';
  end if;
  if v_network_id is null then
    raise exception 'Crypto network is required.';
  end if;
  if v_receive_amount is null or v_receive_amount <= 0 then
    raise exception 'Crypto receive amount must be greater than zero.';
  end if;
  if length(v_wallet_address) < 8 then
    raise exception 'Wallet address is required.';
  end if;

  select * into v_product
  from public.marketplace_products
  where id = v_product_id
  limit 1;
  if not found or coalesce(v_product.published, false) = false then
    raise exception 'This crypto product is not available.';
  end if;

  select * into v_asset
  from public.crypto_assets
  where marketplace_product_id = v_product_id
    and is_active = true
    and availability_status in ('available','active','published')
  limit 1;
  if not found then
    raise exception 'Crypto settings are missing for this product.';
  end if;

  select * into v_network
  from public.crypto_asset_networks
  where id = v_network_id
    and asset_id = v_asset.id
    and is_enabled = true
  limit 1;
  if not found then
    raise exception 'Selected network is not available for this asset.';
  end if;

  if v_receive_amount < v_asset.minimum_purchase then
    raise exception 'Minimum purchase is % %.', v_asset.minimum_purchase, v_asset.asset_symbol;
  end if;
  if v_asset.maximum_purchase is not null and v_receive_amount > v_asset.maximum_purchase then
    raise exception 'Maximum purchase is % %.', v_asset.maximum_purchase, v_asset.asset_symbol;
  end if;

  v_rate := v_asset.supplier_base_rate_mwk;
  v_crypto_value := round(v_receive_amount * v_rate, 2);
  v_fee := public.calculate_crypto_service_fee(v_product_id, v_receive_amount, v_rate);
  v_service_fee_mwk := nullif(v_fee ->> 'fee_mwk', '')::numeric;
  v_service_fee_usdt := nullif(v_fee ->> 'fee_usdt_equivalent', '')::numeric;
  v_total := v_crypto_value + coalesce(v_service_fee_mwk, 0);

  v_order_payload := jsonb_build_object(
    'order_reference', v_reference,
    'customer_name', trim(p_order ->> 'customer_name'),
    'phone', trim(p_order ->> 'phone'),
    'email', nullif(trim(coalesce(p_order ->> 'email', '')), ''),
    'fulfilment_method', 'crypto_wallet',
    'delivery_address', v_wallet_address,
    'delivery_notes', 'Crypto network: ' || v_network.network_name,
    'payment_method', coalesce(nullif(trim(p_order ->> 'payment_method'), ''), 'airtel_money'),
    'payment_reference', nullif(trim(coalesce(p_order ->> 'payment_reference', '')), ''),
    'payment_proof_url', nullif(trim(coalesce(p_order ->> 'payment_proof_url', '')), ''),
    'payment_status', 'pending_confirmation',
    'order_status', 'pending_confirmation',
    'subtotal', v_crypto_value,
    'delivery_fee', 0,
    'service_fee', coalesce(v_service_fee_mwk, 0),
    'service_fee_label', coalesce(v_fee ->> 'label', 'Manual/Admin review'),
    'grand_total', v_total,
    'order_type', 'crypto',
    'source_device_id', nullif(trim(coalesce(p_order ->> 'source_device_id', '')), ''),
    'idempotency_key', nullif(trim(coalesce(p_order ->> 'idempotency_key', '')), ''),
    'created_at', now(),
    'updated_at', now()
  );

  insert into public.marketplace_orders
  select * from jsonb_populate_record(null::public.marketplace_orders, v_order_payload)
  returning * into v_order;

  v_item_payload := jsonb_build_object(
    'order_id', v_order.id,
    'product_id', v_product_id,
    'product_name', v_asset.asset_name || ' / ' || v_asset.asset_symbol,
    'quantity', v_receive_amount,
    'unit', v_asset.asset_symbol,
    'unit_price', v_rate,
    'line_total', v_crypto_value,
    'created_at', now()
  );

  insert into public.marketplace_order_items
  select * from jsonb_populate_record(null::public.marketplace_order_items, v_item_payload)
  returning * into v_item;

  insert into public.crypto_order_details (
    order_id, marketplace_product_id, asset_id, network_id, asset_name, asset_symbol,
    network_name, network_code, wallet_address, receive_amount, supplier_base_rate_mwk,
    lavida_selling_rate_mwk, crypto_value_mwk, service_fee_usdt_equivalent, service_fee_mwk,
    total_payable_mwk, requires_admin_review, crypto_status
  )
  values (
    v_order.id, v_product_id, v_asset.id, v_network.id, v_asset.asset_name, v_asset.asset_symbol,
    v_network.network_name, v_network.network_code, v_wallet_address, v_receive_amount, v_rate,
    v_rate, v_crypto_value, v_service_fee_usdt, v_service_fee_mwk,
    v_total, coalesce((v_fee ->> 'requires_admin_review')::boolean, false), 'pending_payment'
  );

  return jsonb_build_object(
    'id', v_order.id,
    'order_reference', v_order.order_reference,
    'order_status', v_order.order_status,
    'payment_status', v_order.payment_status,
    'grand_total', v_total,
    'crypto_value_mwk', v_crypto_value,
    'service_fee_mwk', v_service_fee_mwk,
    'service_fee_usdt_equivalent', v_service_fee_usdt,
    'requires_admin_review', coalesce((v_fee ->> 'requires_admin_review')::boolean, false)
  );
end;
$$;

create or replace function public.get_crypto_order_details(p_order_id uuid, p_phone text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_result jsonb;
begin
  select to_jsonb(cod)
  into v_result
  from public.crypto_order_details cod
  join public.marketplace_orders mo on mo.id = cod.order_id
  where cod.order_id = p_order_id
    and (
      public.lavida_is_marketplace_admin()
      or p_phone is null
      or regexp_replace(coalesce(mo.phone, ''), '\D', '', 'g') = regexp_replace(coalesce(p_phone, ''), '\D', '', 'g')
    )
  limit 1;

  return v_result;
end;
$$;

create or replace function public.mark_crypto_order_sent(
  p_order_id uuid,
  p_tx_hash text,
  p_amount_sent numeric,
  p_network text,
  p_sent_at timestamptz default now(),
  p_admin_notes text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.lavida_is_marketplace_admin() then
    raise exception 'Access denied.';
  end if;
  if trim(coalesce(p_tx_hash, '')) = '' then
    raise exception 'Transaction hash / TXID is required.';
  end if;
  if p_amount_sent is null or p_amount_sent <= 0 then
    raise exception 'Amount sent must be greater than zero.';
  end if;

  update public.crypto_order_details
  set tx_hash = trim(p_tx_hash),
      amount_sent = p_amount_sent,
      sent_network = nullif(trim(coalesce(p_network, '')), ''),
      sent_at = coalesce(p_sent_at, now()),
      admin_notes = p_admin_notes,
      crypto_status = 'crypto_sent',
      updated_at = now()
  where order_id = p_order_id;

  update public.marketplace_orders
  set order_status = 'crypto_sent',
      updated_at = now()
  where id = p_order_id;
end;
$$;

create or replace function public.complete_crypto_order(
  p_order_id uuid,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.lavida_is_marketplace_admin() then
    raise exception 'Access denied.';
  end if;

  update public.crypto_order_details
  set crypto_status = 'completed',
      admin_notes = coalesce(nullif(trim(coalesce(p_reason, '')), ''), admin_notes),
      updated_at = now()
  where order_id = p_order_id;

  update public.marketplace_orders
  set order_status = 'completed',
      updated_at = now()
  where id = p_order_id;
end;
$$;

revoke all on function public.calculate_crypto_service_fee(uuid, numeric, numeric) from public;
revoke all on function public.submit_crypto_marketplace_order(jsonb) from public;
revoke all on function public.get_crypto_order_details(uuid, text) from public;
revoke all on function public.mark_crypto_order_sent(uuid, text, numeric, text, timestamptz, text) from public;
revoke all on function public.complete_crypto_order(uuid, text) from public;

grant execute on function public.calculate_crypto_service_fee(uuid, numeric, numeric) to anon, authenticated;
grant execute on function public.submit_crypto_marketplace_order(jsonb) to anon, authenticated;
grant execute on function public.get_crypto_order_details(uuid, text) to anon, authenticated;
grant execute on function public.mark_crypto_order_sent(uuid, text, numeric, text, timestamptz, text) to authenticated;
grant execute on function public.complete_crypto_order(uuid, text) to authenticated;
