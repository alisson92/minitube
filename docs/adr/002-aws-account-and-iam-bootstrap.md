# 002 — Conta AWS dedicada e bootstrap de IAM via Terraform

## Status

Aceito

## Contexto

A primeira tentativa de `terraform apply` do bucket de state falhou: o usuário IAM configurado localmente (`lab-operator`, conta `455162168775`) não tinha permissão `s3:CreateBucket`, e não havia registro de qual conta/administrador o criou originalmente — a conta não era rastreável nem documentada.

## Decisão

1. **Conta AWS nova e dedicada**, com e-mail próprio (`alisson.cloudlab@gmail.com`), usada para gerenciar múltiplos projetos pessoais de laboratório de cloud — não amarrada só ao MiniTube.
2. **Nenhuma credencial de longa duração para root.** O root só é usado para: definir senha, ativar MFA, e abrir o AWS CloudShell uma única vez. O CloudShell herda as credenciais temporárias da sessão do console, permitindo rodar `terraform apply` sem nunca gerar uma access key de root (prática desencorajada pela própria AWS).
3. **Usuário operacional criado via Terraform, não manualmente:** `cloudlab-operator` (`terraform/bootstrap/iam.tf`), com a policy gerenciada `PowerUserAccess` — acesso amplo à maioria dos serviços AWS, mas exclui gestão de IAM/Organizations. Essa exclusão é o que mantém a separação de privilégio entre a identidade administrativa (root, uso raríssimo) e a identidade de uso diário.

### Alternativas consideradas

- **Policy customizada, crescente por fase:** mais alinhada ao princípio de menor privilégio, mas exigiria reabrir uma sessão root/CloudShell a cada serviço AWS novo tocado por uma fase do projeto — fricção operacional descartada para um projeto pessoal de operador único.
- **AdministratorAccess no operador diário:** descartada por remover completamente a separação entre identidade admin e identidade operacional, o que viola o princípio de menor privilégio mesmo em contexto de lab pessoal.

## Consequências

- Qualquer mudança futura de IAM (nova policy, novo usuário) exige repetir o procedimento manual do CloudShell — é um evento raro e documentado em [`docs/runbooks/aws-account-bootstrap.md`](../runbooks/aws-account-bootstrap.md), não parte do fluxo normal de `apply`/`destroy` das sessões.
- A conta antiga (`455162168775`, `lab-operator`) é abandonada; nenhuma limpeza é necessária ali além de, eventualmente, encerrá-la se não tiver mais uso.
- O output `operator_secret_access_key` é sensível e só deve ser lido uma vez, no momento da configuração do profile local — nunca deve aparecer em logs ou ser commitado.
