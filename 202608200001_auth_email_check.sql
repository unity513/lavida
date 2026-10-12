create extension if not exists pgcrypto;

create table if not exists public.auth_email_security_events (
  id uuid primary key default gen_random_uuid(),
  event_type text not null,
  ip_hash text not null,
  email_hash text not null,
  pair_hash text not null,
  exists_result boolean,
  success boolean not null default false,
  user_agent text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists auth_email_security_events_ip_created_idx
  on public.auth_email_security_events (ip_hash, created_at desc);

create index if not exists auth_email_security_events_email_created_idx
  on public.auth_email_security_events (email_hash, created_at desc);

create index if not exists auth_email_security_events_pair_created_idx
  on public.auth_email_security_events (pair_hash, created_at desc);

alter table public.auth_email_security_events enable row level security;

revoke all on public.auth_email_security_events from anon, authenticated;

create or replace function public.lavida_auth_email_exists(p_email text)
returns boolean
language sql
security definer
set search_path = auth, public
as $$
  select exists (
    select 1
    from auth.users
    where lower(email) = lower(trim(p_email))
      and deleted_at is null
  );
$$;

revoke all on function public.lavida_auth_email_exists(text) from public, anon, authenticated;
grant execute on function public.lavida_auth_email_exists(text) to service_role;
