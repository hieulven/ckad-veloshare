{{/*
Shared name + label helpers for VeloShare.

These are defined in the umbrella chart but are written to be called from any
subchart context (they read `.Chart` / `.Release` of the calling chart), so a
subchart's templates can do `{{ include "veloshare.fullname" . }}` and get a
name derived from that subchart. Keep all naming/labelling going through here
so every resource gets consistent app.kubernetes.io/* labels.
*/}}

{{/*
Base name — the chart name, overridable via .Values.nameOverride.
Truncated to 63 chars for the k8s DNS label limit.
*/}}
{{- define "veloshare.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Fully qualified app name: "<release>-<chart>", or just the chart name if the
release name already contains it. Overridable via .Values.fullnameOverride.
*/}}
{{- define "veloshare.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Chart label: "<name>-<version>" with any '+' replaced (image-tag safe).
*/}}
{{- define "veloshare.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Selector labels — the stable subset used in Service selectors and
Deployment matchLabels. Must not change across upgrades.
*/}}
{{- define "veloshare.selectorLabels" -}}
app.kubernetes.io/name: {{ include "veloshare.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Common labels — put on every resource.
*/}}
{{- define "veloshare.labels" -}}
helm.sh/chart: {{ include "veloshare.chart" . }}
{{ include "veloshare.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: veloshare
{{- end -}}

{{/*
Pod-level securityContext — non-root baseline applied to every Pod in the
platform. Individual containers still set their own runAsUser (their image's
non-root UID) via veloshare.containerSecurityContext; this just forbids UID 0
pod-wide and owns the mounted volumes via fsGroup. Call with a dict:
  (dict "fsGroup" 10001)
*/}}
{{- define "veloshare.podSecurityContext" -}}
runAsNonRoot: true
fsGroup: {{ .fsGroup }}
seccompProfile:
  type: RuntimeDefault
{{- end -}}

{{/*
Container-level securityContext — the hardened baseline for every container
(app, init, and sidecar) in the platform: no privilege escalation, read-only
root filesystem, all Linux capabilities dropped, must not run as root. Any
container whose image doesn't already default to a non-root USER needs
"runAsUser" (and optionally "runAsGroup", defaults to runAsUser) passed in;
containers whose image already sets a non-root USER (rider/station/trip/
pricing/frontend/fleet-monitor/ambassador) can omit both and inherit that
image-baked UID. Call with a dict, e.g.:
  (dict)                                  no override, use image's own USER
  (dict "runAsUser" 999)                  force uid 999 (e.g. postgres client images)
  (dict "runAsUser" 999 "runAsGroup" 999)
*/}}
{{- define "veloshare.containerSecurityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
runAsNonRoot: true
{{- if .runAsUser }}
runAsUser: {{ .runAsUser }}
runAsGroup: {{ .runAsGroup | default .runAsUser }}
{{- end }}
capabilities:
  drop:
    - ALL
{{- end -}}

{{/*
Fluent Bit logging sidecar — renders ONLY the container list item. Caller
supplies `containers:` and the nindent level. Tails the shared `logs`
emptyDir (mounted read-only here, read-write on the app container) and ships
to Elasticsearch using the fluent-bit-config ConfigMap from the logging
subchart.
*/}}
{{- define "veloshare.loggingSidecar" -}}
- name: log-agent
  image: "fluent/fluent-bit:3.1.9"
  imagePullPolicy: IfNotPresent
  securityContext:
    {{- include "veloshare.containerSecurityContext" (dict "runAsUser" 1000) | nindent 4 }}
  resources:
    requests:
      cpu: 10m
      memory: 48Mi
    limits:
      cpu: 50m
      memory: 96Mi
  volumeMounts:
    - name: logs
      mountPath: /var/log/veloshare
      readOnly: true
    - name: fluent-bit-config
      mountPath: /fluent-bit/etc/
{{- end -}}

{{/*
Log volumes for the Fluent Bit sidecar — renders ONLY the volume list items.
Caller supplies `volumes:` and the nindent level.
*/}}
{{- define "veloshare.logVolumes" -}}
- name: logs
  emptyDir: {}
- name: fluent-bit-config
  configMap:
    name: fluent-bit-config
{{- end -}}

{{/*
Config-check init container — CKAD learning demo of the init-container pattern.
Fails fast, before the app/migrate/ambassador containers start, if any env var
the main container needs (sourced from the same Secrets/ConfigMaps via
envFrom) is missing or empty. This duplicates what each service's own
require_env() already enforces in Python — it exists to demonstrate the
pattern at the Pod level, not because the app needs it.

Renders ONLY the init container list item. Call with a dict:
  (dict "requiredVars" .Values.configCheck.requiredVars
        "envFrom"      .Values.configCheck.envFrom
        "resources"    .Values.configCheck.resources)
An empty requiredVars list is valid (e.g. pricing has no required secrets) —
the check then trivially passes.
*/}}
{{- define "veloshare.configCheckInit" -}}
- name: config-check
  image: alpine:3.20
  securityContext:
    {{- include "veloshare.containerSecurityContext" (dict "runAsUser" 65534) | nindent 4 }}
  command:
    - sh
    - -c
    - |
      {{- if .requiredVars }}
      for name in {{ .requiredVars | join " " }}; do
        eval "val=\$$name"
        if [ -z "$val" ]; then
          echo "config check failed: required env var $name is not set" >&2
          exit 1
        fi
      done
      {{- end }}
      echo "config check passed: all required env vars present"
  envFrom:
    {{- toYaml .envFrom | nindent 4 }}
  resources:
    {{- toYaml .resources | nindent 4 }}
{{- end -}}

{{/*
Ambassador container — CKAD learning demo of the ambassador pattern. A local
nginx reverse proxy sits in front of the app container in the same Pod:
Service traffic hits the ambassador's port, which proxy_passes to the app
over 127.0.0.1 (containers in a Pod share one network namespace). The app
itself is unaware of it — it still just listens on its own containerPort.

Renders ONLY the container list item. Expects a ConfigMap named
"<fullname>-ambassador" (see veloshare.ambassadorConf) mounted as
/etc/nginx/conf.d/default.conf, plus "ambassador-tmp" and "ambassador-cache"
emptyDir volumes (nginx-unprivileged needs to write its pid file under /tmp
and proxy/client-body temp files under /var/cache/nginx even though the rest
of the root filesystem is read-only). Call with a dict:
  (dict "port" .Values.ambassador.port "resources" .Values.ambassador.resources)
*/}}
{{- define "veloshare.ambassadorContainer" -}}
- name: ambassador
  image: nginxinc/nginx-unprivileged:1.27-alpine
  securityContext:
    {{- include "veloshare.containerSecurityContext" (dict "runAsUser" 101) | nindent 4 }}
  ports:
    - name: ambassador
      containerPort: {{ .port }}
  volumeMounts:
    - name: ambassador-config
      mountPath: /etc/nginx/conf.d/default.conf
      subPath: default.conf
      readOnly: true
    - name: ambassador-tmp
      mountPath: /tmp
    - name: ambassador-cache
      mountPath: /var/cache/nginx
  resources:
    {{- toYaml .resources | nindent 4 }}
{{- end -}}

{{/*
Ambassador scratch volumes — the "ambassador-tmp" and "ambassador-cache"
emptyDirs the ambassador container's securityContext.readOnlyRootFilesystem
needs (pid file, proxy/client-body temp files). Renders ONLY the volume list
items. Caller supplies `volumes:` and the nindent level.
*/}}
{{- define "veloshare.ambassadorVolumes" -}}
- name: ambassador-tmp
  emptyDir: {}
- name: ambassador-cache
  emptyDir: {}
{{- end -}}

{{/*
Ambassador nginx config — a single server block proxying <port> to the app
container on 127.0.0.1:<appPort>. Used as the data value of the
"<fullname>-ambassador" ConfigMap each subchart renders. Call with a dict:
  (dict "port" .Values.ambassador.port "appPort" .Values.containerPort)
*/}}
{{- define "veloshare.ambassadorConf" -}}
server {
    listen {{ .port }};
    location / {
        proxy_pass http://127.0.0.1:{{ .appPort }};
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
{{- end -}}
