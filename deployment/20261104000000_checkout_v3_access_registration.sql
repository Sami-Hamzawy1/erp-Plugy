begin;

-- These checkout APIs enforce active-account, branch and action permissions
-- inside their implementations. Register them so v2 activation can audit them.
do $$
declare rpc_signature text;
begin
  if to_regclass('private.access_v2_rpc_registry') is null then return; end if;
  foreach rpc_signature in array array[
    'installation_services_v3(jsonb)',
    'installation_quotes_v3(jsonb)',
    'remove_treasury_account_v3(jsonb)',
    'list_payment_methods_v3(uuid,boolean)',
    'list_salary_records_v3(jsonb)'
  ] loop
    insert into private.access_v2_rpc_registry(signature,function_oid,original_definition)
    values(rpc_signature,('public.'||rpc_signature)::regprocedure,
      pg_get_functiondef(('public.'||rpc_signature)::regprocedure))
    on conflict(signature) do update set
      function_oid=excluded.function_oid, original_definition=excluded.original_definition;
  end loop;
  -- Service catalog access is through its checked RPC, with no direct table API.
  if not exists(select 1 from pg_policies where schemaname='public'
    and tablename='installation_services' and policyname='access_v2_guard_select') then
    create policy access_v2_guard_select on public.installation_services
      as restrictive for select to authenticated using(false);
  end if;
end $$;

notify pgrst,'reload schema';
commit;
