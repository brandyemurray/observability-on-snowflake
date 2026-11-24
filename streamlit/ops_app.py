"""Summit Peak operations: a Streamlit in Snowflake app over the observability data.

Tabs: Service health, Incidents (with the AI SRE summary), Traces, Logs, Pipeline.
The app runs as OBS_APP_OWNER, an analyst-level role, so log text is masked by
the Snowflake masking policy and the AI summary only ever sees masked text.
All times are shown in Mountain time; Snowflake stores them in UTC.
"""
from __future__ import annotations

import altair as alt
import pandas as pd
import streamlit as st

st.set_page_config(page_title="Summit Peak operations", layout="wide")

# ----------------------------------------------------------------------------- data access
def _session():
    """Works in every Streamlit in Snowflake runtime: the classic warehouse
    runtime (active session) and the newer container runtime (st.connection)."""
    try:
        from snowflake.snowpark.context import get_active_session

        return get_active_session()
    except Exception:
        return st.connection("snowflake").session()


SESSION = _session()

TZ = "America/Denver"
SERVICES = ["lift-tickets", "rentals", "payments", "notifications"]
SERVICE_COLORS = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100"]  # fixed: color follows the service
STATE_STYLE = {  # status colors always ship with an icon and a label
    "HEALTHY": ("#0ca30c", "✓", "Healthy"),
    "DEGRADED": ("#fab219", "▲", "Degraded"),
    "BREACHING": ("#d03b3b", "✕", "Breaching SLO"),
    "LOW_TRAFFIC": ("#8a8a85", "○", "Too little traffic to judge"),
}
POOL_SIZE = 8


@st.cache_data(ttl=60, show_spinner=False)
def run(sql: str) -> pd.DataFrame:
    df = SESSION.sql(sql).to_pandas()
    df.columns = [c.lower() for c in df.columns]
    return df


def local(col: str) -> str:
    """UTC column -> Mountain time, as a plain timestamp."""
    return f"CONVERT_TIMEZONE('UTC', '{TZ}', {col})::TIMESTAMP_NTZ"


def q(s: str) -> str:
    return "'" + s.replace("'", "''") + "'"


def service_scale():
    return alt.Scale(domain=SERVICES, range=SERVICE_COLORS)


def chart(c, height=230):
    return (c.properties(height=height)
             .configure_axis(grid=True, gridColor="#ecebe7", domainColor="#c9c8c2", labelColor="#55554f",
                             titleColor="#55554f", labelFontSize=11, titleFontSize=11, titleFontWeight="normal")
             .configure_legend(orient="top", title=None, labelFontSize=12, symbolType="stroke")
             .configure_view(stroke=None))


st.markdown(
    """
    <style>
      .block-container {padding-top: 1.6rem;}
      .tile {border: 1px solid #e3e2dd; border-radius: 8px; padding: 12px 14px; background: #fff;}
      .tile h4 {margin: 0 0 2px 0; font-size: 1rem;}
      .state {font-size: 0.85rem; font-weight: 600;}
      .nums {font-size: 0.85rem; color: #55554f; margin-top: 6px; line-height: 1.5;}
      .pill {display:inline-block; padding: 2px 10px; border-radius: 999px; background:#eef4f5; color:#173F49;
             font-size: 0.8rem; margin-right: 6px;}
    </style>
    """,
    unsafe_allow_html=True,
)

# ----------------------------------------------------------------------------- header
role = run("SELECT CURRENT_ROLE() AS R").r[0]
fresh = run("SELECT MIN(AGE_SECONDS) AS AGE_S FROM SKI_OBS.OPS.PIPELINE_FRESHNESS")

left, right = st.columns([3, 2])
with left:
    st.title("Summit Peak operations")
    age = fresh.age_s[0]
    age_txt = "no data yet" if pd.isna(age) else (f"{int(age)} s ago" if age < 120 else f"{int(age // 60)} min ago")
    st.markdown(f"<span class='pill'>Role: {role}</span><span class='pill'>Latest telemetry: {age_txt}</span>"
                f"<span class='pill'>Times in Mountain time</span>", unsafe_allow_html=True)
with right:
    window = st.radio("Time window", [15, 60, 180, 720], index=1, horizontal=True,
                      format_func=lambda m: f"{m} min" if m < 120 else f"{m // 60} h")
    if st.button("Refresh now"):
        st.cache_data.clear()

since = f"DATEADD(minute, -{window}, SYSDATE())"
health, incidents_tab, traces_tab, logs_tab, pipeline_tab = st.tabs(
    ["Service health", "Incidents", "Traces", "Logs", "Pipeline"])

# ----------------------------------------------------------------------------- service health
with health:
    slo = run("""
        SELECT SERVICE_NAME, STATE, REQUESTS, ERRORS, ERROR_RATE, WORST_P95_MS, MAX_ERROR_RATE, WINDOW_MINUTES
        FROM SKI_OBS.OPS.SLO_STATUS
    """).set_index("service_name")

    st.caption("Right now: each service's last 5 minutes against its error-rate objective.")
    cols = st.columns(4)
    for col, svc in zip(cols, SERVICES):
        if svc not in slo.index:
            continue
        r = slo.loc[svc]
        color, icon, label = STATE_STYLE.get(r.state, STATE_STYLE["LOW_TRAFFIC"])
        er = "–" if pd.isna(r.error_rate) else f"{r.error_rate:.1%}"
        p95 = "–" if pd.isna(r.worst_p95_ms) else f"{r.worst_p95_ms:,.0f} ms"
        col.markdown(
            f"<div class='tile' style='border-left: 5px solid {color}'>"
            f"<h4>{svc}</h4><div class='state' style='color:{color}'>{icon} {label}</div>"
            f"<div class='nums'>{int(r.requests):,} requests · {er} errors<br>"
            f"objective ≤ {r.max_error_rate:.0%} · worst p95 {p95}</div></div>",
            unsafe_allow_html=True)
    st.write("")

    gs = run(f"""
        SELECT SERVICE_NAME, {local('MINUTE')} AS MINUTE, REQUESTS, ERRORS, ERROR_RATE, P95_MS,
               PEAK_PROVIDER_DEMAND
        FROM SKI_OBS.OPS.GOLDEN_SIGNALS
        WHERE MINUTE >= {since} AND MINUTE < DATE_TRUNC('minute', SYSDATE())
        ORDER BY MINUTE
    """)
    if gs.empty:
        st.info("No golden signals in this window yet. Telemetry lands about a minute after it's sent.")
    else:
        gs["error_pct"] = gs.error_rate.fillna(0) * 100
        base = alt.Chart(gs).encode(
            x=alt.X("minute:T", title=None),
            color=alt.Color("service_name:N", scale=service_scale(), legend=alt.Legend(title=None)),
            tooltip=[alt.Tooltip("service_name:N", title="Service"), alt.Tooltip("minute:T", format="%H:%M"),
                     alt.Tooltip("requests:Q", format=","), alt.Tooltip("errors:Q", format=","),
                     alt.Tooltip("error_pct:Q", title="Error %", format=".1f"),
                     alt.Tooltip("p95_ms:Q", title="p95 ms", format=",.0f")])
        a, b = st.columns(2)
        with a:
            st.markdown("**Traffic** · requests per minute")
            st.altair_chart(chart(base.mark_line(strokeWidth=2).encode(y=alt.Y("requests:Q", title=None))),
                            use_container_width=True)
        with b:
            st.markdown("**Errors** · % of requests that failed")
            st.altair_chart(chart(base.mark_line(strokeWidth=2).encode(y=alt.Y("error_pct:Q", title=None))),
                            use_container_width=True)
        c, d = st.columns(2)
        with c:
            st.markdown("**Latency** · p95 in milliseconds")
            st.altair_chart(chart(base.mark_line(strokeWidth=2).encode(y=alt.Y("p95_ms:Q", title=None))),
                            use_container_width=True)
        with d:
            st.markdown(f"**Saturation** · payment requests competing for {POOL_SIZE} provider connections")
            pay = gs[gs.service_name == "payments"].dropna(subset=["peak_provider_demand"])
            line = alt.Chart(pay).mark_line(strokeWidth=2, color="#1baf7a").encode(
                x=alt.X("minute:T", title=None), y=alt.Y("peak_provider_demand:Q", title=None),
                tooltip=[alt.Tooltip("minute:T", format="%H:%M"),
                         alt.Tooltip("peak_provider_demand:Q", title="Peak demand")])
            rule = alt.Chart(pd.DataFrame({"y": [POOL_SIZE]})).mark_rule(strokeDash=[4, 3], color="#55554f").encode(y="y:Q")
            label = alt.Chart(pd.DataFrame({"y": [POOL_SIZE], "t": [f"pool size {POOL_SIZE}"]})).mark_text(
                align="left", dx=4, dy=-6, color="#55554f", fontSize=11).encode(y="y:Q", text="t:N", x=alt.value(0))
            st.altair_chart(chart(alt.layer(line, rule, label)), use_container_width=True)

# ----------------------------------------------------------------------------- incidents
with incidents_tab:
    inc = run(f"""
        SELECT INCIDENT_ID, SERVICE_NAME, STATUS, {local('OPENED_AT')} AS OPENED, {local('RESOLVED_AT')} AS RESOLVED,
               DATEDIFF(minute, OPENED_AT, COALESCE(RESOLVED_AT, SYSDATE())) AS MINUTES,
               TRIGGER_RULE, PEAK_ERROR_RATE, AI_SUMMARY, AI_SUMMARY_MODEL, {local('AI_SUMMARY_AT')} AS AI_SUMMARY_AT,
               OPENED_AT AS OPENED_UTC, COALESCE(RESOLVED_AT, SYSDATE()) AS END_UTC
        FROM SKI_OBS.OPS.INCIDENTS
        WHERE OPENED_AT >= DATEADD(day, -7, SYSDATE())
        ORDER BY OPENED_AT DESC
    """)
    if inc.empty:
        st.info("No incidents in the last 7 days. Run `make incident` in the lab to create one.")
    else:
        open_n = int((inc.status == "OPEN").sum())
        st.markdown(f"**{open_n} open** · {len(inc)} in the last 7 days")
        show = inc[["incident_id", "service_name", "status", "opened", "resolved", "minutes", "peak_error_rate"]].copy()
        show["peak_error_rate"] = (show.peak_error_rate * 100).round(1)
        st.dataframe(show.rename(columns={"incident_id": "ID", "service_name": "Service", "status": "Status",
                                          "opened": "Opened", "resolved": "Resolved", "minutes": "Minutes",
                                          "peak_error_rate": "Peak error %"}),
                     hide_index=True, use_container_width=True)

        pick = st.selectbox("Incident", inc.incident_id.tolist(),
                            format_func=lambda i: f"#{i} · {inc.set_index('incident_id').loc[i, 'service_name']} · "
                                                  f"{inc.set_index('incident_id').loc[i, 'opened']:%b %d %H:%M}")
        row = inc.set_index("incident_id").loc[pick]
        st.markdown(f"#### #{pick} · {row.service_name} · {row.status.lower()}")
        st.caption(row.trigger_rule)

        trend = run(f"""
            SELECT SERVICE_NAME, {local('MINUTE')} AS MINUTE, ERROR_RATE * 100 AS ERROR_PCT, REQUESTS
            FROM SKI_OBS.OPS.GOLDEN_SIGNALS
            WHERE MINUTE BETWEEN DATEADD(minute, -20, {q(str(row.opened_utc))}::TIMESTAMP_NTZ)
                             AND DATEADD(minute, 10, {q(str(row.end_utc))}::TIMESTAMP_NTZ)
            ORDER BY MINUTE
        """)
        if not trend.empty:
            band = alt.Chart(pd.DataFrame({"start": [row.opened], "end": [row.resolved if pd.notna(row.resolved)
                                                                         else trend.minute.max()]})
                             ).mark_rect(opacity=0.08, color="#d03b3b").encode(x="start:T", x2="end:T")
            lines = alt.Chart(trend).mark_line(strokeWidth=2).encode(
                x=alt.X("minute:T", title=None), y=alt.Y("error_pct:Q", title="Error %"),
                color=alt.Color("service_name:N", scale=service_scale()),
                tooltip=["service_name", alt.Tooltip("minute:T", format="%H:%M"),
                         alt.Tooltip("error_pct:Q", format=".1f"), alt.Tooltip("requests:Q", format=",")])
            st.altair_chart(chart(alt.layer(band, lines), height=200), use_container_width=True)
            st.caption("Shaded: while the incident was open.")

        st.markdown("##### AI SRE summary")
        if isinstance(row.ai_summary, str) and row.ai_summary.strip():
            with st.container(border=True):
                st.markdown(row.ai_summary)
            st.caption(f"Written by {row.ai_summary_model} at {row.ai_summary_at:%b %d %H:%M} from the incident's "
                       "golden signals, error logs, slowest operations, SLOs and service catalog. "
                       "Log text was masked before the model saw it.")
            label = "Rewrite the summary"
        else:
            st.caption("Not written yet. The summary uses only this incident's evidence, and the model sees "
                       "masked log text.")
            label = "Write the AI summary"
        if st.button(label, type="primary"):
            with st.spinner("Gathering the evidence and asking Cortex…"):
                SESSION.sql(f"CALL SKI_OBS.OPS.SUMMARIZE_INCIDENT({int(pick)})").collect()
            st.cache_data.clear()
            st.rerun()

        with st.expander("Show the evidence the model receives"):
            st.code(f"CALL SKI_OBS.OPS.SUMMARIZE_INCIDENT({int(pick)});\n\n"
                    "-- Evidence: incident row, overlapping incidents, golden signals by minute,\n"
                    "-- the 15 most common warning/error log messages, the slowest operations\n"
                    "-- from sampled traces, SLOs and the service catalog. See snowflake/07_ai_sre.sql.",
                    language="sql")

# ----------------------------------------------------------------------------- traces
with traces_tab:
    f1, f2 = st.columns([2, 3])
    svc = f1.selectbox("Service", ["Any"] + SERVICES, key="trace_svc")
    kind = f2.radio("Show", ["Failed", "Slowest", "Most recent"], horizontal=True)
    svc_filter = "" if svc == "Any" else f"AND SERVICE_NAME = {q(svc)}"
    order = {"Failed": "HAS_ERROR DESC, START_TIME DESC", "Slowest": "DURATION_MS DESC",
             "Most recent": "START_TIME DESC"}[kind]
    err_filter = "AND HAS_ERROR" if kind == "Failed" else ""
    traces = run(f"""
        WITH roots AS (
          SELECT TRACE_ID, SERVICE_NAME, SPAN_NAME, START_TIME, DURATION_MS, HTTP_STATUS
          FROM SKI_OBS.OTEL.SPANS
          WHERE PARENT_SPAN_ID IS NULL AND START_TIME >= {since} {svc_filter}
        ), errs AS (
          SELECT TRACE_ID, COUNT_IF(STATUS = 'ERROR') > 0 AS HAS_ERROR, COUNT(*) AS SPANS
          FROM SKI_OBS.OTEL.SPANS WHERE START_TIME >= DATEADD(minute, -1, {since}) GROUP BY 1
        )
        SELECT r.TRACE_ID, r.SERVICE_NAME, r.SPAN_NAME, {local('r.START_TIME')} AS STARTED,
               ROUND(r.DURATION_MS, 1) AS DURATION_MS, r.HTTP_STATUS, e.HAS_ERROR, e.SPANS
        FROM roots r JOIN errs e USING (TRACE_ID)
        WHERE TRUE {err_filter}
        ORDER BY {order}
        LIMIT 25
    """)
    if traces.empty:
        st.info("No traces match. Only sampled traces are stored: every failed or slow one, and 10% of the rest.")
    else:
        st.dataframe(traces.rename(columns={"trace_id": "Trace", "service_name": "Entry service",
                                            "span_name": "Request", "started": "Started", "duration_ms": "ms",
                                            "http_status": "HTTP", "has_error": "Failed", "spans": "Spans"}),
                     hide_index=True, use_container_width=True)
        tid = st.selectbox("Open a trace", traces.trace_id.tolist(),
                           format_func=lambda t: f"{t[:12]}… · {traces.set_index('trace_id').loc[t, 'span_name']} · "
                                                 f"{traces.set_index('trace_id').loc[t, 'duration_ms']:,.0f} ms")
        spans = run(f"""
            SELECT SERVICE_NAME, SPAN_NAME, SPAN_ID, PARENT_SPAN_ID, STATUS, STATUS_MESSAGE, HTTP_STATUS,
                   DATEDIFF(microsecond, MIN(START_TIME) OVER (), START_TIME) / 1000 AS OFFSET_MS,
                   DURATION_MS
            FROM SKI_OBS.OTEL.SPANS WHERE TRACE_ID = {q(tid)}
            ORDER BY START_TIME
        """)
        spans["end_ms"] = spans.offset_ms + spans.duration_ms
        spans["step"] = [f"{i + 1:02d} {s} · {n}" for i, (s, n) in enumerate(zip(spans.service_name, spans.span_name))]
        spans["outcome"] = spans.status.map({"ERROR": "Failed"}).fillna("OK")
        bars = alt.Chart(spans).mark_bar(cornerRadius=2).encode(
            x=alt.X("offset_ms:Q", title="Milliseconds from start of request"), x2="end_ms:Q",
            y=alt.Y("step:N", sort=None, title=None, axis=alt.Axis(labelLimit=320, labelOverlap=False)),
            color=alt.Color("service_name:N", scale=service_scale(), legend=None),  # the row label already names the service
            stroke=alt.condition("datum.outcome == 'Failed'", alt.value("#d03b3b"), alt.value(None)),
            strokeWidth=alt.condition("datum.outcome == 'Failed'", alt.value(2), alt.value(0)),
            tooltip=["service_name", "span_name", alt.Tooltip("duration_ms:Q", format=",.1f"), "outcome",
                     "http_status", "status_message"])
        # Discrete y axis: skip chart()'s chart-level config, which collapses band
        # scales in Streamlit; keep only the height.
        st.altair_chart(bars.properties(height=max(120, 34 * len(spans))), use_container_width=True)
        st.caption("Each bar is one step of the request. A red outline marks a step that failed.")
        logs = run(f"""
            SELECT {local('LOG_TIME')} AS TIME, SERVICE_NAME, SEVERITY, BODY
            FROM SKI_OBS.OTEL.LOGS WHERE TRACE_ID = {q(tid)} ORDER BY LOG_TIME
        """)
        st.markdown("**Logs from this request**")
        st.dataframe(logs, hide_index=True, use_container_width=True)

# ----------------------------------------------------------------------------- logs
with logs_tab:
    c1, c2, c3 = st.columns([3, 2, 2])
    text = c1.text_input("Search log text", placeholder="timed out, provider, card…")
    svcs = c2.multiselect("Services", SERVICES)
    sev = c3.multiselect("Severity", ["ERROR", "WARN", "WARNING", "INFO"], default=["ERROR", "WARN", "WARNING"])
    where = [f"LOG_TIME >= {since}"]
    if text:
        where.append(f"BODY ILIKE {q('%' + text + '%')}")
    if svcs:
        where.append("SERVICE_NAME IN (" + ", ".join(q(s) for s in svcs) + ")")
    if sev:
        where.append("SEVERITY IN (" + ", ".join(q(s) for s in sev) + ")")
    logs = run(f"""
        SELECT {local('LOG_TIME')} AS TIME, SERVICE_NAME, SEVERITY, BODY, TRACE_ID
        FROM SKI_OBS.OTEL.LOGS WHERE {' AND '.join(where)}
        ORDER BY LOG_TIME DESC LIMIT 300
    """)
    st.caption(f"{len(logs)} most recent matching records. You're viewing as {role}: "
               "roles below OBS_SRE see emails, phone numbers and long digit strings masked.")
    st.dataframe(logs, hide_index=True, use_container_width=True)

# ----------------------------------------------------------------------------- pipeline
with pipeline_tab:
    st.markdown("**Is telemetry arriving?**")
    landing = run("SELECT SIGNAL, AGE_SECONDS, BATCHES_LAST_HOUR FROM SKI_OBS.OPS.PIPELINE_FRESHNESS ORDER BY SIGNAL DESC")
    cols = st.columns(3)
    for col, (_, r) in zip(cols, landing.iterrows()):
        age = "never" if pd.isna(r.age_seconds) else f"{int(r.age_seconds)} s ago"
        col.markdown(f"<div class='tile'><h4>{r.signal}</h4><div class='nums'>last landed {age}<br>"
                     f"{int(r.batches_last_hour):,} batches in the last hour</div></div>", unsafe_allow_html=True)
    st.write("")

    st.markdown("**Count before you sample** · requests counted vs. traces kept, this window")
    kept = run(f"""
        WITH counted AS (
          SELECT SERVICE_NAME, SUM(REQUESTS) AS REQUESTS, SUM(ERRORS) AS ERRORS
          FROM SKI_OBS.OPS.TRAFFIC_ERRORS WHERE MINUTE >= {since} GROUP BY 1
        ), stored AS (
          SELECT SERVICE_NAME, COUNT(*) AS SERVER_SPANS, COUNT_IF(STATUS = 'ERROR') AS ERROR_SPANS
          FROM SKI_OBS.OTEL.SPANS WHERE SPAN_KIND = 'SERVER' AND START_TIME >= {since} GROUP BY 1
        )
        SELECT c.SERVICE_NAME, c.REQUESTS, s.SERVER_SPANS AS KEPT,
               ROUND(100 * s.SERVER_SPANS / NULLIF(c.REQUESTS, 0), 1) AS KEPT_PCT,
               ROUND(100 * c.ERRORS / NULLIF(c.REQUESTS, 0), 2) AS TRUE_ERROR_PCT,
               ROUND(100 * s.ERROR_SPANS / NULLIF(s.SERVER_SPANS, 0), 2) AS ERROR_PCT_IN_KEPT_TRACES
        FROM counted c LEFT JOIN stored s USING (SERVICE_NAME)
        ORDER BY c.SERVICE_NAME
    """)
    st.dataframe(kept.rename(columns={"service_name": "Service", "requests": "Requests (all)",
                                      "kept": "Requests kept as traces", "kept_pct": "Kept %",
                                      "true_error_pct": "True error %",
                                      "error_pct_in_kept_traces": "Error % if counted from kept traces"}),
                 hide_index=True, use_container_width=True)
    st.caption("Tail sampling keeps every failed and slow trace and 10% of the rest. That's ideal for "
               "debugging, but counting errors from the kept traces would overstate them, which is why "
               "the golden signals come from span metrics computed before sampling.")
