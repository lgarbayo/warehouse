package warehouse;

/**
 * Representa un contenedor en el almacén
 */
public class Container {
    private final String id;
    private final int width;
    private final int height;
    private final double weight;
    private final String type; // "standard", "fragile", "urgent"
    private boolean picked;
    private String assignedShelf;
    private int x, y; // posición actual
    
    public Container(String id, int width, int height, double weight, String type) {
        this.id = id;
        this.width = width;
        this.height = height;
        this.weight = weight;
        this.type = type;
        this.picked = false;
        this.assignedShelf = null;
        this.x = -1;
        this.y = -1;
    }
    
    // Getters
    public String getId() { return id; }
    public int getWidth() { return width; }
    public int getHeight() { return height; }
    public double getWeight() { return weight; }
    public String getType() { return type; }
    public boolean isPicked() { return picked; }
    public String getAssignedShelf() { return assignedShelf; }
    public int getX() { return x; }
    public int getY() { return y; }
    
    // Setters
    public void setPicked(boolean picked) { this.picked = picked; }
    public void setAssignedShelf(String shelfId) { this.assignedShelf = shelfId; }
    public void setPosition(int x, int y) { this.x = x; this.y = y; }
    
    @Override
    public String toString() {
        return String.format("Container[%s: %dx%d, %.1fkg, %s]", 
            id, width, height, weight, type);
    }
    
    /**
     * Categoría de peso del contenedor
     */
    public String getWeightCategory() {
        if (weight <= 10) return "light";
        if (weight <= 30) return "medium";
        return "heavy";
    }
    
    /**
     * Calcula el área del contenedor
     */
    public int getArea() {
        return width * height;
    }

    /**
     * Devuelve las celdas adyacentes ortogonales (sin diagonales) a este CONTENEDOR,
     * usando su posición (x,y) y dimensiones (width x height) propias.
     * Filtra celdas fuera del mapa, SHELF y BLOCKED.
     * El grid y sus dimensiones se pasan desde WarehouseArtifact ya que el contenedor
     * no tiene acceso directo al estado del entorno.
     * Usado por executeMoveToContainer.
     */
    public java.util.List<int[]> getAdyacentes(CellType[][] grid, int gridWidth, int gridHeight) {
        java.util.List<int[]> result = new java.util.ArrayList<>();
        // Fila superior
        for (int i = 0; i < width; i++) {
            int ax = x + i, ay = y - 1;
            if (ax >= 0 && ax < gridWidth && ay >= 0 && ay < gridHeight
                    && grid[ax][ay] != CellType.SHELF && grid[ax][ay] != CellType.BLOCKED)
                result.add(new int[]{ax, ay});
        }
        // Fila inferior
        for (int i = 0; i < width; i++) {
            int ax = x + i, ay = y + height;
            if (ax >= 0 && ax < gridWidth && ay >= 0 && ay < gridHeight
                    && grid[ax][ay] != CellType.SHELF && grid[ax][ay] != CellType.BLOCKED)
                result.add(new int[]{ax, ay});
        }
        // Columna izquierda
        for (int j = 0; j < height; j++) {
            int ax = x - 1, ay = y + j;
            if (ax >= 0 && ax < gridWidth && ay >= 0 && ay < gridHeight
                    && grid[ax][ay] != CellType.SHELF && grid[ax][ay] != CellType.BLOCKED)
                result.add(new int[]{ax, ay});
        }
        // Columna derecha
        for (int j = 0; j < height; j++) {
            int ax = x + width, ay = y + j;
            if (ax >= 0 && ax < gridWidth && ay >= 0 && ay < gridHeight
                    && grid[ax][ay] != CellType.SHELF && grid[ax][ay] != CellType.BLOCKED)
                result.add(new int[]{ax, ay});
        }
        return result;
    }
}
