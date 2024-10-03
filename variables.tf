#variables.tf
variable "access_key" {
    description = "Access key to AWS console"
}
variable "secret_key" {
    description = "Secret key to AWS console"
}

variable "session_token" {
    description = "Session token to AWS console"
}

variable "region" {
    description = "AWS region"
}