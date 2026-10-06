begin;

-- Scope payroll by employee membership on the server. Viewing payroll does not
-- require permission to inspect the separate user/branch assignment table.
create or replace function private.list_salary_records_authorized_v3(input jsonb)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare actor uuid:=auth.uid(); enabled boolean:=false;
  loc uuid:=nullif(input->>'location_id','')::uuid;
begin
  if not coalesce(private.actor_is_active_v1(),false) then
    raise exception using errcode='42501',message='ACTIVE_PROFILE_REQUIRED';
  end if;
  if to_regprocedure('private.access_v2_enabled(uuid)') is not null then
    enabled:=private.access_v2_enabled(actor);
  end if;
  if not enabled then
    raise exception using errcode='42501',message='SALARY_AUTHORIZATION_V2_REQUIRED';
  end if;
  if loc is not null and not coalesce(private.has_location_access(actor,loc),false) then
    raise exception using errcode='42501',message='LOCATION_FORBIDDEN';
  end if;
  -- Legacy foundations use the original caller RLS; v2 uses explicit row
  -- authorization with the same branch and payroll permission predicates.
  if enabled then
    return (select coalesce(jsonb_agg(x.row_data order by x.created_at desc,x.id),'[]'::jsonb)
      from (select sr.id,sr.created_at,to_jsonb(sr)||jsonb_build_object('profiles',
        case when private.access_v2_visible('profiles',to_jsonb(p),false)
          then jsonb_build_object('display_name',p.display_name) else null end) row_data
        from public.salary_records sr left join public.profiles p on p.id=sr.user_id
        where private.access_v2_visible('salary_records',to_jsonb(sr),false)
          and (loc is null or exists(select 1 from public.profile_locations a
            where a.profile_id=sr.user_id and a.location_id=loc and a.can_view)
            or (sr.user_id=actor and private.access_v2_primary(actor)))
          and (nullif(input->>'id','') is null or sr.id=(input->>'id')::uuid)
          and (nullif(input->>'user_id','') is null or sr.user_id=(input->>'user_id')::uuid)
          and (nullif(input->>'status','') is null or sr.status=input->>'status')
          and (nullif(input->>'period_start','') is null or sr.period_start>=(input->>'period_start')::date)
          and (nullif(input->>'period_end','') is null or sr.period_end<=(input->>'period_end')::date)
      ) x);
  end if;
end $$;

-- Legacy salary rows still use their original RLS. Only their branch-membership
-- predicate needs an owner read, limited to employees whose salary may be read.
create or replace function private.employee_in_salary_branch_v3(employee uuid,location uuid)
returns boolean language plpgsql stable security definer set search_path='' as $$
declare actor uuid:=auth.uid();
begin
  if not coalesce(private.actor_is_active_v1(),false)
    or not (coalesce(private.has_permission(actor,'manageSalaries'),false)
      or (employee=actor and coalesce(private.has_permission(actor,'viewOwnSalary'),false))) then
    return false;
  end if;
  if location is null then return true; end if;
  if not coalesce(private.has_location_access(actor,location),false) then return false; end if;
  if employee=actor and to_regprocedure('private.access_v2_primary(uuid)') is not null then
    if private.access_v2_primary(actor) then return true; end if;
  end if;
  return exists(select 1 from public.profile_locations a
    where a.profile_id=employee and a.location_id=location and a.can_view);
end $$;

-- An invoker helper retains every legacy policy rather than duplicating them
-- inside an owner function. Called through an invoker public RPC for legacy users.
create or replace function private.list_salary_records_legacy_v3(input jsonb)
returns jsonb language sql stable security invoker set search_path='' as $$
  select coalesce(jsonb_agg(x.row_data order by x.created_at desc,x.id),'[]'::jsonb)
  from (select sr.id,sr.created_at,to_jsonb(sr)||jsonb_build_object('profiles',
      case when p.id is not null then jsonb_build_object('display_name',p.display_name) else null end) row_data
    from public.salary_records sr left join public.profiles p on p.id=sr.user_id
    where private.employee_in_salary_branch_v3(sr.user_id,nullif(input->>'location_id','')::uuid)
      and (nullif(input->>'id','') is null or sr.id=(input->>'id')::uuid)
      and (nullif(input->>'user_id','') is null or sr.user_id=(input->>'user_id')::uuid)
      and (nullif(input->>'status','') is null or sr.status=input->>'status')
      and (nullif(input->>'period_start','') is null or sr.period_start>=(input->>'period_start')::date)
      and (nullif(input->>'period_end','') is null or sr.period_end<=(input->>'period_end')::date)
  ) x;
$$;

-- Split the API into an invoker entry point and a guarded owner v2 read. This
-- ensures the legacy helper executes as the actual caller, retaining RLS.
create or replace function public.list_salary_records_v3(input jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security invoker set search_path='' as $$
begin
  if to_regprocedure('private.access_v2_enabled(uuid)') is not null then
    if private.access_v2_enabled(auth.uid()) then
      return private.list_salary_records_authorized_v3(input);
    end if;
  end if;
  if not coalesce(private.actor_is_active_v1(),false) then
    raise exception using errcode='42501',message='ACTIVE_PROFILE_REQUIRED';
  end if;
  if nullif(input->>'location_id','') is not null
    and not coalesce(private.has_location_access(auth.uid(),(input->>'location_id')::uuid),false) then
    raise exception using errcode='42501',message='LOCATION_FORBIDDEN';
  end if;
  return private.list_salary_records_legacy_v3(input);
end $$;
revoke all on function private.list_salary_records_authorized_v3(jsonb),
  private.list_salary_records_legacy_v3(jsonb),private.employee_in_salary_branch_v3(uuid,uuid),
  public.list_salary_records_v3(jsonb)
  from public,anon,authenticated;
grant execute on function private.list_salary_records_authorized_v3(jsonb),
  private.list_salary_records_legacy_v3(jsonb),private.employee_in_salary_branch_v3(uuid,uuid),
  public.list_salary_records_v3(jsonb) to authenticated;

do $$ begin
  if to_regclass('private.access_v2_rpc_registry') is not null then
    insert into private.access_v2_rpc_registry(signature,function_oid,original_definition)
      values('list_salary_records_v3(jsonb)','public.list_salary_records_v3(jsonb)'::regprocedure,
        pg_get_functiondef('public.list_salary_records_v3(jsonb)'::regprocedure))
      on conflict(signature) do update set function_oid=excluded.function_oid,
        original_definition=excluded.original_definition;
  end if;
end $$;

notify pgrst,'reload schema';
commit;
