import PiCLI
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@main struct PFMain {
    static func main() async { exit(await PFCLI.run(Array(CommandLine.arguments.dropFirst()))) }
}
