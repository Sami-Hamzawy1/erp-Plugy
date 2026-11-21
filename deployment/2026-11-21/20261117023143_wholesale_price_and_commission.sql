begin;

alter table public.products add column if not exists wholesale_min_price numeric(14,2)
  check (wholesale_min_price >= 0 and wholesale_min_price < 'Infinity'::numeric);
alter table public.products add column if not exists wholesale_commission_percent numeric(5,2)
  check (wholesale_commission_percent between 0 and 100);

-- Preserve the same restrictions as the corresponding retail settings for
-- direct edits and for inserts performed by the inventory product commands.
create function private.guard_product_wholesale_terms()
returns trigger language plpgsql security definer set search_path = '' as $function$
begin
  if current_setting('role', true) <> 'authenticated' or not private.access_v2_enabled(auth.uid()) then
    return new;
  end if;
  if new.wholesale_min_price is distinct from
      (case when tg_op = 'UPDATE' then old.wholesale_min_price end) then
    perform private.access_v2_require('product_minimum_price.update');
  end if;
  if new.wholesale_commission_percent is distinct from
      (case when tg_op = 'UPDATE' then old.wholesale_commission_percent end) then
    perform private.access_v2_require('product_commission.update');
  end if;
  return new;
end;
$function$;
revoke all on function private.guard_product_wholesale_terms() from public, anon, authenticated;
create trigger guard_product_wholesale_terms before insert or update on public.products
  for each row execute function private.guard_product_wholesale_terms();

-- Extend the current read projection with the existing field-level controls.
do $migration$
declare definition text;
begin
  definition := pg_get_viewdef('public.access_v2_products'::regclass, true);
  definition := regexp_replace(definition, $pattern$(\s+FROM (public\.)?products r\M)$pattern$,
    $replacement$,
    CASE WHEN private.access_v2_allows(auth.uid(), 'product_minimum_price.read', null)
      THEN r.wholesale_min_price ELSE null::numeric END AS wholesale_min_price,
    CASE WHEN private.access_v2_allows(auth.uid(), 'product_commission.read', null)
      THEN r.wholesale_commission_percent ELSE null::numeric END AS wholesale_commission_percent\1$replacement$, 'i');
  if position('AS wholesale_min_price' in definition) = 0 then
    raise exception 'PRODUCT_ACCESS_PROJECTION_REQUIRED';
  end if;
  execute 'create or replace view public.access_v2_products with(security_barrier=true) as ' || definition;
end;
$migration$;

-- Extend both product stock writers so a price change and inventory change
-- share the original transaction and authorization checks.
do $migration$
declare
  rpc regprocedure;
  definition text;
  patched text;
begin
  foreach rpc in array array[
    'private.access_v2_impl_save_product_stock_edit_v1(uuid,jsonb,numeric,numeric)'::regprocedure,
    'private.branch_scope_stock_edit_impl(uuid,jsonb,uuid,numeric,numeric)'::regprocedure,
    'private.access_v2_impl_create_product_with_inventory_v1(jsonb)'::regprocedure,
    'private.branch_scope_create_product_impl(jsonb,uuid)'::regprocedure
  ] loop
    definition := pg_get_functiondef(rpc);
    patched := replace(definition, '''commission_percent'',''is_active''',
        '''commission_percent'',''wholesale_min_price'',''wholesale_commission_percent'',''is_active''');
    if patched = definition then raise exception 'PRODUCT_WRITER_REQUIRED: %', rpc; end if;
    if position('commission_percent=patched.commission_percent' in patched) > 0 then
      patched := replace(patched, 'commission_percent=patched.commission_percent,',
        'commission_percent=patched.commission_percent,wholesale_min_price=patched.wholesale_min_price,wholesale_commission_percent=patched.wholesale_commission_percent,');
    elsif position('coalesce(product.commission_percent,0),' in patched)>0 then
      patched := replace(patched, 'commission_percent,is_active,stock',
        'commission_percent,wholesale_min_price,wholesale_commission_percent,is_active,stock');
      patched := replace(patched, 'coalesce(product.commission_percent,0),',
        'coalesce(product.commission_percent,0),product.wholesale_min_price,product.wholesale_commission_percent,');
    else
      raise exception 'PRODUCT_VALUE_WRITER_REQUIRED: %', rpc;
    end if;
    execute patched;
  end loop;
end;
$migration$;

-- Patch the validator wherever the fees/installation wrappers retained it.
-- Unconfigured wholesale terms inherit the product's existing retail values.
do $migration$
declare
  rpc regprocedure;
  definition text;
  matched int := 0;
begin
  for rpc in select oid::regprocedure from pg_proc
    where pronamespace in ('private'::regnamespace,'public'::regnamespace)
      and prosrc like '%MINIMUM_PRICE_VIOLATION%'
      and (prosrc like '%<p.min_price%' or prosrc like '%< product_row.min_price%')
  loop
    definition := pg_get_functiondef(rpc);
    definition := replace(definition, '<p.min_price',
      '<(case when sale_input->>''sale_type''=''wholesale'' then coalesce(p.wholesale_min_price,p.min_price) else p.min_price end)');
    execute replace(definition, 'product_row.min_price',
      '(case when sale_type_value=''wholesale'' then coalesce(product_row.wholesale_min_price,product_row.min_price) else product_row.min_price end)');
    matched := matched + 1;
  end loop;
  if matched = 0 then raise exception 'CHECKOUT_MINIMUM_PRICE_REQUIRED'; end if;
  definition := pg_get_functiondef('private.finalize_checkout_v3(uuid)'::regprocedure);
  if position('select commission_percent into rate' in definition)=0 then
    raise exception 'CHECKOUT_COMMISSION_SNAPSHOT_REQUIRED';
  end if;
  execute replace(definition, 'select commission_percent into rate',
    'select case when invoice.sale_type=''wholesale'' then coalesce(wholesale_commission_percent,commission_percent) else commission_percent end into rate');
end;
$migration$;

notify pgrst,'reload schema';
commit;
