######### User-defined variables. These will be provided directly by the user in the setup process.

variable "startup_script" {
  description = "The startup shell script that will run on each app server host when it starts."
  type        = string
  default     = <<-EOF
              #!/bin/bash
              echo "Hello, World" > /var/www/html/index.html
              nohup python3 -m http.server 8080 --bind 0.0.0.0 &
              EOF
}

variable "autoscaling_minsize" {
  description = "The minimum number of servers in the group."
  type        = number
  default     = 1
}

variable "autoscaling_maxsize" {
  description = "The maximum number of servers in the group."
  type        = number
  default     = 2
}

variable "health_check_interval" {
  description = "The number of seconds between health check invocations on each app server instance."
  type        = number
  default     = 15
}

variable "health_check_timeout" {
  description = "The client-side timeout for the health check invocation."
  type        = number
  default     = 3
}

######## Resolved variables based on user input. The user's vendor agnostic specifications must be translated to vendor-specific terms.

variable "gcp_instance_type" {
  description = "The type of the machine instance to start, from the GCP catalog."
  type        = string
  default     = "e2-micro"
}

######## Vendor-specific configuration that we provide, not the user, and which may vary from one client to another.

variable "gcp_region" {
  description = "The GCP region to run instances in."
  type        = string
  default     = "us-central1"
}

variable "gcp_source_image" {
  description = "The source image identifier of the runtime to use for application instances."
  type        = string
  default     = "projects/debian-cloud/global/images/family/debian-11"
}

variable "gcp_project_id" {
  description = "The client's GCP project ID."
  type        = string
  default     = "your-gcp-project-id" # TODO populate me

######## GCP-specific configuration

provider "google" {
  region  = var.gcp_region
  project = var.gcp_project_id
}

resource "google_compute_firewall" "http" {
  name    = "terraform-example-http"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["8080", "22"]
  }

  source_ranges = ["0.0.0.0/0"]
}

resource "google_compute_instance_template" "example" {
  name_prefix   = "terraform-example-"
  machine_type  = var.gcp_instance_type
  tags          = ["http-server"]

  disk {
    source_image = var.gcp_source_image
    auto_delete  = true
  }

  network_interface {
    network = "default"
    access_config {}  # Assign external IP
  }

  metadata_startup_script = var.startup_script
}

resource "google_compute_region_instance_group_manager" "example" {
  name               = "terraform-example-group"
  region             = "us-central1"
  base_instance_name = "terraform-instance"
  instance_template  = google_compute_instance_template.example.id
  target_size        = var.autoscaling_minsize  # Minimum number of instances

  auto_healing_policies {
    health_check = google_compute_health_check.http.id
  }
}

resource "google_compute_health_check" "http" {
  name               = "terraform-health-check"
  check_interval_sec = var.health_check_interval
  timeout_sec        = var.health_check_timeout
  healthy_threshold  = 2
  unhealthy_threshold = 2

  http_health_check {
    port        = 8080
    request_path = "/"
  }
}

resource "google_compute_global_address" "default" {
  name = "terraform-example-address"
}

resource "google_compute_backend_service" "example" {
  name                  = "terraform-backend-service"
  health_checks         = [google_compute_health_check.http.self_link]
  protocol              = "HTTP"
  timeout_sec           = 10
  port_name             = "http"
  enable_cdn            = false

  backend {
    group = google_compute_region_instance_group_manager.example.instance_group
  }
}

resource "google_compute_url_map" "example" {
  name            = "terraform-example-url-map"
  default_service = google_compute_backend_service.example.id
}

resource "google_compute_target_http_proxy" "example" {
  name   = "terraform-example-proxy"
  url_map = google_compute_url_map.example.id
}

resource "google_compute_global_forwarding_rule" "example" {
  name       = "terraform-example-forwarding-rule"
  ip_address = google_compute_global_address.default.address
  ip_protocol = "TCP"
  port_range = "80"

  target = google_compute_target_http_proxy.example.self_link
}

######## Output

output "lb_ip_address" {
  value       = google_compute_global_address.default.address
  description = "The IP address of the load balancer"
}
