{{/*
Expand the name of the wrapper chart.
*/}}
{{- define "pvc-rancher.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "pvc-rancher.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Determine the target namespace for managed resources.
Falls back to local-path-provisioner.namespaceOverride and then .Release.Namespace.
*/}}
{{- define "pvc-rancher.namespace" -}}
{{- $subchartNs := "" -}}
{{- if hasKey .Values "local-path-provisioner" -}}
{{- $subchart := index .Values "local-path-provisioner" -}}
{{- if and $subchart (hasKey $subchart "namespaceOverride") -}}
{{- $subchartNs = index $subchart "namespaceOverride" -}}
{{- end -}}
{{- end -}}
{{- if .Values.namespace.name -}}
{{- .Values.namespace.name -}}
{{- else if $subchartNs -}}
{{- $subchartNs -}}
{{- else -}}
{{- .Release.Namespace -}}
{{- end -}}
{{- end -}}

{{/*
Common labels for wrapper chart resources.
*/}}
{{- define "pvc-rancher.labels" -}}
app.kubernetes.io/name: {{ include "pvc-rancher.name" . }}
helm.sh/chart: {{ include "pvc-rancher.chart" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}
