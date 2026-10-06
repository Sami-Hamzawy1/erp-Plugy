begin;

-- Existing invoices retain their saved interpretation and values.
alter table public.sales add column if not exists tax_mode text not null default 'legacy'
  check (tax_mode in ('legacy','none','exclusive','inclusive'));
alter table public.sales add column if not exists financial_snapshot_v3 boolean not null default false;
alter table public.sale_items add column if not exists financial_net numeric(14,2);
alter table public.sale_items add column if not exists financial_gross numeric(14,2);
alter table public.sale_items add column if not exists line_tax_total numeric(14,2) not null default 0;
alter table public.installations add column if not exists tax_mode text not null default 'inclusive'
  check (tax_mode in ('none','exclusive','inclusive'));
alter table public.installations add column if not exists discount_type text not null default 'none'
  check (discount_type in ('none','fixed','percentage'));
alter table public.installations add column if not exists discount_value numeric(14,2) not null default 0 check(discount_value>=0);

-- One guard shared by new RPCs, preserving both deployed authorization modes.
create or replace function private.checkout_access_v3(permission text, legacy_permission text, loc uuid default null)
returns void language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null then raise exception using errcode='42501',message='AUTH_REQUIRED'; end if;
 if loc is not null and permission in ('sale.create','sale_discount.cart.apply','installation.update','treasury_account.deactivate')
  and to_regprocedure('private.branch_scope_location(uuid,uuid,boolean)') is not null then
  if not private.branch_scope_location(auth.uid(),loc,true) then raise exception using errcode='42501',message='LOCATION_FORBIDDEN'; end if;
 end if;
 if to_regprocedure('private.access_v2_enabled(uuid)') is not null then
  if private.access_v2_enabled(auth.uid()) then
   perform private.access_v2_require(permission,loc); return;
  end if;
 end if;
 if not coalesce(private.has_permission(auth.uid(),legacy_permission),false)
   or (loc is not null and not private.has_location_access(auth.uid(),loc)) then
  raise exception using errcode='42501',message='ACCESS_DENIED';
 end if;
end $$;
revoke all on function private.checkout_access_v3(text,text,uuid) from public,anon,authenticated;

-- Extend the preserved stock writer; retain inventory, shifts and security checks.
do $$ declare definition text; begin
 select pg_get_functiondef('private.complete_sale_documents_v1(jsonb,jsonb)'::regprocedure) into definition;
 if position('tax_mode' in definition)=0 then
  if position('computed_subtotal - requested_discount + tax_total_value' in definition)=0 then
   raise exception 'CHECKOUT_WRITER_INCOMPATIBLE'; end if;
  definition:=replace(definition,'computed_subtotal - requested_discount + tax_total_value',
   'computed_subtotal - requested_discount + case when sale_input->>''tax_mode''=''inclusive'' then 0 else tax_total_value end');
  definition:=replace(definition,'for item in',
   'update public.sales set tax_mode=coalesce(sale_input->>''tax_mode'',''legacy'') where id=sale_id_value; for item in');
  execute definition;
 end if;
end $$;

create or replace function private.finalize_checkout_v3(target uuid)
returns void language plpgsql security definer set search_path='' as $$
declare invoice public.sales%rowtype; net_cents numeric; tax_cents numeric; weights numeric;
 cumulative numeric:=0; previous_net numeric:=0; previous_tax numeric:=0; next_net numeric; next_tax numeric;
 line public.sale_items%rowtype; rate numeric; eligible boolean;
begin
 select * into invoice from public.sales where id=target for update;
 if invoice.financial_snapshot_v3 or invoice.tax_mode='legacy' or invoice.is_refund then return; end if;
 net_cents:=round((invoice.total-invoice.tax_total)*100); tax_cents:=round(invoice.tax_total*100);
 select sum(round(subtotal*100)) into weights from public.sale_items where sale_id=target;
 select role='salesperson' and is_active into eligible from public.profiles where id=invoice.user_id;
 for line in select * from public.sale_items where sale_id=target order by product_barcode,id loop
  cumulative:=cumulative+round(line.subtotal*100);
  next_net:=case when weights>0 then floor(net_cents*cumulative/weights) else 0 end;
  next_tax:=case when weights>0 then floor(tax_cents*cumulative/weights) else 0 end;
  select commission_percent into rate from public.products where id=line.product_id;
  update public.sale_items set financial_net=(next_net-previous_net)/100,
   financial_gross=(next_net-previous_net+next_tax-previous_tax)/100,
   line_tax_total=(next_tax-previous_tax)/100,
   line_tax_rate=invoice.tax_rate,
   commission_amount=case when coalesce(eligible,false) then round((next_net-previous_net)/100*coalesce(rate,0)/100,2) else 0 end
  where id=line.id;
  previous_net:=next_net; previous_tax:=next_tax;
 end loop;
 update public.sales set financial_snapshot_v3=true where id=target;
end $$;
revoke all on function private.finalize_checkout_v3(uuid) from public,anon,authenticated;

-- Preserve the existing public wrapper, including dynamic authorization and
-- branch confinement, inside the new compatibility wrapper.
do $$ declare definition text; begin
 if to_regprocedure('private.checkout_previous_v3(jsonb,jsonb,jsonb)') is null then
  select pg_get_functiondef('public.complete_sale_v1(jsonb,jsonb,jsonb)'::regprocedure) into definition;
  execute replace(definition,'public.complete_sale_v1(', 'private.checkout_previous_v3(');
 end if;
end $$;
revoke all on function private.checkout_previous_v3(jsonb,jsonb,jsonb) from public,anon,authenticated;
create or replace function public.complete_sale_v1(sale_input jsonb,items_input jsonb,settlements_input jsonb default '[]')
returns uuid language plpgsql security definer set search_path='' as $$
declare result uuid; mode text:=coalesce(sale_input->>'tax_mode','legacy');
 subtotal_value numeric; discount_value numeric:=coalesce((sale_input->>'discount_amount')::numeric,0);
 base numeric; tax numeric; loc uuid:=nullif(sale_input->>'location_id','')::uuid; row_value jsonb; p public.products%rowtype;
begin
 if mode not in ('legacy','none','exclusive','inclusive') then raise exception 'INVALID_TAX_MODE'; end if;
 if mode<>'legacy' then
  perform private.checkout_access_v3('sale.create','posCheckout',loc);
  if loc is null then raise exception 'INVOICE_BRANCH_REQUIRED'; end if;
  select coalesce(sum(round((value->>'subtotal')::numeric,2)),0) into subtotal_value from jsonb_array_elements(items_input);
  if coalesce(sale_input->>'discount_type','none') not in ('none','fixed','percentage')
    or coalesce((sale_input->>'discount_value')::numeric,0)<0
    or (sale_input->>'discount_type'='percentage' and (sale_input->>'discount_value')::numeric>100) then raise exception 'INVALID_DISCOUNT'; end if;
  if abs(discount_value-case sale_input->>'discount_type' when 'fixed' then coalesce((sale_input->>'discount_value')::numeric,0)
    when 'percentage' then round(subtotal_value*coalesce((sale_input->>'discount_value')::numeric,0)/100,2) else 0 end)>0.01 then raise exception 'DISCOUNT_MISMATCH'; end if;
  if discount_value<0 or discount_value>subtotal_value then raise exception 'INVALID_DISCOUNT'; end if;
  if discount_value>0 then perform private.checkout_access_v3('sale_discount.cart.apply','applyDiscounts',loc); end if;
  base:=subtotal_value-discount_value;
  tax:=case mode when 'exclusive' then round(base*0.14,2) when 'inclusive' then round(base-base/1.14,2) else 0 end;
  if abs(subtotal_value-(sale_input->>'subtotal')::numeric)>0.01 or abs(tax-(sale_input->>'tax_total')::numeric)>0.01
   or abs((case when mode='exclusive' then base+tax else base end)-(sale_input->>'total')::numeric)>0.01
   or coalesce((sale_input->>'tax_rate')::numeric,0)<>(case when mode='none' then 0 else 14 end) then raise exception 'CHECKOUT_TOTAL_MISMATCH'; end if;
  for row_value in select value from jsonb_array_elements(coalesce(settlements_input,'[]')) loop
   if not exists(select 1 from public.treasury_accounts a join public.payment_methods m on m.code=row_value->>'payment_method'
    where a.id=(row_value->>'account_id')::uuid and a.is_active and m.is_active
     and (a.location_id is null or a.location_id=loc)
     and case m.method_type when 'cash' then a.account_type='cash'
       when 'bank' then a.account_type in ('bank','instapay') when 'wallet' then a.account_type='wallet'
       when 'card' then a.account_type='bank' else true end) then raise exception 'PAYMENT_ACCOUNT_INELIGIBLE'; end if;
  end loop;
  -- Enforce the same proportional minimum-price rule as checkout, including installations.
  for row_value in select value from jsonb_array_elements(items_input) loop
   select * into p from public.products where id=case when row_value->>'product_id' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then (row_value->>'product_id')::uuid else null end;
   if p.id is not null and subtotal_value>0 and
    ((row_value->>'sale_price')::numeric-coalesce((row_value->>'item_discount')::numeric,0))*(1-discount_value/subtotal_value)+0.000001<p.min_price then
    raise exception 'MINIMUM_PRICE_VIOLATION'; end if;
  end loop;
 end if;
 result:=private.checkout_previous_v3(sale_input,items_input,settlements_input);
 perform private.finalize_checkout_v3(result);
 return result;
end $$;
revoke all on function public.complete_sale_v1(jsonb,jsonb,jsonb) from public,anon;
grant execute on function public.complete_sale_v1(jsonb,jsonb,jsonb) to authenticated;

do $$ declare definition text; begin
 if to_regprocedure('private.installation_legacy_document_v3(jsonb,uuid)') is null then
  select pg_get_functiondef('private.complete_installation_document_v1(jsonb,uuid)'::regprocedure) into definition;
  execute replace(definition,'private.complete_installation_document_v1(', 'private.installation_legacy_document_v3(');
 end if;
end $$;
revoke all on function private.installation_legacy_document_v3(jsonb,uuid) from public,anon,authenticated;

create or replace function private.complete_installation_document_v1(sale_input jsonb,installation uuid)
returns uuid language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); i public.installations%rowtype; line public.installation_lines%rowtype;
 result uuid:=(sale_input->>'id')::uuid; shift_id_value uuid; product_value uuid; qty numeric(14,3); cost_value numeric(14,4);
 stock_value numeric(14,3); total_value numeric(14,2):=0; line_value numeric(14,2); tax_value numeric(14,2); p public.products%rowtype;
begin
 if coalesce(sale_input->>'tax_mode','legacy')='legacy' then return private.installation_legacy_document_v3(sale_input,installation); end if;
 select * into i from public.installations where id=installation for update;
 if i.id is null or i.sale_id is not null or not private.has_location_access(actor,i.location_id) or
 nullif(sale_input->>'user_id','')::uuid is distinct from actor then raise exception using errcode='42501',message='INSTALLATION_FORBIDDEN'; end if;
 select id into shift_id_value from public.shifts where user_id=actor and is_open for update;
 if shift_id_value is null then raise exception using errcode='22023',message='SHIFT_REQUIRED'; end if;
 select coalesce(sum(round(unit_price*case when actual_qty>0 then actual_qty else estimated_qty end,2)),0) into total_value
 from public.installation_lines where installation_id=i.id and is_selected;
 if total_value<=0 or abs(total_value-(sale_input->>'subtotal')::numeric)>0.02 then
  raise exception using errcode='22023',message='INSTALLATION_TOTAL_MISMATCH'; end if;
 tax_value:=coalesce((sale_input->>'tax_total')::numeric,0);
 insert into public.sales(id,total,subtotal,tax_rate,tax_total,tax_mode,discount_amount,discount_type,discount_value,user_id,cashier_name,shift_id,location_id,customer_id,customer_name_snapshot,
 customer_phone_snapshot,customer_address_snapshot,payment_method,payment_status,amount_paid,amount_due,order_status,items_count)
 select result,(sale_input->>'total')::numeric,total_value,(sale_input->>'tax_rate')::numeric,tax_value,coalesce(sale_input->>'tax_mode','legacy'),coalesce((sale_input->>'discount_amount')::numeric,0),coalesce(sale_input->>'discount_type','none'),coalesce((sale_input->>'discount_value')::numeric,0),actor,sale_input->>'cashier_name',shift_id_value,i.location_id,i.customer_id,
 c.name,c.phone,c.address,'cash','unpaid',0,(sale_input->>'total')::numeric,'completed',(select count(*) from public.installation_lines where installation_id=i.id and is_selected)
 from public.customers c where c.id=i.customer_id;
 for line in select * from public.installation_lines where installation_id=i.id and is_selected order by product_id,id loop
  qty:=case when line.actual_qty>0 then line.actual_qty else line.estimated_qty end;
  if qty<=0 then raise exception using errcode='22023',message='INVALID_INSTALLATION_QUANTITY'; end if;
  product_value:=null;cost_value:=0;p:=null;
  if line.kind<>'service' then
   product_value:=nullif(line.product_id,'')::uuid;
   select * into p from public.products where id=product_value and is_active for update;
   if not found then raise exception using errcode='22023',message='INSTALLATION_PRODUCT_REQUIRED'; end if;
   select quantity,weighted_unit_cost into stock_value,cost_value from public.inventory_balances where product_id=product_value and location_id=i.location_id for update;
   if stock_value is null or stock_value<qty then raise exception using errcode='22023',message='INSUFFICIENT_LOCATION_STOCK'; end if;
   update public.inventory_balances set quantity=quantity-qty,updated_at=now() where product_id=product_value and location_id=i.location_id;
   insert into public.inventory_movements(product_id,location_id,movement_type,quantity_delta,unit_cost_snapshot,sale_id,actor_id,notes)
   values(product_value,i.location_id,'sale',-qty,cost_value,result,actor,'Installation consumption');
   perform private.sync_product_inventory(product_value);
  end if;
  line_value:=round(line.unit_price*qty,2);
  insert into public.sale_items(sale_id,product_id,product_barcode,product_name,unit_abbreviation,quantity,price,sale_price,subtotal,wholesale_price,
   unit_cost_snapshot,line_tax_rate,warranty_start_date,warranty_end_date)
  values(result,product_value,coalesce(p.barcode,line.catalog_item_id,line.id::text),coalesce(nullif(line.title_en,''),line.title_ar),line.unit_abbreviation,qty,
   line.unit_price,line.unit_price,line_value,cost_value,cost_value,(sale_input->>'tax_rate')::numeric,
   case when line.warranty_months>0 then current_date end,case when line.warranty_months>0 then (current_date+make_interval(months=>line.warranty_months))::date end);
 end loop;
 return result;
end $$;
revoke all on function private.complete_installation_document_v1(jsonb,uuid) from public,anon,authenticated;

create or replace function private.refund_line_gross_v3(target uuid)
returns numeric language sql stable security definer set search_path='' as $$
 with amounts as (
  select item.id,item.financial_gross,round(sale.total*100) total_cents,
   sum(round(item.subtotal*100)) over(partition by item.sale_id) weights,
   sum(round(item.subtotal*100)) over(partition by item.sale_id order by item.product_barcode,coalesce(item.product_id,item.id),item.id rows between unbounded preceding and current row) cumulative,
   round(item.subtotal*100) weight
  from public.sale_items item join public.sales sale on sale.id=item.sale_id
  where item.sale_id=(select sale_id from public.sale_items where id=target)
 ) select coalesce(financial_gross,(floor(total_cents*cumulative/nullif(weights,0))-floor(total_cents*(cumulative-weight)/nullif(weights,0)))/100,0) from amounts where id=target;
$$;
revoke all on function private.refund_line_gross_v3(uuid) from public,anon,authenticated;

-- Refund the saved financial line value. Legacy invoices use their stored totals.
do $$ declare definition text; old_expression text; replacement text;
begin
 select pg_get_functiondef('private.complete_refund_documents_v1(jsonb,jsonb)'::regprocedure) into definition;
 old_expression:='(original_item.subtotal / nullif(original_item.quantity, 0) * original_sale.total / nullif((select sum(si.subtotal) from public.sale_items si where si.sale_id = original_sale_id_value), 0))';
 replacement:='(private.refund_line_gross_v3(original_item.id) / nullif(original_item.quantity,0))';
 if position('private.refund_line_gross_v3' in definition)=0 then
  if position(old_expression in definition)>0 then definition:=replace(definition,old_expression,replacement);
  elsif position('original_item.sale_price - original_item.item_discount' in definition)>0 then
   definition:=replace(definition,'original_item.sale_price - original_item.item_discount',replacement);
  else raise exception 'REFUND_WRITER_INCOMPATIBLE'; end if;
  definition:=replace(definition,'if abs(line_total_value -',
   'line_total_value:=round('||replacement||'*(original_item.refunded_quantity+quantity_value),2)-round('||replacement||'*original_item.refunded_quantity,2); if abs(line_total_value -');
  definition:=replace(definition,'update public.sale_items set refunded_quantity = refunded_quantity + quantity_value',
   'update public.sale_items set financial_gross=line_total_value, financial_net=case when original_item.financial_net is not null then round(original_item.financial_net/original_item.quantity*(original_item.refunded_quantity+quantity_value),2)-round(original_item.financial_net/original_item.quantity*original_item.refunded_quantity,2) else null end, line_tax_total=case when original_item.financial_net is not null then line_total_value-(round(original_item.financial_net/original_item.quantity*(original_item.refunded_quantity+quantity_value),2)-round(original_item.financial_net/original_item.quantity*original_item.refunded_quantity,2)) else 0 end where sale_id=refund_id_value and product_barcode=original_item.product_barcode and financial_gross is null; update public.sale_items set refunded_quantity = refunded_quantity + quantity_value');
  definition:=replace(definition,'if not exists (',
   'update public.sales set total=computed_total, subtotal=case when original_sale.tax_mode=''legacy'' then computed_total else computed_total-coalesce((select sum(line_tax_total) from public.sale_items where sale_id=refund_id_value),0) end, tax_total=coalesce((select sum(line_tax_total) from public.sale_items where sale_id=refund_id_value),0),tax_rate=original_sale.tax_rate,tax_mode=original_sale.tax_mode where id=refund_id_value; if not exists (');
  execute definition;
 end if;
end $$;

create or replace function private.installation_read_access_v3(loc uuid)
returns void language plpgsql security definer set search_path='' as $$
begin
 if loc is not null then perform private.checkout_access_v3('pos.read','posCheckout',loc); return; end if;
 if auth.uid() is null then raise exception using errcode='42501',message='AUTH_REQUIRED'; end if;
 if to_regprocedure('private.access_v2_enabled(uuid)') is not null then
  if private.access_v2_enabled(auth.uid()) then
   if exists(select 1 from public.locations l where l.is_active and private.has_location_access(auth.uid(),l.id)
     and private.access_v2_allows(auth.uid(),'pos.read',l.id)) then return; end if;
   raise exception using errcode='42501',message='ACCESS_DENIED';
  end if;
 end if;
 perform private.checkout_access_v3('pos.read','posCheckout',null);
end $$;
revoke all on function private.installation_read_access_v3(uuid) from public,anon,authenticated;

-- Service templates are reusable; saved quotation lines remain independent snapshots.
create table if not exists public.installation_services (
 id uuid primary key default gen_random_uuid(), name_ar text not null, name_en text not null,
 unit text not null default 'service', default_price numeric(14,2) not null check(default_price>=0 and default_price<'Infinity'::numeric),
 is_active boolean not null default true, updated_at timestamptz not null default now());
alter table public.installation_services enable row level security;
revoke all on public.installation_services from public,anon,authenticated;

create or replace function public.installation_services_v3(input jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
declare loc uuid:=nullif(input->>'location_id','')::uuid; target uuid;
begin
 perform private.installation_read_access_v3(loc);
 if input->>'action'='save' then
  if loc is null then raise exception 'SERVICE_BRANCH_REQUIRED'; end if;
  perform private.checkout_access_v3('installation.update','posCheckout',loc);
  if nullif(btrim(input->>'name_ar'),'') is null or nullif(btrim(input->>'name_en'),'') is null
   or nullif(btrim(input->>'unit'),'') is null then raise exception 'SERVICE_DETAILS_REQUIRED'; end if;
  target:=coalesce(nullif(input->>'id','')::uuid,gen_random_uuid());
  insert into public.installation_services(id,name_ar,name_en,unit,default_price,is_active)
  values(target,btrim(input->>'name_ar'),btrim(input->>'name_en'),btrim(input->>'unit'),(input->>'default_price')::numeric,coalesce((input->>'is_active')::boolean,true))
  on conflict(id) do update set name_ar=excluded.name_ar,name_en=excluded.name_en,unit=excluded.unit,
   default_price=excluded.default_price,is_active=excluded.is_active,updated_at=now();
 end if;
 return (select coalesce(jsonb_agg(to_jsonb(s) order by s.name_en),'[]') from public.installation_services s);
end $$;

create or replace function public.installation_quotes_v3(input jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
declare loc uuid:=nullif(input->>'location_id','')::uuid; result jsonb:='[]'; quote record;
begin
 perform private.installation_read_access_v3(loc);
 for quote in select * from public.installations where (loc is null or location_id=loc)
  and private.has_location_access(auth.uid(),location_id) order by created_at desc loop
  if to_regprocedure('private.access_v2_enabled(uuid)') is not null then
   if private.access_v2_enabled(auth.uid()) then
    if not private.access_v2_allows(auth.uid(),'pos.read',quote.location_id) then continue; end if;
   end if;
  end if;
  result:=result||jsonb_build_array(to_jsonb(quote)||jsonb_build_object(
   'lines',(select coalesce(jsonb_agg(to_jsonb(l) order by l.created_at,l.id),'[]') from public.installation_lines l where l.installation_id=quote.id),
   'customer',(select jsonb_build_object('id',c.id,'name',c.name,'phone',null,'partner_type','customer','is_active',c.is_active) from public.customers c where c.id=quote.customer_id)));
 end loop;
 return result;
end $$;

-- Retain the existing save RPC's authorization, branch checks and deposit handling.
do $$ declare definition text; begin
 if to_regprocedure('private.installation_previous_v3(jsonb,jsonb)') is null then
  select pg_get_functiondef('public.save_installation_finance_v1(jsonb,jsonb)'::regprocedure) into definition;
  execute replace(definition,'public.save_installation_finance_v1(', 'private.installation_previous_v3(');
 end if;
end $$;
revoke all on function private.installation_previous_v3(jsonb,jsonb) from public,anon,authenticated;
create or replace function public.save_installation_finance_v1(input jsonb,lines_input jsonb)
returns uuid language plpgsql security definer set search_path='' as $$
declare target uuid; mode text:=coalesce(input->>'tax_mode','inclusive'); subtotal_value numeric; discount_value numeric; total_value numeric;
begin
 if mode not in ('none','exclusive','inclusive') or coalesce(input->>'discount_type','none') not in ('none','fixed','percentage')
  or coalesce((input->>'discount_value')::numeric,0)<0 or (input->>'discount_type'='percentage' and (input->>'discount_value')::numeric>100) then raise exception 'INVALID_QUOTATION_PRICING'; end if;
 select coalesce(sum(round((value->>'unit_price')::numeric*(value->>'estimated_qty')::numeric,2)),0) into subtotal_value from jsonb_array_elements(lines_input) where coalesce((value->>'is_selected')::boolean,true);
 discount_value:=case input->>'discount_type' when 'fixed' then coalesce((input->>'discount_value')::numeric,0) when 'percentage' then round(subtotal_value*coalesce((input->>'discount_value')::numeric,0)/100,2) else 0 end;
 if discount_value>subtotal_value then raise exception 'INVALID_DISCOUNT'; end if;
 if discount_value>0 then perform private.checkout_access_v3('sale_discount.cart.apply','applyDiscounts',nullif(input->>'location_id','')::uuid); end if;
 target:=private.installation_previous_v3(input,lines_input);
 update public.installations set tax_mode=mode,tax_rate=case when mode='none' then 0 else 14 end,
  discount_type=coalesce(input->>'discount_type','none'),discount_value=coalesce((input->>'discount_value')::numeric,0) where id=target;
 total_value:=subtotal_value-discount_value;
 if mode='exclusive' then total_value:=total_value+round(total_value*0.14,2); end if;
 if total_value < coalesce((select sum(a.amount) from public.transaction_allocations a join public.transactions t on t.id=a.transaction_id where t.installation_id=target),0) then raise exception 'QUOTE_BELOW_DEPOSITS'; end if;
 update public.transactions set total=total_value where installation_id=target;
 return target;
end $$;

create or replace function public.remove_treasury_account_v3(input jsonb)
returns text language plpgsql security definer set search_path='' as $$
declare account public.treasury_accounts%rowtype; ref record; referenced boolean;
begin
 select * into account from public.treasury_accounts where id=(input->>'id')::uuid for update;
 if not found then raise exception 'ACCOUNT_NOT_FOUND'; end if;
 if to_regprocedure('private.branch_scope_row(text,jsonb,boolean)') is not null then
  if not private.branch_scope_row('treasury_accounts',to_jsonb(account),true) then raise exception using errcode='42501',message='LOCATION_FORBIDDEN'; end if;
 end if;
 perform private.checkout_access_v3('treasury_account.deactivate','manageTreasury',account.location_id);
 if input->>'action'='deactivate' then
  update public.treasury_accounts set is_active=false,updated_at=now() where id=account.id;
  return 'deactivated';
 end if;
 if input->>'action'<>'delete' then raise exception 'INVALID_ACCOUNT_ACTION'; end if;
 if account.balance<>0 or account.opening_balance<>0 then raise exception 'ACCOUNT_HAS_BALANCE'; end if;
 for ref in select ns.nspname schema_name,t.relname table_name,a.attname column_name
  from pg_constraint c join pg_class t on t.oid=c.conrelid join pg_namespace ns on ns.oid=t.relnamespace
  join pg_attribute a on a.attrelid=c.conrelid and a.attnum=any(c.conkey)
  where c.contype='f' and c.confrelid='public.treasury_accounts'::regclass loop
  execute format('select exists(select 1 from %I.%I where %I=$1)',ref.schema_name,ref.table_name,ref.column_name) into referenced using account.id;
  if referenced then raise exception 'ACCOUNT_HAS_HISTORY_USE_DEACTIVATION'; end if;
 end loop;
 delete from public.treasury_accounts where id=account.id;
 return 'deleted';
end $$;
revoke all on function public.installation_services_v3(jsonb),public.installation_quotes_v3(jsonb),public.remove_treasury_account_v3(jsonb),public.save_installation_finance_v1(jsonb,jsonb) from public,anon;
grant execute on function public.installation_services_v3(jsonb),public.installation_quotes_v3(jsonb),public.remove_treasury_account_v3(jsonb),public.save_installation_finance_v1(jsonb,jsonb) to authenticated;
-- Append financial/pricing columns without weakening existing redactions.
do $$ declare relation_name text; definition text; additions text; begin
 foreach relation_name in array array['sales','sale_items','installations'] loop
  if to_regclass('public.access_v2_'||relation_name) is null then continue; end if;
  select string_agg('r.'||quote_ident(a.attname),', ' order by a.attnum) into additions
   from pg_attribute a where a.attrelid=('public.'||relation_name)::regclass and a.attnum>0 and not a.attisdropped
   and not exists(select 1 from pg_attribute v where v.attrelid=('public.access_v2_'||relation_name)::regclass and v.attname=a.attname and not v.attisdropped);
  if additions is null then continue; end if;
  definition:=pg_get_viewdef(('public.access_v2_'||relation_name)::regclass,true);
  definition:=regexp_replace(definition,'(\s+FROM (public\.)?'||relation_name||' r)',', '||additions||'\1','i');
  execute 'create or replace view public.access_v2_'||relation_name||' with(security_barrier=true) as '||definition;
 end loop;
end $$;

-- Preserve historical report amounts; new invoices report discounted revenue before tax.
do $$ declare definition text; relation_name text; begin
 foreach relation_name in array array['recognized_sales_summary','product_profit_summary'] loop
  if to_regclass('public.'||relation_name) is null then continue; end if;
  definition:=pg_get_viewdef(('public.'||relation_name)::regclass,true);
  if relation_name='recognized_sales_summary' then
   if position('tax_mode' in definition)>0 then continue; end if;
   definition:=replace(definition,'sale.total','(case when sale.tax_mode=''legacy'' then sale.total else sale.total-sale.tax_total end)');
  else
   if position('financial_net' in definition)>0 then continue; end if;
   definition:=replace(definition,'item.subtotal','coalesce(item.financial_net,item.subtotal)');
  end if;
  execute 'create or replace view public.'||relation_name||' with(security_invoker=true) as '||definition;
 end loop;
end $$;

notify pgrst,'reload schema';
commit;
