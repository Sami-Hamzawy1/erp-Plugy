-- Plugy production | branch stock dashboard and loan tracking
-- Run this entire file once in the Plugy project orbovqzenjlyshhiuofx.
-- The November wholesale and corrected loan installment migrations must already be installed.
-- All changes commit together. Existing stock, loans and treasury balances are retained.

begin;

do $preflight$
begin
  if to_regprocedure('public.create_branch_product_with_inventory_v1(jsonb,uuid)') is null
     or to_regprocedure('public.save_branch_product_stock_edit_v1(uuid,jsonb,uuid,numeric,numeric)') is null
     or to_regclass('private.access_v2_rpc_registry') is null then
    raise exception 'Plugy branch product and authorization migrations are required first.';
  end if;
  if not exists (
    select 1 from pg_attribute where attrelid='public.products'::regclass
      and attname='wholesale_min_price' and not attisdropped
  ) or not exists (
    select 1 from pg_attribute where attrelid='public.products'::regclass
      and attname='wholesale_commission_percent' and not attisdropped
  ) then
    raise exception 'Apply the November wholesale prices migration (20261117023143) first.';
  end if;
  if to_regclass('private.company_loans') is null
     or to_regprocedure('private.require_accounting_v1(uuid,boolean)') is null
     or to_regprocedure('private.loan_paid_v1(uuid)') is null
     or to_regprocedure('private.loan_funding_reversed_v1(uuid)') is null
     or to_regprocedure('public.accounting_loan_command_v1(jsonb)') is null then
    raise exception 'Apply the corrected Plugy loan installment migration (20261117030300) first.';
  end if;
  if to_regprocedure('public.branch_stock_dashboard_v1(jsonb)') is not null
     or to_regprocedure('public.loan_dashboard_v1(jsonb)') is not null then
    raise exception 'This update is already present in whole or part. Check the applied migrations before retrying.';
  end if;
end $preflight$;


-- 20261122005654_branch_stock_dashboard_and_thresholds.sql
create table if not exists private.branch_stock_minimums (
  product_id uuid not null references public.products(id) on delete cascade,
  location_id uuid not null references public.locations(id) on delete cascade,
  minimum numeric(14,3) not null check (minimum >= 0 and minimum < 'Infinity'::numeric),
  primary key (product_id, location_id)
);
create index if not exists branch_stock_minimums_location_idx
  on private.branch_stock_minimums(location_id, product_id);
create index if not exists inventory_balances_location_product_idx
  on public.inventory_balances(location_id, product_id);
alter table private.branch_stock_minimums enable row level security;
revoke all on private.branch_stock_minimums from public, anon, authenticated;

insert into private.branch_stock_minimums(product_id, location_id, minimum)
select b.product_id, b.location_id, p.min_stock
from public.inventory_balances b join public.products p on p.id=b.product_id
join public.locations l on l.id=b.location_id
where l.is_active and b.quantity>0 and p.min_stock>0
on conflict do nothing;

create function private.branch_minimum_access_v1(actor uuid, branch uuid, creating boolean)
returns boolean language sql stable set search_path='' as $$
  select private.branch_scope_location(actor,branch,true)
    and case when private.access_v2_enabled(actor) then
      private.access_v2_allows(actor,case when creating then 'product.create' else 'product.update' end)
      and private.access_v2_allows(actor,'product_inventory.quantity.update',branch)
    else private.has_permission(actor,'manageProducts') and private.has_permission(actor,'manageInventory') end;
$$;

create function public.product_branch_minimums_v1(target uuid default null)
returns jsonb language sql stable security definer set search_path='' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',l.id,'name_ar',l.name_ar,'name_en',l.name_en,'minimum',coalesce(m.minimum,0)
  ) order by l.is_main desc,l.name_en,l.id),'[]')
  from public.locations l
  left join private.branch_stock_minimums m on m.location_id=l.id and m.product_id=target
  where l.is_active and private.branch_minimum_access_v1(auth.uid(),l.id,target is null);
$$;

create function private.set_product_branch_minimums_v1(target uuid, changes jsonb, creating boolean)
returns void language plpgsql security definer set search_path='' as $$
declare row_value jsonb; branch uuid; value numeric; previous numeric;
begin
  if jsonb_typeof(changes) is distinct from 'array' then raise exception 'INVALID_BRANCH_MINIMUM'; end if;
  perform 1 from public.products where id=target and
    (not creating or xmin::text=pg_current_xact_id()::text) for update;
  if not found then raise exception 'PRODUCT_NOT_FOUND'; end if;
  for row_value in select item.value from jsonb_array_elements(changes) item loop
    branch:=(row_value->>'location_id')::uuid;
    value:=(row_value->>'minimum')::numeric;
    if branch is null or not private.branch_minimum_access_v1(auth.uid(),branch,creating) then
      raise exception using errcode='42501',message='LOCATION_FORBIDDEN';
    end if;
    if value is null or not (value between 0 and 99999999999.999) or value<>round(value,3) then
      raise exception 'INVALID_BRANCH_MINIMUM';
    end if;
    select minimum into previous from private.branch_stock_minimums
    where product_id=target and location_id=branch;
    if coalesce(previous,0) is distinct from (row_value->>'expected')::numeric then
      raise exception 'BRANCH_MINIMUM_CHANGED';
    end if;
    insert into private.branch_stock_minimums values(target,branch,value)
    on conflict(product_id,location_id) do update set minimum=excluded.minimum;
    insert into public.audit_events(actor_id,action,entity_type,entity_id,location_id,before_data,after_data)
      values(auth.uid(),'branch_stock_minimum_updated','product',target,branch,
        jsonb_build_object('minimum',coalesce(previous,0)),jsonb_build_object('minimum',value));
  end loop;
end $$;

-- The invoker keeps the existing product RLS and field guards in force.
create function public.save_product_with_branch_minimums_v1(input jsonb)
returns uuid language plpgsql security invoker set search_path='' as $$
declare
  target uuid:=nullif(input->>'product_id','')::uuid;
  branch uuid:=nullif(input->>'location_id','')::uuid;
  metadata jsonb:=input->'product';
  creating boolean:=target is null;
  product public.products%rowtype;
  assignment text;
begin
  if creating then
    if branch is null then target:=public.create_product_with_inventory_v1(metadata);
    else target:=public.create_branch_product_with_inventory_v1(metadata,branch); end if;
  elsif input ? 'expected_quantity' then
    if branch is null then
      perform public.save_product_stock_edit_v1(target,metadata,(input->>'quantity')::numeric,(input->>'expected_quantity')::numeric);
    else
      perform public.save_branch_product_stock_edit_v1(target,metadata,branch,(input->>'quantity')::numeric,(input->>'expected_quantity')::numeric);
    end if;
  else
    if jsonb_typeof(metadata) is distinct from 'object' or exists (
      select 1 from jsonb_object_keys(metadata) k where k not in (
        'barcode','name','price','min_price','wholesale_min_price','wholesale_commission_percent',
        'wholesale_price','min_stock','category_id','image_url','unit_id','origin_type',
        'warranty_months','supplier_id','commission_percent','is_active','updated_at'
      )
    ) then raise exception 'INVALID_PRODUCT_FIELDS'; end if;
    select string_agg(format('%1$I = ($1).%1$I',k),',') into assignment from jsonb_object_keys(metadata) k;
    product:=jsonb_populate_record(null::public.products,metadata);
    execute 'update public.products set '||assignment||' where id=$2 returning id'
      into target using product,target;
    if target is null then raise exception using errcode='42501',message='PRODUCT_UPDATE_FORBIDDEN'; end if;
  end if;
  perform private.set_product_branch_minimums_v1(target,input->'minimums',creating);
  return target;
end $$;

create function public.branch_stock_minimum_values_v1(branch uuid, products uuid[])
returns jsonb language sql stable security definer set search_path='' as $$
  select coalesce(jsonb_object_agg(m.product_id,m.minimum),'{}')
  from private.branch_stock_minimums m
  where m.location_id=branch and m.product_id=any(products)
    and private.branch_scope_location(auth.uid(),branch)
    and case when private.access_v2_enabled(auth.uid()) then
      private.access_v2_allows(auth.uid(),'location_inventory.read',branch)
      or private.access_v2_allows(auth.uid(),'stock_summary.read',branch)
      or private.access_v2_allows(auth.uid(),'stock_alert.read',branch)
    else private.has_permission(auth.uid(),'viewInventory') or private.has_permission(auth.uid(),'manageProducts')
      or private.has_permission(auth.uid(),'manageInventory') end;
$$;

create function public.branch_stock_alerts_v1(products uuid[])
returns jsonb language sql stable security definer set search_path='' as $$
  select coalesce(jsonb_agg(distinct m.product_id),'[]')
  from private.branch_stock_minimums m
  left join public.inventory_balances b on b.product_id=m.product_id and b.location_id=m.location_id
  where m.product_id=any(products) and m.minimum>0 and coalesce(b.quantity,0)<=m.minimum
    and private.branch_scope_location(auth.uid(),m.location_id)
    and case when private.access_v2_enabled(auth.uid()) then
      private.access_v2_allows(auth.uid(),'location_inventory.read',m.location_id)
      or private.access_v2_allows(auth.uid(),'stock_alert.read',m.location_id)
    else private.has_permission(auth.uid(),'viewInventory') or private.has_permission(auth.uid(),'manageProducts')
      or private.has_permission(auth.uid(),'manageInventory') end;
$$;

create function public.branch_stock_dashboard_v1(input jsonb default '{}')
returns jsonb language sql stable security definer set search_path='' as $$
with permitted as materialized (
  select l.id,l.name_ar,l.name_en,
    (not private.access_v2_enabled(auth.uid()) or
      (private.access_v2_allows(auth.uid(),'stock_summary.financial.read',l.id)
       and private.access_v2_allows(auth.uid(),'inventory_value.read',l.id))) valuation,
    (not private.access_v2_enabled(auth.uid()) or private.access_v2_allows(auth.uid(),'inventory_cost.read',l.id)) cost,
    (not private.access_v2_enabled(auth.uid()) or private.access_v2_allows(auth.uid(),'product_wholesale_price.read')) wholesale,
    (not private.access_v2_enabled(auth.uid()) or private.access_v2_allows(auth.uid(),'report_profit.read',l.id)) spread
  from public.locations l
  where l.is_active and private.branch_scope_location(auth.uid(),l.id)
    and (nullif(input->>'location_id','') is null or l.id=(input->>'location_id')::uuid)
    and case when private.access_v2_enabled(auth.uid()) then
      private.access_v2_allows(auth.uid(),'stock_summary.read',l.id)
      and private.access_v2_allows(auth.uid(),'location_inventory.read',l.id)
      and private.access_v2_allows(auth.uid(),'product.read')
    else private.has_permission(auth.uid(),'manageProducts') or private.has_permission(auth.uid(),'manageInventory')
      or private.has_permission(auth.uid(),'viewReports') end
), rows as materialized (
  select l.id location_id,p.id product_id,p.barcode,p.name,p.category_id,
    c.name category,u.abbreviation unit,p.is_active,
    coalesce(b.quantity,0) quantity,coalesce(m.minimum,0) minimum,
    case when l.valuation and l.cost and b.weighted_unit_cost>0 then b.weighted_unit_cost end unit_cost,
    case when l.valuation and p.is_active and p.price>0 then p.price end retail_price,
    case when l.valuation and l.wholesale and p.is_active and p.wholesale_price>0 then p.wholesale_price end wholesale_price,
    l.spread
  from permitted l
  cross join lateral (
    select product_id from public.inventory_balances where location_id=l.id
    union select product_id from private.branch_stock_minimums where location_id=l.id and minimum>0
  ) keys
  join public.products p on p.id=keys.product_id
  left join public.inventory_balances b on b.location_id=l.id and b.product_id=p.id
  left join private.branch_stock_minimums m on m.location_id=l.id and m.product_id=p.id
  left join public.categories c on c.id=p.category_id
  left join public.product_units u on u.id=p.unit_id
  where p.is_active or b.quantity>0
), amounts as materialized (
  select r.*,
    quantity*unit_cost cost_value,quantity*retail_price retail_value,quantity*wholesale_price wholesale_value,
    case when spread then quantity*(retail_price-unit_cost) end retail_spread,
    case when spread then quantity*(wholesale_price-unit_cost) end wholesale_spread,
    greatest(minimum-quantity,0) replenishment,
    is_active and minimum>0 and quantity<=minimum low_stock
  from rows r
), totals as (
  select location_id,category_id,category,grouping(category) total,
    count(*) filter(where quantity>0) stocked,
    count(*) filter(where low_stock) low_stock,
    count(*) filter(where is_active and quantity=0) out_of_stock,
    count(*) filter(where quantity>0 and unit_cost is null) uncosted,
    count(*) filter(where is_active and quantity>0 and retail_price is null) unpriced_retail,
    count(*) filter(where is_active and quantity>0 and wholesale_price is null) unpriced_wholesale,
    sum(cost_value) cost_value,sum(retail_value) retail_value,sum(wholesale_value) wholesale_value,
    sum(retail_spread) retail_spread,sum(wholesale_spread) wholesale_spread
  from amounts
  group by grouping sets ((location_id),(location_id,category_id,category))
), matched as (
  select a.* from amounts a
  where nullif(input->>'location_id','') is not null
    and (nullif(input->>'category_id','') is null
      or coalesce(a.category_id::text,'uncategorized')=input->>'category_id')
    and (nullif(btrim(input->>'search'),'') is null or
      strpos(lower(a.name),lower(btrim(input->>'search')))>0 or
      strpos(lower(a.barcode),lower(btrim(input->>'search')))>0)
    and case input->>'filter'
      when 'low' then a.low_stock
      when 'out' then a.is_active and a.quantity=0
      when 'missing' then a.quantity>0 and exists (
        select 1 from permitted l where l.id=a.location_id and l.valuation and (
          (l.cost and a.unit_cost is null) or (a.is_active and (
            a.retail_price is null or (l.wholesale and a.wholesale_price is null)
          ))
        )
      )
      else true end
), page as (
  select m.* from matched m
  order by
    case when input->>'sort'='quantity' then m.quantity end desc,
    case when input->>'sort'='cost' then m.cost_value end desc nulls last,
    case when input->>'sort'='retail' then m.retail_value end desc nulls last,
    case when input->>'sort'='wholesale' then m.wholesale_value end desc nulls last,
    case when input->>'sort'='gap' then m.replenishment end desc,
    lower(m.name),m.product_id
  limit 50 offset greatest(0,least(1000000,coalesce((input->>'offset')::int,0)))
)
select jsonb_build_object(
  'as_of',statement_timestamp(),
  'branches',coalesce((select jsonb_agg(jsonb_build_object(
    'location_id',l.id,'name_ar',l.name_ar,'name_en',l.name_en,
    'cost_allowed',l.valuation and l.cost,'retail_allowed',l.valuation,
    'wholesale_allowed',l.valuation and l.wholesale,'spread_allowed',l.spread,
    'stocked',coalesce(t.stocked,0),'low_stock',coalesce(t.low_stock,0),'out_of_stock',coalesce(t.out_of_stock,0),
    'cost_value',case when l.valuation and l.cost then coalesce(t.cost_value,0) end,
    'retail_value',case when l.valuation then coalesce(t.retail_value,0) end,
    'wholesale_value',case when l.valuation and l.wholesale then coalesce(t.wholesale_value,0) end,
    'retail_spread',t.retail_spread,'wholesale_spread',t.wholesale_spread,
    'uncosted',case when l.valuation and l.cost then coalesce(t.uncosted,0) end,
    'unpriced_retail',case when l.valuation then coalesce(t.unpriced_retail,0) end,
    'unpriced_wholesale',case when l.valuation and l.wholesale then coalesce(t.unpriced_wholesale,0) end
  ) order by l.name_en,l.id) from permitted l left join totals t on t.location_id=l.id and t.total=1),'[]'),
  'categories',coalesce((select jsonb_agg(jsonb_build_object(
    'id',coalesce(t.category_id::text,'uncategorized'),'name',t.category,'location_id',t.location_id,
    'stocked',t.stocked,'cost_value',t.cost_value,'retail_value',t.retail_value,'wholesale_value',t.wholesale_value
  ) order by t.location_id,t.category,t.category_id) from totals t where total=0),'[]'),
  'products',coalesce((select jsonb_agg(to_jsonb(page)-'spread') from page),'[]'),
  'product_count',(select count(*) from matched)
);
$$;

revoke all on function private.branch_minimum_access_v1(uuid,uuid,boolean),
  private.set_product_branch_minimums_v1(uuid,jsonb,boolean),
  public.product_branch_minimums_v1(uuid),public.save_product_with_branch_minimums_v1(jsonb),
  public.branch_stock_dashboard_v1(jsonb),public.branch_stock_minimum_values_v1(uuid,uuid[]),public.branch_stock_alerts_v1(uuid[]) from public,anon,authenticated;
grant execute on function public.product_branch_minimums_v1(uuid),public.save_product_with_branch_minimums_v1(jsonb),
  public.branch_stock_dashboard_v1(jsonb),public.branch_stock_minimum_values_v1(uuid,uuid[]),public.branch_stock_alerts_v1(uuid[]),private.set_product_branch_minimums_v1(uuid,jsonb,boolean) to authenticated;
insert into private.access_v2_rpc_registry(signature,function_oid,original_definition)
select p.oid::regprocedure::text,p.oid,pg_get_functiondef(p.oid) from pg_proc p
where p.pronamespace='public'::regnamespace and p.proname in (
  'product_branch_minimums_v1','save_product_with_branch_minimums_v1','branch_stock_dashboard_v1','branch_stock_minimum_values_v1','branch_stock_alerts_v1'
) on conflict(signature) do update set function_oid=excluded.function_oid,original_definition=excluded.original_definition;
notify pgrst,'reload schema';

-- 20261122005702_loan_dashboard_history.sql
create table private.tracked_loans (
  id uuid primary key,
  location_id uuid not null references public.locations(id),
  lender text not null check(length(btrim(lender)) between 1 and 200),
  original_principal numeric(14,2),
  opening_balance numeric(14,2) not null check(opening_balance between 0 and 999999999999.99),
  opening_date date not null check(isfinite(opening_date)),
  notes text,
  schedule jsonb not null default '[]',
  created_at timestamptz not null default now(),
  created_by uuid not null references public.profiles(id),
  archived_at timestamptz,
  check(original_principal is null or original_principal between greatest(opening_balance,0.01) and 999999999999.99)
);
create index tracked_loans_location_idx on private.tracked_loans(location_id,created_at,id);

create table private.tracked_loan_payments (
  id uuid primary key,
  loan_id uuid not null references private.tracked_loans(id),
  amount numeric(14,2) not null check(amount between 0.01 and 999999999999.99),
  paid_on date not null check(isfinite(paid_on)),
  reference text,
  notes text,
  created_by uuid not null references public.profiles(id)
);
create index tracked_loan_payments_loan_idx on private.tracked_loan_payments(loan_id,paid_on,id);

create table private.company_loan_archives (
  loan_id uuid primary key references private.company_loans(id),
  archived_at timestamptz not null default now(),
  archived_by uuid not null references public.profiles(id),
  reason text not null
);
alter table private.tracked_loans enable row level security;
alter table private.tracked_loan_payments enable row level security;
alter table private.company_loan_archives enable row level security;
revoke all on private.tracked_loans,private.tracked_loan_payments,private.company_loan_archives
  from public,anon,authenticated;

create function public.loan_dashboard_v1(input jsonb default '{}')
returns jsonb language plpgsql stable security definer set search_path='' set timezone='Africa/Cairo' as $$
declare branch uuid:=nullif(input->>'location_id','')::uuid;
  accounting boolean:=coalesce((input->>'accounting')::boolean,false);
begin
  if accounting then perform private.require_accounting_v1(branch);
  elsif branch is not null then perform private.loan_access_v1(branch); end if;
  return (
    with visible as materialized (
      select l.id,l.name_en,l.name_ar
      from public.locations l
      where l.is_active and (branch is null or branch=l.id)
        and private.branch_scope_location(auth.uid(),l.id)
        and case when accounting then private.accounting_visible_v1(l.id)
          when private.access_v2_enabled(auth.uid()) then private.access_v2_allows(auth.uid(),'transaction.read',l.id)
          else private.has_permission(auth.uid(),'manageTreasury') end
    ), posted as (
      select l.created_at,jsonb_build_object(
        'id',l.id,'location_id',l.location_id,'lender',l.lender,'principal',l.principal,
        'opening_date',l.received_date,'notes',l.notes,'branch',v.name_en,'branch_ar',v.name_ar,
        'remaining',case when c.cancelled then 0 else installments.remaining end,
        'paid',l.principal-installments.remaining,'installments',installments.items,
        'cancelled',c.cancelled,'unreconciled',false,'unscheduled',0,
        'archived',a.archived_at is not null and (c.cancelled or installments.remaining=0),
        'can_archive',c.cancelled or installments.remaining=0,
         'funding_settlement_id',(select x.id from public.transaction_settlements x
          where x.transaction_id=l.transaction_id and x.reversed_settlement_id is null limit 1),
        'history',history.items
      ) payload
      from private.company_loans l join visible v on v.id=l.location_id
      left join private.company_loan_archives a on a.loan_id=l.id
      cross join lateral (select private.loan_funding_reversed_v1(l.transaction_id) cancelled) c
      cross join lateral (
        select coalesce(sum(greatest(i.amount-p.amount,0)),0) remaining,
          coalesce(jsonb_agg(to_jsonb(i)||jsonb_build_object(
            'paid',p.amount,'remaining',greatest(i.amount-p.amount,0),
            'paid_at',case when p.amount>=i.amount then p.paid_at end,
            'schedule_editable',not exists(select 1 from private.loan_payments h where h.installment_id=i.id)
          ) order by i.due_date,i.id),'[]') items
        from private.loan_installments i cross join lateral private.loan_paid_v1(i.id) p
        where i.loan_id=l.id
      ) installments
      cross join lateral (
        select coalesce(jsonb_agg(jsonb_build_object(
          'id',p.id,'amount',p.amount,'paid_on',s.occurred_at::date,
          'reference',s.reference,'settlement_id',s.id,
          'reversed',exists(select 1 from public.transaction_settlements x where x.reversed_settlement_id=s.id)
        ) order by s.occurred_at desc,p.id),'[]') items
        from private.loan_installments i join private.loan_payments p on p.installment_id=i.id
        join public.transaction_settlements s on s.transaction_id=p.transaction_id and s.reversed_settlement_id is null
        where i.loan_id=l.id
      ) history
    ), tracked as (
      select l.created_at,jsonb_build_object(
        'id',l.id,'location_id',l.location_id,'lender',l.lender,'principal',l.original_principal,
        'opening_date',l.opening_date,'opening_balance',l.opening_balance,
        'notes',l.notes,'branch',v.name_en,'branch_ar',v.name_ar,
        'remaining',l.opening_balance-history.after_opening,
        'paid',case when l.original_principal is not null
          then l.original_principal-l.opening_balance+history.after_opening end,
        'installments',installments.items,'cancelled',false,'unreconciled',true,
        'unscheduled',greatest(l.opening_balance-history.after_opening-installments.remaining,0),
        'archived',l.archived_at is not null,'can_archive',true,'history',history.items
      ) payload
      from private.tracked_loans l join visible v on v.id=l.location_id
      cross join lateral (
        select coalesce(sum(p.amount) filter(where p.paid_on>l.opening_date),0) after_opening,
          coalesce(jsonb_agg(jsonb_build_object(
            'id',p.id,'amount',p.amount,'paid_on',p.paid_on,'reference',p.reference,
            'notes',p.notes,'included_in_opening',p.paid_on<=l.opening_date
          ) order by p.paid_on desc,p.id),'[]') items
        from private.tracked_loan_payments p where p.loan_id=l.id
      ) history
      cross join lateral (
        select coalesce(sum(i.amount-i.paid),0) remaining,
          coalesce(jsonb_agg(jsonb_build_object('due_date',i.due_date,'amount',i.amount,
            'paid',i.paid,'remaining',i.amount-i.paid) order by i.due_date,i.number),'[]') items
        from (
          select s.*,least(s.amount,greatest(history.after_opening-
            coalesce(sum(s.amount) over(order by s.due_date,s.number rows between unbounded preceding and 1 preceding),0),0)) paid
          from (
            select (item->>'date')::date due_date,(item->>'amount')::numeric amount,number
            from jsonb_array_elements(l.schedule) with ordinality as rows(item,number)
          ) s
        ) i
      ) installments
    )
    select jsonb_build_object(
      'branches',coalesce((select jsonb_agg(to_jsonb(v) order by name_en,id) from visible v),'[]'),
      'loans',coalesce((select jsonb_agg(payload order by created_at desc,payload->>'id')
        from (select * from posted union all select * from tracked) loans),'[]')
    )
  );
end $$;

create function public.loan_tracking_command_v1(input jsonb)
returns uuid language plpgsql security definer set search_path='' set timezone='Africa/Cairo' as $$
declare branch uuid:=nullif(input->>'location_id','')::uuid;
  operation text:=input->>'action';
  target uuid:=nullif(input->>'loan_id','')::uuid;
  command_id uuid:=nullif(input->>'id','')::uuid;
  command_key text:='loan-tracking:'||command_id::text;
  actor uuid:=auth.uid();
  tracked private.tracked_loans%rowtype;
  posted private.company_loans%rowtype;
  due_on date:=(input->>'date')::date;
  amount_value numeric:=(input->>'amount')::numeric;
  principal_value numeric:=(input->>'principal')::numeric;
  schedule_rows jsonb:=coalesce(input->'schedule','[]');
  entry jsonb;
  scheduled numeric:=0;
  available numeric;
  already_recorded numeric;
  archived_reason text:=nullif(btrim(input->>'reason'),'');
  replay uuid;
begin
  if branch is null or not private.branch_scope_location(actor,branch,true) then
    raise exception using errcode='42501',message='LOAN_BRANCH_FORBIDDEN';
  end if;
  if coalesce((input->>'accounting')::boolean,false) then
    perform private.require_accounting_v1(branch,true);
    if private.access_v2_enabled(actor) then
      perform private.access_v2_require('transaction_settlement.create',branch);
    end if;
  else perform private.loan_access_v1(branch,true); end if;
  if operation is null or operation not in ('import','past_payment','archive') or command_id is null then
    raise exception 'INVALID_LOAN_ACTION';
  end if;
  replay:=private.finance_command_v1(command_key,input);
  if replay is not null then return replay; end if;
  if operation='import' then
    if nullif(btrim(input->>'lender'),'') is null or length(btrim(input->>'lender'))>200
      or due_on is null or not isfinite(due_on) or due_on>current_date
      or amount_value is null or not (amount_value between 0 and 999999999999.99) or amount_value<>round(amount_value,2)
      or (principal_value is not null and (not (principal_value between greatest(amount_value,0.01) and 999999999999.99)
        or principal_value<>round(principal_value,2)))
      or jsonb_typeof(schedule_rows) is distinct from 'array' or jsonb_array_length(schedule_rows)>240 then
      raise exception 'INVALID_LOAN_DETAILS';
    end if;
    for entry in select value from jsonb_array_elements(schedule_rows) loop
      if entry->>'date' is null or not isfinite((entry->>'date')::date) or (entry->>'date')::date<=due_on
        or entry->>'amount' is null or not ((entry->>'amount')::numeric between 0.01 and 999999999999.99)
        or (entry->>'amount')::numeric<>round((entry->>'amount')::numeric,2) then
        raise exception 'INVALID_LOAN_SCHEDULE';
      end if;
      scheduled:=scheduled+(entry->>'amount')::numeric;
    end loop;
    if scheduled>amount_value then raise exception 'LOAN_SCHEDULE_TOTAL_MISMATCH'; end if;
    target:=command_id;
    insert into private.tracked_loans(id,location_id,lender,original_principal,opening_balance,opening_date,notes,schedule,created_by)
    values(target,branch,btrim(input->>'lender'),principal_value,amount_value,due_on,input->>'notes',schedule_rows,actor);
  elsif operation='past_payment' then
    select * into tracked from private.tracked_loans where id=target and location_id=branch for update;
    if not found or tracked.archived_at is not null then raise exception 'LOAN_NOT_AVAILABLE'; end if;
    if due_on is null or not isfinite(due_on) or due_on>current_date or amount_value is null
      or not (amount_value between 0.01 and 999999999999.99) or amount_value<>round(amount_value,2) then
      raise exception 'INVALID_LOAN_PAYMENT';
    end if;
    available:=case when due_on<=tracked.opening_date then tracked.original_principal-tracked.opening_balance
      else tracked.opening_balance end;
    select coalesce(sum(p.amount),0) into already_recorded from private.tracked_loan_payments p
      where loan_id=target and (p.paid_on<=tracked.opening_date)=(due_on<=tracked.opening_date);
    if available is not null and amount_value+already_recorded>available then raise exception 'HISTORIC_LOAN_PAYMENT_EXCEEDS_BALANCE'; end if;
    insert into private.tracked_loan_payments values(command_id,target,amount_value,due_on,input->>'reference',input->>'notes',actor);
  else
    if archived_reason is null then raise exception 'LOAN_ARCHIVE_REASON_REQUIRED'; end if;
    select * into tracked from private.tracked_loans where id=target and location_id=branch for update;
    if found then
      if tracked.archived_at is not null then return target; end if;
      update private.tracked_loans set archived_at=coalesce(archived_at,now()) where id=target;
    else
      select * into posted from private.company_loans where id=target and location_id=branch for update;
      if not found then raise exception 'LOAN_NOT_AVAILABLE'; end if;
      if not private.loan_funding_reversed_v1(posted.transaction_id) and exists(
        select 1 from private.loan_installments i cross join lateral private.loan_paid_v1(i.id) p
        where i.loan_id=target and i.amount>p.amount
      ) then raise exception 'ACTIVE_POSTED_LOAN'; end if;
      insert into private.company_loan_archives(loan_id,archived_by,reason)
        values(target,actor,archived_reason)
        on conflict(loan_id) do update set archived_at=now(),archived_by=actor,reason=excluded.reason;
    end if;
  end if;
  insert into private.finance_commands_v1 values(command_key,input,target);
  insert into public.audit_events(actor_id,action,entity_type,entity_id,location_id,after_data)
    values(actor,case operation when 'import' then 'loan_history_imported'
      when 'past_payment' then 'loan_past_payment_recorded' else 'loan_archived' end,
      'loan',target,branch,jsonb_build_object('request_id',command_id,'amount',amount_value,'date',due_on,'reason',archived_reason));
  return target;
end $$;

revoke all on function public.loan_dashboard_v1(jsonb),public.loan_tracking_command_v1(jsonb) from public,anon,authenticated;
grant execute on function public.loan_dashboard_v1(jsonb),public.loan_tracking_command_v1(jsonb) to authenticated;
insert into private.access_v2_rpc_registry(signature,function_oid,original_definition)
select p.oid::regprocedure::text,p.oid,pg_get_functiondef(p.oid) from pg_proc p
where p.pronamespace='public'::regnamespace and p.proname in ('loan_dashboard_v1','loan_tracking_command_v1')
on conflict(signature) do update set function_oid=excluded.function_oid,original_definition=excluded.original_definition;
notify pgrst,'reload schema';

commit;
