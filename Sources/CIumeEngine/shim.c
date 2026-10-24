// This target exists only to expose the Rust engine's C header to Swift.
// The implementation lives in crates/iume_engine and links in as a static
// library; there is deliberately no C code here beyond this umbrella include.
#include "iume_engine.h"
