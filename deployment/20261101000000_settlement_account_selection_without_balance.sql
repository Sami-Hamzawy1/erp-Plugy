begin;

-- Shared non-cash accounts may receive an authorized branch's invoice payment.
-- This does not grant access to their ledger, balance, management or transfers.
create or replace function private.settlement_account_location_v5(
  account_data jsonb, document_location uuid, operation text)
returns uuid language sql immutable set search_path='' as $$
  select case when nullif(account_data->>'location_id','') is null
    and account_data->>'account_type' in ('bank','wallet','instapay')
    and operation in ('complete_sale','complete_sale_v1',
      'post_transaction_settlement_v1','settle_transaction_v1')
    then document_location else nullif(account_data->>'location_id','')::uuid end;
$$;
revoke all on function private.settlement_account_location_v5(jsonb,uuid,text)
  from public,anon,authenticated;

create or replace function private.settlement_accounts_for_actor_v5(location_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare actor uuid:=auth.uid();
begin
  perform private.access_v2_require('settlement_account.select',$1);
  if $1 is not null and not private.branch_scope_location(actor,$1) then
    raise exception using errcode='42501',message='LOCATION_FORBIDDEN';
  end if;
  return (select coalesce(jsonb_agg(jsonb_build_object(
    'id',a.id,'code',a.code,'name_ar',a.name_ar,'name_en',a.name_en,
    'account_type',a.account_type,'location_id',a.location_id,'is_active',true)
    ||case when private.access_v2_allows(actor,'treasury_account.balance.read',a.location_id)
      then jsonb_build_object('balance',a.balance) else '{}'::jsonb end
    order by a.code,a.id),'[]'::jsonb)
    from public.treasury_accounts a where a.is_active
      and (($1 is not null and (a.location_id=$1
        or (a.location_id is null and a.account_type in ('bank','wallet','instapay'))))
        or ($1 is null and private.branch_scope_row('treasury_accounts',to_jsonb(a)))));
end $$;
revoke all on function private.settlement_accounts_for_actor_v5(uuid)
  from public,anon,authenticated;

do $$
declare definition text; routine text; patched boolean:=false;
  balance_gate text:='if operation in (''account_statement_v1'',''list_settlement_accounts_v1'') then perform private.access_v2_require(''treasury_account.balance.read'',loc); end if;';
  item_scope text:='select location_id into other from public.treasury_accounts where id=(item->>''account_id'')::uuid;';
  payment_scope text:='select location_id into other from public.treasury_accounts where id=(data->>''account_id'')::uuid;';
  branch_check text:='not private.branch_scope_row(''treasury_accounts'',row_data,true)';
begin
  if to_regprocedure('private.branch_scope_base_access_v2_rpc_guard(text,jsonb)') is null
    or to_regprocedure('private.access_v2_impl_list_settlement_accounts_v1(uuid)') is null then
    raise exception 'SETTLEMENT_ACCOUNT_SELECTION_REQUIRES_BRANCH_CONFINEMENT';
  end if;
  select pg_get_functiondef('private.access_v2_impl_list_settlement_accounts_v1(uuid)'::regprocedure)
    into definition;
  if position('private.settlement_accounts_for_actor_v5' in definition)=0 then
    if position('private.branch_scope_row(''treasury_accounts''' in definition)=0 then
      raise exception 'SETTLEMENT_ACCOUNT_LIST_INCOMPATIBLE';
    end if;
    -- The existing public wrapper still checks selection permission. Legacy
    -- users retain the original guarded list body and finance behavior.
    definition:=regexp_replace(definition,'\mbegin\M',
      'begin if private.access_v2_enabled(auth.uid()) then return private.settlement_accounts_for_actor_v5($1); end if;', 'i');
    execute definition;
  end if;

  foreach routine in array array['private.access_v2_rpc_guard(text,jsonb)',
    'private.branch_scope_base_access_v2_rpc_guard(text,jsonb)'] loop
    select pg_get_functiondef(to_regprocedure(routine)) into definition;
    if position(balance_gate in definition)>0 then
      definition:=replace(definition,balance_gate,
        'if operation=''account_statement_v1'' then perform private.access_v2_require(''treasury_account.balance.read'',loc); end if;');
      patched:=true;
    end if;
    if position(item_scope in definition)>0 then
      definition:=replace(definition,item_scope,
        'select private.settlement_account_location_v5(to_jsonb(a),loc,operation) into other from public.treasury_accounts a where a.id=(item->>''account_id'')::uuid;');
    end if;
    if position(payment_scope in definition)>0 then
      definition:=replace(definition,payment_scope,
        'select private.settlement_account_location_v5(to_jsonb(a),loc,operation) into other from public.treasury_accounts a where a.id=(data->>''account_id'')::uuid;');
    end if;
    if routine='private.access_v2_rpc_guard(text,jsonb)' then
      if position(branch_check in definition)=0
        and position('private.settlement_account_location_v5' in definition)=0 then
        raise exception 'SETTLEMENT_ACCOUNT_BRANCH_GUARD_INCOMPATIBLE';
      end if;
      definition:=replace(definition,branch_check,
        'not private.branch_scope_location(actor,private.settlement_account_location_v5(row_data,coalesce((select t.location_id from public.transactions t where t.id=target),loc),operation),true)');
    end if;
    execute definition;
  end loop;
  if not patched and exists (
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='private' and p.proname in ('access_v2_rpc_guard','branch_scope_base_access_v2_rpc_guard')
      and position(balance_gate in pg_get_functiondef(p.oid))>0
  ) then raise exception 'SETTLEMENT_ACCOUNT_BALANCE_GUARD_INCOMPATIBLE'; end if;
end $$;

notify pgrst,'reload schema';
commit;
