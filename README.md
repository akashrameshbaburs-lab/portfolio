# Portfolio Projects — Engineering Showcase

Five production-style projects by [Akash RameshBabu](https://github.com/akashrameshbaburs-lab), each self-contained with its own git history, Docker-based one-command startup, real end-to-end verification, and measured results (no invented numbers).

| # | Project | What it proves | Stack | Status |
|---|---------|----------------|-------|--------|
| 1 | **[scalex](https://github.com/akashrameshbaburs-lab/scalex)** | Load-tested backend: 1,000+ RPS sustained at **p95 2.25 ms**, 0% errors, 100% Redis cache hit | Node 22, TS, PostgreSQL, Redis, Nginx LB, k6 | ✅ done |
| 2 | **[queueease](https://github.com/akashrameshbaburs-lab/queueease)** | Live clinic queue: WebSockets, OTP auth, wait-time prediction, EN/TA multilingual UI | Node 22, TS, Socket.IO, PostgreSQL | ✅ done |
| 3 | **[deployhub](https://github.com/akashrameshbaburs-lab/deployhub)** | Mini PaaS: git → live URL with isolated Docker-in-Docker builds, reverse proxy, rollback, SSE logs, auto-sleep | Node 22, TS, BullMQ, dockerode, PostgreSQL, Redis | ✅ done |
| 4 | **[documind](https://github.com/akashrameshbaburs-lab/documind)** | RAG document Q&A: pgvector hybrid retrieval, page-cited answers, 50-question eval at **100% Hit@3** — fully offline extractive mode *and* self-hosted GPU mode (Qwen2.5-1.5B on an RTX 3070, $0 API cost) | Node 22, TS, PostgreSQL + pgvector, PyTorch sidecar | ✅ done |
| 5 | **[streamguard](https://github.com/akashrameshbaburs-lab/streamguard)** | Real-time fraud detection: RabbitMQ pipeline, rules + logistic-regression fusion at **precision 0.758 / recall 0.534**, **p95 109 ms** detection latency, 20 evt/s, hot-reloading model | Python 3.12, FastAPI, RabbitMQ, scikit-learn, PostgreSQL | ✅ done |

## Running anything

Each project is its own repository — clone any of them:

```powershell
git clone https://github.com/akashrameshbaburs-lab/scalex.git
cd scalex
docker compose up --build -d     # or: .\scripts\demo.ps1 for a full scripted demo
```

Requirements: Docker Desktop running. Ports are pre-assigned per project so all stacks can run simultaneously:

| Project | App | Database |
|---|---|---|
| scalex | 8080 | 5432, 6379 |
| queueease | 3100 | 5433 |
| documind | 3200 | 5434 (+ 8100 with GPU mode) |
| streamguard | 3300 | 5435, 5673, 15673 |
| deployhub | 3001 | 5436, 6380 |

Every project ships: `README.md` (problem, architecture, API, results), `docs/` (architecture deep-dive + project-specific design notes), `LICENSE` (MIT), `SECURITY.md`, `.env.example`, a GitHub Actions CI workflow (build + unit tests + compose validation), a unit test suite (`npm test` / `pytest`, no framework dependencies), and a `scripts/demo.ps1` that exercises the system end-to-end.

## Portfolio demo (one command)

This repository is the showcase: it holds the portfolio index and the one-command demo script. Clone the five project repositories **next to each other** (siblings of `demo.ps1`), then:

```powershell
powershell -ExecutionPolicy Bypass -File demo.ps1          # fast: live signature check of all five
powershell -ExecutionPolicy Bypass -File demo.ps1 -Full    # also runs every project's full suite
```

The showcase brings up each stack (reusing healthy containers), exercises a signature flow per project — URL shorten/redirect with live latency percentiles, clinic OTP→queue→call flow, sample-app build→deploy→rollback, PDF upload→question→cited answer, StreamGuard pipeline health — and prints a scorecard of numbers **measured in that run**. The `-Full` switch additionally runs every project's complete `scripts/demo.ps1` (ScaleX k6 load test, QueueEase 24-check e2e, DeployHub deploy+rollback drill, DocuMind RAG suite, StreamGuard e2e + evaluation).

Last full showcase run: **29/29 checks passed** (2026-10-20, Windows + Docker Desktop).
