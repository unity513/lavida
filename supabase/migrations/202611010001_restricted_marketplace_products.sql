begin;

alter table public.marketplace_products
  add column if not exists requires_verified_account boolean not null default false;

create table if not exists public.marketplace_account_verifications (
  user_id uuid primary key references auth.users(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  requested_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid references auth.users(id),
  review_note text
);

alter table public.marketplace_account_verifications enable row level security;

create or replace function public.lavida_is_marketplace_admin()
returns boolean language sql stable security definer set search_path=public as $$
  select exists(select 1 from public.user_roles ur where lower(ur.email)=lower(coalesce(auth.jwt()->>'email','')) and coalesce(ur.active,true) and lower(ur.role) in ('owner','admin','executive','manager','marketplace_admin'))
$$;

drop policy if exists "Users read own marketplace verification" on public.marketplace_account_verifications;
create policy "Users read own marketplace verification" on public.marketplace_account_verifications for select to authenticated using (user_id=auth.uid() or public.lavida_is_marketplace_admin());

create or replace function public.request_marketplace_account_verification()
returns public.marketplace_account_verifications language plpgsql security definer set search_path=public as $$
declare v public.marketplace_account_verifications%rowtype;
begin
  if auth.uid() is null then raise exception 'Sign in to request account verification.'; end if;
  insert into public.marketplace_account_verifications(user_id,status,requested_at,reviewed_at,reviewed_by,review_note)
  values(auth.uid(),'pending',now(),null,null,null)
  on conflict(user_id) do update set status=case when public.marketplace_account_verifications.status='approved' then 'approved' else 'pending' end, requested_at=case when public.marketplace_account_verifications.status='approved' then public.marketplace_account_verifications.requested_at else now() end, reviewed_at=case when public.marketplace_account_verifications.status='approved' then public.marketplace_account_verifications.reviewed_at else null end, reviewed_by=case when public.marketplace_account_verifications.status='approved' then public.marketplace_account_verifications.reviewed_by else null end, review_note=case when public.marketplace_account_verifications.status='approved' then public.marketplace_account_verifications.review_note else null end
  returning * into v;
  return v;
end $$;

create or replace function public.review_marketplace_account_verification(p_user_id uuid,p_status text,p_note text default null)
returns public.marketplace_account_verifications language plpgsql security definer set search_path=public as $$
declare v public.marketplace_account_verifications%rowtype;
begin
  if not public.lavida_is_marketplace_admin() then raise exception 'Access denied.' using errcode='42501'; end if;
  if p_status not in ('approved','rejected') then raise exception 'Verification status must be approved or rejected.'; end if;
  insert into public.marketplace_account_verifications(user_id,status,requested_at,reviewed_at,reviewed_by,review_note)
  values(p_user_id,p_status,now(),now(),auth.uid(),nullif(trim(p_note),''))
  on conflict(user_id) do update set status=excluded.status,reviewed_at=now(),reviewed_by=auth.uid(),review_note=excluded.review_note
  returning * into v;
  return v;
end $$;

create or replace function public.get_visible_marketplace_products()
returns setof public.marketplace_products language sql stable security definer set search_path=public as $$
  select mp.* from public.marketplace_products mp
  where coalesce(mp.published,false)=true and coalesce(mp.status,'') in ('published','active')
    and (not mp.requires_verified_account or exists(select 1 from public.marketplace_account_verifications v where v.user_id=auth.uid() and v.status='approved'))
  order by mp.updated_at desc
$$;

create or replace function public.lavida_restrict_marketplace_order_items()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if exists(select 1 from public.marketplace_products mp where mp.id=new.product_id and mp.requires_verified_account)
     and not exists(select 1 from public.marketplace_account_verifications v where v.user_id=auth.uid() and v.status='approved') then
    raise exception 'This restricted product requires an admin-approved account.' using errcode='42501';
  end if;
  return new;
end $$;
drop trigger if exists restrict_marketplace_order_items on public.marketplace_order_items;
create trigger restrict_marketplace_order_items before insert or update of product_id on public.marketplace_order_items for each row execute function public.lavida_restrict_marketplace_order_items();

grant execute on function public.request_marketplace_account_verification(),public.review_marketplace_account_verification(uuid,text,text),public.get_visible_marketplace_products() to authenticated;
grant execute on function public.get_visible_marketplace_products() to anon;
commit;
