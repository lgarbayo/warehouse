/*******************************************************************************
 * SUPERVISOR - Agente de Monitorización y Gestión de Errores
 * 
 * Universidad de Vigo - Sistemas Inteligentes
 * Curso 2025-2026
 * 
 * RESPONSABILIDADES:
 *   1. Monitorizar el estado global del sistema
 *   2. Detectar anomalías y errores
 *   3. Coordinar recuperación de errores
 *   4. Mantener métricas de rendimiento
 *   5. Identificar cuellos de botella
 *   6. Generar reportes y análisis
 * 
 ******************************************************************************/

/* ============================================================================
 * CREENCIAS INICIALES
 * ============================================================================ */

/* Contadores principales */
total_received(0).
total_stored(0).
total_errors(0).

/* Errores por tipo */
errors_by_type(container_too_heavy, 0).
errors_by_type(container_too_big, 0).
errors_by_type(shelf_full, 0).
errors_by_type(illegal_move, 0).
errors_by_type(conflict, 0).
errors_by_type(route_blocked, 0).

/* Intervalo del reporte periódico (ms) */
report_interval(30000).

/* ============================================================================
 * ARRANQUE - Lanza el ciclo de reportes periódico
 * ============================================================================ */

!start.

+!start : true <-
    .print("[SUPERVISOR] Iniciado. Reporte cada 30 segundos.");
    !stats_loop.

+!stats_loop : true <-
    ?report_interval(Interval);
    .wait(Interval);
    !print_stats;
    !stats_loop.

/* ============================================================================
 * CÁLCULO Y REPORTE DE ESTADÍSTICAS
 * ============================================================================ */

+!print_stats :
        total_received(Received) & total_stored(Stored) & total_errors(Errors) <-
    // Tasa de éxito y error (evitar división por cero)
    if (Received > 0) {
        SuccessRate is (Stored * 100) / Received;
        ErrorRate   is (Errors * 100) / Received;
    } else {
        SuccessRate = 0;
        ErrorRate   = 0;
    };
    Pending is Received - Stored - Errors;

    .print("========================================");
    .print("[SUPERVISOR] REPORTE DE ESTADISTICAS");
    .print("Contenedores recibidos: ", Received);
    .print("Contenedores almacenados: ", Stored, " (", SuccessRate, "%)");
    .print("Contenedores con error: ", Errors, " (", ErrorRate,   "%)");
    .print("Pendientes en proceso: ", Pending);
    .print("Errores por tipo: ");
    !print_errors_by_type;
    .print("========================================").

// Imprime cada tipo de error con su contador
+!print_errors_by_type : true <-
    .findall(T-C, errors_by_type(T, C), Pairs);
    for (.member(Type-Count, Pairs)) {
        if (Count > 0) {
            .print("    ", Type, ": ", Count)
        }
    }.

/* ============================================================================
 * MONITORIZACIÓN - Contenedores recibidos
 * ============================================================================ */

// new_container es global: el supervisor lo percibe directamente del entorno
+new_container(CId) : total_received(N) <-
    .print("[SUPERVISOR] Nuevo contenedor recibido: ", CId, " | Total recibidos: ", N + 1);
    -+total_received(N + 1).

/* ============================================================================
 * MONITORIZACIÓN - Contenedores almacenados
 * Los robots notifican al supervisor tras almacenar con éxito
 * ============================================================================ */

+container_stored(CId, ShelfId)[source(Robot)] : total_stored(N) <-
    .print("[SUPERVISOR] Contenedor almacenado: ", CId, " en ", ShelfId, " por ", Robot, " | Total almacenados: ", N + 1);
    -+total_stored(N + 1).

/* ============================================================================
 * MONITORIZACIÓN - Errores
 * Los robots notifican al supervisor cuando detectan un error
 * ============================================================================ */

+container_error(CId, ErrorType)[source(Robot)] :
        total_errors(N) & errors_by_type(ErrorType, M) <-
    .print("[SUPERVISOR] ERROR en ", CId, " tipo: ", ErrorType, " por ", Robot,
           " | Total errores: ", N + 1);
    -+total_errors(N + 1);
    -errors_by_type(ErrorType, M);
    +errors_by_type(ErrorType, M + 1).

// Error de tipo desconocido (no estaba en la lista inicial)
+container_error(CId, ErrorType)[source(Robot)] :
        total_errors(N) & not errors_by_type(ErrorType, _) <-
    .print("[SUPERVISOR] ERROR (nuevo tipo) en ", CId, " tipo: ", ErrorType, " por ", Robot,
           " | Total errores: ", N + 1);
    -+total_errors(N + 1);
    +errors_by_type(ErrorType, 1).

