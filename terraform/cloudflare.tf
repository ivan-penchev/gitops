# ---------------------------------------------------------------------------
# Cloudflare DNS — now managed by external-dns (in-cluster), NOT Terraform.
#
# App DNS records are created automatically from Ingress hosts by the two
# external-dns instances in
# kubernetes/infrastructure/controllers/external-dns.yaml:
#   * <app>.17072021.xyz          -> proxied CNAME to the cluster tunnel
#   * <app>.int.home.17072021.xyz -> grey A record to the ingress LB IP
#
# The previously Terraform-managed records (whoami CNAME + *.int.home wildcard
# A) were removed so external-dns can create and own fresh copies (external-dns
# will not adopt pre-existing records that lack its TXT owner marker).
#
# The provider block is retained (dormant) so the Cloudflare token env stays
# wired for any future one-off record Terraform might need. It authenticates
# from CLOUDFLARE_API_TOKEN in the environment.
# ---------------------------------------------------------------------------

provider "cloudflare" {
  # api_token comes from CLOUDFLARE_API_TOKEN in the environment.
}
