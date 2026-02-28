data "aws_region" "current" {}

resource "terraform_data" "wait_for_cache_available" {
  count = var.create && var.user_group_id != null ? 1 : 0

  # Force re-creation on every apply so the waiter always runs when a
  # user group is associated.  User-group member modifications (even
  # tag-only changes) put the serverless cache into a transitional
  # state that Terraform cannot detect via value references alone.
  triggers_replace = timestamp()

  provisioner "local-exec" {
    environment = {
      AWS_DEFAULT_REGION = data.aws_region.current.id
    }
    command = <<-EOT
      MAX_WAIT=${var.cache_stabilization_max_wait}
      POLL_INTERVAL=10
      ELAPSED=0

      FALLBACK_WAIT=${var.cache_stabilization_fallback_wait}

      # Verify AWS CLI is available
      if ! command -v aws >/dev/null 2>&1; then
        if [ "$FALLBACK_WAIT" -gt 0 ]; then
          echo "WARNING: AWS CLI not found, falling back to fixed wait of $${FALLBACK_WAIT}s"
          sleep $FALLBACK_WAIT
          exit 0
        else
          echo "WARNING: AWS CLI not found and fallback wait is 0, skipping cache stabilization check"
          exit 0
        fi
      fi

      # Check if cache exists — capture both stdout and stderr
      DESCRIBE_OUTPUT=$(aws elasticache describe-serverless-caches \
        --serverless-cache-name "${var.cache_name}" 2>&1) || {
        if echo "$DESCRIBE_OUTPUT" | grep -q "ServerlessCacheNotFoundFault"; then
          echo "Cache '${var.cache_name}' not found (first apply), skipping stabilization wait"
          exit 0
        else
          echo "WARNING: Failed to describe cache: $DESCRIBE_OUTPUT"
          echo "Skipping cache stabilization check"
          exit 0
        fi
      }

      while [ $ELAPSED -lt $MAX_WAIT ]; do
        STATUS=$(aws elasticache describe-serverless-caches \
          --serverless-cache-name "${var.cache_name}" \
          --query 'ServerlessCaches[0].Status' \
          --output text 2>/dev/null || echo "UNKNOWN")

        if [ "$STATUS" = "available" ]; then
          echo "Cache '${var.cache_name}' is available (waited $${ELAPSED}s)"
          exit 0
        fi

        echo "Cache '${var.cache_name}' status: $STATUS ($${ELAPSED}s/$${MAX_WAIT}s), polling in $${POLL_INTERVAL}s..."
        sleep $POLL_INTERVAL
        ELAPSED=$((ELAPSED + POLL_INTERVAL))
      done

      echo "ERROR: Cache '${var.cache_name}' did not reach 'available' within $${MAX_WAIT}s (last status: $STATUS)"
      exit 1
    EOT
  }
}

resource "aws_elasticache_serverless_cache" "this" {
  count = var.create ? 1 : 0

  engine = var.engine
  name   = var.cache_name

  dynamic "cache_usage_limits" {
    for_each = length(var.cache_usage_limits) > 0 ? [var.cache_usage_limits] : []
    content {

      dynamic "data_storage" {
        for_each = try([cache_usage_limits.value.data_storage], [])
        content {
          maximum = try(data_storage.value.maximum, null)
          minimum = try(data_storage.value.minimum, null)
          unit    = try(data_storage.value.unit, "GB")
        }
      }

      dynamic "ecpu_per_second" {
        for_each = try([cache_usage_limits.value.ecpu_per_second], [])
        content {
          maximum = try(ecpu_per_second.value.maximum, null)
          minimum = try(ecpu_per_second.value.minimum, null)
        }
      }
    }
  }
  daily_snapshot_time      = var.daily_snapshot_time
  description              = coalesce(var.description, "Serverless Cache")
  kms_key_id               = var.kms_key_id
  major_engine_version     = var.major_engine_version
  security_group_ids       = var.security_group_ids
  snapshot_arns_to_restore = var.snapshot_arns_to_restore
  snapshot_retention_limit = var.snapshot_retention_limit
  subnet_ids               = var.subnet_ids
  user_group_id            = var.user_group_id

  timeouts {
    create = try(var.timeouts.create, "40m")
    delete = try(var.timeouts.delete, "80m")
    update = try(var.timeouts.update, "40m")
  }

  tags = var.tags

  depends_on = [terraform_data.wait_for_cache_available]
}
