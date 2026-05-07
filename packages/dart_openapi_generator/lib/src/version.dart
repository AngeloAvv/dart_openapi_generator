/// Hardcoded generator version included in every cache key.
///
/// Bump this constant on every published release so that a version upgrade
/// always invalidates prior cache entries. Kept in a dedicated file to make
/// it easy to locate and bump.
const String kGeneratorVersion = '0.1.0';
