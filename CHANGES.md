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

---

## Robots: selección autónoma de contenedores en ciclo de salida

### Motivación

Durante el ciclo de salida los robots no reciben asignaciones del scheduler. Deben consultar qué deadline está activo, filtrar sus contenedores almacenados por el tipo correspondiente, y delegar el transporte al agente Transport de forma autónoma.

### Diseño de la selección autónoma

**Cuándo se ejecuta**: en cada iteración de `work_cycle` cuando el robot está `idle`, antes del `.wait`. El robot consulta el scheduler, hace la selección si hay deadline activo, y luego sigue esperando. Si no hay deadline el ciclo es un no-op.

**Criterio de selección**: orden de almacenamiento (FIFO sobre `stored/2`). El robot usa `.findall` sobre su propia BB para construir la lista `[pair(CId, ShelfId), ...]` de contenedores que almacenó y aún no ha reclamado para salida. Recorre la lista y elige el primer candidato cuyo tipo coincide con el deadline activo.

**Respeto de capacidades**: `stored(CId, ShelfId)` solo contiene contenedores que el propio robot transportó originalmente, es decir, aquellos que ya cumplían sus límites de peso y tamaño. No se necesita revalidación.

### Flujo por deadline

```agentspeak
+!check_exit_cycle : true <-
    .send(scheduler, askOne, active_deadline(_, Category, _), active_deadline(_, Category, _));
    .findall(pair(CId, ShelfId), (stored(CId, ShelfId) & not exit_claimed(CId)), Candidates);
    !select_for_exit(Candidates, Category).

-!check_exit_cycle : true <- true.   // sin deadline activo
```

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

### Cambios en `+!select_for_exit` (los tres robots)

Antes del `.send(transport, tell, exit_transport(CId, ShelfId))` se añaden tres líneas en cada plan:

```agentspeak
.time(Hd, Md, Sd);
Td = Hd * 3600 + Md * 60 + Sd;
.print("EVENT | time=", Td, " | agent=", Me, " | type=container_delivered | data=", CId);
```

### Resumen de cambios

| Archivo | Cambio |
|---|---|
| `robot_light.asl` | `+!select_for_exit/urgent` y `+!select_for_exit/non_urgent`: 3 líneas de log EVENT añadidas antes del `.send(transport, ...)` |
| `robot_medium.asl` | Ídem |
| `robot_heavy.asl` | Ídem |

---

## Verificación manual — Objetivos de la semana

Se ejecutó el sistema durante ~2 minutos con `delta_t(30)`. La sesión terminó antes de saturar ningún tipo (ciclo de salida no activado), pero todos los objetivos fueron verificados estáticamente en código.

| # | Objetivo | Estado | Evidencia |
|---|---|---|---|
| 1 | Activar ciclo de salida al saturar tipo y definir T0 | ✅ Implementado | `+storage_full(Type,_)[source(supervisor)]` añade `exit_cycle(Type,T0)` — `scheduler.asl` sección 7 |
| 2a | Deadline corto para urgentes (`T0 + ΔT`) | ✅ Implementado | `+active_deadline(short, urgent, T0)` + `.wait(DT*1000)` — sección 8 |
| 2b | Deadline largo para no urgentes (`T0 + 3·ΔT`) | ✅ Implementado | `+active_deadline(long, non_urgent, T1)` + `.wait(DT*2*1000)` |
| 2c | ΔT configurable y justificado | ✅ Implementado | `delta_t(30)` en `common.asl` |
| 3 | Solo un deadline activo en cada instante | ✅ Garantizado | `.wait()` bloqueante: `active_deadline(long,...)` no se añade hasta retirar `active_deadline(short,...)` |
| 4a-4c | Robots autónomos en ciclo salida | ✅ Implementado | FIFO sobre `stored/2` local; `exit_claimed` evita duplicados; sin asignación explícita |
| LOG-1 | `EVENT deadline_started` | ✅ Implementado | Emitido en `+!run_exit_cycle` |
| LOG-2 | `EVENT deadline_ended` | ✅ Implementado | Emitido tras cada `.wait()` |
| LOG-3 | `EVENT container_delivered` | ✅ Implementado | Emitido en `+!select_for_exit` de los tres robots |

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

### Fix: Bug 3 — unclaim resetea posición siempre (`WarehouseArtifact.java`)

**Problema**: `executeUnclaimContainer` solo reseteaba la posición del contenedor a la zona de entrada cuando el robot lo llevaba físicamente. Si el contenedor había sido soltado previamente en otro lugar (p. ej., zona de expansión tras `safe_expand_drop` + `unclaim_container`), el percept `container_at_entrance` se emitía pero el contenedor quedaba en la posición incorrecta. Aunque `move_to_container` navega a la posición real del contenedor (evitando fallos de `pickup`), la zona mutex `inbound` se adquiría indebidamente y la semántica del percept era incorrecta.

**Solución**: `findFreeEntranceCell()` se llama **siempre** justo antes de emitir el percept, independientemente de si el robot llevaba el contenedor:

```java
// Drop si el robot lo lleva físicamente
Robot robot = robots.get(agName);
if (robot != null && robot.isCarrying()) {
    Container carried = robot.getCarriedContainer();
    if (carried != null && containerId.equals(carried.getId())) {
        robot.drop();
        carried.setPicked(false);
    }
}

Container container = containers.get(containerId);
if (container == null || container.isBroken()) return true;

// Siempre: resetear a entrada antes de emitir el percept
int[] cell = findFreeEntranceCell();
container.setPosition(cell[0], cell[1]);

addPercept(...container_at_entrance...);
```

**Casos cubiertos**:
- Robot llevando el contenedor (path_blocked, execute_exit): drop + reset ✓
- Contenedor en expansión (safe_expand_drop + unclaim): solo reset ✓
- Contenedor ya en entrada (pick_shelf failure sin pickup): reset idempotente ✓
