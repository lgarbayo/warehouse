/*******************************************************************************
 * ROBOT LIGERO - Sistema de Gestión Logística de Almacén
 * 
 * Universidad de Vigo - Sistemas Inteligentes
 * Curso 2025-2026
 * 
 * CAPACIDADES:
 *   - Peso máximo: 10 kg
 *   - Tamaño máximo: 1×1
 *   - Velocidad: Alta (3)
 * 
 ******************************************************************************/

/* ============================================================================
 * CREENCIAS INICIALES
 * ============================================================================
 * Las creencias iniciales se proporcionan desde el archivo .mas2j
 * - robot_type(light): tipo de robot
 * - max_weight(10): peso máximo que puede cargar
 * - max_size(1,1): tamaño máximo de contenedor
 */

/* Estado inicial del robot */
state(idle).         // Estados posibles: idle, moving, picking, carrying, dropping
position(1,3).       // Posición inicial
carrying(none).      // Contenedor que está cargando

/* ============================================================================
 * PLANES PRINCIPALES
 * ============================================================================ */

!start.

// Plan inicial: Arrancar el robot y hacer pruebas de movimiento
+!start : true <-
    .print("🤖 Robot ligero iniciado - Capacidad: 10kg, 1x1");
    // .print("🔍 Iniciando secuencia de prueba de movimientos...");
    // -+state(testing);
    // !test_movement;
    !work_cycle.

// Ciclo de trabajo principal
+!work_cycle : state(idle) <-
    .print("[LIGHT] Esperando tarea del planificador central...");
    .wait(3000);  // Esperar 3 segundos
    !work_cycle.

+!work_cycle : not state(idle) <-
    .wait(2000);
    !work_cycle.

/* ============================================================================
 * MANEJO DE TAREAS ASIGNADAS
 * ============================================================================ */

// Recibir tarea del scheduler
+task(CId, ShelfId) : state(idle) <-
    .print("✅ Tarea asignada: Transportar ", CId, " a ", ShelfId);
    -task(CId, ShelfId)[source(scheduler)]; // Consumir creencia inmediatamente
    accept_task(CId);
    -+state(working);
    -+carrying(CId);
    !execute_task(CId, ShelfId).

+task(CId, ShelfId) : not state(idle) <-
    .print("⚠️ Ocupado, encolando tarea: ", CId).

// La cola se procesa via !check_queue al final de cada tarea

// Ejecutar la tarea completa
+!execute_task(CId, ShelfId) : true <-
    .print("🚀 Iniciando tarea: ", CId);
    
    // Fase 1: Localizar y navegar al contenedor
    .print("📍 Fase 1: Localizando contenedor ", CId);
    move_to_container(CId);
    .wait(500);

    // Fase 2: Recoger el contenedor
    .print("📦 Fase 2: Recogiendo contenedor ", CId);
    -+state(picking);
    pickup(CId);
    .wait(500);

    // Fase 3: Navegar hacia la estantería
    .print("🚚 Fase 3: Transportando a estantería ", ShelfId);
    -+state(carrying);
    move_to_shelf(ShelfId);
    
    // Fase 4: Depositar el contenedor
    .print("📥 Fase 4: Depositando en ", ShelfId);
    -+state(dropping);
    drop_at(ShelfId);
    .wait(500);
    
    // Fase 5: Completar y verificar cola
    .print("✨ Tarea completada: ", CId);
    -+carrying(none);
    !check_queue.


/* ============================================================================
 * MANEJO DE ERRORES Y FALLOS DE PLANES
 * ============================================================================ */

// Plan de fallo esencial (DEBUGGING.md): sin esto Jason no puede recuperarse
-!execute_task(CId, ShelfId) : true <-
    .print("⚠️ Fallo en execute_task para ", CId, ". Limpiando estado...");
    .wait(1500); // Pausa de seguridad para evitar "tweaking"
    -+carrying(none);
    release_task(CId);
    .send(scheduler, tell, task_failed(CId));
    !check_queue.

// Verificar si hay más tareas encoladas antes de volver a idle
+!check_queue : task(CId, ShelfId) <-
    .print("✅ Procesando tarea encolada: ", CId, " a ", ShelfId);
    -task(CId, ShelfId)[source(scheduler)];
    accept_task(CId);
    -+state(working);
    -+carrying(CId);
    !execute_task(CId, ShelfId).

+!check_queue : not task(_, _) & position(InitX, InitY) <-
    return_to_base(InitX, InitY);
    -+state(idle).

// Error al recoger contenedor (muy pesado o grande)
+error(container_too_heavy, Data) : carrying(CId) <-
    .print("❌ ERROR: Contenedor muy pesado - ", Data);
    .send(scheduler, tell, container_error(CId, container_too_heavy));
    .send(supervisor, tell, container_error(CId, container_too_heavy));
    -+state(idle);
    -+carrying(none);
    .abolish(task(CId, _)).

+error(container_too_big, Data) : carrying(CId) <-
    .print("❌ ERROR: Contenedor muy grande - ", Data);
    .send(scheduler, tell, container_error(CId, container_too_big));
    .send(supervisor, tell, container_error(CId, container_too_big));
    -+state(idle);
    -+carrying(none);
    .abolish(task(CId, _)).

+error(destination_conflict, Data) : true <-
    .my_name(Me);
    .print("⚠️ Conflicto de destino, esperando y reintentando...");
    .send(supervisor, tell, robot_error(Me, destination_conflict, Data));
    .wait(800).

+error(too_far, Data) : true <-
    .my_name(Me);
    .print("⚠️ [LIGHT] Demasiado lejos: ", Data, ". Limpiando estado...");
    .send(supervisor, tell, robot_error(Me, too_far, Data));
    -+state(idle);
    -+carrying(none).

+error(route_blocked, Data) : true <-
    .my_name(Me);
    .print("⚠️ [LIGHT] Ruta bloqueada: ", Data, ". Limpiando estado...");
    .send(supervisor, tell, robot_error(Me, route_blocked, Data));
    -+state(idle);
    -+carrying(none).

+error(path_blocked, Data) : true <-
    .my_name(Me);
    .print("⚠️ [LIGHT] Camino bloqueado: ", Data, ". Limpiando estado...");
    .send(supervisor, tell, robot_error(Me, path_blocked, Data));
    -+state(idle);
    -+carrying(none).

+error(illegal_move, Data) : true <-
    .my_name(Me);
    .print("⚠️ [LIGHT] Movimiento ilegal: ", Data, ". Limpiando estado...");
    .send(supervisor, tell, robot_error(Me, illegal_move, Data));
    -+state(idle);
    -+carrying(none).

+error(robot_not_found, Data) : true <-
    .my_name(Me);
    .print("⚠️ [LIGHT] Robot no encontrado: ", Data, ". Limpiando estado...");
    .send(supervisor, tell, robot_error(Me, robot_not_found, Data));
    -+state(idle);
    -+carrying(none).

// Error general
+error(ErrorType, Data) : carrying(CId) <-
    .print("⚠️ Error detectado: ", ErrorType, " - ", Data);
    .send(scheduler, tell, container_error(CId, ErrorType));
    .send(supervisor, tell, container_error(CId, ErrorType));
    -+state(idle);
    -+carrying(none).

+error(ErrorType, Data) : true <-
    .print("⚠️ Error detectado: ", ErrorType, " - ", Data);
    -+state(idle);
    -+carrying(none).

// Confirmación de recogida exitosa
+picked(CId) : true <-
    .print("✓ Contenedor ", CId, " recogido correctamente").

// Confirmación de almacenamiento exitoso
+stored(CId, ShelfId) : true <-
    .print("✓ Contenedor ", CId, " almacenado en ", ShelfId);
    .send(scheduler, tell, container_stored(CId, ShelfId));
    .send(supervisor, tell, container_stored(CId, ShelfId)).

/* ============================================================================
 * NOTIFICACIÓN DE ESTADO AL SUPERVISOR
 * ============================================================================ */

+state(working) : true <-
    .my_name(Me);
    .send(supervisor, tell, robot_state_change(Me, working)).

+state(idle) : not task(_, _) <-
    .my_name(Me);
    .send(supervisor, tell, robot_state_change(Me, idle)).
