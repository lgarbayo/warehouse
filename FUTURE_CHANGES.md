# 2nd Iteration

The environment can only provide the location of the agents, the shelves and containers.
Temporal control: the scheduler will indicate which packages must be in the outbound area and the time limit by which they must be there (deadline).
Scheduler coordination change: the scheduler will no longer act as the central information provider; robots will query the environment to obtain package locations.
Distributed coordination among robots to organize themselves autonomously and efficiently, without relying on the scheduler to assign specific tasks, in order to optimize workflow.

---

> [!NOTE]
> Nota: cambiar light por L, medium por M, heavy por H, heavy por H2??
>
> Nota: cambiar zonas hardcodeadas?

> [!WARNING]
> **Problema con el backoff: Backoff vertical de dos pasos — robot puede quedar en posición intermedia**
>
> El plan `!path_backoff` para los casos verticales (TY > Y / TY < Y) ejecuta dos `move_step` consecutivos:
> primero `move_step(NX, Y)` (desplazamiento lateral) y luego `move_step(NX, NY)` (diagonal).
> Si el primer paso tiene éxito pero el segundo falla, el robot queda en (NX, Y) — una posición
> intermedia — pero el plan de fallo de `!step_with_retry` recibe las coordenadas originales (X, Y),
> causando inconsistencia de estado. Observado en producción: robot_heavy2 quedó bloqueado tras la
> recuperación de shelf_full cerca de la zona de expansión.
>
> **Solución propuesta:** reemplazar el backoff de dos pasos por un backoff basado en espera pura
> (`.wait()` adicional), dejando que BC se acumule de forma natural hasta que `path_blocked` active
> la recuperación de error, o bien implementar un algoritmo de pathfinding real (A*).

> [!WARNING]
> **REVISAR LO IMPLEMENTADO EN EL OUTBOUND**
> **Inbound: el scheduler sigue asignando tareas y robots**
>
> El objetivo de la 2ª semana exige que el scheduler "no asigne tareas ni robots". En el ciclo
> outbound esto se cumple: el scheduler hace broadcast de `outbound_available` a todos los robots
> y cada uno decide autónomamente según sus capacidades.
>
> En el ciclo **inbound** no se cumple: el planificador formal genera `assign(Robot, CId, ShelfId)`
> y el scheduler responde a cada `request_task` con `ready_task(Robot, CId, ShelfId)` — asignación
> robot-específica. El robot que pide trabajo recibe exactamente la tarea que el scheduler ha
> decidido para él, sin autonomía de decisión.
>
> **Pendiente:** adaptar el inbound para que el scheduler anuncie contenedores pendientes
> (`task_available(CId, ShelfId, W, H, Weight)`) a todos los robots y cada uno decida si lo toma,
> igual que en el outbound. El planificador puede seguir existiendo para decidir *a qué estantería*
> va cada contenedor — lo que debe eliminarse es la asignación del robot concreto.

> [!WARNING]
>
> Revisar bugs de movimiento cuando se dejan robots en la zona de clasification