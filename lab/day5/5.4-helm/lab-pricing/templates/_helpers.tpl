{{/*
Standalone name + label helpers for lab-pricing.

Deliberately NOT the umbrella chart's veloshare.* helpers
(helm/veloshare/templates/_helpers.tpl) -- those are defined inside that
chart's own templates/ directory and Helm does not make a parent chart's
named templates visible to a chart installed on its own, only to charts
listed as its dependencies. Since this chart is meant to be
`helm install`-ed standalone for the lab, it needs its own copies of the
same handful of definitions.
*/}}

{{/*
Base name -- the chart name, overridable via .Values.nameOverride.
*/}}
{{- define "lab-pricing.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Fully qualified app name: "<release>-<chart>", or just the release name if
it already contains the chart name. Overridable via .Values.fullnameOverride.
*/}}
{{- define "lab-pricing.fullname" -}}
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
Selector labels -- the stable subset used in both the Deployment's
matchLabels and the Service's selector. Must never change across upgrades
(matchLabels is immutable on an existing Deployment).
*/}}
{{- define "lab-pricing.selectorLabels" -}}
app.kubernetes.io/name: {{ include "lab-pricing.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Common labels for every object this chart renders, including the CKAD lab
convention (app.kubernetes.io/part-of, app.kubernetes.io/component, lab).
*/}}
{{- define "lab-pricing.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{ include "lab-pricing.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: veloshare
app.kubernetes.io/component: ckad-lab
lab: "5.4"
{{- end -}}
