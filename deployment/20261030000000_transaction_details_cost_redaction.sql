begin;

-- Transaction/payment access is independent from product-cost visibility.
-- Keep the existing RPC wrapper, parent checks and branch confinement intact.
create or replace function private.transaction_details_redacted_v4(target uuid)
returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare d public.transaction_summary%rowtype; items jsonb:='[]'; allocations jsonb;
begin
  perform private.access_v2_rpc_guard('transaction_details_v1',jsonb_build_array(target));
  select * into d from public.transaction_summary where id=target;
  if not found then raise exception using errcode='42501',message='TRANSACTION_NOT_FOUND'; end if;
  if d.sale_id is not null then
    select coalesce(jsonb_agg(to_jsonb(i)),'[]') into items
      from public.access_v2_sale_items i where sale_id=d.sale_id;
  elsif d.stock_receipt_id is not null then
    select coalesce(jsonb_agg(to_jsonb(i)||jsonb_build_object('product_name',p.name,
      'returned_quantity',coalesce(r.qty,0))),'[]') into items
      from public.access_v2_stock_receipt_items i join public.access_v2_products p on p.id=i.product_id
      left join lateral(select sum(quantity) qty from public.vendor_return_items where receipt_item_id=i.id) r on true
      where i.receipt_id=d.stock_receipt_id;
  elsif d.installation_id is not null then
    select coalesce(jsonb_agg(to_jsonb(i)),'[]') into items
      from public.access_v2_installation_lines i where installation_id=d.installation_id;
  elsif d.type='vendor_return' then
    select coalesce(jsonb_agg(case when private.access_v2_allows(auth.uid(),'inventory_cost.read',d.location_id)
      then to_jsonb(i) else to_jsonb(i)-'unit_cost' end),'[]') into items
      from public.vendor_return_items i where transaction_id=d.id;
  end if;
  select coalesce(jsonb_agg(to_jsonb(a)||jsonb_build_object('settlement',to_jsonb(s))),'[]') into allocations
    from public.transaction_allocations a join public.transaction_settlement_summary s on s.id=a.settlement_id
    where a.transaction_id=d.id;
  return jsonb_build_object('document',to_jsonb(d),'items',items,'allocations',allocations,
    'credits',(select coalesce(jsonb_agg(to_jsonb(c)),'[]') from public.transaction_credits c
      where c.transaction_id=d.id or c.credit_transaction_id=d.id));
end $$;
revoke all on function private.transaction_details_redacted_v4(uuid) from public,anon,authenticated;
-- The public invoker wrapper calls this as the authenticated user. This helper
-- enforces the same guard and retains RLS on transactions, allocations and credits.
grant execute on function private.transaction_details_redacted_v4(uuid) to authenticated;

do $$
declare definition text; routine text; patched boolean := false;
  cost_gate text := 'if operation=''transaction_details_v1'' then perform private.access_v2_require(''report_cost.read'',loc); end if;';
begin
  if to_regprocedure('private.access_v2_impl_transaction_details_v1(uuid)') is null then
    raise exception 'TRANSACTION_DETAILS_REQUIRES_AUTHORIZATION_V2';
  end if;
  select pg_get_functiondef('public.transaction_details_v1(uuid)'::regprocedure)
    into definition;
  if position('private.transaction_details_redacted_v4' in definition)=0 then
    if position('private.access_v2_rpc_guard' in definition)=0
      or position('SECURITY DEFINER' in definition)>0 then
      raise exception 'TRANSACTION_DETAILS_IMPLEMENTATION_INCOMPATIBLE';
    end if;
    -- Preserve the original invoker body for legacy users, including its RLS.
    definition := regexp_replace(definition,'\mbegin\M',
      'begin if private.access_v2_enabled(auth.uid()) then return private.transaction_details_redacted_v4(target); end if;', 'i');
    execute definition;
  end if;
  -- Migration 27 delegates to its preserved guard; earlier v2 installations
  -- use access_v2_rpc_guard directly. Update the cost gate in either form.
  foreach routine in array array['private.access_v2_rpc_guard(text,jsonb)',
    'private.branch_scope_base_access_v2_rpc_guard(text,jsonb)'] loop
    if to_regprocedure(routine) is null then continue; end if;
    select pg_get_functiondef(to_regprocedure(routine)) into definition;
    if position(cost_gate in definition)>0 then
      execute replace(definition,cost_gate,'');
      patched := true;
    end if;
  end loop;
  if not patched and exists (
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='private' and p.proname in ('access_v2_rpc_guard','branch_scope_base_access_v2_rpc_guard')
      and position('report_cost.read' in pg_get_functiondef(p.oid))>0
      and position('transaction_details_v1' in pg_get_functiondef(p.oid))>0
  ) then
    raise exception 'TRANSACTION_DETAILS_GUARD_INCOMPATIBLE';
  end if;
end $$;

notify pgrst,'reload schema';
commit;
