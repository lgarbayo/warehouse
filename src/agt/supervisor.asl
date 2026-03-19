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

/* Estado de los robots */
robot_status(robot_light, idle).
robot_status(robot_medium, idle).
robot_status(robot_heavy, idle).

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

// Con contenedores recibidos: calcular tasas
+!print_stats : container_received(_) <-
    Received = .count(container_received(_));
    Stored = .count(container_stored_fact(_,_));
    Errors = .count(error_occurred(_,_));
    SuccessRate = (Stored * 100) / Received;
    ErrorRate   = (Errors * 100) / Received;
    Pending     = Received - Stored - Errors;
    .print("========================================");
    .print("[SUPERVISOR] REPORTE DE ESTADISTICAS");
    .print("Contenedores recibidos: ", Received);
    .print("Contenedores almacenados: ", Stored, " (", SuccessRate, "%)");
    .print("Contenedores con error: ", Errors, " (", ErrorRate, "%)");
    .print("Pendientes en proceso: ", Pending);
    .print("Errores por tipo: ");
    !print_errors_by_type;
    .print("Estado de robots: ");
    !print_robot_status;
    .print("========================================").

// Sin contenedores aún: evitar división por cero (pero sí imprime robots)
+!print_stats : true <-
    .print("========================================");
    .print("[SUPERVISOR] REPORTE DE ESTADISTICAS");
    .print("Sin contenedores recibidos aun.");
    .print("Estado de robots: ");
    !print_robot_status;
    .print("========================================").

// Recorre los tipos de error conocidos con recursión
+!print_errors_by_type : true <-
    .findall(T, errors_by_type(T, _), Types);
    !print_error_list(Types).

+!print_error_list([]) : true <- true.

+!print_error_list([Type|Rest]) : error_occurred(_, Type) <-
    N = .count(error_occurred(_, Type));
    .print("  ", Type, ": ", N);
    !print_error_list(Rest).

+!print_error_list([_|Rest]) : true <-
    !print_error_list(Rest).

/* ============================================================================
 * MONITORIZACIÓN - Estado de los robots
 * Los robots notifican al supervisor cuando cambian a idle o working
 * ============================================================================ */

+robot_state_change(Robot, Status)[source(_)] : true <-
    -robot_status(Robot, _);
    +robot_status(Robot, Status);
    .print("[SUPERVISOR] ", Robot, ": ", Status).

+!print_robot_status : true <-
    .send(robot_light,  askOne, state(SL), state(SL));
    .send(robot_medium, askOne, state(SM), state(SM));
    .send(robot_heavy,  askOne, state(SH), state(SH));
    .print("  robot_light: ",  SL);
    .print("  robot_medium: ", SM);
    .print("  robot_heavy: ",  SH).

/* ============================================================================
 * MONITORIZACIÓN - Contenedores recibidos
 * ============================================================================ */

// new_container es global: el supervisor lo percibe directamente del entorno
+new_container(CId) : true <-
    +container_received(CId);
    N = .count(container_received(_));
    .print("[SUPERVISOR] Nuevo contenedor recibido: ", CId, " | Total recibidos: ", N).

/* ============================================================================
 * MONITORIZACIÓN - Contenedores almacenados
 * Los robots notifican al supervisor tras almacenar con éxito
 * ============================================================================ */

+container_stored(CId, ShelfId)[source(Robot)] : true <-
    +container_stored_fact(CId, ShelfId);
    N = .count(container_stored_fact(_,_));
    .print("[SUPERVISOR] Contenedor almacenado: ", CId, " en ", ShelfId, " por ", Robot, " | Total almacenados: ", N).

/* ============================================================================
 * MONITORIZACIÓN - Errores
 * Los robots notifican al supervisor cuando detectan un error
 * ============================================================================ */

+container_error(CId, ErrorType)[source(Robot)] : true <-
    +error_occurred(CId, ErrorType);
    N = .count(error_occurred(_,_));
    .print("[SUPERVISOR] ERROR en ", CId, " tipo: ", ErrorType, " por ", Robot, " | Total errores: ", N).

// Errores de navegacion enviados directamente desde Java (sin CId: route_blocked, etc.)
+robot_error(Robot, ErrorType, Data) : true <-
    +navigation_error_occurred(Robot, ErrorType);
    .print("[SUPERVISOR] Error de navegacion en ", Robot, ": ", ErrorType).

