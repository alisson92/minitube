# Motivation — why this project exists

## The original question

It all started with a curiosity during the World Cup: **how does YouTube's infrastructure hold up under an event this size?** CazéTV's live match broadcasts broke the platform's simultaneous-audience records — millions of people watching the same live stream, at the same instant, with nothing going down.

The question that stuck was: *what happens under the hood to make that work?*

## The physics of the problem

A 1080p stream consumes on the order of 5 Mbps per viewer. Multiply that by millions of simultaneous viewers, and aggregate traffic reaches the **terabits-per-second** range — no single server or datacenter is capable of serving that.

YouTube's answer (and that of any streaming platform at scale) rests on a few principles:

1. **Video is cacheable.** The same 4-second segment is identical for everyone. That lets the load be absorbed at the edge (CDN), close to the viewer — in Google's case, with cache servers installed inside ISPs themselves (Google Global Cache).
2. **Every layer filters traffic.** The vast majority of requests die at the edge cache. Only *cache misses* make it down to global load balancing (anycast) and, finally, to the origin.
3. **The origin scales horizontally.** Container clusters (Borg, Kubernetes' predecessor) with autoscaling, a distributed transcoding pipeline (each video becomes dozens of quality variants served as HLS/DASH segments), and SRE practices — SLOs, error budgets, incident response.

## What this project reproduces

**MiniTube** is a miniature reproduction of that architecture, built from scratch, to practice cloud-native DevOps and SRE disciplines in an integrated way:

| Real-world piece (YouTube)          | MiniTube equivalent                       |
| ------------------------------------- | --------------------------------------------- |
| Google Global Cache / CDN             | CloudFront serving HLS segments             |
| Video storage at scale                | S3 as the segment origin                  |
| Borg (container clusters)        | EKS (managed Kubernetes on AWS)            |
| Transcoding pipeline          | FFmpeg Job producing HLS variants          |
| Fleet-scale deploys                     | GitOps with Argo CD                             |
| Monitoring and SRE                     | Prometheus, Grafana, Loki, SLOs               |
| The crowd arriving for the goal             | k6 load tests in waves                 |

The end goal is to **watch "game day" through the dashboards**: fire off traffic waves simulating the crowd, watch the edge absorb the load, autoscaling react, and SLOs behave — like an SRE on call.

## Why the infrastructure is ephemeral

The project runs on real cloud (AWS) because cost, networking, and IAM are part of the learning. But managed services like EKS bill for the control plane **even with the cluster idle** — and that's exactly where Terraform closes the loop: at the end of every test run, a `terraform destroy` tears everything down and zeroes out the cost.

That's not a limitation — it's the project's quality test: if destroying and recreating the environment hurts, the infrastructure-as-code isn't good enough yet.

## Questions I want to be able to answer by the end

- Why does edge caching make an event like the World Cup viable at all, and how do you measure that (hit ratio)?
- How does a Kubernetes cluster actually react to a sudden traffic wave (HPA, node provisioning)?
- How do you define and monitor latency and availability SLOs for a streaming service?
- What breaks first under load — and how does an SRE investigate and respond to it?
