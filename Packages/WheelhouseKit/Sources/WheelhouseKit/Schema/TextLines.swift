import Foundation

extension String {
    /// The lines of the text, split on the UTF-16 unit 10 only. `split(separator: "\n")` does not split a CRLF pair, because Swift
    /// reads `\r\n` as one Character; a `\r` stays at the end of its line (the line shapes ignore it).
    var yamlLines: [Substring] {
        var out: [Substring] = []
        var start = startIndex
        var i = utf8.startIndex
        while i != utf8.endIndex {
            if utf8[i] == 10 {
                out.append(self[start..<i])
                start = utf8.index(after: i)
            }
            i = utf8.index(after: i)
        }
        out.append(self[start...])
        return out
    }
}
