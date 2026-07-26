# Runbook — Validação funcional do cluster EKS (lab)

> Estabelece o padrão de "validação funcional pós-apply" descrito em [`docs/engineering-standards.md`](../../engineering-standards.md#11-validação-funcional-pós-apply).

## Por que isso existe

`terraform apply` sem erro e `aws eks describe-cluster` mostrando `status: ACTIVE` provam que o cluster **existe com a configuração esperada** — não provam que ele **funciona**. A pergunta que importa: o control plane responde, os nodes spot ficam `Ready`, e um pod real consegue ser agendado e executar neles? Isso só se responde exercitando o cluster de verdade.

Este runbook documenta o script `terraform/envs/lab/scripts/validate-eks.sh`, que gera um kubeconfig efêmero, roda um pod de teste num namespace descartável, e sempre limpa tudo ao final — nunca fica como estado permanente no cluster.

## Como funciona

- **Kubeconfig efêmero**: gerado num arquivo temporário (`mktemp`) via `aws eks update-kubeconfig`, usando as credenciais SSO do próprio operador (`AWS_PROFILE=cloudlab`) — sem subir nenhuma instância EC2 extra só para o teste.
- **Checagens executadas:**
  1. Pelo menos um node com label `eks.amazonaws.com/capacityType=SPOT` reporta condição `Ready` (com retry de até 180s, já que o node group pode levar alguns minutos para escalar após o `apply`).
  2. Um namespace de teste (`minitube-eks-smoke-test`) é criado e um pod (`busybox`) é agendado nele.
  3. O pod atinge `Ready` dentro de 120s.
  4. O node onde o pod rodou (`spec.nodeName`) tem de fato o label `capacityType=SPOT` — confirma que o workload caiu no node group spot, não em algum node fora dele.
  5. Os logs do pod contêm a saída esperada (`hello from ...`) — prova que o container **executou de verdade**, não só que ficou `Running`.
- **Cleanup garantido:** `trap cleanup EXIT` deleta o namespace de teste e remove o kubeconfig temporário, mesmo se o script falhar ou for interrompido (`Ctrl+C`).

## Pré-requisito: roles IAM do cluster e do node

O script pressupõe que o cluster e o node group já foram aplicados com sucesso em `terraform/envs/lab/`, o que por sua vez exige que as roles IAM (`minitube-eks-cluster-role`, `minitube-eks-node-role`) já existam. Elas vivem em `terraform/bootstrap-iam/` (módulo admin-only), pelo mesmo motivo já documentado para a role do smoke test de rede — `PowerUserAccess` não permite ao operador criar nem ler recursos IAM sem a policy inline explícita.

```bash
# Sessão root/CloudShell, uma única vez (as roles persistem entre sessões, sem custo)
cd terraform/bootstrap-iam

# Antes do primeiro apply: confirmar se os service-linked roles do EKS já existem
# na conta. Se já existirem, ajustar create_eks_service_linked_roles = false
# em variables.tf antes de aplicar (o recurso falha se tentar recriá-los).
aws iam get-role --role-name AWSServiceRoleForAmazonEKS || true
aws iam get-role --role-name AWSServiceRoleForAmazonEKSNodegroup || true

terraform init
terraform plan
terraform apply
```

Verificar que as roles existem antes de aplicar `envs/lab`:

```bash
aws iam get-role --role-name minitube-eks-cluster-role --profile cloudlab
aws iam get-role --role-name minitube-eks-node-role --profile cloudlab
```

⚠️ Sem essas roles aplicadas, `terraform plan`/`apply` em `terraform/envs/lab/` falha ao resolver os `data "aws_iam_role"` em `iam-data.tf`.

## Aplicar o cluster e rodar o teste

> ⚠️ **Tudo em `terraform/envs/lab/` é efêmero por design.** Se a VPC da sessão anterior já foi destruída (fluxo normal — ver `docs/runbooks/validate/validate-vpc-network.md`), este `apply` recria a VPC **do zero**, junto com o cluster EKS, o node group e o OIDC provider — não é incremental sobre nada que já exista. Ao final do teste, **tudo isso é destruído de novo** (ver seção seguinte). O EKS cobra pelo control plane por hora, mesmo ocioso, então não deixe o cluster de pé além do tempo de teste.

```bash
cd terraform/envs/lab
AWS_PROFILE=cloudlab terraform plan     # revisar: VPC (se recriando) + cluster + node group + OIDC provider + tags nas subnets
AWS_PROFILE=cloudlab terraform apply

AWS_PROFILE=cloudlab ./scripts/validate-eks.sh
```

Dependências no seu ambiente: `aws` CLI, `jq`, `terraform`, `kubectl`.

## Destruir tudo ao final do teste

```bash
cd terraform/envs/lab
AWS_PROFILE=cloudlab terraform plan -destroy   # revisar: deve remover cluster, node group, OIDC provider, VPC — tudo
AWS_PROFILE=cloudlab terraform destroy
```

`terraform/bootstrap-iam/` **não** é destruído — as roles do EKS, a role do smoke-test de rede e o permission set do operador ficam de pé entre sessões porque não geram custo. Confirmar que não sobrou nada cobrável na conta:

```bash
aws eks list-clusters --profile cloudlab --region us-east-1
aws ec2 describe-vpcs --profile cloudlab --region us-east-1 --filters "Name=tag:Name,Values=minitube-lab"
aws ec2 describe-nat-gateways --profile cloudlab --region us-east-1 --filter "Name=state,Values=available"
```

Todos os três comandos devem retornar vazio antes de encerrar a sessão.

## Leitura esperada do output

```
PASS: control plane reachable and reports Ready spot node(s)
NAME                          STATUS   ROLES    AGE   VERSION   CAPACITYTYPE
ip-10-0-16-x.ec2.internal     Ready    <none>   5m    v1.31.x   SPOT
ip-10-0-32-x.ec2.internal     Ready    <none>   5m    v1.31.x   SPOT
PASS: smoke-test pod reached Ready
PASS: pod scheduled on spot node ip-10-0-16-x.ec2.internal
PASS: pod produced expected log output
=== All checks passed: EKS cluster is reachable and schedules real workloads on spot nodes. ===
```

Código de saída `0` quando tudo passa, `1` se qualquer checagem falhar (a mensagem de erro específica aparece antes da linha final).

## Segurança / rollback

O script sempre deleta o namespace de teste e o kubeconfig temporário via `trap`, mesmo em caso de erro. Se o script for encerrado de forma anômala (ex. `kill -9`) e o namespace sobrar:

```bash
aws eks update-kubeconfig --region us-east-1 --name minitube-lab --profile cloudlab --kubeconfig /tmp/minitube-kubeconfig
kubectl --kubeconfig /tmp/minitube-kubeconfig delete namespace minitube-eks-smoke-test
rm -f /tmp/minitube-kubeconfig
```

As roles IAM do cluster/node e o service-linked role do EKS não têm custo e não precisam ser destruídos entre sessões — persistem em `terraform/bootstrap-iam/` fora do ciclo efêmero de `envs/lab`, coerente com o critério de conclusão da Fase 1 ("destroy completo seguido de apply limpo, sem passos manuais").
