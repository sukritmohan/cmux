#import "ghostty.h"

// Thin wrapper for ghostty_surface_set_output_observer because Swift's C importer
// cannot import functions with C function pointer typedef parameters directly.
static inline void cmux_surface_set_output_observer(
    ghostty_surface_t surface,
    void (*callback)(void* userdata, const uint8_t* data, size_t len),
    void* userdata
) {
    ghostty_surface_set_output_observer(surface, callback, userdata);
}
