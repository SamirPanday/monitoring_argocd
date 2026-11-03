{{- define "tenant.name" -}}
{{- required "tenant.id is required" .Values.id | lower | replace "_" "-" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "tenant.labels" -}}
app.kubernetes.io/managed-by: Helm
monitoring.example.com/tenant: {{ include "tenant.name" . | quote }}
{{- end -}}

