-- A stale revision requires a fresh client snapshot. PostgREST can retry SQLSTATE
-- 40001 automatically, so return HTTP 409 while preserving the conflict message.
do $migration$
declare
  rpc regprocedure;
  definition text;
  patched_definition text;
  conflict_pattern constant text := $pattern$errcode\s*=\s*'40001'\s*,\s*message\s*=\s*'ACCESS_REVISION_CONFLICT'$pattern$;
  conflict_response constant text := $$errcode='PT409',message='ACCESS_REVISION_CONFLICT'$$;
begin
  foreach rpc in array array[
    'public.admin_access_command_v2(jsonb)'::regprocedure,
    'public.access_effective_preview_v2(uuid,text)'::regprocedure
  ] loop
    -- Patch the deployed body so branch scope and permission checks are preserved.
    definition := pg_get_functiondef(rpc);
    patched_definition := regexp_replace(definition, conflict_pattern, conflict_response, 'gi');

    if patched_definition <> definition then
      execute patched_definition;
    elsif position(conflict_response in definition) = 0 then
      raise exception 'Access revision conflict handler missing in %', rpc;
    end if;
  end loop;
end;
$migration$;
