# Bugs y mejoras pendientes (detectados en logs)

## Bug 1 — `Pendientes en proceso` negativo en supervisor (`supervisor.asl`)

**Síntoma**: el reporte de estadísticas muestra `Pendientes en proceso: -5`.

**Causa**: la fórmula `pending = received - stored - errors` cuenta los eventos `deadline_missed` como errores terminales, pero esos contenedores **siguen físicamente en las estanterías** — no se han perdido. Al descontarlos del pending como si fueran eliminados, el contador baja por debajo de cero.

**Solución propuesta**: distinguir errores terminales (contenedor perdido/descartado) de eventos informativos (`deadline_missed`). Solo los primeros deben restar del pending.

---

## Bug 2 — `deadline_missed` para contenedores fuera del alcance del ciclo de salida (`supervisor.asl`)

**Síntoma**: al terminar el deadline, `container_12` (almacenado exactamente en t=8436, el momento del deadline) y contenedores previos como `container_1`, `container_3`, `container_6` reciben `deadline_missed` aunque no fueron objetivos explícitos del ciclo de salida que acababa de terminar.

**Causa**: el supervisor marca como `deadline_missed` todos los contenedores `non_urgent` que siguen en estanterías al terminar el deadline, independientemente de si llegaron durante el ciclo o si el robot simplemente no tuvo tiempo de evacuarlos todos.

**Solución propuesta**: registrar qué contenedores eran candidatos al inicio del ciclo (snapshot en T0) y aplicar `deadline_missed` solo a esos, no a los que llegaron durante el ciclo.

---

## Bug 3 — Contenedores atascados sin nuevo ciclo de salida tras deadline_ended (`scheduler.asl`, `supervisor.asl`)

**Síntoma**: tras `deadline_ended`, robots heavy fallan repetidamente `no_shelf_space` sin que se dispare un nuevo ciclo de salida en los logs.

**Causa probable**: la re-detección de saturación puede quedar bloqueada si el belief `exit_cycle` o `blocked_type` no se limpia correctamente al terminar el ciclo anterior, impidiendo que el supervisor notifique al scheduler de la nueva saturación.

**Solución propuesta**: verificar que tras `deadline_ended` se limpian correctamente `exit_cycle`, `blocked_type` y el estado interno del scheduler para permitir un nuevo ciclo inmediato si la saturación persiste.