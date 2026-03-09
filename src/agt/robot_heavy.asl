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
    .print("[HEAVY] Solicitando tarea especializada...");
    request_task;
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
    // Marcar robot como busy en Java para evitar doble asignación
    accept_task(CId);
    -+state(working);
    -+carrying(CId);
    !execute_task(CId, ShelfId).

+task(CId, ShelfId) : not state(idle) <-
    .print("⚠️ [HEAVY] Ocupado con carga pesada, rechazando: ", CId).

// Ejecutar la tarea completa - movimientos más lentos pero precisos
+!execute_task(CId, ShelfId) : true <-
    .print("🚀 [HEAVY] Iniciando transporte de carga pesada: ", CId);
    
    // Fase 1: Aproximación cuidadosa al área de entrada
    // Usamos (2,1) para evitar conflicto de destino con robot_medium que usa (0,1)
    .print("📍 [HEAVY] Fase 1: Aproximación al área de entrada");
    move_to(2, 1);
    .wait(1000);  // Robot pesado es más lento
    
    // Fase 2: Recoger el contenedor pesado
    .print("📦 [HEAVY] Fase 2: Recogiendo contenedor pesado ", CId);
    -+state(picking);
    pickup(CId);
    .wait(1000);
    
    // Fase 3: Transporte lento pero seguro
    .print("🚚 [HEAVY] Fase 3: Transportando carga pesada a ", ShelfId);
    -+state(carrying);
    !navigate_to_shelf(ShelfId);
    
    // Fase 4: Depositar con cuidado
    .print("📥 [HEAVY] Fase 4: Depositando carga en ", ShelfId);
    -+state(dropping);
    drop_at(ShelfId);
    .wait(1000);
    
    // Fase 5: Completar y volver a idle
    .print("✨ [HEAVY] Tarea especializada completada: ", CId);
    -+state(idle);
    -+carrying(none);
    -task(CId, ShelfId).

// HEAVY: se coloca en (SX, SY-1) — celda inmediatamente encima del shelf, dist=1
+!navigate_to_shelf(ShelfId) : true <-
    get_shelf_position(ShelfId);
    ?shelf_pos(ShelfId, SX, SY);
    !try_move_to_shelf(SX, SY - 1).

+!try_move_to_shelf(X, Y) : true <-
    move_to(X, Y).

// Si move_to falla (destination_conflict), esperamos y reintentamos
-!try_move_to_shelf(X, Y) : true <-
    .wait(2000);
    !try_move_to_shelf(X, Y).

/* ============================================================================
 * MANEJO DE ERRORES Y FALLOS DE PLANES
 * ============================================================================ */

// Plan de fallo para execute_task: se ejecuta cuando una acción dentro falla
// Según DEBUGGING.md: esencial para que Jason no quede sin manejador
-!execute_task(CId, ShelfId) : true <-
    .print("⚠️ [HEAVY] Fallo en execute_task para ", CId, ". Limpiando estado...");
    -+state(idle);
    -+carrying(none);
    release_task(CId);
    .abolish(task(CId, ShelfId)).

+error(container_too_heavy, Data) : carrying(CId) <-
    .print("❌ [HEAVY] ERROR CRÍTICO: Contenedor excede capacidad máxima - ", Data);
    .print("⚠️ Este es el robot más fuerte, contenedor imposible de transportar");
    -+state(idle);
    -+carrying(none);
    .abolish(task(CId, _)).

+error(container_too_big, Data) : carrying(CId) <-
    .print("❌ [HEAVY] ERROR: Contenedor muy grande - ", Data);
    -+state(idle);
    -+carrying(none);
    .abolish(task(CId, _)).

+error(destination_conflict, Data) : true <-
    .print("⚠️ [HEAVY] Conflicto de destino, esperando y reintentando...");
    .wait(1500).

+error(too_far, Data) : true <-
    .print("⚠️ [HEAVY] Demasiado lejos: ", Data, ". Limpiando estado...");
    -+state(idle);
    -+carrying(none).

+error(ErrorType, Data) : true <-
    .print("⚠️ [HEAVY] Error detectado: ", ErrorType, " - ", Data);
    -+state(idle);
    -+carrying(none).

+picked(CId) : true <-
    .print("✓ [HEAVY] Carga pesada ", CId, " asegurada correctamente").

+stored(CId, ShelfId) : true <-
    .print("✓ [HEAVY] Carga pesada ", CId, " almacenada en ", ShelfId).
