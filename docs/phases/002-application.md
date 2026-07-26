# Fase 2 — Aplicação

> Retrospecto da fase, escrito ao final dela. Não repete o conteúdo de ADRs e runbooks — linka para eles. Serve como insumo para a documentação final do projeto (ver `CLAUDE.md`, seção "Estrutura do repositório").

## Objetivo da fase

Colocar o primeiro workload real do projeto de pé: uma API mínima que recebe upload de vídeo e dispara a transcodificação (FFmpeg → HLS) como um Job no EKS efêmero, gravando os segmentos no S3. Critério de conclusão (`CLAUDE.md`): *"um vídeo de teste transcodificado e segmentos legíveis no S3"*.

## O que foi entregue

| Entregável | Onde vive | Persistente ou efêmero |
| --- | --- | --- |
| API de upload (FastAPI) | `app/api/` | Imagem persistente (ECR); execução efêmera (Deployment em `envs/lab`) |
| Transcoder (FFmpeg → HLS) | `app/transcoder/` | Idem — roda como Job por vídeo recebido |
| Bucket S3 de vídeo (`raw/` + `hls/`) | `terraform/envs/lab/s3.tf` | Efêmero |
| IRSA role compartilhada (API + transcoder) | `terraform/envs/lab/iam-app.tf` | Efêmero (acoplada ao OIDC provider do cluster) |
| Repositórios ECR (`minitube-api`, `minitube-transcoder`) | `terraform/bootstrap/ecr.tf` | Persistente |
| Manifests Kubernetes (namespace, RBAC, Deployment, Service) | `gitops/app/` | Aplicados manualmente por enquanto (`kubectl apply -k`) |

A API cria um `batch/v1 Job` por vídeo recebido — sem fila/worker por trás; o vídeo bruto vai para `raw/`, o transcoder lê de lá e grava `.m3u8` + segmentos `.ts` em `hls/<video_id>/`.

## Decisões de arquitetura

- **[ADR 006](../adr/006-app-irsa-and-job-orchestration.md)** — decisão central da fase. Cobre: onde vive a IRSA role da app (em `envs/lab`, não `bootstrap-iam`, por causa do acoplamento ao OIDC provider efêmero — mesmo raciocínio do ADR 004, aplicado a um novo caso); por que uma única role compartilhada por API e transcoder; por que orquestração via Job dinâmico, não fila; por que os repositórios ECR vivem em `bootstrap/` e não `bootstrap-iam`; e por que `kubectl apply -k` é manual só até a Fase 3.
- **[ADR 004](../adr/004-eks-iam-roles-and-access-mode.md)** ganhou uma nota de atualização: a suposição original de que "quem aplica o Terraform recebe admin no cluster automaticamente" só vale para quem *criou* o cluster — descoberto nesta fase quando o operador diário tentou `kubectl` pela primeira vez contra um cluster criado via CloudShell.

## Bugs reais encontrados e corrigidos

Nenhum destes apareceu em teste local isolado — todos só surgiram exercitando o pipeline de ponta a ponta contra a AWS real, reforçando por que a validação funcional (`engineering-standards.md` §11) importa mais do que `terraform apply`/`kubectl apply` saírem sem erro:

1. **FFmpeg + chroma 4:4:4.** O primeiro teste do comando de transcodificação falhou: o filtro de vídeo de teste (`testsrc`) gera saída 4:4:4, incompatível com o profile `main` do H.264. Corrigido adicionando `format=yuv420p` à cadeia de filtros — necessário de qualquer forma para compatibilidade ampla de players HLS, não só para o teste sintético.
2. **`[[ ]]` como argumento de função em bash.** `[[` é palavra-chave do shell, não um comando — não pode ser passado via `"$@"` para a função `run_check`. Substituído por `[ ]` (o builtin `test`, que é um comando de verdade) no script de validação.
3–5. **Três lacunas sucessivas de permissão IAM do operador**, todas na mesma classe: `terraform plan`/`apply`/`destroy` fazem verificações do provider AWS que não são óbvias a partir do recurso declarado — refresh de todo recurso já no state (não só o que muda), e checagens de "recursos relacionados" (policies anexadas, instance profiles) mesmo quando não existem. Cada uma expôs uma ação IAM faltante: leitura do OIDC provider (`iam:GetOpenIDConnectProvider` e correlatas), leitura de policies gerenciadas anexadas à IRSA role (`iam:ListAttachedRolePolicies`), leitura de instance profiles antes do delete (`iam:ListInstanceProfilesForRole`). Todas corrigidas como novas `Statement`s na mesma policy inline do operador (nunca um novo recurso — API do Identity Center só aceita uma inline policy por permission set).
6. **Acesso `kubectl` do operador ao cluster.** `bootstrap_cluster_creator_admin_permissions` só concede admin a quem de fato chamou `CreateCluster` — nesta sessão, o CloudShell (que aplicou tudo pela primeira vez), não o `cloudlab-operator`. Corrigido com um `aws_eks_access_entry` explícito, resolvido via `var.operator_role_arn` (ARN fixo, obtido uma vez via CloudShell — não via `data "aws_iam_session_context"`, que por sua vez exigiria mais uma permissão IAM sobre uma role que o projeto nem gerencia).
7. **`jobs/status` como subrecurso RBAC separado.** O Job de transcodificação terminou com sucesso (confirmado via `kubectl logs`: FFmpeg rodou, os dois arquivos foram pro S3), mas a API reportava `running` para sempre. Causa: `read_namespaced_job_status()` bate no subrecurso `/status`, que exige uma permissão RBAC separada (`jobs/status`) que o `Role` nunca teve — só `jobs`. Corrigido trocando para `read_namespaced_job()`, que retorna o mesmo campo `.status` usando só a permissão `get` em `jobs` já concedida.
8. **`set -e`/`pipefail` mascarando o bug acima.** O loop de poll do script de validação tratava qualquer resposta não-parseável da API (incluindo um erro real, como o 403 do bug 7) como "ainda rodando", escondendo o problema até estourar o timeout de 300s sem nenhuma mensagem de diagnóstico. Corrigido: falhas repetidas (3 seguidas) agora abortam com a resposta bruta impressa, em vez de mascarar silenciosamente.

## Como validamos

[`docs/runbooks/validate/validate-transcoding.md`](../runbooks/validate/validate-transcoding.md) + `terraform/envs/lab/scripts/validate-transcoding.sh`: gera um vídeo sintético via FFmpeg (sem binário commitado), envia por `POST /videos` através de um `kubectl port-forward`, espera o Job terminar via polling em `GET /videos/{id}`, e confirma via `aws s3api`/`aws s3 ls` que a playlist e ao menos um segmento existem no bucket real. As 4 checagens passaram na validação final desta fase.

## Estado final da fase

- Critério de conclusão cumprido: vídeo de teste real, transcodificado, segmentos HLS confirmados no S3.
- `terraform/bootstrap/` ganhou 2 repositórios ECR (persistentes); `terraform/bootstrap-iam/` ganhou 3 novas `Statement`s na policy inline do operador (persistentes); `terraform/envs/lab/` (VPC, EKS, bucket de vídeo, IRSA role, access entry) confirmado destruído ao final da sessão.
- PR desta fase: [`feat/phase-2-app`](https://github.com/alisson92/minitube/pull/10) *(atualizar o link se o número do PR mudar)*.

## Próxima fase

[Fase 3 — GitOps](../../CLAUDE.md#fases-do-projeto): instalar o ArgoCD e sincronizar `gitops/app/` (e `gitops/platform/`) a partir do Git — critério de conclusão: nenhum `kubectl apply` manual, todo deploy sai do Git. Elimina a exceção temporária registrada no ADR 006 (item 7).
