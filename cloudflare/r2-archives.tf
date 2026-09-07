locals {
  archive_buckets = toset([
    "knot",
    "prosody",
    "tuwunel",
  ])

  # R2 Age conditions are expressed in seconds rather than calendar months.
  archive_lock_seconds   = 183 * 24 * 60 * 60
  archive_expiry_seconds = 184 * 24 * 60 * 60
}

# Each resource below owns the bucket's complete rule set. Add any other lock
# or lifecycle rules here before the first apply; an apply replaces unmanaged
# rules configured in the dashboard.
resource "cloudflare_r2_bucket_lock" "monthly_archives" {
  for_each = local.archive_buckets

  account_id  = var.account_id
  bucket_name = each.value
  rules = [{
    id      = "retain-monthly-archives-for-six-months"
    enabled = true
    prefix  = "archive/"
    condition = {
      type            = "Age"
      max_age_seconds = local.archive_lock_seconds
    }
  }]
}

resource "cloudflare_r2_bucket_lifecycle" "monthly_archives" {
  for_each = local.archive_buckets

  account_id  = var.account_id
  bucket_name = each.value
  rules = [{
    id      = "expire-unlocked-monthly-archives"
    enabled = true
    conditions = {
      prefix = "archive/"
    }
    delete_objects_transition = {
      condition = {
        type    = "Age"
        max_age = local.archive_expiry_seconds
      }
    }
  }]
}
