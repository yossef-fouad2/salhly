-- Salahly M6 manual customer requests. Run this WHOLE file as postgres after
-- the foundation and provider-onboarding migrations. No provider feed, quotes,
-- jobs, notifications, geolocation, or AI is added. All location is user-entered.
--
-- Rerunnable: preserves requests, snapshots, consent, and Storage evidence;
-- repairs this feature's ACLs/bucket settings and refuses unexpected policies
-- on its public tables. This is not a destructive legacy-schema repair script.
-- Evidence/history deliberately restrict account/category deletion. A future
-- trusted retention procedure is required before removing submitted records.

begin;
set local search_path = '';
set local standard_conforming_strings = on;

create schema if not exists salahly_private authorization postgres;
revoke all privileges on schema salahly_private from public, anon;
grant usage on schema salahly_private to authenticated;

create table if not exists public.service_requests (
  id uuid primary key,
  customer_id uuid not null references public.profiles (id) on delete restrict,
  category_id uuid not null references public.service_categories (id) on delete restrict,
  category_name_en text not null,
  category_name_ar text not null,
  category_icon_key text not null,
  title text not null,
  description text not null,
  city text not null,
  address text not null,
  preferred_at timestamptz,
  status text not null default 'open',
  consented_at timestamptz not null,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  cancelled_at timestamptz,
  constraint service_requests_id_check check (
    id::text ~ '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
  ),
  constraint service_requests_title_check check (
    title = pg_catalog.regexp_replace(title, '^[[:space:]]+|[[:space:]]+$', '', 'g')
    and pg_catalog.char_length(title) between 5 and 120
  ),
  constraint service_requests_description_check check (
    description = pg_catalog.regexp_replace(description, '^[[:space:]]+|[[:space:]]+$', '', 'g')
    and pg_catalog.char_length(description) between 10 and 2000
  ),
  constraint service_requests_city_check check (
    city = pg_catalog.regexp_replace(city, '^[[:space:]]+|[[:space:]]+$', '', 'g')
    and pg_catalog.char_length(city) between 2 and 100
  ),
  constraint service_requests_address_check check (
    address = pg_catalog.regexp_replace(address, '^[[:space:]]+|[[:space:]]+$', '', 'g')
    and pg_catalog.char_length(address) between 5 and 500
  ),
  constraint service_requests_consent_check check (
    pg_catalog.isfinite(created_at) and consented_at = created_at
  ),
  -- An instant has an absolute 180 * 24 hour bound, independent of session DST.
  -- Comparing with creation time keeps this constraint valid as history ages.
  constraint service_requests_preferred_check check (
    preferred_at is null or (pg_catalog.isfinite(preferred_at)
      and preferred_at > created_at and preferred_at <= created_at + interval '4320 hours')
  ),
  constraint service_requests_status_check check (
    (status = 'open' and cancelled_at is null)
    or (status = 'cancelled' and cancelled_at is not null
      and pg_catalog.isfinite(cancelled_at) and cancelled_at >= created_at)
  )
);
create index if not exists service_requests_customer_history_idx
  on public.service_requests (customer_id, created_at desc, id desc);
create index if not exists service_requests_category_id_idx
  on public.service_requests (category_id);

create table if not exists public.service_request_photos (
  id uuid primary key,
  request_id uuid not null references public.service_requests (id) on delete restrict,
  object_id uuid not null unique references storage.objects (id) on delete restrict,
  storage_path text not null unique,
  mime_type text not null,
  size_bytes bigint not null check (size_bytes between 1 and 5242880),
  position smallint not null check (position between 1 and 3),
  unique (request_id, position),
  constraint service_request_photos_id_check check (
    id::text ~ '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
  ),
  constraint service_request_photos_path_check check (
    storage_path ~ ('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/'
      || request_id::text || '/' || id::text || '\.(jpg|png)$')
    and ((mime_type = 'image/jpeg' and pg_catalog.right(storage_path, 4) = '.jpg')
      or (mime_type = 'image/png' and pg_catalog.right(storage_path, 4) = '.png'))
  )
);

do $policy_guard$
begin
  if exists (
    select 1 from pg_catalog.pg_policies
    where schemaname = 'public'
      and tablename in ('service_requests', 'service_request_photos')
      and policyname <> 'salahly_' || tablename || '_select_own'
  ) then
    raise exception 'Unexpected RLS policies on service request tables. No changes have been committed.';
  end if;
end;
$policy_guard$;

alter table public.service_requests enable row level security;
alter table public.service_request_photos enable row level security;

-- Revoke column privileges as well as table privileges on every rerun.
revoke all privileges on table public.service_requests, public.service_request_photos
  from public, anon, authenticated, service_role;
revoke all privileges (
  id, customer_id, category_id, category_name_en, category_name_ar, category_icon_key,
  title, description, city, address, preferred_at, status, consented_at, created_at, cancelled_at
) on public.service_requests from public, anon, authenticated, service_role;
revoke all privileges (id, request_id, object_id, storage_path, mime_type, size_bytes, position)
  on public.service_request_photos from public, anon, authenticated, service_role;
grant select on table public.service_requests, public.service_request_photos
  to authenticated, service_role;

create or replace function salahly_private.request_customer_is_self(p_customer_id uuid)
returns boolean language sql stable security definer set search_path = ''
as $function$
  select auth.uid() is not null and auth.uid() = p_customer_id and exists (
    select 1 from public.profiles where id = p_customer_id and role = 'customer'
  );
$function$;

create or replace function salahly_private.lock_request_customer(p_customer_id uuid)
returns void language plpgsql security definer set search_path = ''
as $function$
begin
  -- This row exists even for a customer's first, zero-photo request.
  perform 1 from public.profiles where id = p_customer_id and role = 'customer' for update;
  if not found then
    raise exception using errcode = '42501', message = 'requests.errors.access';
  end if;
end;
$function$;

create or replace function salahly_private.service_request_snapshot(p_request_id uuid)
returns jsonb language sql stable security definer set search_path = ''
as $function$
  select pg_catalog.to_jsonb(request) || pg_catalog.jsonb_build_object('photos', coalesce((
    select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'id', photo.id, 'storage_path', photo.storage_path, 'mime_type', photo.mime_type,
      'size_bytes', photo.size_bytes, 'position', photo.position
    ) order by photo.position)
    from public.service_request_photos as photo where photo.request_id = request.id
  ), '[]'::jsonb))
  from public.service_requests as request where request.id = p_request_id;
$function$;

create or replace function salahly_private.validate_request_photo_metadata(p_path text, p_metadata jsonb)
returns void language plpgsql stable security definer set search_path = ''
as $function$
begin
  -- Storage's finalized metadata is authoritative, never user_metadata.
  if pg_catalog.jsonb_typeof(p_metadata -> 'mimetype') is distinct from 'string'
    or not ((p_metadata ->> 'mimetype' = 'image/jpeg' and pg_catalog.right(p_path, 4) = '.jpg')
      or (p_metadata ->> 'mimetype' = 'image/png' and pg_catalog.right(p_path, 4) = '.png')) then
    raise exception using message = 'requests.errors.photo_type';
  end if;
  if pg_catalog.jsonb_typeof(p_metadata -> 'size') is distinct from 'number'
    or (p_metadata ->> 'size') !~ '^[0-9]{1,7}$' then
    raise exception using message = 'requests.errors.photo_size';
  end if;
  if (p_metadata ->> 'size')::bigint not between 1 and 5242880 then
    raise exception using message = 'requests.errors.photo_size';
  end if;
end;
$function$;

create or replace function public.get_service_request(p_request_id uuid)
returns jsonb language plpgsql stable security definer set search_path = ''
as $function$
begin
  if not salahly_private.request_customer_is_self(auth.uid()) then
    raise exception using errcode = '42501', message = 'requests.errors.access';
  end if;
  if not exists (select 1 from public.service_requests where id = p_request_id and customer_id = auth.uid()) then
    return null;
  end if;
  return salahly_private.service_request_snapshot(p_request_id);
end;
$function$;

create or replace function public.submit_service_request(
  p_request_id uuid, p_category_id uuid, p_title text, p_description text,
  p_city text, p_address text, p_preferred_at timestamptz, p_photos jsonb, p_consent boolean
)
returns jsonb language plpgsql security definer set search_path = ''
as $function$
declare
  customer uuid := auth.uid();
  normalized_title text := pg_catalog.regexp_replace(p_title, '^[[:space:]]+|[[:space:]]+$', '', 'g');
  normalized_description text := pg_catalog.regexp_replace(p_description, '^[[:space:]]+|[[:space:]]+$', '', 'g');
  normalized_city text := pg_catalog.regexp_replace(p_city, '^[[:space:]]+|[[:space:]]+$', '', 'g');
  normalized_address text := pg_catalog.regexp_replace(p_address, '^[[:space:]]+|[[:space:]]+$', '', 'g');
  normalized_photos jsonb := '[]'::jsonb;
  photo_ids uuid[] := '{}'::uuid[];
  photo_paths text[] := '{}'::text[];
  photo_id uuid;
  photo_size bigint;
  photos_error text;
  item jsonb;
  locked_objects integer;
  affected integer;
  existing_request public.service_requests%rowtype;
  category public.service_categories%rowtype;
  object storage.objects%rowtype;
  snapshot jsonb;
  existing_photos jsonb;
  submitted timestamptz;
begin
  if not salahly_private.request_customer_is_self(customer) then
    raise exception using errcode = '42501', message = 'requests.errors.access';
  end if;
  if p_request_id is null
    or p_request_id::text !~ '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' then
    raise exception using message = 'requests.errors.invalid_request';
  end if;
  if p_consent is distinct from true then
    raise exception using message = 'requests.errors.consent';
  end if;

  -- Normalize before taking locks. Delay malformed-photo errors until the final
  -- ID check so a changed retry consistently reports conflict, not a new form error.
  begin
    if pg_catalog.jsonb_typeof(p_photos) is distinct from 'array' then
      raise exception using message = 'requests.errors.photos';
    end if;
    if pg_catalog.jsonb_array_length(p_photos) > 3 then
      raise exception using message = 'requests.errors.photos';
    end if;
    for item in select value from pg_catalog.jsonb_array_elements(p_photos) loop
      if pg_catalog.jsonb_typeof(item) is distinct from 'object' then
        raise exception using message = 'requests.errors.photos';
      end if;
      if not (item ?& array['id', 'storage_path', 'mime_type', 'size_bytes'])
        or (item - array['id', 'storage_path', 'mime_type', 'size_bytes']) <> '{}'::jsonb
        or pg_catalog.jsonb_typeof(item -> 'id') is distinct from 'string'
        or pg_catalog.jsonb_typeof(item -> 'storage_path') is distinct from 'string'
        or (item ->> 'id') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' then
        raise exception using message = 'requests.errors.photos';
      end if;
      photo_id := (item ->> 'id')::uuid;
      if photo_id = any(photo_ids) then
        raise exception using message = 'requests.errors.photos';
      end if;
      if pg_catalog.jsonb_typeof(item -> 'mime_type') is distinct from 'string'
        or (item ->> 'mime_type') not in ('image/jpeg', 'image/png') then
        raise exception using message = 'requests.errors.photo_type';
      end if;
      if pg_catalog.jsonb_typeof(item -> 'size_bytes') is distinct from 'number'
        or (item ->> 'size_bytes') !~ '^[0-9]{1,7}$' then
        raise exception using message = 'requests.errors.photo_size';
      end if;
      photo_size := (item ->> 'size_bytes')::bigint;
      if photo_size not between 1 and 5242880 then
        raise exception using message = 'requests.errors.photo_size';
      end if;
      if (item ->> 'storage_path') is distinct from (customer::text || '/' || p_request_id::text || '/'
        || photo_id::text || case when item ->> 'mime_type' = 'image/jpeg' then '.jpg' else '.png' end) then
        raise exception using message = 'requests.errors.photos';
      end if;
      photo_ids := pg_catalog.array_append(photo_ids, photo_id);
      photo_paths := pg_catalog.array_append(photo_paths, item ->> 'storage_path');
      normalized_photos := normalized_photos || pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
        'id', photo_id, 'storage_path', item ->> 'storage_path',
        'mime_type', item ->> 'mime_type', 'size_bytes', photo_size
      ));
    end loop;
  exception when raise_exception then
    get stacked diagnostics photos_error = message_text;
    photo_paths := '{}'::text[];
  end;

  -- Match Storage's implicit object-row -> profile-row lock order, including
  -- zero-photo requests (no object locks, but ALWAYS the profile lock). Sorting
  -- makes multi-photo submissions agree on the order of their object locks.
  perform stored.id from storage.objects as stored
    where stored.bucket_id = 'request-photos' and stored.name = any(photo_paths)
      and stored.owner_id = customer::text and (stored.owner is null or stored.owner = customer)
    order by stored.id for update;
  get diagnostics locked_objects = row_count;
  perform salahly_private.lock_request_customer(customer);

  select * into existing_request from public.service_requests where id = p_request_id;
  if found then
    if existing_request.customer_id <> customer or photos_error is not null
      or existing_request.category_id is distinct from p_category_id
      or existing_request.title is distinct from normalized_title
      or existing_request.description is distinct from normalized_description
      or existing_request.city is distinct from normalized_city
      or existing_request.address is distinct from normalized_address
      or existing_request.preferred_at is distinct from p_preferred_at then
      raise exception using message = 'requests.errors.conflict';
    end if;
    snapshot := salahly_private.service_request_snapshot(p_request_id);
    select coalesce(pg_catalog.jsonb_agg(value - 'position' order by ordinal), '[]'::jsonb)
      into existing_photos from pg_catalog.jsonb_array_elements(snapshot -> 'photos') with ordinality as photo(value, ordinal);
    if existing_photos is distinct from normalized_photos then
      raise exception using message = 'requests.errors.conflict';
    end if;
    -- Includes cancelled state and ORIGINAL catalog display. Never reopen or
    -- revalidate a now-past preferred instant/inactive category on a same retry.
    return snapshot;
  end if;

  if normalized_title is null or pg_catalog.char_length(normalized_title) not between 5 and 120 then
    raise exception using message = 'requests.errors.title';
  end if;
  if normalized_description is null or pg_catalog.char_length(normalized_description) not between 10 and 2000 then
    raise exception using message = 'requests.errors.description';
  end if;
  if normalized_city is null or pg_catalog.char_length(normalized_city) not between 2 and 100 then
    raise exception using message = 'requests.errors.city';
  end if;
  if normalized_address is null or pg_catalog.char_length(normalized_address) not between 5 and 500 then
    raise exception using message = 'requests.errors.address';
  end if;
  if photos_error is not null then
    raise exception using message = photos_error;
  end if;
  if locked_objects <> pg_catalog.cardinality(photo_ids) then
    raise exception using message = 'requests.errors.photos';
  end if;
  select * into category from public.service_categories where id = p_category_id and is_active for share;
  if not found then
    raise exception using message = 'requests.errors.category';
  end if;

  for item in select value from pg_catalog.jsonb_array_elements(normalized_photos) loop
    select * into object from storage.objects where bucket_id = 'request-photos'
      and name = item ->> 'storage_path' and owner_id = customer::text
      and (owner is null or owner = customer);
    if not found then
      raise exception using message = 'requests.errors.photos';
    end if;
    perform salahly_private.validate_request_photo_metadata(object.name, object.metadata);
    if object.metadata ->> 'mimetype' is distinct from item ->> 'mime_type' then
      raise exception using message = 'requests.errors.photo_type';
    end if;
    if (object.metadata ->> 'size')::bigint <> (item ->> 'size_bytes')::bigint then
      raise exception using message = 'requests.errors.photo_size';
    end if;
  end loop;

  submitted := pg_catalog.clock_timestamp();
  if p_preferred_at is not null and (not pg_catalog.isfinite(p_preferred_at)
    or p_preferred_at <= submitted or p_preferred_at > submitted + interval '4320 hours') then
    raise exception using message = 'requests.errors.preferred_time';
  end if;
  insert into public.service_requests (
    id, customer_id, category_id, category_name_en, category_name_ar, category_icon_key,
    title, description, city, address, preferred_at, consented_at, created_at
  ) values (
    p_request_id, customer, category.id, category.name_en, category.name_ar, category.icon_key,
    normalized_title, normalized_description, normalized_city, normalized_address, p_preferred_at, submitted, submitted
  ) on conflict (id) do nothing;
  get diagnostics affected = row_count;
  -- A collision with another customer's concurrent UUID cannot share our lock.
  if affected <> 1 then
    raise exception using message = 'requests.errors.conflict';
  end if;
  begin
    insert into public.service_request_photos (id, request_id, object_id, storage_path, mime_type, size_bytes, position)
      select (photo.value ->> 'id')::uuid, p_request_id, stored.id, stored.name,
        photo.value ->> 'mime_type', (photo.value ->> 'size_bytes')::bigint, photo.ordinal
      from pg_catalog.jsonb_array_elements(normalized_photos) with ordinality as photo(value, ordinal)
      join storage.objects as stored on stored.bucket_id = 'request-photos' and stored.name = photo.value ->> 'storage_path';
  exception when unique_violation then
    raise exception using message = 'requests.errors.photos';
  end;
  return salahly_private.service_request_snapshot(p_request_id);
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
  select * into request from public.service_requests where id = p_request_id and customer_id = customer;
  if not found then
    raise exception using message = 'requests.errors.not_found';
  end if;
  if request.status = 'open' then
    update public.service_requests set status = 'cancelled',
      cancelled_at = greatest(pg_catalog.clock_timestamp(), created_at) where id = p_request_id;
  elsif request.status <> 'cancelled' then
    raise exception using message = 'requests.errors.status';
  end if;
  return salahly_private.service_request_snapshot(p_request_id);
end;
$function$;

create or replace function salahly_private.guard_service_request_record()
returns trigger language plpgsql security definer set search_path = ''
as $function$
begin
  -- Published content and photo links stay immutable, including for trusted
  -- accidental writes. Cancellation is the only supported record transition.
  if tg_op = 'DELETE' then
    raise exception using message = 'requests.errors.status';
  end if;
  if tg_table_name = 'service_request_photos' then
    if pg_catalog.to_jsonb(new) is distinct from pg_catalog.to_jsonb(old) then
      raise exception using message = 'requests.errors.conflict';
    end if;
  else
    if (pg_catalog.to_jsonb(new) - array['status', 'cancelled_at'])
      is distinct from (pg_catalog.to_jsonb(old) - array['status', 'cancelled_at']) then
      raise exception using message = 'requests.errors.conflict';
    end if;
    if (new.status, new.cancelled_at) is distinct from (old.status, old.cancelled_at)
      and not (old.status = 'open' and new.status = 'cancelled' and new.cancelled_at is not null
        and pg_catalog.isfinite(new.cancelled_at) and new.cancelled_at >= old.created_at) then
      raise exception using message = 'requests.errors.status';
    end if;
  end if;
  return new;
end;
$function$;

create or replace function salahly_private.request_photo_owned(p_name text, p_owner_id text, p_owner uuid)
returns boolean language sql stable security definer set search_path = ''
as $function$
  select coalesce(salahly_private.request_customer_is_self(auth.uid())
    and p_owner_id = auth.uid()::text and (p_owner is null or p_owner = auth.uid())
    and p_name ~ ('^' || auth.uid()::text
      || '/[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}'
      || '/[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\.(jpg|png)$'), false);
$function$;

create or replace function salahly_private.request_photo_unreferenced(p_id uuid, p_name text, p_owner_id text, p_owner uuid)
returns boolean language sql stable security definer set search_path = ''
as $function$
  select salahly_private.request_photo_owned(p_name, p_owner_id, p_owner)
    and not exists (select 1 from public.service_request_photos where object_id = p_id or storage_path = p_name);
$function$;

create or replace function salahly_private.guard_request_photo()
returns trigger language plpgsql security definer set search_path = ''
as $function$
declare
  photo storage.objects%rowtype;
  customer uuid;
begin
  if tg_op = 'UPDATE' then
    if old.bucket_id is distinct from 'request-photos' and new.bucket_id is distinct from 'request-photos' then
      return new;
    end if;
    -- Inspect OLD and NEW: no moves into/out of this bucket, overwrites, owner,
    -- content/version/user-metadata edits. BEFORE triggers cannot use generated
    -- NEW.path_tokens; immutable name already protects those derived tokens.
    if (pg_catalog.to_jsonb(new) - array['updated_at', 'last_accessed_at', 'path_tokens'])
      is distinct from (pg_catalog.to_jsonb(old) - array['updated_at', 'last_accessed_at', 'path_tokens']) then
      raise exception using message = 'requests.errors.status';
    end if;
    photo := old;
  elsif tg_op = 'DELETE' then
    photo := old;
  else
    photo := new;
  end if;
  if photo.bucket_id is distinct from 'request-photos' then
    if tg_op = 'DELETE' then return old; else return new; end if;
  end if;
  if photo.name is null or photo.name !~ (
    '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
    || '/[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}'
    || '/[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\.(jpg|png)$'
  ) then
    raise exception using message = 'requests.errors.photos';
  end if;
  customer := pg_catalog.split_part(photo.name, '/', 1)::uuid;
  if photo.owner_id is distinct from customer::text or (photo.owner is not null and photo.owner <> customer) then
    raise exception using message = 'requests.errors.photos';
  end if;
  perform salahly_private.lock_request_customer(customer);
  if tg_op = 'INSERT' then
    if exists (select 1 from storage.objects where id = photo.id
      or (bucket_id = 'request-photos' and name = photo.name))
      or exists (select 1 from public.service_request_photos where object_id = photo.id or storage_path = photo.name) then
      raise exception using message = 'requests.errors.photos';
    end if;
    -- Storage permission probes may INSERT without finalized metadata and roll
    -- back. Such rows cannot be submitted; supplied metadata must satisfy limits.
    if photo.metadata is not null and photo.metadata <> '{}'::jsonb then
      perform salahly_private.validate_request_photo_metadata(photo.name, photo.metadata);
    end if;
  elsif tg_op = 'DELETE' then
    -- Recheck AFTER the shared customer lock, including trusted Storage writes.
    -- Non-deferrable RESTRICT FKs also protect stale/repeatable-read snapshots.
    if exists (select 1 from public.service_request_photos where object_id = photo.id or storage_path = photo.name) then
      raise exception using message = 'requests.errors.status';
    end if;
    return old;
  end if;
  return new;
end;
$function$;

alter function salahly_private.request_customer_is_self(uuid) owner to postgres;
alter function salahly_private.lock_request_customer(uuid) owner to postgres;
alter function salahly_private.service_request_snapshot(uuid) owner to postgres;
alter function salahly_private.validate_request_photo_metadata(text, jsonb) owner to postgres;
alter function salahly_private.guard_service_request_record() owner to postgres;
alter function salahly_private.request_photo_owned(text, text, uuid) owner to postgres;
alter function salahly_private.request_photo_unreferenced(uuid, text, text, uuid) owner to postgres;
alter function salahly_private.guard_request_photo() owner to postgres;
alter function public.get_service_request(uuid) owner to postgres;
alter function public.submit_service_request(uuid, uuid, text, text, text, text, timestamptz, jsonb, boolean) owner to postgres;
alter function public.cancel_service_request(uuid) owner to postgres;
revoke all privileges on function
  salahly_private.request_customer_is_self(uuid), salahly_private.lock_request_customer(uuid),
  salahly_private.service_request_snapshot(uuid), salahly_private.validate_request_photo_metadata(text, jsonb),
  salahly_private.guard_service_request_record(), salahly_private.request_photo_owned(text, text, uuid),
  salahly_private.request_photo_unreferenced(uuid, text, text, uuid), salahly_private.guard_request_photo(),
  public.get_service_request(uuid), public.cancel_service_request(uuid),
  public.submit_service_request(uuid, uuid, text, text, text, text, timestamptz, jsonb, boolean)
  from public, anon, authenticated, service_role;
grant execute on function salahly_private.request_customer_is_self(uuid),
  salahly_private.request_photo_owned(text, text, uuid),
  salahly_private.request_photo_unreferenced(uuid, text, text, uuid),
  public.get_service_request(uuid), public.cancel_service_request(uuid),
  public.submit_service_request(uuid, uuid, text, text, text, text, timestamptz, jsonb, boolean)
  to authenticated;

drop policy if exists salahly_service_requests_select_own on public.service_requests;
create policy salahly_service_requests_select_own on public.service_requests
  for select to authenticated using (salahly_private.request_customer_is_self(customer_id));
drop policy if exists salahly_service_request_photos_select_own on public.service_request_photos;
create policy salahly_service_request_photos_select_own on public.service_request_photos
  for select to authenticated using (exists (
    select 1 from public.service_requests where id = request_id and customer_id = (select auth.uid())
  ));

drop trigger if exists salahly_service_request_record_guard on public.service_requests;
create trigger salahly_service_request_record_guard before update or delete on public.service_requests
  for each row execute function salahly_private.guard_service_request_record();
drop trigger if exists salahly_service_request_photo_record_guard on public.service_request_photos;
create trigger salahly_service_request_photo_record_guard before update or delete on public.service_request_photos
  for each row execute function salahly_private.guard_service_request_record();

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('request-photos', 'request-photos', false, 5242880, array['image/jpeg', 'image/png'])
on conflict (id) do update set name = excluded.name, public = false,
  file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

alter table storage.objects enable row level security;
alter table storage.buckets enable row level security;

-- Bucket-scoped permissive policies plus RESTRICTIVE gates withstand unrelated
-- broad policies. Anonymous guards never call helpers unavailable to anon.
drop policy if exists salahly_request_objects_client_gate on storage.objects;
create policy salahly_request_objects_client_gate on storage.objects as restrictive
  for all to public
  using (bucket_id is distinct from 'request-photos' or current_user = 'authenticated')
  with check (bucket_id is distinct from 'request-photos' or current_user = 'authenticated');
drop policy if exists salahly_request_objects_select_guard on storage.objects;
create policy salahly_request_objects_select_guard on storage.objects as restrictive
  for select to authenticated using (bucket_id is distinct from 'request-photos'
    or salahly_private.request_photo_owned(name, owner_id, owner));
drop policy if exists salahly_request_objects_insert_guard on storage.objects;
create policy salahly_request_objects_insert_guard on storage.objects as restrictive
  for insert to authenticated with check (bucket_id is distinct from 'request-photos'
    or salahly_private.request_photo_unreferenced(id, name, owner_id, owner));
drop policy if exists salahly_request_objects_update_guard on storage.objects;
create policy salahly_request_objects_update_guard on storage.objects as restrictive
  for update to public using (bucket_id is distinct from 'request-photos')
  with check (bucket_id is distinct from 'request-photos');
drop policy if exists salahly_request_objects_delete_guard on storage.objects;
create policy salahly_request_objects_delete_guard on storage.objects as restrictive
  for delete to authenticated using (bucket_id is distinct from 'request-photos'
    or salahly_private.request_photo_unreferenced(id, name, owner_id, owner));
drop policy if exists salahly_request_objects_select_own on storage.objects;
create policy salahly_request_objects_select_own on storage.objects
  for select to authenticated using (bucket_id = 'request-photos');
drop policy if exists salahly_request_objects_insert_own on storage.objects;
create policy salahly_request_objects_insert_own on storage.objects
  for insert to authenticated with check (bucket_id = 'request-photos');
drop policy if exists salahly_request_objects_delete_own on storage.objects;
create policy salahly_request_objects_delete_own on storage.objects
  for delete to authenticated using (bucket_id = 'request-photos');

drop policy if exists salahly_request_bucket_insert_guard on storage.buckets;
create policy salahly_request_bucket_insert_guard on storage.buckets as restrictive
  for insert to public with check (id is distinct from 'request-photos');
drop policy if exists salahly_request_bucket_update_guard on storage.buckets;
create policy salahly_request_bucket_update_guard on storage.buckets as restrictive
  for update to public using (id is distinct from 'request-photos')
  with check (id is distinct from 'request-photos');
drop policy if exists salahly_request_bucket_delete_guard on storage.buckets;
create policy salahly_request_bucket_delete_guard on storage.buckets as restrictive
  for delete to public using (id is distinct from 'request-photos');

drop trigger if exists salahly_request_photo_guard on storage.objects;
create trigger salahly_request_photo_guard before insert or update or delete on storage.objects
  for each row execute function salahly_private.guard_request_photo();

commit;

-- Run supabase/tests/service_requests_rls.sql and both earlier rollback suites.
-- SQL metadata/role simulations are not hosted Storage byte checks or concurrent
-- HTTP tests. Reconcile a stable request ID before cleanup after any ambiguous
-- submission result; a failed reconciliation is NOT confirmation of absence.
