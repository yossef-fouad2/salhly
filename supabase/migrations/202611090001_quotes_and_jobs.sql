-- Salahly M7 quotes and jobs. Run this WHOLE file as postgres after M6.
-- Marketplace publication is a separate, explicit opt-in: never copy private
-- request text, address, photos, or customer identity into the provider feed.
-- Acceptance consents to sharing the original request details with ONE selected
-- provider. Photos and their Storage policies remain customer-only.
--
-- Rerunnable on this schema, including populated/terminal records. ACLs and our
-- guards are restored; unexpected policies abort rather than widen access.
-- This is not a repair script for differently shaped legacy tables. Evidence
-- restricts account deletion; retention requires a separate trusted procedure.
-- No distance/availability matching, appointments, payments, or notifications.

begin;
set local search_path = '';
set local standard_conforming_strings = on;

create schema if not exists salahly_private authorization postgres;
alter schema salahly_private owner to postgres;
revoke all privileges on schema salahly_private from public, anon, authenticated, service_role;
grant usage on schema salahly_private to authenticated;

-- The composite key prevents a job from substituting another request's owner.
create unique index if not exists service_requests_id_customer_key
  on public.service_requests (id, customer_id);
alter table public.service_requests drop constraint if exists service_requests_status_check;
alter table public.service_requests add constraint service_requests_status_check check (
  (status in ('open', 'assigned') and cancelled_at is null)
  or (status = 'cancelled' and cancelled_at is not null
    and pg_catalog.isfinite(cancelled_at) and cancelled_at >= created_at)
);

create table if not exists public.request_marketplace_listings (
  request_id uuid primary key references public.service_requests (id) on delete restrict,
  summary text not null,
  city text not null,
  consented_at timestamptz not null,
  published_at timestamptz not null,
  constraint request_marketplace_listings_summary_check check (
    summary = pg_catalog.regexp_replace(summary, '^[[:space:]]+|[[:space:]]+$', '', 'g')
    and pg_catalog.char_length(summary) between 10 and 1000
  ),
  constraint request_marketplace_listings_city_check check (
    city = pg_catalog.regexp_replace(city, '^[[:space:]]+|[[:space:]]+$', '', 'g')
    and pg_catalog.char_length(city) between 2 and 100
  ),
  constraint request_marketplace_listings_consent_check check (
    pg_catalog.isfinite(published_at) and consented_at = published_at
  )
);
create index if not exists request_marketplace_listings_feed_idx
  on public.request_marketplace_listings (published_at desc, request_id desc);

create table if not exists public.provider_quotes (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  request_id uuid not null references public.request_marketplace_listings (request_id) on delete restrict,
  provider_id uuid not null references public.provider_profiles (user_id) on delete restrict,
  provider_name text not null,
  amount_minor integer not null check (amount_minor between 1 and 100000000),
  currency text not null check (currency = 'EGP'),
  duration_minutes integer not null check (duration_minutes between 1 and 43200),
  notes text not null,
  revision integer not null default 1 check (revision >= 1),
  status text not null default 'pending'
    check (status in ('pending', 'withdrawn', 'accepted', 'not_selected', 'cancelled')),
  created_at timestamptz not null,
  updated_at timestamptz not null,
  unique (request_id, provider_id),
  unique (id, request_id, provider_id),
  constraint provider_quotes_name_check check (
    provider_name = pg_catalog.regexp_replace(provider_name, '^[[:space:]]+|[[:space:]]+$', '', 'g')
    and pg_catalog.char_length(provider_name) between 2 and 80
  ),
  constraint provider_quotes_notes_check check (
    notes = pg_catalog.regexp_replace(notes, '^[[:space:]]+|[[:space:]]+$', '', 'g')
    and pg_catalog.char_length(notes) <= 1000
  ),
  constraint provider_quotes_time_check check (
    pg_catalog.isfinite(created_at) and pg_catalog.isfinite(updated_at) and updated_at >= created_at
  )
);
create unique index if not exists provider_quotes_one_accepted_idx
  on public.provider_quotes (request_id) where status = 'accepted';
create index if not exists provider_quotes_provider_history_idx
  on public.provider_quotes (provider_id, created_at desc, id desc);
create index if not exists provider_quotes_request_history_idx
  on public.provider_quotes (request_id, created_at desc, id desc);

create table if not exists public.service_jobs (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  request_id uuid not null unique,
  quote_id uuid not null unique,
  customer_id uuid not null,
  provider_id uuid not null,
  provider_name text not null,
  amount_minor integer not null check (amount_minor between 1 and 100000000),
  currency text not null check (currency = 'EGP'),
  duration_minutes integer not null check (duration_minutes between 1 and 43200),
  notes text not null,
  quote_revision integer not null check (quote_revision >= 1),
  status text not null default 'selected'
    check (status in ('selected', 'on_the_way', 'in_progress', 'awaiting_confirmation', 'completed', 'cancelled')),
  disclosure_consented_at timestamptz not null,
  created_at timestamptz not null,
  updated_at timestamptz not null,
  foreign key (request_id, customer_id) references public.service_requests (id, customer_id) on delete restrict,
  foreign key (quote_id, request_id, provider_id)
    references public.provider_quotes (id, request_id, provider_id) on delete restrict,
  constraint service_jobs_participants_check check (customer_id <> provider_id),
  constraint service_jobs_name_check check (
    provider_name = pg_catalog.regexp_replace(provider_name, '^[[:space:]]+|[[:space:]]+$', '', 'g')
    and pg_catalog.char_length(provider_name) between 2 and 80
  ),
  constraint service_jobs_notes_check check (
    notes = pg_catalog.regexp_replace(notes, '^[[:space:]]+|[[:space:]]+$', '', 'g')
    and pg_catalog.char_length(notes) <= 1000
  ),
  constraint service_jobs_time_check check (
    pg_catalog.isfinite(created_at) and pg_catalog.isfinite(updated_at)
    and updated_at >= created_at and disclosure_consented_at = created_at
  )
);
create index if not exists service_jobs_customer_history_idx
  on public.service_jobs (customer_id, created_at desc, id desc);
create index if not exists service_jobs_provider_history_idx
  on public.service_jobs (provider_id, created_at desc, id desc);

create table if not exists public.job_status_history (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  job_id uuid not null references public.service_jobs (id) on delete restrict,
  from_status text,
  status text not null,
  actor_id uuid not null references public.profiles (id) on delete restrict,
  created_at timestamptz not null check (pg_catalog.isfinite(created_at)),
  unique (job_id, status),
  constraint job_status_history_edge_check check (
    (from_status is null and status = 'selected')
    or (from_status is not null and (
      (from_status = 'selected' and status in ('on_the_way', 'in_progress', 'cancelled'))
      or (from_status = 'on_the_way' and status in ('in_progress', 'cancelled'))
      or (from_status = 'in_progress' and status = 'awaiting_confirmation')
      or (from_status = 'awaiting_confirmation' and status = 'completed')
    ))
  )
);
create index if not exists job_status_history_order_idx
  on public.job_status_history (job_id, created_at, id);

alter table public.request_marketplace_listings owner to postgres;
alter table public.provider_quotes owner to postgres;
alter table public.service_jobs owner to postgres;
alter table public.job_status_history owner to postgres;
alter table public.request_marketplace_listings enable row level security;
alter table public.provider_quotes enable row level security;
alter table public.service_jobs enable row level security;
alter table public.job_status_history enable row level security;

-- No base-table API reads, embedding, or writes for M7, even with guessed IDs.
-- Only bounded, explicitly projected RPCs are exposed. Clear column ACL drift
-- too, including any unexpected extra columns, without granting them back.
do $table_security$
declare
  relation_name text;
  columns text;
begin
  foreach relation_name in array array[
    'request_marketplace_listings', 'provider_quotes', 'service_jobs', 'job_status_history',
    'service_requests', 'service_request_photos'
  ] loop
    execute pg_catalog.format('revoke all privileges on table public.%I from public, anon, authenticated, service_role', relation_name);
    select pg_catalog.string_agg(pg_catalog.quote_ident(attname), ',' order by attnum) into columns
      from pg_catalog.pg_attribute where attrelid = ('public.' || relation_name)::regclass
        and attnum > 0 and not attisdropped;
    execute pg_catalog.format('revoke all privileges (%s) on public.%I from public, anon, authenticated, service_role', columns, relation_name);
  end loop;
end;
$table_security$;
alter table public.service_requests enable row level security;
alter table public.service_request_photos enable row level security;
grant select on public.service_requests, public.service_request_photos to authenticated, service_role;
-- Restore only the existing M6 owner policies; never add provider/photo access.
drop policy if exists salahly_service_requests_select_own on public.service_requests;
create policy salahly_service_requests_select_own on public.service_requests
  for select to authenticated using (salahly_private.request_customer_is_self(customer_id));
drop policy if exists salahly_service_request_photos_select_own on public.service_request_photos;
create policy salahly_service_request_photos_select_own on public.service_request_photos
  for select to authenticated using (exists (
    select 1 from public.service_requests where id = request_id and customer_id = (select auth.uid())
  ));

create or replace function salahly_private.marketplace_provider_eligible(
  p_provider_id uuid, p_category_id uuid default null, p_city text default null
)
returns boolean language sql stable security definer set search_path = ''
as $function$
  select coalesce(
    exists (select 1 from public.profiles where id = p_provider_id and role = 'provider')
    and (select status = 'verified' from public.provider_verifications where user_id = p_provider_id
      order by submitted_at desc, id desc limit 1)
    and exists (select 1 from public.provider_skills as skill
      join public.service_categories as category on category.id = skill.category_id
      where skill.user_id = p_provider_id and category.is_active
        and (p_category_id is null or category.id = p_category_id))
    and exists (select 1 from public.provider_service_areas as area
      where area.user_id = p_provider_id and (p_city is null
        or pg_catalog.lower(pg_catalog.regexp_replace(area.label, '^[[:space:]]+|[[:space:]]+$', '', 'g'))
          = pg_catalog.lower(pg_catalog.regexp_replace(p_city, '^[[:space:]]+|[[:space:]]+$', '', 'g')))), false);
$function$;

create or replace function salahly_private.lock_marketplace_request(p_request_id uuid)
returns public.service_requests language plpgsql security definer set search_path = ''
as $function$
declare
  customer uuid;
  request public.service_requests%rowtype;
begin
  select customer_id into customer from public.service_requests where id = p_request_id;
  if not found then raise exception using message = 'marketplace.errors.not_found'; end if;
  -- Same foundation-profile lock as M6 submission/cancellation/Storage guards.
  -- Do not require a current role here: existing job participant IDs are final.
  perform 1 from public.profiles where id = customer for update;
  select * into request from public.service_requests where id = p_request_id and customer_id = customer for update;
  if not found then raise exception using message = 'marketplace.errors.not_found'; end if;
  return request;
end;
$function$;

create or replace function salahly_private.lock_marketplace_provider(
  p_provider_id uuid, p_category_id uuid, p_city text
)
returns text language plpgsql security definer set search_path = ''
as $function$
declare
  provider_name text;
begin
  -- M5 saves/reviews use this profile lock before category locks. Revalidate
  -- AFTER waiting, not against a pre-lock eligibility snapshot.
  select pg_catalog.regexp_replace(full_name, '^[[:space:]]+|[[:space:]]+$', '', 'g') into provider_name
    from public.profiles where id = p_provider_id for update;
  perform 1 from public.service_categories where id = p_category_id for share;
  if not salahly_private.marketplace_provider_eligible(p_provider_id, p_category_id, p_city) then
    raise exception using message = 'marketplace.errors.ineligible';
  end if;
  return provider_name;
end;
$function$;

create or replace function salahly_private.validate_marketplace_page(
  p_before_created_at timestamptz, p_before_id uuid, p_limit integer
)
returns void language plpgsql stable security definer set search_path = ''
as $function$
begin
  if p_limit is null or p_limit not between 1 and 50
    or (p_before_created_at is null) <> (p_before_id is null)
    or (p_before_created_at is not null and not pg_catalog.isfinite(p_before_created_at)) then
    raise exception using message = 'marketplace.errors.invalid';
  end if;
end;
$function$;

create or replace function salahly_private.marketplace_listing_snapshot(p_request_id uuid)
returns jsonb language sql stable security definer set search_path = ''
as $function$
  select pg_catalog.jsonb_build_object(
    'request_id', listing.request_id, 'category_id', request.category_id,
    'category_name_en', request.category_name_en, 'category_name_ar', request.category_name_ar,
    'category_icon_key', request.category_icon_key, 'summary', listing.summary,
    'city', listing.city, 'published_at', listing.published_at, 'request_status', request.status
  ) from public.request_marketplace_listings as listing
    join public.service_requests as request on request.id = listing.request_id
    where listing.request_id = p_request_id;
$function$;

create or replace function salahly_private.provider_quote_snapshot(p_quote_id uuid)
returns jsonb language sql stable security definer set search_path = ''
as $function$
  select pg_catalog.jsonb_build_object(
    'id', id, 'request_id', request_id, 'provider_id', provider_id, 'provider_name', provider_name,
    'amount_minor', amount_minor, 'currency', currency, 'duration_minutes', duration_minutes,
    'notes', notes, 'revision', revision, 'status', status, 'created_at', created_at, 'updated_at', updated_at
  ) from public.provider_quotes where id = p_quote_id;
$function$;

create or replace function salahly_private.quote_opportunity_snapshot(p_request_id uuid, p_provider_id uuid)
returns jsonb language sql stable security definer set search_path = ''
as $function$
  select pg_catalog.jsonb_build_object(
    'listing', salahly_private.marketplace_listing_snapshot(request.id),
    'quote', salahly_private.provider_quote_snapshot(quote.id),
    'can_quote', request.status = 'open' and request.customer_id <> p_provider_id
      and (quote.id is null or quote.status in ('pending', 'withdrawn'))
      and salahly_private.marketplace_provider_eligible(p_provider_id, request.category_id, listing.city)
  ) from public.request_marketplace_listings as listing
    join public.service_requests as request on request.id = listing.request_id
    left join public.provider_quotes as quote on quote.request_id = request.id and quote.provider_id = p_provider_id
    where request.id = p_request_id;
$function$;

create or replace function salahly_private.service_job_snapshot(p_job_id uuid)
returns jsonb language sql stable security definer set search_path = ''
as $function$
  select pg_catalog.jsonb_build_object(
    'id', job.id, 'request_id', job.request_id, 'quote_id', job.quote_id,
    'customer_id', job.customer_id, 'provider_id', job.provider_id, 'provider_name', job.provider_name,
    'amount_minor', job.amount_minor, 'currency', job.currency, 'duration_minutes', job.duration_minutes,
    'notes', job.notes, 'quote_revision', job.quote_revision, 'status', job.status, 'created_at', job.created_at, 'updated_at', job.updated_at,
    'request_title', request.title, 'request_description', request.description, 'city', request.city,
    'address', request.address, 'preferred_at', request.preferred_at,
    'history', coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'id', event.id, 'from_status', event.from_status, 'status', event.status,
      'actor_id', event.actor_id, 'created_at', event.created_at
    ) order by event.created_at, event.id) from (
      -- The acyclic state machine permits at most five events, including selected.
      select * from public.job_status_history where job_id = job.id order by created_at, id limit 5
    ) as event), '[]'::jsonb)
  ) from public.service_jobs as job join public.service_requests as request on request.id = job.request_id
    where job.id = p_job_id;
$function$;

create or replace function salahly_private.guard_marketplace_listing()
returns trigger language plpgsql security definer set search_path = ''
as $function$
begin
  if tg_op = 'DELETE' then raise exception using message = 'marketplace.errors.status'; end if;
  if tg_op = 'UPDATE' then
    if pg_catalog.to_jsonb(new) is distinct from pg_catalog.to_jsonb(old) then
      raise exception using message = 'marketplace.errors.conflict';
    end if;
  elsif not exists (select 1 from public.service_requests as request
    where request.id = new.request_id and request.status = 'open' and request.customer_id = auth.uid()
      and salahly_private.request_customer_is_self(request.customer_id)
      and new.published_at >= request.created_at) then
    raise exception using message = 'marketplace.errors.status';
  end if;
  return new;
end;
$function$;

create or replace function salahly_private.guard_provider_quote()
returns trigger language plpgsql security definer set search_path = ''
as $function$
declare
  request public.service_requests%rowtype;
  listing_city text;
  is_save boolean;
begin
  if tg_op = 'DELETE' then raise exception using message = 'marketplace.errors.status'; end if;
  select * into request from public.service_requests where id = new.request_id;
  select city into listing_city from public.request_marketplace_listings where request_id = new.request_id;
  if tg_op = 'INSERT' then
    if new.status <> 'pending' or new.revision <> 1 or new.created_at is distinct from new.updated_at then
      raise exception using message = 'marketplace.errors.status';
    end if;
    if new.provider_name is distinct from (select pg_catalog.regexp_replace(full_name, '^[[:space:]]+|[[:space:]]+$', '', 'g')
      from public.profiles where id = new.provider_id) then
      raise exception using message = 'marketplace.errors.conflict';
    end if;
    is_save := true;
  else
    if (pg_catalog.to_jsonb(new) - array['amount_minor', 'currency', 'duration_minutes', 'notes', 'revision', 'status', 'updated_at'])
      is distinct from (pg_catalog.to_jsonb(old) - array['amount_minor', 'currency', 'duration_minutes', 'notes', 'revision', 'status', 'updated_at']) then
      raise exception using message = 'marketplace.errors.conflict';
    end if;
    if pg_catalog.to_jsonb(new) = pg_catalog.to_jsonb(old) then return new; end if;
    if not pg_catalog.isfinite(new.updated_at) or new.updated_at <= old.updated_at then
      raise exception using message = 'marketplace.errors.conflict';
    end if;
    is_save := old.status in ('pending', 'withdrawn') and new.status = 'pending'
      and new.revision::bigint = old.revision::bigint + 1;
    if not is_save then
      if (new.amount_minor, new.currency, new.duration_minutes, new.notes, new.revision)
        is distinct from (old.amount_minor, old.currency, old.duration_minutes, old.notes, old.revision) then
        raise exception using message = 'marketplace.errors.conflict';
      end if;
      if old.status <> 'pending' then raise exception using message = 'marketplace.errors.status'; end if;
      if new.status = 'withdrawn' then
        if auth.uid() is distinct from old.provider_id or request.status <> 'open' then
          raise exception using message = 'marketplace.errors.status';
        end if;
      elsif new.status in ('accepted', 'not_selected') then
        if not exists (select 1 from public.service_jobs as job where job.request_id = new.request_id
          and ((new.status = 'accepted' and job.quote_id = new.id
            and (job.provider_id, job.provider_name, job.amount_minor, job.currency, job.duration_minutes, job.notes, job.quote_revision)
              = (new.provider_id, new.provider_name, new.amount_minor, new.currency, new.duration_minutes, new.notes, new.revision))
            or (new.status = 'not_selected' and job.quote_id <> new.id))) then
          raise exception using message = 'marketplace.errors.status';
        end if;
      elsif new.status = 'cancelled' then
        if request.status <> 'cancelled' or exists (select 1 from public.service_jobs where request_id = new.request_id) then
          raise exception using message = 'marketplace.errors.status';
        end if;
      else
        raise exception using message = 'marketplace.errors.status';
      end if;
    end if;
  end if;
  if is_save then
    if auth.uid() is distinct from new.provider_id then
      raise exception using errcode = '42501', message = 'marketplace.errors.access';
    end if;
    if request.id is null or listing_city is null then raise exception using message = 'marketplace.errors.unpublished'; end if;
    if request.status <> 'open' then raise exception using message = 'marketplace.errors.status'; end if;
    if request.customer_id = new.provider_id
      or not salahly_private.marketplace_provider_eligible(new.provider_id, request.category_id, listing_city) then
      raise exception using message = 'marketplace.errors.ineligible';
    end if;
  end if;
  return new;
end;
$function$;

create or replace function salahly_private.guard_service_job()
returns trigger language plpgsql security definer set search_path = ''
as $function$
declare
  quote public.provider_quotes%rowtype;
  request public.service_requests%rowtype;
  allowed boolean;
begin
  if tg_op = 'DELETE' then raise exception using message = 'marketplace.errors.status'; end if;
  if tg_op = 'INSERT' then
    select * into quote from public.provider_quotes where id = new.quote_id;
    select * into request from public.service_requests where id = new.request_id;
    if quote.id is null or request.id is null
      or (new.request_id, new.customer_id, new.provider_id, new.provider_name, new.amount_minor,
          new.currency, new.duration_minutes, new.notes, new.quote_revision)
        is distinct from (quote.request_id, request.customer_id, quote.provider_id, quote.provider_name,
          quote.amount_minor, quote.currency, quote.duration_minutes, quote.notes, quote.revision) then
      raise exception using message = 'marketplace.errors.conflict';
    end if;
    if not salahly_private.request_customer_is_self(new.customer_id) then
      raise exception using errcode = '42501', message = 'marketplace.errors.access';
    end if;
    if new.status <> 'selected' or request.status <> 'open' or quote.status <> 'pending'
      or new.created_at is distinct from new.updated_at or new.created_at < quote.updated_at then
      raise exception using message = 'marketplace.errors.status';
    end if;
    if not salahly_private.marketplace_provider_eligible(new.provider_id, request.category_id,
      (select city from public.request_marketplace_listings where request_id = new.request_id)) then
      raise exception using message = 'marketplace.errors.ineligible';
    end if;
  else
    if (pg_catalog.to_jsonb(new) - array['status', 'updated_at'])
      is distinct from (pg_catalog.to_jsonb(old) - array['status', 'updated_at']) then
      raise exception using message = 'marketplace.errors.conflict';
    end if;
    if pg_catalog.to_jsonb(new) = pg_catalog.to_jsonb(old) then return new; end if;
    -- Immutable participant IDs, NOT current profile role, verification, skills,
    -- category activity, or service area, govern an already-selected job.
    allowed := (auth.uid() = old.provider_id and (
        (old.status = 'selected' and new.status in ('on_the_way', 'in_progress'))
        or (old.status = 'on_the_way' and new.status = 'in_progress')
        or (old.status = 'in_progress' and new.status = 'awaiting_confirmation')))
      or (auth.uid() = old.customer_id and old.status = 'awaiting_confirmation' and new.status = 'completed')
      or (auth.uid() in (old.customer_id, old.provider_id) and old.status in ('selected', 'on_the_way') and new.status = 'cancelled');
    if allowed is distinct from true or not pg_catalog.isfinite(new.updated_at) or new.updated_at <= old.updated_at then
      raise exception using message = 'marketplace.errors.status';
    end if;
  end if;
  return new;
end;
$function$;

create or replace function salahly_private.guard_job_status_history()
returns trigger language plpgsql security definer set search_path = ''
as $function$
declare
  job public.service_jobs%rowtype;
  previous public.job_status_history%rowtype;
begin
  if tg_op = 'DELETE' then raise exception using message = 'marketplace.errors.status'; end if;
  if tg_op = 'UPDATE' then raise exception using message = 'marketplace.errors.conflict'; end if;
  select * into job from public.service_jobs where id = new.job_id;
  select * into previous from public.job_status_history where job_id = new.job_id order by created_at desc, id desc limit 1;
  if job.id is null or new.actor_id is distinct from auth.uid()
    or new.actor_id not in (job.customer_id, job.provider_id)
    or new.status is distinct from job.status or new.created_at is distinct from job.updated_at then
    raise exception using message = 'marketplace.errors.conflict';
  end if;
  if previous.id is null then
    if new.from_status is not null or new.status <> 'selected' or new.actor_id <> job.customer_id
      or new.created_at <> job.created_at then
      raise exception using message = 'marketplace.errors.status';
    end if;
  elsif new.from_status is distinct from previous.status or new.created_at <= previous.created_at then
    raise exception using message = 'marketplace.errors.status';
  end if;
  return new;
end;
$function$;

create or replace function salahly_private.guard_service_request_record()
returns trigger language plpgsql security definer set search_path = ''
as $function$
begin
  if tg_op = 'DELETE' then raise exception using message = 'requests.errors.status'; end if;
  if tg_table_name = 'service_request_photos' then
    if pg_catalog.to_jsonb(new) is distinct from pg_catalog.to_jsonb(old) then
      raise exception using message = 'requests.errors.conflict';
    end if;
  else
    if (pg_catalog.to_jsonb(new) - array['status', 'cancelled_at'])
      is distinct from (pg_catalog.to_jsonb(old) - array['status', 'cancelled_at']) then
      raise exception using message = 'requests.errors.conflict';
    end if;
    if (new.status, new.cancelled_at) is distinct from (old.status, old.cancelled_at) then
      if old.status <> 'open' then raise exception using message = 'requests.errors.status'; end if;
      if new.status = 'cancelled' then
        if new.cancelled_at is null or not pg_catalog.isfinite(new.cancelled_at) or new.cancelled_at < old.created_at
          or exists (select 1 from public.service_jobs where request_id = old.id) then
          raise exception using message = 'requests.errors.status';
        end if;
      elsif new.status = 'assigned' then
        if new.cancelled_at is not null or not exists (
          select 1 from public.service_jobs as job join public.provider_quotes as quote on quote.id = job.quote_id
          where job.request_id = old.id and quote.status = 'accepted'
        ) then raise exception using message = 'requests.errors.status'; end if;
      else
        raise exception using message = 'requests.errors.status';
      end if;
    end if;
  end if;
  return new;
end;
$function$;

create or replace function salahly_private.finish_request_marketplace_status()
returns trigger language plpgsql security definer set search_path = ''
as $function$
begin
  if new.status = 'assigned' and not exists (
    select 1 from public.service_jobs as job join public.provider_quotes as quote on quote.id = job.quote_id
    where job.request_id = new.id and quote.status = 'accepted'
  ) then raise exception using message = 'requests.errors.status'; end if;
  if new.status = 'cancelled' then
    -- Also protects an accidental trusted cancellation. The public RPC has
    -- already locked customer -> request, the same order as every quote writer.
    perform id from public.provider_quotes where request_id = new.id order by id for update;
    update public.provider_quotes set status = 'cancelled',
      updated_at = greatest(pg_catalog.clock_timestamp(), updated_at + interval '1 microsecond')
      where request_id = new.id and status = 'pending';
  end if;
  return new;
end;
$function$;

create or replace function salahly_private.finish_service_job_write()
returns trigger language plpgsql security definer set search_path = ''
as $function$
begin
  if tg_op = 'INSERT' then
    -- Creation, selection, competitor closure, assignment, and the first event
    -- are one statement/transaction, including on an accidental trusted insert.
    update public.provider_quotes set status = 'accepted',
      updated_at = greatest(new.created_at, updated_at + interval '1 microsecond') where id = new.quote_id;
    update public.provider_quotes set status = 'not_selected',
      updated_at = greatest(new.created_at, updated_at + interval '1 microsecond')
      where request_id = new.request_id and id <> new.quote_id and status = 'pending';
    update public.service_requests set status = 'assigned' where id = new.request_id;
    insert into public.job_status_history (job_id, from_status, status, actor_id, created_at)
      values (new.id, null, new.status, new.customer_id, new.created_at);
  elsif new.status is distinct from old.status then
    insert into public.job_status_history (job_id, from_status, status, actor_id, created_at)
      values (new.id, old.status, new.status, auth.uid(), new.updated_at);
  end if;
  return new;
end;
$function$;

drop trigger if exists salahly_marketplace_listing_guard on public.request_marketplace_listings;
create trigger salahly_marketplace_listing_guard before insert or update or delete on public.request_marketplace_listings
  for each row execute function salahly_private.guard_marketplace_listing();
drop trigger if exists salahly_provider_quote_guard on public.provider_quotes;
create trigger salahly_provider_quote_guard before insert or update or delete on public.provider_quotes
  for each row execute function salahly_private.guard_provider_quote();
drop trigger if exists salahly_service_job_guard on public.service_jobs;
create trigger salahly_service_job_guard before insert or update or delete on public.service_jobs
  for each row execute function salahly_private.guard_service_job();
drop trigger if exists salahly_job_status_history_guard on public.job_status_history;
create trigger salahly_job_status_history_guard before insert or update or delete on public.job_status_history
  for each row execute function salahly_private.guard_job_status_history();
drop trigger if exists salahly_service_request_record_guard on public.service_requests;
create trigger salahly_service_request_record_guard before update or delete on public.service_requests
  for each row execute function salahly_private.guard_service_request_record();
drop trigger if exists salahly_service_request_photo_record_guard on public.service_request_photos;
create trigger salahly_service_request_photo_record_guard before update or delete on public.service_request_photos
  for each row execute function salahly_private.guard_service_request_record();
drop trigger if exists salahly_request_marketplace_status on public.service_requests;
create trigger salahly_request_marketplace_status after insert or update of status on public.service_requests
  for each row execute function salahly_private.finish_request_marketplace_status();
drop trigger if exists salahly_service_job_write on public.service_jobs;
create trigger salahly_service_job_write after insert or update on public.service_jobs
  for each row execute function salahly_private.finish_service_job_write();

create or replace function public.get_marketplace_feed(
  p_before_created_at timestamptz default null, p_before_id uuid default null, p_limit integer default 20
)
returns jsonb language plpgsql stable security definer set search_path = ''
as $function$
declare
  result jsonb;
begin
  if not salahly_private.provider_is_self(auth.uid()) then
    raise exception using errcode = '42501', message = 'marketplace.errors.access';
  end if;
  perform salahly_private.validate_marketplace_page(p_before_created_at, p_before_id, p_limit);
  if not salahly_private.marketplace_provider_eligible(auth.uid()) then
    return pg_catalog.jsonb_build_object('items', '[]'::jsonb, 'has_more', false, 'eligible', false);
  end if;
  with candidates as materialized (
    select listing.request_id, listing.published_at from public.request_marketplace_listings as listing
      join public.service_requests as request on request.id = listing.request_id
      where request.status = 'open' and request.customer_id <> auth.uid()
        and salahly_private.marketplace_provider_eligible(auth.uid(), request.category_id, listing.city)
        and (p_before_created_at is null or (listing.published_at, listing.request_id) < (p_before_created_at, p_before_id))
      order by listing.published_at desc, listing.request_id desc limit p_limit + 1
  ), page as (select * from candidates order by published_at desc, request_id desc limit p_limit)
  select pg_catalog.jsonb_build_object(
    'items', coalesce((select pg_catalog.jsonb_agg(salahly_private.marketplace_listing_snapshot(request_id)
      order by published_at desc, request_id desc) from page), '[]'::jsonb),
    'has_more', (select pg_catalog.count(*) > p_limit from candidates), 'eligible', true
  ) into result;
  return result;
end;
$function$;

create or replace function public.get_provider_request(p_request_id uuid)
returns jsonb language plpgsql stable security definer set search_path = ''
as $function$
declare
  result jsonb;
begin
  if not salahly_private.provider_is_self(auth.uid()) then
    raise exception using errcode = '42501', message = 'marketplace.errors.access';
  end if;
  result := salahly_private.quote_opportunity_snapshot(p_request_id, auth.uid());
  if result is null or (result -> 'quote' = 'null'::jsonb and result -> 'can_quote' <> 'true'::jsonb) then
    raise exception using message = 'marketplace.errors.not_found';
  end if;
  return result;
end;
$function$;

create or replace function public.get_provider_quotes(
  p_before_created_at timestamptz default null, p_before_id uuid default null, p_limit integer default 20
)
returns jsonb language plpgsql stable security definer set search_path = ''
as $function$
declare
  result jsonb;
begin
  if not salahly_private.provider_is_self(auth.uid()) then
    raise exception using errcode = '42501', message = 'marketplace.errors.access';
  end if;
  perform salahly_private.validate_marketplace_page(p_before_created_at, p_before_id, p_limit);
  with candidates as materialized (
    select id, request_id, created_at from public.provider_quotes where provider_id = auth.uid()
      and (p_before_created_at is null or (created_at, id) < (p_before_created_at, p_before_id))
      order by created_at desc, id desc limit p_limit + 1
  ), page as (select * from candidates order by created_at desc, id desc limit p_limit)
  select pg_catalog.jsonb_build_object(
    'items', coalesce((select pg_catalog.jsonb_agg(salahly_private.quote_opportunity_snapshot(request_id, auth.uid())
      order by created_at desc, id desc) from page), '[]'::jsonb),
    'has_more', (select pg_catalog.count(*) > p_limit from candidates)
  ) into result;
  return result;
end;
$function$;

create or replace function public.get_customer_quotes(
  p_request_id uuid, p_before_created_at timestamptz default null, p_before_id uuid default null, p_limit integer default 20
)
returns jsonb language plpgsql stable security definer set search_path = ''
as $function$
declare
  request public.service_requests%rowtype;
  result jsonb;
begin
  if not salahly_private.request_customer_is_self(auth.uid()) then
    raise exception using errcode = '42501', message = 'marketplace.errors.access';
  end if;
  perform salahly_private.validate_marketplace_page(p_before_created_at, p_before_id, p_limit);
  select * into request from public.service_requests where id = p_request_id and customer_id = auth.uid();
  if not found then raise exception using message = 'marketplace.errors.not_found'; end if;
  with candidates as materialized (
    select id, created_at from public.provider_quotes where request_id = p_request_id
      and (p_before_created_at is null or (created_at, id) < (p_before_created_at, p_before_id))
      order by created_at desc, id desc limit p_limit + 1
  ), page as (select * from candidates order by created_at desc, id desc limit p_limit)
  select pg_catalog.jsonb_build_object(
    'request_id', request.id, 'customer_id', request.customer_id, 'request_status', request.status,
    'listing', salahly_private.marketplace_listing_snapshot(request.id),
    'quotes', coalesce((select pg_catalog.jsonb_agg(salahly_private.provider_quote_snapshot(id)
      order by created_at desc, id desc) from page), '[]'::jsonb),
    'has_more', (select pg_catalog.count(*) > p_limit from candidates),
    'job', (select salahly_private.service_job_snapshot(id) from public.service_jobs where request_id = request.id)
  ) into result;
  return result;
end;
$function$;

create or replace function public.publish_request_listing(p_request_id uuid, p_summary text, p_city text, p_consent boolean)
returns jsonb language plpgsql security definer set search_path = ''
as $function$
declare
  request public.service_requests%rowtype;
  listing public.request_marketplace_listings%rowtype;
  summary text := pg_catalog.regexp_replace(p_summary, '^[[:space:]]+|[[:space:]]+$', '', 'g');
  city text := pg_catalog.regexp_replace(p_city, '^[[:space:]]+|[[:space:]]+$', '', 'g');
  published timestamptz;
begin
  if not salahly_private.request_customer_is_self(auth.uid()) then
    raise exception using errcode = '42501', message = 'marketplace.errors.access';
  end if;
  if p_consent is distinct from true then raise exception using message = 'marketplace.errors.consent'; end if;
  if not exists (select 1 from public.service_requests where id = p_request_id and customer_id = auth.uid()) then
    raise exception using message = 'marketplace.errors.not_found';
  end if;
  request := salahly_private.lock_marketplace_request(p_request_id);
  if not salahly_private.request_customer_is_self(request.customer_id) then
    raise exception using errcode = '42501', message = 'marketplace.errors.access';
  end if;
  select * into listing from public.request_marketplace_listings where request_id = p_request_id;
  if found then
    if (listing.summary, listing.city) is distinct from (summary, city) then
      raise exception using message = 'marketplace.errors.conflict';
    end if;
    return salahly_private.marketplace_listing_snapshot(p_request_id);
  end if;
  if request.status <> 'open' then raise exception using message = 'marketplace.errors.status'; end if;
  if summary is null or pg_catalog.char_length(summary) not between 10 and 1000 then
    raise exception using message = 'marketplace.errors.summary';
  end if;
  if city is null or pg_catalog.char_length(city) not between 2 and 100 then
    raise exception using message = 'marketplace.errors.city';
  end if;
  published := greatest(pg_catalog.clock_timestamp(), request.created_at);
  insert into public.request_marketplace_listings (request_id, summary, city, consented_at, published_at)
    values (p_request_id, summary, city, published, published);
  return salahly_private.marketplace_listing_snapshot(p_request_id);
end;
$function$;

create or replace function public.save_provider_quote(
  p_request_id uuid, p_amount_minor integer, p_currency text, p_duration_minutes integer, p_notes text, p_expected_revision integer
)
returns jsonb language plpgsql security definer set search_path = ''
as $function$
declare
  request public.service_requests%rowtype;
  quote public.provider_quotes%rowtype;
  listing_city text;
  normalized_notes text := pg_catalog.regexp_replace(p_notes, '^[[:space:]]+|[[:space:]]+$', '', 'g');
  provider_name text;
  saved timestamptz;
begin
  if not salahly_private.provider_is_self(auth.uid()) then
    raise exception using errcode = '42501', message = 'marketplace.errors.access';
  end if;
  if p_expected_revision is null or p_expected_revision < 0 then raise exception using message = 'marketplace.errors.invalid'; end if;
  request := salahly_private.lock_marketplace_request(p_request_id);
  select city into listing_city from public.request_marketplace_listings where request_id = p_request_id;
  if not found then raise exception using message = 'marketplace.errors.unpublished'; end if;
  select * into quote from public.provider_quotes where request_id = p_request_id and provider_id = auth.uid();
  if found then
    -- A response-loss retry returns canonical state, even if since withdrawn,
    -- selected, closed, or now ineligible. It NEVER reactivates a stale save.
    if quote.revision::bigint = p_expected_revision::bigint + 1
      and (quote.amount_minor, quote.currency, quote.duration_minutes, quote.notes)
        is not distinct from (p_amount_minor, p_currency, p_duration_minutes, normalized_notes) then
      return salahly_private.provider_quote_snapshot(quote.id);
    end if;
    if quote.revision <> p_expected_revision then raise exception using message = 'marketplace.errors.conflict'; end if;
    if quote.status not in ('pending', 'withdrawn') then raise exception using message = 'marketplace.errors.status'; end if;
  elsif p_expected_revision <> 0 then
    raise exception using message = 'marketplace.errors.conflict';
  end if;
  if request.status <> 'open' then raise exception using message = 'marketplace.errors.status'; end if;
  if p_amount_minor is null or p_amount_minor not between 1 and 100000000 then raise exception using message = 'marketplace.errors.amount'; end if;
  if p_currency is distinct from 'EGP' then raise exception using message = 'marketplace.errors.currency'; end if;
  if p_duration_minutes is null or p_duration_minutes not between 1 and 43200 then raise exception using message = 'marketplace.errors.duration'; end if;
  if normalized_notes is null or pg_catalog.char_length(normalized_notes) > 1000 then raise exception using message = 'marketplace.errors.notes'; end if;
  provider_name := salahly_private.lock_marketplace_provider(auth.uid(), request.category_id, listing_city);
  if request.customer_id = auth.uid() then raise exception using message = 'marketplace.errors.ineligible'; end if;
  if quote.id is null then
    if provider_name is null or pg_catalog.char_length(provider_name) not between 2 and 80 then
      raise exception using message = 'marketplace.errors.invalid';
    end if;
    saved := pg_catalog.clock_timestamp();
    insert into public.provider_quotes (
      request_id, provider_id, provider_name, amount_minor, currency, duration_minutes, notes, created_at, updated_at
    ) values (p_request_id, auth.uid(), provider_name, p_amount_minor, p_currency, p_duration_minutes, normalized_notes, saved, saved)
      returning * into quote;
  else
    if quote.revision = 2147483647 then raise exception using message = 'marketplace.errors.conflict'; end if;
    update public.provider_quotes set amount_minor = p_amount_minor, currency = p_currency,
      duration_minutes = p_duration_minutes, notes = normalized_notes, revision = revision + 1, status = 'pending',
      updated_at = greatest(pg_catalog.clock_timestamp(), updated_at + interval '1 microsecond')
      where id = quote.id returning * into quote;
  end if;
  return salahly_private.provider_quote_snapshot(quote.id);
end;
$function$;

create or replace function public.withdraw_provider_quote(p_quote_id uuid, p_expected_revision integer)
returns jsonb language plpgsql security definer set search_path = ''
as $function$
declare
  request_id uuid;
  request public.service_requests%rowtype;
  quote public.provider_quotes%rowtype;
begin
  if not salahly_private.provider_is_self(auth.uid()) then
    raise exception using errcode = '42501', message = 'marketplace.errors.access';
  end if;
  if p_expected_revision is null or p_expected_revision < 1 then raise exception using message = 'marketplace.errors.invalid'; end if;
  select existing.request_id into request_id from public.provider_quotes as existing where id = p_quote_id and provider_id = auth.uid();
  if not found then raise exception using message = 'marketplace.errors.not_found'; end if;
  request := salahly_private.lock_marketplace_request(request_id);
  perform 1 from public.profiles where id = auth.uid() for update;
  if not salahly_private.provider_is_self(auth.uid()) then raise exception using errcode = '42501', message = 'marketplace.errors.access'; end if;
  select * into quote from public.provider_quotes where id = p_quote_id for update;
  if quote.revision <> p_expected_revision then raise exception using message = 'marketplace.errors.conflict'; end if;
  if quote.status = 'withdrawn' then return salahly_private.provider_quote_snapshot(quote.id); end if;
  if quote.status <> 'pending' or request.status <> 'open' then raise exception using message = 'marketplace.errors.status'; end if;
  update public.provider_quotes set status = 'withdrawn',
    updated_at = greatest(pg_catalog.clock_timestamp(), updated_at + interval '1 microsecond') where id = quote.id;
  return salahly_private.provider_quote_snapshot(quote.id);
end;
$function$;

create or replace function public.accept_provider_quote(p_quote_id uuid, p_expected_revision integer, p_consent boolean)
returns jsonb language plpgsql security definer set search_path = ''
as $function$
declare
  request_id uuid;
  request public.service_requests%rowtype;
  quote public.provider_quotes%rowtype;
  job public.service_jobs%rowtype;
  selected timestamptz;
begin
  if not salahly_private.request_customer_is_self(auth.uid()) then
    raise exception using errcode = '42501', message = 'marketplace.errors.access';
  end if;
  if p_consent is distinct from true then raise exception using message = 'marketplace.errors.consent'; end if;
  if p_expected_revision is null or p_expected_revision < 1 then raise exception using message = 'marketplace.errors.invalid'; end if;
  select existing.request_id into request_id from public.provider_quotes as existing
    join public.service_requests as owned on owned.id = existing.request_id
    where existing.id = p_quote_id and owned.customer_id = auth.uid();
  if not found then raise exception using message = 'marketplace.errors.not_found'; end if;
  request := salahly_private.lock_marketplace_request(request_id);
  if not salahly_private.request_customer_is_self(request.customer_id) then
    raise exception using errcode = '42501', message = 'marketplace.errors.access';
  end if;
  select * into quote from public.provider_quotes where id = p_quote_id;
  if quote.revision <> p_expected_revision then raise exception using message = 'marketplace.errors.conflict'; end if;
  select * into job from public.service_jobs as existing where existing.request_id = request.id;
  if found then
    if job.quote_id = quote.id and job.quote_revision = p_expected_revision then
      return salahly_private.service_job_snapshot(job.id);
    end if;
    raise exception using message = 'marketplace.errors.status';
  end if;
  if request.status <> 'open' or quote.status <> 'pending' then raise exception using message = 'marketplace.errors.status'; end if;
  perform salahly_private.lock_marketplace_provider(quote.provider_id, request.category_id,
    (select listing.city from public.request_marketplace_listings as listing where listing.request_id = request.id));
  -- All competing RPCs hold the same customer/request lock before touching a
  -- provider or quote. Sorting also makes the multi-row closure deterministic.
  perform id from public.provider_quotes as existing where existing.request_id = request.id order by id for update;
  selected := greatest(pg_catalog.clock_timestamp(), quote.updated_at);
  insert into public.service_jobs (
    request_id, quote_id, customer_id, provider_id, provider_name, amount_minor, currency,
    duration_minutes, notes, quote_revision, disclosure_consented_at, created_at, updated_at
  ) values (request.id, quote.id, request.customer_id, quote.provider_id, quote.provider_name, quote.amount_minor,
    quote.currency, quote.duration_minutes, quote.notes, quote.revision, selected, selected, selected)
    returning * into job;
  return salahly_private.service_job_snapshot(job.id);
end;
$function$;

create or replace function public.cancel_service_request(p_request_id uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $function$
declare
  customer uuid := auth.uid();
  request public.service_requests%rowtype;
begin
  if not salahly_private.request_customer_is_self(customer) then
    raise exception using errcode = '42501', message = 'requests.errors.access';
  end if;
  perform salahly_private.lock_request_customer(customer);
  select * into request from public.service_requests where id = p_request_id and customer_id = customer for update;
  if not found then raise exception using message = 'requests.errors.not_found'; end if;
  if request.status = 'open' then
    -- The status trigger closes pending quotes in this same transaction.
    update public.service_requests set status = 'cancelled',
      cancelled_at = greatest(pg_catalog.clock_timestamp(), created_at) where id = p_request_id;
  elsif request.status <> 'cancelled' then
    raise exception using message = 'requests.errors.status';
  end if;
  return salahly_private.service_request_snapshot(p_request_id);
end;
$function$;

create or replace function public.get_service_jobs(
  p_before_created_at timestamptz default null, p_before_id uuid default null, p_limit integer default 20
)
returns jsonb language plpgsql stable security definer set search_path = ''
as $function$
declare
  result jsonb;
begin
  if auth.uid() is null or not exists (select 1 from public.profiles where id = auth.uid()) then
    raise exception using errcode = '42501', message = 'marketplace.errors.access';
  end if;
  perform salahly_private.validate_marketplace_page(p_before_created_at, p_before_id, p_limit);
  with candidates as materialized (
    select id, created_at from public.service_jobs where auth.uid() in (customer_id, provider_id)
      and (p_before_created_at is null or (created_at, id) < (p_before_created_at, p_before_id))
      order by created_at desc, id desc limit p_limit + 1
  ), page as (select * from candidates order by created_at desc, id desc limit p_limit)
  select pg_catalog.jsonb_build_object(
    'items', coalesce((select pg_catalog.jsonb_agg(salahly_private.service_job_snapshot(id)
      order by created_at desc, id desc) from page), '[]'::jsonb),
    'has_more', (select pg_catalog.count(*) > p_limit from candidates)
  ) into result;
  return result;
end;
$function$;

create or replace function public.get_service_job(p_job_id uuid)
returns jsonb language plpgsql stable security definer set search_path = ''
as $function$
begin
  if auth.uid() is null or not exists (select 1 from public.profiles where id = auth.uid()) then
    raise exception using errcode = '42501', message = 'marketplace.errors.access';
  end if;
  if not exists (select 1 from public.service_jobs where id = p_job_id and auth.uid() in (customer_id, provider_id)) then
    raise exception using message = 'marketplace.errors.not_found';
  end if;
  return salahly_private.service_job_snapshot(p_job_id);
end;
$function$;

create or replace function public.transition_service_job(p_job_id uuid, p_expected_status text, p_status text)
returns jsonb language plpgsql security definer set search_path = ''
as $function$
declare
  job public.service_jobs%rowtype;
begin
  if auth.uid() is null or not exists (select 1 from public.profiles where id = auth.uid()) then
    raise exception using errcode = '42501', message = 'marketplace.errors.access';
  end if;
  select * into job from public.service_jobs where id = p_job_id and auth.uid() in (customer_id, provider_id);
  if not found then raise exception using message = 'marketplace.errors.not_found'; end if;
  if p_expected_status is null or p_status is null
    or p_expected_status not in ('selected', 'on_the_way', 'in_progress', 'awaiting_confirmation', 'completed', 'cancelled')
    or p_status not in ('selected', 'on_the_way', 'in_progress', 'awaiting_confirmation', 'completed', 'cancelled') then
    raise exception using message = 'marketplace.errors.status';
  end if;
  perform salahly_private.lock_marketplace_request(job.request_id);
  perform 1 from public.profiles where id = job.provider_id for update;
  select * into job from public.service_jobs where id = p_job_id for update;
  -- History is immutable and states never repeat. A retry of an actual edge by
  -- that SAME actor succeeds even if the job has since advanced or terminated.
  if exists (select 1 from public.job_status_history where job_id = job.id and actor_id = auth.uid()
    and from_status = p_expected_status and status = p_status) then
    return salahly_private.service_job_snapshot(job.id);
  end if;
  if job.status <> p_expected_status then raise exception using message = 'marketplace.errors.conflict'; end if;
  update public.service_jobs set status = p_status,
    updated_at = greatest(pg_catalog.clock_timestamp(), updated_at + interval '1 microsecond') where id = job.id;
  return salahly_private.service_job_snapshot(job.id);
end;
$function$;

-- Explicit signatures avoid accidentally granting an unexpected overload.
do $routine_security$
declare
  routine_name text;
begin
  foreach routine_name in array array[
    'salahly_private.marketplace_provider_eligible(uuid,uuid,text)',
    'salahly_private.lock_marketplace_request(uuid)', 'salahly_private.lock_marketplace_provider(uuid,uuid,text)',
    'salahly_private.validate_marketplace_page(timestamptz,uuid,integer)',
    'salahly_private.marketplace_listing_snapshot(uuid)', 'salahly_private.provider_quote_snapshot(uuid)',
    'salahly_private.quote_opportunity_snapshot(uuid,uuid)', 'salahly_private.service_job_snapshot(uuid)',
    'salahly_private.guard_marketplace_listing()', 'salahly_private.guard_provider_quote()',
    'salahly_private.guard_service_job()', 'salahly_private.guard_job_status_history()',
    'salahly_private.guard_service_request_record()', 'salahly_private.finish_request_marketplace_status()',
    'salahly_private.finish_service_job_write()',
    'public.get_marketplace_feed(timestamptz,uuid,integer)', 'public.get_provider_request(uuid)',
    'public.get_provider_quotes(timestamptz,uuid,integer)', 'public.get_customer_quotes(uuid,timestamptz,uuid,integer)',
    'public.publish_request_listing(uuid,text,text,boolean)',
    'public.save_provider_quote(uuid,integer,text,integer,text,integer)', 'public.withdraw_provider_quote(uuid,integer)',
    'public.accept_provider_quote(uuid,integer,boolean)', 'public.cancel_service_request(uuid)',
    'public.get_service_jobs(timestamptz,uuid,integer)', 'public.get_service_job(uuid)',
    'public.transition_service_job(uuid,text,text)'
  ] loop
    execute pg_catalog.format('alter function %s owner to postgres', routine_name::regprocedure);
    execute pg_catalog.format('revoke all privileges on function %s from public, anon, authenticated, service_role', routine_name::regprocedure);
    if pg_catalog.left(routine_name, 7) = 'public.' then
      execute pg_catalog.format('grant execute on function %s to authenticated', routine_name::regprocedure);
    end if;
  end loop;
end;
$routine_security$;

-- CREATE TABLE/INDEX IF NOT EXISTS is not a license to accept an incomplete
-- legacy schema. Refuse missing constraint backstops and inconsistent persisted
-- state instead of rewriting an audit trail or masking it behind JSON limits.
create or replace function salahly_private.validate_marketplace_integrity()
returns void language plpgsql security definer set search_path = ''
as $function$
declare
  expected record;
begin
  if exists (select 1 from pg_catalog.pg_policies where schemaname = 'public' and (
    tablename in ('request_marketplace_listings', 'provider_quotes', 'service_jobs', 'job_status_history')
    or (tablename in ('service_requests', 'service_request_photos')
      and policyname <> 'salahly_' || tablename || '_select_own')
  )) then
    raise exception 'Unexpected RLS policies on marketplace/request tables. No changes have been committed.';
  end if;
  for expected in select * from (values
    ('request_marketplace_listings',5), ('provider_quotes',13), ('service_jobs',14), ('job_status_history',6)
  ) as shape(relation_name,constraint_count) loop
    -- PostgreSQL 18 additionally catalogs NOT NULL (type n) constraints.
    if (select pg_catalog.count(*) from pg_catalog.pg_constraint
      where conrelid = ('public.' || expected.relation_name)::regclass
        and contype in ('p','u','f','c') and convalidated and not condeferrable)
      <> expected.constraint_count then
      raise exception 'Unexpected marketplace table constraints: %. No changes have been committed.', expected.relation_name;
    end if;
  end loop;
  if not exists (select 1 from pg_catalog.pg_index
    where indexrelid = 'public.provider_quotes_one_accepted_idx'::regclass
      and indrelid = 'public.provider_quotes'::regclass and indisunique and indisvalid and indnkeyatts = 1
      and indkey[0] = (select attnum from pg_catalog.pg_attribute
        where attrelid = 'public.provider_quotes'::regclass and attname = 'request_id')
      and pg_catalog.pg_get_expr(indpred,indrelid) = '(status = ''accepted''::text)') then
    raise exception 'Unexpected accepted-quote uniqueness index. No changes have been committed.';
  end if;
  if exists (select 1 from public.service_requests as request where (request.status = 'assigned')
    is distinct from exists (select 1 from public.service_jobs as job where job.request_id = request.id))
    or exists (select 1 from public.request_marketplace_listings as listing
      join public.service_requests as request on request.id = listing.request_id where listing.published_at < request.created_at)
    or exists (select 1 from public.service_jobs as job join public.provider_quotes as quote on quote.id = job.quote_id
      where quote.status <> 'accepted'
        or (job.provider_name,job.amount_minor,job.currency,job.duration_minutes,job.notes,job.quote_revision)
          is distinct from (quote.provider_name,quote.amount_minor,quote.currency,quote.duration_minutes,quote.notes,quote.revision))
    or exists (select 1 from public.provider_quotes as quote join public.service_requests as request on request.id = quote.request_id
      left join public.service_jobs as job on job.request_id = quote.request_id
      where (quote.status = 'pending' and request.status <> 'open')
        or (quote.status = 'accepted' and (job.id is null or job.quote_id <> quote.id))
        or (quote.status = 'not_selected' and (job.id is null or job.quote_id = quote.id))
        or (quote.status = 'cancelled' and request.status <> 'cancelled')) then
    raise exception 'Inconsistent persisted marketplace assignment/terms. No changes have been committed.';
  end if;
  if exists (select 1 from public.service_jobs as job left join lateral (
    select status,created_at from public.job_status_history where job_id = job.id order by created_at desc,id desc limit 1
  ) as latest on true where latest.status is distinct from job.status or latest.created_at is distinct from job.updated_at)
    or exists (
      select 1 from (
        select event.*, pg_catalog.row_number() over history as ordinal,
          pg_catalog.lag(status) over history as previous_status,
          pg_catalog.lag(created_at) over history as previous_time
        from public.job_status_history as event
        window history as (partition by job_id order by created_at,id)
      ) as event join public.service_jobs as job on job.id = event.job_id
      where event.ordinal > 5
        or (event.ordinal = 1 and (event.from_status is not null or event.status <> 'selected'
          or event.actor_id <> job.customer_id or event.created_at <> job.created_at))
        or (event.ordinal > 1 and (event.from_status is distinct from event.previous_status or event.created_at <= event.previous_time))
        or (event.status in ('on_the_way','in_progress','awaiting_confirmation') and event.actor_id <> job.provider_id)
        or (event.status = 'completed' and event.actor_id <> job.customer_id)
        or event.actor_id not in (job.customer_id,job.provider_id)
    ) then
    raise exception 'Inconsistent persisted marketplace history. No changes have been committed.';
  end if;
end;
$function$;
alter function salahly_private.validate_marketplace_integrity() owner to postgres;
revoke all privileges on function salahly_private.validate_marketplace_integrity() from public, anon, authenticated, service_role;
select salahly_private.validate_marketplace_integrity();

commit;

-- Run supabase/tests/quotes_and_jobs_rls.sql and all three earlier suites.
-- SQL role/metadata fixtures do not verify JWTs, hosted PostgREST/Storage HTTP,
-- actual bytes, or independent-session races. The local runner covers races
-- separately; never interpret a lost response as a confirmed failed write.
