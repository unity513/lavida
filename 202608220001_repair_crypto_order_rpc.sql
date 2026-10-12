create extension if not exists pgcrypto;

alter table if exists public.marketplace_orders
  add column if not exists order_type text not null default 'standard',
  add column if not exists service_fee numeric(14,2) not null default 0,
  add column if not exists service_fee_label text,
  add column if not exists idempotency_key text;

do $$
begin
  if not exists (
    select 1
    from public.marketplace_orders
    where idempotency_key is not null
    group by idempotency_key
    having count(*) > 1
  ) then
    create unique index if not exists marketplace_orders_idempotency_key_unique_idx
      on public.marketplace_orders(idempotency_key)
      where idempotency_key is not null;
  end if;
end $$;

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

alter table public.crypto_order_details
  add column if not exists order_id uuid references public.marketplace_orders(id) on delete cascade,
  add column if not exists marketplace_product_id uuid references public.marketplace_products(id),
  add column if not exists asset_id uuid references public.crypto_assets(id),
  add column if not exists network_id uuid references public.crypto_asset_networks(id),
  add column if not exists asset_name text,
  add column if not exists asset_symbol text,
  add column if not exists network_name text,
  add column if not exists network_code text,
  add column if not exists wallet_address text,
  add column if not exists receive_amount numeric(18,8),
  add column if not exists supplier_base_rate_mwk numeric(14,2),
  add column if not exists lavida_selling_rate_mwk numeric(14,2),
  add column if not exists crypto_value_mwk numeric(14,2),
  add column if not exists service_fee_usdt_equivalent numeric(18,8),
  add column if not exists service_fee_mwk numeric(14,2),
  add column if not exists total_payable_mwk numeric(14,2),
  add column if not exists requires_admin_review boolean not null default false,
  add column if not exists crypto_status text not null default 'pending_payment',
  add column if not exists tx_hash text,
  add column if not exists amount_sent numeric(18,8),
  add column if not exists sent_network text,
  add column if not exists sent_at timestamptz,
  add column if not exists admin_notes text,
  add column if not exists created_at timestamptz not null default now(),
  add column if not exists updated_at timestamptz not null default now();

create unique index if not exists crypto_order_details_order_unique_idx
  on public.crypto_order_details(order_id);

alter table public.crypto_order_details enable row level security;

drop policy if exists "Admins read crypto order details" on public.crypto_order_details;
create policy "Admins read crypto order details"
  on public.crypto_order_details for select
  using (public.lavida_is_marketplace_admin());

grant select on public.crypto_order_details to authenticated;

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

  if not found or v_range.requires_admin_review then
    return jsonb_build_object(
      'range_id', case when found then v_range.id else null end,
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
  v_product_id uuid := (p_order ->> 'product_id')::uuid;
  v_network_id uuid := (p_order ->> 'network_id')::uuid;
  v_receive_amount numeric := (p_order ->> 'receive_amount')::numeric;
  v_wallet_address text := trim(coalesce(p_order ->> 'wallet_address', ''));
  v_idempotency_key text := nullif(trim(coalesce(p_order ->> 'idempotency_key', '')), '');
  v_rate numeric;
  v_crypto_value numeric;
  v_service_fee_mwk numeric;
  v_service_fee_usdt numeric;
  v_total numeric;
  v_reference text := 'LC-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10));
  v_order_payload jsonb;
  v_item_payload jsonb;
  v_has_order_idempotency boolean := false;
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

  select exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'marketplace_orders'
      and column_name = 'idempotency_key'
  ) into v_has_order_idempotency;

  if v_has_order_idempotency and v_idempotency_key is not null then
    execute 'select * from public.marketplace_orders where idempotency_key = $1 limit 1'
      into v_order
      using v_idempotency_key;
    if v_order.id is not null then
      return jsonb_build_object(
        'id', v_order.id,
        'order_reference', v_order.order_reference,
        'order_status', v_order.order_status,
        'payment_status', v_order.payment_status,
        'grand_total', v_order.grand_total,
        'requires_admin_review', false,
        'idempotent_replay', true
      );
    end if;
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
    'customer_name', trim(coalesce(p_order ->> 'customer_name', '')),
    'phone', trim(coalesce(p_order ->> 'phone', '')),
    'email', nullif(trim(coalesce(p_order ->> 'email', '')), ''),
    'fulfilment_method', 'crypto_wallet',
    'delivery_address', v_wallet_address,
    'delivery_notes', 'Crypto network: ' || v_network.network_name,
    'payment_method', coalesce(nullif(trim(coalesce(p_order ->> 'payment_method', '')), ''), 'airtel_money'),
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
    'idempotency_key', v_idempotency_key,
    'created_at', now(),
    'updated_at', now()
  );

  begin
    insert into public.marketplace_orders
    select * from jsonb_populate_record(null::public.marketplace_orders, v_order_payload)
    returning * into v_order;
  exception
    when unique_violation then
      if v_has_order_idempotency and v_idempotency_key is not null then
        execute 'select * from public.marketplace_orders where idempotency_key = $1 limit 1'
          into v_order
          using v_idempotency_key;
        if v_order.id is not null then
          return jsonb_build_object(
            'id', v_order.id,
            'order_reference', v_order.order_reference,
            'order_status', v_order.order_status,
            'payment_status', v_order.payment_status,
            'grand_total', v_order.grand_total,
            'requires_admin_review', false,
            'idempotent_replay', true
          );
        end if;
      end if;
      raise;
  end;

  v_item_payload := jsonb_build_object(
    'order_id', v_order.id,
    'marketplace_order_id', v_order.id,
    'product_id', v_product_id,
    'marketplace_product_id', v_product_id,
    'product_name', v_asset.asset_name || ' / ' || v_asset.asset_symbol,
    'name', v_asset.asset_name || ' / ' || v_asset.asset_symbol,
    'quantity', v_receive_amount,
    'unit', v_asset.asset_symbol,
    'unit_price', v_rate,
    'price', v_rate,
    'line_total', v_crypto_value,
    'total', v_crypto_value,
    'subtotal', v_crypto_value,
    'created_at', now()
  );

  insert into public.marketplace_order_items
  select * from jsonb_populate_record(null::public.marketplace_order_items, v_item_payload);

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
  )
  on conflict (order_id) do nothing;

  return jsonb_build_object(
    'id', v_order.id,
    'order_reference', v_order.order_reference,
    'order_status', v_order.order_status,
    'payment_status', v_order.payment_status,
    'grand_total', v_total,
    'crypto_value_mwk', v_crypto_value,
    'service_fee_mwk', v_service_fee_mwk,
    'service_fee_usdt_equivalent', v_service_fee_usdt,
    'requires_admin_review', coalesce((v_fee ->> 'requires_admin_review')::boolean, false),
    'idempotent_replay', false
  );
end;
$$;

revoke all on function public.calculate_crypto_service_fee(uuid, numeric, numeric) from public;
revoke all on function public.submit_crypto_marketplace_order(jsonb) from public;

grant execute on function public.calculate_crypto_service_fee(uuid, numeric, numeric) to anon, authenticated;
grant execute on function public.submit_crypto_marketplace_order(jsonb) to anon, authenticated;

notify pgrst, 'reload schema';
