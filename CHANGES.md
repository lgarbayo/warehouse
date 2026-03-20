# Resumen de Cambios y Progreso: Warehouse MAS

## 1. Problemas Identificados y Arreglados

*   **Fallo del Scheduler al Encontrar Estanterías:**
    *   **Problema:** Cuando el almacén se llenaba, el método Java `get_free_shelf` devolvía `false`, provocando que la intención `+container_info` del `scheduler.asl` fallara irrevocablemente. Los contenedores se "perdían" y nunca se asignaban.
    *   **Solución:** Se envolvió el método en un sub-goal en Jason (`!assign_shelf(CId)`). Esto permite capturar el error limpiamente (`-!assign_shelf`) y esperar 5 segundos antes de reintentarlo, creando una cola de espera funcional.
*   **"Flickering" del Robot Pesado (Destination Conflict Loop):**
    *   **Problema:** Tras depositar un contenedor, el sistema intentaba liberar la celda ocupada por el robot en `activeDestinations`. Sin embargo, usaba el nombre del robot (`agName`) como clave de borrado, cuando el mapa usaba las coordenadas (`destKey`). Las celdas quedaban permanentemente bloqueadas.
    *   **Solución:** Se corrigió el bloque `finally` en `WarehouseArtifact.java` para llamar a `activeDestinations.remove(destKey)`, liberando la celda correctamente y evitando el ciclo infinito de recalculos fallidos del `robot_heavy`.
*   **Posiciones de Caída Equivocadas (Corners):**
    *   **Problema:** Para evitar colisiones en versiones anteriores, los robots light y medium usaban offsets diagonales extraños (`SX+1`, `SX+2`), provocando que depositaran la carga fuera de la vista de las estanterías pequeñas.
    *   **Solución:** Al implementar lógicamente que los robots vayan a estanterías según su tamaño, se eliminó la probabilidad de que vayan a la misma simultáneamente. Se unificó a todos los robots (`robot_light.asl`, `robot_medium.asl` y `robot_heavy.asl`) para que se acerquen directamente al frente de la estantería: `(SX, SY-1)`.
*   **Asignación Inteligente de Estanterías:**
    *   **Problema:** El entorno asignaba ciegamente la estantería de menor % ocupado a cualquier carga, mandando paquetes enanos a estanterías industriales.
    *   **Solución:** Se reescribió `findBestShelf` en `WarehouseArtifact.java` para priorizar por tamaño/robot:
        *   Cargas Ligeras -> Estanterías 1-4
        *   Cargas Medianas -> Estanterías 5-7
        *   Cargas Pesadas -> Estanterías 8-9

## 2. Ficheros Modificados

1.  `src/env/warehouse/WarehouseArtifact.java`:
    *   `findBestShelf(Container container)`: Implementación de la asignación por tiers.
    *   `move_to(...)`: Corrección de `activeDestinations.remove(destKey);` en `finally`.
    *   `move_to(...)`: Limpieza explícita del mapa cuando falla la ruta alternativa (`path_blocked`).
2.  `src/agt/scheduler.asl`:
    *   Creación de sub-goal `!assign_shelf` y plan de fallback `-!assign_shelf` para espera y reintento con estanterías llenas.
3.  `src/agt/robot_heavy.asl`: `!navigate_to_shelf` ajustado a `(SX, SY-1)`.
4.  `src/agt/robot_medium.asl`: `!navigate_to_shelf` ajustado a `(SX, SY-1)`.
5.  `src/agt/robot_light.asl`: `!navigate_to_shelf` ajustado a `(SX, SY-1)`.

## 3. Posibles Problemas Futuros a Intervenir ("To-Do")

*   **Pico de Tráfico en Áreas Comunes:** Ahora que todos comparten `(SX, SY-1)` si dos robots del mismo tipo coinciden exactamente yendo a estanterías contiguas o a la misma celda de entrada, **podría** darse un conflicto temporal (el A* y `avoidRobots=true` debería mitigarlo, pero es punto de fallo).
*   **Manejo de Errores Visuales:** Si un paquete queda bloqueado perpetuamente (por bugs de Jason) el GUI no muestra un indicador claro de que un paquete fue descartado.
*   **Priorización del Scheduler:** Ahora usa una espera lineal `Wait(5000)`. Para optimización extrema, el scheduler podría almacenar solicitudes y ordenarlas por urgencia (ej: "urgent" primero) antes de rebuscar sitio cada 5s en lote.
*   **Starvation en Fallback:** En el fallback de Java (buscar cualquier estante si la preferida está llena), podríamos acabar enviando cargas pesadas a huecos muy pequeños repartidos en mútliples huecos de `shelf_1`. El método `canStore` valida que quepa el bulto, pero el diseño general de picking sufre.

---
## 4. Segunda Ronda de Parches (Pick-ups)

*   **Problema de Solapamiento (Robots "Tweaking"):**
    *   **Problema:** Los robots se dirigían exactamente a `(1,1)` (o `(2,1)` en el pesado) para recoger los contenedores. Como el contenedor spawnea siempre en `(1,1)`, el robot físicamente *se subía encima* del contenedor antes de recogerlo. Esto causa un fallo visual en el renderizado (z-index) haciendo que el sprite del robot parpadee ('tweaking') con el sprite del contenedor.
    *   **Solución:** La regla de Java `executePickup` permite recoger un contenedor si la distancia es `<= 1`. Hemos separado los puntos de espera y recogida para que los robots aparquen *al lado* del contenedor, en lugar de encima:
        *   `robot_light` ahora va a `(1,0)` (justo arriba del paquete).
        *   `robot_medium` ahora va a `(0,1)` (justo a la izquierda del paquete).
        *   `robot_heavy` ahora va a `(1,0)` (arriba del paquete ancho 2xN).
    *   Esto garantiza un movimiento limpio donde los robots se sitúan en las esquinas del punto de spawn de cajas y las agarran desde ahí, haciendo la simulación mucho más placentera visualmente.

---
## 5. Tercera Ronda de Parches (Pila de Intenciones, Duplicación de Tareas y Cuellos de Botella de Arquitectura)

*   **Problema de Duplicación (Race Conditions de Tareas):**
    *   **Problema:** El entorno visual en Java tenía un método nativo de *pull* (`request_task`) que los robots invocaban cada 3 segundos si estaban en estado `idle`. Sin embargo, el **planificador oficial** (`scheduler.asl`) actuaba como sistema *push* puro que distribuía mensajes de tarea independientemente (`.send(robot, tell, task(CId, ShelfId))`). 
    En momentos de alta carga o cuando un Action en Java devolvía `error(...)` devolviendo el agente a `idle`, un robot podía llegar a recibir hasta 3 copias y tareas completamente distintas simultáneas, encimando las Phases (Fase 1, 2, 3) y comportándose de manera totalmente ilógica.
    *   **Solución:** 
        1. Se borró la apelación a `request_task` desde el ciclo base de los ASL de todos los robots. Ahora los robots son puramente reactivos y **solo reciben instrucciones vía mensajes** de `scheduler.asl`.
        2. Se introdujo una **cola o buffer ASL** en los robots. En lugar de negarse a aceptar órdenes cuando están `ocupados` (y perdiendo el paquete en el limbo infinito), los robots guardan y procesan tareas pendientes de manera FIFO la próxima vez que entren en estado `idle`: `+state(idle) : task(CId, ShelfId) <- !execute_task(...)`.
        3. Para los fallos graves como `path_blocked`, ahora el robot reporta transparentemente y delega de nuevo al scheduler el encargo usando `.send(scheduler, tell, task_failed(CId))`, reiniciando el ciclo y previniendo que muera desatendido en el entorno de Java sin que el ASL se entere.

---
# CAMBIOS EN SUPERVISOR
## 6. Cuarta ronda -> Supervisor monitoriza estadísticas de contenedores:
**Qué se hizo**
*supervisor.asl* — 3 planes nuevos:

Plan || Qué hace
+new_container(CId)	|| Percibe directamente del entorno (ya era global), incrementa total_received
+container_stored(CId, ShelfId)[source(Robot)] || Recibe mensaje del robot, incrementa total_stored
+container_error(CId, ErrorType)[source(Robot)] ||	Recibe mensaje del robot, incrementa total_errors y errors_by_type

*robots (light, medium, heavy)* — en cada robot:

+stored(...) → añade .send(supervisor, tell, container_stored(CId, ShelfId))
+error(container_too_heavy/big, ...) → añade .send(supervisor, tell, container_error(CId, ErrorType))
+error(ErrorType, ...) : carrying(CId) → nuevo plan genérico que también notifica al supervisor

**Por qué .send en vez de percepciones directas**
*stored* y *error* los añade el entorno Java solo al robot que actúa. El supervisor no los recibe de otra manera. new_container sí es global, por eso el supervisor lo percibe directamente sin necesidad de mensajes.

Para que el supervisor reciba stored y error como percepciones directas, habría que tocar el Java — concretamente WarehouseArtifact.java.

En lugar de:


addPercept(agName, Literal.parseLiteral("stored(...)"));  // solo al robot
Se haría:


addPercept(agName, Literal.parseLiteral("stored(...)"));          // al robot
addPercept("supervisor", Literal.parseLiteral("stored(...)"));    // también al supervisor
O con un broadcast a todos:


addPercept(Literal.parseLiteral("stored(...)"));  // sin agName = todos los agentes
Y en el supervisor el plan sería igual pero sin [source(Robot)], porque no es un mensaje sino una percepción del entorno:


+stored(CId, ShelfId) : total_stored(N) <-
    .print("[SUPERVISOR] Almacenado: ", CId, " en ", ShelfId);
    -+total_stored(N + 1).

**¿Por qué no lo hicimos así?**

                 || .send (lo que hicimos) || Percepción directa (Java)
Cambios necesarios || Solo .asl	|| Java + recompilar
El robot sabe quién almacenó || Sí, via [source(Robot)]	|| No, a menos que lo metas en el literal
Acoplamiento || Bajo — el robot decide notificar || Alto — el entorno lo fuerza siempre
Pureza del modelo MAS || Los agentes se comunican entre sí || El entorno habla directamente al supervisor

En general, el enfoque con .send es más limpio para un sistema multiagente: es el robot quien decide informar al supervisor, lo que respeta mejor la autonomía de los agentes.

---
## 7. Quinta ronda -> Cálculo de estadísticas y reporte:
**Qué hace**
Ciclo periódico — !stats_loop espera 30 segundos y lanza !print_stats, en bucle infinito.

!print_stats — calcula en el momento de imprimir:

Tasa de éxito: (almacenados / recibidos) * 100
Tasa de error: (errores / recibidos) * 100
Pendientes: recibidos - almacenados - errores
!print_errors_by_type — usa .findall para recoger todos los pares tipo-contador y los imprime, saltando los que estén a 0.

La salida cada 30s se verá así:

========================================
[SUPERVISOR] === REPORTE DE ESTADISTICAS ===
  Contenedores recibidos : 5
  Contenedores almacenados: 4 (80%)
  Contenedores con error  : 1 (20%)
  Pendientes en proceso   : 0
  --- Errores por tipo ---
    container_too_heavy: 1
========================================

El intervalo está en la creencia report_interval(30000), fácil de cambiar si quieres reportes más frecuentes durante las pruebas.

---
## 8. Sexta ronda -> Refactorización del supervisor: .count() y corrección de sintaxis ArithSpeak

**Problema**

El supervisor fallaba al parsear con el error:
`error parsing "file:src/agt/supervisor.asl": Encountered "<ATOM> "is"" at line X, column 17`

Esto hacía que el agente supervisor no cargara en absoluto en el sistema, y los robots reportaban `Receiver 'supervisor' does not exist!`.

**Causa raíz: dos errores de sintaxis Jason 3.3.0**

1. **`is` no es un operador válido en cuerpos de planes en Jason 3.3.0.**
   En Prolog estándar, `X is Expr` evalúa la expresión aritmética. En Jason 3.3.0, el operador correcto en cuerpos de planes es `=`. El lexer de Jason tokeniza `is` como un átomo genérico, no como un operador reservado, de ahí el error de parse. Ningún otro fichero `.asl` del proyecto ni de los ejemplos oficiales de Jason 3.3.0 usa `is` — todos usan `=`.

   ```jason
   // Incorrecto en Jason 3.3.0:
   SuccessRate is (Stored * 100) / Received;

   // Correcto:
   SuccessRate = (Stored * 100) / Received;
   ```

2. **`.count(Pattern, Var)` (forma de dos argumentos) — workaround inicial.**
   En el momento de aplicar este fix no se pudo confirmar si la forma de dos argumentos funcionaba en cuerpos de planes en Jason 3.3.0. Como solución segura se usó la forma aritmética de un argumento. Esta decisión fue posteriormente revisada (ver sección 16).

   ```jason
   // Workaround usado inicialmente:
   Received = .count(container_received(_));
   ```

**Refactorización asociada: abandono de contadores manuales**

Aprovechando la corrección, se refactorizó la lógica de conteo para eliminar los contadores manuales (`-+total_received(N1)`, etc.) — propensos a condiciones de carrera si múltiples eventos llegan seguidos. En su lugar, cada evento añade un hecho individual a la base de creencias del supervisor:

- `+container_received(CId)` — al percibir `new_container`
- `+container_stored_fact(CId, ShelfId)` — al recibir notificación del robot
- `+error_occurred(CId, ErrorType)` — al recibir notificación de error

Los totales se calculan en el momento del reporte con `.count(Pattern)`, sin estado intermedio que mantener. Las creencias iniciales del profesor (`total_received(0)`, `errors_by_type(T, 0)`, etc.) se mantienen intactas; `errors_by_type` se reutiliza como registro de tipos conocidos para iterar en el reporte.

---
## 9. Séptima ronda -> Supervisor monitoriza el estado de los robots

**Qué se hizo**

Se implementó el objetivo semanal "Supervisor monitors the status of the robots". El supervisor ahora conoce en tiempo real si cada robot está `idle` o `working`, e incluye ese estado en el reporte periódico.

**Robots** (`robot_light.asl`, `robot_medium.asl`, `robot_heavy.asl`) — mismo bloque añadido al final de los tres:

```jason
+state(working) : true <-
    .my_name(Me);
    .send(supervisor, tell, robot_state_change(Me, working)).

+state(idle) : not task(_, _) <-
    .my_name(Me);
    .send(supervisor, tell, robot_state_change(Me, idle)).
```

Los contextos son mutuamente excluyentes con el plan existente `+state(idle) : task(CId, ShelfId) <- ...` (que gestiona la cola de tareas pendientes), por lo que no hay conflicto. Cuando hay tarea encolada, ese plan tiene prioridad y lleva al robot a `working` inmediatamente, lo que dispara el plan `+state(working)` → supervisor recibe la notificación igualmente.

**Supervisor** (`supervisor.asl`):

| Añadido | Qué hace |
|---|---|
| Creencias iniciales `robot_status(robot_X, idle)` | Estado inicial conocido de los tres robots |
| `+robot_state_change(Robot, Status)[source(Robot)]` | Actualiza `robot_status` y printea el cambio en tiempo real |
| `!print_robot_status` + `!print_robot_list` | Imprime el estado de todos los robots en el reporte periódico |

El reporte periódico (`!print_stats`) ahora incluye una sección de robots tanto cuando hay contenedores recibidos como cuando no los hay todavía.

**Por qué planes evento-disparados en vez de añadir `.send` en cada `-+state`**

Añadir `.send` en cada transición de estado habría requerido tocar 6-8 puntos por robot (cada handler de error, el plan de fallo `-!execute_task`, la tarea completada, etc.). Con los planes `+state(X)`, Jason los dispara automáticamente cada vez que se añade la creencia `state(X)` — incluyendo cuando lo hace `-+state(X)`. Un solo punto de integración por estado relevante.

---
## 10. Octava ronda -> Fix: robots notifican stored/error directamente al supervisor

**Problema**

El scheduler reenviaba `container_stored` y `container_error` al supervisor perdiendo el robot original. El supervisor imprimía `almacenado por scheduler` en vez del robot real.

**Solución**

Los robots envían a **ambos** directamente:

```jason
.send(scheduler, tell, container_stored(CId, ShelfId));   // trazabilidad
.send(supervisor, tell, container_stored(CId, ShelfId));  // monitorización
```

El scheduler mantiene su lógica de trazabilidad (`-assigned`) pero ya no reenvía al supervisor. El supervisor recibe `[source(robot_X)]` directamente y muestra el nombre correcto en los logs.

**Ficheros modificados**

- `robot_light.asl`, `robot_medium.asl`, `robot_heavy.asl`: añadido `.send(supervisor, ...)` en `+stored` y todos los handlers `+error(...) : carrying(CId)`
- `scheduler.asl`: eliminados `.send(supervisor, tell, container_stored(...))` y `.send(supervisor, tell, container_error(...))`

---
## 11. Novena ronda -> Fix: robots notifican estado directamente al supervisor

**Problema**

El commit `771e583` (Vincenzo) redirigió las notificaciones `robot_state_change` de los robots al scheduler en vez de al supervisor, convirtiéndolo en proxy. Esto rompió silenciosamente el plan del supervisor:

```jason
// supervisor esperaba [source(robot_light)], pero llegaba [source(scheduler)]
+robot_state_change(Robot, Status)[source(Robot)] : true <- ...
// Robot=robot_light (del argumento) ≠ Robot=scheduler (del source) → nunca disparaba
```

El supervisor nunca actualizaba `robot_status` ni imprimía cambios de estado.

**Solución**

Dos cambios:

1. Los tres robots vuelven a notificar directamente al supervisor:
   ```jason
   .send(supervisor, tell, robot_state_change(Me, working)).
   ```

2. El plan del supervisor usa `[source(_)]` para aceptar cualquier origen:
   ```jason
   +robot_state_change(Robot, Status)[source(_)] : true <- ...
   ```

3. Se elimina el plan intermediario del scheduler (`+robot_state_change` que reenviaba al supervisor) — era innecesario ya que la trazabilidad del scheduler se gestiona por `assigned(Robot, CId, ShelfId)`, no por el estado de los robots.

**Ficheros modificados**

- `src/agt/robot_light.asl`, `robot_medium.asl`, `robot_heavy.asl`: `.send` apunta a `supervisor`
- `src/agt/scheduler.asl`: eliminado plan `+robot_state_change`
- `src/agt/supervisor.asl`: `[source(Robot)]` → `[source(_)]`
---
## 11. Novena ronda -> Mejoras de movimiento, trazabilidad y estabilidad (commit Vincenzo)

### Mejoras de Movimiento, Estabilidad y Recuperación
-   **Fin del "Tweaking" y Bucles**: Consumo inmediato de creencias de tareas y pausas de seguridad (1.5s-2s) en planes de fallo para estabilizar el MAS.
-   **Recogida Dinámica**: Eliminados los puntos de recogida fijos. Los robots consultan la posición real del contenedor via `get_container_info` y navegan a una celda adyacente válida con comprobación de límites del mapa.
-   **Recuperación por Estantería Llena**: Si una estantería se llena durante el transporte, el robot suelta el contenedor en su posición actual, resetea su estado en Java y notifica al scheduler para re-encolado dinámico.
-   **Evasión de Contenedores Grandes**: Nueva función `hayContenedorEn` en Java para que el A* esquive el área total (width x height) de los bultos grandes en el suelo.

**Trazabilidad de Tareas (`scheduler.asl`)**
- Sistema de creencias dinámicas `assigned(Robot, CId, ShelfId)` en el scheduler.
- Se crean al asignar y se eliminan al confirmar almacenamiento, error o fallo de plan.

**Nota**: este commit redirigió las notificaciones `robot_state_change` al scheduler como proxy, lo que introdujo un bug (ver sección 10). Corregido en el commit siguiente.

---
## 12. Décima ronda -> Refactorización de asignación con elif y trazabilidad de historial de tareas

**Qué se hizo**

Se simplificó la lógica de asignación de robots en `scheduler.asl` y se añadió un sistema de historial permanente de tareas para facilitar el debug y la trazabilidad.

**Problema de legibilidad**

La lógica de asignación usaba `if` anidados, haciendo el código más difícil de leer y mantener:

```jason
// Antes: if anidado
if (Weight <= 10 & W <= 1 & H <= 1) {
    .send(robot_light, ...);
} else {
    if (Weight <= 30 & W <= 1 & H <= 2) {
        .send(robot_medium, ...);
    } else {
        .send(robot_heavy, ...);
    }
}.
```

**Solución: `elif` y aplanado de la estructura**

Se reescribió usando `elif` para que los tres casos queden al mismo nivel de indentación:

```jason
if (Weight <= 10 & W <= 1 & H <= 1) {
    +assigned(robot_light, CId, ShelfId);
    +task_history(robot_light, CId, ShelfId);
    .send(robot_light, tell, task(CId, ShelfId));
} elif (Weight <= 30 & W <= 1 & H <= 2) {
    +assigned(robot_medium, CId, ShelfId);
    +task_history(robot_medium, CId, ShelfId);
    .send(robot_medium, tell, task(CId, ShelfId));
} else {
    +assigned(robot_heavy, CId, ShelfId);
    +task_history(robot_heavy, CId, ShelfId);
    .send(robot_heavy, tell, task(CId, ShelfId));
}.
```

**Nueva creencia `task_history`**

Se introduce `task_history(Robot, CId, ShelfId)` como creencia separada de `assigned(Robot, CId, ShelfId)`:

| Creencia | Ciclo de vida | Propósito |
|---|---|---|
| `assigned(Robot, CId, ShelfId)` | Se elimina al confirmar almacenamiento, error o fallo | Trazabilidad activa — qué tareas están vivas ahora mismo |
| `task_history(Robot, CId, ShelfId)` | Permanece para siempre | Historial completo — registro inmutable de todas las asignaciones |

Esto permite auditar qué robot procesó qué contenedor incluso después de que la tarea haya finalizado, sin interferir con la lógica de asignación activa.

**Trazas de debug añadidas**

Cada rama imprime una línea `[TRACE]` al asignar:

```
[TRACE] assigned: robot_light -> container_3 -> shelf_2
```

**Ficheros modificados**

- `src/agt/scheduler.asl`: lógica de asignación aplanada con `elif`, añadido `+task_history(...)` y `.print("[TRACE]...")` en las tres ramas.

---
## 13. Undécima ronda -> Limpieza de Java y supervisión completa de errores

### 1. Sustitución de API deprecada: `Literal.parseLiteral` → `ASSyntax.parseLiteral`

**Problema**

Todas las llamadas a `Literal.parseLiteral(String)` en `WarehouseArtifact.java` (14 ocurrencias) generaban el warning `The method parseLiteral(String) from the type Literal is deprecated` en el IDE. Aunque funcional, es una API marcada para eliminación en futuras versiones de Jason.

**Solución**

Sustitución global por `ASSyntax.parseLiteral(String)`, que es la API actualizada y equivalente funcionalmente. `ASSyntax` ya estaba disponible vía el import `jason.asSyntax.*` existente.

**Detalle técnico**: `ASSyntax.parseLiteral` lanza `ParseException` (checked), mientras que `Literal.parseLiteral` la silenciaba internamente. El método `addError` no tenía `try-catch`, por lo que se añadió uno específico para esas dos líneas.

---

### 2. Eliminación de código muerto: `getOriginalCellType`

El método privado `getOriginalCellType(int x, int y)` nunca era invocado desde ningún punto del código. Se eliminó para mantener el fichero limpio. VS Code lo marcaba con "is never used locally".

---

### 3. Supervisor recibe errores de navegación vía robots

**Problema**

Los robots notifican al supervisor vía `.send` los errores con contexto de contenedor (`container_too_heavy`, `container_too_big`, `shelf_full`). Sin embargo, los errores de navegación (`route_blocked`, `path_blocked`, `destination_conflict`, `illegal_move`, `too_far`, `robot_not_found`) no tenían plan específico — caían al plan genérico `+error(ErrorType, Data) : carrying(CId)` que enviaba `container_error(none, ErrorType)` cuando el robot no llevaba carga. El supervisor nunca recibía una notificación correcta.

**Solución inicial (intermedia)**

Se añadió en `addError` (Java) una notificación directa al supervisor filtrada por `NAVIGATION_ERRORS`. Solución funcional pero arquitectónicamente incorrecta: el entorno Java comunicándose directamente con el supervisor, saltándose la autonomía de los agentes.

**Solución definitiva**

Cada plan de error de navegación en los tres robots envía directamente al supervisor:

```jason
+error(path_blocked, Data) : true <-
    .my_name(Me);
    .print("⚠️ Camino bloqueado: ", Data);
    .send(supervisor, tell, robot_error(Me, path_blocked, Data));
    -+state(idle);
    -+carrying(none).
```

`addError` en Java vuelve a su responsabilidad original: solo añadir la percepción `error(ErrorType, Data)` al robot que falló. El robot decide qué comunicar y a quién.

**Canales de notificación de errores resultantes**

| Tipo de error | Quién notifica al supervisor | Literal |
|---|---|---|
| `container_too_heavy`, `container_too_big`, `shelf_full` | Robot vía `.send` | `container_error(CId, ErrorType)` |
| `route_blocked`, `path_blocked`, `destination_conflict`, `illegal_move`, `too_far`, `robot_not_found` | Robot vía `.send` | `robot_error(Robot, ErrorType, Data)` |

**Plan añadido en `supervisor.asl`**

```jason
+robot_error(Robot, ErrorType, Data) : true <-
    +navigation_error_occurred(Robot, ErrorType);
    .print("[SUPERVISOR] Error de navegacion en ", Robot, ": ", ErrorType).
```

La creencia `navigation_error_occurred(Robot, ErrorType)` es permanente — historial de errores de navegación visible en el Mind Inspector.

**Ficheros modificados**

- `src/env/warehouse/WarehouseArtifact.java`: eliminado `NAVIGATION_ERRORS`, eliminada notificación al supervisor en `addError`
- `src/agt/robot_light.asl`, `robot_medium.asl`, `robot_heavy.asl`: añadido `.send(supervisor, tell, robot_error(...))` en los 6 planes de error de navegación de cada robot
- `src/agt/supervisor.asl`: añadido plan `+robot_error` con historial `+navigation_error_occurred`

---

## 14. Duodécima ronda -> Fix: planes específicos para errores de navegación en robots

**Problema**

Los errores de navegación (`route_blocked`, `path_blocked`, `illegal_move`, `robot_not_found`, `too_far`) no tenían plan específico en los robots, por lo que caían al plan genérico:

```jason
+error(ErrorType, Data) : carrying(CId) <- ...
```

Cuando el robot tenía `carrying(none)` (sin carga activa), `CId` se ligaba al átomo `none` y el plan enviaba `container_error(none, path_blocked)` al scheduler y supervisor — un error falso sin contenedor real.

**Causa raíz**

`carrying(none)` es una creencia válida (estado idle/reset). El patrón `carrying(CId)` unifica con ella ligando `CId = none`. Los errores de navegación ocurren durante `move_to`, que puede fallar tanto en fase de aproximación (sin carga) como en fase de transporte (con carga). Los errores de contenedor (`container_too_heavy`, etc.) siempre ocurren durante `pickup`, donde el robot ya tiene `carrying(CId)` con CId real.

**Solución**

Añadir planes específicos con contexto `true` para todos los errores de navegación, **antes** del plan genérico, en los tres robots. Estos planes solo limpian el estado sin enviar mensajes al scheduler/supervisor (Java ya notifica al supervisor vía `NAVIGATION_ERRORS`, y `-!execute_task` ya notifica al scheduler con `task_failed` si la acción falla):

| Error | light | medium | heavy |
|---|---|---|---|
| `route_blocked` | añadido | añadido | añadido |
| `path_blocked` | añadido | añadido | añadido |
| `illegal_move` | añadido | añadido | añadido |
| `robot_not_found` | añadido | añadido | añadido |
| `too_far` | añadido | añadido | ya existía |

**Ficheros modificados**

- `src/agt/robot_light.asl`: 5 planes nuevos de navegación
- `src/agt/robot_medium.asl`: 5 planes nuevos de navegación
- `src/agt/robot_heavy.asl`: 4 planes nuevos de navegación (`too_far` ya existía)

---

## 15. Decimotercera ronda -> Fix: estado de robots en tiempo real con `askOne`

**Problema**

El reporte periódico del supervisor leía la creencia cacheada `robot_status(R, S)`, que se actualiza mediante mensajes `.send` de los robots. Estos mensajes son **asíncronos**: cuando el supervisor ejecuta `!print_stats`, los mensajes de cambio de estado pueden estar todavía en la cola de entrada. El resultado era que el reporte mostraba `working` para robots que ya estaban en `idle`.

Ejemplo reproducido:
```
[robot_heavy] [HEAVY] Esperando tarea del planificador central...
[robot_light] [LIGHT] Esperando tarea del planificador central...
[supervisor] ========================================
[supervisor]   robot_light: working  ← incorrecto, ya estaba idle
[supervisor]   robot_heavy: working  ← incorrecto, ya estaba idle
```

**Causa raíz**

En Jason, los mensajes entre agentes son asíncronos: el receptor los procesa en su siguiente ciclo de razonamiento. Si `!print_stats` ya ha comenzado a ejecutarse, los mensajes `robot_state_change(Me, idle)` llegan después del `print`, aunque hayan sido enviados antes en tiempo de reloj.

**Solución**

Se reemplaza la lectura de la caché por consultas directas a cada robot usando la performativa `askOne`:

```jason
// Antes: lee caché local del supervisor
+!print_robot_status : true <-
    .findall(rs(R, S), robot_status(R, S), Robots);
    !print_robot_list(Robots).

// Después: consulta el estado real en el momento exacto del reporte
+!print_robot_status : true <-
    .send(robot_light,  askOne, state(SL), state(SL));
    .send(robot_medium, askOne, state(SM), state(SM));
    .send(robot_heavy,  askOne, state(SH), state(SH));
    .print("  robot_light: ",  SL);
    .print("  robot_medium: ", SM);
    .print("  robot_heavy: ",  SH).
```

`askOne` es una performativa FIPA estándar de Jason: suspende la intención del supervisor hasta recibir respuesta del robot consultado. El robot destino responde automáticamente con su creencia `state(X)` actual — no necesita ningún plan especial para contestar.

**Por qué se mantiene `+robot_state_change`**

La creencia `robot_status(R, S)` sigue actualizándose vía `+robot_state_change` porque es útil para el Mind Inspector (permite ver el historial de cambios de estado en tiempo real). Solo se elimina su uso en el reporte, donde ahora se usa `askOne` para garantizar precisión.

Los planes helper `!print_robot_list([])` y `!print_robot_list([H|T])` se eliminan por quedar huérfanos.

**Ficheros modificados**

- `src/agt/supervisor.asl`: `!print_robot_status` reescrito con `askOne`, eliminados `!print_robot_list([])` y `!print_robot_list([H|T])`

---

## 16. Decimocuarta ronda -> Refactorización: `.count` a forma estándar de dos argumentos

**Contexto**

El profesor confirmó que `.count(Pattern, Var)` sí funciona correctamente en cuerpos de planes en Jason 3.3.0, con el siguiente ejemplo de prueba:

```jason
creencia("A").
creencia("B").
!contar_creencias.

+!contar_creencias : true <-
    .count(creencia(_), Total);
    .print("Total creencias: ", Total);
    .wait(10000);
    !contar_creencias.
```

Este plan imprime `Total creencias: 2` correctamente. La forma de un argumento usada en la sección 8 (`N = .count(P)`) era un workaround innecesario.

**Qué se hizo**

Se actualizaron los 7 usos de `.count` en `supervisor.asl` a la forma estándar de dos argumentos:

```jason
// Antes (workaround):
Received = .count(container_received(_));

// Después (forma estándar):
.count(container_received(_), Received);
```

**Ficheros modificados**

- `src/agt/supervisor.asl`: 7 ocurrencias de `N = .count(P)` reemplazadas por `.count(P, N)`

---

## 17. Decimoquinta ronda -> Navegación inteligente: `move_to_container` y `move_to_shelf`

**Problema**

Los robots calculaban manualmente las coordenadas de destino para recoger contenedores y depositar en estanterías:

- **Fase 1 (contenedor):** `get_container_info` → coordenadas con offsets fijos (`CX-1`, `CX+W`, `CY-1`) según el robot, con `if/else` para evitar salir del mapa. El robot siempre llegaba desde el mismo lado.
- **Fase 3 (estantería):** `get_shelf_position` → `move_to(SX, SY-1)` — siempre la misma celda fija encima de la estantería, independientemente de si estaba libre o había otro robot.

Esto violaba el requisito del profesor: *"que el robot se pueda poner adyacente a un contenedor, no que se ponga a machete delante (abajo)"*.

**Solución**

Se añadieron dos nuevas acciones Java y se refactorizó `executeMoveTo` para eliminar duplicación:

### `getAdyacentes(int x, int y, int width, int height)`

Método privado que devuelve todas las celdas adyacentes ortogonales (arriba, abajo, izquierda, derecha — **sin diagonales**) a un rectángulo de posición `(x,y)` y dimensiones `width×height`, filtrando celdas fuera del mapa, `SHELF` y `BLOCKED`:

```java
// Fila superior:   (x..x+width-1, y-1)
// Fila inferior:   (x..x+width-1, y+height)
// Columna izq:     (x-1, y..y+height-1)
// Columna dcha:    (x+width, y..y+height-1)
```

### `executeMoveToContainer(agName, action)`

Acción `move_to_container(ContainerId)` — busca el contenedor en el mapa Java, obtiene sus adyacentes, elige la primera celda libre (sin robot), y ejecuta el movimiento con la lógica completa de `doMoveTo`.

### `executeMoveToShelf(agName, action)`

Acción `move_to_shelf(ShelfId)` — igual pero para estanterías. Busca la estantería por ID, obtiene sus adyacentes, elige la primera libre, y mueve el robot.

### `doMoveTo(agName, targetX, targetY)`

Se extrajo el núcleo de movimiento de `executeMoveTo` a un método privado reutilizable. Ahora `executeMoveTo`, `executeMoveToShelf` y `executeMoveToContainer` comparten la misma lógica: reserva en `activeDestinations`, cálculo de ruta, movimiento reactivo paso a paso, percepción `robot_at` final.

**Cambios en los robots**

Los tres robots (`robot_light.asl`, `robot_medium.asl`, `robot_heavy.asl`) se simplificaron eliminando código de navegación manual:

| Antes | Después |
|---|---|
| `get_container_info` + `.wait` + `?` + `if/else move_to(...)` | `move_to_container(CId)` |
| `!navigate_to_shelf` → `get_shelf_position` → `move_to(SX, SY-1)` | `move_to_shelf(ShelfId)` |

Los planes `!navigate_to_shelf` y `!try_move_to_shelf` se eliminaron de los tres robots por quedar huérfanos.

**Resultado**

- El robot se posiciona en la celda adyacente libre más cercana al contenedor o estantería, no siempre en la misma posición fija.
- Si la primera celda adyacente está ocupada por otro robot, automáticamente elige la siguiente disponible.
- Las diagonales nunca se consideran adyacentes, cumpliendo el requisito explícito del profesor.

**Ficheros modificados**

- `src/env/warehouse/WarehouseArtifact.java`: añadidos `executeMoveToShelf`, `executeMoveToContainer`, `getAdyacentes`, `doMoveTo`; registradas `move_to_shelf` y `move_to_container` en el switch; `executeMoveTo` refactorizado para delegar en `doMoveTo`
- `src/agt/robot_light.asl`: Fase 1 y Fase 3 simplificadas, eliminados `!navigate_to_shelf` y `!try_move_to_shelf`
- `src/agt/robot_medium.asl`: ídem
- `src/agt/robot_heavy.asl`: ídem

---

## 18. Decimosexta ronda -> Fix: errores de navegación visibles en el reporte del supervisor

**Problema**

El reporte periódico mostraba `Errores por tipo:` pero nunca imprimía nada debajo, incluso cuando habían ocurrido errores de navegación. Dos causas:

1. `!print_errors_by_type` iteraba sobre `errors_by_type(T, _)` — lista fija de tipos de error de contenedor definida en las creencias iniciales. Los errores de navegación se almacenan en `navigation_error_occurred(Robot, ErrorType)`, una creencia distinta que nunca se consultaba en el reporte.

2. Si no había errores de contenedor, la sección quedaba vacía aunque hubiera errores de navegación acumulados en el Mind Inspector.

**Solución**

Se reescribió `!print_errors_by_type` para cubrir ambos tipos:

- **Errores de contenedor:** igual que antes, itera sobre `errors_by_type(T, _)` y cuenta `error_occurred(_, T)`
- **Errores de navegación:** usa `.findall` sobre `navigation_error_occurred(_, T)` para obtener todos los tipos que han ocurrido, luego itera deduplicando con una lista `Seen` acumulada:

```jason
+!print_nav_error_list([], _) : true <- true.

+!print_nav_error_list([T|Rest], Seen) : .member(T, Seen) <-
    !print_nav_error_list(Rest, Seen).

+!print_nav_error_list([T|Rest], Seen) : true <-
    .count(navigation_error_occurred(_, T), N);
    .print("  ", T, " (nav): ", N);
    !print_nav_error_list(Rest, [T|Seen]).
```

La deduplicación es necesaria porque `.findall` devuelve una entrada por cada instancia — si `path_blocked` ocurrió 3 veces, aparece 3 veces en la lista. El patrón `Seen` acumula los tipos ya impresos y los salta.

**Resultado en el reporte**

```
Errores por tipo:
  container_too_heavy: 1
  path_blocked (nav): 3
  destination_conflict (nav): 1
```

**Ficheros modificados**

- `src/agt/supervisor.asl`: `!print_errors_by_type` extendido con sección de navegación, añadidos `!print_nav_error_list` y sus dos variantes

---

## 19. Decimoséptima ronda -> Clasificación de contenedores por tipo, peso y tamaño en el scheduler

**Objetivo**

El objetivo semanal "scheduler clasifica contenedor por peso/tamaño/tipo" requería que el scheduler mantuviera creencias explícitas sobre la categoría de cada contenedor, no solo que tomara decisiones de asignación basadas en esos atributos.

**Qué se hizo**

Se añadieron tres nuevas creencias en el plan `+free_shelf` de `scheduler.asl`, generadas en el momento de la asignación:

| Creencia | Valores posibles | Criterio |
|---|---|---|
| `container_type(CId, Type)` | `urgent`, `fragile`, `standard` | Tipo recibido del entorno |
| `container_weight_category(CId, Cat)` | `light`, `medium`, `heavy` | Peso: ≤10 / ≤30 / >30 kg |
| `container_size_category(CId, Cat)` | `small`, `medium`, `large` | Tamaño: 1×1 / 1×2 / mayor |

**Por qué separar peso y tamaño**

Aunque la lógica de asignación usa ambos combinados (`Weight <= 10 & W <= 1 & H <= 1`), un contenedor puede ser ligero pero grande (ej: 1×2, 5kg) o pesado pero compacto (ej: 1×1, 80kg). Tenerlos como creencias independientes permite ver en el Mind Inspector exactamente qué criterio predominó en cada caso, sin cambiar la lógica de asignación.

La creencia `container_category(CId, Cat)` ya existente refleja la **decisión final** del scheduler (qué robot se asignó). Las nuevas creencias reflejan los **atributos individuales** del contenedor.

**La lógica de asignación no cambia** — el `elif` sigue igual. Las creencias son puramente informativas.

**Visible en**

- Mind Inspector del scheduler: 4 creencias por contenedor
- Logs: `[TRACE] assigned: robot_light -> container_5 -> shelf_4 [fragile]` (el tipo ya aparecía)

**Ficheros modificados**

- `src/agt/scheduler.asl`: añadidas clasificaciones por tipo, peso y tamaño antes del bloque de asignación de robot

---

## 20. Decimoctava ronda -> Activación de contadores totales en supervisor y scheduler

**Problema**

Las creencias iniciales `total_received(0)`, `total_stored(0)` y `total_errors(0)` (supervisor) y `total_containers_received(0)` y `total_tasks_assigned(0)` (scheduler) estaban declaradas pero **nunca se actualizaban**. Permanecían a `0` durante toda la ejecución, haciéndolas inútiles en el Mind Inspector.

Los totales sí se calculaban correctamente con `.count` durante el reporte periódico, pero ese resultado no se persistía como creencia.

**Solución**

Se aprovecha que cada plan relevante ya calculaba `N` con `.count` para añadir `-+total_X(N)` justo después, actualizando la creencia en tiempo real:

**Supervisor** (`supervisor.asl`):

```jason
// +new_container: ya calculaba N con .count(container_received(_), N)
-total_received(_);
+total_received(N);

// +container_stored: ya calculaba N con .count(container_stored_fact(_,_), N)
-total_stored(_);
+total_stored(N);

// +container_error: ya calculaba N con .count(error_occurred(_,_), N)
-total_errors(_);
+total_errors(N);
```

**Scheduler** (`scheduler.asl`):

```jason
// +container_info: añadido .count(container_info(...), N)
-total_containers_received(_);
+total_containers_received(N);

// +free_shelf (tras asignación): añadido .count(task_history(_,_,_), T)
-total_tasks_assigned(_);
+total_tasks_assigned(T);
```

**Por qué `-+` en vez de incremento manual**

El patrón `-old; +(old+1)` requiere recuperar el valor anterior con `?` y es propenso a condiciones de carrera. Recalcular con `.count` directamente desde las creencias fuente es más robusto y coherente con el resto del sistema.

**Resultado**

Mind Inspector del supervisor muestra en tiempo real:
```
total_received(4)
total_stored(2)
total_errors(0)
```

Mind Inspector del scheduler muestra:
```
total_containers_received(4)
total_tasks_assigned(4)
```

**Ficheros modificados**

- `src/agt/supervisor.asl`: activados `total_received`, `total_stored`, `total_errors`
- `src/agt/scheduler.asl`: activados `total_containers_received`, `total_tasks_assigned`

---

## 21. Decimonovena ronda -> Listas de contenedores por categoría en el scheduler

**Objetivo**

Cumplir el ticket: *"containersHeavy: lista rellenada con los nombres de los contenedores (c1, c3, ...)"* y *"creencias con la lista de qué contenedores pertenecen a qué clasificación (heavy, medium, light)"*.

**Qué se hizo**

Se añadieron tres creencias iniciales vacías en `scheduler.asl`:

```jason
containers_heavy([]).
containers_medium([]).
containers_light([]).
```

En cada rama del bloque de asignación (`if/elif/else`), tras asignar `container_category`, se actualiza la lista correspondiente usando el patrón estándar de Jason para modificar una creencia lista:

```jason
?containers_heavy(HL);   // leer lista actual
-containers_heavy(HL);   // eliminar creencia antigua
+containers_heavy([CId|HL]);  // añadir CId al principio
```

**Por qué este patrón y no `-+`**

`-+` solo funciona cuando el nuevo valor no depende del anterior. Aquí necesitamos leer `HL` primero para construir `[CId|HL]`, por lo que hay que hacer los tres pasos explícitamente.

**Resultado en el Mind Inspector**

```
containers_heavy(["container_6","container_2"])
containers_medium(["container_8","container_7","container_5","container_4","container_3","container_1"])
containers_light([])
```

**Ficheros modificados**

- `src/agt/scheduler.asl`: añadidas creencias iniciales `containers_heavy/medium/light([])` y actualización de listas en las tres ramas de asignación
