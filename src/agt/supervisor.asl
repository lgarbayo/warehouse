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

{ include("common.asl") }

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

/* Errores de carga (executePickup) */
errors_by_type(container_too_heavy, 0).
errors_by_type(container_too_big, 0).
errors_by_type(container_broken, 0).

/* Errores de almacenamiento */
errors_by_type(shelf_full, 0).
errors_by_type(no_shelf_space, 0).

/* Errores de deadline */
errors_by_type(deadline_missed, 0).

/* Errores de estado inconsistente (executeDropAt / executePickup) */
errors_by_type(not_carrying, 0).
errors_by_type(invalid_pickup, 0).
errors_by_type(invalid_drop, 0).
errors_by_type(robot_not_found, 0).

/* Estado de los robots */
robot_status(robot_light, idle).
robot_status(robot_medium, idle).
robot_status(robot_heavy, idle).
robot_status(robot_heavy2, idle).

/* Mutex de zonas críticas */
zone_free(inbound).
zone_free(expansion).
zone_free(outbound).

/* Intervalo del reporte periódico (ms) */
report_interval(30000).

/* Clasificación de estanterías por tipo de contenedor (segunda iteración).
 * urgent    → S1, S5, S8
 * non_urgent → S2, S3, S4, S6, S7, S9 (standard y fragile) */
shelf_type("shelf_1", urgent).
shelf_type("shelf_5", urgent).
shelf_type("shelf_8", urgent).
shelf_type("shelf_2", non_urgent).
shelf_type("shelf_3", non_urgent).
shelf_type("shelf_4", non_urgent).
shelf_type("shelf_6", non_urgent).
shelf_type("shelf_7", non_urgent).
shelf_type("shelf_9", non_urgent).

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

// Actualiza las creencias de tasas derivadas.
// total_stored y total_errors se leen en la guardia (atómica) para evitar la carrera
// en que otra intención borra y re-añade la creencia mientras el cuerpo se ejecuta.
+!update_rates : total_received(Received) & Received > 0 &
                 total_stored(Stored) & total_errors(Error) <-
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

// Imprime errores de contenedor y de robot agrupados por tipo
+!print_errors_by_type : true <-
    .findall(T, errors_by_type(T, _), ContainerTypes);
    !print_error_list(ContainerTypes);
    .findall(T, navigation_error_occurred(_, T, _), NavTypes);
    !print_nav_error_list(NavTypes, []).

+!print_error_list([]) : true <- true.

+!print_error_list([Type|Rest]) : error_occurred(_, Type) <-
    .count(error_occurred(_, Type), N);
    .print("  ", Type, ": ", N);
    !print_error_list(Rest).

+!print_error_list([_|Rest]) : true <-
    !print_error_list(Rest).

// Errores de robot: itera deduplicando con Seen para no repetir tipos
+!print_nav_error_list([], _) : true <- true.

+!print_nav_error_list([T|Rest], Seen) : .member(T, Seen) <-
    !print_nav_error_list(Rest, Seen).

+!print_nav_error_list([T|Rest], Seen) : true <-
    .count(navigation_error_occurred(_, T, _), N);
    .print("  ", T, " (robot): ", N);
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
    ?robot_status(robot_light,   SL);
    ?robot_status(robot_medium,  SM);
    ?robot_status(robot_heavy,   SH);
    ?robot_status(robot_heavy2,  SH2);
    .print("  robot_light: ",   SL);
    .print("  robot_medium: ",  SM);
    .print("  robot_heavy: ",   SH);
    .print("  robot_heavy2: ",  SH2).

/* ============================================================================
 * MONITORIZACIÓN - Contenedores recibidos
 * ============================================================================ */

// Ruta principal: el robot notifica tras reclamar exitosamente (evita race condition
// donde claim_container retira container_at_entrance antes de que el supervisor perciba).
+container_claimed(CId, Type, Weight)[source(Robot)] : not container_received(CId) <-
    +container_received(CId);
    +container_received_type(CId, Type);
    .count(container_received(_), N);
    -total_received(_);
    +total_received(N);
    !update_rates;
    .print("[SUPERVISOR] Nuevo contenedor: ", CId, " (", Type, ", ", Weight, "kg) | Total: ", N).

+container_claimed(CId, Type, Weight)[source(Robot)] : true <- true.

// Ruta de fallback: si el percept llega antes del mensaje del robot.
+container_at_entrance(CId, Type, Weight, W, H) : not container_received(CId) <-
    +container_received(CId);
    +container_received_type(CId, Type);
    .count(container_received(_), N);
    -total_received(_);
    +total_received(N);
    !update_rates;
    .print("[SUPERVISOR] Nuevo contenedor: ", CId, " (", Type, ", ", Weight, "kg) | Total: ", N).

+container_at_entrance(CId, Type, Weight, W, H) : true <- true.

/* ============================================================================
 * MONITORIZACIÓN - Contenedores almacenados
 * Los robots notifican al supervisor tras almacenar con éxito
 * ============================================================================ */

+container_stored(CId, ShelfId)[source(Robot)] : not container_stored_fact(CId, _) <-
    +container_stored_fact(CId, ShelfId);
    .count(container_stored_fact(_,_), N);
    -total_stored(_);
    +total_stored(N);
    !update_rates;
    .print("[SUPERVISOR] Contenedor almacenado: ", CId, " en ", ShelfId, " por ", Robot, " | Total almacenados: ", N).

+container_stored(CId, ShelfId)[source(Robot)] : true <-
    .print("[SUPERVISOR] Re-almacenado: ", CId, " en ", ShelfId, " por ", Robot, " (ya contado)").

/* ============================================================================
 * MONITORIZACIÓN - Errores
 * Los robots notifican al supervisor cuando detectan un error
 * ============================================================================ */

// Errores de robot (navegación, estado inconsistente): registrar en navigation_error_occurred
// y actualizar el total combinado con errores de contenedor.
+robot_error(Robot, ErrorType, Data)[source(_)] : true <-
    if (not navigation_error_occurred(Robot, ErrorType, Data)) {
        +navigation_error_occurred(Robot, ErrorType, Data);
        .count(error_occurred(_,_), CE);
        .count(navigation_error_occurred(_,_,_), NE);
        N = CE + NE;
        -total_errors(_);
        +total_errors(N);
        !update_rates
    }.

+container_error(CId, ErrorType)[source(Robot)] : true <-
    .print("[SUPERVISOR] ERROR en ", CId, " tipo: ", ErrorType, " por ", Robot);
    if (not error_occurred(CId, ErrorType)) {
        +error_occurred(CId, ErrorType);
        .count(error_occurred(_,_), CE);
        .count(navigation_error_occurred(_,_,_), NE);
        N = CE + NE;
        -total_errors(_);
        +total_errors(N);
        !update_rates;
        .print("[SUPERVISOR] Total errores: ", N);
    };
    !maybe_notify_storage_full(CId, ErrorType).

/* ============================================================================
 * DETECCIÓN - Sin espacio de almacenamiento para un tipo de contenedor
 * ============================================================================ */

// Llamado desde +container_error cuando el scheduler no encontró estantería tras reintentos.
// Consulta el tipo del contenedor al scheduler (container_info aún existe en ese momento)
// y, si ese tipo aún no fue notificado, registra T0 y envía storage_full al scheduler.
+!maybe_notify_storage_full(CId, no_shelf_space) : true <-
    !query_container_type_and_notify(CId).

// Cualquier otro tipo de error: sin acción de saturación.
+!maybe_notify_storage_full(_, _) : true <- true.

+!query_container_type_and_notify(CId) : container_received_type(CId, Type) <-
    if (not storage_saturated(Type)) {
        .time(H, M, S);
        T0 = H * 3600 + M * 60 + S;
        +storage_saturated(Type);
        .print("[SUPERVISOR] Almacenamiento saturado para tipo '", Type, "'. T0=", T0, "s. Notificando al scheduler.");
        .send(scheduler, tell, storage_full(Type, T0))
    }.

-!query_container_type_and_notify(CId) : true <-
    .print("[SUPERVISOR] No se pudo determinar el tipo de ", CId, " para notificación de saturación.").

/* ============================================================================
 * DETECCIÓN DE SATURACIÓN POR TIPO DE CONTENEDOR
 * Cuando el entorno retira shelf_available para una estantería, el supervisor
 * comprueba si quedan estanterías disponibles del mismo tipo. Si no queda
 * ninguna, emite el evento obligatorio y notifica al scheduler.
 * no_space_notified(Type) evita emitir el evento más de una vez por tipo.
 * ============================================================================ */

// Secondary path: el entorno retira shelf_available cuando una estantería se llena.
// Si no queda ninguna estantería del mismo tipo de urgencia, notificar al scheduler
// con el string de tipo correcto (no el átomo de urgencia que devuelve shelf_type).
// Separado en dos planes para mapear urgent→"urgent" y non_urgent→tipos almacenados.
-shelf_available(ShelfId) : shelf_type(ShelfId, urgent) & not no_space_notified(urgent) <-
    .findall(S, (shelf_type(S, urgent) & shelf_available(S)), Available);
    if (Available == []) {
        +no_space_notified(urgent);
        .time(H, M, S); T = H * 3600 + M * 60 + S;
        .print("EVENT | time=", T, " | agent=supervisor | type=no_space_detected | data=urgent");
        .send(scheduler, tell, storage_full("urgent", T))
    }.

// Para non_urgent: buscar exactamente qué tipos de container están almacenados en
// estanterías non_urgent para notificar solo los necesarios. Fallback a ambos tipos
// si no hay containers stored aún (arranque del sistema o edge case).
-shelf_available(ShelfId) : shelf_type(ShelfId, non_urgent) & not no_space_notified(non_urgent) <-
    .findall(S, (shelf_type(S, non_urgent) & shelf_available(S)), Available);
    if (Available == []) {
        +no_space_notified(non_urgent);
        .time(H, M, S); T = H * 3600 + M * 60 + S;
        .print("EVENT | time=", T, " | agent=supervisor | type=no_space_detected | data=non_urgent");
        .findall(CType,
            (container_stored_fact(_, SId) & shelf_type(SId, non_urgent) &
             container_received_type(CId2, CType) & container_stored_fact(CId2, SId) &
             non_urgent_container_type(CType)),
            Types);
        if (Types == []) {
            // Fallback: sin información de tipos almacenados, notificar todos los non_urgent
            .send(scheduler, tell, storage_full("standard", T));
            .send(scheduler, tell, storage_full("fragile", T))
        } else {
            !notify_unique_types(Types, T, [])
        }
    }.

// Ignorar retirada de percepciones de estanterías ya notificadas
-shelf_available(_) : true <- true.

// Notifica cada tipo de la lista exactamente una vez (deduplicación sin .list.to.set)
+!notify_unique_types([], _, _) : true <- true.
+!notify_unique_types([Type|Rest], T0, Seen) : .member(Type, Seen) <-
    !notify_unique_types(Rest, T0, Seen).
+!notify_unique_types([Type|Rest], T0, Seen) : true <-
    .send(scheduler, tell, storage_full(Type, T0));
    !notify_unique_types(Rest, T0, [Type|Seen]).

// Cuando se libera espacio, resetear ambos flags para que los ciclos puedan
// dispararse de nuevo en una futura saturación.
+shelf_available(ShelfId) : shelf_type(ShelfId, Type) & no_space_notified(Type) <-
    -no_space_notified(Type).

+shelf_available(ShelfId) : shelf_type(ShelfId, Type) & storage_saturated(Type) <-
    -storage_saturated(Type).

+shelf_available(_) : true <- true.

/* ============================================================================
 * SEGUIMIENTO DE CICLO DE SALIDA
 * El supervisor recibe active_deadline del scheduler para conocer T0 y los
 * deadlines activos. Los robots notifican container_delivered tras cada entrega
 * a outbound. Esto permite al supervisor consultar el estado completo:
 *   - container_received(CId)              → contenedor llegó al sistema
 *   - container_stored_fact(CId, ShelfId)  → contenedor en estantería
 *   - container_delivered_fact(CId)        → contenedor entregado a outbound
 *   - active_deadline(Phase, Cat, T0)      → deadline activo (T0 en segundos)
 *   - .time(H, M, S)                       → tiempo actual del sistema
 * ============================================================================ */

// Arranca el monitor periódico al recibir cada deadline
+active_deadline(Phase, Cat, T0)[source(scheduler)] : true <-
    .time(H, M, S); Tnow = H * 3600 + M * 60 + S;
    .print("[SUPERVISOR] Deadline recibido: fase=", Phase, " urgencia=", Cat, " T0=", T0, "s | ahora=", Tnow, "s");
    !monitor_deadline(Phase, Cat, T0).

// Monitor periódico — deadline urgente (comprueba cada 5s)
+!monitor_deadline(Phase, urgent, T0) :
        active_deadline(Phase, urgent, T0) & not deadline_checked(urgent) <-
    .time(H, M, S); Tnow = H * 3600 + M * 60 + S;
    ?delta_t(DT); Deadline = T0 + DT;
    if (Tnow >= Deadline) {
        +deadline_checked(urgent);
        .findall(CId,
            (container_stored_fact(CId, _) & container_received_type(CId, ContType) &
            urgent_container_type(ContType) & not container_delivered_fact(CId)), Missed);
        !report_deadline_missed(Missed)
    } else {
        .wait(5000);
        !monitor_deadline(Phase, urgent, T0)
    }.

+!monitor_deadline(_, urgent, _) : true <- true.
-!monitor_deadline(_, urgent, _) : true <- true.

// Monitor periódico — deadline no urgente (comprueba cada 5s)
+!monitor_deadline(Phase, non_urgent, T1) :
        active_deadline(Phase, non_urgent, T1) & not deadline_checked(non_urgent) <-
    .time(H, M, S); Tnow = H * 3600 + M * 60 + S;
    ?delta_t(DT); Deadline = T1 + DT * 2;
    if (Tnow >= Deadline) {
        +deadline_checked(non_urgent);
        .findall(CId,
            (container_stored_fact(CId, _) & container_received_type(CId, ContType) &
            non_urgent_container_type(ContType) & not container_delivered_fact(CId)), Missed);
        !report_deadline_missed(Missed)
    } else {
        .wait(5000);
        !monitor_deadline(Phase, non_urgent, T1)
    }.

+!monitor_deadline(_, non_urgent, _) : true <- true.
-!monitor_deadline(_, non_urgent, _) : true <- true.

// deadline_checked(Cat) previene la doble notificación: si el monitor periódico detecta
// el incumplimiento y llama !report_deadline_missed, la creencia bloquea al handler
// de retracción (-active_deadline) para que no vuelva a reportar los mismos contenedores.

// Backup: el scheduler retira la creencia antes de que el monitor detecte el incumplimiento
// (p.ej. el monitor estaba en .wait cuando expiró el plazo)
-active_deadline(_, urgent, _) : not deadline_checked(urgent) <-
    .findall(CId,
        (container_stored_fact(CId, _) & container_received_type(CId, ContType) &
        urgent_container_type(ContType) & not container_delivered_fact(CId)), Missed);
    !report_deadline_missed(Missed);
    -deadline_checked(urgent).

-active_deadline(_, urgent, _) : true <- -deadline_checked(urgent).

-active_deadline(_, non_urgent, _) : not deadline_checked(non_urgent) <-
    .findall(CId,
        (container_stored_fact(CId, _) & container_received_type(CId, ContType) &
        non_urgent_container_type(ContType) & not container_delivered_fact(CId)), Missed);
    !report_deadline_missed(Missed);
    -deadline_checked(non_urgent).

-active_deadline(_, non_urgent, _) : true <- -deadline_checked(non_urgent).

+!report_deadline_missed([]) : true <- true.
+!report_deadline_missed([CId|Rest]) : true <-
    .time(H, M, S); T = H * 3600 + M * 60 + S;
    .print("EVENT | time=", T, " | agent=supervisor | type=deadline_missed | data=", CId);
    if (not error_occurred(CId, deadline_missed)) {
        +error_occurred(CId, deadline_missed);
        .count(error_occurred(_, _), CE);
        .count(navigation_error_occurred(_, _, _), NE);
        N = CE + NE;
        -total_errors(_);
        +total_errors(N);
        !update_rates
    };
    !report_deadline_missed(Rest).
-!report_deadline_missed(_) : true <- true.

+container_delivered(CId)[source(Robot)] : not container_delivered_fact(CId) <-
    +container_delivered_fact(CId).

+container_delivered(CId)[source(Robot)] : true <- true.

/* ============================================================================
 * MUTEX DE ZONA - Acceso exclusivo a zonas críticas
 * ============================================================================ */

// Mutex de zona: el supervisor actúa como árbitro centralizado.
// Si la zona está libre, se concede directamente. Si está ocupada, se encola al robot
// solicitante (máximo un robot en cola por zona; intentos duplicados del mismo robot se ignoran).
// Al liberar, si hay robot en cola se le transfiere la zona sin pasar por zone_free,
// garantizando exclusión mutua estricta sin polling activo por parte de los robots.
+request_zone(Zone)[source(Robot)] : zone_free(Zone) <-
    -zone_free(Zone);
    +zone_held(Zone, Robot);
    .send(Robot, tell, zone_granted(Zone)).

+request_zone(Zone)[source(Robot)] : zone_held(Zone, _) & not zone_queued(Zone, Robot) <-
    +zone_queued(Zone, Robot).

+request_zone(Zone)[source(Robot)] : zone_held(Zone, _) <- true.

+release_zone(Zone)[source(Robot)] : zone_queued(Zone, Next) <-
    -zone_held(Zone, Robot);
    -zone_queued(Zone, Next);
    +zone_held(Zone, Next);
    .send(Next, tell, zone_granted(Zone)).

+release_zone(Zone)[source(Robot)] : true <-
    -zone_held(Zone, _);
    +zone_free(Zone).

