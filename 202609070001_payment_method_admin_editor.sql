create or replace function public.save_lavida_payment_method_admin(
  p_id uuid,
  p_display_name text,
  p_method_type text,
  p_recipient_name text,
  p_payment_number text,
  p_provider text,
  p_bank_name text,
  p_branch_name text,
  p_account_type text,
  p_currency text,
  p_customer_instructions text,
  p_is_active boolean,
  p_applies_to text[] default array['printing','professional_services','marketplace','games']::text[]
)
returns public.payment_methods
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.payment_methods%rowtype;
begin
  if not public.lavida_is_payment_admin() then
    raise exception 'Access denied.' using errcode = '42501';
  end if;

  select * into v_row
  from public.payment_methods
  where id = p_id
  for update;

  if not found then
    raise exception 'Payment method not found.';
  end if;

  if trim(coalesce(p_display_name, '')) = '' then
    raise exception 'Payment method name is required.';
  end if;

  if p_method_type not in ('mobile_money','bank_transfer','cash','card','crypto') then
    raise exception 'Unsupported payment method type.';
  end if;

  update public.payment_methods
  set display_name = trim(p_display_name),
      method_type = p_method_type,
      recipient_name = nullif(trim(coalesce(p_recipient_name,'')), ''),
      payment_number = nullif(trim(coalesce(p_payment_number,'')), ''),
      provider = nullif(trim(coalesce(p_provider,'')), ''),
      bank_name = nullif(trim(coalesce(p_bank_name,'')), ''),
      branch_name = nullif(trim(coalesce(p_branch_name,'')), ''),
      account_type = nullif(trim(coalesce(p_account_type,'')), ''),
      currency = upper(coalesce(nullif(trim(p_currency), ''), 'MWK')),
      customer_instructions = nullif(trim(coalesce(p_customer_instructions,'')), ''),
      is_active = coalesce(p_is_active, false),
      applies_to = coalesce(p_applies_to, array[]::text[]),
      archived_at = case when coalesce(p_is_active, false) then null else archived_at end
  where id = p_id
  returning * into v_row;

  return v_row;
end;
$$;

revoke all on function public.save_lavida_payment_method_admin(uuid,text,text,text,text,text,text,text,text,text,text,boolean,text[]) from public;
grant execute on function public.save_lavida_payment_method_admin(uuid,text,text,text,text,text,text,text,text,text,text,boolean,text[]) to authenticated;
