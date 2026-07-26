# Runbook — Validação funcional do ArgoCD e do fluxo GitOps

> Estabelece o padrão de "validação funcional pós-apply" descrito em [`docs/engineering-standards.md`](../engineering-standards.md#11-validação-funcional-pós-apply). Ver também [`docs/adr/007-argocd-gitops-bootstrap.md`](../adr/007-argocd-gitops-bootstrap.md).

## Por que isso existe

`helm_release.argocd` sem erro e os pods `Running` no namespace `argocd` provam que o ArgoCD **existe** — não provam que ele está de fato reconciliando `gitops/` a partir do Git. A pergunta que importa: se alguém divergir o cluster manualmente (drift), o ArgoCD corrige sozinho, sem qualquer `kubectl apply`? Essa é a prova real dos princípios OpenGitOps de "aplicado por pull" e "reconciliado continuamente".

Este runbook documenta `terraform/envs/lab/scripts/validate-argocd.sh`, que confirma os componentes do ArgoCD, o status `Synced`/`Healthy` das duas Applications raiz, que a API responde de verdade, e — a checagem central — que um drift manual introduzido no cluster é revertido sozinho pelo `selfHeal`.

## Pré-requisitos

### 1. Deploy key SSH somente-leitura para o ArgoCD ler o repositório privado

O repositório `alisson92/minitube` é privado — o ArgoCD precisa de credencial própria (não herda sua chave SSH local). **Desde a Fase 4 (ADR 008), este é um setup único** — a chave privada persiste em `aws_ssm_parameter.argocd_repo_ssh_private_key` (`terraform/bootstrap/ssm.tf`), lida por `envs/lab` via `data source` em toda sessão, sem precisar ser regenerada ou reexportada a cada `apply`. Só repita os passos abaixo se o parâmetro SSM ainda não existir (primeiro setup do projeto) ou se a chave precisar ser rotacionada por algum motivo.

```bash
# 1. Gerar o par de chaves fora do repositório (usar um diretório temporário)
ssh-keygen -t ed25519 -C "argocd-minitube-readonly" -f /tmp/argocd-minitube-deploy-key -N ""

# 2. Cadastrar a chave PÚBLICA como Deploy Key somente-leitura
#    (sem --allow-write ⇒ read-only por padrão)
gh repo deploy-key add /tmp/argocd-minitube-deploy-key.pub \
  --repo alisson92/minitube \
  --title "argocd-minitube-readonly"

# 3. Gravar a chave PRIVADA no SSM Parameter Store, via um único apply de
#    terraform/bootstrap/ (nunca em .tfvars, nunca commitada) -- depois
#    deste apply, lifecycle.ignore_changes garante que ela nunca mais
#    precisa ser passada de novo
cd terraform/bootstrap
AWS_PROFILE=cloudlab terraform apply \
  -var argocd_repo_ssh_private_key="$(cat /tmp/argocd-minitube-deploy-key)"

rm -f /tmp/argocd-minitube-deploy-key /tmp/argocd-minitube-deploy-key.pub
```

⚠️ Se o parâmetro SSM ainda não existir e você rodar `terraform apply` em `envs/lab` sem antes ter feito o passo 3 acima em `bootstrap/`, o `data "aws_ssm_parameter"` em `envs/lab/argocd.tf` falha com "parameter not found" — a ordem importa, `bootstrap/` primeiro.

### 2. VPC + EKS + bucket S3 + IRSA + acesso ao cluster (mesmo pré-requisito das fases anteriores)

Ver [`docs/runbooks/validate-eks-cluster.md`](./validate-eks-cluster.md) e [`docs/runbooks/validate-transcoding.md`](./validate-transcoding.md) — nada muda aqui, o ArgoCD só é adicionado ao mesmo `terraform apply` de `envs/lab`.

## Aplicar o ArgoCD e rodar o teste

```bash
cd terraform/envs/lab
terraform init -upgrade     # baixa os providers kubernetes/helm novos (versions.tf)
AWS_PROFILE=cloudlab terraform validate
AWS_PROFILE=cloudlab terraform plan     # revisar: (VPC+EKS se recriando) + namespace argocd + secret de repo + 2 helm_release + output novo
AWS_PROFILE=cloudlab terraform apply

AWS_PROFILE=cloudlab ./scripts/validate-argocd.sh
```

Dependências no seu ambiente: `aws` CLI, `jq`, `terraform`, `kubectl`, `curl`, `gh`.

⚠️ **Se o `apply` falhar no `helm_release.argocd` com erro de conexão** (`connection refused` / `context deadline exceeded`) **logo depois de criar um cluster totalmente novo**: é um sintoma conhecido de o control plane ainda não estar 100% pronto para os providers `kubernetes`/`helm` no mesmo apply em que o cluster nasceu. Como este projeto recria o cluster do zero em toda sessão, esse é o cenário mais comum, não a exceção. Fallback com `-target` em duas etapas:

```bash
AWS_PROFILE=cloudlab terraform apply \
  -target=aws_eks_cluster.lab \
  -target=aws_eks_node_group.lab_spot \
  -target=aws_iam_openid_connect_provider.lab

AWS_PROFILE=cloudlab terraform plan     # deve mostrar só o restante: S3, IRSA, namespace argocd, helm_releases
AWS_PROFILE=cloudlab terraform apply
```

## Como acessar a UI do ArgoCD

Sem Ingress/DNS/TLS ainda (chegam na Fase 4) — acesso só via port-forward:

```bash
aws eks update-kubeconfig --region us-east-1 --name minitube-lab --profile cloudlab
kubectl -n argocd port-forward svc/argocd-server 8080:443
# abrir https://localhost:8080 — certificado self-signed do chart, aceitar o aviso do navegador
```

Usuário `admin`, senha inicial:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

## Como funciona o script de validação

- **Kubeconfig efêmero**: gerado via `aws eks update-kubeconfig` num arquivo temporário, sem escrever no `~/.kube/config` do operador.
- **Checagens executadas:**
  1. `argocd-server` e `argocd-repo-server` atingem `Available`; `argocd-application-controller` tem pelo menos 1 réplica `Ready`.
  2. As duas Applications raiz (`app`, `platform`) atingem `Synced` — `app` também precisa de `Healthy`; `platform` aceita health vazio, já que sincroniza 0 recursos nesta fase (ver `gitops/platform/README.md`).
  3. `Deployment/api` existe, carrega a annotation `argocd.argoproj.io/tracking-id` (prova de que foi o ArgoCD que criou o recurso, não um `kubectl apply` manual rodado à parte), e a API responde `/api/healthz` via port-forward.
  4. **Checagem central — drift e selfHeal:** o script roda `kubectl scale deployment/api --replicas=2` (uma divergência manual proposital, nunca feita via Git) e faz *poll* até o ArgoCD reverter sozinho para `replicas: 1` (o que `gitops/app/deployment.yaml` declara), com timeout de 120s.
- **Cleanup garantido:** `trap cleanup EXIT` mata o `port-forward` e, se o teste de drift tiver sido iniciado mas não confirmado revertido, força o `scale --replicas=1` de volta antes de sair — o cluster nunca fica divergido do Git por causa do próprio teste.

## Leitura esperada do output

```
PASS: argocd-application-controller has at least 1 ready replica
PASS: Application 'app' reaches Synced+Healthy (up to 180s)
PASS: Application 'platform' reaches Synced (up to 180s; empty health accepted, 0 resources)
PASS: deployment/api carries an ArgoCD tracking-id annotation (proves ArgoCD created it, not a manual kubectl apply)
PASS: API is reachable and healthy via port-forward
Baseline: deployment/api replicas=1 (gitops/app/deployment.yaml declares replicas: 1)
Introducing manual drift: scaling deployment/api to 2 replicas (never via GitOps)...
  [  5s] spec.replicas=2 status.readyReplicas=2
  [ 10s] spec.replicas=1 status.readyReplicas=1
PASS: ArgoCD selfHeal reverted the drift back to 1 replica in ~10s, with no manual intervention
=== All checks passed: ArgoCD is installed, both root Applications are synced from Git, and selfHeal reconciles drift without any kubectl apply. ===
```

Código de saída `0` quando tudo passa, `1` se qualquer checagem falhar. O tempo exato de reversão do drift varia com o intervalo de reconciliação do ArgoCD (por padrão, poucos segundos a até ~3 minutos).

## Destruir tudo ao final do teste

```bash
cd terraform/envs/lab
AWS_PROFILE=cloudlab terraform plan -destroy   # revisar: remove ArgoCD e as Applications junto com VPC/EKS/S3/IRSA — tudo
AWS_PROFILE=cloudlab terraform destroy
```

`terraform/bootstrap/` (ECR) e `terraform/bootstrap-iam/` (roles, permission set, budget alert) **não** são destruídos — persistem entre sessões, sem custo relevante. Confirmar que não sobrou nada cobrável:

```bash
aws eks list-clusters --profile cloudlab --region us-east-1
aws ec2 describe-vpcs --profile cloudlab --region us-east-1 --filters "Name=tag:Name,Values=minitube-lab"
aws ec2 describe-nat-gateways --profile cloudlab --region us-east-1 --filter "Name=state,Values=available"
```

A deploy key cadastrada no GitHub (`argocd-minitube-readonly`) também não precisa ser removida entre sessões — é somente-leitura e escopada a este repo; remover é opcional (`gh repo deploy-key delete <id> --repo alisson92/minitube`), mas não é uma preocupação de custo ou segurança que justifique automação agora.

## Segurança / rollback

Se o script for interrompido de forma anômala (`kill -9`) no meio da checagem de drift e o `trap` não rodar, reverter manualmente:

```bash
aws eks update-kubeconfig --region us-east-1 --name minitube-lab --profile cloudlab --kubeconfig /tmp/minitube-kubeconfig
kubectl --kubeconfig /tmp/minitube-kubeconfig -n minitube-app scale deployment/api --replicas=1
rm -f /tmp/minitube-kubeconfig
```

Isso é inofensivo mesmo se rodado sem necessidade — o ArgoCD já teria revertido o drift por conta própria; o comando só adianta a correção.
