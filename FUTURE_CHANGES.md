# Future Changes

## Mostrar lista contenedores al final
## Resolver tema de tipos de containers (standard, urgent y fragile)

### Los path_blocked - No route found to (0,0) no cuentan gracias al -!check_queue que los descarta. Por qué? Porque el retorno a base es una funcionalidad de comodidad — si no puede volver, no pasa nada, el robot simplemente se queda donde terminó la última entrega y sigue operativo para la siguiente tarea. Si ese fallo llegara al supervisor contaminaría total_errors y error_rate con algo que no es un error real del sistema. Un robot que no puede volver a su posición inicial no afecta para nada a la operación del almacén.