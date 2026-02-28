variable "create" {
  description = "Determines whether resources will be created (affects all resources)"
  type        = bool
  default     = true
}

variable "tags" {
  description = "A map of tags to add to all resources"
  type        = map(string)
  default     = {}
}

################################################################################
# Group
################################################################################

variable "create_group" {
  description = "Determines whether a user group will be created"
  type        = bool
  default     = true
}

variable "engine" {
  description = "The current supported value is `REDIS`"
  type        = string
  default     = "redis"
}

variable "user_group_id" {
  description = "The ID of the user group"
  type        = string
  default     = ""
}

################################################################################
# User(s)
################################################################################

variable "users" {
  description = "A map of users to create"
  type        = any
  default     = {}
}

variable "create_default_user" {
  description = "Determines whether a default user will be created"
  type        = bool
  default     = true
}

variable "default_user" {
  description = "A map of default user attributes"
  type        = any
  default     = {}
}

variable "default_user_id" {
  description = "The ID of the default user"
  type        = string
  default     = "default"
}


################################################################################
# Timeouts & Stabilization
################################################################################

variable "user_timeouts" {
  description = "Configurable timeouts for ElastiCache user create, update, and delete operations"
  type = object({
    create = optional(string, "10m")
    update = optional(string, "10m")
    delete = optional(string, "10m")
  })
  default = {
    create = "10m"
    update = "10m"
    delete = "10m"
  }
}

variable "stabilization_max_wait" {
  description = "Maximum time in seconds to wait for the user group to reach 'active' status after modifications. When AWS CLI is available, polls user group status actively. When AWS CLI is unavailable, falls back to a fixed sleep of `stabilization_fallback_wait` seconds. Set to 0 to disable."
  type        = number
  default     = 600
}

variable "stabilization_fallback_wait" {
  description = "Fixed wait time in seconds when AWS CLI is not available. Used as a fallback for user group stabilization. Set to 0 to skip waiting when CLI is unavailable (not recommended)."
  type        = number
  default     = 300
}
