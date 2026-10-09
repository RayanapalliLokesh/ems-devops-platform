# HTTPS entry point. Browsers and phones upgrade links to https://, and the ALB has no certificate: a trusted
# certificate (ACM) needs a domain we own. An API Gateway HTTP API gives a free https://<id>.execute-api... URL
# with a valid certificate and proxies every request to the ALB. With a domain: ACM certificate + a 443 listener.
resource "aws_apigatewayv2_api" "https" {
  name          = "${local.name}-https"
  protocol_type = "HTTP"
  description   = "HTTPS front door for the EMS load balancer"
}

resource "aws_apigatewayv2_integration" "root" {
  api_id               = aws_apigatewayv2_api.https.id
  integration_type     = "HTTP_PROXY"
  integration_method   = "ANY"
  integration_uri      = "http://${module.load_balancer.dns_name}/"
  timeout_milliseconds = 29000
}

resource "aws_apigatewayv2_integration" "proxy" {
  api_id               = aws_apigatewayv2_api.https.id
  integration_type     = "HTTP_PROXY"
  integration_method   = "ANY"
  integration_uri      = "http://${module.load_balancer.dns_name}/{proxy}"
  timeout_milliseconds = 29000
}

resource "aws_apigatewayv2_route" "root" {
  api_id    = aws_apigatewayv2_api.https.id
  route_key = "ANY /"
  target    = "integrations/${aws_apigatewayv2_integration.root.id}"
}

resource "aws_apigatewayv2_route" "proxy" {
  api_id    = aws_apigatewayv2_api.https.id
  route_key = "ANY /{proxy+}"
  target    = "integrations/${aws_apigatewayv2_integration.proxy.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.https.id
  name        = "$default"
  auto_deploy = true
  default_route_settings {
    throttling_burst_limit = 50
    throttling_rate_limit  = 20
  }
}

output "https_url" {
  description = "Open this in a browser or on a phone"
  value       = aws_apigatewayv2_api.https.api_endpoint
}
