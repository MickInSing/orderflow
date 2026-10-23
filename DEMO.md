# orderflow: Helm visualiser demo chart

A small order system built to demo the visualiser: it covers the Helm Chart Template Guide topics and
has deliberate flaws for the visualiser to find. **Not for production.**

```
Users ─▶ Ingress (no TLS) ─▶ frontend (nginx, hardened)     ── the "good" workload
                         └─▶ api ×3–10 (HPA) + log-shipper  ── the "bad" workload
                                 │  ├─▶ redis-lite (subchart)
                                 │  └─▶ Postgres (CloudNativePG: pods created by the operator)
                         worker (CronJob, cluster-admin)  ·  migrate (pre-install hook)  ·  helm test pod
```

Markers in the files:
* `DEMO n`: a Helm concept to talk through (Act numbers below).
* `FLAW <rule>`: something the visualiser flags.
* `H1`…`H9`: sections of `templates/_helpers.tpl`.

## Before the demo

```bash
# 1. Sanity-check it renders with your Helm (needs the ArgoCD-style values)
helm lint examples/demo-chart/orderflow -f examples/demo-chart/orderflow/values-argocd.yaml
helm template demo examples/demo-chart/orderflow -n orderflow-demo \
  -f examples/demo-chart/orderflow/values-argocd.yaml > /dev/null && echo OK

# 2. Make it loadable in the visualiser: copy it into your mounted charts folder…
cp -r examples/demo-chart/orderflow ~/charts/        # or wherever CHARTS_DIR points
# …or push it and use "Open from Git" with path examples/demo-chart/orderflow
```

Settings for the demo: release `demo`, namespace `orderflow-demo`, Kubernetes target **1.36** (so the HPA API shows as removed).
Expect a hardening score in the **mid-teens**, **2 critical** findings, about 16 high, and a fix-planner preview that roughly doubles the score.

---

## Blueprint: concept → where → what the visualiser shows

| # | Helm concept | Where in the chart | What to point at in the visualiser |
|---|---|---|---|
| 1 | Values injected by ArgoCD, `required` | `values.yaml` `cluster.name: ""`; `_helpers.tpl` **H9** | The render fails with the `required` message. Values drawer: placeholders, or pick `values-argocd.yaml`. "ArgoCD values" appears as an external dependency |
| 2 | Subcharts and globals | `Chart.yaml` dependency + condition; `charts/redis-lite/`; `global.imageRegistry`; `redis-lite:` values | Helm concepts → *Subcharts & globals*; the redis-lite Deployment/Service in the graph; HELM-DEP-001 (no Chart.lock) |
| 3 | Validation with `fail` | `_helpers.tpl` **H9**, included at the top of `frontend-deployment.yaml` | Set `cluster.environment: qa` in the values drawer → re-render → readable error |
| 4 | Variables, `$` | `rbac.yaml` (`$fullname`, `range $component`, `include "labels" $`) | Helm concepts → *Variables* |
| 5 | Flow control: `if`, `with`, `range` | `api-deployment.yaml` (no `replicas` when the HPA is on; `with .Values.api.logShipper`) | Template / Rendered / Side by side on the api Deployment: the `replicas:` line disappears |
| 6 | Functions and pipelines, `range` over a map | `_helpers.tpl` **H6** `orderflow.env`, `quote`, `trim | nindent` | Side by side: the map becomes a sorted env list; WORKERS `4` becomes `"4"` |
| 7 | `.Files.Get` + `tpl` | `configmap.yaml` reads `files/app.conf` | Helm concepts → *Accessing files*; rendered ConfigMap shows `environment = STAGING` |
| 8 | Config checksum to restart pods | `api-deployment.yaml` `checksum/config` | Explain why pods roll when only the ConfigMap changes |
| 9 | `.Capabilities` | `servicemonitor.yaml` | The ServiceMonitor isn't rendered; "Cluster capabilities" external dependency |
| 10 | `lookup` + non-deterministic functions | `secret.yaml` | "Live cluster (lookup)" external; HELM-TPL-002 on `randAlphaNum` |
| 11 | Values per environment | `values-prod.yaml` | Pods view: **API → DB blocked** (NetworkPolicy forgot 5432), Service now ClusterIP |
| 12 | Hooks + `helm test` | `migrate-job.yaml`, `tests/test-connection.yaml` | Hook badges in the graph; talking point on hook ordering (below) |
| 13 | Named templates (the helpers file) | `_helpers.tpl` **H1–H9** | Helm concepts → *Named templates*; HELM-TPL-001 on the unprefixed `labels` |
| 14 | NOTES.txt | `templates/NOTES.txt` | Helm concepts → *NOTES.txt* (conditional output for LoadBalancer / no TLS) |
| 15 | Operator custom resources | `database.yaml` (CNPG `Cluster`) | Pods view: orange dashed `demo-orderflow-db-1`, Services `-rw/-ro/-r`, wires from api / worker / migrate |

## Flaw list (what the visualiser should flag)

| Sev | Rule | Flaw | Where | Fix (what the planner / prompt suggests) |
|---|---|---|---|---|
| critical | CKS-POD-001 | `log-shipper` sidecar is `privileged: true` | `api-deployment.yaml` | Drop privileged; run the log agent as a DaemonSet owned by the platform |
| critical | LRN-SEC-001 | Worker bound to **cluster-admin** | `rbac.yaml` (`worker.clusterWide`) | A ClusterRole with `nodes: get,list` only |
| high | CKS-HOST-002 | hostPath `/var/log` | `api-deployment.yaml` | Remove it (see above), or acknowledge it with a reason (Act 7) |
| high | CKS-POD-002/003 | api, worker and migrate run as root, privilege escalation allowed | `api-deployment.yaml`, `worker-cronjob.yaml`, `migrate-job.yaml` | `include "orderflow.securityContext"` (**H7**), like the frontend |
| high | CKS-SEC-001 | `DB_PASSWORD` as a plain env value | `api-deployment.yaml` | `secretKeyRef` to the CNPG Secret `demo-orderflow-db-app` |
| high | LRN-SEC-004 | `SMTP_PASSWORD` in a ConfigMap | `configmap.yaml` | Move it to a Secret |
| high | LRN-SEC-005 | Literal passwords and JWT in `values.yaml` | `values.yaml` | Empty defaults + existingSecret / External Secrets |
| high | LRN-SEC-006 | Password inside `DATABASE_URL` | `_helpers.tpl` **H8** | Use the CNPG `-app` Secret's `uri` key |
| high | CKS-SUP-001 | Worker image `:latest` | `worker-cronjob.yaml` | `include "orderflow.image"` (**H5**) with a pinned tag |
| high | K8S-API-001 | HPA `autoscaling/v2beta2` (removed in 1.26) | `api-hpa.yaml` | `autoscaling/v2` |
| high | CKS-RBAC-001 | `verbs: ["*"]` on pods | `rbac.yaml` | List the verbs it needs |
| medium | CKS-RBAC-002 | API can read every Secret | `rbac.yaml` | `resourceNames:` or drop it |
| medium | CKS-POD-004/005/007 | No read-only FS, capabilities not dropped, no seccomp | api / worker / migrate | **H7** |
| medium / low | CKS-SA-001 / CKS-SA-003 | API token mounted; SAs auto-mount by default | `api-deployment.yaml`, `rbac.yaml` | `automountServiceAccountToken: false` |
| medium | CKS-NET-001 | No NetworkPolicy by default | `values.yaml` `networkPolicy.enabled: false` | Turn it on (and include 5432!) |
| medium | CKS-NET-002 | Ingress without TLS | `values.yaml` `ingress.tls: false` | `ingress.tls: true` + cert-manager |
| medium | K8S-RES-001 / LRN-PERF-002 | API has no CPU request but the HPA scales on CPU | `values.yaml` `api.resources` | Add `requests.cpu` |
| medium | LRN-SEC-013 | `sslmode=disable` | `_helpers.tpl` **H8**, `values.yaml` | Remove it (default `require`) |
| medium | LRN-PERF-006 | CNPG: 1 instance, no backups, superuser on | `database.yaml` | `instances: 3`, `backup:`, `enableSuperuserAccess: false` |
| medium | HELM-TPL-002 | `randAlphaNum` session key: a new value on every render, so ArgoCD shows drift forever | `secret.yaml` | Create it once outside the chart |
| low | K8S-NET-001 | API Service is `LoadBalancer` | `values.yaml` | ClusterIP behind the Ingress |
| low | LRN-PERF-003 (+ K8S-AVAIL-001 when autoscaling is off) | 3+ API replicas, no PDB, no spread (the frontend has both: contrast) | `api-deployment.yaml` | PDB + topologySpreadConstraints |
| low | LRN-PERF-004 | Liveness is a copy of readiness | `api-deployment.yaml` | A cheap liveness check (tcpSocket) |
| low | HELM-TPL-001 | `define "labels"` isn't prefixed | `_helpers.tpl` **H2** | Rename to `orderflow.labels` |
| low | HELM-TPL-003 | Hard-coded `namespace: orderflow` | `configmap.yaml` | Remove it |
| low | HELM-VAL-001 | `featureFlags.legacyCheckout` is never used | `values.yaml` | Delete it |
| low | HELM-VAL-002 | Images hard-coded in templates | worker, log-shipper, test pod | Values + **H5** |
| low | HELM-DEP-001 | No `Chart.lock` | `Chart.yaml` | `helm dependency update` and commit the lock |
| low | HELM-CHART-003 | No `.helmignore` (so DEMO.md gets packaged) | chart root | Add one |
| info | HELM-CHART-004, CKS-SUP-002, CKS-SEC-002 | No values.schema.json, no image digests, Secret rendered from values | various | Optional hardening |

Not flagged by the visualiser, but good talking points:
* **Hook ordering** (`migrate-job.yaml`): a `pre-install` Job runs *before* the ConfigMap and the database exist, so the first install hangs until it times out.
* **LoadBalancer cost**: every `helm install` in a dev namespace buys a cloud load balancer.
* **Selector immutability** (**H3**): adding `version` to selectorLabels would break every `helm upgrade`.

---

## Demo script (about 25 minutes)

### Act 1: Load it, and the ArgoCD values problem (DEMO 1), 3 min
1. Open the chart (local folder or Git). The render **fails**: *"cluster.name must be set (ArgoCD injects it per cluster…)"*.
2. Say: "In ArgoCD this comes from the Application. Locally we don't have it." Show the **Values** drawer: the required value is listed with a placeholder, and "ArgoCD values" appears as an external dependency.
3. Pick **values-argocd.yaml** in the value files list → **Re-render**. It renders, with the score in the mid-teens.

### Act 2: The chart walkthrough, 4 min
1. **Chart** view: step through the resources. The graph shows Ingress → Services → Deployments, the ConfigMap/Secret links, and the hook and test pods.
2. On the **api** Deployment, switch **Template → Rendered → Side by side**:
   * the `{{- if not .Values.autoscaling.enabled }}` block: no `replicas:` in the output (DEMO 5);
   * `orderflow.env` turning a map into a sorted env list, with `quote` (DEMO 6);
   * `with .Values.api.logShipper` and `$.Release.Name` inside it.
3. Click a red finding (CKS-POD-001): the code panel jumps to `privileged: true`.

### Act 3: `_helpers.tpl` walkthrough, 6 min
Open `templates/_helpers.tpl`; the header lists H1–H9.

| Section | Say | Try live (values drawer) |
|---|---|---|
| H1 naming | `fullname` = release-chart, max 63 characters, `trimSuffix "-"`; why `contains` avoids `orderflow-orderflow` | `--set fullnameOverride=shop` → every name changes |
| H2 labels | Recommended labels; **this define isn't prefixed** (HELM-TPL-001): subcharts share the template namespace | – |
| H3 selectors | Immutable; never put `version` in them | – |
| H4 SA name | `if/else` + `default`, called with a `dict` | – |
| H5 image | `dict "root" . "image" …` because include takes one argument; `global.imageRegistry`; empty tag → appVersion | set `global.imageRegistry=registry.internal:5000` → all images, **including the subchart**, change |
| H6 env | `range $k, $v` is sorted; `quote` matters | – |
| H7 securityContext | The secure default the frontend uses and the API doesn't: this is the fix | – |
| H8 databaseUrl | Builds the password into a URL (3 findings come from this one helper) | – |
| H9 validate | `required` + `fail`, so mistakes show up as readable errors | `cluster.environment=qa` → error |

### Act 4: Helm concepts view, 2 min
Switch to **Helm concepts**. Each Chart Template Guide topic shows where this chart uses it: Files (DEMO 7), Subcharts & globals (DEMO 2), NOTES.txt, Variables (DEMO 4). Point out that `.helmignore` isn't used (HELM-CHART-003).

### Act 5: Infrastructure, Pods, 4 min
1. **Infrastructure → Architecture**: platform dependencies (ingress controller, CloudNativePG, the cluster API for `lookup` / `.Capabilities`).
2. **Pods**:
   * **frontend**: 2 pods across zones, PDB, green hardening, no token. "This is what good looks like."
   * **api**: 3 pods + dashed pods up to 10 (HPA), a red log-shipper sidecar, hostPath, token mounted, the "no spread" warning.
   * **Created by operators**: `demo-orderflow-db-1` (orange, dashed). Wires from api, worker and migrate go to it through the ConfigMap → `demo-orderflow-db-rw`; "no egress policy".
   * Click the DB pod: it's created by CloudNativePG, not the chart. Note "1 instance: no standby".

### Act 6: Production values, the blocked connection (DEMO 11), 2 min
Add **values-prod.yaml** to the value files → Re-render → Pods.
* The NetworkPolicy fence appears around the namespace.
* The API → DB arrow is now **red: blocked**: the egress policy allows DNS and Redis but nobody added 5432.
* Say: "This would deploy fine and then time out at runtime. We caught it before the cluster did."

### Act 7: Fix it, 4 min
1. Click the **hardening score** → **Fix planner**.
2. Severity toggles: only Critical + High are on. Turn on Medium.
3. **Acknowledge** something real: on CKS-HOST-002 click **No action**, scope `Deployment/demo-orderflow-api`, reason "log shipper reads node logs until the platform DaemonSet lands", review date in 90 days. The score moves, and it's listed under "Acknowledged · no action" (not committed yet).
4. **Preview impact**: side-by-side diff, before → after score, a risk note on each change.
5. Back on the chart, **Show fixes on Pods**: green outlines, "+ seccomp / + drop ALL / + no token", a new PDB, and the DB going to 3 instances.
6. **Claude prompt** and **git commands**: the acknowledgement is included as a `.helm-visualiser.yaml` block.

### Act 8 (optional): Compare
If the chart is in Git: open **Compare** with `main` vs the branch Claude fixed. You get fixed / new / unchanged findings and a Markdown summary for the PR.

---

## Reset between runs
* Remove acknowledgements: Fix planner → **Undo** (they live in the browser only).
* Value files: clear the list in the drawer (or reload the page).
