@IsTest
private class PurchaseGroupingServiceTest {
    private static final Datetime T0 = Datetime.newInstanceGmt(2026, 5, 20, 9, 0, 0);

    private static Purchase_Grouping_Rule__mdt rule(String code, Integer max, Integer windowMinutes) {
        return (Purchase_Grouping_Rule__mdt) JSON.deserialize(
            JSON.serialize(
                new Map<String, Object>{
                    'Product_Code__c' => code,
                    'Max_Bookings__c' => max,
                    'Window_Minutes__c' => windowMinutes,
                    'Active__c' => true
                }
            ),
            Purchase_Grouping_Rule__mdt.class
        );
    }

    @TestSetup
    static void setup() {
        insert new List<Product2>{
            new Product2(Name = 'Visita guiada', ProductCode = 'GUIDED'),
            new Product2(Name = 'Sin agrupación', ProductCode = 'SOLO')
        };
    }

    private static Id product(String code) {
        return [SELECT Id FROM Product2 WHERE ProductCode = :code].Id;
    }

    private static Booking__c booking(String ref, Integer minutesFromT0, Integer pax) {
        return new Booking__c(
            Platform_Reference__c = ref,
            Product__c = product('GUIDED'),
            Status__c = PurchaseGroupingService.STATUS_CONFIRMED,
            Start_Date_Time__c = T0.addMinutes(minutesFromT0),
            Attendees__c = pax,
            Contact_Name__c = 'Cliente ' + ref
        );
    }

    private static Map<String, Booking__c> byRef() {
        Map<String, Booking__c> m = new Map<String, Booking__c>();
        for (Booking__c b : [SELECT Platform_Reference__c, Purchase_Group__c FROM Booking__c]) {
            m.put(b.Platform_Reference__c, b);
        }
        return m;
    }

    @IsTest
    static void groupsByWindowAndCapacity() {
        PurchaseGroupingService.rulesOverride = new List<Purchase_Grouping_Rule__mdt>{ rule('GUIDED', 3, 60) };

        Test.startTest();
        // Insertadas desordenadas a propósito: la más temprana abre el grupo
        insert new List<Booking__c>{
            booking('B', 30, 2),
            booking('A', 0, 1),
            booking('C', 45, 4),
            booking('D', 50, 1), // grupo 1 lleno (3) → abre grupo 2
            booking('E', 120, 2) // fuera de la ventana de ambos → grupo 3
        };
        Test.stopTest();

        Map<String, Booking__c> b = byRef();
        Assert.areEqual(b.get('A').Purchase_Group__c, b.get('B').Purchase_Group__c);
        Assert.areEqual(b.get('A').Purchase_Group__c, b.get('C').Purchase_Group__c);
        Assert.areNotEqual(b.get('A').Purchase_Group__c, b.get('D').Purchase_Group__c);
        Assert.areNotEqual(b.get('D').Purchase_Group__c, b.get('E').Purchase_Group__c);

        Purchase_Group__c g1 = [
            SELECT Status__c, Booking_Count__c, Total_Attendees__c, Window_Start__c, Window_End__c
            FROM Purchase_Group__c
            WHERE Id = :b.get('A').Purchase_Group__c
        ];
        Assert.areEqual(PurchaseGroupingService.GROUP_FULL, g1.Status__c);
        Assert.areEqual(3, g1.Booking_Count__c.intValue());
        Assert.areEqual(7, g1.Total_Attendees__c.intValue());
        Assert.areEqual(T0, g1.Window_Start__c);
        Assert.areEqual(T0.addMinutes(60), g1.Window_End__c);
        Assert.areEqual(3, [SELECT COUNT() FROM Purchase_Group__c]);
    }

    @IsTest
    static void laterBookingsJoinExistingOpenGroup() {
        PurchaseGroupingService.rulesOverride = new List<Purchase_Grouping_Rule__mdt>{ rule('GUIDED', 3, 60) };
        insert booking('A', 0, 1);

        Test.startTest();
        insert booking('B', 20, 1); // otra transacción: se une al grupo abierto
        Test.stopTest();

        Map<String, Booking__c> b = byRef();
        Assert.areEqual(b.get('A').Purchase_Group__c, b.get('B').Purchase_Group__c);
        Assert.areEqual(2, [SELECT Booking_Count__c FROM Purchase_Group__c].Booking_Count__c.intValue());
    }

    @IsTest
    static void cancellingFreesTheSlotAndReopensGroup() {
        PurchaseGroupingService.rulesOverride = new List<Purchase_Grouping_Rule__mdt>{ rule('GUIDED', 2, 60) };
        insert new List<Booking__c>{ booking('A', 0, 2), booking('B', 10, 3) };
        Booking__c bb = [SELECT Id FROM Booking__c WHERE Platform_Reference__c = 'B'];

        Test.startTest();
        update new Booking__c(Id = bb.Id, Status__c = 'Cancelled');
        Test.stopTest();

        Assert.isNull([SELECT Purchase_Group__c FROM Booking__c WHERE Id = :bb.Id].Purchase_Group__c);
        Purchase_Group__c g = [SELECT Status__c, Booking_Count__c, Total_Attendees__c FROM Purchase_Group__c];
        Assert.areEqual(PurchaseGroupingService.GROUP_OPEN, g.Status__c);
        Assert.areEqual(1, g.Booking_Count__c.intValue());
        Assert.areEqual(2, g.Total_Attendees__c.intValue());
    }

    @IsTest
    static void purchasedGroupsAreFrozen() {
        PurchaseGroupingService.rulesOverride = new List<Purchase_Grouping_Rule__mdt>{ rule('GUIDED', 2, 60) };
        insert new List<Booking__c>{ booking('A', 0, 2), booking('B', 10, 3) };
        Purchase_Group__c g = [SELECT Id FROM Purchase_Group__c];
        update new Purchase_Group__c(Id = g.Id, Status__c = PurchaseGroupingService.GROUP_PURCHASED);
        Booking__c bb = [SELECT Id FROM Booking__c WHERE Platform_Reference__c = 'B'];

        Test.startTest();
        update new Booking__c(Id = bb.Id, Attendees__c = 5);
        Test.stopTest();

        Assert.areEqual(g.Id, [SELECT Purchase_Group__c FROM Booking__c WHERE Id = :bb.Id].Purchase_Group__c);
        Assert.areEqual(PurchaseGroupingService.GROUP_PURCHASED, [SELECT Status__c FROM Purchase_Group__c].Status__c);
    }

    @IsTest
    static void ignoresPendingAndProductsWithoutRule() {
        PurchaseGroupingService.rulesOverride = new List<Purchase_Grouping_Rule__mdt>{ rule('GUIDED', 3, 60) };
        Booking__c pending = booking('P', 0, 1);
        pending.Status__c = 'Pending';
        Booking__c solo = booking('S', 0, 1);
        solo.Product__c = product('SOLO');

        insert new List<Booking__c>{ pending, solo };

        Assert.areEqual(0, [SELECT COUNT() FROM Purchase_Group__c]);
    }

    @IsTest
    static void bulkInsertUsesConstantQueries() {
        PurchaseGroupingService.rulesOverride = new List<Purchase_Grouping_Rule__mdt>{ rule('GUIDED', 10, 60) };
        List<Booking__c> many = new List<Booking__c>();
        for (Integer i = 0; i < 200; i++) {
            many.add(booking('R' + i, i, 1)); // 1 reserva por minuto durante 200 minutos
        }

        Test.startTest();
        insert many;
        Integer queries = Limits.getQueries();
        Test.stopTest();

        Assert.areEqual(20, [SELECT COUNT() FROM Purchase_Group__c], '200 reservas / 10 por grupo');
        Assert.isTrue(queries <= 5, 'consultas constantes para 200 reservas: ' + queries);
    }

    @IsTest
    static void csvExportEscapesAndOrders() {
        PurchaseGroupingService.rulesOverride = new List<Purchase_Grouping_Rule__mdt>{ rule('GUIDED', 3, 60) };
        Booking__c a = booking('A', 10, 2);
        a.Contact_Name__c = '=HYPERLINK("x")';
        Booking__c b = booking('B', 0, 1);
        b.Contact_Name__c = 'García, Ana';
        insert new List<Booking__c>{ a, b };

        String csv = PurchaseGroupingService.toCsv([SELECT Id FROM Purchase_Group__c].Id);
        List<String> lines = csv.split('\n');
        Assert.areEqual('Localizador,Titular,Asistentes,Inicio', lines[0]);
        Assert.isTrue(lines[1].startsWith('B,"García, Ana",1,'), lines[1]);
        Assert.isTrue(lines[2].startsWith('A,"\'=HYPERLINK(""x"")",2,'), 'fórmula neutralizada: ' + lines[2]);
    }
}
