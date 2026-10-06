# Historial de versiones

Cada módulo de este repositorio es la reescritura (2026-10) de un desarrollo que estuvo en producción. Las fechas son las del original.

## Reescritura pública · 2026-10-05 → 2026-10-06
- Los seis módulos con Custom Metadata en lugar de valores fijados en el código, operaciones bulk-safe, tests Apex y lint en CI.

## Webhook OCTO (Ventrata) · 2026-03-08 → 2026-07-23
| Fecha | Cambio |
|---|---|
| 2026-03-08 → 03-09 | Análisis del estándar OCTO y borrador del webhook |
| 2026-06-17 | **Ventrata V1** en producción, con corrección de la consulta de colas cuando la cola no existe en la org |
| 2026-06-19 | V2 y **V3 a nivel de pedido** (order_update); nuevos tipos de entrada |
| 2026-06-24 → 06-25 | Correcciones 4 y 5 |
| 2026-06-26 | Mismo patrón aplicado a **Musement** |
| 2026-07-07 | Corrección de sub-identificadores y documentación del servicio |
| 2026-07-23 | *Supplier reference* en las reservas OCTO |

## Turnos en el punto de encuentro · 2025-09-26 → 2026-03-09
- **V1–V1.3** (2025-09-26): tótem de bienvenida y panel de llamada por áreas.
- **V1.4–V1.5** (2025-10-01 → 10-02): versión estable.
- **V1.6** (2025-10-02): modo *blackout*.
- **V1.7** (2026-03-09).

## Agrupación de compras · 2025-05-30 → 2025-07-25
- **2025-05-30**: agrupación automática por producto, ventana de minutos y límite (Custom Metadata), con página de alertas de compra.
- **2025-06-25 → 2025-07-25**: gestión manual de grupos V1–V3, con descarga de entradas y CSV por grupo.
- **2026-06-03**: corrección de la reserva de grupos.

## Migración de ficheros a tickets · 2025-05-06 → 2025-05-07
- Batch que mueve los ficheros de las reservas futuras al ticket de entrada, con su test.

## Enrutado de incidencias y reseñas · 2025-04-29 → 2025-04-30
- **1.0**: trigger de reorganización de colas por producto.
- **1.1**: handler con creación de reseñas desde casos.

## Conciliación diaria con la plataforma de reservas · 2025-04-28 → 2025-05-21
- Comparación de pedidos por *order id* y conteo de reservas del día anterior por cuenta.
- Página Visualforce de comparativa diaria (revisiones 1 y 2).
