-- Salahly M5 provider onboarding. Run this WHOLE migration as postgres after
-- 202610160001_salahly_foundation.sql. Requires the normal Supabase Storage
-- schema, including storage.objects.owner_id and buckets' upload-limit fields.
-- Rerunnable without deleting drafts, reviews, or objects. This is not a repair
-- script for differently shaped legacy tables; unexpected public-table policies
-- abort the transaction. No jobs, appointments, admin UI, or public credentials.
--
-- Availability is recurring ISO-weekday wall-clock time in each service area's
-- local time, not appointment slots. No time-zone or geocoding semantics here.
-- Evidence/audit FKs deliberately restrict account/profile deletion once a
-- verification exists; trusted retention handling must precede account removal.

begin;
set local search_path = '';
set local standard_conforming_strings = on;

create schema if not exists salahly_private authorization postgres;
revoke all privileges on schema salahly_private from public, anon;
grant usage on schema salahly_private to authenticated;

create table if not exists public.provider_profiles (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  bio text not null default '',
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  updated_at timestamptz not null default pg_catalog.clock_timestamp(),
  constraint provider_profiles_bio_check check (
    bio = pg_catalog.regexp_replace(bio, '^[[:space:]]+|[[:space:]]+$', '', 'g')
    and pg_catalog.char_length(bio) <= 1000
  )
);

create table if not exists public.provider_skills (
  user_id uuid not null references public.provider_profiles (user_id) on delete cascade,
  category_id uuid not null references public.service_categories (id) on delete restrict,
  position smallint not null check (position between 1 and 20),
  primary key (user_id, category_id),
  unique (user_id, position)
);
create index if not exists provider_skills_category_id_idx
  on public.provider_skills (category_id);

create table if not exists public.provider_service_areas (
  user_id uuid not null references public.provider_profiles (user_id) on delete cascade,
  position smallint not null check (position between 1 and 10),
  label text not null,
  primary key (user_id, position),
  constraint provider_service_areas_label_check check (
    label = pg_catalog.regexp_replace(label, '^[[:space:]]+|[[:space:]]+$', '', 'g')
    and pg_catalog.char_length(label) between 2 and 100
  )
);
create unique index if not exists provider_service_areas_label_idx
  on public.provider_service_areas (user_id, pg_catalog.lower(label));

create table if not exists public.provider_availability (
  user_id uuid not null references public.provider_profiles (user_id) on delete cascade,
  weekday smallint not null check (weekday between 1 and 7),
  start_minute smallint not null check (start_minute between 0 and 1439),
  end_minute smallint not null check (end_minute between 1 and 1440),
  primary key (user_id, weekday),
  constraint provider_availability_interval_check check (start_minute < end_minute)
);

create table if not exists public.provider_verifications (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  user_id uuid not null references public.provider_profiles (user_id) on delete restrict,
  document_object_id uuid not null unique references storage.objects (id) on delete restrict,
  document_path text not null unique,
  mime_type text not null,
  size_bytes bigint not null check (size_bytes between 1 and 5242880),
  status text not null default 'pending' check (status in ('pending', 'verified', 'rejected')),
  submitted_profile jsonb not null check (pg_catalog.jsonb_typeof(submitted_profile) = 'object'),
  consented_at timestamptz not null,
  submitted_at timestamptz not null default pg_catalog.clock_timestamp(),
  reviewed_at timestamptz,
  review_note text,
  reviewer text,
  constraint provider_verifications_document_check check (
    document_path ~ ('^' || user_id::text || '/[0-9a-f]{32}\.(jpg|png)$')
    and ((mime_type = 'image/jpeg' and pg_catalog.right(document_path, 4) = '.jpg')
      or (mime_type = 'image/png' and pg_catalog.right(document_path, 4) = '.png'))
  ),
  constraint provider_verifications_review_note_check check (
    review_note is null or (
      review_note = pg_catalog.regexp_replace(review_note, '^[[:space:]]+|[[:space:]]+$', '', 'g')
      and pg_catalog.char_length(review_note) between 1 and 500
    )
  ),
  constraint provider_verifications_review_check check (
    (status = 'pending' and reviewed_at is null and reviewer is null and review_note is null)
    or (status in ('verified', 'rejected') and reviewed_at is not null
      and reviewed_at >= submitted_at and reviewer is not null
      and reviewer = pg_catalog.regexp_replace(reviewer, '^[[:space:]]+|[[:space:]]+$', '', 'g')
      and pg_catalog.char_length(reviewer) > 0
      and (status <> 'rejected' or review_note is not null))
  ),
  constraint provider_verifications_consent_check check (consented_at = submitted_at)
);
create index if not exists provider_verifications_latest_idx
  on public.provider_verifications (user_id, submitted_at desc, id desc);
create unique index if not exists provider_verifications_open_idx
  on public.provider_verifications (user_id) where status in ('pending', 'verified');

do $policy_guard$
begin
  if exists (
    select 1 from pg_catalog.pg_policies
    where schemaname = 'public'
      and tablename in (
        'provider_profiles', 'provider_skills', 'provider_service_areas',
        'provider_availability', 'provider_verifications'
      )
      and policyname <> 'salahly_' || tablename || '_select_own'
  ) then
    raise exception 'Unexpected RLS policies on provider onboarding tables. No changes have been committed.';
  end if;
end;
$policy_guard$;

alter table public.provider_profiles enable row level security;
alter table public.provider_skills enable row level security;
alter table public.provider_service_areas enable row level security;
alter table public.provider_availability enable row level security;
alter table public.provider_verifications enable row level security;

-- Remove column ACLs too: a table-level REVOKE does not revoke UPDATE(column).
revoke all privileges on table public.provider_profiles, public.provider_skills,
  public.provider_service_areas, public.provider_availability, public.provider_verifications
  from public, anon, authenticated, service_role;
revoke all privileges (user_id, bio, created_at, updated_at) on public.provider_profiles
  from public, anon, authenticated, service_role;
revoke all privileges (user_id, category_id, position) on public.provider_skills
  from public, anon, authenticated, service_role;
revoke all privileges (user_id, position, label) on public.provider_service_areas
  from public, anon, authenticated, service_role;
revoke all privileges (user_id, weekday, start_minute, end_minute) on public.provider_availability
  from public, anon, authenticated, service_role;
revoke all privileges (
  id, user_id, document_object_id, document_path, mime_type, size_bytes, status,
  submitted_profile, consented_at, submitted_at, reviewed_at, review_note, reviewer
) on public.provider_verifications from public, anon, authenticated, service_role;
grant select on table public.provider_profiles, public.provider_skills,
  public.provider_service_areas, public.provider_availability, public.provider_verifications
  to authenticated, service_role;

-- Helpers live outside the exposed public API schema. Only policy helpers are
-- executable by authenticated; none accept a role/admin claim from the caller.
create or replace function salahly_private.provider_is_self(p_provider_id uuid)
returns boolean language sql stable security definer set search_path = ''
as $function$
  select auth.uid() is not null and auth.uid() = p_provider_id and exists (
    select 1 from public.profiles where id = p_provider_id and role = 'provider'
  );
$function$;

create or replace function salahly_private.lock_provider(p_provider_id uuid)
returns void language plpgsql security definer set search_path = ''
as $function$
begin
  -- The foundation row exists before the first draft, so even initial saves
  -- serialize. Storage row triggers use this same lock, including server writes.
  perform 1 from public.profiles where id = p_provider_id and role = 'provider' for update;
  if not found then
    raise exception using errcode = '42501', message = 'provider.errors.access';
  end if;
end;
$function$;

create or replace function salahly_private.provider_snapshot(p_provider_id uuid)
returns jsonb language sql stable security definer set search_path = ''
as $function$
  select pg_catalog.jsonb_build_object(
    'user_id', p_provider_id,
    'bio', coalesce((select bio from public.provider_profiles where user_id = p_provider_id), ''),
    'skill_ids', coalesce((
      select pg_catalog.jsonb_agg(category_id order by position)
      from public.provider_skills where user_id = p_provider_id
    ), '[]'::jsonb),
    'service_areas', coalesce((
      select pg_catalog.jsonb_agg(label order by position)
      from public.provider_service_areas where user_id = p_provider_id
    ), '[]'::jsonb),
    'availability', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'weekday', weekday, 'start_minute', start_minute, 'end_minute', end_minute
      ) order by weekday)
      from public.provider_availability where user_id = p_provider_id
    ), '[]'::jsonb),
    'verification', (
      select pg_catalog.jsonb_build_object(
        'id', id, 'document_path', document_path, 'mime_type', mime_type,
        'size_bytes', size_bytes, 'status', status, 'submitted_at', submitted_at,
        'reviewed_at', reviewed_at, 'review_note', review_note
      ) from public.provider_verifications where user_id = p_provider_id
      order by submitted_at desc, id desc limit 1
    )
  );
$function$;

create or replace function public.get_provider_onboarding(p_provider_id uuid)
returns jsonb language plpgsql stable security definer set search_path = ''
as $function$
begin
  if not salahly_private.provider_is_self(p_provider_id) then
    raise exception using errcode = '42501', message = 'provider.errors.access';
  end if;
  -- Reading an empty draft is deliberately side-effect free.
  return salahly_private.provider_snapshot(p_provider_id);
end;
$function$;

create or replace function public.save_provider_onboarding(
  p_provider_id uuid, p_bio text, p_skill_ids uuid[], p_service_areas text[], p_availability jsonb
)
returns jsonb language plpgsql security definer set search_path = ''
as $function$
declare
  normalized_bio text;
  normalized_areas text[];
  item jsonb;
  days integer[] := '{}'::integer[];
  day_number integer;
  starts integer;
  ends integer;
  matched integer;
begin
  if not salahly_private.provider_is_self(p_provider_id) then
    raise exception using errcode = '42501', message = 'provider.errors.access';
  end if;
  perform salahly_private.lock_provider(p_provider_id);
  if exists (select 1 from public.provider_verifications where user_id = p_provider_id and status = 'pending') then
    raise exception using message = 'provider.errors.locked';
  end if;

  if p_bio is null or p_skill_ids is null or p_service_areas is null or p_availability is null then
    raise exception using message = 'provider.errors.invalid_profile';
  end if;
  normalized_bio := pg_catalog.regexp_replace(p_bio, '^[[:space:]]+|[[:space:]]+$', '', 'g');
  if pg_catalog.char_length(normalized_bio) > 1000 then
    raise exception using message = 'provider.errors.bio';
  end if;

  if pg_catalog.cardinality(p_skill_ids) > 20 or coalesce(pg_catalog.array_ndims(p_skill_ids), 1) <> 1 then
    raise exception using message = 'provider.errors.skills';
  end if;
  if exists (select 1 from pg_catalog.unnest(p_skill_ids) as skill(id) where id is null)
    or (select pg_catalog.count(distinct id) from pg_catalog.unnest(p_skill_ids) as skill(id))
      <> pg_catalog.cardinality(p_skill_ids) then
    raise exception using message = 'provider.errors.skills';
  end if;
  -- Keep categories active through this atomic save, not merely at validation.
  perform id from public.service_categories where id = any(p_skill_ids) and is_active order by id for share;
  get diagnostics matched = row_count;
  if matched <> pg_catalog.cardinality(p_skill_ids) then
    raise exception using message = 'provider.errors.skills';
  end if;

  if pg_catalog.cardinality(p_service_areas) > 10 or coalesce(pg_catalog.array_ndims(p_service_areas), 1) <> 1 then
    raise exception using message = 'provider.errors.areas';
  end if;
  select coalesce(pg_catalog.array_agg(
    pg_catalog.regexp_replace(label, '^[[:space:]]+|[[:space:]]+$', '', 'g') order by position
  ), '{}'::text[]) into normalized_areas
  from pg_catalog.unnest(p_service_areas) with ordinality as area(label, position);
  if exists (select 1 from pg_catalog.unnest(normalized_areas) as area(label)
      where label is null or pg_catalog.char_length(label) not between 2 and 100)
    or (select pg_catalog.count(distinct pg_catalog.lower(label))
      from pg_catalog.unnest(normalized_areas) as area(label)) <> pg_catalog.cardinality(normalized_areas) then
    raise exception using message = 'provider.errors.areas';
  end if;

  if pg_catalog.jsonb_typeof(p_availability) <> 'array' then
    raise exception using message = 'provider.errors.availability';
  end if;
  if pg_catalog.jsonb_array_length(p_availability) > 7 then
    raise exception using message = 'provider.errors.availability';
  end if;
  for item in select value from pg_catalog.jsonb_array_elements(p_availability) loop
    if pg_catalog.jsonb_typeof(item) <> 'object' then
      raise exception using message = 'provider.errors.availability';
    end if;
    if not (item ?& array['weekday', 'start_minute', 'end_minute'])
      or (item - 'weekday' - 'start_minute' - 'end_minute') <> '{}'::jsonb
      or pg_catalog.jsonb_typeof(item -> 'weekday') is distinct from 'number'
      or pg_catalog.jsonb_typeof(item -> 'start_minute') is distinct from 'number'
      or pg_catalog.jsonb_typeof(item -> 'end_minute') is distinct from 'number'
      or (item ->> 'weekday') !~ '^[0-9]$'
      or (item ->> 'start_minute') !~ '^[0-9]{1,4}$'
      or (item ->> 'end_minute') !~ '^[0-9]{1,4}$' then
      raise exception using message = 'provider.errors.availability';
    end if;
    day_number := (item ->> 'weekday')::integer;
    starts := (item ->> 'start_minute')::integer;
    ends := (item ->> 'end_minute')::integer;
    if day_number not between 1 and 7 or starts not between 0 and 1439
      or ends not between 1 and 1440 or starts >= ends or day_number = any(days) then
      raise exception using message = 'provider.errors.availability';
    end if;
    days := pg_catalog.array_append(days, day_number);
  end loop;

  insert into public.provider_profiles (user_id, bio) values (p_provider_id, normalized_bio)
  on conflict (user_id) do update set bio = excluded.bio, updated_at = pg_catalog.clock_timestamp();
  delete from public.provider_skills where user_id = p_provider_id;
  insert into public.provider_skills (user_id, category_id, position)
    select p_provider_id, id, position from pg_catalog.unnest(p_skill_ids) with ordinality as skill(id, position);
  delete from public.provider_service_areas where user_id = p_provider_id;
  insert into public.provider_service_areas (user_id, label, position)
    select p_provider_id, label, position from pg_catalog.unnest(normalized_areas) with ordinality as area(label, position);
  delete from public.provider_availability where user_id = p_provider_id;
  insert into public.provider_availability (user_id, weekday, start_minute, end_minute)
    select p_provider_id, (value ->> 'weekday')::smallint,
      (value ->> 'start_minute')::smallint, (value ->> 'end_minute')::smallint
    from pg_catalog.jsonb_array_elements(p_availability);
  return salahly_private.provider_snapshot(p_provider_id);
end;
$function$;

create or replace function public.submit_provider_verification(
  p_provider_id uuid, p_document_path text, p_consent boolean
)
returns jsonb language plpgsql security definer set search_path = ''
as $function$
declare
  document storage.objects%rowtype;
  snapshot jsonb;
  document_mime text;
  document_size bigint;
  submitted timestamptz;
  matched integer;
begin
  if not salahly_private.provider_is_self(p_provider_id) then
    raise exception using errcode = '42501', message = 'provider.errors.access';
  end if;
  if p_consent is distinct from true then
    raise exception using message = 'provider.errors.consent';
  end if;
  if p_document_path is null or p_document_path !~ ('^' || p_provider_id::text || '/[0-9a-f]{32}\.(jpg|png)$') then
    raise exception using message = 'provider.errors.document_unavailable';
  end if;
  if not exists (select 1 from public.provider_profiles where user_id = p_provider_id) then
    raise exception using message = 'provider.errors.incomplete';
  end if;

  -- Object before provider is the same lock order as a Storage DELETE and its
  -- row trigger. The FK additionally protects repeatable-read/stale snapshots.
  select * into document from storage.objects where bucket_id = 'provider-verification'
    and name = p_document_path and owner_id = p_provider_id::text
    and (owner is null or owner = p_provider_id) for update;
  if not found then
    raise exception using message = 'provider.errors.document_unavailable';
  end if;
  perform salahly_private.lock_provider(p_provider_id);

  -- Every used path is a permanent idempotency key, including rejected paths.
  -- A late retry returns the CURRENT latest snapshot; it never resubmits an old
  -- rejection, creates a second row, or demands the now-edited profile be complete.
  if exists (select 1 from public.provider_verifications
    where user_id = p_provider_id and document_path = p_document_path) then
    return salahly_private.provider_snapshot(p_provider_id);
  end if;
  if exists (select 1 from public.provider_verifications
    where user_id = p_provider_id and status in ('pending', 'verified')) then
    raise exception using message = 'provider.errors.locked';
  end if;

  snapshot := salahly_private.provider_snapshot(p_provider_id);
  if pg_catalog.char_length(snapshot ->> 'bio') < 20
    or pg_catalog.jsonb_array_length(snapshot -> 'skill_ids') = 0
    or pg_catalog.jsonb_array_length(snapshot -> 'service_areas') = 0
    or pg_catalog.jsonb_array_length(snapshot -> 'availability') = 0 then
    raise exception using message = 'provider.errors.incomplete';
  end if;
  perform category.id from public.service_categories as category
    join public.provider_skills as skill on skill.category_id = category.id
    where skill.user_id = p_provider_id and category.is_active order by category.id for share of category;
  get diagnostics matched = row_count;
  if matched <> pg_catalog.jsonb_array_length(snapshot -> 'skill_ids') then
    raise exception using message = 'provider.errors.skills';
  end if;

  -- metadata is Storage's finalized object metadata, NOT caller user_metadata.
  -- Initial upload permission probes may have no metadata; they cannot submit.
  document_mime := document.metadata ->> 'mimetype';
  if pg_catalog.jsonb_typeof(document.metadata -> 'mimetype') is distinct from 'string'
    or not ((document_mime = 'image/jpeg' and pg_catalog.right(p_document_path, 4) = '.jpg')
      or (document_mime = 'image/png' and pg_catalog.right(p_document_path, 4) = '.png')) then
    raise exception using message = 'provider.errors.document_type';
  end if;
  if pg_catalog.jsonb_typeof(document.metadata -> 'size') is distinct from 'number'
    or (document.metadata ->> 'size') !~ '^[0-9]{1,7}$' then
    raise exception using message = 'provider.errors.document_size';
  end if;
  document_size := (document.metadata ->> 'size')::bigint;
  if document_size not between 1 and 5242880 then
    raise exception using message = 'provider.errors.document_size';
  end if;

  -- clock_timestamp avoids transaction-wide ties; monotonic per-provider time
  -- also makes the latest record unambiguous if the host clock moves backwards.
  select greatest(pg_catalog.clock_timestamp(), max(submitted_at) + interval '1 microsecond')
    into submitted from public.provider_verifications where user_id = p_provider_id;
  insert into public.provider_verifications (
    user_id, document_object_id, document_path, mime_type, size_bytes,
    submitted_profile, consented_at, submitted_at
  ) values (
    p_provider_id, document.id, p_document_path, document_mime, document_size,
    snapshot - 'verification', submitted, submitted
  );
  return salahly_private.provider_snapshot(p_provider_id);
end;
$function$;

create or replace function public.review_provider_verification(
  p_verification_id uuid, p_decision text, p_review_note text, p_reviewer text
)
returns jsonb language plpgsql security definer set search_path = ''
as $function$
declare
  provider_id uuid;
  normalized_note text := nullif(pg_catalog.regexp_replace(p_review_note, '^[[:space:]]+|[[:space:]]+$', '', 'g'), '');
  normalized_reviewer text := pg_catalog.regexp_replace(p_reviewer, '^[[:space:]]+|[[:space:]]+$', '', 'g');
begin
  if p_decision is null or p_decision not in ('verified', 'rejected')
    or normalized_reviewer is null or normalized_reviewer = ''
    or pg_catalog.char_length(normalized_note) > 500
    or (p_decision = 'rejected' and normalized_note is null) then
    raise exception using message = 'provider.errors.invalid_profile';
  end if;
  select user_id into provider_id from public.provider_verifications where id = p_verification_id;
  if not found then
    raise exception using message = 'provider.errors.document_unavailable';
  end if;
  perform salahly_private.lock_provider(provider_id);
  update public.provider_verifications set status = p_decision,
    review_note = normalized_note, reviewer = normalized_reviewer,
    reviewed_at = greatest(pg_catalog.clock_timestamp(), submitted_at)
    where id = p_verification_id and status = 'pending';
  if not found then
    raise exception using message = 'provider.errors.locked';
  end if;
  return salahly_private.provider_snapshot(provider_id);
end;
$function$;

create or replace function salahly_private.provider_document_owned(
  p_name text, p_owner_id text, p_owner uuid
)
returns boolean language sql stable security definer set search_path = ''
as $function$
  select coalesce(salahly_private.provider_is_self(auth.uid())
    and p_owner_id = auth.uid()::text and (p_owner is null or p_owner = auth.uid())
    and p_name ~ ('^' || auth.uid()::text || '/[0-9a-f]{32}\.(jpg|png)$'), false);
$function$;

create or replace function salahly_private.provider_document_unreferenced(
  p_name text, p_owner_id text, p_owner uuid
)
returns boolean language sql stable security definer set search_path = ''
as $function$
  select salahly_private.provider_document_owned(p_name, p_owner_id, p_owner)
    and exists (select 1 from public.provider_profiles where user_id = auth.uid())
    and not exists (select 1 from public.provider_verifications where document_path = p_name);
$function$;

create or replace function salahly_private.guard_provider_document()
returns trigger language plpgsql security definer set search_path = ''
as $function$
declare
  document storage.objects%rowtype;
  provider_id uuid;
begin
  if tg_op = 'UPDATE' then
    if old.bucket_id is distinct from 'provider-verification'
      and new.bucket_id is distinct from 'provider-verification' then
      return new;
    end if;
    -- No content, name, ownership, version, or user-metadata replacement, even
    -- through Storage's trusted internal writes. Its access timestamps may move.
    -- path_tokens is generated from name AFTER BEFORE triggers; compare name,
    -- not the as-yet-uncomputed generated value on NEW.
    if (pg_catalog.to_jsonb(new) - array['updated_at', 'last_accessed_at', 'path_tokens'])
      is distinct from (pg_catalog.to_jsonb(old) - array['updated_at', 'last_accessed_at', 'path_tokens']) then
      raise exception using message = 'provider.errors.locked';
    end if;
    document := old;
  elsif tg_op = 'DELETE' then
    document := old;
  else
    document := new;
  end if;
  if document.bucket_id is distinct from 'provider-verification' then
    if tg_op = 'DELETE' then return old; else return new; end if;
  end if;
  if document.name is null or document.name !~
    '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{32}\.(jpg|png)$' then
    raise exception using message = 'provider.errors.document_unavailable';
  end if;
  provider_id := pg_catalog.split_part(document.name, '/', 1)::uuid;
  if document.owner_id is distinct from provider_id::text
    or (document.owner is not null and document.owner <> provider_id) then
    raise exception using message = 'provider.errors.document_unavailable';
  end if;
  perform salahly_private.lock_provider(provider_id);
  if tg_op = 'INSERT' then
    if not exists (select 1 from public.provider_profiles where user_id = provider_id)
      or exists (select 1 from storage.objects
        where bucket_id = 'provider-verification' and name = document.name)
      or exists (select 1 from public.provider_verifications where document_path = document.name) then
      raise exception using message = 'provider.errors.document_unavailable';
    end if;
  elsif tg_op = 'DELETE' then
    -- Recheck AFTER the shared provider lock, not just in a preflight policy.
    -- This also covers Storage internals that perform writes as a trusted role.
    if exists (select 1 from public.provider_verifications
      where document_object_id = document.id or document_path = document.name) then
      raise exception using message = 'provider.errors.locked';
    end if;
    return old;
  end if;
  return new;
end;
$function$;

alter function salahly_private.provider_is_self(uuid) owner to postgres;
alter function salahly_private.lock_provider(uuid) owner to postgres;
alter function salahly_private.provider_snapshot(uuid) owner to postgres;
alter function salahly_private.provider_document_owned(text, text, uuid) owner to postgres;
alter function salahly_private.provider_document_unreferenced(text, text, uuid) owner to postgres;
alter function salahly_private.guard_provider_document() owner to postgres;
alter function public.get_provider_onboarding(uuid) owner to postgres;
alter function public.save_provider_onboarding(uuid, text, uuid[], text[], jsonb) owner to postgres;
alter function public.submit_provider_verification(uuid, text, boolean) owner to postgres;
alter function public.review_provider_verification(uuid, text, text, text) owner to postgres;
revoke all privileges on function
  salahly_private.provider_is_self(uuid), salahly_private.lock_provider(uuid),
  salahly_private.provider_snapshot(uuid), salahly_private.provider_document_owned(text, text, uuid),
  salahly_private.provider_document_unreferenced(text, text, uuid), salahly_private.guard_provider_document(),
  public.get_provider_onboarding(uuid), public.save_provider_onboarding(uuid, text, uuid[], text[], jsonb),
  public.submit_provider_verification(uuid, text, boolean), public.review_provider_verification(uuid, text, text, text)
  from public, anon, authenticated, service_role;
grant execute on function salahly_private.provider_is_self(uuid),
  salahly_private.provider_document_owned(text, text, uuid),
  salahly_private.provider_document_unreferenced(text, text, uuid),
  public.get_provider_onboarding(uuid), public.save_provider_onboarding(uuid, text, uuid[], text[], jsonb),
  public.submit_provider_verification(uuid, text, boolean) to authenticated;
grant execute on function public.review_provider_verification(uuid, text, text, text) to service_role;

drop policy if exists salahly_provider_profiles_select_own on public.provider_profiles;
create policy salahly_provider_profiles_select_own on public.provider_profiles
  for select to authenticated using (salahly_private.provider_is_self(user_id));
drop policy if exists salahly_provider_skills_select_own on public.provider_skills;
create policy salahly_provider_skills_select_own on public.provider_skills
  for select to authenticated using (salahly_private.provider_is_self(user_id));
drop policy if exists salahly_provider_service_areas_select_own on public.provider_service_areas;
create policy salahly_provider_service_areas_select_own on public.provider_service_areas
  for select to authenticated using (salahly_private.provider_is_self(user_id));
drop policy if exists salahly_provider_availability_select_own on public.provider_availability;
create policy salahly_provider_availability_select_own on public.provider_availability
  for select to authenticated using (salahly_private.provider_is_self(user_id));
drop policy if exists salahly_provider_verifications_select_own on public.provider_verifications;
create policy salahly_provider_verifications_select_own on public.provider_verifications
  for select to authenticated using (salahly_private.provider_is_self(user_id));

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('provider-verification', 'provider-verification', false, 5242880, array['image/jpeg', 'image/png'])
on conflict (id) do update set name = excluded.name, public = false,
  file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

alter table storage.objects enable row level security;
alter table storage.buckets enable row level security;

-- Other buckets' policies/ACLs are left alone. RESTRICTIVE guards are ANDed
-- with ALL permissive policies, including pre-existing broad/public policies.
-- Separate anonymous/client gates avoid invoking restricted helper functions
-- for anon, so unrelated anonymous buckets continue to work unchanged.
drop policy if exists salahly_provider_objects_client_gate on storage.objects;
create policy salahly_provider_objects_client_gate on storage.objects as restrictive
  for all to public
  using (bucket_id is distinct from 'provider-verification' or current_user = 'authenticated')
  with check (bucket_id is distinct from 'provider-verification' or current_user = 'authenticated');
drop policy if exists salahly_provider_objects_select_guard on storage.objects;
create policy salahly_provider_objects_select_guard on storage.objects as restrictive
  for select to authenticated using (bucket_id is distinct from 'provider-verification'
    or salahly_private.provider_document_owned(name, owner_id, owner));
drop policy if exists salahly_provider_objects_insert_guard on storage.objects;
create policy salahly_provider_objects_insert_guard on storage.objects as restrictive
  for insert to authenticated with check (bucket_id is distinct from 'provider-verification'
    or salahly_private.provider_document_unreferenced(name, owner_id, owner));
drop policy if exists salahly_provider_objects_update_guard on storage.objects;
create policy salahly_provider_objects_update_guard on storage.objects as restrictive
  for update to public using (bucket_id is distinct from 'provider-verification')
  with check (bucket_id is distinct from 'provider-verification');
drop policy if exists salahly_provider_objects_delete_guard on storage.objects;
create policy salahly_provider_objects_delete_guard on storage.objects as restrictive
  for delete to authenticated using (bucket_id is distinct from 'provider-verification'
    or salahly_private.provider_document_unreferenced(name, owner_id, owner));
drop policy if exists salahly_provider_objects_select_own on storage.objects;
create policy salahly_provider_objects_select_own on storage.objects
  for select to authenticated using (bucket_id = 'provider-verification');
drop policy if exists salahly_provider_objects_insert_own on storage.objects;
create policy salahly_provider_objects_insert_own on storage.objects
  for insert to authenticated with check (bucket_id = 'provider-verification');
drop policy if exists salahly_provider_objects_delete_own on storage.objects;
create policy salahly_provider_objects_delete_own on storage.objects
  for delete to authenticated using (bucket_id = 'provider-verification');

-- A broad bucket policy must not let clients make the private bucket public,
-- raise upload limits, replace it, or remove it. No unrelated bucket is gated.
drop policy if exists salahly_provider_bucket_insert_guard on storage.buckets;
create policy salahly_provider_bucket_insert_guard on storage.buckets as restrictive
  for insert to public with check (id is distinct from 'provider-verification');
drop policy if exists salahly_provider_bucket_update_guard on storage.buckets;
create policy salahly_provider_bucket_update_guard on storage.buckets as restrictive
  for update to public using (id is distinct from 'provider-verification')
  with check (id is distinct from 'provider-verification');
drop policy if exists salahly_provider_bucket_delete_guard on storage.buckets;
create policy salahly_provider_bucket_delete_guard on storage.buckets as restrictive
  for delete to public using (id is distinct from 'provider-verification');

drop trigger if exists salahly_provider_document_guard on storage.objects;
create trigger salahly_provider_document_guard before insert or update or delete on storage.objects
  for each row execute function salahly_private.guard_provider_document();

commit;

-- Run supabase/tests/provider_onboarding_rls.sql next, as postgres. SQL checks
-- simulate JWT roles and Storage metadata only, not HTTP, real uploaded bytes,
-- signed URLs, or hosted Storage behavior. Never clean up a possibly submitted
-- document after an ambiguous client response; reconcile the saved snapshot.
