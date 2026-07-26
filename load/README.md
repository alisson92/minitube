# load/

Cenários de teste de carga k6 da Fase 6 ("dia do jogo"). Cada script `run-*.sh` orquestra: encontra (ou cria) um vídeo real já transcodificado (`lib/find-or-create-video.sh`), roda o cenário k6 correspondente em `k6/`, e limpa qualquer recurso temporário ao final (`trap ... EXIT`).

| Script | Cenário k6 | Onde o k6 roda | Runbook |
| ------ | ---------- | --------------- | ------- |
| `run-baseline.sh` | `k6/baseline.js` — carga pequena e crescente, sem intenção de quebrar nada | Local (máquina do operador) | [`docs/runbooks/load/run-k6-baseline.md`](../docs/runbooks/load/run-k6-baseline.md) |
| `run-breakpoint.sh` | `k6/breakpoint.js` — rampa até quebrar | Local | [`docs/runbooks/load/run-k6-breakpoint.md`](../docs/runbooks/load/run-k6-breakpoint.md) |
| `run-breakpoint-from-ec2.sh` | `k6/breakpoint.js` (mesmo cenário) | EC2 efêmera dentro da VPC (via SSM, sem IP público) | mesmo runbook acima |
| `run-waves-from-ec2.sh` | `k6/waves.js` — audiência subindo e descendo em ondas | EC2 efêmera dentro da VPC | [`docs/runbooks/load/run-k6-waves.md`](../docs/runbooks/load/run-k6-waves.md) |

## Por que a cobertura local vs. EC2 é assimétrica

Não é uma lacuna — é o resultado direto de um problema real encontrado nesta fase, documentado em detalhe em `run-k6-breakpoint.md` (seção "Investigação da latência"): rodar o k6 localmente (operador → WSL2 → ISP residencial → internet → AWS) soma ruído de rede que o lado do servidor nunca vê. O primeiro `run-breakpoint.sh` local abortou com `p95=1s`/`max=7.54s`, enquanto o `TargetResponseTime` da ALB e a latência interna da própria API (Prometheus) permaneceram rápidos (≤145ms/≤0,5s) na mesma janela — a lentidão estava no caminho cliente→AWS, não no serviço.

Isso explica por que cada script tem a cobertura que tem, não mais nem menos:

- **`baseline.js` nunca precisou de variante EC2.** É uma carga pequena e deliberadamente não-agressiva, já validada estável (0% de erro) mesmo rodando local — o ruído de rede do caminho local nunca chegou perto de mascarar o resultado.
- **`breakpoint.js` tem as duas variantes** porque foi exatamente esse cenário que expôs o problema: a versão local existe (e documenta o próprio investigação), mas a versão EC2 (`run-breakpoint-from-ec2.sh`) é a que produz o resultado confiável usado para dimensionar o HPA (ADR 012).
- **`waves.js` só tem a variante EC2.** Criado depois da lição acima já estar registrada — rodá-lo local desde o início introduziria o mesmo ruído conhecido, especialmente nos estágios de descida ("scale-down"), onde distinguir latência real de ruído de rede importa tanto quanto no pico. Não existe (nem faz sentido criar) um `run-waves.sh` local só por simetria.

Os dois scripts `-from-ec2` reaproveitam o mesmo padrão de EC2 efêmera via SSM (subnet privada, sem SSH/bastion, sempre terminada via `trap`) já usado por `terraform/envs/lab/scripts/validate-network.sh` — nenhum recurso Terraform novo foi criado para eles.
