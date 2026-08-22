create extension if not exists pgcrypto;

alter table if exists public.marketplace_orders
  alter column id set default gen_random_uuid();

alter table if exists public.marketplace_order_items
  alter column id set default gen_random_uuid();

create or replace function public.lavida_is_valid_crypto_wallet(
  p_network_code text,
  p_network_name text,
  p_wallet text
)
returns boolean
language plpgsql
immutable
as $$
declare
  v_network text := upper(coalesce(p_network_code, '') || ' ' || coalesce(p_network_name, ''));
  v_wallet text := trim(coalesce(p_wallet, ''));
begin
  if v_wallet = '' or length(v_wallet) > 128 or v_wallet ~ '[[:space:]]' then
    return false;
  end if;

  if v_network ~ '(^|[^A-Z0-9])(TRON|TRC20|TRX)([^A-Z0-9]|$)' then
    return v_wallet ~ '^T[1-9A-HJ-NP-Za-km-z]{33}$';
  end if;

  if v_network ~ '(^|[^A-Z0-9])(ETH|ETHEREUM|ERC[-_ ]?20|ERIC20|BEP[-_ ]?20|BSC|BNB|POLYGON|MATIC|AVAX|AVALANCHE|BASE|ARBITRUM|OPTIMISM)([^A-Z0-9]|$)' then
    return v_wallet ~ '^0x[0-9A-Fa-f]{40}$';
  end if;

  if v_network ~ '(^|[^A-Z0-9])(BTC|BITCOIN)([^A-Z0-9]|$)' then
    return v_wallet ~* '^(bc1[ac-hj-np-z02-9]{11,87}|[13][1-9A-HJ-NP-Za-km-z]{25,34})$';
  end if;

  if v_network ~ '(^|[^A-Z0-9])(SOL|SOLANA)([^A-Z0-9]|$)' then
    return v_wallet ~ '^[1-9A-HJ-NP-Za-km-z]{32,44}$';
  end if;

  return length(v_wallet) >= 8;
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
  v_product_json jsonb;
  v_asset public.crypto_assets%rowtype;
  v_network public.crypto_asset_networks%rowtype;
  v_fee jsonb;
  v_order public.marketplace_orders%rowtype;
  v_existing_order public.marketplace_orders%rowtype;
  v_order_id uuid := gen_random_uuid();
  v_item_id uuid := gen_random_uuid();
  v_product_id uuid := (p_order ->> 'product_id')::uuid;
  v_network_id uuid := (p_order ->> 'network_id')::uuid;
  v_receive_amount numeric := (p_order ->> 'receive_amount')::numeric;
  v_wallet_address text := trim(coalesce(p_order ->> 'wallet_address', ''));
  v_idempotency_key text := nullif(trim(coalesce(p_order ->> 'idempotency_key', '')), '');
  v_existing_order_id uuid;
  v_inserted_idempotency integer := 0;
  v_available_text text;
  v_available_amount numeric;
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

  if to_regclass('public.crypto_order_idempotency_keys') is not null and v_idempotency_key is not null then
    insert into public.crypto_order_idempotency_keys(idempotency_key)
    values (v_idempotency_key)
    on conflict (idempotency_key) do nothing;

    get diagnostics v_inserted_idempotency = row_count;

    if v_inserted_idempotency = 0 then
      select order_id
        into v_existing_order_id
      from public.crypto_order_idempotency_keys
      where idempotency_key = v_idempotency_key;

      if v_existing_order_id is not null then
        select *
          into v_existing_order
        from public.marketplace_orders
        where id = v_existing_order_id
        limit 1;

        if v_existing_order.id is not null then
          return jsonb_build_object(
            'success', true,
            'id', v_existing_order.id,
            'order_id', v_existing_order.id,
            'order_reference', v_existing_order.order_reference,
            'order_status', v_existing_order.order_status,
            'payment_status', v_existing_order.payment_status,
            'grand_total', v_existing_order.grand_total,
            'requires_admin_review', false,
            'idempotent_replay', true
          );
        end if;
      end if;

      raise exception 'This order is already being prepared. Please wait a moment.';
    end if;
  end if;

  select * into v_product
  from public.marketplace_products
  where id = v_product_id
  limit 1;
  if not found or coalesce(v_product.published, false) = false then
    raise exception 'This crypto product is not available.';
  end if;

  v_product_json := to_jsonb(v_product);
  v_available_text := coalesce(
    v_product_json ->> 'available_for_new_orders',
    v_product_json ->> 'available_quantity',
    v_product_json ->> 'stock_qty'
  );
  if v_available_text ~ '^[[:space:]]*[0-9]+([.][0-9]+)?[[:space:]]*$' then
    v_available_amount := v_available_text::numeric;
    if v_receive_amount > v_available_amount then
      raise exception 'The requested amount is currently unavailable. Please enter a smaller amount.';
    end if;
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
    raise exception 'This network is not available for this asset. Please select another network.';
  end if;

  if not public.lavida_is_valid_crypto_wallet(v_network.network_code, v_network.network_name, v_wallet_address) then
    raise exception 'Please enter a valid wallet address for the selected network.';
  end if;

  if v_receive_amount < v_asset.minimum_purchase then
    raise exception 'Minimum purchase is % %.', v_asset.minimum_purchase, v_asset.asset_symbol;
  end if;
  if v_asset.maximum_purchase is not null and v_receive_amount > v_asset.maximum_purchase then
    raise exception 'Maximum purchase is % %.', v_asset.maximum_purchase, v_asset.asset_symbol;
  end if;

  v_rate := coalesce(nullif(v_asset.supplier_base_rate_mwk, 0), v_asset.lavida_selling_rate_mwk);
  if v_rate is null or v_rate <= 0 then
    raise exception 'Crypto pricing is not available for this asset.';
  end if;

  v_crypto_value := round(v_receive_amount * v_rate, 2);
  v_fee := public.calculate_crypto_service_fee(v_product_id, v_receive_amount, v_rate);
  v_service_fee_mwk := nullif(v_fee ->> 'fee_mwk', '')::numeric;
  v_service_fee_usdt := nullif(v_fee ->> 'fee_usdt_equivalent', '')::numeric;
  v_total := v_crypto_value + coalesce(v_service_fee_mwk, 0);

  v_order_payload := jsonb_build_object(
    'id', v_order_id,
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

  insert into public.marketplace_orders
  select * from jsonb_populate_record(null::public.marketplace_orders, v_order_payload)
  returning * into v_order;

  if to_regclass('public.crypto_order_idempotency_keys') is not null and v_idempotency_key is not null then
    update public.crypto_order_idempotency_keys
    set order_id = v_order.id
    where idempotency_key = v_idempotency_key;
  end if;

  v_item_payload := jsonb_build_object(
    'id', v_item_id,
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
    'success', true,
    'id', v_order.id,
    'order_id', v_order.id,
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

revoke all on function public.lavida_is_valid_crypto_wallet(text, text, text) from public;
revoke all on function public.submit_crypto_marketplace_order(jsonb) from public;

grant execute on function public.lavida_is_valid_crypto_wallet(text, text, text) to anon, authenticated;
grant execute on function public.submit_crypto_marketplace_order(jsonb) to anon, authenticated;

notify pgrst, 'reload schema';
