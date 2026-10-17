import Foundation

// What the terminal shows of Claude Code's input line: whether text can go in without joining a
// draft someone left there.

/// One terminal cell, with the two attributes the input check reads.
public struct ScreenCell: Equatable, Sendable {
    public var character: Character
    /// Drawn faint (SGR 2). Claude Code draws its placeholder this way, and the next prompt it
    /// suggests after a turn takes the placeholder's place: shown in the input line, never typed.
    public var faint: Bool
    /// Drawn in inverse video (SGR 7), as Claude Code paints its own cursor.
    public var inverse: Bool

    public init(_ character: Character, faint: Bool = false, inverse: Bool = false) {
        self.character = character
        self.faint = faint
        self.inverse = inverse
    }
}

/// One terminal row, cell by cell.
public struct ScreenLine: Equatable, Sendable {
    public var cells: [ScreenCell]

    public init(cells: [ScreenCell]) {
        self.cells = cells
    }

    /// Plain text: no cell faint or inverse.
    public init(_ text: String) {
        cells = text.map { ScreenCell($0) }
    }

    public var text: String { String(cells.map(\.character)) }
}

public enum PromptScreen {
    private static let markers: [Character] = ["❯", ">"]
    private static let frame: Set<Character> = ["│", "|", "┃", " "]
    private static let rules: Set<Character> = ["─", "━", "╭", "┌"]

    /// Reads Claude Code's input line from the screen, bottom up: true when it is on screen with
    /// nothing typed in it, false when it holds text, nil when it is not found. The input line is
    /// the one that starts with the prompt mark right below a rule ("───" or the top of a box);
    /// sent prompts are echoed above with the same mark. Anything typed and not sent would go out
    /// together with what is pasted after it, so only a positive "empty" lets text in.
    public static func inputIsEmpty(_ lines: [ScreenLine]) -> Bool? {
        inputCells(lines).map(holdsNothingTyped)
    }

    /// What is typed in the input line: "" when nothing is, nil when the line is not found.
    public static func typedInput(_ lines: [ScreenLine]) -> String? {
        guard let cells = inputCells(lines) else { return nil }
        if holdsNothingTyped(cells) { return "" }
        return String(cells.filter { !$0.faint }.map(\.character)).trimmingCharacters(in: .whitespaces)
    }

    private static func inputCells(_ lines: [ScreenLine]) -> ArraySlice<ScreenCell>? {
        for index in lines.indices.reversed() where index > 0 {
            let above = lines[index - 1].cells.drop { $0.character == " " }
            guard let rule = above.first?.character, rules.contains(rule) else { continue }
            let start = lines[index].cells.drop { frame.contains($0.character) }
            guard let mark = start.first?.character, markers.contains(mark) else { continue }
            let rest = start.dropFirst()
            guard rest.isEmpty || rest.first?.character.isWhitespace == true else { continue }
            var content = rest.drop { $0.character.isWhitespace }
            while let last = content.last?.character, last.isWhitespace || frame.contains(last) { content.removeLast() }
            return content
        }
        return nil
    }

    /// The same, for text read without attributes.
    public static func inputIsEmpty(_ lines: [String]) -> Bool? {
        inputIsEmpty(lines.map(ScreenLine.init))
    }

    /// True when what follows the mark is only blanks or faint text: the placeholder, or the
    /// suggested next prompt. With Claude Code's drawn cursor on, that text's first character is
    /// painted inverse instead of faint; it is skipped only when faint text follows it, so a
    /// one-letter draft under the cursor still counts as typed.
    private static func holdsNothingTyped(_ cells: ArraySlice<ScreenCell>) -> Bool {
        var shown = cells
        if shown.first?.inverse == true,
           shown.dropFirst().contains(where: { $0.faint && !$0.character.isWhitespace }) {
            shown = shown.dropFirst()
        }
        return shown.allSatisfy { $0.faint || $0.character.isWhitespace }
    }
}
