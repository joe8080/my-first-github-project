import { terminal } from "./terminal.ts";
import { createClient } from "@supabase/supabase-js";

const EXPECTED_TOKEN_HASH = "<REDACTED_SHA256_OF_DASHBOARD_TOKEN>";
const encoder = new TextEncoder();

function toHex(buffer: ArrayBuffer): string {
  return Array.from(new Uint8Array(buffer), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let mismatch = 0;
  for (let i = 0; i < a.length; i += 1) mismatch |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return mismatch === 0;
}

async function authorised(req: Request): Promise<boolean> {
  const supplied = req.headers.get("x-dashboard-token") ?? "";
  const hash = toHex(await crypto.subtle.digest("SHA-256", encoder.encode(supplied)));
  return constantTimeEqual(hash, EXPECTED_TOKEN_HASH) || (req.method === "GET" && new URL(req.url).searchParams.has("terminal") && constantTimeEqual(hash, "<REDACTED_SHA256_OF_DASHBOARD_TOKEN>"));
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "private, max-age=30",
      "x-content-type-options": "nosniff",
    },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method !== "GET" && req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  if (!(await authorised(req))) return json({ error: "unauthorised" }, 401);

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const secretKeys = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}");
  const adminKey = secretKeys.default ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  if (!supabaseUrl || !adminKey) return json({ error: "server_configuration_error" }, 500);

  const db = createClient(supabaseUrl, adminKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  if (req.method === "GET" && new URL(req.url).searchParams.has("terminal")) return terminal(req, db);

  const run = async <T>(label: string, promise: PromiseLike<{ data: T | null; error: { message: string } | null }>) => {
    const { data, error } = await promise;
    if (error) throw new Error(label + ": " + error.message);
    return data ?? [];
  };

  if (req.method === "POST") {
    try {
      const body = await req.json(); const owner = String(body.owner || "").toLowerCase();
      if (!owner) return json({ error: "owner_required" }, 400);
      if (body.action === "context") {
        let conversationId = body.conversation_id;
        if (!conversationId) { const { data, error } = await db.from("mj_conversations").insert({ owner_key: owner, title: String(body.message || "New conversation").slice(0, 80) }).select("id").single(); if (error) throw error; conversationId = data.id; }
        const [messages, policy] = await Promise.all([run("messages", db.from("mj_messages").select("role,content,page_context,created_at").eq("owner_key", owner).eq("conversation_id", conversationId).order("created_at").limit(20)),run("policy", db.from("mj_policy_versions").select("version,constitution").eq("active", true).limit(1))]);
        return json({ conversation_id: conversationId, messages, policy: policy[0] ?? null });
      }
      if (body.action === "save") {
        const { error } = await db.from("mj_messages").insert([{ owner_key: owner, conversation_id: body.conversation_id, role: "user", content: body.user_message, page_context: body.page_context || {} },{ owner_key: owner, conversation_id: body.conversation_id, role: "assistant", content: body.assistant_message, response_id: body.response_id || null, page_context: body.page_context || {} }]);
        if (error) throw error; await db.from("mj_conversations").update({ updated_at: new Date().toISOString() }).eq("id", body.conversation_id).eq("owner_key", owner); return json({ saved: true });
      }
      if (body.action === "retrieve") {
        const { data, error } = await db.rpc("match_mj_memories", { p_owner_key: owner, p_query_embedding: body.embedding, p_match_count: Math.min(Number(body.limit || 8), 20), p_ticker: body.ticker || null });
        if (error) throw error; return json({ memories: data || [] });
      }
      if (body.action === "save_learning") {
        const memoryRow = { owner_key: owner, conversation_id: body.conversation_id || null, memory_type: body.memory_type || "conversation_insight", ticker: body.ticker || null, title: body.title || null, content: body.content, embedding: body.embedding, importance: Math.max(1,Math.min(Number(body.importance || 5),10)), source_date: new Date().toISOString().slice(0,10), metadata: body.metadata || {} };
        const { error: memoryError } = await db.from("mj_semantic_memories").insert(memoryRow); if (memoryError) throw memoryError;
        let recommendationId = null;
        if (body.recommendation?.is_actionable) {
          const rec = body.recommendation;
          const { data, error } = await db.from("mj_recommendations").insert({ owner_key: owner, conversation_id: body.conversation_id || null, response_id: body.response_id || null, ticker: rec.ticker || null, action: rec.action || "REVIEW", confidence: rec.confidence ?? null, recommendation: rec.recommendation || body.content, rationale: rec.rationale || null, success_criteria: rec.success_criteria || [], warning_signs: rec.warning_signs || [], thesis_health_at_decision: rec.thesis_health || null, price_at_decision: rec.price_at_decision ?? null, portfolio_snapshot: body.portfolio_snapshot || {}, risk_snapshot: body.risk_snapshot || {}, policy_version: body.policy_version || "MJ-INVESTMENT-OS-3.1" }).select("id").single();
          if (error) throw error; recommendationId = data.id;
        }
        return json({ saved: true, recommendation_id: recommendationId });
      }
      return json({ error: "unknown_action" }, 400);
    } catch (error) { return json({ error: error instanceof Error ? error.message : "memory_error" }, 500); }
  }

  try {
    const [portfolio,riskState,history,scores,alerts,forecasts,postmortems,counterfactuals,positionRiskRows,theses,watchlist,buckets,contextProfiles,livingTheses] = await Promise.all([
      run("portfolio", db.from("v_live_portfolio").select("ticker,account,bucket,shares,current_value_gbp,pnl_gbp,pnl_pct,snapshot_time").order("current_value_gbp", { ascending: false, nullsFirst: false }).limit(150)),
      run("risk_state", db.from("v_current_portfolio_risk_state").select("as_of,session_date,regime,risk_pressure_score,deployment_bias,max_new_cash_pct,macro_score,market_score,credit_score,portfolio_score,news_score,signal_summary,material_events,recommended_actions,source_summary").order("as_of", { ascending: false }).limit(1)),
      run("history", db.from("v_summary_history").select("snapshot_date,total_value_gbp,isa_value_gbp,gia_value_gbp,total_pnl_gbp,holding_count,north_star_target_gbp,progress_pct").order("snapshot_date", { ascending: true }).limit(180)),
      run("scores", db.from("v_scorecard_coverage").select("ticker,scored_date,total_score,score_grade,components_scored,components_total,coverage_pct,evidence_gaps").order("total_score", { ascending: false, nullsFirst: false }).limit(150)),
      run("alerts", db.from("v_open_alerts").select("created_at,severity,alert_type,ticker,headline,detail,action_required").order("created_at", { ascending: false }).limit(40)),
      run("forecasts", db.from("v_forecasts_needing_actuals").select("ticker,fiscal_period,event_date,status,contamination_flag,days_since_event").order("event_date", { ascending: true }).limit(80)),
      run("postmortems", db.from("v_postmortems_due").select("trade_date,ticker,direction,account,total_value_gbp,funded_by_sale_of,rejected_alternative,horizon_due,days_held").order("trade_date", { ascending: false }).limit(80)),
      run("counterfactuals", db.from("v_counterfactual_verdicts").select("trade_date,ticker,direction,funded_by_sale_of,pnl_30d_pct,counterfactual_return_30d_pct,edge_30d_pct,pnl_90d_pct,counterfactual_return_90d_pct,edge_90d_pct,fees_gbp,verdict_30d").order("trade_date", { ascending: false }).limit(150)),
      run("position_risk", db.from("position_risk_log").select("ticker,log_date,account,position_value_gbp,cost_basis_gbp,unrealised_pnl_pct,portfolio_weight_pct,correlation_to_portfolio,risk_tier,concentration_flag,sizing_rationale").order("log_date", { ascending: false }).limit(250)),
      run("theses", db.from("ticker_thesis").select("ticker,doubling_probability_3yr,conviction_tier,current_status,last_verified,next_verification_due,decay_status,quality_score,speculation_score,research_status,sell_price_target_2029_usd,target_weight_2029_pct,trade_trend,intermediate_trend,trend_200d").order("updated_at", { ascending: false }).limit(200)),
      run("watchlist", db.from("watchlist").select("ticker,company_name,sector,bucket,target_entry_gbp,target_entry_usd,priority,status,added_date,updated_at").order("updated_at", { ascending: false }).limit(150)),
      run("buckets", db.from("portfolio_buckets").select("snapshot_date,bucket_name,value_gbp,allocation_pct,holding_count").order("snapshot_date", { ascending: false }).limit(150)),
      run("context_profiles", db.from("mj_context_profiles").select("*").limit(1)),
      run("living_theses", db.from("v_mj_current_theses").select("ticker,version,position_role,why_owned,bull_case,base_case,bear_case,expected_upside_pct,time_horizon_months,max_weight_pct,catalysts,thesis_breakers,key_metrics,confidence,thesis_health,last_verified").order("ticker").limit(200)),
    ]);

    const latestRisk = new Map<string, unknown>();
    for (const row of positionRiskRows as Array<Record<string, unknown>>) {
      const key = String(row.ticker ?? "") + "|" + String(row.account ?? "");
      if (!latestRisk.has(key)) latestRisk.set(key, row);
    }
    const portfolioRows = portfolio as Array<Record<string, unknown>>;
    const totalValueGbp = portfolioRows.reduce((sum, row) => sum + Number(row.current_value_gbp ?? 0), 0);
    const totalPnlGbp = portfolioRows.reduce((sum, row) => sum + Number(row.pnl_gbp ?? 0), 0);
    const enrichedPositions = portfolioRows.map((row) => ({ ...row, weight_pct: totalValueGbp ? Number(row.current_value_gbp ?? 0) / totalValueGbp * 100 : 0 })).sort((a,b) => Number(b.weight_pct)-Number(a.weight_pct));
    const accountExposure: Record<string,number> = {}; const bucketExposure: Record<string,number> = {};
    for (const row of enrichedPositions) { const value=Number(row.current_value_gbp??0); const account=String(row.account??"Unknown"); const bucket=String(row.bucket??"Unclassified"); accountExposure[account]=(accountExposure[account]||0)+value; bucketExposure[bucket]=(bucketExposure[bucket]||0)+value; }
    const hhi = enrichedPositions.reduce((sum,row)=>sum+Math.pow(Number(row.weight_pct),2),0);
    const thesisTickers = new Set((livingTheses as Array<Record<string,unknown>>).map(row=>String(row.ticker)));
    const contextProfile = (contextProfiles as unknown[])[0] ?? null;
    const tools = {
      portfolio_totals: { total_value_gbp: totalValueGbp, recorded_pnl_gbp: totalPnlGbp, holding_count: enrichedPositions.length },
      concentration: { top_position: enrichedPositions[0] ?? null, top_5_weight_pct: enrichedPositions.slice(0,5).reduce((s,r)=>s+Number(r.weight_pct),0), hhi, positions_over_10_pct: enrichedPositions.filter(r=>Number(r.weight_pct)>10).map(r=>r.ticker) },
      account_exposure_gbp: accountExposure,
      bucket_exposure_gbp: bucketExposure,
      thesis_coverage: { covered: enrichedPositions.filter(r=>thesisTickers.has(String(r.ticker))).length, total: enrichedPositions.length, missing: enrichedPositions.filter(r=>!thesisTickers.has(String(r.ticker))).map(r=>r.ticker) }
    };

    return json({
      generated_at: new Date().toISOString(),
      freshness: { portfolio_snapshot: (portfolio as Array<Record<string, unknown>>).map((row) => String(row.snapshot_date ?? "")).sort().at(-1) ?? null, risk_as_of: (riskState as Array<Record<string, unknown>>)[0]?.as_of ?? null },
      portfolio,
      risk_state: (riskState as unknown[])[0] ?? null,
      history,
      scores,
      alerts,
      forecasts_needing_actuals: forecasts,
      postmortems_due: postmortems,
      counterfactuals,
      position_risk: Array.from(latestRisk.values()),
      theses,
      watchlist,
      buckets,
      context_pack: contextProfile,
      living_theses: livingTheses,
      tools,
      sources: ["v_current_portfolio","v_current_portfolio_risk_state","v_summary_history","v_scorecard_coverage","v_open_alerts","v_forecasts_needing_actuals","v_postmortems_due","v_counterfactual_verdicts","position_risk_log","ticker_thesis","watchlist","portfolio_buckets","mj_context_profiles","v_mj_current_theses"],
    });
  } catch (error) {
    console.error(error);
    return json({ error: "dashboard_query_failed" }, 500);
  }
});