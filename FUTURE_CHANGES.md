# 2nd Iteration

The environment can only provide the location of the agents, the shelves and containers.
Temporal control: the scheduler will indicate which packages must be in the outbound area and the time limit by which they must be there (deadline).
Scheduler coordination change: the scheduler will no longer act as the central information provider; robots will query the environment to obtain package locations.
Distributed coordination among robots to organize themselves autonomously and efficiently, without relying on the scheduler to assign specific tasks, in order to optimize workflow.

## Known Bugs — Iteration 2

### 6. Error handler / plan hierarchy tension — desincronización Java-Jason (parcialmente resuelto)

**Causa raíz**: Java y Jason mantienen estados independientes. El handler reactivo genérico resetea creencias Jason sin acción Java correspondiente, causando desincronización cuando un robot porta físicamente un contenedor.

**Casos resueltos** mediante handlers contextuales que inhiben el reset de estado cuando el plan hierarchy puede gestionar el fallo:
- `exit_picked(_)` — durante `!execute_exit` tras recoger de estantería: el fallo propaga a `-!execute_exit : exit_picked` que devuelve el contenedor a estantería o llama `unclaim_container`. `drop_at_outbound` tiene límite de 3 reintentos; al agotarse propaga `.fail` limpiamente.
- `holding_zone(expansion)` — durante `!safe_expand_drop`: el fallo propaga a `-!safe_expand_drop` que reintenta o descarta, liberando la zona correctamente.

**Caso restante**: `execute_task` durante tránsito normal a estantería. Si `path_blocked` llega tras pickup, el handler genérico resetea `carrying(none)` sin Java drop. `-!execute_task : not carrying(CId)` llama `unclaim_container`, que en Java sí porta el contenedor (`wasCarrying=true`) y lo deposita en entrada correctamente. Resultado funcional aunque con dos rutas de cleanup solapadas. No se corrige porque el comportamiento resultante es correcto.

**Dependencia implícita con el fix de Bug 2**: si en el futuro se añade una acción Java de drop en los handlers reactivos, `unclaim_container` encontraría el robot sin carga y no haría el reposicionamiento a entrada. No modificar los handlers genéricos sin revisar esta dependencia.

### 1. Eficiencia del ciclo de salida: parcialmente mejorado

El ciclo ahora ejecuta **solo la fase relevante al tipo saturado**: si satura `standard` o `fragile` (non_urgent), activa directamente la fase non_urgent (2·ΔT) sin desperdiciar ΔT evacuando urgentes de otras estanterías. Si satura `urgent`, solo fase urgente (ΔT).

El desbloqueo automático al liberar estantería también funciona ya correctamente (ver Bug 3 resuelto).

**Limitación pendiente**: el secondary path de detección de saturación en supervisor (`-shelf_available`) sigue usando átomos de urgencia (`urgent`/`non_urgent`) en vez de strings de tipo (`"standard"`/`"fragile"`), por lo que ese path de detección permanece roto. El primary path (via error de robot → `storage_full`) funciona correctamente y dispara siempre antes en la práctica.

El problema de desbordamiento de entrada si el ciclo dura mucho (zona de 6 celdas fija) sigue siendo una limitación de diseño del enunciado.

