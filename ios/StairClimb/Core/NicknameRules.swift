import Foundation

enum NicknameRules {
    enum ValidationError: LocalizedError {
        case invalid
        var errorDescription: String? { "昵称需为1至24个可见字符，内部仅可使用普通空格。" }
    }

    static func validate(_ input: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...24).contains(value.unicodeScalars.count) else { throw ValidationError.invalid }
        for scalar in value.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .surrogate, .privateUse, .unassigned, .lineSeparator, .paragraphSeparator:
                throw ValidationError.invalid
            case .spaceSeparator where scalar != " ":
                throw ValidationError.invalid
            default: break
            }
        }
        return value
    }
}
