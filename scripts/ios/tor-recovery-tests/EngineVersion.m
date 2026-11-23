// Execute the actual pinned Tor engine through the production Objective-C wrapper.
// AddressSanitizer instruments TORThread.m's variable-length argv allocation.
#import <Foundation/Foundation.h>
#import "TORThread.h"

int main(void) {
    @autoreleasepool {
        TORThread *thread = [[TORThread alloc] initWithArguments:@[@"--version"]];
        [thread main];
    }
    return 0;
}
