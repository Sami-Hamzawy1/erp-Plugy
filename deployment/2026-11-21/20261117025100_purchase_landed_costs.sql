begin;

alter table public.stock_receipts add column purchase_costs jsonb;

create function private.prepare_purchase_costs_v1(costs jsonb, items jsonb)
returns jsonb language plpgsql immutable set search_path='' as $$
declare
  rate numeric := (costs->>'exchange_rate')::numeric;
  customs numeric := coalesce((costs->>'customs')::numeric,0);
  shipping numeric := coalesce((costs->>'shipping')::numeric,0);
  clearance numeric := coalesce((costs->>'clearance')::numeric,0);
  charges numeric;
  purchase jsonb;
begin
  if costs->>'currency' is distinct from 'USD' or rate is null or rate<=0 or rate>1000000
    or customs<0 or shipping<0 or clearance<0
    or exists(select 1 from unnest(array[customs,shipping,clearance]) amount
      where amount>9999999999 or amount<>round(amount,2)) then
    raise exception using errcode='22023', message='INVALID_PURCHASE_COSTS';
  end if;
  if jsonb_typeof(items) is distinct from 'array' or jsonb_array_length(items)=0 then
    raise exception using errcode='22023', message='RECEIPT_ITEMS_REQUIRED';
  end if;
  if exists(select 1 from jsonb_array_elements(items) item
    where (item->>'quantity')::numeric(14,3) is null
      or (item->>'quantity')::numeric(14,3)<=0 or (item->>'quantity')::numeric::text='NaN'
      or (item->>'unit_cost')::numeric not between 0 and 9999999999
      or item->>'unit_cost' is null or item->>'product_id' is null) then
    raise exception using errcode='22023', message='INVALID_PURCHASE_LINE';
  end if;
  if (select count(distinct (item->>'product_id')::uuid) from jsonb_array_elements(items) item)
    <> jsonb_array_length(items) then
    raise exception using errcode='22023', message='DUPLICATE_PURCHASE_PRODUCT';
  end if;

  charges := customs+shipping+clearance;
  with supplier_lines as (
    select item, (item->>'product_id')::uuid product_id,
      (item->>'quantity')::numeric(14,3) quantity, (item->>'unit_cost')::numeric unit_price,
      round((item->>'quantity')::numeric(14,3)*(item->>'unit_cost')::numeric*rate,2) base
    from jsonb_array_elements(items) item
  ), weighted as (
    select *,sum(base) over() supplier_total,
      sum(base) over(order by product_id) running_base,
      sum(quantity) over() total_quantity,
      sum(quantity) over(order by product_id) running_quantity
    from supplier_lines
  ), allocated as (
    select *,case when supplier_total>0
      then round(charges*running_base/supplier_total,2)-round(charges*(running_base-base)/supplier_total,2)
      else round(charges*running_quantity/total_quantity,2)-round(charges*(running_quantity-quantity)/total_quantity,2)
    end apportioned
    from weighted
  )
  select jsonb_build_object(
    'items',jsonb_agg(item || jsonb_build_object('unit_cost',round((base+apportioned)/quantity,4),
      'landed_line_total',base+apportioned) order by product_id),
    'costs',jsonb_build_object('currency','USD','exchange_rate',rate,'customs',customs,
      'shipping',shipping,'clearance',clearance,'supplier_total',max(supplier_total),'total_charges',charges,
      'lines',jsonb_object_agg(product_id,jsonb_build_object('unit_price',unit_price,'supplier_total',base))))
  into purchase from allocated;
  return purchase;
end $$;

-- Reuse the standard stock writer, locks, permissions, payment path and corrections.
do $$
declare definition text; revised text;
begin
  select pg_get_functiondef('private.post_stock_receipt_documents_v1(jsonb,jsonb)'::regprocedure)
    into definition;
  if position('round(quantity_value * unit_cost_value, 2)' in definition)=0
    or position('set total_cost = total_cost_value where' in definition)=0
    or position('  insert into public.stock_receipts (' in definition)=0 then
    raise exception 'UNEXPECTED_STOCK_RECEIPT_DEFINITION';
  end if;
  revised := replace(definition,'declare','declare' || chr(10) || '  purchase jsonb;');
  revised := replace(revised,'  insert into public.stock_receipts (',$body$
  if receipt_input->'import_costs' is not null and receipt_input->'import_costs'<>'null'::jsonb then
    purchase := private.prepare_purchase_costs_v1(receipt_input->'import_costs',items_input);
    items_input := purchase->'items';
  end if;
  insert into public.stock_receipts ($body$);
  revised := replace(revised,'round(quantity_value * unit_cost_value, 2)',
    'case when purchase is null then round(quantity_value * unit_cost_value, 2) else (item->>''landed_line_total'')::numeric end');
  revised := replace(revised,'set total_cost = total_cost_value where',
    'set total_cost = total_cost_value, purchase_costs = purchase->''costs'' where');
  execute revised;
end $$;

create function private.use_purchase_supplier_total_v1()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if new.type='purchase' then
    select coalesce((r.purchase_costs->>'supplier_total')::numeric,new.total)
    into new.total from public.stock_receipts r where r.id=new.stock_receipt_id;
  end if;
  return new;
end $$;
create trigger purchase_supplier_total before insert or update of total on public.transactions
for each row when (new.type='purchase')
execute function private.use_purchase_supplier_total_v1();

-- Supplier credit only includes the supplier's own invoice. The inventory
-- movement still removes the landed value from stock.
create function private.purchase_return_supplier_total_v1(
  receipt_id uuid, product_id uuid, original_quantity numeric,
  prior_quantity numeric, return_quantity numeric, unit_cost numeric
) returns numeric language sql stable security definer set search_path='' as $$
  select coalesce(
    round(get.supplier_total*(prior_quantity+return_quantity)/original_quantity,2)
      -round(get.supplier_total*prior_quantity/original_quantity,2),
    round(return_quantity*unit_cost,2))
  from public.stock_receipts r
  cross join lateral (values((r.purchase_costs->'lines'->product_id::text->>'supplier_total')::numeric)) get(supplier_total)
  where r.id=receipt_id
$$;

do $$
declare definition text;
begin
  select pg_get_functiondef('private.access_v2_impl_post_vendor_return_v1(jsonb,jsonb)'::regprocedure)
    into definition;
  if position('total_value:=total_value+round(qty*r.unit_cost,2);' in definition)=0 then
    raise exception 'UNEXPECTED_VENDOR_RETURN_DEFINITION';
  end if;
  execute replace(definition,'total_value:=total_value+round(qty*r.unit_cost,2);',
    'total_value:=total_value+private.purchase_return_supplier_total_v1(r.receipt_id,r.product_id,r.quantity,returned,qty,r.unit_cost);');
end $$;

do $$
declare definition text;
begin
  select pg_get_functiondef('private.accounting_lines_v1(timestamptz)'::regprocedure) into definition;
  execute replace(definition,'private.accounting_lines_v1(', 'private.accounting_lines_before_purchase_costs_v1(');
end $$;

create or replace function private.accounting_lines_v1(cutoff timestamptz)
returns table(source_id uuid,location_id uuid,occurred_at timestamptz,account text,amount numeric)
language sql stable security definer set search_path='' set timezone='Africa/Cairo' as $$
  select * from private.accounting_lines_before_purchase_costs_v1(cutoff)
  union all
  select r.id,r.location_id,event.at,entry.account,entry.amount*event.sign
  from public.stock_receipts r
  join public.transactions t on t.stock_receipt_id=r.id and t.status in ('posted','void')
  left join private.accounting_voids v on v.transaction_id=t.id
  cross join lateral (values(t.occurred_at,1),(v.voided_at,-1)) event(at,sign)
  cross join lateral (values
    ('inventory',r.total_cost-t.total),('landed_cost_clearing',t.total-r.total_cost)
  ) entry(account,amount)
  where r.purchase_costs is not null and event.at<cutoff and entry.amount<>0
  union all
  select t.id,t.location_id,event.at,entry.account,entry.amount*event.sign
  from public.transactions t
  join public.transactions original on original.id=t.original_transaction_id
  join public.stock_receipts r on r.id=original.stock_receipt_id
  left join private.accounting_voids v on v.transaction_id=t.id
  cross join lateral (values(t.occurred_at,1),(v.voided_at,-1)) event(at,sign)
  cross join lateral (
    select coalesce(sum(round(i.quantity*i.unit_cost,2)),0)-t.total amount
    from public.vendor_return_items i where i.transaction_id=t.id
  ) difference
  cross join lateral (values ('inventory',-difference.amount),('other_expenses',difference.amount)) entry(account,amount)
  where t.type='vendor_return' and t.status in ('posted','void') and r.purchase_costs is not null
    and event.at<cutoff and entry.amount<>0
$$;

-- Payments made separately for the entered charges can clear the accrual
-- through the existing audited cash classification instead of a new expense.
do $$
declare constraint_definition text; command_definition text; manual_definition text;
begin
  select pg_get_constraintdef(oid) into constraint_definition
  from pg_constraint where conrelid='private.accounting_cash_classes'::regclass
    and conname='accounting_cash_classes_account_check';
  if position('''asset_proceeds''' in coalesce(constraint_definition,''))=0 then
    raise exception 'UNEXPECTED_CASH_CLASS_CONSTRAINT';
  end if;
  alter table private.accounting_cash_classes drop constraint accounting_cash_classes_account_check;
  execute 'alter table private.accounting_cash_classes add constraint accounting_cash_classes_account_check '
    || replace(constraint_definition,'''asset_proceeds''','''landed_cost_clearing''::text, ''asset_proceeds''');
  select pg_get_functiondef('public.accounting_command_v1(jsonb)'::regprocedure) into command_definition;
  if position('IF input->>''account''=''asset_proceeds'' THEN' in command_definition)=0 then
    raise exception 'UNEXPECTED_CASH_CLASS_COMMAND';
  end if;
  execute replace(command_definition,'IF input->>''account''=''asset_proceeds'' THEN',$body$
  IF input->>'account'='landed_cost_clearing' AND cash.direction<>'outgoing' THEN
    RAISE EXCEPTION 'OUTGOING_ACQUISITION_PAYMENT_REQUIRED';
  END IF;
  IF input->>'account'='asset_proceeds' THEN$body$);

  -- Keep branch information for explicit manual Treasury movements so they
  -- can clear acquisition charges in the branch that received the goods.
  select pg_get_functiondef('private.access_v2_impl_post_manual_transaction_v1(jsonb)'::regprocedure)
    into manual_definition;
  if position('transactions(type,direction,reference,description,total,created_by)' in manual_definition)=0 then
    raise exception 'UNEXPECTED_MANUAL_TRANSACTION_DEFINITION';
  end if;
  manual_definition := replace(manual_definition,'transactions(type,direction,reference,description,total,created_by)',
    'transactions(type,direction,reference,description,total,created_by,location_id)');
  execute replace(manual_definition,'::numeric,actor) returning id into result;',
    '::numeric,actor,nullif(input->>''location_id'','''')::uuid) returning id into result;');
end $$;

revoke all on function private.prepare_purchase_costs_v1(jsonb,jsonb),
  private.use_purchase_supplier_total_v1(),
  private.purchase_return_supplier_total_v1(uuid,uuid,numeric,numeric,numeric,numeric),
  private.accounting_lines_before_purchase_costs_v1(timestamptz) from public,anon,authenticated;

notify pgrst,'reload schema';
commit;
