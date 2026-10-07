import Foundation

/// Reads a screen captured with `tmux capture-pane -p -e` into rows of cells, with the two
/// attributes `PromptScreen.inputIsEmpty` looks at. tmux writes only the changes of attribute,
/// and a change can come at the end of one row and hold for the next, so the state carries
/// from row to row like on a terminal.
public enum ScreenParser {
    public static func lines(_ capture: String) -> [ScreenLine] {
        var parser = State()
        var rows: [ScreenLine] = []
        var scalars = capture.unicodeScalars[...]
        while let scalar = scalars.popFirst() {
            switch scalar {
            case "\u{1B}":
                parser.flush()
                parser.escape(&scalars)
            case "\n":
                parser.flush()
                rows.append(ScreenLine(cells: parser.cells))
                parser.cells = []
            case "\r":
                break
            default:
                parser.run.unicodeScalars.append(scalar)
            }
        }
        parser.flush()
        if !parser.cells.isEmpty { rows.append(ScreenLine(cells: parser.cells)) }
        return rows
    }

    private struct State {
        var faint = false
        var inverse = false
        var cells: [ScreenCell] = []
        /// Text with the current attributes, kept whole so a character made of several scalars stays one cell.
        var run = ""

        mutating func flush() {
            for character in run { cells.append(ScreenCell(character, faint: faint, inverse: inverse)) }
            run = ""
        }

        /// One escape sequence, after its ESC. Only SGR changes anything; the rest is skipped.
        mutating func escape(_ scalars: inout Substring.UnicodeScalarView.SubSequence) {
            guard let kind = scalars.popFirst() else { return }
            switch kind {
            case "[":
                var parameters = ""
                while let next = scalars.popFirst() {
                    if (0x40...0x7E).contains(next.value) {
                        if next == "m" { sgr(parameters) }
                        return
                    }
                    parameters.unicodeScalars.append(next)
                }
            case "]":
                // OSC (a hyperlink, a title): ends with BEL or ESC \.
                while let next = scalars.popFirst() {
                    if next == "\u{07}" { return }
                    if next == "\u{1B}" {
                        if scalars.first == "\\" { scalars.removeFirst() }
                        return
                    }
                }
            case "(", ")", "*", "+":
                // Character set: one more byte.
                _ = scalars.popFirst()
            default:
                break
            }
        }

        mutating func sgr(_ text: String) {
            // "38:5:246": colons carry the sub-parameters inside one code.
            let parts = text.split(separator: ";", omittingEmptySubsequences: false)
            let codes = parts.map { Int($0.split(separator: ":").first ?? "") ?? 0 }
            var index = 0
            while index < codes.count {
                switch codes[index] {
                case 0:
                    faint = false
                    inverse = false
                case 2: faint = true
                case 22: faint = false
                case 7: inverse = true
                case 27: inverse = false
                case 38, 48, 58:
                    // Colors: 5;n or 2;r;g;b follow and are not codes of their own.
                    if !parts[index].contains(":"), index + 1 < codes.count {
                        index += codes[index + 1] == 5 ? 2 : codes[index + 1] == 2 ? 4 : 0
                    }
                default: break
                }
                index += 1
            }
        }
    }
}
