/**
 * Contrato común para plataformas de venta (Regiondo, FareHarbor, Turitop...).
 * La conciliación solo necesita las referencias de pedido vendidas en un día.
 */
public interface BookingPlatform {
    /** Referencias de pedido vendidas en `day` para la cuenta indicada. */
    Set<String> listOrderReferences(Booking_Platform_Account__mdt account, Date day);
}
