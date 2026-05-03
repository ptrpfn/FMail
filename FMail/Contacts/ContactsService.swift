import Contacts
import Foundation

struct ContactInfo: Sendable, Hashable, Identifiable {
    let id: String              // CNContact.identifier
    let displayName: String
    let emailAddresses: [String]
}

/// Wraps `CNContactStore`. On first use, requests permission. Builds a
/// case-insensitive map of email address → contact for fast lookup. Refreshes
/// when Contacts notifies us of changes.
actor ContactsService {
    enum Authorization {
        case notDetermined, authorized, denied, restricted

        init(_ raw: CNAuthorizationStatus) {
            switch raw {
            case .notDetermined: self = .notDetermined
            case .authorized: self = .authorized
            case .denied: self = .denied
            case .restricted: self = .restricted
            case .limited: self = .authorized
            @unknown default: self = .denied
            }
        }
    }

    private let store = CNContactStore()
    private var loaded = false
    private var addressToContactId: [String: String] = [:]
    private var contactsById: [String: ContactInfo] = [:]
    private var nameLowercaseIndex: [(String, String)] = []  // (lower-name, contactId)

    var authorization: Authorization {
        Authorization(CNContactStore.authorizationStatus(for: .contacts))
    }

    /// Request permission then load if granted. Idempotent.
    func ensureLoaded() async throws -> Authorization {
        let current = authorization
        if current == .denied || current == .restricted { return current }

        if current == .notDetermined {
            do {
                _ = try await store.requestAccess(for: .contacts)
            } catch {
                return Authorization(CNContactStore.authorizationStatus(for: .contacts))
            }
        }

        let after = authorization
        guard after == .authorized else { return after }
        if !loaded {
            try loadAll()
            loaded = true
        }
        return .authorized
    }

    func reload() throws {
        addressToContactId.removeAll()
        contactsById.removeAll()
        nameLowercaseIndex.removeAll()
        try loadAll()
    }

    /// Fetch every contact and build the indices. Called once on first
    /// authorisation; cheap on second access (returns cached state).
    private func loadAll() throws {
        let keys: [CNKeyDescriptor] = [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)
        try store.enumerateContacts(with: request) { contact, _ in
            let display = Self.displayName(from: contact)
            let emails = contact.emailAddresses.map { ($0.value as String).lowercased() }
            guard !emails.isEmpty else { return }
            let info = ContactInfo(id: contact.identifier, displayName: display, emailAddresses: emails)
            self.contactsById[contact.identifier] = info
            for e in emails {
                self.addressToContactId[e] = contact.identifier
            }
            self.nameLowercaseIndex.append((display.lowercased(), contact.identifier))
        }
    }

    func contact(forAddress address: String) -> ContactInfo? {
        guard let id = addressToContactId[address.lowercased()] else { return nil }
        return contactsById[id]
    }

    func contact(byId id: String) -> ContactInfo? {
        contactsById[id]
    }

    /// Case-insensitive prefix-match on contact name.
    func contacts(matching prefix: String, limit: Int = 8) -> [ContactInfo] {
        let needle = prefix.lowercased()
        guard !needle.isEmpty else { return [] }
        var seen = Set<String>()
        var out: [ContactInfo] = []
        for (lower, id) in nameLowercaseIndex {
            if lower.contains(needle), !seen.contains(id) {
                if let c = contactsById[id] {
                    out.append(c)
                    seen.insert(id)
                    if out.count >= limit { break }
                }
            }
        }
        return out
    }

    private static func displayName(from c: CNContact) -> String {
        let parts = [c.givenName, c.familyName].filter { !$0.isEmpty }
        if !parts.isEmpty { return parts.joined(separator: " ") }
        if !c.organizationName.isEmpty { return c.organizationName }
        return c.emailAddresses.first.map { String($0.value) } ?? "(unnamed)"
    }
}
