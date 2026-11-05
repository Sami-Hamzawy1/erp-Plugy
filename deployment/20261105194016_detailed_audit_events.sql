-- Apply AFTER the 5 November combined release and detailed-sale-audit migration.
-- Additive event-time snapshots only. No historical audit or business rows are rewritten.
begin;
set local lock_timeout='10s';
do $$ begin
 if to_regprocedure('public.read_audit_events_v1(jsonb)') is null
 or to_regclass('public.installation_inventory') is null then
  raise exception 'DETAILED_AUDIT_PREREQUISITES_MISSING';
 end if;
end $$;

create table if not exists private.audit_stock_changes_v1 (
 sequence bigint generated always as identity primary key,
 transaction_id xid8 not null default pg_current_xact_id(),
 product_id uuid not null, location_id uuid,
 pool boolean not null default false,
 quantity_before numeric not null, quantity_after numeric not null,
 movement_id uuid, event_id uuid,
 item jsonb not null
);
create index if not exists audit_stock_changes_transaction_idx
 on private.audit_stock_changes_v1(transaction_id,product_id,location_id,sequence desc);
create index if not exists audit_stock_changes_movement_idx
 on private.audit_stock_changes_v1(movement_id) where movement_id is not null;
create table if not exists private.audit_event_details_v1 (
 event_id uuid primary key references public.audit_events(id) on delete restrict deferrable initially deferred,
 before_data jsonb, after_data jsonb
);
alter table private.audit_stock_changes_v1 enable row level security;
alter table private.audit_event_details_v1 enable row level security;
revoke all on private.audit_stock_changes_v1,private.audit_event_details_v1 from public,anon,authenticated;

-- Strip credentials permanently; sensitive business fields live only in private snapshots.
create or replace function private.audit_filter_details_v1(data jsonb, costs boolean default false,
 balances boolean default false, contacts boolean default false)
returns jsonb language plpgsql immutable set search_path='' as $$
declare result jsonb; k text; v jsonb;
begin
 if jsonb_typeof(data)='array' then
  select coalesce(jsonb_agg(private.audit_filter_details_v1(value,costs,balances,contacts)),'[]') into result from jsonb_array_elements(data);
  return result;
 elsif jsonb_typeof(data)='object' then
  result:='{}';
  for k,v in select * from jsonb_each(data) loop
   if k ~* '(password|credential|secret|token|(^|_)pin($|_)|account_number|wallet_number|salary|hourly_rate)' then continue; end if;
   if not costs and k ~* '(cost|profit|wholesale|min_price|margin)' then continue; end if;
   if not balances and k ~* '(balance|salary|hourly_rate)' then continue; end if;
   if not contacts and k ~* '(phone|email|address|tax_registration)' then continue; end if;
   result:=result||jsonb_build_object(k,private.audit_filter_details_v1(v,costs,balances,contacts));
  end loop;
  return result;
 end if;
 return data;
end $$;
revoke all on function private.audit_filter_details_v1(jsonb,boolean,boolean,boolean) from public,anon,authenticated;

-- AFTER row triggers see OLD and NEW while the writer still owns the balance lock.
create or replace function private.capture_audit_stock_change_v1()
returns trigger language plpgsql security definer set search_path='' as $$
declare old_qty numeric:=0; item jsonb; product uuid; loc uuid; is_pool boolean:=tg_table_name='installation_inventory';
begin
 if tg_op='UPDATE' then old_qty:=old.quantity; end if;
 if old_qty is not distinct from new.quantity then return new; end if;
 if is_pool then
  product:=new.id;
  item:=jsonb_build_object('name_ar',new.name_ar,'name_en',new.name_en,'sku',new.sku,'unit',new.unit);
 else
  product:=new.product_id;loc:=new.location_id;
  select jsonb_build_object('name',p.name,'sku',p.barcode,'unit',u.abbreviation) into item
   from public.products p left join public.product_units u on u.id=p.unit_id where p.id=product;
 end if;
 insert into private.audit_stock_changes_v1(product_id,location_id,pool,quantity_before,quantity_after,item)
 values(product,loc,is_pool,old_qty,new.quantity,coalesce(item,'{}')||jsonb_build_object(
  'quantity_before',old_qty,'quantity_after',new.quantity,'quantity_delta',new.quantity-old_qty,
  'location_id',loc,'branch',(select jsonb_build_object('name_ar',name_ar,'name_en',name_en) from public.locations where id=loc)));
 return new;
end $$;
revoke all on function private.capture_audit_stock_change_v1() from public,anon,authenticated;
drop trigger if exists capture_audit_stock_change_v1 on public.inventory_balances;
create trigger capture_audit_stock_change_v1 after insert or update of quantity on public.inventory_balances
 for each row execute function private.capture_audit_stock_change_v1();
drop trigger if exists capture_audit_stock_change_v1 on public.installation_inventory;
create trigger capture_audit_stock_change_v1 after insert or update of quantity on public.installation_inventory
 for each row execute function private.capture_audit_stock_change_v1();

create or replace function private.link_audit_stock_movement_v1()
returns trigger language plpgsql security definer set search_path='' as $$
declare target bigint; product uuid; loc uuid; is_pool boolean:=tg_table_name='installation_inventory_movements';
begin
 if is_pool then product:=new.inventory_id; else product:=new.product_id;loc:=new.location_id; end if;
 select sequence into target from private.audit_stock_changes_v1
 where transaction_id=pg_current_xact_id() and product_id=product and location_id is not distinct from loc
 and pool=is_pool and movement_id is null and quantity_after-quantity_before=new.quantity_delta
 order by sequence desc limit 1;
 update private.audit_stock_changes_v1 set movement_id=new.id,
 item=item||jsonb_build_object('reason',coalesce(to_jsonb(new)->>'reason',to_jsonb(new)->>'notes'),
 'unit_cost',new.unit_cost_snapshot) where sequence=target;
 return new;
end $$;
revoke all on function private.link_audit_stock_movement_v1() from public,anon,authenticated;
drop trigger if exists link_audit_stock_movement_v1 on public.inventory_movements;
create trigger link_audit_stock_movement_v1 after insert on public.inventory_movements
 for each row execute function private.link_audit_stock_movement_v1();
drop trigger if exists link_audit_stock_movement_v1 on public.installation_inventory_movements;
create trigger link_audit_stock_movement_v1 after insert on public.installation_inventory_movements
 for each row execute function private.link_audit_stock_movement_v1();

-- Enrich existing events instead of introducing duplicate document-level entries.
create or replace function private.capture_audit_event_details_v1()
returns trigger language plpgsql security definer set search_path='' as $$
declare source_name text; subject jsonb:='{}'; doc jsonb:='{}'; items jsonb:='[]'; details jsonb; after_snapshot jsonb;
 related uuid; supplier uuid; account uuid;
begin
 -- The detailed sale writer already captures immutable invoice/item/contact snapshots.
 if new.after_data->>'snapshot_type'='sale_audit_v1' then return new; end if;
 source_name:=case new.entity_type when 'product' then 'products' when 'profile' then 'profiles'
 when 'user' then 'profiles' when 'stock_receipt' then 'stock_receipts' when 'stock_transfer' then 'stock_transfers'
 when 'inventory_snapshot' then 'inventory_snapshots' when 'expense' then 'expenses'
 when 'transaction' then 'transactions' when 'transaction_settlement' then 'transaction_settlements'
 when 'treasury_account' then 'treasury_accounts' when 'treasury_transaction' then 'treasury_transactions'
 when 'customer' then 'customers' when 'supplier' then 'suppliers' when 'installation' then 'installations'
 when 'installation_service' then 'installation_services' when 'installation_inventory' then 'installation_inventory' when 'company_loan' then 'company_loans'
 when 'shift' then 'shifts' when 'location' then 'locations' else null end;
 if source_name is not null and to_regclass('public.'||source_name) is not null then
  execute format('select to_jsonb(r) from public.%I r where id=$1',source_name) into subject using new.entity_id;
 end if;
 if new.entity_type='company_loan' and to_regclass('private.company_loans') is not null then
  execute 'select to_jsonb(r) from private.company_loans r where id=$1' into subject using new.entity_id;
 end if;
 subject:=coalesce(subject,'{}');
 if new.location_id is null and nullif(subject->>'location_id','') is not null then new.location_id:=(subject->>'location_id')::uuid; end if;
 -- Whitelist event context; never snapshot arbitrary table columns such as credentials.
 select coalesce(jsonb_object_agg(key,value),'{}') into doc from jsonb_each(subject)
 where key in ('name','name_ar','name_en','display_name','username','barcode','sku','unit','reference_number',
 'quotation_number','invoice_number','reference','lender','principal','amount','total','amount_paid','amount_due','payment_status','status',
 'payment_method','direction','description','reason','notes','due_date','total_cost');
 supplier:=nullif(subject->>'supplier_id','')::uuid;
 account:=coalesce(nullif(subject->>'account_id','')::uuid,nullif(subject->>'treasury_account_id','')::uuid);
 if supplier is not null then doc:=doc||jsonb_build_object('supplier',(select name from public.suppliers where id=supplier)); end if;
 if nullif(subject->>'customer_id','') is not null then
  doc:=doc||jsonb_build_object('party',(select name from public.customers where id=(subject->>'customer_id')::uuid)); end if;
 if account is not null then doc:=doc||jsonb_build_object('account',(select coalesce(name_en,name_ar) from public.treasury_accounts where id=account)); end if;
 if new.entity_type='company_loan' and to_regclass('private.company_loans') is not null then
  related:=nullif(subject->>'transaction_id','')::uuid;
  if new.action='loan_pay' then
   select transaction_id into related from private.loan_payments where id=(new.after_data->>'id')::uuid;
  end if;
  doc:=doc||jsonb_build_object('account',(select string_agg(distinct coalesce(t.name_en,t.name_ar),', ')
   from public.transaction_allocations a join public.transaction_settlements s on s.id=a.settlement_id
   join public.treasury_accounts t on t.id=s.account_id where a.transaction_id=related));
 end if;
 if new.entity_type in ('stock_receipt','stock_transfer','inventory_snapshot','sale','transaction') then
  related:=coalesce(nullif(subject->>'stock_receipt_id','')::uuid,new.entity_id);
  if subject->>'type'='vendor_return' then
   select stock_receipt_id into related from public.transactions where id=(subject->>'original_transaction_id')::uuid;
  end if;
  select coalesce(jsonb_agg(c.item||jsonb_build_object('_change_sequence',c.sequence) order by c.sequence),'[]') into items
  from private.audit_stock_changes_v1 c join public.inventory_movements m on m.id=c.movement_id
  where c.transaction_id=pg_current_xact_id() and c.event_id is null and
   (m.receipt_id=related or m.transfer_id=related or m.snapshot_id=related or m.sale_id=related);
 elsif new.entity_type='installation_inventory' then
  select coalesce(jsonb_agg(item||jsonb_build_object('_change_sequence',sequence) order by sequence),'[]') into items from private.audit_stock_changes_v1
  where transaction_id=pg_current_xact_id() and event_id is null and pool and product_id=new.entity_id;
 end if;
 update private.audit_stock_changes_v1 set event_id=new.id
 where sequence in (select (value->>'_change_sequence')::bigint from jsonb_array_elements(items));
 details:=jsonb_build_object('version',1,'subject',jsonb_strip_nulls(jsonb_build_object(
  'name',coalesce(doc->>'name',doc->>'display_name',doc->>'description',new.after_data->>'store_name',new.after_data->>'name'),'name_ar',doc->>'name_ar','name_en',doc->>'name_en')),
 'actor',(select jsonb_build_object('name',coalesce(nullif(display_name,''),username)) from public.profiles where id=new.actor_id),
 'branch',(select jsonb_build_object('name_ar',name_ar,'name_en',name_en) from public.locations where id=new.location_id),
 'document',doc,'items',items);
 if new.before_data is not null and jsonb_typeof(new.before_data)<>'object' then
  new.before_data:=jsonb_build_object('recorded_payload',new.before_data);
 end if;
 after_snapshot:=(case when new.after_data is null then '{}'::jsonb
  when jsonb_typeof(new.after_data)='object' then new.after_data
  else jsonb_build_object('recorded_payload',new.after_data) end)||jsonb_build_object('audit_details',details);
 insert into private.audit_event_details_v1(event_id,before_data,after_data) values(new.id,
  private.audit_filter_details_v1(new.before_data,true,true,true),private.audit_filter_details_v1(after_snapshot,true,true,true));
 new.before_data:=private.audit_filter_details_v1(new.before_data);
 -- Item details are private: direct audit-table reads cannot bypass per-branch filtering.
 new.after_data:=jsonb_set(private.audit_filter_details_v1(after_snapshot),'{audit_details,items}','[]');
 return new;
end $$;
revoke all on function private.capture_audit_event_details_v1() from public,anon,authenticated;
drop trigger if exists capture_audit_event_details_v1 on public.audit_events;
create trigger capture_audit_event_details_v1 before insert on public.audit_events
 for each row execute function private.capture_audit_event_details_v1();

-- Metadata edits without an existing detailed writer also get readable field diffs.
create or replace function private.audit_record_metadata_v1()
returns trigger language plpgsql security definer set search_path='' as $$
declare previous jsonb:='{}'; current_data jsonb:='{}'; entity text; fields text[]; key_value text; object_id uuid;
begin
 entity:=case tg_table_name when 'store_settings' then 'settings' when 'profiles' then 'profile'
  when 'installation_services' then 'installation_service' else 'product' end;
 fields:=case tg_table_name
  when 'store_settings' then array['store_name','tax_rate','currency','invoice_prefix','logo_path','theme_palette']
  when 'profiles' then array['display_name','username','role','is_active']
  when 'installation_services' then array['name_ar','name_en','unit_price','price','default_cost','is_active','is_default']
  else array['name','barcode','is_active','unit_id','category_id','warranty_months','origin_type'] end;
 if tg_op='UPDATE' then
  select coalesce(jsonb_object_agg(key,value),'{}') into previous from jsonb_each(to_jsonb(old)) where key=any(fields);
 end if;
 select coalesce(jsonb_object_agg(key,value),'{}') into current_data from jsonb_each(to_jsonb(new)) where key=any(fields);
 if previous=current_data then return new; end if;
 key_value:=to_jsonb(new)->>'id';
 if key_value ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then object_id:=key_value::uuid; end if;
 insert into public.audit_events(actor_id,action,entity_type,entity_id,before_data,after_data)
 values(auth.uid(),entity||case when tg_op='INSERT' then '_created' else '_updated' end,entity,object_id,
  case when tg_op='UPDATE' then previous else null end,current_data);
 return new;
end $$;
revoke all on function private.audit_record_metadata_v1() from public,anon,authenticated;
do $$ declare target text; begin
 foreach target in array array['store_settings','profiles','products','installation_services'] loop
  if to_regclass('public.'||target) is not null then
   execute format('drop trigger if exists audit_record_metadata_v1 on public.%I',target);
   execute format('create trigger audit_record_metadata_v1 after insert or update on public.%I for each row execute function private.audit_record_metadata_v1()',target);
  end if;
 end loop;
end $$;

-- Keep the old reader's RLS, scope, sale/contact projection and duplicate suppression.
do $$ declare definition text; begin
 if to_regprocedure('private.read_audit_events_before_details_v1(jsonb)') is null then
  select pg_get_functiondef('public.read_audit_events_v1(jsonb)'::regprocedure) into definition;
  execute replace(definition,'public.read_audit_events_v1(', 'private.read_audit_events_before_details_v1(');
 end if;
end $$;
revoke all on function private.read_audit_events_before_details_v1(jsonb) from public,anon;
-- This SECURITY INVOKER helper still uses the existing authorized audit projection.
grant execute on function private.read_audit_events_before_details_v1(jsonb) to authenticated;

create or replace function private.project_audit_details_v1(event_input jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare e public.audit_events%rowtype; saved private.audit_event_details_v1%rowtype;
 actor uuid:=auth.uid(); costs boolean:=false; balances boolean:=false; contacts boolean:=false;
 cost_permission text; balance_permission text; result jsonb; visible_items jsonb; item jsonb; loc uuid;
begin
 select * into e from public.audit_events where id=(event_input->>'id')::uuid;
 if not found or not private.actor_is_active_v1() or not private.branch_scope_row('audit_events',to_jsonb(e),false) then return null; end if;
 if private.access_v2_enabled(actor) then
  if not private.access_v2_visible('audit_events',to_jsonb(e),false) then return null; end if;
  if not private.access_v2_allows(actor,'audit_event.snapshot.read',e.location_id) then
   return event_input||jsonb_build_object('before_data',null,'after_data',null); end if;
  cost_permission:=case when e.entity_type='product' then 'product_cost.read'
   when e.entity_type in ('stock_receipt','stock_transfer','inventory_snapshot','inventory_balance','installation_inventory') then 'inventory_cost.read' else 'report_cost.read' end;
  balance_permission:=case when e.entity_type='customer' then 'customer_financial.read' when e.entity_type='supplier' then 'supplier_financial.read' else 'treasury_account.balance.read' end;
  costs:=private.access_v2_allows(actor,cost_permission,e.location_id);
  balances:=private.access_v2_allows(actor,balance_permission,e.location_id);
  -- Contacts remain handled by the existing sale/contact helper. No new generic contact exposure.
 else
  if not private.has_permission(actor,'viewAudit') or (e.location_id is not null and not private.has_location_access(actor,e.location_id)) then return null; end if;
  costs:=private.has_permission(actor,'viewReports');
  balances:=exists(select 1 from public.profiles where id=actor and role='admin');
 end if;
 select * into saved from private.audit_event_details_v1 where event_id=e.id;
 if not found then
  if e.after_data->>'snapshot_type'='sale_audit_v1' then return event_input; end if;
  return event_input||jsonb_build_object('before_data',private.audit_filter_details_v1(event_input->'before_data',costs,balances,contacts),
   'after_data',private.audit_filter_details_v1(event_input->'after_data',costs,balances,contacts));
 end if;
 result:=event_input||jsonb_build_object('before_data',private.audit_filter_details_v1(saved.before_data,costs,balances,contacts),
  'after_data',private.audit_filter_details_v1(saved.after_data,costs,balances,contacts));
 visible_items:='[]';
 for item in select value from jsonb_array_elements(coalesce(result#>'{after_data,audit_details,items}','[]')) loop
  loc:=nullif(item->>'location_id','')::uuid;
  if loc is null or (private.branch_scope_row('audit_events',jsonb_build_object('location_id',loc),false)
   and (not private.access_v2_enabled(actor) and private.has_location_access(actor,loc)
    or private.access_v2_enabled(actor) and private.access_v2_allows(actor,'audit_event.snapshot.read',loc))) then
   visible_items:=visible_items||jsonb_build_array(private.audit_filter_details_v1(item-'_change_sequence',costs and loc is not distinct from e.location_id,balances,false));
  end if;
 end loop;
 return jsonb_set(result,'{after_data,audit_details,items}',visible_items);
end $$;
revoke all on function private.project_audit_details_v1(jsonb) from public,anon;
grant execute on function private.project_audit_details_v1(jsonb) to authenticated;

create or replace function public.read_audit_events_v1(input jsonb default '{}')
returns jsonb language plpgsql security invoker set search_path='' as $$
declare rows jsonb; item jsonb; projected jsonb; result jsonb:='[]';
begin
 rows:=private.read_audit_events_before_details_v1(input);
 for item in select value from jsonb_array_elements(rows) loop
  projected:=private.project_audit_details_v1(item);
  if projected is not null then result:=result||jsonb_build_array(projected); end if;
 end loop;
 return result;
end $$;
revoke all on function public.read_audit_events_v1(jsonb) from public,anon;
grant execute on function public.read_audit_events_v1(jsonb) to authenticated;
insert into private.access_v2_rpc_registry(signature,function_oid,original_definition)
 values('read_audit_events_v1(jsonb)','public.read_audit_events_v1(jsonb)'::regprocedure,pg_get_functiondef('public.read_audit_events_v1(jsonb)'::regprocedure))
 on conflict(signature) do update set function_oid=excluded.function_oid,original_definition=excluded.original_definition;
notify pgrst,'reload schema';
commit;
