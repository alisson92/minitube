# Runbook: teste de ondas k6 (Fase 6)

## O quê

`load/run-waves-from-ec2.sh` roda `load/k6/waves.js` — audiência subindo e descendo em ondas ("pré-jogo" → "1º tempo" → "intervalo" → "2º tempo" → "pico do gol" → "apito final"), ao longo de ~23 minutos. Diferente de `load/k6/baseline.js` (crescimento monotônico, já validado estável) e `load/k6/breakpoint.js` (rampa até quebrar, sem descida), este é o primeiro cenário que **desce** de propósito — o objetivo central é observar o HPA (`gitops/app/hpa.yaml`, `minReplicas: 2`/`maxReplicas: 6`) escalando **para baixo** depois de um pico, não só para cima.

O estágio "pico do gol" mira deliberadamente perto do teto real já encontrado em [`docs/runbooks/run-k6-breakpoint.md`](run-k6-breakpoint.md) (execução `PEAK_RATE=800`): `maxReplicas: 6` × `limits.cpu: 500m` = 3 cores agregados, ponto em que a latência sobe (fila) sem erros reais aparecerem. Cruzar esse ponto de propósito — e depois descer — é o que torna este um teste de **recuperação**, não só mais um breakpoint: a latência volta a cair e as réplicas voltam a `minReplicas: 2` depois que a onda passa, ou algo fica preso?

## Por quê

Nem o baseline nem o breakpoint testam scale-down. `docs/adr/012-hpa-cpu-autoscaling.md` valida o HPA escalando 2→3→5→6 sob carga sustentada crescente — nunca o caminho inverso, que é igualmente parte do comportamento esperado de um HPA em produção (economia de custo entre picos, não só absorção de pico).

## Como

```bash
AWS_PROFILE=cloudlab ./load/run-waves-from-ec2.sh
```

Escalar o pico deliberado entre execuções (sem editar código):

```bash
WAVE_PEAK_RATE=1000 AWS_PROFILE=cloudlab ./load/run-waves-from-ec2.sh
```

`WAVE_PEAK_RATE` (default `700` req/s) é o topo do estágio "pico do gol" — os demais estágios escalam como fração dele (`pré-jogo` 15%, `1º tempo` 35%, `intervalo` 5%, `2º tempo` 45%, `apito final` 3%). A duração total (~23 minutos) é fixa, independente do valor.

Roda de dentro da AWS via EC2 efêmera, mesmo padrão de `load/run-breakpoint-from-ec2.sh` (ver seção "Rodando o k6 de dentro da AWS" em `run-k6-breakpoint.md` — necessário para eliminar ruído de rede do cliente, especialmente relevante aqui já que o objetivo é medir a forma exata da curva de recuperação, não só um único número de pico). Pré-requisitos: os mesmos dos outros scripts (`aws`, `jq`, `terraform`, `kubectl`, `curl`, `ffmpeg` no PATH; `terraform apply` já rodou; ArgoCD sincronizado; `k6` instalado remotamente via SSM, não localmente).

## Como ler o resultado

Ao contrário do breakpoint, **este teste não deveria abortar** (`abortOnFail` não está setado em nenhum threshold) — o objetivo é observar a forma completa da curva, incluindo a degradação esperada no pico. Cruzar sempre com o Grafana/Prometheus na janela exata do teste:

- **Réplicas do HPA:** confirmar 2 → 3 → 5 → 6 subindo até o "pico do gol", depois **voltando a 2** depois do "apito final" (`kubectl -n minitube-app get hpa api` logo após o teste, ou o histórico em `kube_deployment_status_replicas{namespace="minitube-app",deployment="api"}` no Prometheus).
- **Latência (`http_req_duration{endpoint:api}`):** esperado subir durante o "pico do gol" (mesmo padrão do `PEAK_RATE=800` do breakpoint) e voltar a valores baixos (~50-190ms, faixa já observada nos outros testes) durante o "apito final" — se não voltar, é sinal de algo preso (réplicas não escalando para baixo, conexões penduradas).
- **Taxa de erro:** esperado ficar perto de 0% durante todo o teste, inclusive no pico — a saturação observada no breakpoint é de fila/latência, não de erro.
- **Vale do "intervalo":** confirmar que o HPA não escala para baixo cedo demais nem demora demais — comportamento normal do HPA tem uma janela de estabilização (`stabilizationWindowSeconds`, default do `autoscaling/v2` é 5 min para scale-down) que pode fazer o vale do intervalo (2-3 min) não ser longo o suficiente para uma descida completa antes do "2º tempo" subir de novo — isso é esperado, não um bug.

## Resultado da execução (2026-07-26) — scale-down confirmado, e um bug real de auto-recuperação encontrado

Executado com `WAVE_PEAK_RATE=700` (default) contra a infra real, via `run-waves-from-ec2.sh`.

**Pergunta central do teste respondida: sim, o HPA escala para baixo depois do pico**, confirmado pelo histórico completo de eventos (`kubectl -n minitube-app describe hpa api`), cobrindo o teste inteiro:

```
SuccessfulRescale  New size: 3   (1º tempo)
SuccessfulRescale  New size: 4   (2º tempo)
SuccessfulRescale  New size: 5   (2º tempo)
SuccessfulRescale  New size: 6   (pico do gol)
SuccessfulRescale  New size: 3   (apito final) — "All metrics below target"
SuccessfulRescale  New size: 2   (apito final) — "All metrics below target"
```

O padrão de subida-e-descida esperado aconteceu de ponta a ponta, sem intervenção manual — a réplica final, minutos depois do teste, estava de volta a `minReplicas: 2`.

**Mas o resultado do k6 em si não bateu com os testes anteriores:** `http_req_failed=0,31%` (contra 0,00% em todos os breakpoints, inclusive em `PEAK_RATE=800` — mais alto que os 700 daqui) e `http_req_duration{endpoint:api}` `p(95)=2,42s`, `max=27,97s`. A métrica agregada (`expected_response:true`, que mistura tráfego `api` com `playlist`/`segment`) também mostrou `p(95)=2,25s` — mas os `checks` confirmam que **`playlist status is 200` e `segment status is 200` nunca falharam**, só `healthz status is 200` e `video status is 200` — ou seja, o CloudFront/S3 nunca degradou; o número agregado só reflete que a maior parte do volume de requisições na janela era tráfego `api`.

**Causa raiz confirmada via `kubectl get events` (não coincide com o comportamento visto em nenhum breakpoint anterior):**

```
Warning  Unhealthy  pod/api-...  Liveness probe failed: Get "http://.../api/healthz": context deadline exceeded (Client.Timeout exceeded while awaiting headers)
Warning  Unhealthy  pod/api-...  Readiness probe failed: Get "http://.../api/healthz": context deadline exceeded ...
Normal   Killing    pod/api-...  Container api failed liveness probe, will be restarted
```

Repetido em pelo menos 5 pods diferentes durante o estágio "pico do gol". **Achado: o `timeoutSeconds` default de 1s (nem `readinessProbe` nem `livenessProbe` em `gitops/app/deployment.yaml` definiam um valor explícito) é curto demais frente à latência real observada sob saturação** (`p(95)=2,42s` no `endpoint:api` durante o pico) — quando o pod fica CPU-pressionado perto do teto de `maxReplicas: 6`, até o `/api/healthz` (endpoint trivial, sem I/O) passa a responder mais devagar que 1s às vezes, porque compete pelo mesmo CPU limitado do processo. O `kubelet` então mata pods que estavam **sobrecarregados, não travados** — exatamente o anti-padrão documentado nas boas práticas do Kubernetes para liveness probes ("não deveriam depender de condições que o próprio processo não controla sozinho, como contenção de CPU"). O efeito é auto-amplificador: perder um pod no meio do pico reduz a capacidade disponível bem na hora em que ela mais falta, o oposto do que o HPA está tentando fazer.

**Corrigido em `gitops/app/deployment.yaml`** (mesma branch/commit deste resultado): `readinessProbe.timeoutSeconds: 3`; `livenessProbe.timeoutSeconds: 5` + `failureThreshold: 5` (o liveness recebeu a folga maior porque é o único dos dois que **mata** o container — readiness só tira da rotação do Service, uma ação bem menos destrutiva sob sobrecarga transiente). Os valores foram calibrados acima do pior `p(95)` observado (2,42s) com margem.

**Não revalidado nesta sessão** — o fix ainda não foi confirmado com uma nova execução do `waves.js` (rodar de novo custa outros ~25-30 minutos). Candidato natural para a próxima vez que este cenário rodar: confirmar que os eventos `Unhealthy`/`Killing` somem do log durante o mesmo "pico do gol".

**Conclusão para o relatório final da Fase 6:** este foi o achado mais valioso desta fase em termos de "o que quebrou primeiro" — não foi capacidade agregada (o HPA absorveu o pico e devolveu a capacidade depois, como esperado), foi uma probe mal calibrada amplificando a própria saturação que o HPA estava tentando resolver.
