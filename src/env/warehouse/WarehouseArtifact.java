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
    // Evita que dos robots naveguen al mismo destino simultáneamente. La clave es la
    // coordenada (no el agente) para que el bloque finally de doMoveTo la libere
    // correctamente aunque el robot cambie de ruta.
    private Map<String, String> activeDestinations;

    // GUI visual
    private WarehouseView view;

    // Contadores para generar IDs
    private int containerCounter = 0;

    // Métricas
    private int totalContainersProcessed = 0;
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
                case "return_to_base":
                    return executeReturnToBase(agName, action);
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
     * Acción: return_to_base(X, Y)
     * Mueve el robot a su posición inicial cuando no tiene tareas pendientes.
     */
    private boolean executeReturnToBase(String agName, Structure action) {
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
     * Navegación coordinada por waypoints.
     * Cada paso se calcula en O(1) comparando coordenadas; sin BFS ni colas.
     *
     * Para destinos en la zona de almacenamiento (x≥10) se usa x=9 como
     * corredor vertical libre: el robot navega primero a (9, targetY) y luego
     * desliza horizontalmente hasta (targetX, targetY). Esto evita atravesar
     * filas de estanterías sin necesidad de búsqueda exhaustiva.
     *
     * Si un paso está ocupado por otro robot se espera hasta 3 s; pasado ese
     * tiempo se recalcula el paso evitando robots. Si sigue bloqueado, fallo.
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

            // Verificar si hay obstáculos permanentes
            if (grid[targetX][targetY] == CellType.BLOCKED) {
                addError(agName, "route_blocked", "Position blocked: (" + targetX + "," + targetY + ")");
                return false;
            }

            // Verificar conflictos de destino con otros robots en movimiento
            if (activeDestinations != null) {
                String claimingRobot = activeDestinations.putIfAbsent(destKey, agName);
                if (claimingRobot != null && !claimingRobot.equals(agName)) {
                    addError(agName, "destination_conflict", "Another robot is moving to this exact destination");
                    return false;
                }
            }

            // Navegación por waypoints con pasos coordinados (O(1) por paso)
            List<int[]> waypoints = computeWaypointPath(
                    robot.getX(), robot.getY(), targetX, targetY);

            for (int[] wp : waypoints) {
                int blockedCount = 0;

                while (robot.getX() != wp[0] || robot.getY() != wp[1]) {
                    // Paso coordinado: prioriza el eje con mayor distancia restante.
                    // Tras 3 s bloqueado por un robot, activa avoidRobots para buscar
                    // una dirección alternativa libre.
                    List<int[]> step = nextCoordinateStep(
                            robot.getX(), robot.getY(), wp[0], wp[1], blockedCount >= 3);

                    if (step.isEmpty()) {
                        addError(agName, "path_blocked",
                                "No route to waypoint (" + wp[0] + "," + wp[1] + ")");
                        if (activeDestinations != null) activeDestinations.remove(destKey, agName);
                        return false;
                    }

                    int[] siguiente = step.get(0);
                    boolean moved = false;

                    synchronized (this) {
                        if (!hayRobotCerca(siguiente[0], siguiente[1])) {
                            // Mecánica de aplastamiento
                            List<String> aplastados = new ArrayList<>();
                            for (Container c : containers.values()) {
                                if (!c.isPicked() && !c.isBroken()
                                        && c.getX() == siguiente[0] && c.getY() == siguiente[1]) {
                                    aplastados.add(c.getId());
                                }
                            }
                            for (String crushedId : aplastados) {
                                containers.remove(crushedId);
                                System.err.println("[WARNING] " + agName + " aplastó " + crushedId
                                        + " en (" + siguiente[0] + "," + siguiente[1] + ")");
                                if (view != null) view.logMessage("💥 " + agName + " aplastó " + crushedId);
                                try {
                                    addPercept(ASSyntax.parseLiteral(
                                            "container_broken(\"" + crushedId + "\")"));
                                } catch (jason.asSyntax.parser.ParseException e) {
                                    e.printStackTrace();
                                }
                            }
                            robot.setPosition(siguiente[0], siguiente[1]);
                            moved = true;
                        }
                    }

                    if (!moved) {
                        blockedCount++;
                        if (blockedCount > 6) {
                            // Bloqueado más de 6 s: fallo definitivo
                            addError(agName, "path_blocked",
                                    "Camino permanentemente bloqueado hacia ("
                                            + wp[0] + "," + wp[1] + ")");
                            if (activeDestinations != null) activeDestinations.remove(destKey, agName);
                            return false;
                        }
                        try {
                            Thread.sleep(1000);
                        } catch (InterruptedException e) {
                            Thread.currentThread().interrupt();
                        }
                        continue;
                    }

                    blockedCount = 0;

                    if (view != null) view.update();

                    try {
                        Thread.sleep(300);
                    } catch (InterruptedException e) {
                        Thread.currentThread().interrupt();
                    }
                }
            }

            // Log a la consola de la GUI al finalizar
            if (view != null) {
                view.logMessage(String.format("➡️  %s moved to (%d,%d)", agName, targetX, targetY));
            }

            // Actualizar percepción final en el agente
            removePerceptsByUnif(agName, ASSyntax.parseLiteral("robot_at(_,_)"));
            addPercept(agName, ASSyntax.parseLiteral("robot_at(" + targetX + "," + targetY + ")"));

            if (view != null) view.update();

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

    /**
     * Calcula el siguiente paso de movimiento coordinado hacia (toX, toY).
     * Inspirado en el robot doméstico de Jason: O(1) en tiempo y memoria, sin BFS.
     *
     * Prioriza el eje con mayor distancia Manhattan restante. Si la dirección
     * preferida está bloqueada por una estantería u obstáculo, intenta la
     * perpendicular. Si ambas están bloqueadas, devuelve lista vacía: el robot
     * esperará (yield) y reintentará en el siguiente ciclo.
     *
     * @param avoidRobots si true, trata las celdas ocupadas por robots como bloqueadas
     */
    private List<int[]> nextCoordinateStep(int fromX, int fromY, int toX, int toY, boolean avoidRobots) {
        if (fromX == toX && fromY == toY) return Collections.emptyList();

        int dx = Integer.compare(toX, fromX); // -1, 0 o +1
        int dy = Integer.compare(toY, fromY); // -1, 0 o +1
        boolean xFirst = Math.abs(toX - fromX) >= Math.abs(toY - fromY);

        if (xFirst) {
            if (dx != 0 && isFreeStep(fromX + dx, fromY, avoidRobots)) return List.of(new int[]{fromX + dx, fromY});
            if (dy != 0 && isFreeStep(fromX, fromY + dy, avoidRobots)) return List.of(new int[]{fromX, fromY + dy});
        } else {
            if (dy != 0 && isFreeStep(fromX, fromY + dy, avoidRobots)) return List.of(new int[]{fromX, fromY + dy});
            if (dx != 0 && isFreeStep(fromX + dx, fromY, avoidRobots)) return List.of(new int[]{fromX + dx, fromY});
        }

        return Collections.emptyList();
    }

    private boolean isFreeStep(int x, int y, boolean avoidRobots) {
        if (!estaDentroDelMapa(x, y)) return false;
        if (grid[x][y] == CellType.SHELF || grid[x][y] == CellType.BLOCKED) return false;
        if (hayContenedorEn(x, y)) return false;
        if (avoidRobots && hayRobotCerca(x, y)) return false;
        return true;
    }

    /**
     * Calcula los waypoints para navegar de (fromX,fromY) a (toX,toY).
     *
     * En la zona de almacenamiento (x≥10), los destinos son siempre celdas
     * adyacentes a estanterías que caen en los corredores horizontales libres
     * (y=1,4,5,8,9,13). Para llegar a ellos sin cruzar filas de estanterías,
     * se usa x=9 como corredor vertical libre: primero se alcanza (9, toY) y
     * luego se desliza horizontalmente hasta (toX, toY).
     *
     * Si el robot ya está en el mismo corredor que el destino, va directo.
     */
    private List<int[]> computeWaypointPath(int fromX, int fromY, int toX, int toY) {
        List<int[]> waypoints = new ArrayList<>();

        if (toX >= 10) {
            // Solo añadir waypoint de corredor si no estamos ya en la misma fila libre
            boolean sameCorridorRow = (fromY == toY) && isCorridorRow(toY);
            if (!sameCorridorRow) {
                waypoints.add(new int[]{9, toY});
            }
        }

        waypoints.add(new int[]{toX, toY});
        return waypoints;
    }

    /**
     * Devuelve true si y es una fila de corredor libre en la zona de almacenamiento.
     * Estas filas no contienen estanterías en ninguna x≥10.
     */
    private boolean isCorridorRow(int y) {
        return y == 1 || y == 4 || y == 5 || y == 8 || y == 9 || y == 13 || y == 14;
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
                "Time: %ds | Processed: %d | Pending: %d",
                elapsedTime, totalContainersProcessed, pendingContainers.size());
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
