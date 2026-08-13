import CoreData

// The data model, built in code rather than in a .xcdatamodeld file.
//
// Why: Swift Playgrounds on iPad cannot compile a .xcdatamodeld — that needs
// Xcode's model compiler. Defining the model programmatically means ONE
// codebase that builds today on your iPad and later on your Mac, with no
// migration and no second version to keep in sync.
//
// Every attribute is optional or has a default, and every relationship has an
// inverse, because NSPersistentCloudKitContainer refuses to load otherwise.

enum LedgerModel {

    static func make() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()

        let card      = entity("CDCard")
        let expense   = entity("CDExpense")
        let statement = entity("CDStatement")
        let payment   = entity("CDPayment")
        let budget    = entity("CDBudgetLine")

        // MARK: Card
        card.properties = [
            attr("id", .UUIDAttributeType),
            attr("name", .stringAttributeType, def: ""),
            attr("issuer", .stringAttributeType, def: ""),
            attr("last4", .stringAttributeType, def: ""),
            // A funding source has more than one identifier. The debit card
            // prints 9636; the ACH/bill-pay confirmation for the same account
            // prints 6932. Matching on the card number alone silently misses
            // every autopay and bill-pay email.
            attr("accountLast4", .stringAttributeType, def: ""),
            attr("otherLast4", .stringAttributeType, def: ""),   // comma separated
            attr("aprBasisPoints", .integer32AttributeType, def: 0),
            attr("creditLimitCents", .integer64AttributeType, def: 0),
            attr("statementDay", .integer16AttributeType, def: 0),
            attr("dueDay", .integer16AttributeType, def: 0),
            attr("isClosed", .booleanAttributeType, def: false),
            attr("isCash", .booleanAttributeType, def: false),
            attr("sortIndex", .integer16AttributeType, def: 0),
            attr("colorHex", .stringAttributeType, def: "#8E8E93"),
            attr("notes", .stringAttributeType, def: ""),
            attr("secretRef", .stringAttributeType, def: ""),
            // Card details, optionally synced. CloudKit encrypts these fields
            // with a key held in your Keychain, so Apple cannot read them.
            encrypted("vaultBlob", .binaryDataAttributeType),
            // Signup bonus tracking: spend N by a deadline to earn the offer.
            attr("bonusTargetCents", .integer64AttributeType, def: 0),
            attr("bonusStartsOn", .dateAttributeType),
            attr("bonusEndsOn", .dateAttributeType),
            attr("bonusReward", .stringAttributeType, def: ""),
        ]

        // MARK: Expense
        expense.properties = [
            attr("id", .UUIDAttributeType),
            attr("date", .dateAttributeType),
            attr("amountCents", .integer64AttributeType, def: 0),
            attr("merchant", .stringAttributeType, def: ""),
            attr("merchantKey", .stringAttributeType, def: ""),
            attr("category", .stringAttributeType, def: "Uncategorized"),
            attr("payer", .stringAttributeType, def: "Us"),
            attr("notes", .stringAttributeType, def: ""),
            attr("cycleKey", .stringAttributeType, def: ""),
            attr("source", .stringAttributeType, def: "manual"),
            attr("isRecurring", .booleanAttributeType, def: false),
            attr("needsReview", .booleanAttributeType, def: false),
            attr("createdAt", .dateAttributeType),
            attr("updatedAt", .dateAttributeType),
            // Links an expense back to the recurring rule that created it, so
            // "what have I paid CoServ each month" is an exact query rather
            // than a fuzzy merchant-name match.
            attr("ruleID", .UUIDAttributeType),
            attr("isEstimated", .booleanAttributeType, def: false),
            // Duplicate prevention. dupeHash identifies the purchase;
            // sourceHash identifies the SMS or receipt it came from.
            attr("dupeHash", .stringAttributeType, def: ""),
            attr("sourceHash", .stringAttributeType, def: ""),
            attr("possibleDuplicateOf", .UUIDAttributeType),
        ]

        // MARK: Statement
        statement.properties = [
            attr("id", .UUIDAttributeType),
            attr("cycleKey", .stringAttributeType, def: ""),
            attr("openedOn", .dateAttributeType),
            attr("closedOn", .dateAttributeType),
            attr("dueOn", .dateAttributeType),
            attr("previousBalanceCents", .integer64AttributeType, def: 0),
            attr("statedClosingCents", .integer64AttributeType, def: 0),
            attr("interestCents", .integer64AttributeType, def: 0),
            attr("feesCents", .integer64AttributeType, def: 0),
            attr("notes", .stringAttributeType, def: ""),
            attr("updatedAt", .dateAttributeType),
            // Set when a CloudKit-driven remote change lands on a statement
            // that also has an unsaved local edit in flight — a genuine
            // two-device collision. See ConflictWatcher.swift.
            attr("needsReview", .booleanAttributeType, def: false),
        ]

        // MARK: Payment
        payment.properties = [
            attr("id", .UUIDAttributeType),
            attr("amountCents", .integer64AttributeType, def: 0),
            attr("paidOn", .dateAttributeType),
            attr("note", .stringAttributeType, def: ""),
        ]

        // MARK: Budget line
        budget.properties = [
            attr("id", .UUIDAttributeType),
            attr("name", .stringAttributeType, def: ""),
            attr("plannedCents", .integer64AttributeType, def: 0),
            attr("category", .stringAttributeType, def: "Others"),
            attr("isIncome", .booleanAttributeType, def: false),
            attr("notes", .stringAttributeType, def: ""),
        ]

        // MARK: Relationships (each side declared, then paired as inverses)
        let cardExpenses  = toMany("expenses", card, expense, rule: .nullifyDeleteRule)
        let expenseCard   = toOne("card", expense, card, rule: .nullifyDeleteRule)
        pair(cardExpenses, expenseCard)

        let cardStatements   = toMany("statements", card, statement, rule: .cascadeDeleteRule)
        let statementCard    = toOne("card", statement, card, rule: .nullifyDeleteRule)
        pair(cardStatements, statementCard)

        let statementPayments = toMany("payments", statement, payment, rule: .cascadeDeleteRule)
        let paymentStatement  = toOne("statement", payment, statement, rule: .nullifyDeleteRule)
        pair(statementPayments, paymentStatement)

        card.properties.append(contentsOf: [cardExpenses, cardStatements])
        expense.properties.append(expenseCard)
        statement.properties.append(contentsOf: [statementCard, statementPayments])
        payment.properties.append(paymentStatement)

        model.entities = [card, expense, statement, payment, budget]
        return model
    }

    // MARK: - builders

    private static func entity(_ name: String) -> NSEntityDescription {
        let e = NSEntityDescription()
        e.name = name
        e.managedObjectClassName = name
        return e
    }

    private static func attr(_ name: String,
                             _ type: NSAttributeType,
                             def: Any? = nil) -> NSAttributeDescription {
        let a = NSAttributeDescription()
        a.name = name
        a.attributeType = type
        a.isOptional = true          // CloudKit requires optional or defaulted
        a.defaultValue = def
        return a
    }

    /// Field-level encryption: CloudKit stores the ciphertext and holds no key.
    private static func encrypted(_ name: String,
                                  _ type: NSAttributeType) -> NSAttributeDescription {
        let a = attr(name, type)
        a.allowsCloudEncryption = true
        return a
    }

    private static func toMany(_ name: String,
                               _ from: NSEntityDescription,
                               _ to: NSEntityDescription,
                               rule: NSDeleteRule) -> NSRelationshipDescription {
        let r = NSRelationshipDescription()
        r.name = name
        r.destinationEntity = to
        r.minCount = 0
        r.maxCount = 0               // 0 == to-many
        r.deleteRule = rule
        r.isOptional = true
        return r
    }

    private static func toOne(_ name: String,
                              _ from: NSEntityDescription,
                              _ to: NSEntityDescription,
                              rule: NSDeleteRule) -> NSRelationshipDescription {
        let r = NSRelationshipDescription()
        r.name = name
        r.destinationEntity = to
        r.minCount = 0
        r.maxCount = 1
        r.deleteRule = rule
        r.isOptional = true
        return r
    }

    private static func pair(_ a: NSRelationshipDescription,
                             _ b: NSRelationshipDescription) {
        a.inverseRelationship = b
        b.inverseRelationship = a
    }
}

// MARK: - Managed object subclasses
//
// Written by hand because there's no .xcdatamodeld to generate them from.
// @NSManaged maps each property straight onto the model above.

@objc(CDCard)
final class CDCard: NSManagedObject {
    @NSManaged var id: UUID?
    @NSManaged var name: String?
    @NSManaged var issuer: String?
    @NSManaged var last4: String?
    @NSManaged var accountLast4: String?
    @NSManaged var otherLast4: String?
    @NSManaged var aprBasisPoints: Int32
    @NSManaged var creditLimitCents: Int64
    @NSManaged var statementDay: Int16
    @NSManaged var dueDay: Int16
    @NSManaged var isClosed: Bool
    @NSManaged var isCash: Bool
    @NSManaged var sortIndex: Int16
    @NSManaged var colorHex: String?
    @NSManaged var notes: String?
    @NSManaged var secretRef: String?
    @NSManaged var vaultBlob: Data?
    @NSManaged var bonusTargetCents: Int64
    @NSManaged var bonusStartsOn: Date?
    @NSManaged var bonusEndsOn: Date?
    @NSManaged var bonusReward: String?
    @NSManaged var expenses: NSSet?
    @NSManaged var statements: NSSet?
}

extension CDCard {
    /// Every four-digit identifier that can appear on a receipt, statement or
    /// payment confirmation for this funding source.
    var allIdentifiers: [String] {
        var out: [String] = []
        for field in [last4, accountLast4] {
            let d = (field ?? "").filter(\.isNumber)
            if d.count >= 4 { out.append(String(d.suffix(4))) }
        }
        for part in (otherLast4 ?? "").split(separator: ",") {
            let d = part.filter(\.isNumber)
            if d.count >= 4 { out.append(String(d.suffix(4))) }
        }
        return out
    }
}

@objc(CDExpense)
final class CDExpense: NSManagedObject {
    @NSManaged var id: UUID?
    @NSManaged var date: Date?
    @NSManaged var amountCents: Int64
    @NSManaged var merchant: String?
    @NSManaged var merchantKey: String?
    @NSManaged var category: String?
    @NSManaged var payer: String?
    @NSManaged var notes: String?
    @NSManaged var cycleKey: String?
    @NSManaged var source: String?
    @NSManaged var isRecurring: Bool
    @NSManaged var needsReview: Bool
    @NSManaged var createdAt: Date?
    @NSManaged var updatedAt: Date?
    @NSManaged var ruleID: UUID?
    @NSManaged var isEstimated: Bool
    @NSManaged var dupeHash: String?
    @NSManaged var sourceHash: String?
    @NSManaged var possibleDuplicateOf: UUID?
    @NSManaged var card: CDCard?
}

@objc(CDStatement)
final class CDStatement: NSManagedObject {
    @NSManaged var id: UUID?
    @NSManaged var cycleKey: String?
    @NSManaged var openedOn: Date?
    @NSManaged var closedOn: Date?
    @NSManaged var dueOn: Date?
    @NSManaged var previousBalanceCents: Int64
    @NSManaged var statedClosingCents: Int64
    @NSManaged var interestCents: Int64
    @NSManaged var feesCents: Int64
    @NSManaged var notes: String?
    @NSManaged var updatedAt: Date?
    @NSManaged var needsReview: Bool
    @NSManaged var card: CDCard?
    @NSManaged var payments: NSSet?
}

@objc(CDPayment)
final class CDPayment: NSManagedObject {
    @NSManaged var id: UUID?
    @NSManaged var amountCents: Int64
    @NSManaged var paidOn: Date?
    @NSManaged var note: String?
    @NSManaged var statement: CDStatement?
}

@objc(CDBudgetLine)
final class CDBudgetLine: NSManagedObject {
    @NSManaged var id: UUID?
    @NSManaged var name: String?
    @NSManaged var plannedCents: Int64
    @NSManaged var category: String?
    @NSManaged var isIncome: Bool
    @NSManaged var notes: String?
}
