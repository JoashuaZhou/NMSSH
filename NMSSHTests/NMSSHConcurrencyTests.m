#import <XCTest/XCTest.h>
#import <NMSSH/NMSSH.h>
#import <sys/socket.h>
#import <unistd.h>

@interface NMSSHSession (ConcurrencyTests)
@property (nonatomic, strong) dispatch_queue_t operationQueue;
@end

@interface NMSSHChannel (ConcurrencyTests)
- (BOOL)nmssh_allocateShell:(NSError **)error;
- (void)nmssh_startShellReader;
- (BOOL)openChannel:(NSError **)error;
- (dispatch_source_t)nmssh_newShellReadSourceForFileDescriptor:(int)fileDescriptor
                                                  eventHandler:(dispatch_block_t)eventHandler
                                                 cancelHandler:(dispatch_block_t)cancelHandler;
@end

extern void disconnect_callback(LIBSSH2_SESSION *session,
                                int reason,
                                const char *message,
                                int messageLength,
                                const char *language,
                                int languageLength,
                                void **abstract);

@interface NMSSHOrderingChannel : NMSSHChannel
@property (nonatomic, strong) NSMutableArray<NSString *> *events;
@property (nonatomic, assign) BOOL allocationSucceeds;
@end

@implementation NMSSHOrderingChannel

- (instancetype)initWithSession:(NMSSHSession *)session {
    self = [super initWithSession:session];
    if (self) {
        _events = [NSMutableArray array];
    }
    return self;
}

- (BOOL)openChannel:(NSError **)error {
    [self.events addObject:@"legacy-open"];
    return NO;
}

- (BOOL)nmssh_allocateShell:(NSError **)error {
    [self.events addObject:@"allocate"];
    return self.allocationSucceeds;
}

- (void)nmssh_startShellReader {
    [self.events addObject:@"reader"];
}

@end

@interface NMSSHDisconnectObserver : NSObject <NMSSHSessionDelegate>
@property (nonatomic, copy) void (^handler)(void);
@end

@implementation NMSSHDisconnectObserver

- (void)session:(NMSSHSession *)session didDisconnectWithError:(NSError *)error {
    if (self.handler) {
        self.handler();
    }
}

@end

@interface NMSSHBlockingDisconnectSession : NMSSHSession
@property (nonatomic, strong) XCTestExpectation *disconnectEntered;
@property (nonatomic, strong) dispatch_semaphore_t disconnectGate;
@end

@implementation NMSSHBlockingDisconnectSession

- (void)disconnect {
    [self.disconnectEntered fulfill];
    dispatch_semaphore_wait(self.disconnectGate, DISPATCH_TIME_FOREVER);
}

@end

@interface NMSSHCleanupRecordingSession : NMSSHSession
@property (nonatomic, copy) void (^cleanupHandler)(void);
@end

@implementation NMSSHCleanupRecordingSession

- (void)disconnect {
    if (self.cleanupHandler) {
        self.cleanupHandler();
    }
}

@end

@interface NMSSHConcurrencyTests : XCTestCase
@end

@implementation NMSSHConcurrencyTests

- (NMSSHSession *)newSession {
    return [[NMSSHSession alloc] initWithHost:@"127.0.0.1" port:22 andUsername:@"user"];
}

- (void)testStartShellStartsReaderAfterShellAllocationSucceeds {
    NMSSHOrderingChannel *channel = [[NMSSHOrderingChannel alloc] initWithSession:[self newSession]];
    channel.allocationSucceeds = YES;

    NSError *error = nil;
    XCTAssertTrue([channel startShell:&error]);
    XCTAssertNil(error);
    XCTAssertEqualObjects(channel.events, (@[@"allocate", @"reader"]));
}

- (void)testStartShellDoesNotStartReaderWhenShellAllocationFails {
    NMSSHOrderingChannel *channel = [[NMSSHOrderingChannel alloc] initWithSession:[self newSession]];
    channel.allocationSucceeds = NO;

    NSError *error = nil;
    XCTAssertFalse([channel startShell:&error]);
    XCTAssertEqualObjects(channel.events, (@[@"allocate"]));
}

- (void)testShellReadSourceRunsOnTheSessionOperationQueue {
    NMSSHSession *session = [self newSession];
    SEL operationQueueSetter = NSSelectorFromString(@"setOperationQueue:");
    XCTAssertTrue([session respondsToSelector:operationQueueSetter]);
    if (![session respondsToSelector:operationQueueSetter]) {
        return;
    }

    int sockets[2] = {-1, -1};
    XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets), 0);
    if (sockets[0] < 0 || sockets[1] < 0) {
        return;
    }

    static char queueKey;
    dispatch_queue_t queue = dispatch_queue_create("com.nmssh.tests.operation", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(queue, &queueKey, &queueKey, NULL);
    session.operationQueue = queue;

    NMSSHChannel *channel = session.channel;
    SEL sourceFactory = NSSelectorFromString(@"nmssh_newShellReadSourceForFileDescriptor:eventHandler:cancelHandler:");
    XCTAssertTrue([channel respondsToSelector:sourceFactory]);
    if (![channel respondsToSelector:sourceFactory]) {
        close(sockets[0]);
        close(sockets[1]);
        return;
    }

    XCTestExpectation *readExpectation = [self expectationWithDescription:@"read handler"];
    XCTestExpectation *cancelExpectation = [self expectationWithDescription:@"cancel handler"];
    __block BOOL usedOperationQueue = NO;
    int readSocket = sockets[0];
    dispatch_source_t source = [channel nmssh_newShellReadSourceForFileDescriptor:readSocket
                                                                     eventHandler:^{
        usedOperationQueue = dispatch_get_specific(&queueKey) == &queueKey;
        char byte;
        if (recv(readSocket, &byte, sizeof(byte), MSG_DONTWAIT) > 0) {
            [readExpectation fulfill];
        }
    }
                                                                    cancelHandler:^{
        close(readSocket);
        [cancelExpectation fulfill];
    }];

    dispatch_resume(source);
    char byte = 1;
    write(sockets[1], &byte, sizeof(byte));
    [self waitForExpectations:@[readExpectation] timeout:3.0];
    dispatch_source_cancel(source);
    [self waitForExpectations:@[cancelExpectation] timeout:3.0];
    close(sockets[1]);

    XCTAssertTrue(usedOperationQueue);
}

- (void)testShellReaderDrainsBufferedDataWithoutASocketEvent {
    NMSSHSession *session = [self newSession];
    static char queueKey;
    dispatch_queue_t queue = dispatch_queue_create("com.nmssh.tests.buffered-prompt", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(queue, &queueKey, &queueKey, NULL);
    session.operationQueue = queue;

    int sockets[2];
    int result = socketpair(AF_UNIX, SOCK_STREAM, 0, sockets);
    XCTAssertEqual(result, 0);
    if (result != 0) {
        return;
    }

    int readSocket = sockets[0];
    XCTestExpectation *initialRead = [self expectationWithDescription:@"read without socket bytes"];
    XCTestExpectation *cancelled = [self expectationWithDescription:@"reader cancelled"];
    __block BOOL startupReturned = NO;
    __block NSUInteger readCount = 0;
    __block dispatch_source_t source;
    dispatch_sync(queue, ^{
        source = [session.channel nmssh_newShellReadSourceForFileDescriptor:readSocket
                                                             eventHandler:^{
            XCTAssertEqual(dispatch_get_specific(&queueKey), &queueKey);
            XCTAssertTrue(startupReturned);
            readCount += 1;
            [initialRead fulfill];
        } cancelHandler:^{
            [cancelled fulfill];
        }];
        dispatch_resume(source);
        startupReturned = YES;
    });

    // Keep the peer open and never write to it: only registration can trigger a read.
    [self waitForExpectations:@[initialRead] timeout:3.0];
    dispatch_source_cancel(source);
    [self waitForExpectations:@[cancelled] timeout:3.0];
    XCTAssertEqual(readCount, 1u);
    close(sockets[0]);
    close(sockets[1]);
}

- (void)testCancelledShellReaderDoesNotDrainAfterTeardown {
    NMSSHSession *session = [self newSession];
    dispatch_queue_t queue = dispatch_queue_create("com.nmssh.tests.cancelled-reader", DISPATCH_QUEUE_SERIAL);
    session.operationQueue = queue;
    int sockets[2];
    int result = socketpair(AF_UNIX, SOCK_STREAM, 0, sockets);
    XCTAssertEqual(result, 0);
    if (result != 0) {
        return;
    }

    int readSocket = sockets[0];
    __block NSUInteger readCount = 0;
    XCTestExpectation *cancelled = [self expectationWithDescription:@"reader cancelled before registration"];
    dispatch_sync(queue, ^{
        dispatch_source_t source = [session.channel nmssh_newShellReadSourceForFileDescriptor:readSocket
                                                                                eventHandler:^{
            readCount += 1;
        } cancelHandler:^{
            [cancelled fulfill];
        }];
        dispatch_resume(source);
        dispatch_source_cancel(source);
    });

    [self waitForExpectations:@[cancelled] timeout:3.0];
    XCTAssertEqual(readCount, 0u);
    close(sockets[0]);
    close(sockets[1]);
}

- (void)testDisconnectCallbackDefersTeardownToTheSessionOperationQueue {
    NMSSHSession *session = [self newSession];
    SEL operationQueueSetter = NSSelectorFromString(@"setOperationQueue:");
    XCTAssertTrue([session respondsToSelector:operationQueueSetter]);
    if (![session respondsToSelector:operationQueueSetter]) {
        return;
    }

    static char queueKey;
    dispatch_queue_t queue = dispatch_queue_create("com.nmssh.tests.disconnect", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(queue, &queueKey, &queueKey, NULL);
    session.operationQueue = queue;

    XCTestExpectation *expectation = [self expectationWithDescription:@"disconnect callback"];
    __block BOOL callbackReturned = NO;
    __block BOOL observedAfterReturn = NO;
    __block BOOL usedOperationQueue = NO;
    NMSSHDisconnectObserver *observer = [NMSSHDisconnectObserver new];
    observer.handler = ^{
        observedAfterReturn = callbackReturned;
        usedOperationQueue = dispatch_get_specific(&queueKey) == &queueKey;
        [expectation fulfill];
    };
    session.delegate = observer;

    dispatch_sync(queue, ^{
        void *abstract = (__bridge void *)session;
        disconnect_callback(NULL, 11, "remote closed", 13, NULL, 0, &abstract);
        callbackReturned = YES;
    });

    [self waitForExpectations:@[expectation] timeout:3.0];
    XCTAssertTrue(observedAfterReturn);
    XCTAssertTrue(usedOperationQueue);
}

- (void)testDuplicateDisconnectCallbacksScheduleOneTeardown {
    NMSSHSession *session = [self newSession];
    dispatch_queue_t queue = dispatch_queue_create("com.nmssh.tests.duplicate-disconnect", DISPATCH_QUEUE_SERIAL);
    session.operationQueue = queue;

    __block NSUInteger callbackCount = 0;
    NMSSHDisconnectObserver *observer = [NMSSHDisconnectObserver new];
    observer.handler = ^{
        callbackCount += 1;
    };
    session.delegate = observer;

    void *abstract = (__bridge void *)session;
    disconnect_callback(NULL, 11, "remote closed", 13, NULL, 0, &abstract);
    disconnect_callback(NULL, 11, "remote closed", 13, NULL, 0, &abstract);

    XCTestExpectation *queueDrained = [self expectationWithDescription:@"operation queue drained"];
    dispatch_async(queue, ^{
        [queueDrained fulfill];
    });
    [self waitForExpectations:@[queueDrained] timeout:3.0];

    XCTAssertEqual(callbackCount, 1u);
}

- (void)testRemoteDisconnectWaitsForCallerFailureCleanup {
    NMSSHCleanupRecordingSession *session = [[NMSSHCleanupRecordingSession alloc]
                                            initWithHost:@"127.0.0.1" port:22 andUsername:@"user"];
    static char queueKey;
    dispatch_queue_t queue = dispatch_queue_create("com.nmssh.tests.auth-failure", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(queue, &queueKey, &queueKey, NULL);
    session.operationQueue = queue;

    __block BOOL callerFinished = NO;
    NSMutableArray<NSNumber *> *cleanupOrder = [NSMutableArray array];
    session.cleanupHandler = ^{
        XCTAssertEqual(dispatch_get_specific(&queueKey), &queueKey);
        [cleanupOrder addObject:@(callerFinished)];
    };

    dispatch_sync(queue, ^{
        void *abstract = (__bridge void *)session;
        disconnect_callback(NULL, 11, "remote closed", 13, NULL, 0, &abstract);
        // Authentication returned failure, and the caller immediately cleans up.
        [session disconnect];
        callerFinished = YES;
    });
    dispatch_sync(queue, ^{
        XCTAssertEqualObjects(cleanupOrder, (@[@NO, @YES]));
        session.cleanupHandler = nil;
    });
}

- (void)testStaleDisconnectCallbackDoesNotTearDownAnotherSession {
    NMSSHSession *session = [self newSession];
    dispatch_queue_t queue = dispatch_queue_create("com.nmssh.tests.stale-disconnect", DISPATCH_QUEUE_SERIAL);
    session.operationQueue = queue;

    dispatch_semaphore_t gate = dispatch_semaphore_create(0);
    dispatch_async(queue, ^{
        dispatch_semaphore_wait(gate, DISPATCH_TIME_FOREVER);
    });

    __block NSUInteger callbackCount = 0;
    NMSSHDisconnectObserver *observer = [NMSSHDisconnectObserver new];
    observer.handler = ^{
        callbackCount += 1;
    };
    session.delegate = observer;

    void *abstract = (__bridge void *)session;
    disconnect_callback((LIBSSH2_SESSION *)0x1, 11, "remote closed", 13, NULL, 0, &abstract);

    XCTestExpectation *queueDrained = [self expectationWithDescription:@"operation queue drained"];
    dispatch_async(queue, ^{
        [queueDrained fulfill];
    });
    dispatch_semaphore_signal(gate);
    [self waitForExpectations:@[queueDrained] timeout:3.0];

    XCTAssertEqual(callbackCount, 0u);
}

- (void)testDeferredDisconnectDoesNotHoldTheSessionMonitorDuringTeardown {
    NMSSHBlockingDisconnectSession *session = [[NMSSHBlockingDisconnectSession alloc]
                                                initWithHost:@"127.0.0.1"
                                                port:22
                                                andUsername:@"user"];
    session.operationQueue = dispatch_queue_create("com.nmssh.tests.blocking-disconnect", DISPATCH_QUEUE_SERIAL);
    session.disconnectEntered = [self expectationWithDescription:@"disconnect entered"];
    session.disconnectGate = dispatch_semaphore_create(0);

    void *abstract = (__bridge void *)session;
    disconnect_callback(NULL, 11, "remote closed", 13, NULL, 0, &abstract);
    [self waitForExpectations:@[session.disconnectEntered] timeout:3.0];

    dispatch_semaphore_t monitorAcquired = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @synchronized (session) {
            dispatch_semaphore_signal(monitorAcquired);
        }
    });

    long result = dispatch_semaphore_wait(monitorAcquired,
                                          dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)));
    dispatch_semaphore_signal(session.disconnectGate);
    if (result != 0) {
        dispatch_semaphore_wait(monitorAcquired,
                                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)));
    }

    XCTAssertEqual(result, 0);
}

@end
