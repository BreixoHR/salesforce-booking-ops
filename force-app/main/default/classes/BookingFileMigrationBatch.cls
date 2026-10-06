/**
 * Mueve los ficheros adjuntos a reservas futuras de ciertos productos a su Ticket__c de "Entrada",
 * que es donde los busca el resto de la automatización (envío al cliente, lectura de fecha...).
 *
 *   Database.executeBatch(new BookingFileMigrationBatch(productIds), 50);
 *
 * Mueve = crea el nuevo ContentDocumentLink y borra el antiguo: el fichero (ContentDocument) es
 * el mismo, no se duplica almacenamiento.
 */
public with sharing class BookingFileMigrationBatch implements Database.Batchable<SObject>, Database.Stateful {
    private final Set<Id> productIds;
    @TestVisible
    private Integer moved = 0;

    public BookingFileMigrationBatch(Set<Id> productIds) {
        if (productIds == null || productIds.isEmpty()) {
            throw new IllegalArgumentException('Indica al menos un producto');
        }
        this.productIds = productIds;
    }

    public Database.QueryLocator start(Database.BatchableContext bc) {
        Date today = Date.today();
        return Database.getQueryLocator(
            [
                SELECT
                    Id,
                    (SELECT Id, Name FROM Tickets__r WHERE Name LIKE '%Entrada%' ORDER BY CreatedDate LIMIT 1),
                    (SELECT Id, ContentDocumentId, ShareType, Visibility FROM ContentDocumentLinks)
                FROM Booking__c
                WHERE Product__c IN :productIds AND Visit_Date__c >= :today
            ]
        );
    }

    public void execute(Database.BatchableContext bc, List<Booking__c> scope) {
        List<ContentDocumentLink> toInsert = new List<ContentDocumentLink>();
        List<ContentDocumentLink> toDelete = new List<ContentDocumentLink>();

        for (Booking__c b : scope) {
            if (b.Tickets__r.isEmpty() || b.ContentDocumentLinks.isEmpty()) {
                continue;
            }
            Id ticketId = b.Tickets__r[0].Id;
            for (ContentDocumentLink link : b.ContentDocumentLinks) {
                toInsert.add(
                    new ContentDocumentLink(
                        ContentDocumentId = link.ContentDocumentId,
                        LinkedEntityId = ticketId,
                        ShareType = link.ShareType,
                        Visibility = link.Visibility
                    )
                );
                toDelete.add(link);
            }
        }

        // Primero insertar: si falla, no se ha borrado nada y el fichero sigue accesible
        insert toInsert;
        delete toDelete;
        moved += toInsert.size();
    }

    public void finish(Database.BatchableContext bc) {
        System.debug(LoggingLevel.INFO, 'BookingFileMigrationBatch: ficheros movidos = ' + moved);
    }
}
