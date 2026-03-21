/*******************************************************************************
 * SCHEDULER - Agente Planificador y Coordinador de Tareas
 * 
 * Universidad de Vigo - Sistemas Inteligentes
 * Curso 2025-2026
 * 
 * RESPONSABILIDADES:
 *   1. Recibir notificaciones de nuevos contenedores
 *   2. Clasificar contenedores según peso, tamaño, tipo (urgente, frágil)
 *   3. Asignar tareas a robots según sus capacidades
 *   4. Optimizar la asignación para maximizar eficiencia
 *   5. Gestionar colas de contenedores pendientes
 *   6. Coordinar con supervisor para manejo de errores
 * 
 ******************************************************************************/

/* ============================================================================
 * CREENCIAS INICIALES - Base de Conocimiento
 * ============================================================================ */

/* Capacidades de los robots (debe coincidir con .mas2j) */
robot_capacity(robot_light, 10, 1, 1, 3).    // (Robot, MaxPeso, MaxW, MaxH, Velocidad)
robot_capacity(robot_medium, 30, 1, 2, 2).
robot_capacity(robot_heavy, 100, 2, 3, 1).

/* Estados de los robots */
robot_available(robot_light).
robot_available(robot_medium).
robot_available(robot_heavy).

/* Contadores y estadísticas */
total_containers_received(0).
total_tasks_assigned(0).
pending_containers(0).

/* Listas de contenedores por categoría */
containers_heavy([]).
containers_medium([]).
containers_light([]).

// 1. Reaccionar a nuevo contenedor (trigger → goal para capturar fallos)
+new_container(CId) : true <-
    .print("Nuevo contenedor: ", CId);
    !process_new_container(CId).

+!process_new_container(CId) : true <-
    get_container_info(CId).

// Fallback: container ya no existe (aplastado antes de ser procesado)
-!process_new_container(CId) : true <-
    .print("💥 [SCHEDULER] ", CId, " ya no existe al intentar procesar. Ignorando.").

// 2. Recibir info: si fue aplastado, ignorar
+container_info(CId, W, H, Weight, Type, X, Y) : container_broken(CId) <-
    .print("💥 [SCHEDULER] ", CId, " fue aplastado antes de clasificar. Ignorando.").

// Recibir info, clasificar y buscar estantería para contenedor
+container_info(CId, W, H, Weight, Type, X, Y) : not container_broken(CId) <-
    .print("Info: ", CId, " - ", Weight, "kg. Solicitando estantería...");
    +pending_container(CId, Weight);
    .count(container_info(_, _, _, _, _, _, _), N);
    -total_containers_received(_);
    +total_containers_received(N);
    !assign_shelf(CId).

// Si el contenedor fue aplastado mientras esperaba, abortar
+!assign_shelf(CId) : container_broken(CId) <-
    .print("💥 [SCHEDULER] ", CId, " fue aplastado antes de asignar estantería. Abortando.");
    -pending_container(CId, _);
    .abolish(container_info(CId, _, _, _, _, _, _));
    .abolish(container_category(CId, _));
    .abolish(container_type(CId, _));
    .abolish(container_weight_category(CId, _));
    .abolish(container_size_category(CId, _));
    .abolish(shelf_retries(CId, _)).

+!assign_shelf(CId) : true <-
    get_free_shelf(CId).

// Sin espacio: si fue aplastado durante reintentos, abortar limpiamente
-!assign_shelf(CId) : container_broken(CId) <-
    .print("💥 [SCHEDULER] ", CId, " fue aplastado durante reintentos de estantería. Abortando.");
    -pending_container(CId, _);
    .abolish(container_info(CId, _, _, _, _, _, _));
    .abolish(container_category(CId, _));
    .abolish(container_type(CId, _));
    .abolish(container_weight_category(CId, _));
    .abolish(container_size_category(CId, _));
    .abolish(shelf_retries(CId, _)).

// Sin espacio: máximo 3 reintentos antes de rechazar
-!assign_shelf(CId) : shelf_retries(CId, N) & N >= 3 <-
    .print("❌ [SCHEDULER] Container ", CId, " rechazado: sin espacio tras ", N, " intentos");
    -shelf_retries(CId, _);
    -pending_container(CId, _);
    .send(supervisor, tell, container_error(CId, no_shelf_space)).

-!assign_shelf(CId) : shelf_retries(CId, N) <-
    N1 = N + 1;
    .print("⚠️ [SCHEDULER] Estanterías llenas para ", CId, ". Reintento ", N1, "/3...");
    -+shelf_retries(CId, N1);
    .wait(5000);
    !assign_shelf(CId).

-!assign_shelf(CId) : true <-
    .print("⚠️ [SCHEDULER] Estanterías llenas para ", CId, ". Reintento 1/3...");
    +shelf_retries(CId, 1);
    .wait(5000);
    !assign_shelf(CId).

// 3. Recibir estantería libre: si el contenedor fue aplastado, descartar
+free_shelf(CId, ShelfId) : container_broken(CId) <-
    .print("💥 [SCHEDULER] ", CId, " fue aplastado antes de asignar robot. Liberando estantería.");
    -free_shelf(CId, ShelfId);
    -pending_container(CId, _);
    .abolish(container_info(CId, _, _, _, _, _, _));
    .abolish(container_category(CId, _));
    .abolish(container_type(CId, _));
    .abolish(container_weight_category(CId, _));
    .abolish(container_size_category(CId, _));
    .abolish(shelf_retries(CId, _)).

// Recibir estantería libre y asignar la tarea (estantería + contenedor) al robot
+free_shelf(CId, ShelfId) : container_info(CId, W, H, Weight, Type, _, _) <-
    .print("Estantería: ", ShelfId, " asignada a ", CId);
    
    // Clasificación por tipo (urgent/fragile/standard)
    +container_type(CId, Type);

    // Clasificación por peso
    if (Weight <= 10) { 
        +container_weight_category(CId, light); 
    } elif (Weight <= 30) { 
        +container_weight_category(CId, medium); 
    } else { 
        +container_weight_category(CId, heavy); 
    };

    // Clasificación por tamaño
    if (W <= 1 & H <= 1) { 
        +container_size_category(CId, small); 
    } elif (W <= 1 & H <= 2) { 
        +container_size_category(CId, medium); 
    } else { 
        +container_size_category(CId, large); 
    };

    // Asignar a robot apropiado según su capacidad (peso Y tamaño)
    if (Weight <= 10 & W <= 1 & H <= 1) {
        .print("Asignando al robot ligero: ", CId);
        +container_category(CId, light);
        ?containers_light(LL); // LL -> light list
        -containers_light(LL); 
        +containers_light([CId|LL]);
        +assigned(robot_light, CId, ShelfId);
        +task_history(robot_light, CId, ShelfId);
        .send(robot_light, tell, task(CId, ShelfId));
        .print("[TRACE] assigned: robot_light -> ", CId, " -> ", ShelfId, " [", Type, "]");
    } elif (Weight <= 30 & W <= 1 & H <= 2) {
        .print("Asignando al robot mediano: ", CId);
        +container_category(CId, medium);
        ?containers_medium(ML); // ML -> medium list
        -containers_medium(ML); 
        +containers_medium([CId|ML]);
        +assigned(robot_medium, CId, ShelfId);
        +task_history(robot_medium, CId, ShelfId);
        .send(robot_medium, tell, task(CId, ShelfId));
        .print("[TRACE] assigned: robot_medium -> ", CId, " -> ", ShelfId, " [", Type, "]");
    } else {
        .print("Asignando al robot pesado: ", CId);
        +container_category(CId, heavy);
        ?containers_heavy(HL); // HL -> heavy list
        -containers_heavy(HL); 
        +containers_heavy([CId|HL]);
        +assigned(robot_heavy, CId, ShelfId);
        +task_history(robot_heavy, CId, ShelfId);
        .send(robot_heavy, tell, task(CId, ShelfId));
        .print("[TRACE] assigned: robot_heavy -> ", CId, " -> ", ShelfId, " [", Type, "]");
    };
    .count(task_history(_, _, _), T);
    -total_tasks_assigned(_);
    +total_tasks_assigned(T).

// 4. Manejo de fallos reportados por robots
+task_failed(CId)[source(Robot)] : container_broken(CId) <-
    .print("💥 [SCHEDULER] ", CId, " fue aplastado. Limpiando creencias...");
    -assigned(Robot, CId, _);
    -task_failed(CId)[source(Robot)];
    -pending_container(CId, _);
    .abolish(container_info(CId, _, _, _, _, _, _));
    .abolish(container_category(CId, _));
    .abolish(container_type(CId, _));
    .abolish(container_weight_category(CId, _));
    .abolish(container_size_category(CId, _));
    .abolish(shelf_retries(CId, _)).

+task_failed(CId)[source(Robot)] : true <-
    .print("⚠️ ", Robot, " reportó fallo con ", CId, ". Reasignando...");
    -assigned(Robot, CId, _);
    -task_failed(CId)[source(Robot)];
    // Borrar percepto anterior para que el nuevo dispare +container_info
    .abolish(container_info(CId, _, _, _, _, _, _));
    get_container_info(CId).

// Fallback: si get_container_info falla (container ya no existe), limpiar
-!task_failed(CId) : true <-
    .print("💥 [SCHEDULER] ", CId, " ya no existe. Limpiando creencias...");
    -pending_container(CId, _);
    .abolish(container_info(CId, _, _, _, _, _, _));
    .abolish(container_category(CId, _));
    .abolish(container_type(CId, _));
    .abolish(container_weight_category(CId, _));
    .abolish(container_size_category(CId, _));
    .abolish(shelf_retries(CId, _)).

// 5. Trazabilidad: Almacenamiento confirmado
+container_stored(CId, ShelfId)[source(Robot)] : true <-
    .print("✨ [TRACE] ", Robot, " almacenó ", CId, " en ", ShelfId);
    -assigned(Robot, CId, ShelfId);
    -container_stored(CId, ShelfId)[source(Robot)].

// 6. Trazabilidad: Errores reportados
+container_error(CId, ErrorType)[source(Robot)] : true <-
    .print("❌ [TRACE] Error reportado por ", Robot, " para ", CId, ": ", ErrorType);
    -assigned(Robot, CId, _);
    -container_error(CId, ErrorType)[source(Robot)].
