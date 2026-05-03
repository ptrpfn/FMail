import Foundation

enum Token: Equatable {
    case word(String)              // bare word
    case quoted(String)            // "exact phrase"
    case field(String, String)     // field:value (value may itself be a quoted string, already unquoted)
    case lparen
    case rparen
    case minus                     // - shortcut for NOT applied to next atom
    case orOp                      // OR keyword
    case andOp                     // AND keyword (usually implicit; we keep it for explicit parsing)
    case notOp                     // NOT keyword
}
