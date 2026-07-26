# Fase 6 — Dia do jogo

> Retrospecto da fase, escrito ao final dela. Não repete o conteúdo de ADRs e runbooks — linka para eles. Serve como insumo para a documentação final do projeto (ver `CLAUDE.md`, seção "Estrutura do repositório"). Também é o relatório final exigido pelo critério de conclusão da fase — ver seção "Estado final da fase".

## Objetivo da fase

Última fase do roadmap. Cenários k6 em ondas; HPA (e opcionalmente KEDA); experimentos de caos simples; runbook de resposta a incidente. Critério de conclusão (`CLAUDE.md`): *"Relatório final em `docs/` com gráficos, o que quebrou primeiro e lições aprendidas"*.

## O que foi entregue

| Entregável | Onde vive | PR(s) |
| --- | --- | --- |
| Fix do bug de TTL do Job exposto pelo 1º teste de carga | `app/api/jobs.py`, imagem `v0.1.4` | #20 |
| `load/k6/baseline.js` + runbook | `load/k6/`, `docs/runbooks/run-k6-baseline.md` | #21 |
| `load/k6/breakpoint.js` + `run-breakpoint-from-ec2.sh` + runbook | `load/`, `docs/runbooks/run-k6-breakpoint.md` | #21, #26 |
| HPA + metrics-server + PDB (ADR 012) | `gitops/app/{hpa,pdb}.yaml`, `gitops/plataforma/metrics-server/` | #22 |
| `load/k6/waves.js` + `run-waves-from-ec2.sh` + runbook | `load/`, `docs/runbooks/run-k6-waves.md` | #26 |
| Fix de `readinessProbe`/`livenessProbe` (timeout curto demais sob saturação) | `gitops/app/deployment.yaml` | #27 |
| 3 experimentos de caos + `docs/runbooks/incident-response.md` | `chaos/`, `docs/runbooks/chaos-*.md` | #25, #28, #29, #30 |
| SLO de latência revisado com dado real | `gitops/plataforma/kube-prometheus-stack/slo-rules.yaml` | #31 |
| Backfill dos retrospectos de Fase 4 e 5 | `docs/phases/004-*.md`, `005-*.md` | #24 |

## Decisões de arquitetura (ADRs)

- **[ADR 012](../adr/012-hpa-cpu-autoscaling.md)** — decisão central da fase: HPA por CPU (não Cluster Autoscaler/Karpenter), `minReplicas: 2`/`maxReplicas: 6`/`averageUtilization: 70%`, `metrics-server` via GitOps, `PodDisruptionBudget`. Guiada por dado real do baseline/breakpoint, não estimativa.

## Bugs reais encontrados e corrigidos

Nenhum destes apareceu fora de um teste de carga ou experimento de caos real — reforça, mais uma vez, "existe vs. funciona" (`docs/engineering-standards.md` §11):

1. **TTL do Job mascarando vídeos válidos como 404** (`app/api/jobs.py`) — o primeiro teste de breakpoint expôs que `GET /api/videos/{id}` dependia só do `Job` do Kubernetes (coletado 1h após terminar) como fonte de verdade. Corrigido com fallback para `s3_client.hls_playlist_exists()`.
2. **Ruído de rede do cliente mascarando o teto de capacidade real** — os primeiros breakpoints rodados localmente (WSL2/rede residencial) abortavam com latências que o servidor nunca via (confirmado via Prometheus/CloudWatch). Corrigido rodando o k6 de uma EC2 efêmera dentro da própria VPC (`run-breakpoint-from-ec2.sh`/`run-waves-from-ec2.sh`).
3. **Gargalo de CPU de réplica única** — com esse ruído eliminado, o breakpoint real mostrou o pod `api` saturando a `500m` de CPU (única réplica, sem HPA) a partir de ~125-130 req/s combinados, enquanto os nodes tinham folga de sobra. Motivou o HPA (ADR 012).
4. **Novo teto real pós-HPA: `maxReplicas: 6`, não CPU de uma réplica** — escalando o breakpoint para `PEAK_RATE=800`, o HPA bateu no próprio `maxReplicas: 6` (3 cores agregados) e segurou lá sob demanda crescente, causando fila (latência subindo a `p95=1,04s`, `max=12,94s`) sem erros reais (`0,00%`) — comportamento de saturação controlada, não crash.
5. **Probes matando pods sobrecarregados, não travados** — o cenário de ondas (`waves.js`) expôs que `readinessProbe`/`livenessProbe` (`gitops/app/deployment.yaml`) não tinham `timeoutSeconds` explícito (default do Kubernetes: 1s) — curto demais frente ao `p95=2,42s` real no pico. O `kubelet` matava pods que estavam sobrecarregados, cortando capacidade bem na hora em que o HPA mais precisava dela. Achado mais valioso da fase em termos de "o que quebrou primeiro": não foi capacidade agregada (o HPA absorveu o pico como esperado), foi uma probe mal calibrada amplificando a própria saturação que o HPA tentava resolver.
6. **`disable-observability-stack.sh` — três bugs em sequência, só o script de teste, não a arquitetura:** (a) tentava descobrir um `video_id` via `GET /api/videos`, rota que nunca existiu (só `POST /api/videos` e `GET /api/videos/{id}`) — o script abortava silenciosamente sob `set -euo pipefail`; (b) a descoberta de workloads por `app.kubernetes.io/instance` (label do Helm) nunca cobria o StatefulSet real do Prometheus/Alertmanager, criados dinamicamente pelo Prometheus Operator com labels próprios — o primeiro resultado "válido" (`FAIL`, 18,75% de erro) não significava nada, porque o Prometheus nunca tinha saído do ar; (c) a correção (descoberta por exclusão) varreu por engano o `metrics-server` (Application separada, fora do escopo do experimento), cujo `selfHeal` nunca pausado reverteu o `scale --replicas=0` sozinho — inofensivo, mas corrigido.

## Como validamos

Resultados completos em cada runbook — aqui só o resumo:

- **[`run-k6-baseline.md`](../runbooks/run-k6-baseline.md):** carga leve, 0% erro, p95 de 50-190ms conforme o endpoint.
- **[`run-k6-breakpoint.md`](../runbooks/run-k6-breakpoint.md):** pré-HPA, satura em ~125-130 req/s (CPU de uma réplica); pós-HPA, `PEAK_RATE=400` limpo (p95=48ms); `PEAK_RATE=800` encontra o novo teto real (`maxReplicas: 6`, p95=1,04s, 0% erro).
- **[`run-k6-waves.md`](../runbooks/run-k6-waves.md):** confirma o HPA escalando para baixo depois do pico (6→3→2, "All metrics below target") — nenhum outro teste da fase exercitava isso. Expõe o bug 5 acima.
- **[`chaos-kill-api-pod.md`](../runbooks/chaos-kill-api-pod.md):** PASS, 0% erro, recuperação limpa via `minReplicas`+PDB.
- **[`chaos-drain-spot-node.md`](../runbooks/chaos-drain-spot-node.md):** PASS, reagendamento da API (e de vários singletons de plataforma que compartilhavam o node) dentro do timeout.
- **[`chaos-disable-observability-stack.md`](../runbooks/chaos-disable-observability-stack.md):** PASS confirmado na 3ª iteração — com o Prometheus/Alertmanager realmente fora do ar, a API e o HLS seguiram servindo 100% do tráfego (0% erro).

## Gráficos/Evidências visuais

> Exportados manualmente do dashboard "dia do jogo" no Grafana (`https://grafana.<domínio>`) pelo operador — a UI não é acessível a partir desta sessão.

- `assets/006-hit-ratio-cdn.png` — hit ratio do CloudFront durante os testes de carga. *(pendente)*
- `assets/006-latencia-p95-p99.png` — latência p95/p99 da API cruzando os estágios dos testes (baseline, breakpoint, ondas). *(pendente)*
- `assets/006-saturacao-hpa.png` — réplicas do HPA e CPU agregada subindo/descendo (ondas). *(pendente)*
- `assets/006-erros-alb.png` — erros da ALB durante os experimentos de caos. *(pendente)*

## Lições aprendidas

- **Liveness probes com timeout default são um risco real sob saturação real, não só teórico.** Um pod lento (mas vivo) sendo morto pela própria probe é um padrão auto-amplificador — corta capacidade exatamente quando ela mais falta. Vale revisar em qualquer Deployment que já tenha passado por um teste de carga real, não só copiar o exemplo de `readinessProbe`/`livenessProbe` da documentação sem ajustar os timeouts ao comportamento real sob carga.
- **O gerador de carga precisa rodar de dentro do mesmo ambiente de rede do alvo.** Ruído de rede do cliente (WSL2, ISP residencial) pode mascarar completamente o sinal real de saturação — só ficou claro cruzando com métricas do lado do servidor (Prometheus, CloudWatch), nunca confiando só no que o k6 reportava.
- **Scripts de teste (inclusive os de caos) merecem o mesmo ceticismo "existe vs. funciona" que a infraestrutura que eles testam.** Um `FAIL` de um script com um bug de descoberta de recursos (`disable-observability-stack.sh`) quase virou uma conclusão errada sobre a arquitetura — só a checagem manual da lista de workloads realmente escalados evitou isso.
- **`maxReplicas` de um HPA é uma decisão de configuração, não um limite físico.** Os nodes seguem com folga de sobra mesmo no teto atual — subir `maxReplicas` é o próximo ajuste natural se o objetivo for suportar mais que ~800 req/s de pico, não uma mudança de estratégia de autoscaling.
- **Pausar `selfHeal` do ArgoCD via `kubectl patch` é seguro quando formalizado como script versionado e sempre revertido** — mas precisa ser escopado com precisão (o incidente do `metrics-server` mostrou o que acontece quando um recurso fora do escopo pretendido é varrido por engano: o ArgoCD briga com a mudança, silenciosamente, sem quebrar nada, mas gerando ruído confuso no resultado).

## Estado final da fase

- Critério de conclusão: relatório final ✅ (este documento), o que quebrou primeiro ✅ (seção "Bugs reais" acima — o achado central foi a probe mal calibrada, não falta de capacidade), lições aprendidas ✅. **Gráficos do dashboard "dia do jogo" pendentes** de exportação manual pelo operador (seção acima) — fase só é considerada formalmente encerrada depois que as imagens forem adicionadas.
- PRs desta fase: #20, #21, #22, #24, #25, #26, #27, #28, #29, #30, #31 — todos mergeados em `main`.

## Próxima fase

Nenhuma — Fase 6 é a última do roadmap planejado (`CLAUDE.md`, tabela de fases). Trabalho futuro fica a critério do operador: candidatos já registrados incluem achar o teto exato de capacidade (escalar `PEAK_RATE` além de 800), KEDA como alternativa ao HPA por CPU, e a decisão de tornar o repositório público para portfólio (ver ADR 007).
