create extension if not exists pgcrypto;

alter table public.service_requests
  add column if not exists selected_package_code text,
  add column if not exists selected_package_name text,
  add column if not exists quantity numeric(12,2),
  add column if not exists billing_unit text,
  add column if not exists unit_price_usd numeric(18,2),
  add column if not exists service_total_usd numeric(18,2),
  add column if not exists payable_currency text,
  add column if not exists payable_amount numeric(18,2),
  add column if not exists payment_method_id uuid references public.payment_methods(id) on delete set null,
  add column if not exists payment_method_name text,
  add column if not exists payment_recipient_name text,
  add column if not exists payment_destination text,
  add column if not exists payment_instructions_snapshot text,
  add column if not exists pricing_snapshot jsonb not null default '{}'::jsonb,
  add column if not exists customer_checkout_id text;

create unique index if not exists service_requests_customer_checkout_uidx
  on public.service_requests(user_id, customer_checkout_id)
  where customer_checkout_id is not null;

alter table public.service_quotes
  add column if not exists subtotal_usd numeric(18,2),
  add column if not exists total_usd numeric(18,2),
  add column if not exists currency text not null default 'MWK',
  add column if not exists pricing_snapshot jsonb not null default '{}'::jsonb;

alter table public.service_quote_items
  add column if not exists unit_price_usd numeric(18,2),
  add column if not exists line_total_usd numeric(18,2),
  add column if not exists currency text not null default 'MWK';

alter table public.service_invoices
  add column if not exists subtotal_usd numeric(18,2),
  add column if not exists total_usd numeric(18,2),
  add column if not exists currency text not null default 'MWK';

create table if not exists public.service_payment_quotes (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.service_requests(id) on delete cascade,
  quote_reference text not null unique,
  payment_method_id uuid references public.payment_methods(id) on delete set null,
  payment_method_code text not null,
  payment_method_name text not null,
  base_currency text not null default 'USD' check (base_currency = 'USD'),
  base_total_usd numeric(18,2) not null check (base_total_usd >= 0),
  exchange_rate_mwk_per_usd numeric(18,6),
  exchange_rate_captured_at timestamptz,
  payable_currency text not null check (payable_currency in ('USD','MWK')),
  payable_amount numeric(18,2) not null check (payable_amount >= 0),
  rounding_adjustment_mwk numeric(18,2),
  recipient_name text,
  payment_destination text,
  payment_instructions_snapshot text,
  status text not null default 'active' check (status in ('active','payment_submitted','paid','expired','cancelled','reconciliation_required')),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null
);

create index if not exists service_payment_quotes_request_idx
  on public.service_payment_quotes(request_id, created_at desc);

create table if not exists public.service_payments (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.service_requests(id) on delete cascade,
  payment_quote_id uuid not null references public.service_payment_quotes(id) on delete restrict,
  payment_method_id uuid references public.payment_methods(id) on delete set null,
  payment_method_code text not null,
  payment_method_name text not null,
  base_total_usd numeric(18,2) not null check (base_total_usd >= 0),
  exchange_rate_mwk_per_usd numeric(18,6),
  payable_currency text not null check (payable_currency in ('USD','MWK')),
  payable_amount numeric(18,2) not null check (payable_amount >= 0),
  transaction_reference text,
  status text not null default 'pending_verification' check (status in ('awaiting_payment','pending_verification','verified','rejected','cancelled','reconciliation_required')),
  submitted_by uuid references auth.users(id) on delete set null,
  submitted_at timestamptz not null default now(),
  verified_by uuid references auth.users(id) on delete set null,
  verified_at timestamptz,
  rejection_reason text,
  created_at timestamptz not null default now(),
  unique(payment_quote_id, transaction_reference)
);

create index if not exists service_payments_request_idx
  on public.service_payments(request_id, created_at desc);

insert into public.lavida_pricing_settings(section, setting_code, display_name, pricing_mode, amount, currency, unit, description, is_active, public_value, display_order)
values
  ('payment_rules','usd_mwk_exchange_rate','USD to MWK exchange rate','rate',null,'MWK','per_usd','MWK payable per 1 USD for service checkout quotes.',false,'{"required_for":"MWK service payments"}'::jsonb,20),
  ('payment_rules','service_payment_quote_validity','Service payment quote validity','rule',30,'MIN','minutes','How long a service payment quote remains valid.',true,'{"message":"Payment quote amount is locked until the displayed expiry time."}'::jsonb,30)
on conflict(section, setting_code) do nothing;

insert into public.lavida_pricing_settings(section, setting_code, display_name, pricing_mode, amount, currency, unit, description, is_active, public_value, display_order)
values
  ('professional_services','systems_it_support','Systems & IT Support','fixed',null,'USD','per_session','One remote support session, up to one hour, for one device or system.',true,'{"area":"digital","service_code":"systems_it","previous_mwk_reference":15000,"included_scope":"One remote support session, up to one hour, for one device or system.","exclusions":"Licences, replacement hardware, on-site work and additional hours are excluded.","quantity_allowed":true,"quantity_label":"Sessions","quote_only_when":"More than one device, on-site work, hardware replacement or work beyond one hour."}'::jsonb,10),
  ('professional_services','website_landing_page','Website Development - Landing Page','fixed',null,'USD','per_project','One-page website; customer supplies text/images; two revision rounds.',true,'{"area":"digital","service_code":"website_development","previous_mwk_reference":150000,"included_scope":"One-page website; customer supplies text/images; two revision rounds.","exclusions":"Copywriting, paid assets, hosting subscriptions, custom integrations and extra revisions are excluded.","quantity_allowed":false,"revision_allowance":"Two revision rounds"}'::jsonb,20),
  ('professional_services','website_business_website','Website Development - Business Website','fixed',null,'USD','per_project','Up to five pages, domain connection and two revision rounds included.',true,'{"area":"digital","service_code":"website_development","previous_mwk_reference":300000,"included_scope":"Up to five pages; customer supplies text/images; domain connection and two revision rounds included.","exclusions":"Domain purchase, hosting subscription, copywriting, paid assets, e-commerce and custom integrations are excluded.","quantity_allowed":false,"revision_allowance":"Two revision rounds"}'::jsonb,30),
  ('professional_services','website_redesign_single_page','Website Redesign - Single Page','fixed',null,'USD','per_page','Redesign one existing page; two revision rounds. New functionality excluded.',true,'{"area":"digital","service_code":"website_redesign","previous_mwk_reference":100000,"included_scope":"Redesign one existing page; two revision rounds.","exclusions":"New functionality, new copywriting and extra revisions are excluded.","quantity_allowed":false,"revision_allowance":"Two revision rounds"}'::jsonb,40),
  ('professional_services','website_redesign_business','Website Redesign - Business Website','fixed',null,'USD','per_project','Redesign up to five existing pages; two revision rounds. New functionality excluded.',true,'{"area":"digital","service_code":"website_redesign","previous_mwk_reference":200000,"included_scope":"Redesign up to five existing pages; two revision rounds.","exclusions":"New functionality, new copywriting and extra revisions are excluded.","quantity_allowed":false,"revision_allowance":"Two revision rounds"}'::jsonb,50),
  ('professional_services','website_maintenance','Website Maintenance','fixed',null,'USD','per_month','Up to two hours of minor fixes, content changes and updates monthly.',true,'{"area":"digital","service_code":"website_maintenance","previous_mwk_reference":30000,"included_scope":"Up to two hours of minor fixes, content changes and updates monthly.","exclusions":"Unused-hours policy, cancellation terms and additional-hour rate must be configured before paid checkout.","quantity_allowed":false,"monthly":true,"quote_only_when":"Monthly terms or additional-hour policy are not configured."}'::jsonb,60),
  ('professional_services','web_app_planning','Web Application - Planning Package','fixed',null,'USD','per_project','Requirements consultation, feature specification and a development quote.',true,'{"area":"digital","service_code":"web_application","previous_mwk_reference":50000,"included_scope":"Requirements consultation, feature specification and a development quote.","exclusions":"Application development is separate and requires a custom quote.","quantity_allowed":false,"offer_custom_quote":true}'::jsonb,70),
  ('professional_services','web_hosting_setup','Web Hosting - Setup','fixed',null,'USD','per_website','Configure one website on a customer-owned hosting account. Provider subscription excluded.',true,'{"area":"digital","service_code":"web_hosting","previous_mwk_reference":20000,"included_scope":"Configure one website on a customer-owned hosting account.","exclusions":"Provider subscription and hosting fees are excluded.","quantity_allowed":true,"quantity_label":"Websites"}'::jsonb,80),
  ('professional_services','domain_support','Domain Support','fixed',null,'USD','per_domain','DNS configuration and connection to one website. Domain purchase and renewal excluded.',true,'{"area":"digital","service_code":"domain_support","previous_mwk_reference":10000,"included_scope":"DNS configuration and connection to one website.","exclusions":"Domain purchase and renewal are excluded.","quantity_allowed":true,"quantity_label":"Domains"}'::jsonb,90),
  ('professional_services','business_email_setup','Business Email - Setup','fixed',null,'USD','per_domain','Configure one domain and up to three mailboxes. Provider subscriptions excluded.',true,'{"area":"digital","service_code":"business_email","previous_mwk_reference":15000,"included_scope":"Configure one domain and up to three mailboxes.","exclusions":"Provider subscriptions and extra mailboxes are excluded.","quantity_allowed":true,"quantity_label":"Domains"}'::jsonb,100),
  ('professional_services','hosting_migration','Hosting Migration','fixed',null,'USD','per_website','Move one standard website up to 2 GB, including one database.',true,'{"area":"digital","service_code":"hosting_migration","previous_mwk_reference":50000,"included_scope":"Move one standard website up to 2 GB, including one database.","exclusions":"Email migration and custom applications require a quote.","quantity_allowed":true,"quantity_label":"Websites","quote_only_when":"Website over 2 GB, email migration, custom app or complex database."}'::jsonb,110),
  ('professional_services','business_software_support','Business Software Support','fixed',null,'USD','per_session','Up to one hour of remote configuration or guidance for one application. Licences excluded.',true,'{"area":"digital","service_code":"business_software","previous_mwk_reference":25000,"included_scope":"Up to one hour of remote configuration or guidance for one application.","exclusions":"Licences and subscriptions are excluded.","quantity_allowed":true,"quantity_label":"Sessions"}'::jsonb,120),
  ('professional_services','installation_setup','Installation & Setup','fixed',null,'USD','per_application_device','Install and perform basic configuration of one legitimately licensed application on one device.',true,'{"area":"digital","service_code":"installation_setup","previous_mwk_reference":10000,"included_scope":"Install and perform basic configuration of one legitimately licensed application on one device.","exclusions":"Software licences and unsupported/unlicensed software are excluded.","quantity_allowed":true,"quantity_label":"Applications/devices"}'::jsonb,130),
  ('professional_services','data_migration_standard','Data Migration - Standard Import','fixed',null,'USD','per_dataset','Import one supplied CSV/Excel dataset of up to 5,000 rows into an existing supported system.',true,'{"area":"digital","service_code":"data_migration","previous_mwk_reference":50000,"included_scope":"Import one supplied CSV/Excel dataset of up to 5,000 rows into an existing supported system, with basic field mapping and validation.","exclusions":"Complex cleanup and unsupported systems require a quote.","quantity_allowed":true,"quantity_label":"Datasets","quote_only_when":"More than 5,000 rows or complex cleanup."}'::jsonb,140),
  ('professional_services','training_individual','Training - Individual','fixed',null,'USD','per_session','One-hour remote session covering one tool.',true,'{"area":"digital","service_code":"training","previous_mwk_reference":20000,"included_scope":"One-hour remote session covering one tool.","exclusions":"Custom training material and extra hours are excluded.","quantity_allowed":true,"quantity_label":"Sessions"}'::jsonb,150),
  ('professional_services','training_group','Training - Group','fixed',null,'USD','per_session','Two-hour remote session covering one tool, for up to five participants.',true,'{"area":"digital","service_code":"training","previous_mwk_reference":60000,"included_scope":"Two-hour remote session covering one tool, for up to five participants.","exclusions":"More than five participants or custom training material requires a quote.","quantity_allowed":true,"quantity_label":"Sessions","participant_limit":5}'::jsonb,160),
  ('professional_services','ongoing_technical_support','Ongoing Technical Support','fixed',null,'USD','per_month','Up to five remote support hours monthly during published business hours.',true,'{"area":"digital","service_code":"ongoing_support","previous_mwk_reference":75000,"included_scope":"Up to five remote support hours monthly during published business hours.","exclusions":"Unused-hours policy, cancellation terms and additional-hour rate must be configured before paid checkout.","quantity_allowed":false,"monthly":true,"included_hours":5,"quote_only_when":"Monthly terms or additional-hour policy are not configured."}'::jsonb,170),
  ('professional_services','other_consultation','Other - Consultation','fixed',null,'USD','per_session','A 30-minute consultation and written recommendation or quote. Implementation is separate.',true,'{"area":"digital","service_code":"other_digital","previous_mwk_reference":10000,"included_scope":"A 30-minute consultation and written recommendation or quote.","exclusions":"Implementation is separate and requires a custom quote.","quantity_allowed":true,"quantity_label":"Consultations","offer_custom_quote":true}'::jsonb,180)
on conflict(section, setting_code) do update
set public_value = lavida_pricing_settings.public_value || excluded.public_value,
    description = coalesce(lavida_pricing_settings.description, excluded.description),
    currency = case when lavida_pricing_settings.amount is null then 'USD' else lavida_pricing_settings.currency end,
    unit = coalesce(nullif(lavida_pricing_settings.unit, ''), excluded.unit);

create or replace function public.get_public_digital_service_checkout()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_rate public.lavida_pricing_settings%rowtype;
  v_validity public.lavida_pricing_settings%rowtype;
begin
  select * into v_rate
  from public.lavida_pricing_settings
  where section = 'payment_rules'
    and setting_code = 'usd_mwk_exchange_rate'
    and is_active = true
    and amount is not null
    and amount > 0
  limit 1;

  select * into v_validity
  from public.lavida_pricing_settings
  where section = 'payment_rules'
    and setting_code = 'service_payment_quote_validity'
    and is_active = true
    and amount is not null
    and amount > 0
  limit 1;

  return jsonb_build_object(
    'packages', coalesce((
      select jsonb_agg(jsonb_build_object(
        'setting_code', ps.setting_code,
        'display_name', ps.display_name,
        'pricing_mode', ps.pricing_mode,
        'amount_usd', ps.amount,
        'currency', ps.currency,
        'unit', ps.unit,
        'description', ps.description,
        'public_value', ps.public_value,
        'display_order', ps.display_order
      ) order by ps.display_order, ps.display_name)
      from public.lavida_pricing_settings ps
      where ps.section = 'professional_services'
        and ps.is_active = true
        and ps.public_value ->> 'area' = 'digital'
    ), '[]'::jsonb),
    'payment_methods', coalesce((
      select jsonb_agg(to_jsonb(pm) order by pm.display_order, pm.display_name)
      from public.get_public_lavida_payment_methods('professional_services') pm
    ), '[]'::jsonb),
    'exchange_rate', case when v_rate.id is null then null else jsonb_build_object(
      'configured', true,
      'currency', 'MWK',
      'unit', 'per_usd',
      'amount', v_rate.amount,
      'updated_at', v_rate.updated_at
    ) end,
    'quote_validity_minutes', coalesce(v_validity.amount, 30)
  );
end;
$$;

create or replace function public.submit_digital_service_checkout(p_order jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_package public.lavida_pricing_settings%rowtype;
  v_method public.payment_methods%rowtype;
  v_rate public.lavida_pricing_settings%rowtype;
  v_validity_minutes numeric := 30;
  v_request public.service_requests%rowtype;
  v_quote public.service_payment_quotes%rowtype;
  v_payment public.service_payments%rowtype;
  v_package_code text := nullif(trim(coalesce(p_order ->> 'package_code', '')), '');
  v_payment_method_id uuid := nullif(trim(coalesce(p_order ->> 'payment_method_id', '')), '')::uuid;
  v_quantity numeric := coalesce(nullif(p_order ->> 'quantity', '')::numeric, 1);
  v_total_usd numeric;
  v_payable_currency text;
  v_payable_amount numeric;
  v_rate_amount numeric;
  v_reference text := nullif(trim(coalesce(p_order ->> 'payment_reference', '')), '');
  v_checkout_id text := nullif(trim(coalesce(p_order ->> 'idempotency_key', '')), '');
  v_requires_mwk boolean := false;
  v_quote_reference text;
begin
  if v_user is null then
    raise exception 'Sign in is required to submit a service checkout.' using errcode = '42501';
  end if;
  if v_package_code is null then raise exception 'Choose a service package.'; end if;
  if v_quantity <= 0 then raise exception 'Quantity must be greater than zero.'; end if;

  if v_checkout_id is not null then
    select * into v_request
    from public.service_requests
    where user_id = v_user and customer_checkout_id = v_checkout_id
    limit 1;
    if found then
      select * into v_quote from public.service_payment_quotes where request_id = v_request.id order by created_at desc limit 1;
      return jsonb_build_object('request', to_jsonb(v_request), 'payment_quote', case when v_quote.id is null then null else to_jsonb(v_quote) end, 'duplicate', true);
    end if;
  end if;

  select * into v_package
  from public.lavida_pricing_settings
  where section = 'professional_services'
    and setting_code = v_package_code
    and is_active = true
    and public_value ->> 'area' = 'digital'
  limit 1;

  if not found then raise exception 'This service package is not available.'; end if;
  if coalesce((v_package.public_value ->> 'quantity_allowed')::boolean, false) = false and v_quantity <> 1 then
    raise exception 'This package does not support quantity multiplication.';
  end if;

  if v_package.pricing_mode = 'custom_quote' or v_package.amount is null or upper(v_package.currency) <> 'USD' then
    insert into public.service_requests (
      user_id, request_number, service_area, service_area_name, service_code, service_name,
      commercial_route, status, title, description, deadline, contact_name, contact_phone,
      contact_email, existing_website_url, answers, uploaded_file_count, quote_status,
      invoice_status, payment_status, selected_package_code, selected_package_name, quantity,
      billing_unit, pricing_snapshot, customer_checkout_id
    )
    values (
      v_user,
      'LVD-DS-' || to_char(now(), 'YYMMDD') || '-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 6)),
      'digital',
      'Digital & Systems Support',
      coalesce(v_package.public_value ->> 'service_code', 'digital'),
      v_package.display_name,
      'custom_quote',
      'submitted',
      coalesce(nullif(trim(p_order ->> 'title'), ''), v_package.display_name),
      coalesce(nullif(trim(p_order ->> 'description'), ''), v_package.description, v_package.display_name),
      nullif(p_order ->> 'deadline', '')::date,
      nullif(trim(coalesce(p_order ->> 'contact_name', '')), ''),
      nullif(trim(coalesce(p_order ->> 'contact_phone', '')), ''),
      nullif(trim(coalesce(p_order ->> 'contact_email', '')), ''),
      nullif(trim(coalesce(p_order ->> 'existing_website_url', '')), ''),
      coalesce(p_order -> 'answers', '{}'::jsonb) || jsonb_build_object('package_code', v_package.setting_code, 'package_name', v_package.display_name, 'custom_quote_required', true),
      coalesce(nullif(p_order ->> 'uploaded_file_count', '')::integer, 0),
      'none',
      'none',
      'not_required_yet',
      v_package.setting_code,
      v_package.display_name,
      v_quantity,
      v_package.unit,
      jsonb_build_object('package', to_jsonb(v_package) - 'private_value', 'reason', 'missing_approved_usd_price'),
      v_checkout_id
    )
    returning * into v_request;

    insert into public.service_project_updates(request_id, created_by, visible_to_customer, update_type, message)
    values (v_request.id, v_user, true, 'status', 'Quote request submitted for LAVIDA review.');

    return jsonb_build_object('request', to_jsonb(v_request), 'payment_quote', null, 'requires_payment', false, 'quote_only', true);
  end if;

  if v_payment_method_id is null then raise exception 'Choose a payment method.'; end if;

  select * into v_method
  from public.payment_methods
  where id = v_payment_method_id
    and is_active = true
    and archived_at is null
    and 'professional_services' = any(applies_to)
  limit 1;

  if not found then raise exception 'This payment method is not available for Digital & Systems Support.'; end if;

  v_total_usd := round((v_package.amount * v_quantity)::numeric, 2);
  v_requires_mwk := upper(v_method.currency) = 'MWK'
    or v_method.method_type = 'mobile_money'
    or v_method.method_code in ('airtel_money','tnm_mpamba','shared_mobile_money','mobile_money');

  if v_requires_mwk then
    select * into v_rate
    from public.lavida_pricing_settings
    where section = 'payment_rules'
      and setting_code = 'usd_mwk_exchange_rate'
      and is_active = true
      and amount is not null
      and amount > 0
    limit 1;
    if not found then raise exception 'MWK payment is temporarily unavailable because the USD to MWK exchange rate is not configured.'; end if;
    v_rate_amount := v_rate.amount;
    v_payable_currency := 'MWK';
    v_payable_amount := round((v_total_usd * v_rate_amount)::numeric, 0);
  elsif upper(v_method.currency) = 'USD' then
    v_payable_currency := 'USD';
    v_payable_amount := v_total_usd;
  else
    raise exception 'This payment currency is not supported for Digital & Systems Support checkout.';
  end if;

  select coalesce(amount, 30) into v_validity_minutes
  from public.lavida_pricing_settings
  where section = 'payment_rules'
    and setting_code = 'service_payment_quote_validity'
    and is_active = true
    and amount is not null
    and amount > 0
  limit 1;

  insert into public.service_requests (
    user_id, request_number, service_area, service_area_name, service_code, service_name,
    commercial_route, status, title, description, deadline, contact_name, contact_phone,
    contact_email, existing_website_url, answers, uploaded_file_count, quote_status,
    invoice_status, payment_status, selected_package_code, selected_package_name, quantity,
    billing_unit, unit_price_usd, service_total_usd, payable_currency, payable_amount,
    payment_method_id, payment_method_name, payment_recipient_name, payment_destination,
    payment_instructions_snapshot, pricing_snapshot, customer_checkout_id
  )
  values (
    v_user,
    'LVD-DS-' || to_char(now(), 'YYMMDD') || '-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 6)),
    'digital',
    'Digital & Systems Support',
    coalesce(v_package.public_value ->> 'service_code', 'digital'),
    v_package.display_name,
    'fixed_price',
    'awaiting_payment',
    coalesce(nullif(trim(p_order ->> 'title'), ''), v_package.display_name),
    coalesce(nullif(trim(p_order ->> 'description'), ''), v_package.description, v_package.display_name),
    nullif(p_order ->> 'deadline', '')::date,
    nullif(trim(coalesce(p_order ->> 'contact_name', '')), ''),
    nullif(trim(coalesce(p_order ->> 'contact_phone', '')), ''),
    nullif(trim(coalesce(p_order ->> 'contact_email', '')), ''),
    nullif(trim(coalesce(p_order ->> 'existing_website_url', '')), ''),
    coalesce(p_order -> 'answers', '{}'::jsonb) || jsonb_build_object('package_code', v_package.setting_code, 'package_name', v_package.display_name),
    coalesce(nullif(p_order ->> 'uploaded_file_count', '')::integer, 0),
    'none',
    'none',
    case when v_reference is null then 'awaiting_payment' else 'pending_verification' end,
    v_package.setting_code,
    v_package.display_name,
    v_quantity,
    v_package.unit,
    v_package.amount,
    v_total_usd,
    v_payable_currency,
    v_payable_amount,
    v_method.id,
    v_method.display_name,
    v_method.recipient_name,
    coalesce(v_method.payment_number, v_method.bank_name),
    v_method.customer_instructions,
    jsonb_build_object(
      'package', to_jsonb(v_package) - 'private_value',
      'quantity', v_quantity,
      'unit_price_usd', v_package.amount,
      'service_total_usd', v_total_usd,
      'payment_method', to_jsonb(v_method) - 'updated_by',
      'exchange_rate_mwk_per_usd', v_rate_amount,
      'payable_currency', v_payable_currency,
      'payable_amount', v_payable_amount
    ),
    v_checkout_id
  )
  returning * into v_request;

  v_quote_reference := 'LVD-PQ-' || to_char(now(), 'YYMMDD') || '-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 6));

  insert into public.service_payment_quotes (
    request_id, quote_reference, payment_method_id, payment_method_code, payment_method_name,
    base_total_usd, exchange_rate_mwk_per_usd, exchange_rate_captured_at, payable_currency,
    payable_amount, rounding_adjustment_mwk, recipient_name, payment_destination,
    payment_instructions_snapshot, status, expires_at
  )
  values (
    v_request.id, v_quote_reference, v_method.id, v_method.method_code, v_method.display_name,
    v_total_usd, v_rate_amount, case when v_rate_amount is null then null else now() end,
    v_payable_currency, v_payable_amount,
    case when v_payable_currency = 'MWK' then v_payable_amount - (v_total_usd * v_rate_amount) else null end,
    v_method.recipient_name, coalesce(v_method.payment_number, v_method.bank_name),
    v_method.customer_instructions,
    case when v_reference is null then 'active' else 'payment_submitted' end,
    now() + make_interval(mins => v_validity_minutes::integer)
  )
  returning * into v_quote;

  if v_reference is not null then
    insert into public.service_payments (
      request_id, payment_quote_id, payment_method_id, payment_method_code, payment_method_name,
      base_total_usd, exchange_rate_mwk_per_usd, payable_currency, payable_amount,
      transaction_reference, status, submitted_by
    )
    values (
      v_request.id, v_quote.id, v_method.id, v_method.method_code, v_method.display_name,
      v_total_usd, v_rate_amount, v_payable_currency, v_payable_amount,
      v_reference, 'pending_verification', v_user
    )
    returning * into v_payment;
  end if;

  insert into public.service_project_updates(request_id, created_by, visible_to_customer, update_type, message)
  values (
    v_request.id,
    v_user,
    true,
    'payment',
    case when v_reference is null then 'Payment quote created. Submit payment before the quote expires.' else 'Payment submitted for verification.' end
  );

  return jsonb_build_object(
    'request', to_jsonb(v_request),
    'payment_quote', to_jsonb(v_quote),
    'payment', case when v_payment.id is null then null else to_jsonb(v_payment) end,
    'requires_payment', true,
    'quote_only', false
  );
end;
$$;

alter table public.service_payment_quotes enable row level security;
alter table public.service_payments enable row level security;

grant select on public.service_payment_quotes, public.service_payments to authenticated;

drop policy if exists "Customers and admins view service payment quotes" on public.service_payment_quotes;
create policy "Customers and admins view service payment quotes"
  on public.service_payment_quotes for select to authenticated
  using (
    public.lavida_is_service_admin()
    or exists (select 1 from public.service_requests sr where sr.id = request_id and sr.user_id = auth.uid())
  );

drop policy if exists "Customers and admins view service payments" on public.service_payments;
create policy "Customers and admins view service payments"
  on public.service_payments for select to authenticated
  using (
    public.lavida_is_service_admin()
    or exists (select 1 from public.service_requests sr where sr.id = request_id and sr.user_id = auth.uid())
  );

drop policy if exists "Admins manage service payment quotes" on public.service_payment_quotes;
create policy "Admins manage service payment quotes"
  on public.service_payment_quotes for all to authenticated
  using (public.lavida_is_service_admin())
  with check (public.lavida_is_service_admin());

drop policy if exists "Admins manage service payments" on public.service_payments;
create policy "Admins manage service payments"
  on public.service_payments for all to authenticated
  using (public.lavida_is_service_admin())
  with check (public.lavida_is_service_admin());

revoke all on function public.get_public_digital_service_checkout() from public;
revoke all on function public.submit_digital_service_checkout(jsonb) from public;
grant execute on function public.get_public_digital_service_checkout() to anon, authenticated;
grant execute on function public.submit_digital_service_checkout(jsonb) to authenticated;
