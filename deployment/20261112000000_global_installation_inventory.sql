begin;

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
commit;
