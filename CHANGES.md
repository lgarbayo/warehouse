# Changes

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