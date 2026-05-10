package warehouse;

import java.util.*;

/**
 * Representa un contenedor en el almacén.
 *
 * Ciclo de vida:
 * generado por el hilo ContainerGenerator con posición en zona ENTRANCE.
 * reclamado atómicamente por un robot (picked=true durante el transporte).
 * depositado en una estantería (assignedShelf != null) o en zona de expansión.
 * recogido de la estantería durante el ciclo de salida y entregado a OUTBOUND.
 * eliminado del sistema por el agente transport (collect_outbound_containers).
 *
 * El campo broken=true marca contenedores destruidos por la mecánica de aplastamiento
 * (robot ocupa la misma celda que el contenedor). Estos contenedores se eliminan del mapa
 * pero la percepción container_broken se mantiene para auditoría.
 */
public class Container {
    private final String id;
    private final int width;
    private final int height;
    private final double weight;
    private final String type; // "standard", "fragile", "urgent"
    private boolean picked;    // true mientras un robot lo transporta físicamente
    private boolean broken;    // true si fue aplastado (destruido permanentemente)
    private String assignedShelf;
    private int x, y; // posición actual en el grid (−1 hasta la primera colocación)

    public Container(String id, int width, int height, double weight, String type) {
        this.id = id;
        this.width = width;
        this.height = height;
        this.weight = weight;
        this.type = type;
        this.picked = false;
        this.broken = false;
        this.assignedShelf = null;
        this.x = -1; // -1 hasta que el generador lo coloca en una celda ENTRANCE
        this.y = -1;
    }
    
    // Getters
    public String getId() { 
        return id; 
    }

    public int getWidth() { 
        return width; 
    }

    public int getHeight() { 
        return height; 
    }

    public double getWeight() { 
        return weight; 
    }

    public String getType() { 
        return type; 
    }

    public boolean isPicked() { 
        return picked; 
    }

    public boolean isBroken() { 
        return broken; 
    }

    public void setBroken(boolean broken) { 
        this.broken = broken; 
    }

    public String getAssignedShelf() { 
        return assignedShelf; 
    }

    public int getX() { 
        return x; 
    }
    
    public int getY() { 
        return y; 
    }
    
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
     * tratado como 1x1 en su posición (x,y) (el tamaño visual es siempre 1x1).
     * Filtra celdas fuera del mapa, SHELF y BLOCKED.
     * Usado por executeMoveToContainer.
     */
    public List<int[]> getAdyacentes(CellType[][] grid, int gridWidth, int gridHeight) {
        List<int[]> result = new ArrayList<>();
        // Orden: abajo primero (y+1) → los robots se aproximan desde y>1 hacia la zona de entrada
        int[][] dirs = {{0, 1}, {1, 0}, {-1, 0}, {0, -1}};
        for (int[] d : dirs) {
            int ax = x + d[0], ay = y + d[1];
            if (ax >= 0 && ax < gridWidth && ay >= 0 && ay < gridHeight
                    && grid[ax][ay] != CellType.SHELF && grid[ax][ay] != CellType.BLOCKED)
                result.add(new int[]{ax, ay});
        }
        return result;
    }
}
