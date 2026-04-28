/*******************************************************************************
 * ROBOT PESADO 2 - Sistema de Gestión Logística de Almacén
 *
 * Universidad de Vigo - Sistemas Inteligentes
 * Curso 2025-2026
 *
 * Segunda instancia del robot pesado. Mismas capacidades que robot_heavy,
 * posición base distinta (4,3).
 *
 * CAPACIDADES:
 *   - Peso máximo: 100 kg
 *   - Tamaño máximo: 2×3
 *   - Velocidad: Baja (1)
 *
 ******************************************************************************/

/* Estado inicial del robot */
state(idle).
position(4,3).       // Posición inicial (diferente a robot_heavy en (3,3))
carrying(none).

shelf_urgency("shelf_1", urgent).  shelf_urgency("shelf_5", urgent).  shelf_urgency("shelf_8", urgent).
shelf_urgency("shelf_2", non_urgent). shelf_urgency("shelf_3", non_urgent). shelf_urgency("shelf_4", non_urgent).
shelf_urgency("shelf_6", non_urgent). shelf_urgency("shelf_7", non_urgent). shelf_urgency("shelf_9", non_urgent).

non_urgent_container_type("standard").
non_urgent_container_type("fragile").

/* ============================================================================
 * PLANES PRINCIPALES
 * ============================================================================ */

!start.

+!start : true <-
    .print("🤖 Robot pesado 2 iniciado - Capacidad: 100kg, 2x3 [ESPECIALIZADO]");
    -+state(idle);
    !work_cycle.

+!work_cycle : state(idle) <-
    .print("[HEAVY2] Consultando scheduler para nueva tarea...");
    .send(scheduler, tell, request_task);
    .wait(4000);
    !work_cycle.

+!work_cycle : not state(idle) <-
    .wait(3000);
    !work_cycle.

/* ============================================================================
 * MANEJO DE TAREAS ASIGNADAS
 * ============================================================================ */

+task(CId, ShelfId) : state(idle) <-
    .print("✅ [HEAVY2] Tarea especializada asignada: ", CId, " a ", ShelfId);
    -task(CId, ShelfId)[source(scheduler)];
    accept_task(CId);
    -+state(working);
    -+carrying(CId);
    !execute_task(CId, ShelfId).

+task(CId, ShelfId) : not state(idle) <-
    .print("⚠️ [HEAVY2] Ocupado con carga pesada, encolando: ", CId).

+!execute_task(CId, ShelfId) : true <-
    .print("🚀 [HEAVY2] Iniciando transporte de carga pesada: ", CId);

    .print("📍 [HEAVY2] Fase 1: Localizando contenedor ", CId);
    !get_to_container(CId, 3);
    .wait(1000);

    .print("📦 [HEAVY2] Fase 2: Recogiendo contenedor pesado ", CId);
    -+state(picking);
    pickup(CId);
    .wait(1000);

    .print("🚚 [HEAVY2] Fase 3: Transportando carga pesada a ", ShelfId);
    -+state(carrying);
    move_to_shelf(ShelfId);
    ?nav_target(TX2, TY2);
    !navigate(TX2, TY2);

    .print("📥 [HEAVY2] Fase 4: Depositando carga en ", ShelfId);
    -+state(dropping);
    drop_at(ShelfId);
    .wait(1000);

    .print("✨ [HEAVY2] Tarea especializada completada: ", CId);
    -+carrying(none);
    !check_queue.

/* ============================================================================
 * MANEJO DE ERRORES Y FALLOS DE PLANES
 * ============================================================================ */

-!execute_task(CId, ShelfId) : error(shelf_full, _) & carrying(CId) <-
    .print("⚠️ [HEAVY2] Estantería llena, llevando ", CId, " a zona de expansión");
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
    .print("⚠️ [HEAVY2] No se pudo llegar a expansión con ", CId, ". Liberando tarea.");
    -+carrying(none);
    release_task(CId);
    .send(scheduler, tell, task_failed(CId)).

-!execute_task(CId, ShelfId) : true <-
    .print("⚠️ [HEAVY2] Fallo en execute_task para ", CId, ". Limpiando estado...");
    -+carrying(none);
    release_task(CId);
    .send(scheduler, tell, task_failed(CId));
    .wait(5000);
    !safe_return;
    !check_queue.

+!safe_return : position(InitX, InitY) <- !navigate(InitX, InitY).
-!safe_return : true <- true.

+!get_to_container(CId, N) : N > 0 <-
    move_to_container(CId);
    ?nav_target(TX, TY);
    !navigate(TX, TY).

-!get_to_container(CId, N) : N > 1 <-
    .print("⚠️ [HEAVY2] Reintentando nav a ", CId, " (", N, " intentos restantes)");
    .wait(5000);
    N1 = N - 1;
    !get_to_container(CId, N1).

/* ============================================================================
 * CICLO OUTBOUND — extraer contenedor de estantería y llevar a zona de salida
 * ============================================================================ */

// Idle + capable + deadline fase correcta → procesar
+outbound_available(CId, ShelfId, W, H, Weight) :
    state(idle) & max_weight(MaxW) & max_size(MaxDimW, MaxDimH)
    & not (Weight > MaxW) & not (W > MaxDimW) & not (H > MaxDimH)
    & active_deadline(_, Category, _) & shelf_urgency(ShelfId, Category) <-
    .print("📤 [HEAVY2] Tomando outbound: ", CId, " de ", ShelfId);
    -outbound_available(CId, ShelfId, W, H, Weight)[source(scheduler)];
    accept_task(CId);
    -+state(working);
    -+carrying(CId);
    !execute_outbound_task(CId, ShelfId).

// Capaz pero ocupado, o deadline incorrecto → conservar para después
+outbound_available(CId, ShelfId, W, H, Weight) :
    max_weight(MaxW) & max_size(MaxDimW, MaxDimH)
    & not (Weight > MaxW) & not (W > MaxDimW) & not (H > MaxDimH) <-
    .print("⚠️ [HEAVY2] Outbound pendiente (ocupado o deadline incorrecto): ", CId).

// No capaz → descartar
+outbound_available(CId, ShelfId, W, H, Weight) : true <-
    -outbound_available(CId, ShelfId, W, H, Weight)[source(scheduler)].

// Cuando llega un nuevo deadline, procesar cola de outbound pendiente
+active_deadline(_, Category, _) : state(idle) <-
    !check_outbound_for_category(Category).

+!check_outbound_for_category(Category) :
    outbound_available(CId, ShelfId, W, H, Weight)
    & max_weight(MaxW) & max_size(MaxDimW, MaxDimH)
    & not (Weight > MaxW) & not (W > MaxDimW) & not (H > MaxDimH)
    & shelf_urgency(ShelfId, Category) <-
    .print("📤 [HEAVY2] Procesando outbound desde cola: ", CId, " de ", ShelfId);
    -outbound_available(CId, ShelfId, W, H, Weight)[source(scheduler)];
    accept_task(CId);
    -+state(working);
    -+carrying(CId);
    !execute_outbound_task(CId, ShelfId).

+!check_outbound_for_category(_) : true <- true.

+!execute_outbound_task(CId, ShelfId) : true <-
    .print("📤 [HEAVY2] Fase 1: Navegando a estantería ", ShelfId);
    move_to_shelf(ShelfId);
    ?nav_target(TX, TY);
    !navigate(TX, TY);

    .print("📦 [HEAVY2] Fase 2: Recogiendo de estantería ", ShelfId);
    -+state(picking);
    pickup_from_shelf(CId, ShelfId);
    .wait(1000);

    .print("🚚 [HEAVY2] Fase 3: Navegando a zona outbound");
    -+state(carrying);
    move_to_outbound;
    ?nav_target(TX2, TY2);
    !navigate(TX2, TY2);

    .print("📤 [HEAVY2] Fase 4: Entregando contenedor");
    -+state(dropping);
    drop_in_outbound(CId);
    .wait(1000);

    .my_name(Me);
    .time(Hd, Md, Sd); Td = Hd * 3600 + Md * 60 + Sd;
    warehouse.log_event("EVENT | time=", Td, " | agent=", Me, " | type=container_delivered | data=", CId);
    .print("✨ [HEAVY2] Outbound completado: ", CId);
    -+carrying(none);
    release_task(CId);
    !check_queue.

-!execute_outbound_task(CId, ShelfId) : true <-
    .print("⚠️ [HEAVY2] Fallo en tarea outbound: ", CId);
    -+carrying(none);
    release_task(CId);
    .send(scheduler, tell, outbound_failed(CId, ShelfId));
    !check_queue.

+shipped(CId) : true <- true.

+!check_queue : outbound_available(CId, ShelfId, W, H, Weight) & max_weight(MaxW) & max_size(MaxDimW, MaxDimH)
              & not (Weight > MaxW) & not (W > MaxDimW) & not (H > MaxDimH)
              & active_deadline(_, Category, _) & shelf_urgency(ShelfId, Category) <-
    .print("✅ [HEAVY2] Procesando outbound disponible: ", CId, " desde ", ShelfId);
    -outbound_available(CId, ShelfId, W, H, Weight)[source(scheduler)];
    accept_task(CId);
    -+state(working);
    -+carrying(CId);
    !execute_outbound_task(CId, ShelfId).

+!check_queue : task(CId, ShelfId) <-
    .print("✅ [HEAVY2] Procesando tarea encolada: ", CId, " a ", ShelfId);
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

-!check_queue : task(CId, ShelfId) <-
    .print("⚠️ [HEAVY2] Fallo al navegar a base, procesando tarea encolada: ", CId);
    -task(CId, ShelfId)[source(scheduler)];
    accept_task(CId);
    -+state(working);
    -+carrying(CId);
    !execute_task(CId, ShelfId).

/* ============================================================================
 * NAVEGACIÓN AUTÓNOMA
 * ============================================================================ */

corridor_row(1). corridor_row(4). corridor_row(5).
corridor_row(8). corridor_row(9). corridor_row(13). corridor_row(14).

+!navigate(TX, TY) : robot_pos(TX, TY) <- true.

+!navigate(TX, TY) : TX >= 10 & robot_pos(X, Y) & not (Y == TY & corridor_row(TY)) <-
    !navigate(9, TY);
    !navigate(TX, TY).

+!navigate(TX, TY) : robot_pos(X, Y) <-
    !step_with_retry(X, Y, TX, TY, 0);
    !navigate(TX, TY).

+!step_with_retry(X, Y, TX, TY, BC) <- !do_step(X, Y, TX, TY).

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
    ?nav_abort_signal.

+!do_step(X, Y, TX, TY) : TX > X & TY >= Y & TX - X >= TY - Y <- -step_done; !try_x_then_y(X, Y, TX, TY); ?step_done.
+!do_step(X, Y, TX, TY) : TX > X & TY <  Y & TX - X >= Y - TY <- -step_done; !try_x_then_y(X, Y, TX, TY); ?step_done.
+!do_step(X, Y, TX, TY) : TX < X & TY >= Y & X - TX >= TY - Y <- -step_done; !try_x_then_y(X, Y, TX, TY); ?step_done.
+!do_step(X, Y, TX, TY) : TX < X & TY <  Y & X - TX >= Y - TY <- -step_done; !try_x_then_y(X, Y, TX, TY); ?step_done.
+!do_step(X, Y, TX, TY) <- -step_done; !try_y_then_x(X, Y, TX, TY); ?step_done.

+!try_x_then_y(X, Y, TX, TY) : TX > X <- NX = X + 1; move_step(NX, Y); +step_done.
+!try_x_then_y(X, Y, TX, TY) : TX < X <- NX = X - 1; move_step(NX, Y); +step_done.
-!try_x_then_y(X, Y, TX, TY) : TY > Y <- NY = Y + 1; move_step(X, NY); +step_done.
-!try_x_then_y(X, Y, TX, TY) : TY < Y <- NY = Y - 1; move_step(X, NY); +step_done.
-!try_x_then_y(X, Y, TX, TY) <- true.

+!try_y_then_x(X, Y, TX, TY) : TY > Y <- NY = Y + 1; move_step(X, NY); +step_done.
+!try_y_then_x(X, Y, TX, TY) : TY < Y <- NY = Y - 1; move_step(X, NY); +step_done.
-!try_y_then_x(X, Y, TX, TY) : TX > X <- NX = X + 1; move_step(NX, Y); +step_done.
-!try_y_then_x(X, Y, TX, TY) : TX < X <- NX = X - 1; move_step(NX, Y); +step_done.
-!try_y_then_x(X, Y, TX, TY) <- true.

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

+error(shelf_full, Data) : true <- true.

+error(container_too_heavy, Data) : carrying(CId) <-
    .send(scheduler, tell, container_error(CId, container_too_heavy));
    .send(supervisor, tell, container_error(CId, container_too_heavy));
    -+state(idle);
    -+carrying(none);
    .abolish(task(CId, _)).

+error(container_too_big, Data) : carrying(CId) <-
    .send(scheduler, tell, container_error(CId, container_too_big));
    .send(supervisor, tell, container_error(CId, container_too_big));
    -+state(idle);
    -+carrying(none);
    .abolish(task(CId, _)).

+error(ErrorType, Data) : carrying(CId) <-
    .send(scheduler, tell, container_error(CId, ErrorType));
    .send(supervisor, tell, container_error(CId, ErrorType));
    -+state(idle);
    -+carrying(none).

+error(ErrorType, Data) : true <-
    -+state(idle);
    -+carrying(none).

+picked(CId) : true <-
    .print("✓ [HEAVY2] Carga pesada ", CId, " asegurada correctamente").

+stored(CId, ShelfId) : true <-
    .print("✓ [HEAVY2] Carga pesada ", CId, " almacenada en ", ShelfId);
    .send(scheduler, tell, container_stored(CId, ShelfId));
    .send(supervisor, tell, container_stored(CId, ShelfId)).

/* ============================================================================
 * NOTIFICACIÓN DE ESTADO AL SUPERVISOR
 * ============================================================================ */

+state(working) : true <-
    .my_name(Me);
    .send(supervisor, tell, robot_state_change(Me, working)).

+state(idle) : task(CId, ShelfId) <-
    .print("✅ [HEAVY2] Tarea pendiente al quedar idle: ", CId, " a ", ShelfId);
    -task(CId, ShelfId)[source(scheduler)];
    accept_task(CId);
    -+state(working);
    -+carrying(CId);
    !execute_task(CId, ShelfId).

+state(idle) : not task(_, _) <-
    .my_name(Me);
    .send(supervisor, tell, robot_state_change(Me, idle)).
