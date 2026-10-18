-- Additive, offline migration. Deploy separately to each existing project.
-- Source documents and treasury remain authoritative; no balances are rewritten.
BEGIN;
SET LOCAL search_path = '';
DO $$ BEGIN
 IF to_regprocedure('private.access_v2_allows(uuid,text,uuid,uuid[])') IS NULL
 OR to_regprocedure('private.record_expense_documents_v1(jsonb)') IS NULL THEN
  RAISE EXCEPTION 'ACCOUNTING_PREREQUISITES_MISSING';
 END IF;
END $$;
ALTER TABLE public.expenses ADD COLUMN expense_type text NOT NULL DEFAULT 'operating'
 CHECK(expense_type IN ('operating','administrative'));
ALTER TABLE public.expenses ADD COLUMN cost_behavior text NOT NULL DEFAULT 'variable'
 CHECK(cost_behavior IN ('fixed','variable'));

-- Existing access views expand SELECT * when created, so append the new fields
-- without replacing their row authorization or financial-field redaction.
DO $$ DECLARE definition text; BEGIN
 SELECT regexp_replace(pg_get_viewdef('public.access_v2_expenses'::regclass,true),';\s*$','') INTO definition;
 EXECUTE 'CREATE OR REPLACE VIEW public.access_v2_expenses WITH(security_barrier=true) AS SELECT d.*, e.expense_type,e.cost_behavior FROM ('||definition||') d JOIN public.expenses e ON e.id=d.id';
END $$;

INSERT INTO private.access_v2_permissions(id,scope,write_action,dependencies) VALUES
 ('accounting.read','location',false,'{}'),
 ('accounting.manage','location',true,ARRAY['accounting.read']);
UPDATE private.access_v2_state SET revision=revision+1;

CREATE TABLE private.accounting_budgets (
 location_id uuid NOT NULL REFERENCES public.locations(id), month date NOT NULL CHECK(extract(day FROM month)=1),
 category text NOT NULL CHECK(length(btrim(category)) BETWEEN 1 AND 120),
 amount numeric(14,2) NOT NULL CHECK(amount>=0 AND amount::text NOT IN ('NaN','Infinity','-Infinity')),
 PRIMARY KEY(location_id,month,category)
);
CREATE TABLE private.accounting_assets (
 expense_id uuid PRIMARY KEY REFERENCES public.expenses(id),
 in_service date NOT NULL, useful_life_months integer NOT NULL CHECK(useful_life_months BETWEEN 1 AND 1200),
 residual_value numeric(14,2) NOT NULL CHECK(residual_value>=0),
 disposal_date date, disposal_treasury_id uuid UNIQUE REFERENCES public.treasury_transactions(id),
 CHECK(disposal_treasury_id IS NULL OR disposal_date IS NOT NULL)
);
CREATE TABLE private.accounting_voids (
 transaction_id uuid PRIMARY KEY REFERENCES public.transactions(id), voided_at timestamptz NOT NULL, date_uncertain boolean NOT NULL DEFAULT false
);
INSERT INTO private.accounting_voids
 SELECT t.id,coalesce((SELECT min(a.created_at) FROM public.audit_events a WHERE a.entity_id=t.id AND a.action='transaction_voided'),t.occurred_at),
  NOT EXISTS(SELECT 1 FROM public.audit_events a WHERE a.entity_id=t.id AND a.action='transaction_voided')
 FROM public.transactions t WHERE t.status='void' AND t.type IN ('expense','purchase');
CREATE FUNCTION private.capture_accounting_void_v1() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' SET timezone='Africa/Cairo' AS $$ BEGIN
 IF new.status='void' AND old.status<>'void' THEN INSERT INTO private.accounting_voids(transaction_id,voided_at) VALUES(new.id,now()) ON CONFLICT DO NOTHING; END IF;
 RETURN new; END $$;
CREATE TRIGGER accounting_void AFTER UPDATE OF status ON public.transactions FOR EACH ROW EXECUTE FUNCTION private.capture_accounting_void_v1();

CREATE TABLE private.accounting_cash_classes (
 treasury_id uuid PRIMARY KEY REFERENCES public.treasury_transactions(id),
 account text NOT NULL CHECK(account IN ('owner_capital','capital_contributions','owner_distributions','loans','noncurrent_liabilities','other_liabilities','prepaid_expenses','other_income','other_expenses','tax_payable','asset_proceeds')),
 activity text NOT NULL CHECK(activity IN ('operating','investing','financing'))
);
CREATE TABLE private.accounting_journals (
 id uuid PRIMARY KEY, location_id uuid REFERENCES public.locations(id),
 occurred_at timestamptz NOT NULL, reason text NOT NULL CHECK(length(btrim(reason))>=3),
 lines jsonb NOT NULL CHECK(jsonb_typeof(lines)='array'),
 reverses uuid UNIQUE REFERENCES private.accounting_journals(id),
 created_by uuid NOT NULL REFERENCES public.profiles(id), created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE private.accounting_cost_pools (
 expense_id uuid PRIMARY KEY REFERENCES public.expenses(id),
 cost_class text NOT NULL CHECK(cost_class IN ('shipping','customs','direct','indirect')),
 driver text NOT NULL CHECK(driver IN ('units','weight','volume','orders','handling','testing')),
 capitalize boolean NOT NULL DEFAULT false,
 allocations jsonb NOT NULL CHECK(jsonb_typeof(allocations)='array'),
 production_overhead boolean NOT NULL DEFAULT false
);
DO $$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['budgets','assets','cash_classes','journals','cost_pools','voids'] LOOP
  EXECUTE format('ALTER TABLE private.accounting_%I ENABLE ROW LEVEL SECURITY',t);
  EXECUTE format('REVOKE ALL ON private.accounting_%I FROM public,anon,authenticated',t);
 END LOOP;
END $$;

CREATE FUNCTION private.accounting_visible_v1(loc uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' SET timezone='Africa/Cairo' AS $$
 SELECT private.actor_is_active_v1() AND CASE WHEN private.access_v2_enabled(auth.uid())
 THEN private.access_v2_allows(auth.uid(),'accounting.read',loc)
 ELSE private.has_permission(auth.uid(),'viewReports') AND ((loc IS NULL AND NOT private.branch_scope_restricted(auth.uid())) OR (loc IS NOT NULL AND private.has_location_access(auth.uid(),loc))) END;
$$;
CREATE FUNCTION private.require_accounting_v1(loc uuid,writing boolean DEFAULT false)
RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' SET timezone='Africa/Cairo' AS $$
BEGIN
 IF NOT coalesce(private.actor_is_active_v1(),false) THEN RAISE EXCEPTION USING errcode='42501',message='AUTH_REQUIRED'; END IF;
 IF writing THEN
  -- Budget and accounting adjustments require an admin AND the explicit grant.
  IF NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=auth.uid() AND role='admin' AND is_active) THEN
   RAISE EXCEPTION USING errcode='42501',message='ACCOUNTING_ADMIN_REQUIRED'; END IF;
  IF private.access_v2_enabled(auth.uid()) THEN PERFORM private.access_v2_require('accounting.manage',loc);
  ELSIF NOT private.has_permission(auth.uid(),'manageTreasury') OR (loc IS NULL AND private.branch_scope_restricted(auth.uid())) OR (loc IS NOT NULL AND NOT private.has_location_access(auth.uid(),loc)) THEN
   RAISE EXCEPTION USING errcode='42501',message='ACCOUNTING_FORBIDDEN'; END IF;
 ELSE
  IF loc IS NOT NULL AND NOT private.accounting_visible_v1(loc) THEN
   RAISE EXCEPTION USING errcode='42501',message='ACCOUNTING_FORBIDDEN'; END IF;
  IF loc IS NULL AND NOT private.accounting_visible_v1(NULL) AND NOT EXISTS(
   SELECT 1 FROM public.locations WHERE private.accounting_visible_v1(id)) THEN
   RAISE EXCEPTION USING errcode='42501',message='ACCOUNTING_FORBIDDEN'; END IF;
 END IF;
END $$;

CREATE FUNCTION private.classify_accounting_expense_v1() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$ BEGIN
 IF new.destination='asset' AND private.access_v2_enabled(auth.uid()) THEN
  PERFORM private.access_v2_require('asset_purchase.create',new.location_id); END IF;
 IF new.salary_record_id IS NOT NULL THEN
  new.expense_type:='administrative';
  SELECT CASE WHEN p.salary_type='hourly' THEN 'variable' ELSE 'fixed' END INTO new.cost_behavior
   FROM public.salary_records sr JOIN public.profiles p ON p.id=sr.user_id WHERE sr.id=new.salary_record_id;
 END IF;
 RETURN new; END $$;
CREATE TRIGGER classify_accounting_expense BEFORE INSERT ON public.expenses FOR EACH ROW EXECUTE FUNCTION private.classify_accounting_expense_v1();
REVOKE ALL ON FUNCTION private.classify_accounting_expense_v1() FROM public,anon,authenticated;

-- Persist classifications through the existing posting command. Rewriting only
-- the private implementation retains all installed public authorization wrappers.
DO $$ DECLARE definition text; BEGIN
 SELECT pg_get_functiondef('private.record_expense_documents_v1(jsonb)'::regprocedure) INTO definition;
 IF position('payment_status, destination' IN definition)=0 THEN RAISE EXCEPTION 'ACCOUNTING_REQUIRES_ASSET_MIGRATION'; END IF;
 definition:=replace(definition,'payment_status, destination','payment_status, destination, expense_type, cost_behavior');
 definition:=replace(definition,'coalesce(nullif(expense_input->>''destination'',''''),''expense'')',
  'coalesce(nullif(expense_input->>''destination'',''''),''expense''), coalesce(expense_input->>''expense_type'',''operating''), coalesce(expense_input->>''cost_behavior'',''variable'')');
 EXECUTE definition;
END $$;

CREATE FUNCTION public.update_expense_metadata_v1(expense_id uuid,input jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' SET timezone='Africa/Cairo' AS $$
DECLARE e public.expenses; BEGIN
 SELECT * INTO e FROM public.expenses WHERE id=expense_id FOR UPDATE;
 IF NOT found OR e.is_void THEN RAISE EXCEPTION 'EXPENSE_NOT_FOUND'; END IF;
 IF NOT private.actor_is_active_v1() OR NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=auth.uid() AND role='admin') THEN RAISE EXCEPTION USING errcode='42501',message='EXPENSE_ADMIN_REQUIRED'; END IF;
 IF private.access_v2_enabled(auth.uid()) THEN PERFORM private.access_v2_require('expense.replace',e.location_id);
 ELSIF NOT private.has_permission(auth.uid(),'manageTreasury') OR NOT private.has_location_access(auth.uid(),e.location_id) THEN RAISE EXCEPTION USING errcode='42501',message='EXPENSE_FORBIDDEN'; END IF;
 IF input - ARRAY['title','notes','category','expense_type','cost_behavior','campaign_platform','shipping_company','payer_name'] <> '{}'::jsonb THEN
  RAISE EXCEPTION 'INVALID_EXPENSE_METADATA'; END IF;
 IF length(btrim(input->>'title'))=0 OR length(btrim(input->>'category'))=0 THEN RAISE EXCEPTION 'INVALID_EXPENSE_METADATA'; END IF;
 IF input->>'expense_type'='administrative' AND EXISTS(SELECT 1 FROM private.accounting_cost_pools pool WHERE pool.expense_id=e.id AND pool.capitalize) THEN
  RAISE EXCEPTION 'REVERSE_COST_ALLOCATION_BEFORE_RECLASSIFICATION'; END IF;
 UPDATE public.expenses SET title=input->>'title',notes=input->>'notes',category=input->>'category',
 expense_type=input->>'expense_type',cost_behavior=input->>'cost_behavior',campaign_platform=input->>'campaign_platform',
 shipping_company=input->>'shipping_company',payer_name=input->>'payer_name' WHERE id=expense_id;
 INSERT INTO public.audit_events(actor_id,action,entity_type,entity_id,location_id,before_data,after_data)
 VALUES(auth.uid(),'expense_classified','expense',expense_id,e.location_id,to_jsonb(e),input);
END $$;
-- Direct classification updates are intentionally not granted to clients.
-- Authorized definer commands can update through the existing financial guard.

CREATE FUNCTION public.accounting_command_v1(input jsonb)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' SET timezone='Africa/Cairo' AS $$
DECLARE operation text:=input->>'operation'; loc uuid:=nullif(input->>'location_id','')::uuid;
 target uuid:=nullif(input->>'id','')::uuid; e public.expenses; cash public.treasury_transactions;
 previous jsonb; proposed jsonb; item jsonb; total numeric; allocated numeric; weight_sum numeric;
 pool_class text; pool_capitalize boolean; journal_balance numeric; journal_id uuid; existing private.accounting_journals;
BEGIN
 PERFORM private.require_accounting_v1(loc,true);
 IF loc IS NULL AND operation NOT IN ('journal','reverse_journal') THEN RAISE EXCEPTION 'ACCOUNTING_LOCATION_REQUIRED'; END IF;
 IF length(btrim(coalesce(input->>'reason','')))<3 THEN RAISE EXCEPTION 'ACCOUNTING_REASON_REQUIRED'; END IF;
 IF target IS NOT NULL THEN PERFORM pg_advisory_xact_lock(hashtextextended(target::text,0)); END IF;
 IF operation='budget' AND (NOT isfinite((input->>'month')::date) OR (input->>'amount')::numeric<>round((input->>'amount')::numeric,2)) THEN RAISE EXCEPTION 'INVALID_BUDGET'; END IF;
 IF operation IN ('journal','reverse_journal') AND NOT isfinite((input->>'occurred_at')::timestamptz) THEN RAISE EXCEPTION 'INVALID_JOURNAL_DATE'; END IF;
 IF operation='asset' AND NOT isfinite((input->>'in_service')::date) THEN RAISE EXCEPTION 'INVALID_ASSET_DATE'; END IF;
 IF operation='dispose_asset' AND NOT isfinite((input->>'disposal_date')::date) THEN RAISE EXCEPTION 'INVALID_ASSET_DATE'; END IF;
 IF operation='budget' THEN
  SELECT to_jsonb(b) INTO previous FROM private.accounting_budgets b WHERE location_id=loc AND month=(input->>'month')::date AND category=input->>'category';
  INSERT INTO private.accounting_budgets VALUES(loc,(input->>'month')::date,btrim(input->>'category'),(input->>'amount')::numeric)
  ON CONFLICT(location_id,month,category) DO UPDATE SET amount=excluded.amount;
 ELSIF operation='reverse_cost_pool' THEN
  SELECT * INTO e FROM public.expenses WHERE id=target AND location_id=loc FOR UPDATE;
  IF NOT found THEN RAISE EXCEPTION 'EXPENSE_NOT_FOUND'; END IF;
  DELETE FROM private.accounting_cost_pools WHERE expense_id=target RETURNING to_jsonb(accounting_cost_pools.*) INTO previous;
  IF previous IS NULL THEN RAISE EXCEPTION 'COST_ALLOCATION_NOT_FOUND'; END IF;
 ELSIF operation='undo_disposal' THEN
  SELECT * INTO e FROM public.expenses WHERE id=target AND location_id=loc FOR UPDATE;
  IF NOT found THEN RAISE EXCEPTION 'EXPENSE_NOT_FOUND'; END IF;
  SELECT to_jsonb(a) INTO previous FROM private.accounting_assets a WHERE expense_id=target;
  IF previous->>'disposal_date' IS NULL THEN RAISE EXCEPTION 'ASSET_NOT_DISPOSED'; END IF;
  DELETE FROM private.accounting_cash_classes WHERE treasury_id=(previous->>'disposal_treasury_id')::uuid;
  UPDATE private.accounting_assets SET disposal_date=NULL,disposal_treasury_id=NULL WHERE expense_id=target;
 ELSIF operation IN ('asset','dispose_asset','cost_pool') THEN
  SELECT * INTO e FROM public.expenses WHERE id=target FOR UPDATE;
  IF NOT found OR e.is_void OR e.location_id IS DISTINCT FROM loc THEN RAISE EXCEPTION 'EXPENSE_NOT_FOUND'; END IF;
  IF operation='asset' THEN
   IF e.destination<>'asset' OR (input->>'residual_value')::numeric>e.amount OR (input->>'in_service')::date<e.created_at::date THEN RAISE EXCEPTION 'INVALID_ASSET_SCHEDULE'; END IF;
   SELECT to_jsonb(a) INTO previous FROM private.accounting_assets a WHERE expense_id=target;
   IF previous->>'disposal_date' IS NOT NULL THEN RAISE EXCEPTION 'ASSET_ALREADY_DISPOSED'; END IF;
   INSERT INTO private.accounting_assets(expense_id,in_service,useful_life_months,residual_value)
   VALUES(target,(input->>'in_service')::date,(input->>'useful_life_months')::integer,(input->>'residual_value')::numeric)
   ON CONFLICT(expense_id) DO UPDATE SET in_service=excluded.in_service,useful_life_months=excluded.useful_life_months,residual_value=excluded.residual_value;
  ELSIF operation='dispose_asset' THEN
   IF nullif(input->>'treasury_id','') IS NOT NULL THEN
   SELECT * INTO cash FROM public.treasury_transactions WHERE id=(input->>'treasury_id')::uuid FOR UPDATE;
   IF NOT found OR cash.direction<>'incoming' OR cash.location_id IS DISTINCT FROM loc OR cash.transaction_date::date<>(input->>'disposal_date')::date
    OR EXISTS(SELECT 1 FROM private.accounting_cash_classes WHERE treasury_id=cash.id) THEN RAISE EXCEPTION 'INVALID_ASSET_PROCEEDS'; END IF;
   IF cash.sale_id IS NOT NULL OR cash.refund_id IS NOT NULL OR cash.expense_id IS NOT NULL OR cash.salary_record_id IS NOT NULL
    OR EXISTS(SELECT 1 FROM public.transaction_settlements s JOIN public.transactions t ON t.id=s.transaction_id WHERE s.id=cash.settlement_id AND t.type NOT IN ('deposit','adjustment')) THEN RAISE EXCEPTION 'CASH_ALREADY_CLASSIFIED'; END IF;
   END IF;
   SELECT to_jsonb(a) INTO previous FROM private.accounting_assets a WHERE expense_id=target FOR UPDATE;
   IF previous IS NULL OR previous->>'disposal_date' IS NOT NULL OR (input->>'disposal_date')::date<(previous->>'in_service')::date THEN RAISE EXCEPTION 'INVALID_ASSET_DISPOSAL'; END IF;
   UPDATE private.accounting_assets SET disposal_date=(input->>'disposal_date')::date,disposal_treasury_id=cash.id WHERE expense_id=target;
   IF cash.id IS NOT NULL THEN INSERT INTO private.accounting_cash_classes VALUES(cash.id,'asset_proceeds','investing'); END IF;
  ELSE
   IF e.destination<>'expense' OR e.salary_record_id IS NOT NULL THEN RAISE EXCEPTION 'INVALID_COST_SOURCE'; END IF;
   pool_class:=input->>'cost_class'; pool_capitalize:=coalesce((input->>'capitalize')::boolean,false);
   IF coalesce((input->>'already_in_purchase_cost')::boolean,false) THEN RAISE EXCEPTION 'COST_ALREADY_INCLUDED'; END IF;
   IF pool_capitalize AND ((pool_class='indirect' AND NOT coalesce((input->>'production_overhead')::boolean,false)) OR e.expense_type='administrative') THEN RAISE EXCEPTION 'NON_INVENTORIABLE_COST'; END IF;
   IF EXISTS(SELECT 1 FROM private.accounting_cost_pools WHERE expense_id=target) THEN RAISE EXCEPTION 'COST_ALREADY_ALLOCATED'; END IF;
   IF jsonb_typeof(input->'allocations')<>'array' OR jsonb_array_length(input->'allocations')=0 THEN RAISE EXCEPTION 'COST_DRIVERS_REQUIRED'; END IF;
   total:=e.amount; weight_sum:=0;
   FOR item IN SELECT value FROM jsonb_array_elements(input->'allocations') LOOP
    IF (item->>'weight')::numeric IS NULL OR (item->>'weight')::numeric<=0 OR (item->>'weight')::numeric::text IN ('NaN','Infinity','-Infinity') THEN RAISE EXCEPTION 'INVALID_COST_DRIVER'; END IF;
    IF NOT EXISTS(SELECT 1 FROM public.stock_receipt_items i JOIN public.stock_receipts r ON r.id=i.receipt_id JOIN public.transactions t ON t.stock_receipt_id=r.id
     WHERE i.id=(item->>'receipt_item_id')::uuid AND r.location_id=loc AND t.status='posted') THEN RAISE EXCEPTION 'INVALID_COST_RECEIPT'; END IF;
    weight_sum:=weight_sum+(item->>'weight')::numeric;
   END LOOP;
   IF (SELECT count(DISTINCT x->>'receipt_item_id') FROM jsonb_array_elements(input->'allocations') x)<>jsonb_array_length(input->'allocations') THEN RAISE EXCEPTION 'DUPLICATE_COST_DRIVER'; END IF;
   -- Largest remainder in cents: allocations sum to the source cost exactly.
   WITH weights AS (SELECT (x->>'receipt_item_id')::uuid id,(x->>'weight')::numeric weight FROM jsonb_array_elements(input->'allocations') x),
   raw AS (SELECT *,total*100*weight/weight_sum exact FROM weights),
   ranked AS (SELECT *,floor(exact) cents,row_number() OVER(ORDER BY exact-floor(exact) DESC,id) rank FROM raw),
   final AS (SELECT *,cents+CASE WHEN rank<=total*100-sum(cents) OVER() THEN 1 ELSE 0 END allocated_cents FROM ranked)
   SELECT jsonb_agg(jsonb_build_object('receipt_item_id',id,'weight',weight,'amount',allocated_cents/100) ORDER BY id) INTO proposed FROM final;
   INSERT INTO private.accounting_cost_pools VALUES(target,pool_class,input->>'driver',pool_capitalize,proposed,coalesce((input->>'production_overhead')::boolean,false));
  END IF;
 ELSIF operation='cash_class' THEN
  SELECT * INTO cash FROM public.treasury_transactions WHERE id=target FOR UPDATE;
  IF NOT found OR cash.location_id IS DISTINCT FROM loc THEN RAISE EXCEPTION 'CASH_NOT_FOUND'; END IF;
  IF cash.sale_id IS NOT NULL OR cash.refund_id IS NOT NULL OR cash.expense_id IS NOT NULL OR cash.salary_record_id IS NOT NULL
   OR EXISTS(SELECT 1 FROM public.transaction_settlements s JOIN public.transactions t ON t.id=s.transaction_id WHERE s.id=cash.settlement_id AND t.type NOT IN ('deposit','withdrawal','adjustment'))
   OR EXISTS(SELECT 1 FROM private.accounting_assets WHERE disposal_treasury_id=target) THEN RAISE EXCEPTION 'CASH_ALREADY_CLASSIFIED'; END IF;
  IF input->>'account'='asset_proceeds' THEN RAISE EXCEPTION 'USE_ASSET_DISPOSAL'; END IF;
  SELECT to_jsonb(c) INTO previous FROM private.accounting_cash_classes c WHERE treasury_id=target;
  INSERT INTO private.accounting_cash_classes VALUES(target,input->>'account',CASE WHEN input->>'account' IN ('owner_capital','capital_contributions','owner_distributions','loans') THEN 'financing' ELSE 'operating' END)
   ON CONFLICT(treasury_id) DO UPDATE SET account=excluded.account,activity=excluded.activity;
 ELSIF operation IN ('journal','reverse_journal') THEN
  IF target IS NULL THEN RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED'; END IF;
  SELECT * INTO existing FROM private.accounting_journals WHERE id=target;
  IF found THEN
   IF existing.location_id IS NOT DISTINCT FROM loc AND existing.reason=input->>'reason'
    AND existing.occurred_at=(input->>'occurred_at')::timestamptz AND (
     (operation='journal' AND existing.reverses IS NULL AND existing.lines=input->'lines') OR
     (operation='reverse_journal' AND existing.reverses=(input->>'reverses')::uuid)) THEN RETURN target; END IF;
   RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT';
  END IF;
  IF operation='reverse_journal' THEN
   SELECT * INTO existing FROM private.accounting_journals WHERE id=(input->>'reverses')::uuid FOR UPDATE;
   IF NOT found OR existing.location_id IS DISTINCT FROM loc THEN RAISE EXCEPTION 'JOURNAL_NOT_FOUND'; END IF;
   SELECT jsonb_agg(jsonb_build_object('account',x->>'account','amount',-(x->>'amount')::numeric)) INTO proposed FROM jsonb_array_elements(existing.lines) x;
  ELSE proposed:=input->'lines'; END IF;
  IF proposed IS NULL OR jsonb_typeof(proposed)<>'array' OR jsonb_array_length(proposed)<2 THEN RAISE EXCEPTION 'BALANCED_JOURNAL_REQUIRED'; END IF;
  journal_balance:=0;
  FOR item IN SELECT value FROM jsonb_array_elements(proposed) LOOP
   IF item->>'account' NOT IN ('receivables','inventory','prepaid_expenses','fixed_assets','accumulated_depreciation','payables','customer_advances','loans','accrued_expenses','tax_payable','other_liabilities','noncurrent_liabilities','owner_capital','capital_contributions','retained_earnings','owner_distributions','suspense','transfer_clearing','operating_expenses','administrative_expenses','other_expenses','income_tax','other_income')
    OR item->>'account' IS NULL OR (item->>'amount')::numeric IS NULL OR (item->>'amount')::numeric::text IN ('NaN','Infinity','-Infinity') OR (item->>'amount')::numeric=0 OR (item->>'amount')::numeric<>round((item->>'amount')::numeric,2) THEN RAISE EXCEPTION 'INVALID_JOURNAL_LINE'; END IF;
   journal_balance:=journal_balance+(item->>'amount')::numeric;
  END LOOP;
  IF journal_balance<>0 THEN RAISE EXCEPTION 'JOURNAL_NOT_BALANCED'; END IF;
  INSERT INTO private.accounting_journals VALUES(target,loc,(input->>'occurred_at')::timestamptz,input->>'reason',proposed,
   CASE WHEN operation='reverse_journal' THEN (input->>'reverses')::uuid END,auth.uid(),now());
 ELSE RAISE EXCEPTION 'UNKNOWN_ACCOUNTING_COMMAND'; END IF;
 INSERT INTO public.audit_events(actor_id,action,entity_type,entity_id,location_id,before_data,after_data)
 VALUES(auth.uid(),'accounting_'||operation,'accounting',coalesce(target,gen_random_uuid()),loc,previous,input||jsonb_build_object('allocated',proposed));
 RETURN target;
END $$;

-- Completed monthly straight-line charges, starting at the in-service date.
-- The final month absorbs rounding; disposal recognizes depreciation to date.
CREATE FUNCTION private.asset_depreciation_v1(cutoff date)
RETURNS TABLE(expense_id uuid,location_id uuid,occurred_at timestamptz,amount numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' SET timezone='Africa/Cairo' AS $$
 WITH assets AS (SELECT a.*,e.location_id,e.amount cost,v.voided_at
  FROM private.accounting_assets a JOIN public.expenses e ON e.id=a.expense_id
  LEFT JOIN public.transactions t ON t.expense_id=e.id LEFT JOIN private.accounting_voids v ON v.transaction_id=t.id),
 monthly AS (
  SELECT a.expense_id,a.location_id,(a.in_service+make_interval(months=>n))::timestamptz occurred_at,
   round((a.cost-a.residual_value)*n/a.useful_life_months,2)-round((a.cost-a.residual_value)*(n-1)/a.useful_life_months,2) amount
  FROM assets a CROSS JOIN LATERAL generate_series(1,a.useful_life_months) n
  WHERE (a.in_service+make_interval(months=>n))::date<=least(cutoff,coalesce(a.disposal_date,cutoff),coalesce(a.voided_at::date,cutoff))
 ), partial AS (
  SELECT a.expense_id,a.location_id,a.disposal_date::timestamptz occurred_at,
   least(a.cost-a.residual_value,round((a.cost-a.residual_value)*
    (completed.n + (a.disposal_date-(a.in_service+make_interval(months=>completed.n))::date)::numeric /
     greatest(1,(a.in_service+make_interval(months=>completed.n+1))::date-(a.in_service+make_interval(months=>completed.n))::date)) / a.useful_life_months,2))
    -round((a.cost-a.residual_value)*completed.n/a.useful_life_months,2) amount
  FROM assets a CROSS JOIN LATERAL(SELECT count(*)::integer n FROM generate_series(1,a.useful_life_months) n
   WHERE (a.in_service+make_interval(months=>n))::date<=a.disposal_date) completed
  WHERE a.disposal_date<=cutoff
 ) SELECT * FROM monthly UNION ALL SELECT * FROM partial
 UNION ALL SELECT a.expense_id,a.location_id,a.voided_at,-coalesce((SELECT sum(m.amount) FROM monthly m WHERE m.expense_id=a.expense_id),0)
 FROM assets a WHERE a.voided_at::date<=cutoff;
$$;

-- Supplementary landed costs use moving weighted average, independently of the
-- original immutable purchase/sale cost snapshots. Transfers carry the layer;
-- refunds restore the original sale's layer. No operating ABC pool is capitalized.
CREATE FUNCTION private.landed_cost_movements_v1(cutoff timestamptz)
RETURNS TABLE(source_id uuid,location_id uuid,occurred_at timestamptz,account text,amount numeric)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' SET timezone='Africa/Cairo' AS $$
DECLARE r record; state jsonb:='{}'; sales jsonb:='{}'; transfers jsonb:='{}'; key text; sale_key text; transfer_key text;
 qty numeric; value numeric; unit_extra numeric; moved numeric; original uuid; sold jsonb; refunded_qty numeric; refund_total numeric;
BEGIN
 FOR r IN
  WITH affected AS (SELECT DISTINCT i.product_id FROM private.accounting_cost_pools p CROSS JOIN LATERAL jsonb_array_elements(p.allocations) x JOIN public.stock_receipt_items i ON i.id=(x->>'receipt_item_id')::uuid WHERE p.capitalize)
  SELECT * FROM (SELECT m.id,m.product_id,m.location_id,m.created_at at,m.quantity_delta qty,m.movement_type kind,m.sale_id,m.transfer_id,0::numeric extra
   FROM public.inventory_movements m WHERE m.created_at<cutoff AND m.product_id IN (SELECT product_id FROM affected)
  UNION ALL
  SELECT e.id,i.product_id,e.location_id,receipt.receipt_date,0,'landed',NULL::uuid,NULL::uuid,(allocation->>'amount')::numeric
   FROM private.accounting_cost_pools pool JOIN public.expenses e ON e.id=pool.expense_id AND NOT e.is_void
   CROSS JOIN LATERAL jsonb_array_elements(pool.allocations) allocation
   JOIN public.stock_receipt_items i ON i.id=(allocation->>'receipt_item_id')::uuid
   JOIN public.stock_receipts receipt ON receipt.id=i.receipt_id
   JOIN public.transactions t ON t.stock_receipt_id=receipt.id AND t.status='posted'
   WHERE pool.capitalize AND receipt.receipt_date<cutoff
  ) events ORDER BY at,CASE kind WHEN 'opening' THEN 0 WHEN 'receipt' THEN 1 WHEN 'landed' THEN 2 WHEN 'transfer_out' THEN 3 WHEN 'transfer_in' THEN 4 ELSE 5 END,id
 LOOP
  key:=r.location_id::text||':'||r.product_id::text;
  qty:=coalesce((state->key->>'qty')::numeric,0); value:=coalesce((state->key->>'value')::numeric,0);
  unit_extra:=CASE WHEN qty>0 THEN value/qty ELSE 0 END;
  moved:=0;
  IF r.kind='landed' THEN
   value:=value+r.extra;
   -- Charges received after all stock was sold are recognized immediately.
   IF qty<=0 THEN moved:=value; value:=0; account:='cogs'; END IF;
  ELSIF r.qty<0 THEN
   moved:=least(value,round(-r.qty*unit_extra,2)); value:=value-moved;
   IF r.kind='sale' THEN
    sale_key:=r.sale_id::text||':'||r.product_id::text;
    sold:=sales->sale_key;
    sales:=jsonb_set(sales,ARRAY[sale_key],jsonb_build_object('quantity',coalesce((sold->>'quantity')::numeric,0)-r.qty,
     'cost',coalesce((sold->>'cost')::numeric,0)+moved,'refunded',0,'returned_cost',0)); account:='cogs';
   ELSIF r.kind='transfer_out' THEN
    transfer_key:=r.transfer_id::text||':'||r.product_id::text;
    transfers:=jsonb_set(transfers,ARRAY[transfer_key],to_jsonb(moved)); account:='transfer_clearing';
   ELSE account:='other_expenses'; END IF;
   qty:=qty+r.qty;
  ELSE
   IF r.kind='refund' THEN
    SELECT original_sale_id INTO original FROM public.sales WHERE id=r.sale_id;
    sale_key:=original::text||':'||r.product_id::text; sold:=sales->sale_key;
    refunded_qty:=coalesce((sold->>'refunded')::numeric,0)+r.qty;
    refund_total:=CASE WHEN coalesce((sold->>'quantity')::numeric,0)>0 THEN least((sold->>'cost')::numeric,round((sold->>'cost')::numeric*refunded_qty/(sold->>'quantity')::numeric,2)) ELSE 0 END;
    moved:=-(refund_total-coalesce((sold->>'returned_cost')::numeric,0));
    IF sold IS NOT NULL THEN sales:=jsonb_set(sales,ARRAY[sale_key],sold||jsonb_build_object('refunded',refunded_qty,'returned_cost',refund_total)); END IF;
    account:='cogs';
   ELSIF r.kind='transfer_in' THEN
    moved:=-coalesce((transfers->>(r.transfer_id::text||':'||r.product_id::text))::numeric,0); account:='transfer_clearing';
   END IF;
   qty:=qty+r.qty; value:=value-moved;
  END IF;
  state:=jsonb_set(state,ARRAY[key],jsonb_build_object('qty',qty,'value',value));
  IF moved<>0 THEN source_id:=r.id;location_id:=r.location_id;occurred_at:=r.at;amount:=moved;RETURN NEXT; END IF;
 END LOOP;
END $$;

CREATE FUNCTION private.accounting_lines_v1(cutoff timestamptz)
RETURNS TABLE(source_id uuid,location_id uuid,occurred_at timestamptz,account text,amount numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' SET timezone='Africa/Cairo' AS $$
 WITH documents AS (
  SELECT t.*,coalesce(t.location_id,e.location_id) accounting_location,e.destination,e.expense_type,p.capitalize,
   CASE WHEN t.type='refund' THEN -1 ELSE 1 END sign,
   abs(CASE WHEN coalesce(s.tax_total,0)=0 AND s.tax_mode='legacy' THEN coalesce(s.tax,0) ELSE coalesce(s.tax_total,0) END) tax,
   round((abs(coalesce(s.discount_amount,0))+coalesce((SELECT sum(si.item_discount*si.quantity) FROM public.sale_items si WHERE si.sale_id=s.id),0)) /
    CASE WHEN s.tax_mode='inclusive' THEN 1+coalesce(s.tax_rate,0)/100 ELSE 1 END,2) discount, v.voided_at
  FROM public.transactions t LEFT JOIN public.expenses e ON e.id=t.expense_id
  LEFT JOIN public.sales s ON s.id=t.sale_id LEFT JOIN private.accounting_voids v ON v.transaction_id=t.id LEFT JOIN private.accounting_cost_pools p ON p.expense_id=e.id
  WHERE t.status IN ('posted','void') AND t.occurred_at<cutoff
 ), cash AS (
  SELECT c.*,bank.location_id cash_location,coalesce(classes.account,original_class.account) cash_account,coalesce(original.customer_id,s.customer_id) customer_id,coalesce(original.supplier_id,s.supplier_id) supplier_id,coalesce(original.direction,s.direction,c.direction) control_direction,
   coalesce(t.type,CASE WHEN c.sale_id IS NOT NULL THEN 'sale' WHEN c.refund_id IS NOT NULL THEN 'refund'
    WHEN c.expense_id IS NOT NULL THEN 'expense' WHEN c.salary_record_id IS NOT NULL THEN 'salary' END) kind,
   s.transfer_id
  FROM public.treasury_transactions c JOIN public.treasury_accounts bank ON bank.id=c.account_id LEFT JOIN public.transaction_settlements s ON s.id=c.settlement_id
  LEFT JOIN public.transaction_settlements original ON original.id=s.reversed_settlement_id
  LEFT JOIN public.transactions t ON t.id=coalesce(original.transaction_id,s.transaction_id)
  LEFT JOIN private.accounting_cash_classes classes ON classes.treasury_id=c.id
  LEFT JOIN public.treasury_transactions original_cash ON original_cash.settlement_id=original.id
  LEFT JOIN private.accounting_cash_classes original_class ON original_class.treasury_id=original_cash.id
  WHERE c.transaction_date<cutoff
 ), source_lines AS (
 SELECT d.id,d.accounting_location AS location_id,event.at AS occurred_at,x.account,x.amount*event.multiplier AS amount
 FROM documents d CROSS JOIN LATERAL (VALUES(d.occurred_at,1),(d.voided_at,-1)) event(at,multiplier) CROSS JOIN LATERAL (
  SELECT 'receivables'::text account,d.sign*d.total amount WHERE d.type IN ('sale','refund')
  UNION ALL SELECT 'sales',-(d.total-d.tax+d.discount) WHERE d.type='sale'
  UNION ALL SELECT 'discounts',d.discount WHERE d.type='sale'
  UNION ALL SELECT 'returns',d.total-d.tax WHERE d.type='refund'
  UNION ALL SELECT 'tax_payable',-d.sign*d.tax WHERE d.type IN ('sale','refund')
  UNION ALL SELECT CASE WHEN d.capitalize THEN 'landed_cost_clearing' WHEN d.type IN ('purchase','vendor_return') THEN 'inventory'
   WHEN d.destination='asset' THEN 'fixed_assets' WHEN d.type='salary' OR d.expense_type='administrative' THEN 'administrative_expenses' ELSE 'operating_expenses' END,
   CASE WHEN d.type='vendor_return' THEN -d.total ELSE d.total END WHERE d.type IN ('purchase','vendor_return','expense','salary')
  UNION ALL SELECT 'payables',CASE WHEN d.type='vendor_return' THEN d.total ELSE -d.total END WHERE d.type IN ('purchase','vendor_return','expense','salary')
 ) x WHERE event.at IS NOT NULL AND event.at<cutoff
 UNION ALL
 SELECT c.id,x.location_id,c.transaction_date,x.account,x.amount FROM cash c CROSS JOIN LATERAL (
  VALUES ('cash',CASE WHEN c.direction='incoming' THEN c.amount ELSE -c.amount END,c.cash_location),
   (coalesce(c.cash_account,CASE WHEN c.kind IN ('sale','refund') THEN 'receivables'
    WHEN c.kind IN ('purchase','expense','salary','vendor_return') THEN 'payables'
    WHEN c.kind='installation' OR ((c.kind='advance' OR c.customer_id IS NOT NULL) AND c.control_direction='incoming') THEN 'customer_advances'
    WHEN (c.kind='advance' OR c.supplier_id IS NOT NULL) AND c.control_direction='outgoing' THEN 'prepaid_expenses'
    WHEN c.transfer_id IS NOT NULL OR c.source_type IN ('transfer','transfer_in','transfer_out') THEN 'transfer_clearing' ELSE 'suspense' END),
   CASE WHEN c.direction='incoming' THEN -c.amount ELSE c.amount END,c.location_id),
   ('transfer_clearing',CASE WHEN c.cash_location IS DISTINCT FROM c.location_id THEN CASE WHEN c.direction='incoming' THEN c.amount ELSE -c.amount END ELSE 0 END,c.location_id),
   ('transfer_clearing',CASE WHEN c.cash_location IS DISTINCT FROM c.location_id THEN CASE WHEN c.direction='incoming' THEN -c.amount ELSE c.amount END ELSE 0 END,c.cash_location)
 ) x(account,amount,location_id)
 UNION ALL
 SELECT a.id,t.location_id,greatest(t.occurred_at,a.created_at),x.account,x.amount
 FROM public.transaction_allocations a JOIN public.transaction_settlements st ON st.id=a.settlement_id
 LEFT JOIN public.transaction_settlements original ON original.id=st.reversed_settlement_id
 LEFT JOIN public.transactions source ON source.id=coalesce(original.transaction_id,st.transaction_id)
 JOIN public.transactions t ON t.id=a.transaction_id
 CROSS JOIN LATERAL(VALUES
  (CASE WHEN coalesce(original.direction,st.direction)='incoming' THEN 'customer_advances' ELSE 'prepaid_expenses' END,
   CASE WHEN coalesce(original.direction,st.direction)='incoming' THEN a.amount ELSE -a.amount END),
  (CASE WHEN t.type IN ('sale','refund') THEN 'receivables' ELSE 'payables' END,
   CASE WHEN coalesce(original.direction,st.direction)='incoming' THEN -a.amount ELSE a.amount END)) x(account,amount)
 WHERE (source.id IS NULL OR source.type IN ('advance','installation')) AND t.type IN ('sale','refund','purchase','expense','salary','vendor_return')
 AND greatest(t.occurred_at,a.created_at)<cutoff
 UNION ALL
 SELECT a.id,a.location_id,a.created_at,x.account,x.amount FROM public.treasury_accounts a CROSS JOIN LATERAL (
  VALUES('cash',a.opening_balance),('suspense',-a.opening_balance)) x(account,amount) WHERE a.created_at<cutoff
 UNION ALL
 SELECT i.id,i.location_id,i.created_at,x.account,x.amount FROM public.inventory_movements i CROSS JOIN LATERAL (
  VALUES('inventory',round(i.quantity_delta*i.unit_cost_snapshot,2)),
   (CASE WHEN i.movement_type='opening' THEN 'suspense' WHEN i.movement_type IN ('transfer_in','transfer_out') THEN 'transfer_clearing'
    WHEN i.quantity_delta<0 THEN 'other_expenses' ELSE 'other_income' END,-round(i.quantity_delta*i.unit_cost_snapshot,2))) x(account,amount)
 WHERE i.movement_type IN ('opening','adjustment','transfer_in','transfer_out') AND i.created_at<cutoff
 AND NOT(i.movement_type='adjustment' AND i.receipt_id IS NOT NULL AND (i.notes LIKE 'Vendor return %' OR i.notes LIKE 'Receipt cancellation:%'))
 UNION ALL
 SELECT s.id,s.location_id,s.created_at,x.account,x.amount FROM public.sales s JOIN public.transactions t ON t.sale_id=s.id AND t.status='posted'
 CROSS JOIN LATERAL(SELECT round(sum(i.quantity*CASE WHEN EXISTS(SELECT 1 FROM public.inventory_movements m WHERE m.sale_id=s.id) THEN i.unit_cost_snapshot ELSE i.wholesale_price END),2)*CASE WHEN s.is_refund THEN -1 ELSE 1 END value FROM public.sale_items i WHERE i.sale_id=s.id) cost
 CROSS JOIN LATERAL(VALUES('cogs',cost.value),('inventory',-cost.value)) x(account,amount) WHERE s.created_at<cutoff
 UNION ALL
 SELECT d.expense_id,d.location_id,d.occurred_at,x.account,x.amount FROM private.asset_depreciation_v1((cutoff-interval '1 microsecond')::date) d
 CROSS JOIN LATERAL(VALUES('administrative_expenses',d.amount),('accumulated_depreciation',-d.amount)) x(account,amount)
 UNION ALL
 SELECT e.id,e.location_id,a.disposal_date::timestamptz,x.account,x.amount FROM private.accounting_assets a JOIN public.expenses e ON e.id=a.expense_id AND NOT e.is_void
 CROSS JOIN LATERAL(SELECT coalesce(sum(amount),0) value FROM private.asset_depreciation_v1(a.disposal_date) d WHERE d.expense_id=e.id) depreciation
 CROSS JOIN LATERAL(VALUES('fixed_assets',-e.amount),('accumulated_depreciation',depreciation.value),('other_expenses',e.amount-depreciation.value)) x(account,amount)
 WHERE a.disposal_date<(cutoff::date)
 UNION ALL
 SELECT j.id,j.location_id,j.occurred_at,x->>'account',(x->>'amount')::numeric FROM private.accounting_journals j
 CROSS JOIN LATERAL jsonb_array_elements(j.lines) x WHERE j.occurred_at<cutoff
 UNION ALL
 -- Accrue acquisition charges when their goods are received. A later supplier
 -- invoice clears the accrual; an earlier invoice is a prepaid acquisition cost.
 -- This also assigns late freight invoices to the goods already sold correctly.
 SELECT e.id,r.location_id,r.receipt_date,x.account,x.amount FROM private.accounting_cost_pools pool
 JOIN public.expenses e ON e.id=pool.expense_id AND NOT e.is_void
 CROSS JOIN LATERAL jsonb_array_elements(pool.allocations) allocation
 JOIN public.stock_receipt_items i ON i.id=(allocation->>'receipt_item_id')::uuid
 JOIN public.stock_receipts r ON r.id=i.receipt_id JOIN public.transactions t ON t.stock_receipt_id=r.id AND t.status='posted'
 CROSS JOIN LATERAL(VALUES('inventory',(allocation->>'amount')::numeric),('landed_cost_clearing',-(allocation->>'amount')::numeric)) x(account,amount)
 WHERE pool.capitalize AND r.receipt_date<cutoff
 UNION ALL
 SELECT m.source_id,m.location_id,m.occurred_at,x.account,x.amount FROM private.landed_cost_movements_v1(cutoff) m
 CROSS JOIN LATERAL(VALUES(m.account,m.amount),('inventory',-m.amount)) x(account,amount)
 ) SELECT id,location_id,occurred_at,CASE account WHEN 'asset_proceeds' THEN 'other_income' ELSE account END,amount FROM source_lines WHERE amount<>0;
$$;

CREATE FUNCTION public.accounting_report_v1(input jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' SET timezone='Africa/Cairo' AS $$
DECLARE loc uuid:=nullif(input->>'location_id','')::uuid;
 start_at timestamptz:=(input->>'start')::timestamptz; end_at timestamptz:=(input->>'end')::timestamptz;
 result jsonb; pools jsonb; balances jsonb; pnl jsonb; cashflow jsonb; budgets jsonb; assets jsonb; costing jsonb; journals jsonb; unclassified jsonb;
BEGIN
 PERFORM private.require_accounting_v1(loc);
 IF start_at IS NULL OR end_at IS NULL OR start_at>=end_at THEN RAISE EXCEPTION 'INVALID_ACCOUNTING_PERIOD'; END IF;
 WITH lines AS (SELECT * FROM private.accounting_lines_v1(end_at) l WHERE (loc IS NULL OR l.location_id=loc) AND private.accounting_visible_v1(l.location_id)),
 grouped AS (SELECT account,sum(amount) closing,sum(amount) FILTER(WHERE occurred_at>=start_at) period FROM lines GROUP BY account)
 SELECT coalesce(jsonb_object_agg(account,closing),'{}'),coalesce(jsonb_object_agg(account,coalesce(period,0)) FILTER(WHERE account IN ('sales','discounts','returns','cogs','operating_expenses','administrative_expenses','other_expenses','income_tax','other_income')),'{}') INTO balances,pnl FROM grouped;
 WITH entries AS (
  SELECT c.*,coalesce(t.type,CASE WHEN c.sale_id IS NOT NULL THEN 'sale' WHEN c.refund_id IS NOT NULL THEN 'refund' WHEN c.salary_record_id IS NOT NULL THEN 'salary' WHEN c.expense_id IS NOT NULL THEN 'expense' END) kind,CASE WHEN c.direction='incoming' THEN c.amount ELSE -c.amount END signed,
   coalesce(cls.activity,original_class.activity,CASE WHEN e.destination='asset' THEN 'investing' WHEN s.transfer_id IS NOT NULL OR c.source_type IN ('transfer','transfer_in','transfer_out') THEN 'transfer'
    WHEN t.type IN ('sale','refund','purchase','expense','salary','vendor_return','advance','installation') OR c.sale_id IS NOT NULL OR c.refund_id IS NOT NULL OR c.expense_id IS NOT NULL OR c.salary_record_id IS NOT NULL THEN 'operating' ELSE 'unclassified' END) activity
  FROM public.treasury_transactions c JOIN public.treasury_accounts bank ON bank.id=c.account_id LEFT JOIN public.transaction_settlements s ON s.id=c.settlement_id
  LEFT JOIN public.transaction_settlements original ON original.id=s.reversed_settlement_id
  LEFT JOIN public.transactions t ON t.id=coalesce(original.transaction_id,s.transaction_id) LEFT JOIN public.expenses e ON e.id=coalesce(t.expense_id,c.expense_id)
  LEFT JOIN private.accounting_cash_classes cls ON cls.treasury_id=c.id
  LEFT JOIN public.treasury_transactions original_cash ON original_cash.settlement_id=original.id
  LEFT JOIN private.accounting_cash_classes original_class ON original_class.treasury_id=original_cash.id
  WHERE c.transaction_date<end_at AND (loc IS NULL OR bank.location_id=loc) AND private.accounting_visible_v1(bank.location_id) AND private.accounting_visible_v1(c.location_id)
 ), opening AS (SELECT coalesce(sum(a.opening_balance),0) value FROM public.treasury_accounts a WHERE a.created_at<start_at AND (loc IS NULL OR a.location_id=loc) AND private.accounting_visible_v1(a.location_id)),
 created AS (SELECT coalesce(sum(a.opening_balance),0) value FROM public.treasury_accounts a WHERE a.created_at>=start_at AND a.created_at<end_at AND (loc IS NULL OR a.location_id=loc) AND private.accounting_visible_v1(a.location_id))
 SELECT jsonb_build_object('opening',(SELECT value FROM opening)+coalesce(sum(signed) FILTER(WHERE transaction_date<start_at),0),
 'inflows',coalesce(sum(amount) FILTER(WHERE transaction_date>=start_at AND direction='incoming'),0),
 'outflows',coalesce(sum(amount) FILTER(WHERE transaction_date>=start_at AND direction='outgoing'),0),
 'operating',coalesce(sum(signed) FILTER(WHERE transaction_date>=start_at AND activity='operating'),0),
 'investing',coalesce(sum(signed) FILTER(WHERE transaction_date>=start_at AND activity='investing'),0),
 'customer_receipts',coalesce(sum(amount) FILTER(WHERE transaction_date>=start_at AND direction='incoming' AND kind IN ('sale','advance','installation')),0),
 'supplier_payments',coalesce(sum(amount) FILTER(WHERE transaction_date>=start_at AND direction='outgoing' AND kind='purchase'),0),
 'payroll_payments',coalesce(sum(amount) FILTER(WHERE transaction_date>=start_at AND direction='outgoing' AND kind='salary'),0),
 'expense_payments',coalesce(sum(amount) FILTER(WHERE transaction_date>=start_at AND direction='outgoing' AND kind='expense' AND activity='operating'),0),
 'customer_refunds',coalesce(sum(amount) FILTER(WHERE transaction_date>=start_at AND direction='outgoing' AND kind='refund'),0),
 'financing',coalesce(sum(signed) FILTER(WHERE transaction_date>=start_at AND activity='financing'),0),
 'transfers',coalesce(sum(signed) FILTER(WHERE transaction_date>=start_at AND activity='transfer'),0),
 'unclassified',coalesce(sum(signed) FILTER(WHERE transaction_date>=start_at AND activity='unclassified'),0),
 'opening_accounts_in_period',(SELECT value FROM created),
 'closing',(SELECT value FROM opening)+(SELECT value FROM created)+coalesce(sum(signed),0)) INTO cashflow FROM entries;
 -- Reconstruct the selected historical date from current balances and subsequent movements.
 SELECT cashflow||jsonb_build_object('treasury_closing',coalesce(sum(a.balance-coalesce(later.value,0)),0)) INTO cashflow
 FROM public.treasury_accounts a LEFT JOIN LATERAL(SELECT sum(CASE WHEN direction='incoming' THEN amount ELSE -amount END) value FROM public.treasury_transactions c WHERE c.account_id=a.id AND c.transaction_date>=end_at) later ON true
 WHERE a.created_at<end_at AND (loc IS NULL OR a.location_id=loc) AND private.accounting_visible_v1(a.location_id);
 WITH actual AS (SELECT e.location_id,date_trunc('month',events.at)::date AS month,e.category,sum(e.amount*events.sign) amount
 FROM public.expenses e LEFT JOIN public.transactions t ON t.expense_id=e.id LEFT JOIN private.accounting_voids v ON v.transaction_id=t.id
 CROSS JOIN LATERAL(VALUES(e.created_at,1),(v.voided_at,-1)) events(at,sign)
 WHERE e.destination='expense' AND (NOT e.is_void OR v.transaction_id IS NOT NULL) AND events.at>=date_trunc('month',start_at) AND events.at<end_at
 AND (loc IS NULL OR e.location_id=loc) AND private.accounting_visible_v1(e.location_id) GROUP BY 1,2,3),
 planned AS (SELECT * FROM private.accounting_budgets b WHERE month>=date_trunc('month',start_at)::date AND month<end_at::date AND (loc IS NULL OR b.location_id=loc) AND private.accounting_visible_v1(b.location_id))
 SELECT coalesce(jsonb_agg(jsonb_build_object('location_id',coalesce(b.location_id,a.location_id),'month',coalesce(b.month,a.month),'category',coalesce(b.category,a.category),'budget',coalesce(b.amount,0),'actual',coalesce(a.amount,0)) ORDER BY coalesce(b.month,a.month),coalesce(b.category,a.category)),'[]') INTO budgets
 FROM planned b FULL JOIN actual a USING(location_id,month,category);
 SELECT coalesce(jsonb_agg(jsonb_build_object('id',e.id,'title',e.title,'cost',e.amount,'date',e.created_at,
 'in_service',a.in_service,'useful_life_months',a.useful_life_months,'residual_value',a.residual_value,'disposal_date',a.disposal_date,
 'depreciation',coalesce(d.value,0),'book_value',CASE WHEN a.disposal_date<end_at::date THEN 0 ELSE e.amount-coalesce(d.value,0) END) ORDER BY e.created_at DESC),'[]') INTO assets
 FROM public.expenses e LEFT JOIN private.accounting_assets a ON a.expense_id=e.id
 LEFT JOIN LATERAL(SELECT sum(amount) value FROM private.asset_depreciation_v1((end_at-interval '1 microsecond')::date) dep WHERE dep.expense_id=e.id) d ON true
 WHERE e.destination='asset' AND (NOT e.is_void OR EXISTS(SELECT 1 FROM public.transactions t JOIN private.accounting_voids v ON v.transaction_id=t.id WHERE t.expense_id=e.id AND v.voided_at>=end_at)) AND e.created_at<end_at AND (loc IS NULL OR e.location_id=loc) AND private.accounting_visible_v1(e.location_id);
 WITH allocated AS (SELECT i.product_id,r.location_id,p.cost_class,p.capitalize,sum((x->>'amount')::numeric) amount
 FROM private.accounting_cost_pools p JOIN public.expenses e ON e.id=p.expense_id AND NOT e.is_void CROSS JOIN LATERAL jsonb_array_elements(p.allocations) x
 JOIN public.stock_receipt_items i ON i.id=(x->>'receipt_item_id')::uuid JOIN public.stock_receipts r ON r.id=i.receipt_id
 JOIN public.transactions t ON t.stock_receipt_id=r.id AND t.status='posted'
 WHERE r.receipt_date>=start_at AND r.receipt_date<end_at
 AND (loc IS NULL OR r.location_id=loc) AND private.accounting_visible_v1(r.location_id) GROUP BY 1,2,3,4),
 purchases AS (SELECT i.product_id,sum(i.quantity) units,sum(i.line_total) cost FROM public.stock_receipt_items i JOIN public.stock_receipts r ON r.id=i.receipt_id
 JOIN public.transactions t ON t.stock_receipt_id=r.id AND t.status='posted'
 WHERE r.receipt_date>=start_at AND r.receipt_date<end_at AND (loc IS NULL OR r.location_id=loc) AND private.accounting_visible_v1(r.location_id) GROUP BY 1)
 SELECT coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'units',b.units,'purchase_cost',b.cost/b.units,'selling_price',realized.price,'list_price',p.price,
 'shipping',coalesce(c.shipping,0)/b.units,'customs',coalesce(c.customs,0)/b.units,'direct',coalesce(c.direct,0)/b.units,'indirect',coalesce(c.indirect,0)/b.units,
 'capitalized',coalesce(c.capitalized,0)/b.units) ORDER BY p.name),'[]') INTO costing
 FROM purchases b JOIN public.products p ON p.id=b.product_id
 LEFT JOIN LATERAL(SELECT sum(coalesce(si.financial_net,
  (s.total-CASE WHEN s.tax_total=0 AND s.tax_mode='legacy' THEN coalesce(s.tax,0) ELSE s.tax_total END)*si.subtotal/nullif((SELECT sum(i2.subtotal) FROM public.sale_items i2 WHERE i2.sale_id=s.id),0))) / nullif(sum(si.quantity),0) price
  FROM public.sales s JOIN public.sale_items si ON si.sale_id=s.id WHERE si.product_id=p.id AND NOT s.is_refund AND s.created_at>=start_at AND s.created_at<end_at
  AND (loc IS NULL OR s.location_id=loc) AND private.accounting_visible_v1(s.location_id)) realized ON true
 LEFT JOIN LATERAL(SELECT sum(amount) FILTER(WHERE cost_class='shipping') shipping,sum(amount) FILTER(WHERE cost_class='customs') customs,
 sum(amount) FILTER(WHERE cost_class='direct') direct,sum(amount) FILTER(WHERE cost_class='indirect') indirect,sum(amount) FILTER(WHERE capitalize) capitalized FROM allocated a WHERE a.product_id=p.id) c ON true;
 SELECT coalesce(jsonb_agg(to_jsonb(j) ORDER BY j.occurred_at DESC),'[]') INTO journals FROM private.accounting_journals j
 WHERE j.occurred_at>=start_at AND j.occurred_at<end_at AND (loc IS NULL OR j.location_id=loc) AND private.accounting_visible_v1(j.location_id);
 SELECT coalesce(jsonb_agg(jsonb_build_object('id',c.id,'date',c.transaction_date,'location_id',c.location_id,'description',c.description,'amount',c.amount,'direction',c.direction) ORDER BY c.transaction_date DESC),'[]') INTO unclassified
 FROM public.treasury_transactions c LEFT JOIN public.transaction_settlements s ON s.id=c.settlement_id LEFT JOIN public.transactions t ON t.id=s.transaction_id
 WHERE c.transaction_date>=start_at AND c.transaction_date<end_at AND (loc IS NULL OR c.location_id=loc) AND private.accounting_visible_v1(c.location_id)
 AND c.sale_id IS NULL AND c.refund_id IS NULL AND c.expense_id IS NULL AND c.salary_record_id IS NULL AND s.transfer_id IS NULL
 AND coalesce(t.type,'') IN ('','deposit','withdrawal','adjustment') AND coalesce(c.source_type,'') NOT IN ('transfer','transfer_in','transfer_out')
 AND NOT EXISTS(SELECT 1 FROM private.accounting_cash_classes WHERE treasury_id=c.id)
 AND NOT EXISTS(SELECT 1 FROM public.treasury_transactions original_cash JOIN private.accounting_cash_classes cls ON cls.treasury_id=original_cash.id WHERE original_cash.settlement_id=s.reversed_settlement_id);
 SELECT coalesce(jsonb_agg(jsonb_build_object('id',e.id,'title',e.title,'amount',e.amount,'cost_class',p.cost_class,'driver',p.driver,'capitalize',p.capitalize)),'[]') INTO pools
 FROM private.accounting_cost_pools p JOIN public.expenses e ON e.id=p.expense_id
 WHERE NOT e.is_void AND e.created_at<end_at AND (loc IS NULL OR e.location_id=loc) AND private.accounting_visible_v1(e.location_id);
 RETURN jsonb_build_object('balances',balances,'pnl',pnl,'cash_flow',cashflow,'budgets',budgets,'assets',assets,'costing',costing,'journals',journals,'unclassified_cash',unclassified,'cost_pools',pools,'expense_categories',(SELECT coalesce(jsonb_agg(category),'[]') FROM (SELECT DISTINCT e.category FROM public.expenses e WHERE (loc IS NULL OR e.location_id=loc) AND private.accounting_visible_v1(e.location_id)) categories),'legacy_void_dates_unknown',(SELECT count(*) FROM private.accounting_voids v JOIN public.transactions t ON t.id=v.transaction_id WHERE v.date_uncertain AND (loc IS NULL OR t.location_id=loc) AND private.accounting_visible_v1(t.location_id)));
END $$;

CREATE FUNCTION public.accounting_cost_inputs_v1(location_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' SET timezone='Africa/Cairo' AS $$
DECLARE result jsonb; BEGIN
 PERFORM private.require_accounting_v1(location_id,true);
 SELECT jsonb_build_object('expenses',(SELECT coalesce(jsonb_agg(jsonb_build_object('id',e.id,'title',e.title,'amount',e.amount)),'[]') FROM public.expenses e
 WHERE e.location_id=accounting_cost_inputs_v1.location_id AND NOT e.is_void AND e.destination='expense' AND e.salary_record_id IS NULL
 AND NOT EXISTS(SELECT 1 FROM private.accounting_cost_pools WHERE expense_id=e.id)),
 'receipts',(SELECT coalesce(jsonb_agg(jsonb_build_object('id',i.id,'name',p.name,'reference',coalesce(r.reference_number,r.id::text),'quantity',i.quantity)),'[]')
 FROM public.stock_receipt_items i JOIN public.stock_receipts r ON r.id=i.receipt_id JOIN public.products p ON p.id=i.product_id JOIN public.transactions t ON t.stock_receipt_id=r.id AND t.status='posted'
 WHERE r.location_id=accounting_cost_inputs_v1.location_id)) INTO result;
 RETURN result;
END $$;

CREATE FUNCTION private.guard_disposal_settlement_v1() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$ BEGIN
 IF EXISTS(SELECT 1 FROM public.treasury_transactions cash JOIN private.accounting_assets a ON a.disposal_treasury_id=cash.id WHERE cash.settlement_id=new.reversed_settlement_id) THEN
  RAISE EXCEPTION 'UNDO_ASSET_DISPOSAL_BEFORE_RECEIPT_REVERSAL'; END IF;
 RETURN new; END $$;
CREATE TRIGGER guard_disposal_settlement BEFORE INSERT ON public.transaction_settlements FOR EACH ROW EXECUTE FUNCTION private.guard_disposal_settlement_v1();
REVOKE ALL ON FUNCTION private.guard_disposal_settlement_v1() FROM public,anon,authenticated;

-- Cost allocation cannot survive voided inputs; remove its effect automatically
-- in every projection. Disposals must be reversed explicitly before source void.
CREATE FUNCTION private.guard_accounting_asset_v1()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' SET timezone='Africa/Cairo' AS $$ BEGIN
 IF new.is_void AND NOT old.is_void AND EXISTS(SELECT 1 FROM private.accounting_cost_pools WHERE expense_id=old.id) THEN
  RAISE EXCEPTION 'REVERSE_COST_ALLOCATION_BEFORE_VOID'; END IF;
 IF new.is_void AND NOT old.is_void AND EXISTS(SELECT 1 FROM private.accounting_assets WHERE expense_id=old.id AND disposal_date IS NOT NULL) THEN
  RAISE EXCEPTION 'DISPOSED_ASSET_CANNOT_BE_VOIDED'; END IF;
 RETURN new;
END $$;
CREATE TRIGGER guard_accounting_asset BEFORE UPDATE ON public.expenses FOR EACH ROW EXECUTE FUNCTION private.guard_accounting_asset_v1();

DO $$ DECLARE p record; BEGIN
 FOR p IN SELECT oid::regprocedure signature FROM pg_proc WHERE pronamespace='private'::regnamespace AND proname IN
 ('capture_accounting_void_v1','accounting_visible_v1','require_accounting_v1','asset_depreciation_v1','landed_cost_movements_v1','accounting_lines_v1','guard_accounting_asset_v1') LOOP
 EXECUTE format('REVOKE ALL ON FUNCTION %s FROM public,anon,authenticated',p.signature); END LOOP;
END $$;
REVOKE ALL ON FUNCTION public.accounting_report_v1(jsonb),public.accounting_command_v1(jsonb),public.update_expense_metadata_v1(uuid,jsonb),public.accounting_cost_inputs_v1(uuid) FROM public,anon;
GRANT EXECUTE ON FUNCTION public.accounting_report_v1(jsonb),public.accounting_command_v1(jsonb),public.update_expense_metadata_v1(uuid,jsonb),public.accounting_cost_inputs_v1(uuid) TO authenticated;
-- The existing analytics and monthly summaries use the same P&L projection,
-- while retaining their own established report permissions.
CREATE FUNCTION private.accounting_profit_visible_v1(loc uuid,purpose text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' SET timezone='Africa/Cairo' AS $$
 SELECT private.actor_is_active_v1() AND CASE WHEN private.access_v2_enabled(auth.uid())
 THEN private.access_v2_allows(auth.uid(),CASE WHEN purpose='monthly' THEN 'monthly_financial_report.read' ELSE 'report_profit.read' END,loc)
 ELSE private.has_permission(auth.uid(),'viewReports') AND ((loc IS NULL AND NOT private.branch_scope_restricted(auth.uid())) OR (loc IS NOT NULL AND private.has_location_access(auth.uid(),loc))) END;
$$;
CREATE FUNCTION public.accounting_profit_v1(input jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' SET timezone='Africa/Cairo' AS $$
DECLARE loc uuid:=nullif(input->>'location_id','')::uuid; purpose text:=coalesce(input->>'purpose','analytics');
 start_at timestamptz:=(input->>'start')::timestamptz; end_at timestamptz:=(input->>'end')::timestamptz; result jsonb;
BEGIN
 IF start_at IS NULL OR end_at IS NULL OR start_at>=end_at THEN RAISE EXCEPTION 'INVALID_ACCOUNTING_PERIOD'; END IF;
 IF NOT coalesce(private.actor_is_active_v1(),false) OR (loc IS NOT NULL AND NOT private.accounting_profit_visible_v1(loc,purpose)) OR
 (loc IS NULL AND NOT private.accounting_profit_visible_v1(NULL,purpose) AND NOT EXISTS(SELECT 1 FROM public.locations WHERE private.accounting_profit_visible_v1(id,purpose))) THEN
  RAISE EXCEPTION USING errcode='42501',message='PROFIT_REPORT_FORBIDDEN'; END IF;
 SELECT coalesce(jsonb_object_agg(account,value),'{}') INTO result FROM (
 SELECT account,sum(amount) value FROM private.accounting_lines_v1(end_at) l
 WHERE l.occurred_at>=start_at AND (loc IS NULL OR l.location_id=loc) AND private.accounting_profit_visible_v1(l.location_id,purpose)
 AND account IN ('sales','discounts','returns','cogs','operating_expenses','administrative_expenses','other_expenses','income_tax','other_income') GROUP BY account) totals;
 RETURN jsonb_build_object('pnl',result,'total_sales',(SELECT count(*) FROM public.transactions t JOIN public.sales s ON s.id=t.sale_id WHERE t.type='sale' AND t.status='posted' AND t.occurred_at>=start_at AND t.occurred_at<end_at AND (loc IS NULL OR t.location_id=loc) AND private.accounting_profit_visible_v1(t.location_id,purpose)));
END $$;
CREATE FUNCTION public.accounting_monthly_summary_v1(input jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' SET timezone='Africa/Cairo' AS $$
DECLARE year_value integer:=(input->>'year')::integer; m integer; r jsonb; p jsonb; revenue numeric; cost numeric; expenses numeric; result jsonb:='[]';
BEGIN
 IF year_value IS NULL OR year_value NOT BETWEEN 2000 AND 2100 THEN RAISE EXCEPTION 'INVALID_REPORT_YEAR'; END IF;
 FOR m IN 1..12 LOOP
  r:=public.accounting_profit_v1(input||jsonb_build_object('purpose','monthly','start',make_date(year_value,m,1),'end',make_date(year_value,m,1)+interval '1 month'));
  p:=r->'pnl'; revenue:=-coalesce((p->>'sales')::numeric,0)-coalesce((p->>'discounts')::numeric,0)-coalesce((p->>'returns')::numeric,0);
  cost:=coalesce((p->>'cogs')::numeric,0);
  expenses:=coalesce((p->>'operating_expenses')::numeric,0)+coalesce((p->>'administrative_expenses')::numeric,0)+coalesce((p->>'other_expenses')::numeric,0)+coalesce((p->>'income_tax')::numeric,0)+coalesce((p->>'other_income')::numeric,0);
  result:=result||jsonb_build_array(jsonb_build_object('month',make_date(year_value,m,1),'revenue',revenue,'cost',cost,'gross_profit',revenue-cost,'expenses',expenses,'net_profit',revenue-cost-expenses));
 END LOOP;
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION private.accounting_profit_visible_v1(uuid,text) FROM public,anon,authenticated;
REVOKE ALL ON FUNCTION public.accounting_profit_v1(jsonb),public.accounting_monthly_summary_v1(jsonb) FROM public,anon;
GRANT EXECUTE ON FUNCTION public.accounting_profit_v1(jsonb),public.accounting_monthly_summary_v1(jsonb) TO authenticated;

CREATE FUNCTION private.accounting_product_visible_v1(loc uuid,purpose text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT private.actor_is_active_v1() AND CASE WHEN private.access_v2_enabled(auth.uid())
 THEN private.access_v2_allows(auth.uid(),CASE WHEN purpose='analytics' THEN 'report_profit.read' ELSE 'product_profit_report.read' END,loc)
 ELSE private.has_permission(auth.uid(),'viewReports') AND ((loc IS NULL AND NOT private.branch_scope_restricted(auth.uid())) OR (loc IS NOT NULL AND private.has_location_access(auth.uid(),loc))) END;
$$;
CREATE FUNCTION public.accounting_product_profit_v1(input jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' SET timezone='Africa/Cairo' AS $$
DECLARE loc uuid:=nullif(input->>'location_id','')::uuid; purpose text:=coalesce(input->>'purpose','product');
 start_at timestamptz:=coalesce((input->>'start')::timestamptz,'1900-01-01'); end_at timestamptz:=coalesce((input->>'end')::timestamptz,now()+interval '1 day');
 shift uuid:=nullif(input->>'shift_id','')::uuid; result jsonb;
BEGIN
 IF start_at>=end_at THEN RAISE EXCEPTION 'INVALID_ACCOUNTING_PERIOD'; END IF;
 IF NOT coalesce(private.actor_is_active_v1(),false) OR (loc IS NOT NULL AND NOT private.accounting_product_visible_v1(loc,purpose)) OR
 (loc IS NULL AND NOT private.accounting_product_visible_v1(NULL,purpose) AND NOT EXISTS(SELECT 1 FROM public.locations WHERE private.accounting_product_visible_v1(id,purpose))) THEN
  RAISE EXCEPTION USING errcode='42501',message='PRODUCT_PROFIT_FORBIDDEN'; END IF;
 WITH invoice_lines AS (
 SELECT si.product_id,coalesce(si.product_id::text,si.product_barcode,si.id::text) product_key,si.product_name,p.origin_type,
 s.id sale_id,s.created_at::date sale_day,date_trunc('month',s.created_at)::date sale_month,
 CASE WHEN s.is_refund THEN -si.quantity ELSE si.quantity END quantity,
 CASE WHEN s.is_refund THEN -1 ELSE 1 END * coalesce(si.financial_net,
  (s.total-CASE WHEN s.tax_total=0 AND s.tax_mode='legacy' THEN coalesce(s.tax,0) ELSE s.tax_total END)*si.subtotal/nullif((SELECT sum(i2.subtotal) FROM public.sale_items i2 WHERE i2.sale_id=s.id),0)) revenue,
 CASE WHEN s.is_refund THEN -1 ELSE 1 END * si.quantity * CASE WHEN EXISTS(SELECT 1 FROM public.inventory_movements m WHERE m.sale_id=s.id) THEN si.unit_cost_snapshot ELSE si.wholesale_price END cost
 FROM public.sale_items si JOIN public.sales s ON s.id=si.sale_id JOIN public.transactions t ON t.sale_id=s.id AND t.status='posted'
 LEFT JOIN public.products p ON p.id=si.product_id
 WHERE s.created_at>=start_at AND s.created_at<end_at AND (shift IS NULL OR s.shift_id=shift) AND (loc IS NULL OR s.location_id=loc) AND private.accounting_product_visible_v1(s.location_id,purpose)
 ), extra AS (
 SELECT m.product_id,m.sale_id,sum(l.amount) cost FROM private.landed_cost_movements_v1(end_at) l JOIN public.inventory_movements m ON m.id=l.source_id
 JOIN public.sales s ON s.id=m.sale_id WHERE l.account='cogs' AND l.occurred_at>=start_at AND (shift IS NULL OR s.shift_id=shift)
 AND (loc IS NULL OR l.location_id=loc) AND private.accounting_product_visible_v1(l.location_id,purpose) GROUP BY 1,2
 ), totals AS (
 SELECT product_key,max(product_name) product_name,max(origin_type) origin_type,sale_day,sale_month,sum(quantity) net_quantity,sum(revenue) revenue,sum(cost) cost
 FROM invoice_lines GROUP BY 1,4,5
 ), extra_daily AS (
 SELECT e.product_id::text product_key,s.created_at::date sale_day,sum(e.cost) cost FROM extra e JOIN public.sales s ON s.id=e.sale_id GROUP BY 1,2
 ) SELECT coalesce(jsonb_agg(jsonb_build_object('product_id',t.product_key,'product_name',t.product_name,'origin_type',t.origin_type,'sale_day',t.sale_day,'sale_month',t.sale_month,
 'net_quantity',t.net_quantity,'revenue',t.revenue,'cost',t.cost+coalesce(e.cost,0),'gross_profit',t.revenue-t.cost-coalesce(e.cost,0)) ORDER BY t.revenue DESC),'[]') INTO result
 FROM totals t LEFT JOIN extra_daily e USING(product_key,sale_day);
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION private.accounting_product_visible_v1(uuid,text) FROM public,anon,authenticated;
REVOKE ALL ON FUNCTION public.accounting_product_profit_v1(jsonb) FROM public,anon;
GRANT EXECUTE ON FUNCTION public.accounting_product_profit_v1(jsonb) TO authenticated;

INSERT INTO private.access_v2_rpc_registry(signature,function_oid,original_definition)
 SELECT p.oid::regprocedure::text,p.oid,pg_get_functiondef(p.oid) FROM pg_proc p
 WHERE p.pronamespace='public'::regnamespace AND p.proname IN ('accounting_report_v1','accounting_command_v1','accounting_profit_v1','accounting_monthly_summary_v1','accounting_cost_inputs_v1','update_expense_metadata_v1','accounting_product_profit_v1')
 ON CONFLICT(signature) DO UPDATE SET function_oid=excluded.function_oid,original_definition=excluded.original_definition;
SELECT private.access_v2_assert_coverage();
NOTIFY pgrst,'reload schema';
COMMIT;
