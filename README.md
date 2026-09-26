# INFOSYS735 Group Project 2: AnyGroupLLC on AWS

Terraform for the AnyGroupLLC AWS environment. All infrastructure is defined as code and deployed through GitHub Actions, which logs in to AWS with OIDC. There are no stored AWS keys anywhere.

- **Region:** `ap-southeast-6` (Auckland)
- **Terraform:** `~> 1.16`, AWS provider `~> 6.66`
- **State:** S3 with native locking, in the bucket created by [`bootstrap/`](bootstrap/README.md)

## Architecture

The target design is a three-tier web application across two Availability Zones:

```
Internet
   |
Web ALB (public subnets)
   |
Web tier (private web subnets)
   |
App ALB (private app subnets)
   |
App tier (private app subnets)
   |
RDS primary + read replica, ElastiCache (private data subnets)
```

A NAT instance in a public subnet gives the private tiers outbound internet access. Instances are managed through SSM Session Manager, so there is no SSH access.

| Component | Status |
|---|---|
| Bootstrap (state bucket, OIDC, CI roles) | Done |
| CI/CD pipeline | Done |
| Network: VPC and subnets | Done |
| Internet gateway, route tables, NAT instance | To do |
| Security groups | To do |
| Web tier | To do |
| App tier | To do |
| Data tier (RDS, ElastiCache) | To do |

## Repository layout

```
.
├── bootstrap/              State bucket, GitHub OIDC provider, CI roles. Applied by hand.
├── envs/
│   └── dev/                The dev environment. Calls the modules. Run by CI.
├── modules/
│   └── network/            VPC and subnets
└── .github/workflows/
    ├── plan.yml            Runs on every pull request
    └── deploy.yml          Runs manually from main
```

- **`bootstrap/`** is a separate Terraform project with its own state. It creates what CI needs before CI can run. See [bootstrap/README.md](bootstrap/README.md).
- **`modules/`** holds reusable building blocks. Terraform never runs inside a module directly.
- **`envs/dev/`** is where Terraform runs. Its `main.tf` calls each module and passes values between them, for example `module.network.vpc_id`. A future `envs/prod/` would call the same modules with different values.

Each module has its own README, for example [modules/network/README.md](modules/network/README.md).

## How changes get deployed

```
branch -> pull request -> "Plan (dev)" check -> 1 approval -> merge -> manual deploy
```

1. **Open a pull request to `main`.** The **Terraform Plan** workflow runs `fmt -check`, `init`, `validate` and `plan` against `envs/dev`, using a read-only AWS role. Read the plan output in the check's log before approving.
2. **Merge.** `main` is protected: merging needs the `Plan (dev)` check to pass and one approval. Nobody can push to `main` directly.
3. **Deploy by hand.** Go to **Actions > Terraform Deploy > Run workflow**, keep the branch as `main`, and pick an action:

   | Action | What it does |
   |---|---|
   | `plan` | Shows what would change. Changes nothing. |
   | `apply` | Makes a plan and applies exactly that plan. |
   | `destroy` | Deletes everything in `envs/dev`. Only runs if you type `destroy` in the confirm box. |

Merging never changes AWS on its own. Someone has to decide to run `apply`.

Only one workflow run touches the dev state at a time. Both workflows share the `terraform-dev` concurrency group, so a second run waits instead of colliding.

### GitHub configuration

Set under **Settings > Secrets and variables > Actions**:

| Name | Type | Value |
|---|---|---|
| `TERRAFORM_VERSION` | Variable | `1.16.4` |
| `AWS_REGION` | Secret | `ap-southeast-6` |
| `PLAN_ROLE_ARN` | Secret | `plan_role_arn` output from `bootstrap/` |
| `DEPLOY_ROLE_ARN` | Secret | `deploy_role_arn` output from `bootstrap/` |

## Working locally

You can check your code without any AWS access:

```sh
terraform fmt -recursive              # from the repo root, fixes formatting
cd envs/dev
terraform init -backend=false         # downloads providers, skips the S3 backend
terraform validate
```

Running `terraform plan` locally needs your own AWS credentials. **Do not run `apply` or `destroy` in `envs/dev` locally.** Those go through the Deploy workflow. The only thing applied from a laptop is `bootstrap/`.

## Adding a module

1. **Create the module.** Add `modules/<name>/` with `main.tf`, `variables.tf` and `outputs.tf`. Give every variable a `type` and `description`, and output anything other modules will need.
2. **Call it** from `envs/dev/main.tf`, passing in outputs from other modules, for example `vpc_id = module.network.vpc_id`.
3. **Add the AWS permissions it needs** to the deploy role (and read permissions to the plan role) in `bootstrap/iam.tf`. These have to be applied by hand **before** your pull request, or CI fails with `AccessDenied`. See [bootstrap/README.md](bootstrap/README.md#adding-permissions-for-a-new-module).
4. **Open a pull request** and check the plan output.
5. **Write a README** for the module.

## Conventions

- **Naming:** `anygroup-<env>-<tier>-<resource>`, for example `anygroup-dev-web-subnet-a`.
- **Tags:** every resource gets `Project`, `Owner`, `Environment` and `ManagedBy` automatically through the provider's `default_tags`. Only add a `Name` tag, plus any extra tags you need.
- **Lock files:** commit `.terraform.lock.hcl`. Never commit `.terraform/`, state files, plan files or `*.tfvars`.
- **Secrets:** none in code. RDS will generate and store its own master password.
- **Formatting:** run `terraform fmt -recursive` before pushing. CI fails on unformatted code.

## Cost

This runs on an account with limited credits. Destroy `envs/dev` with the Deploy workflow when nobody is using it, and apply it again when needed. The bootstrap resources (one small S3 bucket and IAM roles) cost close to nothing and stay up.
