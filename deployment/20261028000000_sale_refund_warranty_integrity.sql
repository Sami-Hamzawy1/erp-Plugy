begin;

-- Keep the deployed inventory, settlement, authorization and installation
-- behavior. Change only refund valuation inside the private document writer.
do $$
declare definition text; old_expression text := 'original_item.sale_price - original_item.item_discount';
 new_expression text := '(original_item.subtotal / nullif(original_item.quantity, 0) * original_sale.total / nullif((select sum(si.subtotal) from public.sale_items si where si.sale_id = original_sale_id_value), 0))';
begin
 select pg_get_functiondef('private.complete_refund_documents_v1(jsonb,jsonb)'::regprocedure) into definition;
 if position(new_expression in definition) = 0 then
  if position(old_expression in definition) = 0 then
   raise exception 'REFUND_IMPLEMENTATION_INCOMPATIBLE: review deployed refund valuation before applying';
  end if;
  execute replace(definition, old_expression, new_expression);
 end if;
end $$;

commit;
