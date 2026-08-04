/// The models this target's views observe live in `ElephruitFeaturesCore`, split out so the
/// iPhone app can share them without compiling a single AppKit view. Re-exported here so the
/// split is invisible inside this module and to the macOS app target: every file that said
/// `AppServices` or `NavigationModel` before the split still says exactly that.
@_exported import ElephruitFeaturesCore
