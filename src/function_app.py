# =============================================================================
# function_app.py
#
# WHAT THIS FILE DOES
# -------------------
# This is the Azure Functions "entry point". Azure Functions v2 Python model
# discovers functions by looking for decorators (@app.timer_trigger,
# @app.route) on a global `app` object in a file called function_app.py.
#
# We expose FOUR functions:
#
#   1. hourly_buy   (timer trigger)
#        Runs at second=0, minute=0 of every hour. Executes the whole
#        reservation cycle. This is the automation.
#
#   2. run_now      (HTTP POST /api/run, function-key protected)
#        Same thing as the timer, but on demand. Handy for testing without
#        waiting for the next hour.
#
#   3. get_state    (HTTP GET /api/state, anonymous)
#        Returns the raw state + recent attempts as JSON. Useful for scripts.
#
#   4. dashboard    (HTTP GET /api/dashboard, anonymous)
#        Renders a small HTML dashboard from the same data. This is what a
#        human opens in a browser.
#
# NOTE ON AUTH LEVELS
# -------------------
#   - FUNCTION means the caller must supply the function-key query string
#     (?code=...). We use this for /api/run to prevent random people from
#     triggering the buy loop.
#   - ANONYMOUS on /api/dashboard and /api/state is fine because they only
#     READ from state - no way to trigger anything. If you want, tighten this
#     later by putting the Function App behind Entra ID.
# =============================================================================

from __future__ import annotations

import html
import json
import logging
from typing import List, Tuple

import azure.functions as func

from cr_config import Config, load_config
from cr_manager import ReservationManager
from cr_state import AttemptRecord, SkuState, StateStore

# Global Functions app object. AuthLevel.FUNCTION is just the default for
# HTTP routes that don't override it individually.
app = func.FunctionApp(http_auth_level=func.AuthLevel.FUNCTION)

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("cr")


# -----------------------------------------------------------------------------
# _bootstrap
#
# All four functions need the Config, StateStore, and ReservationManager.
# We build them here once per invocation. This is safe on Flex Consumption
# where cold starts are cheap and the SDK clients are lightweight.
# -----------------------------------------------------------------------------
def _bootstrap() -> Tuple[Config, StateStore, ReservationManager]:
    cfg = load_config()
    store = StateStore(cfg.storage_endpoint, cfg.state_table, cfg.attempts_table)
    return cfg, store, ReservationManager(cfg, store)


# =============================================================================
# 1) Timer trigger - the automation
# =============================================================================
#   NCRONTAB format: {second} {minute} {hour} {day} {month} {day-of-week}
#   "0 0 * * * *"  = second 0, minute 0, every hour, every day => once per hour.
#
#   run_on_startup=False : don't fire on every deployment (would be annoying).
#   use_monitor=True     : Functions runtime persists timer state so the next
#                          run isn't re-triggered after a restart. This is the
#                          default and is what we want.
# =============================================================================
@app.timer_trigger(schedule="0 0 * * * *", arg_name="mytimer",
                   run_on_startup=False, use_monitor=True)
def hourly_buy(mytimer: func.TimerRequest) -> None:
    log.info("Hourly cycle started (past_due=%s)", mytimer.past_due)
    _, _, mgr = _bootstrap()
    summary = mgr.run_cycle()
    log.info("Cycle summary: %s", json.dumps(summary, default=str))


# =============================================================================
# 2) Manual trigger - "run the cycle right now"
#     Protected by function key. Use it for testing:
#       curl -X POST "https://<app>.azurewebsites.net/api/run?code=<key>"
# =============================================================================
@app.route(route="run", methods=["POST"], auth_level=func.AuthLevel.FUNCTION)
def run_now(req: func.HttpRequest) -> func.HttpResponse:
    try:
        _, _, mgr = _bootstrap()
        summary = mgr.run_cycle()
        return func.HttpResponse(
            json.dumps(summary, default=str),
            status_code=200,
            mimetype="application/json",
        )
    except Exception as exc:
        # Log the full stack trace but return a short error to the caller.
        log.exception("Manual run failed")
        return func.HttpResponse(f"error: {exc}", status_code=500)


# =============================================================================
# 3) JSON state endpoint - for scripts / automation
# =============================================================================
@app.route(route="state", methods=["GET"], auth_level=func.AuthLevel.ANONYMOUS)
def get_state(req: func.HttpRequest) -> func.HttpResponse:
    cfg, store, _ = _bootstrap()
    return func.HttpResponse(
        json.dumps(_payload(cfg, store), default=str, indent=2),
        status_code=200,
        mimetype="application/json",
    )


# =============================================================================
# 4) HTML dashboard - for humans in a browser
# =============================================================================
@app.route(route="dashboard", methods=["GET"], auth_level=func.AuthLevel.ANONYMOUS)
def dashboard(req: func.HttpRequest) -> func.HttpResponse:
    cfg, store, _ = _bootstrap()
    return func.HttpResponse(
        _render(_payload(cfg, store)),
        status_code=200,
        mimetype="text/html; charset=utf-8",
    )


# =============================================================================
# Payload builder (shared between the JSON and HTML endpoints)
# =============================================================================
def _payload(cfg: Config, store: StateStore) -> dict:
    """
    Assemble the full state payload:
      - config    : which subscription/RG/region/group we're operating on
      - targets   : per-SKU status (confirmed vs target, last outcome/error)
      - recent_attempts : the audit log tail (last ~100 attempts)
    """
    states: List[SkuState] = store.list_state()
    attempts: List[AttemptRecord] = store.recent_attempts(limit=100)

    # Convenience map for O(1) lookup by SKU.
    by_sku = {s.sku: s for s in states}

    # Build one entry per configured target. If a SKU has no state row yet
    # (very first hour), we synthesize zeros so the dashboard still shows it.
    per_sku = {}
    for tgt in cfg.targets:
        s = by_sku.get(tgt.sku)
        confirmed = s.current_capacity if s else 0
        per_sku[tgt.sku] = {
            "target": tgt.quantity,
            "confirmed": confirmed,
            "remaining": max(tgt.quantity - confirmed, 0),
            "provisioning_state": s.provisioning_state if s else "None",
            "last_outcome": s.last_outcome if s else "",
            "last_attempt_utc": s.last_attempt_utc if s else None,
            "last_error": s.last_error if s else "",
            "updated_utc": s.updated_utc if s else "",
        }

    return {
        "config": {
            "subscription_id": cfg.subscription_id,
            "resource_group": cfg.resource_group,
            "location": cfg.location,
            "group_name": cfg.group_name,
        },
        "targets": per_sku,
        "recent_attempts": [a.__dict__ for a in attempts],
    }


# =============================================================================
# HTML renderer
#
# We deliberately do NOT use a template engine. A single f-string keeps the
# dashboard file-less (no /templates directory to deploy). All user-visible
# text goes through html.escape() to avoid HTML injection from Azure error
# messages that might contain '<' etc.
# =============================================================================
def _render(payload: dict) -> str:
    cfg = payload["config"]
    targets = payload["targets"]
    attempts = payload["recent_attempts"]

    # ---- Build one card per SKU (top of the page) ----
    sku_cards = []
    for sku, info in targets.items():
        pct = int(100 * info["confirmed"] / info["target"]) if info["target"] else 0
        err_html = (
            f"<p class='err'>Last error: {html.escape(info['last_error'][:400])}</p>"
            if info['last_error'] else ""
        )
        sku_cards.append(f"""
        <section class='sku'>
          <h2>{html.escape(sku)}</h2>
          <div class='progress'><div class='bar' style='width:{pct}%'></div></div>
          <p><b>Confirmed:</b> {info['confirmed']} / {info['target']} &nbsp;
             <b>Remaining:</b> {info['remaining']} &nbsp; ({pct}%)</p>
          <p><b>State:</b> {html.escape(info['provisioning_state'])} &nbsp;
             <b>Last outcome:</b> {html.escape(info['last_outcome'] or '-')} &nbsp;
             <b>Last attempt (UTC):</b> {html.escape(info['last_attempt_utc'] or '-')}</p>
          {err_html}
        </section>""")

    # ---- Build one <tr> per audit-log entry (bottom of the page) ----
    attempt_rows = "".join(
        f"<tr class='{a['result']}'>"
        f"<td>{html.escape(a['timestamp_utc'])}</td>"
        f"<td>{html.escape(a['sku'])}</td>"
        f"<td>{html.escape(a['action'])}</td>"
        f"<td>{a['attempted_quantity']}</td>"
        f"<td>{a['resulting_capacity']}</td>"
        f"<td>{html.escape(a['result'])}</td>"
        f"<td class='err'>{html.escape((a['error'] or '')[:200])}</td></tr>"
        for a in attempts
    )

    # ---- Assemble the final HTML document ----
    # The <meta http-equiv='refresh' content='60'> makes the page auto-refresh
    # every 60 seconds, so you can leave it open on a monitor.
    return f"""<!doctype html>
<html><head>
<meta charset='utf-8'/>
<title>Capacity Reservation Dashboard</title>
<meta http-equiv='refresh' content='60'/>
<style>
  body {{ font-family: -apple-system, Segoe UI, Roboto, Helvetica, Arial; margin: 24px; color: #222; }}
  h1 {{ margin: 0 0 8px 0; }}
  .meta {{ color: #666; margin-bottom: 24px; font-size: 13px; }}
  section.sku {{ background: #f7f9fc; border: 1px solid #e2e8f0; border-radius: 8px; padding: 16px 20px; margin-bottom: 20px; }}
  section.sku h2 {{ margin: 0 0 10px 0; font-size: 18px; }}
  .progress {{ background: #e2e8f0; border-radius: 4px; height: 10px; overflow: hidden; margin: 6px 0; }}
  .bar {{ background: #38a169; height: 100%; }}
  table {{ border-collapse: collapse; width: 100%; font-size: 13px; }}
  th, td {{ border: 1px solid #e2e8f0; padding: 6px 8px; text-align: left; vertical-align: top; }}
  th {{ background: #edf2f7; }}
  tr.failure td {{ background: #fff5f5; }}
  tr.success td {{ background: #f0fff4; }}
  .err {{ color: #c53030; font-family: monospace; font-size: 12px; }}
  details summary {{ cursor: pointer; font-weight: 600; margin: 20px 0 10px; }}
</style>
</head><body>
<h1>Capacity Reservation Dashboard</h1>
<div class='meta'>
  Region: <b>{html.escape(cfg['location'])}</b> &middot;
  RG: <b>{html.escape(cfg['resource_group'])}</b> &middot;
  Group: <b>{html.escape(cfg['group_name'])}</b> (regional)
  &middot; auto-refresh 60s
</div>
{''.join(sku_cards)}
<details open>
  <summary>Recent attempts ({len(attempts)})</summary>
  <table>
    <thead><tr>
      <th>UTC</th><th>SKU</th><th>Action</th>
      <th>Attempted</th><th>Result cap</th><th>Result</th><th>Error</th>
    </tr></thead>
    <tbody>{attempt_rows or '<tr><td colspan=7>No attempts recorded yet</td></tr>'}</tbody>
  </table>
</details>
</body></html>"""
