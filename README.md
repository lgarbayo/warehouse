# Warehouse — Intelligent Multi-Agent Warehouse Management

A multi-agent simulation of an automated warehouse in which a fleet of autonomous
robots stores and retrieves containers **without any central task assignment**.
Robots claim work independently through atomic mutual exclusion, coordinate access
to critical zones through a supervisor arbiter, and run a full outbound cycle when
storage saturates.

Built with **[Jason](https://jason-lang.github.io/) 3.3.0** (AgentSpeak / BDI) for
the agent layer and **Java 21+** for the physical environment.

---

## Table of Contents

- [Overview](#overview)
- [Key Features](#key-features)
- [Requirements](#requirements)
- [Running the Simulation](#running-the-simulation)
- [Architecture](#architecture)
  - [Agents](#agents-srcagt)
  - [Java Environment](#java-environment-srcenvwarehouse)
- [The Warehouse Model](#the-warehouse-model)
  - [Grid Layout](#grid-layout)
  - [Shelves](#shelves)
  - [Containers](#containers)
  - [Robots](#robots)
- [Coordination Mechanisms](#coordination-mechanisms)
- [The Outbound Cycle](#the-outbound-cycle)
- [Design Decisions](#design-decisions)
- [Project Structure](#project-structure)
- [Documentation](#documentation)

---

## Overview

The system simulates an automated warehouse on a 2D grid. Containers are generated
at random intervals at the entrance zone. A team of heterogeneous robots picks them
up, navigates the grid, and stores them on shelves that match each robot's capacity.
When shelves of a given category fill up, a scheduler triggers a **deadline-driven
outbound cycle**: robots empty the shelves into an outbound zone and a transport agent
simulates a truck collecting the goods.

The central design principle is **decentralized coordination**. There is no push-based
task dispatcher telling robots what to do. Instead, every robot perceives incoming
containers, decides locally whether a container fits its capacity, and races to claim
it. Mutual exclusion is guaranteed atomically by the Java environment, so at most one
robot ever picks up a given container — with no inter-agent negotiation required.

## Key Features

- **Decentralized, claim-based task allocation** — robots autonomously claim
  containers via `claim_container`, backed by an atomic `ConcurrentHashMap.putIfAbsent`.
- **Heterogeneous robot fleet** — light, medium, and two heavy robots, each with its
  own weight and size limits.
- **Capacity-aware storage** — shelves enforce both a maximum weight and a maximum
  volume; robots pick the least-loaded compatible shelf.
- **Zone mutual exclusion** — a supervisor agent arbitrates access to critical zones
  (inbound, expansion, outbound) through a `request_zone` / `zone_granted` /
  `release_zone` protocol.
- **Deadline-driven outbound cycle** — saturation triggers a timed evacuation phase,
  after which a transport agent clears the outbound zone.
- **Expansion fallback** — when every shelf of a category is full, containers overflow
  to an expansion zone; if that is full too, they are discarded and logged as an
  operational error.
- **Live visualization** — a Swing view renders the grid, robots, containers, and
  event log in real time.
- **Shared agent logic** — all common robot behaviour lives in a single `common.asl`
  included by every robot.

## Requirements

- **Java 21+**
- **Jason 3.3.0** (either installed on the `PATH`, or resolved via the bundled Gradle
  wrapper)

No manual compilation step is required: Jason compiles the `.asl` agents and the Java
environment on startup.

## Running the Simulation

### Option A — with a Jason installation

```bash
jason warehouse.mas2j
```

### Option B — with the Gradle wrapper (no local Jason install)

```bash
./gradlew run          # Linux / macOS
gradlew.bat run        # Windows
```

To build a self-contained runnable jar:

```bash
./gradlew shadowJar
java -jar build/libs/jason-warehouse-all.jar
```

> If you need to pin a specific JDK, uncomment and edit `org.gradle.java.home`
> in `gradle.properties`.

## Architecture

The project follows the standard Jason split between a **reasoning layer** (BDI agents
written in AgentSpeak) and an **environment layer** (a Java artifact exposing primitive
actions and emitting perceptions). The multi-agent system is declared in
`warehouse.mas2j`.

### Agents (`src/agt/`)

| Agent | Role |
|-------|------|
| `common.asl` | Shared logic included by all four robots: shelf selection (`!pick_shelf`), claim attempts (`!try_claim`), the full transport cycle, the exit cycle (`!execute_exit`), zone-mutex handling, and the expansion fallback (`!safe_expand_drop`). |
| `robot_light.asl` | Light robot — low weight/size capacity, fastest handling timing. |
| `robot_medium.asl` | Medium robot. |
| `robot_heavy.asl` | Heavy robot — highest capacity, slowest handling timing. |
| `robot_heavy2.asl` | Second heavy robot instance, for parallel throughput. |
| `scheduler.asl` | Owns the outbound cycle. On `storage_full` it activates a deadline, broadcasts it, and blocks the saturated type. On expiry it retracts the deadline and sends a `transport_request`. An internal mutex keeps only one outbound cycle active at a time. |
| `supervisor.asl` | Detects shelf saturation, monitors active deadlines (every 5 s), arbitrates access to critical zones, and emits a status report every 30 s. |
| `transport.asl` | Passive agent that clears the outbound zone on `transport_request` (deadline end) or `outbound_full` (reactive), plus a periodic safety sweep every 30 s. |

**How a robot decides to act:** when the environment broadcasts
`container_at_entrance`, each robot checks whether the container fits its capacity and
is still free, then calls `claim_container` in Java. Only the robot that wins the claim
proceeds. The destination shelf is selected locally by comparing `shelf_available` and
`shelf_occupancy` percepts and choosing the least-loaded compatible shelf.

### Java Environment (`src/env/warehouse/`)

| File | Responsibility |
|------|----------------|
| `WarehouseArtifact.java` | The core `Environment`: grid setup, container generator thread, all primitive actions, perception broadcasting, and navigation. |
| `WarehouseView.java` | Swing GUI rendering the grid, robots, containers, and event log. |
| `Robot.java` | Physical robot state — position, carried container, capacity metadata. |
| `Shelf.java` | Shelf state — dual weight/volume capacity and occupancy reporting. |
| `Container.java` | Container model and lifecycle (generated → claimed → stored → retrieved → collected). |
| `CellType.java` | Enum of cell types (`EMPTY`, `ENTRANCE`, `CLASSIFICATION`, `OUTBOUND`, `SHELF`, `BLOCKED`, …). |

**Primitive actions** exposed to agents include: `move_step`, `move_to_shelf`,
`move_to_container`, `pickup`, `drop_at`, `get_container_info`, `claim_container` /
`unclaim_container`, `pickup_from_shelf`, `move_to_outbound` / `drop_in_outbound`,
`move_to_expansion` / `drop_in_expansion`, `discard_container`, and
`collect_outbound_containers`.

## The Warehouse Model

### Grid Layout

The warehouse is a **20 × 15** cell grid. Fixed zones occupy the top rows:

| Zone | Cells | Purpose |
|------|-------|---------|
| Outbound | `x = 0–2, y = 0–1` | Drop-off point for the exit cycle; simulated truck pickup. |
| Classification | `x = 3–4, y = 0–1` | Intermediate staging area between entrance and shelves. |
| Entrance (inbound) | `x = 5–7, y = 0–1` | Spawn zone where containers appear. |

Robots start on row `y = 4` (positions 1–4). Navigation uses BFS with shelves treated
as obstacles, and a deterministic step ceiling (`nav_limit`, 300 steps) to prevent
runaway paths.

### Shelves

Shelves are laid out in three tiers, each enforcing **both** a maximum weight and a
maximum volume simultaneously (a container fits only if neither limit is exceeded):

| Tier | Footprint | Max weight | Max volume | Count |
|------|-----------|-----------:|-----------:|:-----:|
| Small  | 2 × 2 | 50  | 8  | 4 |
| Medium | 3 × 2 | 100 | 12 | 3 |
| Large  | 4 × 3 | 200 | 20 | 2 |

Occupancy is reported as the **maximum** of the weight-% and volume-% (whichever is the
bottleneck), which agents use to pick the least-loaded shelf.

### Containers

Containers spawn at the entrance every **5–10 seconds** with a randomized type
distribution:

- `standard` — 70%
- `fragile` — 15%
- `urgent` — 15%

Each container has a width, height, and weight. A container carries a `broken` flag if
it is crushed (a robot occupies its cell); crushed containers are removed but retain a
`container_broken` percept for auditing.

### Robots

| Robot | Max weight | Max size | Handling timing |
|-------|-----------:|:--------:|:---------------:|
| light   | 10  | 1 × 1 | fastest (500 ms) |
| medium  | 30  | 1 × 2 | 600 ms |
| heavy   | 100 | 2 × 3 | slowest (800 ms) |
| heavy2  | 100 | 2 × 3 | 800 ms |

Movement speed is uniform (300 ms/step); the per-type `speed` value is informational.
Real timing differences come from the `.wait()` delays in the handling phases,
simulating time proportional to the weight being moved.

## Coordination Mechanisms

- **Atomic claims.** `claim_container` uses `ConcurrentHashMap.putIfAbsent` so exactly
  one robot ever transports a given container — no consensus protocol needed.
- **`blocked_type`.** While an outbound cycle runs, robots stop accepting containers of
  the saturated type, coordinated indirectly (no direct robot-to-robot messaging).
- **Zone mutex.** The supervisor centralizes access to inbound, expansion, and outbound
  zones; robots wait for `zone_granted` rather than polling.
- **`exit_claimed`.** A second `ConcurrentHashMap` key prevents two robots from
  selecting the same container during the outbound cycle.

## The Outbound Cycle

When shelves saturate, storage must be evacuated:

1. The **supervisor** detects that the last shelf of a category has become unavailable
   and sends `storage_full` to the scheduler.
2. The **scheduler** activates a deadline, broadcasts it to all robots and the
   supervisor, and blocks the saturated type.
3. **Robots** retrieve containers from the shelves (`pickup_from_shelf`) and drop them
   in the outbound zone (`drop_in_outbound`).
4. On deadline expiry the scheduler retracts the deadline beliefs and sends a
   `transport_request`.
5. The **transport** agent runs `collect_outbound_containers`, removing every container
   from the outbound zone — simulating a truck pickup.

The cycle is **asymmetric by design**: saturating non-urgent shelves triggers the long
(non-urgent) phase, while saturating urgent shelves triggers the short (urgent) phase.
Phases are never mixed, because the urgent phase does not free space on non-urgent
shelves.

## Design Decisions

- **Atomic claiming over centralized dispatch.** The push model (scheduler → robot) was
  replaced by autonomous claiming. The scheduler no longer needs to know each robot's
  state; Java guarantees mutual exclusion directly.
- **Indirect coordination via `blocked_type`.** Prevents robots from accepting
  saturated-type containers without any direct robot-to-robot communication.
- **Zone mutex in the supervisor.** Centralizing access to inbound / expansion /
  outbound avoids collisions; robots block on `zone_granted` instead of busy-polling.
- **Graceful overflow.** `safe_expand_drop` + `discard_container`: if all shelves of a
  category and the expansion zone are full, the container is discarded and reported to
  the supervisor as an operational error, rather than deadlocking the robot.

## Project Structure

```
.
├── warehouse.mas2j              # Multi-agent system declaration
├── build.gradle                 # Gradle build (Jason + shadowJar)
├── settings.gradle
├── gradle.properties
├── gradlew / gradlew.bat        # Gradle wrapper
├── logging.properties
├── src/
│   ├── agt/                     # AgentSpeak (.asl) agents
│   │   ├── common.asl           # Shared robot logic
│   │   ├── robot_light.asl
│   │   ├── robot_medium.asl
│   │   ├── robot_heavy.asl
│   │   ├── robot_heavy2.asl
│   │   ├── scheduler.asl
│   │   ├── supervisor.asl
│   │   └── transport.asl
│   └── env/warehouse/           # Java environment
│       ├── WarehouseArtifact.java
│       ├── WarehouseView.java
│       ├── Robot.java
│       ├── Shelf.java
│       ├── Container.java
│       └── CellType.java
└── doc/
    └── memoria.pdf              # Full technical report
```

## Documentation

The complete technical report is available at `doc/memoria.pdf`.

---

*Developed as an academic project for an Intelligent Systems course
(University of Vigo, 2025–2026).*
