create or replace function public.get_payments_pricing_admin_bundle()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.lavida_is_payment_admin() then
    raise exception 'Access denied.' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'payment_methods', coalesce((
      select jsonb_agg(to_jsonb(pm) order by pm.display_order, pm.display_name)
      from public.payment_methods pm
    ), '[]'::jsonb),
    'printing_prices', case when to_regclass('public.printing_service_prices') is null then '[]'::jsonb else coalesce((
      select jsonb_agg(to_jsonb(pp) order by pp.service_code, pp.display_name)
      from public.printing_service_prices pp
    ), '[]'::jsonb) end,
    'pricing_settings', coalesce((
      select jsonb_agg(to_jsonb(ps) order by ps.section, ps.display_order, ps.display_name)
      from public.lavida_pricing_settings ps
    ), '[]'::jsonb),
    'marketplace_products', case when to_regclass('public.marketplace_products') is null then '[]'::jsonb else coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', mp.id, 'name', mp.name, 'category', mp.category,
        'selling_price', mp.selling_price, 'unit', mp.unit,
        'published', mp.published, 'status', mp.status, 'updated_at', mp.updated_at
      ) order by mp.name)
      from public.marketplace_products mp
    ), '[]'::jsonb) end,
    'crypto_assets', case when to_regclass('public.crypto_assets') is null then '[]'::jsonb else coalesce((
      select jsonb_agg(to_jsonb(ca) order by ca.asset_name)
      from public.crypto_assets ca
    ), '[]'::jsonb) end,
    'history', coalesce((
      select jsonb_agg(to_jsonb(h) order by h.changed_at desc)
      from (
        select id, entity_type, entity_id, action, changed_by, changed_at
        from public.lavida_configuration_history
        order by changed_at desc
        limit 100
      ) h
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function public.save_printing_price_admin(
  p_id uuid,
  p_display_name text,
  p_amount_mwk numeric,
  p_pricing_unit text,
  p_active boolean
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.lavida_is_payment_admin() then
    raise exception 'Access denied.' using errcode = '42501';
  end if;
  if p_amount_mwk is null or p_amount_mwk < 0 then raise exception 'Price must be zero or greater.'; end if;
  if trim(coalesce(p_display_name, '')) = '' then raise exception 'Price name is required.'; end if;
  if p_pricing_unit not in ('per_page','per_document','per_order','per_file','per_copy','custom') then raise exception 'Unsupported pricing unit.'; end if;

  update public.printing_service_prices
  set display_name = trim(p_display_name), amount_mwk = p_amount_mwk,
      pricing_unit = p_pricing_unit, active = p_active,
      updated_by = auth.uid(), updated_at = now()
  where id = p_id;
  if not found then raise exception 'Printing price not found.'; end if;
end;
$$;

create or replace function public.save_marketplace_product_price_admin(p_id uuid, p_selling_price numeric)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.lavida_is_payment_admin() then raise exception 'Access denied.' using errcode = '42501'; end if;
  if p_selling_price is null or p_selling_price < 0 then raise exception 'Selling price must be zero or greater.'; end if;
  update public.marketplace_products set selling_price = p_selling_price, updated_at = now() where id = p_id;
  if not found then raise exception 'Marketplace product not found.'; end if;
end;
$$;

create or replace function public.save_crypto_price_admin(
  p_id uuid,
  p_supplier_rate numeric,
  p_customer_rate numeric,
  p_minimum_purchase numeric,
  p_is_active boolean
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.lavida_is_payment_admin() then raise exception 'Access denied.' using errcode = '42501'; end if;
  if p_supplier_rate is null or p_supplier_rate < 0 or p_customer_rate is null or p_customer_rate < 0 then raise exception 'Rates must be zero or greater.'; end if;
  if p_minimum_purchase is null or p_minimum_purchase <= 0 then raise exception 'Minimum purchase must be greater than zero.'; end if;
  update public.crypto_assets
  set supplier_base_rate_mwk = p_supplier_rate, lavida_selling_rate_mwk = p_customer_rate,
      minimum_purchase = p_minimum_purchase, is_active = p_is_active,
      updated_by = auth.uid(), updated_at = now()
  where id = p_id;
  if not found then raise exception 'Crypto asset not found.'; end if;
end;
$$;

revoke all on function public.get_payments_pricing_admin_bundle() from public;
revoke all on function public.save_printing_price_admin(uuid,text,numeric,text,boolean) from public;
revoke all on function public.save_marketplace_product_price_admin(uuid,numeric) from public;
revoke all on function public.save_crypto_price_admin(uuid,numeric,numeric,numeric,boolean) from public;

grant execute on function public.get_payments_pricing_admin_bundle() to authenticated;
grant execute on function public.save_printing_price_admin(uuid,text,numeric,text,boolean) to authenticated;
grant execute on function public.save_marketplace_product_price_admin(uuid,numeric) to authenticated;
grant execute on function public.save_crypto_price_admin(uuid,numeric,numeric,numeric,boolean) to authenticated;

revoke all on public.lavida_pricing_settings, public.lavida_configuration_history from anon;
revoke all on public.lavida_configuration_history from authenticated;
revoke select, insert, update, delete on public.lavida_pricing_settings from authenticated;
