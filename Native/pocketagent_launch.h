#include "idevice.h"
struct IdeviceFfiError *process_control_launch_test_runner(
    struct ProcessControlHandle *handle, const char *bundle_id,
    const char *const *env_vars, uintptr_t env_vars_count, uint64_t *pid);
