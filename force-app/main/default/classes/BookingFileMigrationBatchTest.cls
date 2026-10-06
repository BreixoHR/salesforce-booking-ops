@IsTest
private class BookingFileMigrationBatchTest {
    private static Id attach(Id parentId, String title) {
        ContentVersion cv = new ContentVersion(
            Title = title,
            PathOnClient = title + '.pdf',
            VersionData = Blob.valueOf('pdf'),
            FirstPublishLocationId = parentId
        );
        insert cv;
        return [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
    }

    @IsTest
    static void movesFilesOfFutureBookingsToEntradaTicket() {
        Product2 product = new Product2(Name = 'Combo');
        Product2 other = new Product2(Name = 'Otro');
        insert new List<Product2>{ product, other };

        Booking__c future = new Booking__c(Product__c = product.Id, Visit_Date__c = Date.today().addDays(10));
        Booking__c past = new Booking__c(Product__c = product.Id, Visit_Date__c = Date.today().addDays(-1));
        Booking__c otherProduct = new Booking__c(Product__c = other.Id, Visit_Date__c = Date.today().addDays(10));
        Booking__c noTicket = new Booking__c(Product__c = product.Id, Visit_Date__c = Date.today().addDays(5));
        insert new List<Booking__c>{ future, past, otherProduct, noTicket };

        Ticket__c entrada = new Ticket__c(Name = 'Entrada', Booking__c = future.Id);
        insert new List<Ticket__c>{
            entrada,
            new Ticket__c(Name = 'Bono', Booking__c = future.Id),
            new Ticket__c(Name = 'Entrada', Booking__c = past.Id),
            new Ticket__c(Name = 'Entrada', Booking__c = otherProduct.Id)
        };

        Id doc1 = attach(future.Id, 'a');
        Id doc2 = attach(future.Id, 'b');
        attach(past.Id, 'c');
        attach(otherProduct.Id, 'd');
        attach(noTicket.Id, 'e');

        Test.startTest();
        Database.executeBatch(new BookingFileMigrationBatch(new Set<Id>{ product.Id }), 50);
        Test.stopTest();

        Set<Id> onTicket = new Set<Id>();
        for (ContentDocumentLink l : [
            SELECT ContentDocumentId
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :entrada.Id
        ]) {
            onTicket.add(l.ContentDocumentId);
        }
        Assert.areEqual(new Set<Id>{ doc1, doc2 }, onTicket);
        Assert.areEqual(
            0,
            [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :future.Id],
            'se mueven, no se copian'
        );
        Assert.areEqual(
            1,
            [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :past.Id],
            'reservas pasadas intactas'
        );
        Assert.areEqual(
            1,
            [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :otherProduct.Id],
            'otros productos intactos'
        );
        Assert.areEqual(
            1,
            [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :noTicket.Id],
            'sin ticket de entrada no se toca'
        );
    }

    @IsTest
    static void requiresProducts() {
        try {
            new BookingFileMigrationBatch(new Set<Id>());
            Assert.fail('debería exigir productos');
        } catch (IllegalArgumentException e) {
            Assert.isTrue(e.getMessage().contains('producto'));
        }
    }
}
