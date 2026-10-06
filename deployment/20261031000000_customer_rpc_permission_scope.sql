begin;

-- Customer actions are global permissions. Their RPCs carry a branch for
-- customer membership/search; that branch must not become the permission scope.
-- Validate the branch independently without broadening any role grants.
do $$
declare definition text; routine text; patched boolean:=false;
  original text:='elsif operation=''search_customers_v1'' then loc:=nullif(args->>1,'''')::uuid;';
  replacement text:='elsif operation in (''search_customers_v1'',''create_customer_v1'') then
  other:=case when operation=''create_customer_v1'' then nullif(data->>''location_id'','''')::uuid
    else nullif(args->>1,'''')::uuid end;
  if other is null or not private.branch_scope_location(actor,other) then
    raise exception using errcode=''42501'',message=''LOCATION_FORBIDDEN'';
  end if;
  loc:=null;';
begin
  if to_regprocedure('private.branch_scope_location(uuid,uuid,boolean)') is null then
    raise exception 'CUSTOMER_RPC_SCOPE_REQUIRES_BRANCH_CONFINEMENT';
  end if;
  -- Migration 27 preserves the original permission guard under this name.
  -- Also support the direct guard if it still contains the original body.
  foreach routine in array array['private.access_v2_rpc_guard(text,jsonb)',
    'private.branch_scope_base_access_v2_rpc_guard(text,jsonb)'] loop
    if to_regprocedure(routine) is null then continue; end if;
    select pg_get_functiondef(to_regprocedure(routine)) into definition;
    if position(original in definition)>0 then
      execute replace(definition,original,replacement);
      patched:=true;
    elsif position(replacement in definition)>0 then
      patched:=true;
    end if;
  end loop;
  if not patched then raise exception 'CUSTOMER_RPC_SCOPE_GUARD_INCOMPATIBLE'; end if;
end $$;

notify pgrst,'reload schema';
commit;
