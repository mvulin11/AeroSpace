public struct FlipCountLayoutCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .flipCountLayout,
        help: flip_count_layout_help_generated,
        flags: [
            "--workspace": workspaceSubArgParser(),
        ],
        posArgs: [],
    )
}
