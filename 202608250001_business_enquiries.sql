create extension if not exists pgcrypto;

create table if not exists public.business_enquiries (
  id uuid primary key default gen_random_uuid(),
  enquiry_type text not null check (enquiry_type in ('partnership','sponsorship')),
  full_name text not null,
  organization_name text not null,
  email text not null,
  phone text not null,
  country text not null,
  city text,
  organization_type text,
  interests text[] not null default '{}',
  sponsorship_type text[] not null default '{}',
  sponsorship_range text,
  message text not null,
  website text,
  preferred_contact_method text,
  status text not null default 'new',
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists business_enquiries_type_created_idx
  on public.business_enquiries (enquiry_type, created_at desc);

create index if not exists business_enquiries_status_created_idx
  on public.business_enquiries (status, created_at desc);

alter table public.business_enquiries enable row level security;

revoke all on public.business_enquiries from anon, authenticated;
grant insert on public.business_enquiries to anon, authenticated;

drop policy if exists "Public can submit business enquiries" on public.business_enquiries;
create policy "Public can submit business enquiries"
  on public.business_enquiries
  for insert
  to anon, authenticated
  with check (
    enquiry_type in ('partnership','sponsorship')
    and status = 'new'
    and length(trim(full_name)) > 0
    and length(trim(organization_name)) > 0
    and email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'
    and length(trim(phone)) > 0
    and length(trim(country)) > 0
    and length(trim(message)) > 0
  );
