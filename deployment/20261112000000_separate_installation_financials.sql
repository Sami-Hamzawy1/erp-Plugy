begin;
-- Reporting only: no invoice, stock, settlement, balance or historical data writes.
-- Depends on integrated accounting, refund correctness, checkout payment fees and balance sheet classification.
create index if not exists checkout_payment_fees_expense_idx
 on private.checkout_payment_fees(expense_id) where expense_id is not null;
create or replace function private.installation_for_sale_v1(target uuid)
returns uuid language sql stable security definer set search_path='' as $$
 select i.id from public.sales s join public.installations i
 on i.sale_id=coalesce(s.original_sale_id,s.id) where s.id=target;
$$;
create or replace function private.installation_source_v1(target uuid)
returns uuid language sql stable security definer set search_path='' as $$
 select private.installation_for_sale_v1(coalesce(
  (select t.sale_id from public.transactions t where t.id=target),
  (select m.sale_id from public.inventory_movements m where m.id=target),
  (select s.id from public.sales s where s.id=target),
  (select f.sale_id from private.checkout_payment_fees f
   where f.expense_id=coalesce((select t.expense_id from public.transactions t where t.id=target),target) limit 1)));
$$;
revoke all on function private.installation_for_sale_v1(uuid),private.installation_source_v1(uuid) from public,anon,authenticated;

CREATE OR REPLACE FUNCTION public.accounting_profit_v1(input jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' SET timezone='Africa/Cairo' AS $$
DECLARE loc uuid:=nullif(input->>'location_id','')::uuid; purpose text:=coalesce(input->>'purpose','analytics');
 shift uuid:=nullif(input->>'shift_id','')::uuid;
 start_at timestamptz:=(input->>'start')::timestamptz; end_at timestamptz:=(input->>'end')::timestamptz; result jsonb;
BEGIN
 IF start_at IS NULL OR end_at IS NULL OR start_at>=end_at THEN RAISE EXCEPTION 'INVALID_ACCOUNTING_PERIOD'; END IF;
 IF NOT coalesce(private.actor_is_active_v1(),false) OR (loc IS NOT NULL AND NOT private.accounting_profit_visible_v1(loc,purpose)) OR
 (loc IS NULL AND NOT private.accounting_profit_visible_v1(NULL,purpose) AND NOT EXISTS(SELECT 1 FROM public.locations WHERE private.accounting_profit_visible_v1(id,purpose))) THEN
  RAISE EXCEPTION USING errcode='42501',message='PROFIT_REPORT_FORBIDDEN'; END IF;
 SELECT coalesce(jsonb_object_agg(account,value),'{}') INTO result FROM (
 SELECT account,sum(amount) value FROM private.accounting_lines_v1(end_at) l
 WHERE private.installation_source_v1(l.source_id) IS NULL AND l.occurred_at>=start_at AND (shift IS NULL OR EXISTS(
  SELECT 1 FROM public.sales s LEFT JOIN public.transactions t ON t.sale_id=s.id
  WHERE s.shift_id=shift AND l.source_id IN (s.id,t.id)
 ) OR EXISTS(SELECT 1 FROM public.expenses e LEFT JOIN public.transactions t ON t.expense_id=e.id
  WHERE e.shift_id=shift AND l.source_id IN(e.id,t.id))
 OR EXISTS(SELECT 1 FROM public.inventory_movements m JOIN public.sales s ON s.id=m.sale_id
  WHERE s.shift_id=shift AND l.source_id=m.id)) AND (loc IS NULL OR l.location_id=loc) AND private.accounting_profit_visible_v1(l.location_id,purpose)
 AND account IN ('sales','discounts','returns','cogs','operating_expenses','administrative_expenses','other_expenses','income_tax','other_income') GROUP BY account) totals;
 RETURN jsonb_build_object('pnl',result,'total_sales',(SELECT count(*) FROM public.transactions t JOIN public.sales s ON s.id=t.sale_id WHERE private.installation_for_sale_v1(s.id) IS NULL AND t.type='sale' AND t.status='posted' AND (shift IS NULL OR s.shift_id=shift) AND t.occurred_at>=start_at AND t.occurred_at<end_at AND (loc IS NULL OR t.location_id=loc) AND private.accounting_profit_visible_v1(t.location_id,purpose)));
END $$;

create or replace function public.accounting_sales_series_v1(input jsonb)
returns jsonb language plpgsql stable security definer set search_path='' set timezone='Africa/Cairo' as $$
declare loc uuid:=nullif(input->>'location_id','')::uuid;
 start_at timestamptz:=(input->>'start')::timestamptz; end_at timestamptz:=(input->>'end')::timestamptz;
 shift uuid:=nullif(input->>'shift_id','')::uuid; bucket text:=coalesce(input->>'bucket','day'); result jsonb;
begin
 if start_at is null or end_at is null or start_at>=end_at or bucket not in ('hour','day','month','year','category') then
  raise exception using errcode='22023',message='INVALID_ACCOUNTING_PERIOD'; end if;
 if not coalesce(private.actor_is_active_v1(),false) or
  (loc is not null and not private.accounting_profit_visible_v1(loc,'analytics')) or
  (loc is null and not private.accounting_profit_visible_v1(null,'analytics') and not exists(
   select 1 from public.locations where private.accounting_profit_visible_v1(id,'analytics'))) then
  raise exception using errcode='42501',message='PROFIT_REPORT_FORBIDDEN'; end if;
 with documents as (
  select s.*,case when s.is_refund then -1 else 1 end sign,
   case when s.tax_total=0 and s.tax_mode='legacy' then coalesce(s.tax,0) else s.tax_total end saved_tax
  from public.sales s join public.transactions t on t.sale_id=s.id and t.status='posted'
  where private.installation_for_sale_v1(s.id) is null and s.created_at>=start_at and s.created_at<end_at and (shift is null or s.shift_id=shift)
   and (loc is null or s.location_id=loc) and private.accounting_profit_visible_v1(s.location_id,'analytics')
 ), values as (
  select case bucket when 'hour' then extract(hour from d.created_at)::int::text
   when 'day' then to_char(d.created_at,'YYYY-MM-DD') when 'month' then to_char(d.created_at,'YYYY-MM')
   when 'year' then to_char(d.created_at,'YYYY') end key,d.sign*(d.total-d.saved_tax) revenue from documents d where bucket<>'category'
  union all
  select coalesce(c.name,'General'),d.sign*coalesce(si.financial_net,private.refund_line_net_v1(si.id))
   from documents d join public.sale_items si on si.sale_id=d.id left join public.products p on p.id=si.product_id
   left join public.categories c on c.id=p.category_id where bucket='category'
 ) select coalesce(jsonb_agg(jsonb_build_object('key',key,'revenue',revenue) order by key),'[]') into result
 from (select key,sum(revenue) revenue from values group by key) totals;
 return result;
end $$;

CREATE OR REPLACE FUNCTION public.accounting_product_profit_v1(input jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' SET timezone='Africa/Cairo' AS $$
DECLARE loc uuid:=nullif(input->>'location_id','')::uuid; purpose text:=coalesce(input->>'purpose','product');
 start_at timestamptz:=coalesce((input->>'start')::timestamptz,'1900-01-01'); end_at timestamptz:=coalesce((input->>'end')::timestamptz,now()+interval '1 day');
 shift uuid:=nullif(input->>'shift_id','')::uuid; returns_only boolean:=coalesce((input->>'returns_only')::boolean,false); result jsonb;
BEGIN
 IF start_at>=end_at THEN RAISE EXCEPTION 'INVALID_ACCOUNTING_PERIOD'; END IF;
 IF NOT coalesce(private.actor_is_active_v1(),false) OR (loc IS NOT NULL AND NOT private.accounting_product_visible_v1(loc,purpose)) OR
 (loc IS NULL AND NOT private.accounting_product_visible_v1(NULL,purpose) AND NOT EXISTS(SELECT 1 FROM public.locations WHERE private.accounting_product_visible_v1(id,purpose))) THEN
  RAISE EXCEPTION USING errcode='42501',message='PRODUCT_PROFIT_FORBIDDEN'; END IF;
 WITH invoice_lines AS (
 SELECT si.product_id,coalesce(si.product_id::text,si.product_barcode,si.id::text) product_key,si.product_name,p.origin_type,
 s.id sale_id,s.created_at::date sale_day,date_trunc('month',s.created_at)::date sale_month,
 CASE WHEN s.is_refund THEN -si.quantity ELSE si.quantity END quantity,
 CASE WHEN s.is_refund THEN -1 ELSE 1 END * coalesce(si.financial_net,private.refund_line_net_v1(si.id)) revenue,
 CASE WHEN s.is_refund THEN -1 ELSE 1 END * si.quantity * CASE WHEN EXISTS(SELECT 1 FROM public.inventory_movements m WHERE m.sale_id=s.id) THEN si.unit_cost_snapshot ELSE si.wholesale_price END cost
 FROM public.sale_items si JOIN public.sales s ON s.id=si.sale_id JOIN public.transactions t ON t.sale_id=s.id AND t.status='posted'
 LEFT JOIN public.products p ON p.id=si.product_id
 WHERE private.installation_for_sale_v1(s.id) IS NULL AND (NOT returns_only OR s.is_refund) AND s.created_at>=start_at AND s.created_at<end_at AND (shift IS NULL OR s.shift_id=shift) AND (loc IS NULL OR s.location_id=loc) AND private.accounting_product_visible_v1(s.location_id,purpose)
 ), extra AS (
 SELECT m.product_id,m.sale_id,sum(l.amount) cost FROM private.landed_cost_movements_v1(end_at) l JOIN public.inventory_movements m ON m.id=l.source_id
 JOIN public.sales s ON s.id=m.sale_id WHERE private.installation_for_sale_v1(s.id) IS NULL AND (NOT returns_only OR s.is_refund) AND l.account='cogs' AND l.occurred_at>=start_at AND (shift IS NULL OR s.shift_id=shift)
 AND (loc IS NULL OR l.location_id=loc) AND private.accounting_product_visible_v1(l.location_id,purpose) GROUP BY 1,2
 ), totals AS (
 SELECT product_key,max(product_name) product_name,max(origin_type) origin_type,sale_day,sale_month,sum(quantity) net_quantity,sum(revenue) revenue,sum(cost) cost
 FROM invoice_lines GROUP BY 1,4,5
 ), extra_daily AS (
 SELECT e.product_id::text product_key,s.created_at::date sale_day,sum(e.cost) cost FROM extra e JOIN public.sales s ON s.id=e.sale_id GROUP BY 1,2
 ) SELECT coalesce(jsonb_agg(jsonb_build_object('product_id',t.product_key,'product_name',t.product_name,'origin_type',t.origin_type,'sale_day',t.sale_day,'sale_month',t.sale_month,
 'net_quantity',t.net_quantity,'revenue',t.revenue,'cost',t.cost+coalesce(e.cost,0),'gross_profit',t.revenue-t.cost-coalesce(e.cost,0)) ORDER BY t.revenue DESC),'[]') INTO result
 FROM totals t LEFT JOIN extra_daily e USING(product_key,sale_day);
 RETURN result;
END $$;

create or replace function public.invoice_payment_totals_v1(input jsonb)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare loc uuid:=nullif(input->>'location_id','')::uuid; actor uuid:=auth.uid(); result jsonb;
begin
 if not coalesce(private.actor_is_active_v1(),false) or not exists(
  select 1 from public.locations l where (loc is null or l.id=loc) and private.has_location_access(actor,l.id) and
   case when private.access_v2_enabled(actor) then private.access_v2_allows(actor,'invoice.read',l.id)
    else private.has_permission(actor,'viewInvoices') end) then
  raise exception using errcode='42501',message='INVOICE_READ_FORBIDDEN'; end if;
 select coalesce(jsonb_object_agg(method,amount),'{}') into result from (
  select pm.code method,sum(a.amount*case when coalesce(original.direction,st.direction)='incoming' then 1 else -1 end) amount
  from public.transaction_allocations a join public.transactions t on t.id=a.transaction_id
  join public.transaction_settlements st on st.id=a.settlement_id
  left join public.transaction_settlements original on original.id=st.reversed_settlement_id
  join public.payment_methods pm on pm.id=coalesce(original.payment_method_id,st.payment_method_id)
  where private.installation_for_sale_v1(t.sale_id) is null and t.type in ('sale','refund') and t.status='posted' and (loc is null or t.location_id=loc)
   and private.has_location_access(actor,t.location_id) and
   case when private.access_v2_enabled(actor) then private.access_v2_allows(actor,'invoice.read',t.location_id)
    else private.has_permission(actor,'viewInvoices') end
  group by pm.code
 ) totals;
 return result;
end $$;

-- Keep the full ledger and balance sheet intact; split only period P&L.
-- The wrapper still checks accounting.read and filters each ledger location.
do $$ declare definition text; begin
 select pg_get_functiondef('private.accounting_report_core_v1(jsonb)'::regprocedure) into definition;
 if position('installation_source_v1' in definition)=0 then
  if position('FILTER(WHERE occurred_at>=start_at)' in definition)=0 then
   raise exception 'ACCOUNTING_REPORT_DEFINITION_UNSUPPORTED'; end if;
  definition:=replace(definition,'FILTER(WHERE occurred_at>=start_at)',
   'FILTER(WHERE occurred_at>=start_at AND private.installation_source_v1(source_id) IS NULL)');
  execute definition;
 end if;
end $$;

-- Preserve an explicit installation P&L for equity reconciliation, without
-- folding it into ordinary sales/profit cards. No extra profit grant is added.
do $$ declare definition text; begin
 if to_regprocedure('private.accounting_report_classified_v2(jsonb)') is null then
  select pg_get_functiondef('public.accounting_report_v1(jsonb)'::regprocedure) into definition;
  execute replace(definition,'public.accounting_report_v1(', 'private.accounting_report_classified_v2(');
 end if;
end $$;
revoke all on function private.accounting_report_classified_v2(jsonb) from public,anon,authenticated;

create or replace function public.accounting_report_v1(input jsonb)
returns jsonb language plpgsql stable security definer set search_path='' set timezone='Africa/Cairo' as $$
declare result jsonb; installation_pnl jsonb;
 loc uuid:=nullif(input->>'location_id','')::uuid;
begin
 perform private.require_accounting_v1(loc);
 result:=private.accounting_report_classified_v2(input);
 select coalesce(jsonb_object_agg(account,value),'{}') into installation_pnl from (
  select l.account,sum(l.amount) value from private.accounting_lines_v1((input->>'end')::timestamptz) l
  where l.occurred_at>=(input->>'start')::timestamptz
   and private.installation_source_v1(l.source_id) is not null
   and (loc is null or l.location_id=loc) and private.accounting_visible_v1(l.location_id)
   and l.account in ('sales','discounts','returns','cogs','operating_expenses') group by l.account
 ) totals;
 return result||jsonb_build_object('installation_pnl',installation_pnl);
end $$;


create or replace function public.installation_financials_v1(input jsonb default '{}')
returns jsonb language plpgsql stable security definer set search_path='' set timezone='Africa/Cairo' as $$
declare loc uuid:=nullif(input->>'location_id','')::uuid; result jsonb;
begin
 perform private.installation_read_access_v3(loc);
 if not coalesce(private.actor_is_active_v1(),false) then
  raise exception using errcode='42501',message='AUTH_REQUIRED'; end if;
 with visible as materialized (
  select i.*,private.accounting_profit_visible_v1(i.location_id,'analytics') can_profit
  from public.installations i where (loc is null or i.location_id=loc)
   and private.has_location_access(auth.uid(),i.location_id)
   and (not private.access_v2_enabled(auth.uid()) or private.access_v2_allows(auth.uid(),'pos.read',i.location_id))
 ), ledger as materialized (
  select private.installation_source_v1(l.source_id) installation_id,l.account,l.amount
  from private.accounting_lines_v1(now()+interval '1 microsecond') l
  where l.account in ('sales','discounts','returns','cogs','operating_expenses')
   and (loc is null or l.location_id=loc)
 ), pnl as (
  select installation_id,-coalesce(sum(amount) filter(where account='sales'),0) sales,
   coalesce(sum(amount) filter(where account='discounts'),0) discounts,
   coalesce(sum(amount) filter(where account='returns'),0) returns,
   coalesce(sum(amount) filter(where account='cogs'),0) cost,
   coalesce(sum(amount) filter(where account='operating_expenses'),0) expenses
  from ledger where installation_id in (select id from visible) group by installation_id
 ), documents as (
  select v.id quote_id,t.* from visible v join public.transaction_summary t
   on t.installation_id=v.id or private.installation_for_sale_v1(t.sale_id)=v.id
  where t.status='posted'
 ), payments as (
  select quote_id,
   coalesce(sum(case when type='refund' then -amount_paid else amount_paid end),0) received,
   coalesce(sum(amount_paid) filter(where type='installation'),0) deposits,
   coalesce(sum(amount_due) filter(where type='sale'),0) outstanding,
   coalesce(sum(total) filter(where type='installation'),0) quotation_value
  from documents group by quote_id
 ), rows as (
  select v.id,v.quotation_number,coalesce(c.name,v.customer_name,'') customer_name,v.status,v.sale_id,
   v.can_profit,coalesce(p.sales,0) sales,coalesce(p.discounts,0) discounts,coalesce(p.returns,0) returns,
   coalesce(p.sales-p.discounts-p.returns,0) revenue,
   case when v.can_profit then coalesce(p.cost,0) end cost,
   case when v.can_profit then coalesce(p.expenses,0) end expenses,
   case when v.can_profit then coalesce(p.sales-p.discounts-p.returns-p.cost-p.expenses,0) end profit,
   coalesce(pay.received,0) received,coalesce(pay.deposits,0) deposits,coalesce(pay.outstanding,0) outstanding,
   case when v.sale_id is null and v.status<>'cancelled' then coalesce(pay.quotation_value,0) else 0 end quotation_value,
   v.created_at
  from visible v left join pnl p on p.installation_id=v.id
   left join payments pay on pay.quote_id=v.id left join public.customers c on c.id=v.customer_id
 ) select jsonb_build_object('rows',coalesce(jsonb_agg(to_jsonb(r) order by r.created_at desc),'[]'),
  'summary',jsonb_build_object('count',count(*),'invoiced_count',count(*) filter(where sale_id is not null),
   'sales',coalesce(sum(sales),0),'discounts',coalesce(sum(discounts),0),'returns',coalesce(sum(returns),0),
   'revenue',coalesce(sum(revenue),0),
   'cost',case when coalesce(bool_and(can_profit),true) then coalesce(sum(cost),0) end,
   'expenses',case when coalesce(bool_and(can_profit),true) then coalesce(sum(expenses),0) end,
   'profit',case when coalesce(bool_and(can_profit),true) then coalesce(sum(profit),0) end,
   'received',coalesce(sum(received),0),'deposits',coalesce(sum(deposits),0),
   'outstanding',coalesce(sum(outstanding),0),'quotation_value',coalesce(sum(quotation_value),0)))
 into result from rows r;
 return result;
end $$;
revoke all on function public.installation_financials_v1(jsonb) from public,anon;
grant execute on function public.installation_financials_v1(jsonb) to authenticated;

-- Classification is read through invoice permissions, so invoice-only staff
-- need no access to installation customer/site details or profit.
create or replace function public.invoice_installation_links_v1(input jsonb)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
 if not coalesce(private.actor_is_active_v1(),false) then
  raise exception using errcode='42501',message='AUTH_REQUIRED'; end if;
 if jsonb_typeof(input->'sale_ids') is distinct from 'array' or jsonb_array_length(input->'sale_ids')>200 then
  raise exception 'INVALID_INVOICE_IDS'; end if;
 select coalesce(jsonb_object_agg(s.id,private.installation_for_sale_v1(s.id)),'{}') into result
 from public.sales s where s.id in (select value::uuid from jsonb_array_elements_text(input->'sale_ids'))
  and private.has_location_access(auth.uid(),s.location_id)
  and case when private.access_v2_enabled(auth.uid()) then private.access_v2_allows(auth.uid(),'invoice.read',s.location_id)
   else private.has_permission(auth.uid(),'viewInvoices') end
  and private.installation_for_sale_v1(s.id) is not null;
 return result;
end $$;
revoke all on function public.invoice_installation_links_v1(jsonb) from public,anon;
grant execute on function public.invoice_installation_links_v1(jsonb) to authenticated;

insert into private.access_v2_rpc_registry(signature,function_oid,original_definition)
 select p.oid::regprocedure::text,p.oid,pg_get_functiondef(p.oid) from pg_proc p
 where p.pronamespace='public'::regnamespace and p.proname in
 ('installation_financials_v1','invoice_installation_links_v1','accounting_report_v1','accounting_profit_v1',
 'accounting_sales_series_v1','accounting_product_profit_v1','invoice_payment_totals_v1')
 on conflict(signature) do update set function_oid=excluded.function_oid,original_definition=excluded.original_definition;
select private.access_v2_assert_coverage();
notify pgrst,'reload schema';
commit;
