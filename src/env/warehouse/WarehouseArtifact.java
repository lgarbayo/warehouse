package warehouse;

import jason.asSyntax.*;
import jason.environment.Environment;

import java.util.*;
import java.util.concurrent.*;

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

    // GUI visual
    private WarehouseView view;

    // Contadores para generar IDs
    private int containerCounter = 0;

    // Métricas
    private int totalContainersProcessed = 0;
    private long startTime;

    // Contenedores reclamados atómicamente por robots (containerId → robotId)
    private ConcurrentHashMap<String, String> claimedContainers = new ConcurrentHashMap<>();

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

        // Zona de salida / outbound (x=0-2, y=0-1)
        for (int x = 0; x < 3; x++) {
            for (int y = 0; y < 2; y++) {
                grid[x][y] = CellType.OUTBOUND;
            }
        }

        // Zona de clasificación (x=3-4, y=0-1)
        for (int x = 3; x < 5; x++) {
            for (int y = 0; y < 2; y++) {
                grid[x][y] = CellType.CLASSIFICATION;
            }
        }

        // Zona de entrada / inbound (x=5-7, y=0-1)
        for (int x = 5; x < 8; x++) {
            for (int y = 0; y < 2; y++) {
                grid[x][y] = CellType.ENTRANCE;
            }
        }

    }

    /**
     * Crea los robots iniciales
     */
    private void initializeRobots() {
        Robot light = new Robot("robot_light", "light", 10, 1, 1, 3);
        light.setPosition(1, 4);
        robots.put("robot_light", light);

        Robot medium = new Robot("robot_medium", "medium", 30, 1, 2, 2);
        medium.setPosition(2, 4);
        robots.put("robot_medium", medium);

        Robot heavy = new Robot("robot_heavy", "heavy", 100, 2, 3, 1);
        heavy.setPosition(3, 4);
        robots.put("robot_heavy", heavy);

        Robot heavy2 = new Robot("robot_heavy2", "heavy", 100, 2, 3, 1);
        heavy2.setPosition(4, 4);
        robots.put("robot_heavy2", heavy2);

        // Emitir posición inicial de cada robot para que sus planes de navegación
        // tengan robot_pos disponible desde el primer ciclo.
        try {
            addPercept("robot_light",   ASSyntax.parseLiteral("robot_pos(1,4)"));
            addPercept("robot_medium",  ASSyntax.parseLiteral("robot_pos(2,4)"));
            addPercept("robot_heavy",   ASSyntax.parseLiteral("robot_pos(3,4)"));
            addPercept("robot_heavy2",  ASSyntax.parseLiteral("robot_pos(4,4)"));
        } catch (jason.asSyntax.parser.ParseException e) {
            e.printStackTrace();
        }
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
            emitShelfAvailable(shelf.getId());
            emitShelfOccupancy(shelf.getId(), shelf);
        }

        // Fila de estanterías medianas
        for (int x = 10; x < 18; x += 3) {
            Shelf shelf = new Shelf("shelf_" + shelfId++, x, 6, 3, 2, 100, 12);
            shelves.put(shelf.getId(), shelf);
            for (int dx = 0; dx < 3; dx++) {
                grid[x + dx][6] = CellType.SHELF;
                grid[x + dx][7] = CellType.SHELF;
            }
            emitShelfAvailable(shelf.getId());
            emitShelfOccupancy(shelf.getId(), shelf);
        }

        // Fila de estanterías grandes
        for (int x = 10; x < 16; x += 4) {
            Shelf shelf = new Shelf("shelf_" + shelfId++, x, 10, 4, 3, 350, 6);
            shelves.put(shelf.getId(), shelf);
            for (int dx = 0; dx < 4; dx++) {
                for (int dy = 0; dy < 3; dy++) {
                    grid[x + dx][10 + dy] = CellType.SHELF;
                }
            }
            emitShelfAvailable(shelf.getId());
            emitShelfOccupancy(shelf.getId(), shelf);
        }
    }

    /**
     * Inicia el generador automático de contenedores
     */
    private void startContainerGenerator() {
        containerGeneratorExecutor = Executors.newSingleThreadExecutor(r -> {
            Thread t = new Thread(r, "ContainerGenerator");
            t.setDaemon(true); // Daemon: se termina automáticamente al salir la JVM sin bloquear el shutdown
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

                    // Notificar a los agentes con propiedades completas del contenedor
                    addPercept(ASSyntax.parseLiteral(
                        "container_at_entrance(\"" + container.getId() + "\",\"" +
                        container.getType() + "\"," + container.getWeight() + "," +
                        container.getWidth() + "," + container.getHeight() + ")"));

                    // Notificar al scheduler para activar el planificador formal
                    addPercept("scheduler", ASSyntax.parseLiteral(
                        "new_container(\"" + container.getId() + "\")"));

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
            // ENTRANCE llena, colocar en (5,0) como fallback (primera celda de la zona de entrada)
            container.setPosition(5, 0);
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
                case "move_step":
                    return executeMoveStep(agName, action);
                case "pickup":
                    return executePickup(agName, action);
                case "drop_at":
                    return executeDropAt(agName, action);
                case "get_container_info":
                    return executeGetContainerInfo(agName, action);
                case "release_task":
                    return executeReleaseTask(agName, action);
                case "accept_task":
                    return executeAcceptTask(agName, action);
                case "move_to_expansion":
                    return executeMoveToExpansion(agName);
                case "drop_in_expansion":
                    return executeDropInExpansion(agName, action);
                case "claim_container":
                    return executeClaimContainer(agName, action);
                case "unclaim_container":
                    return executeUnclaimContainer(agName, action);
                case "pickup_from_shelf":
                    return executePickupFromShelf(agName, action);
                case "move_to_outbound":
                    return executeMoveToOutbound(agName);
                case "drop_in_outbound":
                    return executeDropInOutbound(agName, action);
                case "discard_container":
                    return executeDiscardContainer(agName, action);
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
     * Acción: move_to_shelf(ShelfId)
     * Calcula la primera celda adyacente a la estantería y emite nav_target(X,Y).
     * La navegación real la realiza el agente usando !navigate y move_step.
     */
    private boolean executeMoveToShelf(String agName, Structure action) {
        try {
            String shelfId = action.getTerm(0).toString().replace("\"", "");
            Shelf shelf = shelves.get(shelfId);
            if (shelf == null) {
                System.err.println("[" + agName + "] Shelf not found: " + shelfId);
                return false;
            }
            List<int[]> adyacentes = getAdyacentes(shelf.getX(), shelf.getY(), shelf.getWidth(), shelf.getHeight());
            for (int[] cell : adyacentes) {
                if (!hayContenedorEn(cell[0], cell[1])) {
                    emitNavTarget(agName, cell[0], cell[1]);
                    return true;
                }
            }
            System.err.println("[" + agName + "] All adjacent cells occupied for shelf " + shelfId);
            return false;
        } catch (Exception e) {
            e.printStackTrace();
            return false;
        }
    }

    /**
     * Acción: move_to_container(ContainerId)
     * Calcula la primera celda adyacente al contenedor y emite nav_target(X,Y).
     * La navegación real la realiza el agente usando !navigate y move_step.
     */
    private boolean executeMoveToContainer(String agName, Structure action) {
        try {
            String containerId = action.getTerm(0).toString().replace("\"", "");
            Container container = containers.get(containerId);
            if (container == null) {
                System.err.println("[" + agName + "] Container not found: " + containerId);
                addError(agName, "container_not_found", containerId);
                return false;
            }
            List<int[]> adyacentes = container.getAdyacentes(grid, GRID_WIDTH, GRID_HEIGHT);
            for (int[] cell : adyacentes) {
                if (!hayContenedorEn(cell[0], cell[1])) {
                    emitNavTarget(agName, cell[0], cell[1]);
                    return true;
                }
            }
            System.err.println("[" + agName + "] All adjacent cells occupied for container " + containerId);
            return false;
        } catch (Exception e) {
            e.printStackTrace();
            return false;
        }
    }

    /**
     * Acción: move_step(X, Y)
     * Primitiva de movimiento atómico: mueve el robot exactamente una celda a (X,Y).
     * Falla (devuelve false) si la celda está ocupada por otro robot o es un obstáculo
     * fijo (SHELF, BLOCKED). Si hay un contenedor no recogido en la celda destino,
     * lo aplasta y continúa (mecánica de aplastamiento).
     * Emite robot_pos(X,Y) tras el movimiento para que el agente actualice su posición.
     */
    private boolean executeMoveStep(String agName, Structure action) {
        try {
            int targetX = (int) ((NumberTerm) action.getTerm(0)).solve();
            int targetY = (int) ((NumberTerm) action.getTerm(1)).solve();

            Robot robot = robots.get(agName);
            if (robot == null) { addError(agName, "robot_not_found", agName); return false; }

            if (!estaDentroDelMapa(targetX, targetY)) return false;
            if (grid[targetX][targetY] == CellType.SHELF || grid[targetX][targetY] == CellType.BLOCKED) return false;
            // Evitar pisar contenedores durante la navegación: el agente elige otra dirección.
            // La mecánica de aplastamiento dentro del synchronized cubre solo la carrera
            // en que un contenedor aparece en la celda entre esta comprobación y el movimiento.
            if (hayContenedorEn(targetX, targetY)) return false;

            // El synchronized protege solo la comprobación robot+aplastamiento para evitar
            // que dos robots acaben en la misma celda por una carrera entre el check y el move.
            // El check hayContenedorEn anterior queda fuera del sync intencionalmente: es
            // la barrera "rápida" que evita el 99% de los conflictos sin bloquear el hilo.
            synchronized (this) {
                if (hayRobotCerca(targetX, targetY)) return false;

                // Mecánica de aplastamiento (carrera: contenedor apareció tras el check anterior)
                List<String> aplastados = new ArrayList<>();
                for (Container c : containers.values()) {
                    if (!c.isPicked() && !c.isBroken()
                            && c.getX() == targetX && c.getY() == targetY) {
                        aplastados.add(c.getId());
                    }
                }
                for (String crushedId : aplastados) {
                    containers.remove(crushedId);
                    claimedContainers.remove(crushedId);
                    System.err.println("[WARNING] " + agName + " aplastó " + crushedId
                            + " en (" + targetX + "," + targetY + ")");
                    if (view != null) view.logMessage("💥 " + agName + " aplastó " + crushedId);
                    try {
                        removePerceptsByUnif(ASSyntax.parseLiteral(
                            "container_at_entrance(\"" + crushedId + "\",_,_,_,_)"));
                        addPercept(ASSyntax.parseLiteral("container_broken(\"" + crushedId + "\")"));
                    } catch (jason.asSyntax.parser.ParseException e) {
                        e.printStackTrace();
                    }
                }

                robot.setPosition(targetX, targetY);
            }

            // Actualizar percepción de posición del robot
            removePerceptsByUnif(agName, ASSyntax.parseLiteral("robot_pos(_,_)"));
            addPercept(agName, ASSyntax.parseLiteral("robot_pos(" + targetX + "," + targetY + ")"));

            if (view != null) view.update();

            try {
                Thread.sleep(300);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }

            return true;
        } catch (Exception e) {
            e.printStackTrace();
            return false;
        }
    }

    /**
     * Emite/actualiza la percepción nav_target(X, Y) al agente.
     * move_to_shelf y move_to_container la usan para comunicar el destino
     * al agente sin navegar ellos mismos.
     */
    private void emitNavTarget(String agName, int x, int y) {
        try {
            removePerceptsByUnif(agName, ASSyntax.parseLiteral("nav_target(_,_)"));
            addPercept(agName, ASSyntax.parseLiteral("nav_target(" + x + "," + y + ")"));
        } catch (jason.asSyntax.parser.ParseException e) {
            e.printStackTrace();
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

            if (robot == null) { addError(agName, "robot_not_found", agName); return false; }
            if (container == null) {
                addError(agName, "invalid_pickup", "Container not found: " + containerId);
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
                // El robot conserva el contenedor: el agente decidirá llevarlo a la zona de expansión.
                addError(agName, "shelf_full", "Shelf " + shelfId + " full");
                return false;
            }

            // Depositar
            shelf.store(container);
            robot.drop();
            robot.setBusy(false);
            container.setAssignedShelf(shelfId);

            // Estantería llena: retirar shelf_available de todos los agentes
            if (shelf.isFull()) {
                try {
                    removePerceptsByUnif(ASSyntax.parseLiteral("shelf_available(\"" + shelfId + "\")"));
                } catch (jason.asSyntax.parser.ParseException e) {
                    e.printStackTrace();
                }
            }

            // Actualizar ocupación para que el scheduler pueda elegir la menos cargada.
            emitShelfOccupancy(shelfId, shelf);

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
     * Emite shelf_available(ShelfId) a todos los agentes.
     * Robots la usan para seleccionar estanterías autónomamente.
     */
    private void emitShelfAvailable(String shelfId) {
        try {
            addPercept(ASSyntax.parseLiteral("shelf_available(\"" + shelfId + "\")"));
        } catch (jason.asSyntax.parser.ParseException e) {
            e.printStackTrace();
        }
    }

    /**
     * Emite/actualiza shelf_occupancy(ShelfId, Occ) a todos los agentes.
     */
    private void emitShelfOccupancy(String shelfId, Shelf shelf) {
        try {
            removePerceptsByUnif(ASSyntax.parseLiteral("shelf_occupancy(\"" + shelfId + "\",_)"));
            int occ = (int) Math.round(shelf.getOccupancyPercentage());
            addPercept(ASSyntax.parseLiteral("shelf_occupancy(\"" + shelfId + "\"," + occ + ")"));
        } catch (jason.asSyntax.parser.ParseException e) {
            e.printStackTrace();
        }
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

            // Limpiar estado del robot en el entorno.
            // El drop físico es un mecanismo de seguridad: si un fallo de plan deja al robot
            // llevando un contenedor sin llegar a llamar unclaim_container, evita que el
            // contenedor quede permanentemente perdido. El agente Jason ya habrá reseteado
            // su creencia carrying(none), pero Java necesita sincronizarse.
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

    /**
     * Acción: move_to_expansion
     * Encuentra la celda libre más cercana de la zona CLASSIFICATION y emite nav_target(X,Y).
     */
    private boolean executeMoveToExpansion(String agName) {
        try {
            Robot robot = robots.get(agName);
            if (robot == null) return false;

            List<int[]> cells = new ArrayList<>();
            for (int x = 0; x < GRID_WIDTH; x++) {
                for (int y = 0; y < GRID_HEIGHT; y++) {
                    if (grid[x][y] == CellType.CLASSIFICATION && !hayContenedorEn(x, y)) {
                        cells.add(new int[]{x, y});
                    }
                }
            }
            if (cells.isEmpty()) return false;

            // Celda más cercana al robot: minimiza el trayecto y reduce la probabilidad
            // de que el corredor y=2 esté saturado durante la navegación de expansión.
            cells.sort((a, b) -> {
                int da = Math.abs(a[0] - robot.getX()) + Math.abs(a[1] - robot.getY());
                int db = Math.abs(b[0] - robot.getX()) + Math.abs(b[1] - robot.getY());
                return Integer.compare(da, db);
            });

            emitNavTarget(agName, cells.get(0)[0], cells.get(0)[1]);
            return true;
        } catch (Exception e) {
            e.printStackTrace();
            return false;
        }
    }

    /**
     * Acción: drop_in_expansion(ContainerId)
     * Deposita el contenedor en la celda actual del robot (zona CLASSIFICATION).
     */
    private boolean executeDropInExpansion(String agName, Structure action) {
        try {
            String containerId = action.getTerm(0).toString().replace("\"", "");
            Robot robot = robots.get(agName);
            Container container = containers.get(containerId);

            if (robot == null || container == null) return false;
            if (!robot.isCarrying()) return false;

            int rx = robot.getX(), ry = robot.getY();
            robot.drop();
            container.setPicked(false);
            container.setPosition(rx, ry);
            // No se re-emite container_at_entrance aquí: el agente Jason notifica
            // container_in_expansion al scheduler, que decide si reasignar o esperar.

            System.out.println("[" + agName + "] " + containerId + " depositado en zona de expansión (" + rx + "," + ry + ")");
            if (view != null) {
                view.logMessage("📦 " + agName + " → expansión: " + containerId + " (" + rx + "," + ry + ")");
                view.update();
            }
            return true;
        } catch (Exception e) {
            e.printStackTrace();
            return false;
        }
    }

    /**
     * Acción: claim_container(ContainerId)
     * Reclama atómicamente un contenedor. Falla si ya fue reclamado.
     * En éxito, retira container_at_entrance de todos los agentes.
     */
    private boolean executeClaimContainer(String agName, Structure action) {
        try {
            String containerId = action.getTerm(0).toString().replace("\"", "");
            Container container = containers.get(containerId);
            if (container == null || container.isBroken()) return false;

            // putIfAbsent es atómica: garantiza que solo un robot puede reclamar
            // el contenedor aunque varios ejecuten claim_container simultáneamente.
            String prev = claimedContainers.putIfAbsent(containerId, agName);
            if (prev != null) {
                System.err.println("[CLAIM FAIL] " + agName + " no pudo reclamar " + containerId + " — ya reclamado por: " + prev);
                return false;
            }

            removePerceptsByUnif(ASSyntax.parseLiteral(
                "container_at_entrance(\"" + containerId + "\",_,_,_,_)"));

            if (view != null) view.logMessage("🔒 " + agName + " reclamó " + containerId);
            return true;
        } catch (Exception e) {
            e.printStackTrace();
            return false;
        }
    }

    /**
     * Devuelve una celda libre de la zona ENTRANCE, o (5,0) como fallback.
     */
    private int[] findFreeEntranceCell() {
        List<int[]> cells = new ArrayList<>();
        for (int x = 0; x < GRID_WIDTH; x++) {
            for (int y = 0; y < GRID_HEIGHT; y++) {
                if (grid[x][y] == CellType.ENTRANCE && !hayContenedorEn(x, y)) {
                    cells.add(new int[]{x, y});
                }
            }
        }
        return cells.isEmpty() ? new int[]{5, 0} : cells.get(0);
    }

    /**
     * Acción: unclaim_container(ContainerId)
     * Libera el reclamo y re-emite container_at_entrance para otros robots.
     */
    private boolean executeUnclaimContainer(String agName, Structure action) {
        try {
            String containerId = action.getTerm(0).toString().replace("\"", "");
            claimedContainers.remove(containerId);

            // Si el robot lleva físicamente este contenedor, soltarlo y reposicionar
            // a una celda libre de la zona de entrada (fix Bug 3: evita depositar en
            // una posición arbitraria del almacén inaccesible para otros robots).
            // Si el contenedor ya fue colocado intencionalmente en otro lugar (p. ej.
            // zona de expansión vía drop_in_expansion), no modificar su posición.
            Robot robot = robots.get(agName);
            boolean wasCarrying = false;
            if (robot != null && robot.isCarrying()) {
                Container carried = robot.getCarriedContainer();
                if (carried != null && containerId.equals(carried.getId())) {
                    robot.drop();
                    carried.setPicked(false);
                    wasCarrying = true;
                }
            }

            Container container = containers.get(containerId);
            if (container == null || container.isBroken()) return true;

            if (wasCarrying) {
                int[] cell = findFreeEntranceCell();
                container.setPosition(cell[0], cell[1]);
            }

            addPercept(ASSyntax.parseLiteral(
                "container_at_entrance(\"" + containerId + "\",\"" + container.getType() + "\"," +
                container.getWeight() + "," + container.getWidth() + "," + container.getHeight() + ")"));

            if (view != null) view.logMessage("🔓 " + agName + " liberó " + containerId);
            return true;
        } catch (Exception e) {
            e.printStackTrace();
            return false;
        }
    }

    /**
     * Acción: pickup_from_shelf(ContainerId, ShelfId)
     * Recoge un contenedor almacenado en una estantería (ciclo de salida).
     */
    private boolean executePickupFromShelf(String agName, Structure action) {
        try {
            String containerId = action.getTerm(0).toString().replace("\"", "");
            String shelfId = action.getTerm(1).toString().replace("\"", "");

            Robot robot = robots.get(agName);
            Container container = containers.get(containerId);
            Shelf shelf = shelves.get(shelfId);

            if (robot == null || container == null || shelf == null) return false;
            if (robot.isCarrying()) { addError(agName, "already_carrying", "Robot already carrying"); return false; }
            if (!shelfId.equals(container.getAssignedShelf())) {
                addError(agName, "not_in_shelf", "Container not assigned to " + shelfId);
                return false;
            }
            if (robot.distanceTo(shelf.getX(), shelf.getY()) > 3) {
                addError(agName, "too_far", "Shelf too far for exit pickup");
                return false;
            }
            if (!robot.canCarry(container)) {
                addError(agName, "container_too_heavy", "Container too heavy for exit pickup");
                return false;
            }

            if (!shelf.remove(container)) {
                addError(agName, "not_in_shelf", "Container not found in shelf storage");
                return false;
            }

            // Al retirar un contenedor la estantería recupera espacio: re-emitir
            // shelf_available aunque no estuviera llena (idempotente) y actualizar
            // ocupación para que los robots puedan volver a elegirla como destino.
            emitShelfAvailable(shelf.getId());
            emitShelfOccupancy(shelf.getId(), shelf);

            container.setAssignedShelf(null);
            robot.pickup(container);

            addPercept(agName, ASSyntax.parseLiteral("picked(\"" + containerId + "\")"));
            if (view != null) {
                view.logMessage("📤 " + agName + " recogió " + containerId + " de " + shelfId + " (salida)");
                view.update();
            }
            return true;
        } catch (Exception e) {
            e.printStackTrace();
            return false;
        }
    }

    /**
     * Acción: move_to_outbound
     * Emite nav_target a la celda libre más cercana de la zona OUTBOUND.
     */
    private boolean executeMoveToOutbound(String agName) {
        try {
            Robot robot = robots.get(agName);
            if (robot == null) return false;

            List<int[]> cells = new ArrayList<>();
            for (int x = 0; x < GRID_WIDTH; x++) {
                for (int y = 0; y < GRID_HEIGHT; y++) {
                    if (grid[x][y] == CellType.OUTBOUND && !hayContenedorEn(x, y) && !hayRobotCerca(x, y)) {
                        cells.add(new int[]{x, y});
                    }
                }
            }
            if (cells.isEmpty()) return false;

            cells.sort((a, b) -> {
                // Preferir y=0 sobre y=1: se llena el fondo primero para que y=1 quede
                // libre como pasillo de acceso. El guard Y>=2 en navigate evita el bucle
                // arriba-abajo al reintentar desde y=1.
                if (a[1] != b[1]) return Integer.compare(a[1], b[1]);
                int da = Math.abs(a[0] - robot.getX()) + Math.abs(a[1] - robot.getY());
                int db = Math.abs(b[0] - robot.getX()) + Math.abs(b[1] - robot.getY());
                return Integer.compare(da, db);
            });

            emitNavTarget(agName, cells.get(0)[0], cells.get(0)[1]);
            return true;
        } catch (Exception e) {
            e.printStackTrace();
            return false;
        }
    }

    /**
     * Acción: drop_in_outbound(ContainerId)
     * Deposita el contenedor en la zona de salida. Robot debe estar en celda OUTBOUND.
     */
    private boolean executeDropInOutbound(String agName, Structure action) {
        try {
            String containerId = action.getTerm(0).toString().replace("\"", "");
            Robot robot = robots.get(agName);
            Container container = containers.get(containerId);

            if (robot == null || container == null) return false;
            if (!robot.isCarrying()) { addError(agName, "not_carrying", "Not carrying anything"); return false; }

            int rx = robot.getX(), ry = robot.getY();
            if (grid[rx][ry] != CellType.OUTBOUND) {
                addError(agName, "not_at_outbound", "Robot not in outbound zone");
                return false;
            }

            robot.drop();
            robot.setBusy(false);
            container.setPicked(false);
            container.setPosition(rx, ry);

            totalContainersProcessed++;
            removePerceptsByUnif(agName, ASSyntax.parseLiteral("picked(_)"));

            if (view != null) {
                view.logMessage("🚚 " + agName + " entregó " + containerId + " a zona de salida");
                view.update();
            }

            addPercept("scheduler", ASSyntax.parseLiteral("container_exited(\"" + containerId + "\")"));
            return true;
        } catch (Exception e) {
            e.printStackTrace();
            return false;
        }
    }

    /**
     * Acción: discard_container(ContainerId)
     * Elimina permanentemente un contenedor del sistema (inaccesible definitivo).
     */
    private boolean executeDiscardContainer(String agName, Structure action) {
        try {
            String containerId = action.getTerm(0).toString().replace("\"", "");
            containers.remove(containerId);
            claimedContainers.remove(containerId);
            try {
                removePerceptsByUnif(ASSyntax.parseLiteral(
                    "container_at_entrance(\"" + containerId + "\",_,_,_,_)"));
            } catch (Exception e) {
                e.printStackTrace();
            }
            if (view != null) view.logMessage("🗑️ " + containerId + " descartado definitivamente");
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
     * Marca el robot como ocupado en Java (evita doble asignación vía request_task)
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
