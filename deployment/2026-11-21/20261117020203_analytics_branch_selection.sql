-- Add a branch subset to the existing report RPCs. Their per-row access checks
-- still decide which branches the caller can read.
do $migration$
declare
  rpc regprocedure;
  definition text;
  scoped_definition text;
  location_filter constant text := $pattern$\(loc is null or ([a-z]+)\.location_id\s*=\s*loc\)$pattern$;
begin
  foreach rpc in array array[
    'public.accounting_profit_v1(jsonb)'::regprocedure,
    'public.accounting_sales_series_v1(jsonb)'::regprocedure,
    'public.accounting_product_profit_v1(jsonb)'::regprocedure
  ] loop
    definition := pg_get_functiondef(rpc);
    if position('selected_branches uuid[]' in definition) > 0 then
      continue;
    end if;
    scoped_definition := regexp_replace(definition, location_filter,
      $replace$(loc is null or \1.location_id=loc) and (selected_branches is null or \1.location_id=any(selected_branches))$replace$, 'gi');
    if scoped_definition = definition then
      raise exception 'Missing branch filter in %', rpc;
    end if;
    scoped_definition := regexp_replace(scoped_definition, '\mdeclare\M',
      $replace$declare selected_branches uuid[] := (
        select array_agg(value::uuid) from jsonb_array_elements_text(input->'location_ids')
      );$replace$, 'i');
    execute scoped_definition;
  end loop;
end;
$migration$;
