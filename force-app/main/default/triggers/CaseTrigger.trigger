trigger CaseTrigger on Case(before insert, before update, after insert) {
    if (Trigger.isBefore) {
        CaseRoutingHandler.beforeInsertOrUpdate(Trigger.new);
    } else if (Trigger.isAfter && Trigger.isInsert) {
        CaseRoutingHandler.afterInsert(Trigger.new);
    }
}
