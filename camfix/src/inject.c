#include <dlfcn.h>
#include <mach/mach.h>
#include <notify.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <time.h>
#include <unistd.h>

static const char *const kDylib = "/usr/local/lib/TlapseCameraFix.dylib";
static const char *const kLog = "/var/mobile/Timelapse/logs/camera-fix.log";

static void note(const char *message) {
    FILE *file = fopen(kLog, "a");
    if (!file) {
        return;
    }
    time_t now = time(NULL);
    struct tm parts;
    localtime_r(&now, &parts);
    char stamp[32];
    strftime(stamp, sizeof(stamp), "%Y-%m-%d %H:%M:%S", &parts);
    fprintf(file, "%s %s\n", stamp, message);
    fclose(file);
}

static int read_pid(const char *path) {
    FILE *file = fopen(path, "r");
    if (!file) {
        return -1;
    }
    int pid = -1;
    if (fscanf(file, "%d", &pid) != 1) {
        pid = -1;
    }
    fclose(file);
    return pid;
}

static int notify_pid(const char *name) {
    int token = 0;
    if (notify_register_check(name, &token) != NOTIFY_STATUS_OK) {
        return -1;
    }
    uint64_t state = 0;
    uint32_t status = notify_get_state(token, &state);
    notify_cancel(token);
    if (status != NOTIFY_STATUS_OK || state == 0 || state > 0x7fffffffULL) {
        return -1;
    }
    return (int)state;
}

static int marker_pid(void) {
    static const char *const paths[] = {
        "/tmp/tlapse-camera.ready",
        "/var/tmp/tlapse-camera.ready",
        "/var/mobile/Timelapse/logs/camera-fix.ready",
        NULL
    };
    int ready = notify_pid("com.ddxyl.tlapse.camera.ready");
    if (ready > 0) {
        return ready;
    }
    for (int index = 0; paths[index]; index++) {
        int pid = read_pid(paths[index]);
        if (pid > 0) {
            return pid;
        }
    }
    return -1;
}

static int find_mediaserverd(void) {
    int mib[3] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL};
    size_t size = 0;
    if (sysctl(mib, 3, NULL, &size, NULL, 0) != 0 || size == 0) {
        return 0;
    }
    size += 16384;
    struct kinfo_proc *procs = malloc(size);
    if (!procs) {
        return 0;
    }
    if (sysctl(mib, 3, procs, &size, NULL, 0) != 0) {
        free(procs);
        return 0;
    }
    int found = 0;
    int count = (int)(size / sizeof(struct kinfo_proc));
    for (int index = 0; index < count; index++) {
        if (strcmp(procs[index].kp_proc.p_comm, "mediaserverd") == 0) {
            found = procs[index].kp_proc.p_pid;
            break;
        }
    }
    free(procs);
    return found;
}

static void note_code(const char *what, kern_return_t code) {
    char message[160];
    snprintf(message, sizeof(message), "%s %d", what, (int)code);
    note(message);
}

static uint64_t find_break(void) {
    vm_address_t address = 0;
    int regions = 0;
    while (regions < 400 && address < 0x800000000ULL) {
        vm_size_t size = 0;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t object = MACH_PORT_NULL;
        kern_return_t kr = vm_region_64(mach_task_self(), &address, &size, VM_REGION_BASIC_INFO_64,
                                        (vm_region_info_t)&info, &count, &object);
        if (kr != KERN_SUCCESS || size == 0) {
            break;
        }
        regions += 1;
        int executable = (info.protection & (VM_PROT_READ | VM_PROT_EXECUTE)) == (VM_PROT_READ | VM_PROT_EXECUTE);
        if (executable && size <= 0x4000000) {
            const uint32_t *code = (const uint32_t *)address;
            size_t words = size / sizeof(uint32_t);
            for (size_t index = 0; index < words; index++) {
                if ((code[index] & 0xFFE0001Fu) == 0xD4200000u) {
                    return (uint64_t)address + index * sizeof(uint32_t);
                }
            }
        }
        vm_address_t next = address + size;
        if (next <= address) {
            break;
        }
        address = next;
    }
    char message[80];
    snprintf(message, sizeof(message), "没有找到断点指令，区域 %d", regions);
    note(message);
    return 0;
}

__attribute__((naked)) static void tlapse_open_now(void) {
    __asm__ volatile(
        "stp x19, x20, [sp, #-32]!\n"
        "str x30, [sp, #16]\n"
        "mov x19, x0\n"
        "ldr x16, [x19]\n"
        "ldr x0, [x19, #8]\n"
        "mov x1, #2\n"
        "blr x16\n"
        "mov x20, x0\n"
        "cbnz x20, 1f\n"
        "ldr x16, [x19, #24]\n"
        "cbz x16, 1f\n"
        "blr x16\n"
        "cbz x0, 1f\n"
        "mov x1, x0\n"
        "add x0, x19, #40\n"
        "mov w2, #180\n"
        "2:\n"
        "ldrb w3, [x1], #1\n"
        "cbz w3, 3f\n"
        "subs w2, w2, #1\n"
        "strb w3, [x0], #1\n"
        "b.ne 2b\n"
        "strb wzr, [x0]\n"
        "b 1f\n"
        "3:\n"
        "strb wzr, [x0]\n"
        "1:\n"
        "str x20, [x19, #16]\n"
        "ldr x30, [sp, #16]\n"
        "ldp x19, x20, [sp], #32\n"
        "ret\n");
}

static int remote_call(task_t task, uint64_t function, uint64_t arg0, uint64_t arg1, uint64_t arg2, uint64_t arg3,
                       uint64_t breakpoint, uint64_t *result) {
    *result = 0;
    vm_address_t stack = 0;
    kern_return_t kr = vm_allocate(task, &stack, 0x10000, VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS) {
        note_code("分配栈失败", kr);
        return 1;
    }
    thread_act_t thread = MACH_PORT_NULL;
    kr = thread_create(task, &thread);
    if (kr != KERN_SUCCESS) {
        note_code("创建线程失败", kr);
        vm_deallocate(task, stack, 0x10000);
        return 1;
    }
    arm_thread_state64_t state;
    memset(&state, 0, sizeof(state));
    state.__x[0] = arg0;
    state.__x[1] = arg1;
    state.__x[2] = arg2;
    state.__x[3] = arg3;
    uint64_t stackPointer = (stack + 0x10000 - 0x100) & ~15ULL;
    __darwin_arm_thread_state64_set_sp(state, (void *)(uintptr_t)stackPointer);
    __darwin_arm_thread_state64_set_fp(state, NULL);
    __darwin_arm_thread_state64_set_pc_fptr(state, (void *)(uintptr_t)function);
    __darwin_arm_thread_state64_set_lr_fptr(state, (void *)(uintptr_t)breakpoint);
    kr = thread_set_state(thread, ARM_THREAD_STATE64, (thread_state_t)&state, ARM_THREAD_STATE64_COUNT);
    mach_port_t port = MACH_PORT_NULL;
    if (kr == KERN_SUCCESS) {
        kr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port);
    }
    if (kr == KERN_SUCCESS) {
        kr = mach_port_insert_right(mach_task_self(), port, port, MACH_MSG_TYPE_MAKE_SEND);
    }
    if (kr == KERN_SUCCESS) {
        kr = thread_set_exception_ports(thread, EXC_MASK_ALL, port, EXCEPTION_DEFAULT, ARM_THREAD_STATE64);
    }
    if (kr != KERN_SUCCESS) {
        note_code("准备新线程失败", kr);
        thread_terminate(thread);
        mach_port_deallocate(mach_task_self(), thread);
        if (port != MACH_PORT_NULL) {
            mach_port_destroy(mach_task_self(), port);
        }
        vm_deallocate(task, stack, 0x10000);
        return 1;
    }
    kr = thread_resume(thread);
    if (kr != KERN_SUCCESS) {
        note_code("启动新线程失败", kr);
        thread_terminate(thread);
        mach_port_deallocate(mach_task_self(), thread);
        mach_port_destroy(mach_task_self(), port);
        vm_deallocate(task, stack, 0x10000);
        return 1;
    }
    int status = 2;
    for (int attempt = 0; attempt < 80; attempt++) {
        struct {
            mach_msg_header_t head;
            unsigned char rest[512];
        } message;
        memset(&message, 0, sizeof(message));
        kr = mach_msg(&message.head, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof(message), port, 100, MACH_PORT_NULL);
        if (kr != KERN_SUCCESS) {
            continue;
        }
        arm_thread_state64_t now;
        mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
        memset(&now, 0, sizeof(now));
        thread_get_state(thread, ARM_THREAD_STATE64, (thread_state_t)&now, &count);
        uint64_t pc = __darwin_arm_thread_state64_get_pc(now);
        *result = now.__x[0];
        char line[180];
        snprintf(line, sizeof(line), "调用返回 pc=0x%llx x0=0x%llx",
                 (unsigned long long)pc, (unsigned long long)*result);
        note(line);
        status = 0;
        break;
    }
    if (status == 2) {
        note("调用超时");
        mach_port_deallocate(mach_task_self(), thread);
        return 2;
    }
    thread_terminate(thread);
    mach_port_deallocate(mach_task_self(), thread);
    mach_port_destroy(mach_task_self(), port);
    usleep(50000);
    vm_deallocate(task, stack, 0x10000);
    return 0;
}

static int inject(int pid) {
    task_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr != KERN_SUCCESS) {
        note_code("拿不到任务端口", kr);
        return 1;
    }
    void *openfn = dlsym(RTLD_DEFAULT, "dlopen");
    void *getpidfn = dlsym(RTLD_DEFAULT, "getpid");
    uint64_t breakpoint = find_break();
    if (!openfn || !getpidfn || breakpoint == 0) {
        note("找不到可调用的系统函数");
        mach_port_deallocate(mach_task_self(), task);
        return 1;
    }
    {
        char message[180];
        snprintf(message, sizeof(message), "dlopen=0x%llx getpid=0x%llx brk=0x%llx",
                 (unsigned long long)(uintptr_t)openfn,
                 (unsigned long long)(uintptr_t)getpidfn,
                 (unsigned long long)breakpoint);
        note(message);
    }

    char pathbuf[256];
    snprintf(pathbuf, sizeof(pathbuf), "%s", kDylib);
    vm_address_t remotePath = 0;
    kr = vm_allocate(task, &remotePath, 0x1000, VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS) {
        note_code("分配路径内存失败", kr);
        mach_port_deallocate(mach_task_self(), task);
        return 1;
    }
    kr = vm_write(task, remotePath, (vm_offset_t)(uintptr_t)pathbuf, (mach_msg_type_number_t)sizeof(pathbuf));
    if (kr != KERN_SUCCESS) {
        note_code("写入路径失败", kr);
        vm_deallocate(task, remotePath, 0x1000);
        mach_port_deallocate(mach_task_self(), task);
        return 1;
    }

    uint64_t result = 0;
    int probe = remote_call(task, (uint64_t)(uintptr_t)getpidfn, 0, 0, 0, 0, breakpoint, &result);
    if (probe != 0 || result != (uint64_t)pid) {
        char message[180];
        snprintf(message, sizeof(message), "新线程自检失败 状态 %d 返回 %llu", probe, (unsigned long long)result);
        note(message);
        vm_deallocate(task, remotePath, 0x1000);
        mach_port_deallocate(mach_task_self(), task);
        return probe == 0 ? 1 : probe;
    }
    note("新线程可以执行系统函数");

    void *creator = dlsym(RTLD_DEFAULT, "pthread_create_from_mach_thread");
    void *errfn = dlsym(RTLD_DEFAULT, "dlerror");
    if (!creator) {
        note("没有 pthread_create_from_mach_thread");
        vm_deallocate(task, remotePath, 0x1000);
        mach_port_deallocate(mach_task_self(), task);
        return 1;
    }
    if (!errfn) {
        note("没有 dlerror");
    }
    uintptr_t localFn = (uintptr_t)tlapse_open_now;
    vm_address_t srcPage = localFn & ~0xfffULL;
    vm_size_t mapSize = ((localFn & 0xfffULL) > 0xe00ULL) ? 0x2000 : 0x1000;
    vm_address_t dstPage = 0;
    vm_prot_t currentProt = VM_PROT_NONE;
    vm_prot_t maxProt = VM_PROT_NONE;
    kr = vm_remap(task, &dstPage, mapSize, 0, VM_FLAGS_ANYWHERE, mach_task_self(), srcPage, FALSE, &currentProt, &maxProt,
                  VM_INHERIT_NONE);
    if (kr != KERN_SUCCESS && mapSize != 0x1000) {
        mapSize = 0x1000;
        dstPage = 0;
        kr = vm_remap(task, &dstPage, mapSize, 0, VM_FLAGS_ANYWHERE, mach_task_self(), srcPage, FALSE, &currentProt,
                      &maxProt, VM_INHERIT_NONE);
    }
    if (kr != KERN_SUCCESS) {
        note_code("映射代码页失败", kr);
        vm_deallocate(task, remotePath, 0x1000);
        mach_port_deallocate(mach_task_self(), task);
        return 1;
    }
    uint64_t remoteFn = dstPage + (localFn - srcPage);
    {
        char message[180];
        snprintf(message, sizeof(message), "代码页 0x%llx 权限 %d", (unsigned long long)remoteFn, (int)currentProt);
        note(message);
    }
    static const char *const paths[] = {
        "/usr/local/lib/TlapseCameraFix.dylib",
        "/usr/lib/TlapseCameraFix.dylib",
        "/usr/lib/TlapseCameraFixLd.dylib",
        "/private/var/tmp/TlapseCameraFix.dylib",
        NULL
    };
    vm_address_t remoteArgs = remotePath + 256;
    uint64_t remoteThread = remotePath + 512;
    int loaded = 0;
    int stopped = 0;
    for (int index = 0; paths[index] != NULL; index++) {
        char pathbuf[256];
        snprintf(pathbuf, sizeof(pathbuf), "%s", paths[index]);
        kr = vm_write(task, remotePath, (vm_offset_t)(uintptr_t)pathbuf, (mach_msg_type_number_t)sizeof(pathbuf));
        if (kr != KERN_SUCCESS) {
            note_code("写入路径失败", kr);
            stopped = 1;
            break;
        }
        unsigned char block[224];
        memset(block, 0, sizeof(block));
        uint64_t header[5];
        header[0] = (uint64_t)(uintptr_t)openfn;
        header[1] = remotePath;
        header[2] = 1;
        header[3] = (uint64_t)(uintptr_t)errfn;
        header[4] = 0;
        memcpy(block, header, sizeof(header));
        kr = vm_write(task, remoteArgs, (vm_offset_t)(uintptr_t)block, (mach_msg_type_number_t)sizeof(block));
        if (kr != KERN_SUCCESS) {
            note_code("写入参数失败", kr);
            stopped = 1;
            break;
        }
        result = 0;
        int started = remote_call(task, (uint64_t)(uintptr_t)creator, remoteThread, 0, remoteFn, remoteArgs, 0, &result);
        if (started == 2) {
            note("创建拍摄线程没有返回，停止继续尝试");
            vm_deallocate(task, remotePath, 0x1000);
            mach_port_deallocate(mach_task_self(), task);
            return 2;
        }
        if (started != 0 || result != 0) {
            char message[180];
            snprintf(message, sizeof(message), "创建拍摄线程失败 状态 %d 返回 %llu", started, (unsigned long long)result);
            note(message);
            continue;
        }
        uint64_t handle = 1;
        unsigned char page[0x1000];
        memset(page, 0, sizeof(page));
        for (int attempt = 0; attempt < 40 && handle == 1; attempt++) {
            vm_offset_t out = 0;
            mach_msg_type_number_t outCount = 0;
            kr = vm_read(task, remotePath, 0x1000, &out, &outCount);
            if (kr == KERN_SUCCESS && outCount >= 0x1000) {
                memcpy(page, (void *)(uintptr_t)out, 0x1000);
                memcpy(&handle, page + 272, sizeof(handle));
                vm_deallocate(mach_task_self(), out, outCount);
            }
            if (handle == 1) {
                usleep(50000);
            }
        }
        if (handle == 1) {
            note("动态库调用没有结束，停止继续尝试");
            stopped = 2;
            break;
        }
        if (handle >= 0x100000000ULL && handle < 0x0000800000000000ULL) {
            char message[320];
            snprintf(message, sizeof(message), "路径 %s 已映射 0x%llx", paths[index], (unsigned long long)handle);
            note(message);
            loaded = 1;
            usleep(100000);
            break;
        }
        char text[200];
        size_t out = 0;
        for (size_t byte = 296; byte < 480 && out + 1 < sizeof(text); byte++) {
            unsigned char ch = page[byte];
            if (ch == 0) {
                break;
            }
            if (ch < 0x20 || ch > 0x7e) {
                ch = ' ';
            }
            text[out++] = (char)ch;
        }
        text[out] = 0;
        if (out == 0) {
            snprintf(text, sizeof(text), "没有返回错误信息");
        }
        char message[512];
        snprintf(message, sizeof(message), "路径 %s 没有映射 返回 0x%llx %s", paths[index], (unsigned long long)handle, text);
        note(message);
    }
    vm_deallocate(task, remotePath, 0x1000);
    mach_port_deallocate(mach_task_self(), task);
    if (stopped == 2) {
        return 2;
    }
    return loaded ? 0 : 1;
}

int main(int argc, char **argv) {
    (void)argv;
    int once = argc > 1;
    write(2, "injector-start\n", 15);
    mkdir("/var/mobile/Timelapse/logs", 0755);
    note(once ? "注入器启动 单次" : "注入器启动");
    int fails = 0;
    int injected = 0;
    int announced = 0;
    while (1) {
        int pid = find_mediaserverd();
        if (pid <= 0) {
            sleep(2);
            continue;
        }
        int marked = marker_pid();
        if (marked == pid) {
            fails = 0;
            injected = pid;
            if (announced != pid) {
                note("摄像头例外已生效");
                announced = pid;
            }
            sleep(5);
            continue;
        }
        if (injected == pid) {
            sleep(5);
            continue;
        }
        if (fails >= 3) {
            note("连续注入失败，5 分钟后再试");
            sleep(300);
            fails = 0;
            continue;
        }
        char message[160];
        snprintf(message, sizeof(message), "注入 mediaserverd pid %d", pid);
        note(message);
        int status = inject(pid);
        snprintf(message, sizeof(message), "注入结果 %d", status);
        note(message);
        sleep(2);
        int now = find_mediaserverd();
        marked = marker_pid();
        if (now != pid) {
            fails += 1;
            snprintf(message, sizeof(message), "mediaserverd 在注入后重启了，第 %d 次", fails);
            note(message);
            if (once) {
                return 1;
            }
            sleep(3);
            continue;
        }
        if (once) {
            if (status == 2) {
                note("单次注入未返回，进程保持住");
                for (;;) {
                    sleep(30);
                }
            }
            return status == 0 ? 0 : 1;
        }
        if (status == 2) {
            note("调用没有返回，避免再开线程");
            injected = pid;
            sleep(5);
            continue;
        }
        if (status != 0) {
            fails += 1;
            snprintf(message, sizeof(message), "注入没有成功，第 %d 次", fails);
            note(message);
            sleep(5);
            continue;
        }
        injected = pid;
        fails = 0;
        if (marked == pid) {
            note("摄像头例外已生效");
            announced = pid;
        } else {
            note("已注入，进程仍在，但没有就绪标记");
        }
    }
    return 0;
}
