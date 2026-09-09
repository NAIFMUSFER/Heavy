create or replace function public.jana_public_catalog()
returns jsonb language sql security definer set search_path=public as $$
with b as (
  select stock_id, greatest(on_hand_base-reserved_base,0)::bigint available_base from public.stock_balances
), o as (
  select x.*, coalesce((
    select min(floor(coalesce(b.available_base,0)::numeric/greatest((c->>'base_qty')::numeric,1)))
    from json_array_elements(x.components) c left join b on b.stock_id=c->>'stock_id'
  ),0)::bigint available_units
  from public.offerings x where x.active
)
select coalesce(jsonb_agg(jsonb_build_object('id',id,'family_id',family_id,'version',version,'kind',kind,'name',name,'description',description,'category',category,'size_label',size_label,'emoji',emoji,'image_url',image_url,'sale_unit',sale_unit,'price_halalas',price_halalas,'components',components,'available_units',available_units) order by created_at),'[]'::jsonb) from o$$;
revoke all on function public.jana_public_catalog() from public,authenticated;
grant execute on function public.jana_public_catalog() to anon,service_role;