/*******************************************************************************
 * SCHEDULER - Agente de Gestión de Ciclos de Salida
 *
 * Universidad de Vigo - Sistemas Inteligentes
 * Curso 2025-2026
 *
 * RESPONSABILIDADES:
 *   1. Recibir notificaciones del supervisor sobre saturación de almacenamiento.
 *   2. Activar el ciclo de salida del tipo de contenedor correspondiente.
 *   3. Bloquear tipos de contenedor hasta que haya espacio disponible.
 *   4. Coordinar con el agente Transport al finalizar cada deadline.
 *
 * Los robots operan de forma completamente autónoma (ciclo inbound):
 *   - reclaman contenedores directamente desde +container_at_entrance
 *   - seleccionan estanterías usando !pick_shelf (common.asl)
 *   - no requieren asignación explícita del scheduler
 ******************************************************************************/

{ include("common.asl") }

/* ============================================================================
 * CREENCIAS INICIALES
 * ============================================================================ */

robot_capacity(robot_light,  10,  1, 1, 3).
robot_capacity(robot_medium, 30,  1, 2, 2).
robot_capacity(robot_heavy,  100, 2, 3, 1).
robot_capacity(robot_heavy2, 100, 2, 3, 1).

/* Asignación de estanterías por urgencia y categoría de tamaño.
 * shelf_for(Urgency, SizeCategory, ShelfId) */
shelf_for(urgent,     light,  "shelf_1").
shelf_for(urgent,     medium, "shelf_5").
shelf_for(urgent,     heavy,  "shelf_8").
shelf_for(non_urgent, light,  "shelf_2").
shelf_for(non_urgent, light,  "shelf_3").
shelf_for(non_urgent, light,  "shelf_4").
shelf_for(non_urgent, medium, "shelf_6").
shelf_for(non_urgent, medium, "shelf_7").
shelf_for(non_urgent, heavy,  "shelf_9").

/* ============================================================================
 * REGLAS
 * ============================================================================ */


/* ============================================================================
 * SEGUIMIENTO DE ALMACENAMIENTO (necesario para ciclo de salida)
 * ============================================================================ */

+container_stored(CId, ShelfId)[source(Robot)] : true <-
    .print("✨ [TRACE] ", Robot, " almacenó ", CId, " en ", ShelfId);
    +stored_at(CId, ShelfId);
    -container_stored(CId, ShelfId)[source(Robot)].

/* ============================================================================
 * MENSAJES INBOUND — no-ops (robots autónomos, no requieren respuesta)
 * ============================================================================ */

+task_failed(CId)[source(Robot)] : true <-
    -task_failed(CId)[source(Robot)].

+container_in_expansion(CId)[source(Robot)] : true <-
    -container_in_expansion(CId)[source(Robot)].

+request_task[source(Robot)] : true <-
    -request_task[source(Robot)].

/* ============================================================================
 * CICLO DE SALIDA — Recepción del aviso de saturación del supervisor
 * ============================================================================ */

+storage_full(Type, _)[source(supervisor)] : not exit_cycle(Type, _) <-
    +blocked_type(Type);
    .time(H, M, S);
    T0 = H * 3600 + M * 60 + S;
    .print("EVENT | time=", T0, " | agent=scheduler | type=output_phase_started | data=", Type);
    +exit_cycle(Type, T0);
    .abolish(storage_full(Type, _)).

+storage_full(Type, _)[source(supervisor)] : exit_cycle(Type, T0existing) <-
    .abolish(storage_full(Type, _));
    .print("[SCHEDULER] Ciclo de salida para '", Type, "' ya activo (T0=", T0existing, "s). Ignorando.").

+no_shelf_space(ContainerType)[source(supervisor)] : not exit_cycle(ContainerType, _) <-
    +blocked_type(ContainerType);
    .time(H, M, S);
    T0 = H * 3600 + M * 60 + S;
    .print("EVENT | time=", T0, " | agent=scheduler | type=output_phase_started | data=", ContainerType);
    +exit_cycle(ContainerType, T0).

+no_shelf_space(ContainerType)[source(supervisor)] : exit_cycle(ContainerType, _) <-
    .print("[SCHEDULER] Ciclo de salida para '", ContainerType, "' ya activo. Ignorando.").

/* ============================================================================
 * CICLO DE SALIDA — Gestión de deadlines
 * ============================================================================ */

// active_exit_cycle garantiza que solo un ciclo corre a la vez. Si llega un segundo
// aviso de saturación mientras el ciclo actual está en marcha, el tipo queda bloqueado
// (blocked_type) pero no se lanza un segundo ciclo concurrente; se procesará en el
// siguiente ciclo cuando active_exit_cycle ya no esté en la base de creencias.
+exit_cycle(Type, T0) : not active_exit_cycle <-
    +active_exit_cycle;
    !run_exit_cycle(Type, T0).

+exit_cycle(Type, T0) : active_exit_cycle <-
    .print("[SCHEDULER] Ciclo de salida ya activo. Tipo '", Type, "' permanecerá bloqueado hasta que finalice.").

+!run_exit_cycle(Type, T0) : delta_t(DT) <-
    .findall(R, robot_capacity(R, _, _, _, _), AllRobots);
    for (.member(R, AllRobots)) { .send(R, tell, blocked_type(Type)); };

    // ---- Deadline corto: [T0, T0+ΔT) — salen contenedores urgentes ----
    +active_deadline(short, urgent, T0);
    for (.member(R, AllRobots)) { .send(R, tell, active_deadline(short, urgent, T0)); };
    .send(supervisor, tell, active_deadline(short, urgent, T0));
    .time(H1, M1, S1); Tstart1 = H1 * 3600 + M1 * 60 + S1;
    .print("EVENT | time=", Tstart1, " | agent=scheduler | type=deadline_started | data=urgent");
    DurShort = DT * 1000;  // ΔT en segundos → ms para .wait
    .wait(DurShort);
    -active_deadline(short, urgent, T0);
    for (.member(R, AllRobots)) { .send(R, untell, active_deadline(short, urgent, T0)); };
    .send(supervisor, untell, active_deadline(short, urgent, T0));
    .time(H2, M2, S2); Tend1 = H2 * 3600 + M2 * 60 + S2;
    .print("EVENT | time=", Tend1, " | agent=scheduler | type=deadline_ended | data=urgent");
    .send(transport, tell, transport_request(urgent, short));

    // ---- Deadline largo: [T0+ΔT, T0+3·ΔT) — salen contenedores no urgentes ----
    // T1 = T0+ΔT: la fase no urgente arranca justo cuando termina la urgente.
    // La ventana es 2·ΔT porque los robots no urgentes son más y las estanterías más lejanas.
    T1 = T0 + DT;
    +active_deadline(long, non_urgent, T1);
    for (.member(R, AllRobots)) { .send(R, tell, active_deadline(long, non_urgent, T1)); };
    .send(supervisor, tell, active_deadline(long, non_urgent, T1));
    .time(H3, M3, S3); Tstart2 = H3 * 3600 + M3 * 60 + S3;
    .print("EVENT | time=", Tstart2, " | agent=scheduler | type=deadline_started | data=non_urgent");
    DurLong = DT * 2 * 1000;  // 2·ΔT en ms
    .wait(DurLong);
    -active_deadline(long, non_urgent, T1);
    for (.member(R, AllRobots)) { .send(R, untell, active_deadline(long, non_urgent, T1)); };
    .send(supervisor, untell, active_deadline(long, non_urgent, T1));
    .time(H4, M4, S4); Tend2 = H4 * 3600 + M4 * 60 + S4;
    .print("EVENT | time=", Tend2, " | agent=scheduler | type=deadline_ended | data=non_urgent");
    .send(transport, tell, transport_request(non_urgent, long));

    // Limpieza: desbloquear tipos y liberar flag de ciclo activo
    for (.member(R, AllRobots)) { .send(R, untell, blocked_type(Type)); };
    .abolish(exit_cycle(_, _));
    .abolish(blocked_type(_));
    -active_exit_cycle.

/* ============================================================================
 * DESBLOQUEO AL RECUPERAR ESPACIO
 * ============================================================================ */

+shelf_available(ShelfId) : blocked_type(Type) & shelf_for(Type, _, ShelfId) <-
    -blocked_type(Type);
    .print("[SCHEDULER] Tipo ", Type, " desbloqueado — espacio disponible en ", ShelfId).

+shelf_available(_) : true <- true.

/* ============================================================================
 * CONTENEDOR ENTREGADO A ZONA DE SALIDA
 * ============================================================================ */

+container_exited(CId) : stored_at(CId, ShelfId) <-
    .print("✅ [SCHEDULER] ", CId, " entregado a zona de salida");
    -stored_at(CId, ShelfId).

+container_exited(CId) : true <-
    .print("✅ [SCHEDULER] ", CId, " entregado a zona de salida").
