-- ============================================================
-- LAVIDA Admin Alert Emails - never block order flow
-- An order must always go through, even if alert delivery is broken.
-- This wraps the alert sender so any failure is logged instead of
-- bubbling up and aborting the order insert/update.
-- Safe to run more than once.
-- ============================================================

-- 1. Non-raising wrapper around the alert sender --------------------
create or replace function public.lavida_send_admin_order_alert_safe(
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
  v_count integer := 0;
begin
  begin
    v_count := public.lavida_send_admin_order_alert(
      p_event_type, p_order_type, p_order_id, p_order_reference,
      p_title, p_summary, p_details, p_action_url, p_idempotency_key
    );
  exception when others then
    raise warning 'LAVIDA admin alert skipped for % %: %', p_order_type, p_order_id, sqlerrm;
    begin
      insert into public.admin_alert_log (
        event_type, order_type, order_id, order_reference, recipients_count, detail
      )
      values (
        p_event_type, p_order_type, p_order_id, p_order_reference, 0,
        jsonb_build_object('alert_error', sqlerrm, 'summary', p_summary)
      );
    exception when others then
      null;
    end;
    v_count := 0;
  end;

  return v_count;
end;
$$;

grant execute on function public.lavida_send_admin_order_alert_safe(text,text,text,text,text,text,jsonb,text,text) to authenticated;

-- 2. Rebuild the marketplace order trigger on the safe sender -------
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

    perform public.lavida_send_admin_order_alert_safe(
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

  perform public.lavida_send_admin_order_alert_safe(
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

-- 3. Rebuild the printing order trigger on the safe sender ----------
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

    perform public.lavida_send_admin_order_alert_safe(
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

  perform public.lavida_send_admin_order_alert_safe(
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

-- 4. Rebuild the service request trigger on the safe sender --------
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

  perform public.lavida_send_admin_order_alert_safe(
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

-- 5. Re-attach triggers (functions above are already swapped in) ---
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

-- 6. Guard the in-app breadcrumb too -------------------------------
-- create_lavida_notification is already wrapped in a try/catch inside
-- the alert sender, so a missing grants or role issue cannot abort it.
