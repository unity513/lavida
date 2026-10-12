alter table if exists public.marketplace_products
  add column if not exists price numeric(14,2);

update public.marketplace_products mp
set
  price = coalesce(
    nullif(mp.selling_price, 0),
    nullif(ca.supplier_base_rate_mwk, 0),
    nullif(ca.lavida_selling_rate_mwk, 0)
  ),
  updated_at = now()
from public.crypto_assets ca
where ca.marketplace_product_id = mp.id
  and ca.is_active = true
  and coalesce(
    nullif(mp.selling_price, 0),
    nullif(ca.supplier_base_rate_mwk, 0),
    nullif(ca.lavida_selling_rate_mwk, 0)
  ) > 0
  and coalesce(mp.price, 0) <= 0;

notify pgrst, 'reload schema';
