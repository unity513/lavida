create extension if not exists pgcrypto;

alter table public.payment_methods
  add column if not exists provider text,
  add column if not exists applies_to text[] not null default array['printing','professional_services','marketplace','games']::text[],
  add column if not exists row_version bigint not null default 1;

update public.payment_methods
set provider = case
  when method_code = 'airtel_money' then 'Airtel Money'
  when method_code = 'tnm_mpamba' then 'TNM Mpamba'
  else provider
end
where provider is null;

insert into public.payment_methods (
  method_code, display_name, method_type, currency, customer_instructions,
  is_active, display_order, provider, applies_to
)
values (
  'shared_mobile_money', 'Mobile Money', 'mobile_money', 'MWK',
  'Send the exact amount shown and use your order reference when paying.',
  false, 5, null, array['printing','professional_services','marketplace','games']::text[]
)
on conflict (method_code) do nothing;

create table if not exists public.lavida_pricing_settings (
  id uuid primary key default gen_random_uuid(),
  section text not null check (section in ('printing','professional_services','marketplace','games','payment_rules')),
  setting_code text not null,
  display_name text not null,
  pricing_mode text not null default 'fixed' check (pricing_mode in ('fixed','starting_at','custom_quote','rate','rule')),
  amount numeric(18,8),
  currency text not null default 'MWK',
  unit text not null default 'per_order',
  description text,
  is_active boolean not null default true,
  public_value jsonb not null default '{}'::jsonb,
  private_value jsonb not null default '{}'::jsonb,
  display_order integer not null default 0,
  row_version bigint not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id),
  unique(section, setting_code),
  constraint lavida_pricing_amount_valid check (amount is null or amount >= 0),
  constraint lavida_pricing_currency_valid check (currency ~ '^[A-Z]{3,8}$'),
  constraint lavida_pricing_unit_not_blank check (length(trim(unit)) > 0)
);

create table if not exists public.lavida_configuration_history (
  id uuid primary key default gen_random_uuid(),
  entity_type text not null,
  entity_id text not null,
  action text not null,
  previous_value jsonb,
  new_value jsonb,
  changed_by uuid references auth.users(id),
  changed_at timestamptz not null default now()
);

create index if not exists lavida_configuration_history_entity_idx
  on public.lavida_configuration_history(entity_type, entity_id, changed_at desc);

create or replace function public.lavida_payment_method_before_write()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  new.updated_at := now();
  new.updated_by := coalesce(auth.uid(), new.updated_by);
  if new.method_type = 'mobile_money' and new.payment_number is not null then
    new.payment_number := public.lavida_normalize_malawi_phone(new.payment_number);
  end if;
  if new.is_active and new.method_type = 'mobile_money' then
    if trim(coalesce(new.recipient_name, '')) = '' or new.payment_number !~ '^265(88|89|98|99)[0-9]{7}$' then
      raise exception 'A valid Malawi receiving number and registered recipient name are required.';
    end if;
    if trim(coalesce(new.provider, '')) = '' then
      raise exception 'The supported mobile-money provider is required.';
    end if;
  end if;
  if tg_op = 'UPDATE' then new.row_version := old.row_version + 1; end if;
  return new;
end;
$$;

drop trigger if exists payment_methods_updated_at on public.payment_methods;
drop trigger if exists lavida_payment_method_before_write on public.payment_methods;
create trigger lavida_payment_method_before_write
before insert or update on public.payment_methods
for each row execute function public.lavida_payment_method_before_write();

create or replace function public.lavida_audit_configuration_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id text;
begin
  v_id := coalesce(new.id, old.id)::text;
  insert into public.lavida_configuration_history(entity_type, entity_id, action, previous_value, new_value, changed_by)
  values (tg_table_name, v_id, lower(tg_op), case when tg_op = 'INSERT' then null else to_jsonb(old) end,
          case when tg_op = 'DELETE' then null else to_jsonb(new) end, auth.uid());
  return coalesce(new, old);
end;
$$;

drop trigger if exists audit_payment_methods on public.payment_methods;
create trigger audit_payment_methods after insert or update or delete on public.payment_methods
for each row execute function public.lavida_audit_configuration_change();

drop trigger if exists audit_lavida_pricing_settings on public.lavida_pricing_settings;
create trigger audit_lavida_pricing_settings after insert or update or delete on public.lavida_pricing_settings
for each row execute function public.lavida_audit_configuration_change();

create or replace function public.get_public_lavida_payment_methods(p_service text default null)
returns table (
  id uuid, method_code text, display_name text, method_type text, recipient_name text,
  payment_number text, provider text, bank_name text, branch_name text, account_type text,
  currency text, customer_instructions text, display_order integer, updated_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select pm.id, pm.method_code, pm.display_name, pm.method_type, pm.recipient_name,
         pm.payment_number, pm.provider, pm.bank_name, pm.branch_name, pm.account_type,
         pm.currency, pm.customer_instructions, pm.display_order, pm.updated_at
  from public.payment_methods pm
  where pm.is_active = true
    and pm.archived_at is null
    and (p_service is null or p_service = any(pm.applies_to))
    and (pm.method_type = 'cash' or (trim(coalesce(pm.recipient_name,'')) <> '' and trim(coalesce(pm.payment_number,'')) <> ''))
  order by pm.display_order, pm.display_name;
$$;

create or replace function public.update_shared_mobile_payment(
  p_expected_version bigint,
  p_receiving_number text,
  p_recipient_name text,
  p_provider text,
  p_instructions text,
  p_is_active boolean,
  p_applies_to text[] default array['printing','professional_services','marketplace','games']::text[]
)
returns public.payment_methods
language plpgsql
security definer
set search_path = public
as $$
declare v_row public.payment_methods%rowtype;
begin
  if not public.lavida_is_payment_admin() then raise exception 'Access denied.'; end if;
  select * into v_row from public.payment_methods where method_code = 'shared_mobile_money' for update;
  if not found then raise exception 'Shared mobile-money configuration is missing.'; end if;
  if v_row.row_version <> p_expected_version then raise exception 'These settings were updated by another administrator. Refresh and review the latest values.'; end if;
  update public.payment_methods
  set payment_number = nullif(trim(p_receiving_number), ''), recipient_name = nullif(trim(p_recipient_name), ''),
      provider = nullif(trim(p_provider), ''), display_name = coalesce(nullif(trim(p_provider), ''), 'Mobile Money'),
      customer_instructions = nullif(trim(p_instructions), ''), is_active = p_is_active,
      applies_to = coalesce(p_applies_to, array[]::text[]), archived_at = null
  where id = v_row.id returning * into v_row;
  return v_row;
end;
$$;

create or replace function public.save_lavida_pricing_setting(p_setting jsonb, p_expected_version bigint default null)
returns public.lavida_pricing_settings
language plpgsql
security definer
set search_path = public
as $$
declare v_row public.lavida_pricing_settings%rowtype;
begin
  if not public.lavida_is_payment_admin() then raise exception 'Access denied.'; end if;
  select * into v_row from public.lavida_pricing_settings
  where section = p_setting->>'section' and setting_code = p_setting->>'setting_code' for update;
  if found then
    if p_expected_version is not null and v_row.row_version <> p_expected_version then
      raise exception 'This setting was updated by another administrator. Refresh and try again.';
    end if;
    update public.lavida_pricing_settings set
      display_name = trim(p_setting->>'display_name'), pricing_mode = p_setting->>'pricing_mode',
      amount = nullif(p_setting->>'amount','')::numeric, currency = upper(coalesce(nullif(p_setting->>'currency',''),'MWK')),
      unit = coalesce(nullif(p_setting->>'unit',''),'per_order'), description = nullif(trim(p_setting->>'description'),''),
      is_active = coalesce((p_setting->>'is_active')::boolean,true), public_value = coalesce(p_setting->'public_value','{}'::jsonb),
      private_value = coalesce(p_setting->'private_value','{}'::jsonb), display_order = coalesce((p_setting->>'display_order')::integer,0),
      row_version = row_version + 1, updated_at = now(), updated_by = auth.uid()
    where id = v_row.id returning * into v_row;
  else
    insert into public.lavida_pricing_settings(section,setting_code,display_name,pricing_mode,amount,currency,unit,description,is_active,public_value,private_value,display_order,updated_by)
    values (p_setting->>'section',p_setting->>'setting_code',trim(p_setting->>'display_name'),p_setting->>'pricing_mode',nullif(p_setting->>'amount','')::numeric,
      upper(coalesce(nullif(p_setting->>'currency',''),'MWK')),coalesce(nullif(p_setting->>'unit',''),'per_order'),nullif(trim(p_setting->>'description'),''),
      coalesce((p_setting->>'is_active')::boolean,true),coalesce(p_setting->'public_value','{}'::jsonb),coalesce(p_setting->'private_value','{}'::jsonb),
      coalesce((p_setting->>'display_order')::integer,0),auth.uid()) returning * into v_row;
  end if;
  return v_row;
end;
$$;

alter table public.lavida_pricing_settings enable row level security;
alter table public.lavida_configuration_history enable row level security;

drop policy if exists "Public reads active pricing settings" on public.lavida_pricing_settings;
create policy "Public reads active pricing settings" on public.lavida_pricing_settings for select
using ((is_active = true and private_value = '{}'::jsonb) or public.lavida_is_payment_admin());
drop policy if exists "Payment admins manage pricing settings" on public.lavida_pricing_settings;
create policy "Payment admins manage pricing settings" on public.lavida_pricing_settings for all
using (public.lavida_is_payment_admin()) with check (public.lavida_is_payment_admin());
drop policy if exists "Payment admins read configuration history" on public.lavida_configuration_history;
create policy "Payment admins read configuration history" on public.lavida_configuration_history for select
using (public.lavida_is_payment_admin());

revoke all on public.lavida_pricing_settings, public.lavida_configuration_history from anon, authenticated;
grant select on public.lavida_pricing_settings to anon, authenticated;
grant select on public.lavida_configuration_history to authenticated;
grant select, insert, update on public.lavida_pricing_settings to authenticated;
grant select (id,method_code,display_name,method_type,recipient_name,payment_number,bank_name,branch_name,account_type,currency,customer_instructions,is_active,display_order,archived_at,updated_at,provider,applies_to,row_version) on public.payment_methods to authenticated;
grant update (provider,applies_to,row_version) on public.payment_methods to authenticated;

revoke all on function public.get_public_lavida_payment_methods(text) from public;
revoke all on function public.update_shared_mobile_payment(bigint,text,text,text,text,boolean,text[]) from public;
revoke all on function public.save_lavida_pricing_setting(jsonb,bigint) from public;
grant execute on function public.get_public_lavida_payment_methods(text) to anon, authenticated;
grant execute on function public.update_shared_mobile_payment(bigint,text,text,text,text,boolean,text[]) to authenticated;
grant execute on function public.save_lavida_pricing_setting(jsonb,bigint) to authenticated;

create or replace function public.lavida_snapshot_marketplace_payment()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare v_method public.payment_methods%rowtype;
begin
  if new.payment_method_id is not null then
    select * into v_method from public.payment_methods where id = new.payment_method_id;
  elsif new.payment_method is not null then
    select * into v_method from public.payment_methods
    where is_active and archived_at is null
      and (method_code = new.payment_method or (method_code = 'shared_mobile_money' and new.payment_method in ('airtel_money','tnm_mpamba','mobile_money')))
    order by case when method_code = new.payment_method then 0 else 1 end, display_order limit 1;
  end if;
  if found then
    new.payment_method_id := v_method.id;
    new.payment_method_name := v_method.display_name;
    new.payment_recipient_name := v_method.recipient_name;
    new.payment_destination := v_method.payment_number;
    new.payment_currency := v_method.currency;
    new.payment_instructions_snapshot := v_method.customer_instructions;
  end if;
  return new;
end;
$$;

insert into public.lavida_pricing_settings(section,setting_code,display_name,pricing_mode,amount,currency,unit,description,is_active,public_value,display_order)
values
 ('payment_rules','verification_estimate','Verification estimate','rule',10,'MIN','minutes','Estimated manual payment verification time.',true,'{"message":"Payment pending verification. Verification may take up to 10 minutes. Check My Orders for updates."}'::jsonb,10),
 ('games','credit_purchase','Game credit purchase','fixed',null,'MWK','per_credit','Price for new game-credit purchases. Existing balances are never changed.',false,'{"minimum_purchase":1}'::jsonb,10)
on conflict(section,setting_code) do nothing;

do $$
begin
  if to_regclass('public.marketplace_orders') is not null then
    alter table public.marketplace_orders
      add column if not exists payment_method_id uuid references public.payment_methods(id) on delete set null,
      add column if not exists payment_method_name text,
      add column if not exists payment_recipient_name text,
      add column if not exists payment_destination text,
      add column if not exists payment_currency text,
      add column if not exists payment_instructions_snapshot text,
      add column if not exists pricing_snapshot jsonb;
    drop trigger if exists snapshot_marketplace_payment on public.marketplace_orders;
    create trigger snapshot_marketplace_payment before insert on public.marketplace_orders
    for each row execute function public.lavida_snapshot_marketplace_payment();
  end if;
  if to_regclass('public.service_invoices') is not null then
    alter table public.service_invoices
      add column if not exists payment_method_id uuid references public.payment_methods(id) on delete set null,
      add column if not exists payment_method_name text,
      add column if not exists payment_recipient_name text,
      add column if not exists payment_destination text,
      add column if not exists payment_currency text,
      add column if not exists payment_instructions_snapshot text,
      add column if not exists pricing_snapshot jsonb;
  end if;
  if to_regclass('public.printing_payments') is not null then
    alter table public.printing_payments add column if not exists payment_instructions_snapshot text;
  end if;
end $$;
