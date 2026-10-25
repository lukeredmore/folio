"""Bazel module extension for fetching upstream cmark-gfm C sources and Markdown spec test fixtures."""

CMARK_GFM_REF = "0.29.0.gfm.13"
CMARK_GFM_URL = "https://github.com/github/cmark-gfm/archive/{}.tar.gz".format(CMARK_GFM_REF)
CMARK_GFM_SHA256 = "5abc61798ebd9de5660bc076443c07abad2b8d15dbc11094a3a79644b8ad243a"

COMMONMARK_VERSION = "0.31.2"
COMMONMARK_URL = "https://spec.commonmark.org/{}/spec.json".format(COMMONMARK_VERSION)
COMMONMARK_SHA256 = "d431b29d97b6f73e69d547109cf5081578fac931e72afe95639ebe766c1b2a20"

SWIFTMATH_VERSION = "1.7.3"
SWIFTMATH_URL = "https://github.com/mgriebling/SwiftMath/archive/refs/tags/{}.tar.gz".format(SWIFTMATH_VERSION)
SWIFTMATH_SHA256 = "b474b670121a8063ec27216e2c259d242acae3e03685f917102443201c1bf0e1"

def _cmark_gfm_repo_impl(ctx):
    script = ctx.path(Label("//tools:update_markdown_spec.py"))
    ctx.download(
        url = CMARK_GFM_URL,
        output = "cmark_gfm.tar.gz",
        sha256 = CMARK_GFM_SHA256,
    )
    res = ctx.execute([
        "python3",
        str(script),
        "--cmark-gfm-ref",
        CMARK_GFM_REF,
        "--cmark-tar",
        "cmark_gfm.tar.gz",
        "--output-cmark-dir",
        ".",
        "--output-spec-dir",
        "none",
    ])
    if res.return_code != 0:
        fail("Failed to extract cmark-gfm sources:\n{}\n{}".format(res.stdout, res.stderr))

cmark_gfm_repository = repository_rule(
    implementation = _cmark_gfm_repo_impl,
    attrs = {},
)

def _markdown_spec_repo_impl(ctx):
    script = ctx.path(Label("//tools:update_markdown_spec.py"))
    ctx.download(
        url = CMARK_GFM_URL,
        output = "cmark_gfm.tar.gz",
        sha256 = CMARK_GFM_SHA256,
    )
    ctx.download(
        url = COMMONMARK_URL,
        output = "commonmark_spec_raw.json",
        sha256 = COMMONMARK_SHA256,
    )
    res = ctx.execute([
        "python3",
        str(script),
        "--cmark-gfm-ref",
        CMARK_GFM_REF,
        "--commonmark-version",
        COMMONMARK_VERSION,
        "--cmark-tar",
        "cmark_gfm.tar.gz",
        "--commonmark-json",
        "commonmark_spec_raw.json",
        "--output-cmark-dir",
        "none",
        "--output-spec-dir",
        ".",
    ])
    if res.return_code != 0:
        fail("Failed to generate markdown_spec fixtures:\n{}\n{}".format(res.stdout, res.stderr))

markdown_spec_repository = repository_rule(
    implementation = _markdown_spec_repo_impl,
    attrs = {},
)

def _swift_math_repo_impl(ctx):
    ctx.download_and_extract(
        url = SWIFTMATH_URL,
        sha256 = SWIFTMATH_SHA256,
        stripPrefix = "SwiftMath-{}".format(SWIFTMATH_VERSION),
    )
    patch_res = ctx.execute([
        "python3",
        "-c",
        """
p = "Sources/SwiftMath/MathRender/MTTypesetter.swift"
with open(p, "r", encoding="utf-8") as f:
    src = f.read()
src = src.replace(
    'assert(false, "Interelement space undefined for radical on the right. Treat radical as ordinary.")\\n                return Int.max',
    'return 0'
)
src = src.replace(
    'assert(false, "Interelement space undefined for type \\\\(type)")\\n            return Int.max',
    'return 0'
)
src = src.replace(
    'assert(spaceType != .invalid, "Invalid space between \\\\(left) and \\\\(right)")',
    'if spaceType == .invalid { return 0 }'
)
src = src.replace(
    'NSException(name: NSExceptionName("IllegalCharacter"), reason: "Unknown character \\\\(ch) for default style.").raise()',
    'return ch.utf32Char'
)
with open(p, "w", encoding="utf-8") as f:
    f.write(src)
""",
    ])
    if patch_res.return_code != 0:
        fail("Failed to patch SwiftMath MTTypesetter.swift:\n{}\n{}".format(patch_res.stdout, patch_res.stderr))
    ctx.file(
        "Sources/SwiftMath/MathBundle/BundleModuleAccessor.swift",
        content = """import Foundation
import CoreGraphics

extension Bundle {
    static let module: Bundle = {
        if Bundle.main.url(forResource: "mathFonts", withExtension: "bundle") != nil {
            return Bundle.main
        }
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment
        var candidateDirs: [String] = []
        if let testSrcdir = env["TEST_SRCDIR"] {
            if let entries = try? fm.contentsOfDirectory(atPath: testSrcdir) {
                for entry in entries {
                    candidateDirs.append("\\(testSrcdir)/\\(entry)/Sources/SwiftMath")
                    candidateDirs.append("\\(testSrcdir)/\\(entry)")
                }
            }
        }
        for dir in candidateDirs {
            let bundlePath = "\\(dir)/mathFonts.bundle"
            if fm.fileExists(atPath: bundlePath), let b = Bundle(path: dir) {
                return b
            }
        }
        let sourceDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        if let b = Bundle(url: sourceDir),
           b.url(forResource: "mathFonts", withExtension: "bundle") != nil {
            return b
        }
        return Bundle.main
    }()
}

extension MTDisplay {
    public func folioDraw(in context: CGContext, at position: CGPoint, color: MTColor) {
        self.position = position
        self.textColor = color
        self.draw(context)
    }
}

extension MTMathList {
    private static func folioSanitizeInPlace(_ list: MTMathList?) {
        guard let list = list else { return }
        var lastSignificantAtom: MTMathAtom? = nil
        for atom in list.atoms {
            folioSanitizeInPlace(atom.subScript)
            folioSanitizeInPlace(atom.superScript)
            if let frac = atom as? MTFraction {
                folioSanitizeInPlace(frac.numerator)
                folioSanitizeInPlace(frac.denominator)
            } else if let rad = atom as? MTRadical {
                folioSanitizeInPlace(rad.radicand)
                folioSanitizeInPlace(rad.degree)
            } else if let inner = atom as? MTInner {
                folioSanitizeInPlace(inner.innerList)
            } else if let over = atom as? MTOverLine {
                folioSanitizeInPlace(over.innerList)
            } else if let under = atom as? MTUnderLine {
                folioSanitizeInPlace(under.innerList)
            } else if let acc = atom as? MTAccent {
                folioSanitizeInPlace(acc.innerList)
            } else if let clr = atom as? MTMathColor {
                folioSanitizeInPlace(clr.innerList)
            } else if let tclr = atom as? MTMathTextColor {
                folioSanitizeInPlace(tclr.innerList)
            } else if let cbox = atom as? MTMathColorbox {
                folioSanitizeInPlace(cbox.innerList)
            } else if let table = atom as? MTMathTable {
                for r in 0..<table.cells.count {
                    for c in 0..<table.cells[r].count {
                        table.cells[r][c] = table.cells[r][c].finalized
                        folioSanitizeInPlace(table.cells[r][c])
                    }
                }
            }

            if atom.type == .space || atom.type == .style || atom.type == .boundary {
                continue
            }
            if atom.type == .binaryOperator {
                if let prev = lastSignificantAtom, prev.type.isNotBinaryOperator() {
                    atom.type = .unaryOperator
                } else if lastSignificantAtom == nil {
                    atom.type = .unaryOperator
                }
            } else if atom.type == .relation || atom.type == .punctuation || atom.type == .close {
                if let prev = lastSignificantAtom, prev.type == .binaryOperator {
                    prev.type = .unaryOperator
                }
            }
            lastSignificantAtom = atom
        }
        if let last = lastSignificantAtom, last.type == .binaryOperator {
            last.type = .unaryOperator
        }
    }

    public func folioTypeset(font: MTFont, style: MTLineStyle) -> MTMathListDisplay? {
        let finalizedList = self.finalized
        Self.folioSanitizeInPlace(finalizedList)
        return MTTypesetter.createLineForMathList(finalizedList, font: font, style: style)
    }
}

extension MTMathAtomFactory {
    public static func folioAddSymbol(_ name: String, type: MTMathAtomType, value: String) {
        Self.add(latexSymbol: name, value: MTMathAtom(type: type, value: value))
    }
}
""",
    )
    ctx.file(
        "BUILD.bazel",
        content = """load("@build_bazel_rules_apple//apple:resources.bzl", "apple_bundle_import")
load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

package(default_visibility = ["//visibility:public"])

apple_bundle_import(
    name = "math_fonts_bundle",
    bundle_imports = glob(["Sources/SwiftMath/mathFonts.bundle/**"]),
)

filegroup(
    name = "math_fonts_files",
    srcs = glob(["Sources/SwiftMath/mathFonts.bundle/**"]),
)

swift_library(
    name = "SwiftMath",
    srcs = glob(["Sources/SwiftMath/**/*.swift"]),
    copts = [
        "-swift-version",
        "5",
    ],
    data = [
        ":math_fonts_files",
    ],
    module_name = "SwiftMath",
)
""",
    )

swift_math_repository = repository_rule(
    implementation = _swift_math_repo_impl,
    attrs = {},
)

def _upstream_deps_impl(_module_ctx):
    cmark_gfm_repository(name = "cmark_gfm")
    markdown_spec_repository(name = "markdown_spec")
    swift_math_repository(name = "swift_math")

upstream_deps = module_extension(
    implementation = _upstream_deps_impl,
)
