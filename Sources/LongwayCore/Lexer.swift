import Foundation

enum TokenKind: Equatable {
    case leftParen
    case rightParen
    case symbol(String)
    case string(String)
    case number(Double)
    case boolean(Bool)
    case eof
}

struct Token: Equatable {
    let kind: TokenKind
    let location: SourceLocation
}

struct Lexer {
    private let characters: [Character]
    private var index = 0
    private var line = 1
    private var column = 1

    init(source: String) {
        characters = Array(source)
    }

    mutating func tokenize() throws -> [Token] {
        var tokens: [Token] = []

        while true {
            skipTrivia()
            let location = currentLocation

            guard let character = peek() else {
                tokens.append(Token(kind: .eof, location: location))
                return tokens
            }

            switch character {
            case "(":
                advance()
                tokens.append(Token(kind: .leftParen, location: location))
            case ")":
                advance()
                tokens.append(Token(kind: .rightParen, location: location))
            case "\"":
                tokens.append(Token(kind: .string(try scanString(start: location)), location: location))
            default:
                let atom = scanAtom()
                if atom == "#t" {
                    tokens.append(Token(kind: .boolean(true), location: location))
                } else if atom == "#f" {
                    tokens.append(Token(kind: .boolean(false), location: location))
                } else if let number = Double(atom), atom.contains(where: { $0.isNumber }) {
                    tokens.append(Token(kind: .number(number), location: location))
                } else {
                    tokens.append(Token(kind: .symbol(atom), location: location))
                }
            }
        }
    }

    private var currentLocation: SourceLocation {
        SourceLocation(line: line, column: column)
    }

    private func peek() -> Character? {
        index < characters.count ? characters[index] : nil
    }

    private mutating func advance() {
        guard let character = peek() else { return }
        index += 1
        if character == "\n" {
            line += 1
            column = 1
        } else {
            column += 1
        }
    }

    private mutating func skipTrivia() {
        while let character = peek() {
            if character.isWhitespace {
                advance()
            } else if character == ";" {
                while let commentCharacter = peek(), commentCharacter != "\n" {
                    advance()
                }
            } else {
                return
            }
        }
    }

    private mutating func scanAtom() -> String {
        var value = ""
        while let character = peek(), !character.isWhitespace, character != "(", character != ")", character != ";" {
            value.append(character)
            advance()
        }
        return value
    }

    private mutating func scanString(start: SourceLocation) throws -> String {
        advance()
        var value = ""

        while let character = peek() {
            if character == "\"" {
                advance()
                return value
            }

            if character == "\\" {
                let escapeLocation = currentLocation
                advance()
                guard let escaped = peek() else {
                    throw LongwayError("unterminated escape sequence", at: escapeLocation)
                }
                switch escaped {
                case "n": value.append("\n")
                case "r": value.append("\r")
                case "t": value.append("\t")
                case "\"": value.append("\"")
                case "\\": value.append("\\")
                default:
                    throw LongwayError("unsupported escape sequence \\\(escaped)", at: escapeLocation)
                }
                advance()
            } else {
                value.append(character)
                advance()
            }
        }

        throw LongwayError("unterminated string", at: start)
    }
}
