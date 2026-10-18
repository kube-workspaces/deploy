{{/* One selector flag per persistent deployment mode; neither selects ephemeral. */}}
{{- define "kube-workspaces.execution.storageMode" -}}
{{- if and .Values.execution.storage.external.enabled .Values.execution.storage.bundled.enabled -}}
{{- fail "execution storage external and bundled modes are mutually exclusive" -}}
{{- end -}}
{{- if not .Values.execution.enabled -}}
{{- if or .Values.execution.storage.external.enabled .Values.execution.storage.bundled.enabled -}}
{{- fail "execution storage requires execution.enabled=true" -}}
{{- end -}}
disabled
{{- else if .Values.execution.storage.bundled.enabled -}}
bundled
{{- else if .Values.execution.storage.external.enabled -}}
external
{{- else -}}
ephemeral
{{- end -}}
{{- end -}}

{{- define "kube-workspaces.execution.validate" -}}
{{- $mode := include "kube-workspaces.execution.storageMode" . -}}
{{- if .Values.execution.qgaPilot.enabled -}}
{{- if eq $mode "disabled" -}}
{{- fail "execution.qgaPilot.enabled requires execution.enabled=true" -}}
{{- end -}}
{{- $_ := required "execution.qgaPilot.enabled requires execution.qgaPilot.signingKey.existingSecret" .Values.execution.qgaPilot.signingKey.existingSecret -}}
{{- end -}}
{{- if ne $mode "disabled" -}}
{{- if not .Values.auth.enabled -}}
{{- fail "execution requires auth.enabled=true" -}}
{{- end -}}
{{- if eq $mode "ephemeral" -}}
{{- if ne (int .Values.replicaCount) 1 -}}
{{- fail "ephemeral execution storage requires replicaCount=1; use persistent storage for multiple API replicas" -}}
{{- end -}}
{{- else -}}
{{- $_ := required "persistent execution recording requires execution.storage.encryption.existingSecret" .Values.execution.storage.encryption.existingSecret -}}
{{- $_ := required "persistent execution recording requires an encryption Secret key" .Values.execution.storage.encryption.key -}}
{{- $_ := required "persistent execution recording requires an S3 bucket" .Values.execution.storage.s3.bucket -}}
{{- if eq $mode "bundled" -}}
{{- $_ := required "bundled execution storage requires postgresql.auth.existingSecret" .Values.postgresql.auth.existingSecret -}}
{{- $_ := required "bundled execution storage requires postgresql.customUser.existingSecret (non-superuser app credentials)" .Values.postgresql.customUser.existingSecret -}}
{{- $_ := required "bundled execution storage requires rustfs.secret.existingSecret" .Values.rustfs.secret.existingSecret -}}
{{- if not .Values.postgresql.persistence.enabled -}}
{{- fail "bundled execution storage requires PostgreSQL persistence; use ephemeral mode for no persistent storage" -}}
{{- end -}}
{{- if not .Values.execution.storage.allowInsecureTransport -}}
{{- fail "the bundled test storage profile uses internal PostgreSQL/TCP and S3/HTTP: set execution.storage.allowInsecureTransport=true, or use external TLS endpoints" -}}
{{- end -}}
{{- else -}}
{{- $_ := required "external execution storage requires execution.storage.external.postgresql.existingSecret" .Values.execution.storage.external.postgresql.existingSecret -}}
{{- $_ := required "external execution storage requires execution.storage.s3.existingSecret" .Values.execution.storage.s3.existingSecret -}}
{{- $endpoint := required "external execution storage requires execution.storage.s3.endpoint" .Values.execution.storage.s3.endpoint -}}
{{- if not (or (hasPrefix "https://" $endpoint) (and .Values.execution.storage.allowInsecureTransport (hasPrefix "http://" $endpoint))) -}}
{{- fail "external execution S3 endpoint must use HTTPS, or explicitly opt into insecure transport" -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "kube-workspaces.execution.env" -}}
{{- $mode := include "kube-workspaces.execution.storageMode" . -}}
{{- if ne $mode "disabled" }}
- name: KW_EXECUTION_STORAGE_MODE
  value: {{ $mode | quote }}
- name: KW_EXECUTION_RETENTION_RECORDINGS
  value: {{ .Values.execution.storage.retention.recordings | quote }}
- name: KW_EXECUTION_RETENTION_METADATA
  value: {{ .Values.execution.storage.retention.metadata | quote }}
{{- if eq $mode "ephemeral" }}
- name: KW_EXECUTION_EPHEMERAL_DIR
  value: /var/run/kube-workspaces/execution
- name: KW_EXECUTION_EPHEMERAL_MAX_BYTES
  value: {{ .Values.execution.storage.ephemeral.maxBytes | quote }}
{{- else }}
- name: KW_EXECUTION_RECORDING_KEY_FILE
  value: /etc/kube-workspaces/execution-recording/key
- name: KW_EXECUTION_ALLOW_INSECURE_STORAGE_TRANSPORT
  value: {{ .Values.execution.storage.allowInsecureTransport | quote }}
- name: KW_EXECUTION_S3_BUCKET
  value: {{ .Values.execution.storage.s3.bucket | quote }}
- name: KW_EXECUTION_S3_REGION
  value: {{ .Values.execution.storage.s3.region | quote }}
- name: KW_EXECUTION_S3_FORCE_PATH_STYLE
  value: {{ .Values.execution.storage.s3.forcePathStyle | quote }}
{{- if .Values.execution.storage.s3.caSecret }}
- name: KW_EXECUTION_S3_CA_FILE
  value: /etc/kube-workspaces/execution-storage-ca/ca.crt
{{- end }}
{{- if eq $mode "bundled" }}
{{- $pg := index .Subcharts "postgresql" }}
{{- $s3 := index .Subcharts "rustfs" }}
- name: KW_EXECUTION_PG_HOST
  value: {{ printf "%s.%s.svc" (include "postgres.fullname" $pg) .Release.Namespace | quote }}
- name: KW_EXECUTION_PG_PORT
  value: {{ .Values.postgresql.service.port | quote }}
- name: KW_EXECUTION_PG_DATABASE
  {{- if .Values.postgresql.customUser.secretKeys.database }}
  valueFrom:
    secretKeyRef:
      name: {{ tpl .Values.postgresql.customUser.existingSecret $ | quote }}
      key: {{ .Values.postgresql.customUser.secretKeys.database | quote }}
  {{- else }}
  value: {{ .Values.postgresql.customUser.database | quote }}
  {{- end }}
- name: KW_EXECUTION_PG_USER
  {{- if .Values.postgresql.customUser.secretKeys.name }}
  valueFrom:
    secretKeyRef:
      name: {{ tpl .Values.postgresql.customUser.existingSecret $ | quote }}
      key: {{ .Values.postgresql.customUser.secretKeys.name | quote }}
  {{- else }}
  value: {{ .Values.postgresql.customUser.name | quote }}
  {{- end }}
- name: KW_EXECUTION_PG_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ tpl .Values.postgresql.customUser.existingSecret $ | quote }}
      key: {{ .Values.postgresql.customUser.secretKeys.password | quote }}
- name: KW_EXECUTION_S3_ENDPOINT
  value: {{ printf "http://%s-svc.%s.svc:%v" (include "rustfs.fullname" $s3) .Release.Namespace .Values.rustfs.service.endpoint.port | quote }}
- name: KW_EXECUTION_S3_ACCESS_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.rustfs.secret.existingSecret | quote }}
      key: RUSTFS_ACCESS_KEY
- name: KW_EXECUTION_S3_SECRET_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.rustfs.secret.existingSecret | quote }}
      key: RUSTFS_SECRET_KEY
- name: KW_EXECUTION_S3_CREATE_BUCKET
  value: "true"
{{- else }}
- name: KW_EXECUTION_DATABASE_URL
  valueFrom:
    secretKeyRef:
      name: {{ .Values.execution.storage.external.postgresql.existingSecret | quote }}
      key: {{ .Values.execution.storage.external.postgresql.urlKey | quote }}
- name: KW_EXECUTION_S3_ENDPOINT
  value: {{ .Values.execution.storage.s3.endpoint | quote }}
- name: KW_EXECUTION_S3_ACCESS_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.execution.storage.s3.existingSecret | quote }}
      key: {{ .Values.execution.storage.s3.accessKeyKey | quote }}
- name: KW_EXECUTION_S3_SECRET_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.execution.storage.s3.existingSecret | quote }}
      key: {{ .Values.execution.storage.s3.secretKeyKey | quote }}
- name: KW_EXECUTION_S3_CREATE_BUCKET
  value: "false"
{{- end }}
{{- end }}
{{- end }}
{{- end -}}
