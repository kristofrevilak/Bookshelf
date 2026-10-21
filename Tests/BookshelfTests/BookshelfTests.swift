import Testing
@testable import Bookshelf

/// `Filter.storageKey` is what "remember the last filter across launches" round-trips through
/// `Preferences.lastFilter` — a typo here would silently fall back to `.all` on every relaunch.
@Test func filterStorageKeyRoundTrips() {
    let filters: [AppModel.Filter] = [
        .all, .onDevice, .notOnDevice, .needsConversion,
        .author("Ursula K. Le Guin"), .series("Earthsea"), .tag("sci-fi"),
        .author("Путь: джедая"),
    ]
    for filter in filters {
        #expect(AppModel.Filter(storageKey: filter.storageKey) == filter)
    }
}

@Test func filterStorageKeyRejectsGarbage() {
    #expect(AppModel.Filter(storageKey: "") == nil)
    #expect(AppModel.Filter(storageKey: "nonsense") == nil)
    #expect(AppModel.Filter(storageKey: "author") == nil)
    #expect(AppModel.Filter(storageKey: "bogus:Name") == nil)
}

/// The names in "the Kindle is still in use by …" — lsof's truncated command names mapped to
/// something a person recognises.
@Test func ejectNamesWhoHoldsTheKindle() {
    #expect(VolumeEjector.friendlyName("mds_stores").hasPrefix("Spotlight"))
    #expect(VolumeEjector.friendlyName("mdworker_shared").hasPrefix("Spotlight"))
    #expect(VolumeEjector.friendlyName("Claude Helper").hasPrefix("the Claude app"))
    #expect(VolumeEjector.friendlyName("com.apple.Virtualization.VirtualMachine").hasPrefix("the Claude app"))
    #expect(VolumeEjector.friendlyName("Finder").hasPrefix("Finder"))
    #expect(VolumeEjector.friendlyName("Preview") == "Preview")
}
