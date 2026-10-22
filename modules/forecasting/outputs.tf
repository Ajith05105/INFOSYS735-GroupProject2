output "run_now_trigger" {
  description = "Start this Glue trigger to run the whole forecasting chain on demand."
  value       = aws_glue_trigger.run_now.name
}

output "recommendations_table" {
  description = "DynamoDB table holding perishable stock recommendations."
  value       = aws_dynamodb_table.recommendations.name
}
