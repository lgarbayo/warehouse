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

## Qué hemos implementado

Partimos del proyecto base proporcionado y lo extendimos de forma sustancial. Los cinco agentes están completamente implementados y el entorno Java fue modificado en varios puntos críticos.

### Agentes (`src/agt/`)

**`scheduler.asl`** — Núcleo coordinador del sistema. Detecta la llegada de contenedores vía `new_container(CId)`, los clasifica en tres dimensiones (peso, tamaño, tipo) y asigna el robot y la estantería más adecuados. Usa un patrón de *goal* intermedio (`!process_new_container`) para capturar correctamente el caso en que un contenedor es aplastado antes de ser procesado. Implementa reintentos de asignación de estantería con límite de 3 intentos antes de notificar `no_shelf_space` al supervisor.

**`robot_light.asl` / `robot_medium.asl` / `robot_heavy.asl`** — Los tres siguen la misma arquitectura base: esperan en `idle` hasta recibir `task(CId, ShelfId)` del scheduler (modelo push), ejecutan el ciclo `move_to_container → pickup → move_to_shelf → drop_at` y notifican el resultado a scheduler y supervisor. Incluyen planes de fallo específicos para cada tipo de error del entorno. Al terminar cada tarea procesan la cola de tareas encoladas con `!check_queue`.

**`supervisor.asl`** — Agente puramente observador. Registra cada evento como un hecho individual en su base de creencias y calcula totales con `.count` en el momento del reporte, evitando condiciones de carrera. Emite un reporte cada 30 segundos con tasas de éxito/error y estado de los robots, consultado en tiempo real con `.askOne`.

### Entorno Java (`src/env/warehouse/`)

Los cambios más relevantes respecto a la base:

- **BFS con reserva de destinos** (`activeDestinations`): clave por coordenada `"(X,Y)"` en lugar de nombre de agente, con liberación garantizada en bloque `finally`.
- **`move_to_container` / `move_to_shelf`**: selección dinámica de celda adyacente, filtrando robots y contenedores en tránsito.
- **`findBestShelf`**: zonificación por peso (ligeros → shelf_1–4, medianos → shelf_5–7, pesados → shelf_8–9) con fallback por porcentaje de ocupación.
- **Mecánica de aplastamiento**: `doMoveTo` detecta contenedores en la celda destino, los elimina y emite `container_broken(CId)` globalmente.
- **`getAdyacentes` movido a `Container.java`** para respetar cohesión.
- API de percepciones migrada de `Literal.parseLiteral` a `ASSyntax.parseLiteral`.

---

## Decisiones de diseño destacadas

- **Push vs pull**: se eliminó el patrón `request_task` original. Los robots esperan pasivamente; el scheduler les asigna tareas directamente con `tell`.
- **Goal intermedio en scheduler**: necesario porque Jason no permite plan de fallo (`-!plan`) sobre triggers de creencia (`+belief`); el goal intermedio sí lo permite.
- **`[source(_)]` en supervisor**: se descubrió un bug donde el supervisor nunca disparaba porque esperaba `[source(robot_x)]` pero recibía `[source(scheduler)]`. Se corrigió usando wildcard `_`.
- **Clave de `activeDestinations`**: usar el nombre del agente como clave provocaba que los destinos quedaran bloqueados permanentemente si el agente fallaba antes del `finally`. La clave es la coordenada destino.

---

## Documentación

La memoria técnica completa está en `doc/memoria.pdf`.
