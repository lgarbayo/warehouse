/*******************************************************************************
 * ROBOT MEDIO - Sistema de Gestión Logística de Almacén
 * 
 * Universidad de Vigo - Sistemas Inteligentes
 * Curso 2025-2026
 * 
 * CAPACIDADES:
 *   - Peso máximo: 30 kg
 *   - Tamaño máximo: 1×2
 *   - Velocidad: Media (2)
 * 
 ******************************************************************************/

/* Estado inicial del robot */
state(idle).         // Estados posibles: idle, moving, picking, carrying, dropping
position(2,3).       // Posición inicial
carrying(none).      // Contenedor que está cargando

/* ============================================================================
 * PLANES PRINCIPALES
 * ============================================================================ */
!start.

// Plan inicial: Arrancar el robot y hacer pruebas de movimiento
+!start : true <-
    .print("🤖 Robot medio iniciado - Capacidad: 30kg, 1x2");
   // .print("🔍 Iniciando secuencia de prueba de movimientos...");
  //  -+state(testing);
  //  !test_movement;
    !work_cycle.

// Secuencia de prueba de movimientos (ruta diferente al robot ligero)
+!test_movement : true <-
    .print("📍 Posición inicial: (2,3)");
    .wait(1500);
    
    .print("➡️  Movimiento 1: Ir al área de entrada (2,1)");
    move_to(2, 1);
    .wait(2500);
    
    .print("➡️  Movimiento 2: Patrol por área de clasificación (6,1)");
    move_to(6, 1);
    .wait(2500);
    
    .print("➡️  Movimiento 3: Ir a zona de estanterías medianas (13,7)");
    move_to(13, 7);
    .wait(2500);
    
    .print("➡️  Movimiento 4: Explorar zona central (10,5)");
    move_to(10, 5);
    .wait(2500);
    
    .print("➡️  Movimiento 5: Regresar a zona intermedia (7,4)");
    move_to(7, 4);
    .wait(2500);
    
    .print("✅ Prueba de movimientos completada. Robot funcionando correctamente.");
    -+state(idle).

// Ciclo de trabajo principal
+!work_cycle : state(idle) <-
    .print("[MEDIUM] Esperando tarea del planificador central...");
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

+state(idle) : task(CId, ShelfId) <-
    .print("✅ Procesando tarea encolada: ", CId, " a ", ShelfId);
    -task(CId, ShelfId)[source(scheduler)]; // Consumir creencia inmediatamente
    accept_task(CId);
    -+state(working);
    -+carrying(CId);
    !execute_task(CId, ShelfId).

// Ejecutar la tarea completa
+!execute_task(CId, ShelfId) : true <-
    .print("🚀 Iniciando tarea: ", CId);
    
    // Fase 1: Localizar y navegar al contenedor
    .print("📍 Fase 1: Localizando contenedor ", CId);
    move_to_container(CId);
    .wait(600);

    // Fase 2: Recoger el contenedor
    .print("📦 Fase 2: Recogiendo contenedor ", CId);
    -+state(picking);
    pickup(CId);
    .wait(600);

    // Fase 3: Navegar hacia la estantería
    .print("🚚 Fase 3: Transportando a estantería ", ShelfId);
    -+state(carrying);
    move_to_shelf(ShelfId);
    
    // Fase 4: Depositar el contenedor
    .print("📥 Fase 4: Depositando en ", ShelfId);
    -+state(dropping);
    drop_at(ShelfId);
    .wait(600);
    
    // Fase 5: Completar y volver a idle
    .print("✨ Tarea completada: ", CId);
    -+state(idle);
    -+carrying(none).


/* ============================================================================
 * MANEJO DE ERRORES Y FALLOS DE PLANES
 * ============================================================================ */

// Plan de fallo para execute_task: esencial según DEBUGGING.md
// Se activa cuando una acción dentro de execute_task falla (pickup, drop_at...)
-!execute_task(CId, ShelfId) : true <-
    .print("⚠️ Fallo en execute_task para ", CId, ". Limpiando estado...");
    .wait(1500); // Pausa de seguridad
    -+state(idle);
    -+carrying(none);
    release_task(CId);
    .send(scheduler, tell, task_failed(CId)).

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
    .wait(1000).

+error(too_far, Data) : true <-
    .my_name(Me);
    .print("⚠️ [MEDIUM] Demasiado lejos: ", Data, ". Limpiando estado...");
    .send(supervisor, tell, robot_error(Me, too_far, Data));
    -+state(idle);
    -+carrying(none).

+error(route_blocked, Data) : true <-
    .my_name(Me);
    .print("⚠️ [MEDIUM] Ruta bloqueada: ", Data, ". Limpiando estado...");
    .send(supervisor, tell, robot_error(Me, route_blocked, Data));
    -+state(idle);
    -+carrying(none).

+error(path_blocked, Data) : true <-
    .my_name(Me);
    .print("⚠️ [MEDIUM] Camino bloqueado: ", Data, ". Limpiando estado...");
    .send(supervisor, tell, robot_error(Me, path_blocked, Data));
    -+state(idle);
    -+carrying(none).

+error(illegal_move, Data) : true <-
    .my_name(Me);
    .print("⚠️ [MEDIUM] Movimiento ilegal: ", Data, ". Limpiando estado...");
    .send(supervisor, tell, robot_error(Me, illegal_move, Data));
    -+state(idle);
    -+carrying(none).

+error(robot_not_found, Data) : true <-
    .my_name(Me);
    .print("⚠️ [MEDIUM] Robot no encontrado: ", Data, ". Limpiando estado...");
    .send(supervisor, tell, robot_error(Me, robot_not_found, Data));
    -+state(idle);
    -+carrying(none).

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

+picked(CId) : true <-
    .print("✓ Contenedor ", CId, " recogido correctamente").

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

