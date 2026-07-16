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
  resources:
    requests:
      cpu: 25m
      memory: 32Mi
    limits:
      cpu: 100m
      memory: 64Mi
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
