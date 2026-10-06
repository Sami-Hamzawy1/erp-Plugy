begin;

-- The catalog is shared, but v2 read permission is scoped to a branch.
-- Direct SELECT cannot supply that branch because catalog rows have no location.
create or replace function public.list_payment_methods_v3(
  location_id uuid default null, active_only boolean default true)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare actor uuid:=auth.uid(); enabled boolean:=false;
begin
  if not coalesce(private.actor_is_active_v1(),false) then
    raise exception using errcode='42501',message='ACTIVE_PROFILE_REQUIRED';
  end if;
  if to_regprocedure('private.access_v2_enabled(uuid)') is not null then
    enabled:=private.access_v2_enabled(actor);
  end if;
  if enabled then
    perform private.access_v2_require('payment_method.read',$1);
  end if;
  if $1 is not null and not coalesce(private.has_location_access(actor,$1),false) then
    raise exception using errcode='42501',message='LOCATION_FORBIDDEN';
  end if;
  return (select coalesce(jsonb_agg(to_jsonb(m) order by m.sort_order,m.name_en,m.id),'[]'::jsonb)
    from public.payment_methods m where not coalesce($2,true) or m.is_active);
end $$;
revoke all on function public.list_payment_methods_v3(uuid,boolean) from public,anon;
grant execute on function public.list_payment_methods_v3(uuid,boolean) to authenticated;

-- Register the explicitly guarded API when v2 is installed. Fresh foundations
-- use the same RPC with the existing active-user and branch checks.
do $$ begin
  if to_regclass('private.access_v2_rpc_registry') is not null then
    insert into private.access_v2_rpc_registry(signature,function_oid,original_definition)
      values('list_payment_methods_v3(uuid,boolean)',
        'public.list_payment_methods_v3(uuid,boolean)'::regprocedure,
        pg_get_functiondef('public.list_payment_methods_v3(uuid,boolean)'::regprocedure))
      on conflict(signature) do update set function_oid=excluded.function_oid,
        original_definition=excluded.original_definition;
  end if;
end $$;

notify pgrst,'reload schema';
commit;
