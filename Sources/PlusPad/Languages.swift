import Foundation

/// Keyword lists are written as one space-separated string rather than an array
/// literal.
///
/// Two reasons, and the second is the one that forced it: a flat list is far
/// easier to read and to extend when adding a language, and a thirty-element
/// array of structs each holding a hundred-element `Set` literal takes the
/// optimiser minutes to constant-fold under whole-module optimisation. Splitting
/// a string at runtime costs microseconds once, at startup.
private func words(_ list: String) -> Set<String> {
    Set(list.split(separator: " ").map(String.init))
}

/// The shape of a language's grammar, which decides how the scanner walks it.
///
/// Notepad++ ships roughly eighty lexers; nearly all of them are one of a small
/// number of shapes with a different keyword list bolted on. Modelling the shape
/// separately means a new language is usually just a `LanguageDef` literal.
enum LanguageFlavor {
    /// Braces, `//` and `/* */`-style comments, quoted strings. Covers C, Swift,
    /// Java, Go, Rust, JavaScript, PHP, and anything shaped like them.
    case cLike
    /// Angle-bracket tags with attributes: HTML, XML, and friends.
    case markup
    /// Selector / property / value blocks.
    case css
    /// Headings, emphasis, links, fences.
    case markdown
    /// Keys, values, and nothing else.
    case json
    /// Key = value with section headers and `;` or `#` comments.
    case ini
    /// Indentation-significant key: value with `#` comments.
    case yaml
    /// No highlighting at all.
    case plain
}

/// Everything the scanner needs to colour one language.
struct LanguageDef {
    var name: String
    var flavor: LanguageFlavor
    /// Lower-cased, without the leading dot.
    var extensions: [String]
    /// Bare filenames that identify the language regardless of extension.
    var filenames: [String] = []
    /// Matched against the first line for `#!` scripts.
    var shebangHints: [String] = []

    var lineComments: [String] = []
    var blockComment: (open: String, close: String)? = nil
    /// Quote characters that open a string. A string ends at the same character.
    var stringDelimiters: [Character] = []
    /// Delimiters inside which a backslash escapes the next character.
    var escapesInStrings: Bool = true
    /// Triple-quoted or otherwise multi-line string openers, as (open, close).
    var multilineStrings: [(open: String, close: String)] = []
    /// Line starter that colours the whole line as a directive, e.g. `#` in C.
    var preprocessorPrefix: String? = nil

    var keywords: Set<String> = []
    /// Types, built-ins and constants, coloured differently from keywords so a
    /// declaration reads at a glance.
    var types: Set<String> = []
    var caseSensitive: Bool = true

    /// Comment token used by the Edit > Comment/Uncomment commands.
    var commentToken: String? { lineComments.first }
}

/// The language table and the rules for picking one for a document.
enum LanguageRegistry {

    static let plainText = LanguageDef(name: "Plain Text", flavor: .plain, extensions: ["txt", "text", "log"])

    // Keyword lists are deliberately the language's own reserved words only.
    // Padding them with standard-library names makes ordinary identifiers light
    // up and the highlighting stops carrying information.

    static let all: [LanguageDef] = [
        plainText,

        LanguageDef(
            name: "Swift", flavor: .cLike, extensions: ["swift"],
            lineComments: ["//"], blockComment: ("/*", "*/"),
            stringDelimiters: ["\""], multilineStrings: [("\"\"\"", "\"\"\"")],
            keywords: words("associatedtype class deinit enum extension fileprivate func import init inout internal let open operator private precedencegroup protocol public rethrows static struct subscript typealias var break case catch continue default defer do else fallthrough for guard if in repeat return throw switch where while as await is super self Self throws try async actor nonisolated some any lazy weak unowned override final indirect mutating convenience required dynamic consuming borrowing package each macro"),
            types: words("Int Int8 Int16 Int32 Int64 UInt UInt8 UInt16 UInt32 UInt64 Double Float Bool String Character Array Dictionary Set Optional Result Data Date URL Error Any AnyObject Void true false nil")),

        LanguageDef(
            name: "Python", flavor: .cLike, extensions: ["py", "pyw", "pyi"],
            filenames: ["SConstruct"], shebangHints: ["python"],
            lineComments: ["#"], stringDelimiters: ["\"", "'"],
            multilineStrings: [("\"\"\"", "\"\"\""), ("'''", "'''")],
            keywords: words("and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield match case"),
            types: words("True False None self cls int float str bytes bool list dict set tuple frozenset complex object type print len range enumerate zip open isinstance super Exception")),

        LanguageDef(
            name: "JavaScript", flavor: .cLike, extensions: ["js", "mjs", "cjs", "jsx"],
            shebangHints: ["node"],
            lineComments: ["//"], blockComment: ("/*", "*/"),
            stringDelimiters: ["\"", "'", "`"],
            keywords: words("async await break case catch class const continue debugger default delete do else export extends finally for function get if import in instanceof let new of return set static super switch this throw try typeof var void while with yield"),
            types: words("true false null undefined NaN Infinity Array Object String Number Boolean Symbol BigInt Promise Map Set WeakMap WeakSet JSON Math Date RegExp Error console window document globalThis")),

        LanguageDef(
            name: "TypeScript", flavor: .cLike, extensions: ["ts", "tsx", "mts", "cts"],
            lineComments: ["//"], blockComment: ("/*", "*/"),
            stringDelimiters: ["\"", "'", "`"],
            keywords: words("abstract any as asserts async await break case catch class const continue declare default delete do else enum export extends finally for from function get if implements import in infer instanceof interface is keyof let namespace new of private protected public readonly return satisfies set static super switch this throw try type typeof var void while yield"),
            types: words("true false null undefined string number boolean object symbol bigint unknown never Array Promise Record Partial Readonly Pick Omit Map Set JSON Math console")),

        LanguageDef(
            name: "C", flavor: .cLike, extensions: ["c", "h"],
            lineComments: ["//"], blockComment: ("/*", "*/"),
            stringDelimiters: ["\"", "'"], preprocessorPrefix: "#",
            keywords: words("auto break case const continue default do else enum extern for goto if inline register restrict return sizeof static struct switch typedef union volatile while _Atomic _Bool _Generic _Noreturn _Static_assert"),
            types: words("char double float int long short signed unsigned void size_t ssize_t ptrdiff_t bool true false NULL int8_t int16_t int32_t int64_t uint8_t uint16_t uint32_t uint64_t FILE")),

        LanguageDef(
            name: "C++", flavor: .cLike, extensions: ["cpp", "cxx", "cc", "hpp", "hxx", "hh", "ipp", "inl"],
            lineComments: ["//"], blockComment: ("/*", "*/"),
            stringDelimiters: ["\"", "'"], preprocessorPrefix: "#",
            keywords: words("alignas alignof asm auto break case catch class concept const consteval constexpr constinit const_cast continue co_await co_return co_yield decltype default delete do dynamic_cast else enum explicit export extern friend goto if inline mutable namespace new noexcept operator private protected public register reinterpret_cast requires return sizeof static static_assert static_cast struct switch template this thread_local throw try typedef typeid typename union using virtual volatile while"),
            types: words("bool char char8_t char16_t char32_t double float int long short signed unsigned void wchar_t size_t nullptr true false std string vector map set unordered_map shared_ptr unique_ptr optional span")),

        LanguageDef(
            name: "Objective-C", flavor: .cLike, extensions: ["m", "mm"],
            lineComments: ["//"], blockComment: ("/*", "*/"),
            stringDelimiters: ["\"", "'"], preprocessorPrefix: "#",
            keywords: words("@interface @implementation @protocol @end @property @synthesize @dynamic @selector @class @autoreleasepool @synchronized @try @catch @finally @throw break case const continue default do else enum extern for goto if inline return sizeof static struct switch typedef union volatile while in out inout bycopy byref oneway"),
            types: words("id instancetype Class SEL IMP BOOL YES NO nil Nil NSString NSArray NSDictionary NSNumber NSObject NSInteger NSUInteger CGFloat void char int long short float double unsigned signed")),

        LanguageDef(
            name: "Java", flavor: .cLike, extensions: ["java"],
            lineComments: ["//"], blockComment: ("/*", "*/"),
            stringDelimiters: ["\"", "'"], multilineStrings: [("\"\"\"", "\"\"\"")],
            keywords: words("abstract assert break case catch class const continue default do else enum extends final finally for goto if implements import instanceof interface native new package private protected public record return sealed static strictfp super switch synchronized this throw throws transient try var volatile while yield permits non-sealed"),
            types: words("boolean byte char double float int long short void String Object Integer Long Double Boolean List Map Set Optional Stream true false null")),

        LanguageDef(
            name: "Kotlin", flavor: .cLike, extensions: ["kt", "kts"],
            lineComments: ["//"], blockComment: ("/*", "*/"),
            stringDelimiters: ["\"", "'"], multilineStrings: [("\"\"\"", "\"\"\"")],
            keywords: words("as break by catch class companion const constructor continue crossinline data do else enum external false final finally for fun get if import in infix init inline inner interface internal is lateinit noinline object open operator out override package private protected public reified return sealed set super suspend tailrec this throw try typealias val var vararg when where while"),
            types: words("Int Long Short Byte Double Float Boolean Char String Any Unit Nothing List Map Set Array true false null")),

        LanguageDef(
            name: "Go", flavor: .cLike, extensions: ["go"],
            lineComments: ["//"], blockComment: ("/*", "*/"),
            stringDelimiters: ["\"", "'", "`"],
            keywords: words("break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var"),
            types: words("bool byte complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8 uint16 uint32 uint64 uintptr any true false nil iota make new len cap append copy delete panic recover")),

        LanguageDef(
            name: "Rust", flavor: .cLike, extensions: ["rs"],
            lineComments: ["//"], blockComment: ("/*", "*/"),
            stringDelimiters: ["\"", "'"],
            keywords: words("as async await break const continue crate dyn else enum extern fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait type unsafe use where while union macro_rules"),
            types: words("bool char f32 f64 i8 i16 i32 i64 i128 isize str u8 u16 u32 u64 u128 usize String Vec Option Result Box Rc Arc HashMap HashSet Some None Ok Err true false")),

        LanguageDef(
            name: "C#", flavor: .cLike, extensions: ["cs"],
            lineComments: ["//"], blockComment: ("/*", "*/"),
            stringDelimiters: ["\"", "'"], preprocessorPrefix: "#",
            keywords: words("abstract as async await base break case catch checked class const continue default delegate do else enum event explicit extern finally fixed for foreach get goto if implicit in init interface internal is lock namespace new operator out override params private protected public readonly record ref return sealed set sizeof stackalloc static struct switch this throw try typeof unchecked unsafe using var virtual volatile when where while yield"),
            types: words("bool byte char decimal double dynamic float int long nint nuint object sbyte short string uint ulong ushort void true false null List Dictionary Task String")),

        LanguageDef(
            name: "PHP", flavor: .cLike, extensions: ["php", "phtml", "php3", "php4", "php5"],
            lineComments: ["//", "#"], blockComment: ("/*", "*/"),
            stringDelimiters: ["\"", "'"],
            keywords: words("abstract and array as break callable case catch class clone const continue declare default do echo else elseif empty enddeclare endfor endforeach endif endswitch endwhile enum extends final finally fn for foreach function global goto if implements include include_once instanceof insteadof interface isset list match namespace new or print private protected public readonly require require_once return static switch throw trait try unset use var while xor yield"),
            types: words("bool float int iterable mixed never object string void null true false self parent $this")),

        LanguageDef(
            name: "Ruby", flavor: .cLike, extensions: ["rb", "rake", "gemspec"],
            filenames: ["Rakefile", "Gemfile", "Podfile", "Fastfile"], shebangHints: ["ruby"],
            lineComments: ["#"], stringDelimiters: ["\"", "'"],
            keywords: words("alias and begin break case class def defined? do else elsif end ensure for if in module next not or redo rescue retry return then undef unless until when while yield require require_relative attr_accessor attr_reader attr_writer include extend lambda proc"),
            types: words("true false nil self super __FILE__ __LINE__ String Integer Float Array Hash Symbol Range Proc Struct")),

        LanguageDef(
            name: "Shell", flavor: .cLike, extensions: ["sh", "bash", "zsh", "ksh", "command"],
            filenames: [".bashrc", ".bash_profile", ".zshrc", ".zprofile", ".profile"],
            shebangHints: ["sh", "bash", "zsh", "ksh"],
            lineComments: ["#"], stringDelimiters: ["\"", "'"],
            keywords: words("if then else elif fi case esac for select while until do done in function time coproc return break continue exit local declare typeset readonly export unset shift source alias trap set"),
            types: words("echo printf read cd pwd test eval exec let true false cat grep sed awk curl git sudo chmod mkdir rm cp mv ls find xargs")),

        LanguageDef(
            name: "SQL", flavor: .cLike, extensions: ["sql", "ddl", "dml"],
            lineComments: ["--"], blockComment: ("/*", "*/"),
            stringDelimiters: ["'", "\""],
            keywords: words("select from where insert into values update set delete create alter drop truncate table view index trigger procedure function database schema join inner left right full outer cross on using group by having order asc desc limit offset union all distinct as and or not in exists between like ilike is case when then else end with recursive begin commit rollback transaction grant revoke primary foreign key references constraint unique check default cascade returning over partition window"),
            types: words("int integer bigint smallint tinyint decimal numeric float real double char varchar nvarchar text blob clob date time timestamp datetime boolean bool null true false serial uuid json jsonb"),
            caseSensitive: false),

        LanguageDef(
            name: "Perl", flavor: .cLike, extensions: ["pl", "pm", "t"], shebangHints: ["perl"],
            lineComments: ["#"], stringDelimiters: ["\"", "'"],
            keywords: words("my our local sub package use no require if elsif else unless while until for foreach do last next redo return given when default and or not eq ne lt gt le ge cmp qw qq BEGIN END"),
            types: words("print printf say defined undef ref bless scalar wantarray die warn eval shift push pop splice keys values exists delete sort map grep join split")),

        LanguageDef(
            name: "Lua", flavor: .cLike, extensions: ["lua"], shebangHints: ["lua"],
            lineComments: ["--"], blockComment: ("--[[", "]]"),
            stringDelimiters: ["\"", "'"],
            keywords: words("and break do else elseif end for function goto if in local not or repeat return then until while"),
            types: words("nil true false self print pairs ipairs type tostring tonumber table string math io os require pcall error setmetatable")),

        LanguageDef(
            name: "R", flavor: .cLike, extensions: ["r"], shebangHints: ["Rscript"],
            lineComments: ["#"], stringDelimiters: ["\"", "'"],
            keywords: words("if else repeat while function for in next break return"),
            types: words("TRUE FALSE NULL NA Inf NaN c list vector matrix data.frame factor library require print cat paste length nrow ncol apply sapply lapply")),

        LanguageDef(
            name: "HTML", flavor: .markup, extensions: ["html", "htm", "xhtml", "vue", "svelte"],
            blockComment: ("<!--", "-->"), stringDelimiters: ["\"", "'"]),

        LanguageDef(
            name: "XML", flavor: .markup, extensions: ["xml", "xsd", "xsl", "xslt", "svg", "plist", "rss", "atom", "storyboard", "xib", "pom", "csproj"],
            blockComment: ("<!--", "-->"), stringDelimiters: ["\"", "'"]),

        LanguageDef(
            name: "CSS", flavor: .css, extensions: ["css", "scss", "sass", "less"],
            lineComments: ["//"], blockComment: ("/*", "*/"),
            stringDelimiters: ["\"", "'"]),

        LanguageDef(
            name: "JSON", flavor: .json, extensions: ["json", "jsonc", "geojson", "webmanifest"],
            filenames: ["package.json", ".eslintrc", ".babelrc", "tsconfig.json"],
            lineComments: ["//"], blockComment: ("/*", "*/"),
            stringDelimiters: ["\""]),

        LanguageDef(
            name: "YAML", flavor: .yaml, extensions: ["yaml", "yml"],
            filenames: [".gitlab-ci.yml", "docker-compose.yml"],
            lineComments: ["#"], stringDelimiters: ["\"", "'"]),

        LanguageDef(
            name: "TOML", flavor: .ini, extensions: ["toml"],
            filenames: ["Cargo.toml", "pyproject.toml"],
            lineComments: ["#"], stringDelimiters: ["\"", "'"]),

        LanguageDef(
            name: "INI", flavor: .ini, extensions: ["ini", "cfg", "conf", "properties", "env", "editorconfig"],
            filenames: [".env", ".gitconfig", ".editorconfig"],
            lineComments: ["#", ";"], stringDelimiters: ["\"", "'"]),

        LanguageDef(
            name: "Markdown", flavor: .markdown, extensions: ["md", "markdown", "mdown", "mkd", "mdx"],
            filenames: ["README", "CHANGELOG", "LICENSE"]),

        LanguageDef(
            name: "Makefile", flavor: .cLike, extensions: ["mk", "mak"],
            filenames: ["Makefile", "makefile", "GNUmakefile"],
            lineComments: ["#"], stringDelimiters: ["\"", "'"],
            keywords: words("ifeq ifneq ifdef ifndef else endif include define endef export unexport override vpath .PHONY .DEFAULT .SUFFIXES .PRECIOUS"),
            types: words("wildcard patsubst subst shell foreach filter filter-out sort dir notdir basename suffix addprefix addsuffix call eval value")),

        LanguageDef(
            name: "Dockerfile", flavor: .cLike, extensions: ["dockerfile"],
            filenames: ["Dockerfile", "Containerfile"],
            lineComments: ["#"], stringDelimiters: ["\"", "'"],
            keywords: words("FROM RUN CMD LABEL MAINTAINER EXPOSE ENV ADD COPY ENTRYPOINT VOLUME USER WORKDIR ARG ONBUILD STOPSIGNAL HEALTHCHECK SHELL AS"),
            caseSensitive: false),

        LanguageDef(
            name: "Batch", flavor: .cLike, extensions: ["bat", "cmd"],
            lineComments: ["rem", "::"], stringDelimiters: ["\""],
            keywords: words("if else for in do goto call exit set setlocal endlocal shift echo off on pause rem not exist defined errorlevel equ neq lss leq gtr geq"),
            caseSensitive: false),

        LanguageDef(
            name: "PowerShell", flavor: .cLike, extensions: ["ps1", "psm1", "psd1"],
            lineComments: ["#"], blockComment: ("<#", "#>"),
            stringDelimiters: ["\"", "'"],
            keywords: words("begin break catch class continue data define do dynamicparam else elseif end enum exit filter finally for foreach from function hidden if in param process return static switch throw trap try until using var while"),
            types: words("$true $false $null $_ $args $PSItem Write-Host Write-Output Get-ChildItem Set-Location New-Item Remove-Item Get-Content Set-Content"),
            caseSensitive: false),

        LanguageDef(
            name: "Diff", flavor: .plain, extensions: ["diff", "patch"]),
    ]

    /// Languages for the menu, alphabetical with Plain Text pinned first.
    static var menuOrder: [LanguageDef] {
        let rest = all.filter { $0.name != plainText.name }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return [plainText] + rest
    }

    static func named(_ name: String) -> LanguageDef? {
        all.first { $0.name == name }
    }

    /// Pick a language for a file. Exact filename beats extension, because
    /// `Makefile` and `Dockerfile` have no extension at all, and both beat the
    /// shebang, which only gets a look when nothing else matched.
    static func detect(url: URL?, firstLine: String = "") -> LanguageDef {
        if let url {
            let name = url.lastPathComponent
            if let match = all.first(where: { $0.filenames.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) }) {
                return match
            }
            let ext = url.pathExtension.lowercased()
            if !ext.isEmpty, let match = all.first(where: { $0.extensions.contains(ext) }) {
                return match
            }
            // A file with no extension but a known stem, e.g. `Dockerfile.dev`.
            let stem = (name as NSString).deletingPathExtension.lowercased()
            if !stem.isEmpty, let match = all.first(where: { $0.extensions.contains(stem) }) {
                return match
            }
        }
        if firstLine.hasPrefix("#!") {
            let lower = firstLine.lowercased()
            if let match = all.first(where: { def in
                def.shebangHints.contains { lower.contains("/" + $0) || lower.contains(" " + $0) }
            }) {
                return match
            }
        }
        if firstLine.hasPrefix("<?xml") { return named("XML") ?? plainText }
        if firstLine.lowercased().hasPrefix("<!doctype html") { return named("HTML") ?? plainText }
        return plainText
    }

    /// Extensions offered in the open panel. Nil means "everything", which is
    /// what a general-purpose editor wants; this is here for the save panel.
    static var allExtensions: [String] {
        Array(Set(all.flatMap(\.extensions))).sorted()
    }
}
