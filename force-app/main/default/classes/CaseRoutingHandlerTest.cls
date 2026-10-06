@IsTest
private class CaseRoutingHandlerTest {
    private static Case_Routing_Rule__mdt rule(String subfamily, String queue) {
        return (Case_Routing_Rule__mdt) JSON.deserialize(
            JSON.serialize(
                new Map<String, Object>{
                    'Product_Subfamily__c' => subfamily,
                    'Queue_Developer_Name__c' => queue,
                    'Active__c' => true
                }
            ),
            Case_Routing_Rule__mdt.class
        );
    }

    @TestSetup
    static void setup() {
        // Colas en un contexto de usuario aparte para evitar MIXED_DML
        System.runAs(new User(Id = UserInfo.getUserId())) {
            List<Group> queues = new List<Group>{
                new Group(Name = 'Urgent', DeveloperName = CaseRoutingHandler.genericQueueName(), Type = 'Queue'),
                new Group(Name = 'Museum', DeveloperName = 'Urgent_Museum', Type = 'Queue'),
                new Group(Name = 'Cathedral', DeveloperName = 'Urgent_Cathedral', Type = 'Queue')
            };
            insert queues;
            List<QueueSobject> objs = new List<QueueSobject>();
            for (Group g : queues) {
                objs.add(new QueueSobject(QueueId = g.Id, SobjectType = 'Case'));
            }
            insert objs;
        }

        Product2 museum = new Product2(Name = 'Museum ticket');
        insert museum;
        insert new List<Booking__c>{
            new Booking__c(
                Contact_Email__c = 'ana@example.com',
                Product_Subfamily__c = 'Museum',
                Product__c = museum.Id
            ),
            new Booking__c(Contact_Email__c = 'luis@example.com', Product_Subfamily__c = 'Cathedral'),
            new Booking__c(Contact_Email__c = 'eva@example.com', Product_Subfamily__c = 'Sin regla')
        };
    }

    private static Map<String, Id> queues() {
        Map<String, Id> ids = new Map<String, Id>();
        for (Group g : [SELECT Id, DeveloperName FROM Group WHERE Type = 'Queue']) {
            ids.put(g.DeveloperName, g.Id);
        }
        return ids;
    }

    @IsTest
    static void routesBulkCasesByCustomerProduct() {
        CaseRoutingHandler.rulesOverride = new List<Case_Routing_Rule__mdt>{
            rule('Museum', 'Urgent_Museum'),
            rule('Cathedral', 'Urgent_Cathedral')
        };
        Map<String, Id> q = queues();
        Id generic = q.get(CaseRoutingHandler.genericQueueName());

        List<Case> cases = new List<Case>();
        for (Integer i = 0; i < 100; i++) {
            cases.add(
                new Case(
                    Subject = 'Incidencia ' + i,
                    OwnerId = generic,
                    SuppliedEmail = Math.mod(i, 2) == 0 ? 'ANA@example.com' : 'luis@example.com'
                )
            );
        }
        cases.add(new Case(Subject = 'Sin regla', OwnerId = generic, SuppliedEmail = 'eva@example.com'));
        cases.add(new Case(Subject = 'Sin reserva', OwnerId = generic, SuppliedEmail = 'nadie@example.com'));

        Test.startTest();
        insert cases;
        Integer queries = Limits.getQueries();
        Test.stopTest();

        Map<Id, Integer> byOwner = new Map<Id, Integer>();
        for (Case c : [SELECT OwnerId FROM Case]) {
            byOwner.put(c.OwnerId, (byOwner.containsKey(c.OwnerId) ? byOwner.get(c.OwnerId) : 0) + 1);
        }
        Assert.areEqual(50, byOwner.get(q.get('Urgent_Museum')), 'el email se compara sin mayúsculas');
        Assert.areEqual(50, byOwner.get(q.get('Urgent_Cathedral')));
        Assert.areEqual(2, byOwner.get(generic), 'sin regla o sin reserva se quedan en la cola genérica');
        Assert.isTrue(queries <= 3, 'bulkificado: consultas constantes para 102 casos, usadas: ' + queries);
    }

    @IsTest
    static void reviewCaseCreatesReview() {
        Booking__c booking = [SELECT Id, Name, Product__c FROM Booking__c WHERE Contact_Email__c = 'ana@example.com'];

        Test.startTest();
        Case c = new Case(
            Subject = booking.Name,
            Is_Review__c = true,
            Description = 'Genial',
            Guide_Score__c = 5,
            Activity_Score__c = 4
        );
        insert c;
        Test.stopTest();

        Review__c review = [
            SELECT Booking__c, Product__c, Case__c, Comment__c, Guide_Score__c, Published__c
            FROM Review__c
        ];
        Assert.areEqual(booking.Id, review.Booking__c);
        Assert.areEqual(booking.Product__c, review.Product__c);
        Assert.areEqual(c.Id, review.Case__c);
        Assert.areEqual('Genial', review.Comment__c);
        Assert.areEqual(5, review.Guide_Score__c.intValue());
        Assert.isFalse(review.Published__c);
        Assert.areEqual(booking.Id, [SELECT Booking__c FROM Case WHERE Id = :c.Id].Booking__c);
    }

    @IsTest
    static void nonReviewCasesCreateNothing() {
        Booking__c booking = [SELECT Name FROM Booking__c LIMIT 1];
        insert new Case(Subject = booking.Name, Is_Review__c = false);
        Assert.areEqual(0, [SELECT COUNT() FROM Review__c]);
    }
}
