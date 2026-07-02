#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// Thin shim over the private CGVirtualDisplay API (CoreGraphics). All contact
// with the private classes stays in CVDShim.m; Swift sees only these two
// functions. The classes are resolved with NSClassFromString at runtime, so
// nothing private is referenced at link time.

// Creates a virtual display with a single pixel mode. Returns the retained
// display object — keep it alive for as long as the display should exist;
// releasing it (or process exit — WindowServer reclaims virtual displays of
// dead owners) removes the display. Returns nil if the API is unavailable or
// the descriptor/settings were refused.
NSObject * _Nullable CVDCreate(NSString * _Nonnull name,
                               uint32_t widthPx, uint32_t heightPx, double hz,
                               CGSize sizeMm, BOOL hiDPI);

// The CGDirectDisplayID of a display returned by CVDCreate.
uint32_t CVDDisplayID(NSObject * _Nonnull display);
