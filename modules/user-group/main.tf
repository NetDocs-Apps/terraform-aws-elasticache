locals {
  tags = merge(var.tags, { terraform-aws-modules = "elasticache" })
}

################################################################################
# Group
################################################################################

resource "aws_elasticache_user_group" "this" {
  count = var.create && var.create_group ? 1 : 0

  engine        = var.engine
  user_group_id = var.user_group_id
  tags          = local.tags
  user_ids      = var.create_default_user ? [aws_elasticache_user.default[0].user_id] : [var.default_user_id]

  lifecycle {
    ignore_changes = [user_ids]
  }
}

resource "aws_elasticache_user" "default" {
  count = var.create && var.create_default_user ? 1 : 0

  access_string = try(var.default_user.access_string, "on ~* +@read")

  dynamic "authentication_mode" {
    for_each = try([var.default_user.authentication_mode], [])

    content {
      passwords = try(authentication_mode.value.passwords, null)
      # AWS returns "no-password-required" but accepts "no-password" as input.
      # Normalize to avoid perpetual drift.
      type = authentication_mode.value.type == "no-password" ? "no-password-required" : authentication_mode.value.type
    }
  }

  engine               = try(var.default_user.engine, "REDIS")
  no_password_required = try(var.default_user.no_password_required, null)
  passwords            = try(var.default_user.passwords, null)
  user_id              = var.default_user.user_id
  user_name            = "default"

  tags = local.tags

  timeouts {
    create = var.user_timeouts.create
    update = var.user_timeouts.update
    delete = var.user_timeouts.delete
  }
}

################################################################################
# User(s)
################################################################################

resource "aws_elasticache_user" "this" {
  for_each = { for k, v in var.users : k => v if var.create }

  access_string = each.value.access_string

  dynamic "authentication_mode" {
    for_each = try([each.value.authentication_mode], [])

    content {
      passwords = try(authentication_mode.value.passwords, null)
      # AWS returns "no-password-required" but accepts "no-password" as input.
      # Normalize to avoid perpetual drift.
      type = authentication_mode.value.type == "no-password" ? "no-password-required" : authentication_mode.value.type
    }
  }

  engine               = try(each.value.engine, "REDIS")
  no_password_required = try(each.value.no_password_required, null)
  passwords            = try(each.value.passwords, null)
  user_id              = try(each.value.user_id, each.key)
  user_name            = try(each.value.user_name, each.key)

  tags = merge(local.tags, try(each.value.tags, {}))

  timeouts {
    create = var.user_timeouts.create
    update = var.user_timeouts.update
    delete = var.user_timeouts.delete
  }

  depends_on = [aws_elasticache_user.default]
}

resource "aws_elasticache_user_group_association" "this" {
  for_each = { for k, v in var.users : k => v if var.create }

  user_group_id = var.create && var.create_group ? aws_elasticache_user_group.this[0].user_group_id : each.value.user_group_id
  user_id       = aws_elasticache_user.this[each.key].user_id

  dynamic "timeouts" {
    for_each = try([each.value.timeouts], [])
    content {
      create = try(timeouts.value.create, null)
      delete = try(timeouts.value.delete, null)
    }
  }

  depends_on = [aws_elasticache_user.this, aws_elasticache_user.default]
}

################################################################################
# Stabilization
################################################################################

data "aws_region" "current" {}

resource "terraform_data" "wait_for_user_group_ready" {
  count = var.create && var.create_group ? 1 : 0

  # Force re-creation on every apply so downstream consumers always
  # wait for user-group stabilization after any member modification.
  triggers_replace = timestamp()

  provisioner "local-exec" {
    environment = {
      AWS_DEFAULT_REGION = data.aws_region.current.id
    }
    command = <<-EOT
      MAX_WAIT=${var.stabilization_max_wait}
      POLL_INTERVAL=10
      ELAPSED=0

      # Verify AWS CLI is available
      if ! command -v aws >/dev/null 2>&1; then
        echo "WARNING: AWS CLI not found, skipping user group stabilization check"
        exit 0
      fi

      # Check if user group exists — capture both stdout and stderr
      DESCRIBE_OUTPUT=$(aws elasticache describe-user-groups \
        --user-group-id "${var.user_group_id}" 2>&1) || {
        if echo "$DESCRIBE_OUTPUT" | grep -q "UserGroupNotFound"; then
          echo "User group '${var.user_group_id}' not found (first apply), skipping stabilization wait"
          exit 0
        else
          echo "WARNING: Failed to describe user group: $DESCRIBE_OUTPUT"
          echo "Skipping user group stabilization check"
          exit 0
        fi
      }

      while [ $ELAPSED -lt $MAX_WAIT ]; do
        STATUS=$(aws elasticache describe-user-groups \
          --user-group-id "${var.user_group_id}" \
          --query 'UserGroups[0].Status' \
          --output text 2>/dev/null || echo "UNKNOWN")

        if [ "$STATUS" = "active" ]; then
          echo "User group '${var.user_group_id}' is active (waited $${ELAPSED}s)"
          exit 0
        fi

        echo "User group '${var.user_group_id}' status: $STATUS ($${ELAPSED}s/$${MAX_WAIT}s), polling in $${POLL_INTERVAL}s..."
        sleep $POLL_INTERVAL
        ELAPSED=$((ELAPSED + POLL_INTERVAL))
      done

      echo "ERROR: User group '${var.user_group_id}' did not reach 'active' within $${MAX_WAIT}s (last status: $STATUS)"
      exit 1
    EOT
  }

  depends_on = [
    aws_elasticache_user_group.this,
    aws_elasticache_user.default,
    aws_elasticache_user.this,
    aws_elasticache_user_group_association.this,
  ]
}
