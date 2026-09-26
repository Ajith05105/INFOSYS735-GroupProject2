# Bootstrap

Creates the things CI needs before CI can run:

| Resource | Name | Purpose |
|---|---|---|
| S3 bucket | `anygroup-dev-bootstrap-tfstate-ap-southeast-6` | Holds Terraform state for every stack |
| OIDC identity provider | `token.actions.githubusercontent.com` | Lets GitHub Actions log in to AWS without stored keys |
| IAM role | `anygroup-dev-cicd-plan-role` | Read-only role for pull request plans |
| IAM role | `anygroup-dev-cicd-deploy-role` | Role for applies and destroys from `main` |

## Why it is separate

1. **Chicken and egg.** The state bucket has to exist before anything can store state in it, and the CI roles have to exist before GitHub Actions can log in. So these are created first, by hand.
2. **CI cannot change its own permissions.** If the pipeline managed its own roles, a pull request could grant it more access. Only someone with admin AWS credentials can change what CI is allowed to do.
3. **Destroying the app never touches the foundation.** A `destroy` in `envs/dev` cannot delete the state bucket or the roles.

## State bucket

- **Versioning** is on, so older state versions can be recovered.
- **Encryption** is on (SSE-S3), and all public access is blocked.
- **`prevent_destroy`** stops Terraform from deleting the bucket.
- **Locking** uses S3 native lock files (`use_lockfile = true`), so no DynamoDB table is needed.

The bucket holds one state file per Terraform project:

```
anygroup-dev-bootstrap-tfstate-ap-southeast-6/
├── bootstrap/terraform.tfstate    this folder's own state
└── envs/dev/terraform.tfstate     the dev environment
```

The CI roles can only reach `envs/*`. They cannot read or change `bootstrap/terraform.tfstate`.

## CI roles

Each role only trusts login tokens from this repository, and checks the exact event:

| Role | Who can assume it | Permissions |
|---|---|---|
| Plan | Pull request workflows | List the bucket, read `envs/*` state, `ec2:Describe*`. Read-only: it cannot write state or take the state lock. |
| Deploy | Workflows running on `main` | Read and write `envs/*` state and lock files, plus the permissions each module needs (see `iam.tf`) |

PRs from forks cannot use either role, because GitHub does not issue AWS login tokens to fork pull requests.

### The repository ID in the trust policy

`var.github_repository` is set to `Ajith05105@75721773/INFOSYS735-GroupProject2@1387092923` instead of just `Ajith05105/INFOSYS735-GroupProject2`. That is the format GitHub puts in this repository's login tokens. The numbers are the permanent IDs of the owner account and the repository. They are public, not secret.

The IDs make the trust stricter. If this repository were deleted and someone created a new one with the same name, it would get a different ID and could not assume the roles.

## Applying changes

Bootstrap is applied from a laptop by someone with admin AWS credentials. It is never applied by CI.

```sh
aws login                        # or any other way of getting admin credentials
aws sts get-caller-identity      # check you are in the right account
cd bootstrap
terraform init
terraform plan                   # read it carefully
terraform apply
```

### Adding permissions for a new module

When a new module needs AWS permissions, for example `ec2:CreateInternetGateway`:

1. Edit `iam.tf` on a branch:
   - add a statement to the **deploy** policy with the create, modify, tag and delete actions the module needs
   - add read-only actions to the **plan** policy if the plan needs to look anything up
2. Open a pull request so someone can review the new permissions.
3. After merging, the bootstrap owner runs `terraform apply` in `bootstrap/` from `main`.
4. Only then open the pull request for the module itself.

If a CI run fails with `AccessDenied`, the error names the missing action. Add that action and apply bootstrap again.

## Outputs

| Output | Used for |
|---|---|
| `state_bucket_name` | The `bucket` value in each environment's backend block |
| `github_oidc_provider_arn` | Reference only |
| `plan_role_arn` | GitHub secret `PLAN_ROLE_ARN` |
| `deploy_role_arn` | GitHub secret `DEPLOY_ROLE_ARN` |

Run `terraform output` in this folder to see the values.

## Rebuilding from scratch

Only needed if the bucket is ever lost. On a fresh account, bootstrap's state cannot start in a bucket that does not exist yet:

1. Comment out the `backend "s3"` block in `versions.tf`.
2. Run `terraform init` and `terraform apply`. State is kept locally for this first run.
3. Uncomment the backend block and run `terraform init -migrate-state`, answering `yes` to copy the local state into the bucket.
4. Delete the local `terraform.tfstate` files.
