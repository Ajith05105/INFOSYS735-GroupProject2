output "glue_job_name" {
  description = "Run this job to start the whole forecasting chain on demand."
  value       = aws_glue_job.extract.name
}

output "recommendations_table" {
  description = "DynamoDB table holding perishable stock recommendations."
  value       = aws_dynamodb_table.recommendations.name
}
