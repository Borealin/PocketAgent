// Host side of the embedded iSH kernel: rootfs import, boot, and the iOS
// callbacks the kernel libraries expect. No PTY or terminal UI is attached;
// scripts run through pocket_run_process (Native/ish/patches/0005).
#import "PocketISH.h"
#import <CommonCrypto/CommonDigest.h>
#import <UIKit/UIKit.h>
#include <arpa/inet.h>
#include <errno.h>
#include <os/log.h>
#include <sqlite3.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include "LinuxInterop.h"
#include "tools/fakefs.h"

static NSString *PocketISHRootPath;
static NSString *PocketISHBootError;
static BOOL PocketISHBooted;
static NSLock *PocketISHBootLock;
static os_log_t PocketISHLog;
static atomic_bool PocketISHStalled;
static char PocketISHPanic[256];

// The kernel can no longer be trusted (a bound expired or it panicked):
// every later call fails at once and no hostfs operation reaches the host,
// even from guest threads that are still running. No in-process restart.
// Also called from inside panic(): hostfs holds its root lock only in pure
// host code that cannot panic, so taking the write lock here cannot deadlock.
static void PocketISHPoison(void) {
    atomic_store(&PocketISHStalled, true);
    pocket_hostfs_set_root(NULL);
}

// Runs `work` in a Linux work item and waits at most `seconds` (less if the
// kernel is poisoned meanwhile). The block owns everything it uses (the
// callers' copied strings are freed inside it), so a caller that gives up can
// return while the item still runs later.
static int PocketISHWork(int64_t seconds, int (^work)(void)) {
    if (atomic_load(&PocketISHStalled)) return -ETIMEDOUT;
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    __block int result = 0;
    async_do_in_workqueue(^{
        result = work();
        dispatch_semaphore_signal(finished);
    });
    for (int64_t waited = 0; dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2)) != 0;) {
        if (atomic_load(&PocketISHStalled)) return -ETIMEDOUT;
        if (++waited == seconds * 2) {
            PocketISHPoison();
            os_log_fault(PocketISHLog, "iSH work item did not finish within %lld s", seconds);
            return -ETIMEDOUT;
        }
    }
    return result;
}

static NSString *PocketISHDigest(NSString *path) {
    NSInputStream *stream = [NSInputStream inputStreamWithFileAtPath:path];
    [stream open];
    if (stream.streamStatus != NSStreamStatusOpen) return nil;
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    uint8_t *buffer = malloc(1 << 20);
    NSInteger count;
    while ((count = [stream read:buffer maxLength:1 << 20]) > 0) CC_SHA256_Update(&context, buffer, (CC_LONG)count);
    free(buffer);
    [stream close];
    if (count < 0) return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &context);
    NSMutableString *text = [NSMutableString string];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [text appendFormat:@"%02x", digest[i]];
    return text;
}

// The kernel can only mount an import whose root entry is a directory, and
// boots only with an init. An archive without a root entry once produced a
// root without a file type: EIO at mount, no init, kernel panic.
static BOOL PocketISHRootUsable(NSString *root) {
    // fakefs stores links as regular files, so this checks the entry only.
    if (![NSFileManager.defaultManager fileExistsAtPath:[root stringByAppendingPathComponent:@"data/sbin/init"]]) return NO;
    sqlite3 *db = NULL;
    sqlite3_stmt *statement = NULL;
    BOOL directory = NO;
    NSString *meta = [root stringByAppendingPathComponent:@"meta.db"];
    if (sqlite3_open_v2(meta.fileSystemRepresentation, &db, SQLITE_OPEN_READONLY, NULL) == SQLITE_OK &&
        sqlite3_prepare_v2(db, "select stat from stats natural join paths where path = x''", -1, &statement, NULL) == SQLITE_OK &&
        sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_bytes(statement, 0) >= (int)sizeof(uint32_t)) {
        uint32_t mode;
        memcpy(&mode, sqlite3_column_blob(statement, 0), sizeof mode);
        directory = S_ISDIR(mode);
    }
    sqlite3_finalize(statement);
    sqlite3_close(db);
    return directory;
}

static BOOL PocketISHPrepareRoot(NSString *archive, NSString *runtime, NSString **error) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *root = [runtime stringByAppendingPathComponent:@"rootfs"];
    NSString *stamp = [runtime stringByAppendingPathComponent:@"rootfs.imported"];
    NSString *expected = PocketISHDigest(archive);
    if (expected == nil) {
        *error = @"rootfs archive unreadable";
        return NO;
    }
    NSString *current = [NSString stringWithContentsOfFile:stamp encoding:NSUTF8StringEncoding error:nil];
    PocketISHRootPath = root;
    if ([files fileExistsAtPath:root] && [current isEqualToString:expected] && PocketISHRootUsable(root)) return YES;
    // A partial or outdated import is replaced; guest-only files outside the
    // project (for example pip --user packages) are runtime cache.
    NSString *staging = [runtime stringByAppendingPathComponent:@"rootfs.importing"];
    [files removeItemAtPath:staging error:nil];
    [files createDirectoryAtPath:runtime withIntermediateDirectories:YES attributes:nil error:nil];
    struct fakefsify_error failure = {0};
    if (!fakefs_import(archive.fileSystemRepresentation, staging.fileSystemRepresentation, &failure, (struct progress){0})) {
        *error = failure.message ? [NSString stringWithFormat:@"rootfs import failed: %s", failure.message]
                                 : @"rootfs import failed";
        free(failure.message);
        return NO;
    }
    if (!PocketISHRootUsable(staging)) {
        *error = @"rootfs import has no directory root or no /sbin/init";
        return NO;
    }
    [files removeItemAtPath:root error:nil];
    NSError *moveError = nil;
    if (![files moveItemAtPath:staging toPath:root error:&moveError]) {
        *error = moveError.localizedDescription;
        return NO;
    }
    [expected writeToFile:stamp atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return YES;
}

BOOL PocketISHBoot(NSString *archivePath, NSString *runtimeDirectory, NSString **error) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        PocketISHBootLock = [NSLock new];
        PocketISHLog = os_log_create("io.github.borealin.PocketAgent", "ish");
    });
    [PocketISHBootLock lock];
    if (!PocketISHBooted && PocketISHBootError == nil) {
        NSString *failure = nil;
        if (PocketISHPrepareRoot(archivePath, runtimeDirectory, &failure)) {
            // No hostfs access is possible until a project is mounted.
            pocket_hostfs_set_root(NULL);
            // Bounded (patch 0005), and a panic ends the wait early. A boot
            // that has not started may still be running on its own static
            // stack, so the runtime is poisoned and never used in this process.
            if (actuate_kernel_bounded("earlyprintk", 60) != 0) {
                PocketISHPoison();
                os_log_fault(PocketISHLog, "iSH kernel did not start within 60 s");
                PocketISHBootError = PocketISHPanic[0] ? [NSString stringWithFormat:@"iSH kernel panic: %s", PocketISHPanic]
                                                       : @"iSH kernel did not start within 60 s";
            } else {
                // uts_sem may sleep: the hostname is set from a kernel work item.
                int named = PocketISHWork(30, ^int {
                    linux_sethostname("pocketagent");
                    return 0;
                });
                if (named == 0 && !atomic_load(&PocketISHStalled)) {
                    PocketISHBooted = YES;
                } else {
                    PocketISHBootError = PocketISHFailure() ?: @"iSH kernel did not answer after boot";
                }
            }
        } else {
            PocketISHBootError = failure ?: @"iSH boot failed";
        }
    }
    // A panic after startup (for example init exiting) is never reported ready.
    BOOL booted = PocketISHBooted && !atomic_load(&PocketISHStalled);
    if (!booted && error) *error = PocketISHBootError ?: PocketISHFailure();
    [PocketISHBootLock unlock];
    return booted;
}

NSString *PocketISHFailure(void) {
    if (!atomic_load(&PocketISHStalled)) return nil;
    return PocketISHPanic[0] ? [NSString stringWithFormat:@"iSH kernel panic: %s", PocketISHPanic]
                             : @"iSH kernel stopped responding";
}

int PocketISHMount(NSString *hostDirectory, NSString *mountPoint) {
    // O_NOFOLLOW_ANY in hostfs rejects any symbolic link in a path, so the
    // root must already be canonical (iOS /var is itself a link).
    char *host = strdup(hostDirectory.fileSystemRepresentation), *point = strdup(mountPoint.fileSystemRepresentation);
    char canonical[PATH_MAX];
    if (realpath(host, canonical) == NULL || strcmp(canonical, host) != 0) {
        free(host); free(point);
        return -EINVAL;
    }
    int rooted = pocket_hostfs_set_root(host);
    if (rooted != 0) {
        free(host); free(point);
        return rooted;
    }
    int result = PocketISHWork(30, ^int {
        int mounted = pocket_mount_workspace(host, point);
        free(host); free(point);
        return mounted;
    });
    if (result != 0) pocket_hostfs_set_root(NULL);
    return result;
}

int PocketISHUnmount(NSString *mountPoint) {
    char *point = strdup(mountPoint.fileSystemRepresentation);
    int result = PocketISHWork(30, ^int {
        int unmounted = pocket_unmount_workspace(point);
        free(point);
        return unmounted;
    });
    // Whatever the outcome, no operation of a detached mount reaches the host.
    pocket_hostfs_set_root(NULL);
    return result;
}

int PocketISHUserTasks(int uid, int signal) {
    return PocketISHWork(15, ^int { return pocket_user_tasks(uid, signal); });
}

static char **PocketISHStrings(NSArray<NSString *> *values) {
    char **strings = calloc(values.count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < values.count; i++) strings[i] = strdup(values[i].UTF8String);
    return strings;
}

static void PocketISHFreeStrings(char **strings) {
    for (char **cursor = strings; *cursor; cursor++) free(*cursor);
    free(strings);
}

void PocketISHRun(NSArray<NSString *> *argv, NSArray<NSString *> *environment, int uid, void (^done)(int, int)) {
    void (^finish)(int, int) = [done copy];
    if (atomic_load(&PocketISHStalled)) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ finish(-ETIMEDOUT, 0); });
        return;
    }
    // Host-allocated copies stay valid until the process has exited.
    char **arguments = PocketISHStrings(argv), **variables = PocketISHStrings(environment);
    async_do_in_workqueue(^{
        pocket_run_process((const char *const *)arguments, (const char *const *)variables, uid, ^(int status, int pid) {
            PocketISHFreeStrings(arguments);
            PocketISHFreeStrings(variables);
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ finish(status, pid); });
        });
    });
}

void PocketISHSetBlockedHosts(NSArray<NSNumber *> *addresses) {
    uint32_t values[32] = {0};
    unsigned count = 0;
    for (NSNumber *address in addresses) {
        if (count == 32) break;
        values[count++] = address.unsignedIntValue;
    }
    pocket_set_blocked_hosts(values, count);
}

// MARK: Callbacks required by the iSH kernel libraries

nsobj_t objc_get(nsobj_t object) { return object ? CFBridgingRetain((__bridge id)object) : NULL; }
void objc_put(nsobj_t object) { if (object) CFBridgingRelease(object); }
void async_do_in_ios(void (^block)(void)) { dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), block); }
// Kernel console (boot messages, oopses and the panic text) at the default
// level so a device log shows why the runtime failed.
void ConsoleLog(const char *data, unsigned length) {
    if (PocketISHLog) os_log(PocketISHLog, "%{public}.*s", (int)length, data);
}
// Patch 0005 calls this after parking the panicking kernel thread, instead
// of letting panic() trap the whole app.
void ReportPanic(const char *message) {
    // The message is stored before the stalled flag publishes it.
    if (!PocketISHPanic[0]) strlcpy(PocketISHPanic, message, sizeof PocketISHPanic);
    os_log_fault(PocketISHLog, "iSH kernel panic: %{public}s", message);
    PocketISHPoison();
}
const char *DefaultRootPath(void) { return PocketISHRootPath.fileSystemRepresentation; }
void FsInitialize(void) {}
// No terminal is attached; console devices get no backing object.
nsobj_t Terminal_terminalWithType_number(int type, int number) { return NULL; }
void Terminal_setLinuxTTY(nsobj_t object, struct linux_tty *tty) {}
int Terminal_sendOutput_length(nsobj_t object, const char *data, int size) { return size; }
int Terminal_roomForOutput(nsobj_t object) { return 4096; }
// Scripts never read or replace the user's clipboard.
nsobj_t UIPasteboard_get(void) { return objc_get((__bridge nsobj_t)[NSData data]); }
long UIPasteboard_changeCount(void) { return 0; }
void UIPasteboard_set(const char *data, size_t length) {}
size_t NSData_length(nsobj_t data) { return [(__bridge NSData *)data length]; }
const void *NSData_bytes(nsobj_t data) { return [(__bridge NSData *)data bytes]; }
