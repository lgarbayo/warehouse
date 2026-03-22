package warehouse;

import jason.asSyntax.*;
import jason.environment.Environment;

import java.util.*;
import java.util.concurrent.*;
import java.util.stream.Collectors;

/**
 * Artefacto del almacén automatizado Proporciona la API para que los agentes
 * interactúen con el entorno
 */

public class WarehouseArtifact extends Environment {

    // Dimensiones del almacén
    private static final int GRID_WIDTH = 20;
    private static final int GRID_HEIGHT = 15;

    // Estructuras de datos del almacén
    private CellType[][] grid;
    private Map<String, Robot> robots;
    private Map<String, Container> containers;
    private Map<String, Shelf> shelves;
    private ConcurrentLinkedQueue<Container> pendingContainers;
    private Map<String, String> taskAssignments; // containerId -> robotId

    // Mapa de destinos activos: clave "(X,Y)" → nombre del robot que lo ha reservado.
    // Evita que dos robots calculen BFS al mismo destino simultáneamente y lleguen
    // a la misma celda. La clave es la coordenada (no el agente) para que el bloque
    // finally de doMoveTo la libere correctamente aunque el robot cambie de ruta.
    private Map<String, String> activeDestinations;

    // GUI visual
    private WarehouseView view;

    // Contadores para generar IDs
    private int containerCounter = 0;

    // Métricas
    private int totalContainersProcessed = 0;
    private int totalErrors = 0;
    private long startTime;

    // Gestión del thread generador de contenedores
    private ExecutorService containerGeneratorExecutor;
    private volatile boolean running = true;

    @Override
    public void init(String[] args) {
        super.init(args);

        // Inicializar estructuras
        grid = new CellType[GRID_WIDTH][GRID_HEIGHT];
        robots = new ConcurrentHashMap<>();
        containers = new ConcurrentHashMap<>();
        shelves = new ConcurrentHashMap<>();
        pendingContainers = new ConcurrentLinkedQueue<>();
        taskAssignments = new ConcurrentHashMap<>();
        activeDestinations = new ConcurrentHashMap<>();

        // Inicializar grid
        initializeGrid();

        // Crear robots
        initializeRobots();

        // Crear estanterías
        initializeShelves();

        // Crear GUI
        view = new WarehouseView(this, GRID_WIDTH, GRID_HEIGHT);
        view.setVisible(true);

        // Mensaje de bienvenida en la consola
        view.logMessage("✨ ========================================");
        view.logMessage("🏢 Warehouse Management System Initialized");
        view.logMessage("   Grid: " + GRID_WIDTH + "x" + GRID_HEIGHT);
        view.logMessage("   Robots: " + robots.size());
        view.logMessage("   Shelves: " + shelves.size());
        view.logMessage("✨ ========================================");
        view.logMessage("");

        // Iniciar generador de contenedores
        startContainerGenerator();

        // Agregar shutdown hook para limpieza apropiada
        Runtime.getRuntime().addShutdownHook(new Thread(this::stop));

        startTime = System.currentTimeMillis();

        System.out.println("Warehouse environment initialized");
        System.out.println("Grid size: " + GRID_WIDTH + "x" + GRID_HEIGHT);
        System.out.println("Robots: " + robots.size());
        System.out.println("Shelves: " + shelves.size());
    }

    /**
     * Inicializa el grid con zonas
     */
    private void initializeGrid() {
        // Inicializar todos como vacíos
        for (int x = 0; x < GRID_WIDTH; x++) {
            for (int y = 0; y < GRID_HEIGHT; y++) {
                grid[x][y] = CellType.EMPTY;
            }
        }

        // Zona de entrada (arriba izquierda)
        for (int x = 0; x < 3; x++) {
            for (int y = 0; y < 2; y++) {
                grid[x][y] = CellType.ENTRANCE;
            }
        }

        // Zona de clasificación
        for (int x = 3; x < 7; x++) {
            for (int y = 0; y < 2; y++) {
                grid[x][y] = CellType.CLASSIFICATION;
            }
        }
    }

    /**
     * Crea los robots iniciales
     */
    private void initializeRobots() {
        Robot light = new Robot("robot_light", "light", 10, 1, 1, 3);
        light.setPosition(1, 3);
        robots.put("robot_light", light);

        Robot medium = new Robot("robot_medium", "medium", 30, 1, 2, 2);
        medium.setPosition(2, 3);
        robots.put("robot_medium", medium);

        Robot heavy = new Robot("robot_heavy", "heavy", 100, 2, 3, 1);
        heavy.setPosition(3, 3);
        robots.put("robot_heavy", heavy);
    }

    /**
     * Crea las estanterías del almacén
     */
    private void initializeShelves() {
        // Crear estanterías en el área de almacenamiento
        int shelfId = 1;

        // Fila de estanterías pequeñas
        for (int x = 10; x < 18; x += 2) {
            Shelf shelf = new Shelf("shelf_" + shelfId++, x, 2, 2, 2, 50, 8);
            shelves.put(shelf.getId(), shelf);
            grid[x][2] = CellType.SHELF;
            grid[x + 1][2] = CellType.SHELF;
            grid[x][3] = CellType.SHELF;
            grid[x + 1][3] = CellType.SHELF;
        }

        // Fila de estanterías medianas
        for (int x = 10; x < 18; x += 3) {
            Shelf shelf = new Shelf("shelf_" + shelfId++, x, 6, 3, 2, 100, 12);
            shelves.put(shelf.getId(), shelf);
            for (int dx = 0; dx < 3; dx++) {
                grid[x + dx][6] = CellType.SHELF;
                grid[x + dx][7] = CellType.SHELF;
            }
        }

        // Fila de estanterías grandes
        for (int x = 10; x < 16; x += 4) {
            Shelf shelf = new Shelf("shelf_" + shelfId++, x, 10, 4, 3, 200, 20);
            shelves.put(shelf.getId(), shelf);
            for (int dx = 0; dx < 4; dx++) {
                for (int dy = 0; dy < 3; dy++) {
                    grid[x + dx][10 + dy] = CellType.SHELF;
                }
            }
        }
    }

    /**
     * Inicia el generador automático de contenedores
     */
    private void startContainerGenerator() {
        containerGeneratorExecutor = Executors.newSingleThreadExecutor(r -> {
            Thread t = new Thread(r, "ContainerGenerator");
            t.setDaemon(true);
            return t;
        });

        containerGeneratorExecutor.submit(() -> {
            Random rand = new Random();
            while (running) {
                try {
                    Thread.sleep(5000 + rand.nextInt(5000)); // Entre 5 y 10 segundos

                    if (!running)
                        break;

                    // Generar contenedor aleatorio
                    Container container = generateRandomContainer();
                    containers.put(container.getId(), container);
                    pendingContainers.offer(container);

                    System.out.println("New container generated: " + container);

                    // Log a la consola de la GUI
                    if (view != null) {
                        view.logMessage(String.format("🆕 New container: %s (%.1fkg, %s)",
                                container.getId(), container.getWeight(), container.getType()));
                    }

                    // Notificar a los agentes
                    addPercept(ASSyntax.parseLiteral("new_container(\"" + container.getId() + "\")"));

                    if (view != null) {
                        view.update();
                    }

                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                    break;
                } catch (Exception e) {
                    e.printStackTrace();
                }
            }
            System.out.println("Container generator stopped");
        });
    }

    /**
     * Detiene el entorno de forma limpia
     */
    public void stop() {
        System.out.println("Stopping warehouse environment...");
        running = false;

        if (containerGeneratorExecutor != null) {
            containerGeneratorExecutor.shutdown();
            try {
                if (!containerGeneratorExecutor.awaitTermination(5, TimeUnit.SECONDS)) {
                    containerGeneratorExecutor.shutdownNow();
                }
            } catch (InterruptedException e) {
                containerGeneratorExecutor.shutdownNow();
                Thread.currentThread().interrupt();
            }
        }
        System.out.println("Warehouse environment stopped");
    }

    /**
     * Genera un contenedor aleatorio con distribución balanceada entre los 3 tipos
     * de robot
     */
    private Container generateRandomContainer() {
        Random rand = new Random();
        String id = "container_" + (++containerCounter);

        // Distribución de carga por tipo de robot:
        // 25% ligero: 1x1, 5-10 kg → robot_light
        // 35% mediano: 1x2, 10-30 kg → robot_medium
        // 40% pesado: 2x2/2x3, >30kg → robot_heavy
        int width, height;
        double weight;
        double r = rand.nextDouble();
        if (r < 0.25) {
            // Ligero
            width = 1;
            height = 1;
            weight = 5 + rand.nextDouble() * 5; // 5-10 kg
        } else if (r < 0.60) {
            // Mediano
            width = 1;
            height = (rand.nextBoolean() ? 1 : 2);
            weight = 10 + rand.nextDouble() * 20; // 10-30 kg
        } else {
            // Pesado
            int[][] heavySizes = { { 1, 2 }, { 2, 2 }, { 2, 3 } };
            int[] size = heavySizes[rand.nextInt(heavySizes.length)];
            width = size[0];
            height = size[1];
            weight = 31 + rand.nextDouble() * 69; // 31-100 kg
        }

        // Tipo: standard (70%), fragile (15%), urgent (15%)
        String type;
        double t = rand.nextDouble();
        if (t < 0.70)
            type = "standard";
        else if (t < 0.85)
            type = "fragile";
        else
            type = "urgent";

        Container container = new Container(id, width, height, weight, type);

        // Posición inicial aleatoria en zona de entrada (ENTRANCE)
        // Solo celdas ENTRANCE sin otro container ya colocado
        List<int[]> entranceCells = new ArrayList<>();
        for (int x = 0; x < GRID_WIDTH; x++) {
            for (int y = 0; y < GRID_HEIGHT; y++) {
                if (grid[x][y] == CellType.ENTRANCE && !hayContenedorEn(x, y)) {
                    entranceCells.add(new int[]{x, y});
                }
            }
        }
        if (entranceCells.isEmpty()) {
            // ENTRANCE llena, colocar en (0,0) como fallback
            container.setPosition(0, 0);
        } else {
            int[] cell = entranceCells.get(rand.nextInt(entranceCells.size()));
            container.setPosition(cell[0], cell[1]);
        }

        return container;
    }

    @Override
    public boolean executeAction(String agName, Structure action) {
        try {
            String actionName = action.getFunctor();

            switch (actionName) {
                case "move_to":
                    return executeMoveTo(agName, action);
                case "move_to_shelf":
                    return executeMoveToShelf(agName, action);
                case "move_to_container":
                    return executeMoveToContainer(agName, action);
                case "pickup":
                    return executePickup(agName, action);
                case "drop_at":
                    return executeDropAt(agName, action);
                case "get_container_info":
                    return executeGetContainerInfo(agName, action);
                case "get_free_shelf":
                    return executeGetFreeShelf(agName, action);
                case "release_task":
                    return executeReleaseTask(agName, action);
                case "accept_task":
                    return executeAcceptTask(agName, action);
                default:
                    System.err.println("Unknown action: " + actionName);
                    return false;
            }
        } catch (Exception e) {
            e.printStackTrace();
            return false;
        }
    }

    /**
     * Acción: move_to(X, Y)
     * Mueve el robot a la posición especificada.
     */
    private boolean executeMoveTo(String agName, Structure action) {
        try {
            int targetX = (int) ((NumberTerm) action.getTerm(0)).solve();
            int targetY = (int) ((NumberTerm) action.getTerm(1)).solve();
            return doMoveTo(agName, targetX, targetY);
        } catch (Exception e) {
            e.printStackTrace();
            return false;
        }
    }

    /**
     * Acción: move_to_shelf(ShelfId)
     * Navega a la celda adyacente libre más cercana a la estantería indicada,
     * descartando celdas ocupadas por robots o contenedores. Prueba todas las
     * adyacentes en orden antes de reportar path_blocked. Los errores parciales
     * de intentos fallidos se limpian antes de emitir el error definitivo.
     */
    private boolean executeMoveToShelf(String agName, Structure action) {
        try {
            String shelfId = action.getTerm(0).toString().replace("\"", "");
            Shelf shelf = shelves.get(shelfId);
            if (shelf == null) {
                addError(agName, "robot_not_found", "Shelf " + shelfId + " not found");
                return false;
            }
            List<int[]> adyacentes = getAdyacentes(shelf.getX(), shelf.getY(), shelf.getWidth(), shelf.getHeight());
            for (int[] cell : adyacentes) {
                if (!hayRobotCerca(cell[0], cell[1]) && !hayContenedorEn(cell[0], cell[1])) {
                    // Limpiar errores de path_blocked de intentos anteriores
                    removePerceptsByUnif(agName, ASSyntax.parseLiteral("error(path_blocked,_)"));
                    if (doMoveTo(agName, cell[0], cell[1])) {
                        return true;
                    }
                    // doMoveTo falló (sin ruta BFS), probar siguiente celda adyacente
                }
            }
            // Limpiar errores intermedios antes de añadir el definitivo
            removePerceptsByUnif(agName, ASSyntax.parseLiteral("error(path_blocked,_)"));
            addError(agName, "path_blocked", "No free adjacent cell for shelf " + shelfId);
            return false;
        } catch (Exception e) {
            e.printStackTrace();
            return false;
        }
    }

    /**
     * Acción: move_to_container(ContainerId)
     * Igual que executeMoveToShelf pero usa container.getAdyacentes() (lógica
     * encapsulada en Container.java) en lugar de la versión local para estanterías.
     * Los contenedores se tratan siempre como 1×1 en el grid.
     */
    private boolean executeMoveToContainer(String agName, Structure action) {
        try {
            String containerId = action.getTerm(0).toString().replace("\"", "");
            Container container = containers.get(containerId);
            if (container == null) {
                addError(agName, "robot_not_found", "Container " + containerId + " not found");
                return false;
            }
            List<int[]> adyacentes = container.getAdyacentes(grid, GRID_WIDTH, GRID_HEIGHT);
            for (int[] cell : adyacentes) {
                if (!hayRobotCerca(cell[0], cell[1]) && !hayContenedorEn(cell[0], cell[1])) {
                    // Limpiar errores de path_blocked de intentos anteriores
                    removePerceptsByUnif(agName, ASSyntax.parseLiteral("error(path_blocked,_)"));
                    if (doMoveTo(agName, cell[0], cell[1])) {
                        return true;
                    }
                    // doMoveTo falló (sin ruta BFS), probar siguiente celda adyacente
                }
            }
            // Limpiar errores intermedios antes de añadir el definitivo
            removePerceptsByUnif(agName, ASSyntax.parseLiteral("error(path_blocked,_)"));
            addError(agName, "path_blocked", "No free adjacent cell for container " + containerId);
            return false;
        } catch (Exception e) {
            e.printStackTrace();
            return false;
        }
    }

    /**
     * Devuelve las celdas adyacentes ortogonales (sin diagonales) a una ESTANTERÍA,
     * dado su rectángulo de posición (x,y) y dimensiones (width x height).
     * Filtra celdas fuera del mapa, SHELF y BLOCKED.
     * Usado por executeMoveToShelf. Para contenedores, usar container.getAdyacentes().
     */
    private List<int[]> getAdyacentes(int x, int y, int width, int height) {
        List<int[]> result = new ArrayList<>();
        // Fila superior
        for (int i = 0; i < width; i++) {
            int ax = x + i, ay = y - 1;
            if (estaDentroDelMapa(ax, ay) && grid[ax][ay] != CellType.SHELF && grid[ax][ay] != CellType.BLOCKED)
                result.add(new int[]{ax, ay});
        }
        // Fila inferior
        for (int i = 0; i < width; i++) {
            int ax = x + i, ay = y + height;
            if (estaDentroDelMapa(ax, ay) && grid[ax][ay] != CellType.SHELF && grid[ax][ay] != CellType.BLOCKED)
                result.add(new int[]{ax, ay});
        }
        // Columna izquierda
        for (int j = 0; j < height; j++) {
            int ax = x - 1, ay = y + j;
            if (estaDentroDelMapa(ax, ay) && grid[ax][ay] != CellType.SHELF && grid[ax][ay] != CellType.BLOCKED)
                result.add(new int[]{ax, ay});
        }
        // Columna derecha
        for (int j = 0; j < height; j++) {
            int ax = x + width, ay = y + j;
            if (estaDentroDelMapa(ax, ay) && grid[ax][ay] != CellType.SHELF && grid[ax][ay] != CellType.BLOCKED)
                result.add(new int[]{ax, ay});
        }
        return result;
    }

    /**
     * Núcleo de navegación: mueve el robot agName hasta (targetX, targetY).
     *
     * Estrategia en dos fases:
     *   Fase 1 (optimista): BFS ignorando robots en movimiento. Más eficiente
     *     y evita que robots se bloqueen mutuamente al calcular rutas simultáneas.
     *   Fase 2 (reactiva): Si un paso lleva 3 s bloqueado, recalcula con
     *     avoidRobots=true para esquivar robots que están parados. Se resetea
     *     tras cada recálculo exitoso para volver a modo optimista.
     *
     * La mecánica de aplastamiento ocurre dentro del bucle paso a paso:
     * si un contenedor no recogido ocupa la celda destino del paso, se elimina
     * del mapa y se emite container_broken globalmente antes de mover el robot.
     */
    private boolean doMoveTo(String agName, int targetX, int targetY) {
        String destKey = targetX + "," + targetY;
        try {
            Robot robot = robots.get(agName);
            if (robot == null) {
                addError(agName, "robot_not_found", "Robot " + agName + " not found");
                return false;
            }

            // Verificar límites
            if (targetX < 0 || targetX >= GRID_WIDTH || targetY < 0 || targetY >= GRID_HEIGHT) {
                addError(agName, "illegal_move", "Position out of bounds: (" + targetX + "," + targetY + ")");
                return false;
            }

            // Verificar si hay obstáculos (excepto estanterías que son destinos válidos)
            if (grid[targetX][targetY] == CellType.BLOCKED) {
                addError(agName, "route_blocked", "Position blocked: (" + targetX + "," + targetY + ")");
                return false;
            }

            /*
             * // Verificar conflictos finales con otros robots
             * for (Robot other : robots.values()) {
             * if (!other.getId().equals(agName) && other.getX() == targetX && other.getY()
             * == targetY) {
             * addError(agName, "conflict", "Conflict with " + other.getId() +
             * " at destination");
             * return false;
             * }
             * }
             */

            // Verificar conflictos de destino con otros robots en movimiento
            if (activeDestinations != null) {
                String claimingRobot = activeDestinations.putIfAbsent(destKey, agName);
                if (claimingRobot != null && !claimingRobot.equals(agName)) {
                    addError(agName, "destination_conflict", "Another robot is moving to this exact destination");
                    return false;
                }
            }

            // 1. CÁLCULO INICIAL: Optimista (ignorando robots en movimiento)
            boolean avoidRobots = false;
            List<int[]> pos = calcularRuta(robot.getX(), robot.getY(), targetX, targetY, avoidRobots);

            // Si no hay ruta y el robot no está ya en el destino, fallo
            if (pos.isEmpty() && (robot.getX() != targetX || robot.getY() != targetY)) {
                addError(agName, "path_blocked", "No route found to (" + targetX + "," + targetY + ")");
                if (activeDestinations != null) {
                    activeDestinations.remove(destKey, agName);
                }
                return false;
            }

            // 2. MOVIMIENTO PASO A PASO (Reactivo)
            while (!pos.isEmpty()) {
                // Miramos cuál es nuestro próximo paso inmediato
                int[] siguientePaso = pos.get(0);
                int cont = 0;

                boolean moved = false;
                while (!moved && cont < 3) {
                    synchronized (this) {
                        if (!hayRobotCerca(siguientePaso[0], siguientePaso[1])) {
                            // Comprobar si hay un container en la celda destino y destruirlo
                            List<String> crushedIds = new ArrayList<>();
                            for (Container c : containers.values()) {
                                if (!c.isPicked() && !c.isBroken()
                                        && c.getX() == siguientePaso[0] && c.getY() == siguientePaso[1]) {
                                    crushedIds.add(c.getId());
                                }
                            }
                            for (String crushedId : crushedIds) {
                                containers.remove(crushedId);
                                System.err.println("[WARNING] " + agName + " aplastó " + crushedId
                                        + " en (" + siguientePaso[0] + "," + siguientePaso[1] + ")");
                                if (view != null) {
                                    view.logMessage("💥 " + agName + " aplastó " + crushedId);
                                }
                                addPercept(ASSyntax.parseLiteral(
                                        "container_broken(\"" + crushedId + "\")"));
                            }
                            robot.setPosition(siguientePaso[0], siguientePaso[1]);
                            moved = true;
                        }
                    }

                    if (!moved) {
                        try {
                            Thread.sleep(1000);
                        } catch (InterruptedException e) {
                            Thread.currentThread().interrupt();
                        }
                        cont++;
                    }
                }

                // Si pasaron los 3 segundos y el obstáculo sigue ahí, recalculamos
                if (!moved) {
                    avoidRobots = true; // Ahora sí, buscamos ruta esquivando robots fijos
                    List<int[]> nuevaRuta = calcularRuta(robot.getX(), robot.getY(), targetX, targetY, avoidRobots);

                    if (nuevaRuta.isEmpty()) {
                        addError(agName, "path_blocked", "Ruta totalmente bloqueada, imposible avanzar.");
                        if (activeDestinations != null) {
                            activeDestinations.remove(destKey, agName);
                        }
                        return false;
                    }

                    // Actualizamos nuestra ruta con la nueva y volvemos a evaluar
                    pos = nuevaRuta;
                    avoidRobots = false; // Reseteamos por si este obstáculo también se mueve
                    continue; // Vuelve al inicio del 'while (!pos.isEmpty())'
                }

                // Eliminamos el paso que acabamos de dar de la lista
                pos.remove(0);

                if (view != null) {
                    view.update();
                }

                try {
                    // Tiempo de desplazamiento visual (300ms)
                    Thread.sleep(300);
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                }
            }

            // Log a la consola de la GUI al finalizar
            if (view != null) {
                view.logMessage(String.format("➡️  %s moved to (%d,%d)", agName, targetX, targetY));
            }

            // Actualizar percepción final en el agente
            removePerceptsByUnif(agName, ASSyntax.parseLiteral("robot_at(_,_)"));
            addPercept(agName, ASSyntax.parseLiteral("robot_at(" + targetX + "," + targetY + ")"));

            if (view != null) {
                view.update();
            }

            return true;

        } catch (Exception e) {
            e.printStackTrace();
            return false;
        } finally {
            if (activeDestinations != null) {
                activeDestinations.remove(destKey);
            }
        }
    }

    private List<int[]> calcularRuta(int inicioX, int inicioY, int destinoX, int destinoY, boolean avoidRobots) {
        // 1. Estructuras de control
        // 'padres' guarda: [Celda Actual] -> [Celda de la que venimos]
        Map<List<Integer>, List<Integer>> mapaPadres = new HashMap<>();
        Deque<List<Integer>> colaExploracion = new ArrayDeque<>();

        // 2. Preparar puntos de inicio y destino
        List<Integer> celdaInicial = Arrays.asList(inicioX, inicioY);
        List<Integer> celdaDestino = Arrays.asList(destinoX, destinoY);

        colaExploracion.addLast(celdaInicial);
        mapaPadres.put(celdaInicial, null); // La celda inicial no tiene predecesor

        boolean rutaEncontrada = false;

        // 3. Algoritmo BFS (Búsqueda en Anchura)
        while (!colaExploracion.isEmpty()) {
            List<Integer> actual = colaExploracion.removeFirst();
            int xActual = actual.get(0);
            int yActual = actual.get(1);

            // Si llegamos al destino, dejamos de buscar
            if (xActual == destinoX && yActual == destinoY) {
                rutaEncontrada = true;
                break;
            }

            // Direcciones: Derecha, Izquierda, Abajo, Arriba
            int[][] movimientos = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } };

            for (int[] mov : movimientos) {
                int sigX = xActual + mov[0];
                int sigY = yActual + mov[1];
                List<Integer> vecino = Arrays.asList(sigX, sigY);

                // Verificamos: Límites, Obstáculos, Contenedores y si ya pasamos por ahí
                if (estaDentroDelMapa(sigX, sigY) &&
                        grid[sigX][sigY] != CellType.BLOCKED &&
                        grid[sigX][sigY] != CellType.SHELF &&
                        !hayContenedorEn(sigX, sigY) &&
                        !mapaPadres.containsKey(vecino)) {

                    if (avoidRobots) {
                        if (!hayRobotCerca(sigX, sigY)) {
                            mapaPadres.put(vecino, actual); // Registramos quién es el "padre" de este vecino
                            colaExploracion.addLast(vecino);
                        }

                    } else {
                        mapaPadres.put(vecino, actual); // Registramos quién es el "padre" de este vecino
                        colaExploracion.addLast(vecino);
                    }
                }
            }
        }

        // 4. Reconstrucción de la ruta (de atrás hacia adelante)
        return construirRutaFinal(rutaEncontrada, celdaDestino, mapaPadres);
    }

    private boolean hayContenedorEn(int x, int y) {
        for (Container c : containers.values()) {
            if (!c.isPicked() && !c.isBroken()) {
                // Container tratado como 1x1 (su tamaño visual)
                if (x == c.getX() && y == c.getY()) {
                    return true;
                }
            }
        }
        return false;
    }

    private boolean hayRobotCerca(int x, int y) {
        for (Robot robot : robots.values()) {
            if (robot.getX() == x && robot.getY() == y) {
                return true;
            }
        }
        return false;
    }

    // Métodos auxiliares para limpiar el código principal:

    private boolean estaDentroDelMapa(int x, int y) {
        return x >= 0 && x < GRID_WIDTH && y >= 0 && y < GRID_HEIGHT;
    }

    private List<int[]> construirRutaFinal(boolean encontrada, List<Integer> destino,
            Map<List<Integer>, List<Integer>> mapaPadres) {
        List<int[]> ruta = new ArrayList<>();

        if (encontrada) {
            List<Integer> pasoActual = destino;
            while (pasoActual != null) {
                // Insertamos al principio para que el orden sea Inicio -> Destino
                ruta.add(0, new int[] { pasoActual.get(0), pasoActual.get(1) });
                pasoActual = mapaPadres.get(pasoActual);
            }

            // Quitamos la primera posición (donde ya está el robot)
            if (!ruta.isEmpty()) {
                ruta.remove(0);
            }
        }
        return ruta;
    }

    /**
     * Acción: pickup(ContainerId)
     * Recoge un contenedor
     */
    private boolean executePickup(String agName, Structure action) {
        try {
            String containerId = action.getTerm(0).toString().replace("\"", "");

            Robot robot = robots.get(agName);
            Container container = containers.get(containerId);

            if (robot == null || container == null) {
                addError(agName, "invalid_pickup", "Robot or container not found");
                return false;
            }

            if (container.isBroken()) {
                addError(agName, "container_broken", "Container " + containerId + " is broken");
                return false;
            }

            // Verificar distancia - tolerancia de 3 para permitir que robots grandes (ej
            // heavy 2x3)
            // no tengan que solapar físicamente el contenedor para recogerlo
            if (robot.distanceTo(container.getX(), container.getY()) > 3) {
                addError(agName, "too_far", "Container too far away");
                return false;
            }

            // Verificar capacidad
            if (!robot.canCarry(container)) {
                if (container.getWeight() > robot.getMaxWeight()) {
                    addError(agName, "container_too_heavy",
                            "Container " + containerId + " is too heavy for " + agName);
                } else {
                    addError(agName, "container_too_big",
                            "Container " + containerId + " is too big for " + agName);
                }
                return false;
            }

            // Recoger contenedor
            if (robot.pickup(container)) {
                container.setPicked(true);
                addPercept(agName, ASSyntax.parseLiteral("picked(\"" + containerId + "\")"));

                if (view != null) {
                    view.logMessage(
                            String.format("📦 %s picked up %s (%.1fkg)", agName, containerId, container.getWeight()));
                    view.update();
                }

                return true;
            }

            return false;

        } catch (Exception e) {
            e.printStackTrace();
            return false;
        }
    }

    /**
     * Acción: drop_at(ShelfId)
     * Deposita el contenedor en una estantería
     */
    private boolean executeDropAt(String agName, Structure action) {
        try {
            String shelfId = action.getTerm(0).toString().replace("\"", "");

            Robot robot = robots.get(agName);
            Shelf shelf = shelves.get(shelfId);

            if (robot == null || shelf == null) {
                addError(agName, "invalid_drop", "Robot or shelf not found"); // esto es un error de programación, no operacional
                return false;
            }

            if (!robot.isCarrying()) {
                addError(agName, "not_carrying", "Robot is not carrying anything"); // esto es un error de programación, no operacional
                return false;
            }

            // Verificar distancia a la estantería
            // heavy→(SX,SY-1)=d1, medium→(SX+1,SY-1)=d2, light→(SX+2,SY-1)=d3
            if (robot.distanceTo(shelf.getX(), shelf.getY()) > 3) {
                addError(agName, "too_far", "Shelf too far away");
                return false;
            }

            Container container = robot.getCarriedContainer();

            // Verificar si cabe en la estantería.
            // Si está llena, el robot suelta el contenedor en su posición actual (pasillo).
            // El plan -!execute_task del robot notificará task_failed al scheduler,
            // que reintentará assign_shelf hasta shelf_retries >= 3.
            if (!shelf.canStore(container)) {
                robot.drop();
                container.setPicked(false);
                container.setPosition(robot.getX(), robot.getY());
                robot.setBusy(false);

                addError(agName, "shelf_full",
                        "Shelf " + shelfId + " full. Dropped at (" + robot.getX() + "," + robot.getY() + ")");
                return false;
            }

            // Depositar
            shelf.store(container);
            robot.drop();
            robot.setBusy(false);
            container.setAssignedShelf(shelfId);

            totalContainersProcessed++;

            // Actualizar percepciones
            removePerceptsByUnif(agName, ASSyntax.parseLiteral("picked(_)"));
            addPercept(agName, ASSyntax.parseLiteral("stored(\"" + container.getId() + "\",\"" + shelfId + "\")"));

            if (view != null) {
                view.logMessage(String.format("✅ %s stored %s at %s", agName, container.getId(), shelfId));
                view.update();
            }

            System.out.println(agName + " stored " + container.getId() + " at " + shelfId);

            if (view != null) {
                view.update();
            }

            return true;

        } catch (Exception e) {
            e.printStackTrace();
            return false;
        }
    }


    /**
     * Encuentra la mejor estantería para un contenedor, priorizando por tipo de
     * carga.
     * - Ligero (<= 10kg, 1x1): shelves 1-4 (pequeñas)
     * - Mediano (<= 30kg, <= 1x2): shelves 5-7 (medianas)
     * - Pesado (> 30kg o grande): shelves 8-9 (grandes)
     */
    private Shelf findBestShelf(Container container) {
        List<String> preferredShelves;
        if (container.getWeight() <= 10 && container.getWidth() <= 1 && container.getHeight() <= 1) {
            preferredShelves = Arrays.asList("shelf_1", "shelf_2", "shelf_3", "shelf_4");
        } else if (container.getWeight() <= 30 && container.getWidth() <= 1 && container.getHeight() <= 2) {
            preferredShelves = Arrays.asList("shelf_5", "shelf_6", "shelf_7");
        } else {
            preferredShelves = Arrays.asList("shelf_8", "shelf_9");
        }

        // 1. Intentar buscar en las estanterías preferidas
        List<Shelf> availableShelves = shelves.values().stream()
                .filter(s -> preferredShelves.contains(s.getId()))
                .filter(s -> s.canStore(container))
                .sorted(Comparator.comparingDouble(Shelf::getOccupancyPercentage))
                .collect(Collectors.toList());

        if (!availableShelves.isEmpty()) {
            return availableShelves.get(0);
        }

        // 2. Fallback: Si no hay espacio en las preferidas, buscar en cualquier otra
        // (evita starvation)
        List<Shelf> fallbackShelves = shelves.values().stream()
                .filter(s -> s.canStore(container))
                .sorted(Comparator.comparingDouble(Shelf::getOccupancyPercentage))
                .collect(Collectors.toList());

        return fallbackShelves.isEmpty() ? null : fallbackShelves.get(0);
    }

    /**
     * Acción: get_container_info(ContainerId)
     * Obtiene información sobre un contenedor
     */
    private boolean executeGetContainerInfo(String agName, Structure action) {
        try {
            String containerId = action.getTerm(0).toString().replace("\"", "");
            Container container = containers.get(containerId);

            if (container == null) {
                return false;
            }

            // Agregar percepción con información del contenedor, incluyendo posición
            addPercept(agName, ASSyntax.parseLiteral(
                    "container_info(\"" + containerId + "\"," +
                            container.getWidth() + "," +
                            container.getHeight() + "," +
                            container.getWeight() + ",\"" +
                            container.getType() + "\"," +
                            container.getX() + "," +
                            container.getY() + ")"));

            return true;

        } catch (Exception e) {
            e.printStackTrace();
            return false;
        }
    }

    /**
     * Acción: get_free_shelf(ContainerId)
     * Busca una estantería libre para un contenedor
     */
    private boolean executeGetFreeShelf(String agName, Structure action) {
        try {
            String containerId = action.getTerm(0).toString().replace("\"", "");
            Container container = containers.get(containerId);

            if (container == null) {
                return false;
            }

            Shelf shelf = findBestShelf(container);
            if (shelf != null) {
                addPercept(agName, ASSyntax.parseLiteral(
                        "free_shelf(\"" + containerId + "\",\"" + shelf.getId() + "\")"));
                return true;
            }

            // null → no hay estantería disponible → la acción falla en Jason →
            // dispara -!assign_shelf(CId) en el scheduler, que reintentará
            // hasta shelf_retries >= 3 antes de notificar no_shelf_space.
            return false;

        } catch (Exception e) {
            e.printStackTrace();
            return false;
        }
    }


    /**
     * Acción: release_task(ContainerId)
     * El agente libera una tarea fallida: limpia estado busy y re-encola el
     * contenedor
     */
    private boolean executeReleaseTask(String agName, Structure action) {
        try {
            Robot robot = robots.get(agName);
            if (robot == null)
                return false;

            // Si tiene argumento (el containerId), re-encolar ese contenedor
            if (action.getArity() > 0) {
                String containerId = action.getTerm(0).toString().replace("\"", "");
                Container container = containers.get(containerId);
                if (container != null && !container.isPicked()) {
                    pendingContainers.offer(container);
                    System.out.println("[" + agName + "] Container " + containerId + " re-queued after task failure");
                }
            }

            // Limpiar estado del robot en el entorno
            robot.setBusy(false);
            robot.setCurrentTask(null);
            if (robot.isCarrying()) {
                Container c = robot.drop();
                if (c != null) {
                    c.setPicked(false);
                    c.setPosition(robot.getX(), robot.getY());
                }
            }
            taskAssignments.values().remove(agName);

            return true;
        } catch (Exception e) {
            e.printStackTrace();
            return false;
        }
    }

    private void addError(String agName, String errorType, String data) {
        totalErrors++;
        try {
            addPercept(agName, ASSyntax.parseLiteral(
                    "error(" + errorType + ",\"" + data + "\")"));
        } catch (Exception e) {
            e.printStackTrace();
        }
        System.err.println("ERROR [" + agName + "]: " + errorType + " - " + data);
    }

    // Getters para la vista
    public CellType[][] getGrid() {
        return grid;
    }

    public Map<String, Robot> getRobots() {
        return robots;
    }

    public Map<String, Container> getContainers() {
        return containers;
    }

    public Map<String, Shelf> getShelves() {
        return shelves;
    }

    public String getStatistics() {
        long elapsedTime = (System.currentTimeMillis() - startTime) / 1000;
        return String.format(
                "Time: %ds | Processed: %d | Pending: %d | Errors: %d",
                elapsedTime, totalContainersProcessed, pendingContainers.size(), totalErrors);
    }

    /**
     * Acción: accept_task(ContainerId)
     * El agente llama esto al aceptar una tarea enviada por el scheduler.
     * Marca el robot como busy en Java (evita double-assignment via request_task)
     * y elimina el contenedor de la cola pendiente.
     */
    private boolean executeAcceptTask(String agName, Structure action) {
        try {
            Robot robot = robots.get(agName);
            if (robot == null)
                return false;

            String containerId = action.getTerm(0).toString().replace("\"", "");

            // Marcar robot como ocupado en Java
            robot.setBusy(true);
            robot.setCurrentTask(containerId);
            taskAssignments.put(containerId, agName);

            // Eliminar el contenedor de la cola pendiente (ya asignado por scheduler)
            pendingContainers.removeIf(c -> c.getId().equals(containerId));

            return true;
        } catch (Exception e) {
            e.printStackTrace();
            return false;
        }
    }

}
