-- PLUGY PRODUCTION UPDATE — 5 November 2026
-- Target project: orbovqzenjlyshhiuofx. Select that project before running.
-- Run this ENTIRE file once in Supabase SQL Editor as the migration owner.
-- For the existing production schema only: this is not a fresh installer.
-- Installs/reapplies shared installation inventory, detailed future-sale audits,
-- employee multi-branch access, asset photos, installation workflow and company loans.
-- Existing rows are retained; missing sale-to-quotation links are backfilled.
-- Earlier accounting/refund/fee/balance-sheet/installation-financials updates
-- must already be installed. Do not replay those historical installers here.
-- This file does NOT change Supabase Auth Site URL or Redirect URLs. Set those
-- in Authentication > URL Configuration to your actual production website.
-- No passwords, balances, historical sales or existing memberships are reset.
-- Everything commits together. Any failure rolls the transaction back; stop
-- and report the error rather than removing prerequisite/compatibility checks.

begin;
set transaction isolation level repeatable read;
set local lock_timeout = '10s';
select pg_advisory_xact_lock(hashtext('plugy-production-update-20261105'));

do $preflight$
declare missing text[] := '{}'; item text;
begin
 foreach item in array array[
  'public.profiles','public.profile_locations','public.sales','public.sale_items',
  'public.installation_lines','public.expenses','public.inventory_balances',
  'public.audit_events','public.transactions','public.transaction_settlements',
  'public.treasury_transactions','private.access_v2_state',
  'private.access_v2_rpc_registry','private.accounting_cash_classes','storage.buckets','storage.objects'
 ] loop
  if to_regclass(item) is null then missing := array_append(missing,item); end if;
 end loop;
 foreach item in array array[
  'public.admin_save_user_v1(jsonb,text,text)',
  'public.admin_access_command_v2(jsonb)',
  'public.access_management_overview_v2()',
  'public.replace_expense_v1(jsonb,jsonb,jsonb)',
  'public.save_installation_finance_v1(jsonb,jsonb)',
  'public.installation_services_v3(jsonb)',
  'public.installation_quotes_v3(jsonb)',
  'private.complete_installation_document_v1(jsonb,uuid)',
  'private.complete_refund_documents_v1(jsonb,jsonb)',
  'private.refund_line_gross_v3(uuid)',
  'private.branch_scope_location(uuid,uuid,boolean)',
  'private.branch_scope_row(text,jsonb,boolean)',
  'private.access_v2_allows(uuid,text,uuid,uuid[])'
 ] loop
  if to_regprocedure(item) is null then missing := array_append(missing,item); end if;
 end loop;
 if cardinality(missing)>0 then
  raise exception 'PRODUCTION_UPDATE_PREREQUISITES_MISSING: %',array_to_string(missing,', ');
 end if;
end $preflight$;

-- Snapshot business counts and financial/inventory totals in this transaction.
-- The check below rejects any unintended change made by this update itself.
create temporary table plugy_update_baseline(metric text primary key,value numeric) on commit drop;
do $baseline$
declare item text; n bigint;
begin
 foreach item in array array['profiles','profile_locations','sales','sale_items',
  'expenses','transactions','transaction_settlements','treasury_transactions',
  'inventory_balances','inventory_movements'] loop
  execute format('select count(*) from public.%I',item) into n;
  insert into plugy_update_baseline values(item,n);
 end loop;
end $baseline$;
insert into plugy_update_baseline values
 ('sales_total',(select coalesce(sum(total),0) from public.sales)),
 ('expenses_total',(select coalesce(sum(amount),0) from public.expenses)),
 ('inventory_quantity',(select coalesce(sum(quantity),0) from public.inventory_balances)),
 ('inventory_value',(select coalesce(sum(quantity*weighted_unit_cost),0) from public.inventory_balances));


-- SOURCE: 20261112000000_global_installation_inventory.sql
-- SHA256: 53bf434921f9ef23bf0190c8da686a84750205f4347eaee4e2e21c3f0be4b159
-- A separate, company-wide pool. Existing products and branch balances are untouched.
create table if not exists public.installation_inventory (
 id uuid primary key default gen_random_uuid(),
 sku text not null unique check(length(btrim(sku)) between 1 and 100),
 name_ar text not null check(length(btrim(name_ar)) between 1 and 300),
 name_en text not null check(length(btrim(name_en)) between 1 and 300),
 kind text not null check(kind in ('variableMaterial','fixedMaterial','optionalProtection')),
 unit text not null check(length(btrim(unit)) between 1 and 50),
 price numeric(14,2) not null check(price>=0 and price<'Infinity'::numeric),
 quantity numeric(14,3) not null default 0 check(quantity>=0 and quantity<'Infinity'::numeric),
 unit_cost numeric(14,4) not null default 0 check(unit_cost>=0 and unit_cost<'Infinity'::numeric),
 is_active boolean not null default true,
 updated_at timestamptz not null default now()
);
create table if not exists public.installation_inventory_movements (
 id uuid primary key default gen_random_uuid(),
 inventory_id uuid not null references public.installation_inventory(id) on delete restrict,
 quantity_delta numeric(14,3) not null check(abs(quantity_delta)<'Infinity'::numeric),
 value_delta numeric(14,2) not null,
 unit_cost_snapshot numeric(14,4) not null,
 check(quantity_delta<>0 or value_delta<>0),
 reason text not null,
 sale_id uuid references public.sales(id) on delete restrict,
 actor_id uuid not null references public.profiles(id) on delete restrict,
 created_at timestamptz not null default now()
);
create index if not exists installation_inventory_movements_item_idx
 on public.installation_inventory_movements(inventory_id,created_at desc);
create index if not exists installation_inventory_movements_sale_idx
 on public.installation_inventory_movements(sale_id) where sale_id is not null;
alter table public.installation_inventory enable row level security;
alter table public.installation_inventory_movements enable row level security;
revoke all on public.installation_inventory,public.installation_inventory_movements from public,anon,authenticated;
do $$ declare t text; begin
 if to_regclass('private.access_v2_permissions') is null then return; end if;
 foreach t in array array['installation_inventory','installation_inventory_movements'] loop
  if not exists(select 1 from pg_policies where schemaname='public' and tablename=t and policyname='access_v2_guard_select') then
   execute format('create policy access_v2_guard_select on public.%I as restrictive for select to authenticated using(false)',t);
  end if;
 end loop;
end $$;

alter table public.installation_lines add column if not exists installation_inventory_id uuid
 references public.installation_inventory(id) on delete restrict;
alter table public.sale_items add column if not exists installation_inventory_id uuid
 references public.installation_inventory(id) on delete restrict;
create index if not exists installation_lines_pool_idx on public.installation_lines(installation_inventory_id)
 where installation_inventory_id is not null;
create index if not exists sale_items_pool_idx on public.sale_items(installation_inventory_id)
 where installation_inventory_id is not null;

-- Compatibility with the legacy permissions and with explicitly delegated v2 permissions.
create or replace function private.installation_inventory_allows_v1(action text)
returns boolean language plpgsql stable security definer set search_path='' as $$
begin
 if not private.actor_is_active_v1() then return false; end if;
 if to_regprocedure('private.access_v2_enabled(uuid)') is not null then
  if private.access_v2_enabled(auth.uid()) then
   return private.access_v2_allows(auth.uid(),'installation_inventory.'||action);
  end if;
 end if;
 return case action
  when 'manage' then coalesce(private.has_permission(auth.uid(),'manageInventory'),false)
  when 'use' then coalesce(private.has_permission(auth.uid(),'posCheckout'),false)
  when 'read' then coalesce(private.has_permission(auth.uid(),'posCheckout'),false)
    or coalesce(private.has_permission(auth.uid(),'manageInventory'),false)
  else false end;
end $$;
revoke all on function private.installation_inventory_allows_v1(text) from public,anon,authenticated;

create or replace function public.installation_inventory_v1(input jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
declare target uuid; previous public.installation_inventory%rowtype; saved public.installation_inventory%rowtype;
 delta numeric; value_change numeric; can_manage boolean;
begin
 if not private.installation_inventory_allows_v1('read') then
  raise exception using errcode='42501',message='INSTALLATION_INVENTORY_ACCESS_DENIED'; end if;
 can_manage:=private.installation_inventory_allows_v1('manage');
 if coalesce(input->>'action','list') not in ('list','save') then raise exception 'INVALID_INVENTORY_ACTION'; end if;
 if input->>'action'='save' then
  if not can_manage then raise exception using errcode='42501',message='INSTALLATION_INVENTORY_MANAGE_DENIED'; end if;
  target:=nullif(input->>'id','')::uuid;
  if target is not null then
   select * into previous from public.installation_inventory where id=target for update;
   if not found then raise exception 'INSTALLATION_INVENTORY_NOT_FOUND'; end if;
   -- Reject stale stock edits instead of overwriting a sale posted since the form opened.
   if (input->>'expected_quantity')::numeric is distinct from previous.quantity then
    raise exception 'INSTALLATION_INVENTORY_CHANGED_REFRESH'; end if;
  else target:=gen_random_uuid(); end if;
  delta:=coalesce((input->>'quantity')::numeric,0)-coalesce(previous.quantity,0);
  if delta<>0 and nullif(btrim(input->>'reason'),'') is null then raise exception 'STOCK_REASON_REQUIRED'; end if;
  insert into public.installation_inventory(id,sku,name_ar,name_en,kind,unit,price,quantity,unit_cost,is_active)
  values(target,btrim(input->>'sku'),btrim(input->>'name_ar'),btrim(input->>'name_en'),input->>'kind',
   btrim(input->>'unit'),(input->>'price')::numeric,coalesce((input->>'quantity')::numeric,0),
   coalesce((input->>'unit_cost')::numeric,0),coalesce((input->>'is_active')::boolean,true))
  on conflict(id) do update set sku=excluded.sku,name_ar=excluded.name_ar,name_en=excluded.name_en,
   kind=excluded.kind,unit=excluded.unit,price=excluded.price,quantity=excluded.quantity,
   unit_cost=excluded.unit_cost,is_active=excluded.is_active,updated_at=now()
  returning * into saved;
  value_change:=round(saved.quantity*saved.unit_cost-coalesce(previous.quantity*previous.unit_cost,0),2);
  if delta<>0 or value_change<>0 then
   if nullif(btrim(input->>'reason'),'') is null then raise exception 'STOCK_REASON_REQUIRED'; end if;
   insert into public.installation_inventory_movements(inventory_id,quantity_delta,value_delta,unit_cost_snapshot,reason,actor_id)
   values(target,delta,value_change,saved.unit_cost,btrim(input->>'reason'),auth.uid());
  end if;
  insert into public.audit_events(actor_id,action,entity_type,entity_id,before_data,after_data)
  values(auth.uid(),'installation_inventory_saved','installation_inventory',target,
   case when previous.id is null then null else to_jsonb(previous) end,to_jsonb(saved)||jsonb_build_object('reason',input->>'reason'));
 end if;
 return (select coalesce(jsonb_agg(
  case when can_manage then to_jsonb(i) else to_jsonb(i)-'unit_cost' end order by i.name_en),'[]')
  from public.installation_inventory i where can_manage or i.is_active);
end $$;
revoke all on function public.installation_inventory_v1(jsonb) from public,anon;
grant execute on function public.installation_inventory_v1(jsonb) to authenticated;

-- The existing quotation writer remains responsible for branch permissions, money,
-- customer identity, deposits and saved receipt wording.
do $$ declare definition text; begin
 if to_regprocedure('private.installation_inventory_previous_v1(jsonb,jsonb)') is null then
  select pg_get_functiondef('public.save_installation_finance_v1(jsonb,jsonb)'::regprocedure) into definition;
  execute replace(definition,'public.save_installation_finance_v1(', 'private.installation_inventory_previous_v1(');
 end if;
end $$;
revoke all on function private.installation_inventory_previous_v1(jsonb,jsonb) from public,anon,authenticated;
create or replace function public.save_installation_finance_v1(input jsonb,lines_input jsonb)
returns uuid language plpgsql security definer set search_path='' as $$
declare target uuid; line jsonb; item public.installation_inventory%rowtype; previous jsonb; current_data jsonb;
begin
 select to_jsonb(i)||jsonb_build_object('lines',coalesce((select jsonb_agg(to_jsonb(l)) from public.installation_lines l where l.installation_id=i.id),'[]'))
 into previous from public.installations i where i.quotation_number=input->>'quotation_number';
 if exists(select 1 from public.installation_lines l join public.installations i on i.id=l.installation_id
  join jsonb_array_elements(lines_input) v on v->>'client_line_id'=l.client_line_id
  where i.quotation_number=input->>'quotation_number' and l.installation_inventory_id is not null
   and nullif(v->>'installation_inventory_id','')::uuid is distinct from l.installation_inventory_id) then
  raise exception 'INSTALLATION_INVENTORY_REFERENCE_REQUIRED'; end if;
 if exists(select 1 from jsonb_array_elements(lines_input) v where nullif(v->>'installation_inventory_id','') is not null) then
  if not private.installation_inventory_allows_v1('use') then
   raise exception using errcode='42501',message='INSTALLATION_INVENTORY_USE_DENIED'; end if;
  if exists(select 1 from jsonb_array_elements(lines_input) v group by v->>'client_line_id'
    having count(*)>1) then raise exception 'DUPLICATE_INSTALLATION_LINE'; end if;
 end if;
 for line in select value from jsonb_array_elements(lines_input) where nullif(value->>'installation_inventory_id','') is not null loop
  select * into item from public.installation_inventory where id=(line->>'installation_inventory_id')::uuid and is_active;
  if not found then raise exception 'INSTALLATION_INVENTORY_UNAVAILABLE'; end if;
  if nullif(line->>'client_line_id','') is null or nullif(line->>'product_id','') is not null
   or line->>'kind' is distinct from item.kind then raise exception 'INVALID_INSTALLATION_INVENTORY_LINE'; end if;
 end loop;
 target:=private.installation_inventory_previous_v1(input,lines_input);
 update public.installation_lines l set installation_inventory_id=(v->>'installation_inventory_id')::uuid
 from jsonb_array_elements(lines_input) v where l.installation_id=target and l.client_line_id=v->>'client_line_id'
  and nullif(v->>'installation_inventory_id','') is not null;
 select to_jsonb(i)||jsonb_build_object('lines',coalesce((select jsonb_agg(to_jsonb(l)) from public.installation_lines l where l.installation_id=i.id),'[]'))
 into current_data from public.installations i where i.id=target;
 insert into public.audit_events(actor_id,action,entity_type,entity_id,location_id,before_data,after_data)
 values(auth.uid(),'installation_details_saved','installation',target,(input->>'location_id')::uuid,previous,current_data);
 return target;
end $$;
revoke all on function public.save_installation_finance_v1(jsonb,jsonb) from public,anon;
grant execute on function public.save_installation_finance_v1(jsonb,jsonb) to authenticated;

create or replace function private.consume_installation_inventory_v1(target uuid,qty numeric,sale uuid)
returns numeric language plpgsql security definer set search_path='' as $$
declare item public.installation_inventory%rowtype;
begin
 if not private.installation_inventory_allows_v1('use') then
  raise exception using errcode='42501',message='INSTALLATION_INVENTORY_USE_DENIED'; end if;
 select * into item from public.installation_inventory where id=target for update;
 if item.id is null or not item.is_active then raise exception 'INSTALLATION_INVENTORY_UNAVAILABLE'; end if;
 if qty is null or qty<=0 or qty>item.quantity then raise exception 'INSUFFICIENT_INSTALLATION_STOCK'; end if;
 update public.installation_inventory set quantity=quantity-qty,updated_at=now() where id=target;
 insert into public.installation_inventory_movements(inventory_id,quantity_delta,value_delta,unit_cost_snapshot,reason,sale_id,actor_id)
 values(target,-qty,-round(qty*item.unit_cost,2),item.unit_cost,'Installation sale',sale,auth.uid());
 insert into public.audit_events(actor_id,action,entity_type,entity_id,location_id,before_data,after_data)
 values(auth.uid(),'installation_inventory_consumed','installation_inventory',target,
  (select location_id from public.sales where id=sale),jsonb_build_object('quantity',item.quantity),
  jsonb_build_object('quantity',item.quantity-qty,'sale_id',sale));
 return item.unit_cost;
end $$;
revoke all on function private.consume_installation_inventory_v1(uuid,numeric,uuid) from public,anon,authenticated;

-- Extend the checked sale writer without replacing its pricing, warranty or shift checks.
do $$ declare definition text; begin
 select pg_get_functiondef('private.complete_installation_document_v1(jsonb,uuid)'::regprocedure) into definition;
 if position('consume_installation_inventory_v1' in definition)=0 then
  if position('if line.kind<>''service'' then' in definition)=0 then raise exception 'INSTALLATION_WRITER_INCOMPATIBLE'; end if;
  definition:=replace(definition,'if coalesce(sale_input->>''tax_mode'',''legacy'')=''legacy'' then return',
   'if coalesce(sale_input->>''tax_mode'',''legacy'')=''legacy'' and exists(select 1 from public.installation_lines where installation_id=installation and is_selected and installation_inventory_id is not null) then
    raise exception ''CURRENT_INSTALLATION_CHECKOUT_REQUIRED''; end if;
    if coalesce(sale_input->>''tax_mode'',''legacy'')=''legacy'' then return');
  definition:=replace(definition,'if line.kind<>''service'' then',
   'if line.installation_inventory_id is not null then
     cost_value:=private.consume_installation_inventory_v1(line.installation_inventory_id,qty,result);
    elsif line.kind<>''service'' then');
  definition:=replace(definition,'insert into public.sale_items(sale_id,product_id,',
   'insert into public.sale_items(installation_inventory_id,sale_id,product_id,');
  definition:=replace(definition,'values(result,product_value,',
   'values(line.installation_inventory_id,result,product_value,');
  -- Lock shared items in a consistent order before any stock is consumed.
  definition:=replace(definition,'for line in select * from public.installation_lines where installation_id=i.id and is_selected order by product_id,id loop',
   'perform 1 from public.installation_inventory where id in
     (select installation_inventory_id from public.installation_lines where installation_id=i.id and is_selected)
     order by id for update;
    for line in select * from public.installation_lines where installation_id=i.id and is_selected order by product_id,id loop');
  execute definition;
 end if;
end $$;

-- Refunds return materials to this same pool, including inactive catalog items.
create or replace function private.restore_installation_inventory_v1(target uuid,qty numeric,cost numeric,refund uuid)
returns void language plpgsql security definer set search_path='' as $$
declare restored numeric;
begin
 update public.installation_inventory set
  unit_cost=round((quantity*unit_cost+qty*cost)/(quantity+qty),4),
  quantity=quantity+qty,updated_at=now() where id=target returning quantity into restored;
 if not found then raise exception 'INSTALLATION_INVENTORY_NOT_FOUND'; end if;
 insert into public.installation_inventory_movements(inventory_id,quantity_delta,value_delta,unit_cost_snapshot,reason,sale_id,actor_id)
 values(target,qty,round(qty*cost,2),cost,'Installation refund',refund,auth.uid());
 insert into public.audit_events(actor_id,action,entity_type,entity_id,location_id,before_data,after_data)
 values(auth.uid(),'installation_inventory_returned','installation_inventory',target,
  (select location_id from public.sales where id=refund),jsonb_build_object('quantity',restored-qty),
  jsonb_build_object('quantity',restored,'sale_id',refund));
end $$;
revoke all on function private.restore_installation_inventory_v1(uuid,numeric,numeric,uuid) from public,anon,authenticated;
do $$ declare definition text; begin
 select pg_get_functiondef('private.complete_refund_documents_v1(jsonb,jsonb)'::regprocedure) into definition;
 if position('restore_installation_inventory_v1' in definition)=0 then
  if position('total_value:=total_value+gross;' in definition)>0 then
   definition:=replace(definition,'insert into public.sale_items(sale_id,original_sale_item_id,product_id,',
    'insert into public.sale_items(installation_inventory_id,sale_id,original_sale_item_id,product_id,');
   definition:=replace(definition,'values(return_id,line.id,line.product_id,',
    'values(line.installation_inventory_id,return_id,line.id,line.product_id,');
   definition:=replace(definition,'total_value:=total_value+gross;',
    'if line.installation_inventory_id is not null then
      perform private.restore_installation_inventory_v1(line.installation_inventory_id,qty,unit_cost,return_id);
     end if;
     total_value:=total_value+gross;');
  elsif position('computed_total := computed_total + line_total_value;' in definition)=0 then raise exception 'REFUND_WRITER_INCOMPATIBLE'; end if;
  definition:=replace(definition,'sale_id, product_id, product_barcode, product_name, unit_abbreviation,',
    'installation_inventory_id, sale_id, product_id, product_barcode, product_name, unit_abbreviation,');
  definition:=replace(definition,'refund_id_value, original_item.product_id, original_item.product_barcode,',
    'original_item.installation_inventory_id, refund_id_value, original_item.product_id, original_item.product_barcode,');
  definition:=replace(definition,'computed_total := computed_total + line_total_value;',
   'if original_item.installation_inventory_id is not null then
     perform private.restore_installation_inventory_v1(original_item.installation_inventory_id,quantity_value,original_item.unit_cost_snapshot,refund_id_value);
    end if;
    computed_total := computed_total + line_total_value;');
  execute definition;
 end if;
end $$;

-- Record account removal/deactivation and user deactivation with exact snapshots.
-- Profile credentials and PIN material never enter the audit log.
create or replace function private.audit_account_metadata_v1()
returns trigger language plpgsql security definer set search_path='' as $$
declare before_value jsonb; after_value jsonb; entity text; loc uuid;
begin
 if auth.uid() is null then return null; end if;
 if tg_table_name='profiles' then
  if old.is_active is not distinct from new.is_active then return null; end if;
  before_value:=jsonb_build_object('username',old.username,'display_name',old.display_name,'is_active',old.is_active);
  after_value:=jsonb_build_object('username',new.username,'display_name',new.display_name,'is_active',new.is_active);
  entity:='user';
 else
  before_value:=to_jsonb(old); after_value:=case when tg_op='DELETE' then null else to_jsonb(new) end;
  if before_value-'updated_at' is not distinct from after_value-'updated_at' then return null; end if;
  entity:='treasury_account'; loc:=old.location_id;
 end if;
 insert into public.audit_events(actor_id,action,entity_type,entity_id,location_id,before_data,after_data)
 values(auth.uid(),entity||case when tg_op='DELETE' then '_deleted' else '_updated' end,entity,old.id,loc,before_value,after_value);
 return null;
end $$;
revoke all on function private.audit_account_metadata_v1() from public,anon,authenticated;
drop trigger if exists audit_account_metadata_v1 on public.treasury_accounts;
create trigger audit_account_metadata_v1 after update or delete on public.treasury_accounts
 for each row execute function private.audit_account_metadata_v1();
drop trigger if exists audit_user_deactivation_v1 on public.profiles;
create trigger audit_user_deactivation_v1 after update of is_active on public.profiles
 for each row execute function private.audit_account_metadata_v1();

-- Extend accounting when installed; retain its existing permissions and reports.
-- Pool opening/recount values balance to suspense. Sale/refund stock is moved
-- between the shared pool and the fulfillment branch before the existing COGS entry.
do $do$ declare definition text; begin
 if to_regprocedure('private.accounting_lines_v1(timestamptz)') is null then return; end if;
 if to_regprocedure('private.installation_inventory_accounting_previous_v1(timestamptz)') is null then
  select pg_get_functiondef('private.accounting_lines_v1(timestamptz)'::regprocedure) into definition;
  execute replace(definition,'private.accounting_lines_v1(', 'private.installation_inventory_accounting_previous_v1(');
 end if;
 execute $sql$create or replace function private.accounting_lines_v1(cutoff timestamptz)
 returns table(source_id uuid,location_id uuid,occurred_at timestamptz,account text,amount numeric)
 language sql stable security definer set search_path='' set timezone='Africa/Cairo' as $ledger$
  select * from private.installation_inventory_accounting_previous_v1(cutoff)
  union all select m.id,null::uuid,m.created_at,'inventory',m.value_delta
   from public.installation_inventory_movements m where m.created_at<cutoff
  union all select m.id,s.location_id,m.created_at,'inventory',-m.value_delta
   from public.installation_inventory_movements m join public.sales s on s.id=m.sale_id where m.created_at<cutoff
  union all select m.id,null::uuid,m.created_at,'suspense',-m.value_delta
   from public.installation_inventory_movements m where m.sale_id is null and m.created_at<cutoff;
 $ledger$ $sql$;
 execute 'revoke all on function private.installation_inventory_accounting_previous_v1(timestamptz) from public,anon,authenticated';
end $do$;

-- Redacted views gain only the pool identity; existing column redactions remain intact.
do $$ declare relation_name text; definition text; begin
 foreach relation_name in array array['sale_items','installation_lines'] loop
  if to_regclass('public.access_v2_'||relation_name) is null then continue; end if;
  if exists(select 1 from information_schema.columns where table_schema='public'
   and table_name='access_v2_'||relation_name and column_name='installation_inventory_id') then continue; end if;
  definition:=pg_get_viewdef(('public.access_v2_'||relation_name)::regclass,true);
  definition:=regexp_replace(definition,'(\s+FROM (public\.)?'||relation_name||' r)',', r.installation_inventory_id\1','i');
  execute 'create or replace view public.access_v2_'||relation_name||' with(security_barrier=true) as '||definition;
 end loop;
 if to_regclass('private.access_v2_permissions') is not null then
  insert into private.access_v2_permissions(id,scope,write_action,dependencies) values
   ('installation_inventory.read','global',false,'{}'),
   ('installation_inventory.use','global',true,array['installation_inventory.read']),
   ('installation_inventory.manage','global',true,array['installation_inventory.read'])
  on conflict(id) do nothing;
  insert into private.access_v2_rpc_registry(signature,function_oid,original_definition)
  values('installation_inventory_v1(jsonb)','public.installation_inventory_v1(jsonb)'::regprocedure,
   pg_get_functiondef('public.installation_inventory_v1(jsonb)'::regprocedure))
  on conflict(signature) do update set function_oid=excluded.function_oid,original_definition=excluded.original_definition;
  update private.access_v2_state set revision=revision+1;
 end if;
end $$;
notify pgrst,'reload schema';


-- SOURCE: 20261113000000_detailed_sale_audit.sql
-- SHA256: 9ebe6b4fe9bd4b890d55f0f83fe1c1404488019c5f989f12f72c22e4e1fdeafe
-- Created with the CLI, ordered after the shared installation inventory release.
-- New posted sales only: historical events and invoices are never rewritten.
-- Phone snapshots live outside the public audit JSON so raw reads cannot bypass
-- the customer's contact permissions.
create table if not exists private.audit_sale_contacts_v1 (
 event_id uuid primary key references public.audit_events(id) on delete restrict,
 phone text not null
);
alter table private.audit_sale_contacts_v1 enable row level security;
revoke all on private.audit_sale_contacts_v1 from public,anon,authenticated;
create unique index if not exists audit_sale_details_once_v1 on public.audit_events(entity_id)
 where entity_type='sale' and action in ('sale_details_recorded','refund_details_recorded');

create or replace function private.record_sale_audit_v1()
returns trigger language plpgsql security definer set search_path='' as $$
declare invoice public.sales%rowtype; seller_name text; customer_name text; customer_phone text;
 branch jsonb; items jsonb; snapshot jsonb; event uuid;
begin
 select * into invoice from public.sales where id=new.id;
 if not found then return null; end if;
 select coalesce(nullif(display_name,''),username) into seller_name from public.profiles where id=invoice.user_id;
 customer_name:=nullif(invoice.customer_name_snapshot,'');
 customer_phone:=nullif(invoice.customer_phone_snapshot,'');
 select jsonb_build_object('id',id,'name_ar',name_ar,'name_en',name_en) into branch
 from public.locations where id=invoice.location_id;
 select coalesce(jsonb_agg(jsonb_build_object(
  'id',si.id,'product_id',si.product_id,'name',si.product_name,'sku',si.product_barcode,
  'quantity',si.quantity,'unit',si.unit_abbreviation,
  'unit_price',si.sale_price,'unit_discount',coalesce(si.item_discount,0),
  'line_total',private.refund_line_gross_v3(si.id)) order by si.product_barcode,si.id),'[]') into items
 from public.sale_items si where si.sale_id=invoice.id;
 snapshot:=jsonb_build_object('snapshot_type','sale_audit_v1','invoice_id',invoice.id,
  'invoice_date',invoice.created_at,'is_refund',invoice.is_refund,'original_sale_id',invoice.original_sale_id,
  'seller',jsonb_build_object('id',invoice.user_id,'name',seller_name),
  'customer',jsonb_build_object('id',invoice.customer_id,'name',customer_name),
  'branch',branch,'items',items,
  'amounts',jsonb_build_object('subtotal',invoice.subtotal,'discount',invoice.discount_amount,
   'tax',invoice.tax_total,'total',invoice.total,'paid',invoice.amount_paid,'due',invoice.amount_due,
   'payment_status',invoice.payment_status));
 insert into public.audit_events(actor_id,action,entity_type,entity_id,location_id,after_data)
 values(coalesce(auth.uid(),invoice.user_id),case when invoice.is_refund then 'refund_details_recorded' else 'sale_details_recorded' end,
  'sale',invoice.id,invoice.location_id,snapshot)
 on conflict do nothing returning id into event;
 if event is not null and customer_phone is not null then
  insert into private.audit_sale_contacts_v1(event_id,phone) values(event,customer_phone);
 end if;
 return null;
end $$;
revoke all on function private.record_sale_audit_v1() from public,anon,authenticated;
-- Run after the entire checkout transaction: items, discounts, fees, deposits
-- and payments must all be final before the immutable snapshot is written.
drop trigger if exists record_sale_audit_v1 on public.sales;
create constraint trigger record_sale_audit_v1 after insert on public.sales
 deferrable initially deferred for each row execute function private.record_sale_audit_v1();

create or replace function private.audit_sale_phone_for_actor_v1(target uuid)
returns text language plpgsql stable security definer set search_path='' as $$
declare event public.audit_events%rowtype; actor uuid:=auth.uid();
begin
 if not private.actor_is_active_v1() then return null; end if;
 select * into event from public.audit_events where id=target;
 if not found then return null; end if;
 if not private.branch_scope_row('audit_events',to_jsonb(event),false) then return null; end if;
 if private.access_v2_enabled(actor) then
  if not private.access_v2_visible('audit_events',to_jsonb(event),false)
   or not private.access_v2_allows(actor,'audit_event.snapshot.read',event.location_id)
   or not (private.access_v2_allows(actor,'customer_contact.read')
       or private.access_v2_allows(actor,'report_customer_contact.read',event.location_id)) then return null; end if;
 else
  if not private.has_permission(actor,'viewAudit') or not private.has_permission(actor,'manageCustomers')
    or (event.location_id is not null and not private.has_location_access(actor,event.location_id)) then return null; end if;
 end if;
 return (select phone from private.audit_sale_contacts_v1 where event_id=target);
end $$;
revoke all on function private.audit_sale_phone_for_actor_v1(uuid) from public,anon;
grant execute on function private.audit_sale_phone_for_actor_v1(uuid) to authenticated;

-- Invoker reads preserve the existing RLS, scope and snapshot-redaction rules.
-- The private helper independently checks audit, branch and contact permissions.
create or replace function public.read_audit_events_v1(input jsonb default '{}')
returns jsonb language plpgsql security invoker set search_path='' as $$
declare source_name text; result jsonb; loc uuid:=nullif(input->>'location_id','')::uuid;
 entity text:=nullif(input->>'entity_type',''); row_limit int:=greatest(1,least(coalesce((input->>'limit')::int,100),500));
begin
 if not private.actor_is_active_v1() then raise exception using errcode='42501',message='AUDIT_ACCESS_DENIED'; end if;
 source_name:=case when private.access_v2_enabled(auth.uid()) then 'access_v2_audit_events' else 'audit_events' end;
 execute format($query$
  select coalesce(jsonb_agg(row_data order by created_at desc,id desc),'[]') from (
   select e.id,e.created_at,to_jsonb(e)||jsonb_build_object('after_data',
    case when e.after_data->>'snapshot_type'='sale_audit_v1' then
      jsonb_set(e.after_data,'{customer,phone}',coalesce(to_jsonb(private.audit_sale_phone_for_actor_v1(e.id)),'null'))
     else e.after_data end) row_data
   from public.%I e where ($1 is null or e.location_id=$1) and ($2 is null or e.entity_type=$2)
    and not (e.entity_type='sale' and e.action in ('sale_completed','refund_completed') and exists(
     select 1 from public.%I details where details.entity_id=e.entity_id and details.entity_type='sale'
       and details.action in ('sale_details_recorded','refund_details_recorded')))
   order by e.created_at desc,e.id desc limit $3
  ) authorized_events
 $query$,source_name,source_name) into result using loc,entity,row_limit;
 return result;
end $$;
revoke all on function public.read_audit_events_v1(jsonb) from public,anon;
grant execute on function public.read_audit_events_v1(jsonb) to authenticated;
insert into private.access_v2_rpc_registry(signature,function_oid,original_definition)
 values('read_audit_events_v1(jsonb)','public.read_audit_events_v1(jsonb)'::regprocedure,
  pg_get_functiondef('public.read_audit_events_v1(jsonb)'::regprocedure))
 on conflict(signature) do update set function_oid=excluded.function_oid,original_definition=excluded.original_definition;
notify pgrst,'reload schema';


-- SOURCE: 20261105142438_employee_multi_branch_access.sql
-- SHA256: 276b0242e0b539167de2c26e47da0380ca9752a6f93bac07e6b29445f5923618
-- Compose the existing checked commands so account, password, PIN and branch
-- changes either all commit or all roll back. Existing clients keep their API.
create or replace function public.admin_save_employee_v1(
 user_input jsonb, password_input text default null, pin_input text default null,
 branch_membership_input jsonb default null,
 expected_branch_membership_input jsonb default null
) returns uuid language plpgsql security definer set search_path='' as $$
declare
 actor uuid:=auth.uid(); target uuid:=nullif(user_input->>'id','')::uuid;
 old_membership jsonb; source_branch uuid; revision_value text;
 role_rows jsonb; override_rows jsonb; added_branches uuid[];
begin
 if actor is null or not private.actor_is_active_v1() then
  raise exception using errcode='42501',message='AUTH_REQUIRED';
 end if;
 if branch_membership_input is null then
  return public.admin_save_user_v1(user_input,password_input,pin_input);
 end if;
 if jsonb_typeof(branch_membership_input) is distinct from 'array'
 or jsonb_array_length(branch_membership_input)=0
 or jsonb_typeof(expected_branch_membership_input) is distinct from 'array'
 or (select count(*) from jsonb_array_elements(branch_membership_input) a
     where coalesce((a->>'is_default')::boolean,false))<>1 then
  raise exception using errcode='22023',message='ACCESS_INVALID_BRANCH_ASSIGNMENTS';
 end if;
 -- Same lock order as admin_access_command_v2: revision, then profile.
 select revision::text into revision_value from private.access_v2_state where singleton for update;
 if target is null and exists(select 1 from public.profiles where username=user_input->>'username') then
  raise exception using errcode='23505',message='USERNAME_EXISTS';
 end if;
 if target is not null then perform 1 from public.profiles where id=target for update; end if;
 select coalesce(jsonb_agg(jsonb_build_object('location_id',location_id,
  'is_default',is_default,'can_view',can_view,'can_manage',can_manage)),'[]')
 into old_membership from public.profile_locations where profile_id=target;
 if not (old_membership @> expected_branch_membership_input and old_membership <@ expected_branch_membership_input)
 or jsonb_array_length(old_membership)<>jsonb_array_length(expected_branch_membership_input) then
  raise exception using errcode='40001',message='EMPLOYEE_BRANCHES_CHANGED_REFRESH';
 end if;
 select location_id into source_branch from public.profile_locations
 where profile_id=target and can_view order by is_default desc,location_id limit 1;
 select coalesce(array_agg((a->>'location_id')::uuid),'{}'::uuid[]) into added_branches
 from jsonb_array_elements(branch_membership_input) a where coalesce((a->>'can_view')::boolean,true)
 and not exists(select 1 from public.profile_locations p where p.profile_id=target
   and p.location_id=(a->>'location_id')::uuid and p.can_view);
 target:=public.admin_save_user_v1(user_input,password_input,pin_input);
 if private.access_v2_enabled(target) then
  -- Retained branches keep their exact grants, denials and expiry dates. New
  -- branches inherit only the previous default branch's scoped permissions.
  select coalesce(jsonb_agg(row_data),'[]') into role_rows from (
   select jsonb_build_object('role_id',a.role_id,'location_id',a.location_id,'expires_at',a.expires_at) row_data
   from private.access_v2_assignments a where a.user_id=target and a.revoked_at is null
   and (a.location_id is null or exists(select 1 from jsonb_array_elements(branch_membership_input) b where (b->>'location_id')::uuid=a.location_id))
   union all
   select jsonb_build_object('role_id',a.role_id,'location_id',loc,'expires_at',a.expires_at)
   from private.access_v2_assignments a cross join unnest(added_branches) loc
   where a.user_id=target and a.location_id=source_branch and a.revoked_at is null
   and (a.expires_at is null or a.expires_at>now())
   and not exists(select 1 from private.access_v2_assignments existing where existing.user_id=target and existing.role_id=a.role_id and existing.location_id=loc and existing.revoked_at is null)
  ) rows;
  select coalesce(jsonb_agg(row_data),'[]') into override_rows from (
   select jsonb_build_object('permission_id',o.permission_id,'location_id',o.location_id,'effect',o.effect,'expires_at',o.expires_at) row_data
   from private.access_v2_overrides o where o.user_id=target
   and (o.location_id is null or exists(select 1 from jsonb_array_elements(branch_membership_input) b where (b->>'location_id')::uuid=o.location_id))
   union all
   select jsonb_build_object('permission_id',o.permission_id,'location_id',loc,'effect',o.effect,'expires_at',o.expires_at)
   from private.access_v2_overrides o join private.access_v2_permissions p on p.id=o.permission_id
   cross join unnest(added_branches) loc
   where o.user_id=target and o.location_id=source_branch and p.scope='location'
   and (o.expires_at is null or o.expires_at>now())
   and not exists(select 1 from private.access_v2_overrides existing where existing.user_id=target and existing.permission_id=o.permission_id and existing.location_id=loc)
  ) rows;
  perform public.admin_access_command_v2(jsonb_build_object('command','save_member_access',
   'user_id',target,'expected_revision',revision_value,'branch_membership',branch_membership_input,
   'assignments',role_rows,'overrides',override_rows));
 else
  perform public.save_user_location_assignments_v2(jsonb_build_object('user_id',target,'assignments',branch_membership_input));
 end if;
 return target;
end $$;
revoke all on function public.admin_save_employee_v1(jsonb,text,text,jsonb,jsonb) from public,anon;
grant execute on function public.admin_save_employee_v1(jsonb,text,text,jsonb,jsonb) to authenticated;

insert into private.access_v2_rpc_registry(signature,function_oid,original_definition)
values('admin_save_employee_v1(jsonb,text,text,jsonb,jsonb)',
 'public.admin_save_employee_v1(jsonb,text,text,jsonb,jsonb)'::regprocedure,
 pg_get_functiondef('public.admin_save_employee_v1(jsonb,text,text,jsonb,jsonb)'::regprocedure))
on conflict(signature) do update set function_oid=excluded.function_oid,original_definition=excluded.original_definition;

-- Include memberships in the already-authorized member overview. Keep its
-- existing authorization and any later deployment-specific implementation.
do $$ declare definition text; marker text:='''enabled'',private.access_v2_enabled(p.id),''assignments'''; begin
 definition:=pg_get_functiondef('public.access_management_overview_v2()'::regprocedure);
 if position('''branch_membership''' in definition)=0 then
  if position(marker in definition)=0 then raise exception 'EMPLOYEE_BRANCH_OVERVIEW_PREREQUISITE'; end if;
  execute replace(definition,marker,
   '''enabled'',private.access_v2_enabled(p.id),''branch_membership'',(select coalesce(jsonb_agg(jsonb_build_object(''location_id'',b.location_id,''is_default'',b.is_default,''can_view'',b.can_view,''can_manage'',b.can_manage)),''[]'') from public.profile_locations b where b.profile_id=p.id),''assignments''');
 end if;
end $$;
notify pgrst,'reload schema';


-- SOURCE: 20261105145638_asset_photos.sql
-- SHA256: 67e170388d3e2f52c3bb708fa4331b573c9db7329ec45cfa050597980dba6c41
-- Attachments are separate from immutable purchases and financial ledgers.
create table if not exists private.asset_photos (
 id uuid primary key default gen_random_uuid(),
 expense_id uuid not null references public.expenses(id) on delete restrict,
 storage_path text not null,
 created_by uuid not null references public.profiles(id) on delete restrict,
 created_at timestamptz not null default now(),
 unique(expense_id,storage_path)
);
create index if not exists asset_photos_path_idx on private.asset_photos(storage_path);
create index if not exists asset_photos_created_by_idx on private.asset_photos(created_by);
alter table private.asset_photos enable row level security;
revoke all on private.asset_photos from public,anon,authenticated;
-- A correction retry must not restore photos the user subsequently removed.
create table if not exists private.asset_photo_copies (
 expense_id uuid primary key references public.expenses(id) on delete restrict
);
alter table private.asset_photo_copies enable row level security;
revoke all on private.asset_photo_copies from public,anon,authenticated;

create or replace function private.asset_photo_access(asset_id uuid,manage boolean default false)
returns boolean language sql stable security definer set search_path='' as $$
 select private.actor_is_active_v1() and exists(
  select 1 from public.expenses e where e.id=asset_id and e.destination='asset'
  and (not manage or not e.is_void)
  and private.branch_scope_location(auth.uid(),e.location_id,manage)
  and (not manage or exists(select 1 from public.profiles p where p.id=auth.uid() and p.role='admin'))
  and case when private.access_v2_enabled(auth.uid())
   then private.access_v2_allows(auth.uid(),case when manage then 'expense.replace' else 'expense.read' end,e.location_id)
   else private.has_permission(auth.uid(),'manageTreasury') end
 );
$$;
revoke all on function private.asset_photo_access(uuid,boolean) from public,anon,authenticated;

create or replace function private.asset_photo_object_access(path text,operation text)
returns boolean language plpgsql stable security definer set search_path='' as $$
declare asset_id uuid;
begin
 if not private.actor_is_active_v1() then return false; end if;
 if operation='read' then
  return exists(select 1 from private.asset_photos p where p.storage_path=path and private.asset_photo_access(p.expense_id,false));
 end if;
 if path !~ '^[0-9a-f-]{36}/[0-9a-f-]{36}/[0-9a-f-]{36}\.(jpg|png|webp)$'
 or split_part(path,'/',1)<>auth.uid()::text then return false; end if;
 begin asset_id:=split_part(path,'/',2)::uuid;
 exception when invalid_text_representation then return false; end;
 if not private.asset_photo_access(asset_id,true) then return false; end if;
 if operation='upload' then return true; end if;
 -- Only unattached uploads can be cleaned up. Historical copies stay private.
 return operation='delete' and not exists(select 1 from private.asset_photos p where p.storage_path=path);
end $$;
revoke all on function private.asset_photo_object_access(text,text) from public,anon;
grant execute on function private.asset_photo_object_access(text,text) to authenticated;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('asset-photos','asset-photos',false,10485760,array['image/jpeg','image/png','image/webp'])
on conflict(id) do update set public=false,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;
drop policy if exists asset_photos_read on storage.objects;
create policy asset_photos_read on storage.objects for select to authenticated
 using(bucket_id='asset-photos' and private.asset_photo_object_access(name,'read'));
drop policy if exists asset_photos_upload on storage.objects;
create policy asset_photos_upload on storage.objects for insert to authenticated
 with check(bucket_id='asset-photos' and private.asset_photo_object_access(name,'upload'));
drop policy if exists asset_photos_cleanup on storage.objects;
create policy asset_photos_cleanup on storage.objects for delete to authenticated
 using(bucket_id='asset-photos' and private.asset_photo_object_access(name,'delete'));

create or replace function public.asset_photos_v1(input jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare target uuid:=(input->>'asset_id')::uuid; action text:=coalesce(input->>'action','list'); path text:=input->>'storage_path'; result jsonb;
begin
 if action not in ('list','add','remove') or not private.asset_photo_access(target,action<>'list') then
  raise exception using errcode='42501',message='ASSET_PHOTO_FORBIDDEN'; end if;
 if action<>'list' then
  -- Serialize attachment edits with voiding/correcting the asset.
  perform 1 from public.expenses where id=target for update;
  if not private.asset_photo_access(target,true) then raise exception using errcode='42501',message='ASSET_PHOTO_FORBIDDEN'; end if;
 end if;
 if action='add' then
  if split_part(path,'/',2)<>target::text
  or not coalesce(private.asset_photo_object_access(path,'upload'),false)
  or not exists(select 1 from storage.objects where bucket_id='asset-photos' and name=path) then
   raise exception using errcode='42501',message='ASSET_PHOTO_UPLOAD_REQUIRED'; end if;
  insert into private.asset_photos(expense_id,storage_path,created_by) values(target,path,auth.uid())
   on conflict(expense_id,storage_path) do nothing;
 elsif action='remove' then
  delete from private.asset_photos where id=(input->>'photo_id')::uuid and expense_id=target;
 end if;
 if action<>'list' then
  insert into public.audit_events(actor_id,action,entity_type,entity_id,location_id,after_data)
  select auth.uid(),'asset_photo_'||action,'expense',e.id,e.location_id,
   jsonb_build_object('photo_id',input->>'photo_id','storage_path',path) from public.expenses e where e.id=target;
 end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'storage_path',p.storage_path,'created_at',p.created_at) order by p.created_at,p.id),'[]') into result
 from private.asset_photos p where p.expense_id=target;
 return result;
end $$;
revoke all on function public.asset_photos_v1(jsonb) from public,anon;
grant execute on function public.asset_photos_v1(jsonb) to authenticated;
insert into private.access_v2_rpc_registry(signature,function_oid,original_definition)
values('asset_photos_v1(jsonb)','public.asset_photos_v1(jsonb)'::regprocedure,
 pg_get_functiondef('public.asset_photos_v1(jsonb)'::regprocedure))
on conflict(signature) do update set function_oid=excluded.function_oid,original_definition=excluded.original_definition;

-- Financial corrections retain pictures atomically, without changing the
-- existing posting, reversal, authorization or retry logic.
do $$ declare definition text; begin
 if to_regprocedure('private.asset_photo_replace_expense_base(jsonb,jsonb,jsonb)') is null then
  definition:=pg_get_functiondef('public.replace_expense_v1(jsonb,jsonb,jsonb)'::regprocedure);
  execute replace(definition,'public.replace_expense_v1(', 'private.asset_photo_replace_expense_base(');
 end if;
end $$;
revoke all on function private.asset_photo_replace_expense_base(jsonb,jsonb,jsonb) from public,anon,authenticated;
create or replace function public.replace_expense_v1(input jsonb,expense_input jsonb,settlements_input jsonb default '[]')
returns public.expenses language plpgsql security definer set search_path='' as $$
declare source_id uuid; result public.expenses; copied integer;
begin
 select expense_id into source_id from public.transactions where id=(input->>'transaction_id')::uuid;
 result:=private.asset_photo_replace_expense_base(input,expense_input,settlements_input);
 if result.destination='asset' and source_id is not null then
  insert into private.asset_photo_copies(expense_id) values(result.id) on conflict do nothing;
  get diagnostics copied=row_count;
  if copied=1 then
  insert into private.asset_photos(expense_id,storage_path,created_by,created_at)
   select result.id,storage_path,created_by,created_at from private.asset_photos where expense_id=source_id
   on conflict(expense_id,storage_path) do nothing;
  end if;
 end if;
 return result;
end $$;
notify pgrst,'reload schema';


-- SOURCE: 20261112000000_installation_workflow.sql
-- SHA256: 7414555fd6c526be340a44271d3bba960cc784e5d601e5fb34727908f8f0b4cd
alter table public.installation_services add column if not exists default_cost numeric(14,4) not null default 0
 check(default_cost>=0 and default_cost<'Infinity'::numeric);
alter table public.installation_services add column if not exists is_default boolean not null default false;
alter table public.installation_lines add column if not exists unit_cost numeric(14,4) not null default 0
 check(unit_cost>=0 and unit_cost<'Infinity'::numeric);
alter table public.installation_lines add column if not exists image_url text;
alter table public.installations add column if not exists deleted_at timestamptz;
alter table public.sales add column if not exists installation_id uuid references public.installations(id);
create index if not exists sales_installation_idx on public.sales(installation_id) where installation_id is not null;
update public.sales s set installation_id=i.id from public.installations i where i.sale_id=s.id and s.installation_id is null;

create or replace function private.installation_cost_visible_v1(loc uuid)
returns boolean language plpgsql stable security definer set search_path='' as $$
begin
 if not coalesce(private.actor_is_active_v1(),false) then return false; end if;
 if private.access_v2_enabled(auth.uid()) then return private.access_v2_allows(auth.uid(),'report_cost.read',loc); end if;
 return coalesce(private.has_permission(auth.uid(),'viewReports'),false)
  and (loc is null or private.has_location_access(auth.uid(),loc));
end $$;
revoke all on function private.installation_cost_visible_v1(uuid) from public,anon,authenticated;

-- Keep saved terms, totals, deposits and permissions in the existing writers.
do $$ declare definition text; signature text; backup text;
begin
 foreach signature in array array['save_installation_finance_v1(jsonb,jsonb)','installation_services_v3(jsonb)','installation_quotes_v3(jsonb)'] loop
  backup:=case split_part(signature,'(',1) when 'save_installation_finance_v1' then 'installation_workflow_previous_v1'
   when 'installation_services_v3' then 'installation_services_previous_v4' else 'installation_quotes_previous_v4' end;
  if to_regprocedure('private.'||backup||substr(signature,strpos(signature,'('))) is null then
   select pg_get_functiondef(('public.'||signature)::regprocedure) into definition;
   execute replace(definition,'public.'||split_part(signature,'(',1)||'(', 'private.'||backup||'(');
  end if;
 end loop;
end $$;
revoke all on function private.installation_workflow_previous_v1(jsonb,jsonb),private.installation_services_previous_v4(jsonb),private.installation_quotes_previous_v4(jsonb) from public,anon,authenticated;

create or replace function public.installation_services_v3(input jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
declare rows jsonb; target uuid; loc uuid:=nullif(input->>'location_id','')::uuid; visible boolean;
begin
 visible:=private.installation_cost_visible_v1(loc);
 if input->>'action'='save' and input ? 'default_cost' and not visible then
  raise exception using errcode='42501',message='INSTALLATION_COST_FORBIDDEN'; end if;
 target:=coalesce(nullif(input->>'id','')::uuid,gen_random_uuid());
 rows:=private.installation_services_previous_v4(case when input->>'action'='save' then input||jsonb_build_object('id',target) else input end);
 if input->>'action'='save' and input ? 'default_cost' then
  if input->>'default_cost' is null then raise exception 'INVALID_INSTALLATION_COST'; end if;
  update public.installation_services set default_cost=(input->>'default_cost')::numeric where id=target;
 end if;
 if input->>'action'='save' and input ? 'is_default' then
  update public.installation_services set is_default=coalesce((input->>'is_default')::boolean,false) where id=target;
 end if;
 return (select coalesce(jsonb_agg(case when visible then to_jsonb(s) else to_jsonb(s)-'default_cost' end order by s.name_en),'[]') from public.installation_services s);
end $$;

create or replace function public.save_installation_finance_v1(input jsonb,lines_input jsonb)
returns uuid language plpgsql security definer set search_path='' as $$
declare target uuid; old_costs jsonb; old_images jsonb; loc uuid:=nullif(input->>'location_id','')::uuid;
 line jsonb; visible boolean;
begin
 -- Serialize with saves, checkout and settlements before inspecting history.
 perform pg_advisory_xact_lock(7353101101);
 if exists(select 1 from public.installations where quotation_number=input->>'quotation_number' and deleted_at is not null) then
  raise exception 'INSTALLATION_LOCKED'; end if;
 visible:=private.installation_cost_visible_v1(loc);
 if exists(select 1 from jsonb_array_elements(lines_input) x where x->>'kind'='service' and x ? 'unit_cost') and not visible then
  raise exception using errcode='42501',message='INSTALLATION_COST_FORBIDDEN'; end if;
 select coalesce(jsonb_object_agg(coalesce(l.client_line_id,l.id::text),l.unit_cost),'{}'),
  coalesce(jsonb_object_agg(coalesce(l.client_line_id,l.id::text),l.image_url),'{}') into old_costs,old_images from public.installation_lines l
  join public.installations i on i.id=l.installation_id where i.quotation_number=input->>'quotation_number';
 target:=private.installation_workflow_previous_v1(input,lines_input);
 for line in select value from jsonb_array_elements(lines_input) loop
  if line->>'kind'='service' and line ? 'unit_cost' and line->>'unit_cost' is null then raise exception 'INVALID_INSTALLATION_COST'; end if;
  if nullif(line->>'image_url','') is not null and (length(line->>'image_url')>4096 or line->>'image_url' !~ '^https?://') then raise exception 'INVALID_INSTALLATION_IMAGE'; end if;
  update public.installation_lines set
   unit_cost=case when line->>'kind'='service' and line ? 'unit_cost' then (line->>'unit_cost')::numeric
    else coalesce((old_costs->>(line->>'client_line_id'))::numeric,0) end,
   image_url=case when line ? 'image_url' then nullif(line->>'image_url','')
    else old_images->>(line->>'client_line_id') end
  where installation_id=target and client_line_id=line->>'client_line_id';
 end loop;
 return target;
end $$;

create or replace function public.installation_quotes_v3(input jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
declare quote jsonb; result jsonb:='[]'; visible boolean;
begin
 for quote in select value from jsonb_array_elements(private.installation_quotes_previous_v4(input)) loop
  if quote->>'deleted_at' is not null then continue; end if;
  visible:=private.installation_cost_visible_v1((quote->>'location_id')::uuid);
  if not visible then
   quote:=jsonb_set(quote,'{lines}',(select coalesce(jsonb_agg(value-'unit_cost'),'[]') from jsonb_array_elements(quote->'lines')));
  end if;
  result:=result||jsonb_build_array(quote);
 end loop;
 return result;
end $$;

create or replace function public.delete_installation_quote_v1(input jsonb)
returns uuid language plpgsql security definer set search_path='' as $$
declare quote public.installations%rowtype; doc public.transactions%rowtype;
begin
 perform pg_advisory_xact_lock(7353101101);
 select * into quote from public.installations where id=(input->>'id')::uuid for update;
 if not found then raise exception 'INSTALLATION_NOT_FOUND'; end if;
 perform private.checkout_access_v3('installation.update','posCheckout',quote.location_id);
 if not coalesce(private.actor_is_active_v1(),false) then raise exception using errcode='42501',message='AUTH_REQUIRED'; end if;
 if not private.access_v2_enabled(auth.uid()) and not exists(select 1 from public.profiles where id=auth.uid() and is_active and role in ('admin','manager')) then
  raise exception using errcode='42501',message='ACCESS_DENIED'; end if;
 if quote.sale_id is not null then raise exception 'QUOTE_HAS_FINANCIAL_HISTORY'; end if;
 for doc in select * from public.transactions where installation_id=quote.id for update loop
  if exists(select 1 from public.transaction_allocations where transaction_id=doc.id)
    or exists(select 1 from public.transaction_settlements where transaction_id=doc.id) then raise exception 'QUOTE_HAS_FINANCIAL_HISTORY'; end if;
 end loop;
 update public.installations set deleted_at=coalesce(deleted_at,now()),status='cancelled',updated_at=now() where id=quote.id;
 update public.transactions set status='void' where installation_id=quote.id and status='posted';
 insert into public.audit_events(actor_id,action,entity_type,entity_id) values(auth.uid(),'installation_deleted','installation',quote.id);
 return quote.id;
end $$;

-- Both modern and legacy checkout use the service's saved cost without moving stock.
do $$ declare definition text; writer text;
begin
 foreach writer in array array['private.complete_installation_document_v1(jsonb,uuid)','private.installation_legacy_document_v3(jsonb,uuid)'] loop
  select pg_get_functiondef(writer::regprocedure) into definition;
  if position('cost_value:=line.unit_cost' in definition)=0 then
   if position('product_value:=null;cost_value:=0;p:=null;' in definition)=0 then raise exception 'INSTALLATION_WRITER_INCOMPATIBLE'; end if;
   definition:=replace(definition,'product_value:=null;cost_value:=0;p:=null;',
    'product_value:=null;cost_value:=line.unit_cost;p:=null;');
   end if;
  definition:=replace(definition,'if i.id is null or i.sale_id is not null or',
    'if i.id is null or i.sale_id is not null or i.deleted_at is not null or');
  -- Reapplication leaves an already inserted predicate unchanged.
  definition:=replace(definition,'or i.deleted_at is not null or i.deleted_at is not null or','or i.deleted_at is not null or');
  execute definition;
 end loop;
end $$;

-- The existing installation update is the authoritative conversion link.
create or replace function private.capture_installation_sale_v1() returns trigger
language plpgsql security definer set search_path='' as $$ begin
 if new.sale_id is not null then update public.sales set installation_id=new.id where id=new.sale_id; end if;
 return new;
end $$;
revoke all on function private.capture_installation_sale_v1() from public,anon,authenticated;
drop trigger if exists installation_sale_link_v1 on public.installations;
create trigger installation_sale_link_v1 after update of sale_id on public.installations for each row execute function private.capture_installation_sale_v1();

-- Add only the safe link column to the existing redacted invoice view.
do $$ declare definition text; begin
 if to_regclass('public.access_v2_sales') is not null and not exists(select 1 from information_schema.columns where table_schema='public' and table_name='access_v2_sales' and column_name='installation_id') then
  select rtrim(pg_get_viewdef('public.access_v2_sales'::regclass,true),'; '||chr(10)) into definition;
  execute 'create or replace view public.access_v2_sales with (security_barrier=true) as select existing.*,s.installation_id from ('||definition||') existing join public.sales s on s.id=existing.id';
 end if;
end $$;

revoke all on function public.delete_installation_quote_v1(jsonb) from public,anon;
grant execute on function public.delete_installation_quote_v1(jsonb) to authenticated;
do $$ declare rpc_signature text; begin
 foreach rpc_signature in array array['delete_installation_quote_v1(jsonb)','installation_services_v3(jsonb)','installation_quotes_v3(jsonb)','save_installation_finance_v1(jsonb,jsonb)'] loop
  insert into private.access_v2_rpc_registry(signature,function_oid,original_definition)
   values(rpc_signature,('public.'||rpc_signature)::regprocedure,pg_get_functiondef(('public.'||rpc_signature)::regprocedure))
   on conflict(signature) do update set function_oid=excluded.function_oid,original_definition=excluded.original_definition;
 end loop;
end $$;
notify pgrst,'reload schema';


-- SOURCE: 20261112000001_company_loans.sql
-- SHA256: d39d2ff16e0e130734cf1f458710e2d2383ca751822e60ae6bc5fd8ef6d0bd34
-- Requires the integrated accounting migration so loan cash flows are financing,
-- and principal repayments never become operating expenses.
do $$ begin
 if to_regclass('private.accounting_cash_classes') is null then raise exception 'INTEGRATED_ACCOUNTING_MIGRATION_REQUIRED'; end if;
end $$;
create table if not exists private.company_loans (
 id uuid primary key, location_id uuid not null references public.locations(id),
 lender text not null check(length(btrim(lender)) between 1 and 200),
 principal numeric(14,2) not null check(principal>0 and principal<'Infinity'::numeric),
 received_date date not null check(isfinite(received_date)), notes text,
 transaction_id uuid not null unique references public.transactions(id),
 request_payload jsonb not null, created_by uuid not null references public.profiles(id),
 created_at timestamptz not null default now()
);
create index if not exists company_loans_location_idx on private.company_loans(location_id,created_at desc);
create table if not exists private.loan_installments (
 id uuid primary key default gen_random_uuid(), loan_id uuid not null references private.company_loans(id),
 due_date date not null check(isfinite(due_date)),
 amount numeric(14,2) not null check(amount>0 and amount<'Infinity'::numeric)
);
create index if not exists loan_installments_loan_idx on private.loan_installments(loan_id,due_date,id);
create table if not exists private.loan_payments (
 id uuid primary key, installment_id uuid not null references private.loan_installments(id),
 amount numeric(14,2) not null check(amount>0 and amount<'Infinity'::numeric),
 transaction_id uuid not null unique references public.transactions(id), request_payload jsonb not null
);
create index if not exists loan_payments_installment_idx on private.loan_payments(installment_id);
alter table private.company_loans enable row level security;
alter table private.loan_installments enable row level security;
alter table private.loan_payments enable row level security;
revoke all on private.company_loans,private.loan_installments,private.loan_payments from public,anon,authenticated;

create or replace function private.loan_access_v1(loc uuid,writing boolean default false)
returns void language plpgsql security definer set search_path='' as $$ begin
 if loc is null or not coalesce(private.actor_is_active_v1(),false) or not private.branch_scope_location(auth.uid(),loc,writing) then
  raise exception using errcode='42501',message='LOAN_BRANCH_FORBIDDEN'; end if;
 perform private.checkout_access_v3('transaction.read','manageTreasury',loc);
 if writing then
  perform private.checkout_access_v3('manual_transaction.create','manageTreasury',loc);
  perform private.checkout_access_v3('transaction_settlement.create','manageTreasury',loc);
 end if;
end $$;
revoke all on function private.loan_access_v1(uuid,boolean) from public,anon,authenticated;

create or replace function private.loan_cash_v1(input jsonb,loc uuid,incoming boolean,amount_value numeric,reason text)
returns uuid language plpgsql security definer set search_path='' as $$
declare doc uuid; settlement uuid; cash uuid; account public.treasury_accounts%rowtype;
begin
 select * into account from public.treasury_accounts where id=(input->>'account_id')::uuid and is_active for update;
 if not found or (account.location_id is not null and account.location_id<>loc)
  or not private.branch_scope_location(auth.uid(),coalesce(account.location_id,loc),true) then raise exception 'LOAN_ACCOUNT_FORBIDDEN'; end if;
 insert into public.transactions(type,direction,reference,description,location_id,total,occurred_at,created_by)
 values(case when incoming then 'deposit' else 'withdrawal' end,case when incoming then 'incoming' else 'outgoing' end,
  input->>'id',reason,loc,amount_value,(input->>'date')::date::timestamptz,auth.uid()) returning id into doc;
 settlement:=private.post_settlement_v1(jsonb_build_object('transaction_id',doc,'account_id',account.id,
  'amount',amount_value,'payment_method',coalesce(input->>'payment_method','cash'),'location_id',loc,
  'description',reason,'reference',input->>'reference','occurred_at',(input->>'date')::date::timestamptz,
  'idempotency_key','loan:'||(input->>'id')));
 select id into cash from public.treasury_transactions where settlement_id=settlement;
 insert into private.accounting_cash_classes(treasury_id,account,activity) values(cash,'loans','financing');
 return doc;
end $$;
revoke all on function private.loan_cash_v1(jsonb,uuid,boolean,numeric,text) from public,anon,authenticated;

create or replace function public.company_loans_v1(input jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' set timezone='Africa/Cairo' as $$
declare action text:=coalesce(input->>'action','list'); loc uuid:=nullif(input->>'location_id','')::uuid;
 target uuid; loan private.company_loans%rowtype; installment private.loan_installments%rowtype;
 payment private.loan_payments%rowtype; line jsonb; amount_value numeric; paid numeric; scheduled numeric; document uuid;
begin
 if action not in ('list','create','pay','schedule') then raise exception 'INVALID_LOAN_ACTION'; end if;
 perform private.loan_access_v1(loc,action<>'list');
 if action='create' then
  target:=(input->>'id')::uuid;
  if target is null then raise exception 'LOAN_REQUEST_ID_REQUIRED'; end if;
  perform pg_advisory_xact_lock(hashtextextended('loan:'||target::text,0));
  select * into loan from private.company_loans where id=target;
  if found then
   if loan.location_id<>loc or loan.request_payload<>input then raise exception 'LOAN_REQUEST_CHANGED'; end if;
   return jsonb_build_object('id',loan.id);
  end if;
  amount_value:=(input->>'amount')::numeric;
  if amount_value is null or amount_value<=0 or amount_value>999999999999.99 or amount_value<>round(amount_value,2)
   or amount_value::text in ('NaN','Infinity','-Infinity') or nullif(btrim(input->>'lender'),'') is null
   or (input->>'date') is null or not isfinite((input->>'date')::date) then raise exception 'INVALID_LOAN_DETAILS'; end if;
  if jsonb_typeof(input->'schedule') is distinct from 'array' or jsonb_array_length(input->'schedule') not between 1 and 240 then raise exception 'INVALID_LOAN_SCHEDULE'; end if;
  select sum((value->>'amount')::numeric) into scheduled from jsonb_array_elements(input->'schedule');
  if scheduled is distinct from amount_value then raise exception 'LOAN_SCHEDULE_TOTAL_MISMATCH'; end if;
  for line in select value from jsonb_array_elements(input->'schedule') loop
   if line->>'amount' is null or (line->>'amount')::numeric<=0 or (line->>'amount')::numeric<>round((line->>'amount')::numeric,2)
    or line->>'date' is null or not isfinite((line->>'date')::date) or (line->>'date')::date<(input->>'date')::date then raise exception 'INVALID_LOAN_SCHEDULE'; end if;
  end loop;
  document:=private.loan_cash_v1(input,loc,true,amount_value,'Loan received: '||(input->>'lender'));
  insert into private.company_loans(id,location_id,lender,principal,received_date,notes,transaction_id,request_payload,created_by)
   values(target,loc,btrim(input->>'lender'),amount_value,(input->>'date')::date,input->>'notes',document,input,auth.uid());
  insert into private.loan_installments(loan_id,due_date,amount)
   select target,(value->>'date')::date,(value->>'amount')::numeric from jsonb_array_elements(input->'schedule');
 elsif action in ('pay','schedule') then
  -- Lock the loan before the installment to serialize edits and partial payments.
  target:=(input->>'loan_id')::uuid;
  select * into loan from private.company_loans where id=target and location_id=loc for update;
  if not found then raise exception 'LOAN_NOT_FOUND'; end if;
  if action='pay' then
   select * into payment from private.loan_payments where id=(input->>'id')::uuid;
   if found then
    if payment.request_payload<>input then raise exception 'LOAN_REQUEST_CHANGED'; end if;
    return jsonb_build_object('id',payment.id);
   end if;
   select * into installment from private.loan_installments where id=(input->>'installment_id')::uuid and loan_id=loan.id for update;
   if not found then raise exception 'LOAN_INSTALLMENT_NOT_FOUND'; end if;
   select coalesce(sum(amount),0) into paid from private.loan_payments where installment_id=installment.id;
   amount_value:=(input->>'amount')::numeric;
   if nullif(input->>'id','') is null or amount_value is null or amount_value<=0 or amount_value<>round(amount_value,2)
    or amount_value::text in ('NaN','Infinity','-Infinity') or amount_value>installment.amount-paid
    or input->>'date' is null or not isfinite((input->>'date')::date) or (input->>'date')::date<loan.received_date then raise exception 'INVALID_LOAN_PAYMENT'; end if;
   document:=private.loan_cash_v1(input,loc,false,amount_value,'Loan repayment: '||loan.lender);
   insert into private.loan_payments(id,installment_id,amount,transaction_id,request_payload)
    values((input->>'id')::uuid,installment.id,amount_value,document,input);
  else
   -- Edit only untouched installments. Paid/partially paid rows remain intact.
   if jsonb_typeof(input->'schedule') is distinct from 'array' or jsonb_array_length(input->'schedule') not between 1 and 240 then raise exception 'INVALID_LOAN_SCHEDULE'; end if;
   select coalesce(sum(i.amount),0) into paid from private.loan_installments i where i.loan_id=loan.id
    and exists(select 1 from private.loan_payments p where p.installment_id=i.id);
   select sum((value->>'amount')::numeric) into scheduled from jsonb_array_elements(input->'schedule');
   if scheduled is distinct from loan.principal-paid then raise exception 'LOAN_SCHEDULE_TOTAL_MISMATCH'; end if;
   for line in select value from jsonb_array_elements(input->'schedule') loop
    if line->>'amount' is null or (line->>'amount')::numeric<=0 or (line->>'amount')::numeric<>round((line->>'amount')::numeric,2)
     or line->>'date' is null or not isfinite((line->>'date')::date) or (line->>'date')::date<loan.received_date then raise exception 'INVALID_LOAN_SCHEDULE'; end if;
   end loop;
   delete from private.loan_installments i where i.loan_id=loan.id and not exists(select 1 from private.loan_payments p where p.installment_id=i.id);
   insert into private.loan_installments(loan_id,due_date,amount)
    select loan.id,(value->>'date')::date,(value->>'amount')::numeric from jsonb_array_elements(input->'schedule');
  end if;
 end if;
 if action<>'list' then
  insert into public.audit_events(actor_id,action,entity_type,entity_id,after_data)
   values(auth.uid(),'loan_'||action,'company_loan',target,input-'account_id');
  return jsonb_build_object('id',target);
 end if;
 return (select coalesce(jsonb_agg(to_jsonb(l)-'request_payload'||jsonb_build_object(
  'installments',(select coalesce(jsonb_agg(to_jsonb(i)||jsonb_build_object('paid',
   (select coalesce(sum(p.amount),0) from private.loan_payments p where p.installment_id=i.id)) order by i.due_date,i.id),'[]')
   from private.loan_installments i where i.loan_id=l.id)) order by l.created_at desc),'[]') from private.company_loans l where l.location_id=loc);
end $$;
revoke all on function public.company_loans_v1(jsonb) from public,anon;
grant execute on function public.company_loans_v1(jsonb) to authenticated;

-- Keep the repayment schedule consistent with its posted treasury records.
create or replace function private.guard_loan_financial_history_v1() returns trigger
language plpgsql security definer set search_path='' as $$
declare doc uuid;
begin
 if tg_table_name='transactions' then
  if new.status is not distinct from old.status then return new; end if;
  doc:=old.id;
 else
  if new.reversed_settlement_id is null then return new; end if;
  select transaction_id into doc from public.transaction_settlements where id=new.reversed_settlement_id;
 end if;
 if exists(select 1 from private.company_loans where transaction_id=doc)
  or exists(select 1 from private.loan_payments where transaction_id=doc) then raise exception 'LOAN_FINANCIAL_HISTORY_LOCKED'; end if;
 return new;
end $$;
revoke all on function private.guard_loan_financial_history_v1() from public,anon,authenticated;
drop trigger if exists loan_history_document_guard on public.transactions;
create trigger loan_history_document_guard before update of status on public.transactions for each row execute function private.guard_loan_financial_history_v1();
drop trigger if exists loan_history_settlement_guard on public.transaction_settlements;
create trigger loan_history_settlement_guard before insert on public.transaction_settlements for each row execute function private.guard_loan_financial_history_v1();
insert into private.access_v2_rpc_registry(signature,function_oid,original_definition)
 values('company_loans_v1(jsonb)','public.company_loans_v1(jsonb)'::regprocedure,pg_get_functiondef('public.company_loans_v1(jsonb)'::regprocedure))
 on conflict(signature) do update set function_oid=excluded.function_oid,original_definition=excluded.original_definition;
notify pgrst,'reload schema';

do $verification$
declare item text; n bigint;
begin
 foreach item in array array['profiles','profile_locations','sales','sale_items',
  'expenses','transactions','transaction_settlements','treasury_transactions',
  'inventory_balances','inventory_movements'] loop
  execute format('select count(*) from public.%I',item) into n;
  if n is distinct from (select value from plugy_update_baseline where metric=item) then
   raise exception 'PRODUCTION_UPDATE_BUSINESS_COUNT_CHANGED: %',item;
  end if;
 end loop;
 if (select value from plugy_update_baseline where metric='sales_total') is distinct from
    (select coalesce(sum(total),0) from public.sales)
 or (select value from plugy_update_baseline where metric='expenses_total') is distinct from
    (select coalesce(sum(amount),0) from public.expenses)
 or (select value from plugy_update_baseline where metric='inventory_quantity') is distinct from
    (select coalesce(sum(quantity),0) from public.inventory_balances)
 or (select value from plugy_update_baseline where metric='inventory_value') is distinct from
    (select coalesce(sum(quantity*weighted_unit_cost),0) from public.inventory_balances) then
  raise exception 'PRODUCTION_UPDATE_BALANCES_CHANGED';
 end if;
 if to_regprocedure('public.installation_inventory_v1(jsonb)') is null
 or to_regprocedure('public.read_audit_events_v1(jsonb)') is null
 or to_regprocedure('public.admin_save_employee_v1(jsonb,text,text,jsonb,jsonb)') is null
 or to_regclass('private.asset_photos') is null
 or to_regprocedure('public.company_loans_v1(jsonb)') is null
 or to_regclass('private.loan_installments') is null
 or not exists(select 1 from storage.buckets where id='asset-photos' and not public) then
  raise exception 'PRODUCTION_UPDATE_VERIFICATION_FAILED';
 end if;
end $verification$;
notify pgrst,'reload schema';
commit;
select 'PLUGY_UPDATE_COMPLETE' as result,
 'Existing record counts, sales/expense totals and branch stock quantities/value preserved' as verification;
