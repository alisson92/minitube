# Runbook — Validação funcional da rede da VPC (lab)

> Estabelece o padrão de "validação funcional pós-apply" descrito em [`docs/engineering-standards.md`](../../engineering-standards.md#11-validação-funcional-pós-apply).

## Por que isso existe

`terraform apply` sem erro e `aws ec2 describe-*` mostrando os atributos certos provam que os recursos **existem com a configuração esperada** — não provam que eles **funcionam**. Para a VPC do lab, a pergunta que importa é: uma carga de trabalho numa subnet privada realmente consegue sair para a internet através do NAT Gateway? Ler a route table não responde isso; só exercitar o caminho de rede responde.

Este runbook documenta o script `terraform/envs/lab/scripts/validate-network.sh`, que sobe uma instância EC2 efêmera na subnet privada, testa o caminho de rede de dentro dela, e sempre a termina ao final — nunca fica como infraestrutura permanente.

## Como funciona

- **Acesso via SSM Session Manager**, não SSH: a instância não tem IP público, chave, nem Security Group de entrada. O agente SSM se conecta de dentro para fora, então **o próprio registro da instância no SSM já é um primeiro teste de egress** — se o NAT não funcionar, a instância nunca aparece `Online`.
- **AMI resolvida dinamicamente** via parâmetro público do SSM (`/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64`), sem hardcodar um AMI ID que expira.
- **Checagens executadas:**
  1. IP privado atribuído está dentro do CIDR da subnet (sanity check via API do EC2, não precisa de SSM).
  2. Instância registra no SSM como `Online` (prova indireta de egress).
  3. `curl` para `https://checkip.amazonaws.com` de dentro da instância (prova direta: o NAT traduz e roteia tráfego de saída).
  4. Resolução de DNS público (`getent hosts amazon.com`).
- **Cleanup garantido:** `trap cleanup EXIT` chama `aws ec2 terminate-instances` mesmo se o script falhar ou for interrompido (`Ctrl+C`).

## Pré-requisito: role de smoke test

O script precisa de uma instance profile (`minitube-network-smoke-test`) para a EC2 assumir a role de SSM. O `cloudlab-operator` (`PowerUserAccess`) **não pode criar recursos IAM** — só ler e `PassRole`. Por isso essa role vive em `terraform/bootstrap-iam/` (módulo admin-only) e precisa ser aplicada uma vez via CloudShell/root, seguindo o mesmo fluxo de [`docs/runbooks/bootstrap/aws-account-bootstrap.md`](../bootstrap/aws-account-bootstrap.md).

```bash
# Sessão root/CloudShell, uma única vez (a role persiste entre sessões, sem custo)
cd terraform/bootstrap-iam
terraform init
terraform plan
terraform apply
```

Verificar que a role existe antes de rodar o script:

```bash
aws iam get-instance-profile --instance-profile-name minitube-network-smoke-test --profile cloudlab
```

⚠️ Sem essa role aplicada, `terraform plan`/`apply` em `terraform/envs/lab/` falha ao resolver o `data "aws_iam_instance_profile"` em `ssm.tf`.

## Executar o teste

```bash
cd terraform/envs/lab
AWS_PROFILE=cloudlab ./scripts/validate-network.sh
```

Dependências no seu ambiente: `aws` CLI, `jq`, `terraform`, `python3` (usado só para a checagem de IP-dentro-do-CIDR).

## Leitura esperada do output

```
PASS: private IP 10.0.16.x is within subnet CIDR 10.0.16.0/20
PASS: SSM agent online (this alone proves NAT egress: ...)
PASS: internet egress via NAT Gateway (curl to checkip.amazonaws.com)
PASS: public DNS resolution
=== All checks passed: private subnet has real internet egress via the NAT Gateway. ===
```

Código de saída `0` quando tudo passa, `1` se qualquer checagem falhar (a mensagem de erro específica aparece antes da linha final).

## Segurança / rollback

O script sempre termina a instância de teste via `trap`, mesmo em caso de erro. Se o script for encerrado de forma anômala (ex. `kill -9`, painel travado) e a instância sobrar:

```bash
aws ec2 describe-instances --profile cloudlab \
  --filters "Name=tag:Name,Values=minitube-network-smoke-test" "Name=instance-state-name,Values=running,pending" \
  --query 'Reservations[].Instances[].InstanceId' --output text

aws ec2 terminate-instances --profile cloudlab --instance-ids <instance-id>
```

A role/instance profile em si não tem custo e não precisa ser destruída entre sessões — é reutilizável por futuros scripts de validação (EKS, etc.).
