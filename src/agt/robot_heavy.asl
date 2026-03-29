/*******************************************************************************
 * ROBOT PESADO - Sistema de Gestión Logística de Almacén
 * 
 * Universidad de Vigo - Sistemas Inteligentes
 * Curso 2025-2026
 * 
 * CAPACIDADES:
 *   - Peso máximo: 100 kg
 *   - Tamaño máximo: 2×3
 *   - Velocidad: Baja (1)
 * 
 ******************************************************************************/

/* Estado inicial del robot */
state(idle).         // Estados posibles: idle, moving, picking, carrying, dropping
position(3,3).       // Posición inicial
carrying(none).      // Contenedor que está cargando

/* CARACTERÍSTICAS ESPECIALES:
 * - Único robot capaz de manejar contenedores > 30kg
 * - Puede transportar contenedores hasta 2×3
 * - Velocidad baja: debe optimizar rutas y minimizar movimientos
 * - Es un recurso escaso: debe usarse eficientemente
 */

/* ============================================================================
 * PLANES PRINCIPALES
 * ============================================================================ */

!start.

// Plan inicial: Arrancar el robot y hacer pruebas de movimiento
+!start : true <-
    .print("🤖 Robot pesado iniciado - Capacidad: 100kg, 2x3 [ESPECIALIZADO]");
    -+state(idle);
    !work_cycle.

// Ciclo de trabajo principal - más selectivo, solo grandes cargas
+!work_cycle : state(idle) <-
    .print("[HEAVY] Esperando tarea del planificador central...");
    .wait(4000);  // Esperar más tiempo (robot más lento)
    !work_cycle.

+!work_cycle : not state(idle) <-
    .wait(3000);
    !work_cycle.

/* ============================================================================
 * MANEJO DE TAREAS ASIGNADAS
 * ============================================================================ */

// Recibir tarea del scheduler
+task(CId, ShelfId) : state(idle) <-
    .print("✅ [HEAVY] Tarea especializada asignada: ", CId, " a ", ShelfId);
    -task(CId, ShelfId)[source(scheduler)]; // Consumir creencia inmediatamente
    // Marcar robot como busy en Java para evitar doble asignación
    accept_task(CId);
    -+state(working);
    -+carrying(CId);
    !execute_task(CId, ShelfId).

+task(CId, ShelfId) : not state(idle) <-
    .print("⚠️ [HEAVY] Ocupado con carga pesada, encolando: ", CId).

// La cola se procesa via !check_queue al final de cada tarea

// Ejecutar la tarea completa - movimientos más lentos pero precisos
+!execute_task(CId, ShelfId) : true <-
    .print("🚀 [HEAVY] Iniciando transporte de carga pesada: ", CId);
    
    // Fase 1: Localizar y navegar al contenedor pesado
    .print("📍 [HEAVY] Fase 1: Localizando contenedor ", CId);
    move_to_container(CId);
    .wait(1000);

    // Fase 2: Recoger el contenedor pesado
    .print("📦 [HEAVY] Fase 2: Recogiendo contenedor pesado ", CId);
    -+state(picking);
    pickup(CId);
    .wait(1000);

    // Fase 3: Transporte lento pero seguro
    .print("🚚 [HEAVY] Fase 3: Transportando carga pesada a ", ShelfId);
    -+state(carrying);
    move_to_shelf(ShelfId);
    
    // Fase 4: Depositar con cuidado
    .print("📥 [HEAVY] Fase 4: Depositando carga en ", ShelfId);
    -+state(dropping);
    drop_at(ShelfId);
    .wait(1000);
    
    // Fase 5: Completar y verificar cola
    .print("✨ [HEAVY] Tarea especializada completada: ", CId);
    -+carrying(none);
    !check_queue.


/* ============================================================================
 * MANEJO DE ERRORES Y FALLOS DE PLANES
 * ============================================================================ */

// Plan de fallo para execute_task: se ejecuta cuando una acción dentro falla
// Según DEBUGGING.md: esencial para que Jason no quede sin manejador
-!execute_task(CId, ShelfId) : true <-
    .print("⚠️ [HEAVY] Fallo en execute_task para ", CId, ". Limpiando estado...");
    .wait(2000); // Robot pesado es más reflexivo
    -+carrying(none);
    release_task(CId);
    .send(scheduler, tell, task_failed(CId));
    !check_queue.

// Verificar si hay más tareas encoladas antes de volver a idle
+!check_queue : task(CId, ShelfId) <-
    .print("✅ [HEAVY] Procesando tarea encolada: ", CId, " a ", ShelfId);
    -task(CId, ShelfId)[source(scheduler)];
    accept_task(CId);
    -+state(working);
    -+carrying(CId);
    !execute_task(CId, ShelfId).

+!check_queue : not task(_, _) & position(InitX, InitY) <-
    return_to_base(InitX, InitY);
    -+state(idle).

+error(container_too_heavy, Data) : carrying(CId) <-
    .print("❌ [HEAVY] ERROR CRÍTICO: Contenedor excede capacidad máxima - ", Data);
    .print("⚠️ Este es el robot más fuerte, contenedor imposible de transportar");
    .send(scheduler, tell, container_error(CId, container_too_heavy));
    .send(supervisor, tell, container_error(CId, container_too_heavy));
    -+state(idle);
    -+carrying(none);
    .abolish(task(CId, _)).

+error(container_too_big, Data) : carrying(CId) <-
    .print("❌ [HEAVY] ERROR: Contenedor muy grande - ", Data);
    .send(scheduler, tell, container_error(CId, container_too_big));
    .send(supervisor, tell, container_error(CId, container_too_big));
    -+state(idle);
    -+carrying(none);
    .abolish(task(CId, _)).

+error(destination_conflict, Data) : true <-
    .my_name(Me);
    .print("⚠️ [HEAVY] Conflicto de destino, esperando y reintentando...");
    .send(supervisor, tell, robot_error(Me, destination_conflict, Data));
    .wait(1500).

+error(too_far, Data) : true <-
    .my_name(Me);
    .print("⚠️ [HEAVY] Demasiado lejos: ", Data, ". Limpiando estado...");
    .send(supervisor, tell, robot_error(Me, too_far, Data));
    -+state(idle);
    -+carrying(none).

+error(route_blocked, Data) : true <-
    .my_name(Me);
    .print("⚠️ [HEAVY] Ruta bloqueada: ", Data, ". Limpiando estado...");
    .send(supervisor, tell, robot_error(Me, route_blocked, Data));
    -+state(idle);
    -+carrying(none).

+error(path_blocked, Data) : true <-
    .my_name(Me);
    .print("⚠️ [HEAVY] Camino bloqueado: ", Data, ". Limpiando estado...");
    .send(supervisor, tell, robot_error(Me, path_blocked, Data));
    -+state(idle);
    -+carrying(none).

+error(illegal_move, Data) : true <-
    .my_name(Me);
    .print("⚠️ [HEAVY] Movimiento ilegal: ", Data, ". Limpiando estado...");
    .send(supervisor, tell, robot_error(Me, illegal_move, Data));
    -+state(idle);
    -+carrying(none).

+error(robot_not_found, Data) : true <-
    .my_name(Me);
    .print("⚠️ [HEAVY] Robot no encontrado: ", Data, ". Limpiando estado...");
    .send(supervisor, tell, robot_error(Me, robot_not_found, Data));
    -+state(idle);
    -+carrying(none).

+error(ErrorType, Data) : carrying(CId) <-
    .print("⚠️ [HEAVY] Error detectado: ", ErrorType, " - ", Data);
    .send(scheduler, tell, container_error(CId, ErrorType));
    .send(supervisor, tell, container_error(CId, ErrorType));
    -+state(idle);
    -+carrying(none).

+error(ErrorType, Data) : true <-
    .print("⚠️ [HEAVY] Error detectado: ", ErrorType, " - ", Data);
    -+state(idle);
    -+carrying(none).

+picked(CId) : true <-
    .print("✓ [HEAVY] Carga pesada ", CId, " asegurada correctamente").

+stored(CId, ShelfId) : true <-
    .print("✓ [HEAVY] Carga pesada ", CId, " almacenada en ", ShelfId);
    .send(scheduler, tell, container_stored(CId, ShelfId));
    .send(supervisor, tell, container_stored(CId, ShelfId)).

/* ============================================================================
 * NOTIFICACIÓN DE ESTADO AL PLANIFICADOR
 * ============================================================================ */

+state(working) : true <-
    .my_name(Me);
    .send(supervisor, tell, robot_state_change(Me, working)).

+state(idle) : not task(_, _) <-
    .my_name(Me);
    .send(supervisor, tell, robot_state_change(Me, idle)).
