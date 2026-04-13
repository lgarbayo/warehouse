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

/* Categorías de estanterías — el scheduler razona sobre esto sin delegar al entorno.
 * shelf_available(ShelfId) llega como percepción del entorno y se retira cuando
 * la estantería está llena. La decisión de cuál usar es del agente. */
shelf_category("shelf_1", light).
shelf_category("shelf_2", light).
shelf_category("shelf_3", light).
shelf_category("shelf_4", light).
shelf_category("shelf_5", medium).
shelf_category("shelf_6", medium).
shelf_category("shelf_7", medium).
shelf_category("shelf_8", heavy).
shelf_category("shelf_9", heavy).

// 1. Reaccionar a nuevo contenedor.
// Se usa un goal intermedio (!process_new_container) en lugar de procesar
// directamente en el trigger +new_container. Esto permite que el plan de fallo
// -!process_new_container capture el caso en que el contenedor es aplastado
// entre su aparición y su procesamiento por el scheduler. Con un trigger de
// creencia (+new_container) no es posible añadir un manejador de fallo.
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

// El scheduler razona sobre qué estantería usar consultando sus propias creencias:
// shelf_category (estática), shelf_available y shelf_occupancy (percepciones del entorno).
// Jason prueba los planes en orden: primero la categoría preferida; si no hay espacio,
// cae al siguiente plan (fallback natural de Jason).
//
// La guardia verifica que EXISTE al menos una estantería de la categoría deseada
// (ExS vincula la misma variable en shelf_category y shelf_available).
// El cuerpo recoge TODAS las disponibles con su ocupación actual, y elige
// la menos cargada replicando el criterio de findBestShelf pero sin código en el entorno.

// Contenedor ligero → estantería pequeña (fallback a mediana/grande si llenas)
+!assign_shelf(CId) :
    not container_broken(CId) &
    container_info(CId, W, H, Weight, _, _, _) &
    not (Weight > 10) & not (W > 1) & not (H > 1) &
    shelf_category(ExS, light) & shelf_available(ExS) <-
    !pick_least_occupied(CId, light).

// Contenedor mediano → estantería mediana (fallback a grande si llenas)
+!assign_shelf(CId) :
    not container_broken(CId) &
    container_info(CId, W, H, Weight, _, _, _) &
    not (Weight > 30) & not (W > 1) & not (H > 2) &
    shelf_category(ExS, medium) & shelf_available(ExS) <-
    !pick_least_occupied(CId, medium).

// Contenedor pesado/grande → estantería grande
+!assign_shelf(CId) :
    not container_broken(CId) &
    container_info(CId, _, _, _, _, _, _) &
    shelf_category(ExS, heavy) & shelf_available(ExS) <-
    !pick_least_occupied(CId, heavy).

// Fallback anti-starvation: categoría preferida llena pero hay espacio en otra.
// Reproduce el fallback de findBestShelf: elige la menos ocupada de todas las disponibles.
+!assign_shelf(CId) :
    not container_broken(CId) &
    container_info(CId, _, _, _, _, _, _) &
    shelf_available(_) <-
    .findall(pair(Occ, S), (shelf_available(S) & shelf_occupancy(S, Occ)), Pairs);
    .sort(Pairs, [pair(_, ShelfId)|_]);
    +free_shelf(CId, ShelfId).

// Selecciona la estantería menos ocupada de una categoría dada.
// Estrategia: recoger todos los pares (ocupación, id), ordenar por ocupación
// (Jason compara compound terms argumento a argumento: pair(0,...) < pair(15,...)),
// y tomar el primero — equivale al sorted(comparingDouble(occupancy)).get(0)
// del antiguo findBestShelf, pero razonado por el agente.
+!pick_least_occupied(CId, Cat) <-
    .findall(pair(Occ, S), (shelf_category(S, Cat) & shelf_available(S) & shelf_occupancy(S, Occ)), Pairs);
    .sort(Pairs, [pair(_, ShelfId)|_]);
    +free_shelf(CId, ShelfId).

// Ningún plan anterior aplicó → no hay estantería disponible → falla →
// dispara -!assign_shelf → lógica de reintento existente.

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
    
    // Clasificación multidimensional: tipo, peso y tamaño se almacenan como
    // creencias separadas para que el scheduler pueda consultarlas independientemente
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

    // Asignar a robot apropiado según su capacidad (peso Y tamaño).
    // ?containers_X(L) consulta la lista actual, se retira y se reinserta con CId
    // añadido al frente — patrón estándar en AgentSpeak para actualizar listas.
    if (Weight <= 10 & W <= 1 & H <= 1) {
        .print("Asignando al robot ligero: ", CId);
        +container_category(CId, light);
        ?containers_light(LL); // LL -> light list
        -containers_light(LL); 
        +containers_light([CId|LL]);
        // assigned: creencia transitoria: se elimina al confirmar o fallar la tarea
        // task_history: registro permanente para trazabilidad de auditoría
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
    .print("⚠️ ", Robot, " reportó fallo con ", CId, ". Reasignando en 10s...");
    -assigned(Robot, CId, _);
    -task_failed(CId)[source(Robot)];
    .wait(10000);   // Dar tiempo a que la zona de entrada se despeje antes de reasignar
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
