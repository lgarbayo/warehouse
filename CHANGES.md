# Changes

## Fix: Robot Navigation Deadlocks

### 1. Sistema de autopistas verticales (x=9 y x=19)
Se solucionó el problema de los robots atascándose o sufriendo `nav_timeout` al intentar ir a la zona de salida (Outbound) o moverse entre estanterías. El problema principal era que la zona de salida se movió a `x=17..19` pero las reglas de navegación (`!navigate`) seguían asumiendo que estaba en `x < 3`. Como resultado, los robots usaban navegación "greedy" (diagonal directa) y chocaban contra los bloques horizontales de las estanterías, atascándose indefinidamente.

Para solucionarlo, se reescribió por completo la lógica de enrutamiento con waypoints en los 4 agentes (`robot_light`, `robot_medium`, `robot_heavy`, `robot_heavy2`):
- **Highway 9 y 19**: Se usan las columnas `x=9` (izquierda de las estanterías) y `x=19` (derecha de las estanterías) como pasillos verticales principales.
- Al salir de las estanterías hacia la entrada o clasificación (`TX < 9`), se usa la ruta por `x=9`.
- Al salir hacia Outbound (`TX >= 17, TY < 2`), se usa la ruta por `x=19`, evitando por completo chocar con las estanterías.
- Para cambios de fila (`Y \== TY`) cuando el robot ya está dentro de las estanterías (`X >= 10`), el robot busca la autopista más cercana (`x=9` si está en la mitad izquierda, `x=19` si está en la mitad derecha) para cambiar de fila de forma segura antes de adentrarse en el pasillo correcto. Se solucionó también un fallo de recursión infinita en esta regla.

### 2. `path_backoff` ortogonal
Se solucionó el problema de los robots quedándose atascados (el "sándwich" en la columna `x=1` como `1,10`). Antes, cuando un robot encontraba un obstáculo en el eje Y, el `path_backoff` intentaba moverse en el mismo eje Y (hacia adelante o atrás), lo que causaba colisiones continuas. Ahora, cuando se bloquea en el eje Y, el backoff intenta un movimiento ortogonal (lateral) en el eje X, y viceversa. Esto permite a los robots esquivarse fluidamente en los pasillos.

### 2. Bucle infinito en `!navigate` para estanterías (`TX >= 10`)
Se corrigió un bucle de recursión infinita en la regla de navegación `+!navigate(TX, TY) : TX >= 10`. Si un robot era asignado a una celda adyacente a una estantería que no era un corredor principal (`corridor_row`), el robot evaluaba infinitamente la regla que intentaba enviarlo a la columna `x=9` y de vuelta, causando que se quedara completamente inmóvil. La condición se simplificó para comprobar si el robot ya cruzó la columna `9` (`X < 9`), evitando retrocesos innecesarios y bucles infinitos.
## Iteración 3: Ciclo de salida por tipo, deadlines y agente Transport

### Objetivos cumplidos

1. Ciclo de salida activado por tipo de contenedor con instante inicial T0.
2. Deadline corto (urgentes, T0+ΔT) y deadline largo (no urgentes, T0+3ΔT) no solapados.
3. Solo un deadline activo en cada instante.
4. Robots deciden autónomamente qué contenedor transportar sin asignaciones explícitas.
5. Agente Transport creado para simular recogida de contenedores del OUTBOUND.
6. Fix bug #4 (iteración 2): `askOne` eliminado del ciclo de salida.

---

### 1. `common.asl`: creencias `shelf_urgency`

Se añaden 9 creencias estáticas `shelf_urgency(ShelfId, urgent|non_urgent)` para los nueve shelves. Necesarias para que los robots filtren contenedores outbound por fase de deadline sin consultar al scheduler.

---

### 2. Scheduler: broadcast de `active_deadline` y llamada a Transport (`scheduler.asl`)

**`!run_exit_cycle`** ampliado con dos cambios:

- Al inicio de cada deadline: `for (.member(R, AllRobots)) { .send(R, tell, active_deadline(...)); }` — broadcast directo a todos los robots. Elimina la necesidad de que cada robot haga `askOne` (fix bug #4).
- Al final de cada deadline: `for (.member(R, AllRobots)) { .send(R, untell, active_deadline(...)); }` — retira la creencia localmente en cada robot al terminar la fase.
- Al final de cada deadline: `.send(transport, tell, transport_request(Type, Phase))` — notifica al agente Transport.

---

### 3. Robots `robot_light`, `robot_medium`, `robot_heavy`: fix `!check_exit_cycle`

**Antes** (bug #4):
```agentspeak
+!check_exit_cycle : true <-
    .send(scheduler, askOne, active_deadline(_, Category, _), active_deadline(_, Category, _));
    ...
```

**Después**:
```agentspeak
+!check_exit_cycle : active_deadline(_, Category, _) <-
    .findall(pair(CId, ShelfId), (stored(CId, ShelfId) & not exit_claimed(CId)), Candidates);
    !select_for_exit(Candidates, Category).

+!check_exit_cycle : true <- true.
```

El robot consulta su propia base de creencias (creencia `active_deadline` recibida por broadcast) sin suspender la intención.

---

### 4. `robot_heavy2.asl`: unificado con el resto de robots

robot_heavy2 adoptó la misma arquitectura que `robot_light`, `robot_medium` y `robot_heavy`: reclamación desde `+container_at_entrance`, selección autónoma de estantería con `!pick_shelf`, ciclo de salida por `active_deadline`. Se corrigieron además: argumentos invertidos en `pickup_from_shelf`, `release_task` sin argumento, y `unclaim_container` ausente en varios handlers de error.

---

### 5. Agente `transport.asl` (nuevo)

Simula la llegada de camiones al finalizar cada deadline. Recibe `transport_request(ContainerType, Phase)` del scheduler y emite el evento obligatorio:

```
EVENT | time=T | agent=transport | type=transport_dispatched | data=ContainerType
```

Añadido a `warehouse.mas2j`.

---

### 6. Java: fix enum `OUTBOUND` duplicado (`CellType.java`, `WarehouseView.java`)

`CellType.java` tenía dos entradas `OUTBOUND` (bug de merge). `WarehouseView.java` tenía el `case OUTBOUND:` duplicado en el switch de pintado. Se eliminó la entrada duplicada en ambos ficheros; se conserva el color azul claro `(200, 230, 255)` para la zona de salida (x=17-19, y=0-1).

---

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

### 2. Scheduler: solo gestión del ciclo de salida (`scheduler.asl`)

**Eliminado**: toda la lógica de asignación de tareas y robots. El scheduler no interviene en el ciclo inbound.

**Conservado**:
- Gestión del ciclo de salida: `no_shelf_space/storage_full → exit_cycle → run_exit_cycle` con `active_deadline` broadcast a todos los robots.
- Handler `container_exited(CId)` para confirmación de entrega y limpieza de `stored_at`.
- No-ops para mensajes inbound que los robots siguen enviando (`task_failed`, `container_in_expansion`).

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

## Logging de eventos

Los eventos obligatorios se emiten por consola con `.print()` siguiendo el formato:

```
EVENT | time=T | agent=scheduler   | type=deadline_started    | data=urgent
EVENT | time=T | agent=scheduler   | type=deadline_ended      | data=urgent
EVENT | time=T | agent=scheduler   | type=output_phase_started| data=container_type
EVENT | time=T | agent=supervisor  | type=no_space_detected   | data=container_type
EVENT | time=T | agent=robot_id    | type=container_delivered | data=container_id
```

`T` es el tiempo en segundos desde medianoche (`H*3600 + M*60 + S`). Formato consistente en todos los agentes.

## Sustitución del algoritmo de pathfinding: BFS → Navegación distribuida en agentes ASL

### Problema
El algoritmo BFS (`calcularRuta`) en Java era inadecuado:
- Requería estructuras de datos proporcionales al tamaño del grid: `HashMap` para rastrear padres y `ArrayDeque` para la cola. En el peor caso exploraba los 300 nodos del grid (20×15) por cada paso.
- Calculaba la ruta completa de una vez aunque solo se necesitara el siguiente paso.
- El razonamiento de navegación estaba en el entorno (entorno grueso): el agente decía "ve a X" y Java calculaba cómo. Los robots no tenían control sobre su propio movimiento.

### Solución: navegación distribuida en los agentes

Se eliminó todo el razonamiento de ruta de Java. El entorno ahora solo provee primitivas:

| Acción Java | Descripción |
|---|---|
| `move_step(X, Y)` | Mueve el robot exactamente una celda. Valida límites, obstáculos y colisiones. Falla si la celda está ocupada. |
| `move_to_shelf(ShelfId)` | Calcula la celda adyacente libre a la estantería y emite `nav_target(TX,TY)`. |
| `move_to_container(CId)` | Calcula la celda adyacente libre al contenedor y emite `nav_target(TX,TY)`. |
| `move_to_outbound` | Encuentra la celda libre más cercana en la zona OUTBOUND y emite `nav_target`. |
| `move_to_expansion` | Encuentra la celda libre más cercana en la zona CLASSIFICATION y emite `nav_target`. |

Cada robot conduce su propia ruta en ASL con el plan `!navigate(TX, TY)`.

### Arquitectura de navegación ASL

#### Paso greedy con prioridad Manhattan (`!do_step`)
En cada paso se prioriza el eje con mayor distancia restante al destino:

```agentspeak
+!do_step(X, Y, TX, TY) : TX > X & TX - X >= TY - Y <- !try_x_then_y(...)
+!do_step(X, Y, TX, TY)                              <- !try_y_then_x(...)
```

Equivale a usar la **distancia Manhattan** como heurística implícita: `h = |TX-X| + |TY-Y|`. Es admisible — nunca sobreestima el coste en un grid ortogonal.

El patrón visual resultante es una escalera diagonal (zigzag): pasos horizontales y verticales alternados que convergen hacia el destino. Es el equivalente Manhattan de una línea recta diagonal.

#### Waypoints de corredor (`!navigate`)
Las estanterías forman filas compactas que el greedy no puede atravesar directamente. Se usan dos columnas siempre libres como autopistas verticales:

- **x=9** — corredor izquierdo (entre zona libre y estanterías)
- **x=19** — corredor derecho (extremo del almacén)

Reglas de routing en `!navigate`:
- Destino en zona libre (`TX < 9`) desde estanterías → cruzar por x=9 primero
- Destino en outbound (`TX >= 17, TY < 2`) → cruzar por x=19
- Cambio de fila dentro de estanterías → ir al corredor más cercano (x=9 si X≤14, x=19 si X>14)

```
posición → (9 o 19, targetY) → (targetX, targetY)
```

#### Gestión de colisiones (`!step_with_retry`)
Si `move_step` falla porque otra celda está ocupada:
- Intentos 1-2: espera aleatoria 300-1200ms y reintenta
- Intentos 3-4: ejecuta `!path_backoff` (paso perpendicular) + espera
- Intentos 5-6: espera larga 1500-3000ms
- Tras 6 fallos: notifica al supervisor con `path_blocked` y falla el plan

`nav_limit(300)` actúa como timeout global: si el robot da más de 300 pasos sin llegar, notifica `nav_timeout` y falla.

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
| `common.asl` | — | `shelf_category` beliefs, `!pick_shelf`, `!pick_least_occupied_shelf` |

> Nota: la selección de estantería pasó primero al scheduler (como planificador centralizado) y posteriormente se movió a `common.asl` para que los robots la ejecuten autónomamente, en coherencia con el objetivo "el scheduler no asigna tareas ni robots".

---

## Decisión de diseño: Planificación formal distribuida (R&N Cap. 11)

### El modelo de planificación clásico

El enunciado requería planificación formal sobre contenedores pendientes y disponibilidad de robots (R&N Cap. 11). El modelo centralizado sería:

- **Estado**: `ps_robot_free(Robot)`, `ps_shelf(ShelfId, Occ)`, `ps_pending(CId, W, H, Weight, Type)`
- **Esquema de acción**: `assign(Robot, CId, ShelfId)` con precondiciones (robot libre, contenedor pendiente, estantería compatible, robot capaz) y efectos (robot ocupado, contenedor asignado, ocupación +1)
- **Búsqueda**: forward search greedy best-first con heurística `urgency_weight + 3 - occupancy`

Esto fue implementado en una iteración anterior. Los objetivos de la semana 2 lo reemplazaron.

### Por qué no se implementa centralizado

El objetivo de la semana 2 impone que el scheduler **no asigne tareas ni robots**. Un planificador centralizado que genera `assign(Robot, CId, Shelf)` viola directamente este requisito: los robots quedan subordinados al razonamiento del scheduler y pierden autonomía.

### Cómo se resuelve en el código actual

La planificación se **descentraliza**: cada robot aplica localmente el mismo razonamiento que el planificador centralizado haría globalmente.

**Contenedores pendientes** — gestión reactiva y por polling:
- `+container_at_entrance(CId, Type, Weight, W, H)` dispara inmediatamente si el robot puede manejar el contenedor y está idle. Equivale a la precondición `ps_robot_free(Robot) & ps_pending(CId, ...)` del esquema clásico.
- `!check_pending_containers` en `!work_cycle` recupera contenedores que llegaron mientras el robot estaba ocupado.
- `claim_container(CId)` (Java `ConcurrentHashMap.putIfAbsent`) garantiza exclusión mutua: equivale a la restricción de que un contenedor solo puede aparecer en un `assign(...)` del plan.

**Disponibilidad de robots** — estado local:
- Cada robot mantiene `state(idle/working)`. La guarda `state(idle)` en `+container_at_entrance` es la precondición `ps_robot_free(Robot)` del esquema clásico, evaluada localmente sin consultar al scheduler.

**Selección de estantería** — planificación greedy con heurística en `!pick_shelf` (`common.asl`):
- **Estado observado**: `shelf_available(S)`, `shelf_occupancy(S, Occ)` — percepciones del entorno compartido
- **Decisión**: menor ocupación dentro de la categoría compatible (light/medium/heavy) según peso del contenedor
- **Fallback**: cualquier estantería con ocupación < 85% que aguante el peso
- La heurística es admisible: nunca asigna a estantería incompatible ni sobrecargada

**Resultado**: la planificación clásica centralizada se reemplaza por coordinación emergente entre agentes autónomos. La consistencia global (sin doble asignación, sin sobrecarga de estanterías) se garantiza mediante el entorno compartido y el reclamo atómico, no mediante un planificador central.

---

## Fix: eliminación de `nav_abort_signal`

### Problema
La gestión de timeout de navegación dependía de `?nav_abort_signal` — una consulta de creencia diseñada para fallar — como mecanismo de propagación de fallo fuera de una intención anidada. Si algún agente añadía accidentalmente `nav_abort_signal` a su base de creencias, el abort dejaba de dispararse silenciosamente.

### Solución
Sustituido por un contador `nav_limit(N)` decrementado en cada paso de `!navigate`. Cuando `N` llega a 0, el plan de timeout `+!navigate(TX, TY) : true` notifica al supervisor y falla explícitamente. El control de flujo es directo y sin dependencias ocultas en el estado de la base de creencias.

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

#### Backoff general `!path_backoff` con estrategia híbrida

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

La creencia `storage_saturated(Type)` actúa como semáforo por tipo: la notificación se envía **una sola vez** por tipo, independientemente de cuántos `no_shelf_space` lleguen. El tipo del contenedor se obtiene de `container_received_type(CId, Type)`, creencia que el supervisor mantiene desde la recepción inicial del contenedor. T0 se expresa en segundos desde medianoche usando `.time/3` de Jason.

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
| `scheduler.asl` | `shelf_category` → `shelf_for(Urgency, SizeCat, ShelfId)`; 6 planes `assign_shelf` tipados; `pick_least_occupied` con 3 argumentos |
| `scheduler.asl` | Sección 8 añadida: trigger `+exit_cycle`, plan `+!run_exit_cycle` con gestión de `active_deadline`, logs EVENT y llamadas a Transport |
| `robot_{light,medium,heavy}.asl` | `work_cycle` (idle): `request_task` → `!check_exit_cycle`; nueva sección "Ciclo de salida" con `!check_exit_cycle`, `!select_for_exit/2`, log `EVENT container_delivered` |

# Cambios realizados — 2ª semana (pull model + robot_heavy2)


### Mejora: robots no vuelven a la base si hay contenedor pendiente

**Comportamiento anterior:** al terminar una tarea, `!check_queue` siempre navegaba de vuelta a la base y solo entonces `!work_cycle` comprobaba si había contenedores que reclamar.

**Primera implementación (scheduler-based, commit `ba48854`):** `!check_queue` enviaba `request_task` al scheduler y esperaba 2s. Obsoleta desde el refactor a pull protocol.

**Implementación actual (pull protocol):** `!check_queue` comprueba la belief base antes de decidir si navegar. Si hay un contenedor compatible esperando, setea `state(idle)` inmediatamente sin navegar — `!work_cycle` lo reclamará en la siguiente iteración. Si no hay nada, usa un estado intermedio `state(returning)` para navegar a base sin riesgo de race condition:

```agentspeak
// robot_heavy / robot_heavy2
+!check_queue : position(InitX, InitY) <-
    .abolish(error(_, _));
    !release_zone(inbound);
    !release_zone(expansion);
    if (container_at_entrance(_, _, Weight, W, H) &
            (Weight > 30 | W > 1 | H > 2) &
            Weight <= 100 & W <= 2 & H <= 3) {
        -+state(idle)
    } else {
        -+state(returning);
        !navigate(InitX, InitY);
        -+state(idle)
    }.
```

**Por qué `state(returning)` en lugar de `state(idle)` durante la navegación a base**: si se setea `state(idle)` antes de completar la navegación, el trigger reactivo `+container_at_entrance : state(idle)` puede disparar mientras `!navigate` está en curso, creando dos intenciones enviando `move_step` en paralelo — oscilación. `state(returning)` bloquea los triggers reactivos durante la navegación a base. Es funcionalmente idéntico al comportamiento original cuando no hay contenedor disponible; la diferencia real es solo cuando hay contenedor esperando (rama `if`).

Cada robot usa los guards de capacidad propios (medium: `Weight>10 | H>1`; light: `not(Weight>10) & not(W>1) & not(H>1)`). No se llama a `!try_claim` desde `!check_queue` para evitar cadena de llamadas anidadas.

**Verificado en runtime**: robot_medium encadenó 6 tareas consecutivas sin volver a base (container_1→2→4→6→5→8); robot_light encadenó 3 (container_7→9→10).

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


---

## Semana 3 — Refactorización y corrección de bugs

### Arquitectura: scheduler sin asignación inbound

El scheduler dejó de gestionar el ciclo inbound por completo. Los robots reclaman contenedores autónomamente desde `+container_at_entrance` y seleccionan estanterías con `!pick_shelf` (`common.asl`). El scheduler solo gestiona el ciclo de salida.

Archivos afectados: `scheduler.asl` reescrito (eliminado planificador formal inbound), `common.asl` ampliado, todos los robots refactorizados.

---

### Fix: selección de estantería con urgencia y categoría (`common.asl`)

**Problema**: `!pick_shelf` asignaba estanterías solo por peso/tamaño, ignorando la urgencia del contenedor. Contenedores standard acababan en estanterías urgentes (S1/S5/S8) y viceversa.

**Solución**: `!pick_shelf` usa `claimed_type(CId, "urgent")` para distinguir entre planes urgentes (→ S1, S5, S8) y no urgentes (→ S2-S4, S6-S7, S9). Los fallbacks también respetan urgencia y categoría física:
- Peso > 30kg → solo estanterías `heavy`
- 10 < Peso ≤ 30kg → `medium` o `heavy`
- Peso ≤ 10kg → cualquiera

`!pick_least_occupied_shelf` recibe ahora `(CId, Cat, Urg)` para filtrar por ambos criterios.

---

### Fix: planes compartidos movidos a `common.asl`

`!try_claim` y `!select_shelf_and_execute` eran idénticos en los 4 robots. Movidos a `common.asl` eliminando ~40 líneas duplicadas. El label del print usa `.my_name(Me)` para mantener trazabilidad.

---

### Fix: supervisor stats — race condition en `container_at_entrance`

**Problema**: `claim_container` retira `container_at_entrance` atómicamente. Si el supervisor no procesó el percept antes, nunca incrementa `total_received`.

**Solución**: robots envían `.send(supervisor, tell, container_claimed(CId, Type, Weight))` tras un claim exitoso. Supervisor tiene handler `+container_claimed` como ruta principal y mantiene `+container_at_entrance` como fallback. La creencia `container_received(CId)` previene doble conteo.

---

### Fix: paths `storage_full` y `no_shelf_space` unificados (`scheduler.asl`, `supervisor.asl`)

**Problema**: el path `+storage_full` (vía robot container_error) no añadía `blocked_type` ni emitía `EVENT | type=output_phase_started`. Solo `+no_shelf_space` lo hacía.

**Solución**: `+storage_full` ahora añade `+blocked_type(Type)` y emite el evento obligatorio, igual que `+no_shelf_space`. Ambos paths son ahora equivalentes.

Además, `storage_saturated(Type)` en supervisor ahora se elimina cuando una estantería del mismo tipo recupera disponibilidad (`+shelf_available` handler), permitiendo que el path `container_error` dispare de nuevo en futuras saturaciones.

---

### Fix: cooldown `shelf_wait` para contenedores sin estantería (`common.asl`, todos los robots)

**Problema**: cuando `!pick_shelf` fallaba definitivamente o un robot alcanzaba `expansion_drop_final`, `unclaim_container` re-emitía `container_at_entrance` y los robots lo re-reclamaban inmediatamente, generando un bucle de retries rápido y errores falsos en el supervisor.

**Solución**: se añade `+shelf_wait(CId)` en dos puntos:
- `!pick_shelf` final (N ≥ 3 retries): en `common.asl`
- `expansion_drop_final`: en los 4 robots

`shelf_wait` tiene auto-clear a los 20s (`+shelf_wait(CId) <- .wait(20000); -shelf_wait(CId)`) y se limpia antes si otro robot reclama el contenedor. Los guards de `+container_at_entrance` y `!check_pending_containers` incluyen `not shelf_wait(CId)`.

---

### Fix: error count correcto para errores repetidos (`supervisor.asl`)

**Problema**: si dos robots reportaban `container_error(CId, no_shelf_space)` para el mismo contenedor, el segundo reporte no incrementaba el contador porque `error_occurred(CId, ErrorType)` ya existía en la base de creencias.

**Solución**: el handler `+container_error` solo añade `error_occurred` y actualiza el contador si `not error_occurred(CId, ErrorType)`. El print de trazabilidad sigue apareciendo siempre.

### Fix: `blocked_type` propagado a robots durante el ciclo de salida (`scheduler.asl`, todos los robots)

**Problema**: `blocked_type(Type)` solo existía en la base de creencias del scheduler. Los robots no lo conocían, por lo que seguían intentando reclamar contenedores del tipo bloqueado durante el exit cycle. Con dos robots pesados compitiendo por el mismo contenedor sin estantería disponible, se generaba un bucle alternante: mientras uno tenía `shelf_wait` activo el otro lo reclamaba, impidiendo que el ciclo de salida tuviera el tiempo necesario para liberar espacio.

**Solución** (dos partes):

- **`scheduler.asl` — `!run_exit_cycle`**: al inicio del ciclo se hace broadcast `tell blocked_type(Type)` a todos los robots; al finalizar (antes de limpiar la belief base), broadcast `untell blocked_type(Type)`.

```agentspeak
+!run_exit_cycle(Type, T0) : delta_t(DT) <-
    .findall(R, robot_capacity(R, _, _, _, _), AllRobots);
    for (.member(R, AllRobots)) { .send(R, tell, blocked_type(Type)); };
    // ... fases urgente y no_urgente ...
    for (.member(R, AllRobots)) { .send(R, untell, blocked_type(Type)); };
    .abolish(exit_cycle(_, _));
    .abolish(blocked_type(_));
    -active_exit_cycle.
```

- **Todos los robots — planes reactivos y `!check_pending_containers`**: añadido `not blocked_type(Type)` como guard en todos los puntos de reclamación. También se aprovechó para añadir `not shelf_wait(CId)` en los `!check_pending_containers` de `robot_heavy` y `robot_heavy2`, donde faltaba.

**Resultado**: durante el exit cycle, ningún robot intentará reclamar contenedores del tipo bloqueado. Cuando el ciclo termina y se libera espacio en estantería, el `untell` reactiva los robots y el contenedor pendiente se almacena directamente.

### Fix: Bug 2 — contenedor perdido tras fallo en `!execute_exit` (`WarehouseArtifact.java`, todos los robots)

**Problema**: si `pickup_from_shelf` tenía éxito (contenedor físicamente recogido de la estantería, `exit_picked(CId)` activado) pero la navegación posterior hacia la zona outbound fallaba, el handler `-!execute_exit : exit_picked(CId)` intentaba devolver el contenedor a la estantería con `!return_to_shelf`. Si esta también fallaba, el plan de fallo `-!return_to_shelf` llamaba a `!safe_expand_drop`, que depositaba el contenedor en la zona de expansión sin emitir ningún percept `container_at_entrance`. El contenedor quedaba abandonado: no estaba en estantería, no estaba en outbound y ningún robot podía reclamarlo.

**Solución** (dos partes):

- **`WarehouseArtifact.java`**: añadido método helper `findFreeEntranceCell()` que localiza una celda libre de tipo `ENTRANCE` (o devuelve `(5,0)` como fallback). Modificado `executeUnclaimContainer` para, cuando el robot lleva físicamente el contenedor, resetear su posición a una celda de entrada tras el `robot.drop()`:

```java
private int[] findFreeEntranceCell() {
    List<int[]> cells = new ArrayList<>();
    for (int x = 0; x < GRID_WIDTH; x++)
        for (int y = 0; y < GRID_HEIGHT; y++)
            if (grid[x][y] == CellType.ENTRANCE && !hayContenedorEn(x, y))
                cells.add(new int[]{x, y});
    return cells.isEmpty() ? new int[]{5, 0} : cells.get(0);
}
// En executeUnclaimContainer, tras robot.drop() + setPicked(false):
int[] cell = findFreeEntranceCell();
carried.setPosition(cell[0], cell[1]);
```

  Este cambio inicia la corrección del **Bug 3** para el caso en que el robot lleva el contenedor.

- **Todos los robots — `-!return_to_shelf(CId, _)`**: reemplazado `!safe_expand_drop(CId)` por `unclaim_container(CId)`. La acción Java re-emite `container_at_entrance` con el contenedor reposicionado en la entrada, reintroduciéndolo en el ciclo inbound normal:

```agentspeak
// Antes:
-!return_to_shelf(CId, _) <-
    !safe_expand_drop(CId);
    .abolish(stored(CId, _));
    .abolish(claimed_type(CId, _)).

// Después:
-!return_to_shelf(CId, _) <-
    unclaim_container(CId);
    .abolish(stored(CId, _));
    .abolish(claimed_type(CId, _)).
```

**Flujo corregido**:
```
pickup_from_shelf ✓ → navegar a outbound ✗ → return_to_shelf ✗
                                                    ↓
                                          unclaim_container(CId)
                                          → drop en Java
                                          → posición reseteada a ENTRANCE
                                          → container_at_entrance emitido
                                          → otro robot lo reclama ✓
```

### Semana 4 — Infraestructura de seguimiento de deadlines

**Objetivo**: adaptar el supervisor para que conozca T0, los deadlines activos, el tiempo actual y el estado completo de los contenedores.

- **`scheduler.asl` — `!run_exit_cycle`**: el scheduler envía `active_deadline` también al supervisor (tell al inicio de cada fase, untell al final), además de a los robots. El supervisor recibe así T0 y la categoría (urgent/non_urgent) de cada deadline.

- **4 robots — `+!execute_exit`**: tras depositar en outbound, cada robot envía `.send(supervisor, tell, container_delivered(CId))`. Permite al supervisor saber qué contenedores han sido efectivamente entregados.

- **`supervisor.asl`**: nueva sección "Seguimiento de ciclo de salida":
  - `+active_deadline(Phase, Cat, T0)[source(scheduler)]` — log de recepción con tiempo actual.
  - `+container_delivered(CId)[source(Robot)]` — almacena `container_delivered_fact(CId)`.

El supervisor puede ahora consultar el ciclo de vida completo de cada contenedor:

| Creencia | Significado |
|---|---|
| `container_received(CId)` | Contenedor llegó al sistema |
| `container_stored_fact(CId, ShelfId)` | Contenedor en estantería |
| `container_delivered_fact(CId)` | Contenedor entregado a outbound |
| `active_deadline(Phase, Cat, T0)` | Deadline activo con T0 en segundos |

### Semana 4 — Criterio de incumplimiento de deadline (`supervisor.asl`)

**Objetivo**: detectar y registrar contenedores que no fueron entregados a outbound antes de que expirara su deadline.

El supervisor reacciona a `-active_deadline` (creencia retirada por el scheduler tras el `.wait` de cada fase) y aplica el criterio explícito:

- **Deadline urgente** (`-active_deadline(_, urgent, T0)`):  
  `Tnow >= T0 + DT` AND existen contenedores de tipo `urgent` en estantería sin entregar.

- **Deadline no urgente** (`-active_deadline(_, non_urgent, T1)`):  
  `Tnow >= T1 + 2·DT` AND existen contenedores `standard`/`fragile` en estantería sin entregar.

Por cada contenedor incumplido se emite el evento obligatorio:
```
EVENT | time=T | agent=supervisor | type=deadline_missed | data=container_id
```

La detección usa las creencias acumuladas durante el ciclo:
- `container_stored_fact(CId, _)` — contenedor estuvo en estantería
- `container_received_type(CId, Type)` — tipo del contenedor
- `not container_delivered_fact(CId)` — no fue entregado a outbound

El check `if (Tnow >= Deadline)` hace el criterio explícito aunque en la práctica siempre se cumple al dispararse el trigger (el scheduler retira la creencia justo al expirar el plazo).

### Semana 4 — Detección periódica de incumplimientos (`supervisor.asl`)

**Objetivo**: el supervisor comprueba activamente cada 5 segundos si el deadline ha expirado, en lugar de esperar solo al evento reactivo de fin de fase.

**Diseño**: dos mecanismos en paralelo previenen tanto la detección tardía como el doble reporte:

- **Monitor periódico** (`+!monitor_deadline`): arranca cuando el supervisor recibe `+active_deadline`. Comprueba cada 5s si `Tnow >= Deadline`. En cuanto se cumple, establece `deadline_checked(Cat)`, busca contenedores incumplidos y emite los eventos. El loop para.

- **Backup reactivo** (`-active_deadline`): se dispara cuando el scheduler retira la creencia (fin de fase). Si el monitor ya actuó (`deadline_checked` presente), solo limpia el flag. Si el monitor estaba en `.wait` cuando expiró el plazo, hace la comprobación definitiva.

**Flujo completo**:
```
+active_deadline recibido
        ↓
!monitor_deadline (loop cada 5s)
        ↓
   Tnow < Deadline → .wait(5000) → vuelve a comprobar
        ↓
   Tnow >= Deadline → +deadline_checked → !report_deadline_missed → para

        ↓ (scheduler hace untell → -active_deadline)
   • monitor YA detectó → solo limpia deadline_checked
   • monitor en .wait    → comprobación definitiva aquí
```

El flag `deadline_checked(Cat)` garantiza que los eventos `deadline_missed` se emiten exactamente una vez por fase, independientemente de qué mecanismo actúe primero.

### Semana 4 — Registro de errores de deadline en estadísticas (`supervisor.asl`)

**Objetivo**: cada contenedor que incumple su deadline queda registrado en el sistema de estadísticas del supervisor, igual que cualquier otro error de contenedor.

- **Creencia inicial**: añadido `errors_by_type(deadline_missed, 0)`. El reporte periódico (`!print_errors_by_type`) ya itera `errors_by_type`, por lo que `deadline_missed` aparece automáticamente en el resumen de estadísticas.

- **`+!report_deadline_missed`**: por cada contenedor incumplido, si no existe ya `error_occurred(CId, deadline_missed)`, se añade la creencia, se recalculan `total_errors` y las tasas derivadas (`!update_rates`). El guard `not error_occurred` previene doble conteo si el mismo contenedor aparece en ambas fases del ciclo.

El reporte periódico mostrará:
```
Errores por tipo:
  deadline_missed: N
  no_shelf_space: M
```

### Semana 4 — No interferencia: detección de deadlines aislada del sistema (`supervisor.asl`)

La detección y registro de incumplimientos de deadline cumple las tres propiedades de no interferencia por construcción:

| Propiedad | Garantía |
|---|---|
| **No detiene la ejecución** | El monitor corre como intención separada con `.wait(5000)`. Se añadieron handlers de fallo `-!monitor_deadline(_, _, _) : true <- true` para ambas variantes (urgent/non_urgent): si el cuerpo del monitor falla internamente (p.ej. `?delta_t(DT)` no encuentra la creencia, o `.findall` lanza excepción), Jason propagaría el fallo hacia `+active_deadline` que lo lanzó con `!monitor_deadline(...)`, pudiendo afectar la intención del supervisor. El handler absorbe el fallo silenciosamente. Idem `-!report_deadline_missed : true <- true`. |
| **No cancela tareas de robots** | El supervisor no envía ningún mensaje a los robots desde el código de deadline. No invoca `unclaim_container`, `release_task` ni ninguna acción que afecte al ciclo de trabajo de los robots. |
| **No modifica el entorno ni decisiones** | No se llama ninguna acción Java. Las creencias `error_occurred(CId, deadline_missed)` y `deadline_checked(Cat)` son internas al supervisor. Los robots no perciben ni reciben nada de esta lógica. |

Las propiedades son estructurales — no requieren validación en tiempo de ejecución porque no existe ningún mecanismo de interferencia en el código.

### Fix: Bug 3 — unclaim resetea posición solo cuando el robot llevaba el contenedor (`WarehouseArtifact.java`)

**Problema original**: `executeUnclaimContainer` no reseteaba la posición cuando el robot llevaba físicamente el contenedor al llamarse (p. ej., `path_blocked` en mitad de la navegación). El contenedor caía en la posición actual del robot (arbitraria dentro del almacén) y otro robot no podía recogerlo porque `pickup` verifica distancia.

**Solución**: `executeUnclaimContainer` resetea a una celda libre de entrada **únicamente si el robot llevaba el contenedor** (`wasCarrying`). Si el contenedor ya fue depositado intencionalmente en otro lugar (p. ej., zona de expansión vía `drop_in_expansion`), su posición se respeta — ese caso tiene su propia semántica correcta.

```java
boolean wasCarrying = false;
if (robot != null && robot.isCarrying()) {
    Container carried = robot.getCarriedContainer();
    if (carried != null && containerId.equals(carried.getId())) {
        robot.drop();
        carried.setPicked(false);
        wasCarrying = true;
    }
}

Container container = containers.get(containerId);
if (container == null || container.isBroken()) return true;

if (wasCarrying) {
    int[] cell = findFreeEntranceCell();
    container.setPosition(cell[0], cell[1]);
}
addPercept(...container_at_entrance...);
```

**Casos cubiertos**:
- Robot llevando el contenedor (path_blocked, execute_exit failure): drop + reset a entrada ✓
- Contenedor en expansión (safe_expand_drop + unclaim): posición de expansión respetada ✓
- Contenedor ya en entrada (pick_shelf failure sin pickup): posición respetada ✓

### Fix: `select_for_exit` usa `shelf_urgency` en lugar de `claimed_type` (4 robots)

**Problema**: `+!select_for_exit` filtraba contenedores candidatos usando `claimed_type(CId, "urgent")`, una creencia per-robot que solo existe en el robot que originalmente almacenó el contenedor. Si ese robot estaba ocupado, ningún otro robot podía sacar el contenedor durante el ciclo de salida, aunque estuviese idle.

**Solución**: sustituir `claimed_type(CId, "urgent")` por `shelf_urgency(ShelfId, urgent)` (y `claimed_type(...) & non_urgent_container_type(...)` por `shelf_urgency(ShelfId, non_urgent)`). `shelf_urgency` es una creencia estática en `common.asl` disponible para todos los robots. Ahora cualquier robot idle puede mover cualquier contenedor de la categoría correcta independientemente de quién lo almacenó:

```agentspeak
// Antes:
+!select_for_exit([pair(CId, ShelfId)|_], urgent) : claimed_type(CId, "urgent") & state(idle) <- ...

// Después:
+!select_for_exit([pair(CId, ShelfId)|_], urgent) : shelf_urgency(ShelfId, urgent) & state(idle) <- ...
```

### Fix: `delta_t` aumentado de 60 a 120 segundos (`common.asl`)

**Motivo**: con `delta_t(60)`, robots pesados (velocidad 1) que recogen un contenedor de una estantería lejana no tienen tiempo suficiente para llegar a outbound antes de que expire el deadline, especialmente con congestión de navegación. Un robot heavy desde shelf_9 (x≈18, y≈10) hasta outbound (x=0-2, y=0-1) necesita ~100 pasos con posibles backoffs → ~90-100 segundos reales.

**Justificación**: `delta_t(120)` da margen suficiente para el robot más lento en el peor caso de distancia. El enunciado especifica que ΔT es configurable y debe justificarse en la memoria.

### Fix: navegación a outbound bloqueada por zona de entrada (`common.asl`)

**Problema**: el layout del grid tiene el outbound en x=0-2, la clasificación/expansión en x=3-4, y la entrada en x=5-7, todas en y=0-1. Cuando un robot navegaba hacia outbound desde las estanterías (lado derecho), la ruta greedy cruzaba y=0-1 horizontalmente pasando por la zona de entrada (x=5-7) donde podían estar contenedores re-encolados. Si cuatro robots bloqueaban las cuatro celdas adyacentes al robot, éste quedaba atrapado indefinidamente.

**Solución final — regla de 3 pasos** en `common.asl`: garantiza que el robot **nunca entra en y=0-1 mientras está en x≥3** de camino a outbound. Solo aplica a outbound (TX<3); la expansión (x=3-4) se excluye deliberadamente para evitar congestión en y=2 cuando varios robots hacen expansion_drop simultáneamente.

```agentspeak
// Paso 1: subir a y=2 en la columna actual   → (X, 2)
// Paso 2: deslizarse a la columna destino    → (TX, 2)
// Paso 3: bajar al destino                  → (TX, TY)
+!navigate(TX, TY) : TX < 3 & TY < 2 & robot_pos(X, Y) & (X \== TX | Y \== 2) <-
    !navigate(X, 2);
    !navigate(TX, 2);
    !navigate(TX, TY).
```

La guarda `(X \== TX | Y \== 2)` detiene la recursión cuando el robot ya está en `(TX, 2)`.

Se añadieron dos reglas simétricas para salir de la zona izquierda (x<5, y<2):

```agentspeak
// Hacia el este con cualquier destino: subir a y=2 antes de cruzar x=5-7.
// Sin esta regla, el robot intentaba cruzar y=0-1 en x=5-7 (zona de entrada),
// bloqueado por contenedores re-encolados si el robot está en expansión (x=3-4).
+!navigate(TX, TY) : TX >= 5 & robot_pos(X, Y) & X < 5 & Y < 2 <-
    !navigate(X, 2);
    !navigate(TX, TY).
```

### Mejoras de documentación y calidad de código (`WarehouseArtifact.java`, todos los `.asl`)

Revisión completa de comentarios en todos los ficheros del proyecto:

- **Traducción**: todos los comentarios en inglés traducidos al castellano en `WarehouseArtifact.java` y en los cuatro robots (`robot_heavy`, `robot_heavy2`, `robot_medium`, `robot_light`), `common.asl`, `scheduler.asl` y `supervisor.asl`.

- **Comentarios explicativos añadidos** (solo donde el WHY no es obvio):
  - `WarehouseArtifact.java`: bloque `synchronized` en `executeMoveStep` (qué protege y por qué el check externo queda fuera), `setDaemon(true)` (terminación automática con JVM), `putIfAbsent` en `executeClaimContainer` (atomicidad frente a reclamaciones concurrentes), drop de seguridad en `executeReleaseTask` (sincronización Java cuando Jason ya reseteó `carrying`), sort por distancia en `executeMoveToExpansion` (minimizar trayecto), no re-emit en `executeDropInExpansion` (cadena de responsabilidad va por scheduler), `emitShelfAvailable` en `executePickupFromShelf` (restaurar disponibilidad tras retirada).
  - `common.asl`: `.wait(zone_granted)` — patrón Jason de suspensión por creencia sin polling; `!release_zone : true <- true` — idempotencia.
  - Robots (×4): `nav_limit` — contador anti-bucle infinito en navigate; `corridor_row` — marcado como legacy sin uso en ninguna regla actual.
  - `scheduler.asl`: conversión `DT*1000` a ms para `.wait`; semántica de `T1 = T0+DT` (fase no urgente arranca al terminar la urgente); ventana `2·ΔT` para la fase no urgente; `active_exit_cycle` — exclusión mutua entre ciclos.
  - `supervisor.asl`: mecanismo de cola del mutex de zona (concesión directa, encolado único, transferencia sin pasar por `zone_free`); `deadline_checked` — previene doble notificación entre monitor periódico y handler de retracción.

### Fix: Bug 6 (parcial) — desincronización Java-Jason durante ciclo de salida y expansion_drop (`common.asl`, 4 robots)

**Problema**: cuando `path_blocked` u otro error de navegación ocurría mientras un robot portaba un contenedor en dos contextos críticos, el handler reactivo genérico reseteaba `state(idle)` y `carrying(none)` en Jason sin acción Java correspondiente, causando:
- Durante `!execute_exit` (ciclo de salida): el robot quedaba físicamente portando el contenedor indefinidamente. La zona `outbound` nunca se liberaba, bloqueando a cualquier otro robot que esperase adquirirla.
- Durante `!safe_expand_drop`: misma desincronización pero con la zona `expansion`.

**Solución**: handlers contextuales que inhiben el reset de estado según el contexto activo, dejando que la jerarquía de planes gestione el fallo:

```agentspeak
// Durante ciclo de salida: no resetear — propaga a -!execute_exit : exit_picked
+error(path_blocked, Data) : exit_picked(_) <-
    .my_name(Me); .send(supervisor, tell, robot_error(Me, path_blocked, Data)).

// Durante expansion_drop: no resetear — propaga a -!safe_expand_drop
+error(path_blocked, Data) : holding_zone(expansion) <-
    .my_name(Me); .send(supervisor, tell, robot_error(Me, path_blocked, Data)).

// Caso general: reset normal
+error(path_blocked, Data) : true <-
    .my_name(Me);
    .send(supervisor, tell, robot_error(Me, path_blocked, Data));
    -+state(idle); -+carrying(none).
```

Aplica a `path_blocked`, `route_blocked`, `too_far` e `illegal_move` en los 4 robots.

`drop_at_outbound` añade límite de 3 reintentos: al agotarse propaga `.fail` a `!execute_exit`, cuyo handler de fallo (`exit_picked`) devuelve el contenedor a la estantería o llama `unclaim_container`.

### Fix: `check_queue` ignora contenedores bloqueados durante ciclo de salida (4 robots)

**Problema**: al terminar una tarea durante el ciclo de salida (`blocked_type(standard)` activo), `check_queue` detectaba contenedores en entrada que encajaban en capacidad pero estaban bloqueados. Decidía no volver a base (había trabajo "disponible"), pero luego `check_pending_containers` no podía reclamarlos. El robot quedaba parado en su posición actual hasta que el ciclo terminase.

**Solución**: añadir `not blocked_type(Type)` a la condición de `check_queue` en los 4 robots:

```agentspeak
if (container_at_entrance(_, Type, Weight, W, H) &
        not blocked_type(Type) &          // ← nuevo
        not (Weight > 10) & ...) {
    -+state(idle)
} else {
    -+state(returning); !navigate(InitX, InitY); -+state(idle)
}.
```

### Fix: restauración de tracking de errores de robot (`supervisor.asl`, 4 robots, `WarehouseArtifact.java`)

**Problema**: el refactor a pull-protocol (`ba48854`) eliminó el handler `+robot_error[source(Robot)]` del supervisor que populaba `navigation_error_occurred`, dejando las queries (`.findall`, `.count`) como código muerto. Adicionalmente, los handlers para `not_carrying`, `invalid_pickup`, `invalid_drop` y `robot_not_found` en los robots no enviaban al supervisor, y Java no emitía `robot_not_found`.

**Solución**:
- **Supervisor**: handler `+robot_error(Robot, ErrorType, Data)[source(_)]` que añade `navigation_error_occurred` y recalcula `total_errors` combinando errores de contenedor y de robot. Sección de impresión `!print_nav_error_list` restaurada en el reporte periódico.
- **4 robots**: handlers específicos para `robot_not_found`, `not_carrying`, `invalid_pickup` e `invalid_drop` que envían `robot_error` al supervisor antes de resetear estado.
- **Java**: `addError(agName, "robot_not_found", agName)` en `executeMoveStep` y `executePickup` cuando `robots.get(agName)` devuelve null.

El reporte periódico ahora diferencia errores de contenedor (p.ej. `no_shelf_space`) de errores de robot (p.ej. `path_blocked (robot): N`).

### Fix: posiciones base de robots desplazadas a y=4 (`WarehouseArtifact.java`, 4 robots)

**Problema**: las bases de los 4 robots estaban en y=3 (1,3), (2,3), (3,3), (4,3). El corredor y=3 es la ruta principal de regreso a base. Con robots idle aparcados en ese corredor, los demás robots navegando de vuelta al home lo encontraban bloqueado, lo que causaba que `step_with_retry` agotase sus intentos, `check_queue` fallase y el robot quedase parado lejos de su base.

**Solución**: desplazar todas las bases a y=4: (1,4), (2,4), (3,4), (4,4). y=4 es un corredor libre entre las estanterías pequeñas (y=2-3) y las medianas (y=6-7), sin conflicto con ninguna ruta de navegación.

### Fix: navegación a outbound bloqueada por celdas SHELF en columnas de estanterías (`common.asl`)

**Problema**: la regla de 3 pasos para X≥9 usaba `!navigate(9,2)` como primer paso desde cualquier posición. Cuando el robot estaba en, por ejemplo, (10,9) —adyacente a shelf_8— `step_with_retry` priorizaba la dirección Y (más larga), intentaba subir por X=10. Las celdas (10,2) y (10,3) son SHELF → bloqueado → path_backoff enviaba el robot hacia abajo → bucle vertical arriba-abajo sin llegar nunca a outbound.

**Solución**: regla de 4 pasos que garantiza entrada limpia al corredor x=9 antes de ascender:

```agentspeak
+!navigate(TX, TY) : TX < 3 & TY < 2 & robot_pos(X, Y) & X >= 9 <-
    !navigate(9, Y);   // paso horizontal puro al corredor x=9 (sin estanterías)
    !navigate(9, 2);   // sube por x=9 (siempre libre)
    !navigate(TX, 2);  // desliza a la columna destino por y=2
    !navigate(TX, TY). // baja al outbound
```

### Fix: `move_to_outbound` llena y=0 primero para no bloquear el acceso (`WarehouseArtifact.java`)

**Problema inicial**: con la navegación de 4 pasos el robot llegaba siempre por y=2, por lo que y=1 era el primer paso natural. Se invirtió el comparador para preferir y=1 (`Integer.compare(b[1], a[1])`), evitando el paso extra hacia y=0.

**Problema derivado**: al llenarse y=1 primero, las celdas de y=0 quedaban inaccesibles físicamente — los containers en y=1 bloqueaban el único camino desde y=2 hacia y=0. El outbound efectivo pasaba de 6 a 3 celdas útiles.

**Solución**: revertir a preferir y=0 primero (`Integer.compare(a[1], b[1])`). El fondo se llena antes y y=1 queda libre como pasillo de acceso. El bucle arriba-abajo en reintento ya no ocurre gracias al guard `Y>=2` añadido en la regla de navegación para X<9 (ver entrada siguiente).

### Fix: guard `Y>=2` en regla navigate para X<9 hacia outbound (`common.asl`)

**Problema**: al reintentar `drop_at_outbound` desde una posición ya en outbound (y=0 o y=1), la regla de 3 pasos para X<9 disparaba igualmente porque solo comprobaba `TX<3 & TY<2 & X<9`. El robot subía innecesariamente a y=2 antes de volver a bajar — bucle arriba-abajo visible en logs como movimientos repetidos en la misma columna.

**Solución**: añadir guard `Y>=2` a la regla para que solo dispare cuando el robot se aproxima desde arriba del corredor, no cuando ya está dentro del outbound:

```agentspeak
+!navigate(TX, TY) : TX < 3 & TY < 2 & robot_pos(X, Y) & X < 9 & Y >= 2 & (X \== TX | Y \== 2) <-
    !navigate(X, 2);
    !navigate(TX, 2);
    !navigate(TX, TY).
```

Cuando el robot está en y=0 o y=1 (Y<2), la regla no dispara y `step_with_retry` lleva directamente al destino sin subir.

### Fix: `shelf_wait` se borraba prematuramente al reclamar otro robot (`common.asl`)

**Problema**: existía la regla:

```agentspeak
-container_at_entrance(CId,_,_,_,_) : shelf_wait(CId) <- -shelf_wait(CId).
```

Esta regla disparaba cuando **cualquier** robot reclamaba el container (retractando `container_at_entrance`), borrando el cooldown del robot que lo había soltado. El robot sin cooldown volvía a reclamar el mismo container inmediatamente, sin estantería disponible, entrando en un ciclo infinito de fallo-reclamación-fallo.

**Solución**: eliminar esa regla completamente. El cooldown expira únicamente por tiempo (`.wait(20000)`), independientemente de qué robot reclame el container.

### Fix: doble-cleanup en `pick_shelf` / `select_shelf_and_execute` (`common.asl`)

**Problema**: cuando `!pick_shelf` agotaba 3 reintentos, su handler de fallo hacía el cleanup completo (unclaim, release, check_queue) pero no llamaba `.fail`. Esto hacía que `?shelf_selected` fallase en `!select_shelf_and_execute`, que también ejecutaba su propio handler de fallo con el mismo cleanup. Resultado: `unclaim_container` y `release_task` llamados dos veces, el mensaje "Container re-queued" aparecía duplicado.

**Solución**: el handler N≥3 de `pick_shelf` solo notifica al supervisor, activa `shelf_wait` y llama `.fail`. Todo el cleanup (unclaim, release, check_queue) queda consolidado únicamente en `-!select_shelf_and_execute`.

### Fix: `pick_shelf` reducido a 1 reintento con 3s de espera (`common.asl`)

**Problema**: los 3 reintentos con 5s de espera (~15s total) retrasaban la detección de saturación y bloqueaban la celda de entrada durante ese tiempo. Sin reintentos (fallo inmediato), múltiples robots fallaban simultáneamente antes de que `blocked_type` se propagase, congestionando la zona inbound con containers re-encolados y causando Bug 6 cuando un robot portando un container no podía salir de la zona.

**Solución**: 1 reintento con 3s de espera. Durante esos 3s el robot retiene el container (no lo devuelve a la entrada), evitando la congestión. `blocked_type` llega en <1s, así que el reintento ya lo ve activo. El ciclo de salida empieza como máximo 3s después del primer fallo. `shelf_wait` reducido de 20s a 5s — margen suficiente para que `blocked_type` se propague antes de que `container_at_entrance` re-dispare el claim.

### Fix: `exit_cycle` solo elimina el ciclo completado, re-dispara pendientes (`scheduler.asl`)

**Problema**: `.abolish(exit_cycle(_, _))` borraba TODOS los ciclos de salida al terminar el primero. Si dos tipos saturaban simultáneamente, el segundo ciclo se perdía aunque `blocked_type` seguía activo para ese tipo.

**Solución**: `-exit_cycle(Type, T0)` elimina solo el ciclo completado. Al terminar, `.findall` recoge los ciclos pendientes de otros tipos y los re-dispara con `-exit_cycle(PT, PT0); +exit_cycle(PT, PT0)` para que `+exit_cycle` vuelva a activarse.

### Fix: `shelf_available` desbloquea correctamente el tipo saturado (`scheduler.asl`)

**Problema**: el plan `+shelf_available(ShelfId) : blocked_type(Type) & shelf_for(Type, _, ShelfId)` nunca disparaba. `shelf_for` usa átomos (`urgent`/`non_urgent`) pero `blocked_type` usa strings de tipo de contenedor (`"standard"`, `"fragile"`). La unificación `blocked_type(Type) & shelf_for(Type, _, ShelfId)` fallaba silenciosamente — el desbloqueo automático al liberar espacio nunca funcionaba.

**Solución**: separar en dos planes usando `urgent_container_type`/`non_urgent_container_type` de `common.asl` para el mapeo correcto entre átomos de urgencia y strings de tipo. Añadido `untell blocked_type` a todos los robots al desbloquear (el scheduler había enviado `tell` a todos al inicio del ciclo).

### Fix: `run_exit_cycle` ejecuta solo la fase relevante al tipo saturado (`scheduler.asl`)

**Problema**: el ciclo siempre ejecutaba ambas fases (urgente ΔT + non_urgent 2·ΔT) independientemente del tipo que saturó. Cuando saturaba `standard` (estanterías non_urgent), la fase urgente evacuaba estanterías urgent (zona diferente), sin liberar espacio para standard. Los robots heavy quedaban idle durante ΔT=120s sin nada que evacuar.

**Solución**: dos planes `!run_exit_cycle` separados por contexto:
- `urgent_container_type(Type)` → solo fase urgente (ΔT)
- `non_urgent_container_type(Type)` → solo fase non_urgent (2·ΔT) directamente

Los robots pesados empiezan a evacuar shelf_9 inmediatamente cuando standard satura, sin esperar 120s.

### Fix: `move_to_outbound` excluye celdas ocupadas por robots (`WarehouseArtifact.java`)

**Problema**: `move_to_outbound` seleccionaba celdas outbound libres de containers (`!hayContenedorEn`) pero no comprobaba si había un robot parado en esa celda. Un robot idle en outbound tras entregar su container bloqueaba la celda físicamente. Otro robot navegaba hacia esa celda como target, fallaba `drop_in_outbound`, y el handler genérico reseteaba `state(idle)` + `carrying(none)` en Jason mientras Java seguía viendo al robot portando el container → Bug 6 desync.

**Solución**: añadir `!hayRobotCerca(x, y)` a la condición de selección de celda. El método ya existía en el código. Una línea cambiada.
