# Future Changes

## Mostrar lista contenedores al final
## Resolver tema de tipos de containers (standard, urgent y fragile)

### Los path_blocked - No route found to (0,0) no cuentan gracias al -!check_queue que los descarta. Por qué? Porque el retorno a base es una funcionalidad de comodidad — si no puede volver, no pasa nada, el robot simplemente se queda donde terminó la última entrega y sigue operativo para la siguiente tarea. Si ese fallo llegara al supervisor contaminaría total_errors y error_rate con algo que no es un error real del sistema. Un robot que no puede volver a su posición inicial no afecta para nada a la operación del almacén.

## 09/04
Errrores generales de laiteracion 1

There is no formal planning: no action plan is drawn up before execution. The agentes react sequentially. A planning agent RyN, Chapter 11 would generate an optimal plan b ytaking into account all pending containers and the avaliability of robots.
Goal -> Draw up a formal plan for how to handle pending containers and robot availability (see Russel and Norvig, Chapter 11).

## CORRECCIÓN ITERACIÓN 1
Código: 80
- Se debe tener cuidado a la hora de calcular la ruta, puesto que se hace en base a un estado presente del entorno, y no en el tiempo futuro en el que se va a realizar la acción, por lo que ese estado del entorno no se cumpla (puede que al calcular la ruta, no existan obstáculos que si se pueden dar cuando los robots se están moviendo en el entorno). Tiene que ver con: "Distributed coordination among robots to organize themselves autonomously and efficiently, without relying on the scheduler to assign specific tasks, in order to optimize workflow."

Memoria: 80
- Se incluyen diagramas y están referenciados en el texto.
- Memoria con carácter LLM. Debe ser pulido este carácter.
- Cómo se tiene en cuenta las etiquetas urgent y fragile en la asignación de los contenedores? Realmente se hace como se dice en la memoria? En código los contenedores son asignados a la cola del correspondiente robot sin tener ninguna matización de si es urgente o fragile.
- El rol que está manteniendo ahora el Scheduler es de broker centralizado, por lo que la arquitectura es centralizada en el Scheduler.
- Ojo con este tipo de afirmaciones: "El supervisor confirma la operación mediante el reporte periódico, que muestra tasas de éxito del 100 % en escenarios sin saturación.". Estas afirmaciones del 100 % sin un respaldo documentado son complicadas de mantener.

# 2nd Iteration
The environment can only provide the location of the agents, the shelves and containers.
A new outbound area located in the area opposite to the entry point.
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

### 4. askOne suspension window in check_exit_cycle
`!check_exit_cycle` uses `.send(scheduler, askOne, active_deadline, ...)` which suspends the current intention while waiting for the scheduler reply. During this suspension window a reactive `+container_at_entrance` plan can fire and transition the robot to `state(working)`. The `state(idle)` guard added to `!select_for_exit` prevents acting on the exit cycle result in that case, but the askOne round-trip still happens and the scheduler's reply arrives and is discarded — wasted communication per cycle.
**Fix direction**: scheduler should proactively broadcast `active_deadline(CId, ShelfId, Deadline)` beliefs to all robots; robots maintain a local `active_deadline` belief and check it without a round-trip query, eliminating the suspension window entirely.

### 5. nav_abort_signal — fragile failure propagation in navigate
The navigation timeout path in `!navigate` relies on `?nav_abort_signal` — a belief query that is expected to fail — as a mechanism to propagate navigation failure out of a nested intention. This is a fragile hack: if a belief named `nav_abort_signal` is accidentally added elsewhere, the abort silently stops triggering. The mechanism also makes the control flow hard to follow.
**Fix direction**: use a proper internal goal `!abort_navigation(CId)` with a dedicated failure plan, or raise a named exception via `.throw` / Jason's internal action mechanism.

### 6. Error handler / plan hierarchy tension for path_blocked-after-pickup
When `path_blocked` fires after a successful pickup, the error handler immediately resets `state(idle)` and `carrying(none)` in Jason beliefs. This happens outside the normal plan hierarchy — the `-!execute_task` failure plan then runs and checks `nav_failed(CId)` to decide whether to also call `release_task`/`unclaim_container`. The split handler partially addresses this, but the architectural tension remains: reactive error handlers and declarative failure plans both modify overlapping state, making it easy for future changes to reintroduce double-cleanup or missed-cleanup bugs.
**Fix direction**: consolidate all post-failure cleanup into a single `!handle_task_failure(CId, Reason)` plan called from both the error handler and the `-!execute_task` plan, with the reason parameter controlling which cleanup steps run.