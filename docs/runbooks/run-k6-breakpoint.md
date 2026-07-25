# Runbook: teste de breakpoint k6 (Fase 6)

## O quê

`load/run-breakpoint.sh` roda `load/k6/breakpoint.js` — um teste de **breakpoint**, categoria oficialmente documentada pelo próprio k6 (distinta de load/soak/spike testing): escalar carga deliberadamente até o sistema quebrar de verdade, em vez de validar que ele aguenta um número fixo. Complementa `load/run-baseline.sh` (carga pequena e fixa, já validada estável — ver `docs/runbooks/run-k6-baseline.md`), sem substituí-lo: o baseline permanece registrado como está, este é um teste novo e separado.

O alvo é o caminho da API (`/api/healthz`, `/api/videos/{id}` via ALB → EKS) — a única réplica sem HPA, candidata mais provável a quebrar primeiro (ver o resultado do baseline: `uvicorn` sem `--workers`, limite de `500m` CPU, nunca estressado de verdade). O tráfego de `viewers` (CloudFront/S3) entra só como um fundo constante e pequeno (10 VUs), não como alvo — CDN/S3 não é o que este teste tenta quebrar.

## Por quê

Diferença central em relação ao baseline: **modelo aberto, não fechado**. `load/k6/baseline.js` usa `ramping-vus` (modelo fechado) — cada VU só faz a próxima requisição depois que a anterior responde, então se o sistema desacelerar, a demanda real cai junto (a fila fica invisível). `load/k6/breakpoint.js` usa `ramping-arrival-rate` (modelo aberto) — dispara requisições numa taxa alvo (req/s) independente do tempo de resposta, então filas e erros aparecem de verdade nas métricas quando o sistema não consegue acompanhar. É a recomendação oficial do k6 para este tipo de teste.

Os thresholds aqui **não** protegem um SLO — eles existem só para detectar quebra e abortar (`abortOnFail`, `delayAbortEval: 10s`) assim que:
- `http_req_failed` passa de 5% (bem mais tolerante que o `<1%` do baseline — aqui queremos deixar degradar até doer, não até o primeiro soluço).
- `http_req_duration{endpoint:api}` p95 passa de 1s.

Sem `abortOnFail`, o teste rodaria a duração toda cegamente contra um alvo já quebrado, desperdiçando tempo e possivelmente piorando um incidente real em andamento.

## Como

```bash
AWS_PROFILE=cloudlab ./load/run-breakpoint.sh
```

Escalar o teto entre execuções (sem editar código):

```bash
PEAK_RATE=800 AWS_PROFILE=cloudlab ./load/run-breakpoint.sh
```

`PEAK_RATE` (default `400` req/s) é o topo da rampa de 6 estágios (~17 min): `5% → 12,5% → 25% → 50% → 100% → 100%` do valor de `PEAK_RATE`, sustentado nos últimos 5 minutos. `preAllocatedVUs`/`maxVUs` escalam junto automaticamente.

Pré-requisitos: os mesmos do baseline (`k6`, `aws`, `jq`, `terraform`, `kubectl`, `curl`, `ffmpeg` no PATH; `terraform apply` já rodou; ArgoCD sincronizado). O script reaproveita a mesma lógica de "achar ou criar vídeo de teste" (`load/lib/find-or-create-video.sh`), compartilhada com `run-baseline.sh`.

## Como ler o resultado

- **Abortou antes do fim (`abortOnFail`)?** Achamos o ponto de quebra — o k6 imprime em qual estágio/instante o threshold estourou. Esse é o dado que faltava para decidir entre HPA e Cluster Autoscaler/Karpenter (cruzar com os dashboards da Fase 5: saturação de CPU do pod `api` vs. saturação dos nós no momento exato do abort).
- **Completou os ~17 minutos sem abortar?** O sistema aguentou até `PEAK_RATE` req/s. Não é o teto real ainda — reexecute com `PEAK_RATE` maior (dobrar é um passo razoável: 400 → 800 → 1600...) até encontrar a quebra.
- Cruzar sempre com Grafana/Prometheus no horário exato do teste, não só com o sumário do k6 — o k6 mostra o sintoma do lado do cliente, o dashboard mostra a causa (CPU, memória, throttling, réplicas).

Mesma observação do baseline: este script não se autolimpa como os `validate-*.sh` no sentido de destruir infraestrutura — só gera tráfego HTTP e, se preciso, cria um vídeo de teste real no S3.

## Depois de achar o ponto de quebra

Este runbook só descobre onde quebra — a decisão de qual mitigação aplicar (HPA vs. Cluster Autoscaler/Karpenter) e o ajuste do threshold de 500ms em `slo-rules.yaml` continuam sendo os próximos passos combinados com o operador, não parte deste script.

## Resultado da execução (2026-07-24) — abortou cedo, mas não por capacidade

Executado com `PEAK_RATE=400` (default) contra a infra real, na retomada da sessão após uma queda de energia (ambiente conferido íntegro antes de rodar: sessão SSO válida, `terraform plan` sem drift, cluster/node group `ACTIVE`, as 9 Applications do ArgoCD `Synced`/`Healthy`).

O `k6 run` abortou (`abortOnFail`) em ~82s — ainda no primeiro estágio da rampa (~14 VUs, ~85 req/s de pico, **9% do primeiro degrau de 5% do `PEAK_RATE`**). Isso por si só já é o primeiro sinal de que não foi a API nem o node group que saturaram: a carga nunca chegou perto de qualquer teto de capacidade.

**Causa raiz confirmada: não é de capacidade, é um bug de correção exposto pelo teste.** `GET /api/videos/{video_id}` (`app/api/jobs.py::get_job_status`) usa o `batch/v1 Job` do Kubernetes como única fonte de verdade sobre o vídeo. Esse Job é criado com `ttl_seconds_after_finished=3600` — passada essa 1h após a conclusão, o próprio Kubernetes coleta o objeto (`kubectl get job transcode-<id>` → `NotFound`, confirmado após o teste). O vídeo reaproveitado pelo `load/lib/find-or-create-video.sh` (`4228cdfc6c57409ebe8fd6100a5ac7cb`, o mesmo do baseline, rodado horas antes) já estava fora dessa janela: os segmentos HLS seguem 100% válidos e serviveis no S3/CloudFront (os checks `playlist status is 200` e `segment status is 200` deram 100% de sucesso), mas o Job já não existe — então `get_job_status` devolve `"not_found"` e a API responde `404` para `/api/videos/{id}`. Isso não é uma falha sob carga: é um 404 legítimo (porém incorreto) que aconteceria do mesmo jeito com um único usuário, a qualquer hora depois de 1h da transcodificação.

Evidência nos logs do pod `api` (`kubectl logs -n minitube-app deploy/api --since-time=...`, janela exata do teste): 100% dos `GET /api/healthz` → `200`; 100% dos `GET /api/videos/4228cdfc6c57409ebe8fd6100a5ac7cb` → `404`. `http_req_duration{endpoint:api}` p95 = 176.89ms — nem perto do threshold de 1s — reforçando que a resposta foi errada e rápida, não lenta/saturada. Motivo pelo qual o baseline (rodado antes, contra o mesmo vídeo ainda "fresco") não bateu nisso: correu dentro da janela de 1h do TTL do Job.

**Causa raiz de segunda ordem, no próprio script de teste:** `load/lib/find-or-create-video.sh` só confere se existe `hls/*/playlist.m3u8` no S3 — nunca confere se o Job correspondente ainda existe no cluster. Funciona para achar "um vídeo já transcodificado" mas não garante que `GET /api/videos/{id}` vá responder `200` para ele.

**Conclusão: este run não encontrou o ponto de quebra de capacidade — encontrou que o teste, do jeito que está, é inválido contra um vídeo reaproveitado com mais de 1h.** Nenhuma mitigação (HPA, Cluster Autoscaler) foi decidida ou aplicada a partir deste resultado; não há dado de capacidade real ainda.

### Pendências em aberto (decisão do operador) — resolvidas na sessão seguinte

1. ~~**Bug real na API**~~ — corrigido: `get_job_status` (`app/api/jobs.py`) agora cai para `s3_client.hls_playlist_exists()` (novo helper, `head_object` em `hls/<id>/playlist.m3u8`) quando o Job não é encontrado, em vez de responder `not_found` direto. O S3 passa a ser a fonte de verdade durável; o Job segue sendo a fonte de verdade só enquanto ainda existe (para distinguir `running`/`failed`). Publicado em `minitube-api:v0.1.4`.
2. ~~**Teste de breakpoint pendente**~~ — reexecutado após o fix. Ver seção abaixo.

## Resultado da execução (2026-07-24, pós-fix) — achado real de capacidade, não é CPU/memória

Reexecutado com `PEAK_RATE=400` (default) contra a infra real, imagem `minitube-api:v0.1.4` (com o fix do TTL do Job) publicada via GitOps — ArgoCD apontado temporariamente para a branch `feat/k6-baseline-scenario` (`terraform apply -var argocd_gitops_revision=...`, mesmo padrão do ADR 007 decisão 5), Application `app` `Synced`/`Healthy` na revisão do commit do fix. Validado isoladamente **antes** do k6: `GET /api/videos/4228cdfc6c57409ebe8fd6100a5ac7cb` (o mesmo vídeo "velho" que antes dava 404) voltou a responder `200`/`succeeded`.

O `k6 run` abortou de novo (`abortOnFail`), desta vez em ~91s — ainda cedo (só ~22-24 VUs, ~63 req/s), mas **por um motivo genuinamente diferente**:

- `http_req_failed`: **0.00%** (5724 de 5724 requisições bem-sucedidas) — `video status is 200` agora passa 100%, confirmando que o fix eliminou o bug do TTL.
- `http_req_duration{endpoint:api}`: `p(95)=1s` — estourou o threshold (`p(95)<1000`), com `max=7.54s`. Latência, não erro, é o que abortou o teste desta vez.

**Descartei capacidade de pod/node como causa antes de concluir qualquer coisa** — cruzei o horário exato do teste (20:44:19–20:46:00 UTC) com o Prometheus (`kube-prometheus-stack`, Fase 5) via `container_cpu_usage_seconds_total`/`container_memory_working_set_bytes` do pod `api`:
- CPU: pico de **~0.083 cores** (8,3% do limite de `500m`).
- Memória: pico de **~102 MB** (40% do limite de `256Mi`).

Ou seja, **o pod nunca chegou perto de saturar CPU ou memória** enquanto a latência já tinha estourado o SLO de 1s — a resposta para a pergunta original do baseline ("o gargalo é de pod ou de node group?") é **nenhum dos dois**. O node group (folga confirmada na Fase 5, 3× `t3.medium`) nem chegou a ser avaliado a fundo porque o próprio pod já descartava a hipótese de recurso.

`argocd_gitops_revision` revertido para `main` (default) ao final desta validação — o override era só para testar o fix antes do merge, não um estado permanente.

## Investigação da latência (2026-07-24) — a hipótese de pool de conexão foi descartada por evidência

A primeira hipótese registrada aqui ("`uvicorn` sem `--workers`, chamadas bloqueantes ao K8s/S3 em sequência, pool de conexão do `boto3`/cliente k8s") **foi refutada por dados**, antes de qualquer código ser alterado em cima dela. Duas fontes independentes, na janela exata do teste (20:44:19–20:46:05 UTC), mostram que o processamento dentro da API nunca foi lento:

- **`http_request_duration_seconds`** (métrica do próprio `prometheus-fastapi-instrumentator`, via Prometheus): das 842 requisições a `/api/videos/{video_id}` na janela, **100% completaram em ≤ 0,5s** (99,6% em ≤ 0,1s). Zero requisições internas passaram de 1s — as duas chamadas síncronas (K8s API + fallback S3) nunca demoraram o que o k6 mediu.
- **`TargetResponseTime`** (CloudWatch, `AWS/ApplicationELB` — métrica da própria AWS, não nossa): p95 ≤ 37ms, p99 ≤ 84ms, **máximo absoluto de 145ms** em qualquer janela de 30s do teste.

Ou seja: nem o pod, nem o salto ALB→pod, chegam perto do que o k6 reportou (`p95=1s`, `max=7.54s`). A latência está sendo adicionada em algum lugar entre o cliente k6 (rodando localmente via WSL2, na máquina do operador) e o ALB.

**Quatro testes diferenciais curtos (90s cada), isolando uma variável de cada vez, todos via CloudFront, contra o mesmo vídeo:**

| Teste | Configuração | Resultado |
| ----- | ------------- | --------- |
| 1 | Só `api`, taxa constante 20 req/s | p95=184ms, max=1.09s |
| 2 | `viewers`(10 VUs) + `api` juntos, taxa constante | p95=193ms, max=945ms |
| 3 | Só `api`, `ramping-arrival-rate` (5→20 em 90s) | p95=184ms, max=1.41s |
| 4 | `viewers`(10 VUs) + `api` com `ramping-arrival-rate`, **mesmo dimensionamento exato do breakpoint real** (`preAllocatedVUs=100`, `maxVUs=800`) | p95=191ms, max=978ms |

**Nenhuma das quatro reproduziu o problema** — nem a variante que replica exatamente os parâmetros do primeiro estágio do breakpoint real (teste 4). Isso descarta, com dado, as hipóteses de: taxa constante vs. rampa, cenários combinados vs. isolados, e tamanho do pool de VUs do k6.

**Conclusão honesta:** o pico de latência (`max=7.54s` na execução pós-fix) não foi reproduzido de forma sistemática em nenhuma variação testada, apesar de replicar os parâmetros exatos do teste original. Combinado com a evidência de que ALB e pod estavam rápidos durante o próprio run que falhou, a explicação mais defensável é que o pico foi um **artefato transiente do caminho cliente→AWS** (rede local/WSL2/internet residencial do operador no momento exato daquelas duas execuções) — não uma propriedade determinística do MiniTube nem do desenho do teste k6. Chama atenção que os dois aborts reais aconteceram em instantes parecidos (~82s e ~91s) dentro da rampa, o que poderia sugerir algo determinístico, mas nenhuma tentativa de reprodução (incluindo uma cópia fiel dos parâmetros) confirmou isso.

**Implicação prática:** k6 rodando localmente (WSL2, rede residencial) não é um cliente confiável para medir o teto de capacidade real via HTTPS público neste nível de precisão — instabilidades do caminho cliente→AWS podem abortar o teste antes de qualquer saturação real do sistema acontecer. Para um sinal limpo, o gerador de carga precisaria rodar de dentro da AWS (ex.: uma instância EC2 pequena e efêmera na mesma VPC/região). **Confirmado na seção seguinte** — essa mudança de abordagem foi o que finalmente achou o breakpoint real.

HPA vs. Cluster Autoscaler/Karpenter **seguiu sem dado de capacidade real até a execução via EC2, abaixo** — nem o resultado do primeiro breakpoint pós-fix (latência do cliente, não do servidor) nem os testes diferenciais (nunca chegaram perto de estressar nada) respondiam isso.

## Rodando o k6 de dentro da AWS (`run-breakpoint-from-ec2.sh`)

Para eliminar de vez a variável "rede do cliente" da equação, `load/run-breakpoint-from-ec2.sh` roda o **mesmo** `load/k6/breakpoint.js`, mas o processo do k6 executa numa instância EC2 efêmera dentro da própria VPC do laboratório, não na máquina do operador.

```bash
AWS_PROFILE=cloudlab ./load/run-breakpoint-from-ec2.sh
# Escalar o teto entre execuções, igual ao script local:
PEAK_RATE=800 AWS_PROFILE=cloudlab ./load/run-breakpoint-from-ec2.sh
```

**Como funciona (reaproveita infraestrutura já existente, nenhuma mudança de Terraform):**
- Mesmo padrão de `terraform/envs/lab/scripts/validate-network.sh`: instância `t3.small` (`INSTANCE_TYPE` sobrescrevível) na subnet privada, sem IP público, acessada só via **SSM Session Manager/Run Command** — sem SSH, sem bastion.
- Mesma IAM instance profile do smoke test de rede (`smoke_test_instance_profile_name`, só `AmazonSSMManagedInstanceCore`) — o próprio comentário em `terraform/bootstrap-iam/main.tf` já previa reuso ("reusable across future validation scripts"), então nenhum recurso IAM novo foi criado.
- O passo de achar/criar o vídeo de teste (`find_or_create_test_video`) continua rodando **localmente** (precisa de `kubectl`/AWS local) — só o `k6 run` em si roda na EC2. O binário do k6 (mesma versão usada localmente) é baixado do release oficial no GitHub; o conteúdo de `breakpoint.js` é enviado em base64 via SSM Run Command.
- A instância é **sempre terminada ao final**, mesmo em caso de erro (`trap cleanup EXIT`), igual a todo `validate-*.sh` do projeto.

**Quando usar este script em vez do `run-breakpoint.sh` local:** sempre que o objetivo for medir capacidade real (o motivo desta seção existir) — o script local segue válido para testes rápidos/exploratórios onde ruído de rede do cliente não importa tanto (ex.: confirmar que um fix não quebrou nada, como na seção "pós-fix" acima).

## Resultado da execução via EC2 (2026-07-25) — breakpoint real encontrado: CPU do pod, não de node

Executado com `PEAK_RATE=400` (default), instância `t3.small` na subnet privada, mesmo vídeo (`4228cdfc6c57409ebe8fd6100a5ac7cb`). Desta vez o teste **rodou ~6m32s** (contra ~82-91s dos runs locais) antes de abortar — chegou a **367 VUs simultâneas** e 1.418.721 requisições totais antes do threshold de latência estourar de novo:

- `http_req_failed`: **0,00%** — zero erros em toda a execução.
- `http_req_duration{endpoint:api}`: `p(95)=1.19s`, `max=2.95s` — estourou o mesmo threshold (`p(95)<1000`) de antes, mas depois de muito mais carga sustentada.

**Desta vez a lentidão é real e confirmada por três fontes independentes, na janela exata do teste (~00:21:58–00:28:30 UTC, via Prometheus):**

1. **CPU do pod `api` sobe de forma constante e monotônica** ao longo de todo o teste — de ~0,15% em repouso até **~0,49 cores às 00:28:15-00:28:30, ~98% do limite de `500m`** — exatamente no momento do abort.
2. **A latência interna da própria API** (`http_request_duration_seconds`, medida dentro do pod via Prometheus, não pelo k6) fica **estável em ~95ms de p95 por mais de 6 minutos** e só dispara nos últimos ~60s: **0,48s às 00:28:30, 1s às 00:29:00** — acompanhando a curva de CPU, não o k6.
3. **Memória do pod fica estável** (~100-120MB de um limite de `256Mi`, nunca passa de 47%) — não é o gargalo. Zero restarts do pod (sem OOM/crash).
4. **CPU dos 3 nodes fica com folga enorme durante todo o teste** — o node que hospeda o pod `api` chega no máximo a ~35% de utilização; os outros dois ficam entre 4-6%. **Não é falta de capacidade de node.**

**Achado confirmado: o gargalo é o limite de CPU (`500m`) da única réplica do Deployment `api`.** Sob carga sustentada (a saturação começou por volta do início do 4º estágio da rampa, ~6 min de teste, ~125-130 req/s combinados de `/api/healthz` + `/api/videos/{id}`), o `uvicorn` sem `--workers` esgota o único core alocado antes de qualquer outro recurso (node, memória) chegar perto do limite.

**Isso reverte a conclusão precipitada da execução pós-fix anterior** ("este resultado derruba HPA baseado em CPU") — aquele resultado vinha de um teste que abortou cedo demais (91s, CPU nunca passou de 8,3%) por ruído de rede do cliente local, antes de a carga real chegar perto de saturar qualquer coisa. Com o ruído removido (EC2) e o teste rodando tempo suficiente para atingir carga real, **CPU é exatamente o sinal que sobe primeiro e no lugar certo (o pod, não o node)** — a resposta mais simples (HPA por CPU, ou aumentar `--workers`/o limite de CPU da réplica) volta a ser a candidata correta.

**Decisão de mitigação (HPA vs. Cluster Autoscaler/Karpenter) agora tem dado real para se apoiar:** HPA baseado em CPU do pod `api` é a mitigação indicada — os nodes têm folga de sobra, então Cluster Autoscaler/Karpenter não resolveria nada sozinho aqui (só passaria a fazer sentido se o HPA algum dia escalasse réplicas o suficiente para esgotar os 3 nodes atuais, o que está longe de acontecer com a folga observada).

Instância EC2 terminada ao final do teste (`trap cleanup EXIT`), confirmado no próprio log do script (`Cleaning up: terminating i-0af14f1a8b8316d5c`).

## Resultado da execução via EC2, pós-HPA (2026-07-25) — o mesmo teste que abortava agora completa limpo

HPA implementado (`docs/adr/012-hpa-cpu-autoscaling.md`): metrics-server via GitOps, `HorizontalPodAutoscaler` no Deployment `api` (`minReplicas: 2`, `maxReplicas: 6`, `averageUtilization: 70` de CPU), `PodDisruptionBudget` (`minAvailable: 1`), `ignoreDifferences` em `/spec/replicas` na Application `app` para o `selfHeal` do ArgoCD parar de brigar com o HPA.

Reexecutado `AWS_PROFILE=cloudlab ./load/run-breakpoint-from-ec2.sh` com **exatamente os mesmos parâmetros** do teste anterior (`PEAK_RATE=400`, mesmo vídeo, mesma instância `t3.small`). Resultado:

- **O teste completou os ~17 minutos inteiros — não abortou.** Antes abortava em ~6m32s.
- `http_req_duration{endpoint:api}`: `p(95)=48.16ms` — contra `p(95)=1.19s`/`max=2.95s` de antes. Threshold (`p(95)<1000`) passou limpo.
- `http_req_failed`: **0,00%** (1 falha isolada em 4.250.363 requisições — ruído desprezível, não um padrão).
- Volume total bem maior que antes por ter completado o teste inteiro: 4.250.363 requisições, pico de 4166,5 req/s combinado (viewers + api).

**Confirmado via Prometheus, na janela exata do teste (~01:03–01:21 UTC), que o HPA é a causa da melhora, não coincidência:**
- **Réplicas escalaram de 2 → 3 → 5 → 6** acompanhando a CPU agregada subindo — chegou ao teto de `maxReplicas: 6` durante o estágio de pico (`PEAK_RATE=400` sustentado) e segurou ali.
- **CPU agregada de todos os pods `api` chegou a ~2,3 cores no pico** — distribuída entre 6 réplicas (~380m cada, folga confortável abaixo do `limits.cpu: 500m` por pod que saturava sozinho antes) — nunca throttlou.
- CPU caiu para perto de zero assim que o teste terminou, confirmando que o consumo acompanhou a carga real, não outro processo.

**Conclusão: a mitigação funcionou exatamente como o dado da execução anterior previa.** O gargalo de CPU de uma réplica única foi resolvido distribuindo a carga entre múltiplas réplicas, dentro da folga de CPU dos nodes já confirmada.

**Isso não encontrou um novo teto de capacidade** — só confirmou que o teto anterior (uma réplica, ~125-130 req/s combinados) foi superado com folga em `PEAK_RATE=400`. Para achar o novo ponto de quebra (agora limitado por `maxReplicas: 6` × `500m` de CPU por pod, ou por outro recurso ainda não testado), o próximo passo seria escalar `PEAK_RATE` (800, depois 1600...) até o teste abortar de novo — não feito nesta sessão, fica como candidato futuro se o objetivo for encontrar o novo teto exato em vez de só validar a mitigação.
