import AppKit
import Foundation

extension MarkdownLiveStyler {

    // MARK: - Language-Aware Code Fence Syntax Highlighter

    static let sharedStringsRegex = try! NSRegularExpression(pattern: #""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`"#)
    static let sharedNumbersRegex = try! NSRegularExpression(pattern: #"\b(?:0x[0-9a-fA-F]+|\d+(?:\.\d+)?)\b"#)
    static let sharedFunctionsRegex = try! NSRegularExpression(pattern: #"\b([a-zA-Z_][a-zA-Z0-9_]*)\s*(?=\()"#)

    static func syntaxProfile(for rawLanguage: String) -> LanguageSyntaxProfile? {
        let lang = rawLanguage.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lang.isEmpty else { return nil }

        switch lang {
        case "swift":
            return LanguageSyntaxProfile(
                keywords: try? NSRegularExpression(pattern: #"\b(func|let|var|struct|class|enum|protocol|extension|import|return|if|else|switch|case|default|for|while|in|guard|try|catch|throw|throws|async|await|public|private|internal|fileprivate|open|static|final|override|mutating|init|deinit|self|super|true|false|nil|where|some|any|typealias|inout|defer|repeat)\b"#),
                typesAndBuiltins: try? NSRegularExpression(pattern: #"\b([A-Z][a-zA-Z0-9_]*)\b"#),
                attributesOrMacros: try? NSRegularExpression(pattern: #"@[a-zA-Z_][a-zA-Z0-9_]*|#[a-zA-Z_][a-zA-Z0-9_]*"#),
                comments: try? NSRegularExpression(pattern: #"//.*$|/\*.*?\*/"#),
                strings: sharedStringsRegex,
                numbers: sharedNumbersRegex,
                functions: sharedFunctionsRegex,
                keywordColorLight: NSColor(srgbRed: 0.68, green: 0.09, blue: 0.54, alpha: 1.0),
                keywordColorDark: NSColor(srgbRed: 0.99, green: 0.37, blue: 0.64, alpha: 1.0)
            )

        case "python", "py":
            return LanguageSyntaxProfile(
                keywords: try? NSRegularExpression(pattern: #"\b(def|class|return|if|elif|else|for|while|in|import|from|as|with|try|except|finally|raise|pass|break|continue|lambda|yield|async|await|global|nonlocal|assert|del|is|not|and|or|True|False|None|self|cls)\b"#),
                typesAndBuiltins: try? NSRegularExpression(pattern: #"\b(int|str|float|bool|list|dict|set|tuple|bytes|object|type|print|len|range|enumerate|zip|map|filter|sorted|super|isinstance|getattr|setattr|open)\b"#),
                attributesOrMacros: try? NSRegularExpression(pattern: #"@[a-zA-Z_][a-zA-Z0-9_\.]*"#),
                comments: try? NSRegularExpression(pattern: #"#.*$"#),
                strings: sharedStringsRegex,
                numbers: sharedNumbersRegex,
                functions: sharedFunctionsRegex,
                keywordColorLight: NSColor(srgbRed: 0.05, green: 0.38, blue: 0.68, alpha: 1.0),
                keywordColorDark: NSColor(srgbRed: 0.38, green: 0.72, blue: 0.98, alpha: 1.0)
            )

        case "javascript", "js", "jsx", "typescript", "ts", "tsx":
            return LanguageSyntaxProfile(
                keywords: try? NSRegularExpression(pattern: #"\b(const|let|var|function|return|if|else|switch|case|default|for|while|do|of|in|import|export|from|default|class|extends|new|this|super|try|catch|finally|throw|async|await|typeof|instanceof|void|delete|yield|interface|type|implements|readonly|public|private|protected|true|false|null|undefined)\b"#),
                typesAndBuiltins: try? NSRegularExpression(pattern: #"\b(Promise|Array|Object|String|Number|Boolean|Map|Set|WeakMap|WeakSet|Date|RegExp|Error|Math|JSON|console|window|document|globalThis|number|string|boolean|any|unknown|never|Record|Partial)\b"#),
                attributesOrMacros: try? NSRegularExpression(pattern: #"@[a-zA-Z_][a-zA-Z0-9_]*"#),
                comments: try? NSRegularExpression(pattern: #"//.*$|/\*.*?\*/"#),
                strings: sharedStringsRegex,
                numbers: sharedNumbersRegex,
                functions: sharedFunctionsRegex,
                keywordColorLight: NSColor(srgbRed: 0.56, green: 0.24, blue: 0.78, alpha: 1.0),
                keywordColorDark: NSColor(srgbRed: 0.78, green: 0.56, blue: 0.98, alpha: 1.0)
            )

        case "rust", "rs":
            return LanguageSyntaxProfile(
                keywords: try? NSRegularExpression(pattern: #"\b(fn|let|mut|const|static|struct|enum|trait|impl|pub|crate|mod|use|as|where|for|in|while|loop|if|else|match|return|break|continue|async|await|move|ref|type|unsafe|extern|dyn|self|Self|super|true|false)\b"#),
                typesAndBuiltins: try? NSRegularExpression(pattern: #"\b(u8|u16|u32|u64|u128|usize|i8|i16|i32|i64|i128|isize|f32|f64|bool|char|str|String|Vec|Option|Result|Some|None|Ok|Err|Box|Rc|Arc|Cow|HashMap|HashSet)\b"#),
                attributesOrMacros: try? NSRegularExpression(pattern: #"#!?\[[^\]]*\]|\b[a-zA-Z_][a-zA-Z0-9_]*!"#),
                comments: try? NSRegularExpression(pattern: #"//.*$|/\*.*?\*/"#),
                strings: sharedStringsRegex,
                numbers: sharedNumbersRegex,
                functions: sharedFunctionsRegex,
                keywordColorLight: NSColor(srgbRed: 0.75, green: 0.28, blue: 0.08, alpha: 1.0),
                keywordColorDark: NSColor(srgbRed: 0.96, green: 0.58, blue: 0.34, alpha: 1.0)
            )

        case "go", "golang":
            return LanguageSyntaxProfile(
                keywords: try? NSRegularExpression(pattern: #"\b(func|package|import|var|const|type|struct|interface|map|chan|go|defer|return|if|else|switch|case|default|select|for|range|break|continue|fallthrough|goto|true|false|nil|iota)\b"#),
                typesAndBuiltins: try? NSRegularExpression(pattern: #"\b(int|int8|int16|int32|int64|uint|uint8|uint16|uint32|uint64|uintptr|float32|float64|complex64|complex128|byte|rune|string|bool|error|any|make|len|cap|new|append|copy|close|delete|panic|recover|print|println)\b"#),
                attributesOrMacros: nil,
                comments: try? NSRegularExpression(pattern: #"//.*$|/\*.*?\*/"#),
                strings: sharedStringsRegex,
                numbers: sharedNumbersRegex,
                functions: sharedFunctionsRegex,
                keywordColorLight: NSColor(srgbRed: 0.0, green: 0.48, blue: 0.62, alpha: 1.0),
                keywordColorDark: NSColor(srgbRed: 0.28, green: 0.82, blue: 0.92, alpha: 1.0)
            )

        case "c", "cpp", "c++", "h", "hpp", "objc", "objective-c":
            return LanguageSyntaxProfile(
                keywords: try? NSRegularExpression(pattern: #"\b(if|else|switch|case|default|for|while|do|return|break|continue|goto|struct|class|union|enum|typedef|using|namespace|template|typename|public|private|protected|virtual|override|final|static|extern|const|constexpr|volatile|inline|sizeof|new|delete|try|catch|throw|nullptr|NULL|true|false)\b"#),
                typesAndBuiltins: try? NSRegularExpression(pattern: #"\b(void|int|long|short|char|float|double|bool|unsigned|signed|size_t|uint8_t|uint16_t|uint32_t|uint64_t|int32_t|int64_t|std|string|vector|map|set|shared_ptr|unique_ptr)\b"#),
                attributesOrMacros: try? NSRegularExpression(pattern: #"^\s*#\s*[a-zA-Z_]+"#),
                comments: try? NSRegularExpression(pattern: #"//.*$|/\*.*?\*/"#),
                strings: sharedStringsRegex,
                numbers: sharedNumbersRegex,
                functions: sharedFunctionsRegex,
                keywordColorLight: NSColor(srgbRed: 0.58, green: 0.12, blue: 0.45, alpha: 1.0),
                keywordColorDark: NSColor(srgbRed: 0.88, green: 0.48, blue: 0.75, alpha: 1.0)
            )

        case "json", "jsonc", "yaml", "yml", "toml":
            return LanguageSyntaxProfile(
                keywords: try? NSRegularExpression(pattern: #"\b(true|false|null|yes|no|on|off)\b"#),
                typesAndBuiltins: nil,
                attributesOrMacros: try? NSRegularExpression(pattern: #""[^"\n]*"\s*(?=:)|^\s*[a-zA-Z0-9_-]+\s*(?=:)"#),
                comments: lang == "json" ? nil : (try? NSRegularExpression(pattern: #"#.*$|//.*$"#)),
                strings: sharedStringsRegex,
                numbers: sharedNumbersRegex,
                functions: sharedFunctionsRegex,
                keywordColorLight: NSColor(srgbRed: 0.12, green: 0.48, blue: 0.34, alpha: 1.0),
                keywordColorDark: NSColor(srgbRed: 0.42, green: 0.85, blue: 0.65, alpha: 1.0)
            )

        case "bash", "sh", "zsh", "shell":
            return LanguageSyntaxProfile(
                keywords: try? NSRegularExpression(pattern: #"\b(if|then|else|elif|fi|for|while|until|do|done|in|case|esac|function|return|exit|export|local|readonly|set|unset|shift|source)\b"#),
                typesAndBuiltins: try? NSRegularExpression(pattern: #"\b(echo|printf|cd|pwd|ls|cp|mv|rm|mkdir|cat|grep|sed|awk|find|xargs|curl|git|swift|npm|npx|python3|brew|chmod|chown)\b"#),
                attributesOrMacros: try? NSRegularExpression(pattern: #"\$[a-zA-Z0-9_@*#?-]+|\$\{[^\}]+\}"#),
                comments: try? NSRegularExpression(pattern: #"#.*$"#),
                strings: sharedStringsRegex,
                numbers: sharedNumbersRegex,
                functions: sharedFunctionsRegex,
                keywordColorLight: NSColor(srgbRed: 0.16, green: 0.46, blue: 0.22, alpha: 1.0),
                keywordColorDark: NSColor(srgbRed: 0.48, green: 0.86, blue: 0.54, alpha: 1.0)
            )

        case "html", "xml", "svg", "css", "scss":
            return LanguageSyntaxProfile(
                keywords: try? NSRegularExpression(pattern: #"</?[a-zA-Z0-9_-]+|/?>|@[a-zA-Z_-]+"#),
                typesAndBuiltins: try? NSRegularExpression(pattern: #"\b[a-zA-Z-]+(?=\s*=|\s*:)"#),
                attributesOrMacros: try? NSRegularExpression(pattern: #"#[0-9a-fA-F]{3,8}\b|\.[a-zA-Z_-][a-zA-Z0-9_-]*"#),
                comments: try? NSRegularExpression(pattern: #"<!--.*?-->|/\*.*?\*/"#),
                strings: sharedStringsRegex,
                numbers: sharedNumbersRegex,
                functions: sharedFunctionsRegex,
                keywordColorLight: NSColor(srgbRed: 0.72, green: 0.14, blue: 0.26, alpha: 1.0),
                keywordColorDark: NSColor(srgbRed: 0.95, green: 0.45, blue: 0.55, alpha: 1.0)
            )

        case "mermaid", "mmd":
            return LanguageSyntaxProfile(
                keywords: try? NSRegularExpression(pattern: #"\b(flowchart|graph|sequenceDiagram|classDiagram|stateDiagram|stateDiagram-v2|pie|erDiagram|subgraph|end|participant|actor|class|title|direction|TD|TB|LR|RL|BT|showData)\b"#),
                typesAndBuiltins: try? NSRegularExpression(pattern: #"-->|-\.->|==>|-->>|->>|--|==|\[\*\]"#),
                attributesOrMacros: try? NSRegularExpression(pattern: #"\|[^\|]+\|"#),
                comments: try? NSRegularExpression(pattern: #"%%.*$"#),
                strings: sharedStringsRegex,
                numbers: sharedNumbersRegex,
                functions: sharedFunctionsRegex,
                keywordColorLight: NSColor(srgbRed: 0.45, green: 0.18, blue: 0.72, alpha: 1.0),
                keywordColorDark: NSColor(srgbRed: 0.76, green: 0.52, blue: 0.98, alpha: 1.0)
            )

        case "sql":
            return LanguageSyntaxProfile(
                keywords: try? NSRegularExpression(pattern: #"(?i)\b(SELECT|FROM|WHERE|INSERT|INTO|VALUES|UPDATE|SET|DELETE|CREATE|TABLE|DROP|ALTER|INDEX|VIEW|JOIN|INNER|LEFT|RIGHT|FULL|ON|AS|AND|OR|NOT|NULL|IS|IN|EXISTS|BETWEEN|LIKE|ORDER|BY|GROUP|HAVING|LIMIT|OFFSET|UNION|ALL|DISTINCT|PRIMARY|KEY|FOREIGN|REFERENCES|DEFAULT|BEGIN|COMMIT|ROLLBACK)\b"#),
                typesAndBuiltins: try? NSRegularExpression(pattern: #"(?i)\b(INT|INTEGER|BIGINT|TEXT|VARCHAR|BOOLEAN|DATE|TIMESTAMP|FLOAT|DOUBLE|DECIMAL|UUID|JSONB|COUNT|SUM|AVG|MIN|MAX|COALESCE|NOW)\b"#),
                attributesOrMacros: nil,
                comments: try? NSRegularExpression(pattern: #"--.*$|/\*.*?\*/"#),
                strings: sharedStringsRegex,
                numbers: sharedNumbersRegex,
                functions: sharedFunctionsRegex,
                keywordColorLight: NSColor(srgbRed: 0.10, green: 0.36, blue: 0.72, alpha: 1.0),
                keywordColorDark: NSColor(srgbRed: 0.44, green: 0.72, blue: 0.98, alpha: 1.0)
            )

        default:
            // Unknown/custom language tag: provide lightweight generic highlighting
            return LanguageSyntaxProfile(
                keywords: try? NSRegularExpression(pattern: #"\b(if|else|for|while|return|function|class|import|true|false|null)\b"#),
                typesAndBuiltins: nil,
                attributesOrMacros: nil,
                comments: try? NSRegularExpression(pattern: #"//.*$|#.*$"#),
                strings: sharedStringsRegex,
                numbers: sharedNumbersRegex,
                functions: sharedFunctionsRegex,
                keywordColorLight: NSColor(srgbRed: 0.45, green: 0.25, blue: 0.65, alpha: 1.0),
                keywordColorDark: NSColor(srgbRed: 0.72, green: 0.55, blue: 0.88, alpha: 1.0)
            )
        }
    }

    static func highlightCodeLine(
        in storage: NSTextStorage,
        range: NSRange,
        language: String,
        theme: EditorTheme,
        dimFactor: CGFloat
    ) {
        guard range.length > 0, let profile = syntaxProfile(for: language) else { return }
        let string = storage.string

        let keywordColor = (theme.isDark ? profile.keywordColorDark : profile.keywordColorLight).withAlphaComponent(dimFactor)
        let typeColor = (theme.isDark
            ? NSColor(srgbRed: 0.38, green: 0.84, blue: 0.78, alpha: dimFactor)
            : NSColor(srgbRed: 0.04, green: 0.45, blue: 0.48, alpha: dimFactor))
        let functionColor = (theme.isDark
            ? NSColor(srgbRed: 0.45, green: 0.72, blue: 0.96, alpha: dimFactor)
            : NSColor(srgbRed: 0.14, green: 0.36, blue: 0.74, alpha: dimFactor))
        let numberColor = (theme.isDark
            ? NSColor(srgbRed: 0.88, green: 0.68, blue: 0.38, alpha: dimFactor)
            : NSColor(srgbRed: 0.68, green: 0.36, blue: 0.04, alpha: dimFactor))
        let attrColor = (theme.isDark
            ? NSColor(srgbRed: 0.94, green: 0.62, blue: 0.42, alpha: dimFactor)
            : NSColor(srgbRed: 0.64, green: 0.28, blue: 0.12, alpha: dimFactor))
        let stringColor = (theme.isDark
            ? NSColor(srgbRed: 0.60, green: 0.82, blue: 0.50, alpha: dimFactor)
            : NSColor(srgbRed: 0.12, green: 0.46, blue: 0.18, alpha: dimFactor))
        let commentColor = theme.secondaryTextNSColor.withAlphaComponent(0.72 * dimFactor)

        // 1. Numbers
        profile.numbers.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            if let r = match?.range {
                storage.addAttribute(.foregroundColor, value: numberColor, range: r)
            }
        }

        // 2. Function calls/names
        profile.functions.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            if let r = match?.range(at: 1) {
                storage.addAttribute(.foregroundColor, value: functionColor, range: r)
            }
        }

        // 3. Types & Builtins
        profile.typesAndBuiltins?.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            if let r = match?.range {
                storage.addAttribute(.foregroundColor, value: typeColor, range: r)
            }
        }

        // 4. Keywords (override function/type matches if a keyword is followed by '(')
        profile.keywords?.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            if let r = match?.range {
                storage.addAttribute(.foregroundColor, value: keywordColor, range: r)
            }
        }

        // 5. Attributes / Decorators / Preprocessor / JSON keys
        profile.attributesOrMacros?.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            if let r = match?.range {
                storage.addAttribute(.foregroundColor, value: attrColor, range: r)
            }
        }

        // 6. Strings (override keywords inside string literals)
        profile.strings.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            if let r = match?.range {
                storage.addAttribute(.foregroundColor, value: stringColor, range: r)
            }
        }

        // 7. Comments (override everything inside a comment)
        profile.comments?.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            if let r = match?.range {
                storage.addAttribute(.foregroundColor, value: commentColor, range: r)
            }
        }
    }
}
