// Embedded iSH Linux runtime used by run_script. Every function except
// PocketISHFailure, PocketISHSetBlockedHosts and PocketISHRun blocks until a
// Linux work item finishes or its bound expires: call them off the main thread.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Imports the bundled rootfs archive into `runtimeDirectory` once per archive
/// content (SHA-256), then boots the kernel, waiting at most 60 s for it to
/// start (after that the runtime is unusable until relaunch). Safe to call
/// repeatedly; later calls return the first result.
BOOL PocketISHBoot(NSString *archivePath, NSString *runtimeDirectory, NSString *_Nullable *_Nullable error);
/// nil while the runtime is usable; otherwise why it was poisoned (the
/// kernel panic message, or a bound that expired). Never usable again.
NSString *_Nullable PocketISHFailure(void);
/// Mounts a canonical host directory (no symbolic link in its path) at an
/// existing guest directory; every hostfs operation is confined below it.
/// Returns 0 or a negative errno (-ETIMEDOUT when the kernel does not answer).
int PocketISHMount(NSString *hostDirectory, NSString *mountPoint);
/// Detaches the mount and refuses all further hostfs access. 0 or -errno.
int PocketISHUnmount(NSString *mountPoint);
/// Live non-kernel threads owned by `uid`; with `signal` > 0 each is
/// signalled. A negative value is an error (count unknown), never zero.
int PocketISHUserTasks(int uid, int signal);
/// Starts `argv` as a new session owned by `uid` with no capabilities.
/// `done` runs on a background queue with the kernel wait status (or -errno).
void PocketISHRun(NSArray<NSString *> *argv, NSArray<NSString *> *environment, int uid,
                  void (^done)(int status, int pid));
/// IPv4 destinations (network byte order) guest traffic may not reach, in
/// addition to the fixed loopback/private/reserved ranges. Replaces the list.
void PocketISHSetBlockedHosts(NSArray<NSNumber *> *addressesNetworkOrder);

NS_ASSUME_NONNULL_END
