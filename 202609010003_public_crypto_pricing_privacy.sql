create or replace function public.get_public_crypto_asset_config(
  p_marketplace_product_id uuid,
  p_asset_symbol text default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_asset public.crypto_assets%rowtype;
  v_symbol text := upper(nullif(trim(coalesce(p_asset_symbol, '')), ''));
begin
  select * into v_asset
  from public.crypto_assets
  where is_active = true
    and (marketplace_product_id = p_marketplace_product_id or (v_symbol is not null and upper(asset_symbol) = v_symbol))
  order by case when marketplace_product_id = p_marketplace_product_id then 0 else 1 end,
           updated_at desc nulls last, created_at desc
  limit 1;

  if not found then return jsonb_build_object('asset', null, 'networks', '[]'::jsonb); end if;

  return jsonb_build_object(
    'asset', jsonb_build_object(
      'id', v_asset.id, 'marketplace_product_id', v_asset.marketplace_product_id,
      'asset_name', v_asset.asset_name, 'asset_symbol', v_asset.asset_symbol,
      'lavida_selling_rate_mwk', v_asset.lavida_selling_rate_mwk,
      'rate_currency', v_asset.rate_currency, 'minimum_purchase', v_asset.minimum_purchase,
      'maximum_purchase', v_asset.maximum_purchase, 'availability_status', v_asset.availability_status,
      'is_active', v_asset.is_active, 'updated_at', v_asset.updated_at
    ),
    'networks', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', n.id, 'asset_id', n.asset_id, 'network_name', n.network_name,
        'network_code', n.network_code, 'is_enabled', n.is_enabled, 'sort_order', n.sort_order
      ) order by n.sort_order, n.network_name)
      from public.crypto_asset_networks n where n.asset_id = v_asset.id and n.is_enabled = true
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function public.get_crypto_asset_admin(p_marketplace_product_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare v_asset public.crypto_assets%rowtype;
begin
  if not public.lavida_is_marketplace_admin() then raise exception 'Access denied.' using errcode = '42501'; end if;
  select * into v_asset from public.crypto_assets where marketplace_product_id = p_marketplace_product_id limit 1;
  return case when found then to_jsonb(v_asset) else null end;
end;
$$;

revoke select on public.crypto_assets from anon, authenticated;
grant select (
  id, marketplace_product_id, asset_name, asset_symbol, lavida_selling_rate_mwk,
  rate_currency, minimum_purchase, maximum_purchase, availability_status,
  is_active, created_at, updated_at
) on public.crypto_assets to anon, authenticated;

revoke all on function public.get_public_crypto_asset_config(uuid,text) from public;
revoke all on function public.get_crypto_asset_admin(uuid) from public;
grant execute on function public.get_public_crypto_asset_config(uuid,text) to anon, authenticated;
grant execute on function public.get_crypto_asset_admin(uuid) to authenticated;
