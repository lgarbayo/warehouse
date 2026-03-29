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

/* Tasas derivadas */
success_rate(0).
error_rate(0).
pending(0).

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

// Actualiza las creencias de tasas derivadas
+!update_rates : total_received(Received) & Received > 0 <-
    ?total_stored(Stored);
    ?total_errors(Error);
    SuccessRate = (Stored * 100) / Received;
    ErrorRate   = (Error * 100) / Received;
    Pending     = Received - Stored - Error;
    -success_rate(_); 
    +success_rate(SuccessRate);
    -error_rate(_);   
    +error_rate(ErrorRate);
    -pending(_);      
    +pending(Pending).

// Fallback para evitar división por cero antes de recibir contenedores
+!update_rates : true <- true.

// Con contenedores recibidos: calcular tasas
+!print_stats : container_received(_) <-
    ?total_received(Received);
    ?total_stored(Stored);
    ?total_errors(Errors);
    ?success_rate(SuccessRate);
    ?error_rate(ErrorRate);
    ?pending(Pending);
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

// Imprime errores de contenedor y de navegación agrupados por tipo
+!print_errors_by_type : true <-
    .findall(T, errors_by_type(T, _), ContainerTypes);
    !print_error_list(ContainerTypes);
    .findall(T, navigation_error_occurred(_, T), NavTypes);
    !print_nav_error_list(NavTypes, []).

+!print_error_list([]) : true <- true.

+!print_error_list([Type|Rest]) : error_occurred(_, Type) <-
    .count(error_occurred(_, Type), N);
    .print("  ", Type, ": ", N);
    !print_error_list(Rest).

+!print_error_list([_|Rest]) : true <-
    !print_error_list(Rest).

// Navegación: itera la lista deduplicando con Seen
+!print_nav_error_list([], _) : true <- true.

+!print_nav_error_list([T|Rest], Seen) : .member(T, Seen) <-
    !print_nav_error_list(Rest, Seen).

+!print_nav_error_list([T|Rest], Seen) : true <-
    .count(navigation_error_occurred(_, T), N);
    .print("  ", T, " (nav): ", N);
    !print_nav_error_list(Rest, [T|Seen]).

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
    .count(container_received(_), N);
    -total_received(_);
    +total_received(N);
    !update_rates;
    .print("[SUPERVISOR] Nuevo contenedor recibido: ", CId, " | Total recibidos: ", N).

/* ============================================================================
 * MONITORIZACIÓN - Contenedores almacenados
 * Los robots notifican al supervisor tras almacenar con éxito
 * ============================================================================ */

+container_stored(CId, ShelfId)[source(Robot)] : true <-
    +container_stored_fact(CId, ShelfId);
    .count(container_stored_fact(_,_), N);
    -total_stored(_);
    +total_stored(N);
    !update_rates;
    .print("[SUPERVISOR] Contenedor almacenado: ", CId, " en ", ShelfId, " por ", Robot, " | Total almacenados: ", N).

/* ============================================================================
 * MONITORIZACIÓN - Errores
 * Los robots notifican al supervisor cuando detectan un error
 * ============================================================================ */

+container_error(CId, ErrorType)[source(Robot)] : true <-
    +error_occurred(CId, ErrorType);
    .count(error_occurred(_,_), N);
    -total_errors(_);
    +total_errors(N);
    !update_rates;
    .print("[SUPERVISOR] ERROR en ", CId, " tipo: ", ErrorType, " por ", Robot, " | Total errores: ", N).

// Errores de navegacion enviados directamente desde Java (sin CId: route_blocked, etc.)
+robot_error(Robot, ErrorType, Data) : true <-
    +navigation_error_occurred(Robot, ErrorType);
    .print("[SUPERVISOR] Error de navegacion en ", Robot, ": ", ErrorType).

