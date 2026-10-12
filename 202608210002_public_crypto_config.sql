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
  select *
  into v_asset
  from public.crypto_assets
  where is_active = true
    and (
      marketplace_product_id = p_marketplace_product_id
      or (v_symbol is not null and upper(asset_symbol) = v_symbol)
    )
  order by
    case when marketplace_product_id = p_marketplace_product_id then 0 else 1 end,
    updated_at desc nulls last,
    created_at desc
  limit 1;

  if not found then
    return jsonb_build_object('asset', null, 'networks', '[]'::jsonb);
  end if;

  return jsonb_build_object(
    'asset', to_jsonb(v_asset),
    'networks', coalesce(
      (
        select jsonb_agg(to_jsonb(n) order by n.sort_order, n.network_name)
        from public.crypto_asset_networks n
        where n.asset_id = v_asset.id
          and n.is_enabled = true
      ),
      '[]'::jsonb
    )
  );
end;
$$;

revoke all on function public.get_public_crypto_asset_config(uuid, text) from public;
grant execute on function public.get_public_crypto_asset_config(uuid, text) to anon, authenticated;
