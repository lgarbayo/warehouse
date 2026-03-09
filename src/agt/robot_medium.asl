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
    
    // Fase 1: Ir al área de entrada
    // Usamos (0,1) para evitar conflicto de destino con robot_heavy que usa (2,1)
    .print("📍 Fase 1: Moviéndose al área de entrada");
    move_to(0, 1);
    .wait(600);  // Robot medio es más lento
    
    // Fase 2: Recoger el contenedor
    .print("📦 Fase 2: Recogiendo contenedor ", CId);
    -+state(picking);
    pickup(CId);
    .wait(600);
    
    // Fase 3: Navegar hacia la estantería
    .print("🚚 Fase 3: Transportando a estantería ", ShelfId);
    -+state(carrying);
    !navigate_to_shelf(ShelfId);
    
    // Fase 4: Depositar el contenedor
    .print("📥 Fase 4: Depositando en ", ShelfId);
    -+state(dropping);
    drop_at(ShelfId);
    .wait(600);
    
    // Fase 5: Completar y volver a idle
    .print("✨ Tarea completada: ", CId);
    -+state(idle);
    -+carrying(none);
    -task(CId, ShelfId).

// MEDIUM: se coloca en (SX+1, SY-1) — encima del shelf, dist=2, celda distinta a heavy
+!navigate_to_shelf(ShelfId) : true <-
    get_shelf_position(ShelfId);
    ?shelf_pos(ShelfId, SX, SY);
    !try_move_to_shelf(SX + 1, SY - 1).

+!try_move_to_shelf(X, Y) : true <-
    move_to(X, Y).

-!try_move_to_shelf(X, Y) : true <-
    .wait(2000);
    !try_move_to_shelf(X, Y).

/* ============================================================================
 * MANEJO DE ERRORES Y FALLOS DE PLANES
 * ============================================================================ */

// Plan de fallo para execute_task: esencial según DEBUGGING.md
// Se activa cuando una acción dentro de execute_task falla (pickup, drop_at...)
-!execute_task(CId, ShelfId) : true <-
    .print("⚠️ Fallo en execute_task para ", CId, ". Limpiando estado...");
    -+state(idle);
    -+carrying(none);
    release_task(CId);
    .abolish(task(CId, ShelfId)).

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
    .wait(1000).

+error(ErrorType, Data) : true <-
    .print("⚠️ Error detectado: ", ErrorType, " - ", Data);
    -+state(idle);
    -+carrying(none).

+picked(CId) : true <-
    .print("✓ Contenedor ", CId, " recogido correctamente").

+stored(CId, ShelfId) : true <-
    .print("✓ Contenedor ", CId, " almacenado en ", ShelfId).

