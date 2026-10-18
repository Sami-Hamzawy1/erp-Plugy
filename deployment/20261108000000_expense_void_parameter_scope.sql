-- Fix the parameter reference in the private copy of the expense reversal RPC.
-- The public authorization wrapper, grants, records and balances are unchanged.
BEGIN;
SET LOCAL search_path = '';

DO $$
DECLARE implementation regprocedure; definition text; patched text; wrapper text;
BEGIN
  implementation := to_regprocedure('private.access_v2_impl_void_expense(uuid)');
  IF implementation IS NULL OR to_regprocedure('public.void_expense(uuid)') IS NULL THEN
    RAISE EXCEPTION 'EXPENSE_VOID_REQUIRES_DYNAMIC_ACCESS_V2';
  END IF;
  wrapper := pg_get_functiondef('public.void_expense(uuid)'::regprocedure);
  IF position('private.access_v2_rpc_guard' IN wrapper) = 0
    OR position('private.access_v2_impl_void_expense' IN wrapper) = 0 THEN
    RAISE EXCEPTION 'EXPENSE_VOID_INCOMPATIBLE_WRAPPER: review the installed authorization wrapper';
  END IF;

  definition := pg_get_functiondef(implementation);
  -- The implementation was copied from public.void_expense. Its old implicit
  -- function label is no longer in scope after that copy was renamed.
  patched := regexp_replace(definition,
    '\mvoid_expense\M[[:space:]]*\.[[:space:]]*\mexpense_id\M', '$1', 'g');
  IF patched IS DISTINCT FROM definition THEN
    EXECUTE patched;
  END IF;
END $$;

NOTIFY pgrst, 'reload schema';
COMMIT;
