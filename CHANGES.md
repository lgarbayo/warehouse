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

2. **`.count(Pattern, Var)` (forma de dos argumentos) no es válida en cuerpos de planes.**
   En Jason 3.3.0, `.count` funciona como función aritmética inline con un solo argumento: `.count(Pattern)` devuelve el entero directamente (como `math.max(...)` o `math.abs(...)`). La forma de dos argumentos `.count(P, N)` existe en contextos de plan (guardas) para comparar contra un valor ya ligado, pero no para ligar una variable en el cuerpo. Forma correcta en el cuerpo:

   ```jason
   // Incorrecto en cuerpo de plan:
   .count(container_received(_), Received);

   // Correcto:
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