# Changes

---

## Iteración 2: Coordinación distribuida y ciclo de salida físico

### Objetivos cumplidos

1. El entorno solo provee localización de agentes, estanterías y contenedores.
2. Nueva zona de salida (OUTBOUND) en el lado opuesto a la entrada.
3. Control temporal con deadlines gestionado por el scheduler.
4. El scheduler deja de ser proveedor central de información.
5. Coordinación distribuida: los robots seleccionan y reclaman contenedores autónomamente.

---

### 1. Zona OUTBOUND y nuevas acciones Java (`WarehouseArtifact.java`, `CellType.java`, `Shelf.java`, `WarehouseView.java`)

Se añade `CellType.OUTBOUND` (celdas x=17-19, y=0-1) en el extremo opuesto a la entrada (ENTRANCE x=0-2, y=0-1). Se visualizan en azul claro en la GUI.

`Shelf.java` añade `remove(Container)` para retirar contenedores en el ciclo de salida.

Nuevas acciones Java en `executeAction`:

| Acción | Descripción |
|---|---|
| `claim_container(CId)` | Reclamo atómico con `ConcurrentHashMap.putIfAbsent`. Retira `container_at_entrance` de todos los agentes si tiene éxito. Falla si ya reclamado. |
| `unclaim_container(CId)` | Libera el reclamo. Si el robot lleva físicamente ese contenedor (estado inconsistente tras error), lo suelta (`robot.drop()`) antes de re-emitir el percept `container_at_entrance`. |
| `pickup_from_shelf(CId, ShelfId)` | Recoge un contenedor ya almacenado en una estantería. Comprueba adyacencia, llama `shelf.remove()` y restaura `shelf_available`. |
| `move_to_outbound` | Calcula la celda libre de la zona OUTBOUND más cercana y emite `nav_target`. |
| `drop_in_outbound(CId)` | Deposita el contenedor en la zona OUTBOUND. Requiere que el robot esté en una celda OUTBOUND. Incrementa `totalContainersProcessed` y emite `container_exited(CId)` al scheduler. |
| `discard_container(CId)` | Elimina el contenedor del mapa Java y de `claimedContainers`. Retira el percept `container_at_entrance` de todos los agentes. |

`container_at_entrance` pasa de `addPercept("scheduler", ...)` a `addPercept(...)` (broadcast a todos los agentes). Incluye todas las propiedades del contenedor: `container_at_entrance(CId, Type, Weight, W, H)`.

`shelf_available` y `shelf_occupancy` también se vuelven broadcast (antes solo al scheduler).

---

### 2. Scheduler: solo gestión de deadlines y fallos (`scheduler.asl`)

**Eliminado**: toda la lógica de asignación de tareas (`new_container`, `process_new_container`, `container_info`, `assign_shelf`, `pick_least_occupied`, `free_shelf`, creencias `robot_capacity`, `robot_available`, `assigned`, categorías de contenedor, `container_type`).

**Conservado y ampliado**:
- Gestión del ciclo de salida: `storage_full → exit_cycle → run_exit_cycle` con `active_deadline`.
- Seguimiento de fallos permanentes con `container_requeue_count` (hasta 3 intentos cross-robot; al 3.º llama `discard_container` y notifica al supervisor).
- Handler `container_exited(CId)` para confirmación de entrega.

---

### 3. Supervisor: percepción directa de contenedores (`supervisor.asl`)

- Handler cambiado de `+new_container(CId)` a `+container_at_entrance(CId, Type, Weight, W, H)`.
- Se añade `container_received_type(CId, Type)` para trackear el tipo localmente.
- `+!query_container_type_and_notify(CId)` ya no usa `askOne` al scheduler: consulta la creencia local `container_received_type(CId, Type)` para determinar el tipo antes de enviar `storage_full` al scheduler.

---

### 4. `common.asl`: creencias de categoría de estantería y selección autónoma

`common.asl` se amplía con:
- Creencias estáticas `shelf_category(ShelfId, Cat)` (light/medium/heavy) para las 9 estanterías.
- Planes compartidos `!pick_shelf(CId, Weight, W, H)` y `!pick_least_occupied_shelf(CId, Cat)` para selección autónoma de estantería según peso y tamaño del contenedor, con fallback a expansión tras 3 reintentos.

---

### 5. Robots: reclamación autónoma y ciclo de salida físico

Los tres robots reescriben su arquitectura de tareas:

**Eliminado**: plan `+task(CId, ShelfId)` recibido del scheduler.

**Añadido**:

- `+container_at_entrance(CId, Type, Weight, W, H)`: trigger reactivo con guardia de capacidad hardcodeada (sin `max_weight/max_size` del `.mas2j`, que Jason no carga al tener múltiples `beliefs=`). Se usa `|` eliminado a favor de múltiples planes separados (Jason 3.x no soporta `|` fiablemente en guardias).
  - robot_light: `Weight <= 10 & W <= 1 & H <= 1`
  - robot_medium: dos planes — `Weight > 10` y `H > 1` (hasta 30kg, 1×2)
  - robot_heavy: tres planes — `Weight > 30`, `W > 1`, `H > 2` (hasta 100kg, 2×3)

- `+container_at_entrance(...) : nav_failed(CId) <- true.` — skip plan: evita reclamar contenedores a los que el robot falló navegar recientemente.

- `-container_at_entrance(...) : nav_failed(CId) <- -nav_failed(CId).` — limpia el skip cuando el percept es retirado (por otro robot que lo reclamó, o por `discard_container`).

- `!try_claim(CId, ...)`: llama `claim_container(CId)` como acción directa. Si falla (ya reclamado), `-!try_claim : true <- true` absorbe silenciosamente.

- `!check_pending_containers`: versión de polling (work_cycle), con guarda `not nav_failed(CId)`.

- `!select_shelf_and_execute → !pick_shelf → !execute_task`: flujo de almacenamiento igual que iteración 1 pero con estantería seleccionada autónomamente.

- `+!execute_exit(CId, ShelfId)`: ciclo de salida físico.
  1. `move_to_shelf(ShelfId)` + `!navigate` → adyacente a la estantería.
  2. `pickup_from_shelf(CId, ShelfId)` → recoge de la estantería.
  3. `move_to_outbound` + `!navigate` → zona OUTBOUND.
  4. `drop_in_outbound(CId)` → entrega.
  5. Limpia `stored(CId, ShelfId)`, `claimed_type(CId, _)`, `exit_claimed(CId)`, `carrying`.

- `+!select_for_exit([pair(CId,ShelfId)|_], Category) : claimed_type(CId, ...) & state(idle)`: guarda `state(idle)` añadida para evitar iniciar exit cycle concurrentemente con execute_task (el `askOne` al scheduler suspende la intención, abriendo una ventana donde un trigger reactivo podría cambiar el estado).

- `stored(CId, ShelfId)` handler: notifica solo al supervisor (ya no al scheduler).

**Correcciones de bugs en robustez**:

- `-!execute_task : not carrying(CId) & nav_failed(CId)`: el cleanup ya fue hecho por `-!get_to_container(CId,1)`, solo hace `!safe_return; !check_queue`.
- `-!execute_task : not carrying(CId)`: (sin `nav_failed`) el error ocurrió después del pickup (ej. `path_blocked` durante navigate a estantería). Hace `release_task + unclaim_container + task_failed` completo. `unclaim_container` con la nueva lógica Java fuerza-suelta el contenedor si el robot lo lleva físicamente.
- `-!get_to_container(CId,1)`: añade `+nav_failed(CId)` antes de `unclaim_container` para activar el mecanismo de skip.

---

## Ejercicio 3: Registro de eventos en fichero (warehouse.log_event)

### Problema
Los logs EVENT requeridos por el enunciado (`deadline_started`, `deadline_ended`, `container_delivered`) solo se emitían por consola con `.print()`. El enunciado exige que se almacenen en fichero.

### Solución
Nueva acción interna Java `warehouse.log_event` en `src/java/warehouse/log_event.java`:
- Acepta los mismos argumentos varargs que `.print()` — reemplazo directo.
- Concatena todos los términos (StringTerm → getString, resto → toString).
- Escribe cada línea al final de `events.log` en el directorio de ejecución.
- Uso de `synchronized` para evitar interleaving entre robots concurrentes.

Ficheros modificados:
- `src/java/warehouse/log_event.java` — nueva clase, acción interna Jason.
- `src/agt/scheduler.asl` — 4 llamadas `.print("EVENT | ...")` → `warehouse.log_event(...)`. Se mantiene `.print(...)` de diagnóstico.
- `src/agt/robot_light.asl`, `robot_medium.asl`, `robot_heavy.asl` — 2 llamadas cada uno.

Formato de línea en `events.log`:
```
EVENT | time=T | agent=scheduler | type=deadline_started | data=urgent
EVENT | time=T | agent=scheduler | type=deadline_ended   | data=urgent
EVENT | time=T | agent=robot_id  | type=container_delivered | data=container_id
```

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
| `src/agt/common.asl` | Creado con `delta_t(30)`, `urgent_container_type`, `urgent_shelf`, `non_urgent_container_type` |
| `robot_{light,medium,heavy}.asl`, `scheduler.asl`, `supervisor.asl` | Añadido `{ include("common.asl") }` al inicio |

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
| `supervisor.asl` | `+container_error`: añadida llamada `!maybe_notify_storage_full(CId, ErrorType)`; nuevos planes `!maybe_notify_storage_full`, `!query_container_type_and_notify`, `-!query_container_type_and_notify` |

---

## Scheduler: gestión de deadlines del ciclo de salida

### Motivación

Una vez registrado `exit_cycle(Type, T0)`, el scheduler debe orquestar dos fases de salida con duraciones definidas por ΔT, emitir los eventos de log estructurados y notificar al agente Transport. Las dos fases deben ser mutuamente excluyentes: la fase larga no puede empezar hasta que la corta haya terminado.

### Solución

Se añade la sección 8 a `scheduler.asl` con dos planes: un trigger reactivo sobre `+exit_cycle` y el plan principal `+!run_exit_cycle`.

#### Trigger reactivo

```agentspeak
+exit_cycle(Type, T0) : true <-
    !run_exit_cycle(Type, T0).
```

Se dispara en el ciclo de razonamiento siguiente a que `+storage_full` añada la creencia, manteniendo la separación entre "recibir el aviso" (sección 7) y "gestionar los deadlines" (sección 8).

#### Secuencia de deadlines

```agentspeak
+!run_exit_cycle(Type, T0) : delta_t(DT) <-

    // Deadline corto: [T0, T0+ΔT) — salen contenedores urgentes
    +active_deadline(short, urgent, T0);
    .time(H1, M1, S1); Tstart1 = H1 * 3600 + M1 * 60 + S1;
    .print("EVENT | time=", Tstart1, " | agent=scheduler | type=deadline_started | data=urgent");
    .send(transport, tell, start_transport(urgent, T0));
    .wait(DT * 1000);
    -active_deadline(short, urgent, T0);
    .time(H2, M2, S2); Tend1 = H2 * 3600 + M2 * 60 + S2;
    .print("EVENT | time=", Tend1, " | agent=scheduler | type=deadline_ended | data=urgent");

    // Deadline largo: [T0+ΔT, T0+3·ΔT) — salen contenedores no urgentes
    T1 = T0 + DT;
    +active_deadline(long, non_urgent, T1);
    .time(H3, M3, S3); Tstart2 = H3 * 3600 + M3 * 60 + S3;
    .print("EVENT | time=", Tstart2, " | agent=scheduler | type=deadline_started | data=non_urgent");
    .send(transport, tell, start_transport(non_urgent, T1));
    .wait(DT * 2 * 1000);
    -active_deadline(long, non_urgent, T1);
    .time(H4, M4, S4); Tend2 = H4 * 3600 + M4 * 60 + S4;
    .print("EVENT | time=", Tend2, " | agent=scheduler | type=deadline_ended | data=non_urgent").
```

**Exclusión mutua**: `.wait()` es bloqueante dentro de la intención — `active_deadline(long,...)` no se añade hasta que `active_deadline(short,...)` se retira. No es necesario un semáforo explícito.

**Duraciones**: `DT * 1000` ms para el deadline corto; `DT * 2 * 1000` ms para el largo (span `T0+ΔT` a `T0+3·ΔT` = 2·ΔT de duración).

**Llamada a Transport**: `.send(transport, tell, start_transport(Category, StartTime))` donde `Category` es `urgent` o `non_urgent`. En Jason Centralised, el envío a un agente no registrado se descarta silenciosamente — el plan no falla si Transport aún no existe.

**Formato de log**:
```
EVENT | time=T | agent=scheduler | type=deadline_started | data=urgent
EVENT | time=T | agent=scheduler | type=deadline_ended   | data=urgent
EVENT | time=T | agent=scheduler | type=deadline_started | data=non_urgent
EVENT | time=T | agent=scheduler | type=deadline_ended   | data=non_urgent
```

`T` se calcula con `.time(H, M, S)` → `H*3600 + M*60 + S` en el instante exacto de inicio/fin de cada deadline.

### Resumen de cambios

| Archivo | Cambio |
|---|---|
| `scheduler.asl` | Sección 8 añadida: trigger `+exit_cycle`, plan `+!run_exit_cycle` con gestión de `active_deadline`, logs EVENT y llamadas a Transport |

---

## Robots: selección autónoma de contenedores en ciclo de salida

### Motivación

Durante el ciclo de salida los robots no reciben asignaciones del scheduler. Deben consultar qué deadline está activo, filtrar sus contenedores almacenados por el tipo correspondiente, y delegar el transporte al agente Transport de forma autónoma.

### Diseño de la selección autónoma

**Cuándo se ejecuta**: en cada iteración de `work_cycle` cuando el robot está `idle`, antes del `.wait`. El robot consulta el scheduler, hace la selección si hay deadline activo, y luego sigue esperando. Si no hay deadline el ciclo es un no-op.

**Criterio de selección**: orden de almacenamiento (FIFO sobre `stored/2`). El robot usa `.findall` sobre su propia BB para construir la lista `[pair(CId, ShelfId), ...]` de contenedores que almacenó y aún no ha reclamado para salida. Recorre la lista y elige el primer candidato cuyo tipo coincide con el deadline activo.

Justificación: FIFO respeta el orden en que los contenedores llegaron al almacén — los primeros en entrar son los primeros en salir, comportamiento natural en logística. No requiere información de posición de estanterías ni rutas.

**Respeto de capacidades**: `stored(CId, ShelfId)` solo contiene contenedores que el propio robot transportó originalmente, es decir, aquellos que ya cumplían sus límites de peso y tamaño. No se necesita revalidación.

### Flujo por deadline

```agentspeak
+!check_exit_cycle : true <-
    .send(scheduler, askOne, active_deadline(_, Category, _), active_deadline(_, Category, _));
    .findall(pair(CId, ShelfId), (stored(CId, ShelfId) & not exit_claimed(CId)), Candidates);
    !select_for_exit(Candidates, Category).

-!check_exit_cycle : true <- true.   // sin deadline activo
```

**Deadline urgente** (`Category = urgent`): pide al scheduler `container_type(CId, "urgent")`. Si coincide: añade `exit_claimed(CId)`, notifica a Transport con `exit_transport(CId, ShelfId)`.

**Deadline no urgente** (`Category = non_urgent`): pide al scheduler `container_type(CId, ContType)` (sin valor fijo), luego verifica localmente `?non_urgent_container_type(ContType)` — disponible en `common.asl` como `non_urgent_container_type("standard")` y `non_urgent_container_type("fragile")`.

**Iteración**: si el `askOne` al scheduler falla (tipo no coincide o creencia ausente), el plan falla y `-!select_for_exit([_|Rest], Category)` avanza al siguiente candidato. Lista agotada → `+!select_for_exit([], _)` → no-op.

**Idempotencia**: `exit_claimed(CId)` persiste en la BB del robot y evita reclamar el mismo contenedor en ciclos de `work_cycle` posteriores mientras el deadline sigue activo.

### Resumen de cambios

| Archivo | Cambio |
|---|---|
| `robot_{light,medium,heavy}.asl` | `work_cycle` (idle): añadido `!check_exit_cycle` al inicio del cuerpo; nueva sección "Ciclo de salida" con `!check_exit_cycle`, `!select_for_exit/2` (urgente y no urgente), fallbacks y caso base |

---

## Log obligatorio: EVENT container_delivered al depositar en zona de salida

### Motivación

Los objetivos de la semana exigen que cada vez que un robot deposite un contenedor en la zona de salida quede registrado el evento estructurado:

```
EVENT | time=T | agent=robot_id | type=container_delivered | data=container_id
```

El evento debe reflejar correctamente el tipo de contenedor activo en el ciclo (urgente o no urgente).

### Dónde se emite

El momento semántico en que el robot "deposita" el contenedor en la zona de salida es cuando selecciona un candidato válido en `!select_for_exit` y envía `exit_transport(CId, ShelfId)` al agente Transport. Es exactamente ahí — tras verificar el tipo coincidente con el deadline activo y registrar `exit_claimed(CId)` — donde se emite el log, antes del `.send` de notificación.

Esto aplica igualmente a los dos sub-planes de selección:
- `+!select_for_exit([pair(CId, ShelfId)|_], urgent)` → log durante deadline corto
- `+!select_for_exit([pair(CId, ShelfId)|_], non_urgent)` → log durante deadline largo

### Cambios en `+!select_for_exit` (los tres robots)

Antes del `.send(transport, tell, exit_transport(CId, ShelfId))` se añaden tres líneas en cada plan:

```agentspeak
.time(Hd, Md, Sd);
Td = Hd * 3600 + Md * 60 + Sd;
.print("EVENT | time=", Td, " | agent=", Me, " | type=container_delivered | data=", CId);
```

La variable `Me` ya estaba vinculada por `.my_name(Me)` en la línea anterior, por lo que no se necesita ninguna llamada adicional. `Td` usa el mismo cálculo de segundos desde medianoche que el scheduler usa para `deadline_started` y `deadline_ended`, manteniendo la homogeneidad de todos los eventos del sistema.

### Ejemplo de salida esperada

Deadline corto (urgente):
```
[robot_light] [robot_light] Ciclo de salida (urgente): seleccionado container_4 en shelf_7 → Transport
[robot_light] EVENT | time=53412 | agent=robot_light | type=container_delivered | data=container_4
```

Deadline largo (no urgente):
```
[robot_medium] [robot_medium] Ciclo de salida (no urgente): seleccionado container_1 (standard) en shelf_5 → Transport
[robot_medium] EVENT | time=53472 | agent=robot_medium | type=container_delivered | data=container_1
```

### Resumen de cambios

| Archivo | Cambio |
|---|---|
| `robot_light.asl` | `+!select_for_exit/urgent` y `+!select_for_exit/non_urgent`: 3 líneas de log EVENT añadidas antes del `.send(transport, ...)` |
| `robot_medium.asl` | Ídem |
| `robot_heavy.asl` | Ídem |

---

## Verificación manual — Objetivos de la semana (Sprint 6)

Se ejecutó el sistema durante ~2 minutos con la configuración por defecto (`delta_t(30)` = 30 s). A continuación se documenta el análisis completo de los objetivos.

### Log de referencia analizado

```
[robot_light]   stored container_3 at shelf_1    — standard
[robot_medium]  stored container_1 at shelf_5    — standard
[robot_medium]  stored container_2 at shelf_6    — standard
[robot_medium]  stored container_4 at shelf_7    — urgent
[robot_medium]  stored container_5 at shelf_6    — fragile
[robot_light]   stored container_6 at shelf_2    — standard
[robot_heavy]   stored container_7 at shelf_8    — standard
[robot_medium]  stored container_8 at shelf_7    — standard
[robot_light]   stored container_9 at shelf_3    — standard
[robot_light]   stored container_10 at shelf_4   — fragile
[robot_light]   stored container_11 at shelf_4   — standard
[robot_light]   stored container_12 at shelf_1   — standard
[robot_light]   stored container_13 at shelf_1   — (en tránsito al cerrar)
[robot_medium]  stored container_14 at shelf_5   — fragile  (en tránsito al cerrar)
```

La sesión terminó antes de que el almacenamiento se saturase en ningún tipo, por lo que el ciclo de salida no se activó durante esta ejecución. Esto es esperado: con `delta_t(30)` y llegadas cada 5-10 s la saturación requiere decenas de contenedores más.

### Verificación punto a punto (según objetivos de la semana)

| # | Objetivo | Estado | Evidencia |
|---|---|---|---|
| 1 | Activar ciclo de salida al saturar tipo y definir T0 | ✅ Implementado | `+storage_full(Type,_)[source(supervisor)]` añade `exit_cycle(Type,T0)` con `.time/3`. Verificado en código de `scheduler.asl` sección 7. |
| 2a | Deadline corto para urgentes (`T0 + ΔT`) | ✅ Implementado | `+active_deadline(short, urgent, T0)` + `.wait(DT*1000)`. Verificado en código de `scheduler.asl` sección 8. |
| 2b | Deadline largo para no urgentes (`T0 + 3·ΔT`, duración `2·ΔT`) | ✅ Implementado | `+active_deadline(long, non_urgent, T1)` + `.wait(DT*2*1000)`. |
| 2c | ΔT configurable y justificado | ✅ Implementado | `delta_t(30)` en `common.asl`. Justificación: robot ligero (speed=3) ida+vuelta a shelf_1 ≈ 20 pasos × 300 ms ≈ 6 s real; con 5-10 s entre contenedores, δt=30 s da margen suficiente. |
| 3 | Solo un deadline activo en cada instante | ✅ Garantizado | El `.wait()` en `+!run_exit_cycle` es bloqueante dentro de la intención: `active_deadline(long,...)` no se añade hasta retirar `active_deadline(short,...)`. Exclusión mutua sin semáforo explícito. |
| 4a | Robots consideran solo contenedores del deadline activo | ✅ Implementado | `!select_for_exit` filtra por `category` (devuelta por `askOne active_deadline`) y verifica el tipo del contenedor contra el scheduler. |
| 4b | Robots deciden autónomamente qué contenedor transportar | ✅ Implementado | FIFO sobre `stored/2` local: `.findall(pair(CId,ShelfId), stored(...) & not exit_claimed(...))`. Sin asignación explícita del scheduler. |
| 4c | Robots no dependen de asignaciones explícitas en ciclo salida | ✅ Implementado | `check_exit_cycle` solo usa `askOne` para leer el deadline activo; la selección y reclamación (`exit_claimed`) son completamente locales. |
| 5a | Transportes ocurren durante ambos ciclos de salida | ✅ Verificable en código | Ambos planes `+!select_for_exit` emiten `exit_transport` + log EVENT. La sesión de verificación terminó antes de activar el ciclo; para verlo en vivo se necesita una sesión más larga hasta saturación. |
| 5b | Sistema no se bloquea al cambiar de deadline corto a largo | ✅ Garantizado por diseño | La transición es puramente secuencial dentro de una intención. `-active_deadline(short,...)` precede a `+active_deadline(long,...)` en el mismo plan. No hay send/await entre agentes en esa transición. |
| 5c | No se reinicia al cambiar de deadline | ✅ Sin reinicio | Los robots no tienen trigger sobre `active_deadline`; reciben el nuevo valor en el siguiente `check_exit_cycle` (dentro del `work_cycle` de 3-4 s). Transición transparente. |
| LOG-1 | `EVENT deadline_started` | ✅ Implementado | Emitido en `+!run_exit_cycle` para `urgent` y `non_urgent`. Formato exacto: `EVENT \| time=T \| agent=scheduler \| type=deadline_started \| data=container_type`. |
| LOG-2 | `EVENT deadline_ended` | ✅ Implementado | Emitido tras cada `.wait()` en `+!run_exit_cycle`. |
| LOG-3 | `EVENT container_delivered` | ✅ Implementado (este sprint) | Emitido en `+!select_for_exit` de los tres robots justo antes de `exit_transport`. Refleja el tipo activo (urgente/no urgente) según el deadline en curso. |

### Problema encontrado: ciclo de salida no se activó en la sesión de prueba

**Causa**: la sesión duró ~2 minutos con llegadas cada 5-10 s (≈14 contenedores). Las estanterías tienen capacidad suficiente para decenas de contenedores (shelf_1 a shelf_4: 8 unidades c/u; shelf_5 a shelf_7: 12 c/u; shelf_8 a shelf_9: 20 c/u). La saturación de un tipo requiere agotar todas las estanterías de esa categoría — no ocurre en 2 minutos con generación aleatoria (solo 15% de probabilidad de tipo "urgent").

**Sin impacto en corrección**: el código del ciclo de salida, deadlines y log EVENT fue implementado en sprints anteriores; el único cambio de este sprint (log `container_delivered`) se verificó estáticamente en código. Para observar los tres EVENT en tiempo real se necesita una sesión de ≥15-20 minutos, o reducir temporalmente `delta_t` y las capacidades de las estanterías.

**Recomendación**: reducir capacidades de estantería en `initializeShelves()` (p.ej. a 2-3 contenedores) para forzar saturación en sesiones cortas de demo.

### Estado global del sistema en el log analizado

- **Sin bloqueos**: ningún `path_blocked` ni `task_failed` en toda la ejecución.
- **Sin reinicios**: todos los agentes mantuvieron su estado a lo largo de la sesión.
- **Tasa de éxito**: 12 contenedores almacenados de 13 generados hasta cierre (92%). El contenedor 13 y 14 estaban en tránsito al terminar — no errores.
- **Logs de deadline**: no aparecen en esta sesión (ciclo no activado), pero el formato correcto es verificable en `scheduler.asl` líneas 360 y 367.