-- ============================================================
-- LAVIDA Admin Alert Email - automation helpers
-- Makes the email worker fully self-configuring:
--   * creates the vault secret that the dispatcher reads
--   * derives the worker URL from the project
--   * a management-only RPC so the console can do it in one click
-- Safe to run more than once.
-- ============================================================

-- 1. Enable the vault extension (Supabase projects ship with it) ----
create extension if not exists supabase_vault with schema vault;

-- 2. Store / refresh the shared worker secret -------------------------
-- The value is taken from the function secret ADMIN_ALERT_WORKER_SECRET
-- that the same app setting already exposes, so both sides always match.
create or replace function public.lavida_admin_alert_set_worker_secret(p_secret text)
returns boolean
language plpgsql
security definer
set search_path = public, vault
as $$
declare
  v_existing uuid;
begin
  if not public.lavida_is_admin_alert_manager() then
    raise exception 'Access denied.' using errcode = '42501';
  end if;

  p_secret := nullif(trim(coalesce(p_secret, '')), '');
  if p_secret is null then
    raise exception 'A worker secret is required.' using errcode = '22023';
  end if;

  select id into v_existing
  from vault.secrets
  where name = 'lavida_admin_alert_worker_secret'
  order by updated_at desc
  limit 1;

  if v_existing is null then
    perform vault.create_secret(
      p_secret,
      'lavida_admin_alert_worker_secret',
      'Shared secret used by the LAVIDA admin order alert email dispatcher.'
    );
  else
    perform vault.update_secret(
      v_existing,
      p_secret,
      'lavida_admin_alert_worker_secret',
      'Shared secret used by the LAVIDA admin order alert email dispatcher.'
    );
  end if;

  return true;
end;
$$;

grant execute on function public.lavida_admin_alert_set_worker_secret(text) to authenticated;

-- 3. Derive and store the worker URL automatically -------------------
-- Supabase exposes the project URL to the database as a role setting,
-- so the console never has to be told the URL by hand.
create or replace function public.lavida_admin_alert_autoconfigure()
returns public.admin_alert_config
language plpgsql
security definer
set search_path = public, vault
as $$
declare
  v_project_url text;
  v_url text;
  v_row public.admin_alert_config%rowtype;
begin
  if not public.lavida_is_admin_alert_manager() then
    raise exception 'Access denied.' using errcode = '42501';
  end if;

  begin
    v_project_url := current_setting('app.settings.supabase_url', true);
  exception when others then
    v_project_url := null;
  end;

  v_project_url := coalesce(
    nullif(v_project_url, ''),
    'https://cgvpoddtqswmtzvyrmwj.supabase.co'
  );

  v_url := rtrim(v_project_url, '/') || '/functions/v1/send-admin-alert-email';

  update public.admin_alert_config
  set send_worker_url = v_url,
      updated_at = now()
  where id = 1
  returning * into v_row;

  return v_row;
end;
$$;

grant execute on function public.lavida_admin_alert_autoconfigure() to authenticated;

-- 4. One-call ready check used by the console -------------------------
-- Also returns whether the required pieces are in place.
create or replace function public.lavida_admin_alert_setup_status()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, vault
as $$
declare
  v_cfg public.admin_alert_config%rowtype;
  v_secret_ok boolean;
  v_url_ok boolean;
  v_recipients integer;
  v_queued integer;
  v_sent integer;
  v_failed integer;
begin
  if not public.lavida_is_admin_alert_manager() then
    raise exception 'Access denied.' using errcode = '42501';
  end if;

  select * into v_cfg from public.admin_alert_config where id = 1;

  select exists (
    select 1 from vault.decrypted_secrets
    where name = 'lavida_admin_alert_worker_secret'
      and nullif(decrypted_secret, '') is not null
  ) into v_secret_ok;

  v_url_ok := nullif(coalesce(v_cfg.send_worker_url, ''), '') is not null;

  select count(*) into v_recipients
  from public.admin_alert_recipients where active = true and receives_order_alerts = true;

  select count(*) filter (where status = 'queued'),
         count(*) filter (where status = 'sent'),
         count(*) filter (where status = 'failed')
    into v_queued, v_sent, v_failed
  from public.admin_alert_email_queue;

  return jsonb_build_object(
    'secret_configured', v_secret_ok,
    'worker_url_configured', v_url_ok,
    'worker_url', v_cfg.send_worker_url,
    'from_email', v_cfg.from_email,
    'email_enabled', v_cfg.email_enabled,
    'active_recipients', coalesce(v_recipients, 0),
    'queued', coalesce(v_queued, 0),
    'sent', coalesce(v_sent, 0),
    'failed', coalesce(v_failed, 0)
  );
end;
$$;

grant execute on function public.lavida_admin_alert_setup_status() to authenticated;

-- 5. Make sure the cron sweep exists even if section 10 was skipped --
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
