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

+!start : true <-
    .print("🤖 Robot medio iniciado - Capacidad: 30kg, 1x2");
    !work_cycle.

// Ciclo de trabajo principal
+!work_cycle : state(idle) <-
    .print("[MEDIUM] Consultando scheduler para nueva tarea...");
    .send(scheduler, tell, request_task);
    .wait(3000);
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

    // Fase 1: Localizar y navegar al contenedor (hasta 3 reintentos con nav_target fresco)
    .print("📍 [MEDIUM] Fase 1: Localizando contenedor ", CId);
    !get_to_container(CId, 3);
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
    ?nav_target(TX2, TY2);
    !navigate(TX2, TY2);

    // Fase 4: Depositar el contenedor
    .print("📥 Fase 4: Depositando en ", ShelfId);
    -+state(dropping);
    drop_at(ShelfId);
    .wait(600);

    // Fase 5: Completar y verificar cola
    .print("✨ Tarea completada: ", CId);
    -+carrying(none);
    !check_queue.


/* ============================================================================
 * MANEJO DE ERRORES Y FALLOS DE PLANES
 * ============================================================================ */

// Estantería llena: llevar el contenedor a la zona de expansión (amarilla) en lugar
// de dejarlo en el pasillo. El robot sigue cargándolo tras el fallo de drop_at.
-!execute_task(CId, ShelfId) : error(shelf_full, _) & carrying(CId) <-
    .print("⚠️ [MEDIUM] Estantería llena, llevando ", CId, " a zona de expansión");
    .abolish(error(shelf_full, _));
    !go_to_expansion(CId);
    !check_queue.

+!go_to_expansion(CId) <-
    move_to_expansion;
    ?nav_target(TX, TY);
    !navigate(TX, TY);
    drop_in_expansion(CId);
    -+carrying(none);
    release_task(CId);
    .send(scheduler, tell, container_in_expansion(CId)).

-!go_to_expansion(CId) <-
    .print("⚠️ [MEDIUM] No se pudo llegar a expansión con ", CId, ". Liberando tarea.");
    -+carrying(none);
    release_task(CId);
    .send(scheduler, tell, task_failed(CId)).

// Plan de fallo para execute_task: esencial según DEBUGGING.md
-!execute_task(CId, ShelfId) : true <-
    .print("⚠️ [MEDIUM] Fallo en execute_task para ", CId, ". Limpiando estado...");
    -+carrying(none);
    release_task(CId);
    .send(scheduler, tell, task_failed(CId));
    .wait(5000);       // Esperar a que la zona de entrada se despeje
    !safe_return;      // Volver a base para salir de zona congestionada
    !check_queue.

// Navegar a la base de forma segura; si también falla, continuar igualmente
+!safe_return : position(InitX, InitY) <- !navigate(InitX, InitY).
-!safe_return : true <- true.

// Navegar hasta una celda adyacente al contenedor; reintenta hasta N veces
// recomputando nav_target (cubre: celda ocupada por nuevo contenedor mid-nav).
+!get_to_container(CId, N) : N > 0 <-
    move_to_container(CId);
    ?nav_target(TX, TY);
    !navigate(TX, TY).

-!get_to_container(CId, N) : N > 1 <-
    .print("⚠️ [MEDIUM] Reintentando nav a ", CId, " (", N, " intentos restantes)");
    .wait(5000);
    N1 = N - 1;
    !get_to_container(CId, N1).
// N <= 1: sin plan de fallo aplicable → goal falla → propaga a execute_task → -!execute_task

/* ============================================================================
 * CICLO OUTBOUND — extraer contenedor de estantería y llevar a zona de salida
 * ============================================================================ */

+outbound_available(CId, ShelfId, W, H, Weight) : state(idle) & max_weight(MaxW) & max_size(MaxDimW, MaxDimH)
                                                  & not (Weight > MaxW) & not (W > MaxDimW) & not (H > MaxDimH) <-
    .print("📤 [MEDIUM] Tomando outbound: ", CId, " de ", ShelfId);
    -outbound_available(CId, ShelfId, W, H, Weight)[source(scheduler)];
    accept_task(CId);
    -+state(working);
    -+carrying(CId);
    !execute_outbound_task(CId, ShelfId).

+outbound_available(CId, ShelfId, W, H, Weight) : not state(idle) & max_weight(MaxW) & max_size(MaxDimW, MaxDimH)
                                                  & not (Weight > MaxW) & not (W > MaxDimW) & not (H > MaxDimH) <-
    .print("⚠️ [MEDIUM] Ocupado, guardando outbound: ", CId).

+outbound_available(CId, ShelfId, W, H, Weight) : true <-
    -outbound_available(CId, ShelfId, W, H, Weight)[source(scheduler)].

+!execute_outbound_task(CId, ShelfId) : true <-
    .print("📤 [MEDIUM] Fase 1: Navegando a estantería ", ShelfId);
    move_to_shelf(ShelfId);
    ?nav_target(TX, TY);
    !navigate(TX, TY);

    .print("📦 [MEDIUM] Fase 2: Recogiendo de estantería ", ShelfId);
    -+state(picking);
    pickup_from_shelf(ShelfId, CId);
    .wait(600);

    .print("🚚 [MEDIUM] Fase 3: Navegando a zona outbound");
    -+state(carrying);
    move_to_outbound;
    ?nav_target(TX2, TY2);
    !navigate(TX2, TY2);

    .print("📤 [MEDIUM] Fase 4: Entregando contenedor");
    -+state(dropping);
    drop_in_outbound(CId);
    .wait(600);

    .print("✨ [MEDIUM] Outbound completado: ", CId);
    -+carrying(none);
    release_task(CId);
    .send(scheduler, tell, container_shipped(CId, ShelfId));
    !check_queue.

-!execute_outbound_task(CId, ShelfId) : true <-
    .print("⚠️ [MEDIUM] Fallo en tarea outbound: ", CId);
    -+carrying(none);
    release_task;
    .send(scheduler, tell, outbound_failed(CId, ShelfId));
    !check_queue.

+shipped(CId) : true <- true.

// Verificar si hay más tareas encoladas antes de volver a idle
+!check_queue : outbound_available(CId, ShelfId, W, H, Weight) & max_weight(MaxW) & max_size(MaxDimW, MaxDimH)
              & not (Weight > MaxW) & not (W > MaxDimW) & not (H > MaxDimH) <-
    .print("✅ [MEDIUM] Procesando outbound disponible: ", CId, " desde ", ShelfId);
    -outbound_available(CId, ShelfId, W, H, Weight)[source(scheduler)];
    accept_task(CId);
    -+state(working);
    -+carrying(CId);
    !execute_outbound_task(CId, ShelfId).

+!check_queue : task(CId, ShelfId) <-
    .print("✅ Procesando tarea encolada: ", CId, " a ", ShelfId);
    -task(CId, ShelfId)[source(scheduler)];
    accept_task(CId);
    -+state(working);
    -+carrying(CId);
    !execute_task(CId, ShelfId).

+!check_queue : not task(_, _) & not outbound_available(_, _, _, _, _) & position(InitX, InitY) <-
    .send(scheduler, tell, request_task);
    .wait(2000);
    if (task(CId, ShelfId)) {
        -task(CId, ShelfId)[source(scheduler)];
        accept_task(CId);
        -+state(working);
        -+carrying(CId);
        !execute_task(CId, ShelfId);
    } else {
        !navigate(InitX, InitY);
        -+state(idle);
    }.

-!check_queue : not task(_, _) & not outbound_available(_, _, _, _, _) <-
    .abolish(error(_, _));
    -+state(idle).

// Fallo al navegar a base pero hay tareas encoladas: procesar directamente
-!check_queue : task(CId, ShelfId) <-
    .print("⚠️ [MEDIUM] Fallo al navegar a base, procesando tarea encolada: ", CId);
    -task(CId, ShelfId)[source(scheduler)];
    accept_task(CId);
    -+state(working);
    -+carrying(CId);
    !execute_task(CId, ShelfId).

/* ============================================================================
 * NAVEGACIÓN AUTÓNOMA
 * El agente decide cada paso; Java solo ejecuta move_step(X,Y) como primitiva.
 * corridor_row(Y): filas libres de estanterías en la zona de almacenamiento.
 * ============================================================================ */

corridor_row(1). corridor_row(4). corridor_row(5).
corridor_row(8). corridor_row(9). corridor_row(13). corridor_row(14).

// Llegamos al destino
+!navigate(TX, TY) : robot_pos(TX, TY) <- true.

// Destino en zona de almacenamiento (x>=10) y no estamos ya en el corredor correcto:
// navegar primero al corredor vertical libre (x=9, y=TY), luego deslizar al destino.
+!navigate(TX, TY) : TX >= 10 & robot_pos(X, Y) & not (Y == TY & corridor_row(TY)) <-
    !navigate(9, TY);
    !navigate(TX, TY).

// Paso a paso hacia el destino (greedy Manhattan)
+!navigate(TX, TY) : robot_pos(X, Y) <-
    !step_with_retry(X, Y, TX, TY, 0);
    !navigate(TX, TY).

// Intentar un paso; si falla (celda ocupada por robot), reintentar hasta 6 veces
+!step_with_retry(X, Y, TX, TY, BC) <- !do_step(X, Y, TX, TY).

// Backoff general tras ≥2 fallos: retroceder para sortear obstáculo o robot de frente
-!step_with_retry(X, Y, TX, TY, BC) : BC >= 2 & BC < 6 <-
    !path_backoff(X, Y, TX, TY);
    .wait(1000);
    BC1 = BC + 1;
    ?robot_pos(CX, CY);
    !step_with_retry(CX, CY, TX, TY, BC1).

-!step_with_retry(X, Y, TX, TY, BC) : BC < 6 <-
    .wait(1000);
    BC1 = BC + 1;
    ?robot_pos(CX, CY);
    !step_with_retry(CX, CY, TX, TY, BC1).

-!step_with_retry(_, _, _, _, _) <-
    .my_name(Me);
    .send(supervisor, tell, robot_error(Me, path_blocked, "permanently_blocked"));
    ?nav_abort_signal.   // creencia inexistente: falla y propaga fallo hacia arriba

// step_done: flag temporal que se activa cuando move_step tiene éxito.
// Permite que ?step_done al final de do_step distinga "movió" de "ambos ejes bloqueados".

// Prioridad X si |dx| >= |dy|
+!do_step(X, Y, TX, TY) : TX > X & TY >= Y & TX - X >= TY - Y <- -step_done; !try_x_then_y(X, Y, TX, TY); ?step_done.
+!do_step(X, Y, TX, TY) : TX > X & TY <  Y & TX - X >= Y - TY <- -step_done; !try_x_then_y(X, Y, TX, TY); ?step_done.
+!do_step(X, Y, TX, TY) : TX < X & TY >= Y & X - TX >= TY - Y <- -step_done; !try_x_then_y(X, Y, TX, TY); ?step_done.
+!do_step(X, Y, TX, TY) : TX < X & TY <  Y & X - TX >= Y - TY <- -step_done; !try_x_then_y(X, Y, TX, TY); ?step_done.
+!do_step(X, Y, TX, TY) <- -step_done; !try_y_then_x(X, Y, TX, TY); ?step_done.   // prioridad Y

// Intentar eje X primero; si falla (bloqueado), intentar eje Y como fallback.
// +step_done marca éxito. Catch-all con body true: no añade step_done → ?step_done falla
// en do_step → step_with_retry reintenta con delay.
+!try_x_then_y(X, Y, TX, TY) : TX > X <- NX = X + 1; move_step(NX, Y); +step_done.
+!try_x_then_y(X, Y, TX, TY) : TX < X <- NX = X - 1; move_step(NX, Y); +step_done.
-!try_x_then_y(X, Y, TX, TY) : TY > Y <- NY = Y + 1; move_step(X, NY); +step_done.
-!try_x_then_y(X, Y, TX, TY) : TY < Y <- NY = Y - 1; move_step(X, NY); +step_done.
-!try_x_then_y(X, Y, TX, TY) <- true.   // ambos ejes bloqueados o TY==Y sin fallback

// Intentar eje Y primero; si falla (bloqueado), intentar eje X como fallback.
+!try_y_then_x(X, Y, TX, TY) : TY > Y <- NY = Y + 1; move_step(X, NY); +step_done.
+!try_y_then_x(X, Y, TX, TY) : TY < Y <- NY = Y - 1; move_step(X, NY); +step_done.
-!try_y_then_x(X, Y, TX, TY) : TX > X <- NX = X + 1; move_step(NX, Y); +step_done.
-!try_y_then_x(X, Y, TX, TY) : TX < X <- NX = X - 1; move_step(NX, Y); +step_done.
-!try_y_then_x(X, Y, TX, TY) <- true.   // ambos ejes bloqueados o TX==X sin fallback

// Sortear obstáculo según el tipo de movimiento:
// - Con componente Y (TY != Y): perpendicular en X → cambia columna, el greedy
//   re-ruteará sin romper la lógica de fila de corredor.
// - Horizontal puro (TY == Y): retrocede en X → no altera la fila actual, el BC
//   incrementa correctamente hasta path_blocked si el obstáculo es permanente.
+!path_backoff(X, Y, TX, TY) : TY > Y <- NX = X + 1; NY = Y + 1; move_step(NX, Y); move_step(NX, NY).
+!path_backoff(X, Y, TX, TY) : TY < Y <- NX = X + 1; NY = Y - 1; move_step(NX, Y); move_step(NX, NY).
+!path_backoff(X, Y, TX, TY) : TX > X <- NY = Y + 1; move_step(X, NY).
+!path_backoff(X, Y, TX, TY) : TX < X <- NY = Y + 1; move_step(X, NY).
+!path_backoff(_, _, _, _) <- true.
-!path_backoff(X, Y, TX, TY) : TY > Y <- NX = X - 1; NY = Y + 1; move_step(NX, Y); move_step(NX, NY).
-!path_backoff(X, Y, TX, TY) : TY < Y <- NX = X - 1; NY = Y - 1; move_step(NX, Y); move_step(NX, NY).
-!path_backoff(X, Y, TX, TY) : TX > X <- NY = Y - 1; move_step(X, NY).
-!path_backoff(X, Y, TX, TY) : TX < X <- NY = Y - 1; move_step(X, NY).
-!path_backoff(_, _, _, _) <- true.

// shelf_full lo gestiona -!execute_task: el robot lleva el contenedor a la zona de expansión
+error(shelf_full, Data) : true <- true.

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

// Tarea encolada durante la vuelta a base: procesarla al quedar idle
+state(idle) : task(CId, ShelfId) <-
    .print("✅ [MEDIUM] Tarea pendiente al quedar idle: ", CId, " a ", ShelfId);
    -task(CId, ShelfId)[source(scheduler)];
    accept_task(CId);
    -+state(working);
    -+carrying(CId);
    !execute_task(CId, ShelfId).

+state(idle) : not task(_, _) <-
    .my_name(Me);
    .send(supervisor, tell, robot_state_change(Me, idle)).

