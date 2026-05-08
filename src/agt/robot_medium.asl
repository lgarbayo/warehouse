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
 * MODO: Autónomo — reclama contenedores directamente del entorno.
 ******************************************************************************/

{ include("common.asl") }

/* ============================================================================
 * CREENCIAS INICIALES
 * ============================================================================ */

state(idle).
position(2,3).
carrying(none).
nav_limit(300).

/* ============================================================================
 * ARRANQUE Y CICLO DE TRABAJO
 * ============================================================================ */

!start.

+!start : true <-
    .print("🤖 Robot medio iniciado - Capacidad: 30kg, 1x2 - Modo autónomo");
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
 * ============================================================================ */

// Robot medio: Weight>10 OR H>1, hasta 30kg y 1x2
+container_at_entrance(CId, Type, Weight, W, H) :
    state(idle) & not nav_failed(CId) & not shelf_wait(CId) & not blocked_type(Type) &
    Weight > 10 & Weight <= 30 & W <= 1 & H <= 2 <-
    !try_claim(CId, Type, Weight, W, H).

+container_at_entrance(CId, Type, Weight, W, H) :
    state(idle) & not nav_failed(CId) & not shelf_wait(CId) & not blocked_type(Type) &
    H > 1 & Weight <= 30 & W <= 1 & H <= 2 <-
    !try_claim(CId, Type, Weight, W, H).

+container_at_entrance(_, _, _, _, _) : true <- true.

-container_at_entrance(CId, _, _, _, _) : nav_failed(CId) <- -nav_failed(CId).

+nav_failed(CId) <- .wait(20000); -nav_failed(CId).

+!check_pending_containers :
    container_at_entrance(CId, Type, Weight, W, H) &
    Weight > 10 & Weight <= 30 & W <= 1 & H <= 2 &
    not nav_failed(CId) & not shelf_wait(CId) & not blocked_type(Type) <-
    !try_claim(CId, Type, Weight, W, H).

+!check_pending_containers :
    container_at_entrance(CId, Type, Weight, W, H) &
    H > 1 & Weight <= 30 & W <= 1 & H <= 2 &
    not nav_failed(CId) & not shelf_wait(CId) & not blocked_type(Type) <-
    !try_claim(CId, Type, Weight, W, H).

+!check_pending_containers : true <- true.
-!check_pending_containers : true <- true.


/* ============================================================================
 * EJECUCIÓN DE TAREA
 * ============================================================================ */

+!execute_task(CId, ShelfId) : true <-
    -nav_limit(_); +nav_limit(300);
    .print("🚀 [MEDIUM] Iniciando tarea: ", CId, " → ", ShelfId);

    .print("📍 [MEDIUM] Fase 1: Localizando contenedor ", CId);
    !acquire_zone(inbound);
    !get_to_container(CId, 3);
    .wait(600);

    .print("📦 [MEDIUM] Fase 2: Recogiendo ", CId);
    -+state(picking);
    pickup(CId);
    !release_zone(inbound);
    .wait(600);
    .time(H_pk,M_pk,S_pk); T_pk=H_pk*3600+M_pk*60+S_pk;
    .print("EVENT | time=",T_pk," | agent=robot_medium | type=pickup | data=",CId);

    .print("🚚 [MEDIUM] Fase 3: Transportando a estantería ", ShelfId);
    -+state(carrying);
    move_to_shelf(ShelfId);
    ?nav_target(TX2, TY2);
    !navigate(TX2, TY2);

    .print("📥 [MEDIUM] Fase 4: Depositando en ", ShelfId);
    -+state(dropping);
    drop_at(ShelfId);
    .wait(600);

    .print("✨ [MEDIUM] Tarea completada: ", CId);
    -+carrying(none);
    !check_queue.



/* ============================================================================
 * NAVEGACIÓN AUTÓNOMA
 * ============================================================================ */

corridor_row(1). corridor_row(4). corridor_row(5).
corridor_row(8). corridor_row(9). corridor_row(13). corridor_row(14).

+!navigate(TX, TY) : robot_pos(TX, TY) <- true.

+!navigate(TX, TY) : TX < 9 & TX \== 9 & robot_pos(X, Y) & X >= 10 <-
    !navigate(9, Y);
    !navigate(9, TY);
    !navigate(TX, TY).

+!navigate(TX, TY) : TX >= 17 & TY < 2 & robot_pos(X, Y) & Y > 3 <-
    !navigate(19, 4);
    !navigate(19, 3);
    !navigate(TX, TY).

+!navigate(TX, TY) : TX >= 17 & TY < 2 & TX \== 19 & robot_pos(X, Y) & X >= 10 & X < 19 <-
    !navigate(19, Y);
    !navigate(19, TY);
    !navigate(TX, TY).

+!navigate(TX, TY) : TX >= 10 & TY >= 2 & TX \== 9 & robot_pos(X, Y) & X < 9 <-
    !navigate(9, Y);
    !navigate(9, TY);
    !navigate(TX, TY).

// X<=14 going to right side (TX>=15): use x=19
+!navigate(TX, TY) : TX >= 15 & TY >= 2 & TX \== 9 & robot_pos(X, Y) & X >= 10 & Y \== TY & X <= 14 <-
    !navigate(19, Y);
    !navigate(19, TY);
    !navigate(TX, TY).

+!navigate(TX, TY) : TX >= 10 & TY >= 2 & TX \== 9 & robot_pos(X, Y) & X >= 10 & Y \== TY & X <= 14 <-
    !navigate(9, Y);
    !navigate(9, TY);
    !navigate(TX, TY).

+!navigate(TX, TY) : TX >= 10 & TY >= 2 & TX \== 19 & robot_pos(X, Y) & X >= 10 & Y \== TY & X > 14 <-
    !navigate(19, Y);
    !navigate(19, TY);
    !navigate(TX, TY).

+!navigate(TX, TY) : TX \== 9 & robot_pos(X, Y) & X == 9 & Y \== TY <-
    !navigate(9, TY);
    !navigate(TX, TY).

// TY >= 2 guard: don't force route via (19,TY) when targeting outbound (TY<2)
+!navigate(TX, TY) : TX \== 19 & robot_pos(X, Y) & X == 19 & Y \== TY & TY >= 2 <-
    !navigate(19, TY);
    !navigate(TX, TY).

+!navigate(TX, TY) : robot_pos(X, Y) & nav_limit(N) & N > 0 <-
    N1 = N - 1; -nav_limit(_); +nav_limit(N1);
    !step_with_retry(X, Y, TX, TY, 0);
    !navigate(TX, TY).

+!navigate(TX, TY) : true <-
    .my_name(Me);
    .print("⚠️ [MEDIUM] Nav timeout hacia (", TX, ",", TY, ")");
    .send(supervisor, tell, robot_error(Me, nav_timeout, "navigation_timed_out"));
    .fail.

+!step_with_retry(X, Y, TX, TY, BC) <- !do_step(X, Y, TX, TY).

-!step_with_retry(X, Y, TX, TY, BC) : BC >= 4 & BC < 6 <-
    .random(R); .wait(1500 + R * 1500);
    BC1 = BC + 1;
    ?robot_pos(CX, CY);
    !step_with_retry(CX, CY, TX, TY, BC1).

-!step_with_retry(X, Y, TX, TY, BC) : BC >= 2 & BC < 4 <-
    !path_backoff(X, Y, TX, TY);
    .random(R); .wait(300 + R * 1200);
    BC1 = BC + 1;
    ?robot_pos(CX, CY);
    !step_with_retry(CX, CY, TX, TY, BC1).

-!step_with_retry(X, Y, TX, TY, BC) : BC < 6 <-
    .random(R); .wait(300 + R * 1200);
    BC1 = BC + 1;
    ?robot_pos(CX, CY);
    !step_with_retry(CX, CY, TX, TY, BC1).

-!step_with_retry(_, _, _, _, _) <-
    .my_name(Me);
    .send(supervisor, tell, robot_error(Me, path_blocked, "permanently_blocked"));
    .fail.

+!do_step(X, Y, TX, TY) : X == TX & Y == TY <- +step_done.
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

+!path_backoff(X, Y, TX, TY) : TX \== X & Y < 14 <- NY = Y + 1; move_step(X, NY).
+!path_backoff(X, Y, TX, TY) : TX \== X & Y > 0 <- NY = Y - 1; move_step(X, NY).
+!path_backoff(X, Y, TX, TY) : TY \== Y & X < 19 <- NX = X + 1; move_step(NX, Y).
+!path_backoff(X, Y, TX, TY) : TY \== Y & X > 0 <- NX = X - 1; move_step(NX, Y).
+!path_backoff(_, _, _, _) <- true.
-!path_backoff(X, Y, TX, TY) : TX \== X & Y > 0 <- NY = Y - 1; move_step(X, NY).
-!path_backoff(X, Y, TX, TY) : TX \== X & Y < 14 <- NY = Y + 1; move_step(X, NY).
-!path_backoff(X, Y, TX, TY) : TY \== Y & X > 0 <- NX = X - 1; move_step(NX, Y).
-!path_backoff(X, Y, TX, TY) : TY \== Y & X < 19 <- NX = X + 1; move_step(NX, Y).
-!path_backoff(_, _, _, _) <- true.

/* ============================================================================
 * MANEJO DE ERRORES Y FALLOS DE PLANES
 * ============================================================================ */

-!execute_task(CId, ShelfId) : error(shelf_full, _) & carrying(CId) & expansion_count(CId, N) & N >= 2 <-
    .print("⚠️ [MEDIUM] Sin espacio tras 3 intentos, abandonando ", CId);
    .abolish(error(shelf_full, _));
    .time(H_ex,M_ex,S_ex); T_ex=H_ex*3600+M_ex*60+S_ex;
    .print("EVENT | time=",T_ex," | agent=robot_medium | type=expansion_drop_final | data=",CId,",",ShelfId);
    .abolish(expansion_count(CId, _));
    .abolish(expansion_failed_shelf(CId, _));
    +shelf_wait(CId);
    -+carrying(none);
    unclaim_container(CId);
    release_task(CId);
    .send(supervisor, tell, container_error(CId, no_shelf_space));
    .send(scheduler, tell, task_failed(CId));
    !safe_return;
    !check_queue.

-!execute_task(CId, ShelfId) : error(shelf_full, _) & carrying(CId) <-
    .print("⚠️ [MEDIUM] Estantería llena, llevando ", CId, " a zona de expansión");
    .abolish(error(shelf_full, _));
    +expansion_failed_shelf(CId, ShelfId);
    if (expansion_count(CId, N)) {
        N1 = N + 1;
        .abolish(expansion_count(CId, _));
        +expansion_count(CId, N1)
    } else {
        +expansion_count(CId, 1)
    };
    !safe_expand_drop(CId);
    -+carrying(none);
    .time(H_ex,M_ex,S_ex); T_ex=H_ex*3600+M_ex*60+S_ex;
    .print("EVENT | time=",T_ex," | agent=robot_medium | type=expansion_drop | data=",CId,",",ShelfId);
    unclaim_container(CId);
    release_task(CId);
    !safe_return;
    .send(scheduler, tell, container_in_expansion(CId));
    !check_queue.

-!execute_task(CId, ShelfId) : not carrying(CId) & nav_failed(CId) <-
    .wait(2000);
    !safe_return;
    !check_queue.

-!execute_task(CId, ShelfId) : not carrying(CId) <-
    unclaim_container(CId);
    release_task(CId);
    .send(scheduler, tell, task_failed(CId));
    .wait(2000);
    !safe_return;
    !check_queue.

-!execute_task(CId, ShelfId) : true <-
    .print("⚠️ [MEDIUM] Fallo en execute_task para ", CId);
    -+carrying(none);
    unclaim_container(CId);
    release_task(CId);
    .time(H_tf,M_tf,S_tf); T_tf=H_tf*3600+M_tf*60+S_tf;
    .print("EVENT | time=",T_tf," | agent=robot_medium | type=task_failed | data=",CId,",",ShelfId);
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

-!get_to_container(CId, N) : error(container_not_found, _) <-
    .abolish(error(container_not_found, _));
    .print("⚠️ [MEDIUM] Contenedor ", CId, " no existe. Descartando.");
    -+carrying(none);
    release_task(CId);
    .send(scheduler, tell, task_failed(CId));
    .fail.

-!get_to_container(CId, N) : N > 1 <-
    .print("⚠️ [MEDIUM] Reintentando nav a ", CId, " (", N, " intentos restantes)");
    .wait(2000);
    N1 = N - 1;
    !get_to_container(CId, N1).

-!get_to_container(CId, 1) : true <-
    .print("⚠️ [MEDIUM] Inaccesible tras 3 intentos: ", CId);
    -+carrying(none);
    release_task(CId);
    +nav_failed(CId);
    .time(H_nf,M_nf,S_nf); T_nf=H_nf*3600+M_nf*60+S_nf;
    .print("EVENT | time=",T_nf," | agent=robot_medium | type=nav_failed | data=",CId);
    .send(scheduler, tell, task_failed(CId));
    .fail.

+!check_queue : position(InitX, InitY) <-
    .abolish(error(_, _));
    !release_zone(inbound);
    !release_zone(expansion);
    !navigate(InitX, InitY);
    -+state(idle).

-!check_queue : true <-
    .abolish(error(_, _));
    !release_zone(inbound);
    !release_zone(expansion);
    -+state(idle).

/* ============================================================================
 * CICLO DE SALIDA
 * ============================================================================ */

+active_deadline(_, Cat, _) : not state(idle) <-
    +pending_exit_flag(Cat).

+active_deadline(_, Cat, _) : true <- true.

+!check_exit_cycle : pending_exit_flag(Cat) <-
    .abolish(pending_exit_flag(_));
    .findall(pair(CId, ShelfId), (stored(CId, ShelfId) & not exit_claimed(CId)), Candidates);
    !select_for_exit(Candidates, Cat).

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

+!execute_exit(CId, ShelfId) : true <-
    -nav_limit(_); +nav_limit(300);
    .print("🚀 [MEDIUM] Execute exit: ", CId, " desde ", ShelfId);

    move_to_shelf(ShelfId);
    ?nav_target(TX, TY);
    !navigate(TX, TY);

    pickup_from_shelf(CId, ShelfId);
    .wait(600);
    +exit_picked(CId);
    -+state(carrying);

    -nav_limit(_); +nav_limit(300);
    !drop_at_outbound(CId);
    .wait(600);

    .my_name(Me);
    .time(Hd, Md, Sd); Td = Hd * 3600 + Md * 60 + Sd;
    .print("EVENT | time=", Td, " | agent=", Me, " | type=container_delivered | data=", CId);
    -stored(CId, ShelfId);
    .abolish(claimed_type(CId, _));
    .abolish(expansion_failed_shelf(CId, _));
    .abolish(expansion_count(CId, _));
    -exit_picked(CId);
    -+carrying(none);
    !check_queue.

+!return_to_shelf(CId, ShelfId) <-
    -nav_limit(_); +nav_limit(200);
    move_to_shelf(ShelfId);
    ?nav_target(TX, TY);
    !navigate(TX, TY);
    drop_at(ShelfId).

-!return_to_shelf(CId, _) <-
    unclaim_container(CId);
    .abolish(stored(CId, _));
    .abolish(claimed_type(CId, _)).

-!return_to_shelf(_, _) : true <- true.

-!execute_exit(CId, ShelfId) : exit_picked(CId) <-
    .print("⚠️ [MEDIUM] Fallo en execute_exit tras pickup, devolviendo ", CId, " a ", ShelfId);
    -exit_claimed(CId);
    -exit_picked(CId);
    !return_to_shelf(CId, ShelfId);
    -+carrying(none);
    !check_queue.

-!execute_exit(CId, ShelfId) : true <-
    .print("⚠️ [MEDIUM] Fallo en execute_exit para ", CId);
    -exit_claimed(CId);
    -+carrying(none);
    !check_queue.

/* ============================================================================
 * NOTIFICACIÓN DE ESTADO AL SUPERVISOR
 * ============================================================================ */

+state(working) : true <-
    .my_name(Me);
    .send(supervisor, tell, robot_state_change(Me, working)).

+state(idle) : task(CId, ShelfId) <-
    .print("✅ [MEDIUM] Tarea pendiente al quedar idle: ", CId, " → ", ShelfId);
    -task(CId, ShelfId)[source(scheduler)];
    accept_task(CId);
    -+state(working);
    -+carrying(CId);
    !execute_task(CId, ShelfId).

+state(idle) : true <-
    .my_name(Me);
    .send(supervisor, tell, robot_state_change(Me, idle)).

/* ============================================================================
 * MANEJADORES DE ERRORES DEL ENTORNO
 * ============================================================================ */

+error(shelf_full, Data) : true <- true.

+error(container_too_heavy, Data) : carrying(CId) <-
    .send(supervisor, tell, container_error(CId, container_too_heavy));
    -+state(idle); -+carrying(none);
    .abolish(claimed_type(CId, _)).

+error(container_too_big, Data) : carrying(CId) <-
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
    .print("✓ [MEDIUM] ", CId, " recogido").

+stored(CId, ShelfId) : true <-
    .print("✓ [MEDIUM] ", CId, " almacenado en ", ShelfId);
    .time(H_st,M_st,S_st); T_st=H_st*3600+M_st*60+S_st;
    .print("EVENT | time=",T_st," | agent=robot_medium | type=stored | data=",CId,",",ShelfId);
    .send(scheduler, tell, container_stored(CId, ShelfId));
    .send(supervisor, tell, container_stored(CId, ShelfId)).
