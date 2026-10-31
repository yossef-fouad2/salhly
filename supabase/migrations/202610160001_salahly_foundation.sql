-- Salahly M1/M3 foundation. Run this WHOLE file in the Supabase SQL Editor
-- as postgres. It is also a standalone Supabase migration; no includes, keys,
-- extensions, or prior application migrations are required.
-- Requires a normal Supabase project (auth.users, auth.uid(), anon,
-- authenticated, service_role) on PostgreSQL 13+.
--
-- Safe to rerun this version: no tables/data are dropped, existing profiles
-- and notifications are untouched, and existing category slugs are not reset.
-- Only this foundation's policies/triggers are replaced, transactionally.
-- This is NOT an upgrade/repair script for differently shaped legacy tables.
-- Unexpected policies abort the transaction rather than silently combining
-- permissive policies or deleting another feature's authorization rules.
--
-- Arabic literals use PostgreSQL U& Unicode escapes for an ASCII-portable SQL
-- file; the stored values are ordinary Arabic text. No email is copied out of
-- auth.users. No administrator, verification, or future business schema is added.

begin;
set local search_path = '';
set local standard_conforming_strings = on;

create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  full_name text not null,
  role text not null default 'customer',
  phone text,
  city text,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  constraint profiles_full_name_check check (
    full_name = pg_catalog.btrim(full_name)
    and pg_catalog.char_length(full_name) between 2 and 80
  ),
  constraint profiles_role_check check (role in ('customer', 'provider')),
  constraint profiles_phone_check check (pg_catalog.char_length(phone) <= 32),
  constraint profiles_city_check check (pg_catalog.char_length(city) <= 100)
);

create table if not exists public.service_categories (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  slug text not null unique,
  name_en text not null,
  name_ar text not null,
  description_en text not null,
  description_ar text not null,
  icon_key text not null,
  sort_order integer not null default 0,
  is_active boolean not null default true
);

create table if not exists public.notifications (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  title_en text not null,
  title_ar text not null,
  body_en text not null,
  body_ar text not null,
  created_at timestamptz not null default pg_catalog.now(),
  read_at timestamptz
);

-- The profile PK already indexes its auth FK. The notification index supports
-- owned inbox queries ordered by created_at DESC and profile-delete cascades.
create index if not exists notifications_user_id_created_at_idx
  on public.notifications (user_id, created_at desc);
create index if not exists service_categories_active_sort_order_idx
  on public.service_categories (sort_order, slug) where is_active;

do $policy_guard$
begin
  if exists (
    select 1
    from pg_catalog.pg_policies
    where schemaname = 'public'
      and tablename in ('profiles', 'service_categories', 'notifications')
      and not (
        (tablename = 'profiles' and policyname in (
          'salahly_profiles_select_own', 'salahly_profiles_update_own'
        ))
        or (tablename = 'service_categories'
          and policyname = 'salahly_categories_select_active')
        or (tablename = 'notifications' and policyname in (
          'salahly_notifications_select_own', 'salahly_notifications_update_own'
        ))
      )
  ) then
    raise exception 'Unexpected RLS policies on Salahly tables. Review the existing schema separately; no changes have been committed.';
  end if;
end;
$policy_guard$;

alter table public.profiles enable row level security;
alter table public.service_categories enable row level security;
alter table public.notifications enable row level security;

-- Supabase may grant broad default table privileges. Clear BOTH table and
-- column ACLs on these three tables; revoking table UPDATE alone does not
-- remove an existing UPDATE(column) grant. Other schemas/defaults are untouched.
revoke all privileges on table
  public.profiles, public.service_categories, public.notifications
  from public, anon, authenticated, service_role;
revoke all privileges (id, full_name, role, phone, city, created_at, updated_at)
  on table public.profiles from public, anon, authenticated, service_role;
revoke all privileges (
  id, slug, name_en, name_ar, description_en, description_ar, icon_key,
  sort_order, is_active
) on table public.service_categories from public, anon, authenticated, service_role;
revoke all privileges (
  id, user_id, title_en, title_ar, body_en, body_ar, created_at, read_at
) on table public.notifications from public, anon, authenticated, service_role;

grant usage on schema public to authenticated, service_role;
grant select on table
  public.profiles, public.service_categories, public.notifications
  to authenticated;
grant update (full_name, phone, city) on table public.profiles to authenticated;
grant update (read_at) on table public.notifications to authenticated;

-- Trusted server/admin operations only. Supabase's service_role bypasses RLS;
-- never expose its key to the app. It gets CRUD, not TRUNCATE/TRIGGER/REFERENCES
-- or grant options. postgres remains the trusted SQL Editor owner.
grant select, insert, update, delete on table
  public.profiles, public.service_categories, public.notifications
  to service_role;

drop policy if exists salahly_profiles_select_own on public.profiles;
create policy salahly_profiles_select_own on public.profiles
  for select to authenticated
  using ((select auth.uid()) = id);

drop policy if exists salahly_profiles_update_own on public.profiles;
create policy salahly_profiles_update_own on public.profiles
  for update to authenticated
  using ((select auth.uid()) = id)
  with check ((select auth.uid()) = id);

drop policy if exists salahly_categories_select_active on public.service_categories;
create policy salahly_categories_select_active on public.service_categories
  for select to authenticated
  using (is_active = true);

drop policy if exists salahly_notifications_select_own on public.notifications;
create policy salahly_notifications_select_own on public.notifications
  for select to authenticated
  using ((select auth.uid()) = user_id);

drop policy if exists salahly_notifications_update_own on public.notifications;
create policy salahly_notifications_update_own on public.notifications
  for update to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

-- No INSERT/DELETE policies or anonymous policies. RLS controls ROWS; column
-- grants above separately prevent role/ownership/content/timestamp changes.
-- Customer/provider are application labels, never PostgreSQL/JWT role names.

create or replace function public.salahly_touch_profile_updated_at()
returns pg_catalog.trigger
language plpgsql
security invoker
set search_path = ''
as $function$
begin
  -- Reflect updates even within a single transaction, unlike transaction now().
  new.updated_at := pg_catalog.clock_timestamp();
  return new;
end;
$function$;

alter function public.salahly_touch_profile_updated_at() owner to postgres;
revoke all privileges on function public.salahly_touch_profile_updated_at()
  from public, anon, authenticated, service_role;

drop trigger if exists salahly_profile_updated_at on public.profiles;
create trigger salahly_profile_updated_at
  before update on public.profiles
  for each row execute function public.salahly_touch_profile_updated_at();

create or replace function public.salahly_handle_auth_user_created()
returns pg_catalog.trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  metadata_name pg_catalog.text;
  inserted_profile_id pg_catalog.uuid;
begin
  metadata_name := pg_catalog.btrim(coalesce(new.raw_user_meta_data ->> 'full_name', ''));
  -- Metadata is untrusted, including for OAuth/imported users. A safe display
  -- name fallback avoids breaking signup and never derives a name from email.
  if pg_catalog.jsonb_typeof(new.raw_user_meta_data -> 'full_name') is distinct from 'string'
    or pg_catalog.char_length(metadata_name) not between 2 and 80 then
    metadata_name := 'Salahly User';
  end if;

  insert into public.profiles (id, full_name, role)
  values (
    new.id,
    metadata_name,
    case when new.raw_user_meta_data ->> 'role' in ('customer', 'provider')
      then new.raw_user_meta_data ->> 'role'
      else 'customer'
    end
  )
  on conflict (id) do nothing
  returning id into inserted_profile_id;

  -- Profile + welcome are atomic. Only a newly inserted profile earns a
  -- welcome, so retries/backfills never duplicate it for an existing profile.
  if inserted_profile_id is not null then
    insert into public.notifications (user_id, title_en, title_ar, body_en, body_ar)
    values (
      inserted_profile_id,
      'Welcome to Salahly',
      U&'\0645\0631\062D\0628\0627 \0628\0643 \0641\064A \0635\0644\062D\0644\064A',
      'Your account is ready. Browse home services and complete your profile.',
      U&'\062D\0633\0627\0628\0643 \062C\0627\0647\0632. \062A\0635\0641\062D \062E\062F\0645\0627\062A \0627\0644\0645\0646\0632\0644 \0648\0623\0643\0645\0644 \0645\0644\0641\0643 \0627\0644\0634\062E\0635\064A.'
    );
  end if;

  return new;
end;
$function$;

alter function public.salahly_handle_auth_user_created() owner to postgres;
revoke all privileges on function public.salahly_handle_auth_user_created()
  from public, anon, authenticated, service_role;

-- Trigger invocation still works with EXECUTE revoked from clients. Only the
-- trusted owner can install these triggers; neither function is a public RPC.
-- INSERT only: later Auth user-metadata updates never synchronize name/role.
drop trigger if exists salahly_auth_user_created on auth.users;
create trigger salahly_auth_user_created
  after insert on auth.users
  for each row execute function public.salahly_handle_auth_user_created();

-- Backfill users that predate installation using exactly the signup rules.
-- Existing profiles (including their role/name/timestamps) are never updated.
-- Profile timestamps reflect provisioning time. Existing profiles without a
-- welcome are intentionally left alone rather than recreating dismissed mail.
with candidates as (
  select
    users.id,
    users.raw_user_meta_data,
    pg_catalog.btrim(coalesce(users.raw_user_meta_data ->> 'full_name', '')) as metadata_name
  from auth.users as users
), inserted_profiles as (
  insert into public.profiles (id, full_name, role)
  select
    id,
    case when pg_catalog.jsonb_typeof(raw_user_meta_data -> 'full_name') = 'string'
      and pg_catalog.char_length(metadata_name) between 2 and 80
      then metadata_name else 'Salahly User'
    end,
    case when raw_user_meta_data ->> 'role' in ('customer', 'provider')
      then raw_user_meta_data ->> 'role' else 'customer'
    end
  from candidates
  where not exists (
    select 1 from public.profiles as existing where existing.id = candidates.id
  )
  on conflict (id) do nothing
  returning id
)
insert into public.notifications (user_id, title_en, title_ar, body_en, body_ar)
select
  id,
  'Welcome to Salahly',
  U&'\0645\0631\062D\0628\0627 \0628\0643 \0641\064A \0635\0644\062D\0644\064A',
  'Your account is ready. Browse home services and complete your profile.',
  U&'\062D\0633\0627\0628\0643 \062C\0627\0647\0632. \062A\0635\0641\062D \062E\062F\0645\0627\062A \0627\0644\0645\0646\0632\0644 \0648\0623\0643\0645\0644 \0645\0644\0641\0643 \0627\0644\0634\062E\0635\064A.'
from inserted_profiles;

-- Exactly six initial categories, in app icon-key order. ON CONFLICT preserves
-- trusted catalog edits, inactive state, and stable IDs on subsequent runs.
insert into public.service_categories (
  slug, name_en, name_ar, description_en, description_ar, icon_key, sort_order
)
values
  (
    'plumbing', 'Plumbing', U&'\0627\0644\0633\0628\0627\0643\0629',
    'Repair leaks and install or maintain household pipes.',
    U&'\0625\0635\0644\0627\062D \0627\0644\062A\0633\0631\064A\0628\0627\062A \0648\062A\0631\0643\064A\0628 \0648\0635\064A\0627\0646\0629 \0627\0644\0645\0648\0627\0633\064A\0631.',
    'plumbing', 10
  ),
  (
    'electrical', 'Electrical', U&'\0627\0644\0643\0647\0631\0628\0627\0621',
    'Troubleshoot electrical faults and maintain home wiring.',
    U&'\0625\0635\0644\0627\062D \0627\0644\0623\0639\0637\0627\0644 \0648\0635\064A\0627\0646\0629 \0627\0644\062A\0645\062F\064A\062F\0627\062A \0627\0644\0643\0647\0631\0628\0627\0626\064A\0629.',
    'electrical', 20
  ),
  (
    'carpentry', 'Carpentry', U&'\0627\0644\0646\062C\0627\0631\0629',
    'Repair and fit wooden doors and furniture.',
    U&'\0625\0635\0644\0627\062D \0648\062A\0631\0643\064A\0628 \0627\0644\0623\0628\0648\0627\0628 \0648\0627\0644\0623\062B\0627\062B \0627\0644\062E\0634\0628\064A.',
    'carpentry', 30
  ),
  (
    'air_conditioning', 'Air Conditioning', U&'\062A\0643\064A\064A\0641 \0627\0644\0647\0648\0627\0621',
    'Install, clean, and maintain air conditioning units.',
    U&'\062A\0631\0643\064A\0628 \0648\062A\0646\0638\064A\0641 \0648\0635\064A\0627\0646\0629 \0623\062C\0647\0632\0629 \0627\0644\062A\0643\064A\064A\0641.',
    'air_conditioning', 40
  ),
  (
    'appliance_repair', 'Appliance Repair', U&'\0625\0635\0644\0627\062D \0627\0644\0623\062C\0647\0632\0629',
    'Inspect and repair household appliances.',
    U&'\0641\062D\0635 \0648\0625\0635\0644\0627\062D \0627\0644\0623\062C\0647\0632\0629 \0627\0644\0645\0646\0632\0644\064A\0629.',
    'appliance_repair', 50
  ),
  (
    'painting', 'Painting', U&'\0627\0644\062F\0647\0627\0646\0627\062A',
    'Paint walls and ceilings to refresh your home.',
    U&'\062F\0647\0627\0646 \0627\0644\062C\062F\0631\0627\0646 \0648\0627\0644\0623\0633\0642\0641 \0648\062A\062C\062F\064A\062F \0627\0644\0645\0646\0632\0644.',
    'painting', 60
  )
on conflict (slug) do nothing;

commit;

-- Next: run supabase/tests/foundation_rls.sql as postgres. That file deliberately
-- rolls back all fixtures. These SQL checks do not test Auth email delivery,
-- HTTP/PostgREST configuration, or any future Realtime/Storage integration.
