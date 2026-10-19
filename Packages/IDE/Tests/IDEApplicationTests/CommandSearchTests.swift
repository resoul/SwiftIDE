import IDEApplication
import Testing

private func command(_ title: String, group: String = "Edit", enabled: Bool = true) -> PaletteCommand {
    PaletteCommand(id: "\(group)/\(title)", title: title, group: group, isEnabled: enabled)
}

private let sample = [
    command("Undo"),
    command("Duplicate Line"),
    command("Toggle Line Comment"),
    command("Jump to Definition"),
    command("Open Folder…", group: "File"),
    command("Save As…", group: "File")
]

@Test
func anEmptyQueryKeepsMenuOrderAndPutsUnavailableCommandsLast() {
    let commands = [command("A", enabled: false), command("B"), command("C")]
    #expect(CommandSearch.rank("  ", in: commands).map(\.title) == ["B", "C", "A"])
}

@Test
func lettersInOrderFindACommandAndTheBestMatchComesFirst() {
    #expect(CommandSearch.rank("dl", in: sample).map(\.title) == ["Duplicate Line"])
    #expect(CommandSearch.rank("line", in: sample).map(\.title) == ["Duplicate Line", "Toggle Line Comment"])
    #expect(CommandSearch.rank("jump", in: sample).first?.title == "Jump to Definition")
    #expect(CommandSearch.rank("xyz", in: sample).isEmpty)
}

@Test
func everyWordMustMatchAndTheGroupCountsToo() {
    #expect(CommandSearch.rank("file open", in: sample).map(\.title) == ["Open Folder…"])
    #expect(CommandSearch.rank("edit line", in: sample).map(\.title).contains("Toggle Line Comment"))
    #expect(!CommandSearch.rank("edit line", in: sample).map(\.title).contains("Save As…"))
}

@Test
func aStartOfTitleBeatsScatteredLettersAndAvailableBeatsUnavailable() {
    let commands = [command("Show Undo History"), command("Undo"), command("Undo", group: "Other", enabled: false)]
    #expect(CommandSearch.rank("undo", in: commands).map(\.group) == ["Edit", "Other", "Edit"])
    #expect(CommandSearch.rank("undo", in: commands).first?.title == "Undo")
}
