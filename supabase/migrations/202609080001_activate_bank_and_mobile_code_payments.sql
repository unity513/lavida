-- Allow a shared mobile-money destination to be an agent/mobile code, a number, or both.
-- Bank payment availability remains an explicit finance-admin decision.
begin;

alter table public.payment_methods add column if not exists agent_code text;

-- Preserve the destination requirement for every active method, while allowing
-- mobile money to use an agent/mobile code in place of a phone number.
alter table public.payment_methods drop constraint if exists payment_methods_active_destination_required;
alter table public.payment_methods add constraint payment_methods_active_destination_required check (
  is_active = false
  or method_type = 'cash'
  or (
    length(trim(coalesce(recipient_name, ''))) > 0
    and (
      length(trim(coalesce(payment_number, ''))) > 0
      or (method_type = 'mobile_money' and length(trim(coalesce(agent_code, ''))) > 0)
    )
  )
);

create or replace function public.lavida_payment_method_before_write()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  new.updated_at := now();
  new.updated_by := coalesce(auth.uid(), new.updated_by);
  if new.method_type = 'mobile_money' and new.payment_number is not null then
    new.payment_number := public.lavida_normalize_malawi_phone(new.payment_number);
  end if;
  if new.is_active and new.method_type = 'mobile_money' then
    if trim(coalesce(new.recipient_name, '')) = ''
       or (trim(coalesce(new.payment_number, '')) = '' and trim(coalesce(new.agent_code, '')) = '') then
      raise exception 'A registered recipient and a receiving number or mobile/agent code are required.';
    end if;
    if trim(coalesce(new.payment_number, '')) <> '' and new.payment_number !~ '^265(88|89|98|99)[0-9]{7}$' then
      raise exception 'The receiving number must be a valid Malawi mobile number.';
    end if;
    if trim(coalesce(new.provider, '')) = '' then
      raise exception 'The supported mobile-money provider is required.';
    end if;
  end if;
  if tg_op = 'UPDATE' then new.row_version := old.row_version + 1; end if;
  return new;
end;
$$;

create or replace function public.update_shared_mobile_payment_details(
  p_expected_version bigint, p_receiving_number text, p_agent_code text,
  p_recipient_name text, p_provider text, p_instructions text, p_is_active boolean,
  p_applies_to text[] default array['printing','professional_services','marketplace','games']::text[]
)
returns public.payment_methods language plpgsql security definer set search_path=public as $$
declare v public.payment_methods%rowtype;
begin
  if not public.lavida_is_payment_admin() then raise exception 'Access denied.' using errcode='42501'; end if;
  select * into v from public.payment_methods where method_code='shared_mobile_money' for update;
  if not found then raise exception 'Shared mobile-money configuration is missing.'; end if;
  if v.row_version<>p_expected_version then raise exception 'These settings were updated by another administrator. Refresh and review the latest values.'; end if;
  if p_is_active and nullif(trim(p_receiving_number),'') is null and nullif(trim(p_agent_code),'') is null then
    raise exception 'Add a receiving number or mobile/agent code before activation.';
  end if;
  update public.payment_methods set payment_number=nullif(trim(p_receiving_number),''), agent_code=nullif(trim(p_agent_code),''),
    recipient_name=nullif(trim(p_recipient_name),''), provider=nullif(trim(p_provider),''),
    display_name=coalesce(nullif(trim(p_provider),''),'Mobile Money'), customer_instructions=nullif(trim(p_instructions),''),
    is_active=p_is_active, applies_to=coalesce(p_applies_to,array[]::text[]), archived_at=null
  where id=v.id returning * into v;
  return v;
end;
$$;
revoke all on function public.update_shared_mobile_payment_details(bigint,text,text,text,text,text,boolean,text[]) from public;
grant execute on function public.update_shared_mobile_payment_details(bigint,text,text,text,text,text,boolean,text[]) to authenticated;

create or replace function public.set_lavida_bank_payment_active(p_method_id uuid, p_is_active boolean)
returns public.payment_methods language plpgsql security definer set search_path=public as $$
declare v public.payment_methods%rowtype;
begin
  if not public.lavida_is_payment_admin() then raise exception 'Access denied.' using errcode='42501'; end if;
  select * into v from public.payment_methods where id=p_method_id and method_type='bank_transfer' and archived_at is null for update;
  if not found then raise exception 'Bank payment method not found.'; end if;
  if p_is_active and (nullif(trim(v.recipient_name),'') is null or nullif(trim(v.payment_number),'') is null) then
    raise exception 'Add the bank account number and account-holder name before activating this bank payment method.';
  end if;
  update public.payment_methods set is_active=p_is_active where id=v.id returning * into v;
  return v;
end;
$$;
revoke all on function public.set_lavida_bank_payment_active(uuid,boolean) from public;
grant execute on function public.set_lavida_bank_payment_active(uuid,boolean) to authenticated;

create or replace function public.update_lavida_bank_payment_details(
  p_expected_version bigint, p_method_id uuid, p_recipient_name text,
  p_account_number text, p_bank_name text, p_is_active boolean
)
returns public.payment_methods language plpgsql security definer set search_path=public as $$
declare v public.payment_methods%rowtype;
begin
  if not public.lavida_is_payment_admin() then raise exception 'Access denied.' using errcode='42501'; end if;
  select * into v from public.payment_methods where id=p_method_id and method_type='bank_transfer' and archived_at is null for update;
  if not found then raise exception 'Bank payment method not found.'; end if;
  if v.row_version<>p_expected_version then raise exception 'These bank details were updated by another administrator. Refresh and review the latest values.'; end if;
  if p_is_active and (nullif(trim(p_recipient_name),'') is null or nullif(trim(p_account_number),'') is null) then
    raise exception 'Add the account-holder name and account number before activating bank payment.';
  end if;
  update public.payment_methods
  set recipient_name=nullif(trim(p_recipient_name),''), payment_number=nullif(trim(p_account_number),''),
      bank_name=nullif(trim(p_bank_name),''), is_active=p_is_active, archived_at=null
  where id=v.id returning * into v;
  return v;
end;
$$;
revoke all on function public.update_lavida_bank_payment_details(bigint,uuid,text,text,text,boolean) from public;
grant execute on function public.update_lavida_bank_payment_details(bigint,uuid,text,text,text,boolean) to authenticated;

commit;
