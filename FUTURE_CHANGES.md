# 2nd Iteration

The environment can only provide the location of the agents, the shelves and containers.
Temporal control: the scheduler will indicate which packages must be in the outbound area and the time limit by which they must be there (deadline).
Scheduler coordination change: the scheduler will no longer act as the central information provider; robots will query the environment to obtain package locations.
Distributed coordination among robots to organize themselves autonomously and efficiently, without relying on the scheduler to assign specific tasks, in order to optimize workflow.

## Known Bugs — Iteration 2

### 1. Supervisor stats undercount (claim race condition)
`claim_container` removes the `container_at_entrance` percept atomically. If a robot claims and removes the percept before the supervisor's perception cycle runs, the supervisor never fires `+container_at_entrance` and never increments `total_received`. Result: supervisor final report underreports total containers processed.
**Fix direction**: supervisor should track arrivals via a dedicated broadcast belief (`container_received(CId)`) sent by the robot that successfully claims, rather than relying on percept observation.

### 2. execute_exit partial failure — container lost in transit
If `pickup_from_shelf` succeeds but the subsequent navigate to the outbound zone fails (e.g. nav_timeout), the `-!execute_exit` failure handler only calls `!check_queue`. The container has been physically removed from the shelf (Java state updated) but never delivered to OUTBOUND — it is effectively lost (not on shelf, not at outbound, not at entrance).
**Fix direction**: the failure handler must either return the container to the shelf (`drop_on_shelf(ShelfId)`) or re-emit a `container_at_entrance` percept so another robot can claim it.

### 3. unclaim force-drop leaves container at wrong grid position
`executeUnclaimContainer` in `WarehouseArtifact.java` now calls `robot.drop()` + `container.setPicked(false)` when the robot physically holds the container being unclaimed. This frees the robot for future pickups, but the container's grid coordinates remain at the robot's current position (wherever it got stuck), not at the entrance. The re-emitted `container_at_entrance` percept is logically correct but the physical position is inconsistent — if another robot navigates to the entrance to pick it up, the Java-side `pickup()` may fail because the container is not actually at entrance coordinates.
**Fix direction**: after `robot.drop()`, reset the container's position to its original entrance cell before re-adding the percept.

### ~~4. askOne suspension window in check_exit_cycle~~ ✅ Resuelto en iteración 3
~~`!check_exit_cycle` uses `.send(scheduler, askOne, active_deadline, ...)` which suspends the current intention~~

**Fix aplicado**: `run_exit_cycle` hace broadcast `tell/untell active_deadline` a todos los robots al inicio/fin de cada deadline. `!check_exit_cycle` consulta la creencia local sin round-trip. Ventana de suspensión eliminada.

### 5. nav_abort_signal — fragile failure propagation in navigate
The navigation timeout path in `!navigate` relies on `?nav_abort_signal` — a belief query that is expected to fail — as a mechanism to propagate navigation failure out of a nested intention. This is a fragile hack: if a belief named `nav_abort_signal` is accidentally added elsewhere, the abort silently stops triggering. The mechanism also makes the control flow hard to follow.
**Fix direction**: use a proper internal goal `!abort_navigation(CId)` with a dedicated failure plan, or raise a named exception via `.throw` / Jason's internal action mechanism.

### 6. Error handler / plan hierarchy tension for path_blocked-after-pickup
When `path_blocked` fires after a successful pickup, the error handler immediately resets `state(idle)` and `carrying(none)` in Jason beliefs. This happens outside the normal plan hierarchy — the `-!execute_task` failure plan then runs and checks `nav_failed(CId)` to decide whether to also call `release_task`/`unclaim_container`. The split handler partially addresses this, but the architectural tension remains: reactive error handlers and declarative failure plans both modify overlapping state, making it easy for future changes to reintroduce double-cleanup or missed-cleanup bugs.
**Fix direction**: consolidate all post-failure cleanup into a single `!handle_task_failure(CId, Reason)` plan called from both the error handler and the `-!execute_task` plan, with the reason parameter controlling which cleanup steps run.

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
