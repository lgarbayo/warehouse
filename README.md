# Warehouse — Solución Grupo SI 8-2

**Universidad de Vigo · Sistemas Inteligentes · 2025-2026**

Luis Garbayo Fernández, Yerai Fernández Rodríguez, Alberto Andrés Faublak Álvarez, Vincenzo Gagliano, Eva Barreiro Ferreira

---

## Ejecución

**Requisitos:** Java 21+ y Jason 3.3.0

```bash
cd warehouse
jason warehouse.mas2j
```

No se requiere ningún paso de compilación previo: Jason compila los agentes `.asl` y el entorno Java al arrancar.

---

## Estado de la entrega (iteración 2)

Esta entrega extiende la solución de la iteración 1 con un ciclo de salida completo y una arquitectura de coordinación distribuida. Los cambios principales respecto a la iteración anterior son:

- **Cuatro robots** en lugar de tres: se añade `robot_heavy2` como segunda instancia del robot pesado.
- **Coordinación distribuida**: los robots ya no reciben tareas del scheduler. Reclaman contenedores de forma autónoma mediante `claim_container` (exclusión mutua atómica en Java).
- **Ciclo de salida**: cuando el almacén satura, el scheduler activa un deadline; los robots sacan contenedores de las estanterías y los depositan en la zona OUTBOUND.
- **Agente transport** (nuevo): simula la recogida por camión al finalizar cada deadline.
- **Código compartido** (`common.asl`): toda la lógica común de los robots reside en un único fichero incluido con `{ include("common.asl") }`.

---

## Agentes (`src/agt/`)

**`common.asl`** — Código compartido por los cuatro robots. Incluye la selección autónoma de estantería (`!pick_shelf`), el intento de reclamo (`!try_claim`), el ciclo de transporte completo, el ciclo de salida (`!execute_exit`), la gestión del mutex de zonas y el fallback de expansión (`!safe_expand_drop`).

**`robot_light.asl` / `robot_medium.asl` / `robot_heavy.asl` / `robot_heavy2.asl`** — Declaran capacidades propias (peso máximo, dimensiones, velocidad) e incluyen `common.asl`. Cuando el entorno emite `container_at_entrance`, cada robot evalúa si el contenedor entra en su capacidad y si está libre; si es así, ejecuta `claim_container` en Java. Solo el robot que obtiene el reclamo procede. La estantería de destino se selecciona localmente comparando `shelf_available` y `shelf_occupancy`.

**`scheduler.asl`** — Gestiona exclusivamente el ciclo de salida. Al recibir `storage_full` del supervisor, activa un deadline (`active_deadline`) difundido a todos los robots y al supervisor, y bloquea el tipo saturado (`blocked_type`) para que los robots no sigan aceptando ese tipo. Al expirar el deadline, retira las creencias y envía `transport_request` al agente transport. Un mutex interno garantiza que solo un ciclo de salida esté activo en cada instante.

**`supervisor.asl`** — Detecta la saturación de estanterías reaccionando a la retracción de `shelf_available`; si no quedan estanterías del mismo tipo, envía `storage_full` al scheduler. Monitoriza los deadlines activos cada 5 segundos y registra `deadline_missed` si expiran con contenedores pendientes. Actúa como árbitro centralizado para el acceso a zonas críticas (inbound, expansion, outbound) mediante el protocolo `request_zone` / `zone_granted` / `release_zone`. Emite un reporte de estado cada 30 segundos.

**`transport.asl`** — Agente pasivo. Reacciona a `transport_request` (fin de deadline) y a `outbound_full` (zona llena, recogida inmediata reactiva). Ejecuta `collect_outbound_containers`, que elimina físicamente todos los contenedores del OUTBOUND. Realiza además una recogida periódica cada 30 segundos como salvaguarda.

---

## Entorno Java (`src/env/warehouse/`)

Cambios respecto a la iteración 1:

- **`claim_container` / `unclaim_container`**: reclamo atómico mediante `ConcurrentHashMap.putIfAbsent`. Garantiza que a lo sumo un robot recoge cada contenedor, sin coordinación entre agentes.
- **`pickup_from_shelf`**: extrae un contenedor de una estantería para el ciclo de salida.
- **`move_to_outbound` / `drop_in_outbound`**: calcula la celda libre más cercana de la zona OUTBOUND y deposita el contenedor; emite `outbound_full` si no hay hueco.
- **`move_to_expansion` / `drop_in_expansion`**: gestiona la zona de expansión cuando todas las estanterías de una categoría están llenas; emite `expansion_free_cell(D,X,Y)` con la distancia Manhattan precalculada.
- **`collect_outbound_containers`**: elimina del sistema todos los contenedores presentes en la zona OUTBOUND.
- **`exit_claimed`**: clave en `ConcurrentHashMap` análoga a `claim_container` para evitar que dos robots seleccionen el mismo contenedor en el ciclo de salida.
- **`nav_limit(300)`**: límite determinista de pasos de navegación que reemplaza la señal `nav_abort_signal` de la iteración 1.
- **Broadcast de percepciones**: `container_at_entrance`, `shelf_available` y `shelf_occupancy` se emiten ahora a todos los agentes (no solo al scheduler).

---

## Decisiones de diseño destacadas

- **Reclamo atómico vs. asignación centralizada**: se eliminó el modelo push (scheduler → robot) de la iteración 1. El scheduler ya no necesita conocer el estado de cada robot; la exclusión mutua la garantiza Java directamente.
- **`blocked_type`**: impide que los robots sigan aceptando contenedores del tipo saturado mientras el ciclo de salida está activo, sin necesidad de comunicación directa entre robots.
- **Diseño asimétrico del ciclo de salida**: cuando saturan las estanterías no urgentes, el scheduler activa la fase larga (non_urgent); cuando saturan las urgentes, activa la fase corta (urgent). No se mezclan fases porque la fase urgente no libera espacio en estanterías no urgentes.
- **Mutex de zonas en supervisor**: centraliza el acceso a inbound, expansion y outbound para evitar colisiones; los robots no hacen polling sino que esperan `zone_granted`.
- **`safe_expand_drop` + `discard_container`**: si todas las estanterías de una categoría están llenas y la zona de expansión también, el contenedor se descarta y se notifica al supervisor como error operacional.

---

## Documentación

La memoria técnica completa está en `doc/memoria.pdf`.
