package warehouse;

/**
 * Tipos de celdas en el almacén
 */
public enum CellType {
    EMPTY,          // Pasillo vacío — navegable por robots
    ENTRANCE,       // Zona de entrada — donde aparecen los contenedores (spawn)
    CLASSIFICATION, // Zona de clasificación — área intermedia entre entrada y estanterías
    OUTBOUND,       // Zona de salida — lado opuesto a la entrada; destino de drop_in_outbound
    STORAGE,        // Área de almacenamiento genérica (no usada actualmente)
    SHELF,          // Estantería — obstáculo para BFS; destino lógico de drop_at
    BLOCKED,        // Celda inaccesible permanentemente
    ROBOT           // Reservado; los robots se pintan sobre el grid pero no modifican
                        // el tipo de celda: su posición se gestiona en el mapa 'robots'
}
