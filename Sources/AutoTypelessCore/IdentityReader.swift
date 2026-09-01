import Foundation

public enum IdentityReader {
    public static func read(from appStorageURL: URL) throws -> AccountIdentity {
        guard FileManager.default.fileExists(atPath: appStorageURL.path) else {
            throw AutoTypelessError.missingRequiredFile(appStorageURL.path)
        }

        let data = try Data(contentsOf: appStorageURL)
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let userData = root["userData"] as? [String: Any]
        else {
            throw AutoTypelessError.malformedAppStorage
        }

        let userID = stringValue(userData["user_id"])
        let email = stringValue(userData["email"])
        let name = stringValue(userData["name"])

        guard let userID, !userID.isEmpty, let email, !email.isEmpty else {
            throw AutoTypelessError.missingIdentity
        }

        return AccountIdentity(userID: userID, email: email, displayName: name)
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let value = value as? String {
            return value
        }
        if let value = value as? NSNumber {
            return value.stringValue
        }
        return nil
    }
}
