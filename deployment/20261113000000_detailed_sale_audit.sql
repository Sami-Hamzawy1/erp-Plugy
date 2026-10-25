begin;
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
commit;
