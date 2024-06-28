variable "function_name" {
  description = "function name"
  type        = string
  default     = "lambda_container"
}

variable "region" {
  description = "Region in which AWS Resource will be created"
  type        = string
  default     = "eu-west-1"
}

variable "repository_name" {
  description = "Name of the repo"
  type        = string
  default     = "lambda_bash_container"
}

