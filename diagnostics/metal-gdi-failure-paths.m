/* Self-authored failure-path harness for the experimental readback layer.
 * No app input, Wine prefix or GPU submission. The Metal factory doubles
 * implement only the selectors exercised before submission fails. */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned buffer_allocs, buffer_frees, command_calls, commit_calls;
static BOOL fail_encoder, fail_pixels, fail_crop;

@interface ReadbackAllocators : NSObject
+ (NSData *)pixelsWithBytes:(const void *)bytes length:(NSUInteger)length;
+ (NSMutableData *)cropWithLength:(NSUInteger)length;
@end
@implementation ReadbackAllocators
+ (NSData *)pixelsWithBytes:(const void *)bytes length:(NSUInteger)length
{ return fail_pixels ? nil : [[NSData alloc] initWithBytes:bytes length:length]; }
+ (NSMutableData *)cropWithLength:(NSUInteger)length
{ return fail_crop ? nil : [[NSMutableData alloc] initWithLength:length]; }
@end
static void OnMainThreadAsync(void (^block)(void)) { block(); }

@interface WineMetalLayer : NSObject
@property(nonatomic, retain) id<MTLDevice> device;
- (instancetype)initWithLayer:(id)layer;
- (id<CAMetalDrawable>)nextDrawable;
@end
@implementation WineMetalLayer
@synthesize device;
- (instancetype)initWithLayer:(id)layer { return [self init]; }
- (id<CAMetalDrawable>)nextDrawable { return nil; }
- (void)dealloc { [device release]; [super dealloc]; }
@end

#include "gdi_readback.h"

@interface FailureBuffer : NSObject
- (void *)contents;
@end
@implementation FailureBuffer
- (instancetype)init { if ((self = [super init])) buffer_allocs++; return self; }
- (void *)contents { static unsigned char pixels[64*64*4]; memset(pixels, 0x5a, sizeof(pixels)); return pixels; }
- (void)dealloc { buffer_frees++; [super dealloc]; }
@end

@interface FailureCommand : NSObject
- (id<MTLBlitCommandEncoder>)blitCommandEncoder;
- (void)addCompletedHandler:(MTLCommandBufferHandler)block;
- (void)commit;
@end
@implementation FailureCommand
- (id<MTLBlitCommandEncoder>)blitCommandEncoder { return nil; }
/* A nil encoder must be handled before any completion registration or commit. */
- (void)addCompletedHandler:(MTLCommandBufferHandler)block {}
- (void)commit { commit_calls++; }
@end

@interface FailureQueue : NSObject
- (id<MTLCommandBuffer>)commandBuffer;
@end
@implementation FailureQueue
- (id<MTLCommandBuffer>)commandBuffer
{
    command_calls++;
    return fail_encoder ? (id)[[[FailureCommand alloc] init] autorelease] : nil;
}
@end

@interface FailureDevice : NSObject
- (id<MTLCommandQueue>)newCommandQueue;
- (id<MTLBuffer>)newBufferWithLength:(NSUInteger)length options:(MTLResourceOptions)options;
@end
@implementation FailureDevice
- (id<MTLCommandQueue>)newCommandQueue { return (id)[[FailureQueue alloc] init]; }
- (id<MTLBuffer>)newBufferWithLength:(NSUInteger)length options:(MTLResourceOptions)options
{ return (id)[[FailureBuffer alloc] init]; }
@end

@interface FailureTexture : NSObject
- (MTLPixelFormat)pixelFormat;
- (NSUInteger)width;
- (NSUInteger)height;
@end
@implementation FailureTexture
- (MTLPixelFormat)pixelFormat { return MTLPixelFormatBGRA8Unorm; }
- (NSUInteger)width { return 64; }
- (NSUInteger)height { return 64; }
@end

@interface CheckedLayer : WineGDIReadbackLayer
- (void)arm;
- (BOOL)gateIsClear;
- (uint64_t)serial;
@end
@implementation CheckedLayer
- (void)arm { readback_pending = YES; }
- (BOOL)gateIsClear
{
    if (pthread_mutex_trylock(&readback_lock)) return NO;
    BOOL clear = !readback_pending;
    pthread_mutex_unlock(&readback_lock);
    return clear;
}
- (uint64_t)serial { return readback_serial; }
@end

int main(int argc, const char **argv)
{
    if (argc != 2) return 2;
    @autoreleasepool
    {
        CheckedLayer *layer = [[CheckedLayer alloc] init];
        BOOL pass = YES;
        [layer setRequestedRect:CGRectMake(0, 0, 16, 16) ready:^{}];
        if (!strcmp(argv[1], "pixels") || !strcmp(argv[1], "crop"))
        {
            FailureBuffer *buffer = [[FailureBuffer alloc] init];
            CGRect rect = CGRectMake(0, 0, 16, 16);
            [layer arm];
            [layer finishReadbackBuffer:(id)buffer crop:rect bounds:rect serial:0 stride:256 status:MTLCommandBufferStatusCompleted];
            pass &= [layer serial] == 1 && [layer gateIsClear];
            if (!strcmp(argv[1], "pixels"))
            {
                fail_pixels = YES;
                [layer arm];
                [layer finishReadbackBuffer:(id)buffer crop:rect bounds:rect serial:0 stride:256 status:MTLCommandBufferStatusCompleted];
                pass &= [layer serial] == 1 && [layer gateIsClear];
                fail_pixels = NO;
            }
            else fail_crop = YES;
            uint64_t serial = 0;
            NSUInteger stride = 0;
            NSData *pixels = [layer copyPixelsForRect:&rect since:&serial stride:&stride];
            if (fail_crop)
            {
                pass &= !pixels && !serial && [layer gateIsClear];
                fail_crop = NO;
                pixels = [layer copyPixelsForRect:&rect since:&serial stride:&stride];
            }
            pass &= pixels && serial == 1 && stride == 64 && pixels.length == 1024;
            if (pixels) pass &= ((const unsigned char *)pixels.bytes)[0] == 0x5a;
            [pixels release];
            [buffer release];
        }
        else
        {
            if (strcmp(argv[1], "command") && strcmp(argv[1], "encoder")) return 2;
            fail_encoder = !strcmp(argv[1], "encoder");
            FailureDevice *device = [[FailureDevice alloc] init];
            layer.device = (id)device;
            [device release];
            FailureTexture *texture = [[FailureTexture alloc] init];
            NSObject *drawable = [[NSObject alloc] init];
            [layer recordPresentedTexture:(id)texture drawable:(id)drawable];
            [layer recordPresentedTexture:(id)texture drawable:(id)drawable];
            [layer stopReadback];
            pass &= command_calls == 2 && buffer_allocs == 2 && buffer_frees == 2 && drawable.retainCount == 1 && commit_calls == 0 && [layer gateIsClear];
            [texture release];
            [drawable release];
        }
        [layer release];
        printf("%s %s\n", argv[1], pass ? "PASS" : "FAIL");
        return !pass;
    }
}
