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
  //  -+state(testing);
   // !test_movement;
    !work_cycle.

// Secuencia de prueba de movimientos
+!test_movement : true <-
    .print("📍 Posición inicial: (1,3)");
    .wait(1000);
    
    .print("➡️  Movimiento 1: Ir al área de entrada (1,1)");
    move_to(1, 1);
    .wait(2000);
    
    .print("➡️  Movimiento 2: Ir al área de clasificación (5,1)");
    move_to(5, 1);
    .wait(2000);
    
    .print("➡️  Movimiento 3: Ir a zona de estanterías pequeñas (12,3)");
    move_to(12, 3);
    .wait(2000);
    
    .print("➡️  Movimiento 4: Explorar más estanterías (16,3)");
    move_to(16, 3);
    .wait(2000);
    
    .print("➡️  Movimiento 5: Volver a posición intermedia (8,5)");
    move_to(8, 5);
    .wait(2000);
    
    .print("✅ Prueba de movimientos completada. Robot funcionando correctamente.");
    -+state(idle).

// Ciclo de trabajo principal
+!work_cycle : state(idle) <-
    .print("Solicitando nueva tarea...");
    request_task;
    .wait(3000);  // Esperar 3 segundos antes de solicitar otra
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
    accept_task(CId);
    -+state(working);
    -+carrying(CId);
    !execute_task(CId, ShelfId).

+task(CId, ShelfId) : not state(idle) <-
    .print("⚠️ Ocupado, no puedo aceptar tarea: ", CId).

// Ejecutar la tarea completa
+!execute_task(CId, ShelfId) : true <-
    .print("🚀 Iniciando tarea: ", CId);
    
    // Fase 1: Ir al área de entrada (donde están los contenedores)
    .print("📍 Fase 1: Moviéndose al área de entrada");
    move_to(1, 1);
    .wait(500);
    
    // Fase 2: Recoger el contenedor
    .print("📦 Fase 2: Recogiendo contenedor ", CId);
    -+state(picking);
    pickup(CId);
    .wait(500);
    
    // Fase 3: Navegar hacia la estantería
    .print("🚚 Fase 3: Transportando a estantería ", ShelfId);
    -+state(carrying);
    !navigate_to_shelf(ShelfId);
    
    // Fase 4: Depositar el contenedor
    .print("📥 Fase 4: Depositando en ", ShelfId);
    -+state(dropping);
    drop_at(ShelfId);
    .wait(500);
    
    // Fase 5: Completar y volver a idle
    .print("✨ Tarea completada: ", CId);
    -+state(idle);
    -+carrying(none);
    .abolish(task(CId, ShelfId)).

// LIGHT: se coloca en (SX+2, SY-1) — encima del shelf, dist=3, celda distinta
+!navigate_to_shelf(ShelfId) : true <-
    get_shelf_position(ShelfId);
    ?shelf_pos(ShelfId, SX, SY);
    !try_move_to_shelf(SX + 2, SY - 1).

+!try_move_to_shelf(X, Y) : true <-
    move_to(X, Y).

-!try_move_to_shelf(X, Y) : true <-
    .wait(2000);
    !try_move_to_shelf(X, Y).

/* ============================================================================
 * MANEJO DE ERRORES Y FALLOS DE PLANES
 * ============================================================================ */

// Plan de fallo esencial (DEBUGGING.md): sin esto Jason no puede recuperarse
-!execute_task(CId, ShelfId) : true <-
    .print("⚠️ Fallo en execute_task para ", CId, ". Limpiando estado...");
    -+state(idle);
    -+carrying(none);
    release_task(CId);
    .abolish(task(CId, ShelfId)).

// Error al recoger contenedor (muy pesado o grande)
+error(container_too_heavy, Data) : carrying(CId) <-
    .print("❌ ERROR: Contenedor muy pesado - ", Data);
    -+state(idle);
    -+carrying(none);
    .abolish(task(CId, _)).

+error(container_too_big, Data) : carrying(CId) <-
    .print("❌ ERROR: Contenedor muy grande - ", Data);
    -+state(idle);
    -+carrying(none);
    .abolish(task(CId, _)).

+error(destination_conflict, Data) : true <-
    .print("⚠️ Conflicto de destino, esperando y reintentando...");
    .wait(800).

// Error general
+error(ErrorType, Data) : true <-
    .print("⚠️ Error detectado: ", ErrorType, " - ", Data);
    -+state(idle);
    -+carrying(none).

// Confirmación de recogida exitosa
+picked(CId) : true <-
    .print("✓ Contenedor ", CId, " recogido correctamente").

// Confirmación de almacenamiento exitoso
+stored(CId, ShelfId) : true <-
    .print("✓ Contenedor ", CId, " almacenado en ", ShelfId).