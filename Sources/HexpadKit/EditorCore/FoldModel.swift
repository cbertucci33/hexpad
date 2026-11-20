import Foundation

/// A foldable span in a document.
///
/// Ranges are UTF-16 code-unit offsets, matching `NSRange` and the rest of the
/// editor core. A range covers the complete construct: for a brace fold it
/// starts at the opening delimiter and ends just past the closing delimiter,
/// for a block comment it covers `/* ... */`, and for a region marker it starts
/// at the beginning of the opening marker's line and ends at the end of the
/// closing marker's line.
///
/// A fold's identity is its span, not its `kind`. The kind records how the
/// range was discovered and is used for presentation (for example, a gutter
/// may draw comments differently from braces); two folds with the same span
/// are the same fold even if the language metadata changes how it was found.
public struct FoldRange: Hashable, Codable {

    /// How a foldable range was discovered.
    public enum Kind: String, Codable {
        /// A `{ ... }` pair declared by the lexer definition.
        case braces
        /// A `( ... )` pair declared by the lexer definition.
        case parentheses
        /// A `[ ... ]` pair (or another non-curly pair) declared by the lexer
        /// definition.
        case brackets
        /// A block comment declared by the lexer definition.
        case blockComment
        /// A start/end region marker from `FoldConfiguration`.
        case region
    }

    /// The UTF-16 span of the fold, including its delimiters.
    public let range: NSRange

    /// How the range was discovered.
    public let kind: Kind

    public init(range: NSRange, kind: Kind) {
        self.range = range
        self.kind = kind
    }

    public init(location: Int, length: Int, kind: Kind) {
        self.init(range: NSRange(location: location, length: length), kind: kind)
    }

    /// UTF-16 start offset.
    public var location: Int { range.location }

    /// UTF-16 length.
    public var length: Int { range.length }

    /// UTF-16 end offset (exclusive).
    public var upperBound: Int { NSMaxRange(range) }

    public static func == (lhs: FoldRange, rhs: FoldRange) -> Bool {
        lhs.range == rhs.range
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(range.location)
        hasher.combine(range.length)
    }
}

/// A pair of region markers that delimit a foldable section.
///
/// Region markers belong to the fold policy rather than to the grammar: the
/// markers are matched against the leading whitespace-trimmed text of a line.
/// Nested regions are supported. For example, Common Lisp-style folding uses
/// `start = ";; region"` and `end = ";; endregion"`.
public struct FoldRegionMarker: Equatable, Hashable, Codable {

    /// Prefix that opens a region when it starts a trimmed line.
    public let start: String

    /// Prefix that closes the most recent matching region.
    public let end: String

    public init(start: String, end: String) {
        self.start = start
        self.end = end
    }
}

/// Policies that decide which metadata-derived ranges are foldable.
///
/// Square brackets are opt-in because in many languages they are used for
/// indexing and are not useful fold points. Curly braces and parentheses are
/// always considered when the lexer definition declares them.
public struct FoldConfiguration: Equatable, Codable {

    /// Whether `[ ... ]` pairs declared by the definition are foldable.
    public var foldsSquareBrackets: Bool

    /// Region markers to match, in priority order. An empty list disables
    /// region folding.
    ///
    /// `LexerDefinition` does not carry region metadata yet, so markers are
    /// supplied by the caller. When definitions gain a region field, this list
    /// can be populated from it without changing the fold model.
    public var regionMarkers: [FoldRegionMarker]

    /// Whether constructs contained on a single line are foldable.
    ///
    /// The default is `false`: a fold must contain a line break. Single-line
    /// folds remove text without reducing the number of visible lines, so
    /// editors normally only offer folds that span lines.
    public var foldsSingleLineRanges: Bool

    public init(foldsSquareBrackets: Bool = false,
                regionMarkers: [FoldRegionMarker] = [],
                foldsSingleLineRanges: Bool = false) {
        self.foldsSquareBrackets = foldsSquareBrackets
        self.regionMarkers = regionMarkers
        self.foldsSingleLineRanges = foldsSingleLineRanges
    }

    public static let `default` = FoldConfiguration()
}

/// One replacement an edit made to the document.
///
/// The edit is expressed in pre-edit UTF-16 offsets: `replacedLength` units
/// starting at `location` were replaced by `insertedLength` units. A pure
/// insertion has `replacedLength == 0`; a pure deletion has
/// `insertedLength == 0`.
public struct FoldTextEdit: Equatable, Codable {

    /// UTF-16 location of the first replaced code unit.
    public let location: Int

    /// Number of UTF-16 code units removed from the old text.
    public let replacedLength: Int

    /// Number of UTF-16 code units inserted in their place.
    public let insertedLength: Int

    public init(location: Int, replacedLength: Int, insertedLength: Int) {
        self.location = max(0, location)
        self.replacedLength = max(0, replacedLength)
        self.insertedLength = max(0, insertedLength)
    }

    /// Creates an edit from a position and a signed length delta.
    ///
    /// A positive delta is a pure insertion of that many units; a negative
    /// delta is a pure deletion of that many units. Use the three-value
    /// initializer when the edit also replaces existing text.
    public init(location: Int, delta: Int) {
        self.init(location: location,
                  replacedLength: delta < 0 ? -delta : 0,
                  insertedLength: max(0, delta))
    }

    public init(replacedRange: NSRange, insertedLength: Int) {
        self.init(location: replacedRange.location,
                  replacedLength: replacedRange.length,
                  insertedLength: insertedLength)
    }

    /// A pure insertion at `location`.
    public static func insertion(at location: Int, length: Int) -> FoldTextEdit {
        FoldTextEdit(location: location, replacedLength: 0, insertedLength: length)
    }

    /// A pure deletion of `range`.
    public static func deletion(_ range: NSRange) -> FoldTextEdit {
        FoldTextEdit(replacedRange: range, insertedLength: 0)
    }

    /// The replaced range in the pre-edit document.
    public var replacedRange: NSRange {
        NSRange(location: location, length: replacedLength)
    }

    /// The inserted range in the post-edit document.
    public var insertedRange: NSRange {
        NSRange(location: location, length: insertedLength)
    }

    /// Change in document length: `insertedLength - replacedLength`.
    public var delta: Int { insertedLength - replacedLength }
}

/// The foldable ranges of one document, plus the independent collapsed state.
///
/// `foldableRanges` is derived from the document text and the language's
/// comment/bracket metadata. `foldState` is kept separate from that
/// computation so rebuilding the model after a re-tokenization does not lose
/// which folds the user collapsed: pass the existing state to the new model.
///
/// The model is pure and Kit-side. It has no `NSTextView` dependency; the
/// gutter and session layers consume its ranges and state.
public struct FoldModel {

    /// The document text the ranges were computed from.
    public let text: String

    /// The grammar whose comment and bracket metadata drives folding.
    public let definition: LexerDefinition

    /// Which metadata-derived ranges are allowed to fold.
    public let configuration: FoldConfiguration

    /// Every foldable range, sorted by location. Outer ranges sort before
    /// nested ranges that start at the same offset.
    public let foldableRanges: [FoldRange]

    /// Nesting depth of every foldable range.
    ///
    /// A top-level fold has depth 1; a fold directly inside it has depth 2,
    /// and so on. Depth is derived at build time from containment, because
    /// ``FoldRange`` is just a span and its kind does not record nesting.
    public let foldDepths: [FoldRange: Int]

    /// 1-based logical line each foldable range starts on.
    ///
    /// Derived at build time in a single pass over the text (the ranges are
    /// sorted by location, so one scan maps every start to its line). Marker
    /// derivation reads this through ``startingLine(of:)`` instead of calling
    /// `GutterGeometry.logicalLine` per fold, which was O(document) per marker
    /// on every gutter draw.
    private let foldStartLines: [FoldRange: Int]

    /// Collapsed ranges, persisted independently of `foldableRanges`.
    public private(set) var foldState: FoldState

    public init(text: String,
                definition: LexerDefinition,
                configuration: FoldConfiguration = .default,
                foldState: FoldState = FoldState()) {
        self.text = text
        self.definition = definition
        self.configuration = configuration
        self.foldableRanges = FoldModel.computeFoldableRanges(
            in: text,
            definition: definition,
            configuration: configuration
        )
        self.foldDepths = FoldModel.computeFoldDepths(for: self.foldableRanges)
        self.foldStartLines = FoldModel.computeFoldStartLines(for: self.foldableRanges,
                                                              in: text)
        self.foldState = foldState
    }

    // MARK: - Fold state

    /// The collapsed ranges, for persistence or inspection.
    public var collapsedRanges: Set<FoldRange> { foldState.collapsedRanges }

    /// Whether `fold` is currently collapsed.
    public func isCollapsed(_ fold: FoldRange) -> Bool {
        foldState.isCollapsed(fold)
    }

    /// Whether `range` is one of the ranges computed from the current text.
    public func isFoldable(_ range: NSRange) -> Bool {
        foldableRanges.contains { $0.range == range }
    }

    /// The foldable range that starts on `line`, if any.
    ///
    /// Lines are 1-based logical lines. When several folds start on the same
    /// line (for example two braces on one line), the outermost fold wins,
    /// which is the one a gutter marker normally represents.
    public func foldableRange(startingAtLine line: Int) -> FoldRange? {
        foldableRanges.first { lineNumber(of: $0.location) == line }
    }

    /// Nesting depth of `fold`: 1 for a top-level fold, 2 when directly inside
    /// another fold, and so on.
    public func depth(of fold: FoldRange) -> Int? {
        foldDepths[fold]
    }

    /// 1-based logical line `fold` starts on.
    ///
    /// Read from the build-time mapping (O(1)); falls back to a direct line
    /// scan for a range not present in the model.
    public func startingLine(of fold: FoldRange) -> Int {
        foldStartLines[fold] ?? lineNumber(of: fold.location)
    }

    /// Every foldable range at `depth`, in model order.
    public func foldableRanges(atDepth depth: Int) -> [FoldRange] {
        guard depth > 0 else { return [] }
        return foldableRanges.filter { foldDepths[$0] == depth }
    }

    /// The innermost foldable range whose lines include the caret line.
    ///
    /// Containment is line-based so a caret anywhere on a construct's opening
    /// line (including before the brace) targets that construct. The deepest
    /// range wins; equal depths fall back to the shorter span. Returns `nil`
    /// when the caret line is not inside any foldable range.
    public func innermostFoldableRange(containing selection: NSRange) -> FoldRange? {
        guard !foldableRanges.isEmpty else { return nil }
        let caretLine = lineNumber(of: max(0, selection.location))
        return foldableRanges
            .filter { fold in
                let firstLine = lineNumber(of: fold.location)
                let lastLine = lineNumber(of: max(fold.location, fold.upperBound - 1))
                return firstLine <= caretLine && caretLine <= lastLine
            }
            .max { lhs, rhs in
                let lhsDepth = foldDepths[lhs] ?? 0
                let rhsDepth = foldDepths[rhs] ?? 0
                if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
                return lhs.length > rhs.length
            }
    }

    /// Collapses `fold`.
    ///
    /// - Returns: `true` when the range is foldable and was not already
    ///   collapsed.
    @discardableResult
    public mutating func fold(_ fold: FoldRange) -> Bool {
        guard let canonical = canonicalFold(for: fold) else { return false }
        guard !foldState.isCollapsed(canonical) else { return false }
        foldState.insert(canonical)
        return true
    }

    /// Expands `fold`.
    ///
    /// - Returns: `true` when the fold was collapsed.
    @discardableResult
    public mutating func unfold(_ fold: FoldRange) -> Bool {
        foldState.remove(fold)
    }

    /// Collapses `fold` when expanded, or expands it when collapsed.
    ///
    /// - Returns: `true` when a foldable range was toggled.
    @discardableResult
    public mutating func toggle(_ fold: FoldRange) -> Bool {
        guard isFoldable(fold.range) else { return false }
        if foldState.isCollapsed(fold) {
            foldState.remove(fold)
        } else if let canonical = canonicalFold(for: fold) {
            foldState.insert(canonical)
        }
        return true
    }

    /// Collapses every foldable range.
    ///
    /// - Returns: The number of ranges newly added to the collapsed set.
    @discardableResult
    public mutating func foldAll() -> Int {
        let before = foldState.count
        for fold in foldableRanges {
            foldState.insert(fold)
        }
        return foldState.count - before
    }

    /// Expands every collapsed range.
    ///
    /// - Returns: The number of ranges removed from the collapsed set.
    @discardableResult
    public mutating func unfoldAll() -> Int {
        let removed = foldState.count
        foldState.removeAll()
        return removed
    }

    /// Collapses the innermost foldable range containing the caret line.
    ///
    /// This is the "Fold Current Level" operation: repeated invocations on the
    /// same caret line walk outward only because collapsing the innermost range
    /// hides its contents, and the caret stays on the visible opening line.
    /// Toggle semantics (a single N++ preference) are deliberately not folded
    /// into this command; Fold and Unfold are separate commands.
    ///
    /// - Returns: `true` when an expanded range was collapsed.
    @discardableResult
    public mutating func foldCurrentLevel(selection: NSRange) -> Bool {
        guard let target = innermostFoldableRange(containing: selection) else { return false }
        return fold(target)
    }

    /// Expands the innermost foldable range containing the caret line.
    ///
    /// - Returns: `true` when a collapsed range was expanded.
    @discardableResult
    public mutating func unfoldCurrentLevel(selection: NSRange) -> Bool {
        guard let target = innermostFoldableRange(containing: selection) else { return false }
        return unfold(target)
    }

    /// Collapses every foldable range at `depth` (1-based).
    ///
    /// Only ranges at exactly that nesting depth are touched. Folding a nested
    /// level while its ancestors are expanded is harmless: the nested range is
    /// already marked collapsed and becomes visible as soon as an ancestor opens.
    ///
    /// - Returns: The number of ranges newly added to the collapsed set.
    @discardableResult
    public mutating func foldLevel(_ depth: Int) -> Int {
        guard depth > 0 else { return 0 }
        let before = foldState.count
        for fold in foldableRanges where foldDepths[fold] == depth {
            foldState.insert(fold)
        }
        return foldState.count - before
    }

    /// Expands every collapsed range at `depth` (1-based).
    ///
    /// - Returns: The number of ranges removed from the collapsed set.
    @discardableResult
    public mutating func unfoldLevel(_ depth: Int) -> Int {
        guard depth > 0 else { return 0 }
        var removed = 0
        for fold in foldableRanges where foldDepths[fold] == depth {
            if foldState.remove(fold) {
                removed += 1
            }
        }
        return removed
    }

    /// Toggles the fold that starts on `line`.
    ///
    /// - Returns: `true` when a fold started on that line.
    @discardableResult
    public mutating func toggleFold(atLine line: Int) -> Bool {
        guard let fold = foldableRange(startingAtLine: line) else { return false }
        return toggle(fold)
    }

    // MARK: - Subtree (expand/collapse a whole branch)

    /// Every foldable range contained in `fold`, including `fold` itself.
    public func foldsContained(in fold: FoldRange) -> [FoldRange] {
        foldableRanges.filter { other in
            other.location >= fold.location && other.upperBound <= fold.upperBound
        }
    }

    /// Expands `fold` and every foldable range nested inside it.
    @discardableResult
    public mutating func expandSubtree(_ fold: FoldRange) -> Int {
        guard let canonical = canonicalFold(for: fold) else { return 0 }
        let targets = foldsContained(in: canonical)
        var expanded = 0
        for target in targets {
            if foldState.remove(target) {
                expanded += 1
            }
        }
        return expanded
    }

    /// Collapses `fold` and every foldable range nested inside it.
    @discardableResult
    public mutating func collapseSubtree(_ fold: FoldRange) -> Int {
        guard let canonical = canonicalFold(for: fold) else { return 0 }
        let targets = foldsContained(in: canonical)
        let before = foldState.count
        for target in targets {
            foldState.insert(target)
        }
        return foldState.count - before
    }

    /// Expands the subtree rooted at the fold that starts on `line`.
    @discardableResult
    public mutating func expandSubtree(atLine line: Int) -> Int {
        guard let fold = foldableRange(startingAtLine: line) else { return 0 }
        return expandSubtree(fold)
    }

    /// Collapses the subtree rooted at the fold that starts on `line`.
    @discardableResult
    public mutating func collapseSubtree(atLine line: Int) -> Int {
        guard let fold = foldableRange(startingAtLine: line) else { return 0 }
        return collapseSubtree(fold)
    }

    // MARK: - Visibility

    /// Visible and hidden spans for the current fold state.
    public func visibility() -> FoldVisibility {
        FoldVisibility(text: text, collapsedRanges: foldState.collapsedRanges)
    }

    /// Visible and hidden spans for an explicit fold state.
    public func visibility(for state: FoldState) -> FoldVisibility {
        FoldVisibility(text: text, collapsedRanges: state.collapsedRanges)
    }

    /// Visible document ranges for the current fold state.
    public var visibleRanges: [NSRange] { visibility().visibleRanges }

    /// Maps a document UTF-16 position to its visible position.
    public func visiblePosition(of documentPosition: Int) -> Int {
        visibility().visiblePosition(ofDocumentPosition: documentPosition)
    }

    // MARK: - Remapping

    /// Remaps every collapsed range across an edit, returning a new state.
    ///
    /// This is a pure function; the receiver is unchanged.
    public func remappedFoldState(for edit: FoldTextEdit) -> FoldState {
        foldState.remapped(for: edit)
    }

    /// Remaps the collapsed state across an edit, in place.
    public mutating func remapFolds(for edit: FoldTextEdit) {
        foldState = foldState.remapped(for: edit)
    }

    /// Recomputes foldable ranges from the current text while preserving the
    /// fold state, as a re-tokenization would.
    public func recomputed() -> FoldModel {
        FoldModel(text: text,
                  definition: definition,
                  configuration: configuration,
                  foldState: foldState)
    }

    // MARK: - Computation

    private func canonicalFold(for fold: FoldRange) -> FoldRange? {
        foldableRanges.first { $0.range == fold.range }
    }

    private func lineNumber(of location: Int) -> Int {
        GutterGeometry.logicalLine(of: location, in: text)
    }

    /// Depth of each range = 1 + the number of ranges that strictly contain it.
    ///
    /// A fold `G` strictly contains `F` when `G.location <= F.location` and
    /// `G.upperBound >= F.upperBound` with `G != F` (equal spans are deduped, so
    /// a same-location equal-length pair never arises). `foldableRanges` arrives
    /// sorted by location — outer before nested at a shared offset — so every
    /// container of a fold precedes it in the array.
    ///
    /// Counting, for each fold, how many *preceding* folds end at or after its
    /// own end is a 2D dominance query. A Fenwick tree over the
    /// coordinate-compressed upper bounds answers it in O(log folds) per fold:
    /// O(folds log folds) total instead of the old O(folds²) pairwise scan that
    /// stalled large files on every keystroke.
    private static func computeFoldDepths(for ranges: [FoldRange]) -> [FoldRange: Int] {
        var depths: [FoldRange: Int] = [:]
        depths.reserveCapacity(ranges.count)
        guard !ranges.isEmpty else { return depths }

        // Coordinate-compress upper bounds to contiguous 0-based ranks.
        let distinctBounds = Array(Set(ranges.map(\.upperBound))).sorted()
        let rank: [Int: Int] = Dictionary(uniqueKeysWithValues:
            distinctBounds.enumerated().map { ($1, $0) })

        // Fenwick tree keyed by rank (1-based internally). `insert` adds one
        // fold at a bound; `countStrictlyBelow` returns how many inserted folds
        // end at a bound smaller than `bound`.
        var tree = [Int](repeating: 0, count: distinctBounds.count + 1)
        func insert(_ bound: Int) {
            var i = rank[bound]! + 1
            while i < tree.count {
                tree[i] += 1
                i += i & (-i)
            }
        }
        func countStrictlyBelow(_ bound: Int) -> Int {
            var sum = 0
            var i = rank[bound]!
            while i > 0 {
                sum += tree[i]
                i -= i & (-i)
            }
            return sum
        }

        var inserted = 0
        for fold in ranges {
            // Every fold already inserted starts at or before this fold, so it
            // contains this fold exactly when it also ends at or after it.
            // (Closed siblings and partial overlaps end earlier and drop out.)
            depths[fold] = 1 + (inserted - countStrictlyBelow(fold.upperBound))
            insert(fold.upperBound)
            inserted += 1
        }
        return depths
    }

    /// Starting 1-based logical line of every foldable range, computed in a
    /// single pass over the text.
    ///
    /// `ranges` is sorted by location, so one scan maps each start to its line
    /// without the O(document) `logicalLine` call the marker layer used to make
    /// per fold on every gutter draw.
    private static func computeFoldStartLines(for ranges: [FoldRange],
                                              in text: String) -> [FoldRange: Int] {
        var lines: [FoldRange: Int] = [:]
        lines.reserveCapacity(ranges.count)
        guard !ranges.isEmpty else { return lines }

        var foldIndex = 0
        var line = 1
        var offset = 0
        for unit in text.utf16 {
            while foldIndex < ranges.count, ranges[foldIndex].location == offset {
                lines[ranges[foldIndex]] = line
                foldIndex += 1
            }
            offset += 1
            if unit == 10 { line += 1 } // "\n"
        }
        // A fold starting exactly at the text length sits on the final line.
        while foldIndex < ranges.count {
            lines[ranges[foldIndex]] = line
            foldIndex += 1
        }
        return lines
    }

    private static func computeFoldableRanges(in text: String,
                                              definition: LexerDefinition,
                                              configuration: FoldConfiguration) -> [FoldRange] {
        let nsText = text as NSString
        guard nsText.length > 0 else { return [] }

        let blockComments = blockCommentSpans(in: nsText, comments: definition.comments)
        let lineComments = lineCommentSpans(
            in: nsText,
            prefix: definition.comments?.linePrefix,
            excluding: blockComments
        )
        let excluded = mergedSpans(blockComments + lineComments)

        var candidates = braceFoldRanges(
            in: nsText,
            pairs: activeBracketPairs(definition: definition, configuration: configuration),
            excluding: excluded
        )
        candidates.append(contentsOf: blockComments.map {
            FoldRange(range: $0, kind: .blockComment)
        })
        candidates.append(contentsOf: regionFoldRanges(in: nsText,
                                                       markers: configuration.regionMarkers))

        var seen = Set<FoldRange>()
        var result: [FoldRange] = []
        for fold in candidates {
            guard fold.length > 0 else { continue }
            guard configuration.foldsSingleLineRanges || containsLineBreak(fold.range, in: nsText) else {
                continue
            }
            guard seen.insert(fold).inserted else { continue }
            result.append(fold)
        }

        return result.sorted { lhs, rhs in
            if lhs.location != rhs.location { return lhs.location < rhs.location }
            if lhs.length != rhs.length { return lhs.length > rhs.length }
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
    }

    private static func containsLineBreak(_ range: NSRange, in text: NSString) -> Bool {
        guard range.length > 0, range.location < text.length else { return false }
        let clamped = NSRange(location: range.location,
                              length: min(range.length, text.length - range.location))
        return text.range(of: "\n", options: [], range: clamped).location != NSNotFound
    }

    private static func activeBracketPairs(definition: LexerDefinition,
                                           configuration: FoldConfiguration) -> [LexerDefinition.BracketPair] {
        definition.brackets.filter { pair in
            guard !pair.open.isEmpty, !pair.close.isEmpty else { return false }
            if pair.open == "[" || pair.close == "]" {
                return configuration.foldsSquareBrackets
            }
            return true
        }
    }

    private static func braceFoldRanges(in text: NSString,
                                        pairs: [LexerDefinition.BracketPair],
                                        excluding excluded: [NSRange]) -> [FoldRange] {
        guard !pairs.isEmpty else { return [] }

        var folds: [FoldRange] = []
        var stack: [(pair: LexerDefinition.BracketPair, kind: FoldRange.Kind, location: Int)] = []
        var index = 0
        var excludedIndex = 0
        let length = text.length

        while index < length {
            // Skip comment text so delimiters inside comments are not matched.
            while excludedIndex < excluded.count, NSMaxRange(excluded[excludedIndex]) <= index {
                excludedIndex += 1
            }
            if excludedIndex < excluded.count {
                let span = excluded[excludedIndex]
                if span.location <= index, index < NSMaxRange(span) {
                    index = NSMaxRange(span)
                    continue
                }
            }

            var advanced = false
            for pair in pairs {
                if matches(pair.open, at: index, in: text) {
                    stack.append((pair, kind(for: pair), index))
                    index += pair.open.utf16.count
                    advanced = true
                    break
                }
                if matches(pair.close, at: index, in: text) {
                    if let top = stack.last, top.pair.close == pair.close {
                        stack.removeLast()
                        let end = index + pair.close.utf16.count
                        folds.append(FoldRange(location: top.location,
                                               length: end - top.location,
                                               kind: top.kind))
                    }
                    index += pair.close.utf16.count
                    advanced = true
                    break
                }
            }
            if !advanced {
                index += 1
            }
        }
        return folds
    }

    private static func kind(for pair: LexerDefinition.BracketPair) -> FoldRange.Kind {
        switch pair.open {
        case "{": return .braces
        case "(": return .parentheses
        default: return .brackets
        }
    }

    private static func matches(_ token: String, at index: Int, in text: NSString) -> Bool {
        let tokenLength = token.utf16.count
        guard tokenLength > 0,
              index + tokenLength <= text.length,
              text.character(at: index) == token.utf16.first else {
            return false
        }
        return text.substring(with: NSRange(location: index, length: tokenLength)) == token
    }

    private static func blockCommentSpans(in text: NSString,
                                          comments: LexerDefinition.CommentSyntax?) -> [NSRange] {
        guard let blockStart = comments?.blockStart,
              let blockEnd = comments?.blockEnd,
              !blockStart.isEmpty,
              !blockEnd.isEmpty else {
            return []
        }

        var spans: [NSRange] = []
        var searchLocation = 0
        let length = text.length
        while searchLocation < length {
            let startRange = text.range(of: blockStart,
                                        options: [],
                                        range: NSRange(location: searchLocation,
                                                       length: length - searchLocation))
            guard startRange.location != NSNotFound else { break }

            let contentStart = NSMaxRange(startRange)
            let endRange = text.range(of: blockEnd,
                                      options: [],
                                      range: NSRange(location: contentStart,
                                                     length: length - contentStart))
            guard endRange.location != NSNotFound else { break }

            spans.append(NSRange(location: startRange.location,
                                 length: NSMaxRange(endRange) - startRange.location))
            searchLocation = NSMaxRange(endRange)
        }
        return spans
    }

    private static func lineCommentSpans(in text: NSString,
                                         prefix: String?,
                                         excluding blockSpans: [NSRange]) -> [NSRange] {
        guard let prefix, !prefix.isEmpty else { return [] }

        var spans: [NSRange] = []
        let prefixLength = prefix.utf16.count
        let prefixFirstUnit = prefix.utf16.first
        let length = text.length
        var index = 0
        var blockIndex = 0

        while index < length {
            while blockIndex < blockSpans.count, NSMaxRange(blockSpans[blockIndex]) <= index {
                blockIndex += 1
            }
            if blockIndex < blockSpans.count {
                let block = blockSpans[blockIndex]
                if block.location <= index, index < NSMaxRange(block) {
                    index = NSMaxRange(block)
                    continue
                }
            }

            if text.character(at: index) == prefixFirstUnit,
               index + prefixLength <= length,
               text.substring(with: NSRange(location: index, length: prefixLength)) == prefix {
                let newline = text.range(of: "\n",
                                         options: [],
                                         range: NSRange(location: index,
                                                        length: length - index))
                let end = newline.location == NSNotFound ? length : newline.location
                spans.append(NSRange(location: index, length: end - index))
                index = end
            } else {
                index += 1
            }
        }
        return spans
    }

    private static func regionFoldRanges(in text: NSString,
                                         markers: [FoldRegionMarker]) -> [FoldRange] {
        guard !markers.isEmpty else { return [] }

        var folds: [FoldRange] = []
        var stack: [(markerIndex: Int, location: Int)] = []
        var lineStart = 0
        let length = text.length

        while lineStart <= length {
            let searchRange = NSRange(location: lineStart, length: length - lineStart)
            let newline = text.range(of: "\n", options: [], range: searchRange)
            let lineEnd = newline.location == NSNotFound ? length : newline.location
            let line = text.substring(with: NSRange(location: lineStart, length: lineEnd - lineStart))
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            var matchedStart = false
            for (markerIndex, marker) in markers.enumerated()
            where !marker.start.isEmpty && trimmed.hasPrefix(marker.start) {
                stack.append((markerIndex, lineStart))
                matchedStart = true
                break
            }

            if !matchedStart {
                for (markerIndex, marker) in markers.enumerated()
                where !marker.end.isEmpty && trimmed.hasPrefix(marker.end) {
                    if let openIndex = stack.lastIndex(where: { $0.markerIndex == markerIndex }) {
                        let start = stack[openIndex].location
                        stack.removeSubrange(openIndex...)
                        folds.append(FoldRange(location: start,
                                               length: lineEnd - start,
                                               kind: .region))
                    }
                    break
                }
            }

            if newline.location == NSNotFound { break }
            lineStart = NSMaxRange(newline)
        }
        return folds
    }

    private static func mergedSpans(_ spans: [NSRange]) -> [NSRange] {
        let sorted = spans.filter { $0.length > 0 }.sorted { lhs, rhs in
            if lhs.location != rhs.location { return lhs.location < rhs.location }
            return lhs.length > rhs.length
        }
        var result: [NSRange] = []
        for span in sorted {
            if let last = result.last, span.location <= NSMaxRange(last) {
                let start = min(last.location, span.location)
                let end = max(NSMaxRange(last), NSMaxRange(span))
                result[result.count - 1] = NSRange(location: start, length: end - start)
            } else {
                result.append(span)
            }
        }
        return result
    }
}
