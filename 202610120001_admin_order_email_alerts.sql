create extension if not exists pgcrypto;
create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron with schema extensions;

-- ============================================================
-- LAVIDA Admin Order Email Alerts
-- Every new order notifies whichever admins have been assigned
-- to receive order alert emails. Assignment is managed inside
-- the app by the super admin (giyanichirwa@gmail.com).
-- ============================================================

-- 1. Config -------------------------------------------------
create table if not exists public.admin_alert_config (
  id integer primary key default 1 check (id = 1),
  super_admin_email text not null default 'giyanichirwa@gmail.com',
  email_enabled boolean not null default true,
  from_name text not null default 'LAVIDA Connect',
  from_email text not null default 'info@lavida.agency',
  reply_to_email text,
  send_worker_url text,
  app_base_url text not null default 'https://app.lavida.agency',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

insert into public.admin_alert_config (id)
values (1)
on conflict (id) do nothing;

-- 2. Recipients ---------------------------------------------
create table if not exists public.admin_alert_recipients (
  id uuid primary key default gen_random_uuid(),
  email text not null,
  display_name text,
  is_super_admin boolean not null default false,
  receives_order_alerts boolean not null default true,
  can_manage_recipients boolean not null default false,
  active boolean not null default true,
  notes text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint admin_alert_recipients_email_check
    check (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$')
);

create unique index if not exists admin_alert_recipients_email_idx
  on public.admin_alert_recipients (lower(email));
create index if not exists admin_alert_recipients_active_idx
  on public.admin_alert_recipients (active, receives_order_alerts);

-- 3. Email queue --------------------------------------------
create table if not exists public.admin_alert_email_queue (
  id uuid primary key default gen_random_uuid(),
  notification_id uuid references public.notifications(id) on delete set null,
  recipient_email text not null,
  recipient_name text,
  event_type text not null,
  subject text not null,
  body_text text not null,
  body_html text,
  order_type text,
  order_id text,
  order_reference text,
  status text not null default 'queued' check (status in ('queued','processing','sent','failed','skipped')),
  attempts integer not null default 0,
  last_error text,
  provider_message_id text,
  queued_at timestamptz not null default now(),
  sent_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists admin_alert_email_queue_status_idx
  on public.admin_alert_email_queue (status, queued_at);
create index if not exists admin_alert_email_queue_recipient_idx
  on public.admin_alert_email_queue (lower(recipient_email), created_at desc);
create index if not exists admin_alert_email_queue_order_idx
  on public.admin_alert_email_queue (order_type, order_id);

-- 4. Audit log ----------------------------------------------
create table if not exists public.admin_alert_log (
  id uuid primary key default gen_random_uuid(),
  event_type text not null,
  order_type text,
  order_id text,
  order_reference text,
  notification_id uuid references public.notifications(id) on delete set null,
  recipients_count integer not null default 0,
  detail jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists admin_alert_log_created_idx
  on public.admin_alert_log (created_at desc);

-- 5. Keep recipient flags aligned with the super admin --------
create or replace function public.lavida_admin_alert_super_email()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select lower(coalesce(
    (select super_admin_email from public.admin_alert_config where id = 1),
    'giyanichirwa@gmail.com'
  ));
$$;

create or replace function public.lavida_is_admin_alert_recipient()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.admin_alert_recipients r
    where lower(r.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
      and r.active = true
  );
$$;

-- Who is allowed to open / manage the alert console?
create or replace function public.lavida_is_admin_alert_manager()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(auth.role(), '') = 'service_role'
    or lower(coalesce(auth.jwt() ->> 'email', '')) = public.lavida_admin_alert_super_email()
    or exists (
      select 1
      from public.admin_alert_recipients r
      where lower(r.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
        and r.active = true
        and r.can_manage_recipients = true
    )
    or exists (
      select 1
      from public.user_roles ur
      where lower(ur.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
        and coalesce(ur.active, true) = true
        and lower(ur.role) in ('owner','admin','executive','manager','notification_admin')
    );
$$;

-- 6. Recipient management API ---------------------------------
create or replace function public.lavida_list_admin_alert_recipients()
returns setof public.admin_alert_recipients
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.lavida_is_admin_alert_manager() then
    raise exception 'Access denied.' using errcode = '42501';
  end if;
  return query
    select *
    from public.admin_alert_recipients
    order by is_super_admin desc, active desc, lower(email);
end;
$$;

grant execute on function public.lavida_list_admin_alert_recipients() to authenticated;

create or replace function public.lavida_save_admin_alert_recipient(
  p_id uuid,
  p_email text,
  p_display_name text default null,
  p_receives_order_alerts boolean default true,
  p_can_manage_recipients boolean default false,
  p_active boolean default true,
  p_notes text default null
)
returns public.admin_alert_recipients
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.admin_alert_recipients%rowtype;
  v_email text := lower(trim(coalesce(p_email, '')));
begin
  if not public.lavida_is_admin_alert_manager() then
    raise exception 'Access denied.' using errcode = '42501';
  end if;

  if v_email = '' or v_email !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'A valid email address is required.';
  end if;

  if p_id is null then
    insert into public.admin_alert_recipients (
      email, display_name, receives_order_alerts, can_manage_recipients, active, notes, created_by
    )
    values (
      v_email,
      nullif(trim(coalesce(p_display_name, '')), ''),
      coalesce(p_receives_order_alerts, true),
      coalesce(p_can_manage_recipients, false),
      coalesce(p_active, true),
      nullif(trim(coalesce(p_notes, '')), ''),
      auth.uid()
    )
    on conflict (lower(email)) do update
    set display_name = excluded.display_name,
        receives_order_alerts = excluded.receives_order_alerts,
        can_manage_recipients = excluded.can_manage_recipients,
        active = excluded.active,
        notes = excluded.notes,
        updated_at = now()
    returning * into v_row;
  else
    update public.admin_alert_recipients
    set email = v_email,
        display_name = nullif(trim(coalesce(p_display_name, '')), ''),
        receives_order_alerts = coalesce(p_receives_order_alerts, true),
        can_manage_recipients = coalesce(p_can_manage_recipients, false),
        active = coalesce(p_active, true),
        notes = nullif(trim(coalesce(p_notes, '')), '')
    where id = p_id
    returning * into v_row;

    if not found then
      raise exception 'Recipient not found.';
    end if;
  end if;

  -- The super admin always receives order alerts and can always manage.
  if lower(v_row.email) = public.lavida_admin_alert_super_email() then
    update public.admin_alert_recipients
    set is_super_admin = true,
        receives_order_alerts = true,
        can_manage_recipients = true,
        active = true
    where id = v_row.id
    returning * into v_row;
  end if;

  return v_row;
end;
$$;

grant execute on function public.lavida_save_admin_alert_recipient(uuid,text,text,boolean,boolean,boolean,text) to authenticated;

create or replace function public.lavida_delete_admin_alert_recipient(p_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.lavida_is_admin_alert_manager() then
    raise exception 'Access denied.' using errcode = '42501';
  end if;

  if exists (
    select 1 from public.admin_alert_recipients
    where id = p_id and is_super_admin = true
  ) then
    raise exception 'The super admin recipient cannot be removed.';
  end if;

  delete from public.admin_alert_recipients where id = p_id;
  return found;
end;
$$;

grant execute on function public.lavida_delete_admin_alert_recipient(uuid) to authenticated;

create or replace function public.lavida_save_admin_alert_config(
  p_email_enabled boolean default null,
  p_from_name text default null,
  p_from_email text default null,
  p_reply_to_email text default null,
  p_send_worker_url text default null,
  p_app_base_url text default null
)
returns public.admin_alert_config
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.admin_alert_config%rowtype;
begin
  if not public.lavida_is_admin_alert_manager() then
    raise exception 'Access denied.' using errcode = '42501';
  end if;

  update public.admin_alert_config
  set email_enabled = coalesce(p_email_enabled, email_enabled),
      from_name = coalesce(nullif(trim(coalesce(p_from_name, '')), ''), from_name),
      from_email = coalesce(nullif(trim(coalesce(p_from_email, '')), ''), from_email),
      reply_to_email = coalesce(nullif(trim(coalesce(p_reply_to_email, '')), ''), reply_to_email),
      send_worker_url = coalesce(nullif(trim(coalesce(p_send_worker_url, '')), ''), send_worker_url),
      app_base_url = coalesce(nullif(trim(coalesce(p_app_base_url, '')), ''), app_base_url)
  where id = 1
  returning * into v_row;

  return v_row;
end;
$$;

grant execute on function public.lavida_save_admin_alert_config(boolean,text,text,text,text,text) to authenticated;

-- 7. Email composer + queueing --------------------------------
create or replace function public.lavida_admin_alert_html(
  p_title text,
  p_body text,
  p_order_type text,
  p_order_reference text,
  p_action_url text,
  p_details jsonb default '{}'::jsonb
)
returns text
language plpgsql
immutable
as $$
declare
  v_rows text := '';
  v_key text;
  v_value text;
begin
  for v_key, v_value in
    select key, value #>> '{}'
    from jsonb_each(coalesce(p_details, '{}'::jsonb))
    where value is not null and value <> 'null'::jsonb and value <> '""'::jsonb
  loop
    v_rows := v_rows || '<tr>'
      || '<td style="padding:7px 12px;border-bottom:1px solid #e3e8f0;color:#667085;font:600 13px Inter,Arial,sans-serif;white-space:nowrap">'
      || replace(initcap(replace(v_key, '_', ' ')), '&', '&amp;') || '</td>'
      || '<td style="padding:7px 12px;border-bottom:1px solid #e3e8f0;color:#061433;font:700 13px Inter,Arial,sans-serif">'
      || replace(replace(coalesce(v_value, ''), '&', '&amp;'), '<', '&lt;') || '</td>'
      || '</tr>';
  end loop;

  return '<div style="background:#f3f5f8;padding:22px 12px">'
    || '<div style="max-width:620px;margin:auto;background:#fff;border:1px solid #dfe5ee;border-radius:14px;overflow:hidden;box-shadow:0 14px 34px rgba(6,20,51,.10)">'
    || '<div style="background:#03163d;padding:18px 22px">'
    || '<div style="color:#fff;font:900 22px Inter,Arial,sans-serif;letter-spacing:1px">LAVIDA</div>'
    || '<div style="color:#f5b821;font:900 11px Inter,Arial,sans-serif;letter-spacing:2px;text-transform:uppercase;margin-top:3px">New Order Alert</div>'
    || '</div>'
    || '<div style="padding:22px">'
    || '<h1 style="margin:0 0 8px;color:#03163d;font:900 20px Inter,Arial,sans-serif">' || replace(coalesce(p_title, 'New Order'), '&', '&amp;') || '</h1>'
    || '<p style="margin:0 0 16px;color:#4a5568;font:500 14px Inter,Arial,sans-serif;line-height:1.6">' || replace(coalesce(p_body, ''), '&', '&amp;') || '</p>'
    || '<table style="width:100%;border-collapse:collapse;border:1px solid #dfe5ee;border-radius:10px;overflow:hidden">' || v_rows || '</table>'
    || case when coalesce(p_action_url, '') <> '' then
         '<div style="margin-top:18px"><a href="' || p_action_url || '" style="display:inline-block;background:#03163d;color:#fff;text-decoration:none;padding:12px 20px;border-radius:10px;font:900 14px Inter,Arial,sans-serif">Open In App</a></div>'
       else '' end
    || '<p style="margin:18px 0 0;color:#98a2b3;font:600 12px Inter,Arial,sans-serif">Sent automatically because you are assigned to receive LAVIDA order alerts.</p>'
    || '</div></div></div>';
end;
$$;

create or replace function public.lavida_send_admin_order_alert(
  p_event_type text,
  p_order_type text,
  p_order_id text,
  p_order_reference text,
  p_title text,
  p_summary text,
  p_details jsonb default '{}'::jsonb,
  p_action_url text default null,
  p_idempotency_key text default null
)
returns integer
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_cfg public.admin_alert_config%rowtype;
  v_recipient record;
  v_count integer := 0;
  v_subject text;
  v_html text;
  v_link text;
  v_notification_id uuid;
  v_seen text[] := '{}';
begin
  select * into v_cfg from public.admin_alert_config where id = 1;
  if v_cfg.id is null then
    return 0;
  end if;

  -- Record the alert regardless of email state so the console has a full trail.
  insert into public.admin_alert_log (
    event_type, order_type, order_id, order_reference, detail
  )
  values (
    p_event_type, p_order_type, p_order_id, p_order_reference,
    jsonb_build_object('title', p_title, 'summary', p_summary, 'details', p_details)
  );

  if not coalesce(v_cfg.email_enabled, true) then
    return 0;
  end if;

  v_link := coalesce(nullif(p_action_url, ''), v_cfg.app_base_url || '/marketplace.html#orders');
  v_subject := '[LAVIDA Order] ' || coalesce(nullif(p_title, ''), 'New Order')
    || case when coalesce(p_order_reference, '') <> '' then ' - ' || p_order_reference else '' end;
  v_html := public.lavida_admin_alert_html(p_title, p_summary, p_order_type, p_order_reference, v_link, p_details);

  for v_recipient in
    select r.email, r.display_name
    from public.admin_alert_recipients r
    where r.active = true
      and r.receives_order_alerts = true
      and r.email is not null
      and trim(r.email) <> ''
    order by r.is_super_admin desc, lower(r.email)
  loop
    -- De-duplicate case-insensitively in case rows somehow overlap.
    if lower(v_recipient.email) = any (v_seen) then
      continue;
    end if;
    v_seen := v_seen || lower(v_recipient.email);

    insert into public.admin_alert_email_queue (
      recipient_email, recipient_name, event_type, subject,
      body_text, body_html, order_type, order_id, order_reference, status
    )
    values (
      lower(v_recipient.email),
      nullif(trim(coalesce(v_recipient.display_name, '')), ''),
      p_event_type,
      v_subject,
      p_summary,
      v_html,
      p_order_type,
      p_order_id,
      p_order_reference,
      'queued'
    )
    on conflict do nothing;

    v_count := v_count + 1;
  end loop;

  -- Leave an in-app breadcrumb for the assigned recipients.
  for v_recipient in
    select r.email, r.display_name
    from public.admin_alert_recipients r
    where r.active = true
      and r.receives_order_alerts = true
      and r.email is not null
      and trim(r.email) <> ''
  loop
    begin
      perform public.create_lavida_notification(
        null, lower(v_recipient.email), p_event_type, 'marketplace',
        coalesce(nullif(p_title, ''), 'New Order'),
        coalesce(nullif(p_summary, ''), 'A new order was placed.'),
        'Open Orders', coalesce(nullif(p_action_url, ''), 'marketplace.html#orders'),
        p_order_type, p_order_id, 'transactional', 'LAVIDA Admin',
        p_idempotency_key || ':inapp:' || lower(v_recipient.email),
        jsonb_build_object('order_reference', p_order_reference, 'admin_alert', true),
        false
      );
    exception when others then
      null;
    end;
  end loop;

  -- Kick the email worker so delivery does not wait for the cron tick.
  begin
    perform public.lavida_dispatch_admin_alert_emails(50);
  exception when others then
    null;
  end;

  update public.admin_alert_log
  set recipients_count = v_count
  where id = (
    select id from public.admin_alert_log
    order by created_at desc
    limit 1
  );

  return v_count;
end;
$$;

grant execute on function public.lavida_send_admin_order_alert(text,text,text,text,text,text,jsonb,text,text) to authenticated;

-- 8. Worker dispatch -----------------------------------------
create or replace function public.lavida_dispatch_admin_alert_emails(p_limit integer default 50)
returns void
language plpgsql
security definer
set search_path = public, vault
as $$
declare
  v_url text;
  v_secret text;
  v_pending integer;
begin
  select nullif(send_worker_url, '') into v_url
  from public.admin_alert_config where id = 1;

  select decrypted_secret into v_secret
  from vault.decrypted_secrets
  where name = 'lavida_admin_alert_worker_secret'
  order by updated_at desc
  limit 1;

  if v_url is null or nullif(v_secret, '') is null then
    return;
  end if;

  select count(*) into v_pending
  from public.admin_alert_email_queue
  where status = 'queued';

  if coalesce(v_pending, 0) = 0 then
    return;
  end if;

  perform net.http_post(
    url := v_url,
    body := jsonb_build_object('limit', greatest(1, least(100, coalesce(p_limit, 50)))),
    params := '{}'::jsonb,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-lavida-admin-alert-secret', v_secret
    ),
    timeout_milliseconds := 8000
  );
end;
$$;

grant execute on function public.lavida_dispatch_admin_alert_emails(integer) to authenticated;

create or replace function public.lavida_dispatch_admin_alert_emails_safe(p_limit integer default 50)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  begin
    perform public.lavida_dispatch_admin_alert_emails(p_limit);
  exception when others then
    raise warning 'LAVIDA admin alert email dispatch request failed: %', sqlerrm;
  end;
end;
$$;

do $$
begin
  perform cron.unschedule('lavida-admin-alert-email-worker');
exception when others then
  null;
end $$;

select cron.schedule(
  'lavida-admin-alert-email-worker',
  '* * * * *',
  'select public.lavida_dispatch_admin_alert_emails_safe(50);'
);

-- 9. Order triggers -----------------------------------------
create or replace function public.lavida_admin_alert_money(p_value numeric)
returns text
language sql
immutable
as $$
  select case
    when p_value is null then null
    else 'MWK ' || to_char(p_value, 'FM999,999,999,990.00')
  end;
$$;

-- Marketplace orders (which includes crypto orders)
create or replace function public.notify_admin_marketplace_order()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_reference text;
  v_customer text;
  v_total numeric;
  v_items text;
  v_details jsonb;
begin
  v_reference := coalesce(new.order_reference, new.id::text);
  v_customer := coalesce(nullif(trim(coalesce(new.customer_name, '')), ''), 'Customer');
  v_total := coalesce(new.grand_total, new.total, new.subtotal);

  if tg_op = 'INSERT' then
    select string_agg(
             coalesce(i.product_name, 'Item') || ' x' || coalesce(i.quantity, 1),
             ', '
           )
    into v_items
    from public.marketplace_order_items i
    where i.order_id = new.id;

    v_details := jsonb_build_object(
      'order_reference', v_reference,
      'customer', v_customer,
      'phone', new.phone,
      'email', new.email,
      'order_type', coalesce(new.order_type, 'standard'),
      'items', v_items,
      'total', public.lavida_admin_alert_money(v_total),
      'payment_method', new.payment_method,
      'fulfilment', new.fulfilment_method,
      'placed_at', to_char(coalesce(new.created_at, now()), 'YYYY-MM-DD HH24:MI')
    );

    perform public.lavida_send_admin_order_alert(
      'admin_order_alert_marketplace',
      'marketplace_order',
      new.id::text,
      v_reference,
      'New Marketplace Order',
      v_customer || ' placed a new marketplace order worth ' || coalesce(public.lavida_admin_alert_money(v_total), 'an unknown amount') || '.',
      v_details,
      'marketplace.html#orders',
      'admin-alert:marketplace-order:' || new.id::text || ':created'
    );
    return new;
  end if;

  -- On update only alert for meaningful state changes.
  if coalesce(old.order_status, '') is not distinct from coalesce(new.order_status, '')
     and coalesce(old.payment_status, '') is not distinct from coalesce(new.payment_status, '') then
    return new;
  end if;

  v_details := jsonb_build_object(
    'order_reference', v_reference,
    'customer', v_customer,
    'order_type', coalesce(new.order_type, 'standard'),
    'order_status', new.order_status,
    'payment_status', new.payment_status,
    'total', public.lavida_admin_alert_money(v_total),
    'updated_at', to_char(now(), 'YYYY-MM-DD HH24:MI')
  );

  perform public.lavida_send_admin_order_alert(
    'admin_order_updated_marketplace',
    'marketplace_order',
    new.id::text,
    v_reference,
    'Marketplace Order Updated',
    'Order ' || v_reference || ' is now ' || coalesce(new.order_status, 'updated')
      || ' (payment: ' || coalesce(new.payment_status, 'unknown') || ').',
    v_details,
    'marketplace.html#orders',
    'admin-alert:marketplace-order:' || new.id::text || ':' || coalesce(new.order_status, '') || ':' || coalesce(new.payment_status, '')
  );

  return new;
end;
$$;

-- Printing orders
create or replace function public.notify_admin_printing_order()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_reference text;
  v_customer text;
  v_details jsonb;
begin
  v_reference := coalesce(new.order_number, new.id::text);
  v_customer := coalesce(nullif(trim(coalesce(new.customer_name, '')), ''), 'Customer');

  if tg_op = 'INSERT' then
    v_details := jsonb_build_object(
      'order_number', v_reference,
      'customer', v_customer,
      'phone', new.customer_phone,
      'email', new.customer_email,
      'total', public.lavida_admin_alert_money(new.total_amount),
      'production_status', new.production_status,
      'payment_status', new.payment_status,
      'placed_at', to_char(coalesce(new.created_at, now()), 'YYYY-MM-DD HH24:MI')
    );

    perform public.lavida_send_admin_order_alert(
      'admin_order_alert_printing',
      'printing_order',
      new.id::text,
      v_reference,
      'New Printing Order',
      v_customer || ' submitted printing order ' || v_reference || '.',
      v_details,
      'marketplace.html#printing-orders',
      'admin-alert:printing-order:' || new.id::text || ':created'
    );
    return new;
  end if;

  if coalesce(old.production_status, '') = coalesce(new.production_status, '')
     and coalesce(old.payment_status, '') = coalesce(new.payment_status, '') then
    return new;
  end if;

  v_details := jsonb_build_object(
    'order_number', v_reference,
    'customer', v_customer,
    'production_status', new.production_status,
    'payment_status', new.payment_status,
    'total', public.lavida_admin_alert_money(new.total_amount),
    'updated_at', to_char(now(), 'YYYY-MM-DD HH24:MI')
  );

  perform public.lavida_send_admin_order_alert(
    'admin_order_updated_printing',
    'printing_order',
    new.id::text,
    v_reference,
    'Printing Order Updated',
    'Printing order ' || v_reference || ' is now ' || coalesce(new.production_status, 'updated') || '.',
    v_details,
    'marketplace.html#printing-orders',
    'admin-alert:printing-order:' || new.id::text || ':' || coalesce(new.production_status, '') || ':' || coalesce(new.payment_status, '')
  );

  return new;
end;
$$;

-- Service requests
create or replace function public.notify_admin_service_request()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_details jsonb;
begin
  v_details := jsonb_build_object(
    'request_number', new.request_number,
    'service', new.service_name,
    'service_area', new.service_area_name,
    'customer', new.contact_name,
    'phone', new.contact_phone,
    'email', new.contact_email,
    'title', new.title,
    'deadline', new.deadline,
    'submitted_at', to_char(coalesce(new.created_at, now()), 'YYYY-MM-DD HH24:MI')
  );

  perform public.lavida_send_admin_order_alert(
    'admin_order_alert_service_request',
    'service_request',
    new.id::text,
    new.request_number,
    'New Service Request',
    new.contact_name || ' submitted request ' || new.request_number
      || ' for ' || coalesce(new.service_name, 'a service') || '.',
    v_details,
    'service-requests-admin.html',
    'admin-alert:service-request:' || new.id::text || ':created'
  );

  return new;
end;
$$;

do $$
begin
  if to_regclass('public.marketplace_orders') is not null then
    drop trigger if exists lavida_admin_alert_marketplace_order_insert on public.marketplace_orders;
    create trigger lavida_admin_alert_marketplace_order_insert
    after insert on public.marketplace_orders
    for each row execute function public.notify_admin_marketplace_order();

    drop trigger if exists lavida_admin_alert_marketplace_order_update on public.marketplace_orders;
    create trigger lavida_admin_alert_marketplace_order_update
    after update on public.marketplace_orders
    for each row execute function public.notify_admin_marketplace_order();
  end if;

  if to_regclass('public.printing_orders') is not null then
    drop trigger if exists lavida_admin_alert_printing_order_insert on public.printing_orders;
    create trigger lavida_admin_alert_printing_order_insert
    after insert on public.printing_orders
    for each row execute function public.notify_admin_printing_order();

    drop trigger if exists lavida_admin_alert_printing_order_update on public.printing_orders;
    create trigger lavida_admin_alert_printing_order_update
    after update on public.printing_orders
    for each row execute function public.notify_admin_printing_order();
  end if;

  if to_regclass('public.service_requests') is not null then
    drop trigger if exists lavida_admin_alert_service_request_insert on public.service_requests;
    create trigger lavida_admin_alert_service_request_insert
    after insert on public.service_requests
    for each row execute function public.notify_admin_service_request();
  end if;
end $$;

-- 10. Seed the super admin -------------------------------------
insert into public.admin_alert_recipients (
  email, display_name, is_super_admin, receives_order_alerts, can_manage_recipients, active, notes
)
values (
  lower((select super_admin_email from public.admin_alert_config where id = 1)),
  'Super Admin',
  true, true, true, true,
  'Primary LAVIDA super admin. Always receives order alert emails.'
)
on conflict (lower(email)) do update
set is_super_admin = true,
    receives_order_alerts = true,
    can_manage_recipients = true,
    active = true,
    display_name = coalesce(public.admin_alert_recipients.display_name, excluded.display_name),
    updated_at = now();

-- 11. RLS + grants ---------------------------------------------
alter table public.admin_alert_config enable row level security;
alter table public.admin_alert_recipients enable row level security;
alter table public.admin_alert_email_queue enable row level security;
alter table public.admin_alert_log enable row level security;

grant select on public.admin_alert_config to authenticated;
grant select on public.admin_alert_recipients to authenticated;
grant select on public.admin_alert_email_queue to authenticated;
grant select on public.admin_alert_log to authenticated;

-- Writes only through the security-definer RPCs above.
revoke insert, update, delete on public.admin_alert_config from anon, authenticated;
revoke insert, update, delete on public.admin_alert_recipients from anon, authenticated;

drop policy if exists "Managers read admin alert config" on public.admin_alert_config;
create policy "Managers read admin alert config"
  on public.admin_alert_config for select to authenticated
  using (public.lavida_is_admin_alert_manager());

drop policy if exists "Managers read admin alert recipients" on public.admin_alert_recipients;
create policy "Managers read admin alert recipients"
  on public.admin_alert_recipients for select to authenticated
  using (public.lavida_is_admin_alert_manager());

drop policy if exists "Managers read admin alert queue" on public.admin_alert_email_queue;
create policy "Managers read admin alert queue"
  on public.admin_alert_email_queue for select to authenticated
  using (public.lavida_is_admin_alert_manager());

drop policy if exists "Managers read admin alert log" on public.admin_alert_log;
create policy "Managers read admin alert log"
  on public.admin_alert_log for select to authenticated
  using (public.lavida_is_admin_alert_manager());

-- 12. updated_at triggers -------------------------------------
drop trigger if exists lavida_touch_admin_alert_config on public.admin_alert_config;
create trigger lavida_touch_admin_alert_config
before update on public.admin_alert_config
for each row execute function public.lavida_touch_updated_at();

drop trigger if exists lavida_touch_admin_alert_recipients on public.admin_alert_recipients;
create trigger lavida_touch_admin_alert_recipients
before update on public.admin_alert_recipients
for each row execute function public.lavida_touch_updated_at();

drop trigger if exists lavida_touch_admin_alert_email_queue on public.admin_alert_email_queue;
create trigger lavida_touch_admin_alert_email_queue
before update on public.admin_alert_email_queue
for each row execute function public.lavida_touch_updated_at();
