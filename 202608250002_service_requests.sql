create extension if not exists pgcrypto;

create or replace function public.lavida_is_service_admin()
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
      and coalesce(ur.active, true) = true
      and lower(ur.role) in ('owner','admin','executive','manager','printing_admin','service_admin')
  );
$$;

create table if not exists public.service_requests (
  id uuid primary key default gen_random_uuid(),
  request_number text not null unique,
  user_id uuid not null references auth.users(id) on delete cascade,
  service_area text not null check (service_area in ('digital','documents')),
  service_area_name text not null,
  service_code text not null,
  service_name text not null,
  commercial_route text not null default 'review_first' check (commercial_route in ('review_first','custom_quote','fixed_price')),
  status text not null default 'submitted' check (status in ('submitted','under_review','more_information_required','scope_confirmed','quotation_ready','quote_accepted','invoice_issued','awaiting_payment','payment_confirmed','in_progress','client_review','completed','cancelled','active_subscription','payment_due','suspended')),
  title text not null,
  description text not null,
  deadline date,
  contact_name text not null,
  contact_phone text not null,
  contact_email text not null,
  existing_website_url text,
  answers jsonb not null default '{}'::jsonb,
  uploaded_file_count integer not null default 0,
  quote_status text not null default 'none',
  invoice_status text not null default 'none',
  payment_status text not null default 'not_required_yet',
  assigned_to uuid references auth.users(id) on delete set null,
  admin_summary text,
  internal_notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists service_requests_user_created_idx on public.service_requests(user_id, created_at desc);
create index if not exists service_requests_status_created_idx on public.service_requests(status, created_at desc);
create index if not exists service_requests_area_created_idx on public.service_requests(service_area, created_at desc);

create table if not exists public.service_request_files (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.service_requests(id) on delete cascade,
  storage_bucket text not null default 'service-request-files',
  storage_path text not null,
  file_name text not null,
  file_type text,
  file_size_bytes bigint,
  file_description text,
  uploaded_by uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

create index if not exists service_request_files_request_idx on public.service_request_files(request_id, created_at desc);

create table if not exists public.service_quotes (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.service_requests(id) on delete cascade,
  quote_number text not null unique,
  scope text not null,
  deliverables text,
  optional_additions text,
  estimated_delivery_period text,
  deposit_required_mwk numeric(14,2) not null default 0,
  total_mwk numeric(14,2) not null default 0,
  validity_expires_at date,
  notes text,
  status text not null default 'draft' check (status in ('draft','sent','clarification_requested','accepted','expired','cancelled')),
  created_by uuid references auth.users(id) on delete set null,
  accepted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists service_quotes_request_idx on public.service_quotes(request_id, created_at desc);

create table if not exists public.service_quote_items (
  id uuid primary key default gen_random_uuid(),
  quote_id uuid not null references public.service_quotes(id) on delete cascade,
  item_name text not null,
  item_description text,
  quantity numeric(12,2) not null default 1,
  unit_price_mwk numeric(14,2) not null default 0,
  line_total_mwk numeric(14,2) not null default 0,
  sort_order integer not null default 0
);

create table if not exists public.service_invoices (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.service_requests(id) on delete cascade,
  quote_id uuid references public.service_quotes(id) on delete set null,
  invoice_number text not null unique,
  subtotal_mwk numeric(14,2) not null default 0,
  total_mwk numeric(14,2) not null default 0,
  amount_paid_mwk numeric(14,2) not null default 0,
  status text not null default 'issued' check (status in ('draft','issued','awaiting_payment','payment_submitted','paid','cancelled','refunded')),
  payment_method text,
  payment_reference text,
  payment_proof_bucket text,
  payment_proof_path text,
  due_at date,
  notes text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists service_invoices_request_idx on public.service_invoices(request_id, created_at desc);

create table if not exists public.service_project_updates (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.service_requests(id) on delete cascade,
  created_by uuid references auth.users(id) on delete set null,
  visible_to_customer boolean not null default true,
  update_type text not null default 'status',
  message text not null,
  created_at timestamptz not null default now()
);

create index if not exists service_project_updates_request_idx on public.service_project_updates(request_id, created_at desc);

create table if not exists public.service_admin_notes (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.service_requests(id) on delete cascade,
  admin_user_id uuid references auth.users(id) on delete set null,
  note text not null,
  created_at timestamptz not null default now()
);

create or replace function public.lavida_touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists lavida_touch_service_requests on public.service_requests;
create trigger lavida_touch_service_requests
before update on public.service_requests
for each row execute function public.lavida_touch_updated_at();

drop trigger if exists lavida_touch_service_quotes on public.service_quotes;
create trigger lavida_touch_service_quotes
before update on public.service_quotes
for each row execute function public.lavida_touch_updated_at();

drop trigger if exists lavida_touch_service_invoices on public.service_invoices;
create trigger lavida_touch_service_invoices
before update on public.service_invoices
for each row execute function public.lavida_touch_updated_at();

alter table public.service_requests enable row level security;
alter table public.service_request_files enable row level security;
alter table public.service_quotes enable row level security;
alter table public.service_quote_items enable row level security;
alter table public.service_invoices enable row level security;
alter table public.service_project_updates enable row level security;
alter table public.service_admin_notes enable row level security;

grant select, insert, update on public.service_requests to authenticated;
grant select, insert on public.service_request_files to authenticated;
grant select on public.service_quotes, public.service_quote_items, public.service_invoices, public.service_project_updates to authenticated;
grant insert on public.service_project_updates to authenticated;
grant all on public.service_admin_notes to authenticated;

drop policy if exists "Customers create own service requests" on public.service_requests;
create policy "Customers create own service requests"
  on public.service_requests for insert to authenticated
  with check (user_id = auth.uid());

drop policy if exists "Customers view own service requests" on public.service_requests;
create policy "Customers view own service requests"
  on public.service_requests for select to authenticated
  using (user_id = auth.uid() or public.lavida_is_service_admin());

drop policy if exists "Admins update service requests" on public.service_requests;
create policy "Admins update service requests"
  on public.service_requests for update to authenticated
  using (public.lavida_is_service_admin())
  with check (public.lavida_is_service_admin());

drop policy if exists "Customers add files to own service requests" on public.service_request_files;
create policy "Customers add files to own service requests"
  on public.service_request_files for insert to authenticated
  with check (
    uploaded_by = auth.uid()
    and exists (select 1 from public.service_requests sr where sr.id = request_id and sr.user_id = auth.uid())
  );

drop policy if exists "Customers and admins view service request files" on public.service_request_files;
create policy "Customers and admins view service request files"
  on public.service_request_files for select to authenticated
  using (
    public.lavida_is_service_admin()
    or exists (select 1 from public.service_requests sr where sr.id = request_id and sr.user_id = auth.uid())
  );

drop policy if exists "Customers and admins view service quotes" on public.service_quotes;
create policy "Customers and admins view service quotes"
  on public.service_quotes for select to authenticated
  using (
    public.lavida_is_service_admin()
    or exists (select 1 from public.service_requests sr where sr.id = request_id and sr.user_id = auth.uid())
  );

drop policy if exists "Admins manage service quotes" on public.service_quotes;
create policy "Admins manage service quotes"
  on public.service_quotes for all to authenticated
  using (public.lavida_is_service_admin())
  with check (public.lavida_is_service_admin());

drop policy if exists "Customers and admins view service quote items" on public.service_quote_items;
create policy "Customers and admins view service quote items"
  on public.service_quote_items for select to authenticated
  using (
    public.lavida_is_service_admin()
    or exists (
      select 1 from public.service_quotes sq
      join public.service_requests sr on sr.id = sq.request_id
      where sq.id = quote_id and sr.user_id = auth.uid()
    )
  );

drop policy if exists "Admins manage service quote items" on public.service_quote_items;
create policy "Admins manage service quote items"
  on public.service_quote_items for all to authenticated
  using (public.lavida_is_service_admin())
  with check (public.lavida_is_service_admin());

drop policy if exists "Customers and admins view service invoices" on public.service_invoices;
create policy "Customers and admins view service invoices"
  on public.service_invoices for select to authenticated
  using (
    public.lavida_is_service_admin()
    or exists (select 1 from public.service_requests sr where sr.id = request_id and sr.user_id = auth.uid())
  );

drop policy if exists "Admins manage service invoices" on public.service_invoices;
create policy "Admins manage service invoices"
  on public.service_invoices for all to authenticated
  using (public.lavida_is_service_admin())
  with check (public.lavida_is_service_admin());

drop policy if exists "Customers and admins view visible updates" on public.service_project_updates;
create policy "Customers and admins view visible updates"
  on public.service_project_updates for select to authenticated
  using (
    public.lavida_is_service_admin()
    or (
      visible_to_customer = true
      and exists (select 1 from public.service_requests sr where sr.id = request_id and sr.user_id = auth.uid())
    )
  );

drop policy if exists "Customers add visible updates to own requests" on public.service_project_updates;
create policy "Customers add visible updates to own requests"
  on public.service_project_updates for insert to authenticated
  with check (
    created_by = auth.uid()
    and visible_to_customer = true
    and exists (select 1 from public.service_requests sr where sr.id = request_id and sr.user_id = auth.uid())
  );

drop policy if exists "Admins manage service updates" on public.service_project_updates;
create policy "Admins manage service updates"
  on public.service_project_updates for all to authenticated
  using (public.lavida_is_service_admin())
  with check (public.lavida_is_service_admin());

drop policy if exists "Admins manage private service notes" on public.service_admin_notes;
create policy "Admins manage private service notes"
  on public.service_admin_notes for all to authenticated
  using (public.lavida_is_service_admin())
  with check (public.lavida_is_service_admin());

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'service-request-files',
  'service-request-files',
  false,
  20971520,
  array[
    'application/pdf',
    'application/msword',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'application/vnd.ms-excel',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'application/vnd.ms-powerpoint',
    'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    'image/jpeg',
    'image/png',
    'application/zip',
    'application/x-zip-compressed'
  ]
)
on conflict (id) do update
set public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "Customers upload own service files" on storage.objects;
create policy "Customers upload own service files"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'service-request-files'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "Customers read own service files" on storage.objects;
create policy "Customers read own service files"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'service-request-files'
    and (
      public.lavida_is_service_admin()
      or (storage.foldername(name))[1] = auth.uid()::text
    )
  );

drop policy if exists "Admins manage service files" on storage.objects;
create policy "Admins manage service files"
  on storage.objects for all to authenticated
  using (bucket_id = 'service-request-files' and public.lavida_is_service_admin())
  with check (bucket_id = 'service-request-files' and public.lavida_is_service_admin());
