begin;

alter table public.installation_inventory add column if not exists image_url text
  check (image_url is null or (length(image_url) <= 2048 and image_url ~* '^https?://[^[:space:]]+$'));
alter table public.installation_inventory drop constraint if exists installation_inventory_kind_check;
alter table public.installation_inventory add constraint installation_inventory_kind_check
  check (kind in ('charger', 'variableMaterial', 'fixedMaterial', 'optionalProtection'));

-- Extend the installed inventory writer, including deployments that already
-- have the original shared pool.
do $migration$
declare definition text;
begin
  definition := pg_get_functiondef('public.installation_inventory_v1(jsonb)'::regprocedure);
  if position('image_url=excluded.image_url' in definition) = 0 then
    if position('quantity,unit_cost,is_active)' in definition) = 0
        or position('coalesce((input->>''is_active'')::boolean,true))' in definition) = 0 then
      raise exception 'INSTALLATION_INVENTORY_WRITER_REQUIRED';
    end if;
    definition := replace(definition, 'quantity,unit_cost,is_active)', 'quantity,unit_cost,is_active,image_url)');
    definition := replace(definition, 'coalesce((input->>''is_active'')::boolean,true))',
        'coalesce((input->>''is_active'')::boolean,true),nullif(btrim(input->>''image_url''),''''))');
    definition := replace(definition, 'is_active=excluded.is_active,updated_at=now()',
        'is_active=excluded.is_active,image_url=case when input ? ''image_url'' then excluded.image_url else installation_inventory.image_url end,updated_at=now()');
    execute definition;
  end if;
end;
$migration$;

create table private.installation_stock_receipts (
  id uuid primary key default gen_random_uuid(),
  inventory_id uuid not null references public.installation_inventory(id),
  location_id uuid not null references public.locations(id),
  settlement_id uuid not null unique references public.transaction_settlements(id),
  quantity numeric(14,3) not null check (quantity > 0),
  unit_cost numeric(14,4) not null check (unit_cost > 0),
  total numeric(14,2) not null check (total > 0),
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now()
);
revoke all on private.installation_stock_receipts from public, anon, authenticated;

create function public.post_installation_stock_receipt_v1(input jsonb)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  actor uuid := auth.uid();
  location uuid := nullif(input->>'location_id', '')::uuid;
  bank uuid := nullif(input->>'account_id', '')::uuid;
  added_quantity numeric(14,3) := (input->>'quantity')::numeric;
  purchase_cost numeric(14,4) := (input->>'unit_cost')::numeric;
  bank_reference text := nullif(btrim(input->>'reference'), '');
  method_code text := input->>'payment_method';
  command_key text := 'installation-stock-receipt:' || (input->>'idempotency_key');
  item public.installation_inventory%rowtype;
  receipt uuid;
  settlement uuid;
  total numeric(14,2);
  new_cost numeric(14,4);
begin
  if not private.installation_inventory_allows_v1('manage')
      or location is null
      or not coalesce(private.branch_scope_location(actor, location, true), false)
      or not coalesce(private.has_location_access(actor, location), false) then
    raise exception using errcode = '42501', message = 'INSTALLATION_STOCK_RECEIPT_FORBIDDEN';
  end if;
  if private.access_v2_enabled(actor) then
    perform private.access_v2_require('stock_receipt.create', location);
    perform private.access_v2_require('transaction_settlement.create', location);
  else
    perform private.require_finance_v1();
  end if;

  if not exists (select 1 from public.locations where id = location and is_active)
      or not exists (select 1 from jsonb_array_elements(public.list_settlement_accounts_v1(location)) account
          where account->>'id' = bank::text and account->>'account_type' = 'bank') then
    raise exception using errcode = '42501', message = 'INSTALLATION_STOCK_BANK_REQUIRED';
  end if;
  if bank_reference is null or not exists (select 1 from public.payment_methods
      where code = method_code and method_type = 'bank' and is_active) then
    raise exception using errcode = '22023', message = 'INSTALLATION_BANK_PAYMENT_REQUIRED';
  end if;
  if added_quantity is null or added_quantity <= 0 or added_quantity >= 'Infinity'::numeric
      or added_quantity <> (input->>'quantity')::numeric
      or purchase_cost is null or purchase_cost <= 0 or purchase_cost >= 'Infinity'::numeric
      or purchase_cost <> (input->>'unit_cost')::numeric then
    raise exception using errcode = '22023', message = 'INVALID_INSTALLATION_RECEIPT_QUANTITY_OR_COST';
  end if;

  receipt := private.finance_command_v1(command_key, input);
  if receipt is not null then return receipt; end if;
  select * into item from public.installation_inventory
    where id = (input->>'inventory_id')::uuid and is_active for update;
  if not found then raise exception 'INSTALLATION_INVENTORY_UNAVAILABLE'; end if;

  total := round(added_quantity * purchase_cost, 2);
  if total <= 0 then raise exception 'INVALID_INSTALLATION_RECEIPT_QUANTITY_OR_COST'; end if;
  new_cost := round((item.quantity * item.unit_cost + total) / (item.quantity + added_quantity), 4);
  receipt := gen_random_uuid();
  settlement := private.post_settlement_v1(jsonb_build_object(
      'account_id', bank, 'location_id', location, 'payment_method', method_code,
      'direction', 'outgoing', 'amount', total, 'reference', bank_reference,
      'description', 'Installation material receipt · ' || item.sku,
      'transfer', true, 'idempotency_key', command_key));

  insert into private.installation_stock_receipts
    (id, inventory_id, location_id, settlement_id, quantity, unit_cost, total, created_by)
    values (receipt, item.id, location, settlement, added_quantity, purchase_cost, total, actor);
  update public.installation_inventory set quantity = item.quantity + added_quantity,
    unit_cost = new_cost, updated_at = now() where id = item.id;
  insert into public.installation_inventory_movements
    (inventory_id, quantity_delta, value_delta, unit_cost_snapshot, reason, actor_id)
    values (item.id, added_quantity, total, purchase_cost, 'Bank receipt ' || receipt::text, actor);
  insert into public.audit_events(actor_id, action, entity_type, entity_id, location_id, after_data)
    values (actor, 'installation_stock_receipt_posted', 'installation_inventory', item.id,
        location, jsonb_build_object('receipt_id', receipt, 'bank_settlement_id', settlement,
            'quantity', added_quantity, 'unit_cost', purchase_cost, 'total', total));
  insert into private.finance_commands_v1 values (command_key, input, receipt);
  return receipt;
end;
$function$;

revoke all on function public.post_installation_stock_receipt_v1(jsonb) from public, anon;
grant execute on function public.post_installation_stock_receipt_v1(jsonb) to authenticated;
insert into private.access_v2_rpc_registry(signature, function_oid, original_definition)
values ('post_installation_stock_receipt_v1(jsonb)',
    'public.post_installation_stock_receipt_v1(jsonb)'::regprocedure,
    pg_get_functiondef('public.post_installation_stock_receipt_v1(jsonb)'::regprocedure))
on conflict(signature) do update set function_oid=excluded.function_oid, original_definition=excluded.original_definition;

-- A generic bank reversal cannot undo the stock side of a posted receipt.
create function private.protect_installation_bank_receipt()
returns trigger language plpgsql security definer set search_path = '' as $function$
begin
  if exists (select 1 from private.installation_stock_receipts where settlement_id = new.reversed_settlement_id) then
    raise exception using errcode = '22023', message = 'INSTALLATION_RECEIPT_STOCK_RECONCILIATION_REQUIRED';
  end if;
  return new;
end;
$function$;
revoke all on function private.protect_installation_bank_receipt() from public, anon, authenticated;
create trigger protect_installation_bank_receipt before insert on public.transaction_settlements
  for each row when (new.reversed_settlement_id is not null)
  execute function private.protect_installation_bank_receipt();

notify pgrst, 'reload schema';
commit;
