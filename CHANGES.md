# Changes

## Nota de diseño: distancia Manhattan como heurística implícita de navegación

El plan `!do_step` elige en cada paso el eje con mayor distancia restante al destino:

```agentspeak
// Prioridad X si |dx| >= |dy|
+!do_step(X, Y, TX, TY) : TX > X & TX - X >= TY - Y <- !try_x_then_y(...)
+!do_step(X, Y, TX, TY) : TY > Y                     <- !try_y_then_x(...)
```

Esto es equivalente a usar la **distancia Manhattan** como función heurística:
```
h(n) = |TX - X| + |TY - Y|
```

La distancia Manhattan es una heurística **admisible** — nunca sobreestima el coste real porque en un grid ortogonal ningún camino puede ser más corto que la suma de las diferencias en cada eje. Esta propiedad es la que Russell & Norvig (Cap. 4) requieren para que A* garantice la solución óptima.

La diferencia con A* es que el greedy Manhattan no hace backtracking: si el paso preferido está bloqueado, prueba el eje secundario, y si ambos fallan, `!step_with_retry` espera y reintenta. No explora caminos alternativos — confía en que el entorno se despejará. Esto es correcto para un almacén dinámico donde los obstáculos principales son otros robots en movimiento.

---

## Nota de diseño: fallo de retorno a base no se reporta al supervisor

El plan `-!check_queue : not task(_, _)` absorbe silenciosamente cualquier fallo de navegación al volver a la posición base, pasando el robot a `idle` desde donde esté. No se reporta al supervisor porque el retorno a base es una funcionalidad de comodidad — si el robot no puede volver, sigue operativo para la siguiente tarea desde su posición actual. Reportarlo contaminaría `total_errors` con algo que no es un error real de la operación.

En la práctica, este plan nunca se ha activado: los robots siempre han llegado correctamente a su posición base. Existe como red de seguridad defensiva para el caso extremo de bloqueo permanente de la posición base.

---

## Sustitución del algoritmo de pathfinding: BFS → Movimiento coordinado con waypoints

### Problema
El algoritmo BFS (`calcularRuta`) utilizado para la navegación de robots era inadecuado:
- Requería estructuras de datos proporcionales al tamaño del grid: `HashMap<List<Integer>, List<Integer>>` para rastrear padres y `ArrayDeque` para la cola de exploración. En el peor caso exploraba los 300 nodos del grid (20×15) por cada paso.
- Calculaba la ruta completa de una vez aunque solo se necesitara el siguiente paso.
- La reconstrucción de la ruta (`construirRutaFinal`) añadía una pasada adicional hacia atrás sobre el mapa de padres.

### Solución: movimiento coordinado inspirado en el robot doméstico

Se reemplazaron `calcularRuta` y `construirRutaFinal` por tres métodos nuevos:

#### `nextCoordinateStep(fromX, fromY, toX, toY, avoidRobots)`
Calcula el siguiente paso en O(1) sin estructuras auxiliares, siguiendo el mismo principio que el `moveTowards` del robot doméstico de Jason:

```java
int dx = Integer.compare(toX, fromX);  // -1, 0 o +1
int dy = Integer.compare(toY, fromY);  // -1, 0 o +1
boolean xFirst = Math.abs(toX - fromX) >= Math.abs(toY - fromY);
```

Se prioriza el eje con mayor distancia Manhattan restante. Si ese eje está bloqueado, se intenta el perpendicular. Si ambos están bloqueados, devuelve lista vacía y el robot cede el paso.

A diferencia del robot doméstico (entorno sin obstáculos), este método delega la comprobación de obstáculos en `isFreeStep`.

#### Comportamiento visual: escalera diagonal ("zigzag")
Al alternar entre los dos ejes según cuál tiene mayor distancia restante, el robot traza el camino diagonal más corto posible en un grid ortogonal. Visualmente produce un patrón de escalera — una secuencia de pasos horizontales y verticales alternados que converge en diagonal hacia el destino. Esto no es un error sino el equivalente Manhattan de una línea recta diagonal, y es exactamente el comportamiento del robot doméstico.

#### `isFreeStep(x, y, avoidRobots)`
Comprueba que una celda es transitable:
1. Dentro del mapa
2. No es `SHELF` ni `BLOCKED`
3. No tiene un contenedor no recogido (`hayContenedorEn`)
4. Si `avoidRobots=true`, no está ocupada por otro robot

La comprobación de contenedores es crítica: sin ella el greedy navega en línea recta a través de la celda del contenedor destino aplastándolo antes de recogerlo. El BFS original incluía `!hayContenedorEn` al expandir nodos por la misma razón. Al restaurar esta comprobación, si la ruta directa pasa por la celda del contenedor `doMoveTo` falla, y `executeMoveToContainer` prueba automáticamente la siguiente celda adyacente libre.

#### `computeWaypointPath(fromX, fromY, toX, toY)`
En la zona de almacenamiento (x≥10) las estanterías forman filas compactas que el greedy no puede atravesar. Se usa `x=9` como corredor vertical siempre libre (no hay estanterías en x<10) y los corredores horizontales del layout como puntos de paso seguros:

```
y=1   — sobre estanterías pequeñas  (x=10..17, y=2-3)
y=4-5 — entre pequeñas y medianas
y=8-9 — entre medianas y grandes
y=13  — bajo estanterías grandes    (x=10..17, y=10-12)
```

Para cualquier destino en la zona de almacenamiento el path es:
```
posición_actual → (9, targetY) → (targetX, targetY)
```

El primer waypoint `(9, targetY)` garantiza que el robot entra al pasillo correcto antes de deslizarse horizontalmente. Si el robot ya está en el mismo corredor que el destino (`fromY == targetY` y es fila de corredor libre), va directo sin waypoint intermedio.

### Acceso a estanterías desde el corredor inferior

`executeMoveToShelf` itera las celdas adyacentes a la estantería en el orden: fila superior → fila inferior → laterales. En condiciones normales el robot accede desde el corredor superior (p.ej. y=5 para estanterías medianas). Si ese corredor está bloqueado por contenedores soltados (p.ej. por `shelf_full`), `doMoveTo` falla para esas celdas y `executeMoveToShelf` prueba automáticamente las del corredor inferior (p.ej. y=8). El depósito funciona igual desde cualquier lado: `drop_at` solo comprueba distancia, no dirección de acceso.

### Resumen de cambios en `WarehouseArtifact.java`

| Eliminado | Añadido |
|---|---|
| `calcularRuta` (BFS, O(W×H)) | `nextCoordinateStep` (greedy coordinado, O(1)) |
| `construirRutaFinal` | `isFreeStep` |
| — | `computeWaypointPath` |
| — | `isCorridorRow` |

El método `doMoveTo` se refactorizó para navegar waypoint a waypoint usando `nextCoordinateStep` en cada iteración, manteniendo la misma lógica de yield (espera 1s si bloqueado por robot, activa `avoidRobots=true` tras 3s).

---

## Corrección de entorno grueso: asignación de estanterías movida al agente scheduler

### Problema
El entorno tenía `findBestShelf()` y `executeGetFreeShelf()` en `WarehouseArtifact.java`. El scheduler simplemente llamaba `get_free_shelf(CId)` y el entorno decidía qué estantería asignar — filtrando por categoría, ordenando por ocupación y devolviendo la mejor. Esto es entorno grueso: el entorno realizaba razonamiento que corresponde al agente.

### Solución

#### Entorno: solo expone percepciones primitivas

Se eliminaron `findBestShelf`, `executeGetFreeShelf` y el case `"get_free_shelf"`. En su lugar el entorno emite dos tipos de percepción al scheduler:

- **`shelf_available("shelf_1")`** — se emite al inicializar cada estantería y se retira con `removePerceptsByUnif` cuando `shelf.isFull()` tras un `drop_at`. Indica simplemente que la estantería tiene capacidad.
- **`shelf_occupancy("shelf_1", 42)`** — el porcentaje de ocupación actual redondeado a entero. Se emite al inicializar (0%) y se actualiza tras cada `drop_at` exitoso. Dato puro: el entorno mide, no interpreta.

#### Scheduler: razona sobre qué estantería usar

Se añaden creencias estáticas que representan el conocimiento propio del agente sobre el layout del almacén:

```agentspeak
shelf_category("shelf_1", light).
shelf_category("shelf_2", light).
shelf_category("shelf_3", light).
shelf_category("shelf_4", light).
shelf_category("shelf_5", medium).
shelf_category("shelf_6", medium).
shelf_category("shelf_7", medium).
shelf_category("shelf_8", heavy).
shelf_category("shelf_9", heavy).
```

La lógica de asignación se implementa con cuatro planes `+!assign_shelf` que Jason prueba en orden:

1. **Ligero** (`Weight ≤ 10, W ≤ 1, H ≤ 1`) → estanterías `light`
2. **Mediano** (`Weight ≤ 30, W ≤ 1, H ≤ 2`) → estanterías `medium`
3. **Pesado/grande** → estanterías `heavy`
4. **Fallback anti-starvation** → cualquier estantería disponible (si la categoría preferida está llena)

Los planes 1-3 usan la variable `ExS` en la guardia para verificar que existe al menos una estantería de la categoría con disponibilidad (`shelf_category(ExS, Cat) & shelf_available(ExS)`). Si la guardia falla, Jason prueba automáticamente el siguiente plan — el fallback entre categorías es implícito, igual que en el antiguo `findBestShelf`.

#### Plan auxiliar `+!pick_least_occupied`

Para elegir entre todas las estanterías disponibles de una categoría se replica el criterio de `findBestShelf` (ordenar por ocupación, tomar la de menor carga):

```agentspeak
+!pick_least_occupied(CId, Cat) <-
    .findall(pair(Occ, S),
             (shelf_category(S, Cat) & shelf_available(S) & shelf_occupancy(S, Occ)),
             Pairs);
    .sort(Pairs, [pair(_, ShelfId)|_]);
    +free_shelf(CId, ShelfId).
```

`.findall` recoge todos los pares `(ocupación, id)`. `.sort` los ordena por el primer argumento del término `pair` — Jason compara términos compuestos argumento a argumento, por lo que `pair(0,"shelf_2") < pair(15,"shelf_1")`. El primer elemento de la lista ordenada es siempre la menos ocupada.

Se usa `pair(Occ, S)` como functor explícito en lugar de `Occ-S` porque Jason evalúa el operador `-` como aritmética, lo que produce `ArithExpr: value is not a number` al intentar restar un átomo de un número.

### Resumen de cambios

| Archivo | Eliminado | Añadido |
|---|---|---|
| `WarehouseArtifact.java` | `findBestShelf`, `executeGetFreeShelf`, case `"get_free_shelf"` | `emitShelfAvailable`, `emitShelfOccupancy` |
| `scheduler.asl` | `get_free_shelf(CId)` | `shelf_category` beliefs, 4 planes `assign_shelf`, `pick_least_occupied` |

---

## Corrección de bloqueo en supervisor: eliminar `askOne` en `!print_robot_status`

### Problema

`!print_robot_status` usaba `.send(robot_X, askOne, state(S), state(S))` para obtener el estado de cada robot en el momento del reporte. `askOne` es bloqueante: suspende la intención del supervisor hasta recibir respuesta. Si un robot está ejecutando un plan largo (navegando, esperando en `.wait`, etc.), el supervisor queda paralizado durante ese tiempo, bloqueando también el procesamiento de mensajes entrantes (`container_stored`, `container_error`, `robot_state_change`).

### Solución

El supervisor ya mantiene `robot_status(Robot, Status)` actualizado de forma reactiva mediante el plan `+robot_state_change(Robot, Status)`, que los robots disparan en cada transición de estado. `!print_robot_status` ahora lee directamente esa creencia local:

```agentspeak
+!print_robot_status : true <-
    ?robot_status(robot_light,  SL);
    ?robot_status(robot_medium, SM);
    ?robot_status(robot_heavy,  SH);
    .print("  robot_light: ",  SL);
    .print("  robot_medium: ", SM);
    .print("  robot_heavy: ",  SH).
```

Sin mensajes, sin bloqueos, sin dependencia de disponibilidad de los robots.

### Resumen de cambios

| Archivo | Cambio |
|---|---|
| `supervisor.asl` | `!print_robot_status`: sustituidos tres `.send(askOne)` por tres `?robot_status` |

---

## Corrección de entorno grueso: navegación movida al agente (Opción B)

### Problema
La navegación completa (`doMoveTo`, `nextCoordinateStep`, `computeWaypointPath`, `isCorridorRow`) vivía en `WarehouseArtifact.java`. El entorno decidía qué dirección tomar en cada paso, cuándo usar waypoints y cuándo esperar a un robot bloqueante — razonamiento que corresponde al agente.

### Solución

#### Entorno: solo expone primitivas físicas

Se eliminaron todos los métodos de navegación. El entorno ahora expone:

- **`move_step(X, Y)`** — primitiva atómica: mueve el robot exactamente una celda a (X,Y). Falla si la celda está ocupada por otro robot o es obstáculo fijo. Aplasta contenedores no recogidos. Emite `robot_pos(X,Y)` tras el movimiento.
- **`move_to_shelf(ShelfId)`** — ya no navega: calcula la primera celda adyacente a la estantería y emite `nav_target(X,Y)`.
- **`move_to_container(CId)`** — igual: emite `nav_target(X,Y)` con la primera celda adyacente al contenedor.

Se eliminó también `return_to_base(X,Y)` (acción Java), reemplazada por `!navigate` en el agente. Se eliminó `activeDestinations` (ya no se necesita coordinación de destinos en Java).

La posición inicial de cada robot se emite como percepción `robot_pos(X,Y)` al arrancar para que los planes de navegación tengan el valor desde el primer ciclo.

#### Agentes: razonan sobre cada paso de navegación

Los tres robots reciben la misma sección de navegación autónoma:

```agentspeak
corridor_row(1). corridor_row(4). corridor_row(5).
corridor_row(8). corridor_row(9). corridor_row(13). corridor_row(14).

+!navigate(TX, TY) : robot_pos(TX, TY) <- true.
+!navigate(TX, TY) : TX >= 10 & robot_pos(X, Y) & not (Y == TY & corridor_row(TY)) <-
    !navigate(9, TY);
    !navigate(TX, TY).
+!navigate(TX, TY) : robot_pos(X, Y) <-
    !step_with_retry(X, Y, TX, TY, 0);
    !navigate(TX, TY).
```

El segundo plan replica la lógica de waypoints de `computeWaypointPath`: para destinos en la zona de almacenamiento (TX≥10), si no estamos ya en el corredor correcto, pasar primero por (9, TY) y luego deslizarse horizontalmente.

`!step_with_retry` intenta `!do_step`; si falla (celda ocupada por otro robot), espera 1 s y reintenta hasta 6 veces. Al agotar reintentos, envía `robot_error(path_blocked)` al supervisor y consulta `?nav_abort_signal` (creencia inexistente) para propagar el fallo hacia `!execute_task` → `-!execute_task` → `task_failed` al scheduler.

`!do_step` elige la dirección prioritaria (eje con mayor distancia Manhattan restante). `!try_x_then_y` / `!try_y_then_x` intentan el eje primario y, si `move_step` falla, el secundario como fallback. Si ambos fallan, `!step_with_retry` reintenta.

El flujo de `execute_task` se actualiza para leer `?nav_target` tras cada acción de movimiento y llamar `!navigate`:

```agentspeak
move_to_container(CId);
?nav_target(TX1, TY1);
!navigate(TX1, TY1);
// ...
move_to_shelf(ShelfId);
?nav_target(TX2, TY2);
!navigate(TX2, TY2);
```

`!check_queue` reemplaza `return_to_base(InitX, InitY)` por `!navigate(InitX, InitY)`.

### Resumen de cambios

| Archivo | Eliminado | Añadido |
|---|---|---|
| `WarehouseArtifact.java` | `doMoveTo`, `nextCoordinateStep`, `computeWaypointPath`, `isCorridorRow`, `isFreeStep`, `executeReturnToBase`, `activeDestinations`, case `return_to_base` | `executeMoveStep`, `emitNavTarget`, case `move_step`, emit `robot_pos` en init |
| `robot_{light,medium,heavy}.asl` | `return_to_base(...)` en `check_queue` | sección de navegación completa (`corridor_row`, `!navigate`, `!step_with_retry`, `!do_step`, `!try_x_then_y`, `!try_y_then_x`), `?nav_target` + `!navigate` en `execute_task` |

---

## Corrección de bloqueo en zona de entrada: nav_target obsoleto y cascada de fallos

### Problema

Al probar el sistema con varios contenedores medianos seguidos se producía un bloqueo total: `robot_medium` informaba `path_blocked` y a partir de ahí ningún contenedor más avanzaba. La causa real era una combinación de tres factores:

1. **Condición de carrera en `nav_target`**: `move_to_container(CId)` calcula la celda adyacente libre en el instante T y emite `nav_target(TX, TY)`. Si entre T y el momento en que el robot llega a esa celda (≈3 s a 300 ms/paso) un contenedor nuevo se genera justo en ese punto, `move_step` falla en cada reintento. Tras 6 reintentos (6 s) se dispara `path_blocked`. El `nav_target` computado ya no es válido pero el robot no lo recomputa.

2. **Sin retroceso ante el fallo**: `-!execute_task` enviaba `task_failed` al scheduler, que reasignaba el contenedor de inmediato. El robot volvía a intentarlo desde una posición intermedia en la zona congestionada, obtenía el mismo `path_blocked` en <1 s, y así sucesivamente. La secuencia completa de contenedores encolados (4, 5, 6…) fallaba en cadena con intervalos de 2 s.

3. **Preferencia equivocada de `nav_target`**: `getAdyacentes` ordenaba: arriba (y-1), abajo (y+1), izquierda, derecha. Para contenedores en la fila superior de la zona de entrada (y=0) la celda "arriba" (y=-1) es inválida y la siguiente candidata era la celda lateral a y=0, que puede estar bloqueada por más contenedores. La celda "abajo" (y=1, lado por el que se aproxima el robot) era la más accesible pero se evaluaba segunda.

### Solución

#### 1. Sub-goal `!get_to_container` con reintento de `nav_target`

Se extrae la fase de navegación al contenedor en los tres robots a un sub-goal independiente que recomputa `nav_target` en cada reintento:

```agentspeak
+!get_to_container(CId, N) : N > 0 <-
    move_to_container(CId);
    ?nav_target(TX, TY);
    !navigate(TX, TY).

-!get_to_container(CId, N) : N > 1 <-
    .wait(5000);
    N1 = N - 1;
    !get_to_container(CId, N1).
// N <= 1: sin plan de fallo → falla hacia -!execute_task
```

Se invoca con `!get_to_container(CId, 3)`. Cubre dos casos:
- `move_to_container` devuelve false (todas las celdas adyacentes ocupadas): espera y reintenta.
- `!navigate` falla con `path_blocked` (la celda que era libre cuando se calculó el `nav_target` ahora tiene un contenedor): recomputa el `nav_target` con el estado actual del entorno y vuelve a navegar.

#### 2. `!safe_return` y mayor espera en `-!execute_task`

Cuando `-!execute_task` dispara tras un fallo, el robot puede estar en una posición intermedia dentro de la zona congestionada. Intentar la siguiente tarea encolada desde ahí podría producir el mismo bloqueo. Se añade un retorno seguro a la posición base antes de procesar la cola:

```agentspeak
-!execute_task(CId, ShelfId) : true <-
    -+carrying(none);
    release_task(CId);
    .send(scheduler, tell, task_failed(CId));
    .wait(5000);      // dar tiempo a que la zona se despeje
    !safe_return;     // volver a base para salir de zona congestionada
    !check_queue.

+!safe_return : position(InitX, InitY) <- !navigate(InitX, InitY).
-!safe_return : true <- true.  // si la vuelta también falla, continuar igualmente
```

#### 3. Backoff en `task_failed` del scheduler

El scheduler esperaba 0 ms antes de reasignar un contenedor fallido. Con la zona de entrada congestionada, esto rellenaba la cola del robot con la misma tarea imposible de inmediato. Se añade una espera:

```agentspeak
+task_failed(CId)[source(Robot)] : true <-
    .print("⚠️ ", Robot, " reportó fallo con ", CId, ". Reasignando en 10s...");
    -assigned(Robot, CId, _);
    -task_failed(CId)[source(Robot)];
    .wait(10000);
    .abolish(container_info(CId, _, _, _, _, _, _));
    get_container_info(CId).
```

#### 4. Preferencia de `nav_target` hacia el robot (`Container.java`)

Se cambia el orden de direcciones en `getAdyacentes` para evaluar primero la celda "abajo" (y+1), que es la más accesible para robots que se aproximan desde y≥3:

```java
// Antes: arriba, abajo, izquierda, derecha
int[][] dirs = {{0, -1}, {0, 1}, {-1, 0}, {1, 0}};

// Después: abajo, derecha, izquierda, arriba
int[][] dirs = {{0, 1}, {1, 0}, {-1, 0}, {0, -1}};
```

Para contenedores en la fila y=1 (fila inferior de la zona de entrada) la celda adyacente preferida pasa a ser y=2, que está fuera de la zona de entrada y siempre libre de contenedores.

### Comportamiento observado en el log

Sin los cambios: `path_blocked` en el primer intento → cascada de `task_failed` inmediatos → sistema parado.

Con los cambios: 15 contenedores procesados sin ningún `path_blocked`. El único error fue `shelf_full` en `container_10` (shelf_9 llena), que el sistema manejó correctamente: `-!execute_task` limpió el estado, el scheduler esperó 10 s y reasignó a otra estantería.

### Resumen de cambios

| Archivo | Cambio |
|---|---|
| `robot_{light,medium,heavy}.asl` | `!execute_task` usa `!get_to_container(CId, 3)` en fase 1; `-!execute_task` añade `wait(5000)` + `!safe_return`; nuevos planes `!get_to_container`, `-!get_to_container`, `!safe_return`, `-!safe_return` |
| `scheduler.asl` | `task_failed`: añadido `.wait(10000)` antes de `get_container_info` |
| `Container.java` | `getAdyacentes`: orden de dirs cambiado a `{0,1}, {1,0}, {-1,0}, {0,-1}` |

### Limitación conocida documentada en FUTURE_CHANGES

El encolado informal de tareas (creencias `task` acumuladas en la BB del robot) produce inversión de prioridad cuando una tarea nueva llega mientras el robot ya es `idle` y hay tareas encoladas previas: el plan reactivo `+task : state(idle)` procesa la nueva tarea de inmediato, antes que las ya encoladas. La solución correcta es gestionar la cola de despacho en el scheduler (planificación centralizada).

---

## Zona de expansión: desbordamiento de estanterías a zona de clasificación

### Problema

Cuando `drop_at(ShelfId)` fallaba por `shelf_full`, el robot soltaba el contenedor en el pasillo (corredor adyacente a la estantería). Esto bloqueaba otros robots que necesitaban ese corredor para acceder a la misma estantería, podía provocar aplastamientos y dejaba el contenedor en un estado inconsistente (en el suelo, sin asignación).

### Solución

El contenedor se lleva a la **zona de clasificación** (celdas amarillas, `CellType.CLASSIFICATION`, x=3-6, y=0-1) cuando no cabe en la estantería asignada. Esta zona actúa como área de desbordamiento y comparte las mismas reglas de acceso que la zona de entrada (el robot puede recoger y depositar contenedores en ella). El scheduler reintenta la asignación pasados 5 s.

#### Entorno: dos nuevas primitivas (`WarehouseArtifact.java`)

- **`move_to_expansion`** — busca la celda libre de la zona de clasificación más cercana al robot (distancia Manhattan), emite `nav_target(TX, TY)` y retorna. No navega, solo calcula el destino.
- **`drop_in_expansion(CId)`** — deposita el contenedor que lleva el robot en la celda actual (posición del robot). Equivalente a `drop_at` pero sin comprobar tipo de celda destino.

`executeDropAt` ya no suelta el contenedor al detectar `shelf_full`; devuelve `false` directamente para que el robot siga cargando el contenedor y pueda llevarlo a la zona de expansión.

#### Agentes: plan de fallo específico para `shelf_full`

Se añade en los tres robots un plan `-!execute_task` **antes** del plan genérico, que se activa únicamente cuando el error es `shelf_full` y el robot sigue cargando el contenedor:

```agentspeak
-!execute_task(CId, ShelfId) : error(shelf_full, _) & carrying(CId) <-
    .print("⚠️ Estantería llena, llevando ", CId, " a zona de expansión");
    .abolish(error(shelf_full, _));
    move_to_expansion;
    ?nav_target(TX, TY);
    !navigate(TX, TY);
    drop_in_expansion(CId);
    -+carrying(none);
    release_task(CId);
    .send(scheduler, tell, container_in_expansion(CId));
    !check_queue.
```

Se añade también el manejador de evento `+error(shelf_full, Data) : true <- true.` (no-op) para que el evento de adición de la creencia `error(shelf_full,...)` no active el plan genérico de error — `shelf_full` lo gestiona el plan de fallo del goal, no el manejador de evento.

#### Scheduler: reasignación desde zona de expansión

Al recibir `container_in_expansion(CId)`, el scheduler elimina la asignación, espera 5 s y solicita de nuevo la información del contenedor para reasignarlo:

```agentspeak
+container_in_expansion(CId)[source(Robot)] : true <-
    .print("📦 [SCHEDULER] ", CId, " en zona de expansión. Buscando estantería en 5s...");
    -assigned(Robot, CId, _);
    .wait(5000);
    .abolish(container_info(CId, _, _, _, _, _, _));
    get_container_info(CId).
```

### Resumen de cambios

| Archivo | Cambio |
|---|---|
| `WarehouseArtifact.java` | `executeDropAt`: no suelta en `shelf_full`; nuevos métodos `executeMoveToExpansion`, `executeDropInExpansion`; nuevos cases en `switch` |
| `robot_{light,medium,heavy}.asl` | Plan `-!execute_task : error(shelf_full, _)` añadido antes del genérico; `+error(shelf_full, Data)` no-op añadido antes de los manejadores genéricos |
| `scheduler.asl` | Plan `+container_in_expansion` para reasignación desde zona de expansión |

---

## Mejoras de navegación: backoff general, sorteo de obstáculos y corrección de bucle infinito

### Problema 1: interbloqueo en el corredor x=9

Dos robots que se aproximaban desde lados opuestos en x=9 se bloqueaban mutuamente: cada uno esperaba a que el otro cediera el paso. Sin mecanismo de retroceso, ninguno avanzaba.

### Problema 2: tarea perdida al encolar durante retorno a base

Si llegaba una tarea nueva (`task(CId, ShelfId)`) mientras un robot navegaba de vuelta a su posición base, el robot la encolaba en la base de creencias. Al pasar a `state(idle)`, el plan reactivo `+task : state(idle)` no disparaba porque la creencia `task` ya estaba en la BB (el trigger solo actúa sobre la *adición*, no sobre el estado previo). La tarea quedaba silenciosamente ignorada.

Además, si `!navigate` fallaba durante el retorno y existía tarea encolada, `-!check_queue : not task(_, _)` no aplicaba y el fallo se propagaba hacia arriba como `task_failed` espurio.

### Problema 3: oscilación del backoff hacia atrás

El backoff inicial retrocedía en la dirección opuesta al destino. Esto funcionaba para el corredor, pero al volver al greedy el robot recalculaba el siguiente paso hacia exactamente la misma celda bloqueada, produciendo un bucle oscilatorio indefinido.

### Problema 4: bucle infinito del backoff perpendicular Y en el corredor de almacenamiento

Al generalizar el backoff a movimiento perpendicular (X±1 para movimientos con componente Y), el movimiento funcionaba bien para obstáculos en la zona de entrada. Pero al usarlo en el corredor de almacenamiento con movimiento puramente horizontal (TY==Y), el paso perpendicular en Y sacaba al robot de la fila del corredor. El plan `+!navigate(TX, TY) : TX >= 10 & not (Y == TY & corridor_row(TY))` se reactivaba, generando un nuevo `!step_with_retry` con BC=0, y el BC nunca llegaba a 6. El robot oscilaba indefinidamente.

### Solución

#### 1. Plan `+state(idle) : task(CId, ShelfId)` y `-!check_queue : task(CId, ShelfId)`

Se añade antes del plan `+state(idle) : not task(_, _)` un plan reactivo que procesa la tarea encolada en la transición a idle:

```agentspeak
+state(idle) : task(CId, ShelfId) <-
    .print("✅ Tarea pendiente al quedar idle: ", CId, " a ", ShelfId);
    -task(CId, ShelfId)[source(scheduler)];
    accept_task(CId);
    -+state(working);
    -+carrying(CId);
    !execute_task(CId, ShelfId).
```

Se añade también el plan de fallo de `check_queue` cuando hay tarea encolada (evita propagar el fallo de navegación):

```agentspeak
-!check_queue : task(CId, ShelfId) <-
    .print("⚠️ Fallo al navegar a base, procesando tarea encolada: ", CId);
    -task(CId, ShelfId)[source(scheduler)];
    accept_task(CId);
    -+state(working);
    -+carrying(CId);
    !execute_task(CId, ShelfId).
```

#### 2. Backoff general `!path_backoff` con estrategia híbrida

Se sustituye el anterior `!corridor_backoff` (específico de x=9, retroceso en Y) por `!path_backoff` (cualquier posición, movimiento en X):

```agentspeak
// Con componente Y (TY != Y): perpendicular en X → cambia columna, evita
// que el greedy recalcule hacia la misma celda bloqueada.
+!path_backoff(X, Y, TX, TY) : TY > Y <- NX = X + 1; move_step(NX, Y).
+!path_backoff(X, Y, TX, TY) : TY < Y <- NX = X + 1; move_step(NX, Y).
// Horizontal puro (TY == Y): retrocede en X → no altera la fila del corredor,
// BC incrementa correctamente hasta path_blocked si el obstáculo es permanente.
+!path_backoff(X, Y, TX, TY) : TX > X <- NX = X - 1; move_step(NX, Y).
+!path_backoff(X, Y, TX, TY) : TX < X <- NX = X + 1; move_step(NX, Y).
+!path_backoff(_, _, _, _) <- true.
// Fallback si X+1/X-1 está también bloqueado:
-!path_backoff(X, Y, TX, TY) : TY > Y <- NX = X - 1; move_step(NX, Y).
-!path_backoff(X, Y, TX, TY) : TY < Y <- NX = X - 1; move_step(NX, Y).
-!path_backoff(_, _, _, _) <- true.
```

El plan de backoff activa a partir de BC≥2 (dos fallos consecutivos de `!do_step`):

```agentspeak
-!step_with_retry(X, Y, TX, TY, BC) : BC >= 2 & BC < 6 <-
    !path_backoff(X, Y, TX, TY);
    .wait(1000);
    BC1 = BC + 1;
    ?robot_pos(CX, CY);
    !step_with_retry(CX, CY, TX, TY, BC1).
```

**Por qué perpendicular X para movimiento con Y**: al moverse a X+1 (o X-1) sin cambiar Y, el robot permanece en la misma fila horizontal. El siguiente ciclo de `!navigate` recalcula el siguiente paso greedy desde la nueva columna, lo que suele ofrecer una ruta distinta que sortea el obstáculo sin volver exactamente a la celda bloqueada.

**Por qué retroceso X para movimiento horizontal puro**: si el robot está en el corredor de almacenamiento (TY==Y, fila de corredor) y se mueve perpendicularmente en Y, el plan `+!navigate : TX>=10 & not (Y==TY & corridor_row(TY))` se reactivaría, generando un nuevo `!step_with_retry` con BC=0 — el BC se resetea indefinidamente y el robot nunca llega a `path_blocked`. El retroceso en X mantiene al robot en la misma fila y permite que BC siga incrementando hasta 6.

### Resumen de cambios

| Archivo | Cambio |
|---|---|
| `robot_{light,medium,heavy}.asl` | Reemplazado `!corridor_backoff` por `!path_backoff` con estrategia híbrida; añadido `+state(idle) : task(CId, ShelfId)` antes del plan de supervisor; añadido `-!check_queue : task(CId, ShelfId)`; `-!step_with_retry : BC>=2 & BC<6` llama a `!path_backoff` en lugar de `!corridor_backoff` |

---

## Reorganización de zonas: inbound desplazada, clasificación reducida, outbound añadida

### Problema

El layout original tenía la zona de entrada (inbound) en x=0-2 y la zona de clasificación en x=3-6, ambas en y=0-1. No existía zona de salida (outbound). Para la segunda iteración se requiere incorporar una zona de salida dedicada y reposicionar las zonas existentes para acomodarla sin alterar la zona de almacenamiento.

### Solución

Se redefinen las tres franjas horizontales de y=0-1 (fila superior del grid) con las nuevas coordenadas:

| Zona | X anterior | X nueva | Y | Color GUI |
|---|---|---|---|---|
| Outbound (nueva) | — | 0-2 | 0-1 | Rojo suave (255,180,180) |
| Clasificación | 3-6 | 3-4 | 0-1 | Amarillo (255,255,200) |
| Entrada / Inbound | 0-2 | 5-7 | 0-1 | Verde suave (200,255,200) |

Las posiciones iniciales de los robots (y=3) no se ven afectadas por el cambio — siguen en celdas `EMPTY`.

#### Nuevo tipo de celda `OUTBOUND`

Se añade `OUTBOUND` al enum `CellType` para distinguir semánticamente la zona de salida de la de entrada. El entorno puede así razonar sobre qué zona es cada celda sin depender de coordenadas hardcodeadas en los agentes.

#### Fallback de spawn de contenedor

El fallback de `generateRandomContainer()` cuando la zona de entrada está llena se actualiza de `(0,0)` (ahora zona outbound) a `(5,0)` (primera celda de la nueva zona de entrada).

---

## Constantes globales y clasificación de tipos de contenedor (`common.asl`)

### Motivación

Las constantes y clasificaciones usadas por varios agentes estaban dispersas o implícitas en la lógica. Se necesitaba un lugar único, fácilmente modificable, para:

- El parámetro temporal ΔT que el scheduler usa para razonar sobre el ciclo de salida de contenedores urgentes.
- La clasificación de tipos de contenedor en dos grupos semánticamente distintos: urgentes y no urgentes.

### Solución

Se crea el archivo `src/agt/common.asl`, incluido desde los cinco agentes con `{ include("common.asl") }`. Contiene únicamente hechos base — sin planes ni triggers.

#### `delta_t`

```agentspeak
// ΔT: tiempo mínimo razonable (en ciclos de razonamiento) para que los robots
// urgentes completen sus transportes dado el layout del almacén.
delta_t(30).
```

Valor de referencia: robot ligero (speed=3) ida+vuelta a `shelf_1` (y=2 desde ENTRANCE en y≈0) ≈ 20 pasos → margen con δt=30. Ajustable sin tocar lógica de agente.

#### Clasificación de tipos de contenedor

```agentspeak
urgent_container_type("urgent").
urgent_shelf("shelf_1").
urgent_shelf("shelf_5").
urgent_shelf("shelf_8").

non_urgent_container_type("standard").
non_urgent_container_type("fragile").
```

`urgent_shelf` designa una estantería representante por categoría de peso (light/medium/heavy). La clasificación es independiente del criterio de asignación por peso del scheduler — expresa la urgencia semántica del contenedor, no su categoría física.

### Resumen de cambios

| Archivo | Cambio |
|---|---|
| `CellType.java` | Añadido valor `OUTBOUND` |
| `WarehouseView.java` | Añadido case `OUTBOUND` con color rojo suave en el render del grid |
| `WarehouseArtifact.java` | `initializeGrid()`: tres bloques con nuevas coordenadas; fallback spawn de (0,0) a (5,0) |
| `src/agt/common.asl` | Creado con `delta_t(30)`, `urgent_container_type`, `urgent_shelf`, `non_urgent_container_type` |
| `robot_{light,medium,heavy}.asl`, `scheduler.asl`, `supervisor.asl` | Añadido `{ include("common.asl") }` al inicio |

---

## Logging obligatorio: detección de saturación por tipo de contenedor

### Problema

El sistema no detectaba ni registraba cuándo las estanterías de un tipo de contenedor (urgent / non_urgent) quedaban completamente llenas, ni notificaba al scheduler para que activara el ciclo de salida.

### Solución

#### Supervisor: monitorización de saturación

Se añaden creencias estáticas `shelf_type/2` que clasifican cada estantería según el tipo de contenedor que almacena:

```agentspeak
shelf_type("shelf_1", urgent).   // S1, S5, S8 → urgentes
shelf_type("shelf_5", urgent).
shelf_type("shelf_8", urgent).
shelf_type("shelf_2", non_urgent). // S2-S4, S6-S7, S9 → standard y fragile
...
```

Cuando el entorno retira `shelf_available(ShelfId)` (la estantería se llena), el plan reactivo `-shelf_available` comprueba con `.findall` si quedan estanterías disponibles del mismo tipo. Si no queda ninguna, emite el evento obligatorio y notifica al scheduler:

```agentspeak
-shelf_available(ShelfId) : shelf_type(ShelfId, Type) & not no_space_notified(Type) <-
    .findall(S, (shelf_type(S, Type) & shelf_available(S)), Available);
    if (Available == []) {
        +no_space_notified(Type);
        .time(H, M, S);
        .print("EVENT | time=", H, ":", M, ":", S,
               " | agent=supervisor | type=no_space_detected | data=", Type);
        .send(scheduler, tell, no_shelf_space(Type));
    }.
```

La creencia `no_space_notified(Type)` garantiza que el evento se emite exactamente una vez por tipo.

#### Scheduler: activación del ciclo outbound

Al recibir la notificación del supervisor, el scheduler emite el segundo evento obligatorio:

```agentspeak
+no_shelf_space(ContainerType)[source(supervisor)] : true <-
    .time(H, M, S);
    .print("EVENT | time=", H, ":", M, ":", S,
           " | agent=scheduler | type=output_phase_started | data=", ContainerType).
```

#### Entorno: percepciones al supervisor

`emitShelfAvailable` y la retirada en `executeDropAt` se actualizan para emitir/retirar `shelf_available` tanto al scheduler como al supervisor, permitiendo que el supervisor monitorice el estado de las estanterías de forma independiente.

### Formato de los eventos en consola

```
EVENT | time=H:M:S | agent=supervisor | type=no_space_detected | data=urgent
EVENT | time=H:M:S | agent=scheduler  | type=output_phase_started | data=urgent
```

---

## Supervisor: detección de saturación de almacenamiento por tipo

### Problema

Cuando el scheduler agotaba sus 3 reintentos para encontrar estantería a un contenedor (`no_shelf_space`), el supervisor registraba el error genéricamente pero no distinguía si el sistema había alcanzado una condición estructural: ninguna estantería puede aceptar más contenedores de un tipo concreto. Sin esta señal, el scheduler continuaba recibiendo y encolando contenedores de ese tipo sin posibilidad de almacenarlos.

### Solución

El supervisor detecta la saturación por tipo al recibir `no_shelf_space` y notifica al scheduler con `storage_full(Type, T0)`.

#### Por qué `askOne` al scheduler

`shelf_available` y `shelf_occupancy` se emiten exclusivamente al scheduler (`addPercept("scheduler", ...)`); el supervisor no las percibe. El tipo del contenedor tampoco está disponible directamente: `container_info` es un percepto privado que el entorno añade solo al agente que ejecuta `get_container_info(CId)`.

Sin embargo, en el path `no_shelf_space` del scheduler, la creencia `container_info(CId, W, H, Weight, Type, X, Y)` **no se abole** (a diferencia del path `container_broken`). Está disponible en la base de creencias del scheduler cuando el supervisor procesa el mensaje. Se usa `.send(scheduler, askOne, ...)` para consultarla en ese momento.

#### Flujo

```agentspeak
// Al final del handler genérico de errores:
+container_error(CId, ErrorType)[source(Robot)] : true <-
    ...
    !maybe_notify_storage_full(CId, ErrorType).

// Solo actúa para no_shelf_space:
+!maybe_notify_storage_full(CId, no_shelf_space) : true <-
    !query_container_type_and_notify(CId).
+!maybe_notify_storage_full(_, _) : true <- true.

+!query_container_type_and_notify(CId) : true <-
    .send(scheduler, askOne,
          container_info(CId, _, _, _, Type, _, _),
          container_info(_, _, _, _, Type, _, _));
    if (not storage_saturated(Type)) {
        .time(H, M, S);
        T0 = H * 3600 + M * 60 + S;
        +storage_saturated(Type);
        .send(scheduler, tell, storage_full(Type, T0))
    }.

// Edge case: container_info ya no existe (contenedor aplastado justo antes)
-!query_container_type_and_notify(CId) : true <-
    .print("[SUPERVISOR] No se pudo determinar el tipo de ", CId, " para notificación de saturación.").
```

La creencia `storage_saturated(Type)` actúa como semáforo por tipo: la notificación se envía **una sola vez** por tipo, independientemente de cuántos `no_shelf_space` lleguen. T0 se expresa en segundos desde medianoche (`H×3600 + M×60 + S`), usando `.time/3` de Jason.

### Resumen de cambios

| Archivo | Cambio |
|---|---|
| `WarehouseArtifact.java` | `emitShelfAvailable`: añade percept también a supervisor; `executeDropAt`: retira percept también de supervisor |
| `supervisor.asl` | Añadidas creencias `shelf_type/2`; plan `-shelf_available` con detección y log obligatorio; creencia `no_space_notified` anti-duplicado |
| `scheduler.asl` | Plan `+no_shelf_space(ContainerType)[source(supervisor)]` con log obligatorio |
| `supervisor.asl` | `+container_error`: añadida llamada `!maybe_notify_storage_full(CId, ErrorType)`; nuevos planes `!maybe_notify_storage_full`, `!query_container_type_and_notify`, `-!query_container_type_and_notify` |

---

## Asignación de estanterías por tipo de contenedor (urgent vs non_urgent)

### Problema

El scheduler asignaba estanterías exclusivamente por peso y tamaño del contenedor (light/medium/heavy), sin tener en cuenta el tipo (urgent/standard/fragile). Los contenedores urgentes y no urgentes competían por las mismas estanterías, lo que impedía reservar espacio dedicado para cada tipo.

### Solución

Se sustituye la creencia `shelf_category(ShelfId, SizeCat)` por `shelf_for(Urgency, SizeCat, ShelfId)`, que cruza las dos dimensiones de clasificación:

```agentspeak
shelf_for(urgent,     light,  "shelf_1").   // S1 → urgentes pequeños
shelf_for(urgent,     medium, "shelf_5").   // S5 → urgentes medianos
shelf_for(urgent,     heavy,  "shelf_8").   // S8 → urgentes pesados/grandes
shelf_for(non_urgent, light,  "shelf_2").   // S2, S3, S4 → no urgentes pequeños
shelf_for(non_urgent, light,  "shelf_3").
shelf_for(non_urgent, light,  "shelf_4").
shelf_for(non_urgent, medium, "shelf_6").   // S6, S7 → no urgentes medianos
shelf_for(non_urgent, medium, "shelf_7").
shelf_for(non_urgent, heavy,  "shelf_9").   // S9 → no urgentes pesados/grandes
```

Los seis planes `assign_shelf` se reescriben en dos grupos: uno para `urgent` (Type == urgent en la guardia) y otro para `non_urgent` (not (Type == urgent)). Dentro de cada grupo se mantiene la progresión light → medium → heavy por si el tamaño preferido está lleno.

`pick_least_occupied` pasa de dos argumentos `(CId, Cat)` a tres `(CId, Urgency, SizeCat)` y consulta `shelf_for` en lugar de `shelf_category`.

El fallback anti-starvation (cualquier estantería disponible cuando todas las compatibles están llenas) se mantiene sin cambios.

La asignación de robot (`free_shelf`) no cambia: sigue siendo por peso y dimensiones, que determinan qué robot puede transportar el contenedor.

### Resumen de cambios

| Archivo | Cambio |
|---|---|
| `scheduler.asl` | `shelf_category` → `shelf_for(Urgency, SizeCat, ShelfId)`; 6 planes `assign_shelf` tipados; `pick_least_occupied` con 3 argumentos |



# IMPORTANTE -> Planificación Formal — R&N Capítulo 11 (scheduler.asl + supervisor.asl)

## Motivación

El scheduler de la iteración anterior reaccionaba de forma puramente secuencial: al llegar cada contenedor buscaba una estantería disponible y asignaba un robot de inmediato, sin elaborar ningún plan previo. Esto cumplía el objetivo básico, pero carecía de los tres elementos que define la planificación formal según Russell & Norvig (Cap. 11): (1) representación explícita del estado del mundo, (2) esquemas de acción con precondiciones y efectos, y (3) búsqueda guiada por una heurística admisible. El ticket de segunda semana exigía incorporar estos elementos.

---

## Qué se implementó

### 1. Estado del mundo proyectado (`ps_*`)

Se introdujo un conjunto de creencias de planificación prefijadas con `ps_` que representan un **snapshot del mundo** en el momento de iniciar cada ciclo del planificador, y que se modifican a medida que el planificador aplica acciones sobre ellas (sin tocar el estado real del agente):

- `ps_robot_free(Robot)` — robot sin tarea activa asignada en la proyección.
- `ps_shelf(ShelfId, Occ)` — ocupación proyectada de cada estantería disponible.
- `ps_pending(CId, W, H, Weight, Type)` — contenedor aún sin asignar en la proyección.

El plan `!build_planning_state` limpia cualquier proyección anterior con `.abolish` y reconstruye las tres vistas desde el estado real: consulta `assigned(R, _, _)` para saber qué robots están libres, `shelf_available(S) & shelf_occupancy(S, Occ)` para las estanterías, y `planner_pending(CId, ...)` (la cola de entrada del planificador) para los pendientes.

La cola de entrada `planner_pending(CId, W, H, Weight, Type)` es la creencia en la que cada contenedor queda registrado al llegar su `container_info` del entorno. Permanece hasta que el plan la ejecuta (`-planner_pending`) o hasta que se detecta que el contenedor fue aplastado.

### 2. Esquema de acción `assign(Robot, CId, ShelfId)`

La única acción del planificador es `assign/3`. Tiene precondiciones implícitas (evaluadas en `!get_applicable_actions`) y efectos explícitos (aplicados por `!apply_action`):

**Precondiciones:**
- `ps_robot_free(Robot)` — el robot debe estar libre en la proyección.
- `ps_pending(CId, W, H, Weight, Type)` — el contenedor debe estar sin asignar.
- `ps_shelf(ShelfId, _)` — la estantería debe existir y tener espacio en la proyección.
- Compatibilidad robot ↔ contenedor (peso y dimensiones).
- Compatibilidad estantería ↔ tipo de contenedor (urgent/non_urgent).
- `not blocked_type(urgency)` — el tipo no está bloqueado por saturación (outbound).

**Efectos (aplicados sobre `ps_*`):**
- Se elimina `ps_robot_free(Robot)` → el robot queda ocupado en la proyección.
- Se elimina `ps_pending(CId, ...)` → el contenedor queda asignado en la proyección.
- Se incrementa `ps_shelf(ShelfId, Occ+1)` → la ocupación proyectada aumenta en 1.

Esto permite que el planificador proyecte correctamente múltiples asignaciones en un mismo ciclo sin que las primeras contaminen las siguientes.

### 3. Heurística admisible `h(assign(Robot, CId, ShelfId)) → Score`

```
h = urgency_weight + fit_bonus - occupancy_penalty
```

- **urgency_weight**: 10 si el contenedor es `"urgent"`, 5 si es `standard` o `fragile`. Prioriza contenedores urgentes en cada paso de búsqueda.
- **fit_bonus**: fijo en 3 (simplificación; todos los robots asignados son exactamente compatibles con el contenedor por construcción de las acciones aplicables).
- **occupancy_penalty**: ocupación proyectada de la estantería destino. Distribuye la carga entre estanterías del mismo tipo evitando llenar siempre la misma.

Score mayor = mejor acción. El planificador ordena la lista de acciones puntuadas con `.sort` (ascendente) + `.reverse` y toma la primera, obteniendo la de mayor score. En caso de empate entre estanterías, la ordenación alfabética de Jason hace que se elija la última alfabéticamente (ej. shelf_7 antes que shelf_6 cuando ambas tienen Occ=0).

La heurística es admisible: en cada paso del forward search evalúa solo el beneficio inmediato sin sobreestimar el coste real hasta el objetivo.

### 4. Forward search greedy best-first

El plan `!run_planner` orquesta el ciclo completo:

1. `!build_planning_state` — construye el snapshot `ps_*`.
2. `!forward_search([], Plan)` — bucle recursivo:
   - Genera todas las acciones aplicables en el estado proyectado actual (`!get_applicable_actions`).
   - Si hay acciones: puntúa cada una con `!heuristic`, selecciona la mejor (`!pick_best_action`), aplica sus efectos sobre `ps_*` (`!apply_action`), y llama recursivamente con la acción acumulada.
   - Si no hay acciones (robots saturados o estanterías llenas): detiene la búsqueda y devuelve el plan parcial.
   - Caso base: cuando `ps_pending` queda vacío, el plan está completo.
3. `.reverse(Plan, OrderedPlan)` — el plan se acumuló en orden inverso; se invierte para ejecutarlo en el orden correcto.
4. `!execute_plan(OrderedPlan)` — envía las tareas a los robots en el orden planificado.

Este flujo genera el plan **completo antes de enviar ningún mensaje a ningún robot**, satisfaciendo el requisito formal de planificación previa.

### 5. Restricciones estrictas robot ↔ contenedor ↔ estantería

Se mantienen exactamente las mismas restricciones de la iteración anterior:

| Robot | Contenedor | Estanterías |
|---|---|---|
| `robot_light` | ≤10kg, 1×1 | urgent: shelf_1 / non_urgent: shelf_2, shelf_3, shelf_4 |
| `robot_medium` | ≤30kg, 1×2, NO ligero | urgent: shelf_5 / non_urgent: shelf_6, shelf_7 |
| `robot_heavy` | no cabe en medium | urgent: shelf_8 / non_urgent: shelf_9 |

"No ligero" se expresa como: Weight>10 OR H>1 (dos condiciones OR → dos `.findall` separados + `.concat`, para evitar `not` anidado en Jason).

"No cabe en medium" se expresa como: Weight>30 OR W>1 OR H>2 (tres `.findall` + `.concat`).

### 6. `planning_active` — mutex para evitar planificadores concurrentes

El planificador puede ser disparado desde múltiples eventos: llegada de un nuevo `container_info`, o confirmación de almacenamiento de un robot (`container_stored`). Para evitar que dos instancias del planificador se ejecuten en paralelo y generen asignaciones duplicadas, se usa la creencia `planning_active` como semáforo:

- Al iniciar: `+planning_active`.
- Al terminar: `-planning_active`.
- Antes de lanzar: `if (not planning_active) { ... }`.

Hay además un `.wait(300)` al inicio del ciclo para acumular contenedores que llegan casi simultáneamente en el mismo ciclo de planificación, evitando lanzar N planes para N contenedores que podrían planificarse de golpe.

### 7. Relanzamiento automático al liberar robot

Cuando un robot confirma el almacenamiento (`+container_stored`), el scheduler elimina la creencia `assigned(Robot, CId, ShelfId)` y comprueba si hay contenedores en `planner_pending` que no pudieron asignarse en el ciclo anterior (por falta de robots o espacio). Si los hay, relanza el planificador. Esto resuelve el caso en que llega un contenedor pesado pero `robot_heavy` estaba ocupado: el contenedor queda en `planner_pending` y se asigna en cuanto el robot queda libre.

---

## Bugs encontrados y corregidos durante el desarrollo

### Bug 1: `=<` no funciona en reglas ni en guardias de Jason

Jason evalúa `=<` como unificación estructural, no como comparación aritmética, cuando aparece en reglas `:-` o en guardias de planes. Cualquier regla como `can_carry(robot, W, H, Weight) :- Weight =< 10 & ...` falla en tiempo de parseo. La solución fue eliminar todas las reglas auxiliares con aritmética (`can_carry`, `shelf_type_ok`) e inline todas las condiciones numéricas directamente en los findalls usando únicamente `>` (ej. `not (Weight > 10)` en lugar de `Weight =< 10`).

### Bug 2: Reglas y facts con lookup no se evalúan dentro de `.findall`

Ni las reglas `:-` con aritmética ni los facts como `urgency_of(Type, non_urgent)` se evalúan correctamente dentro del cuerpo de un `.findall` en Jason — devuelven resultados vacíos silenciosamente. La solución fue no usar ningún predicado derivado dentro de findalls; todas las condiciones deben ser directas (comparaciones, accesos a creencias base).

### Bug 3: `not` anidado falla silenciosamente en `.findall`

La condición `not (not A & not B)` (equivalente lógico a `A OR B`) no funciona en Jason dentro de `.findall`. Por ejemplo, para expresar "el contenedor NO es ligero" (es decir, Weight>10 OR H>1) no se puede escribir `not (not (Weight > 10) & not (H > 1))`. La solución fue dividir cada condición OR en `.findall`s separados y concatenar los resultados. Posibles duplicados son inofensivos ya que el planificador selecciona la mejor acción por score.

### Bug 4: Aritmética en `.findall` (`S-Occ` interpretado como resta)

Al intentar construir un functor `shelf(S, Occ)` dentro de un `.findall` como `S-Occ`, Jason lo interpretaba como una resta aritmética en lugar de un término compuesto, produciendo errores en tiempo de ejecución. La solución fue usar el functor `shelf(S, Occ)` con notación de paréntesis en lugar de guion.

### Bug 5: Código huérfano en `supervisor.asl` causaba error de parseo

El supervisor tenía un bloque de código (cuerpo de plan de errores de navegación) sin cabecera de plan, resultado de un refactor incompleto anterior. Jason no podía parsear el fichero. Se eliminaron las líneas huérfanas (el robot_heavy especializado de esta iteración nunca enviaba eventos de navegación al supervisor).

### Bug 6 (crítico): Tipos de contenedor como strings en el entorno vs átomos en el código

El entorno Java construye el percepto `container_info` usando interpolación de strings:
```java
"container_info(\"" + containerId + "\"," + ... + ",\"" + container.getType() + "\"," + ...
```
Esto hace que `Type` llegue a Jason como una **cadena entre comillas** (`"urgent"`, `"standard"`, `"fragile"`), no como un átomo (`urgent`, `standard`, `fragile`). En Jason, `"urgent" \== urgent`: son tipos distintos.

Consecuencia: todas las guardias y findalls que usaban el átomo `urgent` fallaban silenciosamente — `ps_pending(CId, W, H, Weight, urgent)` nunca unificaba con `ps_pending(CId, W, H, Weight, "urgent")`. El efecto observable era que **todos los contenedores urgentes se asignaban a estanterías non_urgent**: las secciones `AM_U` y `AH_U` devolvían listas vacías, y los contenedores urgentes se colaban en `AM_N`/`AH_N` porque `not (Type == urgent)` evaluaba como `not ("urgent" == urgent)` = `true`.

La solución fue cambiar todos los literales de tipo de contenedor en el código AgentSpeak a strings con comillas: `"urgent"` en los patrones de findall, `not (Type == "urgent")` en los filtros, e `if (Type == "urgent")` en la heurística.

---

## Estado del sistema tras estos cambios

- Contenedores `urgent` se asignan correctamente a las estanterías priority (shelf_1, shelf_5, shelf_8).
- Contenedores `standard` y `fragile` (non_urgent) se asignan a shelf_2–4, shelf_6–7, shelf_9 según peso.
- La saturación de `shelf_9` (única estantería heavy non_urgent) provoca que contenedores heavy non_urgent queden en zona de expansión y reboten indefinidamente. Este es el límite esperado de la iteración actual: **se resolverá cuando se implemente el ciclo outbound**.

---

# Cambios realizados — 2ª semana (pull model + robot_heavy2)

## Ticket resuelto: adaptación del comportamiento de los robots (pull-based architecture)

### Problema que resolvía

El modelo anterior era push: el scheduler asignaba tareas a robots de forma proactiva llamando a `.send(Robot, tell, task(...))` directamente desde `!execute_plan`. Los robots eran receptores pasivos, sin capacidad de decidir cuándo estaban listos para aceptar trabajo. Esto contradecía el objetivo de que los robots no dependieran de asignaciones explícitas del scheduler.

### Cambios en scheduler.asl

**`!execute_plan`** dejó de enviar `task(CId, ShelfId)` directamente al robot. En su lugar almacena la asignación como una creencia local:

```agentspeak
+ready_task(Robot, CId, ShelfId);
```

**Sección 12 — Protocolo pull** (añadida al final del archivo): el scheduler reacciona cuando un robot envía `request_task`:

- Si existe un `ready_task` pendiente para ese robot, lo consume y responde con `task(CId, ShelfId)`.
- Si no hay tarea pero hay pendientes sin planificar (`planner_pending`), lanza el planificador y vuelve a intentarlo.
- Si no hay nada disponible, responde con un mensaje de log y no hace nada.

### Cambios en los robots (robot_light, robot_medium, robot_heavy)

El plan `+!work_cycle : state(idle)` pasó de esperar pasivamente a enviar activamente una petición al scheduler:

```agentspeak
+!work_cycle : state(idle) <-
    .send(scheduler, tell, request_task);
    .wait(3000);   // 4000 para heavy
    !work_cycle.
```

Los robots siguen manteniendo creencias locales de estado: `state(idle/working/picking/carrying/dropping)`, `carrying(CId)`, `position(X,Y)` y `robot_pos(X,Y)`.

### Bug crítico resuelto: string vs. átomo en tipos de contenedor

`WarehouseArtifact.java` emite el tipo de contenedor como string Java → Jason lo recibe como `"urgent"` (con comillas). Todos los findalls y guardas del planificador usaban el átomo `urgent` (sin comillas), que nunca unificaba. Efecto: los contenedores urgentes se asignaban siempre a estanterías non-urgent.

Corrección: todos los literales de tipo en scheduler.asl cambiados a strings:

```agentspeak
not (Type == "urgent")   // antes: not (Type == urgent)
if (Type == "urgent")    // ídem
```

Verificado: `container_10` (urgent, 2×3, 89.3 kg) → `shelf_8` ✅

### Nueva instancia: robot_heavy2

Se añadió una segunda instancia del robot pesado con posición base (4,3):

- **`src/agt/robot_heavy2.asl`** — copia de robot_heavy con `position(4,3)` y prefijo `[HEAVY2]` en todos los prints. Mismo protocolo pull, misma lógica de navegación y manejo de errores.
- **`src/env/warehouse/WarehouseArtifact.java`** — objeto `Robot heavy2` inicializado en (4,3) y percepción `robot_pos(4,3)` emitida al agente.
- **`warehouse.mas2j`** — entrada `robot_heavy2` con las mismas creencias de capacidad que `robot_heavy`.
- **`src/agt/supervisor.asl`** — creencia inicial `robot_status(robot_heavy2, idle)` añadida; `!print_robot_status` actualizado para imprimir su estado.
- **`src/agt/scheduler.asl`** — `robot_capacity(robot_heavy2, 100, 2, 3, 1)` y `robot_available(robot_heavy2)` añadidos como creencias iniciales.

### Bug resuelto: robot_heavy2 nunca recibía tareas

El planificador tenía dos sitios hardcodeados con la lista de robots:

1. Las creencias `robot_capacity` / `robot_available` — faltaba `robot_heavy2`.
2. El bucle `for (.member(R, [robot_light, robot_medium, robot_heavy]))` en `!snapshot_state` — tampoco lo incluía, por lo que `robot_heavy2` nunca aparecía en `ps_robot_free` y el planificador lo ignoraba.

### Mejora de diseño: eliminación de hardcoding en el planificador

El bucle de construcción del snapshot se reescribió para derivar la lista de robots directamente de `robot_capacity`, que actúa como única fuente de verdad:

```agentspeak
.findall(R, robot_capacity(R, _, _, _, _), AllRobots);
for (.member(R, AllRobots)) {
    if (not assigned(R, _, _)) { +ps_robot_free(R); }
};
```

Añadir un nuevo robot ahora solo requiere una línea en `robot_capacity`.

### Mejora: robots no vuelven a la base si hay tarea disponible

**Comportamiento anterior:** al terminar una tarea, `!check_queue` comprobaba la cola local del robot. Como en el modelo pull nunca hay tarea local pre-encolada, siempre navegaba de vuelta a la base antes de pedir trabajo.

**Comportamiento nuevo:** `!check_queue : not task(_, _)` envía primero `request_task` al scheduler y espera 2 segundos. Si el scheduler responde con una tarea, el robot la ejecuta directamente desde donde está. Solo navega a la base si no hay ninguna tarea disponible:

```agentspeak
+!check_queue : not task(_, _) & position(InitX, InitY) <-
    .send(scheduler, tell, request_task);
    .wait(2000);
    if (task(CId, ShelfId)) {
        -task(CId, ShelfId)[source(scheduler)];
        accept_task(CId);
        -+state(working);
        -+carrying(CId);
        !execute_task(CId, ShelfId);
    } else {
        !navigate(InitX, InitY);
        -+state(idle);
    }.
```

Aplicado en los cuatro robots: `robot_light`, `robot_medium`, `robot_heavy`, `robot_heavy2`.

### Mejora: desempate por orden de declaración en `robot_capacity`

**Problema:** cuando dos robots tienen el mismo score heurístico para un contenedor, `!pick_best_action` usaba `.sort` + `.reverse` sobre términos `s(Score, Action)`. Jason ordena términos compuestos alfabéticamente, por lo que `robot_heavy2 > robot_heavy` → `robot_heavy2` ganaba siempre el desempate, independientemente del orden deseado.

**Solución:** se añade un segundo campo `Priority` al término de score, calculado como el índice negado del robot en la lista `robot_capacity`:

```agentspeak
+!score_actions([assign(R, CId, ShelfId)|Rest], [s(Score, Priority, assign(R, CId, ShelfId))|SRest]) <-
    !heuristic(assign(R, CId, ShelfId), Score);
    .findall(Rx, robot_capacity(Rx, _, _, _, _), AllRobots);
    .nth(Idx, AllRobots, R);
    Priority = -Idx;
    !score_actions(Rest, SRest).

+!pick_best_action(Actions, Best) <-
    !score_actions(Actions, Scored);
    .sort(Scored, Sorted);
    .reverse(Sorted, [s(_, _, Best)|_]).
```

`robot_heavy` está en índice 2 → `Priority = -2`. `robot_heavy2` está en índice 3 → `Priority = -3`. Como el sort es ascendente y se invierte, `s(10, -2, ...)` queda por delante de `s(10, -3, ...)` → `robot_heavy` gana el desempate.

El orden de preferencia entre robots con igual score queda determinado por su posición en `robot_capacity`, que actúa como única fuente de verdad.

### Corrección: oscilación del backoff horizontal (robot bloqueado por otro robot)

**Causa raíz:** cuando un robot intentaba moverse horizontalmente y otro robot bloqueaba la celda destino, el backoff movía al robot a (X, Y+1). Desde ahí el greedy recalculaba y volvía inmediatamente a (X, Y) porque ese punto estaba más cerca del destino. El BC nunca llegaba a 6 porque cada ciclo oscilatorio completaba un paso exitoso que lo reseteaba.

**Solución:** para movimiento horizontal bloqueado, el backoff ahora se mueve en Y (perpendicular al movimiento), en lugar de retroceder en X:

```agentspeak
+!path_backoff(X, Y, TX, TY) : TX > X <- NY = Y + 1; move_step(X, NY).
+!path_backoff(X, Y, TX, TY) : TX < X <- NY = Y + 1; move_step(X, NY).
-!path_backoff(X, Y, TX, TY) : TX > X <- NY = Y - 1; move_step(X, NY).
-!path_backoff(X, Y, TX, TY) : TX < X <- NY = Y - 1; move_step(X, NY).
```

Desde (X, Y+1) el greedy no tiene incentivo para volver a (X, Y) si el destino sigue en X — avanza hacia él desde la nueva fila.

### Corrección: oscilación del backoff vertical (robot o contenedor bloqueando acceso)

**Causa raíz:** idéntica al caso horizontal pero en vertical. El backoff movía al robot a (X+1, Y). Desde ahí, el greedy volvía a (X, Y) porque TX == X y (X, Y) está más cerca del destino vertical. BC se reseteaba en cada ciclo.

**Solución:** para movimiento vertical bloqueado, el backoff hace **dos pasos**: lateral (X±1) seguido de un paso en la dirección del destino (Y±1). El robot queda en (X+1, Y+1) — desde ahí el greedy ya no regresa a (X, Y) porque eso aumentaría |dy|:

```agentspeak
+!path_backoff(X, Y, TX, TY) : TY > Y <- NX = X + 1; NY = Y + 1; move_step(NX, Y); move_step(NX, NY).
+!path_backoff(X, Y, TX, TY) : TY < Y <- NX = X + 1; NY = Y - 1; move_step(NX, Y); move_step(NX, NY).
-!path_backoff(X, Y, TX, TY) : TY > Y <- NX = X - 1; NY = Y + 1; move_step(NX, Y); move_step(NX, NY).
-!path_backoff(X, Y, TX, TY) : TY < Y <- NX = X - 1; NY = Y - 1; move_step(NX, Y); move_step(NX, NY).
```

Aplicado en los cuatro robots: `robot_light`, `robot_medium`, `robot_heavy`, `robot_heavy2`.

---

### Corrección: crash al fallar la navegación a la zona de expansión tras `shelf_full`

**Causa raíz:** el plan `-!execute_task : error(shelf_full, _)` incluía `!navigate(TX, TY)` directamente en su cuerpo. Si esa navegación fallaba (p. ej. `path_blocked` por bloqueo permanente), Jason intentaba generar un nuevo evento de fallo para `-!execute_task` — pero ya estábamos dentro de un plan de fallo de ese mismo goal, por lo que Jason no podía generar otro y abortaba con `"No failure event was generated"`. El estado `carrying(CId)` quedaba activo y el robot no enviaba `task_failed` al scheduler, dejando el sistema en un estado inconsistente permanente.

**Solución:** se extrae la recuperación a un sub-goal independiente `!go_to_expansion(CId)`, que tiene su propio plan de fallo `-!go_to_expansion(CId)`. Cualquier fallo dentro de la recuperación (incluyendo la navegación) se captura en ese plan de fallo y limpia el estado correctamente:

```agentspeak
-!execute_task(CId, ShelfId) : error(shelf_full, _) & carrying(CId) <-
    .abolish(error(shelf_full, _));
    !go_to_expansion(CId);
    !check_queue.

+!go_to_expansion(CId) <-
    move_to_expansion;
    ?nav_target(TX, TY);
    !navigate(TX, TY);
    drop_in_expansion(CId);
    -+carrying(none);
    release_task(CId);
    .send(scheduler, tell, container_in_expansion(CId)).

-!go_to_expansion(CId) <-
    -+carrying(none);
    release_task(CId);
    .send(scheduler, tell, task_failed(CId)).
```

El plan de fallo de `-!execute_task : shelf_full` ya no puede romperse: si `!go_to_expansion` tiene éxito, el contenedor queda en la zona de expansión; si falla, `-!go_to_expansion` limpia el estado y libera la tarea. En ningún caso el robot queda con `carrying(CId)` activo sin que el scheduler sea notificado.

| Archivo | Cambio |
|---|---|
| `robot_{light,medium,heavy,heavy2}.asl` | Extraída navegación a expansión al sub-goal `!go_to_expansion(CId)` con su plan de fallo `-!go_to_expansion(CId)` |

---

# Ciclo outbound — extracción de contenedores saturados a zona de salida

## Motivación

Cuando todas las estanterías de un tipo (urgent / non_urgent) están llenas, el sistema bloqueaba nuevas asignaciones de ese tipo (`blocked_type`) pero no hacía nada para liberar espacio. Los contenedores se acumulaban en la zona de expansión o generaban fallos de `shelf_full` indefinidamente. El ciclo outbound activa el vaciado activo de las estanterías saturadas hacia la zona de salida (roja, x=0–2, y=0–1) para reanudar el inbound.

## Flujo completo

```
supervisor detecta estantería llena
    → -shelf_available(ShelfId) → .findall de misma categoría vacía
    → if vacía: no_space_notified, EVENT, .send(scheduler, no_shelf_space(Type))

scheduler recibe no_shelf_space(Type)
    → +blocked_type(Type)   ← planificador ignorará ese tipo
    → EVENT output_phase_started
    → !dispatch_outbound(Type)
        → .findall de stored_at(CId, ShelfId) del tipo
        → para cada (CId, ShelfId) × para cada robot:
              .send(robot, tell, outbound_available(CId, ShelfId, W, H, Weight))
        (broadcast: el scheduler anuncia, NO asigna)

robot recibe outbound_available(CId, ShelfId, W, H, Weight)
    → si state(idle) & compatible (max_weight, max_size):
          -outbound_available, accept_task, -+state(working), !execute_outbound_task
    → si not state(idle) & compatible:
          mantiene creencia en BB (la procesará al terminar tarea actual)
    → si incompatible:
          -outbound_available (descarta)
    (decisión autónoma: el scheduler no decide qué robot extrae qué contenedor)

robot ejecuta !execute_outbound_task
    → move_to_shelf → navigate → pickup_from_shelf → move_to_outbound → navigate → drop_in_outbound
    → release_task(CId), .send(scheduler, container_shipped(CId, ShelfId))

pickup_from_shelf (Java)
    → shelf.remove(container)
    → si shelf estaba llena: emitShelfAvailable(shelfId) → +shelf_available percept

condición de carrera: dos robots intentan el mismo contenedor
    → el primero en llamar pickup_from_shelf gana (atómico en Java)
    → el segundo recibe container_not_on_shelf → -!execute_outbound_task dispara
          → release_task (sin args), .send(scheduler, outbound_failed(CId, ShelfId))

+shelf_available en scheduler
    → si blocked_type(Type) & shelf_for(Type, _, ShelfId): -blocked_type(Type)
    → inbound de ese tipo se reanuda

+shelf_available en supervisor
    → si no_space_notified(Type): -no_space_notified(Type)
    → el ciclo de detección puede dispararse de nuevo si es necesario
```

## Cambios por archivo

### `Shelf.java`

Nuevo método `remove(Container)` — inverso de `store`: decrementa `currentWeight` y `currentVolume` y elimina el ID de `storedContainers`. Necesario para que `pickup_from_shelf` libere el espacio de la estantería correctamente.

### `WarehouseArtifact.java`

Tres nuevas acciones:

- **`pickup_from_shelf(ShelfId, CId)`** — recoge un contenedor almacenado en una estantería. Comprueba proximidad (≤3), compatibilidad de peso/tamaño, y que el contenedor está efectivamente en la estantería. Llama a `shelf.remove(container)`, hace `robot.pickup`, y si la estantería estaba llena re-emite `shelf_available` al scheduler y al supervisor. Actualiza `shelf_occupancy`.

- **`move_to_outbound`** — calcula la celda OUTBOUND más cercana al robot (zona roja, x=0–2, y=0–1) y emite `nav_target(X,Y)`. Análogo a `move_to_expansion`.

- **`drop_in_outbound(CId)`** — el robot deposita el contenedor en la zona outbound y lo elimina de `containers` (enviado; no vuelve a aparecer en la simulación). Análogo a `drop_in_expansion` pero sin zona de clasificación.

### `scheduler.asl`

- **`+container_stored`**: añadido `+stored_at(CId, ShelfId)` para rastrear qué contenedores están en qué estantería.
- **`+no_shelf_space`**: llama a `!dispatch_outbound(Type)` tras fijar `blocked_type`.
- **`+!dispatch_outbound(Type)`**: broadcast puro — con `.findall` recoge todos los `stored_at(CId, ShelfId)` del tipo y envía `outbound_available(CId, ShelfId, W, H, Weight)` a **todos** los robots. No asigna ningún robot concreto.
- **`+shelf_available`**: nuevo plan reactivo — si `blocked_type(Type)` y la estantería es de ese tipo, elimina `blocked_type` y reanuda el inbound.
- **Protocolo `request_task`**: sin cambios respecto al inbound — el outbound ya no pasa por `request_task`; los robots reciben `outbound_available` directamente y deciden de forma autónoma.
- **`+container_shipped`**: elimina `stored_at` y `container_info` al confirmar envío.
- **`+outbound_failed`** (2 planes): si el contenedor sigue en la estantería (`container_info` existe) → re-broadcast a todos los robots; si ya no existe → elimina `stored_at`.

### `supervisor.asl`

- **`+shelf_available`**: nuevo plan reactivo — si `no_space_notified(Type)` y la estantería es de ese tipo, retira `no_space_notified` para que el ciclo de detección pueda volver a dispararse si se vuelve a llenar.

### `robot_{light,medium,heavy,heavy2}.asl`

- **`+outbound_available(CId, ShelfId, W, H, Weight)`** (3 planes):
  1. `state(idle) & compatible` → elimina la creencia, `accept_task`, `-+state(working)`, `!execute_outbound_task`.
  2. `not state(idle) & compatible` → mantiene la creencia en BB para procesarla al quedar idle.
  3. `true` (incompatible) → elimina la creencia (`-outbound_available[source(scheduler)]`).
- **`+!execute_outbound_task(CId, ShelfId)`**: 4 fases — navegar a estantería, `pickup_from_shelf`, navegar a outbound, `drop_in_outbound`. Al completar: `release_task(CId)`, envía `container_shipped` al scheduler.
- **`-!execute_outbound_task`**: limpia estado, llama `release_task` **sin args** (evita re-encolar el contenedor al inbound) y notifica `outbound_failed`.
- **`+!check_queue`**: comprueba `outbound_available` compatible *antes* que `task` inbound. El plan de "pedir tarea" solo se activa si no hay ni `task` ni `outbound_available` pendiente (eliminado el `else if outbound_task` del bloque inline).

| Archivo | Cambio |
|---|---|
| `Shelf.java` | Añadido `remove(Container)` |
| `WarehouseArtifact.java` | Nuevas acciones `pickup_from_shelf`, `move_to_outbound`, `drop_in_outbound` |
| `scheduler.asl` | `stored_at`, `dispatch_outbound` (broadcast), `shelf_available` reactivo, `container_shipped`, `outbound_failed` (re-broadcast) |
| `supervisor.asl` | `+shelf_available` reactivo para resetear `no_space_notified` |
| `robot_{light,medium,heavy,heavy2}.asl` | 3 planes `+outbound_available` (idle+compatible / busy+compatible / incompatible), `execute_outbound_task`, `check_queue` actualizado |
