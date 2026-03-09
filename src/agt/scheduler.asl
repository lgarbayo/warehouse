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

// 1. Reaccionar a nuevo contenedor
+new_container(CId) : true <-
    .print("Nuevo contenedor: ", CId);
    get_container_info(CId).

// 2. Recibir info, clasificar y buscar estantería para contenedor
+container_info(CId, W, H, Weight, Type) : true <-
    .print("Info: ", CId, " - ", Weight, "kg. Solicitando estantería...");
    +pending_container(CId, Weight);
    !assign_shelf(CId).

+!assign_shelf(CId) : true <-
    get_free_shelf(CId).

-!assign_shelf(CId) : true <-
    .print("⚠️ [SCHEDULER] Estanterías llenas para ", CId, ". Reintentando en 5s...");
    .wait(5000);
    !assign_shelf(CId).

// 3. Recibir estantería libre y asignar la tarea (estantería + contenedor) al robot
+free_shelf(CId, ShelfId) : container_info(CId, W, H, Weight, Type) <-
    .print("Estantería: ", ShelfId, " asignada a ", CId);
    
    // Asignar a robot apropiado según su capacidad (peso Y tamaño)
    if (Weight <= 10 & W <= 1 & H <= 1) {
        .print("Asignando al robot ligero: ", CId);
        .send(robot_light, tell, task(CId, ShelfId));
    } else {
        if (Weight <= 30 & W <= 1 & H <= 2) {
            .print("Asignando al robot mediano: ", CId);
            .send(robot_medium, tell, task(CId, ShelfId));
        } else {
            .print("Asignando al robot pesado: ", CId);
            .send(robot_heavy, tell, task(CId, ShelfId));
        }
    }.

// 4. Manejo de fallos reportados por robots
+task_failed(CId)[source(Robot)] : true <-
    .print("⚠️ ", Robot, " reportó fallo con ", CId, ". Reasignando...");
    -task_failed(CId)[source(Robot)];
    // Volvemos a pedir info para reiniciar el ciclo de asignación
    get_container_info(CId).
