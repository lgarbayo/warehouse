# 2nd Iteration

The environment can only provide the location of the agents, the shelves and containers.
Temporal control: the scheduler will indicate which packages must be in the outbound area and the time limit by which they must be there (deadline).
Scheduler coordination change: the scheduler will no longer act as the central information provider; robots will query the environment to obtain package locations.
Distributed coordination among robots to organize themselves autonomously and efficiently, without relying on the scheduler to assign specific tasks, in order to optimize workflow.

## Known Bugs — Iteration 2

### 6. Error handler / plan hierarchy tension — desincronización Java-Jason

**Causa raíz**: Java y Jason mantienen estados independientes que pueden desincronizarse. El estado físico (`robot.isCarrying()`, posición) solo cambia con acciones Java explícitas (`pickup`, `drop`, `move_step`). Las creencias Jason (`carrying(CId)`, `state(idle)`) las actualiza el agente manualmente. Los handlers reactivos de error solo tocan creencias Jason, sin acción Java correspondiente:

```agentspeak
+error(path_blocked, Data) : true <-
    .send(supervisor, tell, robot_error(Me, path_blocked, Data));
    -+state(idle); -+carrying(none).   // solo Jason — robot.isCarrying() sigue true en Java
```

**Síntoma documentado originalmente (Bug 6)**: cuando `path_blocked` ocurre tras un pickup exitoso, el handler reactivo resetea `carrying(none)` en Jason. Después `-!execute_task` también corre y llama `unclaim_container`/`release_task`. Dos rutas de cleanup sobre el mismo estado → riesgo de doble-cleanup o cleanup incompleto.

**Dependencia implícita con el fix de Bug 2**: la corrección de Bug 2 asume que cuando `-!return_to_shelf` falla, el robot sigue llevando físicamente el contenedor en Java (`robot.isCarrying() = true`), lo que permite que `unclaim_container` haga el drop y el reset de posición. Esto es verdad mientras los handlers reactivos no añadan una acción Java de drop. Si en el futuro alguien "arregla" el handler añadiendo `drop_item` o similar, el fix de Bug 2 dejaría de funcionar correctamente.

**Fix direction**: consolidar todo el cleanup post-fallo en un único plan `!handle_task_failure(CId, Reason)` llamado tanto desde los handlers reactivos como desde `-!execute_task`, con el parámetro `Reason` controlando qué pasos de cleanup ejecutar. El plan debe ser la única autoridad sobre qué acciones Java y qué creencias Jason se limpian, eliminando la dependencia de la desincronización.

---

## Mejoras pendientes

LOGS EN INGLÉS, CÓDIGO MUERTO, 
LOGS DE CONSOLA Y REPL AGENT, POSIBLES FIXES DE BUGS DE EJECUCIÓN.

### Centralizar coordenadas de zona en `common.asl`

Las coordenadas de zona (outbound en x≥17, y≤1; corredores en x=9 y x=19; posiciones iniciales de robots; etc.) están hardcodeadas en las reglas de navegación de los 4 robots. Si el mapa cambia, hay que actualizarlas manualmente en cada archivo.

**Solución propuesta**: mover todos los valores a `common.asl` como facts únicos:
```agentspeak
zone_x_min(outbound, 17).
zone_y_max(outbound, 1).
corridor_x(9).
corridor_x(19).
```
Los robots los usan en sus reglas de navegación en lugar de literales numéricos. Un solo punto de cambio si el mapa evoluciona.

Existe una alternativa más completa (Java emite `zone_bounds` como percepts al arranque, agentes completamente dinámicos) pero implica refactorizar 20+ variantes de navegación y no es prioritaria mientras el mapa no cambie.