begin;

-- Adjust refund invoice #13 from 14,500.00 to 13,500.00 to account for
-- the 1,000.00 discount on original sale #12 that was omitted during refund.
-- This restores the 1,000.00 difference to sales revenue and the treasury account
-- in the PLUGY EV branch.

do $$
declare
  refund_sale_id uuid;
  refund_tx_id uuid;
  orig_tx_id uuid;
  settlement_rec record;
  diff numeric(14,2);
begin
  -- 1. Locate refund sale for invoice #13 (scoped to PLUGY EV branch if present)
  select s.id into refund_sale_id
  from public.sales s
  left join public.locations l on l.id = s.location_id
  where s.invoice_number = 13
    and s.is_refund = true
    and (
      l.name_en ilike '%plugy%'
      or l.name_ar ilike '%بلاجي%'
      or s.location_id is null
    )
  order by s.created_at desc
  limit 1;

  if refund_sale_id is null then
    select s.id into refund_sale_id
    from public.sales s
    where s.invoice_number = 13 and s.is_refund = true
    order by s.created_at desc
    limit 1;
  end if;

  if refund_sale_id is null then
    raise notice 'Refund invoice #13 not found, skipping adjustment';
    return;
  end if;

  -- 2. Update the refund sale header and line items
  update public.sales
  set total = 13500.00,
      subtotal = 13500.00,
      amount_paid = 13500.00,
      amount_due = 0.00
  where id = refund_sale_id;

  update public.sale_items
  set price = 13500.00,
      sale_price = 13500.00,
      subtotal = 13500.00
  where sale_id = refund_sale_id;

  -- 3. Update the associated unified transaction
  select id, original_transaction_id into refund_tx_id, orig_tx_id
  from public.transactions
  where sale_id = refund_sale_id;

  if refund_tx_id is not null then
    update public.transactions
    set total = 13500.00
    where id = refund_tx_id;

    -- 4. Update settlement records and credit back difference to treasury
    for settlement_rec in
      select id, account_id, amount
      from public.transaction_settlements
      where transaction_id = refund_tx_id
    loop
      diff := settlement_rec.amount - 13500.00;

      update public.transaction_settlements
      set amount = 13500.00
      where id = settlement_rec.id;

      update public.treasury_transactions
      set amount = 13500.00
      where settlement_id = settlement_rec.id or refund_id = refund_sale_id;

      update public.transaction_allocations
      set amount = 13500.00
      where settlement_id = settlement_rec.id;

      if settlement_rec.account_id is not null and diff > 0 then
        update public.treasury_accounts
        set balance = balance + diff,
            updated_at = now()
        where id = settlement_rec.account_id;
      end if;
    end loop;

    -- 5. Update source credits if applied
    update public.transaction_credits
    set amount = 13500.00
    where credit_transaction_id = refund_tx_id or transaction_id = refund_tx_id;

    -- 6. Recalculate transaction summaries and sync document records
    if exists (select 1 from pg_proc where proname = 'sync_transaction_v1') then
      perform private.sync_transaction_v1(refund_tx_id);
      if orig_tx_id is not null then
        perform private.sync_transaction_v1(orig_tx_id);
      end if;
    end if;
  end if;

  insert into public.audit_events(action, entity_type, entity_id, after_data)
  values ('refund_discount_correction', 'sales', refund_sale_id,
          jsonb_build_object('invoice_number', 13, 'adjusted_amount', 1000.00, 'new_total', 13500.00));
end $$;

notify pgrst,'reload schema';
commit;
