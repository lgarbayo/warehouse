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
 * MODO: Autónomo — reclama contenedores directamente del entorno.
 ******************************************************************************/

{ include("common.asl") }

/* ============================================================================
 * CREENCIAS INICIALES
 * ============================================================================ */

state(idle).
position(1,2).
carrying(none).
nav_limit(300).

/* ============================================================================
 * ARRANQUE Y CICLO DE TRABAJO
 * ============================================================================ */

!start.

+!start : true <-
    .print("🤖 Robot ligero iniciado - Capacidad: 10kg, 1x1 - Modo autónomo");
    !work_cycle.

+!work_cycle : state(idle) <-
    !check_exit_cycle;
    !check_pending_containers;
    .wait(3000);
    !work_cycle.

+!work_cycle : not state(idle) <-
    .wait(2000);
    !work_cycle.

/* ============================================================================
 * RECLAMACIÓN AUTÓNOMA DE CONTENEDORES
 * El robot responde a contenedores que puede manejar (W<=1, H<=1, Weight<=10).
 * ============================================================================ */

+container_at_entrance(CId, Type, Weight, W, H) : nav_failed(CId) <- true.

// Robot ligero: solo contenedores 1x1 hasta 10kg (capacidad hardcodeada)
+container_at_entrance(CId, Type, Weight, W, H) :
    state(idle) & Weight <= 10 & W <= 1 & H <= 1 <-
    !try_claim(CId, Type, Weight, W, H).

// Robot ocupado o contenedor fuera de capacidad: conservar percept para después
+container_at_entrance(CId, Type, Weight, W, H) : true <- true.

-container_at_entrance(CId, Type, Weight, W, H) : nav_failed(CId) <-
    -nav_failed(CId).

// Intentar reclamar usando if para no propagar fallo si otro robot llegó antes
+!try_claim(CId, Type, Weight, W, H) : state(idle) <-
    claim_container(CId);
    +claimed_type(CId, Type);
    accept_task(CId);
    -+state(working);
    -+carrying(CId);
    !select_shelf_and_execute(CId, Weight, W, H).

-!try_claim(CId, Type, Weight, W, H) : true <- true.

// Verifica si hay contenedores pendientes en belief base al quedar idle
+!check_pending_containers :
    container_at_entrance(CId, Type, Weight, W, H) &
    Weight <= 10 & W <= 1 & H <= 1 &
    not nav_failed(CId) <-
    !try_claim(CId, Type, Weight, W, H).

+!check_pending_containers : true <- true.
-!check_pending_containers : true <- true.

/* ============================================================================
 * SELECCIÓN DE ESTANTERÍA Y EJECUCIÓN
 * ============================================================================ */

+!select_shelf_and_execute(CId, Weight, W, H) : true <-
    !pick_shelf(CId, Weight, W, H);
    ?shelf_selected(CId, ShelfId);
    .abolish(shelf_selected(CId, _));
    .abolish(shelf_retries_count(CId, _));
    !execute_task(CId, ShelfId).

-!select_shelf_and_execute(CId, Weight, W, H) : true <-
    .print("⚠️ [LIGHT] Falló selección de estantería para ", CId);
    .abolish(claimed_type(CId, _));
    unclaim_container(CId);
    release_task(CId);
    -+carrying(none);
    !check_queue.

/* ============================================================================
 * EJECUCIÓN DE TAREA
 * ============================================================================ */

+!execute_task(CId, ShelfId) : true <-
    -nav_limit(_); +nav_limit(300);
    .print("🚀 [LIGHT] Iniciando tarea: ", CId, " → ", ShelfId);

    .print("📍 [LIGHT] Fase 1: Localizando contenedor ", CId);
    !get_to_container(CId, 3);
    .wait(500);

    .print("📦 [LIGHT] Fase 2: Recogiendo ", CId);
    -+state(picking);
    pickup(CId);
    .wait(500);
    .time(H_pk,M_pk,S_pk); T_pk=H_pk*3600+M_pk*60+S_pk;
    warehouse.log_event("EVENT | time=",T_pk," | agent=robot_light | type=pickup | data=",CId);

    .print("🚚 [LIGHT] Fase 3: Transportando a estantería ", ShelfId);
    -+state(carrying);
    move_to_shelf(ShelfId);
    ?nav_target(TX2, TY2);
    !navigate(TX2, TY2);

    .print("📥 [LIGHT] Fase 4: Depositando en ", ShelfId);
    -+state(dropping);
    drop_at(ShelfId);
    .wait(500);

    .print("✨ [LIGHT] Tarea completada: ", CId);
    -+carrying(none);
    !check_queue.

/* ============================================================================
 * NAVEGACIÓN AUTÓNOMA
 * ============================================================================ */

corridor_row(1). corridor_row(4). corridor_row(5).
corridor_row(8). corridor_row(9). corridor_row(13). corridor_row(14).

+!navigate(TX, TY) : robot_pos(TX, TY) <- true.

+!navigate(TX, TY) : TX >= 10 & robot_pos(X, Y) & not (Y == TY & corridor_row(TY)) <-
    !navigate(9, TY);
    !navigate(TX, TY).

+!navigate(TX, TY) : robot_pos(X, Y) & nav_limit(N) & N > 0 <-
    N1 = N - 1; -nav_limit(_); +nav_limit(N1);
    !step_with_retry(X, Y, TX, TY, 0);
    !navigate(TX, TY).

+!navigate(TX, TY) : true <-
    .my_name(Me);
    .print("⚠️ [LIGHT] Nav timeout hacia (", TX, ",", TY, ")");
    .send(supervisor, tell, robot_error(Me, nav_timeout, "navigation_timed_out"));
    ?nav_abort_signal.

+!step_with_retry(X, Y, TX, TY, BC) <- !do_step(X, Y, TX, TY).

-!step_with_retry(X, Y, TX, TY, BC) : BC >= 2 & BC < 6 <-
    !path_backoff(X, Y, TX, TY);
    .wait(800);
    BC1 = BC + 1;
    ?robot_pos(CX, CY);
    !step_with_retry(CX, CY, TX, TY, BC1).

-!step_with_retry(X, Y, TX, TY, BC) : BC < 6 <-
    .wait(800);
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

/* ============================================================================
 * MANEJO DE ERRORES Y FALLOS DE PLANES
 * ============================================================================ */

// Estantería llena: llevar a zona de expansión y liberar para reasignación
-!execute_task(CId, ShelfId) : error(shelf_full, _) & carrying(CId) <-
    .print("⚠️ [LIGHT] Estantería llena, llevando ", CId, " a zona de expansión");
    .abolish(error(shelf_full, _));
    +expansion_failed_shelf(CId, ShelfId);
    move_to_expansion;
    ?nav_target(TX, TY);
    !navigate(TX, TY);
    drop_in_expansion(CId);
    -+carrying(none);
    .time(H_ex,M_ex,S_ex); T_ex=H_ex*3600+M_ex*60+S_ex;
    warehouse.log_event("EVENT | time=",T_ex," | agent=robot_light | type=expansion_drop | data=",CId,",",ShelfId);
    release_task(CId);
    unclaim_container(CId);
    !check_queue.

-!execute_task(CId, ShelfId) : not carrying(CId) & nav_failed(CId) <-
    .wait(2000);
    !safe_return;
    !check_queue.

-!execute_task(CId, ShelfId) : not carrying(CId) <-
    release_task(CId);
    unclaim_container(CId);
    .send(scheduler, tell, task_failed(CId));
    .wait(2000);
    !safe_return;
    !check_queue.

-!execute_task(CId, ShelfId) : true <-
    .print("⚠️ [LIGHT] Fallo en execute_task para ", CId);
    -+carrying(none);
    release_task(CId);
    unclaim_container(CId);
    .time(H_tf,M_tf,S_tf); T_tf=H_tf*3600+M_tf*60+S_tf;
    warehouse.log_event("EVENT | time=",T_tf," | agent=robot_light | type=task_failed | data=",CId,",",ShelfId);
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
    .print("⚠️ [LIGHT] Reintentando nav a ", CId, " (", N, " intentos restantes)");
    .wait(2000);
    N1 = N - 1;
    !get_to_container(CId, N1).

-!get_to_container(CId, 1) : true <-
    .print("⚠️ [LIGHT] Inaccesible tras 3 intentos: ", CId);
    -+carrying(none);
    release_task(CId);
    +nav_failed(CId);
    unclaim_container(CId);
    .time(H_nf,M_nf,S_nf); T_nf=H_nf*3600+M_nf*60+S_nf;
    warehouse.log_event("EVENT | time=",T_nf," | agent=robot_light | type=nav_failed | data=",CId);
    .send(scheduler, tell, task_failed(CId));
    .fail.

+!check_queue : true <-
    .abolish(error(_, _));
    !safe_return;
    -+state(idle).

-!check_queue : true <-
    .abolish(error(_, _));
    -+state(idle).

/* ============================================================================
 * CICLO DE SALIDA - Selección y entrega física a zona outbound
 * ============================================================================ */

+!check_exit_cycle : active_deadline(_, Category, _) <-
    .findall(pair(CId, ShelfId), (stored(CId, ShelfId) & not exit_claimed(CId)), Candidates);
    !select_for_exit(Candidates, Category).

+!check_exit_cycle : true <- true.

+!select_for_exit([pair(CId, ShelfId)|_], urgent) : claimed_type(CId, "urgent") & state(idle) <-
    +exit_claimed(CId);
    .my_name(Me);
    .print("[", Me, "] Ciclo de salida (urgente): seleccionado ", CId, " en ", ShelfId);
    -+state(working);
    -+carrying(CId);
    !execute_exit(CId, ShelfId).

-!select_for_exit([_|Rest], urgent) : true <-
    !select_for_exit(Rest, urgent).

+!select_for_exit([pair(CId, ShelfId)|_], non_urgent) :
    claimed_type(CId, ContType) & non_urgent_container_type(ContType) & state(idle) <-
    +exit_claimed(CId);
    .my_name(Me);
    .print("[", Me, "] Ciclo de salida (no urgente): seleccionado ", CId, " (", ContType, ") en ", ShelfId);
    -+state(working);
    -+carrying(CId);
    !execute_exit(CId, ShelfId).

-!select_for_exit([_|Rest], non_urgent) : true <-
    !select_for_exit(Rest, non_urgent).

+!select_for_exit([], _) : true <- true.

// Tarea física de salida: shelf → outbound zone
+!execute_exit(CId, ShelfId) : true <-
    -nav_limit(_); +nav_limit(300);
    .print("🚀 [LIGHT] Execute exit: ", CId, " desde ", ShelfId);

    move_to_shelf(ShelfId);
    ?nav_target(TX, TY);
    !navigate(TX, TY);

    pickup_from_shelf(CId, ShelfId);
    .wait(500);
    -+state(carrying);

    move_to_outbound;
    ?nav_target(TX2, TY2);
    !navigate(TX2, TY2);

    drop_in_outbound(CId);
    .wait(500);

    .my_name(Me);
    .time(Hd, Md, Sd); Td = Hd * 3600 + Md * 60 + Sd;
    warehouse.log_event("EVENT | time=", Td, " | agent=", Me, " | type=container_delivered | data=", CId);
    -stored(CId, ShelfId);
    .abolish(claimed_type(CId, _));
    .abolish(expansion_failed_shelf(CId, _));
    -+carrying(none);
    !check_queue.

-!execute_exit(CId, ShelfId) : true <-
    .print("⚠️ [LIGHT] Fallo en execute_exit para ", CId);
    -exit_claimed(CId);
    -+carrying(none);
    !check_queue.

/* ============================================================================
 * NOTIFICACIÓN DE ESTADO AL SUPERVISOR
 * ============================================================================ */

+state(working) : true <-
    .my_name(Me);
    .send(supervisor, tell, robot_state_change(Me, working)).

+state(idle) : true <-
    .my_name(Me);
    .send(supervisor, tell, robot_state_change(Me, idle)).

/* ============================================================================
 * MANEJADORES DE ERRORES DEL ENTORNO
 * ============================================================================ */

+error(shelf_full, Data) : true <- true.

+error(container_too_heavy, Data) : carrying(CId) <-
    .print("❌ ERROR: Contenedor muy pesado - ", Data);
    .send(supervisor, tell, container_error(CId, container_too_heavy));
    -+state(idle); -+carrying(none);
    .abolish(claimed_type(CId, _)).

+error(container_too_big, Data) : carrying(CId) <-
    .print("❌ ERROR: Contenedor muy grande - ", Data);
    .send(supervisor, tell, container_error(CId, container_too_big));
    -+state(idle); -+carrying(none);
    .abolish(claimed_type(CId, _)).

+error(destination_conflict, Data) : true <-
    .my_name(Me);
    .send(supervisor, tell, robot_error(Me, destination_conflict, Data));
    .wait(800).

+error(too_far, Data) : true <-
    .my_name(Me);
    .send(supervisor, tell, robot_error(Me, too_far, Data));
    -+state(idle); -+carrying(none).

+error(route_blocked, Data) : true <-
    .my_name(Me);
    .send(supervisor, tell, robot_error(Me, route_blocked, Data));
    -+state(idle); -+carrying(none).

+error(path_blocked, Data) : true <-
    .my_name(Me);
    .send(supervisor, tell, robot_error(Me, path_blocked, Data));
    -+state(idle); -+carrying(none).

+error(illegal_move, Data) : true <-
    .my_name(Me);
    .send(supervisor, tell, robot_error(Me, illegal_move, Data));
    -+state(idle); -+carrying(none).

+error(robot_not_found, Data) : true <-
    .my_name(Me);
    .send(supervisor, tell, robot_error(Me, robot_not_found, Data));
    -+state(idle); -+carrying(none).

+error(ErrorType, Data) : carrying(CId) <-
    .send(supervisor, tell, container_error(CId, ErrorType));
    -+state(idle); -+carrying(none).

+error(ErrorType, Data) : true <-
    -+state(idle); -+carrying(none).

+picked(CId) : true <-
    .print("✓ [LIGHT] ", CId, " recogido").

+stored(CId, ShelfId) : true <-
    .print("✓ [LIGHT] ", CId, " almacenado en ", ShelfId);
    .time(H_st,M_st,S_st); T_st=H_st*3600+M_st*60+S_st;
    warehouse.log_event("EVENT | time=",T_st," | agent=robot_light | type=stored | data=",CId,",",ShelfId);
    .send(supervisor, tell, container_stored(CId, ShelfId)).
