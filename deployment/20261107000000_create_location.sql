begin;

-- INSERT ... RETURNING runs the location SELECT policy before the stable
-- location-access helper can see the new row. Return it from a checked command
-- instead, without weakening SELECT policies or changing existing memberships.
create or replace function public.create_location_v1(input jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); enabled boolean:=false; created public.locations%rowtype;
begin
  if not coalesce(private.actor_is_active_v1(),false) then
    raise exception using errcode='42501',message='ACTIVE_PROFILE_REQUIRED';
  end if;
  if to_regprocedure('private.access_v2_enabled(uuid)') is not null then
    enabled:=private.access_v2_enabled(actor);
  end if;
  if enabled then
    perform private.access_v2_require('location.create');
  else
    if not coalesce(private.has_permission(actor,'manageLocations'),false) then
      raise exception using errcode='42501',message='LOCATION_FORBIDDEN';
    end if;
    if to_regprocedure('private.branch_scope_restricted(uuid)') is not null then
      if private.branch_scope_restricted(actor) then
        raise exception using errcode='42501',message='LOCATION_FORBIDDEN';
      end if;
    end if;
  end if;
  if nullif(btrim(input->>'code'),'') is null
    or nullif(btrim(input->>'name_ar'),'') is null
    or nullif(btrim(input->>'name_en'),'') is null then
    raise exception using errcode='22023',message='LOCATION_FIELDS_REQUIRED';
  end if;
  insert into public.locations(code,name_ar,name_en,is_main,is_active)
    values(upper(btrim(input->>'code')),btrim(input->>'name_ar'),btrim(input->>'name_en'),
      coalesce((input->>'is_main')::boolean,false),coalesce((input->>'is_active')::boolean,true))
    returning * into created;
  return to_jsonb(created);
end $$;
revoke all on function public.create_location_v1(jsonb) from public,anon;
grant execute on function public.create_location_v1(jsonb) to authenticated;

do $$ begin
  if to_regclass('private.access_v2_rpc_registry') is not null then
    insert into private.access_v2_rpc_registry(signature,function_oid,original_definition)
      values('create_location_v1(jsonb)','public.create_location_v1(jsonb)'::regprocedure,
        pg_get_functiondef('public.create_location_v1(jsonb)'::regprocedure))
      on conflict(signature) do update set function_oid=excluded.function_oid,
        original_definition=excluded.original_definition;
  end if;
end $$;

notify pgrst,'reload schema';
commit;
