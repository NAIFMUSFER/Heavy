do $$
declare r record;
begin
 for r in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in (
  'jana_public_catalog','jana_public_slots','jana_register','jana_login','jana_logout','jana_change_password','jana_me',
  'jana_list_addresses','jana_add_address','jana_update_address','jana_delete_address','jana_my_favorites','jana_toggle_favorite',
  'jana_create_quote','jana_confirm_order','jana_my_orders','jana_order_detail','jana_cancel_order','jana_review_order','jana_rotate_delivery_code','jana_customer_tracking','jana_my_substitutions','jana_decide_substitution',
  'jana_customer_notifications','jana_mark_notification_read','jana_my_tickets','jana_create_ticket',
  'jana_ops_orders','jana_picker_record_actual','jana_propose_substitution','jana_courier_update_location','jana_finalize_picking','jana_ops_transition',
  'jana_admin_dashboard','jana_admin_orders','jana_admin_reports','jana_create_staff','jana_support_tickets','jana_support_reply','jana_finance_settle','jana_admin_refund',
  'jana_expire_quotes','jana_expire_substitutions'
 ) loop
  execute format('grant execute on function %s to anon',r.sig);
 end loop;
end$$;