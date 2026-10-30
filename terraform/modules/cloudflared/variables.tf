variable "credentials_json" {
  description = "credentials.json for cloudflared (credentials-file mode)."
  type        = string
  sensitive   = true
}
