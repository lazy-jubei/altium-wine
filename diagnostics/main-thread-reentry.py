from pathlib import Path
import argparse
import subprocess
import tempfile

# Compile Wine's actual helper with a native main queue and kqueue test fixture.
fixture = r"""
#import <Foundation/Foundation.h>
#include <sys/event.h>
#include <unistd.h>
#include <stdio.h>
#include <stdatomic.h>
typedef struct { void *event; } MacDrvEvent;
#define QUERY_EVENT 1
#define event_mask_for_type(t) (t)
NSString *WineEventQueueThreadDictionaryKey = @"wine-test-queue";
@interface WineEventQueue : NSObject {
@public int kq; void (*event_handler)(void *);
}
- (void)signalEventAvailable;
- (MacDrvEvent *)getEventMatchingMask:(unsigned int)mask;
@end
@implementation WineEventQueue
- (instancetype)init {
    if ((self = [super init])) {
        struct kevent event;
        kq = kqueue();
        EV_SET(&event, 1, EVFILT_USER, EV_ADD | EV_CLEAR, 0, 0, NULL);
        if (kevent(kq, &event, 1, NULL, 0, NULL) < 0) abort();
    }
    return self;
}
- (void)signalEventAvailable {
    struct kevent event;
    EV_SET(&event, 1, EVFILT_USER, 0, NOTE_TRIGGER, 0, NULL);
    if (kevent(kq, &event, 1, NULL, 0, NULL) < 0) abort();
}
- (MacDrvEvent *)getEventMatchingMask:(unsigned int)mask { return NULL; }
- (void)dealloc { close(kq); [super dealloc]; }
@end
void OnMainThreadAsync(dispatch_block_t block) {
    dispatch_async(dispatch_get_main_queue(), block);
}
/* WINE_FUNCTION */
static atomic_int done;
static int callbacks;
int main(void) {
@autoreleasepool {
    __block int inline_calls = 0;
    for (int i = 0; i < 100; i++) OnMainThread(^{
        if (![NSThread isMainThread]) abort();
        OnMainThread(^{ inline_calls++; });
    });
    if (inline_calls != 100) abort();
    for (int worker = 0; worker < 2; worker++) dispatch_async(
        dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @autoreleasepool {
            WineEventQueue *queue = worker ? [[WineEventQueue alloc] init] : nil;
            if (queue) [NSThread currentThread].threadDictionary[WineEventQueueThreadDictionaryKey] = queue;
            for (int i = 0; i < 100; i++) {
                __block BOOL completed = NO;
                OnMainThread(^{
                    if (![NSThread isMainThread]) abort();
                    OnMainThread(^{ callbacks++; completed = YES; });
                });
                if (!completed) abort();
            }
            [[NSThread currentThread].threadDictionary removeObjectForKey:WineEventQueueThreadDictionaryKey];
            [queue release];
            atomic_fetch_add(&done, 1);
        }
    });
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:4];
    while (atomic_load(&done) < 2 && deadline.timeIntervalSinceNow > 0)
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    if (atomic_load(&done) != 2 || callbacks != 200) abort();
    puts("PASS: main-thread reentry, nested callbacks, semaphore worker and kqueue worker (300 calls)");
}
return 0;
}
"""

def test(source, expect_timeout):
    text = source.read_text()
    start = text.index('void OnMainThread(dispatch_block_t block)')
    end = text.index('\n\n\n/', start)
    with tempfile.TemporaryDirectory() as temp:
        root = Path(temp)
        (root/'test.m').write_text(fixture.replace('/* WINE_FUNCTION */', text[start:end]))
        subprocess.run(['/usr/bin/clang', '-arch', 'x86_64', '-fblocks', '-O2', '-framework', 'Foundation', str(root/'test.m'), '-o', str(root/'test')], check=True)
        try:
            result = subprocess.run([str(root/'test')], timeout=5, check=True, capture_output=True, text=True)
        except subprocess.TimeoutExpired:
            if not expect_timeout: raise
            print('CONFIRMED: original Wine helper deadlocks on main-thread reentry')
        else:
            if expect_timeout: raise RuntimeError('Original bug was not reproduced')
            print(result.stdout.strip())

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description="Test Wine's OnMainThread helper on macOS with Rosetta.")
    parser.add_argument('source', type=Path, help='Patched dlls/winemac.drv/cocoa_event.m')
    parser.add_argument('--baseline', type=Path, help='Unpatched source to confirm the original deadlock')
    args = parser.parse_args()
    if args.baseline:
        test(args.baseline, True)
    test(args.source, False)
