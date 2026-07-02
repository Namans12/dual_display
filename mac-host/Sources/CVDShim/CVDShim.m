#import "CVDShim.h"

// Private CoreGraphics interfaces, declared locally so the compiler can type
// the message sends. Instantiated via NSClassFromString — the class symbols
// are not exported, so a direct reference would fail to link.

@interface CGVirtualDisplayDescriptor : NSObject
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, copy) NSString *name;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) unsigned int maxPixelsWide;
@property(nonatomic) unsigned int maxPixelsHigh;
@property(nonatomic) CGPoint redPrimary;
@property(nonatomic) CGPoint greenPrimary;
@property(nonatomic) CGPoint bluePrimary;
@property(nonatomic) CGPoint whitePoint;
@property(nonatomic) unsigned int serialNum;
@property(nonatomic) unsigned int productID;
@property(nonatomic) unsigned int vendorID;
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width
                       height:(unsigned int)height
                  refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property(nonatomic, strong) NSArray *modes;
@property(nonatomic) unsigned int hiDPI;
@end

@interface CGVirtualDisplay : NSObject
@property(nonatomic, readonly) uint32_t displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

NSObject *CVDCreate(NSString *name, uint32_t widthPx, uint32_t heightPx,
                    double hz, CGSize sizeMm, BOOL hiDPI) {
    Class descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
    Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
    Class displayClass = NSClassFromString(@"CGVirtualDisplay");
    if (!descriptorClass || !modeClass || !settingsClass || !displayClass) {
        return nil;
    }

    CGVirtualDisplayDescriptor *descriptor = [[descriptorClass alloc] init];
    descriptor.name = name;
    descriptor.maxPixelsWide = widthPx;
    descriptor.maxPixelsHigh = heightPx;
    descriptor.sizeInMillimeters = sizeMm;
    descriptor.productID = 0x4544;  // 'ED'
    descriptor.vendorID = 0x3456;
    descriptor.serialNum = 0x0001;
    descriptor.queue = dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0);
    // sRGB primaries; some macOS builds reject a descriptor without them.
    descriptor.redPrimary = CGPointMake(0.64, 0.33);
    descriptor.greenPrimary = CGPointMake(0.30, 0.60);
    descriptor.bluePrimary = CGPointMake(0.15, 0.06);
    descriptor.whitePoint = CGPointMake(0.3127, 0.3290);

    CGVirtualDisplay *display = [[displayClass alloc] initWithDescriptor:descriptor];
    if (!display) {
        return nil;
    }

    CGVirtualDisplaySettings *settings = [[settingsClass alloc] init];
    // HiDPI recipe (verified on macOS 26): declare BOTH the full pixel mode and
    // its half — with hiDPI set, WindowServer pairs them into a Retina mode
    // (points = half, framebuffer = full pixels) and makes it the default.
    // Declaring only the full mode yields a 1x-only mode list.
    settings.hiDPI = hiDPI ? 2 : 0;
    NSMutableArray *modes = [NSMutableArray array];
    [modes addObject:[[modeClass alloc] initWithWidth:widthPx
                                               height:heightPx
                                          refreshRate:hz]];
    if (hiDPI) {
        [modes addObject:[[modeClass alloc] initWithWidth:widthPx / 2
                                                   height:heightPx / 2
                                              refreshRate:hz]];
    }
    settings.modes = modes;
    if (![display applySettings:settings]) {
        return nil;
    }
    return (NSObject *)display;
}

uint32_t CVDDisplayID(NSObject *display) {
    return ((CGVirtualDisplay *)display).displayID;
}
