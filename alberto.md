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
