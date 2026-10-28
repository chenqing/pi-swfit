// Port of packages/agent/test/utils/wait-for-tick.ts

/// `setTimeout(resolve, 0)`
func waitForTick() async {
    try? await Task.sleep(nanoseconds: 0)
    await Task.yield()
}
