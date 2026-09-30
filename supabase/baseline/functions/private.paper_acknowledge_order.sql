CREATE OR REPLACE FUNCTION private.paper_acknowledge_order(p_alpaca_order_id text, p_note text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r public.paper_orders;
begin
  if coalesce(trim(p_note), '') = '' then raise exception 'A review note is required'; end if;
  update public.paper_orders set review_note = left(p_note, 1000), reviewed_at = now()
   where alpaca_order_id = p_alpaca_order_id returning * into r;
  if r.alpaca_order_id is null then raise exception 'Order not found in ledger'; end if;
  return jsonb_build_object('alpaca_order_id', r.alpaca_order_id, 'origin', r.origin, 'reviewed_at', r.reviewed_at);
end;
$function$
