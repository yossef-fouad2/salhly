-- Rollback-only M8 authorization, consent, scoring, pagination, and drift tests.
-- Run the WHOLE file as postgres after all five migrations in an isolated TEST
-- database. Never change the final ROLLBACK to COMMIT. Synthetic users, Storage
-- metadata, catalog/settings, and adversarial grants/DDL all roll back.
-- SQL roles/JWT GUCs are not hosted Auth/PostgREST/Storage/bytes/JWT validation.
-- Existing M7 independent-connection concurrency tests remain in the local runner.

begin;
set local search_path = '';
set local standard_conforming_strings = on;
set local timezone = 'UTC';

create temporary table matching_test_scope (unused boolean) on commit drop;
create function pg_temp.matching_assert(p_condition boolean, p_label text)
returns void language plpgsql security invoker set search_path = ''
as $function$
begin
  if p_condition is distinct from true then raise exception 'FAIL: %', p_label; end if;
  raise notice 'PASS: %', p_label;
end;
$function$;

create function pg_temp.matching_expect_error(p_sql text, p_state text, p_message text default null)
returns void language plpgsql security invoker set search_path = ''
as $function$
declare
  actual_state text;
  actual_message text;
  actual_detail text;
  actual_hint text;
begin
  begin
    execute p_sql;
  exception when others then
    get stacked diagnostics actual_state = returned_sqlstate, actual_message = message_text,
      actual_detail = pg_exception_detail, actual_hint = pg_exception_hint;
  end;
  if actual_state is null or actual_state <> all(pg_catalog.string_to_array(p_state, ','))
    or (p_message is not null and actual_message is distinct from p_message)
    or (p_message like 'matching.errors.%' and (coalesce(actual_detail, '') <> '' or coalesce(actual_hint, '') <> '')) then
    raise exception 'FAIL: expected % / %, got % / %; SQL: %', p_state, p_message, actual_state, actual_message, p_sql;
  end if;
  raise notice 'PASS (expected error): % / %', actual_state, actual_message;
end;
$function$;

create function pg_temp.matching_login(p_user_id uuid)
returns void language plpgsql security invoker set search_path = ''
as $function$
begin
  perform pg_catalog.set_config('request.jwt.claim.sub', coalesce(p_user_id::text, ''), true);
  perform pg_catalog.set_config('request.jwt.claims', pg_catalog.jsonb_build_object('sub', p_user_id, 'role', 'authenticated')::text, true);
end;
$function$;

create function pg_temp.matching_keys(p_value jsonb, p_keys text[], p_label text)
returns void language plpgsql security invoker set search_path = ''
as $function$
begin
  perform pg_temp.matching_assert(pg_catalog.jsonb_typeof(p_value) = 'object'
    and p_value ?& p_keys and p_value - p_keys = '{}'::jsonb, p_label);
end;
$function$;

create function pg_temp.matching_save_sql(p_changes jsonb default '{}'::jsonb)
returns text language plpgsql security invoker set search_path = ''
as $function$
declare
  payload jsonb := '{"discoverable":true,"latitude":null,"longitude":null,"experience_years":{},"expected_revision":0,"consent":true}'::jsonb || p_changes;
begin
  return pg_catalog.format('select public.save_provider_matching_profile(%L::boolean,%L::numeric,%L::numeric,%L::jsonb,%L::integer,%L::boolean)',
    payload ->> 'discoverable', payload ->> 'latitude', payload ->> 'longitude', payload -> 'experience_years',
    payload ->> 'expected_revision', payload ->> 'consent');
end;
$function$;

create function pg_temp.matching_query_sql(p_request_id uuid, p_changes jsonb default '{}'::jsonb)
returns text language plpgsql security invoker set search_path = ''
as $function$
declare
  payload jsonb := '{"mode":"recommended","latitude":null,"longitude":null,"location_consent":false,"weekday":null,"minute":null,"before_score_bps":null,"before_tie_key":null,"before_provider_id":null,"rules_revision":null,"before_query_key":null,"limit":20}'::jsonb || p_changes;
begin
  return pg_catalog.format('select public.get_provider_matches(%L::uuid,%L::text,%L::numeric,%L::numeric,%L::boolean,%L::integer,%L::integer,%L::integer,%L::text,%L::uuid,%L::integer,%L::text,%L::integer)',
    p_request_id, payload ->> 'mode', payload ->> 'latitude', payload ->> 'longitude', payload ->> 'location_consent',
    payload ->> 'weekday', payload ->> 'minute', payload ->> 'before_score_bps', payload ->> 'before_tie_key',
    payload ->> 'before_provider_id', payload ->> 'rules_revision', payload ->> 'before_query_key', payload ->> 'limit');
end;
$function$;

create function pg_temp.matching_item(p_result jsonb, p_provider_id uuid)
returns jsonb language sql immutable security invoker set search_path = ''
as $function$
  select value from pg_catalog.jsonb_array_elements(p_result -> 'items') where value ->> 'provider_id' = p_provider_id::text;
$function$;

create function pg_temp.matching_result_contract(p_result jsonb, p_request_id uuid)
returns void language plpgsql security invoker set search_path = ''
as $function$
declare
  item jsonb;
  factor jsonb;
  position integer;
  total_weight integer;
  weighted_score numeric;
  known_weight integer;
  keys text[] := array['distance','rating','availability','experience'];
begin
  perform pg_temp.matching_keys(p_result, array['listing','rules','mode','items','has_more'], 'MatchResults exact wire keys');
  perform pg_temp.matching_keys(p_result -> 'rules', array['revision','distance_weight','rating_weight','availability_weight',
    'experience_weight','neutral_bps','distance_scale_km','experience_cap_years'], 'MatchingRules exact wire keys');
  perform pg_temp.matching_keys(p_result -> 'listing', array['request_id','category_id','category_name_en','category_name_ar',
    'category_icon_key','summary','city','published_at','request_status'], 'existing MarketplaceListing projection only');
  perform pg_temp.matching_assert(p_result #>> '{listing,request_id}' = p_request_id::text
    and p_result #>> '{listing,request_status}' = 'open' and pg_catalog.jsonb_array_length(p_result -> 'items') <= 50
    and pg_catalog.jsonb_typeof(p_result -> 'has_more') = 'boolean', 'owner listing, open status, and bounded result');
  total_weight := (p_result #>> '{rules,distance_weight}')::integer + (p_result #>> '{rules,rating_weight}')::integer
    + (p_result #>> '{rules,availability_weight}')::integer + (p_result #>> '{rules,experience_weight}')::integer;
  for item in select value from pg_catalog.jsonb_array_elements(p_result -> 'items') loop
    perform pg_temp.matching_keys(item, array['provider_id','provider_name','score_bps','evidence_bps','tie_key','distance_km',
      'available','experience_years','review_count','average_rating','factors'], 'ProviderMatch contains no coordinates/private M5 fields');
    perform pg_temp.matching_assert(item ->> 'tie_key' = pg_catalog.md5(p_request_id::text || ':' || (item ->> 'provider_id'))
      and item ->> 'tie_key' ~ '^[0-9a-f]{32}$' and (item ->> 'score_bps')::integer between 0 and 10000
      and (item ->> 'evidence_bps')::integer between 0 and 10000 and item -> 'review_count' = '0'::jsonb
      and item -> 'average_rating' = 'null'::jsonb and pg_catalog.jsonb_array_length(item -> 'factors') = 4,
      'bounded scores, request-specific MD5 rotation, no invented rating');
    weighted_score := 0;
    known_weight := 0;
    for position in 0..3 loop
      factor := item #> array['factors',position::text];
      perform pg_temp.matching_keys(factor, array['key','score_bps','effective_bps','weight','reason'], 'MatchFactor exact wire keys');
      perform pg_temp.matching_assert(factor ->> 'key' = keys[position + 1]
        and factor -> 'weight' = p_result #> array['rules',keys[position + 1] || '_weight']
        and (factor ->> 'effective_bps')::integer = coalesce((factor ->> 'score_bps')::integer, 5000)
        and (factor ->> 'effective_bps')::integer between 0 and 10000, 'fixed factor order/weights and neutral unknown evidence');
      weighted_score := weighted_score + (factor ->> 'effective_bps')::numeric * (factor ->> 'weight')::integer;
      if factor -> 'score_bps' <> 'null'::jsonb then known_weight := known_weight + (factor ->> 'weight')::integer; end if;
    end loop;
    perform pg_temp.matching_assert((item ->> 'score_bps')::integer = pg_catalog.round(weighted_score / total_weight)::integer
      and (item ->> 'evidence_bps')::integer = pg_catalog.round(known_weight::numeric * 10000 / total_weight)::integer,
      'score and evidence use the same WHOLE configured weight denominator');
  end loop;
end;
$function$;

do $temp_grants$
begin
  execute pg_catalog.format('grant usage on schema %I to authenticated, anon, service_role',
    (select nspname from pg_catalog.pg_namespace where oid = pg_catalog.pg_my_temp_schema()));
end;
$temp_grants$;
grant execute on function pg_temp.matching_assert(boolean,text), pg_temp.matching_expect_error(text,text,text),
  pg_temp.matching_login(uuid), pg_temp.matching_keys(jsonb,text[],text), pg_temp.matching_save_sql(jsonb),
  pg_temp.matching_query_sql(uuid,jsonb), pg_temp.matching_item(jsonb,uuid), pg_temp.matching_result_contract(jsonb,uuid)
  to authenticated, anon, service_role;

do $security_contract$
declare
  relation_name text;
  routine_name text;
  api_role text;
  rules jsonb;
begin
  perform pg_temp.matching_assert(current_user = 'postgres', 'M8 suite starts as postgres');
  foreach relation_name in array array['provider_matching_profiles','matching_rules'] loop
    perform pg_temp.matching_assert((select relrowsecurity and pg_catalog.pg_get_userbyid(relowner) = 'postgres'
      from pg_catalog.pg_class where oid = ('public.' || relation_name)::regclass), 'new table RLS + postgres ownership: ' || relation_name);
    foreach api_role in array array['anon','authenticated','service_role'] loop
      perform pg_temp.matching_assert(not pg_catalog.has_table_privilege(api_role,'public.' || relation_name,
        'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') and not pg_catalog.has_any_column_privilege(
          api_role,'public.' || relation_name,'SELECT,INSERT,UPDATE,REFERENCES'), 'RPC-only table AND column ACLs: ' || api_role || '/' || relation_name);
    end loop;
  end loop;
  foreach routine_name in array array['public.get_provider_matching_profile()',
    'public.save_provider_matching_profile(boolean,numeric,numeric,jsonb,integer,boolean)',
    'public.get_provider_matches(uuid,text,numeric,numeric,boolean,integer,integer,integer,text,uuid,integer,text,integer)'] loop
    perform pg_temp.matching_assert(pg_catalog.has_function_privilege('authenticated',routine_name,'EXECUTE')
      and not pg_catalog.has_function_privilege('anon',routine_name,'EXECUTE')
      and not pg_catalog.has_function_privilege('service_role',routine_name,'EXECUTE'), 'only authenticated executes M8 client RPC: ' || routine_name);
  end loop;
  foreach routine_name in array array['salahly_private.configure_matching_rules(integer,integer,integer,integer,integer,numeric,integer)',
    'salahly_private.provider_can_quote(uuid,uuid)', 'salahly_private.matching_rules_snapshot()',
    'salahly_private.provider_matching_profile_snapshot(uuid)', 'salahly_private.normalize_matching_experience(jsonb)',
    'salahly_private.matching_distance_km(numeric,numeric,numeric,numeric)',
    'salahly_private.matching_query_key(uuid,text,numeric,numeric,integer,integer)',
    'salahly_private.validate_matching_integrity()', 'salahly_private.restore_matching_security()'] loop
    foreach api_role in array array['anon','authenticated','service_role'] loop
      perform pg_temp.matching_assert(not pg_catalog.has_function_privilege(api_role,routine_name,'EXECUTE'),
        'internal helper/configuration not executable: ' || api_role || '/' || routine_name);
    end loop;
  end loop;
  perform pg_temp.matching_assert(not exists (select 1 from pg_catalog.pg_proc as routine
    join pg_catalog.pg_namespace as namespace on namespace.oid = routine.pronamespace
    where (namespace.nspname = 'salahly_private' or (namespace.nspname = 'public' and routine.proname in (
      'get_provider_matching_profile','save_provider_matching_profile','get_provider_matches')))
      and (not routine.prosecdef or pg_catalog.pg_get_userbyid(routine.proowner) <> 'postgres'
        or not coalesce(routine.proconfig @> array['search_path=""'],false)
        or pg_catalog.has_function_privilege('anon',routine.oid,'EXECUTE'))), 'ALL private + M8 routines retain earlier definer/owner/path/no-anon contract');
  perform pg_temp.matching_assert((select provolatile = 's' from pg_catalog.pg_proc where oid =
    'public.get_provider_matches(uuid,text,numeric,numeric,boolean,integer,integer,integer,text,uuid,integer,text,integer)'::regprocedure)
    and (select provolatile = 's' from pg_catalog.pg_proc where oid =
      'salahly_private.score_provider_match(uuid,uuid,public.provider_matching_profiles,public.matching_rules,numeric,numeric,integer,integer)'::regprocedure),
    'matching query/scorer use one STABLE SQL snapshot');
  perform pg_temp.matching_assert(not exists (select 1 from pg_catalog.pg_policies where schemaname = 'public'
    and tablename in ('provider_matching_profiles','matching_rules','request_marketplace_listings','provider_quotes','service_jobs','job_status_history'))
    and (select pg_catalog.count(*) from pg_catalog.pg_policies where schemaname = 'public'
      and tablename in ('service_requests','service_request_photos')) = 2, 'new/M7 tables deny-all; M6 retains exactly two owner policies');
  perform pg_temp.matching_assert(not pg_catalog.has_schema_privilege('anon','salahly_private','USAGE')
    and not pg_catalog.has_schema_privilege('service_role','salahly_private','USAGE')
    and not pg_catalog.has_schema_privilege('authenticated','salahly_private','CREATE')
    and not pg_catalog.has_schema_privilege('authenticated','public','CREATE'), 'no API schema creation/configuration path');
  rules := salahly_private.matching_rules_snapshot();
  perform pg_catalog.set_config('matching_test.original_rules',rules::text,true);
  if rules ->> 'revision' = '1' then
    perform pg_temp.matching_assert(rules = '{"revision":1,"distance_weight":35,"rating_weight":25,"availability_weight":20,"experience_weight":20,"neutral_bps":5000,"distance_scale_km":50,"experience_cap_years":10}'::jsonb,
      'first install seeds exactly the agreed defaults');
  else
    perform pg_temp.matching_assert((rules ->> 'revision')::integer > 1 and rules -> 'neutral_bps' = '5000'::jsonb,
      'populated rerun retains a versioned configuration, not a reset seed');
  end if;
  rules := salahly_private.configure_matching_rules((rules ->> 'revision')::integer,35,25,20,20,50,10);
  perform pg_catalog.set_config('matching_test.rules',rules::text,true);
  perform pg_temp.matching_assert((rules ->> 'revision')::integer =
    (pg_catalog.current_setting('matching_test.original_rules')::jsonb ->> 'revision')::integer + 1, 'configuration save has an explicit version bump');
end;
$security_contract$;

do $fixtures$
declare
  fixture record;
  category uuid;
  active_ids uuid[] := '{}'::uuid[];
  other_category uuid := pg_catalog.gen_random_uuid();
  inactive_category uuid := pg_catalog.gen_random_uuid();
  user_id uuid;
  request_id uuid;
  photo_id uuid := pg_catalog.gen_random_uuid();
  path text;
  verification jsonb;
  original jsonb;
  index_number integer;
begin
  for index_number in 1..21 loop
    category := pg_catalog.gen_random_uuid();
    active_ids := pg_catalog.array_append(active_ids,category);
    insert into public.service_categories(id,slug,name_en,name_ar,description_en,description_ar,icon_key)
      values(category,'matching_' || category::text,'M8 Category EN','M8 Category AR','Fixture','Fixture','plumbing');
  end loop;
  insert into public.service_categories(id,slug,name_en,name_ar,description_en,description_ar,icon_key,is_active) values
    (other_category,'matching_' || other_category::text,'Other M8','Other M8','Fixture','Fixture','electrical',true),
    (inactive_category,'matching_' || inactive_category::text,'Inactive M8','Inactive M8','Fixture','Fixture','painting',false);
  perform pg_catalog.set_config('matching_test.active_ids',active_ids::text,true);
  perform pg_catalog.set_config('matching_test.category',active_ids[1]::text,true);
  perform pg_catalog.set_config('matching_test.other_category',other_category::text,true);
  perform pg_catalog.set_config('matching_test.inactive',inactive_category::text,true);
  for fixture in select * from (values
    ('customer_a','customer','Matching Customer A'),('customer_b','customer','Matching Customer B'),
    ('near','provider','Near Provider'),('far','provider','Far Provider'),('mid','provider','Mid Provider'),
    ('unknown','provider','New Provider'),('optout','provider','Opt-out Provider'),
    ('other_skill','provider','Other Skill Provider'),('outside_area','provider','Other Area Provider'),
    ('pending','provider','Pending Provider'),('rejected','provider','Rejected Provider'),('empty','provider','Empty Provider')
  ) as person(key,role,name) loop
    user_id := pg_catalog.gen_random_uuid();
    perform pg_catalog.set_config('matching_test.' || fixture.key,user_id::text,true);
    insert into auth.users(id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
      values(user_id,'authenticated','authenticated','m8-' || user_id::text || '@example.invalid',
        '{"provider":"email","providers":["email"]}'::jsonb,
        pg_catalog.jsonb_build_object('full_name',fixture.name,'role',fixture.role),pg_catalog.now(),pg_catalog.now());
    if fixture.role = 'provider' and fixture.key <> 'empty' then
      perform pg_temp.matching_login(user_id);
      set local role authenticated;
      perform public.save_provider_onboarding(user_id,'PRIVATE-bio and credential fixture, not a public description.',
        array[case when fixture.key = 'other_skill' then other_category else active_ids[1] end],
        array[case when fixture.key = 'outside_area' then 'Cairo district' else E' \tcAiRo\n ' end],
        '[{"weekday":1,"start_minute":480,"end_minute":600}]'::jsonb);
      path := user_id::text || '/' || pg_catalog.replace(pg_catalog.gen_random_uuid()::text,'-','') || '.jpg';
      insert into storage.objects(bucket_id,name,owner_id,metadata,user_metadata)
        values('provider-verification',path,user_id::text,'{"mimetype":"image/jpeg","size":1}'::jsonb,'{"PRIVATE-credential":"fixture"}'::jsonb);
      verification := public.submit_provider_verification(user_id,path,true);
      set local role postgres;
      if fixture.key <> 'pending' then
        perform public.review_provider_verification((verification #>> '{verification,id}')::uuid,
          case when fixture.key = 'rejected' then 'rejected' else 'verified' end,
          case when fixture.key = 'rejected' then 'PRIVATE-rejection note' else null end,'PRIVATE-reviewer');
        perform pg_temp.matching_login(user_id);
        set local role authenticated;
        if fixture.key in ('unknown','mid') then
          perform public.save_provider_onboarding(user_id,'PRIVATE-live bio',array[active_ids[1]],array['Cairo'],'[]'::jsonb);
        elsif fixture.key = 'far' then
          perform public.save_provider_onboarding(user_id,'PRIVATE-live bio',array[active_ids[1]],array['Cairo'],
            '[{"weekday":1,"start_minute":600,"end_minute":660}]'::jsonb);
        end if;
        set local role postgres;
      end if;
    end if;
  end loop;
  update public.profiles set phone = 'PRIVATE-contact',city = 'PRIVATE-personal city'
    where id = pg_catalog.current_setting('matching_test.near')::uuid;
  perform pg_temp.matching_login(pg_catalog.current_setting('matching_test.customer_a')::uuid);
  set local role authenticated;
  foreach path in array array['main','rotated','unpublished','cancelled','assigned'] loop
    request_id := pg_catalog.gen_random_uuid();
    perform pg_catalog.set_config('matching_test.request_' || path,request_id::text,true);
    if path = 'main' then
      insert into storage.objects(bucket_id,name,owner_id,metadata) values('request-photos',
        auth.uid()::text || '/' || request_id::text || '/' || photo_id::text || '.jpg',auth.uid()::text,
        '{"mimetype":"image/jpeg","size":1}'::jsonb);
      original := public.submit_service_request(request_id,active_ids[1],'PRIVATE-request title',
        'PRIVATE-request description with customer identity.','PRIVATE-request city','PRIVATE-address apartment 999',
        pg_catalog.clock_timestamp() + interval '1 hour',pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
          'id',photo_id,'storage_path',auth.uid()::text || '/' || request_id::text || '/' || photo_id::text || '.jpg',
          'mime_type','image/jpeg','size_bytes',1)),true);
      perform pg_catalog.set_config('matching_test.private_request',original::text,true);
    else
      perform public.submit_service_request(request_id,active_ids[1],'PRIVATE-request title','PRIVATE-request description.',
        'PRIVATE-request city','PRIVATE-request address',null,'[]'::jsonb,true);
    end if;
    if path <> 'unpublished' then
      perform public.publish_request_listing(request_id,'Public repair summary only','Cairo',true);
    end if;
    if path = 'cancelled' then perform public.cancel_service_request(request_id); end if;
  end loop;
  set local role postgres;
  perform pg_temp.matching_login(pg_catalog.current_setting('matching_test.customer_b')::uuid);
  set local role authenticated;
  request_id := pg_catalog.gen_random_uuid();
  perform pg_catalog.set_config('matching_test.request_foreign',request_id::text,true);
  perform public.submit_service_request(request_id,active_ids[1],'PRIVATE-foreign title','PRIVATE-foreign description.',
    'PRIVATE-city','PRIVATE-address',null,'[]'::jsonb,true);
  perform public.publish_request_listing(request_id,'Public foreign-owner summary','Cairo',true);
  set local role postgres;
end;
$fixtures$;

select pg_temp.matching_login(pg_catalog.current_setting('matching_test.empty')::uuid);
set local role authenticated;
do $empty_and_ineligible_drafts$
declare
  draft jsonb;
begin
  draft := public.get_provider_matching_profile();
  perform pg_temp.matching_keys(draft,array['provider_id','provider_name','discoverable','latitude','longitude','experience_years',
    'revision','consented_at','updated_at'],'ProviderMatchingProfile exact owner-only wire keys');
  perform pg_temp.matching_assert(draft = pg_catalog.jsonb_build_object('provider_id',auth.uid(),'provider_name','Empty Provider',
    'discoverable',false,'latitude',null,'longitude',null,'experience_years','{}'::jsonb,'revision',0,'consented_at',null,'updated_at',null),
    'absent preferences read as revision0 with current private name and no side effect');
  perform pg_temp.matching_expect_error(pg_temp.matching_save_sql(),'P0001','matching.errors.ineligible');
  draft := public.save_provider_matching_profile(false,null,null,'{}'::jsonb,0,false);
  perform pg_temp.matching_assert(draft ->> 'revision' = '1' and draft -> 'consented_at' = 'null'::jsonb
    and draft ->> 'provider_name' = 'Empty Provider' and public.save_provider_matching_profile(false,null,null,'{}'::jsonb,0,false) = draft,
    'unverified empty private draft saves and exactly retries without publication consent');
  perform pg_catalog.set_config('matching_test.empty_draft',draft::text,true);
  perform pg_temp.matching_expect_error(pg_temp.matching_save_sql('{"discoverable":false,"expected_revision":9,"consent":false}'::jsonb),
    'P0001','matching.errors.conflict');
end;
$empty_and_ineligible_drafts$;

set local role postgres;
do $pending_and_rejected$
declare
  key text;
  draft jsonb;
begin
  foreach key in array array['pending','rejected'] loop
    perform pg_temp.matching_login(pg_catalog.current_setting('matching_test.' || key)::uuid);
    set local role authenticated;
    perform pg_temp.matching_expect_error(pg_temp.matching_save_sql(),'P0001','matching.errors.ineligible');
    draft := public.save_provider_matching_profile(false,null,null,'{}'::jsonb,0,false);
    perform pg_temp.matching_assert(draft -> 'discoverable' = 'false'::jsonb and draft -> 'consented_at' = 'null'::jsonb,
      'pending/rejected providers can retain private opt-out drafts: ' || key);
    set local role postgres;
  end loop;
  perform pg_temp.matching_assert(not exists (select 1 from public.provider_matching_profiles
    where provider_id = pg_catalog.current_setting('matching_test.optout')::uuid), 'read/write lifecycle never opts another eligible provider in');
end;
$pending_and_rejected$;

select pg_temp.matching_login(pg_catalog.current_setting('matching_test.near')::uuid);
set local role authenticated;
do $validation_and_first_publication$
declare
  category uuid := pg_catalog.current_setting('matching_test.category')::uuid;
  before_snapshot jsonb := public.get_provider_matching_profile();
  invalid record;
  invalid_map jsonb;
  result jsonb;
begin
  foreach invalid_map in array array['null'::jsonb,'[]'::jsonb,'true'::jsonb,'1'::jsonb,'"{}"'::jsonb,
    '{"bad-uuid":1}'::jsonb, pg_catalog.jsonb_build_object(category,null),pg_catalog.jsonb_build_object(category,'1'),
    pg_catalog.jsonb_build_object(category,true),pg_catalog.jsonb_build_object(category,'{}'::jsonb),
    pg_catalog.jsonb_build_object(category,'[]'::jsonb),pg_catalog.jsonb_build_object(category,-1),
    pg_catalog.jsonb_build_object(category,61),pg_catalog.jsonb_build_object(category,1.5),pg_catalog.jsonb_build_object(category,1e100),
    pg_catalog.jsonb_build_object(pg_catalog.gen_random_uuid(),1),pg_catalog.jsonb_build_object(pg_catalog.current_setting('matching_test.inactive'),1)] loop
    perform pg_temp.matching_expect_error(pg_temp.matching_save_sql(pg_catalog.jsonb_build_object('experience_years',invalid_map)),
      'P0001','matching.errors.experience');
    perform pg_temp.matching_assert(public.get_provider_matching_profile() = before_snapshot,'malformed/inactive/non-current experience cannot create a row');
  end loop;
  perform pg_temp.matching_expect_error('select public.save_provider_matching_profile(true,null,null,null,0,true)','P0001','matching.errors.experience');
  for invalid in select * from (values
    (null::numeric,31::numeric),(30::numeric,null::numeric),(90.01,31),(-90.01,31),(30,180.01),(30,-180.01),
    (30.001,31),(30,31.001),('NaN'::numeric,31),(30,'NaN'::numeric),('Infinity'::numeric,31),
    ('-Infinity'::numeric,31),(30,'Infinity'::numeric),(30,'-Infinity'::numeric),(1e100,31)
  ) as location(latitude,longitude) loop
    perform pg_temp.matching_expect_error(pg_temp.matching_save_sql(pg_catalog.jsonb_build_object('latitude',invalid.latitude,'longitude',invalid.longitude)),
      'P0001','matching.errors.location');
    perform pg_temp.matching_assert(public.get_provider_matching_profile() = before_snapshot,'malformed/NaN/pair/precision location leaves preferences absent');
  end loop;
  for invalid in select * from (values
    ('{"expected_revision":null}'::jsonb,'invalid'),('{"expected_revision":-1}'::jsonb,'invalid'),
    ('{"expected_revision":1}'::jsonb,'conflict'),('{"discoverable":null}'::jsonb,'invalid'),
    ('{"consent":false}'::jsonb,'consent'),('{"consent":null}'::jsonb,'consent')
  ) as payload(changes,error_key) loop
    perform pg_temp.matching_expect_error(pg_temp.matching_save_sql(invalid.changes),'P0001','matching.errors.' || invalid.error_key);
  end loop;
  result := public.save_provider_matching_profile(true,30,31,pg_catalog.jsonb_build_object(category,10),0,true);
  perform pg_temp.matching_assert(result ->> 'provider_name' = 'Near Provider' and result ->> 'revision' = '1'
    and result -> 'discoverable' = 'true'::jsonb and result -> 'latitude' = '30'::jsonb and result -> 'longitude' = '31'::jsonb
    and result -> 'consented_at' = result -> 'updated_at' and result -> 'consented_at' <> 'null'::jsonb,
    'first consented publication freezes current name and approximate work origin at revision1');
  perform pg_temp.matching_assert(public.save_provider_matching_profile(true,30.00,31.00,
    pg_catalog.jsonb_build_object(pg_catalog.upper(category::text),10.0),0,true) = result,
    'retry canonicalizes UUID case, numeric zeros, and integer years without a new consent/name snapshot');
  perform pg_catalog.set_config('matching_test.near_profile',result::text,true);
end;
$validation_and_first_publication$;

set local role postgres;
do $publish_candidates$
declare
  key text;
  category uuid := pg_catalog.current_setting('matching_test.category')::uuid;
  result jsonb;
begin
  foreach key in array array['far','mid','unknown','other_skill','outside_area'] loop
    perform pg_temp.matching_login(pg_catalog.current_setting('matching_test.' || key)::uuid);
    set local role authenticated;
    result := public.save_provider_matching_profile(true,
      case when key = 'far' then 30::numeric when key = 'mid' then 30.1::numeric else null end,
      case when key = 'far' then 32::numeric when key = 'mid' then 31::numeric else null end,
      case when key = 'far' then pg_catalog.jsonb_build_object(category,0)
        when key = 'mid' then pg_catalog.jsonb_build_object(category,5) else '{}'::jsonb end,0,true);
    perform pg_temp.matching_assert(result -> 'discoverable' = 'true'::jsonb,'basic M7 eligibility permits consented publication: ' || key);
    set local role postgres;
  end loop;
end;
$publish_candidates$;

select pg_temp.matching_login(pg_catalog.current_setting('matching_test.customer_a')::uuid);
set local role authenticated;
do $owner_query_and_baseline_scores$
declare
  request_id uuid := pg_catalog.current_setting('matching_test.request_main')::uuid;
  result jsonb;
  item jsonb;
  provider_id uuid;
begin
  result := public.get_provider_matches(request_id);
  perform pg_temp.matching_result_contract(result,request_id);
  perform pg_temp.matching_assert(pg_catalog.jsonb_array_length(result -> 'items') = 4 and result -> 'has_more' = 'false'::jsonb
    and result ->> 'mode' = 'recommended' and result::text not like '%PRIVATE-%',
    'only four consented request-eligible providers; private customer/provider/M5 data is never projected');
  foreach provider_id in array array[pg_catalog.current_setting('matching_test.optout')::uuid,
    pg_catalog.current_setting('matching_test.empty')::uuid,pg_catalog.current_setting('matching_test.pending')::uuid,
    pg_catalog.current_setting('matching_test.rejected')::uuid,pg_catalog.current_setting('matching_test.other_skill')::uuid,
    pg_catalog.current_setting('matching_test.outside_area')::uuid] loop
    perform pg_temp.matching_assert(pg_temp.matching_item(result,provider_id) is null,'discovery/credential/current category/exact area exclusions are hard filters');
  end loop;
  item := pg_temp.matching_item(result,pg_catalog.current_setting('matching_test.unknown')::uuid);
  perform pg_temp.matching_assert(item -> 'score_bps' = '5000'::jsonb and item -> 'evidence_bps' = '0'::jsonb
    and item -> 'distance_km' = 'null'::jsonb and item -> 'available' = 'null'::jsonb and item -> 'experience_years' = 'null'::jsonb
    and item #>> '{factors,0,reason}' = 'no_query_location' and item #>> '{factors,1,reason}' = 'no_reviews'
    and item #>> '{factors,2,reason}' = 'no_time_preference' and item #>> '{factors,3,reason}' = 'no_experience',
    'new/no-evidence provider is neutral, not zero or a fictitious star/quality score');
  item := pg_temp.matching_item(result,pg_catalog.current_setting('matching_test.near')::uuid);
  perform pg_temp.matching_assert(item -> 'score_bps' = '6000'::jsonb and item -> 'evidence_bps' = '2000'::jsonb,
    'only self-reported experience is known with omitted query location/time');
  item := pg_temp.matching_item(result,pg_catalog.current_setting('matching_test.far')::uuid);
  perform pg_temp.matching_assert(item -> 'score_bps' = '4000'::jsonb and item #> '{factors,3,score_bps}' = '0'::jsonb
    and item #>> '{factors,3,reason}' = 'self_reported', 'known zero experience differs from missing experience');
  result := public.get_provider_matches(request_id,'recommended',30,31,true,1,480);
  perform pg_temp.matching_result_contract(result,request_id);
  item := pg_temp.matching_item(result,pg_catalog.current_setting('matching_test.near')::uuid);
  perform pg_temp.matching_assert(item -> 'distance_km' = '0.0'::jsonb and item -> 'available' = 'true'::jsonb
    and item -> 'experience_years' = '10'::jsonb and item -> 'score_bps' = '8750'::jsonb and item -> 'evidence_bps' = '7500'::jsonb
    and item #> '{factors,0,score_bps}' = '10000'::jsonb and item #>> '{factors,0,reason}' = 'straight_line',
    'near/within-hours/capped experience score8750 with rating neutral and75% weight evidence');
  item := pg_temp.matching_item(result,pg_catalog.current_setting('matching_test.far')::uuid);
  perform pg_temp.matching_assert(item -> 'distance_km' = '96.3'::jsonb and item -> 'available' = 'false'::jsonb
    and item -> 'score_bps' = '1250'::jsonb and item -> 'evidence_bps' = '7500'::jsonb
    and item #> '{factors,0,score_bps}' = '0'::jsonb and item #>> '{factors,2,reason}' = 'outside_hours',
    'far/outside-hours/zero-years provider stays eligible with score1250, not silently excluded');
  item := pg_temp.matching_item(result,pg_catalog.current_setting('matching_test.mid')::uuid);
  perform pg_temp.matching_assert(item -> 'distance_km' = '11.1'::jsonb and item #> '{factors,0,score_bps}' = '7776'::jsonb
    and item -> 'available' = 'null'::jsonb and item #>> '{factors,2,reason}' = 'no_declared_hours'
    and item -> 'score_bps' = '5972'::jsonb and item -> 'evidence_bps' = '5500'::jsonb,
    'real Haversine sample and partial evidence use fixed denominator, not renormalized known factors');
  item := pg_temp.matching_item(result,pg_catalog.current_setting('matching_test.unknown')::uuid);
  perform pg_temp.matching_assert(item -> 'score_bps' = '5000'::jsonb and item -> 'evidence_bps' = '0'::jsonb
    and item #>> '{factors,0,reason}' = 'no_provider_origin' and item #>> '{factors,2,reason}' = 'no_declared_hours',
    'supplied query preferences change missing-evidence reasons, not neutrality or eligibility');
  result := public.get_provider_matches(request_id,'recommended',30.01,31,true,1,480);
  item := pg_temp.matching_item(result,pg_catalog.current_setting('matching_test.near')::uuid);
  perform pg_temp.matching_assert(item -> 'distance_km' = '1.1'::jsonb and item #> '{factors,0,score_bps}' = '9778'::jsonb
    and item -> 'score_bps' = '8672'::jsonb, 'score uses UNROUNDED distance, public one-decimal distance is only an estimate');
  perform pg_temp.matching_assert(public.get_service_request(request_id) = pg_catalog.current_setting('matching_test.private_request')::jsonb,
    'query does not persist points, rewrite requests/photos, or convert M6 preferred_at');
  perform pg_temp.matching_expect_error(pg_temp.matching_query_sql(pg_catalog.current_setting('matching_test.request_unpublished')::uuid),
    'P0001','matching.errors.unpublished');
  perform pg_temp.matching_expect_error(pg_temp.matching_query_sql(pg_catalog.current_setting('matching_test.request_cancelled')::uuid),
    'P0001','matching.errors.status');
  perform pg_temp.matching_expect_error(pg_temp.matching_query_sql(pg_catalog.current_setting('matching_test.request_foreign')::uuid),
    'P0001','matching.errors.not_found');
  perform pg_temp.matching_expect_error(pg_temp.matching_query_sql(null),'P0001','matching.errors.not_found');
end;
$owner_query_and_baseline_scores$;

set local role postgres;
select pg_temp.matching_assert(salahly_private.provider_matching_profile_snapshot(pg_catalog.current_setting('matching_test.near')::uuid)
  = pg_catalog.current_setting('matching_test.near_profile')::jsonb, 'all customer matching queries leave provider preferences untouched');

select pg_temp.matching_login(pg_catalog.current_setting('matching_test.near')::uuid);
set local role authenticated;
do $consent_name_retry_withdrawal$
declare
  category uuid := pg_catalog.current_setting('matching_test.category')::uuid;
  first_profile jsonb := pg_catalog.current_setting('matching_test.near_profile')::jsonb;
  published jsonb;
  withdrawn jsonb;
begin
  update public.profiles set full_name = E'\tRenamed Near Provider\n' where id = auth.uid();
  perform pg_temp.matching_assert(public.save_provider_matching_profile(true,30,31,pg_catalog.jsonb_build_object(category,10),0,true) = first_profile,
    'exact publication retry cannot silently expose a newly edited profile name');
  published := public.save_provider_matching_profile(true,30,31,pg_catalog.jsonb_build_object(category,10),1,true);
  perform pg_temp.matching_assert(published ->> 'provider_name' = 'Renamed Near Provider' and published ->> 'revision' = '2'
    and (published ->> 'consented_at')::timestamptz > (first_profile ->> 'consented_at')::timestamptz
    and published -> 'consented_at' = published -> 'updated_at', 'new explicit consent publishes a new trimmed name at a new revision');
  perform pg_temp.matching_expect_error(pg_temp.matching_save_sql(pg_catalog.jsonb_build_object(
    'expected_revision',1,'latitude',30,'longitude',31,'experience_years',pg_catalog.jsonb_build_object(category,11))),
    'P0001','matching.errors.conflict');
  perform pg_temp.matching_expect_error(pg_temp.matching_save_sql(pg_catalog.jsonb_build_object(
    'expected_revision',1,'latitude',30,'longitude',31,'experience_years','{}'::jsonb,'consent',false)),
    'P0001','matching.errors.consent');
  update public.profiles set full_name = E'\tX\t' where id = auth.uid();
  perform pg_temp.matching_assert(public.save_provider_matching_profile(true,30,31,pg_catalog.jsonb_build_object(category,10),1,true) = published,
    'retry keeps a valid consented snapshot even when current normalized name is invalid');
  perform pg_temp.matching_expect_error(pg_temp.matching_save_sql(pg_catalog.jsonb_build_object(
    'expected_revision',2,'latitude',30,'longitude',31,'experience_years',pg_catalog.jsonb_build_object(category,10))),
    'P0001','matching.errors.invalid');
  withdrawn := public.save_provider_matching_profile(false,30,31,pg_catalog.jsonb_build_object(category,10),2,false);
  perform pg_temp.matching_assert(withdrawn ->> 'revision' = '3' and withdrawn -> 'discoverable' = 'false'::jsonb
    and withdrawn -> 'provider_name' = published -> 'provider_name' and withdrawn -> 'consented_at' = published -> 'consented_at'
    and (withdrawn ->> 'updated_at')::timestamptz > (published ->> 'updated_at')::timestamptz,
    'withdrawal needs no new consent/name publication and keeps prior consent privately for audit');
  perform public.save_provider_onboarding(auth.uid(),'','{}'::uuid[],'{}'::text[],'[]'::jsonb);
  perform pg_temp.matching_assert(public.save_provider_matching_profile(false,30,31,pg_catalog.jsonb_build_object(category,10),2,false) = withdrawn,
    'exact opt-out retry succeeds despite later skill/area loss');
  withdrawn := public.save_provider_matching_profile(false,30,31,pg_catalog.jsonb_build_object(category,10),3,false);
  perform pg_temp.matching_assert(withdrawn ->> 'revision' = '4', 'pure opt-out remains possible without clearing now-stale experience');
  perform pg_temp.matching_expect_error(pg_temp.matching_save_sql(pg_catalog.jsonb_build_object(
    'expected_revision',4,'latitude',30,'longitude',31,'experience_years',pg_catalog.jsonb_build_object(category,10))),
    'P0001','matching.errors.experience');
  perform pg_temp.matching_expect_error(pg_temp.matching_save_sql('{"expected_revision":4}'::jsonb),'P0001','matching.errors.ineligible');
  withdrawn := public.save_provider_matching_profile(false,null,null,'{}'::jsonb,4,false);
  perform pg_temp.matching_assert(withdrawn ->> 'revision' = '5' and withdrawn -> 'experience_years' = '{}'::jsonb,
    'stale settings may be removed while unapproved/ineligible');
  update public.profiles set full_name = 'Renamed Near Provider' where id = auth.uid();
  perform public.save_provider_onboarding(auth.uid(),'PRIVATE-bio restored',array[category],array['Cairo'],
    '[{"weekday":1,"start_minute":480,"end_minute":600}]'::jsonb);
  published := public.save_provider_matching_profile(true,30,31,pg_catalog.jsonb_build_object(category,10),5,true);
  perform pg_catalog.set_config('matching_test.near_profile',published::text,true);
end;
$consent_name_retry_withdrawal$;

set local role postgres;
update public.provider_verifications set status = 'rejected',review_note = 'PRIVATE-later revocation'
  where user_id = pg_catalog.current_setting('matching_test.near')::uuid;
set local role authenticated;
do $revoked_exact_retry$
declare
  category uuid := pg_catalog.current_setting('matching_test.category')::uuid;
  published jsonb := pg_catalog.current_setting('matching_test.near_profile')::jsonb;
  withdrawn jsonb;
begin
  perform pg_temp.matching_assert(public.save_provider_matching_profile(true,30,31,pg_catalog.jsonb_build_object(category,10),5,true) = published,
    'exact consented save retry is canonical after verification loss and cannot republish');
  perform pg_temp.matching_expect_error(pg_temp.matching_save_sql(pg_catalog.jsonb_build_object(
    'expected_revision',6,'latitude',30,'longitude',31,'experience_years',pg_catalog.jsonb_build_object(category,10))),
    'P0001','matching.errors.ineligible');
  withdrawn := public.save_provider_matching_profile(false,30,31,pg_catalog.jsonb_build_object(category,10),6,false);
  perform pg_temp.matching_assert(withdrawn -> 'discoverable' = 'false'::jsonb and withdrawn ->> 'revision' = '7',
    'verification loss never blocks withdrawal');
end;
$revoked_exact_retry$;
set local role postgres;
update public.provider_verifications set status = 'verified',review_note = null
  where user_id = pg_catalog.current_setting('matching_test.near')::uuid;
set local role authenticated;
select pg_catalog.set_config('matching_test.near_profile',public.save_provider_matching_profile(true,30,31,
  pg_catalog.jsonb_build_object(pg_catalog.current_setting('matching_test.category'),10),7,true)::text,true);
set local role postgres;

do $experience_bounds_and_general_uuid$
declare
  provider uuid := pg_catalog.current_setting('matching_test.near')::uuid;
  category uuid := pg_catalog.current_setting('matching_test.category')::uuid;
  skills uuid[] := pg_catalog.current_setting('matching_test.active_ids')::uuid[];
  generic_id uuid := pg_catalog.overlay(pg_catalog.gen_random_uuid()::text,'7',15,1)::uuid;
  experience jsonb;
  before_profile jsonb;
  profile jsonb;
  revision integer;
begin
  perform pg_temp.matching_login(provider);
  set local role authenticated;
  before_profile := public.get_provider_matching_profile();
  revision := (before_profile ->> 'revision')::integer;
  select pg_catalog.jsonb_object_agg(id::text,0) into experience from pg_catalog.unnest(skills) as skill(id);
  perform pg_temp.matching_expect_error(pg_temp.matching_save_sql(pg_catalog.jsonb_build_object(
    'expected_revision',revision,'experience_years',experience)),'P0001','matching.errors.experience');
  perform public.save_provider_onboarding(provider,'PRIVATE-20 skills',skills[1:20],array['Cairo'],
    '[{"weekday":1,"start_minute":480,"end_minute":600}]'::jsonb);
  select pg_catalog.jsonb_object_agg(id::text,case when position = 1 then 60 else 0 end) into experience
    from pg_catalog.unnest(skills[1:20]) with ordinality as skill(id,position);
  profile := public.save_provider_matching_profile(true,90,180,experience,revision,true);
  perform pg_temp.matching_assert((select pg_catalog.count(*) from pg_catalog.jsonb_object_keys(profile -> 'experience_years')) = 20
    and profile #>> array['experience_years',category::text] = '60' and profile -> 'latitude' = '90'::jsonb
    and profile -> 'longitude' = '180'::jsonb,'20 current active skills, integer0/60 years, and location maxima accepted');
  revision := (profile ->> 'revision')::integer;
  perform pg_temp.matching_expect_error(pg_temp.matching_save_sql(pg_catalog.jsonb_build_object('expected_revision',revision,
    'experience_years',pg_catalog.jsonb_build_object(category::text,1,pg_catalog.upper(category::text),1))),
    'P0001','matching.errors.experience');
  set local role postgres;
  insert into public.service_categories(id,slug,name_en,name_ar,description_en,description_ar,icon_key)
    values(generic_id,'matching_' || generic_id::text,'Generic UUID','Generic UUID','Fixture','Fixture','plumbing');
  set local role authenticated;
  perform public.save_provider_onboarding(provider,'PRIVATE-generic UUID',array[category,generic_id],array['Cairo'],
    '[{"weekday":1,"start_minute":480,"end_minute":600}]'::jsonb);
  profile := public.save_provider_matching_profile(true,-90,-180,pg_catalog.jsonb_build_object(category,10,generic_id,1),revision,true);
  perform pg_temp.matching_assert(profile #>> array['experience_years',generic_id::text] = '1'
    and profile -> 'latitude' = '-90'::jsonb and profile -> 'longitude' = '-180'::jsonb,
    'M5 generic category UUIDs (not justv4) and negative location bounds remain valid');
  perform public.save_provider_onboarding(provider,'PRIVATE-original skill',array[category],array['Cairo'],
    '[{"weekday":1,"start_minute":480,"end_minute":600}]'::jsonb);
  profile := public.save_provider_matching_profile(true,30,31,pg_catalog.jsonb_build_object(category,10),(profile ->> 'revision')::integer,true);
  perform pg_catalog.set_config('matching_test.near_profile',profile::text,true);
  set local role postgres;
end;
$experience_bounds_and_general_uuid$;

do $current_mutable_eligibility$
declare
  provider uuid := pg_catalog.current_setting('matching_test.near')::uuid;
  customer uuid := pg_catalog.current_setting('matching_test.customer_a')::uuid;
  category uuid := pg_catalog.current_setting('matching_test.category')::uuid;
  request_id uuid := pg_catalog.current_setting('matching_test.request_main')::uuid;
  result jsonb;
  action integer;
begin
  for action in 1..7 loop
    if action = 1 then update public.profiles set role = 'customer' where id = provider;
    elsif action = 2 then update public.provider_verifications set status = 'rejected',review_note = 'PRIVATE-revocation' where user_id = provider;
    elsif action = 3 then update public.service_categories set is_active = false where id = category;
    else
      perform pg_temp.matching_login(provider);
      set local role authenticated;
      perform public.save_provider_onboarding(provider,'PRIVATE-live edit',
        case when action = 4 then '{}'::uuid[] when action = 5 then array[pg_catalog.current_setting('matching_test.other_category')::uuid]
          else array[category] end,
        case when action = 6 then array['Cairo district'] when action = 7 then '{}'::text[] else array['Cairo'] end,
        '[{"weekday":1,"start_minute":480,"end_minute":600}]'::jsonb);
      set local role postgres;
    end if;
    perform pg_temp.matching_login(customer);
    set local role authenticated;
    result := public.get_provider_matches(request_id,'recommended',30,31,true,1,480);
    perform pg_temp.matching_assert(pg_temp.matching_item(result,provider) is null,
      'query revalidates current role/verification/active exact skill/area, not submission snapshot: ' || action);
    if action = 3 then
      perform pg_temp.matching_assert(result -> 'items' = '[]'::jsonb,'inactive request category excludes ALL matching providers');
    end if;
    set local role postgres;
    update public.profiles set role = 'provider' where id = provider;
    update public.provider_verifications set status = 'verified',review_note = null where user_id = provider;
    update public.service_categories set is_active = true where id = category;
    perform pg_temp.matching_login(provider);
    set local role authenticated;
    perform public.save_provider_onboarding(provider,'PRIVATE-restored live edit',array[category],array[E' \tCAIRO\r '],
      '[{"weekday":1,"start_minute":480,"end_minute":600}]'::jsonb);
    set local role postgres;
  end loop;
  perform pg_temp.matching_login(customer);
  set local role authenticated;
  result := public.get_provider_matches(request_id,'recommended',30,31,true,1,480);
  perform pg_temp.matching_assert(pg_temp.matching_item(result,provider) ->> 'provider_name' = 'Renamed Near Provider'
    and pg_temp.matching_item(result,provider) -> 'score_bps' = '8750'::jsonb, 'restored casefold/trim exact M7 eligibility restores the consented card');
  set local role postgres;
end;
$current_mutable_eligibility$;

select pg_temp.matching_login(pg_catalog.current_setting('matching_test.customer_a')::uuid);
set local role authenticated;
do $query_validation_and_hours$
declare
  request_id uuid := pg_catalog.current_setting('matching_test.request_main')::uuid;
  provider uuid := pg_catalog.current_setting('matching_test.near')::uuid;
  invalid record;
  minute_value integer;
  result jsonb;
  item jsonb;
begin
  for invalid in select * from (values
    ('{"mode":null}'::jsonb,'invalid'),('{"mode":"all"}'::jsonb,'invalid'),('{"mode":"Recommended"}'::jsonb,'invalid'),
    ('{"limit":null}'::jsonb,'invalid'),('{"limit":0}'::jsonb,'invalid'),('{"limit":-1}'::jsonb,'invalid'),('{"limit":51}'::jsonb,'invalid'),
    ('{"weekday":1}'::jsonb,'invalid'),('{"minute":480}'::jsonb,'invalid'),('{"weekday":0,"minute":0}'::jsonb,'invalid'),
    ('{"weekday":8,"minute":0}'::jsonb,'invalid'),('{"weekday":1,"minute":-1}'::jsonb,'invalid'),('{"weekday":1,"minute":1440}'::jsonb,'invalid'),
    ('{"latitude":30,"longitude":31}'::jsonb,'consent'),('{"latitude":30,"longitude":31,"location_consent":null}'::jsonb,'consent'),
    ('{"latitude":30,"location_consent":true}'::jsonb,'location'),('{"longitude":31,"location_consent":true}'::jsonb,'location'),
    ('{"latitude":90.01,"longitude":31,"location_consent":true}'::jsonb,'location'),
    ('{"latitude":-90.01,"longitude":31,"location_consent":true}'::jsonb,'location'),
    ('{"latitude":30,"longitude":180.01,"location_consent":true}'::jsonb,'location'),
    ('{"latitude":30,"longitude":-180.01,"location_consent":true}'::jsonb,'location'),
    ('{"latitude":30.001,"longitude":31,"location_consent":true}'::jsonb,'location'),
    ('{"latitude":30,"longitude":31.001,"location_consent":true}'::jsonb,'location'),
    ('{"latitude":"NaN","longitude":31,"location_consent":true}'::jsonb,'location'),
    ('{"latitude":30,"longitude":"NaN","location_consent":true}'::jsonb,'location'),
    ('{"latitude":"Infinity","longitude":31,"location_consent":true}'::jsonb,'location'),
    ('{"latitude":"-Infinity","longitude":31,"location_consent":true}'::jsonb,'location'),
    ('{"latitude":30,"longitude":"Infinity","location_consent":true}'::jsonb,'location'),
    ('{"latitude":30,"longitude":"-Infinity","location_consent":true}'::jsonb,'location'),
    ('{"latitude":1e100,"longitude":31,"location_consent":true}'::jsonb,'location')
  ) as query(changes,error_key) loop
    perform pg_temp.matching_expect_error(pg_temp.matching_query_sql(request_id,invalid.changes),'P0001','matching.errors.' || invalid.error_key);
  end loop;
  foreach minute_value in array array[479,480,599,600] loop
    result := public.get_provider_matches(request_id,'recommended',null,null,false,1,minute_value);
    item := pg_temp.matching_item(result,provider);
    perform pg_temp.matching_assert((item ->> 'available')::boolean = (minute_value >= 480 and minute_value < 600)
      and (item #>> '{factors,2,score_bps}')::integer = case when minute_value >= 480 and minute_value < 600 then 10000 else 0 end,
      'weekly hours use inclusive start/exclusive end, not booked slots: minute ' || minute_value);
  end loop;
  result := public.get_provider_matches(request_id,'recommended',null,null,false,2,480);
  item := pg_temp.matching_item(result,provider);
  perform pg_temp.matching_assert(item -> 'available' = 'false'::jsonb and item #>> '{factors,2,reason}' = 'outside_hours',
    'a missing requested weekday in an otherwise declared schedule is known outside-hours');
  result := public.get_provider_matches(request_id,'recommended',90,180,true);
  item := pg_temp.matching_item(result,provider);
  perform pg_temp.matching_assert((item ->> 'distance_km')::numeric > 0 and (item ->> 'distance_km')::numeric < 20016,
    'query coordinate boundaries produce finite bounded spherical distances');
end;
$query_validation_and_hours$;
set local role postgres;
select pg_temp.matching_assert(pg_catalog.abs(salahly_private.matching_distance_km(0,179.99,0,-179.99) - 2.22390160467) < 0.000001
  and pg_catalog.abs(salahly_private.matching_distance_km(0,0,0,180) - 20015.1144420359) < 0.000001
  and salahly_private.matching_distance_km(90,0,90,180) < 0.000001, 'Haversine clamps antipodes/poles and crosses antimeridian by the short straight-line path');
select pg_temp.matching_assert(salahly_private.matching_query_key(pg_catalog.current_setting('matching_test.request_main')::uuid,
  'recommended',-0.00,31.10,1,0) = pg_catalog.md5(pg_catalog.current_setting('matching_test.request_main') || ':recommended:0.00:31.10:1:0'),
  'cursor query key uses two decimals, dot separator, numeric zero, and explicit wall time');

do $full_day_hours$
declare
  provider uuid := pg_catalog.current_setting('matching_test.near')::uuid;
  customer uuid := pg_catalog.current_setting('matching_test.customer_a')::uuid;
  category uuid := pg_catalog.current_setting('matching_test.category')::uuid;
  request_id uuid := pg_catalog.current_setting('matching_test.request_main')::uuid;
  result jsonb;
begin
  perform pg_temp.matching_login(provider);
  set local role authenticated;
  perform public.save_provider_onboarding(provider,'PRIVATE-hours',array[category],array['Cairo'],
    '[{"weekday":1,"start_minute":0,"end_minute":1440},{"weekday":7,"start_minute":1439,"end_minute":1440}]'::jsonb);
  set local role postgres;
  perform pg_temp.matching_login(customer);
  set local role authenticated;
  result := public.get_provider_matches(request_id,'recommended',null,null,false,1,0);
  perform pg_temp.matching_assert(pg_temp.matching_item(result,provider) -> 'available' = 'true'::jsonb,'full-day schedule starts at minute0');
  result := public.get_provider_matches(request_id,'recommended',null,null,false,7,1439);
  perform pg_temp.matching_assert(pg_temp.matching_item(result,provider) -> 'available' = 'true'::jsonb,'ISO Sunday/minute1439 respects end1440');
  set local role postgres;
  perform pg_temp.matching_login(provider);
  set local role authenticated;
  perform public.save_provider_onboarding(provider,'PRIVATE-hours restored',array[category],array['Cairo'],
    '[{"weekday":1,"start_minute":480,"end_minute":600}]'::jsonb);
  set local role postgres;
end;
$full_day_hours$;

do $m7_quoteability_unchanged$
declare
  provider uuid := pg_catalog.current_setting('matching_test.optout')::uuid;
  customer uuid := pg_catalog.current_setting('matching_test.customer_a')::uuid;
  request_id uuid := pg_catalog.current_setting('matching_test.request_assigned')::uuid;
  quote jsonb;
  job jsonb;
  result jsonb;
begin
  perform pg_temp.matching_login(provider);
  set local role authenticated;
  quote := public.save_provider_quote(request_id,12500,'EGP',60,'M7 terms unchanged',0);
  perform pg_temp.matching_assert(quote ->> 'status' = 'pending','M7 quotes do not require M8 discovery opt-in');
  perform public.save_provider_matching_profile(true,null,null,'{}'::jsonb,0,true);
  set local role postgres;
  perform pg_temp.matching_login(customer);
  set local role authenticated;
  result := public.get_provider_matches(request_id);
  perform pg_temp.matching_assert(pg_temp.matching_item(result,provider) is not null,'existing pending quote remains matching-eligible');
  set local role postgres;
  perform pg_temp.matching_login(provider);
  set local role authenticated;
  perform public.withdraw_provider_quote((quote ->> 'id')::uuid,1);
  set local role postgres;
  perform pg_temp.matching_login(customer);
  set local role authenticated;
  result := public.get_provider_matches(request_id);
  perform pg_temp.matching_assert(pg_temp.matching_item(result,provider) is not null,'withdrawn quote remains eligible for discovery/reactivation');
  perform pg_temp.matching_expect_error(pg_catalog.format('select public.accept_provider_quote(%L,1,true)',quote ->> 'id'),
    'P0001','marketplace.errors.status');
  set local role postgres;
  perform pg_temp.matching_login(provider);
  set local role authenticated;
  quote := public.save_provider_quote(request_id,12500,'EGP',60,'M7 terms unchanged',1);
  set local role postgres;
  perform pg_temp.matching_login(customer);
  set local role authenticated;
  job := public.accept_provider_quote((quote ->> 'id')::uuid,2,true);
  perform pg_temp.matching_assert(job ->> 'status' = 'selected','selection still requires a current M7 quote and acceptance consent');
  perform pg_temp.matching_expect_error(pg_temp.matching_query_sql(request_id),'P0001','matching.errors.status');
  set local role postgres;
  perform pg_temp.matching_login(provider);
  set local role authenticated;
  perform public.save_provider_matching_profile(false,null,null,'{}'::jsonb,1,false);
  perform pg_temp.matching_assert(not exists (select 1 from public.service_requests) and not exists (select 1 from public.service_request_photos)
    and public.get_service_job((job ->> 'id')::uuid) ->> 'address' = 'PRIVATE-request address',
    'M7 participant disclosure remains distinct from M8 matching and M6 photo/base-table privacy');
  set local role postgres;
end;
$m7_quoteability_unchanged$;

do $configuration_validation$
declare
  revision integer := (salahly_private.matching_rules_snapshot() ->> 'revision')::integer;
  before_rules jsonb := salahly_private.matching_rules_snapshot();
  invalid record;
begin
  for invalid in select * from (values
    (null::integer,25,20,20,50::numeric,10),(-1,25,20,20,50,10),(1001,25,20,20,50,10),
    (35,null,20,20,50,10),(35,-1,20,20,50,10),(35,1001,20,20,50,10),
    (35,25,null,20,50,10),(35,25,-1,20,50,10),(35,25,1001,20,50,10),
    (35,25,20,null,50,10),(35,25,20,-1,50,10),(35,25,20,1001,50,10),
    (2147483647,2147483647,2147483647,2147483647,50,10),(0,0,0,0,50,10),
    (35,25,20,20,null,10),(35,25,20,20,0.99,10),(35,25,20,20,500.01,10),
    (35,25,20,20,'NaN'::numeric,10),(35,25,20,20,'Infinity'::numeric,10),(35,25,20,20,'-Infinity'::numeric,10),
    (35,25,20,20,50,null),(35,25,20,20,50,0),(35,25,20,20,50,61)
  ) as config(distance_weight,rating_weight,availability_weight,experience_weight,scale,cap) loop
    perform pg_temp.matching_expect_error(pg_catalog.format('select salahly_private.configure_matching_rules(%L,%L,%L,%L,%L,%L::numeric,%L)',
      revision,invalid.distance_weight,invalid.rating_weight,invalid.availability_weight,invalid.experience_weight,invalid.scale,invalid.cap),
      'P0001','matching.errors.invalid');
    perform pg_temp.matching_assert(salahly_private.matching_rules_snapshot() = before_rules,'invalid/overflow/NaN configuration leaves the versioned singleton unchanged');
  end loop;
  perform pg_temp.matching_expect_error('select salahly_private.configure_matching_rules(null,35,25,20,20,50,10)','P0001','matching.errors.invalid');
  perform pg_temp.matching_expect_error('select salahly_private.configure_matching_rules(0,35,25,20,20,50,10)','P0001','matching.errors.invalid');
  perform pg_temp.matching_expect_error(pg_catalog.format('select salahly_private.configure_matching_rules(%L,35,25,20,20,50,10)',revision + 1),
    'P0001','matching.errors.conflict');
  perform pg_temp.matching_expect_error('update public.matching_rules set neutral_bps = 4999','23514');
  perform pg_temp.matching_expect_error('update public.matching_rules set neutral_bps = 5001','23514');
  perform pg_temp.matching_expect_error('insert into public.matching_rules(singleton) values(false)','23514');
  perform pg_temp.matching_expect_error('insert into public.matching_rules(singleton) values(true)','23505');
end;
$configuration_validation$;

do $custom_weights_and_caps$
declare
  customer uuid := pg_catalog.current_setting('matching_test.customer_a')::uuid;
  request_id uuid := pg_catalog.current_setting('matching_test.request_main')::uuid;
  rules jsonb;
  result jsonb;
  near_item jsonb;
  far_item jsonb;
  mid_item jsonb;
  unknown_item jsonb;
  config record;
begin
  for config in select * from (values
    (350,250,200,200,50::numeric,10,8750,1250,5972,7500,5500),
    (0,7,0,0,50,10,5000,5000,5000,0,0),
    (1,0,0,0,1,10,10000,0,0,10000,10000),
    (0,0,0,1,50,60,1667,0,833,10000,10000),
    (7,5,3,2,50,10,8529,1471,6143,7059,5294),
    (0,0,0,1,50,1,10000,0,10000,10000,10000),
    (1,0,0,0,500,10,10000,8074,9778,10000,10000),
    (1000,1000,1000,1000,50,10,8750,1250,5694,7500,5000)
  ) as weights(distance_weight,rating_weight,availability_weight,experience_weight,scale,cap,near_score,far_score,mid_score,near_evidence,mid_evidence) loop
    rules := salahly_private.configure_matching_rules((salahly_private.matching_rules_snapshot() ->> 'revision')::integer,
      config.distance_weight,config.rating_weight,config.availability_weight,config.experience_weight,config.scale,config.cap);
    perform pg_temp.matching_assert(rules -> 'neutral_bps' = '5000'::jsonb,'configuration cannot choose an unfair missing-factor neutral');
    perform pg_temp.matching_login(customer);
    set local role authenticated;
    result := public.get_provider_matches(request_id,'recommended',30,31,true,1,480);
    perform pg_temp.matching_result_contract(result,request_id);
    near_item := pg_temp.matching_item(result,pg_catalog.current_setting('matching_test.near')::uuid);
    far_item := pg_temp.matching_item(result,pg_catalog.current_setting('matching_test.far')::uuid);
    mid_item := pg_temp.matching_item(result,pg_catalog.current_setting('matching_test.mid')::uuid);
    unknown_item := pg_temp.matching_item(result,pg_catalog.current_setting('matching_test.unknown')::uuid);
    perform pg_temp.matching_assert((near_item ->> 'score_bps')::integer = config.near_score
      and (far_item ->> 'score_bps')::integer = config.far_score and (mid_item ->> 'score_bps')::integer = config.mid_score
      and (near_item ->> 'evidence_bps')::integer = config.near_evidence and (mid_item ->> 'evidence_bps')::integer = config.mid_evidence
      and unknown_item -> 'score_bps' = '5000'::jsonb and unknown_item -> 'evidence_bps' = '0'::jsonb
      and pg_catalog.jsonb_array_length(result -> 'items') = 4,
      'normalized custom/zero/max weights, distance scale, experience cap, and unknown fairness preserve every eligible provider');
    set local role postgres;
    perform pg_temp.matching_assert(salahly_private.configure_matching_rules((rules ->> 'revision')::integer - 1,
      config.distance_weight,config.rating_weight,config.availability_weight,config.experience_weight,config.scale,config.cap) = rules,
      'exact configuration retry returns one canonical version without resetting populated settings');
  end loop;
  rules := salahly_private.configure_matching_rules((rules ->> 'revision')::integer,35,25,20,20,50,10);
  perform pg_catalog.set_config('matching_test.rules',rules::text,true);
end;
$custom_weights_and_caps$;

do $revision_limits$
declare
  provider uuid := pg_catalog.current_setting('matching_test.near')::uuid;
  profile jsonb := salahly_private.provider_matching_profile_snapshot(provider);
  rules jsonb := salahly_private.matching_rules_snapshot();
begin
  update public.provider_matching_profiles set revision = 2147483647 where provider_id = provider;
  perform pg_temp.matching_login(provider);
  set local role authenticated;
  perform pg_temp.matching_assert(public.get_provider_matching_profile() ->> 'revision' = '2147483647'
    and public.save_provider_matching_profile(true,30,31,profile -> 'experience_years',2147483646,true) ->> 'revision' = '2147483647',
    'maximum persisted profile revision is readable and exactly retryable without overflow');
  perform pg_temp.matching_expect_error(pg_temp.matching_save_sql(pg_catalog.jsonb_build_object('expected_revision',2147483647,
    'latitude',30,'longitude',31,'experience_years',profile -> 'experience_years')),'P0001','matching.errors.conflict');
  set local role postgres;
  update public.provider_matching_profiles set revision = (profile ->> 'revision')::integer where provider_id = provider;
  update public.matching_rules set revision = 2147483647 where singleton;
  perform pg_temp.matching_assert(salahly_private.configure_matching_rules(2147483646,35,25,20,20,50,10) ->> 'revision' = '2147483647',
    'maximum rules revision supports canonical retries');
  perform pg_temp.matching_expect_error('select salahly_private.configure_matching_rules(2147483647,35,25,20,20,50,10)',
    'P0001','matching.errors.conflict');
  update public.matching_rules set revision = (rules ->> 'revision')::integer where singleton;
end;
$revision_limits$;

create function pg_temp.matching_cursor(
  p_item jsonb, p_revision integer, p_request_id uuid, p_mode text,
  p_latitude numeric default null, p_longitude numeric default null, p_weekday integer default null, p_minute integer default null
)
returns jsonb language sql immutable security invoker set search_path = ''
as $function$
  select pg_catalog.jsonb_build_object('mode',p_mode,'before_score_bps',p_item -> 'score_bps',
    'before_tie_key',p_item -> 'tie_key','before_provider_id',p_item -> 'provider_id','rules_revision',p_revision,
    'before_query_key',pg_catalog.md5(p_request_id::text || ':' || p_mode || ':'
      || coalesce(pg_catalog.to_char(p_latitude,'FM990.00'),'') || ':' || coalesce(pg_catalog.to_char(p_longitude,'FM990.00'),'')
      || ':' || coalesce(p_weekday::text,'') || ':' || coalesce(p_minute::text,'')));
$function$;
grant execute on function pg_temp.matching_cursor(jsonb,integer,uuid,text,numeric,numeric,integer,integer) to authenticated;

create temporary table matching_test_candidates (provider_id uuid primary key) on commit drop;
grant select on pg_temp.matching_test_candidates to authenticated;
insert into pg_temp.matching_test_candidates select pg_catalog.current_setting('matching_test.' || key)::uuid
  from pg_catalog.unnest(array['near','far','mid','unknown']) as candidate(key);
do $pagination_fixtures$
declare
  provider uuid;
  category uuid := pg_catalog.current_setting('matching_test.category')::uuid;
  path text;
  verification jsonb;
  index_number integer;
begin
  for index_number in 1..52 loop
    provider := pg_catalog.gen_random_uuid();
    insert into auth.users(id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
      values(provider,'authenticated','authenticated','m8-page-' || provider::text || '@example.invalid',
        '{"provider":"email","providers":["email"]}'::jsonb,'{"full_name":"Page Provider","role":"provider"}'::jsonb,
        pg_catalog.now(),pg_catalog.now());
    perform pg_temp.matching_login(provider);
    set local role authenticated;
    perform public.save_provider_onboarding(provider,'PRIVATE-pagination onboarding fixture',array[category],array['Cairo'],
      '[{"weekday":1,"start_minute":0,"end_minute":60}]'::jsonb);
    path := provider::text || '/' || pg_catalog.replace(pg_catalog.gen_random_uuid()::text,'-','') || '.jpg';
    insert into storage.objects(bucket_id,name,owner_id,metadata)
      values('provider-verification',path,provider::text,'{"mimetype":"image/jpeg","size":1}'::jsonb);
    verification := public.submit_provider_verification(provider,path,true);
    set local role postgres;
    perform public.review_provider_verification((verification #>> '{verification,id}')::uuid,'verified',null,'rollback-reviewer');
    set local role authenticated;
    perform public.save_provider_onboarding(provider,'PRIVATE-pagination current fixture',array[category],array['Cairo'],'[]'::jsonb);
    perform public.save_provider_matching_profile(true,null,null,'{}'::jsonb,0,true);
    set local role postgres;
    insert into pg_temp.matching_test_candidates values(provider);
  end loop;
end;
$pagination_fixtures$;

select pg_temp.matching_login(pg_catalog.current_setting('matching_test.customer_a')::uuid);
set local role authenticated;
do $rotation_pagination_and_cursors$
declare
  request_id uuid := pg_catalog.current_setting('matching_test.request_main')::uuid;
  rotated_id uuid := pg_catalog.current_setting('matching_test.request_rotated')::uuid;
  mode text;
  page jsonb;
  next_page jsonb;
  cursor jsonb;
  expected uuid[];
  actual uuid[];
  rotated uuid[];
  revision integer;
  invalid record;
  forged uuid := pg_catalog.gen_random_uuid();
  item jsonb;
  rows_seen integer;
begin
  page := public.get_provider_matches(request_id);
  perform pg_temp.matching_assert(pg_catalog.jsonb_array_length(page -> 'items') = 20 and page -> 'has_more' = 'true'::jsonb,
    'default matching page is20 and reports further candidates');
  foreach mode in array array['recommended','all_eligible'] loop
    execute pg_temp.matching_query_sql(request_id,pg_catalog.jsonb_build_object('mode',mode,'limit',50)) into page;
    revision := (page #>> '{rules,revision}')::integer;
    cursor := pg_temp.matching_cursor(page #> '{items,49}',revision,request_id,mode);
    execute pg_temp.matching_query_sql(request_id,cursor || '{"limit":50}'::jsonb) into next_page;
    select pg_catalog.array_agg(provider_id order by case when mode = 'recommended' then
      case when provider_id = pg_catalog.current_setting('matching_test.near')::uuid then 6000
        when provider_id = pg_catalog.current_setting('matching_test.far')::uuid then 4000 else 5000 end end desc,
      pg_catalog.md5(request_id::text || ':' || provider_id::text),provider_id) into expected from pg_temp.matching_test_candidates;
    select pg_catalog.array_agg((value ->> 'provider_id')::uuid order by position) into actual
      from pg_catalog.jsonb_array_elements((page -> 'items') || (next_page -> 'items')) with ordinality as item(value,position);
    perform pg_temp.matching_assert(pg_catalog.jsonb_array_length(page -> 'items') = 50 and page -> 'has_more' = 'true'::jsonb
      and pg_catalog.jsonb_array_length(next_page -> 'items') = 6 and next_page -> 'has_more' = 'false'::jsonb
      and actual = expected, 'all56 candidates returned exactly once across50+6 with honest ordering: ' || mode);
    cursor := '{}'::jsonb;
    actual := '{}'::uuid[];
    loop
      execute pg_temp.matching_query_sql(request_id,cursor || pg_catalog.jsonb_build_object('mode',mode,'limit',1)) into page;
      rows_seen := pg_catalog.jsonb_array_length(page -> 'items');
      perform pg_temp.matching_assert(rows_seen = 1,'limit1 pages have no silent candidate truncation');
      actual := pg_catalog.array_append(actual,(page #>> '{items,0,provider_id}')::uuid);
      exit when page -> 'has_more' = 'false'::jsonb;
      cursor := pg_temp.matching_cursor(page #> '{items,0}',(page #>> '{rules,revision}')::integer,request_id,mode);
      if pg_catalog.cardinality(actual) > 56 then raise exception 'FAIL: matching cursor did not advance'; end if;
    end loop;
    perform pg_temp.matching_assert(actual = expected,'score/tie/provider keyset advances across every candidate: ' || mode);
    if mode = 'all_eligible' then
      select pg_catalog.array_agg(provider_id order by pg_catalog.md5(rotated_id::text || ':' || provider_id::text),provider_id)
        into rotated from pg_temp.matching_test_candidates;
      execute pg_temp.matching_query_sql(rotated_id,'{"mode":"all_eligible","limit":50}'::jsonb) into page;
      cursor := pg_temp.matching_cursor(page #> '{items,49}',(page #>> '{rules,revision}')::integer,rotated_id,mode);
      execute pg_temp.matching_query_sql(rotated_id,cursor || '{"limit":50}'::jsonb) into next_page;
      select pg_catalog.array_agg((value ->> 'provider_id')::uuid order by position) into actual
        from pg_catalog.jsonb_array_elements((page -> 'items') || (next_page -> 'items')) with ordinality as item(value,position);
      perform pg_temp.matching_assert(actual = rotated and actual <> expected,
        'tie rotation is request-specific, never name/registration/history/incumbency bias');
    end if;
  end loop;
  page := public.get_provider_matches(request_id);
  revision := (page #>> '{rules,revision}')::integer;
  item := pg_temp.matching_item(public.get_provider_matches(request_id,'recommended',null,null,false,null,null,null,null,null,null,null,50),
    pg_catalog.current_setting('matching_test.unknown')::uuid);
  -- The anchor itself may not be on the first50. Its valid wire fields can be
  -- obtained on a later bounded page, never by broadening object authorization.
  if item is null then
    cursor := pg_temp.matching_cursor(page #> '{items,19}',revision,request_id,'recommended');
    execute pg_temp.matching_query_sql(request_id,cursor || '{"limit":50}'::jsonb) into next_page;
    item := pg_temp.matching_item(next_page,pg_catalog.current_setting('matching_test.unknown')::uuid);
  end if;
  cursor := pg_temp.matching_cursor(item,revision,request_id,'recommended');
  perform pg_catalog.set_config('matching_test.cursor',cursor::text,true);
  for invalid in select * from (values
    ('{"before_score_bps":null}'::jsonb,'invalid'),('{"before_tie_key":null}'::jsonb,'invalid'),
    ('{"before_provider_id":null}'::jsonb,'invalid'),('{"rules_revision":null}'::jsonb,'invalid'),('{"before_query_key":null}'::jsonb,'invalid'),
    ('{"before_score_bps":-1}'::jsonb,'invalid'),('{"before_score_bps":10001}'::jsonb,'invalid'),
    (pg_catalog.jsonb_build_object('before_tie_key',pg_catalog.repeat('a',31)),'invalid'),
    (pg_catalog.jsonb_build_object('before_tie_key',pg_catalog.repeat('a',33)),'invalid'),
    (pg_catalog.jsonb_build_object('before_tie_key',pg_catalog.repeat('G',32)),'invalid'),
    (pg_catalog.jsonb_build_object('before_tie_key',pg_catalog.repeat('a',31) || E'\n'),'invalid'),
    (pg_catalog.jsonb_build_object('before_query_key',pg_catalog.repeat('a',31)),'invalid'),
    (pg_catalog.jsonb_build_object('before_query_key',pg_catalog.repeat('A',32)),'invalid'),
    ('{"rules_revision":0}'::jsonb,'invalid'),(pg_catalog.jsonb_build_object('rules_revision',revision + 1),'stale'),
    (pg_catalog.jsonb_build_object('before_tie_key',pg_catalog.md5('forged tie')),'invalid'),
    (pg_catalog.jsonb_build_object('before_query_key',pg_catalog.md5('other query')),'stale'),
    ('{"mode":"all_eligible"}'::jsonb,'stale'),('{"latitude":30,"longitude":31,"location_consent":true}'::jsonb,'stale'),
    ('{"weekday":1,"minute":480}'::jsonb,'stale')
  ) as change(payload,error_key) loop
    perform pg_temp.matching_expect_error(pg_temp.matching_query_sql(request_id,cursor || invalid.payload),
      'P0001','matching.errors.' || invalid.error_key);
  end loop;
  perform pg_temp.matching_expect_error(pg_temp.matching_query_sql(request_id,pg_catalog.jsonb_build_object('rules_revision',revision)),
    'P0001','matching.errors.invalid');
  perform pg_temp.matching_expect_error(pg_temp.matching_query_sql(request_id,pg_catalog.jsonb_build_object('before_query_key',cursor -> 'before_query_key')),
    'P0001','matching.errors.invalid');
  perform pg_temp.matching_expect_error(pg_temp.matching_query_sql(rotated_id,cursor),'P0001','matching.errors.invalid');
  execute pg_temp.matching_query_sql(request_id,cursor || pg_catalog.jsonb_build_object('before_score_bps',0,
    'before_provider_id',forged,'before_tie_key',pg_catalog.md5(request_id::text || ':' || forged::text))) into page;
  perform pg_temp.matching_assert(page -> 'items' = '[]'::jsonb and page -> 'has_more' = 'false'::jsonb,
    'well-formed forged cursor may skip rows but cannot authorize new ones');
  cursor := pg_temp.matching_cursor(pg_catalog.jsonb_build_object('score_bps',10000,'provider_id',forged,
    'tie_key',pg_catalog.md5(request_id::text || ':' || forged::text)),revision,request_id,'all_eligible');
  execute pg_temp.matching_query_sql(request_id,cursor || '{"limit":50}'::jsonb) into page;
  perform pg_temp.matching_assert(not exists (select 1 from pg_catalog.jsonb_array_elements(page -> 'items') as item(value)
    where not exists (select 1 from pg_temp.matching_test_candidates where provider_id = (value ->> 'provider_id')::uuid)),
    'all-eligible forged cursor changes ordering only, not eligibility or request ownership');
end;
$rotation_pagination_and_cursors$;
set local role postgres;

do $stale_rules_and_context$
declare
  customer uuid := pg_catalog.current_setting('matching_test.customer_a')::uuid;
  request_id uuid := pg_catalog.current_setting('matching_test.request_main')::uuid;
  cursor jsonb := pg_catalog.current_setting('matching_test.cursor')::jsonb;
  rules jsonb;
  page jsonb;
  item jsonb;
begin
  rules := salahly_private.configure_matching_rules((salahly_private.matching_rules_snapshot() ->> 'revision')::integer,35,25,20,20,50,10);
  perform pg_temp.matching_login(customer);
  set local role authenticated;
  perform pg_temp.matching_expect_error(pg_temp.matching_query_sql(request_id,cursor),'P0001','matching.errors.stale');
  page := public.get_provider_matches(request_id);
  perform pg_temp.matching_assert(page -> 'rules' = rules,'first page without a cursor always reads the current configuration');
  item := page #> '{items,0}';
  cursor := pg_temp.matching_cursor(item,(rules ->> 'revision')::integer,request_id,'recommended',30,31,1,480)
    || '{"latitude":30,"longitude":31,"location_consent":true,"weekday":1,"minute":480}'::jsonb;
  execute pg_temp.matching_query_sql(request_id,cursor) into page;
  perform pg_temp.matching_assert(pg_catalog.jsonb_typeof(page) = 'object','canonical supplied-point/wall-time query key is accepted');
  perform pg_temp.matching_expect_error(pg_temp.matching_query_sql(request_id,cursor || '{"weekday":2}'::jsonb),'P0001','matching.errors.stale');
  perform pg_temp.matching_expect_error(pg_temp.matching_query_sql(request_id,cursor || '{"minute":481}'::jsonb),'P0001','matching.errors.stale');
  perform pg_temp.matching_expect_error(pg_temp.matching_query_sql(request_id,cursor || '{"latitude":30.01}'::jsonb),'P0001','matching.errors.stale');
  set local role postgres;
end;
$stale_rules_and_context$;

-- Verify authorization failures independently of favorable fixture/ranking data.
grant select,insert,update,delete on storage.objects to authenticated,anon;
create policy salahly_matching_test_storage_all on storage.objects for all to public using(true) with check(true);
do $roles_direct_access_and_privacy$
declare
  key text;
  relation_name text;
  column_name text;
  request_id uuid := pg_catalog.current_setting('matching_test.request_main')::uuid;
  routine_sql text;
begin
  foreach key in array array['customer_a','customer_b','near','far'] loop
    perform pg_temp.matching_login(pg_catalog.current_setting('matching_test.' || key)::uuid);
    set local role authenticated;
    foreach relation_name in array array['provider_matching_profiles','matching_rules'] loop
      column_name := case when relation_name = 'provider_matching_profiles' then 'latitude' else 'distance_weight' end;
      perform pg_temp.matching_expect_error('select * from public.' || relation_name,'42501');
      perform pg_temp.matching_expect_error('select ' || column_name || ' from public.' || relation_name,'42501');
      perform pg_temp.matching_expect_error('insert into public.' || relation_name || ' default values','42501');
      perform pg_temp.matching_expect_error('update public.' || relation_name || ' set ' || column_name || ' = ' || column_name,'42501');
      perform pg_temp.matching_expect_error('delete from public.' || relation_name,'42501');
    end loop;
    perform pg_temp.matching_expect_error('select salahly_private.configure_matching_rules(1,35,25,20,20,50,10)','42501');
    perform pg_temp.matching_expect_error('select salahly_private.provider_can_quote(auth.uid(),null)','42501');
    perform pg_temp.matching_expect_error('select salahly_private.provider_matching_profile_snapshot(auth.uid())','42501');
    if key like 'customer%' then
      perform pg_temp.matching_expect_error('select public.get_provider_matching_profile()','42501','matching.errors.access');
      perform pg_temp.matching_expect_error(pg_temp.matching_save_sql(),'42501','matching.errors.access');
      if key = 'customer_b' then
        perform pg_temp.matching_expect_error(pg_temp.matching_query_sql(request_id),'P0001','matching.errors.not_found');
      end if;
    else
      perform pg_temp.matching_assert(public.get_provider_matching_profile() ->> 'provider_id' = auth.uid()::text,
        'provider profile RPC has no caller-supplied foreign identifier');
      perform pg_temp.matching_expect_error(pg_temp.matching_query_sql(request_id),'42501','matching.errors.access');
      perform pg_temp.matching_assert(not exists(select 1 from public.service_requests)
        and not exists(select 1 from public.service_request_photos)
        and not exists(select 1 from storage.objects where bucket_id = 'request-photos'),
        'provider cannot obtain request points/private requests/photos even with hostile broad Storage policy');
    end if;
    set local role postgres;
  end loop;
  perform pg_temp.matching_login(null);
  set local role authenticated;
  perform pg_temp.matching_expect_error('select public.get_provider_matching_profile()','42501','matching.errors.access');
  perform pg_temp.matching_expect_error(pg_temp.matching_save_sql(),'42501','matching.errors.access');
  perform pg_temp.matching_expect_error(pg_temp.matching_query_sql(request_id),'42501','matching.errors.access');
  set local role postgres;
  foreach key in array array['anon','service_role'] loop
    execute pg_catalog.format('set local role %I',key);
    foreach relation_name in array array['provider_matching_profiles','matching_rules'] loop
      perform pg_temp.matching_expect_error('select * from public.' || relation_name,'42501');
      perform pg_temp.matching_expect_error('insert into public.' || relation_name || ' default values','42501');
    end loop;
    foreach routine_sql in array array['select public.get_provider_matching_profile()',pg_temp.matching_save_sql(),
      pg_temp.matching_query_sql(request_id),'select salahly_private.configure_matching_rules(1,35,25,20,20,50,10)'] loop
      perform pg_temp.matching_expect_error(routine_sql,'42501');
    end loop;
    set local role postgres;
  end loop;
  update public.profiles set role = 'customer' where id = pg_catalog.current_setting('matching_test.far')::uuid;
  perform pg_temp.matching_login(pg_catalog.current_setting('matching_test.far')::uuid);
  set local role authenticated;
  perform pg_temp.matching_expect_error('select public.get_provider_matching_profile()','42501','matching.errors.access');
  perform pg_temp.matching_expect_error(pg_temp.matching_save_sql(),'42501','matching.errors.access');
  set local role postgres;
  update public.profiles set role = 'provider' where id = pg_catalog.current_setting('matching_test.far')::uuid;
end;
$roles_direct_access_and_privacy$;

-- Column ACLs do not disappear with a table REVOKE. Probe both separate grants
-- and deny-all RLS, then invoke the exact security repair used by the migration.
grant select(latitude),update(longitude),references(provider_id) on public.provider_matching_profiles to authenticated,anon;
grant select(distance_weight),update(rating_weight) on public.matching_rules to authenticated,anon;
select pg_temp.matching_login(pg_catalog.current_setting('matching_test.near')::uuid);
set local role authenticated;
select pg_temp.matching_assert((select pg_catalog.count(latitude) from public.provider_matching_profiles) = 0
  and (select pg_catalog.count(distance_weight) from public.matching_rules) = 0,
  'column-only SELECT ACL drift still reveals no RLS rows');
set local role postgres;
grant select,insert,update,delete on public.provider_matching_profiles,public.matching_rules to authenticated,anon;
do $independent_rls$
declare
  api_role text;
  affected integer;
begin
  foreach api_role in array array['authenticated','anon'] loop
    execute pg_catalog.format('set local role %I',api_role);
    perform pg_temp.matching_assert(not exists(select 1 from public.provider_matching_profiles)
      and not exists(select 1 from public.matching_rules),'deny-all RLS blocks ALL new base rows despite broad table/column grants: ' || api_role);
    perform pg_temp.matching_expect_error('insert into public.provider_matching_profiles(provider_id,provider_name) values(auth.uid(),''Own forged row'')','42501');
    perform pg_temp.matching_expect_error('insert into public.matching_rules(singleton) values(true)','42501');
    update public.provider_matching_profiles set discoverable = false;
    get diagnostics affected = row_count;
    perform pg_temp.matching_assert(affected = 0,'RLS filters even owned UPDATE under adversarial grants');
    delete from public.provider_matching_profiles;
    get diagnostics affected = row_count;
    perform pg_temp.matching_assert(affected = 0,'RLS filters DELETE under adversarial grants');
    set local role postgres;
  end loop;
end;
$independent_rls$;
select salahly_private.restore_matching_security();

do $acl_schema_default_repair$
declare
  profiles_before jsonb;
  rules_before jsonb := salahly_private.matching_rules_snapshot();
  api_role text;
  relation_name text;
begin
  select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(preferences) order by provider_id) into profiles_before
    from public.provider_matching_profiles as preferences;
  grant all privileges on public.provider_matching_profiles,public.matching_rules to public,anon,authenticated,service_role;
  grant select(latitude),update(provider_name),references(provider_id) on public.provider_matching_profiles to public,anon,authenticated,service_role;
  grant select(distance_scale_km),update(neutral_bps) on public.matching_rules to public,anon,authenticated,service_role;
  alter table public.provider_matching_profiles disable row level security;
  alter table public.matching_rules disable row level security;
  grant all privileges on schema salahly_private to public,anon,authenticated,service_role;
  grant create on schema public to public,anon,authenticated,service_role;
  grant execute on function salahly_private.configure_matching_rules(integer,integer,integer,integer,integer,numeric,integer),
    salahly_private.provider_matching_profile_snapshot(uuid),salahly_private.restore_matching_security() to public,anon,authenticated,service_role;
  alter default privileges for role postgres in schema public,salahly_private grant all privileges on tables to anon,authenticated,service_role;
  alter default privileges for role postgres in schema public,salahly_private grant all privileges on functions to anon,authenticated,service_role;
  perform salahly_private.restore_matching_security();
  perform pg_temp.matching_assert((select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(preferences) order by provider_id)
    from public.provider_matching_profiles as preferences) = profiles_before and salahly_private.matching_rules_snapshot() = rules_before,
    'security repair preserves every populated preference, consent/name/time/revision, and custom configuration');
  foreach api_role in array array['anon','authenticated','service_role'] loop
    foreach relation_name in array array['provider_matching_profiles','matching_rules'] loop
      perform pg_temp.matching_assert(not pg_catalog.has_table_privilege(api_role,'public.' || relation_name,
        'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') and not pg_catalog.has_any_column_privilege(api_role,
          'public.' || relation_name,'SELECT,INSERT,UPDATE,REFERENCES') and (select relrowsecurity from pg_catalog.pg_class
            where oid = ('public.' || relation_name)::regclass), 'table/column/default/RLS drift repaired without client grants: ' || api_role || '/' || relation_name);
    end loop;
    perform pg_temp.matching_assert(not pg_catalog.has_function_privilege(api_role,
      'salahly_private.configure_matching_rules(integer,integer,integer,integer,integer,numeric,integer)','EXECUTE')
      and not pg_catalog.has_function_privilege(api_role,'salahly_private.provider_matching_profile_snapshot(uuid)','EXECUTE')
      and not pg_catalog.has_schema_privilege(api_role,'public','CREATE')
      and not pg_catalog.has_schema_privilege(api_role,'salahly_private','CREATE'), 'configuration/internal function/schema CREATE drift repaired');
  end loop;
  create table public.matching_test_default_probe(id integer);
  perform pg_temp.matching_assert(not pg_catalog.has_table_privilege('anon','public.matching_test_default_probe','SELECT,INSERT,UPDATE,DELETE')
    and not pg_catalog.has_table_privilege('authenticated','public.matching_test_default_probe','SELECT,INSERT,UPDATE,DELETE')
    and not pg_catalog.has_table_privilege('service_role','public.matching_test_default_probe','SELECT,INSERT,UPDATE,DELETE'),
    'restored public table defaults do not create an alternate client API');
  drop table public.matching_test_default_probe;
end;
$acl_schema_default_repair$;

-- Every hostile DDL probe is inside an expected-error subtransaction. Unknown
-- policies are rejected, not dropped or combined with permissive client access.
select pg_temp.matching_expect_error($probe$do $drift$ begin
  create policy unexpected_matching_access on public.provider_matching_profiles for select to public using(true);
  perform salahly_private.restore_matching_security();
end; $drift$;$probe$,'P0001','matching.errors.invalid');
select pg_temp.matching_expect_error($probe$do $drift$ begin
  create policy unexpected_rules_access on public.matching_rules for all to authenticated using(true) with check(true);
  perform salahly_private.validate_matching_integrity();
end; $drift$;$probe$,'P0001','matching.errors.invalid');
select pg_temp.matching_expect_error($probe$do $drift$ begin
  alter table public.matching_rules drop constraint matching_rules_values_check;
  perform salahly_private.validate_matching_integrity();
end; $drift$;$probe$,'P0001','matching.errors.invalid');
select pg_temp.matching_expect_error($probe$do $drift$ begin
  alter table public.matching_rules drop constraint matching_rules_values_check;
  alter table public.matching_rules add constraint matching_rules_values_check check(true);
  perform salahly_private.validate_matching_integrity();
end; $drift$;$probe$,'P0001','matching.errors.invalid');
select pg_temp.matching_expect_error($probe$do $drift$ begin
  alter table public.provider_matching_profiles drop constraint provider_matching_profiles_location_check;
  alter table public.provider_matching_profiles add constraint provider_matching_profiles_location_check check(true);
  perform salahly_private.validate_matching_integrity();
end; $drift$;$probe$,'P0001','matching.errors.invalid');
select pg_temp.matching_expect_error($probe$do $drift$ begin
  alter table public.provider_matching_profiles drop constraint provider_matching_profiles_name_check;
  alter table public.provider_matching_profiles add constraint provider_matching_profiles_name_check check(true);
  perform salahly_private.validate_matching_integrity();
end; $drift$;$probe$,'P0001','matching.errors.invalid');
select pg_temp.matching_expect_error($probe$do $drift$ begin
  alter table public.provider_matching_profiles alter column latitude type numeric(5,2);
  perform salahly_private.validate_matching_integrity();
end; $drift$;$probe$,'P0001','matching.errors.invalid');
select pg_temp.matching_expect_error($probe$do $drift$ begin
  alter table public.provider_matching_profiles drop constraint provider_matching_profiles_consent_check;
  alter table public.provider_matching_profiles add constraint provider_matching_profiles_consent_check check(true);
  perform salahly_private.validate_matching_integrity();
end; $drift$;$probe$,'P0001','matching.errors.invalid');
select pg_temp.matching_expect_error($probe$do $drift$ begin
  alter table public.matching_rules add column unreviewed_factor integer;
  perform salahly_private.validate_matching_integrity();
end; $drift$;$probe$,'P0001','matching.errors.invalid');
select pg_temp.matching_expect_error($probe$do $drift$ begin
  alter table public.matching_rules alter column distance_weight drop not null;
  perform salahly_private.validate_matching_integrity();
end; $drift$;$probe$,'P0001','matching.errors.invalid');
select pg_temp.matching_expect_error($probe$do $drift$ begin
  alter table public.provider_matching_profiles drop constraint provider_matching_profiles_provider_id_fkey;
  perform salahly_private.validate_matching_integrity();
end; $drift$;$probe$,'P0001','matching.errors.invalid');
select pg_temp.matching_expect_error($probe$do $drift$ begin
  delete from public.matching_rules;
  perform salahly_private.validate_matching_integrity();
end; $drift$;$probe$,'P0001','matching.errors.invalid');
select salahly_private.validate_matching_integrity();

do $complete$
begin
  perform salahly_private.validate_matching_integrity();
  perform pg_temp.matching_assert(not exists(select 1 from pg_catalog.pg_policies where schemaname = 'public'
    and tablename in ('provider_matching_profiles','matching_rules','request_marketplace_listings','provider_quotes','service_jobs','job_status_history'))
    and (select pg_catalog.count(*) from pg_catalog.pg_policies where schemaname = 'public'
      and tablename in ('service_requests','service_request_photos')) = 2, 'drift probes leave all new/M7/M6 authorization boundaries intact');
  raise notice 'PASS: all Salahly smart matching authorization/scoring SQL checks passed; rolling back every fixture.';
end;
$complete$;
rollback;
