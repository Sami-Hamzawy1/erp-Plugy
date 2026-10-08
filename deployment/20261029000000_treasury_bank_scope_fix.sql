begin;

-- Company-wide treasury accounts (banks, wallets, other) are not tied to any
-- branch location (location_id is null). They must remain accessible to users
-- with treasury privileges regardless of branch-scope confinement.

create or replace function private.branch_scope_row(relation_name text,row_data jsonb,manage boolean default false)
returns boolean language plpgsql stable security definer set search_path='' as $$
declare actor uuid:=auth.uid(); employee uuid; parent jsonb; location uuid:=nullif(row_data->>'location_id','')::uuid;
begin
 if actor is null or not exists(select 1 from public.profiles where id=actor and is_active) then return false; end if;
 if not private.branch_scope_restricted(actor) then return true; end if;
 if relation_name='locations' then location:=(row_data->>'id')::uuid; end if;
 if relation_name='profiles' then return private.branch_scope_employee(actor,(row_data->>'id')::uuid,manage); end if;
 if relation_name='profile_locations' then
  if not manage and (row_data->>'profile_id')::uuid=actor then return true; end if;
  if manage then return false; end if;
 end if;
 if relation_name in ('sale_items','stock_receipt_items','stock_transfer_items','inventory_snapshot_items','installation_lines','salary_adjustments','transaction_allocations','transaction_credits','vendor_return_items') then
  case relation_name
   when 'sale_items' then select to_jsonb(p) into parent from public.sales p where p.id=(row_data->>'sale_id')::uuid;
   when 'stock_receipt_items' then select to_jsonb(p) into parent from public.stock_receipts p where p.id=(row_data->>'receipt_id')::uuid;
   when 'stock_transfer_items' then select to_jsonb(p) into parent from public.stock_transfers p where p.id=(row_data->>'transfer_id')::uuid;
   when 'inventory_snapshot_items' then select to_jsonb(p) into parent from public.inventory_snapshots p where p.id=(row_data->>'snapshot_id')::uuid;
   when 'installation_lines' then select to_jsonb(p) into parent from public.installations p where p.id=(row_data->>'installation_id')::uuid;
   when 'salary_adjustments' then select to_jsonb(p) into parent from public.salary_records p where p.id=(row_data->>'salary_record_id')::uuid;
   else select to_jsonb(p) into parent from public.transactions p where p.id=(row_data->>'transaction_id')::uuid;
  end case;
  if parent is null then return false; end if;
  return private.branch_scope_row(case relation_name when 'stock_transfer_items' then 'stock_transfers' when 'salary_adjustments' then 'salary_records' else 'branch_parent' end,parent,manage)
   and (relation_name<>'transaction_credits' or exists(select 1 from public.transactions p where p.id=(row_data->>'credit_transaction_id')::uuid and private.branch_scope_row('transactions',to_jsonb(p),manage)));
 end if;
 if relation_name='stock_transfers' then return private.branch_scope_location(actor,(row_data->>'from_location_id')::uuid,manage)
  and private.branch_scope_location(actor,(row_data->>'to_location_id')::uuid,manage); end if;
 if relation_name in ('shifts','work_hours') and (row_data->>'user_id')::uuid=actor then return true; end if;
 if relation_name in ('shifts','work_hours','salary_records') then return private.branch_scope_employee(actor,(row_data->>'user_id')::uuid,manage); end if;
 if nullif(row_data->>'employee_id','') is not null then
  employee:=(row_data->>'employee_id')::uuid;
  if not private.branch_scope_employee(actor,employee,manage) then return false; end if;
  if location is null then return true; end if;
 end if;
 -- Bank and wallet treasury accounts are company-wide (location_id is null)
 if relation_name='treasury_accounts' and location is null then return true; end if;
 if row_data ? 'location_id' or relation_name='locations' then return private.branch_scope_location(actor,location,manage); end if;
 return true;
end $$;

-- Allow company-wide treasury permissions (where location is null) to evaluate
-- through access_v2 rather than failing early in branch confinement.
create or replace function private.access_v2_allows(actor uuid,permission text,location uuid default null,visited uuid[] default '{}')
returns boolean language plpgsql stable security definer set search_path='' as $$
declare spec private.access_v2_permissions%rowtype;
begin
 select * into spec from private.access_v2_permissions where id=permission;
 if spec.scope='location' and private.branch_scope_restricted(actor)
  and not (permission like 'treasury_account.%' and location is null)
  and (location is null or not private.branch_scope_location(actor,location,spec.write_action)) then return false; end if;
 return private.branch_scope_base_access_v2_allows(actor,permission,location,visited);
end $$;

grant execute on function private.branch_scope_row(text,jsonb,boolean) to authenticated;
grant execute on function private.access_v2_allows(uuid,text,uuid,uuid[]) to authenticated;
notify pgrst,'reload schema';
commit;
