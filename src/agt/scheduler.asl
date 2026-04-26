/*******************************************************************************
 * SCHEDULER - Agente de Control Temporal y Coordinación de Salida
 *
 * Universidad de Vigo - Sistemas Inteligentes
 * Curso 2025-2026
 *
 * RESPONSABILIDADES (2ª iteración):
 *   1. Gestionar deadlines de salida (exit cycle)
 *   2. Activar ciclos de salida urgente / no urgente
 *   3. Rastrear fallos permanentes de contenedores
 *   4. Coordinar con supervisor
 *
 * Los robots seleccionan autónomamente sus contenedores y estanterías.
 ******************************************************************************/

{ include("common.asl") }

/* ============================================================================
 * MANEJO DE FALLOS REPORTADOS POR ROBOTS
 * ============================================================================ */

+task_failed(CId)[source(Robot)] : container_permanently_failed(CId) <-
    -task_failed(CId)[source(Robot)].

+task_failed(CId)[source(Robot)] : container_requeue_count(CId, N) & N >= 2 <-
    .print("❌ [SCHEDULER] ", CId, " inaccesible definitivamente tras 3 intentos. Descartando.");
    +container_permanently_failed(CId);
    -task_failed(CId)[source(Robot)];
    -container_requeue_count(CId, _);
    discard_container(CId);
    .send(supervisor, tell, container_error(CId, unreachable)).

+task_failed(CId)[source(Robot)] : container_requeue_count(CId, N) <-
    N1 = N + 1;
    -container_requeue_count(CId, _);
    +container_requeue_count(CId, N1);
    -task_failed(CId)[source(Robot)].

+task_failed(CId)[source(Robot)] : true <-
    +container_requeue_count(CId, 1);
    -task_failed(CId)[source(Robot)].

/* ============================================================================
 * CONTENEDOR ENTREGADO A ZONA DE SALIDA
 * ============================================================================ */

+container_exited(CId) : true <-
    .print("✅ [SCHEDULER] ", CId, " entregado a zona de salida").

/* ============================================================================
 * CICLO DE SALIDA - Recepción del aviso de saturación del supervisor
 * ============================================================================ */

+storage_full(Type, _)[source(supervisor)] : not exit_cycle(Type, _) <-
    .time(H, M, S);
    T0 = H * 3600 + M * 60 + S;
    +exit_cycle(Type, T0);
    .abolish(storage_full(Type, _));
    .print("[SCHEDULER] ⛔ Ciclo de salida activado para tipo '", Type, "'. T0=", T0, "s.").

+storage_full(Type, _)[source(supervisor)] : exit_cycle(Type, T0existing) <-
    .abolish(storage_full(Type, _));
    .print("[SCHEDULER] Ciclo de salida para '", Type, "' ya activo (T0=", T0existing, "s). Ignorando.").

/* ============================================================================
 * CICLO DE SALIDA - Gestión de deadlines
 * ============================================================================ */

+exit_cycle(Type, T0) : true <-
    !run_exit_cycle(Type, T0).

+!run_exit_cycle(Type, T0) : delta_t(DT) <-

    // ---- Deadline corto: [T0, T0+ΔT) — salen contenedores urgentes ----
    +active_deadline(short, urgent, T0);
    .time(H1, M1, S1);
    Tstart1 = H1 * 3600 + M1 * 60 + S1;
    warehouse.log_event("EVENT | time=", Tstart1, " | agent=scheduler | type=deadline_started | data=urgent");
    .print("[SCHEDULER] EVENT deadline_started urgent T=", Tstart1);
    DurShort = DT * 1000;
    .wait(DurShort);
    -active_deadline(short, urgent, T0);
    .time(H2, M2, S2);
    Tend1 = H2 * 3600 + M2 * 60 + S2;
    warehouse.log_event("EVENT | time=", Tend1, " | agent=scheduler | type=deadline_ended | data=urgent");
    .print("[SCHEDULER] EVENT deadline_ended urgent T=", Tend1);

    // ---- Deadline largo: [T0+ΔT, T0+3·ΔT) — salen contenedores no urgentes ----
    T1 = T0 + DT;
    +active_deadline(long, non_urgent, T1);
    .time(H3, M3, S3);
    Tstart2 = H3 * 3600 + M3 * 60 + S3;
    warehouse.log_event("EVENT | time=", Tstart2, " | agent=scheduler | type=deadline_started | data=non_urgent");
    .print("[SCHEDULER] EVENT deadline_started non_urgent T=", Tstart2);
    DurLong = DT * 2 * 1000;
    .wait(DurLong);
    -active_deadline(long, non_urgent, T1);
    .time(H4, M4, S4);
    Tend2 = H4 * 3600 + M4 * 60 + S4;
    warehouse.log_event("EVENT | time=", Tend2, " | agent=scheduler | type=deadline_ended | data=non_urgent");
    .print("[SCHEDULER] EVENT deadline_ended non_urgent T=", Tend2).
