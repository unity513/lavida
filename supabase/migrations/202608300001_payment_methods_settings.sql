create extension if not exists pgcrypto;

create or replace function public.lavida_is_payment_admin()
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
      and lower(ur.role) in ('owner','admin','executive','finance_admin')
  );
$$;

create or replace function public.lavida_normalize_malawi_phone(raw_value text)
returns text
language sql
immutable
as $$
  with cleaned as (
    select regexp_replace(coalesce(raw_value, ''), '[^0-9]+', '', 'g') as digits
  )
  select case
    when digits ~ '^0(88|89|98|99)[0-9]{7}$' then '265' || substring(digits from 2)
    when digits ~ '^265(88|89|98|99)[0-9]{7}$' then digits
    else digits
  end
  from cleaned;
$$;

create table if not exists public.payment_methods (
  id uuid primary key default gen_random_uuid(),
  method_code text unique not null,
  display_name text not null,
  method_type text not null,
  recipient_name text,
  payment_number text,
  bank_name text,
  branch_name text,
  account_type text,
  currency text not null default 'MWK',
  customer_instructions text,
  is_active boolean not null default false,
  display_order integer not null default 0,
  archived_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id),
  constraint payment_methods_code_not_blank check (length(trim(method_code)) > 0),
  constraint payment_methods_name_not_blank check (length(trim(display_name)) > 0),
  constraint payment_methods_type_valid check (method_type in ('mobile_money','bank_transfer','card','cash','other')),
  constraint payment_methods_currency_not_blank check (length(trim(currency)) > 0),
  constraint payment_methods_active_destination_required check (
    is_active = false
    or method_type = 'cash'
    or (length(trim(coalesce(recipient_name, ''))) > 0 and length(trim(coalesce(payment_number, ''))) > 0)
  ),
  constraint payment_methods_mobile_number_valid check (
    method_type <> 'mobile_money'
    or payment_number is null
    or public.lavida_normalize_malawi_phone(payment_number) ~ '^265(88|89|98|99)[0-9]{7}$'
  )
);

create index if not exists payment_methods_checkout_idx
  on public.payment_methods(is_active, display_order, display_name)
  where archived_at is null;

create or replace function public.set_payment_methods_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  if auth.uid() is not null then
    new.updated_by := auth.uid();
  end if;
  if new.method_type = 'mobile_money' and new.payment_number is not null then
    new.payment_number := public.lavida_normalize_malawi_phone(new.payment_number);
  end if;
  if new.is_active = true then
    new.archived_at := null;
  end if;
  return new;
end;
$$;

drop trigger if exists payment_methods_updated_at on public.payment_methods;
create trigger payment_methods_updated_at
before insert or update on public.payment_methods
for each row execute function public.set_payment_methods_updated_at();

create or replace function public.archive_used_payment_method()
returns trigger
language plpgsql
as $$
begin
  if to_regclass('public.printing_payments') is not null and exists (
    select 1 from public.printing_payments pp where pp.payment_method_id = old.id
  ) then
    update public.payment_methods
      set is_active = false,
          archived_at = coalesce(archived_at, now()),
          updated_at = now(),
          updated_by = coalesce(auth.uid(), updated_by)
      where id = old.id;
    return null;
  end if;
  return old;
end;
$$;

drop trigger if exists archive_used_payment_method_before_delete on public.payment_methods;
create trigger archive_used_payment_method_before_delete
before delete on public.payment_methods
for each row execute function public.archive_used_payment_method();

alter table public.payment_methods enable row level security;

drop policy if exists "Checkout can read active payment methods" on public.payment_methods;
create policy "Checkout can read active payment methods"
  on public.payment_methods for select
  using ((is_active = true and archived_at is null) or public.lavida_is_payment_admin());

drop policy if exists "Payment admins insert payment methods" on public.payment_methods;
create policy "Payment admins insert payment methods"
  on public.payment_methods for insert
  with check (public.lavida_is_payment_admin());

drop policy if exists "Payment admins update payment methods" on public.payment_methods;
create policy "Payment admins update payment methods"
  on public.payment_methods for update
  using (public.lavida_is_payment_admin())
  with check (public.lavida_is_payment_admin());

drop policy if exists "Payment admins delete unused payment methods" on public.payment_methods;
create policy "Payment admins delete unused payment methods"
  on public.payment_methods for delete
  using (public.lavida_is_payment_admin());

revoke all on public.payment_methods from anon, authenticated;
grant select (
  id,
  method_code,
  display_name,
  method_type,
  recipient_name,
  payment_number,
  bank_name,
  branch_name,
  account_type,
  currency,
  customer_instructions,
  is_active,
  display_order,
  archived_at,
  updated_at
) on public.payment_methods to anon, authenticated;
grant insert (
  method_code,
  display_name,
  method_type,
  recipient_name,
  payment_number,
  bank_name,
  branch_name,
  account_type,
  currency,
  customer_instructions,
  is_active,
  display_order,
  updated_by
) on public.payment_methods to authenticated;
grant update (
  method_code,
  display_name,
  method_type,
  recipient_name,
  payment_number,
  bank_name,
  branch_name,
  account_type,
  currency,
  customer_instructions,
  is_active,
  display_order,
  archived_at,
  updated_by
) on public.payment_methods to authenticated;
grant delete on public.payment_methods to authenticated;

insert into public.payment_methods (
  method_code,
  display_name,
  method_type,
  recipient_name,
  payment_number,
  bank_name,
  currency,
  customer_instructions,
  is_active,
  display_order
)
values
  ('airtel_money','Airtel Money','mobile_money',null,null,null,'MWK','Send the exact amount shown at checkout.',false,10),
  ('tnm_mpamba','TNM Mpamba','mobile_money',null,null,null,'MWK','Send the exact amount shown at checkout.',false,20),
  ('bank_transfer','Bank Transfer','bank_transfer',null,null,null,'MWK','Use your order number or transaction reference when paying.',false,30),
  ('cash_on_pickup','Cash on Pickup','cash','LAVIDA',null,null,'MWK','Pay at the pickup point when LAVIDA confirms your order is ready.',true,40)
on conflict (method_code) do nothing;

insert into public.payment_methods (
  method_code,
  display_name,
  method_type,
  recipient_name,
  payment_number,
  currency,
  customer_instructions,
  is_active,
  display_order
)
select 'cash_on_pickup','Cash on Pickup','cash','LAVIDA',null,'MWK','Pay at the pickup point when LAVIDA confirms your order is ready.',true,40
where not exists (select 1 from public.payment_methods where method_code = 'cash_on_pickup');

do $$
begin
  if to_regclass('public.printing_payments') is not null then
    alter table public.printing_payments
      add column if not exists payment_method_id uuid references public.payment_methods(id) on delete set null,
      add column if not exists payment_method_name text,
      add column if not exists payment_recipient_name text,
      add column if not exists payment_destination text,
      add column if not exists payment_currency text not null default 'MWK',
      add column if not exists amount_submitted numeric(14,2),
      add column if not exists submitted_at timestamptz not null default now();

    update public.printing_payments pp
      set payment_method_id = coalesce(pp.payment_method_id, pm.id),
          payment_method_name = coalesce(pp.payment_method_name, pm.display_name, initcap(replace(pp.payment_method, '_', ' '))),
          payment_recipient_name = coalesce(pp.payment_recipient_name, pm.recipient_name),
          payment_destination = coalesce(pp.payment_destination, pm.payment_number),
          payment_currency = coalesce(nullif(pp.payment_currency, ''), pm.currency, 'MWK'),
          amount_submitted = coalesce(pp.amount_submitted, pp.amount_mwk)
    from public.payment_methods pm
    where pm.method_code = pp.payment_method
      and (
        pp.payment_method_name is null
        or pp.payment_method_id is null
        or pp.payment_recipient_name is null
        or pp.payment_destination is null
        or pp.amount_submitted is null
      );

    update public.printing_payments pp
      set payment_method_name = coalesce(pp.payment_method_name, initcap(replace(pp.payment_method, '_', ' '))),
          amount_submitted = coalesce(pp.amount_submitted, pp.amount_mwk),
          payment_currency = coalesce(nullif(pp.payment_currency, ''), 'MWK')
      where pp.payment_method_name is null
        or pp.amount_submitted is null
        or pp.payment_currency is null;
  end if;
end $$;
