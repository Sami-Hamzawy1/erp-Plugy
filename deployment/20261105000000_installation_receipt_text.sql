begin;

-- Wording belongs to its quotation so later prints reproduce the saved terms.
alter table public.installations add column if not exists receipt_text jsonb
  not null default '{}'::jsonb;
do $$ begin
  if not exists(select 1 from pg_constraint where conrelid='public.installations'::regclass
      and conname='installations_receipt_text_object') then
    alter table public.installations add constraint installations_receipt_text_object
      check(jsonb_typeof(receipt_text)='object' and octet_length(receipt_text::text)<=262144);
  end if;
end $$;

-- Keep the existing save implementation, including financial, deposit, branch,
-- locking and authorization checks. No posted financial values are rewritten.
do $$ declare definition text; begin
  if to_regprocedure('private.installation_receipt_previous_v1(jsonb,jsonb)') is null then
    select pg_get_functiondef('public.save_installation_finance_v1(jsonb,jsonb)'::regprocedure) into definition;
    execute replace(definition, 'public.save_installation_finance_v1(',
      'private.installation_receipt_previous_v1(');
  end if;
end $$;
revoke all on function private.installation_receipt_previous_v1(jsonb,jsonb) from public,anon,authenticated;

create or replace function public.save_installation_finance_v1(input jsonb,lines_input jsonb)
returns uuid language plpgsql security definer set search_path='' as $$
declare target uuid; receipt jsonb:=input->'receipt_text'; field text; limit_value integer;
begin
  if to_regprocedure('private.access_v2_rpc_guard(text,jsonb)') is not null then
    perform private.access_v2_rpc_guard('save_installation_finance_v1',jsonb_build_array(input,lines_input));
  end if;
  if input ? 'receipt_text' then
    if jsonb_typeof(receipt) is distinct from 'object' or octet_length(receipt::text)>262144
      or (receipt ? 'values' and jsonb_typeof(receipt->'values') is distinct from 'object') then
      raise exception using errcode='22023',message='INVALID_INSTALLATION_RECEIPT_TEXT';
    end if;
    if exists(select 1 from jsonb_each(coalesce(receipt->'values','{}')) where jsonb_typeof(value)<>'string') then
      raise exception using errcode='22023',message='INVALID_INSTALLATION_RECEIPT_TEXT';
    end if;
    foreach field in array array['charger_warranty_months','installation_warranty_months','validity_days'] loop
      if receipt ? field then
        limit_value:=case field when 'validity_days' then 3650 else 1200 end;
        if (receipt->>field) is null or (receipt->>field)!~'^[0-9]{1,4}$'
          or (receipt->>field)::integer>limit_value then
          raise exception using errcode='22023',message='INVALID_INSTALLATION_RECEIPT_TEXT';
        end if;
      end if;
    end loop;
  end if;
  target:=private.installation_receipt_previous_v1(input,lines_input);
  -- Old clients omit this field and retain existing wording unchanged.
  if input ? 'receipt_text' then
    update public.installations set receipt_text=receipt where id=target;
  end if;
  return target;
end $$;
revoke all on function public.save_installation_finance_v1(jsonb,jsonb) from public,anon;
grant execute on function public.save_installation_finance_v1(jsonb,jsonb) to authenticated;
notify pgrst,'reload schema';
commit;
