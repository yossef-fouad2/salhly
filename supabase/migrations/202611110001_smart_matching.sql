-- Salahly M8 request-specific matching. Run the WHOLE file as postgres after M7.
-- Discovery is a separate opt-in, not an invitation, quote, or provider selection.
-- An optional two-decimal SERVICE ORIGIN is public/inferable through repeated
-- distance queries. It must not be presented as a secret or a personal address.
-- Customer query points are transient inputs: never stored or sent to providers.
-- Explicit ISO weekday/minute inputs mean SERVICE-AREA WALL TIME, not preferred_at,
-- a device time zone, appointments, route distance, or a booked-slot guarantee.
-- No reviews/ratings exist: missing evidence is neutral, never fabricated quality.
-- Reruns preserve populated preferences/rules and reject unexpected schema/policies.

begin;
set local search_path = '';
set local standard_conforming_strings = on;

create schema if not exists salahly_private authorization postgres;

create or replace function salahly_private.matching_name_valid(p_name text)
returns boolean language sql immutable security definer set search_path = ''
as $function$
  select coalesce(p_name = pg_catalog.regexp_replace(p_name, '^[[:space:]]+|[[:space:]]+$', '', 'g')
    and pg_catalog.char_length(p_name) between 2 and 80, false);
$function$;

create or replace function salahly_private.matching_location_valid(p_latitude numeric, p_longitude numeric)
returns boolean language sql immutable security definer set search_path = ''
as $function$
  -- Unconstrained numeric avoids silently rounding excessive input precision.
  -- Bounds also reject numeric NaN/+Infinity/-Infinity before any float trig.
  select (p_latitude is null and p_longitude is null) or coalesce(
    p_latitude between -90 and 90 and p_longitude between -180 and 180
    and p_latitude = pg_catalog.trunc(p_latitude, 2)
    and p_longitude = pg_catalog.trunc(p_longitude, 2), false);
$function$;

create or replace function salahly_private.normalize_matching_experience(p_experience_years jsonb)
returns jsonb language plpgsql immutable security definer set search_path = ''
as $function$
declare
  item record;
  skill_id text;
  years numeric;
  normalized jsonb := '{}'::jsonb;
begin
  if pg_catalog.jsonb_typeof(p_experience_years) is distinct from 'object' then
    raise exception using errcode = 'P0001', message = 'matching.errors.experience';
  end if;
  if (select pg_catalog.count(*) from pg_catalog.jsonb_object_keys(p_experience_years)) > 20 then
    raise exception using errcode = 'P0001', message = 'matching.errors.experience';
  end if;
  for item in select key, value from pg_catalog.jsonb_each(p_experience_years) loop
    if item.key !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      or pg_catalog.jsonb_typeof(item.value) is distinct from 'number' then
      raise exception using errcode = 'P0001', message = 'matching.errors.experience';
    end if;
    skill_id := item.key::uuid::text;
    years := item.value::text::numeric;
    if years not between 0 and 60 or years <> pg_catalog.trunc(years) or normalized ? skill_id then
      raise exception using errcode = 'P0001', message = 'matching.errors.experience';
    end if;
    normalized := normalized || pg_catalog.jsonb_build_object(skill_id, years::integer);
  end loop;
  return normalized;
end;
$function$;

create or replace function salahly_private.matching_rules_valid(
  p_revision integer, p_distance_weight integer, p_rating_weight integer,
  p_availability_weight integer, p_experience_weight integer, p_neutral_bps integer,
  p_distance_scale_km numeric, p_experience_cap_years integer
)
returns boolean language sql immutable security definer set search_path = ''
as $function$
  select coalesce(p_revision >= 1
    and p_distance_weight between 0 and 1000 and p_rating_weight between 0 and 1000
    and p_availability_weight between 0 and 1000 and p_experience_weight between 0 and 1000
    and p_distance_weight::bigint + p_rating_weight::bigint + p_availability_weight::bigint + p_experience_weight::bigint > 0
    and p_neutral_bps = 5000 and p_distance_scale_km between 1 and 500
    and p_experience_cap_years between 1 and 60, false);
$function$;

create table if not exists public.provider_matching_profiles (
  provider_id uuid primary key references public.profiles (id) on delete cascade,
  provider_name text not null,
  discoverable boolean not null default false,
  latitude numeric,
  longitude numeric,
  experience_years jsonb not null default '{}'::jsonb,
  revision integer not null default 1,
  discovery_consented_at timestamptz,
  updated_at timestamptz not null default pg_catalog.clock_timestamp(),
  constraint provider_matching_profiles_name_check check (salahly_private.matching_name_valid(provider_name)),
  constraint provider_matching_profiles_location_check check (salahly_private.matching_location_valid(latitude, longitude)),
  constraint provider_matching_profiles_experience_check check (
    experience_years::text = salahly_private.normalize_matching_experience(experience_years)::text
  ),
  constraint provider_matching_profiles_revision_check check (revision >= 1),
  constraint provider_matching_profiles_consent_check check (
    (not discoverable or discovery_consented_at is not null)
    and (discovery_consented_at is null or (pg_catalog.isfinite(discovery_consented_at) and discovery_consented_at <= updated_at))
  ),
  constraint provider_matching_profiles_time_check check (pg_catalog.isfinite(updated_at))
);
create index if not exists provider_matching_profiles_discoverable_idx
  on public.provider_matching_profiles (provider_id) where discoverable;

-- An existing empty singleton is drift, not permission to silently reseed lost
-- configured settings. The nested IF avoids planning a missing table on install.
do $existing_rules_guard$
begin
  if pg_catalog.to_regclass('public.matching_rules') is not null then
    if not exists (select 1 from public.matching_rules) then
      raise exception using errcode = 'P0001', message = 'matching.errors.invalid';
    end if;
  end if;
end;
$existing_rules_guard$;

create table if not exists public.matching_rules (
  singleton boolean primary key default true,
  revision integer not null default 1,
  distance_weight integer not null default 35,
  rating_weight integer not null default 25,
  availability_weight integer not null default 20,
  experience_weight integer not null default 20,
  neutral_bps integer not null default 5000,
  distance_scale_km numeric not null default 50,
  experience_cap_years integer not null default 10,
  constraint matching_rules_singleton_check check (singleton),
  constraint matching_rules_values_check check (salahly_private.matching_rules_valid(
    revision, distance_weight, rating_weight, availability_weight, experience_weight,
    neutral_bps, distance_scale_km, experience_cap_years
  ))
);
insert into public.matching_rules (
  singleton, revision, distance_weight, rating_weight, availability_weight, experience_weight,
  neutral_bps, distance_scale_km, experience_cap_years
) values (true, 1, 35, 25, 20, 20, 5000, 50, 10) on conflict (singleton) do nothing;

create or replace function salahly_private.matching_rules_snapshot()
returns jsonb language sql stable security definer set search_path = ''
as $function$
  select pg_catalog.jsonb_build_object(
    'revision', revision, 'distance_weight', distance_weight, 'rating_weight', rating_weight,
    'availability_weight', availability_weight, 'experience_weight', experience_weight,
    'neutral_bps', neutral_bps, 'distance_scale_km', distance_scale_km,
    'experience_cap_years', experience_cap_years
  ) from public.matching_rules where singleton;
$function$;

create or replace function salahly_private.provider_matching_profile_snapshot(p_provider_id uuid)
returns jsonb language sql stable security definer set search_path = ''
as $function$
  select pg_catalog.jsonb_build_object(
    'provider_id', profile.id,
    'provider_name', coalesce(preferences.provider_name,
      pg_catalog.regexp_replace(profile.full_name, '^[[:space:]]+|[[:space:]]+$', '', 'g')),
    'discoverable', coalesce(preferences.discoverable, false),
    'latitude', preferences.latitude, 'longitude', preferences.longitude,
    'experience_years', coalesce(preferences.experience_years, '{}'::jsonb),
    'revision', coalesce(preferences.revision, 0),
    'consented_at', preferences.discovery_consented_at, 'updated_at', preferences.updated_at
  ) from public.profiles as profile left join public.provider_matching_profiles as preferences
    on preferences.provider_id = profile.id where profile.id = p_provider_id;
$function$;

-- M7 has one authoritative current-role/verification/skill/category/area policy.
-- Add request quoteability here without changing the existing M7 RPCs or policies.
create or replace function salahly_private.provider_can_quote(p_provider_id uuid, p_request_id uuid)
returns boolean language sql stable security definer set search_path = ''
as $function$
  select exists (select 1 from public.service_requests as request
    join public.request_marketplace_listings as listing on listing.request_id = request.id
    left join public.provider_quotes as quote on quote.request_id = request.id and quote.provider_id = p_provider_id
    where request.id = p_request_id and request.status = 'open' and request.customer_id <> p_provider_id
      and (quote.id is null or quote.status in ('pending', 'withdrawn'))
      and salahly_private.marketplace_provider_eligible(p_provider_id, request.category_id, listing.city));
$function$;

create or replace function public.get_provider_matching_profile()
returns jsonb language plpgsql stable security definer set search_path = ''
as $function$
declare
  result jsonb;
begin
  if not salahly_private.provider_is_self(auth.uid()) then
    raise exception using errcode = '42501', message = 'matching.errors.access';
  end if;
  result := salahly_private.provider_matching_profile_snapshot(auth.uid());
  if not salahly_private.matching_name_valid(result ->> 'provider_name') then
    raise exception using errcode = 'P0001', message = 'matching.errors.invalid';
  end if;
  return result;
end;
$function$;

create or replace function public.save_provider_matching_profile(
  p_discoverable boolean, p_latitude numeric, p_longitude numeric, p_experience_years jsonb,
  p_expected_revision integer, p_consent boolean
)
returns jsonb language plpgsql security definer set search_path = ''
as $function$
declare
  provider uuid := auth.uid();
  provider_name text;
  provider_role text;
  preferences public.provider_matching_profiles%rowtype;
  experience jsonb;
  invalid_experience boolean := false;
  unchanged_settings boolean;
  saved timestamptz;
begin
  if not salahly_private.provider_is_self(provider) then
    raise exception using errcode = '42501', message = 'matching.errors.access';
  end if;
  if p_expected_revision is null or p_expected_revision < 0 then
    raise exception using errcode = 'P0001', message = 'matching.errors.invalid';
  end if;
  if p_discoverable and p_consent is distinct from true then
    raise exception using errcode = 'P0001', message = 'matching.errors.consent';
  end if;
  -- Same profile-before-category order as M5. Initial saves serialize too.
  select pg_catalog.regexp_replace(full_name, '^[[:space:]]+|[[:space:]]+$', '', 'g'), role
    into provider_name, provider_role from public.profiles where id = provider for update;
  if provider_role is distinct from 'provider' then
    raise exception using errcode = '42501', message = 'matching.errors.access';
  end if;
  select * into preferences from public.provider_matching_profiles where provider_id = provider for update;
  if (preferences.provider_id is null and p_expected_revision <> 0)
    or (preferences.provider_id is not null and preferences.revision <> p_expected_revision
      and preferences.revision::bigint <> p_expected_revision::bigint + 1) then
    raise exception using errcode = 'P0001', message = 'matching.errors.conflict';
  end if;
  -- Canonical payload comparison precedes mutable eligibility/skill checks.
  begin
    experience := salahly_private.normalize_matching_experience(p_experience_years);
  exception when sqlstate 'P0001' then
    invalid_experience := true;
  end;
  unchanged_settings := not invalid_experience and preferences.provider_id is not null
    and (preferences.latitude, preferences.longitude, preferences.experience_years)
      is not distinct from (p_latitude, p_longitude, experience);
  if preferences.provider_id is not null and preferences.revision::bigint = p_expected_revision::bigint + 1 then
    if unchanged_settings and preferences.discoverable is not distinct from p_discoverable then
      return salahly_private.provider_matching_profile_snapshot(provider);
    end if;
    raise exception using errcode = 'P0001', message = 'matching.errors.conflict';
  end if;
  if p_discoverable is null then raise exception using errcode = 'P0001', message = 'matching.errors.invalid'; end if;
  if not salahly_private.matching_location_valid(p_latitude, p_longitude) then
    raise exception using errcode = 'P0001', message = 'matching.errors.location';
  end if;
  if invalid_experience then raise exception using errcode = 'P0001', message = 'matching.errors.experience'; end if;
  if preferences.revision = 2147483647 then
    raise exception using errcode = 'P0001', message = 'matching.errors.conflict';
  end if;
  -- Withdrawal must not be blocked by subsequently removed skills. Only NEW
  -- experience/settings and every new publication require current validation.
  if p_discoverable or not unchanged_settings then
    perform category.id from public.service_categories as category
      join public.provider_skills as skill on skill.category_id = category.id
      where skill.user_id = provider order by category.id for share of category;
    if exists (select 1 from pg_catalog.jsonb_object_keys(experience) as entry(skill_id)
      where not exists (select 1 from public.provider_skills as skill
        join public.service_categories as category on category.id = skill.category_id
        where skill.user_id = provider and category.is_active and category.id = entry.skill_id::uuid)) then
      raise exception using errcode = 'P0001', message = 'matching.errors.experience';
    end if;
  end if;
  if p_discoverable and not salahly_private.marketplace_provider_eligible(provider) then
    raise exception using errcode = 'P0001', message = 'matching.errors.ineligible';
  end if;
  if (p_discoverable or preferences.provider_id is null) and not salahly_private.matching_name_valid(provider_name) then
    raise exception using errcode = 'P0001', message = 'matching.errors.invalid';
  end if;
  saved := greatest(pg_catalog.clock_timestamp(), preferences.updated_at + interval '1 microsecond');
  insert into public.provider_matching_profiles (
    provider_id, provider_name, discoverable, latitude, longitude, experience_years,
    revision, discovery_consented_at, updated_at
  ) values (
    provider, case when p_discoverable or preferences.provider_id is null then provider_name else preferences.provider_name end,
    p_discoverable, p_latitude, p_longitude, experience, coalesce(preferences.revision, 0) + 1,
    case when p_discoverable then saved else preferences.discovery_consented_at end, saved
  ) on conflict (provider_id) do update set
    provider_name = excluded.provider_name, discoverable = excluded.discoverable,
    latitude = excluded.latitude, longitude = excluded.longitude, experience_years = excluded.experience_years,
    revision = excluded.revision, discovery_consented_at = excluded.discovery_consented_at, updated_at = excluded.updated_at;
  return salahly_private.provider_matching_profile_snapshot(provider);
end;
$function$;

create or replace function salahly_private.configure_matching_rules(
  p_expected_revision integer, p_distance_weight integer, p_rating_weight integer,
  p_availability_weight integer, p_experience_weight integer,
  p_distance_scale_km numeric, p_experience_cap_years integer
)
returns jsonb language plpgsql security definer set search_path = ''
as $function$
declare
  rules public.matching_rules%rowtype;
begin
  if p_expected_revision is null or p_expected_revision < 1 then
    raise exception using errcode = 'P0001', message = 'matching.errors.invalid';
  end if;
  select * into rules from public.matching_rules where singleton for update;
  if not found then raise exception using errcode = 'P0001', message = 'matching.errors.invalid'; end if;
  if rules.revision::bigint = p_expected_revision::bigint + 1 and (
    rules.distance_weight, rules.rating_weight, rules.availability_weight, rules.experience_weight,
    rules.distance_scale_km, rules.experience_cap_years
  ) is not distinct from (
    p_distance_weight, p_rating_weight, p_availability_weight, p_experience_weight,
    p_distance_scale_km, p_experience_cap_years
  ) then return salahly_private.matching_rules_snapshot(); end if;
  if rules.revision <> p_expected_revision or rules.revision = 2147483647 then
    raise exception using errcode = 'P0001', message = 'matching.errors.conflict';
  end if;
  if not salahly_private.matching_rules_valid(1, p_distance_weight, p_rating_weight,
    p_availability_weight, p_experience_weight, 5000, p_distance_scale_km, p_experience_cap_years) then
    raise exception using errcode = 'P0001', message = 'matching.errors.invalid';
  end if;
  update public.matching_rules set revision = revision + 1, distance_weight = p_distance_weight,
    rating_weight = p_rating_weight, availability_weight = p_availability_weight,
    experience_weight = p_experience_weight, distance_scale_km = p_distance_scale_km,
    experience_cap_years = p_experience_cap_years where singleton;
  return salahly_private.matching_rules_snapshot();
end;
$function$;

create or replace function salahly_private.matching_distance_km(
  p_latitude numeric, p_longitude numeric, p_origin_latitude numeric, p_origin_longitude numeric
)
returns numeric language sql immutable strict security definer set search_path = ''
as $function$
  -- Trig requires float8, but ONLY bounded finite inputs enter it. Clamp the
  -- Haversine intermediate before sqrt/asin; all subsequent scoring is numeric.
  select (2 * 6371.0088 * pg_catalog.asin(pg_catalog.sqrt(greatest(0::double precision,
    least(1::double precision,
      pg_catalog.power(pg_catalog.sin(((p_origin_latitude - p_latitude)::double precision * pg_catalog.pi() / 180) / 2), 2)
      + pg_catalog.cos(p_latitude::double precision * pg_catalog.pi() / 180)
      * pg_catalog.cos(p_origin_latitude::double precision * pg_catalog.pi() / 180)
      * pg_catalog.power(pg_catalog.sin(((p_origin_longitude - p_longitude)::double precision * pg_catalog.pi() / 180) / 2), 2)
    )))))::numeric;
$function$;

create or replace function salahly_private.score_provider_match(
  p_request_id uuid, p_category_id uuid, p_profile public.provider_matching_profiles,
  p_rules public.matching_rules, p_latitude numeric, p_longitude numeric, p_weekday integer, p_minute integer
)
returns jsonb language plpgsql stable security definer set search_path = ''
as $function$
declare
  distance numeric;
  distance_score integer;
  distance_reason text;
  available boolean;
  availability_score integer;
  availability_reason text;
  experience integer := (p_profile.experience_years ->> p_category_id::text)::integer;
  experience_score integer;
  total_weight integer := p_rules.distance_weight + p_rules.rating_weight + p_rules.availability_weight + p_rules.experience_weight;
  known_weight integer := 0;
  score integer;
begin
  if p_latitude is null then distance_reason := 'no_query_location';
  elsif p_profile.latitude is null then distance_reason := 'no_provider_origin';
  else
    distance := salahly_private.matching_distance_km(p_latitude, p_longitude, p_profile.latitude, p_profile.longitude);
    distance_score := pg_catalog.round(greatest(0::numeric, least(1::numeric,
      1 - distance / p_rules.distance_scale_km)) * 10000)::integer;
    distance_reason := 'straight_line';
    known_weight := known_weight + p_rules.distance_weight;
  end if;
  if p_weekday is null then availability_reason := 'no_time_preference';
  elsif not exists (select 1 from public.provider_availability where user_id = p_profile.provider_id) then
    availability_reason := 'no_declared_hours';
  else
    available := exists (select 1 from public.provider_availability where user_id = p_profile.provider_id
      and weekday = p_weekday and p_minute >= start_minute and p_minute < end_minute);
    availability_score := case when available then 10000 else 0 end;
    availability_reason := case when available then 'within_hours' else 'outside_hours' end;
    known_weight := known_weight + p_rules.availability_weight;
  end if;
  if experience is not null then
    experience_score := pg_catalog.round(least(experience::numeric / p_rules.experience_cap_years, 1::numeric) * 10000)::integer;
    known_weight := known_weight + p_rules.experience_weight;
  end if;
  score := pg_catalog.round((coalesce(distance_score, p_rules.neutral_bps)::numeric * p_rules.distance_weight
    + p_rules.neutral_bps::numeric * p_rules.rating_weight
    + coalesce(availability_score, p_rules.neutral_bps)::numeric * p_rules.availability_weight
    + coalesce(experience_score, p_rules.neutral_bps)::numeric * p_rules.experience_weight) / total_weight)::integer;
  return pg_catalog.jsonb_build_object(
    'provider_id', p_profile.provider_id, 'provider_name', p_profile.provider_name,
    'score_bps', score, 'evidence_bps', pg_catalog.round(known_weight::numeric / total_weight * 10000)::integer,
    'tie_key', pg_catalog.md5(p_request_id::text || ':' || p_profile.provider_id::text),
    'distance_km', pg_catalog.round(distance, 1), 'available', available, 'experience_years', experience,
    'review_count', 0, 'average_rating', null,
    'factors', pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object('key', 'distance', 'score_bps', distance_score,
        'effective_bps', coalesce(distance_score, p_rules.neutral_bps), 'weight', p_rules.distance_weight, 'reason', distance_reason),
      pg_catalog.jsonb_build_object('key', 'rating', 'score_bps', null,
        'effective_bps', p_rules.neutral_bps, 'weight', p_rules.rating_weight, 'reason', 'no_reviews'),
      pg_catalog.jsonb_build_object('key', 'availability', 'score_bps', availability_score,
        'effective_bps', coalesce(availability_score, p_rules.neutral_bps), 'weight', p_rules.availability_weight, 'reason', availability_reason),
      pg_catalog.jsonb_build_object('key', 'experience', 'score_bps', experience_score,
        'effective_bps', coalesce(experience_score, p_rules.neutral_bps), 'weight', p_rules.experience_weight,
        'reason', case when experience is null then 'no_experience' else 'self_reported' end)
    )
  );
end;
$function$;

create or replace function salahly_private.matching_query_key(
  p_request_id uuid, p_mode text, p_latitude numeric, p_longitude numeric, p_weekday integer, p_minute integer
)
returns text language sql immutable security definer set search_path = ''
as $function$
  -- Literal '.' (not locale-sensitive D), two places, and normalized numeric zero.
  select pg_catalog.md5(p_request_id::text || ':' || p_mode || ':'
    || coalesce(pg_catalog.to_char(p_latitude, 'FM990.00'), '') || ':'
    || coalesce(pg_catalog.to_char(p_longitude, 'FM990.00'), '') || ':'
    || coalesce(p_weekday::text, '') || ':' || coalesce(p_minute::text, ''));
$function$;

create or replace function public.get_provider_matches(
  p_request_id uuid, p_mode text default 'recommended', p_latitude numeric default null, p_longitude numeric default null,
  p_location_consent boolean default false, p_weekday integer default null, p_minute integer default null,
  p_before_score_bps integer default null, p_before_tie_key text default null, p_before_provider_id uuid default null,
  p_rules_revision integer default null, p_before_query_key text default null, p_limit integer default 20
)
returns jsonb language plpgsql stable security definer set search_path = ''
as $function$
declare
  category uuid;
  request_status text;
  listing jsonb;
  rules public.matching_rules%rowtype;
  result jsonb;
begin
  if not salahly_private.request_customer_is_self(auth.uid()) then
    raise exception using errcode = '42501', message = 'matching.errors.access';
  end if;
  -- Authorize the requested object BEFORE joining any listing or candidate.
  select category_id, status into category, request_status from public.service_requests
    where id = p_request_id and customer_id = auth.uid();
  if not found then raise exception using errcode = 'P0001', message = 'matching.errors.not_found'; end if;
  if request_status <> 'open' then raise exception using errcode = 'P0001', message = 'matching.errors.status'; end if;
  listing := salahly_private.marketplace_listing_snapshot(p_request_id);
  if listing is null then raise exception using errcode = 'P0001', message = 'matching.errors.unpublished'; end if;
  if p_mode is null or p_mode not in ('recommended', 'all_eligible') or p_limit is null or p_limit not between 1 and 50
    or (p_weekday is null) <> (p_minute is null)
    or (p_weekday is not null and (p_weekday not between 1 and 7 or p_minute not between 0 and 1439))
    or pg_catalog.num_nonnulls(p_before_score_bps, p_before_tie_key, p_before_provider_id, p_rules_revision, p_before_query_key) not in (0, 5) then
    raise exception using errcode = 'P0001', message = 'matching.errors.invalid';
  end if;
  if not salahly_private.matching_location_valid(p_latitude, p_longitude) then
    raise exception using errcode = 'P0001', message = 'matching.errors.location';
  end if;
  if p_latitude is not null and p_location_consent is distinct from true then
    raise exception using errcode = 'P0001', message = 'matching.errors.consent';
  end if;
  if p_before_score_bps is not null and (p_before_score_bps not between 0 and 10000 or p_rules_revision < 1
    or pg_catalog.char_length(p_before_tie_key) <> 32 or p_before_tie_key !~ '^[0-9a-f]{32}$'
    or pg_catalog.char_length(p_before_query_key) <> 32 or p_before_query_key !~ '^[0-9a-f]{32}$'
    or p_before_tie_key <> pg_catalog.md5(p_request_id::text || ':' || p_before_provider_id::text)) then
    raise exception using errcode = 'P0001', message = 'matching.errors.invalid';
  end if;
  select * into rules from public.matching_rules where singleton;
  if not found or not salahly_private.matching_rules_valid(rules.revision, rules.distance_weight, rules.rating_weight,
    rules.availability_weight, rules.experience_weight, rules.neutral_bps, rules.distance_scale_km, rules.experience_cap_years) then
    raise exception using errcode = 'P0001', message = 'matching.errors.invalid';
  end if;
  if p_rules_revision is not null and p_rules_revision <> rules.revision then
    raise exception using errcode = 'P0001', message = 'matching.errors.stale';
  end if;
  if p_before_query_key is not null and p_before_query_key <> salahly_private.matching_query_key(
    p_request_id, p_mode, p_latitude, p_longitude, p_weekday, p_minute) then
    raise exception using errcode = 'P0001', message = 'matching.errors.stale';
  end if;
  -- STABLE RPC + STABLE reads/scorer share ONE calling-statement snapshot.
  -- There is no total-candidate cap or per-provider missing-factor denominator.
  with scored as materialized (
    select preferences.provider_id, salahly_private.score_provider_match(
      p_request_id, category, preferences, rules, p_latitude, p_longitude, p_weekday, p_minute
    ) as item from public.provider_matching_profiles as preferences
      where preferences.discoverable and preferences.discovery_consented_at is not null
        and salahly_private.provider_can_quote(preferences.provider_id, p_request_id)
  ), candidates as materialized (
    select provider_id, item, (item ->> 'score_bps')::integer as score_bps, item ->> 'tie_key' as tie_key from scored
  ), bounded as materialized (
    select * from candidates where p_before_score_bps is null or (
      (p_mode = 'recommended' and (score_bps < p_before_score_bps or (score_bps = p_before_score_bps
        and (tie_key collate pg_catalog."C", provider_id) > (p_before_tie_key collate pg_catalog."C", p_before_provider_id))))
      or (p_mode = 'all_eligible' and (tie_key collate pg_catalog."C", provider_id)
        > (p_before_tie_key collate pg_catalog."C", p_before_provider_id))
    ) order by case when p_mode = 'recommended' then score_bps end desc, tie_key collate pg_catalog."C", provider_id
      limit p_limit + 1
  ), page as (
    select * from bounded order by case when p_mode = 'recommended' then score_bps end desc,
      tie_key collate pg_catalog."C", provider_id limit p_limit
  ) select pg_catalog.jsonb_build_object(
    'listing', listing, 'rules', salahly_private.matching_rules_snapshot(), 'mode', p_mode,
    'items', coalesce((select pg_catalog.jsonb_agg(item order by case when p_mode = 'recommended' then score_bps end desc,
      tie_key collate pg_catalog."C", provider_id) from page), '[]'::jsonb),
    'has_more', (select pg_catalog.count(*) > p_limit from bounded)
  ) into result;
  return result;
end;
$function$;

-- Do not silently accept weakened constraints, altered numeric typmods, extra
-- columns, multiple/invalid configs, or unexpected policies on a populated rerun.
create or replace function salahly_private.validate_matching_integrity()
returns void language plpgsql security definer set search_path = ''
as $function$
declare
  expected record;
  actual_names text[];
  actual_types text[];
  actual_nullability boolean[];
begin
  if exists (select 1 from pg_catalog.pg_policies where schemaname = 'public'
    and tablename in ('provider_matching_profiles', 'matching_rules')) then
    raise exception using errcode = 'P0001', message = 'matching.errors.invalid';
  end if;
  for expected in select * from (values
    ('provider_matching_profiles', array['provider_id','provider_name','discoverable','latitude','longitude','experience_years','revision','discovery_consented_at','updated_at'],
      array['uuid','text','boolean','numeric','numeric','jsonb','integer','timestamp with time zone','timestamp with time zone'],
      array[true,true,true,false,false,true,true,false,true], 8),
    ('matching_rules', array['singleton','revision','distance_weight','rating_weight','availability_weight','experience_weight','neutral_bps','distance_scale_km','experience_cap_years'],
      array['boolean','integer','integer','integer','integer','integer','integer','numeric','integer'],
      array[true,true,true,true,true,true,true,true,true], 3)
  ) as shape(relation_name, names, types, nullability, constraint_count) loop
    select pg_catalog.array_agg(attname::text order by attnum),
      pg_catalog.array_agg(pg_catalog.format_type(atttypid, atttypmod) order by attnum),
      pg_catalog.array_agg(attnotnull order by attnum) into actual_names, actual_types, actual_nullability
      from pg_catalog.pg_attribute where attrelid = ('public.' || expected.relation_name)::regclass
        and attnum > 0 and not attisdropped;
    if actual_names is distinct from expected.names or actual_types is distinct from expected.types
      or actual_nullability is distinct from expected.nullability
      or (select pg_catalog.count(*) from pg_catalog.pg_constraint
        where conrelid = ('public.' || expected.relation_name)::regclass
          and contype in ('p','u','f','c') and convalidated and not condeferrable) <> expected.constraint_count then
      raise exception using errcode = 'P0001', message = 'matching.errors.invalid';
    end if;
  end loop;
  for expected in select * from (values
    ('provider_matching_profiles', 'provider_matching_profiles_name_check', 'salahly_private.matching_name_valid(provider_name)'),
    ('provider_matching_profiles', 'provider_matching_profiles_location_check', 'salahly_private.matching_location_valid(latitude, longitude)'),
    ('provider_matching_profiles', 'provider_matching_profiles_experience_check', '((experience_years)::text = (salahly_private.normalize_matching_experience(experience_years))::text)'),
    ('provider_matching_profiles', 'provider_matching_profiles_revision_check', '(revision >= 1)'),
    ('provider_matching_profiles', 'provider_matching_profiles_consent_check', '(((NOT discoverable) OR (discovery_consented_at IS NOT NULL)) AND ((discovery_consented_at IS NULL) OR (isfinite(discovery_consented_at) AND (discovery_consented_at <= updated_at))))'),
    ('provider_matching_profiles', 'provider_matching_profiles_time_check', 'isfinite(updated_at)'),
    ('matching_rules', 'matching_rules_singleton_check', 'singleton'),
    ('matching_rules', 'matching_rules_values_check', 'salahly_private.matching_rules_valid(revision, distance_weight, rating_weight, availability_weight, experience_weight, neutral_bps, distance_scale_km, experience_cap_years)')
  ) as backstop(relation_name, constraint_name, expression) loop
    if not exists (select 1 from pg_catalog.pg_constraint where conrelid = ('public.' || expected.relation_name)::regclass
      and conname = expected.constraint_name and contype = 'c' and convalidated and not condeferrable
      and pg_catalog.pg_get_expr(conbin, conrelid) = expected.expression) then
      raise exception using errcode = 'P0001', message = 'matching.errors.invalid';
    end if;
  end loop;
  if not exists (select 1 from pg_catalog.pg_constraint where conrelid = 'public.provider_matching_profiles'::regclass
    and contype = 'p' and conkey = array[1]::smallint[])
    or not exists (select 1 from pg_catalog.pg_constraint where conrelid = 'public.matching_rules'::regclass
      and contype = 'p' and conkey = array[1]::smallint[])
    or not exists (select 1 from pg_catalog.pg_constraint where conrelid = 'public.provider_matching_profiles'::regclass
      and contype = 'f' and conkey = array[1]::smallint[] and confrelid = 'public.profiles'::regclass
      and confkey = array[1]::smallint[] and confdeltype = 'c' and convalidated and not condeferrable)
    or (select pg_catalog.count(*) from public.matching_rules) <> 1
    or exists (select 1 from public.matching_rules where not singleton or not salahly_private.matching_rules_valid(
      revision, distance_weight, rating_weight, availability_weight, experience_weight,
      neutral_bps, distance_scale_km, experience_cap_years))
    or exists (select 1 from public.provider_matching_profiles where not salahly_private.matching_name_valid(provider_name)
      or not salahly_private.matching_location_valid(latitude, longitude)
      or experience_years::text <> salahly_private.normalize_matching_experience(experience_years)::text
      or revision < 1 or not pg_catalog.isfinite(updated_at)
      or (discoverable and discovery_consented_at is null)
      or (discovery_consented_at is not null and (not pg_catalog.isfinite(discovery_consented_at) or discovery_consented_at > updated_at))) then
    raise exception using errcode = 'P0001', message = 'matching.errors.invalid';
  end if;
end;
$function$;

-- Shared with rollback drift probes. No older policies, table ACLs, or RPCs are
-- changed here; schema CREATE/default grants cannot create an alternate M8 API.
create or replace function salahly_private.restore_matching_security()
returns void language plpgsql security definer set search_path = ''
as $function$
declare
  relation_name text;
  columns text;
  routine_name text;
begin
  perform salahly_private.validate_matching_integrity();
  alter schema salahly_private owner to postgres;
  revoke all privileges on schema salahly_private from public, anon, authenticated, service_role;
  grant usage on schema salahly_private to authenticated;
  revoke create on schema public from public, anon, authenticated, service_role;
  alter default privileges for role postgres in schema public, salahly_private
    revoke all privileges on tables from public, anon, authenticated, service_role;
  alter default privileges for role postgres in schema public, salahly_private
    revoke all privileges on functions from public, anon, authenticated, service_role;
  foreach relation_name in array array['provider_matching_profiles', 'matching_rules'] loop
    execute pg_catalog.format('alter table public.%I owner to postgres', relation_name);
    execute pg_catalog.format('alter table public.%I enable row level security', relation_name);
    execute pg_catalog.format('revoke all privileges on table public.%I from public, anon, authenticated, service_role', relation_name);
    select pg_catalog.string_agg(pg_catalog.quote_ident(attname), ',' order by attnum) into columns
      from pg_catalog.pg_attribute where attrelid = ('public.' || relation_name)::regclass and attnum > 0 and not attisdropped;
    execute pg_catalog.format('revoke all privileges (%s) on public.%I from public, anon, authenticated, service_role', columns, relation_name);
  end loop;
  foreach routine_name in array array[
    'salahly_private.matching_name_valid(text)', 'salahly_private.matching_location_valid(numeric,numeric)',
    'salahly_private.normalize_matching_experience(jsonb)',
    'salahly_private.matching_rules_valid(integer,integer,integer,integer,integer,integer,numeric,integer)',
    'salahly_private.matching_rules_snapshot()', 'salahly_private.provider_matching_profile_snapshot(uuid)',
    'salahly_private.provider_can_quote(uuid,uuid)',
    'salahly_private.configure_matching_rules(integer,integer,integer,integer,integer,numeric,integer)',
    'salahly_private.matching_distance_km(numeric,numeric,numeric,numeric)',
    'salahly_private.matching_query_key(uuid,text,numeric,numeric,integer,integer)',
    'salahly_private.score_provider_match(uuid,uuid,public.provider_matching_profiles,public.matching_rules,numeric,numeric,integer,integer)',
    'salahly_private.validate_matching_integrity()', 'salahly_private.restore_matching_security()',
    'public.get_provider_matching_profile()',
    'public.save_provider_matching_profile(boolean,numeric,numeric,jsonb,integer,boolean)',
    'public.get_provider_matches(uuid,text,numeric,numeric,boolean,integer,integer,integer,text,uuid,integer,text,integer)'
  ] loop
    execute pg_catalog.format('alter function %s owner to postgres', routine_name::regprocedure);
    execute pg_catalog.format('revoke all privileges on function %s from public, anon, authenticated, service_role', routine_name::regprocedure);
    if pg_catalog.left(routine_name, 7) = 'public.' then
      execute pg_catalog.format('grant execute on function %s to authenticated', routine_name::regprocedure);
    end if;
  end loop;
end;
$function$;
alter function salahly_private.restore_matching_security() owner to postgres;
revoke all privileges on function salahly_private.restore_matching_security() from public, anon, authenticated, service_role;
select salahly_private.restore_matching_security();

commit;
