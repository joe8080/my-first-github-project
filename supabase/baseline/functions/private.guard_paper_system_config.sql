CREATE OR REPLACE FUNCTION private.guard_paper_system_config()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  if current_user in ('postgres', 'supabase_admin') then
    return new;
  end if;
  if coalesce(new.new_orders_enabled, false) and not coalesce(old.new_orders_enabled, false) then
    raise exception 'Only the database owner can release the kill switch (private.paper_kill_switch_release)';
  end if;
  if (new.permitted_strategy_tags, new.permitted_asset_classes, new.max_quote_age_seconds, new.diagnostic_max_notional_usd,
      new.min_reward_risk, new.market_data_feed, new.max_risk_per_trade_pct, new.exceptional_risk_per_trade_pct,
      new.max_single_position_pct, new.max_speculative_position_pct, new.max_concurrent_positions, new.max_gross_exposure_pct,
      new.max_short_gross_exposure_pct, new.daily_loss_circuit_breaker_pct, new.max_drawdown_limit_pct, new.baseline_at)
     is distinct from
     (old.permitted_strategy_tags, old.permitted_asset_classes, old.max_quote_age_seconds, old.diagnostic_max_notional_usd,
      old.min_reward_risk, old.market_data_feed, old.max_risk_per_trade_pct, old.exceptional_risk_per_trade_pct,
      old.max_single_position_pct, old.max_speculative_position_pct, old.max_concurrent_positions, old.max_gross_exposure_pct,
      old.max_short_gross_exposure_pct, old.daily_loss_circuit_breaker_pct, old.max_drawdown_limit_pct, old.baseline_at) then
    raise exception 'Risk limits and mandate decisions can only be changed by the database owner';
  end if;
  return new;
end;
$function$
