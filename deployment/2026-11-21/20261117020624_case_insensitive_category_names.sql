begin;

lock table public.categories, public.product_subcategory_groups,
    public.product_subcategory_values in share row exclusive mode;

-- Reserve normalized names without deleting or renaming legacy duplicates.
-- Each key stores how many existing rows use it, so deleting one of several
-- old variants does not let a new duplicate slip in.
create table private.category_name_keys (
  namespace text not null,
  name_key text not null,
  uses int not null check (uses >= 0),
  primary key (namespace, name_key)
);

revoke all on private.category_name_keys from public, anon, authenticated;

insert into private.category_name_keys(namespace, name_key, uses)
select namespace, name_key, count(*)
from (
  select 'categories' namespace, lower(btrim(name)) name_key from public.categories
  union all
  select 'product_subcategory_groups', lower(btrim(name)) from public.product_subcategory_groups
  union all
  select 'product_subcategory_values:' || group_id, lower(btrim(value)) from public.product_subcategory_values
) names
group by namespace, name_key;

create function private.guard_category_name_key()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  old_row jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) end;
  new_row jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) end;
  old_key text := lower(btrim(coalesce(old_row->>'name', old_row->>'value')));
  new_key text := lower(btrim(coalesce(new_row->>'name', new_row->>'value')));
  old_namespace text := tg_table_name || coalesce(':' || (old_row->>'group_id'), '');
  new_namespace text := tg_table_name || coalesce(':' || (new_row->>'group_id'), '');
  remaining_uses int;
begin
  if tg_op = 'UPDATE' and (old_namespace, old_key) = (new_namespace, new_key) then
    return null;
  end if;

  if tg_op <> 'DELETE' then
    -- The primary key resolves concurrent writes to the same normalized name.
    insert into private.category_name_keys(namespace, name_key, uses)
    values (new_namespace, new_key, 1)
    on conflict do nothing;
    if not found then
      raise exception using errcode = '23505', message = 'CATEGORY_NAME_ALREADY_EXISTS';
    end if;
  end if;

  if tg_op <> 'INSERT' then
    update private.category_name_keys
       set uses = uses - 1
     where namespace = old_namespace and name_key = old_key
     returning uses into remaining_uses;
    if remaining_uses = 0 then
      delete from private.category_name_keys
       where namespace = old_namespace and name_key = old_key;
    end if;
  end if;
  return null;
end;
$function$;

revoke all on function private.guard_category_name_key() from public, anon, authenticated;

create trigger guard_category_names after insert or update or delete on public.categories
for each row execute function private.guard_category_name_key();

create trigger guard_subcategory_group_names after insert or update or delete on public.product_subcategory_groups
for each row execute function private.guard_category_name_key();

create trigger guard_subcategory_values after insert or update or delete on public.product_subcategory_values
for each row execute function private.guard_category_name_key();

commit;
