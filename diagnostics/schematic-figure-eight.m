/* Reproduce schematic pan edge artifacts without editing the document. */
#import <AppKit/AppKit.h>
#include <ApplicationServices/ApplicationServices.h>
#include <math.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t interrupted;
static void stop(int sig) { interrupted = 1; }
static double now(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec * 1e-9;
}
static void post(CGEventSourceRef source, CGEventType type, double x, double y)
{
    CGEventRef event = CGEventCreateMouseEvent(source, type, CGPointMake(x, y), kCGMouseButtonRight);
    CGEventSetFlags(event, 0);
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}

int main(int argc, char **argv)
{
    @autoreleasepool
    {
        if (argc != 8)
        {
            fprintf(stderr, "usage: schematic-figure-eight WINDOW_ID X Y RADIUS_X RADIUS_Y PERIOD_SECONDS TOTAL_SECONDS\n");
            return 2;
        }
        CGWindowID window = (CGWindowID)strtoul(argv[1], NULL, 10);
        double x = atof(argv[2]), y = atof(argv[3]), rx = atof(argv[4]), ry = atof(argv[5]);
        double period = atof(argv[6]), seconds = atof(argv[7]);
        if (!isfinite(x) || !isfinite(y) || !isfinite(rx) || !isfinite(ry) ||
            !isfinite(period) || !isfinite(seconds) || rx <= 0 || ry <= 0 ||
            period < .5 || seconds <= 0 || seconds > 60) return 2;

        CFArrayRef info = CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow, window);
        if (!info || CFArrayGetCount(info) != 1)
        {
            if (info) CFRelease(info);
            fprintf(stderr, "The requested window is unavailable.\n");
            return 3;
        }
        NSDictionary *item = (NSDictionary *)CFArrayGetValueAtIndex(info, 0);
        pid_t pid = [item[(id)kCGWindowOwnerPID] intValue];
        NSString *title = item[(id)kCGWindowName];
        CGRect bounds;
        BOOL valid = CGRectMakeWithDictionaryRepresentation((CFDictionaryRef)item[(id)kCGWindowBounds], &bounds);
        valid = valid && [[title lowercaseString] containsString:@".schdoc"] &&
            [NSWorkspace sharedWorkspace].frontmostApplication.processIdentifier == pid &&
            CGRectContainsRect(CGRectInset(bounds, 12, 90), CGRectMake(x - rx, y - ry, rx * 2, ry * 2));
        CFRelease(info);
        if (!valid)
        {
            fprintf(stderr, "Bring the schematic to the front and keep the entire gesture inside its canvas.\n");
            return 3;
        }
        if (!AXIsProcessTrusted())
        {
            fprintf(stderr, "The terminal needs macOS Accessibility permission to post mouse events.\n");
            return 4;
        }
        signal(SIGINT, stop);
        signal(SIGTERM, stop);
        CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
        if (!source) return 5;
        post(source, kCGEventMouseMoved, x, y);
        usleep(100000);
        post(source, kCGEventRightMouseDown, x, y);
        usleep(150000);
        double start = now(), next = start;
        unsigned int events = 0;
        while (!interrupted && now() - start < seconds)
        {
            double phase = (now() - start) * 2 * M_PI / period;
            post(source, kCGEventRightMouseDragged, x + rx * sin(phase), y + ry * sin(2 * phase));
            ++events;
            next += 1.0 / 120.0;
            double delay = next - now();
            if (delay > 0) usleep((useconds_t)(delay * 1e6));
        }
        post(source, kCGEventRightMouseDragged, x, y);
        usleep(150000);
        post(source, kCGEventRightMouseUp, x, y);
        CFRelease(source);
        printf("figure-eight: %u drag events, %.2f seconds\n", events, now() - start);
        return interrupted ? 130 : 0;
    }
}
