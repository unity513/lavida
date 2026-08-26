create extension if not exists pgcrypto;
create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron with schema extensions;

create or replace function public.lavida_touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create or replace function public.lavida_is_notification_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(auth.role(), '') = 'service_role'
    or exists (
      select 1
      from public.user_roles ur
      where lower(ur.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
        and coalesce(ur.active, true) = true
        and lower(ur.role) in ('owner','admin','executive','manager','notification_admin','service_admin','printing_admin','games_admin')
    );
$$;

create table if not exists public.notification_preferences (
  user_id uuid primary key references auth.users(id) on delete cascade,
  service_updates boolean not null default true,
  order_delivery boolean not null default true,
  invoice_payment boolean not null default true,
  games_tournaments boolean not null default true,
  promotions boolean not null default false,
  app_updates boolean not null default true,
  push_enabled boolean not null default false,
  push_denied_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete cascade,
  email text,
  notification_type text not null,
  category text not null check (category in ('service','order_delivery','invoice_payment','games','marketplace','marketing','system','security')),
  priority text not null default 'transactional' check (priority in ('transactional','engagement','marketing','system','security')),
  title text not null,
  body text not null,
  service_label text,
  action_label text,
  action_url text,
  entity_type text,
  entity_id text,
  is_read boolean not null default false,
  read_at timestamptz,
  archived_at timestamptz,
  expires_at timestamptz,
  idempotency_key text,
  push_status text not null default 'not_queued' check (push_status in ('not_queued','queued','sent','failed','skipped')),
  push_last_error text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint notifications_target_check check (user_id is not null or nullif(email, '') is not null)
);

create unique index if not exists notifications_user_idempotency_idx
  on public.notifications (user_id, idempotency_key)
  where user_id is not null and idempotency_key is not null;

create unique index if not exists notifications_email_idempotency_idx
  on public.notifications (lower(email), idempotency_key)
  where user_id is null and email is not null and idempotency_key is not null;

create index if not exists notifications_user_created_idx on public.notifications(user_id, created_at desc);
create index if not exists notifications_email_created_idx on public.notifications(lower(email), created_at desc);
create index if not exists notifications_unread_idx on public.notifications(user_id, is_read, created_at desc);

create table if not exists public.notification_recipients (
  id uuid primary key default gen_random_uuid(),
  notification_id uuid not null references public.notifications(id) on delete cascade,
  user_id uuid references auth.users(id) on delete cascade,
  email text,
  is_read boolean not null default false,
  read_at timestamptz,
  archived_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint notification_recipients_target_check check (user_id is not null or nullif(email, '') is not null)
);

create unique index if not exists notification_recipients_user_idx
  on public.notification_recipients (notification_id, user_id)
  where user_id is not null;

create unique index if not exists notification_recipients_email_idx
  on public.notification_recipients (notification_id, lower(email))
  where user_id is null and email is not null;

create index if not exists notification_recipients_user_unread_idx on public.notification_recipients(user_id, is_read, created_at desc);

create table if not exists public.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  auth_key text,
  platform text not null default 'web',
  installation_id text,
  user_agent text,
  device_label text,
  active boolean not null default true,
  last_used_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists push_subscriptions_user_active_idx on public.push_subscriptions(user_id, active);
create unique index if not exists push_subscriptions_user_endpoint_idx on public.push_subscriptions(user_id, endpoint);
alter table public.push_subscriptions add column if not exists auth_key text;
alter table public.push_subscriptions add column if not exists installation_id text;
update public.push_subscriptions set auth_key = auth where auth_key is null;

create table if not exists public.mobile_push_tokens (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  fcm_token text not null,
  platform text not null default 'android',
  installation_id text,
  device_label text,
  app_version text,
  active boolean not null default true,
  last_seen_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists mobile_push_tokens_token_idx on public.mobile_push_tokens(fcm_token);
create index if not exists mobile_push_tokens_user_active_idx on public.mobile_push_tokens(user_id, active);
create index if not exists mobile_push_tokens_installation_idx on public.mobile_push_tokens(user_id, installation_id) where installation_id is not null;

create table if not exists public.notification_push_queue (
  id uuid primary key default gen_random_uuid(),
  notification_id uuid not null references public.notifications(id) on delete cascade,
  subscription_id uuid references public.push_subscriptions(id) on delete set null,
  status text not null default 'queued' check (status in ('queued','sent','failed','skipped')),
  attempts integer not null default 0,
  last_error text,
  queued_at timestamptz not null default now(),
  sent_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists notification_push_queue_status_idx on public.notification_push_queue(status, queued_at);

create table if not exists public.notification_mobile_push_queue (
  id uuid primary key default gen_random_uuid(),
  notification_id uuid not null references public.notifications(id) on delete cascade,
  mobile_push_token_id uuid references public.mobile_push_tokens(id) on delete set null,
  status text not null default 'queued' check (status in ('queued','sent','failed','skipped')),
  attempts integer not null default 0,
  last_error text,
  queued_at timestamptz not null default now(),
  sent_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists notification_mobile_push_queue_status_idx on public.notification_mobile_push_queue(status, queued_at);

create table if not exists public.notification_delivery_log (
  id uuid primary key default gen_random_uuid(),
  notification_id uuid not null references public.notifications(id) on delete cascade,
  user_id uuid references auth.users(id) on delete set null,
  channel text not null check (channel in ('web_push','android_fcm')),
  destination_ref uuid,
  status text not null check (status in ('queued','sent','failed','skipped')),
  provider_response jsonb,
  error_message text,
  attempted_at timestamptz not null default now(),
  delivered_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists notification_delivery_log_notification_idx on public.notification_delivery_log(notification_id, channel, attempted_at desc);
create index if not exists notification_delivery_log_user_idx on public.notification_delivery_log(user_id, attempted_at desc);

create table if not exists public.notification_campaigns (
  id uuid primary key default gen_random_uuid(),
  notification_type text not null,
  category text not null,
  priority text not null default 'marketing',
  title text not null,
  body text not null,
  action_label text,
  action_url text,
  audience text not null default 'all_users',
  selected_user_ids uuid[] not null default '{}'::uuid[],
  send_phone_push boolean not null default false,
  preview_payload jsonb not null default '{}'::jsonb,
  status text not null default 'draft' check (status in ('draft','published','cancelled')),
  created_by uuid references auth.users(id) on delete set null,
  published_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.app_releases (
  id uuid primary key default gen_random_uuid(),
  version text not null unique,
  release_title text not null,
  release_notes text not null,
  release_type text not null default 'minor' check (release_type in ('internal','minor','major','critical')),
  minimum_supported_version text,
  is_required boolean not null default false,
  force_update boolean not null default false,
  notify_users boolean not null default false,
  action_url text not null default 'marketplace.html#account',
  published_at timestamptz,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

create table if not exists public.notification_public_config (
  id integer primary key default 1 check (id = 1),
  current_release_version text,
  minimum_supported_version text,
  vapid_public_key text,
  push_function_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

insert into public.notification_public_config (id, current_release_version, minimum_supported_version)
values (1, '3.3.0', null)
on conflict (id) do nothing;

alter table public.notification_preferences enable row level security;
alter table public.notifications enable row level security;
alter table public.notification_recipients enable row level security;
alter table public.push_subscriptions enable row level security;
alter table public.mobile_push_tokens enable row level security;
alter table public.notification_push_queue enable row level security;
alter table public.notification_mobile_push_queue enable row level security;
alter table public.notification_delivery_log enable row level security;
alter table public.notification_campaigns enable row level security;
alter table public.app_releases enable row level security;
alter table public.notification_public_config enable row level security;

grant select, insert, update on public.notification_preferences to authenticated;
grant select, update on public.notifications to authenticated;
grant select, update on public.notification_recipients to authenticated;
grant select, insert, update, delete on public.push_subscriptions to authenticated;
grant select, insert, update, delete on public.mobile_push_tokens to authenticated;
grant select on public.notification_push_queue to authenticated;
grant select on public.notification_mobile_push_queue to authenticated;
grant select on public.notification_delivery_log to authenticated;
grant select, insert, update on public.notification_campaigns to authenticated;
grant select, insert, update on public.app_releases to authenticated;
grant select, update on public.notification_public_config to authenticated;
grant select on public.notification_public_config to anon;

drop trigger if exists lavida_touch_notification_preferences on public.notification_preferences;
create trigger lavida_touch_notification_preferences
before update on public.notification_preferences
for each row execute function public.lavida_touch_updated_at();

drop trigger if exists lavida_touch_notifications on public.notifications;
create trigger lavida_touch_notifications
before update on public.notifications
for each row execute function public.lavida_touch_updated_at();

drop trigger if exists lavida_touch_notification_recipients on public.notification_recipients;
create trigger lavida_touch_notification_recipients
before update on public.notification_recipients
for each row execute function public.lavida_touch_updated_at();

drop trigger if exists lavida_touch_push_subscriptions on public.push_subscriptions;
create trigger lavida_touch_push_subscriptions
before update on public.push_subscriptions
for each row execute function public.lavida_touch_updated_at();

drop trigger if exists lavida_touch_mobile_push_tokens on public.mobile_push_tokens;
create trigger lavida_touch_mobile_push_tokens
before update on public.mobile_push_tokens
for each row execute function public.lavida_touch_updated_at();

drop trigger if exists lavida_touch_notification_push_queue on public.notification_push_queue;
create trigger lavida_touch_notification_push_queue
before update on public.notification_push_queue
for each row execute function public.lavida_touch_updated_at();

drop trigger if exists lavida_touch_notification_mobile_push_queue on public.notification_mobile_push_queue;
create trigger lavida_touch_notification_mobile_push_queue
before update on public.notification_mobile_push_queue
for each row execute function public.lavida_touch_updated_at();

drop trigger if exists lavida_touch_notification_public_config on public.notification_public_config;
create trigger lavida_touch_notification_public_config
before update on public.notification_public_config
for each row execute function public.lavida_touch_updated_at();

drop policy if exists "Users manage own notification preferences" on public.notification_preferences;
create policy "Users manage own notification preferences"
  on public.notification_preferences for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

drop policy if exists "Users read own notifications" on public.notifications;
create policy "Users read own notifications"
  on public.notifications for select to authenticated
  using (
    user_id = auth.uid()
    or lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
    or public.lavida_is_notification_admin()
  );

drop policy if exists "Users update own notification read state" on public.notifications;
create policy "Users update own notification read state"
  on public.notifications for update to authenticated
  using (user_id = auth.uid() or lower(email) = lower(coalesce(auth.jwt() ->> 'email', '')) or public.lavida_is_notification_admin())
  with check (user_id = auth.uid() or lower(email) = lower(coalesce(auth.jwt() ->> 'email', '')) or public.lavida_is_notification_admin());

drop policy if exists "Users read own notification recipients" on public.notification_recipients;
create policy "Users read own notification recipients"
  on public.notification_recipients for select to authenticated
  using (user_id = auth.uid() or lower(email) = lower(coalesce(auth.jwt() ->> 'email', '')) or public.lavida_is_notification_admin());

drop policy if exists "Users update own notification recipient read state" on public.notification_recipients;
create policy "Users update own notification recipient read state"
  on public.notification_recipients for update to authenticated
  using (user_id = auth.uid() or lower(email) = lower(coalesce(auth.jwt() ->> 'email', '')) or public.lavida_is_notification_admin())
  with check (user_id = auth.uid() or lower(email) = lower(coalesce(auth.jwt() ->> 'email', '')) or public.lavida_is_notification_admin());

drop policy if exists "Users manage own push subscriptions" on public.push_subscriptions;
create policy "Users manage own push subscriptions"
  on public.push_subscriptions for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

drop policy if exists "Users manage own mobile push tokens" on public.mobile_push_tokens;
create policy "Users manage own mobile push tokens"
  on public.mobile_push_tokens for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

drop policy if exists "Admins view push delivery queue" on public.notification_push_queue;
create policy "Admins view push delivery queue"
  on public.notification_push_queue for select to authenticated
  using (public.lavida_is_notification_admin());

drop policy if exists "Admins view mobile push delivery queue" on public.notification_mobile_push_queue;
create policy "Admins view mobile push delivery queue"
  on public.notification_mobile_push_queue for select to authenticated
  using (public.lavida_is_notification_admin());

drop policy if exists "Users view own notification delivery log" on public.notification_delivery_log;
create policy "Users view own notification delivery log"
  on public.notification_delivery_log for select to authenticated
  using (user_id = auth.uid() or public.lavida_is_notification_admin());

drop policy if exists "Admins manage notification campaigns" on public.notification_campaigns;
create policy "Admins manage notification campaigns"
  on public.notification_campaigns for all to authenticated
  using (public.lavida_is_notification_admin())
  with check (public.lavida_is_notification_admin());

drop policy if exists "Admins manage app releases" on public.app_releases;
create policy "Admins manage app releases"
  on public.app_releases for all to authenticated
  using (public.lavida_is_notification_admin())
  with check (public.lavida_is_notification_admin());

drop policy if exists "Users read public notification config" on public.notification_public_config;
create policy "Users read public notification config"
  on public.notification_public_config for select to anon, authenticated
  using (true);

drop policy if exists "Admins update notification config" on public.notification_public_config;
create policy "Admins update notification config"
  on public.notification_public_config for update to authenticated
  using (public.lavida_is_notification_admin())
  with check (public.lavida_is_notification_admin());

create or replace function public.lavida_notification_pref_allowed(
  p_user_id uuid,
  p_category text,
  p_priority text
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  prefs public.notification_preferences%rowtype;
begin
  if p_user_id is null then
    return false;
  end if;

  insert into public.notification_preferences (user_id)
  values (p_user_id)
  on conflict (user_id) do nothing;

  select * into prefs
  from public.notification_preferences
  where user_id = p_user_id;

  if p_priority in ('transactional','security') then
    return true;
  end if;

  if p_category = 'service' then return coalesce(prefs.service_updates, true); end if;
  if p_category = 'order_delivery' then return coalesce(prefs.order_delivery, true); end if;
  if p_category = 'invoice_payment' then return coalesce(prefs.invoice_payment, true); end if;
  if p_category = 'games' then return coalesce(prefs.games_tournaments, true); end if;
  if p_category = 'marketing' then return coalesce(prefs.promotions, false); end if;
  if p_category = 'system' then return coalesce(prefs.app_updates, true); end if;
  if p_category = 'marketplace' then return true; end if;
  return true;
end;
$$;

create or replace function public.register_lavida_mobile_push_token(
  p_fcm_token text,
  p_platform text default 'android',
  p_installation_id text default null,
  p_device_label text default null,
  p_app_version text default null
)
returns public.mobile_push_tokens
language plpgsql
security definer
set search_path = public
as $$
declare
  registered public.mobile_push_tokens%rowtype;
begin
  if auth.uid() is null then
    raise exception 'Sign in is required.';
  end if;

  if nullif(trim(coalesce(p_fcm_token, '')), '') is null then
    raise exception 'A device token is required.';
  end if;

  insert into public.mobile_push_tokens (
    user_id, fcm_token, platform, installation_id, device_label, app_version,
    active, last_seen_at
  )
  values (
    auth.uid(), trim(p_fcm_token), coalesce(nullif(trim(p_platform), ''), 'android'),
    nullif(trim(coalesce(p_installation_id, '')), ''),
    nullif(trim(coalesce(p_device_label, '')), ''),
    nullif(trim(coalesce(p_app_version, '')), ''),
    true, now()
  )
  on conflict (fcm_token) do update
  set user_id = excluded.user_id,
      platform = excluded.platform,
      installation_id = excluded.installation_id,
      device_label = excluded.device_label,
      app_version = excluded.app_version,
      active = true,
      last_seen_at = now(),
      updated_at = now()
  returning * into registered;

  insert into public.notification_preferences (user_id, push_enabled)
  values (auth.uid(), true)
  on conflict (user_id) do update set push_enabled = true, updated_at = now();

  return registered;
end;
$$;

grant execute on function public.register_lavida_mobile_push_token(text,text,text,text,text) to authenticated;

create or replace function public.deactivate_lavida_mobile_push_token(
  p_fcm_token text default null,
  p_installation_id text default null
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  affected integer := 0;
begin
  if auth.uid() is null then
    return 0;
  end if;

  update public.mobile_push_tokens
  set active = false, updated_at = now()
  where user_id = auth.uid()
    and (
      (nullif(trim(coalesce(p_fcm_token, '')), '') is not null and fcm_token = trim(p_fcm_token))
      or (nullif(trim(coalesce(p_installation_id, '')), '') is not null and installation_id = trim(p_installation_id))
    );
  get diagnostics affected = row_count;
  return affected;
end;
$$;

grant execute on function public.deactivate_lavida_mobile_push_token(text,text) to authenticated;

create or replace function public.lavida_dispatch_push_queue(p_limit integer default 50)
returns void
language plpgsql
security definer
set search_path = public, vault
as $$
declare
  push_url text;
  push_secret text;
begin
  select nullif(push_function_url, '') into push_url
  from public.notification_public_config
  where id = 1;

  select decrypted_secret into push_secret
  from vault.decrypted_secrets
  where name = 'lavida_push_worker_secret'
  order by updated_at desc
  limit 1;

  if push_url is null or nullif(push_secret, '') is null then
    return;
  end if;

  perform net.http_post(
    url := push_url,
    body := jsonb_build_object('limit', greatest(1, least(100, coalesce(p_limit, 50)))),
    params := '{}'::jsonb,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-lavida-push-secret', push_secret
    ),
    timeout_milliseconds := 5000
  );
exception when others then
  raise warning 'LAVIDA push dispatch request failed: %', sqlerrm;
end;
$$;

create or replace function public.lavida_dispatch_push_queue_after_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status = 'queued' then
    perform public.lavida_dispatch_push_queue(50);
  end if;
  return new;
exception when others then
  raise warning 'LAVIDA push queue trigger failed: %', sqlerrm;
  return new;
end;
$$;

drop trigger if exists lavida_dispatch_push_queue_insert on public.notification_push_queue;
create trigger lavida_dispatch_push_queue_insert
after insert on public.notification_push_queue
for each row execute function public.lavida_dispatch_push_queue_after_insert();

drop trigger if exists lavida_dispatch_mobile_push_queue_insert on public.notification_mobile_push_queue;
create trigger lavida_dispatch_mobile_push_queue_insert
after insert on public.notification_mobile_push_queue
for each row execute function public.lavida_dispatch_push_queue_after_insert();

do $$
begin
  perform cron.unschedule('lavida-push-queue-worker');
exception when others then
  null;
end $$;

select cron.schedule(
  'lavida-push-queue-worker',
  '* * * * *',
  'select public.lavida_dispatch_push_queue(50);'
);

create or replace function public.create_lavida_notification(
  p_user_id uuid,
  p_email text,
  p_notification_type text,
  p_category text,
  p_title text,
  p_body text,
  p_action_label text default null,
  p_action_url text default null,
  p_entity_type text default null,
  p_entity_id text default null,
  p_priority text default 'transactional',
  p_service_label text default null,
  p_idempotency_key text default null,
  p_metadata jsonb default '{}'::jsonb,
  p_send_push boolean default true
)
returns public.notifications
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  target_email text;
  target_user_id uuid;
  existing public.notifications%rowtype;
  created public.notifications%rowtype;
  push_allowed boolean := false;
  sub record;
  token record;
begin
  target_user_id := p_user_id;

  if target_user_id is null and nullif(trim(coalesce(p_email, '')), '') is not null then
    select u.id into target_user_id
    from auth.users u
    where lower(u.email) = lower(trim(p_email))
    order by u.created_at desc
    limit 1;
  end if;

  if target_user_id is null and nullif(trim(coalesce(p_email, '')), '') is null then
    raise exception 'Notification target is required.';
  end if;

  if not (
    public.lavida_is_notification_admin()
    or coalesce(auth.role(), '') = 'service_role'
    or target_user_id = auth.uid()
    or lower(coalesce(p_email, '')) = lower(coalesce(auth.jwt() ->> 'email', ''))
  ) then
    raise exception 'Not allowed to create this notification.';
  end if;

  if target_user_id is not null then
    select u.email into target_email from auth.users u where u.id = target_user_id;
  end if;
  target_email := nullif(trim(coalesce(target_email, p_email)), '');

  if p_idempotency_key is not null then
    select * into existing
    from public.notifications n
    where (
      (target_user_id is not null and n.user_id = target_user_id)
      or (target_user_id is null and target_email is not null and lower(n.email) = lower(target_email))
    )
    and n.idempotency_key = p_idempotency_key
    limit 1;
    if found then
      return existing;
    end if;
  end if;

  insert into public.notifications (
    user_id, email, notification_type, category, priority, title, body,
    service_label, action_label, action_url, entity_type, entity_id,
    idempotency_key, metadata
  )
  values (
    target_user_id, target_email, p_notification_type, p_category, p_priority,
    left(p_title, 120), left(p_body, 300), p_service_label, p_action_label,
    p_action_url, p_entity_type, p_entity_id, p_idempotency_key, coalesce(p_metadata, '{}'::jsonb)
  )
  returning * into created;

  insert into public.notification_recipients (notification_id, user_id, email, is_read, read_at, archived_at)
  values (created.id, target_user_id, target_email, created.is_read, created.read_at, created.archived_at)
  on conflict do nothing;

  push_allowed := p_send_push
    and target_user_id is not null
    and public.lavida_notification_pref_allowed(target_user_id, p_category, p_priority)
    and exists (
      select 1
      from public.notification_preferences np
      where np.user_id = target_user_id and np.push_enabled = true
    );

  if push_allowed then
    for sub in
      select ps.id
      from public.push_subscriptions ps
      where ps.user_id = target_user_id
        and ps.active = true
        and not exists (
          select 1
          from public.mobile_push_tokens mt
          where mt.user_id = ps.user_id
            and mt.active = true
            and mt.installation_id is not null
            and ps.installation_id is not null
            and mt.installation_id = ps.installation_id
        )
    loop
      insert into public.notification_push_queue (notification_id, subscription_id, status)
      values (created.id, sub.id, 'queued');

      insert into public.notification_delivery_log (
        notification_id, user_id, channel, destination_ref, status
      )
      values (created.id, target_user_id, 'web_push', sub.id, 'queued');
    end loop;

    for token in select id from public.mobile_push_tokens where user_id = target_user_id and active = true loop
      insert into public.notification_mobile_push_queue (notification_id, mobile_push_token_id, status)
      values (created.id, token.id, 'queued');

      insert into public.notification_delivery_log (
        notification_id, user_id, channel, destination_ref, status
      )
      values (created.id, target_user_id, 'android_fcm', token.id, 'queued');
    end loop;

    update public.notifications
    set push_status = case
      when exists (select 1 from public.notification_push_queue q where q.notification_id = created.id)
        or exists (select 1 from public.notification_mobile_push_queue q where q.notification_id = created.id)
      then 'queued'
      else 'skipped'
    end
    where id = created.id
    returning * into created;
  end if;

  return created;
end;
$$;

grant execute on function public.create_lavida_notification(uuid,text,text,text,text,text,text,text,text,text,text,text,text,jsonb,boolean) to authenticated;

create or replace function public.mark_lavida_notifications_read(p_notification_ids uuid[] default null)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  affected integer := 0;
begin
  update public.notifications
  set is_read = true, read_at = coalesce(read_at, now())
  where archived_at is null
    and (p_notification_ids is null or id = any(p_notification_ids))
    and (user_id = auth.uid() or lower(email) = lower(coalesce(auth.jwt() ->> 'email', '')))
    and is_read = false;
  get diagnostics affected = row_count;

  update public.notification_recipients
  set is_read = true, read_at = coalesce(read_at, now())
  where archived_at is null
    and (p_notification_ids is null or notification_id = any(p_notification_ids))
    and (user_id = auth.uid() or lower(email) = lower(coalesce(auth.jwt() ->> 'email', '')))
    and is_read = false;

  return affected;
end;
$$;

grant execute on function public.mark_lavida_notifications_read(uuid[]) to authenticated;

create or replace function public.publish_notification_campaign(
  p_notification_type text,
  p_category text,
  p_title text,
  p_body text,
  p_action_label text default null,
  p_action_url text default null,
  p_audience text default 'all_users',
  p_selected_user_ids uuid[] default '{}'::uuid[],
  p_send_phone_push boolean default false,
  p_priority text default 'marketing'
)
returns uuid
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  campaign_id uuid;
  user_row record;
begin
  if not public.lavida_is_notification_admin() then
    raise exception 'Only notification admins can publish campaigns.';
  end if;

  insert into public.notification_campaigns (
    notification_type, category, priority, title, body, action_label, action_url,
    audience, selected_user_ids, send_phone_push, status, created_by, published_at,
    preview_payload
  )
  values (
    p_notification_type, p_category, p_priority, p_title, p_body, p_action_label, p_action_url,
    p_audience, coalesce(p_selected_user_ids, '{}'::uuid[]), p_send_phone_push, 'published',
    auth.uid(), now(), jsonb_build_object('title', p_title, 'body', p_body, 'action_url', p_action_url)
  )
  returning id into campaign_id;

  for user_row in
    select u.id, u.email
    from auth.users u
    where u.deleted_at is null
      and (
        p_audience = 'all_users'
        or (p_audience = 'selected_users' and u.id = any(coalesce(p_selected_user_ids, '{}'::uuid[])))
        or (p_audience = 'admins' and exists (
          select 1 from public.user_roles ur
          where lower(ur.email) = lower(u.email)
            and coalesce(ur.active, true) = true
            and lower(ur.role) in ('owner','admin','executive','manager')
        ))
      )
  loop
    if public.lavida_notification_pref_allowed(user_row.id, p_category, p_priority) then
      perform public.create_lavida_notification(
        user_row.id, user_row.email, p_notification_type, p_category, p_title, p_body,
        p_action_label, p_action_url, 'notification_campaign', campaign_id::text, p_priority,
        null, 'campaign:' || campaign_id::text || ':' || user_row.id::text,
        jsonb_build_object('campaign_id', campaign_id, 'audience', p_audience),
        p_send_phone_push
      );
    end if;
  end loop;

  return campaign_id;
end;
$$;

grant execute on function public.publish_notification_campaign(text,text,text,text,text,text,text,uuid[],boolean,text) to authenticated;

create or replace function public.publish_lavida_app_release(
  p_version text,
  p_release_title text,
  p_release_notes text,
  p_release_type text default 'minor',
  p_minimum_supported_version text default null,
  p_is_required boolean default false,
  p_force_update boolean default false,
  p_notify_users boolean default false,
  p_action_url text default 'marketplace.html#account'
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  release_id uuid;
begin
  if not public.lavida_is_notification_admin() then
    raise exception 'Only notification admins can publish releases.';
  end if;

  insert into public.app_releases (
    version, release_title, release_notes, release_type, minimum_supported_version,
    is_required, force_update, notify_users, action_url, published_at, created_by
  )
  values (
    p_version, p_release_title, p_release_notes, p_release_type, p_minimum_supported_version,
    p_is_required, p_force_update, p_notify_users, p_action_url, now(), auth.uid()
  )
  on conflict (version) do update
  set release_title = excluded.release_title,
      release_notes = excluded.release_notes,
      release_type = excluded.release_type,
      minimum_supported_version = excluded.minimum_supported_version,
      is_required = excluded.is_required,
      force_update = excluded.force_update,
      notify_users = excluded.notify_users,
      action_url = excluded.action_url,
      published_at = excluded.published_at
  returning id into release_id;

  update public.notification_public_config
  set current_release_version = p_version,
      minimum_supported_version = coalesce(p_minimum_supported_version, minimum_supported_version)
  where id = 1;

  if p_notify_users and p_release_type <> 'internal' then
    perform public.publish_notification_campaign(
      case when p_is_required then 'app_update_required' else 'app_update_available' end,
      'system',
      p_release_title,
      p_release_notes,
      case when p_is_required then 'Update App' else 'See What''s New' end,
      p_action_url,
      'all_users',
      '{}'::uuid[],
      true,
      'system'
    );
  end if;

  return release_id;
end;
$$;

grant execute on function public.publish_lavida_app_release(text,text,text,text,text,boolean,boolean,boolean,text) to authenticated;

alter table if exists public.service_project_updates
  add column if not exists metadata jsonb not null default '{}'::jsonb;

create or replace function public.notify_service_request_received()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.create_lavida_notification(
    new.user_id, new.contact_email, 'service_request_received', 'service',
    'Request Received',
    'We received your ' || coalesce(new.service_name, 'service') || ' request.',
    'View Request', 'marketplace.html#account', 'service_request', new.id::text,
    'transactional', new.service_area_name,
    'service_request:' || new.id::text || ':received',
    jsonb_build_object('request_number', new.request_number), true
  );
  return new;
end;
$$;

create or replace function public.notify_service_quote_ready()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  req record;
begin
  if new.status not in ('sent','accepted') then
    return new;
  end if;
  if tg_op = 'UPDATE' then
    if coalesce(old.status, '') = coalesce(new.status, '') then
      return new;
    end if;
  end if;
  select * into req from public.service_requests where id = new.request_id;
  if req.id is null then return new; end if;
  perform public.create_lavida_notification(
    req.user_id, req.contact_email, 'service_quote_ready', 'service',
    'Your Quotation Is Ready',
    'We completed the review of your request and your quotation is ready.',
    'View Quote', 'marketplace.html#account', 'service_quote', new.id::text,
    'transactional', req.service_area_name,
    'service_quote:' || new.id::text || ':' || new.status,
    jsonb_build_object('request_id', req.id, 'quote_number', new.quote_number), true
  );
  return new;
end;
$$;

create or replace function public.notify_service_invoice_issued()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  req record;
begin
  if new.status not in ('issued','awaiting_payment') then
    return new;
  end if;
  if tg_op = 'UPDATE' then
    if coalesce(old.status, '') = coalesce(new.status, '') then
      return new;
    end if;
  end if;
  select * into req from public.service_requests where id = new.request_id;
  if req.id is null then return new; end if;
  perform public.create_lavida_notification(
    req.user_id, req.contact_email, 'invoice_issued', 'invoice_payment',
    'Invoice Ready',
    'Your invoice for ' || coalesce(req.service_area_name, 'LAVIDA') || ' has been issued.',
    'View Invoice', 'marketplace.html#account', 'service_invoice', new.id::text,
    'transactional', req.service_area_name,
    'service_invoice:' || new.id::text || ':issued',
    jsonb_build_object('request_id', req.id, 'invoice_number', new.invoice_number), true
  );
  return new;
end;
$$;

create or replace function public.notify_service_project_update()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  req record;
begin
  if not coalesce(new.visible_to_customer, false) then return new; end if;
  if coalesce(new.metadata ->> 'notify_customer', 'false') <> 'true' then return new; end if;
  select * into req from public.service_requests where id = new.request_id;
  if req.id is null then return new; end if;
  perform public.create_lavida_notification(
    req.user_id, req.contact_email, 'project_update', 'service',
    'Project Update',
    left(new.message, 160),
    'View Update', 'marketplace.html#account', 'service_project_update', new.id::text,
    'transactional', req.service_area_name,
    'service_update:' || new.id::text,
    jsonb_build_object('request_id', req.id), true
  );
  return new;
end;
$$;

create or replace function public.notify_printing_order_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  title text;
  body text;
  ntype text;
begin
  if tg_op = 'INSERT' then
    ntype := 'printing_order_received';
    title := 'Order Received';
    body := 'We received your printing request.';
  elsif coalesce(old.production_status, '') <> coalesce(new.production_status, '') then
    ntype := 'printing_' || coalesce(new.production_status, 'update');
    title := case new.production_status
      when 'payment_confirmed' then 'Payment Confirmed'
      when 'printing' then 'Printing Started'
      when 'ready_for_pickup' then 'Ready for Collection'
      when 'out_for_delivery' then 'Your Order Is On The Way'
      when 'completed' then 'Delivered'
      when 'cancelled' then 'Printing Order Cancelled'
      when 'rejected' then 'Printing Order Needs Attention'
      else 'Printing Update'
    end;
    body := case new.production_status
      when 'payment_confirmed' then 'Your printing payment has been confirmed.'
      when 'printing' then 'We are now preparing your printing order.'
      when 'ready_for_pickup' then 'Your printing order is ready for collection.'
      when 'out_for_delivery' then 'Your order is now out for delivery.'
      when 'completed' then 'Your printing order has been completed.'
      else 'Your printing order status has been updated.'
    end;
  else
    return new;
  end if;

  perform public.create_lavida_notification(
    new.user_id, new.customer_email, ntype, 'order_delivery',
    title, body, 'View Order', 'marketplace.html#printing-orders',
    'printing_order', new.id::text, 'transactional', 'Print 365',
    'printing_order:' || new.id::text || ':' || coalesce(new.production_status, 'submitted'),
    jsonb_build_object('order_number', new.order_number), true
  );
  return new;
end;
$$;

create or replace function public.notify_marketplace_order_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  title text;
  body text;
begin
  if tg_op = 'INSERT' then
    title := 'Order Received';
    body := 'We received your marketplace order.';
  elsif coalesce(old.order_status, '') <> coalesce(new.order_status, '') then
    title := case new.order_status
      when 'approved' then 'Order Approved'
      when 'processing' then 'Order Processing'
      when 'crypto_sent' then 'Crypto Sent'
      when 'ready_for_collection' then 'Ready for Collection'
      when 'out_for_delivery' then 'Your Order Is On The Way'
      when 'completed' then 'Order Completed'
      when 'cancelled' then 'Order Cancelled'
      when 'rejected' then 'Order Needs Attention'
      else 'Marketplace Update'
    end;
    body := case new.order_status
      when 'crypto_sent' then 'Your crypto order has been sent.'
      when 'ready_for_collection' then 'Your marketplace order is ready for collection.'
      when 'out_for_delivery' then 'Your order is now out for delivery.'
      when 'completed' then 'Your marketplace order has been completed.'
      else 'Your marketplace order status has been updated.'
    end;
  elsif coalesce(old.payment_status, '') <> coalesce(new.payment_status, '') and new.payment_status in ('paid','proof_submitted','rejected') then
    title := case new.payment_status when 'paid' then 'Payment Confirmed' when 'rejected' then 'Payment Problem' else 'Payment Submitted' end;
    body := case new.payment_status when 'paid' then 'Your payment has been confirmed.' when 'rejected' then 'There is a problem with your payment.' else 'Your payment proof was received.' end;
  else
    return new;
  end if;

  perform public.create_lavida_notification(
    null, new.email, 'marketplace_order_update', 'marketplace',
    title, body, 'View Order', 'marketplace.html#orders',
    'marketplace_order', new.id::text, 'transactional', 'Market 365',
    'marketplace_order:' || new.id::text || ':' || coalesce(new.order_status, new.payment_status, 'submitted'),
    jsonb_build_object('order_reference', new.order_reference), true
  );
  return new;
end;
$$;

do $$
begin
  if to_regclass('public.service_requests') is not null then
    drop trigger if exists lavida_notify_service_request_received on public.service_requests;
    create trigger lavida_notify_service_request_received
    after insert on public.service_requests
    for each row execute function public.notify_service_request_received();
  end if;

  if to_regclass('public.service_quotes') is not null then
    drop trigger if exists lavida_notify_service_quote_ready_insert on public.service_quotes;
    create trigger lavida_notify_service_quote_ready_insert
    after insert on public.service_quotes
    for each row execute function public.notify_service_quote_ready();

    drop trigger if exists lavida_notify_service_quote_ready_update on public.service_quotes;
    create trigger lavida_notify_service_quote_ready_update
    after update on public.service_quotes
    for each row execute function public.notify_service_quote_ready();
  end if;

  if to_regclass('public.service_invoices') is not null then
    drop trigger if exists lavida_notify_service_invoice_issued_insert on public.service_invoices;
    create trigger lavida_notify_service_invoice_issued_insert
    after insert on public.service_invoices
    for each row execute function public.notify_service_invoice_issued();

    drop trigger if exists lavida_notify_service_invoice_issued_update on public.service_invoices;
    create trigger lavida_notify_service_invoice_issued_update
    after update on public.service_invoices
    for each row execute function public.notify_service_invoice_issued();
  end if;

  if to_regclass('public.service_project_updates') is not null then
    drop trigger if exists lavida_notify_service_project_update on public.service_project_updates;
    create trigger lavida_notify_service_project_update
    after insert on public.service_project_updates
    for each row execute function public.notify_service_project_update();
  end if;

  if to_regclass('public.printing_orders') is not null then
    drop trigger if exists lavida_notify_printing_order_insert on public.printing_orders;
    create trigger lavida_notify_printing_order_insert
    after insert on public.printing_orders
    for each row execute function public.notify_printing_order_change();

    drop trigger if exists lavida_notify_printing_order_update on public.printing_orders;
    create trigger lavida_notify_printing_order_update
    after update on public.printing_orders
    for each row execute function public.notify_printing_order_change();
  end if;

  if to_regclass('public.marketplace_orders') is not null then
    drop trigger if exists lavida_notify_marketplace_order_insert on public.marketplace_orders;
    create trigger lavida_notify_marketplace_order_insert
    after insert on public.marketplace_orders
    for each row execute function public.notify_marketplace_order_change();

    drop trigger if exists lavida_notify_marketplace_order_update on public.marketplace_orders;
    create trigger lavida_notify_marketplace_order_update
    after update on public.marketplace_orders
    for each row execute function public.notify_marketplace_order_change();
  end if;
end $$;
