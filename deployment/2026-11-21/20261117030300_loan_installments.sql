begin;

-- Reuse the company-loan records and schedule introduced in the November 5
-- production update so both screens see the same loans and posted payments.
create function private.loan_funding_reversed_v1(document_id uuid)
returns boolean language sql stable set search_path='' as $$
  select exists (
    select 1 from public.transaction_settlements funding
    join public.transaction_settlements reversal on reversal.reversed_settlement_id=funding.id
    where funding.transaction_id=document_id and funding.reversed_settlement_id is null
  );
$$;

create function private.loan_paid_v1(target_installment uuid)
returns table (amount numeric, paid_at timestamptz) language sql stable set search_path='' as $$
  select coalesce(sum(p.amount),0),max(s.occurred_at)
  from private.loan_payments p
  join public.transaction_settlements s
    on s.transaction_id=p.transaction_id and s.reversed_settlement_id is null
  where p.installment_id=target_installment and not exists (
    select 1 from public.transaction_settlements r where r.reversed_settlement_id=s.id
  );
$$;

create function public.accounting_loans_v1(location_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
  perform private.require_accounting_v1(location_id);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id',l.id,'lender',l.lender,'principal',l.principal,'branch',loc.name_en,'branch_ar',loc.name_ar,
      'remaining',case when funding.cancelled then 0 else i.remaining end,
      'cancelled',funding.cancelled,'installments',i.installments
    ) order by l.created_at desc,l.id)
    from private.company_loans l
    join public.locations loc on loc.id=l.location_id
    cross join lateral (select private.loan_funding_reversed_v1(l.transaction_id) cancelled) funding
    cross join lateral (
      select coalesce(sum(greatest(line.amount-payment.amount,0)),0) remaining,
        jsonb_agg(jsonb_build_object('id',line.id,'number',line.number,'due_date',line.due_date,
          'amount',line.amount,'remaining',greatest(line.amount-payment.amount,0),'paid_at',case when payment.amount>=line.amount then payment.paid_at end)
          order by line.number) installments
      from (
        select row_number() over (order by due_date,id) number,id,due_date,amount
        from private.loan_installments where loan_id=l.id
      ) line
      cross join lateral private.loan_paid_v1(line.id) payment
    ) i
    where ($1 is null or l.location_id=$1) and private.accounting_visible_v1(l.location_id)
  ), '[]'::jsonb);
end $$;

create function public.accounting_loan_command_v1(input jsonb)
returns uuid language plpgsql security definer set search_path='' set timezone='Africa/Cairo' as $$
declare
  actor uuid := auth.uid();
  location uuid := (input->>'location_id')::uuid;
  account_id uuid := (input->>'account_id')::uuid;
  command text := input->>'operation';
  command_key text := 'loan:'||(input->>'idempotency_key');
  lender_name text;
  first_due date;
  installment_count integer;
  installment_number bigint;
  amount numeric;
  loan private.company_loans%rowtype;
  installment private.loan_installments%rowtype;
  account_type text;
  method_code text;
  description text;
  result uuid;
  document_id uuid;
  posted_settlement uuid;
begin
  if location is null or not coalesce(private.branch_scope_location(actor,location,true),false)
    or not exists(select 1 from public.locations where id=location and is_active) then
    raise exception using errcode='42501',message='LOAN_BRANCH_REQUIRED';
  end if;
  perform private.require_accounting_v1(location,true);
  if private.access_v2_enabled(actor) then
    perform private.access_v2_require('transaction_settlement.create', location);
  else
    perform private.require_finance_v1();
  end if;
  result := private.finance_command_v1(command_key,input);
  if result is not null then return result; end if;
  select a->>'account_type' into account_type from jsonb_array_elements(public.list_settlement_accounts_v1(location)) a
    where a->>'id'=account_id::text and a->>'account_type' in ('bank','cash');
  if not found then raise exception using errcode='42501',message='LOAN_TREASURY_ACCOUNT_REQUIRED'; end if;
  if account_type='bank' and nullif(btrim(input->>'reference'),'') is null then
    raise exception using errcode='22023',message='PAYMENT_REFERENCE_REQUIRED';
  end if;
  -- Match the reversal lock order when funding and repayment use one account.
  perform 1 from public.treasury_accounts a where a.id=account_id and a.is_active for update;
  if not found then raise exception using errcode='22023',message='TREASURY_ACCOUNT_NOT_FOUND'; end if;
  select p.code into method_code from public.payment_methods p
    where p.is_active and p.method_type=account_type
    order by (p.code in ('cash','bank_transfer')) desc,p.sort_order,p.id limit 1;
  if not found then raise exception using errcode='22023',message='PAYMENT_METHOD_NOT_FOUND'; end if;

  if command='create' then
    lender_name := btrim(input->>'lender');
    first_due := (input->>'first_due_date')::date;
    installment_count := (input->>'installment_count')::integer;
    amount := (input->>'amount')::numeric;
    if length(coalesce(lender_name,'')) not between 1 and 120
      or first_due is null or not isfinite(first_due) or first_due<current_date
      or installment_count is null or installment_count not between 1 and 120
      or amount is null or not (amount between installment_count*.01 and 999999999999.99)
      or amount<>round(amount,2) then
      raise exception using errcode='22023',message='INVALID_LOAN_SCHEDULE';
    end if;
    result := gen_random_uuid();
    description := 'Loan funds · '||lender_name;
  elsif command='pay' then
    select * into loan from private.company_loans
      where id=(input->>'loan_id')::uuid and location_id=location for update;
    if not found or private.loan_funding_reversed_v1(loan.transaction_id) then
      raise exception using errcode='22023',message='LOAN_NOT_AVAILABLE';
    end if;
    select * into installment from private.loan_installments
      where id=(input->>'installment_id')::uuid and loan_id=loan.id;
    if not found then raise exception using errcode='22023',message='LOAN_INSTALLMENT_NOT_FOUND'; end if;
    select installment.amount-p.amount into amount from private.loan_paid_v1(installment.id) p;
    if amount<=0 then
      raise exception using errcode='22023',message='LOAN_INSTALLMENT_ALREADY_PAID';
    end if;
    select count(*) into installment_number from private.loan_installments
      where loan_id=loan.id and (due_date,id)<=(installment.due_date,installment.id);
    result := installment.id;
    description := 'Loan installment '||installment_number||' · '||loan.lender;
  else
    raise exception using errcode='22023',message='UNKNOWN_LOAN_OPERATION';
  end if;

  insert into public.transactions(type,direction,location_id,reference,description,total,created_by)
    values(case when command='create' then 'deposit' else 'withdrawal' end,
      case when command='create' then 'incoming' else 'outgoing' end,location,
      coalesce(nullif(btrim(input->>'reference'),''),result::text),description,amount,actor)
    returning id into document_id;
  posted_settlement := private.post_settlement_v1(jsonb_build_object(
    'transaction_id',document_id,'account_id',account_id,'payment_method',method_code,
    'reference',nullif(btrim(input->>'reference'),''),'amount',amount,
    'description',description,'idempotency_key',command_key));

  insert into private.accounting_cash_classes(treasury_id,account,activity)
    select t.id,'loans','financing' from public.treasury_transactions t
    where t.settlement_id=posted_settlement;
  if command='create' then
    insert into private.company_loans(id,location_id,lender,principal,received_date,transaction_id,request_payload,created_by)
      values(result,location,lender_name,amount,current_date,document_id,input,actor);
    insert into private.loan_installments(loan_id,due_date,amount)
      select result,(first_due+make_interval(months=>n-1))::date,
        round(amount*n/installment_count,2)-round(amount*(n-1)/installment_count,2)
      from generate_series(1,installment_count) n;
  else
    insert into private.loan_payments(id,installment_id,amount,transaction_id,request_payload)
      values(gen_random_uuid(),installment.id,amount,document_id,input);
  end if;
  insert into private.finance_commands_v1 values(command_key,input,result);
  insert into public.audit_events(actor_id,action,entity_type,entity_id,location_id,after_data)
    values(actor,case when command='create' then 'loan_created' else 'loan_installment_paid' end,
      'loan',coalesce(loan.id,result),location,jsonb_build_object('amount',amount,'settlement_id',posted_settlement));
  return result;
end $$;

-- The existing status guard still protects posted loan documents. Use the
-- standard settlement reversal path and prohibit funding reversal while any
-- repayment continues to apply.
drop trigger loan_history_settlement_guard on public.transaction_settlements;
create function private.guard_loan_funding_reversal_v1()
returns trigger language plpgsql security definer set search_path='' as $$
declare funding_loan_id uuid;
begin
  select l.id into funding_loan_id from private.company_loans l
    join public.transaction_settlements funding on funding.transaction_id=l.transaction_id
    where funding.id=new.reversed_settlement_id for update of l;
  if found and exists(
    select 1 from private.loan_installments i
    cross join lateral private.loan_paid_v1(i.id) p
    where i.loan_id=funding_loan_id and p.amount>0
  ) then
    raise exception using errcode='22023',message='REVERSE_LOAN_PAYMENTS_FIRST';
  end if;
  return new;
end $$;
create trigger guard_loan_funding_reversal before insert on public.transaction_settlements
for each row when (new.reversed_settlement_id is not null)
execute function private.guard_loan_funding_reversal_v1();

-- Use the same payment balance in the existing Operations screen and acquire
-- the finance lock before its loan lock, matching Accounting and reversals.
do $compatibility$
declare
  definition text := pg_get_functiondef('public.company_loans_v1(jsonb)'::regprocedure);
  original text := definition;
begin
  definition := replace(definition, 'if action=''create'' then',
    'if action<>''list'' then perform pg_advisory_xact_lock(7353101101); end if;'||chr(10)||
    ' if action=''create'' then');
  definition := replace(definition, 'if not found then raise exception ''LOAN_NOT_FOUND''; end if;',
    'if not found then raise exception ''LOAN_NOT_FOUND''; end if;'||chr(10)||
    '  if private.loan_funding_reversed_v1(loan.transaction_id) then raise exception ''LOAN_NOT_AVAILABLE''; end if;');
  definition := replace(definition, 'select coalesce(sum(amount),0) into paid from private.loan_payments where installment_id=installment.id;',
    'select p.amount into paid from private.loan_paid_v1(installment.id) p;');
  definition := replace(definition, '(select coalesce(sum(p.amount),0) from private.loan_payments p where p.installment_id=i.id)',
    '(select p.amount from private.loan_paid_v1(i.id) p)');
  definition := regexp_replace(definition, $pattern$jsonb_build_object\(\s*'installments',$pattern$,
    'jsonb_build_object(''cancelled'',private.loan_funding_reversed_v1(l.transaction_id),''installments'',');
  definition := replace(definition, 'to_jsonb(i)||jsonb_build_object(''paid'',',
    'to_jsonb(i)||jsonb_build_object(''schedule_editable'',not exists(select 1 from private.loan_payments p where p.installment_id=i.id),''paid'',');
  if definition=original
    or strpos(definition,'private.loan_funding_reversed_v1(loan.transaction_id)')=0
    or strpos(definition,'private.loan_funding_reversed_v1(l.transaction_id)')=0
    or strpos(definition,'private.loan_paid_v1(installment.id)')=0
    or strpos(definition,'private.loan_paid_v1(i.id)')=0
    or strpos(definition,'pg_advisory_xact_lock(7353101101)')=0 then
    raise exception 'COMPANY_LOANS_PRODUCTION_UPDATE_REQUIRED';
  end if;
  execute definition;
end $compatibility$;

create function private.guard_loan_cash_class_v1()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if new.account is distinct from old.account and exists(
    select 1 from public.treasury_transactions t
    join public.transaction_settlements s on s.id=t.settlement_id
    where t.id=old.treasury_id and (
      exists(select 1 from private.company_loans l where l.transaction_id=s.transaction_id)
      or exists(select 1 from private.loan_payments p where p.transaction_id=s.transaction_id)
    )
  ) then raise exception using errcode='22023',message='LOAN_CASH_CLASS_FIXED'; end if;
  return new;
end $$;
create trigger guard_loan_cash_class before update on private.accounting_cash_classes
for each row execute function private.guard_loan_cash_class_v1();

create function private.restrict_loan_allocations_v1()
returns trigger language plpgsql security definer set search_path='' as $$
declare original public.transaction_settlements%rowtype;
begin
  select * into original from public.transaction_settlements s where s.id=coalesce(
    (select reversal.reversed_settlement_id from public.transaction_settlements reversal
      where reversal.id=new.settlement_id), new.settlement_id);
  if exists(
    select 1 from public.transaction_settlements s
    where s.transaction_id=new.transaction_id and s.id<>original.id
      and s.reversed_settlement_id is null and (
      exists(select 1 from private.company_loans l where l.transaction_id=s.transaction_id)
      or exists(select 1 from private.loan_payments p where p.transaction_id=s.transaction_id)
    )
  ) or (original.transaction_id is distinct from new.transaction_id and (
    exists(select 1 from private.company_loans l where l.transaction_id=original.transaction_id)
    or exists(select 1 from private.loan_payments p where p.transaction_id=original.transaction_id)
  )) then raise exception using errcode='22023',message='PAY_LOAN_FROM_LOAN_SCHEDULE'; end if;
  return new;
end $$;
create trigger restrict_loan_allocations before insert on public.transaction_allocations
for each row execute function private.restrict_loan_allocations_v1();

revoke all on function public.accounting_loans_v1(uuid),public.accounting_loan_command_v1(jsonb),
  private.loan_funding_reversed_v1(uuid),private.loan_paid_v1(uuid),
  private.guard_loan_funding_reversal_v1(),private.guard_loan_cash_class_v1(),
  private.restrict_loan_allocations_v1() from public,anon,authenticated;
grant execute on function public.accounting_loans_v1(uuid),public.accounting_loan_command_v1(jsonb)
  to authenticated;

insert into private.access_v2_rpc_registry(signature,function_oid,original_definition)
select p.oid::regprocedure::text,p.oid,pg_get_functiondef(p.oid) from pg_proc p
where p.pronamespace='public'::regnamespace
  and p.proname in ('company_loans_v1','accounting_loans_v1','accounting_loan_command_v1')
on conflict(signature) do update set function_oid=excluded.function_oid,original_definition=excluded.original_definition;
select private.access_v2_assert_coverage();
notify pgrst,'reload schema';
commit;
