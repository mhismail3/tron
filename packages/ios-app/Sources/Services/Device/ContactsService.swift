import Contacts
import Foundation

/// Handles contact search device requests using the Contacts framework.
///
/// Read-only: only searches by name, returns name, phones, emails, organization.
final class ContactsService: @unchecked Sendable {
    static let shared = ContactsService()

    private nonisolated(unsafe) let store = CNContactStore()

    private init() {}

    // MARK: - Request Routing

    func handle(action: String, params: [String: AnyCodable]?) async throws -> [String: AnyCodable] {
        try await requestAccess()

        switch action {
        case "search":
            return try search(params: params)
        default:
            throw DeviceRequestError.unknownMethod("contacts.\(action)")
        }
    }

    // MARK: - Authorization

    func requestPermission() async -> Bool {
        do {
            return try await store.requestAccess(for: .contacts)
        } catch {
            return false
        }
    }

    private func requestAccess() async throws {
        let granted = try await store.requestAccess(for: .contacts)
        guard granted else {
            throw DeviceRequestError.permissionDenied("Contacts access denied")
        }
    }

    // MARK: - Search

    private func search(params: [String: AnyCodable]?) throws -> [String: AnyCodable] {
        guard let query = params?["query"]?.value as? String, !query.isEmpty else {
            throw DeviceRequestError.unknownMethod("contacts.search: query required")
        }

        let limit = min((params?["limit"]?.value as? Int) ?? 10, 50)

        let keysToFetch: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
        ]

        let request = CNContactFetchRequest(keysToFetch: keysToFetch)
        request.predicate = CNContact.predicateForContacts(matchingName: query)

        var contacts: [[String: Any]] = []
        try store.enumerateContacts(with: request) { contact, stop in
            if contacts.count >= limit {
                stop.pointee = true
                return
            }

            let phones = contact.phoneNumbers.map { phone -> [String: String] in
                [
                    "label": CNLabeledValue<CNPhoneNumber>.localizedString(forLabel: phone.label ?? "other"),
                    "number": phone.value.stringValue
                ]
            }

            let emails = contact.emailAddresses.map { email -> [String: String] in
                [
                    "label": CNLabeledValue<NSString>.localizedString(forLabel: email.label ?? "other"),
                    "value": email.value as String
                ]
            }

            contacts.append([
                "id": contact.identifier,
                "givenName": contact.givenName,
                "familyName": contact.familyName,
                "organization": contact.organizationName,
                "phones": phones,
                "emails": emails
            ])
        }

        return ["contacts": AnyCodable(contacts)]
    }
}
