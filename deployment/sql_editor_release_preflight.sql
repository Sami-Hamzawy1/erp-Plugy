-- Plugy SQL Editor: target project orbovqzenjlyshhiuofx.
-- READ ONLY. No migrations are applied by this file.
-- Presence is a footprint, not proof of a complete/compatible installation.
-- Missing foundations require review before using the release migration packet.
begin read only;

select current_database() database_name,current_user sql_role,
 'Confirm the dashboard project is orbovqzenjlyshhiuofx (Plugy)' target_check;

-- SQL Editor changes may be absent from CLI migration history.
do $$ declare entry record; registered bigint; begin
 if to_regclass('supabase_migrations.schema_migrations') is not null then
  for entry in execute 'select version from supabase_migrations.schema_migrations order by version' loop
   raise notice 'Recorded migration version: %',entry.version;
  end loop;
 else raise notice 'No CLI migration history table; inspect actual schema footprints below.'; end if;
 if to_regclass('private.access_v2_rpc_registry') is not null then
  execute $q$select count(*) from private.access_v2_rpc_registry where signature in
   ('installation_services_v3(jsonb)','installation_quotes_v3(jsonb)','remove_treasury_account_v3(jsonb)',
    'list_payment_methods_v3(uuid,boolean)','list_salary_records_v3(jsonb)')$q$ into registered;
  raise notice 'Step 08 checkout registration: % of 5 signatures found (review matching function OIDs too).',registered;
 end if;
end $$;

with probes(step,file,kind,object_name,detail) as (values
 (0,'FOUNDATIONS (before 20261029)','table','public.profiles',''),
 (0,'FOUNDATIONS (before 20261029)','table','public.transactions',''),
 (0,'FOUNDATIONS (before 20261029)','table','public.transaction_settlements',''),
 (0,'FOUNDATIONS (before 20261029)','table','private.access_v2_rpc_registry',''),
 (0,'FOUNDATIONS (before 20261029)','function','private.branch_scope_location(uuid,uuid,boolean)',''),
 (0,'FOUNDATIONS (before 20261029)','function','private.record_expense_documents_v1(jsonb)',''),
 (0,'FOUNDATIONS (before 20261029)','function','private.complete_sale_documents_v1(jsonb,jsonb)',''),
 (1,'20261029000000_checkout_installations_v3.sql','column','public.sales','tax_mode'),
 (1,'20261029000000_checkout_installations_v3.sql','column','public.sale_items','financial_net'),
 (1,'20261029000000_checkout_installations_v3.sql','function','public.remove_treasury_account_v3(jsonb)',''),
 (1,'20261029000000_checkout_installations_v3.sql','function','public.installation_quotes_v3(jsonb)',''),
 (2,'20261029000000_treasury_bank_scope_fix.sql','body','private.branch_scope_row(text,jsonb,boolean)','relation_name=''treasury_accounts'' and location is null'),
 (2,'20261029000000_treasury_bank_scope_fix.sql','body','private.access_v2_allows(uuid,text,uuid,uuid[])','treasury_account.%'),
 (3,'20261030000000_transaction_details_cost_redaction.sql','function','private.transaction_details_redacted_v4(uuid)',''),
 (4,'20261031000000_customer_rpc_permission_scope.sql','body','private.branch_scope_base_access_v2_rpc_guard(text,jsonb)','''search_customers_v1'',''create_customer_v1'''),
 (5,'20261101000000_settlement_account_selection_without_balance.sql','function','private.settlement_accounts_for_actor_v5(uuid)',''),
 (5,'20261101000000_settlement_account_selection_without_balance.sql','function','private.settlement_account_location_v5(jsonb,uuid,text)',''),
 (6,'20261102000000_branch_payment_method_catalog.sql','function','public.list_payment_methods_v3(uuid,boolean)',''),
 (7,'20261103000000_branch_salary_record_reads.sql','function','private.list_salary_records_authorized_v3(jsonb)',''),
 (8,'20261104000000_checkout_v3_access_registration.sql','policy','installation_services','access_v2_guard_select'),
 (9,'20261105000000_installation_receipt_text.sql','column','public.installations','receipt_text'),
 (9,'20261105000000_installation_receipt_text.sql','function','private.installation_receipt_previous_v1(jsonb,jsonb)',''),
 (10,'20261106000000_integrated_accounting.sql','table','private.accounting_journals',''),
 (10,'20261106000000_integrated_accounting.sql','table','private.accounting_assets',''),
 (10,'20261106000000_integrated_accounting.sql','function','public.accounting_report_v1(jsonb)',''),
 (10,'20261106000000_integrated_accounting.sql','function','public.accounting_command_v1(jsonb)',''),
 (11,'20261107000000_create_location.sql','function','public.create_location_v1(jsonb)',''),
 (12,'20261108000000_expense_void_parameter_scope.sql','void_fix','private.access_v2_impl_void_expense(uuid)',''),
 (13,'20261109000000_refund_correctness.sql','column','public.sale_items','original_sale_item_id'),
 (13,'20261109000000_refund_correctness.sql','function','private.refund_line_net_v1(uuid)',''),
 (14,'20261110000000_checkout_payment_fees.sql','table','private.checkout_payment_fees',''),
 (14,'20261110000000_checkout_payment_fees.sql','function','public.complete_sale_with_fees_v1(jsonb,jsonb,jsonb)',''),
 (15,'20261111000000_balance_sheet_classification.sql','table','private.accounting_asset_classes',''),
 (15,'20261111000000_balance_sheet_classification.sql','function','private.accounting_report_core_v1(jsonb)',''),
 (15,'20261111000000_balance_sheet_classification.sql','function','public.accounting_ledger_v1(jsonb)',''),
 (16,'20261112000000_separate_installation_financials.sql','function','public.installation_financials_v1(jsonb)',''),
 (16,'20261112000000_separate_installation_financials.sql','function','public.invoice_installation_links_v1(jsonb)',''),
 (16,'20261112000000_separate_installation_financials.sql','function','private.accounting_report_classified_v2(jsonb)',''),
 (17,'20261112000000_global_installation_inventory.sql','table','public.installation_inventory',''),
 (17,'20261112000000_global_installation_inventory.sql','function','public.installation_inventory_v1(jsonb)',''),
 (17,'20261112000000_global_installation_inventory.sql','column','public.sale_items','installation_inventory_id'),
 (18,'20261113000000_detailed_sale_audit.sql','function','public.read_audit_events_v1(jsonb)',''),
 (18,'20261113000000_detailed_sale_audit.sql','function','private.record_sale_audit_v1()',''),
 (18,'20261113000000_detailed_sale_audit.sql','table','private.audit_sale_contacts_v1','')
), checked as (
 select *,case kind
  when 'table' then to_regclass(object_name) is not null
  when 'function' then to_regprocedure(object_name) is not null
  when 'column' then exists(select 1 from pg_attribute where attrelid=to_regclass(object_name) and attname=detail and not attisdropped)
  when 'policy' then exists(select 1 from pg_policies where schemaname='public' and tablename=object_name and policyname=detail)
  when 'body' then position(detail in coalesce(pg_get_functiondef(to_regprocedure(object_name)),''))>0
  when 'void_fix' then to_regprocedure(object_name) is not null and
   pg_get_functiondef(to_regprocedure(object_name)) !~ '\mvoid_expense\M[[:space:]]*\.[[:space:]]*\mexpense_id\M'
  else false end available from probes
)
select step,file,
 case when step=0 and not bool_and(available) then 'STOP: missing foundation(s); review before release migrations'
  when step=0 then 'Foundation footprints present; compatibility still needs review'
  when bool_and(available) then 'Footprints present: review/confirm installed; do not blindly replay'
  when bool_or(available) then 'PARTIAL footprint: review before running'
  else 'Footprints missing: candidate migration, subject to prerequisites' end result,
 string_agg(object_name||case when kind='column' then '.'||detail else '' end,', ' order by object_name) filter(where not available) missing_checks
from checked group by step,file order by step;
commit;
