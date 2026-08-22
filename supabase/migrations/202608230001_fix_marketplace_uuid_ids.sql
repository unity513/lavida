create extension if not exists pgcrypto;

alter table if exists public.marketplace_orders
  alter column id set default gen_random_uuid();

alter table if exists public.marketplace_order_items
  alter column id set default gen_random_uuid();

alter table if exists public.crypto_order_details
  alter column id set default gen_random_uuid();

create or replace function public.lavida_assign_uuid_id()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.id is null then
    new.id := gen_random_uuid();
  end if;

  return new;
end;
$$;

drop trigger if exists lavida_assign_marketplace_orders_id on public.marketplace_orders;
create trigger lavida_assign_marketplace_orders_id
  before insert on public.marketplace_orders
  for each row
  execute function public.lavida_assign_uuid_id();

drop trigger if exists lavida_assign_marketplace_order_items_id on public.marketplace_order_items;
create trigger lavida_assign_marketplace_order_items_id
  before insert on public.marketplace_order_items
  for each row
  execute function public.lavida_assign_uuid_id();

drop trigger if exists lavida_assign_crypto_order_details_id on public.crypto_order_details;
create trigger lavida_assign_crypto_order_details_id
  before insert on public.crypto_order_details
  for each row
  execute function public.lavida_assign_uuid_id();

notify pgrst, 'reload schema';
