// Exercise the real, pinned TORController on macOS, with loopback-only peers.
// The unpatched binary must reproduce the three upstream lifecycle defects.
#import <Foundation/Foundation.h>
#import "TORController.h"
#import <dispatch/dispatch.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <unistd.h>
#import <fcntl.h>

static int failures = 0;
static void check(BOOL passed, NSString *name) {
    printf("%s: %s\n", passed ? "PASS" : "FAIL", name.UTF8String);
    if (!passed) ++failures;
}

static BOOL until(BOOL (^condition)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2];
    while (!condition() && deadline.timeIntervalSinceNow > 0)
        [NSThread sleepForTimeInterval:0.005];
    return condition();
}

static int endpoint(uint16_t *port, BOOL listening) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    NSCAssert(fd >= 0, @"fixture socket failed");
    struct sockaddr_in address = {0};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_len = sizeof(address);
    NSCAssert(bind(fd, (struct sockaddr *)&address, sizeof(address)) == 0, @"fixture bind failed");
    socklen_t length = sizeof(address);
    NSCAssert(getsockname(fd, (struct sockaddr *)&address, &length) == 0, @"fixture address failed");
    *port = ntohs(address.sin_port);
    if (listening) NSCAssert(listen(fd, 4) == 0, @"fixture listen failed");
    return fd;
}

static int descriptorCount(void) {
    int count = 0;
    for (int fd = 0; fd < 1024; ++fd) if (fcntl(fd, F_GETFD) >= 0) ++count;
    return count;
}

int main(void) {
    setbuf(stdout, NULL);
    alarm(45); // Bound blocked upstream system calls, not just assertions.
    @autoreleasepool {
        uint16_t port;
        int server;
        // Use a closed listener. A bound-but-not-listening TCP PCB can leave
        // connect() waiting for SYN retransmission on Darwin.
        printf("Testing refused connections\n");
        server = endpoint(&port, YES);
        close(server);
        int before = descriptorCount();
        for (int i = 0; i < 64; ++i) {
            @autoreleasepool {
                TORController *refused = [[TORController alloc] initWithSocketHost:@"127.0.0.1" port:port];
                NSCAssert(!refused.connected, @"fixture must refuse connections");
            }
        }
        int leaked = descriptorCount() - before;
        printf("Descriptors added by 64 refused connections: %d\n", leaked);
        check(leaked == 0, @"refused connections release their descriptors");

        printf("Testing controller release\n");
        server = endpoint(&port, YES);
        __weak TORController *released;
        int peer;
        @autoreleasepool {
            TORController *control = [[TORController alloc] initWithSocketHost:@"127.0.0.1" port:port];
            NSCAssert(control.connected, @"fixture connect failed");
            peer = accept(server, NULL, NULL);
            released = control;
            control = nil;
        }
        check(until(^BOOL { return released == nil; }), @"releasing controller closes channel without a retain cycle");
        close(peer);
        close(server);

        printf("Testing peer EOF\n");
        server = endpoint(&port, YES);
        TORController *control = [[TORController alloc] initWithSocketHost:@"127.0.0.1" port:port];
        NSCAssert(control.connected, @"fixture connect failed");
        peer = accept(server, NULL, NULL);
        close(peer);
        check(until(^BOOL { return !control.connected; }), @"peer EOF invalidates isConnected");
#if XAUXAT_PATCHED
        [control xauxatCloseControlSocket];
#endif
        control = nil;
        close(server);

#if XAUXAT_PATCHED
        printf("Testing explicit socket close\n");
        server = endpoint(&port, YES);
        control = [[TORController alloc] initWithSocketHost:@"127.0.0.1" port:port];
        NSCAssert(control.connected, @"fixture connect failed");
        peer = accept(server, NULL, NULL);
        [control xauxatCloseControlSocket];
        [control xauxatCloseControlSocket]; // repeat must not close another FD
        struct timeval readTimeout = {.tv_sec = 1};
        setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, &readTimeout, sizeof(readTimeout));
        char data[32];
        ssize_t received = recv(peer, data, sizeof(data), 0);
        check(received == 0 && !control.connected, @"socket-only close sends no SIGNAL SHUTDOWN and is idempotent");
        close(peer); close(server); control = nil;

        printf("Testing concurrent EOF and explicit close\n");
        server = endpoint(&port, YES);
        BOOL concurrentClose = YES;
        for (int i = 0; i < 64; ++i) {
            TORController *closing = [[TORController alloc] initWithSocketHost:@"127.0.0.1" port:port];
            if (!closing.connected) { concurrentClose = NO; break; }
            peer = accept(server, NULL, NULL);
            close(peer); // reader EOF races two foreground/deadline closes
            dispatch_group_t closes = dispatch_group_create();
            for (int j = 0; j < 2; ++j)
                dispatch_group_async(closes, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                    [closing xauxatCloseControlSocket];
                });
            if (dispatch_group_wait(closes, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) != 0 || closing.connected)
                concurrentClose = NO;
        }
        check(concurrentClose, @"64 concurrent EOF/timeout closes preserve subsequent connections");
        close(server);

        // A loopback peer answers immediately; read callbacks share the same
        // queue as registration, so replies cannot beat their observer.
        server = endpoint(&port, YES);
        printf("Testing immediate replies\n");
        dispatch_group_t responder = dispatch_group_create();
        dispatch_group_async(responder, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            int client = accept(server, NULL, NULL);
            char byte;
            int requests = 0;
            while (recv(client, &byte, 1, 0) == 1) {
                if (byte == '\n') {
                    send(client, "250 OK\r\n", 8, 0);
                    if (++requests == 100) break;
                }
            }
            close(client);
        });
        control = [[TORController alloc] initWithSocketHost:@"127.0.0.1" port:port];
        NSCAssert(control.connected, @"fixture connect failed");
        BOOL replies = YES;
        for (int i = 0; i < 100; ++i) {
            dispatch_semaphore_t reply = dispatch_semaphore_create(0);
            [control authenticateWithData:[NSData data] completion:^(BOOL ok, NSError *error) {
                if (ok) dispatch_semaphore_signal(reply);
            }];
            if (dispatch_semaphore_wait(reply, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) != 0) { replies = NO; break; }
        }
        [control xauxatCloseControlSocket];
        check(replies, @"100 immediate replies reach the installed observer");
        check(dispatch_group_wait(responder, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0, @"fixture responder stops after socket close");
        close(server); control = nil;
#endif

    }
#if XAUXAT_PATCHED
    return failures == 0 ? 0 : 1;
#else
    // Baseline is an expected failure, proving the real defects before patch.
    return failures == 3 ? 0 : 1;
#endif
}
