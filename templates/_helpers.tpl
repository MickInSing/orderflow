{{/*
=====================================================================================================
 _helpers.tpl: the chart's named templates ("partials").

 - Files starting with "_" are never rendered on their own. They only hold `define` blocks.
 - A `define` is global across the parent chart AND every subchart, so names must be prefixed
   with the chart name ("orderflow.") or two charts can silently overwrite each other.
 - Call them with `include` (returns a string you can pipe: | nindent 4), not `template`
   (writes straight out and can't be piped).

 Walkthrough order (matches DEMO.md, "Helm concepts" view):
   H1 orderflow.name / fullname / chart   naming, trunc 63, trimSuffix, default
   H2 labels  (FLAW)                       an unprefixed name, and labels that change every upgrade
   H3 orderflow.selectorLabels             the labels that must NEVER change
   H4 orderflow.serviceAccountName         if/else, default
   H5 orderflow.image                      dict arguments, globals, default to .Chart.AppVersion
   H6 orderflow.env                        range over a map, quote, sorted keys
   H7 orderflow.securityContext            the "secure default" block, used only by the frontend
   H8 orderflow.databaseUrl  (FLAW)        builds a URL with the password in it
   H9 orderflow.validate                   required + fail: stop bad values before they reach the cluster
=====================================================================================================
*/}}

{{/* ---------------------------------------------------------------------------------- H1 naming */}}
{{/*
Chart name, overridable. Kubernetes names max out at 63 characters (DNS label), hence trunc 63,
and trimSuffix stops a trailing "-" after truncation.
*/}}
{{- define "orderflow.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified app name: <release>-<chart>, unless the release name already contains the chart name.
Every resource name in this chart goes through here, so `helm install shop .` gives "shop-orderflow-api" etc.
*/}}
{{- define "orderflow.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/* "orderflow-0.4.0": "+" isn't allowed in label values, so replace it (SemVer build metadata). */}}
{{- define "orderflow.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* ---------------------------------------------------------------------------------- H2 labels */}}
{{/*
FLAW HELM-TPL-001: this define is called "labels", not "orderflow.labels".
Any subchart (or library chart) that also defines "labels" wins or loses depending on load order:
your Deployments quietly get someone else's labels.
Fix: rename to "orderflow.labels" and update every `include "labels"`.

Recommended labels (K8S-META-001): app.kubernetes.io/name, instance, version, managed-by, helm.sh/chart.
Note `version` changes on every upgrade. That's fine here, but never put it in selectorLabels (H3).
*/}}
{{- define "labels" -}}
helm.sh/chart: {{ include "orderflow.chart" . }}
{{ include "orderflow.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: orderflow
orderflow.io/cluster: {{ .Values.cluster.name | quote }}
{{- end }}

{{/* -------------------------------------------------------------------------- H3 selector labels */}}
{{/*
Selector labels are immutable on a Deployment: change them and `helm upgrade` fails with
"field is immutable". Keep them to name + instance (+ component, set per workload).
*/}}
{{- define "orderflow.selectorLabels" -}}
app.kubernetes.io/name: {{ include "orderflow.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Per-component selector: called with a dict, because `include` only takes ONE argument.
  {{ include "orderflow.componentSelector" (dict "root" . "component" "api") }}
Inside, "." is the dict, so the chart context is .root.
*/}}
{{- define "orderflow.componentSelector" -}}
{{ include "orderflow.selectorLabels" .root }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{/* ------------------------------------------------------------------------ H4 service account */}}
{{- define "orderflow.serviceAccountName" -}}
{{- if .create }}
{{- default (printf "%s-%s" (include "orderflow.fullname" .root) .component) .name }}
{{- else }}
{{- default "default" .name }}
{{- end }}
{{- end }}

{{/* ------------------------------------------------------------------------------------ H5 image */}}
{{/*
Builds registry/repository:tag from values.
  - global.imageRegistry (DEMO 2) lets one setting re-point every image, including subcharts.
  - an empty tag falls back to .Chart.AppVersion, so the chart version and the app version move together.
Called as: {{ include "orderflow.image" (dict "root" . "image" .Values.api.image) }}
The worker CronJob does NOT use this (FLAW HELM-VAL-002 / CKS-SUP-001: hard-coded ":latest").
*/}}
{{- define "orderflow.image" -}}
{{- $registry := .root.Values.global.imageRegistry -}}
{{- $tag := default .root.Chart.AppVersion .image.tag -}}
{{- if $registry -}}
{{- printf "%s/%s:%s" $registry .image.repository $tag -}}
{{- else -}}
{{- printf "%s:%s" .image.repository $tag -}}
{{- end -}}
{{- end }}

{{/* -------------------------------------------------------------------------------------- H6 env */}}
{{/*
Turns a values map into an env list. Two things to show:
  - `range $k, $v := ...` iterates a map in sorted key order (stable output, no diff noise in ArgoCD).
  - `quote` every value: WORKERS: 4 is a number in YAML, but env values must be strings, or the
    API server rejects the Deployment. Try removing `| quote` and re-render to see the error.
*/}}
{{- define "orderflow.env" -}}
{{- range $k, $v := . }}
- name: {{ $k }}
  value: {{ $v | quote }}
{{- end }}
{{- end }}

{{/* ------------------------------------------------------------------------- H7 security context */}}
{{/*
The secure container default (CKS-POD-002/003/004/005/007). The frontend includes it; the API
doesn't, so the visualiser shows the contrast. The fix planner's suggested change is to include
this block in api-deployment.yaml as well.
*/}}
{{- define "orderflow.securityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
runAsNonRoot: true
capabilities:
  drop: ["ALL"]
seccompProfile:
  type: RuntimeDefault
{{- end }}

{{/* ---------------------------------------------------------------------------- H8 database url */}}
{{/*
FLAW LRN-SEC-006 / LRN-SEC-004 / LRN-SEC-013: the password ends up inside the URL, the URL ends up
in a ConfigMap (readable by anyone who can read ConfigMaps), and sslmode defaults to "disable".
Fix: read the CloudNativePG Secret "<fullname>-db-app" (key: uri) with secretKeyRef instead,
and drop sslmode=disable.
The host is the CNPG read/write Service, which is how the Pods view links the API to the database.
*/}}
{{- define "orderflow.databaseUrl" -}}
{{- $db := .Values.database -}}
{{- printf "postgresql://%s:%s@%s-db-rw:5432/%s?sslmode=%s" $db.user $db.password (include "orderflow.fullname" .) $db.name (default "require" $db.sslmode) -}}
{{- end }}

{{/* --------------------------------------------------------------------------------- H9 validate */}}
{{/*
Fail early with a readable message instead of a broken release.
  - required: this value MUST be supplied (ArgoCD sets it per cluster: values-argocd.yaml).
  - fail: reject combinations that can't work.
Included at the top of the frontend Deployment so it runs on every render.
*/}}
{{- define "orderflow.validate" -}}
{{- $_ := required "cluster.name must be set (ArgoCD injects it per cluster; for local renders use -f values-argocd.yaml)" .Values.cluster.name -}}
{{- if and .Values.ingress.tls (not .Values.ingress.host) -}}
{{- fail "ingress.tls needs ingress.host (the certificate is issued for that name)" -}}
{{- end -}}
{{- if not (has .Values.cluster.environment (list "dev" "staging" "prod")) -}}
{{- fail (printf "cluster.environment must be dev, staging or prod (got %q)" .Values.cluster.environment) -}}
{{- end -}}
{{- end }}
