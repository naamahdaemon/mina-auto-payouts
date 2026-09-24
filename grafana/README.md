# Mina payout overview panel

One built-in **Stat** panel with 15 values: epoch, status, estimated confirmation
progress, confirmed/planned transaction counts, next position awaiting
confirmation, on-chain/inferred nonces, pending transactions, wallet balance,
funding required, last completed epoch/date, collection health and collection
age. No Grafana plugin is required. Labels and instructions are in English.

## 1. Import and select your machine

1. In Grafana, open **Dashboards → New → Import**.
2. Upload [`mina-payout-dashboard.json`](mina-payout-dashboard.json), then import.
3. At the top, select your **Prometheus**, **Job** and **Instance**. They are
   discovered from `mina_payout_metrics_collection_timestamp_seconds`.

This creates a new dashboard containing just the overview panel. It uses
Classic dashboard JSON (schema version 39), the built-in Prometheus datasource
and Stat visualization. No server, username or datasource UID is hardcoded.

The dashboard refreshes every 30 seconds; a once-per-minute collector still
only provides new observations once per minute, plus scrape latency.

## 2. Add the panel to your existing dashboard

For a panel that does not depend on dashboard variables, use
[`mina-payout-panel.json`](mina-payout-panel.json):

1. Replace **all** occurrences of these placeholders in a copy of the JSON:

   | Placeholder | Replace with |
   |---|---|
   | `REPLACE_PROMETHEUS_UID` | Your Prometheus datasource UID, not its display name |
   | `REPLACE_JOB` | The metric's `job` label, e.g. `node-exporter` |
   | `REPLACE_INSTANCE` | The metric's `instance` label, e.g. `server.example.net:9100` |

   Find the datasource UID in its Grafana settings/URL or in the JSON of an
   existing Prometheus panel. Find the labels in Explore using:

   ```promql
   mina_payout_metrics_collection_timestamp_seconds
   ```

2. Export/back up your existing dashboard, then open its **Classic JSON model**
   (the location is version-dependent, commonly dashboard settings → JSON Model).
   Append the prepared panel object to the `panels` array, preserving all
   existing panels. Give it an unused numeric `id` and adjust `gridPos.y` to put
   it below your existing panels. Save the dashboard.

   Where Grafana offers an editable **Panel JSON** view, you can instead create
   a new Stat panel and replace its panel JSON with the prepared object,
   preserving the new panel's ID and position.

The panel-only file is not a complete dashboard: do not upload it through
**Import dashboard**. Alternatively, copy the panel from the imported dashboard
using your Grafana version's panel copy/paste action. In that case also copy the
`DS_PROMETHEUS`, `job`, and `instance` variables into the destination dashboard,
or replace those references with your datasource and label values.

## Reading the panel

Example values (illustrative, not bundled demo data):

```text
Epoch                 Status                        Confirmed progress
81                    Submitted waiting confirmation 16.8 %

Confirmed transactions  Planned transactions         Next awaiting confirmation
42                      250                          43

Wallet nonce            Inferred nonce               Pending transactions
542                     550                          8
```

- **Next awaiting confirmation** is a one-based position, not a percentage.
  It displays **All confirmed** when the exported position is zero.
- Progress is estimated from consumed nonces for a dedicated wallet. **100%**
  does not imply that the wrapper's final integrity checks have passed: look
  for **Completed ok** in Status.
- **Funding remaining** is absent after signing starts. Other unavailable
  fields may be absent or show **N/A/No data**; absence is never replaced by zero.
- Values are hidden when the collector timestamp is at least **180 seconds** old.
  **Collection age** remains visible and turns red. If the collector has never
  run, or the datasource/labels are incorrect, the panel has no data.
- **Collection error** means the latest collector run reported a failure.
  During a daemon failure, available local batch data remains visible, but live
  wallet/progress values may be absent. See the collector logs.
- Queries use both `job` and `instance` and select one machine at a time.
  Keep the dashboard time range ending at **now** for current values.

JSON structure and collector metric references have been checked locally.
Rendering and import still need verification on your Grafana installation;
no live Grafana or Prometheus instance was used to validate this panel.

Official references: [Import dashboards](https://grafana.com/docs/grafana/latest/visualizations/dashboards/build-dashboards/import-dashboards/)
and [Prometheus instant queries](https://grafana.com/docs/grafana/latest/datasources/prometheus/query-editor/).
