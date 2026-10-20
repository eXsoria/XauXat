#!/usr/bin/env python3
"""Bounded socket-lifecycle fix for Tor.framework 409.11.2 (Core, app and NSE).

Upstream: iCepa/Tor.framework commit 727f628a15dd1bd83e0e171deb0aba7ab18be09e.
Never call disconnect(): that API sends SIGNAL SHUTDOWN to the Tor runtime.
"""
import hashlib
from pathlib import Path
import sys


def replace_once(source, before, after):
    assert source.count(before) == 1, 'Pinned Tor controller layout changed; review patch'
    return source.replace(before, after, 1)


def implementation(source):
    source = replace_once(source, '#import <arpa/inet.h>', '#import <arpa/inet.h>\n#import <unistd.h>\n#import <errno.h>')
    source = replace_once(source, '    int sock;\n', '    int sock;\n    NSUInteger _xauxatSocketGeneration;\n    NSInteger _xauxatLastSocketError;\n')
    source = replace_once(source, '''    if (_channel)
        dispatch_io_close(_channel, DISPATCH_IO_STOP);
}''', '''    if (_channel)
        dispatch_io_close(_channel, DISPATCH_IO_STOP);
    else if (sock >= 0)
        close(sock);
}''')
    source = replace_once(source, '- (BOOL)connect:(out NSError **)error {', '''// Socket-only close: never sends a Tor command and is safe after EOF/timeout.
- (void)xauxatCloseControlSocket {
    dispatch_io_t channel = _channel;
    int descriptor = sock;
    _channel = nil;
    sock = -1;
    ++_xauxatSocketGeneration;
    if (channel) {
        if (descriptor >= 0) shutdown(descriptor, SHUT_RDWR);
        dispatch_io_close(channel, DISPATCH_IO_STOP);
    } else if (descriptor >= 0) {
        close(descriptor);
    }
    dispatch_async([self.class controlQueue], ^{
        [self->_blocks removeAllObjects];
    });
}

- (NSInteger)xauxatLastSocketError { return _xauxatLastSocketError; }

- (BOOL)connect:(out NSError **)error {''')
    source = replace_once(source, '    self->sock = -1;\n', '    self->sock = -1;\n    _xauxatLastSocketError = 0;\n')
    # Every early socket/connect failure must release its descriptor and retain
    # errno before close() can overwrite it. Same code serves TCP and AF_UNIX.
    old = '''            if (error)
            {
                *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
            }

            return NO;'''
    new = '''            int savedError = errno;
            _xauxatLastSocketError = savedError;
            if (self->sock >= 0) close(self->sock);
            self->sock = -1;
            if (error)
            {
                *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:savedError userInfo:nil];
            }

            return NO;'''
    assert source.count(old) == 3, 'Pinned socket failure paths changed'
    source = source.replace(old, new)
    source = replace_once(source, '''    _channel = dispatch_io_create(DISPATCH_IO_STREAM, self->sock, [self.class controlQueue], ^(int __unused error) {
        close(self->sock);
        
        TORController *strongSelf = weakSelf;
        if (strongSelf)
        {
            strongSelf->_channel = nil;
        }
    });''', '''    // Capture the descriptor by value. Capturing self->sock here creates a
    // self/channel retain cycle, so releasing a stale controller never closes it.
    int descriptor = self->sock;
    NSUInteger generation = ++_xauxatSocketGeneration;
    _channel = dispatch_io_create(DISPATCH_IO_STREAM, descriptor, [self.class controlQueue], ^(int __unused error) {
        close(descriptor);
        TORController *strongSelf = weakSelf;
        if (strongSelf && strongSelf->_xauxatSocketGeneration == generation)
        {
            strongSelf->_channel = nil;
            strongSelf->sock = -1;
        }
    });''')
    source = replace_once(source, '''    if (!_channel)
    {
        return NO;
    }''', '''    if (!_channel)
    {
        _xauxatLastSocketError = errno;
        if (sock >= 0) close(sock);
        sock = -1;
        return NO;
    }''')
    source = replace_once(source, '''dispatch_io_read(_channel, 0, SIZE_MAX, [self.class controlQueue], ^(bool __unused done, dispatch_data_t data, int __unused error) {
        [buffer appendData:(NSData *)data];''', '''dispatch_io_read(_channel, 0, SIZE_MAX, [self.class controlQueue], ^(bool done, dispatch_data_t data, int error) {
        // EOF/errors invalidate isConnected; the original reader ignored both.
        if (error || !data || dispatch_data_get_size(data) == 0) {
            if (done || error) {
                TORController *strongSelf = weakSelf;
                if (strongSelf && strongSelf->_xauxatSocketGeneration == generation)
                    [strongSelf xauxatCloseControlSocket];
            }
            return;
        }
        [buffer appendData:(NSData *)data];''')
    # Register before write on the same queue as reads; localhost can reply
    # before the write-completion callback installs the upstream observer.
    source = replace_once(source, '''    dispatch_io_write(_channel, 0, dispatchData, [self.class controlQueue], ^(bool done, dispatch_data_t __unused data, int error) {
        if (done && !error && observer) {
            [self->_blocks insertObject:observer atIndex:0];
        }
    });''', '''    dispatch_async([self.class controlQueue], ^{
        if (!self->_channel) return;
        if (observer) [self->_blocks insertObject:observer atIndex:0];
        dispatch_io_write(self->_channel, 0, dispatchData, [self.class controlQueue], ^(bool __unused done, dispatch_data_t __unused data, int error) {
            if (error) [self xauxatCloseControlSocket];
        });
    });''')
    return source


def header(source):
    return replace_once(source, '- (void)disconnect;', '''- (void)disconnect;
// XauXat: release only this local control socket; keep embedded Tor running.
- (void)xauxatCloseControlSocket;
@property (nonatomic, readonly) NSInteger xauxatLastSocketError;''')


def patch(directory):
    # Hashes cover normalized upstream text; patched hashes are verified too,
    # so repeated pod installs cannot silently accept a partial/altered patch.
    entries = [
        ('TORController.m', 'c49aea0df45981b0b09f3bac7cc35a5b43d5b872daaa0581846d0693bfd2cbdc', '49f1d23144f2b86a562a0919d1237caa1d08fd4a389a7521834985756f7846f3', implementation),
        ('TORController.h', '0524b978c1ebbc70a96eea3c0f0e750a6356ecc2b76ba82644901f08c9606a5c', '600ac91a0538d9dd695147df6264cd3207eab5faab4c160e782d74028403e15a', header),
    ]
    pending = []
    for name, original, patched, transform in entries:
        path = directory / name
        source = path.read_text(encoding='utf-8')
        digest = hashlib.sha256(source.encode()).hexdigest()
        if digest == patched:
            continue
        assert digest == original, f'{name} differs from pinned Tor 409.11.2; review before patching'
        result = transform(source)
        assert hashlib.sha256(result.encode()).hexdigest() == patched
        pending.append((path, result))
    for path, source in pending:
        path.chmod(0o644)
        path.write_bytes(source.encode())


if __name__ == '__main__':
    patch(Path(sys.argv[1]))
