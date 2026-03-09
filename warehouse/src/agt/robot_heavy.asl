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
    .print("🔍 Iniciando secuencia de prueba de movimientos (más lento)...");
    -+state(testing);
    !test_movement;
    !work_cycle.

// Secuencia de prueba de movimientos (más lento, zonas de estanterías grandes)
+!test_movement : true <-
    .print("📍 Posición inicial: (3,3)");
    .wait(2000);
    
    .print("➡️  Movimiento 1: Aproximación cuidadosa al área de entrada (2,2)");
    move_to(2, 2);
    .wait(3000);
    
    .print("➡️  Movimiento 2: Navegar a zona central (8,6)");
    move_to(8, 6);
    .wait(3000);
    
    .print("➡️  Movimiento 3: Ir a zona de estanterías GRANDES (12,11)");
    move_to(12, 11);
    .wait(3000);
    
    .print("➡️  Movimiento 4: Explorar más estanterías grandes (14,10)");
    move_to(14, 10);
    .wait(3000);
    
    .print("➡️  Movimiento 5: Retornar a zona segura (6,6)");
    move_to(6, 6);
    .wait(3000);
    
    .print("✅ [HEAVY] Prueba de movimientos completada. Robot pesado funcionando.");
    -+state(idle).

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
    -+state(working);
    -+carrying(CId);
    !execute_task(CId, ShelfId).

+task(CId, ShelfId) : not state(idle) <-
    .print("⚠️ [HEAVY] Ocupado con carga pesada, rechazando: ", CId).

// Ejecutar la tarea completa - movimientos más lentos pero precisos
+!execute_task(CId, ShelfId) : true <-
    .print("🚀 [HEAVY] Iniciando transporte de carga pesada: ", CId);
    
    // Fase 1: Aproximación cuidadosa al área de entrada
    .print("📍 [HEAVY] Fase 1: Aproximación al área de entrada");
    move_to(1, 1);
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

// Navegar a la estantería (zona de estanterías grandes)
+!navigate_to_shelf(ShelfId) : true <-
    // Estanterías grandes están en y=10-12
    move_to(12, 10);
    .wait(1000);  // Movimiento más lento por el peso
    move_to(14, 11);
    .wait(1000).

/* ============================================================================
 * MANEJO DE ERRORES
 * ============================================================================ */

+error(container_too_heavy, Data) : carrying(CId) <-
    .print("❌ [HEAVY] ERROR CRÍTICO: Contenedor excede capacidad máxima - ", Data);
    .print("⚠️ Este es el robot más fuerte, contenedor imposible de transportar");
    -+state(idle);
    -+carrying(none);
    -task(CId, _).

+error(container_too_big, Data) : carrying(CId) <-
    .print("❌ [HEAVY] ERROR: Contenedor muy grande - ", Data);
    -+state(idle);
    -+carrying(none);
    -task(CId, _).

+error(ErrorType, Data) : true <-
    .print("⚠️ [HEAVY] Error detectado: ", ErrorType, " - ", Data);
    -+state(idle);
    -+carrying(none).

+picked(CId) : true <-
    .print("✓ [HEAVY] Carga pesada ", CId, " asegurada correctamente").

+stored(CId, ShelfId) : true <-
    .print("✓ [HEAVY] Carga pesada ", CId, " almacenada en ", ShelfId).
