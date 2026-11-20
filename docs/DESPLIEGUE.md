# Proceso de despliegue de punta a punta

Este documento explica cómo se despliega el Sistema Escolar de Citas en AWS, desde el bootstrap hasta las pruebas de disponibilidad, y cómo resolver los fallos que ya se presentaron.

## Resumen del flujo

```
1. Bootstrap (local, una sola vez)          2. Pipeline GitHub Actions (cada push a main)
   terraform apply en bootstrap/                ┌─ 1. Infraestructura (terraform/)
   ├─ Proveedor OIDC de GitHub                  ├─ 2. Backend (código de Lambda)
   ├─ Rol IAM del pipeline + política           ├─ 3. Frontend (S3 + invalidación CloudFront)
   ├─ Bucket S3 del estado remoto               └─ 4. Smoke tests (frontend y API)
   └─ Tabla DynamoDB de bloqueo
            │
            └── el ARN del rol se guarda en GitHub como AWS_ROLE_ARN
```

El pipeline no usa llaves de acceso fijas. GitHub emite un token OIDC (JWT), AWS STS lo valida contra el proveedor OIDC y entrega credenciales temporales del rol `citas-escolares-github-oidc-role`.

## Requisitos previos

- AWS CLI configurado con un usuario IAM con permisos administrativos sobre IAM, S3 y DynamoDB. En este proyecto es el usuario `terraform-lab`, configurado en el perfil `default`.
- Terraform >= 1.5.0. El pipeline usa 1.7.0.
- GitHub CLI (`gh`) autenticado con permisos sobre el repositorio.

Verificación:

```bash
aws sts get-caller-identity   # debe mostrar arn:aws:iam::<ACCOUNT_ID>:user/terraform-lab
gh auth status
```

## Fase 1: Bootstrap

El bootstrap crea lo que el pipeline necesita para existir. Se ejecuta en local y se vuelve a aplicar solo cuando cambian los permisos del rol, la trust policy o el proveedor OIDC.

### Recursos que crea

| Recurso | Nombre | Propósito |
|---|---|---|
| Proveedor OIDC | `token.actions.githubusercontent.com` | Confiar en los tokens de GitHub Actions (audiencia `sts.amazonaws.com`) |
| Rol IAM | `citas-escolares-github-oidc-role` | Rol que asume el pipeline |
| Política IAM | `citas-escolares-pipeline-policy` | Permisos del pipeline sobre S3, DynamoDB, Lambda, API Gateway, Cognito, CloudFront, IAM y SES |
| Bucket S3 | `citas-escolares-tfstate-<sufijo>` | Estado remoto de `terraform/` (versionado, cifrado AES-256, sin acceso público) |
| Tabla DynamoDB | `citas-escolares-tflocks` | Bloqueo del estado para evitar ejecuciones concurrentes |

### Variables (`bootstrap/terraform.tfvars`)

```hcl
aws_region    = "us-east-1"
project_name  = "citas-escolares"
github_repo   = "llorld43-gif/agentes"
github_branch = "main"
```

### Ejecución

```bash
cd bootstrap
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

### Salidas y configuración en GitHub

```
github_actions_role_arn = "arn:aws:iam::<ACCOUNT_ID>:role/citas-escolares-github-oidc-role"
terraform_state_bucket  = "citas-escolares-tfstate-393v53"
terraform_lock_table    = "citas-escolares-tflocks"
```

1. Guarda el ARN del rol como secreto del repositorio. El workflow lee `secrets.AWS_ROLE_ARN`:
   ```bash
   gh secret set AWS_ROLE_ARN --body "arn:aws:iam::<ACCOUNT_ID>:role/citas-escolares-github-oidc-role"
   ```
2. Pon el bucket y la tabla en el bloque `backend "s3"` de [terraform/provider.tf](../terraform/provider.tf).

> **Importante:** el estado del bootstrap (`bootstrap/terraform.tfstate`) es local y está en `.gitignore`. Solo existe en la máquina donde se ejecutó. Si se pierde, habrá que importar los recursos existentes con `terraform import` antes de volver a aplicar.

## Trust policy y formato del claim `sub`

El rol solo puede asumirse con `sts:AssumeRoleWithWebIdentity` si el token de GitHub cumple dos condiciones:

```hcl
StringEquals = {
  "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
}
StringLike = {
  "token.actions.githubusercontent.com:sub" = [
    "repo:llorld43-gif/agentes:*",                         # formato clásico
    "repo:llorld43-gif@307716463/agentes@1462154844:*"     # formato inmutable
  ]
}
```

GitHub cambió el formato del claim `sub`. Los repositorios creados después del 15 de julio de 2026 reciben el **formato inmutable**, que añade los IDs numéricos del propietario y del repositorio:

```
repo:OWNER@OWNER_ID/REPO@REPO_ID:ref:refs/heads/main
```

Este repositorio se creó el 18/11/2026, así que sus tokens llegan en el formato inmutable. La trust policy acepta ambos formatos por compatibilidad.

Para obtener los IDs:

```bash
gh api repos/llorld43-gif/agentes --jq '{owner_id:.owner.id, repo_id:.id}'
```

Referencias:
- [Immutable subject claims for GitHub Actions OIDC tokens](https://github.blog/changelog/2026-04-23-immutable-subject-claims-for-github-actions-oidc-tokens)
- [OpenID Connect reference (GitHub Docs)](https://docs.github.com/en/actions/reference/security/oidc)

## Fase 2: Pipeline de despliegue

Archivo: [.github/workflows/deploy.yml](../.github/workflows/deploy.yml)

**Disparadores:** cada `push` a `main` y la ejecución manual (`workflow_dispatch`).

**Permisos del workflow:** `id-token: write` permite pedir el token OIDC y `contents: read` permite leer el código.

Cada job se autentica por su cuenta con `aws-actions/configure-aws-credentials@v4`:

```yaml
role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
aws-region: us-east-1
audience: sts.amazonaws.com
role-session-name: GitHubActions-Infra   # -Backend / -Frontend según el job
```

### Jobs

| # | Job | Qué hace |
|---|---|---|
| 1 | Infraestructura | `terraform init` y `terraform apply` en `terraform/` con el estado remoto en S3. Luego exporta como salidas del job las URLs de CloudFront y API Gateway, el bucket del frontend, el nombre de la Lambda, los IDs de Cognito y el ID de la distribución. |
| 2 | Backend | Empaqueta `backend/app.py` en un zip, ejecuta `aws lambda update-function-code` y espera a que la función quede actualizada. |
| 3 | Frontend | Genera `frontend/config.js` con la URL de la API y los IDs de Cognito, ejecuta `aws s3 sync` al bucket e invalida la caché de CloudFront (`/*`). |
| 4 | Smoke tests | Ejecuta [.github/scripts/smoke_test.py](../.github/scripts/smoke_test.py) contra la URL de CloudFront y la de API Gateway, con reintentos. |

Los jobs van en secuencia: `infrastructure → deploy-backend → deploy-frontend → verify-deployment`.

### Lanzar y seguir el pipeline manualmente

```bash
gh workflow run deploy.yml --ref main
gh run list -L 1
gh run watch <RUN_ID> --exit-status
gh run view <RUN_ID> --log-failed     # si falla
```

## Recursos de la aplicación (`terraform/`)

| Archivo | Recursos |
|---|---|
| `dynamodb.tf` | Tabla de citas con bloqueo atómico |
| `cognito.tf` | User Pool de docentes y cliente de la app |
| `lambda.tf` | Función Lambda, su rol IAM y su política |
| `api_gateway.tf` | HTTP API v2, autorizador JWT, rutas, integración y stage |
| `s3_cloudfront.tf` | Bucket del frontend, OAC y distribución CloudFront |
| `frontend_sync.tf` | Subida inicial de archivos del frontend |
| `ses.tf` | Identidad de correo para notificaciones |

## Solución de problemas

### Error en "Autenticación con AWS vía OIDC" (`Not authorized to perform sts:AssumeRoleWithWebIdentity`)

1. Comprueba que el secreto `AWS_ROLE_ARN` existe y tiene el ARN correcto: `gh secret list`.
2. Comprueba que la trust policy acepta el formato inmutable del `sub` con los IDs correctos (ver la sección anterior).
3. Comprueba que el workflow tiene `permissions: id-token: write`.
4. Comprueba que `audience` es `sts.amazonaws.com` y que el proveedor OIDC tiene ese client ID.

### Error `AccessDenied ... is not authorized to perform <acción>` durante `terraform apply`

El rol se asumió bien, pero a la política del pipeline le falta un permiso. Añade la acción en `aws_iam_policy.pipeline_policy` de [bootstrap/main.tf](../bootstrap/main.tf) y vuelve a aplicar el bootstrap en local. Después relanza el pipeline.

Caso real (20/11/2026): fallaron `iam:ListRolePolicies`, `iam:CreatePolicy` y `cloudfront:ListTagsForResource`. Se resolvió así:

- **Roles `citas-escolares-*`:** se añadieron `ListRolePolicies`, `ListAttachedRolePolicies`, `ListInstanceProfilesForRole`, `ListRoleTags`, `UntagRole` y `UpdateAssumeRolePolicy`.
- **Políticas `arn:aws:iam::*:policy/citas-escolares-*`:** un bloque nuevo con todo su ciclo de vida (`CreatePolicy`, `GetPolicy`, `GetPolicyVersion`, `ListPolicyVersions`, `CreatePolicyVersion`, `DeletePolicyVersion`, `DeletePolicy`, `TagPolicy`, `UntagPolicy`, `ListPolicyTags`).
- **CloudFront:** acciones de lectura, configuración, borrado y tags para distribuciones y OAC (`GetDistributionConfig`, `ListDistributions`, `ListTagsForResource`, `UntagResource`, `*OriginAccessControl*`, etc.).

Con esos cambios el pipeline terminó bien en sus cuatro jobs.

### Bloqueo de estado colgado

Si un job se cancela a mitad de `terraform apply`, puede quedar un lock en `citas-escolares-tflocks`. Para liberarlo:

```bash
cd terraform
terraform init
terraform force-unlock <LOCK_ID>
```

Confirma antes que no hay otra ejecución en curso.

## Lista de verificación de punta a punta

- [ ] `aws sts get-caller-identity` muestra el usuario `terraform-lab`
- [ ] `terraform apply` en `bootstrap/` sin errores
- [ ] Secreto `AWS_ROLE_ARN` configurado en GitHub
- [ ] Backend S3 configurado en `terraform/provider.tf`
- [ ] Pipeline lanzado (push a `main` o `gh workflow run deploy.yml`)
- [ ] Los cuatro jobs en ✅
- [ ] La URL de CloudFront abre la aplicación y la API responde
